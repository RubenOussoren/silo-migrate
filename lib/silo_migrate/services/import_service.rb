# frozen_string_literal: true

require "set"
require "rbconfig"
require "zlib"
require "json"
require "time"

module SiloMigrate
  module Services
    class ImportService
      CHUNK_SIZE = 1024 * 1024
      PROGRESS_BYTE_INTERVAL = 4 * 1024 * 1024
      PROGRESS_TIME_INTERVAL = 0.5
      LARGE_IMPORT_BYTES = 1024 * 1024 * 1024
      XML_CONVERTED_MARKER = "-- XML dumps are generated in autocommit mode"

      def initialize(runtime: Runtime::Docker.new, env: ENV, output: $stdout)
        Runtime::Contract.assert_implemented!(runtime)
        @runtime = runtime
        @env = env
        @output = output
      end

      def import_dump(customer, phase, options = {})
        config = Project.load_config(customer, @env)
        db_type, db_name, password = database_config(customer, phase, config)
        dumps_dir = File.join(Project.project_path(customer, @env), "dumps", phase)
        dump_path = resolve_dump_path(dumps_dir, options[:file])
        unless options[:skip_validation] || options[:trust_dump]
          print_validation = !options[:quiet_validation]
          format = DumpTools.detect_file_format(dump_path)
          @output.puts "Detected dump format: #{format[:format]}" if print_validation
          raise UsageError, "File does not appear to be a valid SQL dump: #{File.basename(dump_path)}\n#{format[:message]}" unless format[:is_valid]
          raise UsageError, "Cannot import tar archive directly. Extract the SQL file first." if format[:format] == "tar"

          verify_gzip_integrity!(dump_path, print_validation)
          detection = SQLTools.detect_dump_type(dump_path)
          SQLTools.dump_type_summary(detection).each { |line| @output.puts line } if print_validation
        end

        max_packet = options[:turbo] ? "1G" : (options[:max_packet] || "512M")
        fast = options[:fast] || options[:turbo]
        container_name = "#{customer}_#{phase}_#{db_type}"
        raise UsageError, "Container #{container_name} is not running. Start it first." unless @runtime.container_running?(container_name)

        ensure_container_ready!(customer, phase, container_name, options)

        preflight = ImportPreflight.new(
          runtime: @runtime,
          env: @env,
          output: @output,
          customer: customer,
          phase: phase,
          db_type: db_type,
          db_name: db_name,
          password: password,
          container_name: container_name,
          dump_path: dump_path,
          options: options
        )
        preflight.run unless options[:skip_preflight]

        store = WorkflowStore.new(customer, env: @env, runtime: @runtime)
        # The lock is held only for state transitions, never while dump bytes
        # stream: the persisted "importing" state (with a live PID) is what
        # blocks concurrent imports, so status/dashboard reads stay responsive.
        store.with_lock do |state|
          store.reconcile_state!(state)
          phase_state = store.phase(state, phase)
          guard_import_state!(customer, phase, phase_state)
          count = store.user_table_count(phase)
          if count.nil?
            phase_state["state"] = "unknown"
            store.write_locked(state)
            raise UsageError, "Could not verify that the #{phase} database is empty. Start it and retry, or reset it with: silo-migrate reset-db #{customer} #{phase} --yes"
          end
          if count.positive?
            phase_state["state"] = "untracked"
            phase_state["user_table_count"] = count
            phase_state["probed_at"] = Time.now.utc.iso8601
            store.write_locked(state)
            raise UsageError, "The #{phase} database contains #{count} user table(s) and cannot be imported over. Reset it first: silo-migrate reset-db #{customer} #{phase} --yes"
          end

          phase_state["state"] = "importing"
          phase_state["import_started_at"] = Time.now.utc.iso8601
          phase_state["import_pid"] = Process.pid
          phase_state["pending_import"] = store.dump_identity(dump_path).merge("options" => persisted_options(options))
          store.write_locked(state)
        end

        begin
          needs_collation_fix = collation_fix_needed?(db_type, dump_path, options)
          cmd = @runtime.exec_import_command(container_name, db_type, db_name, password, max_packet: max_packet, disable_keys: fast)
          start_time = Time.now
          @output.puts "Importing into #{container_name}..."
          reporter = ImportProgressReporter.new(
            @output,
            file_size: File.size(dump_path),
            compressed: DumpTools.gzip_file?(dump_path),
            interval: options.fetch(:progress_interval, 2)
          )
          custom_progress_callback = options[:progress_callback]
          report_progress = options.fetch(:report_progress, custom_progress_callback.nil?)
          progress_callback = import_progress_callback(custom_progress_callback, reporter, report_progress)
          reporter.start if report_progress
          result = stream_dump_to_runtime(cmd, dump_path, needs_collation_fix, excluded_tables(options[:exclude_tables]), progress_callback)
          elapsed = Time.now - start_time
          raise UsageError, failure_message(result, dump_path, customer: customer, phase: phase, db_type: db_type) unless result.success?

          imported_at = Time.now.utc.iso8601
          store.with_lock do |state|
            phase_state = store.phase(state, phase)
            pending = phase_state.delete("pending_import") || store.dump_identity(dump_path).merge("options" => persisted_options(options))
            phase_state["generation"] = phase_state["generation"].to_i + 1
            phase_state["state"] = "ready"
            phase_state["import"] = pending.merge("imported_at" => imported_at)
            phase_state.delete("import_started_at")
            phase_state.delete("import_pid")
            phase_state.delete("user_table_count")
            store.write_locked(state)
            write_legacy_marker(customer, phase, phase_state["import"])
          end
          reporter.finish(elapsed) if report_progress
          @output.puts "\n[OK] Dump imported successfully"
          @output.puts "     File: #{File.basename(dump_path)}"
          @output.puts "     Size: #{DumpTools.format_size(File.size(dump_path))}"
          @output.puts "     Time elapsed: #{DumpTools.format_elapsed(elapsed)}"
        rescue StandardError
          store.with_lock do |state|
            phase_state = store.phase(state, phase)
            if phase_state["state"] == "importing"
              phase_state["state"] = "dirty"
              phase_state["failed_at"] = Time.now.utc.iso8601
              phase_state.delete("import_pid")
              store.write_locked(state)
            end
          end
          raise
        end
      end

      def replace_dump(customer, phase, yes: false)
        Project.load_config(customer, @env)
        raise UsageError, "Resetting a database deletes its container data and archives dependent artifacts. Re-run with --yes to confirm." unless yes

        store = WorkflowStore.new(customer, env: @env, runtime: @runtime)
        store.with_lock do |state|
          store.reconcile_state!(state)
          if store.phase(state, phase)["state"] == "importing"
            raise UsageError, "An import into the #{phase} database is currently running; wait for it to finish (or fail) before resetting."
          end

          stop = @runtime.compose(customer, ["--profile", "#{phase}-db", "stop"])
          remove = @runtime.compose(customer, ["--profile", "#{phase}-db", "rm", "-f", "-v"])
          raise UsageError, "Database reset failed; nothing was archived and workflow state was not cleared." unless stop.success? && remove.success?

          Services::HistoryService.new(env: @env, output: @output).archive_for_phase(customer, phase, state: state)
          data = store.phase(state, phase)
          reset_generation = data["generation"].to_i
          data.replace("generation" => reset_generation + 1, "state" => "empty", "import" => nil, "schema_bundle" => nil, "reset_at" => Time.now.utc.iso8601)
          lineage = state.dig("converter", "output_lineage")
          if lineage && lineage["phase"] == phase && lineage["generation"].to_i == reset_generation
            state.fetch("converter")["output_lineage"] = nil
            state.fetch("discourse")["state"] = "stale" unless state.dig("discourse", "state") == "pristine"
          end
          clear_legacy_markers(customer, phase)
          store.write_locked(state)
        end
        @output.puts "[OK] #{phase.capitalize} database reset complete; staged dumps were preserved"
      end

      private

      def guard_import_state!(customer, phase, phase_state)
        return if phase_state["state"] == "empty"

        detail = if phase_state["state"] == "ready" && phase_state["import"]
                   " (loaded #{phase_state.dig('import', 'filename')} at #{phase_state.dig('import', 'imported_at')})"
                 elsif phase_state["state"] == "untracked" && phase_state["user_table_count"]
                   " (contains #{phase_state['user_table_count']} user table(s) without import provenance)"
                 else
                   ""
                 end
        raise UsageError, "The #{phase} database is #{phase_state['state']}#{detail}; imports are blocked and no dump data was sent. Reset it first: silo-migrate reset-db #{customer} #{phase} --yes"
      end

      def persisted_options(options)
        allowed = %i[exclude_tables max_packet fast turbo fix_collations skip_validation trust_dump]
        options.select { |key, _| allowed.include?(key) }.transform_keys(&:to_s)
      end

      def write_legacy_marker(customer, phase, import)
        path = File.join(Project.project_path(customer, @env), "dumps", phase, ".imported.json")
        Project.atomic_write(path, JSON.pretty_generate({ "file" => import["filename"], "imported_at" => import["imported_at"], "sha256" => import["sha256"], "options" => import["options"] }) + "\n")
      end

      def clear_legacy_markers(customer, phase)
        project = Project.project_path(customer, @env)
        FileUtils.rm_f(File.join(project, "dumps", phase, ".imported.json"))
        FileUtils.rm_f(File.join(project, "output", "#{phase}-imported.txt"))
      end

      def verify_gzip_integrity!(dump_path, print_validation)
        return unless DumpTools.gzip_file?(dump_path)
        return if @env["SILO_MIGRATE_SKIP_GZIP_VERIFY"] == "1"

        @output.puts "Verifying gzip integrity (full read)..." if print_validation
        verification = DumpTools.verify_gzip(dump_path, full: true)
        unless verification[:valid]
          raise UsageError, <<~MSG.chomp
            gzip integrity check failed for #{File.basename(dump_path)}: #{verification[:message]}
            The file is likely truncated or corrupt - re-transfer it and stage it again.
            Bypass this check with --skip-validation or SILO_MIGRATE_SKIP_GZIP_VERIFY=1 if you are sure the file is intact.
          MSG
        end
        @output.puts "[OK] gzip integrity verified" if print_validation
      end

      def ensure_container_ready!(customer, phase, container_name, options)
        return if options[:skip_health_wait]

        state = container_health_state(container_name)
        if state.nil? || state == "none"
          # nil: runtime cannot report health states; waiting on a healthcheck
          # that may not exist would just burn the timeout.
          @output.puts "[WARN] Container #{container_name} has no healthcheck; skipping health wait." if state == "none"
          return
        end
        return if state == "healthy"

        timeout = options.fetch(:health_timeout, 60)
        @output.puts "Waiting for #{container_name} to become healthy (up to #{timeout}s)..."
        return if @runtime.wait_for_container_healthy(container_name, timeout: timeout)

        unless @runtime.container_running?(container_name)
          raise UsageError, "Container #{container_name} stopped while waiting for it to become healthy.\nStart it again: silo-migrate start #{customer} --profile #{phase}-db --wait"
        end

        raise UsageError, <<~MSG.chomp
          Container #{container_name} is not healthy after #{timeout}s (state: #{container_health_state(container_name) || 'unknown'}).
          The database is probably still initializing. Wait for it, then retry:
            silo-migrate start #{customer} --profile #{phase}-db --wait
            silo-migrate import-dump #{customer} #{phase}
          Bypass this check with --skip-health-wait, or raise the limit with --health-timeout SECONDS.
        MSG
      end

      def container_health_state(container_name)
        return nil unless @runtime.respond_to?(:container_health_state)

        @runtime.container_health_state(container_name)
      rescue UsageError
        nil
      end

      def collation_fix_needed?(db_type, dump_path, options)
        case db_type
        when "mariadb"
          options[:fix_collations] != false && SQLTools.detect_mysql8_collations(dump_path)[:has_incompatible_collations]
        when "mysql"
          if options[:fix_collations] == true
            @output.puts "[INFO] Applying MySQL 8 collation fix as requested (MySQL 8 normally supports utf8mb4_0900_* natively)."
            true
          else
            false
          end
        else
          @output.puts "[WARN] --fix-collations is a MySQL/MariaDB option; ignoring it for #{db_type}." if options[:fix_collations] == true
          false
        end
      end

      def database_config(customer, phase, config)
        Project.database_config(customer, phase, config)
      end

      def resolve_dump_path(dumps_dir, file)
        if file
          path = File.absolute_path(file) == file ? file : File.join(dumps_dir, file)
          raise UsageError, "Dump file not found: #{path}" unless File.exist?(path)

          return path
        end

        files = Dir[File.join(dumps_dir, "*.sql")] + Dir[File.join(dumps_dir, "*.sql.gz")]
        raise UsageError, "No dump files found in #{dumps_dir}" if files.empty?
        raise UsageError, "Multiple dump files found; pass --file." if files.length > 1

        files.first
      end

      def stream_dump_to_runtime(cmd, path, fix_collations, exclude_tables, progress_callback)
        if @runtime.respond_to?(:run_with_stdin)
          return @runtime.run_with_stdin(cmd) do |stdin|
            write_import_stream(stdin, path, fix_collations, exclude_tables, progress_callback)
          end
        end

        text = +""
        write_import_stream(text, path, fix_collations, exclude_tables, progress_callback)
        @runtime.run(cmd, stdin_data: text, capture: true)
      end

      def write_import_stream(output, path, fix_collations, exclude_tables, progress_callback)
        if fast_chunked_import?(fix_collations, exclude_tables)
          write_chunked_import_stream(output, path, progress_callback)
        else
          write_filtered_import_stream(output, path, fix_collations, exclude_tables, progress_callback)
        end
      end

      def fast_chunked_import?(fix_collations, exclude_tables)
        !fix_collations && exclude_tables.empty?
      end

      def write_chunked_import_stream(output, path, progress_callback)
        stats = { bytes_processed: 0, lines_processed: 0, current_table: nil, stream_mode: :chunked }
        progress = ProgressThrottler.new(progress_callback)
        open_chunk_reader(path) do |file|
          while (chunk = file.read(CHUNK_SIZE))
            output.write(chunk)
            stats[:bytes_processed] += chunk.bytesize
            progress.emit(stats)
          end
        end
        progress.emit(stats.merge(complete: true), force: true)
      end

      def write_filtered_import_stream(output, path, fix_collations, exclude_tables, progress_callback)
        filter = TableExclusionFilter.new(exclude_tables)
        stats = { bytes_processed: 0, lines_processed: 0, current_table: nil, stream_mode: :filtered }
        progress = ProgressThrottler.new(progress_callback)
        DumpTools.open_text(path) do |file|
          file.each_line do |line|
            line = SQLTools.fix_mysql8_collations(line) if fix_collations
            stats[:bytes_processed] += line.bytesize
            stats[:lines_processed] += 1
            stats[:current_table] = TableNameDetector.table_name(line) || stats[:current_table]
            progress.emit(stats)
            next if filter.skip?(line)

            output.write(line)
          end
        end
        progress.emit(stats.merge(complete: true), force: true)
      end

      def open_chunk_reader(path)
        if DumpTools.gzip_file?(path)
          Zlib::GzipReader.open(path.to_s) { |gz| yield gz }
        else
          File.open(path, "rb") { |file| yield file }
        end
      end

      def excluded_tables(value)
        case value
        when nil then []
        when Array then value
        else
          value.to_s.split(",").map(&:strip).reject(&:empty?)
        end.map(&:downcase)
      end

      def import_progress_callback(custom_callback, reporter, report_progress)
        return custom_callback unless report_progress
        return proc { |stats| reporter.tick(stats) } unless custom_callback

        proc do |stats|
          custom_callback.call(stats)
          reporter.tick(stats)
        end
      end

      def failure_message(result, dump_path, customer:, phase:, db_type:)
        output = result.stderr.empty? ? result.stdout : result.stderr
        lines = ["Import failed (exit code #{result.status}): #{output}"]
        diagnostic = ImportFailureDiagnostic.new(
          path: dump_path,
          output: output,
          db_type: db_type,
          customer: customer,
          phase: phase
        ).summary
        lines.concat(diagnostic) if diagnostic.any?
        lines.join("\n")
      end

      class ImportPreflight
        MYSQL_VARIABLES = %w[
          innodb_flush_method
          innodb_use_native_aio
          innodb_flush_log_at_trx_commit
        ].freeze

        def initialize(runtime:, env:, output:, customer:, phase:, db_type:, db_name:, password:, container_name:, dump_path:, options:)
          @runtime = runtime
          @env = env
          @output = output
          @customer = customer
          @phase = phase
          @db_type = db_type
          @db_name = db_name
          @password = password
          @container_name = container_name
          @dump_path = dump_path
          @options = options
        end

        def run
          return unless mysql_family?

          metadata = {
            host_os: host_os,
            docker_desktop: docker_desktop?,
            dump_size: File.size(@dump_path),
            xml_converted: xml_converted_dump?
          }
          variables = mysql_variables
          disk = container_disk_free
          print_preflight(metadata, variables, disk)
          return unless block_unsafe_macos_mariadb?(metadata, variables)

          raise UsageError, unsafe_macos_message(variables)
        end

        private

        def mysql_family?
          %w[mysql mariadb].include?(@db_type)
        end

        def macos?
          host_os.match?(/darwin/i)
        end

        def host_os
          (@env["SILO_MIGRATE_HOST_OS"] || RbConfig::CONFIG["host_os"]).to_s
        end

        def docker_desktop?
          return @runtime.docker_desktop? if @runtime.respond_to?(:docker_desktop?)

          macos?
        end

        def large_import?(size)
          size >= large_import_threshold
        end

        def large_import_threshold
          Integer(@env.fetch("SILO_MIGRATE_LARGE_IMPORT_BYTES", LARGE_IMPORT_BYTES))
        rescue ArgumentError
          LARGE_IMPORT_BYTES
        end

        def xml_converted_dump?
          DumpHeaderScanner.contains?(@dump_path, XML_CONVERTED_MARKER)
        end

        def mysql_variables
          return {} unless @runtime.respond_to?(:mysql_variables)

          @runtime.mysql_variables(@container_name, @db_type, @db_name, @password, MYSQL_VARIABLES)
        rescue UsageError
          {}
        end

        def container_disk_free
          return {} unless @runtime.respond_to?(:container_disk_free)

          @runtime.container_disk_free(@container_name, ["/var/lib/mysql", "/tmp"])
        rescue UsageError
          {}
        end

        def print_preflight(metadata, variables, disk)
          @output.puts "Import preflight:"
          @output.puts "  Host OS: #{metadata[:host_os]}"
          @output.puts "  Docker Desktop: #{metadata[:docker_desktop] ? 'yes' : 'no'}"
          @output.puts "  DB type: #{@db_type}"
          @output.puts "  Dump size: #{DumpTools.format_size(metadata[:dump_size])}"
          @output.puts "  XML-converted dump: #{metadata[:xml_converted] ? 'yes' : 'no'}"
          if variables.any?
            @output.puts "  InnoDB: innodb_flush_method=#{variables['innodb_flush_method'] || 'unknown'}, innodb_use_native_aio=#{variables['innodb_use_native_aio'] || 'unknown'}, innodb_flush_log_at_trx_commit=#{variables['innodb_flush_log_at_trx_commit'] || 'unknown'}"
          end
          disk.each do |path, bytes|
            @output.puts "  Free space #{path}: #{DumpTools.format_size(bytes)}"
          end
          print_macos_warning(metadata) if macos_warning?(metadata)
        end

        def macos_warning?(metadata)
          @db_type == "mariadb" &&
            macos? &&
            metadata[:docker_desktop] &&
            large_import?(metadata[:dump_size])
        end

        def print_macos_warning(metadata)
          qualifier = metadata[:xml_converted] ? " XML-converted" : ""
          @output.puts "[WARN] Large#{qualifier} MariaDB imports on macOS Docker Desktop can fail during InnoDB commit/fsync."
          @output.puts "[WARN] Linux is the preferred path for multi-GB imports if this failure repeats."
        end

        def block_unsafe_macos_mariadb?(metadata, variables)
          return false unless macos_warning?(metadata)

          unsafe_flush_method?(variables["innodb_flush_method"]) || unsafe_native_aio?(variables["innodb_use_native_aio"])
        end

        def unsafe_flush_method?(value)
          !value.to_s.empty? && value.to_s.downcase != "fsync"
        end

        def unsafe_native_aio?(value)
          normalized = value.to_s.downcase
          !normalized.empty? && !%w[off 0 false no].include?(normalized)
        end

        def unsafe_macos_message(variables)
          <<~MESSAGE.chomp
            Unsafe MariaDB InnoDB settings for a large macOS Docker Desktop import.
            Current values: innodb_flush_method=#{variables['innodb_flush_method'] || 'unknown'}, innodb_use_native_aio=#{variables['innodb_use_native_aio'] || 'unknown'}.

            Regenerate compose with safer DB settings:
              silo-migrate regenerate #{@customer}
            Reset the #{@phase} DB container so the new settings apply:
              silo-migrate reset-db #{@customer} #{@phase} --yes
            Start the DB again:
              silo-migrate start #{@customer} --profile #{@phase}-db --wait
            Retry the import:
              silo-migrate import-dump #{@customer} #{@phase} --file #{File.basename(@dump_path)}
          MESSAGE
        end
      end

      class DumpHeaderScanner
        HEADER_BYTES = 1024 * 1024

        def self.contains?(path, needle)
          new(path).contains?(needle)
        end

        def initialize(path)
          @path = path
        end

        def contains?(needle)
          content = +""
          open_reader do |reader|
            content = reader.read(HEADER_BYTES).to_s
          end
          content.include?(needle)
        end

        private

        def open_reader(&block)
          if DumpTools.gzip_file?(@path)
            Zlib::GzipReader.open(@path.to_s, &block)
          else
            File.open(@path, "rb", &block)
          end
        end
      end

      class ImportFailureDiagnostic
        ERROR_CODE_PATTERN = /ERROR\s+(\d{3,4})\b/i
        LINE_NUMBER_PATTERN = /\bat line\s+(\d+)/i

        MYSQL_ADVICE = {
          1062 => "Duplicate entry: the database already contains data, likely from a previous partial import. Reset it before retrying (see recovery steps below).",
          1054 => "Unknown column: the dump references columns the target schema lacks (often MySQL generated columns). Try: silo-migrate preprocess-dump DUMP_FILE",
          1118 => "Row size too large: the table declares too many inline VARCHAR columns. If this dump was generated by convert-json, regenerate it with the current converter so wide columns are moved to TEXT, then reset the database and retry.",
          1366 => "Invalid value for a column: usually a character set mismatch. Re-export the source with --default-character-set=utf8mb4."
        }.freeze

        POSTGRES_ADVICE = [
          [/duplicate key value violates unique constraint/i, "Duplicate key: the database already contains data, likely from a previous partial import. Reset it before retrying (see recovery steps below)."],
          [/invalid byte sequence for encoding/i, "Encoding error: the dump contains bytes that are invalid for the database encoding. Re-export the source with UTF-8 client encoding."],
          [/column .* does not exist/i, "Unknown column: the dump does not match the target schema."],
          [/relation .* already exists/i, "Objects already exist: the database is not empty, likely from a previous partial import. Reset it before retrying (see recovery steps below)."]
        ].freeze

        def initialize(path:, output:, db_type: nil, customer: nil, phase: nil)
          @path = path
          @output = output.to_s
          @db_type = db_type
          @customer = customer
          @phase = phase
        end

        def summary
          lines = []
          lines.concat(statement_context_lines)
          lines.concat(advice_lines)
          lines.concat(recovery_lines)
          lines
        end

        private

        def statement_context_lines
          line_number = error_line_number
          return [] unless line_number

          statement = SQLStatementScanner.new(@path).statement_at(line_number)
          lines = ["Import failure diagnostics:"]
          lines << "  Reported SQL line: #{line_number}"
          lines << "  Statement table: #{statement[:table] || 'unknown'}"
          lines << "  Statement lines: #{statement[:start_line] || 'unknown'}-#{statement[:end_line] || 'unknown'}"
          lines << "  Statement rows: #{statement[:row_count] || 0}"
          lines << "  Statement size: #{DumpTools.format_size(statement[:bytes] || 0)}"
          lines << "  Dump transaction markers: #{statement[:dump_transaction_markers] ? 'yes' : 'no'}"
          if @output.match?(/during\s+COMMIT/i) && @output.match?(/Operation not permitted|EPERM/i)
            table = statement[:table] || "the failing table"
            lines << "  Recommendation: when a dump sets UNIQUE_CHECKS=0 and FOREIGN_KEY_CHECKS=0, MariaDB bulk-loads the first INSERT into each empty table and reports duplicate values in a UNIQUE column only at COMMIT, as this misleading OS error. Check #{table} for duplicate (especially repeated empty-string) values in UNIQUE-keyed columns."
            unless statement[:dump_transaction_markers]
              lines << "  If no duplicates exist: this dump is transaction-free, so a genuine OS EPERM during COMMIT points at the host filesystem - retry the same import on Linux."
            end
          end
          lines
        end

        def advice_lines
          advice = mysql_advice || postgres_advice
          advice ? ["Advice: #{advice}"] : []
        end

        def mysql_advice
          code = error_code
          return nil unless code
          return collation_advice if code == 1273

          MYSQL_ADVICE[code]
        end

        def collation_advice
          if @db_type == "mariadb"
            "Unknown collation: the dump uses MySQL 8 collations MariaDB does not support. Retry without --no-fix-collations so they are mapped automatically, or recreate the project with a mysql initial DB to match the dump."
          else
            "Unknown collation: the dump uses collations this server does not support. Retry with --fix-collations, or recreate the project with the engine matching the dump (see silo-migrate analyze-dump)."
          end
        end

        def postgres_advice
          POSTGRES_ADVICE.each do |pattern, advice|
            return advice if @output.match?(pattern)
          end
          nil
        end

        def recovery_lines
          return [] unless @customer && @phase

          [
            "Recovery (reset the #{@phase} database and retry):",
            "  silo-migrate reset-db #{@customer} #{@phase} --yes",
            "  silo-migrate start #{@customer} --profile #{@phase}-db --wait",
            "  silo-migrate import-dump #{@customer} #{@phase} --file #{File.basename(@path)}"
          ]
        end

        def error_code
          match = @output.match(ERROR_CODE_PATTERN)
          match && match[1].to_i
        end

        # Only the mysql-family clients report dump line numbers as "at line N";
        # postgres emits "at line N" inside PL/pgSQL CONTEXT messages where the
        # number refers to a function body, not the dump.
        def error_line_number
          return nil unless @db_type.nil? || %w[mysql mariadb].include?(@db_type)

          match = @output.match(LINE_NUMBER_PATTERN)
          match && match[1].to_i
        end
      end

      class SQLStatementScanner
        # Anchored to line start: dump data rows can contain these words inside
        # string values (forum posts), which must not count as markers.
        TRANSACTION_MARKER = /\A\s*(?:START\s+TRANSACTION|BEGIN|COMMIT)\b|\A\s*SET\s+AUTOCOMMIT\s*=\s*0/i

        def initialize(path)
          @path = path
        end

        def statement_at(line_number)
          current = nil
          selected = nil
          dump_transaction_markers = false

          DumpTools.open_text(@path) do |file|
            file.each_line.with_index(1) do |line, number|
              dump_transaction_markers ||= line.match?(TRANSACTION_MARKER)
              current ||= new_statement(number)
              update_statement(current, line, number)

              if selected.nil? && number >= line_number && statement_complete?(line)
                selected = current
              elsif selected.nil? && current[:start_line] <= line_number && number >= line_number
                selected = current
              end

              current = nil if statement_complete?(line)
            end
          end

          selected ||= current || new_statement(line_number)
          selected.merge(dump_transaction_markers: dump_transaction_markers)
        end

        private

        def new_statement(line_number)
          { start_line: line_number, end_line: line_number, table: nil, row_count: 0, bytes: 0, insert: false }
        end

        def update_statement(statement, line, line_number)
          statement[:end_line] = line_number
          statement[:bytes] += line.bytesize
          statement[:table] ||= TableNameDetector.table_name(line)
          statement[:insert] ||= line.match?(/\A\s*INSERT\s+(?:IGNORE\s+)?INTO\b/i)
          statement[:row_count] += count_insert_rows(line) if statement[:insert]
        end

        def count_insert_rows(line)
          if line.match?(/\A\s*INSERT\b/i)
            values_index = line =~ /\bVALUES\b/i
            return 0 unless values_index

            return count_value_tuple_starts(line[(values_index + 6)..])
          end

          count_value_tuple_starts(line)
        end

        def count_value_tuple_starts(text)
          text.scan(/(?:\A|,)\s*\(/).length
        end

        def statement_complete?(line)
          line.match?(/;\s*\z/)
        end
      end

      class ProgressThrottler
        def initialize(callback, byte_interval: PROGRESS_BYTE_INTERVAL, time_interval: PROGRESS_TIME_INTERVAL)
          @callback = callback
          @byte_interval = byte_interval
          @time_interval = time_interval
          @last_bytes = 0
          @last_time = nil
        end

        def emit(stats, force: false)
          return unless @callback

          now = Time.now
          return unless force || due?(stats, now)

          @last_bytes = stats[:bytes_processed].to_i
          @last_time = now
          @callback.call(stats.dup)
        end

        private

        def due?(stats, now)
          return true if @last_time.nil?
          return true if stats[:bytes_processed].to_i - @last_bytes >= @byte_interval

          now - @last_time >= @time_interval
        end
      end

      class TableExclusionFilter
        def initialize(tables)
          @tables = tables.to_set
          @skipping_create_table = false
          @skipping_insert = false
        end

        def skip?(line)
          normalized = normalize_mysql_version_comment(line)
          if @skipping_insert
            @skipping_insert = false if statement_complete?(normalized)
            return true
          end

          if @skipping_create_table
            @skipping_create_table = false if statement_complete?(normalized)
            return true
          end

          table = table_name(normalized)
          return false unless table && @tables.include?(table)

          @skipping_create_table = true if normalized.match?(/\A\s*CREATE\s+TABLE\b/i) && !statement_complete?(normalized)
          @skipping_insert = true if normalized.match?(/\A\s*INSERT\s+(?:IGNORE\s+)?INTO\b/i) && !statement_complete?(normalized)
          true
        end

        private

        def table_name(line)
          TableNameDetector.table_name(line)&.downcase
        end

        def normalize_mysql_version_comment(line)
          line.sub(/\A\s*\/\*!\d+\s*/, "").sub(/\s*\*\/\s*;?\s*\z/, ";")
        end

        def statement_complete?(line)
          line.match?(/;\s*\z/)
        end
      end

      module TableNameDetector
        PATTERNS = [
          /\A\s*INSERT\s+(?:IGNORE\s+)?INTO\s+(?:[`"]?\w+[`"]?\.)?[`"]?(\w+)[`"]?/i,
          /\A\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:[`"]?\w+[`"]?\.)?[`"]?(\w+)[`"]?/i,
          /\A\s*DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:[`"]?\w+[`"]?\.)?[`"]?(\w+)[`"]?/i,
          /\A\s*LOCK\s+TABLES\s+(?:[`"]?\w+[`"]?\.)?[`"]?(\w+)[`"]?/i,
          /\A\s*ALTER\s+TABLE\s+(?:[`"]?\w+[`"]?\.)?[`"]?(\w+)[`"]?/i
        ].freeze

        module_function

        def table_name(line)
          PATTERNS.each do |pattern|
            match = line.match(pattern)
            return match[1] if match
          end
          nil
        end
      end

      class ImportProgressReporter
        def initialize(output, file_size:, compressed:, interval:)
          @output = output
          @file_size = file_size.to_i
          @effective_size = compressed ? @file_size * DumpTools::GZIP_COMPRESSION_RATIO_ESTIMATE : @file_size
          @interval = interval
          @last_update = nil
          @last_percent_line = -10
          @tty = output.respond_to?(:tty?) && output.tty?
        end

        def start
          write("  Progress: 0% | Lines: 0 | Starting...")
        end

        def tick(stats)
          now = Time.now
          percent = percent_for(stats[:bytes_processed], complete: stats[:complete])
          return unless stats[:complete] || should_print?(now, percent)

          @last_update = now
          @last_percent_line = percent if !@tty && percent >= @last_percent_line + 10
          table = stats[:current_table].to_s[0, 24]
          table_part = table.empty? ? "" : " | Table: #{table}"
          write("  Progress: #{percent}% | Lines: #{stats[:lines_processed].to_i}#{table_part}")
        end

        def finish(elapsed)
          write("  Progress: 100% | Elapsed: #{DumpTools.format_elapsed(elapsed)}", final: true)
        end

        private

        def percent_for(bytes, complete:)
          return 100 if complete
          return 0 unless @effective_size.positive?

          [[((bytes.to_f / @effective_size) * 100).to_i, 99].min, 0].max
        end

        def should_print?(now, percent)
          return true if @last_update.nil?
          return true if @interval.to_f <= 0
          return true if @tty && now - @last_update >= @interval

          !@tty && percent >= @last_percent_line + 10 && now - @last_update >= @interval
        end

        def write(message, final: false)
          if @tty
            @output.print "\r#{message}    "
            @output.puts if final
          else
            @output.puts message
          end
        end
      end
    end
  end
end
