# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "rubygems/package"
require "zlib"
begin
  require "sqlite3"
rescue LoadError
  # Other CLI/converter modes need not inspect SQLite. Fail only when required.
end
require "rbconfig"
require "set"
require "shellwords"
require "time"
require "yaml"
require_relative "discourse_archive"

module SiloMigrate
  module Services
    class DiscourseService
      include DiscourseArchive

      ROLES = %w[uploads import].freeze
      STANDARD_DISCOURSE_REVISION = "3158c7503a59d0952c84cc8c032790e80167bf38"
      STANDARD_LOCK_SHA256 = "bacaa276aebc56385bf28c9fefbc6224e494e0361bd734933b4a20427e0f87d2"
      STANDARD_RUBY_VERSION = "4.0.9"
      STANDARD_BUNDLER_VERSION = "4.0.23"
      ROLE_BOTH = "both"
      DEFAULT_DOCKER_PATH = "/var/discourse"
      DEFAULT_DOCKER_REPO = "https://github.com/discourse/discourse_docker.git"
      DEFAULT_UPLOADS_PORT = "8080"
      DEFAULT_IMPORT_PORT = "8081"
      DEFAULT_DEVELOPER_EMAILS = "ruben@discourse.org"
      DEFAULT_WORKERS = "4"
      DEFAULT_DB_POOL = "200"
      DEFAULT_SHARED_BUFFERS = "32GB"
      DEFAULT_MAX_CONNECTIONS = "250"
      DEPENDENCY_TIMEOUT = 1_200
      IMPORT_TIMEOUT = nil
      REBUILD_TIMEOUT = nil
      BACKUP_TIMEOUT = nil

      attr_reader :env

      def initialize(runtime: Runtime::Docker.new, env: ENV, output: $stdout)
        Runtime::Contract.assert_implemented!(runtime)
        @runtime = runtime
        @env = env
        @output = output
      end

      def setup(customer, options = {})
        customer = Project.validate_customer_name!(customer)
        config = Project.load_config(customer, @env)
        Project.ensure_project_dirs(customer, @env)

        explicit_keys = (existing_discourse_config(config).keys + stringify_config(options).keys).to_set
        discourse_config = default_config(customer).merge(existing_discourse_config(config)).merge(stringify_config(options))
        if standard_local?(discourse_config)
          { "DISCOURSE_WORKERS" => "1", "DISCOURSE_DB_POOL" => "5",
            "DISCOURSE_DB_SHARED_BUFFERS" => "128MB", "DISCOURSE_DB_MAX_CONNECTIONS" => "20" }.each do |key, value|
            discourse_config[key] = value unless explicit_keys.include?(key)
          end
        end
        validate_guest_root!(discourse_config.fetch("DISCOURSE_IMPORT_GUEST_ROOT"))
        validate_service_ports!(config, discourse_config, explicit_keys: explicit_keys)
        validate_discourse_docker_path!(discourse_config.fetch("DISCOURSE_DOCKER_PATH"))
        validate_scratch_dirs!(customer) if standard_local?(discourse_config)
        ensure_discourse_dirs(customer, discourse_config)
        write_container_yml(customer, "uploads", discourse_config)
        write_container_yml(customer, "import", discourse_config)
        write_uploads_importer_config(customer, discourse_config)
        # Persist config only after the launcher/container artifacts exist, so
        # a failed setup cannot leave config claiming containers that were
        # never created.
        Project.save_config(customer, config.merge(discourse_config), @env)

        @output.puts "[OK] Discourse containers configured:"
        @output.puts "  uploads: #{discourse_config.fetch('DISCOURSE_UPLOADS_CONTAINER')} on 127.0.0.1:#{discourse_config.fetch('DISCOURSE_UPLOADS_PORT')}"
        @output.puts "  import:  #{discourse_config.fetch('DISCOURSE_IMPORT_CONTAINER')} on 127.0.0.1:#{discourse_config.fetch('DISCOURSE_IMPORT_PORT')}"
        discourse_config
      end

      def install_launcher(docker_path: DEFAULT_DOCKER_PATH, branch: "main", repo: DEFAULT_DOCKER_REPO)
        ensure_linux_launcher_install_supported!(docker_path)
        ensure_program!("git", ["git", "--version"], "install Git")
        ensure_program!("Docker", ["docker", "version", "--format", "{{.Server.Version}}"], "install and start Docker")

        target = File.expand_path(docker_path)
        if valid_discourse_docker_path?(target)
          @output.puts "[OK] Discourse Docker launcher already installed: #{target}"
          return target
        end

        if Dir.exist?(target)
          entries = Dir.children(target) - %w[.DS_Store]
          unless entries.empty?
            raise UsageError, invalid_discourse_path_message(target)
          end
        else
          ensure_install_parent!(target)
        end

        result = @runtime.run(["git", "clone", "-b", branch, repo, target], timeout: 300)
        raise UsageError, "Could not clone discourse_docker into #{target}" unless result.success?

        validate_discourse_docker_path!(target)
        @output.puts "[OK] Discourse Docker launcher installed: #{target}"
        target
      end

      def rebuild(customer, role: ROLE_BOTH)
        each_role(role) do |selected_role|
          run_launcher(customer, "rebuild", container_name(customer, selected_role), role: selected_role, timeout: REBUILD_TIMEOUT)
        end
        @output.puts "[OK] Discourse rebuild completed for #{role}"
      end

      def start(customer, role: ROLE_BOTH)
        each_role(role) do |selected_role|
          run_launcher(customer, "start", container_name(customer, selected_role), role: selected_role)
        end
        @output.puts "[OK] Discourse container(s) started for #{role}"
      end

      def stop(customer, role: ROLE_BOTH)
        each_role(role) do |selected_role|
          run_launcher(customer, "stop", container_name(customer, selected_role), role: selected_role)
        end
        @output.puts "[OK] Discourse container(s) stopped for #{role}"
      end

      def status(customer, role: ROLE_BOTH)
        lines = each_role(role).map do |selected_role|
          name = container_name(customer, selected_role)
          state = if @runtime.respond_to?(:container_running?) && @runtime.container_running?(name)
                    "running"
                  else
                    "stopped"
                  end
          "#{selected_role}: #{name} #{state}"
        end
        @output.puts lines.join("\n")
        lines
      end

      # Runtime preparation is a separate, pinned build task. Never resolve/install
      # dependencies opportunistically into a running destination.
      def prepare_deps(customer, role: ROLE_BOTH)
        each_role(role) do |selected_role|
          container = container_name(customer, selected_role)
          assert_standard_runtime!(container) if standard_local?(discourse_config(customer))
          command = discourse_command(container, ["bundle", "check"])
          log_command_notice("Checking frozen Discourse #{selected_role} dependencies in #{container}...", command)
          result = @runtime.run(command, timeout: DEPENDENCY_TIMEOUT)
          raise UsageError, "Frozen dependencies missing for #{selected_role}; prepare the pinned migration image separately" unless result.success?
        end
        @output.puts "[OK] Frozen Discourse import dependencies checked for #{role}"
      end

      def run_uploads(customer, role: "uploads")
        raise UsageError, "Upload processing requires one explicit role: uploads or import" unless ROLES.include?(role)

        source = intermediate_db_path(customer)
        ensure_file!(source, "Run the converter first to create the selected converter output database.")
        setup(customer) unless discourse_configured?(customer)
        config = discourse_config(customer)
        validate_scratch_dirs!(customer) if standard_local?(config)
        write_uploads_importer_config(customer, config)
        if standard_local?(config)
          ensure_single_link_db!(source)
          validate_local_uploads!(customer, source)
        end
        store = WorkflowStore.new(customer, env: @env, runtime: @runtime)
        prior = lineage = nil
        store.with_lock do
          state = store.read
          prior = state.dig("discourse", "state")
          if state.dig("discourse", "uploads") || File.exist?(uploads_db_path(customer)) || File.symlink?(uploads_db_path(customer))
            raise UsageError, "Upload processing already attempted or output exists; use a fresh snapshot scratch project, not a repeat run"
          end
          if role == "import" && !%w[pristine restored].include?(prior)
            raise UsageError, "Discourse import instance is #{prior}; upload processing is blocked"
          end
          lineage = file_identity(source).merge("role" => role, "container" => container_name(customer, role), "state" => "dirty")
          store.update do |current|
            current.fetch("discourse")["uploads"] = lineage
            current.fetch("discourse")["state"] = "dirty" if role == "import"
          end
        end
        container = container_name(customer, role)
        assert_local_runtime!(container) if standard_local?(config)
        command = discourse_command(container, ["bundle", "exec", "ruby", "/var/www/discourse/script/bulk_import/uploads_importer.rb", uploads_importer_guest_config_path(customer)])
        log_command_notice("Running Discourse uploads importer in #{container}...", command)
        result = @runtime.run(command, timeout: IMPORT_TIMEOUT)
        raise UsageError, "Upload import failed" unless result.success?
        validate_processing_db!(uploads_db_path(customer))
        assert_local_runtime!(container) if standard_local?(config)
        store.update do |current|
          current.fetch("discourse")["uploads"] = lineage.merge("state" => "processed", "processing_db" => file_identity(uploads_db_path(customer)))
          current.fetch("discourse")["state"] = prior if role == "import"
        end
        @output.puts "[OK] Upload import completed: #{uploads_db_path(customer)}"
      end

      def restore_import(customer, backup:)
        setup(customer) unless discourse_configured?(customer)
        ensure_file!(backup, "Supply a regular local Discourse backup.")
        backup_basename = validate_backup_filename!(File.basename(backup), restore: true)
        store = WorkflowStore.new(customer, env: @env, runtime: @runtime)
        store.with_lock do
          state = store.read
          discourse_state = state.dig("discourse", "state")
          unless discourse_state == "pristine" && (!state.dig("discourse", "uploads") ||
            (state.dig("discourse", "uploads", "role") == "uploads" && state.dig("discourse", "uploads", "state") == "processed"))
            raise UsageError, "Discourse import instance is #{discourse_state}; restore is blocked. Reset it first: silo-migrate discourse reset-import #{customer} --yes"
          end
          store.update { |current| current.fetch("discourse")["state"] = "dirty" }
        end
        name = container_name(customer, "import")
        prior_restore = nil
        begin
          assert_standard_runtime!(name) if standard_local?(discourse_config(customer))
          prior_restore = restore_enabled?(name)
          backup_dir = "/var/www/discourse/public/backups/default"
          remote = "#{backup_dir}/#{backup_basename}"
          check = @runtime.run(["docker", "exec", name, "test", "!", "-e", remote], timeout: 30)
          raise UsageError, "Restore backup identity already exists in #{name}" unless check.success?
          copy_command = ["docker", "cp", File.expand_path(backup), "#{name}:#{remote}"]
          log_command_notice("Copying Discourse backup into #{name}...", copy_command)
          copy = @runtime.run(copy_command, timeout: BACKUP_TIMEOUT)
          raise UsageError, "Could not copy backup into #{name}" unless copy.success?

          begin
            set_restore_enabled!(name, true) unless prior_restore
            restore_command = discourse_command(name, ["bundle", "exec", "script/discourse", "restore", backup_basename, "--location", "local"])
            log_command_notice("Restoring Discourse backup in #{name}...", restore_command)
            restore = @runtime.run(restore_command, timeout: BACKUP_TIMEOUT)
            raise UsageError, "Backup restore failed in #{name}" unless restore.success?
          ensure
            # The restored DB can carry a different setting. Restore the caller's
            # original value even if enable/restore itself failed.
            set_restore_enabled!(name, prior_restore)
            raise UsageError, "Restore permission cleanup did not take effect in #{name}" unless restore_enabled?(name) == prior_restore
          end
          restored_at = Time.now.utc.iso8601
          marker = File.join(Project.project_path(customer, @env), "output", "discourse-import-restored.txt")
          Project.atomic_write(marker, "#{restored_at} #{backup_basename}\n")
          store.update do |current|
            current.fetch("discourse").merge!("state" => "restored", "restored_at" => restored_at, "backup" => backup_basename, "baseline" => file_identity(backup))
          end
          @output.puts "[OK] Backup restored into #{name}"
        rescue StandardError
          store.update { |current| current.fetch("discourse")["state"] = "dirty" }
          raise
        end
      end

      def import(customer, no_uploads_db: false)
        setup(customer) unless discourse_configured?(customer)
        ensure_file!(intermediate_db_path(customer), "Run the converter first to create the selected converter output database.")
        store = WorkflowStore.new(customer, env: @env, runtime: @runtime)
        use_uploads_db = !no_uploads_db
        store.with_lock do
          workflow = store.read
          current_state = workflow.dig("discourse", "state")
          unless %w[pristine restored].include?(current_state)
            raise UsageError, "Discourse import instance is #{current_state}; repeat import is blocked. Reset it first: silo-migrate discourse reset-import #{customer} --yes"
          end
          if standard_local?(discourse_config(customer))
            validate_scratch_dirs!(customer)
            ensure_single_link_db!(intermediate_db_path(customer))
          end
          use_uploads_db = !no_uploads_db
          validate_processing_db!(uploads_db_path(customer)) if use_uploads_db
          upload_lineage = workflow.dig("discourse", "uploads")
          if use_uploads_db && standard_local?(discourse_config(customer)) &&
             (!upload_lineage || upload_lineage["role"] != "import" || upload_lineage["container"] != container_name(customer, "import"))
            raise UsageError, "Standard local upload import requires processing on this same destination instance"
          end
          if upload_lineage
            unless upload_lineage["state"] == "processed" &&
                   upload_lineage["sha256"] == file_identity(intermediate_db_path(customer))["sha256"] &&
                   upload_lineage["processing_db"] == file_identity(uploads_db_path(customer))
              raise UsageError, "Upload processing lineage does not match this snapshot"
            end
            if upload_lineage["role"] == "uploads" && !workflow.dig("discourse", "baseline")
              raise UsageError, "Separate upload role requires its post-processing full DB+uploads restore before import"
            end
          end
          store.update { |current| current.fetch("discourse")["state"] = "dirty" }
        end
        args = ["bundle", "exec", "ruby", "script/bulk_import/generic_bulk.rb", guest_output_db_path(customer)]
        args << "#{guest_root(customer)}/output/uploads.sqlite3" if use_uploads_db
        @output.puts "[WARN] Explicitly skipping uploads.sqlite3; converter output only." if no_uploads_db
        container = container_name(customer, "import")
        docker_command = discourse_command(container, args)
        standard = standard_local?(discourse_config(customer))
        docker_command = bounded_import_command(docker_command) if standard
        log_command_notice("Running Discourse generic import in #{container}...", docker_command)
        begin
          if standard
            use_uploads_db ? assert_local_runtime!(container) : assert_standard_runtime!(container)
          end
          result = @runtime.run(docker_command, capture: standard, timeout: IMPORT_TIMEOUT)
          raise UsageError, "Generic bulk import failed" unless result.success?
          assert_clean_import_report!(result) if standard

          imported_at = Time.now.utc.iso8601
          marker = File.join(Project.project_path(customer, @env), "output", "discourse-import-complete.txt")
          Project.atomic_write(marker, "#{imported_at}\n")
          store.update do |current|
            current.fetch("discourse").merge!(
              "state" => "imported", "imported_at" => imported_at,
              "output_lineage" => current.dig("converter", "output_lineage"),
              "intermediate" => file_identity(intermediate_db_path(customer)),
              "processing_db" => use_uploads_db ? file_identity(uploads_db_path(customer)) : nil
            )
          end
          @output.puts "[OK] Generic bulk import completed"
        rescue StandardError
          store.update { |current| current.fetch("discourse")["state"] = "dirty" }
          raise
        end
      end

      def reset_import(customer, yes: false)
        raise UsageError, "Resetting the Discourse import instance is destructive. Re-run with --yes." unless yes

        config = discourse_config(customer)
        validate_discourse_docker_path!(config.fetch("DISCOURSE_DOCKER_PATH"))
        name = container_name(customer, "import", config)
        store = WorkflowStore.new(customer, env: @env, runtime: @runtime)
        store.update { |state| state.fetch("discourse")["state"] = "dirty" }
        result = @runtime.run(["./launcher", "destroy", name], chdir: config.fetch("DISCOURSE_DOCKER_PATH"), capture: true, timeout: REBUILD_TIMEOUT)
        raise UsageError, "Could not destroy Discourse import container #{name}" unless result.success?

        shared_root_path = File.join(config.fetch("DISCOURSE_DOCKER_PATH"), "shared")
        FileUtils.mkdir_p(shared_root_path)
        shared_root = File.realpath(shared_root_path)
        shared = File.join(shared_root, name)
        unless File.basename(shared) == name && File.expand_path(shared).start_with?("#{shared_root}#{File::SEPARATOR}")
          raise UsageError, "Refusing to reset unexpected Discourse shared directory: #{shared}"
        end
        FileUtils.rm_rf(shared)
        FileUtils.mkdir_p(shared)
        project = Project.project_path(customer, @env)
        FileUtils.rm_f(File.join(project, "output", "discourse-import-restored.txt"))
        FileUtils.rm_f(File.join(project, "output", "discourse-import-complete.txt"))
        run_launcher(customer, "rebuild", name, role: "import", timeout: REBUILD_TIMEOUT)
        store.update do |state|
          state["discourse"] = WorkflowStore.new(customer, env: @env).default_state.fetch("discourse")
        end
        @output.puts "[OK] Discourse import instance reset to pristine; converter output and final backups were preserved"
      end

      def backup_import(customer, filename: nil, required_uploads: [])
        filename = validate_backup_filename!(filename)
        required_uploads.each { |member| validate_upload_member!(member) }
        setup(customer) unless discourse_configured?(customer)
        store = WorkflowStore.new(customer, env: @env, runtime: @runtime)
        store.with_lock do
          state = store.read
          unless %w[pristine restored imported].include?(state.dig("discourse", "state"))
            raise UsageError, "Cannot back up a dirty/stale/unknown destination"
          end
          name = container_name(customer, "import")
          stem = filename.delete_suffix(".tar.gz")
          validate_scratch_dirs!(customer)
          root = File.join(Project.project_path(customer, @env), "output", "discourse-backups")
          raise UsageError, "Backup output root must not be a symlink" if File.symlink?(root)
          FileUtils.mkdir_p(root)
          unless File.realpath(root) == File.expand_path(root)
            raise UsageError, "Backup output directory and parents must not be symlinks"
          end
          destination = File.join(root, stem)
          begin
            Dir.mkdir(destination, 0o700) # Consume this output identity even on failure.
          rescue Errno::EEXIST
            raise UsageError, "Backup output identity already exists: #{stem}"
          end
          remote_dir = "/shared/silo-migrate-backup-#{stem}"
          receipt = { "state" => "dirty", "requested_filename" => filename, "container" => name,
                      "destination" => state.fetch("discourse"), "converter" => state.fetch("converter"),
                      "configured_app_revision" => standard_local?(discourse_config(customer)) ? STANDARD_DISCOURSE_REVISION : nil }
          receipt_path = File.join(destination, "manifest.json")
          Project.atomic_write(receipt_path, JSON.pretty_generate(receipt) + "\n")
          begin
            assert_standard_runtime!(name) if standard_local?(discourse_config(customer))
            create = @runtime.run(["docker", "exec", name, "mkdir", "-m", "700", remote_dir], timeout: 30)
            raise UsageError, "Backup staging identity already exists or cannot be created" unless create.success?
            owner = @runtime.run(["docker", "exec", name, "chown", "discourse:discourse", remote_dir], timeout: 30)
            raise UsageError, "Could not prepare backup staging owner" unless owner.success?
            backup_command = discourse_command(name, ["bundle", "exec", "script/discourse", "backup", "#{remote_dir}/#{filename}"])
            log_command_notice("Generating full Discourse backup in #{name}...", backup_command)
            backup = @runtime.run(backup_command, timeout: BACKUP_TIMEOUT)
            raise UsageError, "Discourse backup failed in #{name}" unless backup.success?
            # Upstream appends app/schema versions, even with a filename argument.
            # Inspect ONLY our new exclusive directory, never a shared newest glob.
            listing = @runtime.run(["docker", "exec", name, "find", remote_dir, "-mindepth", "1", "-maxdepth", "1", "-printf", "%f\n"], capture: true, timeout: 30)
            files = listing.stdout.to_s.lines.map(&:strip)
            unless listing.success? && files.length == 1 && files.first.match?(/\A#{Regexp.escape(stem)}-v[0-9A-Za-z.-]+\.tar\.gz\z/)
              raise UsageError, "Missing, unexpected or ambiguous full backup output"
            end
            archive_name = files.first
            remote = "#{remote_dir}/#{archive_name}"
            regular = @runtime.run(["docker", "exec", name, "sh", "-c", "test -f #{Shellwords.escape(remote)} && test ! -L #{Shellwords.escape(remote)} && test -s #{Shellwords.escape(remote)}"], timeout: 30)
            raise UsageError, "Backup output is not a nonempty regular file" unless regular.success?
            archive = File.join(destination, archive_name)
            copy = @runtime.run(["docker", "cp", "#{name}:#{remote}", archive], timeout: BACKUP_TIMEOUT)
            raise UsageError, "Could not copy final backup out of #{name}" unless copy.success?
            ensure_file!(archive, "Runtime did not copy the exact full backup.")
            members = validate_full_archive!(archive, required_uploads)
            receipt.merge!("state" => "archive-validated", "archive" => file_identity(archive), "members" => members, "required_uploads" => required_uploads)
            Project.atomic_write(receipt_path, JSON.pretty_generate(receipt) + "\n")
            @output.puts "[OK] Archive-validated full Discourse backup: #{archive} (not restore-proven)"
            archive
          rescue StandardError => error
            receipt["failure"] = error.class.name
            Project.atomic_write(receipt_path, JSON.pretty_generate(receipt) + "\n")
            raise
          end
        end
      end

      def status_details(customer)
        project_path = Project.project_path(customer, @env)
        {
          intermediate_db: File.exist?(intermediate_db_path(customer)),
          selected_output_db: intermediate_db_path(customer),
          uploads_db: File.exist?(File.join(project_path, "output", "uploads.sqlite3")),
          uploads_container: container_state(customer, "uploads"),
          import_container: container_state(customer, "import"),
          uploads_importer_config: File.exist?(uploads_importer_host_config_path(customer)),
          import_restored: File.exist?(File.join(project_path, "output", "discourse-import-restored.txt")),
          import_complete: File.exist?(File.join(project_path, "output", "discourse-import-complete.txt")),
          final_backups: Dir[File.join(project_path, "output", "discourse-backups", "**", "*.tar.gz")].select { |path| File.file?(path) && !File.symlink?(path) }
        }
      end

      def configured?(customer)
        discourse_configured?(customer)
      end

      private

      def validate_service_ports!(project_config, discourse_config, explicit_keys: Set.new)
        validator = PortValidator.new(env: @env)
        used = {}
        used["initial database"] = project_config["INITIAL_PORT"] if project_config["INITIAL_PORT"]
        used["final database"] = project_config["FINAL_PORT"] if project_config["FINAL_PORT"]
        uploads = resolve_service_port(
          validator, discourse_config, "DISCOURSE_UPLOADS_PORT",
          label: "Discourse uploads", used: used,
          explicit: explicit_keys.include?("DISCOURSE_UPLOADS_PORT"),
          allow_occupied: project_config["DISCOURSE_UPLOADS_PORT"].to_s == discourse_config.fetch("DISCOURSE_UPLOADS_PORT").to_s
        )
        used["Discourse uploads"] = uploads
        import_port = resolve_service_port(
          validator, discourse_config, "DISCOURSE_IMPORT_PORT",
          label: "Discourse import", used: used,
          explicit: explicit_keys.include?("DISCOURSE_IMPORT_PORT"),
          allow_occupied: project_config["DISCOURSE_IMPORT_PORT"].to_s == discourse_config.fetch("DISCOURSE_IMPORT_PORT").to_s
        )
        discourse_config["DISCOURSE_UPLOADS_PORT"] = uploads.to_s
        discourse_config["DISCOURSE_IMPORT_PORT"] = import_port.to_s
      end

      # Explicitly configured ports fail fast when unusable; default ports
      # silently advance to the next free one.
      def resolve_service_port(validator, discourse_config, key, label:, used:, explicit:, allow_occupied:)
        value = discourse_config.fetch(key)
        return validator.validate!(value, label: label, used: used, allow_occupied: allow_occupied) if explicit

        chosen = validator.next_free(value, avoid: used.values)
        @output.puts "[OK] #{label} default port #{value} is in use; selected free port #{chosen}" if chosen.to_s != value.to_s
        chosen
      end

      def default_config(customer)
        {
          "DISCOURSE_DOCKER_PATH" => DEFAULT_DOCKER_PATH,
          "DISCOURSE_UPLOADS_CONTAINER" => "#{customer}-uploads",
          "DISCOURSE_IMPORT_CONTAINER" => "#{customer}-import",
          "DISCOURSE_UPLOADS_PORT" => DEFAULT_UPLOADS_PORT,
          "DISCOURSE_IMPORT_PORT" => DEFAULT_IMPORT_PORT,
          "DISCOURSE_IMPORT_GUEST_ROOT" => "/migrations/#{customer}",
          "DISCOURSE_UPLOADS_HOSTNAME" => "discourse.local",
          "DISCOURSE_IMPORT_HOSTNAME" => "discourse.local",
          "DISCOURSE_DEVELOPER_EMAILS" => DEFAULT_DEVELOPER_EMAILS,
          "DISCOURSE_WORKERS" => DEFAULT_WORKERS,
          "DISCOURSE_DB_POOL" => DEFAULT_DB_POOL,
          "DISCOURSE_DB_SHARED_BUFFERS" => DEFAULT_SHARED_BUFFERS,
          "DISCOURSE_DB_MAX_CONNECTIONS" => DEFAULT_MAX_CONNECTIONS
        }
      end

      def existing_discourse_config(config)
        config.select { |key, _| key.start_with?("DISCOURSE_") }
      end

      def stringify_config(options)
        options.each_with_object({}) do |(key, value), config|
          next if value.nil?

          env_key = key.to_s.upcase
          env_key = "DISCOURSE_#{env_key}" unless env_key.start_with?("DISCOURSE_")
          config[env_key] = value.to_s
        end
      end

      def discourse_config(customer)
        default_config(customer).merge(existing_discourse_config(Project.load_config(customer, @env)))
      end

      def discourse_configured?(customer)
        config = Project.load_config(customer, @env)
        config["DISCOURSE_UPLOADS_CONTAINER"] && config["DISCOURSE_IMPORT_CONTAINER"]
      end

      def ensure_discourse_dirs(customer, config)
        containers_dir = File.join(config.fetch("DISCOURSE_DOCKER_PATH"), "containers")
        FileUtils.mkdir_p(containers_dir)
        FileUtils.mkdir_p(File.join(Project.project_path(customer, @env), "shared", "bulk_import_scripts"))
        FileUtils.mkdir_p(File.join(Project.project_path(customer, @env), "shared", "downloaded_files"))
      end

      def write_container_yml(customer, role, config)
        path = File.join(config.fetch("DISCOURSE_DOCKER_PATH"), "containers", "#{container_name(customer, role, config)}.yml")
        Project.atomic_write(path, YAML.dump(container_definition(customer, role, config)))
        path
      end

      def container_definition(customer, role, config)
        port = config.fetch(role == "uploads" ? "DISCOURSE_UPLOADS_PORT" : "DISCOURSE_IMPORT_PORT")
        hostname = config.fetch(role == "uploads" ? "DISCOURSE_UPLOADS_HOSTNAME" : "DISCOURSE_IMPORT_HOSTNAME")
        project_path = Project.project_path(customer, @env)
        guest_root = config.fetch("DISCOURSE_IMPORT_GUEST_ROOT")

        definition = {
          "templates" => [
            "templates/postgres.template.yml",
            "templates/redis.template.yml",
            "templates/web.template.yml",
            "templates/web.ratelimited.template.yml"
          ],
          "expose" => ["127.0.0.1:#{port}:80"],
          "params" => {
            "db_default_text_search_config" => "pg_catalog.english",
            "db_shared_buffers" => config.fetch("DISCOURSE_DB_SHARED_BUFFERS"),
            "db_max_connections" => config.fetch("DISCOURSE_DB_MAX_CONNECTIONS")
          },
          "env" => {
            "LC_ALL" => "en_US.UTF-8",
            "LANG" => "en_US.UTF-8",
            "LANGUAGE" => "en_US.UTF-8",
            "UNICORN_WORKERS" => config.fetch("DISCOURSE_WORKERS"),
            "UNICORN_SIDEKIQS" => "0",
            "DISCOURSE_HOSTNAME" => hostname,
            "DISCOURSE_DEVELOPER_EMAILS" => config.fetch("DISCOURSE_DEVELOPER_EMAILS"),
            "DISCOURSE_USE_HTTPS" => false,
            "DISCOURSE_DB_POOL" => config.fetch("DISCOURSE_DB_POOL"),
            "DISCOURSE_SMTP_ADDRESS" => "localhost",
            "DISCOURSE_SMTP_PORT" => "25"
          },
          "hooks" => {
            "after_postgres" => [
              {
                "exec" => {
                  "cmd" => "sudo -E -u postgres psql -d template1 -c \"ALTER SYSTEM SET enable_memoize = off;\""
                }
              }
            ],
            "after_code" => [
              {
                "exec" => {
                  "cd" => "$home/plugins",
                  "cmd" => [
                    "git clone https://github.com/discourse/docker_manager.git",
                    "git clone https://github.com/discourse/discourse-signatures.git"
                  ]
                }
              }
            ]
          },
          "run" => [
            { "exec" => "echo \"Beginning of custom commands\"" },
            { "exec" => "echo \"End of custom commands\"" }
          ],
          "volumes" => [
            { "volume" => { "host" => File.join(config.fetch("DISCOURSE_DOCKER_PATH"), "shared", container_name(customer, role, config)), "guest" => "/shared" } },
            { "volume" => { "host" => File.join(config.fetch("DISCOURSE_DOCKER_PATH"), "shared", container_name(customer, role, config), "log", "var-log"), "guest" => "/var/log" } },
            { "volume" => { "host" => File.join(project_path, "uploads"), "guest" => "#{guest_root}/uploads" } },
            { "volume" => { "host" => File.join(project_path, "output"), "guest" => "#{guest_root}/output" } },
            { "volume" => { "host" => File.join(project_path, "shared"), "guest" => "#{guest_root}/shared" } }
          ]
        }
        if standard_local?(config)
          # This opt-in text-fixture profile must not strip plugins/settings
          # from other converter, delta or merge configurations.
          definition.fetch("hooks").delete("after_code")
          definition.fetch("params")["version"] = STANDARD_DISCOURSE_REVISION
          definition.fetch("env").merge!(
            "DISCOURSE_DB_HOST" => "/var/run/postgresql", "DISCOURSE_DB_USERNAME" => "discourse",
            "DISCOURSE_DB_PORT" => "5432", "DISCOURSE_DISABLE_EMAILS" => "yes",
            "DISCOURSE_ENABLE_S3_UPLOADS" => false, "LOAD_PLUGINS" => "0"
          )
        end
        definition
      end

      def write_uploads_importer_config(customer, config)
        guest_root = config.fetch("DISCOURSE_IMPORT_GUEST_ROOT")
        content = {
          "source_db_path" => guest_output_db_path(customer, config: config),
          "output_db_path" => "#{guest_root}/output/uploads.sqlite3",
          "root_paths" => ["#{guest_root}/uploads"],
          "download_cache_path" => "#{guest_root}/shared/downloaded_files",
          "thread_count_factor" => 1.0,
          "path_replacements" => [],
          "fix_missing" => false,
          "delete_missing_uploads" => false,
          "delete_surplus_uploads" => false,
          "create_optimized_images" => false,
          "site_settings" => {
            "download_remote_images_to_local" => true,
            "prevent_anons_from_downloading_files" => false
          }
        }
        if standard_local?(config)
          content["site_settings"] = {
            "authorized_extensions" => "txt", "max_attachment_size_kb" => 1024,
            "max_image_size_kb" => 1024, "max_image_megapixels" => 5,
            "secure_uploads" => false, "s3_enable_access_control_tags" => false,
            "enable_s3_uploads" => false, "multisite" => false
          }
        end
        Project.atomic_write(uploads_importer_host_config_path(customer), YAML.dump(content))
      end

      def standard_local?(config)
        config["DISCOURSE_STANDARD_LOCAL"] == "true"
      end

      def validate_scratch_dirs!(customer)
        root = Project.project_path(customer, @env)
        %w[output uploads shared].each do |name|
          path = File.join(root, name)
          unless Dir.exist?(path) && File.realpath(path) == File.expand_path(path)
            raise UsageError, "Migration #{name} must be a real per-snapshot scratch directory, not a symlink"
          end
        end
      end

      def validate_guest_root!(path)
        unless path.start_with?("/") && path != "/" && path.split("/").none? { |part| %w[. ..].include?(part) } && !path.match?(/[\x00-\x1f]/)
          raise UsageError, "Guest root must be a safe absolute scratch path"
        end
      end

      # Standard import only: presence (even =0) activates upstream delta/merge.
      # Do not delete those settings from project config or other engines.
      def discourse_command(container, args)
        prefix = ["env", "-u", "IMPORT", "-u", "DELTA_IMPORT", "-u", "MERGE_IMPORT",
                  "BUNDLE_WITH=generic_import", "BUNDLE_WITHOUT=development:test:assets:migrations",
                  "BUNDLE_FROZEN=true", "RAILS_ENV=production",
                  "PGHOST=/var/run/postgresql", "PGUSER=discourse", "PGPORT=5432"]
        ["docker", "exec", container, "su", "discourse", "-c",
         "cd /var/www/discourse && exec #{Shellwords.join(prefix + args)}"]
      end

      def file_identity(path)
        ensure_file!(path, "Expected a regular local artifact.")
        { "filename" => File.basename(path), "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path) }
      end

      def validate_backup_filename!(filename, restore: false)
        pattern = restore ? /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,230}\.tar\.gz\z/ : /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}\.tar\.gz\z/
        unless filename.is_a?(String) && filename.match?(pattern)
          raise UsageError, "Supply an explicit safe new backup filename (.tar.gz basename, letters/digits/_/- only)"
        end
        filename
      end

      def bounded_import_command(command)
        command = command.dup
        invocation = command.last.delete_prefix("cd /var/www/discourse && exec ")
        # A single-use destination-side log survives failure. Never emit more
        # than the tiny synthetic profile's fixed capture budget to the client.
        command[-1] = <<~SH
          cd /var/www/discourse || exit 1
          log=/shared/silo-migrate-standard-import.log
          (set -C; : > "$log") || exit 1
          #{invocation} >> "$log" 2>&1
          status=$?
          bytes=$(wc -c < "$log")
          [ "$bytes" -le #{STANDARD_IMPORT_LOG_LIMIT} ] || exit 1
          cat "$log"
          exit "$status"
        SH
        command
      end

      def assert_clean_import_report!(result)
        unless result.stderr.to_s.empty?
          raise UsageError, "Standard import report is incomplete or contains errors/skips; destination remains dirty"
        end
        assert_clean_import_output!(result.stdout)
      end

      def restore_enabled?(container)
        query = 'puts "SILO_ALLOW_RESTORE=#{SiteSetting.allow_restore?}"'
        result = @runtime.run(discourse_command(container, ["bundle", "exec", "rails", "runner", query]), capture: true, timeout: 300)
        # Deliberately require one machine-readable response, not exit0 alone.
        values = result.stdout.to_s.lines.map(&:strip).grep(/\ASILO_ALLOW_RESTORE=(true|false)\z/)
        raise UsageError, "Could not determine restore permission in #{container}" unless result.success? && values.length == 1
        values.first.end_with?("=true")
      end

      def set_restore_enabled!(container, enabled)
        action = enabled ? "enable_restore" : "disable_restore"
        result = @runtime.run(discourse_command(container, ["bundle", "exec", "script/discourse", action]), timeout: 300)
        raise UsageError, "Could not #{action} in #{container}; destination remains dirty" unless result.success?
      end

      def assert_standard_runtime!(container)
        # Prebuilt images carry no .git; upstream records the revision here instead.
        revision = @runtime.run(["docker", "exec", container, "cat", "/var/www/discourse/config/git-utils-overrides.json"], capture: true, timeout: 30)
        recorded = revision.success? ? (JSON.parse(revision.stdout.to_s)["git_version"] rescue nil) : nil
        unless recorded == STANDARD_DISCOURSE_REVISION
          raise UsageError, "Standard local runtime must use the exact approved Discourse app revision"
        end
        code = <<~RUBY
          require "bundler"
          require "digest"
          abort "Ruby/Bundler mismatch" unless RUBY_VERSION == "#{STANDARD_RUBY_VERSION}" && Bundler::VERSION == "#{STANDARD_BUNDLER_VERSION}"
          abort "App lock mismatch" unless Digest::SHA256.file("Gemfile.lock").hexdigest == "#{STANDARD_LOCK_SHA256}"
        RUBY
        versions = @runtime.run(discourse_command(container, ["ruby", "-e", code]), timeout: 30)
        raise UsageError, "Pinned standard local runtime dependencies do not match" unless versions.success?
      end

      def assert_local_runtime!(container)
        assert_standard_runtime!(container)
        code = <<~RUBY
          abort "Expected one actual uploader worker" unless Etc.nprocessors == 1
          abort "Expected LocalStore" unless Discourse.store.is_a?(FileStore::LocalStore) && !SiteSetting.enable_s3_uploads
          abort "Unsafe download policy" if SiteSetting.secure_uploads || SiteSetting.prevent_anons_from_downloading_files || SiteSetting.download_remote_images_to_local
          db = ActiveRecord::Base.connection_db_config.configuration_hash
          abort "Destination/libpq mismatch" unless db[:host] == ENV.fetch("PGHOST") && db[:username] == ENV.fetch("PGUSER") && db.fetch(:port, 5432).to_s == ENV.fetch("PGPORT")
        RUBY
        result = @runtime.run(discourse_command(container, ["bundle", "exec", "rails", "runner", "require 'etc'; #{code}"]), timeout: 300)
        raise UsageError, "Local upload runtime preconditions failed" unless result.success?
      end

      def validate_local_uploads!(customer, source)
        raise UsageError, "SQLite3 is required to validate local upload inputs" unless defined?(SQLite3::Database)
        root = File.join(Project.project_path(customer, @env), "uploads")
        raise UsageError, "Upload root must be a local scratch directory" unless Dir.exist?(root) && !File.symlink?(root)
        real_root = File.realpath(root)
        raise UsageError, "Source database must be closed/checkpointed" if %w[-wal -shm].any? { |suffix| File.exist?("#{source}#{suffix}") }
        db = SQLite3::Database.new(source, readonly: true)
        db.results_as_hash = true
        db.execute("SELECT filename, relative_path, url, data FROM uploads").each do |row|
          if !row["url"].to_s.empty? || (row["data"] && !row["data"].empty?)
            raise UsageError, "Standard local text uploads require local files only; no URL download or embedded data"
          end
          parts = [row["relative_path"].to_s, row["filename"].to_s]
          if parts.any? { |part| part.start_with?("/") || part.split("/").include?("..") || part.include?("\0") } || parts.last.empty?
            raise UsageError, "Unsafe local upload path"
          end
          path = File.join(root, *parts)
          resolved = File.realpath(path)
          unless resolved.start_with?("#{real_root}/") && File.file?(resolved) && File.extname(resolved).downcase == ".txt"
            raise UsageError, "Upload file escapes local text fixture root"
          end
          # Reject links even when they happen to resolve inside the root.
          current = path
          until current == root
            raise UsageError, "Symlinked upload paths are not allowed" if File.symlink?(current)
            current = File.dirname(current)
          end
        end
      rescue StandardError => error
        raise if error.is_a?(UsageError)
        raise UsageError, "Cannot validate local upload inputs: #{error.class}"
      ensure
        db&.close
      end

      def validate_discourse_docker_path!(path)
        expanded = File.expand_path(path)
        raise UsageError, invalid_discourse_path_message(expanded) unless valid_discourse_docker_path?(expanded)

        containers = File.join(expanded, "containers")
        shared = File.join(expanded, "shared")
        ensure_writable_or_creatable!(containers, expanded)
        ensure_writable_or_creatable!(shared, expanded)
      end

      def valid_discourse_docker_path?(path)
        Dir.exist?(path) &&
          File.file?(File.join(path, "launcher")) &&
          File.executable?(File.join(path, "launcher"))
      end

      def ensure_writable_or_creatable!(path, parent)
        return if Dir.exist?(path) && File.writable?(path)
        return if !Dir.exist?(path) && File.writable?(parent)

        raise UsageError, <<~MSG.strip
          Discourse Docker path is not writable: #{path}
          Fix permissions, run with a writable --docker-path, or install the launcher with:
            sudo silo-migrate discourse install-launcher
        MSG
      end

      def invalid_discourse_path_message(path)
        <<~MSG.strip
          Discourse Docker launcher is not installed or invalid at #{path}.
          silo-migrate does not run Discourse's interactive public-site installer; it only needs the discourse_docker launcher checkout.

          On Linux, install the launcher with:
            sudo silo-migrate discourse install-launcher

          Or point at an existing checkout:
            silo-migrate discourse setup CUSTOMER --docker-path /path/to/discourse_docker
        MSG
      end

      def ensure_linux_launcher_install_supported!(docker_path)
        return if linux_host?

        raise UsageError, <<~MSG.strip
          discourse install-launcher is Linux-only.
          On macOS, clone discourse_docker yourself and pass:
            silo-migrate discourse setup CUSTOMER --docker-path /path/to/discourse_docker
        MSG
      end

      def linux_host?
        host_os = @env["SILO_MIGRATE_HOST_OS"] || RbConfig::CONFIG["host_os"]
        host_os.to_s.match?(/linux/i)
      end

      def ensure_program!(name, command, fix)
        result = @runtime.run(command, capture: true, timeout: 30)
        return if result.success?

        raise UsageError, "#{name} is required for Discourse Docker launcher install; #{fix} first."
      end

      def ensure_install_parent!(target)
        parent = File.dirname(target)
        if target == DEFAULT_DOCKER_PATH && Process.uid != 0 && (!Dir.exist?(parent) || !File.writable?(parent))
          raise UsageError, <<~MSG.strip
            Installing to #{DEFAULT_DOCKER_PATH} requires root permissions on Linux.
            Retry with:
              sudo silo-migrate discourse install-launcher
            Or choose a writable path:
              silo-migrate discourse install-launcher --docker-path /path/to/discourse_docker
          MSG
        end

        FileUtils.mkdir_p(parent)
      rescue SystemCallError => e
        raise UsageError, "Could not prepare #{parent}: #{e.message}"
      end

      def each_role(role)
        validate_role!(role)
        roles = role == ROLE_BOTH ? ROLES : [role]
        return roles unless block_given?

        roles.each { |selected_role| yield selected_role }
      end

      def validate_role!(role)
        return if ROLES.include?(role) || role == ROLE_BOTH

        raise UsageError, "Invalid Discourse role: #{role}. Use uploads, import, or both."
      end

      def run_launcher(customer, action, container, role:, timeout: 300)
        config = discourse_config(customer)
        validate_discourse_docker_path!(config.fetch("DISCOURSE_DOCKER_PATH"))
        command = ["./launcher", action, container]
        log_command_notice("#{launcher_action_label(action)} Discourse #{role} container #{container}...", command)
        result = @runtime.run(command, chdir: config.fetch("DISCOURSE_DOCKER_PATH"), timeout: timeout)
        raise UsageError, "Discourse #{action} failed for #{container}" unless result.success?

        result
      end

      def launcher_action_label(action)
        case action
        when "rebuild" then "Rebuilding"
        when "start" then "Starting"
        when "stop" then "Stopping"
        else "Running #{action} for"
        end
      end

      def log_command_notice(message, command)
        @output.puts "[INFO] #{message}"
        @output.puts "[INFO] Running: #{Shellwords.join(command)}"
      end

      def container_name(customer, role, config = nil)
        config ||= discourse_config(customer)
        config.fetch(role == "uploads" ? "DISCOURSE_UPLOADS_CONTAINER" : "DISCOURSE_IMPORT_CONTAINER")
      end

      def guest_root(customer)
        discourse_config(customer).fetch("DISCOURSE_IMPORT_GUEST_ROOT")
      end

      def guest_output_db_path(customer, config: nil)
        config ||= discourse_config(customer)
        host = intermediate_db_path(customer)
        relative = Pathname.new(host).relative_path_from(Pathname.new(Project.project_path(customer, @env))).to_s
        "#{config.fetch('DISCOURSE_IMPORT_GUEST_ROOT')}/#{relative}"
      end

      def intermediate_db_path(customer)
        ConverterOutput.new(customer, env: @env, runtime: @runtime).selected_path
      end

      def uploads_db_path(customer)
        File.join(Project.project_path(customer, @env), "output", "uploads.sqlite3")
      end

      def uploads_importer_host_config_path(customer)
        File.join(Project.project_path(customer, @env), "shared", "bulk_import_scripts", "uploads_importer.yml")
      end

      def uploads_importer_guest_config_path(customer)
        "#{guest_root(customer)}/shared/bulk_import_scripts/uploads_importer.yml"
      end

      def ensure_file!(path, message)
        return if File.file?(path) && !File.symlink?(path)

        raise UsageError, "Missing #{path}. #{message}"
      end

      def container_state(customer, role)
        name = container_name(customer, role)
        running = @runtime.respond_to?(:container_running?) && @runtime.container_running?(name)
        { name: name, running: running }
      end
    end
  end
end
