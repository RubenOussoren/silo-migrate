# frozen_string_literal: true

require "set"
require "rbconfig"
require "zlib"

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

          detection = SQLTools.detect_dump_type(dump_path)
          SQLTools.dump_type_summary(detection).each { |line| @output.puts line } if print_validation
        end

        max_packet = options[:turbo] ? "1G" : (options[:max_packet] || "512M")
        fast = options[:fast] || options[:turbo]
        container_name = "#{customer}_#{phase}_#{db_type}"
        raise UsageError, "Container #{container_name} is not running. Start it first." unless @runtime.container_running?(container_name)

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

        needs_collation_fix = db_type == "mariadb" && options[:fix_collations] != false && SQLTools.detect_mysql8_collations(dump_path)[:has_incompatible_collations]
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
        raise UsageError, failure_message(result, dump_path) unless result.success?

        reporter.finish(elapsed) if report_progress
        @output.puts "\n[OK] Dump imported successfully"
        @output.puts "     File: #{File.basename(dump_path)}"
        @output.puts "     Size: #{DumpTools.format_size(File.size(dump_path))}"
        @output.puts "     Time elapsed: #{DumpTools.format_elapsed(elapsed)}"
      end

      def replace_dump(customer, phase, yes: false)
        Project.load_config(customer, @env)
        raise UsageError, "Replacing a dump resets database container data. Re-run with --yes to confirm." unless yes

        @runtime.compose(customer, ["--profile", "#{phase}-db", "stop"])
        @runtime.compose(customer, ["--profile", "#{phase}-db", "rm", "-f", "-v"])
        @output.puts "[OK] Database reset complete"
      end

      private

      def database_config(customer, phase, config)
        if phase == "final"
          db_type = config["FINAL_DB_TYPE"]
          raise UsageError, "No final database configured for #{customer}.\nRun 'silo-migrate add-final-db #{customer}' first to configure it." unless db_type

          [db_type, config["FINAL_DB_NAME"] || "#{customer}_final_db", config["FINAL_DB_PASSWORD"] || config["INITIAL_DB_PASSWORD"] || config["DB_PASSWORD"]]
        else
          [config["INITIAL_DB_TYPE"], config["INITIAL_DB_NAME"] || config["DB_NAME"], config["INITIAL_DB_PASSWORD"] || config["DB_PASSWORD"]]
        end.tap do |db_type, db_name, password|
          raise UsageError, "No #{phase} database configured" unless db_type
          raise UsageError, "Database name not configured" unless db_name
          raise UsageError, "Database password not configured in config.env." unless password
        end
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

      def failure_message(result, dump_path)
        output = result.stderr.empty? ? result.stdout : result.stderr
        lines = ["Import failed (exit code #{result.status}): #{output}"]
        diagnostic = ImportFailureDiagnostic.new(dump_path, output).summary
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
              silo-migrate replace-dump #{@customer} #{@phase} --yes
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
        ERROR_LINE_PATTERN = /ERROR\s+1180\b.*?\bat line\s+(\d+)/i

        def initialize(path, output)
          @path = path
          @output = output.to_s
        end

        def summary
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
          if @output.match?(/during\s+COMMIT/i) && @output.match?(/Operation not permitted|EPERM/i) && !statement[:dump_transaction_markers]
            lines << "  Recommendation: this dump is transaction-free; if MariaDB still reports OS EPERM during COMMIT, retry the same import on Linux."
          end
          lines
        end

        private

        def error_line_number
          match = @output.match(ERROR_LINE_PATTERN)
          match && match[1].to_i
        end
      end

      class SQLStatementScanner
        TRANSACTION_MARKER = /\b(?:START\s+TRANSACTION|BEGIN|COMMIT)\b|SET\s+AUTOCOMMIT\s*=\s*0/i

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
