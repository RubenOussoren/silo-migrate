# frozen_string_literal: true

require "fileutils"
require "set"
require "socket"

module SiloMigrate
  module Services
    class ProjectService
      DEFAULT_CONVERTER_REPO = "git@github.com:discourse-org/discourse-converters.git"
      GIT_CLONE_TIMEOUT = 120
      INTERACTIVE_GIT_CLONE_TIMEOUT = 300
      BUNDLE_INSTALL_TIMEOUT = 600
      SSH_PREFLIGHT_TIMEOUT = 10

      attr_reader :env, :last_converter_result, :last_converter_command

      def initialize(runtime: Runtime::Docker.new, env: ENV, output: $stdout)
        Runtime::Contract.assert_implemented!(runtime)
        @runtime = runtime
        @env = env
        @output = output
        @compose = ComposeGenerator.new(env: env)
      end

      def init(customer, options = {})
        customer = Project.validate_customer_name!(customer)
        Project.ensure_project_dirs(customer, @env)

        db_type = options[:db_type] || "mariadb"
        initial_port = (options[:initial_port] || DATABASE_TYPES.fetch(db_type)[:default_port]).to_i
        db_name = options[:db_name] || "#{customer}_initial_db"
        password = options[:password] || DEFAULT_PASSWORD

        config = {
          "CUSTOMER" => customer,
          "INITIAL_DB_TYPE" => db_type,
          "INITIAL_PORT" => initial_port.to_s,
          "INITIAL_DB_NAME" => db_name,
          "INITIAL_DB_PASSWORD" => password
        }

        if options[:final_db_type]
          final_port = (options[:final_port] || initial_port + 1).to_i
          raise UsageError, "Initial and final database ports cannot be the same (#{initial_port})" if final_port == initial_port

          config["FINAL_DB_TYPE"] = options[:final_db_type]
          config["FINAL_PORT"] = final_port.to_s
          config["FINAL_DB_NAME"] = options[:final_db_name] || "#{customer}_final_db"
          config["FINAL_DB_PASSWORD"] = options[:final_password] || password
        end

        Project.save_config(customer, config, @env)
        @compose.generate(customer, config)
        generate_connection_readme(customer, "initial", db_type, db_name, initial_port, password)
        if config["FINAL_DB_TYPE"]
          generate_connection_readme(customer, "final", config["FINAL_DB_TYPE"], config["FINAL_DB_NAME"], config["FINAL_PORT"], config["FINAL_DB_PASSWORD"])
        end

        project_path = Project.project_path(customer, @env)
        @output.puts "\n[OK] Project initialized: #{project_path}"
        @output.puts "  Initial DB: #{db_type} on port #{initial_port} (database: #{db_name})"
        @output.puts "  Final DB: #{config['FINAL_DB_TYPE']} on port #{config['FINAL_PORT']} (database: #{config['FINAL_DB_NAME']})" if config["FINAL_DB_TYPE"]
        project_path
      end

      def start(customer, profile: "all", build: false, force: false, wait_for_health: false, health_timeout: 60, on_port_conflict: nil)
        config_path = Project.config_path(customer, @env)
        config = File.exist?(config_path) ? Project.load_config(customer, @env) : {}
        conflicts = port_conflicts_for_config(config, profile, customer: customer)
        if conflicts.any? && !force
          if on_port_conflict
            raise UsageError, "Start cancelled because configured port is in use." unless on_port_conflict.call(conflicts)
          else
            raise UsageError, port_conflict_message(customer, conflicts)
          end
        end

        args = ["--profile", profile, "up", "-d"]
        args.insert(-2, "--build") if build
        @output.puts "Starting #{profile} services for #{customer}..."
        result = @runtime.compose(customer, args)
        raise UsageError, "Failed to start services" unless result.success?

        @output.puts "[OK] Services started successfully"
        wait_for_database_health(customer, config, profile, timeout: health_timeout) if wait_for_health
        true
      end

      def stop(customer, profile: "all", remove: false)
        Project.load_config(customer, @env)
        args = remove ? ["--profile", profile, "down"] : ["--profile", profile, "stop"]
        @output.puts "Stopping #{profile} services for #{customer}..."
        result = @runtime.compose(customer, args)
        raise UsageError, "Failed to stop services" unless result.success?

        @output.puts "[OK] Services stopped successfully"
      end

      def status(customer)
        config = Project.load_config(customer, @env)
        project_path = Project.project_path(customer, @env)
        initial_db_name = config["INITIAL_DB_NAME"] || config["DB_NAME"] || "#{customer}_initial_db"
        @output.puts "\n=== Migration Project: #{customer} ===\n"
        @output.puts "Location: #{project_path}"
        @output.puts "Initial DB: #{config['INITIAL_DB_TYPE'] || 'not set'} on port #{config['INITIAL_PORT'] || 'not set'} (database: #{initial_db_name})"
        @output.puts "Final DB: #{config['FINAL_DB_TYPE']} on port #{config['FINAL_PORT']} (database: #{config['FINAL_DB_NAME']})" if config["FINAL_DB_TYPE"]
        @output.puts "\nDump files:"
        %w[initial final].each do |phase|
          files = Dir[File.join(project_path, "dumps", phase, "*")].select { |path| File.file?(path) }
          @output.puts "  #{phase.capitalize}: #{files.length} file(s)"
          files.first(3).each { |path| @output.puts "    - #{File.basename(path)}" }
        end
        @output.puts "\nContainer status:"
        result = @runtime.compose(customer, ["ps", "--format", "table"], capture: true)
        @output.puts(result.stdout.empty? ? "  No containers running" : result.stdout)
      end

      def container_status(customer)
        Project.load_config(customer, @env)
        result = @runtime.compose(customer, ["ps", "--format", "table"], capture: true)
        result.stdout.empty? ? "No containers running" : result.stdout
      end

      def list
        projects = list_projects
        base = Project.base_path(@env)
        if projects.empty?
          @output.puts Dir.exist?(base) ? "No projects found in #{base}" : "No projects found. Base path: #{base}"
        else
          @output.puts "Migration projects in #{base}:\n\n"
          projects.each do |project|
            config = Project.read_env_file(File.join(base, project, "config.env"))
            @output.puts "  #{project} (#{config['INITIAL_DB_TYPE'] || '?'}:#{config['INITIAL_PORT'] || '?'})"
          end
        end
        projects
      end

      def list_projects
        base = Project.base_path(@env)
        return [] unless Dir.exist?(base)

        Dir.children(base).select { |entry| File.exist?(File.join(base, entry, "config.env")) }.sort
      end

      def project_path(customer)
        Project.project_path(customer, @env)
      end

      def regenerate(customer)
        config = Project.load_config(customer, @env)
        @compose.generate(customer, config)
        @output.puts "[OK] Regenerated docker-compose.yml for #{customer}"
      end

      def update_phase_port(customer, phase, port)
        config = Project.load_config(customer, @env)
        port = Integer(port)
        raise UsageError, "Port must be between 1 and 65535" unless port.between?(1, 65_535)

        case phase
        when "initial"
          if config["FINAL_PORT"].to_s == port.to_s
            raise UsageError, "Initial and final database ports cannot be the same (#{port})"
          end
          config["INITIAL_PORT"] = port.to_s
          db_type = config["INITIAL_DB_TYPE"] || "mariadb"
          db_name = config["INITIAL_DB_NAME"] || config["DB_NAME"] || "#{customer}_initial_db"
          password = config["INITIAL_DB_PASSWORD"] || config["DB_PASSWORD"] || DEFAULT_PASSWORD
        when "final"
          raise UsageError, "No final database configured for #{customer}" unless config["FINAL_DB_TYPE"]
          if config["INITIAL_PORT"].to_s == port.to_s
            raise UsageError, "Initial and final database ports cannot be the same (#{port})"
          end
          config["FINAL_PORT"] = port.to_s
          db_type = config["FINAL_DB_TYPE"]
          db_name = config["FINAL_DB_NAME"] || "#{customer}_final_db"
          password = config["FINAL_DB_PASSWORD"] || config["INITIAL_DB_PASSWORD"] || config["DB_PASSWORD"] || DEFAULT_PASSWORD
        else
          raise UsageError, "Unknown phase: #{phase}"
        end

        Project.save_config(customer, config, @env)
        @compose.generate(customer, config)
        generate_connection_readme(customer, phase, db_type, db_name, port, password)
        @output.puts "[OK] Updated #{phase} database port to #{port} and regenerated docker-compose.yml"
        port
      end

      def available_port(preferred, avoid: [])
        port = Integer(preferred)
        avoid = avoid.map(&:to_i).to_set
        while port <= 65_535
          return port if !avoid.include?(port) && port_available?(port)

          port += 1
        end
        raise UsageError, "Could not find an available localhost port starting at #{preferred}"
      end

      def cleanup(customer, yes: false, force: false)
        path = Project.project_path(customer, @env)
        raise UsageError, "Project not found: #{customer}" unless Dir.exist?(path)
        raise UsageError, "Cleanup deletes the project and volumes. Re-run with --yes to confirm." unless yes

        config = Project.load_config(customer, @env)
        if File.exist?(File.join(path, "docker-compose.yml"))
          result = @runtime.compose(customer, ["--profile", "all", "--profile", "initial-db", "--profile", "final-db", "--profile", "converter", "down", "--volumes", "--remove-orphans"], capture: true)
          unless result.success?
            detail = (result.stderr.to_s.empty? ? result.stdout.to_s : result.stderr.to_s).strip
            unless force
              raise UsageError, <<~MSG.chomp
                Could not stop containers/volumes for '#{customer}' (exit #{result.status || 'unknown'}): #{detail}
                Project directory NOT deleted: #{path}
                Fix Docker (or stop the containers manually) and retry, or re-run with --force to delete the directory anyway.
              MSG
            end
            @output.puts "[WARN] Containers/volumes could not be stopped; deleting project directory anyway (--force)."
          end
        end
        cleanup_discourse_handoff(customer, config, path, force: force)
        FileUtils.rm_rf(path)
        @output.puts "[OK] Project '#{customer}' has been deleted"
      end

      def add_final_db(customer, options = {})
        config = Project.load_config(customer, @env)
        raise UsageError, "Final database already configured." if config["FINAL_DB_TYPE"]

        db_type = options[:db_type] || config["INITIAL_DB_TYPE"] || "mariadb"
        initial_port = (config["INITIAL_PORT"] || DATABASE_TYPES.fetch("mariadb")[:default_port]).to_i
        port = (options[:port] || initial_port + 1).to_i
        raise UsageError, "Final database port cannot be the same as initial port (#{initial_port})" if port == initial_port

        db_name = options[:db_name] || "#{customer}_final_db"
        password = options[:password] || config["INITIAL_DB_PASSWORD"] || config["DB_PASSWORD"] || DEFAULT_PASSWORD
        config.merge!(
          "FINAL_DB_TYPE" => db_type,
          "FINAL_PORT" => port.to_s,
          "FINAL_DB_NAME" => db_name,
          "FINAL_DB_PASSWORD" => password
        )
        Project.save_config(customer, config, @env)
        @compose.generate(customer, config)
        generate_connection_readme(customer, "final", db_type, db_name, port, password)
        @output.puts "[OK] Final database added: #{db_type} on port #{port} (database: #{db_name})"
      end

      def setup_converter(customer, repo: DEFAULT_CONVERTER_REPO, branch: "main", start: false, bundle_install: false, hard_fail: true, allow_ssh_prompt: false)
        config = Project.load_config(customer, @env)
        project_path = Project.project_path(customer, @env)
        converter_dir = File.join(project_path, "discourse-converters")
        if Dir.exist?(converter_dir)
          validate_converter_dir!(converter_dir)
        else
          ensure_ssh_repo_access!(repo, allow_ssh_prompt: allow_ssh_prompt)
          result = clone_converter_repo(branch, repo, converter_dir, allow_ssh_prompt: allow_ssh_prompt)
          unless result.success?
            FileUtils.rm_rf(converter_dir)
            raise UsageError, "Git clone failed: #{clone_output(result)}"
          end
          validate_converter_dir!(converter_dir)
        end
        dockerfile = File.join(converter_dir, "Dockerfile")
        unless File.exist?(dockerfile)
          Project.atomic_write(dockerfile, converter_dockerfile)
        end
        @compose.generate(customer, config)
        @output.puts "[OK] Converter setup complete"
        start_converter(customer, bundle_install: bundle_install, hard_fail: hard_fail) if start || bundle_install
      end

      def start_converter(customer, bundle_install: true, hard_fail: true)
        start_failed = false
        begin
          start(customer, profile: "converter", build: true, force: true)
        rescue UsageError => e
          start_failed = true
          @output.puts "[WARN] Failed to start converter: #{e.message}"
          @output.puts "Try manually:"
          @output.puts "  silo-migrate start #{customer} --profile converter --build"
          raise if hard_fail
        end

        return false if start_failed
        return true unless bundle_install

        @output.puts "Running bundle install in #{customer}_converter..."
        result = @runtime.run(["docker", "exec", "#{customer}_converter", "bundle", "install"], timeout: BUNDLE_INSTALL_TIMEOUT)
        if result.success?
          @output.puts "[OK] Dependencies installed"
          true
        else
          @output.puts "[WARN] bundle install failed or timed out. The converter container is still running."
          @output.puts "Try manually:"
          @output.puts "  docker exec -it #{customer}_converter bundle install"
          raise UsageError, "bundle install failed" if hard_fail

          false
        end
      end

      # True when the runtime's backing daemon is reachable (always true for
      # runtimes without an availability probe, e.g. the fake runtime).
      def runtime_available?
        return true unless @runtime.respond_to?(:ensure_available!)

        @runtime.ensure_available!
        true
      rescue UsageError
        false
      end

      def run_converter(customer, command: [], redacted_logs: false)
        Project.load_config(customer, @env)
        command = Array(command).reject(&:empty?)
        command = ["bundle", "exec", "ruby", "converter.rb"] if command.empty?
        @last_converter_command = command
        args = ["--profile", "converter", "exec", "-T", "converter", *command]
        result = execute_converter_command(customer, args)
        @last_converter_result = result
        generate_converter_summary(customer, command: command, result: result) if redacted_logs
        raise UsageError, "Converter command failed with exit code #{result.status}" unless result.success?

        @output.puts "[OK] Converter command completed"
      end

      def run_converter_platform(customer, platform, reset: true, settings: nil, redacted_logs: false)
        validate_converter_platform!(customer, platform)
        settings = generate_default_converter_settings(customer, platform) if settings.to_s.empty?
        command = ["./convert", "--from", platform]
        command << "--reset" if reset
        command.concat(["--settings", settings]) if settings && !settings.empty?
        run_converter(customer, command: command, redacted_logs: redacted_logs)
      end

      def generate_converter_summary(customer, command: [], result: nil)
        command = Array(command).reject(&:empty?)
        command = ["bundle", "exec", "ruby", "converter.rb"] if command.empty?
        artifacts = ConverterSummaryService.new(env: @env, output: @output).generate(customer, command: command, result: result)
        @output.puts "[OK] Redacted converter log: #{artifacts.fetch(:log_path)}"
        @output.puts "[OK] Redacted converter summary: #{artifacts.fetch(:summary_path)}"
        artifacts
      end

      def export_schema(customer, phase: "initial", output_dir: nil)
        config = Project.load_config(customer, @env)
        db_type, db_name, password = database_config(customer, phase, config)
        container_name = "#{customer}_#{phase}_#{db_type}"
        raise UsageError, "Container #{container_name} is not running. Start it first." unless @runtime.container_running?(container_name)

        cmd = @runtime.schema_dump_command(container_name, db_type, db_name, password)
        result = @runtime.run(cmd, capture: true)
        raise UsageError, "Schema export failed: #{result.stderr.empty? ? result.stdout : result.stderr}" unless result.success?

        output_dir ||= File.join(Project.project_path(customer, @env), "schema")
        FileUtils.mkdir_p(output_dir)
        output_path = File.join(output_dir, "#{phase}_schema.sql")
        Project.atomic_write(output_path, result.stdout)
        @output.puts "[OK] Schema exported: #{output_path}"
        output_path
      end

      def stage_dump(customer, phase, source_path, sql_filename: nil)
        Project.load_config(customer, @env)
        raise UsageError, "Invalid phase: #{phase}" unless %w[initial final].include?(phase)
        raise UsageError, "Source path not found: #{source_path}" unless File.exist?(source_path)

        destination_dir = File.join(Project.project_path(customer, @env), "dumps", phase)
        FileUtils.mkdir_p(destination_dir)
        format = DumpTools.detect_file_format(source_path)
        @output.puts "Detected source format: #{format[:format]}"

        destination = if format[:format] == "tar"
                        extracted = DumpTools.extract_sql_from_tar(source_path, destination_dir, sql_filename)
                        raise UsageError, "No SQL dump found in archive: #{source_path}" unless extracted

                        extracted
                      else
                        destination_path = File.join(destination_dir, File.basename(source_path))
                        raise UsageError, "Destination already exists: #{destination_path}" if File.exist?(destination_path) && File.expand_path(destination_path) != File.expand_path(source_path)

                        FileUtils.cp(source_path, destination_path) unless File.expand_path(destination_path) == File.expand_path(source_path)
                        destination_path
                      end

        @output.puts "[OK] Dump staged: #{destination}"
        warn_on_gzip_corruption(destination)
        print_dump_source_type(destination) if %w[sql gzip].include?(DumpTools.detect_file_format(destination)[:format])
        destination
      end

      def generate_connection_readme(customer, phase, db_type, db_name, port, password)
        project_path = Project.project_path(customer, @env)
        path = File.join(project_path, "dumps", phase, "CONNECTION.md")
        username = db_type == "postgres" ? "postgres" : "root"
        internal_port = DATABASE_TYPES.fetch(db_type)[:internal_port]
        container_name = "#{customer}_#{phase}_#{db_type}"
        uri_scheme = db_type == "postgres" ? "postgresql" : "mysql"
        content = <<~TEXT
          # #{phase.capitalize} Database Connection Info

          | Property | Value |
          |----------|-------|
          | **Host (external)** | 127.0.0.1 |
          | **Port (external)** | #{port} |
          | **Database** | #{db_name} |
          | **Username** | #{username} |
          | **Password** | See `config.env` (DB_PASSWORD) |
          | **Container** | #{container_name} |

          ## Connection URI Template

          ```
          #{uri_scheme}://#{username}:${DB_PASSWORD}@127.0.0.1:#{port}/#{db_name}
          ```

          Docker network host: #{container_name}:#{internal_port}

          ## Inside the converter container

          Containers on the shared `migration_network` (including the converter)
          must use the container hostname, not 127.0.0.1:

          | Property | Value |
          |----------|-------|
          | **Host (in-network)** | #{container_name} |
          | **Port (in-network)** | #{internal_port} |

          `silo-migrate run-converter CUSTOMER PLATFORM` generates a settings file
          with these values automatically (mounted at /converter-settings inside
          the converter container); pass `--settings PATH` to override it.
        TEXT
        Project.atomic_write(path, content)
      end

      def service_ports_for_profile(config, profile)
        services = []
        if %w[all initial-db].include?(profile) && config["INITIAL_PORT"]
          services << { service: "initial-db", port: config["INITIAL_PORT"].to_i }
        end
        if %w[all final-db].include?(profile) && config["FINAL_DB_TYPE"] && config["FINAL_PORT"]
          services << { service: "final-db", port: config["FINAL_PORT"].to_i }
        end
        services
      end

      def port_conflicts(customer, profile = "all")
        port_conflicts_for_config(Project.load_config(customer, @env), profile, customer: customer)
      end

      private

      # Streams converter output live and keeps only a bounded tail in memory;
      # falls back to a full capture for runtimes without streaming support.
      def execute_converter_command(customer, args)
        unless @runtime.respond_to?(:compose_exec_stream)
          result = @runtime.compose(customer, args, capture: true, timeout: nil)
          @output.puts result.stdout unless result.stdout.empty?
          @output.puts result.stderr unless result.stderr.empty?
          return result
        end

        stdout_tail = BoundedBuffer.new
        stderr_tail = BoundedBuffer.new
        stream_result = @runtime.compose_exec_stream(customer, args, timeout: nil) do |stream, chunk|
          @output.print(chunk)
          (stream == :stderr ? stderr_tail : stdout_tail).write(chunk)
        end
        Runtime::CommandResult.new(
          success?: stream_result.success?,
          stdout: tail_with_truncation_marker(stdout_tail),
          stderr: tail_with_truncation_marker(stderr_tail),
          status: stream_result.status
        )
      end

      def tail_with_truncation_marker(buffer)
        text = buffer.tail_string
        buffer.truncated? ? "[earlier output truncated]\n#{text}" : text
      end

      def cleanup_discourse_handoff(customer, config, project_path, force:)
        return unless discourse_handoff_configured?(config)

        docker_path = config["DISCOURSE_DOCKER_PATH"].to_s
        unless valid_discourse_launcher?(docker_path)
          handle_discourse_cleanup_failure(customer, project_path, "Discourse Docker launcher is not installed or invalid at #{docker_path.empty? ? '(not set)' : docker_path}.", force: force)
          return
        end

        containers = [
          config["DISCOURSE_UPLOADS_CONTAINER"] || "#{customer}-uploads",
          config["DISCOURSE_IMPORT_CONTAINER"] || "#{customer}-import"
        ].uniq
        failures = []
        containers.each do |container|
          result = @runtime.run(["./launcher", "destroy", container], chdir: docker_path, capture: true)
          failures << "#{container}: #{command_failure_detail(result)}" unless result.success?
        end

        if failures.empty?
          @output.puts "[OK] Discourse handoff containers destroyed"
        else
          handle_discourse_cleanup_failure(customer, project_path, failures.join("; "), force: force)
        end
      end

      def discourse_handoff_configured?(config)
        config.any? { |key, value| key.start_with?("DISCOURSE_") && !value.to_s.empty? }
      end

      def valid_discourse_launcher?(path)
        return false if path.to_s.empty?

        expanded = File.expand_path(path)
        Dir.exist?(expanded) &&
          File.file?(File.join(expanded, "launcher")) &&
          File.executable?(File.join(expanded, "launcher"))
      end

      def handle_discourse_cleanup_failure(customer, project_path, detail, force:)
        if force
          @output.puts "[WARN] Discourse handoff containers could not be destroyed; deleting project directory anyway (--force)."
          @output.puts "[WARN] #{detail}" unless detail.to_s.empty?
          return
        end

        raise UsageError, <<~MSG.chomp
          Could not destroy Discourse handoff containers for '#{customer}': #{detail}
          Project directory NOT deleted: #{project_path}
          Fix discourse_docker (or destroy the containers manually) and retry, or re-run with --force to delete the directory anyway.
        MSG
      end

      def command_failure_detail(result)
        detail = (result.stderr.to_s.empty? ? result.stdout.to_s : result.stderr.to_s).strip
        detail.empty? ? "exit #{result.status || 'unknown'}" : detail
      end

      # Generates in-network connection settings for the platform shortcut.
      # Failures fall back to the platform defaults (matching old behavior)
      # rather than blocking the run.
      def generate_default_converter_settings(customer, platform)
        result = ConverterSettingsService.new(env: @env, output: @output).generate(customer, platform)
        ensure_converter_settings_mount(customer)
        @output.puts "[OK] Generated converter settings: #{result.fetch(:host_path)}"
        result.fetch(:container_path)
      rescue UsageError => e
        @output.puts "[WARN] Could not generate converter settings: #{e.message.lines.first.strip}"
        @output.puts "       Running with the platform's default settings (likely localhost; pass --settings to override)."
        nil
      end

      def ensure_converter_settings_mount(customer)
        compose_path = File.join(Project.project_path(customer, @env), "docker-compose.yml")
        return unless File.exist?(compose_path)
        return if File.read(compose_path).include?("/converter-settings")

        @compose.generate(customer, Project.load_config(customer, @env))
        @output.puts "[WARN] docker-compose.yml was regenerated to mount converter-settings/."
        @output.puts "       Recreate the converter container so the generated settings are visible:"
        @output.puts "         silo-migrate start #{customer} --profile converter"
      end

      def warn_on_gzip_corruption(path)
        return unless DumpTools.gzip_file?(path)

        verification = DumpTools.verify_gzip(path)
        return if verification[:valid]

        @output.puts "[WARN] gzip quick check failed: #{verification[:message]}"
        @output.puts "[WARN] The dump may be truncated or corrupt; the import preflight will verify it fully."
      end

      def port_conflicts_for_config(config, profile, customer: nil)
        service_ports_for_profile(config, profile).select do |entry|
          next false unless port_listening?(entry[:port])
          next true unless customer

          !expected_service_container_running?(customer, config, entry[:service])
        end
      end

      def port_listening?(port)
        socket = Socket.tcp("127.0.0.1", port, connect_timeout: 1)
        socket.close
        true
      rescue SystemCallError, IOError
        false
      end

      def port_available?(port)
        server = TCPServer.new("127.0.0.1", port)
        server.close
        true
      rescue SystemCallError, IOError
        false
      end

      def port_conflict_message(customer, conflicts)
        lines = conflicts.map { |entry| "  - Port #{entry[:port]} (#{entry[:service]})" }
        <<~MESSAGE
          The following configured ports appear to be in use:
          #{lines.join("\n")}
          Another migration project or local service may already be bound to the port.
          To change ports: edit config.env, then run 'silo-migrate regenerate #{customer}'.
          Use --force to start anyway.
        MESSAGE
      end

      def wait_for_database_health(customer, config, profile, timeout:)
        service_ports_for_profile(config, profile).each do |entry|
          phase = entry[:service].sub("-db", "")
          db_type = phase == "final" ? config["FINAL_DB_TYPE"] : config["INITIAL_DB_TYPE"]
          container_name = "#{customer}_#{phase}_#{db_type}"
          @output.puts "Waiting for #{container_name} to become healthy..."
          healthy = @runtime.respond_to?(:wait_for_container_healthy) && @runtime.wait_for_container_healthy(container_name, timeout: timeout)
          next @output.puts("[OK] #{container_name} is healthy") if healthy

          if @runtime.container_running?(container_name)
            @output.puts "[WARN] #{container_name} did not become healthy within #{timeout}s; continuing because it is running."
          else
            raise UsageError, "#{container_name} is not running after startup."
          end
        end
      end

      def expected_service_container_running?(customer, config, service)
        container_name = container_name_for_service(customer, config, service)
        return false unless container_name && @runtime.respond_to?(:container_running?)

        @runtime.container_running?(container_name)
      rescue StandardError
        false
      end

      def container_name_for_service(customer, config, service)
        case service
        when "initial-db"
          db_type = config["INITIAL_DB_TYPE"]
          "#{customer}_initial_#{db_type}" if db_type
        when "final-db"
          db_type = config["FINAL_DB_TYPE"]
          "#{customer}_final_#{db_type}" if db_type
        end
      end

      def validate_converter_dir!(converter_dir)
        missing = %w[Gemfile convert].reject { |name| File.exist?(File.join(converter_dir, name)) }
        return if missing.empty?

        raise UsageError, <<~MESSAGE.chomp
          Existing discourse-converters directory is incomplete: #{converter_dir}
          Missing required file(s): #{missing.join(", ")}
          Repair it by deleting or replacing the directory, then rerun setup-converter.
        MESSAGE
      end

      def validate_converter_platform!(customer, platform)
        unless platform.match?(/\A[a-zA-Z0-9_.-]+\z/) && platform != "." && platform != ".."
          raise UsageError, "Invalid converter platform: #{platform}"
        end

        converter_dir = File.join(Project.project_path(customer, @env), "discourse-converters")
        raise UsageError, "Converter is not set up for #{customer}.\nRun 'silo-migrate setup-converter #{customer}' first." unless Dir.exist?(converter_dir)

        validate_converter_dir!(converter_dir)
        platform_dir = File.join(converter_dir, "converters", platform)
        return if Dir.exist?(platform_dir)

        available = Dir[File.join(converter_dir, "converters", "*")].select { |path| File.directory?(path) }.map { |path| File.basename(path) }.sort
        message = +"Converter platform not found: #{platform}\nExpected directory: #{platform_dir}"
        message << "\nAvailable converters: #{available.join(', ')}" unless available.empty?
        raise UsageError, message
      end

      def ensure_ssh_repo_access!(repo, allow_ssh_prompt:)
        host = ssh_repo_host(repo)
        return unless host == "github.com"
        return if allow_ssh_prompt

        result = @runtime.run(
          ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=#{SSH_PREFLIGHT_TIMEOUT}", "git@#{host}"],
          capture: true,
          timeout: SSH_PREFLIGHT_TIMEOUT + 2
        )
        return if ssh_preflight_success?(host, result)

        raise UsageError, ssh_access_error(repo, host, result)
      end

      def clone_converter_repo(branch, repo, converter_dir, allow_ssh_prompt:)
        if allow_ssh_prompt && ssh_repo_host(repo)
          @output.puts "Cloning converter repository. SSH may prompt for a key passphrase..."
          @runtime.run(
            ["git", "clone", "-b", branch, repo, converter_dir],
            timeout: INTERACTIVE_GIT_CLONE_TIMEOUT,
            separate_process_group: false
          )
        else
          @runtime.run(["git", "clone", "-b", branch, repo, converter_dir], capture: true, timeout: GIT_CLONE_TIMEOUT)
        end
      end

      def ssh_repo_host(repo)
        case repo
        when /\Agit@([^:]+):/
          Regexp.last_match(1)
        when %r{\Assh://git@([^/]+)/}
          Regexp.last_match(1)
        end
      end

      def ssh_preflight_success?(host, result)
        return true if result.success?

        host == "github.com" && clone_output(result).include?("successfully authenticated")
      end

      def ssh_access_error(repo, host, result)
        output = clone_output(result)
        <<~MESSAGE.chomp
          Git SSH access is not available for #{host}.

          The converter repository uses SSH and may be private:
            #{repo}

          Silo Migrate checks SSH before cloning so setup does not hang on authentication.
          Configure SSH access, then retry setup-converter.

          Recommended checks:
            ssh -T git@#{host}
            ssh-add -l

          If your key has a passphrase and is not loaded into an agent, 'ssh -T git@#{host}'
          may work because it can ask for the passphrase. Interactive mode can retry setup using
          that same terminal SSH prompt, or command mode can use:
            silo-migrate setup-converter CUSTOMER --allow-ssh-prompt

          Common SSH agent setups:
            - macOS ssh-agent / keychain: add the key with ssh-add, then retry.
            - 1Password SSH agent: enable the agent and make sure ~/.ssh/config uses its IdentityAgent.
            - Other agents: make sure SSH_AUTH_SOCK points at the agent and 'ssh-add -l' lists the key.

          If you use 1Password for SSH keys:
            1. Enable the 1Password SSH agent.
            2. Add your GitHub key to 1Password.
            3. Ensure your ~/.ssh/config uses IdentityAgent for the 1Password agent socket.
            4. Run 'ssh -T git@#{host}' until GitHub confirms authentication.

          You can also pass an alternate repository URL:
            silo-migrate setup-converter CUSTOMER --repo <alternate-url>

          SSH check output:
          #{output.empty? ? "(no output)" : output}
        MESSAGE
      end

      def clone_output(result)
        [result.stderr, result.stdout].compact.reject(&:empty?).join("\n")
      end

      def database_config(customer, phase, config)
        Project.database_config(customer, phase, config)
      end

      def converter_dockerfile
        <<~DOCKERFILE
          FROM ruby:3.3

          WORKDIR /converters

          RUN apt-get update && apt-get install -y \\
              git nano vim freetds-dev \\
              && apt-get clean && rm -rf /var/lib/apt/lists/*

          RUN bundle config --global jobs 7

          COPY Gemfile ./
          RUN bundle install

          CMD ["sleep", "infinity"]
        DOCKERFILE
      end

      def print_dump_source_type(path)
        detection = SQLTools.detect_dump_type(path)
        SQLTools.dump_type_summary(detection).each { |line| @output.puts line }
      rescue StandardError => e
        @output.puts "[WARN] Could not detect source type: #{e.message}"
      end
    end
  end
end
