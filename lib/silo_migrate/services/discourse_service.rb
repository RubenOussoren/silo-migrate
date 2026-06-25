# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "shellwords"
require "time"
require "yaml"

module SiloMigrate
  module Services
    class DiscourseService
      ROLES = %w[uploads import].freeze
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

        discourse_config = default_config(customer).merge(existing_discourse_config(config)).merge(stringify_config(options))
        validate_discourse_docker_path!(discourse_config.fetch("DISCOURSE_DOCKER_PATH"))
        Project.save_config(customer, config.merge(discourse_config), @env)
        ensure_discourse_dirs(customer, discourse_config)
        write_container_yml(customer, "uploads", discourse_config)
        write_container_yml(customer, "import", discourse_config)
        write_uploads_importer_config(customer, discourse_config)

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

      def prepare_deps(customer, role: ROLE_BOTH)
        each_role(role) do |selected_role|
          container = container_name(customer, selected_role)
          command = ["docker", "exec", container, "su", "discourse", "-c", "bundle config set --local with generic_import && bundle install"]
          log_command_notice("Preparing Discourse #{selected_role} dependencies in #{container}...", command)
          result = @runtime.run(command, timeout: DEPENDENCY_TIMEOUT)
          raise UsageError, "Dependency preparation failed for #{selected_role}" unless result.success?
        end
        @output.puts "[OK] Discourse import dependencies prepared for #{role}"
      end

      def run_uploads(customer)
        ensure_file!(intermediate_db_path(customer), "Run the converter first to create output/intermediate.db.")
        setup(customer) unless discourse_configured?(customer)

        container = container_name(customer, "uploads")
        command = [
          "docker", "exec", container, "su", "discourse", "-c",
          "bundle exec ruby /var/www/discourse/script/bulk_import/uploads_importer.rb #{uploads_importer_guest_config_path(customer)}"
        ]
        log_command_notice("Running Discourse uploads importer in #{container}...", command)
        result = @runtime.run(command, timeout: IMPORT_TIMEOUT)
        raise UsageError, "Upload import failed" unless result.success?

        @output.puts "[OK] Upload import completed: #{uploads_db_path(customer)}"
      end

      def restore_import(customer, backup:)
        setup(customer) unless discourse_configured?(customer)
        raise UsageError, "Backup not found: #{backup}" unless File.exist?(backup)

        name = container_name(customer, "import")
        backup_basename = File.basename(backup)
        backup_dir = "/var/www/discourse/public/backups/default"
        copy_command = ["docker", "cp", backup, "#{name}:#{backup_dir}/#{backup_basename}"]
        log_command_notice("Copying Discourse backup into #{name}...", copy_command)
        copy = @runtime.run(copy_command, timeout: BACKUP_TIMEOUT)
        raise UsageError, "Could not copy backup into #{name}" unless copy.success?

        restore_command = ["docker", "exec", name, "su", "discourse", "-c", "DISCOURSE_ENABLE_RESTORE=true bundle exec script/discourse restore #{backup_basename}"]
        log_command_notice("Restoring Discourse backup in #{name}...", restore_command)
        restore = @runtime.run(restore_command, timeout: BACKUP_TIMEOUT)
        raise UsageError, "Backup restore failed in #{name}" unless restore.success?

        marker = File.join(Project.project_path(customer, @env), "output", "discourse-import-restored.txt")
        Project.atomic_write(marker, "#{Time.now.utc.iso8601} #{backup_basename}\n")
        @output.puts "[OK] Backup restored into #{name}"
      end

      def import(customer, no_uploads_db: false)
        setup(customer) unless discourse_configured?(customer)
        ensure_file!(intermediate_db_path(customer), "Run the converter first to create output/intermediate.db.")
        use_uploads_db = !no_uploads_db && File.exist?(uploads_db_path(customer))

        guest_root = guest_root(customer)
        command = "IMPORT=1 bundle exec ruby script/bulk_import/generic_bulk.rb #{guest_root}/output/intermediate.db"
        command << " #{guest_root}/output/uploads.sqlite3" if use_uploads_db
        if !use_uploads_db && no_uploads_db
          @output.puts "[WARN] Skipping uploads.sqlite3; importing with intermediate.db only."
        elsif !use_uploads_db
          @output.puts "[WARN] uploads.sqlite3 not found; importing with intermediate.db only."
        end
        container = container_name(customer, "import")
        docker_command = ["docker", "exec", container, "su", "discourse", "-c", command]
        log_command_notice("Running Discourse generic import in #{container}...", docker_command)
        result = @runtime.run(docker_command, timeout: IMPORT_TIMEOUT)
        raise UsageError, "Generic bulk import failed" unless result.success?

        marker = File.join(Project.project_path(customer, @env), "output", "discourse-import-complete.txt")
        Project.atomic_write(marker, "#{Time.now.utc.iso8601}\n")
        @output.puts "[OK] Generic bulk import completed"
      end

      def backup_import(customer)
        setup(customer) unless discourse_configured?(customer)
        name = container_name(customer, "import")
        backup_command = ["docker", "exec", name, "su", "discourse", "-c", "bundle exec script/discourse backup"]
        log_command_notice("Generating final Discourse backup in #{name}...", backup_command)
        backup = @runtime.run(backup_command, timeout: BACKUP_TIMEOUT)
        raise UsageError, "Discourse backup failed in #{name}" unless backup.success?

        destination = File.join(Project.project_path(customer, @env), "output", "discourse-backups")
        FileUtils.mkdir_p(destination)
        latest_command = ["docker", "exec", name, "bash", "-lc", "ls -1t /var/www/discourse/public/backups/default/*.tar.gz 2>/dev/null | head -1"]
        log_command_notice("Finding latest Discourse backup in #{name}...", latest_command)
        latest = @runtime.run(latest_command, capture: true, timeout: 30)
        if latest.success? && !latest.stdout.to_s.strip.empty?
          remote_path = latest.stdout.strip.lines.first.strip
          copy_command = ["docker", "cp", "#{name}:#{remote_path}", destination]
          log_command_notice("Copying final Discourse backup to #{destination}...", copy_command)
          copy = @runtime.run(copy_command, timeout: BACKUP_TIMEOUT)
          raise UsageError, "Could not copy final backup out of #{name}" unless copy.success?
        else
          @output.puts "[WARN] Backup completed, but the latest backup path could not be detected automatically."
        end
        @output.puts "[OK] Final Discourse backup output: #{destination}"
        destination
      end

      def status_details(customer)
        project_path = Project.project_path(customer, @env)
        {
          intermediate_db: File.exist?(File.join(project_path, "output", "intermediate.db")),
          uploads_db: File.exist?(File.join(project_path, "output", "uploads.sqlite3")),
          uploads_container: container_state(customer, "uploads"),
          import_container: container_state(customer, "import"),
          uploads_importer_config: File.exist?(uploads_importer_host_config_path(customer)),
          import_restored: File.exist?(File.join(project_path, "output", "discourse-import-restored.txt")),
          import_complete: File.exist?(File.join(project_path, "output", "discourse-import-complete.txt")),
          final_backups: Dir[File.join(project_path, "output", "discourse-backups", "*")].select { |path| File.file?(path) }
        }
      end

      def configured?(customer)
        discourse_configured?(customer)
      end

      private

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

        {
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
      end

      def write_uploads_importer_config(customer, config)
        guest_root = config.fetch("DISCOURSE_IMPORT_GUEST_ROOT")
        content = {
          "source_db_path" => "#{guest_root}/output/intermediate.db",
          "output_db_path" => "#{guest_root}/output/uploads.sqlite3",
          "root_paths" => ["#{guest_root}/uploads"],
          "download_cache_path" => "#{guest_root}/shared/downloaded_files",
          "thread_factor" => 1,
          "delete_missing_uploads" => false,
          "delete_surplus_uploads" => false,
          "optimized_images" => false,
          "site_settings" => {
            "download_remote_images_to_local" => true,
            "prevent_anons_from_downloading_files" => false
          }
        }
        Project.atomic_write(uploads_importer_host_config_path(customer), YAML.dump(content))
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

      def intermediate_db_path(customer)
        File.join(Project.project_path(customer, @env), "output", "intermediate.db")
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
        return if File.exist?(path)

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
