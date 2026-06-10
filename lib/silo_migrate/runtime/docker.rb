# frozen_string_literal: true

require "open3"
require "rbconfig"
require "timeout"

module SiloMigrate
  module Runtime
    CommandResult = Struct.new(:success?, :stdout, :stderr, :status, keyword_init: true)

    class Docker
      DOCKER_NOT_FOUND_ERROR = "Docker is not installed or not in PATH.\nInstall Docker: https://docs.docker.com/get-docker/"

      def initialize(env: ENV)
        @env = env
      end

      def compose(customer, args, capture: false, timeout: 300)
        ensure_available!
        project_path = Project.project_path(customer, @env)
        cmd = ["docker", "compose", "-f", File.join(project_path, "docker-compose.yml"), *args]
        run(cmd, chdir: project_path, capture: capture, timeout: timeout)
      end

      def container_running?(name)
        result = run(["docker", "inspect", "-f", "{{.State.Running}}", name], capture: true, timeout: 10)
        result.success? && result.stdout.strip == "true"
      end

      def wait_for_container_healthy(container_name, timeout:)
        deadline = Time.now + timeout
        while Time.now < deadline
          health = run(["docker", "inspect", "-f", "{{if .State.Health}}{{.State.Health.Status}}{{end}}", container_name], capture: true, timeout: 10)
          return true if health.success? && health.stdout.strip == "healthy"
          return false unless container_running?(container_name)

          sleep 2
        end
        false
      end

      def exec_import_command(container_name, db_type, db_name, password, max_packet: nil, disable_keys: false)
        db_config = DATABASE_TYPES.fetch(db_type)
        docker_cmd = ["docker", "exec", "-i", "-e", "#{db_config[:password_env]}=#{password}", container_name]
        import_cmd = db_config[:import_cmd].dup
        if %w[mysql mariadb].include?(db_type)
          import_cmd << "--max-allowed-packet=#{max_packet}" if max_packet
          if disable_keys
            import_cmd << '--init-command=SET GLOBAL net_buffer_length=1000000; SET GLOBAL max_allowed_packet=1000000000; SET SESSION sql_mode="", FOREIGN_KEY_CHECKS=0, UNIQUE_CHECKS=0;'
          end
          import_cmd << db_name
        else
          import_cmd.concat(["-d", db_name])
        end
        docker_cmd + import_cmd
      end

      def schema_dump_command(container_name, db_type, db_name, password)
        db_config = DATABASE_TYPES.fetch(db_type)
        docker_cmd = ["docker", "exec", "-e", "#{db_config[:password_env]}=#{password}", container_name]
        if %w[mysql mariadb].include?(db_type)
          docker_cmd + ["mysqldump", "-u", "root", "--default-character-set=utf8mb4", "--no-data", "--skip-comments", db_name]
        else
          docker_cmd + ["pg_dump", "-U", "postgres", "--schema-only", db_name]
        end
      end

      def schema_metadata_commands(container_name, db_type, db_name, password)
        db_config = DATABASE_TYPES.fetch(db_type)
        docker_cmd = ["docker", "exec", "-e", "#{db_config[:password_env]}=#{password}", container_name]
        if %w[mysql mariadb].include?(db_type)
          mysql_metadata_commands(docker_cmd, db_name)
        else
          postgres_metadata_commands(docker_cmd, db_name)
        end
      end

      def mysql_variables(container_name, db_type, db_name, password, names)
        db_config = DATABASE_TYPES.fetch(db_type)
        docker_cmd = ["docker", "exec", "-e", "#{db_config[:password_env]}=#{password}", container_name]
        sql = "SHOW VARIABLES WHERE Variable_name IN (#{names.map { |name| "'#{name}'" }.join(', ')})"
        result = run(mysql_query_command(docker_cmd, db_name, sql), capture: true, timeout: 20)
        raise UsageError, "Could not query MySQL variables: #{result.stderr}" unless result.success?

        result.stdout.lines.each_with_object({}) do |line, variables|
          name, value = line.chomp.split("\t", 2)
          variables[name] = value if name && value
        end
      end

      def container_disk_free(container_name, paths)
        result = run(["docker", "exec", container_name, "df", "-Pk", *paths], capture: true, timeout: 20)
        raise UsageError, "Could not query container disk free space: #{result.stderr}" unless result.success?

        parse_df_free_bytes(result.stdout)
      end

      def docker_desktop?
        return false unless RbConfig::CONFIG["host_os"].to_s.match?(/darwin/i)

        true
      end

      def run(cmd, chdir: nil, capture: false, timeout: nil, stdin_data: nil, separate_process_group: true)
        cmd = normalize_command(cmd)
        process_options = {}
        process_options[:chdir] = chdir if chdir
        process_options[:pgroup] = true if separate_process_group

        if capture || stdin_data
          run_captured(cmd, process_options, timeout, stdin_data, separate_process_group)
        else
          run_attached(cmd, process_options, timeout, separate_process_group)
        end
      rescue Errno::ENOENT => e
        raise UsageError, "#{DOCKER_NOT_FOUND_ERROR}\nOriginal error: #{e.message}"
      end

      def run_with_stdin(cmd, chdir: nil)
        cmd = normalize_command(cmd)
        stdout = +""
        stderr = +""
        status = nil
        stdin_error = nil
        process_options = {}
        process_options[:chdir] = chdir if chdir

        Open3.popen3(*cmd, **process_options) do |stdin, out, err, wait_thr|
          stdout_thread = Thread.new { out.read.to_s }
          stderr_thread = Thread.new { err.read.to_s }
          begin
            yield stdin
          rescue Errno::EPIPE => e
            stdin_error = e
          ensure
            stdin.close unless stdin.closed?
          end
          stdout = stdout_thread.value
          stderr = stderr_thread.value
          status = wait_thr.value
        end

        stderr = [stderr, stdin_error&.message].compact.reject(&:empty?).join("\n") if stdin_error
        CommandResult.new(success?: status.success?, stdout: stdout, stderr: stderr, status: status.exitstatus)
      rescue Errno::ENOENT => e
        raise UsageError, "#{DOCKER_NOT_FOUND_ERROR}\nOriginal error: #{e.message}"
      end

      def ensure_available!
        result = run(["docker", "version", "--format", "{{.Server.Version}}"], capture: true, timeout: 10)
        raise UsageError, "Docker is not running. Start Docker daemon first." unless result.success?
      end

      private

      def normalize_command(cmd)
        return cmd unless cmd.first == "docker"

        [docker_executable, *cmd.drop(1)]
      end

      def docker_executable
        @docker_executable ||= find_executable("docker") || "docker"
      end

      def find_executable(name)
        paths = (@env["PATH"] || ENV["PATH"]).to_s.split(File::PATH_SEPARATOR)
        paths.each do |dir|
          path = File.join(dir, name)
          return path if File.file?(path) && File.executable?(path)
        end
        nil
      end

      def mysql_metadata_commands(docker_cmd, db_name)
        {
          tables: mysql_query_command(docker_cmd, db_name, <<~SQL),
            SELECT TABLE_SCHEMA, TABLE_NAME, COALESCE(TABLE_ROWS, 0), COALESCE(DATA_LENGTH, 0), COALESCE(INDEX_LENGTH, 0), COALESCE(ENGINE, ''), COALESCE(TABLE_COLLATION, '')
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
            ORDER BY TABLE_NAME
          SQL
          columns: mysql_query_command(docker_cmd, db_name, <<~SQL),
            SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, COLUMN_TYPE, DATA_TYPE, IS_NULLABLE, COALESCE(COLUMN_DEFAULT, ''), COLUMN_KEY, EXTRA, COALESCE(CHARACTER_SET_NAME, ''), COALESCE(COLLATION_NAME, '')
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE()
            ORDER BY TABLE_NAME, ORDINAL_POSITION
          SQL
          indexes: mysql_query_command(docker_cmd, db_name, <<~SQL)
            SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX, COLUMN_NAME, NON_UNIQUE, COALESCE(INDEX_TYPE, '')
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE()
            ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
          SQL
        }
      end

      def mysql_query_command(docker_cmd, db_name, sql)
        docker_cmd + ["mysql", "-u", "root", "--batch", "--raw", "--skip-column-names", db_name, "-e", compact_sql(sql)]
      end

      def postgres_metadata_commands(docker_cmd, db_name)
        {
          tables: postgres_query_command(docker_cmd, db_name, <<~SQL),
            SELECT t.table_schema, t.table_name, COALESCE(c.reltuples, 0)::bigint, pg_total_relation_size(c.oid), pg_indexes_size(c.oid), '', ''
            FROM information_schema.tables t
            JOIN pg_namespace n ON n.nspname = t.table_schema
            JOIN pg_class c ON c.relname = t.table_name AND c.relnamespace = n.oid
            WHERE t.table_schema NOT IN ('pg_catalog', 'information_schema') AND t.table_type = 'BASE TABLE'
            ORDER BY t.table_schema, t.table_name
          SQL
          columns: postgres_query_command(docker_cmd, db_name, <<~SQL),
            SELECT table_schema, table_name, column_name, ordinal_position, data_type, data_type, is_nullable, COALESCE(column_default, ''), '', '', COALESCE(character_set_name, ''), COALESCE(collation_name, '')
            FROM information_schema.columns
            WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
            ORDER BY table_schema, table_name, ordinal_position
          SQL
          indexes: postgres_query_command(docker_cmd, db_name, <<~SQL)
            SELECT schemaname, tablename, indexname, 0, COALESCE(indexdef, ''), 0, ''
            FROM pg_indexes
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY schemaname, tablename, indexname
          SQL
        }
      end

      def postgres_query_command(docker_cmd, db_name, sql)
        docker_cmd + ["psql", "-U", "postgres", "-d", db_name, "-At", "-F", "\t", "-c", compact_sql(sql)]
      end

      def compact_sql(sql)
        sql.lines.map(&:strip).reject(&:empty?).join(" ")
      end

      def parse_df_free_bytes(output)
        output.lines.drop(1).each_with_object({}) do |line, free|
          parts = line.split
          next if parts.length < 6

          available_kb = parts[3].to_i
          path = parts[5]
          free[path] = available_kb * 1024
        end
      end

      def run_attached(cmd, process_options, timeout, separate_process_group)
        pid = spawn(*cmd, **process_options)
        status = wait_for_pid(pid, timeout)
        CommandResult.new(success?: status.success?, stdout: "", stderr: "", status: status.exitstatus)
      rescue Timeout::Error
        terminate_process(pid, separate_process_group: separate_process_group) if pid
        CommandResult.new(success?: false, stdout: "", stderr: timeout_message(cmd, timeout), status: nil)
      end

      def run_captured(cmd, process_options, timeout, stdin_data, separate_process_group)
        stdout = +""
        stderr = +""
        status = nil
        pid = nil

        Open3.popen3(*cmd, **process_options) do |stdin, out, err, wait_thr|
          pid = wait_thr.pid
          stdout_thread = Thread.new { out.read.to_s }
          stderr_thread = Thread.new { err.read.to_s }
          captured_exchange(stdin, wait_thr, stdout_thread, stderr_thread, stdin_data, timeout) do |captured_stdout, captured_stderr, captured_status|
            stdout = captured_stdout
            stderr = captured_stderr
            status = captured_status
          end
        rescue Timeout::Error
          terminate_process(pid, separate_process_group: separate_process_group) if pid
          [stdout_thread, stderr_thread].compact.each(&:kill)
          stdout = safe_thread_value(stdout_thread)
          stderr = safe_thread_value(stderr_thread)
          status = nil
          raise
        end

        CommandResult.new(success?: status.success?, stdout: stdout, stderr: stderr, status: status.exitstatus)
      rescue Timeout::Error
        stderr = [stderr, timeout_message(cmd, timeout)].reject(&:empty?).join("\n")
        CommandResult.new(success?: false, stdout: stdout, stderr: stderr, status: nil)
      end

      def wait_for_pid(pid, timeout)
        if timeout
          Timeout.timeout(timeout) { Process.wait2(pid).last }
        else
          Process.wait2(pid).last
        end
      end

      def captured_exchange(stdin, wait_thr, stdout_thread, stderr_thread, stdin_data, timeout)
        operation = proc do
          stdin.write(stdin_data) if stdin_data
          stdin.close unless stdin.closed?
          status = wait_thr.value
          [stdout_thread.value, stderr_thread.value, status]
        end
        stdout, stderr, status = timeout ? Timeout.timeout(timeout, &operation) : operation.call
        yield stdout, stderr, status
      end

      def terminate_process(pid, separate_process_group:)
        if separate_process_group
          terminate_process_group(pid)
        else
          terminate_single_process(pid)
        end
      end

      def terminate_single_process(pid)
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        return
      ensure
        reap_single_process(pid) if pid
      end

      def terminate_process_group(pid)
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH
        return
      rescue Errno::EPERM, Errno::EINVAL
        begin
          Process.kill("TERM", pid)
        rescue Errno::ESRCH
          return
        end
      ensure
        reap_or_kill(pid) if pid
      end

      def reap_or_kill(pid)
        deadline = Time.now + 1
        loop do
          waited = Process.waitpid(pid, Process::WNOHANG)
          return if waited
          break if Time.now >= deadline

          sleep 0.05
        end
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      rescue Errno::EPERM, Errno::EINVAL
        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        end
      ensure
        begin
          Process.waitpid(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          nil
        end
      end

      def reap_single_process(pid)
        deadline = Time.now + 1
        loop do
          waited = Process.waitpid(pid, Process::WNOHANG)
          return if waited
          break if Time.now >= deadline

          sleep 0.05
        end
        Process.kill("KILL", pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      ensure
        begin
          Process.waitpid(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          nil
        end
      end

      def safe_thread_value(thread)
        return "" unless thread
        return "" if thread.alive?

        thread.value.to_s
      rescue StandardError
        ""
      end

      def timeout_message(cmd, timeout)
        "Command timed out after #{timeout}s: #{cmd.join(' ')}"
      end
    end
  end
end
