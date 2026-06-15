# frozen_string_literal: true

require "pathname"
require "fileutils"
require "set"
require "zlib"
require "time"
require_relative "sql_text"
require_relative "json_to_sql/record_streamer"
require_relative "json_to_sql/shredder"
require_relative "json_to_sql/schema_inferrer"
require_relative "json_to_sql/json_schema_loader"
require_relative "json_to_sql/sql_emitter"

module SiloMigrate
  # Converts arbitrary JSON export files into a MySQL/MariaDB SQL dump using
  # convention-based relational shredding. Counterpart to XMLToSQLConverter:
  # same output framing, filters, gzip handling, atomic writes, and progress
  # callback vocabulary. Each file is streamed twice: pass 1 infers the
  # schema (CREATE TABLEs must precede INSERTs), pass 2 emits the rows.
  class JSONToSQLConverter
    attr_reader :stats

    DEFAULT_PROGRESS_INTERVAL = 5
    DEFAULT_MAX_DEPTH = 5

    def initialize(batch_size: 1000, include_tables: nil, exclude_tables: nil, include_files: nil,
                   exclude_files: nil, schema_only: false, records_path: nil, table_name: nil,
                   max_depth: DEFAULT_MAX_DEPTH, json_columns: nil, graphql_unwrap: true,
                   raw_dates: false, schema_dir: nil, meta_table: true, recover_truncated: false, verbose: true)
      raise UsageError, "JSON batch size must be greater than 0" unless batch_size.to_i.positive?
      raise UsageError, "JSON max depth must be greater than 0" unless max_depth.to_i.positive?
      raise UsageError, "Schema directory not found: #{schema_dir}" if schema_dir && !Dir.exist?(schema_dir)

      @batch_size = batch_size
      @include_tables = include_tables&.to_set
      @exclude_tables = Array(exclude_tables).to_set
      @include_files = include_files&.to_set
      @exclude_files = Array(exclude_files).to_set
      @schema_only = schema_only
      @records_path = records_path
      @table_name = table_name
      @max_depth = max_depth
      @json_columns = json_columns
      @graphql_unwrap = graphql_unwrap
      @raw_dates = raw_dates
      @schema_dir = schema_dir
      @meta_table = meta_table
      @recover_truncated = recover_truncated
      @verbose = verbose
      @emitter = JSONToSQL::SqlEmitter.new
      reset_stats
    end

    def convert(source, output_path, file_pattern: "*.json", progress_callback: nil, atomic: true, progress_interval: DEFAULT_PROGRESS_INTERVAL)
      reset_stats
      @progress_callback = progress_callback
      @progress_interval = progress_interval
      @last_progress_at = nil
      @current_file_progress = nil
      @conversion_started_at = Time.now
      @emitted_tables = {}
      @pii_meta = []
      @schema_used = false
      source = Pathname(source)
      output_path = Pathname(output_path)
      files = source.file? ? [source] : source.glob(file_pattern).to_a.concat(source.glob("#{file_pattern}.gz").to_a).sort
      raise UsageError, "No JSON files found in #{source}" if files.empty?

      files_to_process, skipped = files.partition { |file| process_file?(file) }
      @stats[:files_skipped] += skipped.length
      raise UsageError, "No JSON files to process after filtering. All #{files.length} files were excluded." if files_to_process.empty?

      log "\n#{'=' * 60}\nJSON TO SQL CONVERTER\n#{'=' * 60}"
      log "\nSource: #{source}"
      log "Output: #{output_path}"
      log "Files found: #{files.length}"
      log "Files to skip: #{skipped.length}" if skipped.any?
      log "Files to process: #{files_to_process.length}"
      total_input_bytes = files_to_process.sum { |file| file.size rescue 0 }
      report_progress(:start, file_count: files_to_process.length, total_input_bytes: total_input_bytes, output_path: output_path.to_s, force: true)

      write_path = atomic ? temporary_output_path(output_path) : output_path
      FileUtils.rm_f(write_path) if atomic
      open_output(write_path, gzip: output_path.to_s.end_with?(".gz")) do |out|
        @emitter.write_header(out, source)
        files_to_process.each_with_index { |file, index| convert_file(file, out, index: index + 1, count: files_to_process.length) }
        @emitter.write_meta_table(out, @pii_meta) if @schema_used && @meta_table
        @emitter.write_footer(out)
      end
      FileUtils.mv(write_path, output_path) if atomic

      @stats[:bytes_written] = File.size(output_path)
      report_progress(:complete, bytes_written: @stats[:bytes_written], force: true)
      log "\n#{'=' * 60}\nCONVERSION COMPLETE\n#{'=' * 60}"
      log "\nFiles processed:  #{@stats[:files_processed]}"
      log "Files skipped:    #{@stats[:files_skipped]}" if @stats[:files_skipped].positive?
      log "Tables converted: #{@stats[:tables_processed]}"
      log "Tables skipped:   #{@stats[:tables_skipped]}" if @stats[:tables_skipped].positive?
      log "Rows converted:   #{@stats[:rows_processed]} (+#{@stats[:child_rows_processed]} child rows)"
      log "Output size:      #{DumpTools.format_size(@stats[:bytes_written])}"
      log "\nOutput written to: #{output_path}"
      @stats
    ensure
      FileUtils.rm_f(write_path) if atomic && write_path && output_path && write_path != output_path && File.exist?(write_path)
      @progress_callback = nil
      @current_file_progress = nil
    end

    private

    def convert_file(path, out, index: 1, count: 1)
      convert_file!(path, out, index: index, count: count)
    rescue Oj::ParseError, EncodingError => e
      base = File.basename(path.to_s).sub(/\.gz\z/, "").sub(/\.json\z/, "")
      message = "Malformed JSON in #{File.basename(path)} (#{e.message.sub(/ \[\S+\]\z/, '')})."
      if truncated_json?(path)
        message += " The file appears to be truncated — it does not end with '}' or ']'."
        message += " Re-run with --recover-truncated to keep the complete records before the truncation point," \
                   " fix or re-export the file, or convert the others with --exclude-files #{base}."
      else
        message += " Fix or re-export the file, or convert the others with --exclude-files #{base}."
      end
      raise UsageError, message
    end

    # The last non-whitespace byte of a complete JSON document is always '}'
    # or ']' for object/array roots (the only roots these exports use).
    def truncated_json?(path)
      return false if path.to_s.end_with?(".gz")

      tail = File.open(path, "rb") do |file|
        file.seek(-[file.size, 256].min, IO::SEEK_END)
        file.read
      end
      last = tail.to_s.rstrip[-1]
      !["}", "]"].include?(last)
    rescue SystemCallError, IOError
      false
    end

    def convert_file!(path, out, index: 1, count: 1)
      log "\nProcessing: #{File.basename(path)}"
      schema_path = find_schema(path)
      file_size = path.size rescue 0
      streaming_passes = schema_path ? 1 : 2
      streaming_passes -= 1 if @schema_only
      @current_file_progress = { path: path.to_s, name: File.basename(path), index: index, count: count, size: file_size * [streaming_passes, 1].max, bytes_read: 0, pass: 1 }
      report_progress(:file_start, force: true)

      registry = JSONToSQL::NameRegistry.new
      if schema_path
        loaded = JSONToSQL::JsonSchemaLoader.new(
          registry: registry,
          max_depth: @max_depth,
          graphql_unwrap: @graphql_unwrap,
          raw_dates: @raw_dates
        ).load(schema_path, records_path: @records_path)
        @schema_used = true
        tables = loaded.plans.transform_values { |plan| { defs: plan.defs, child: plan.child } }
        root_table = resolve_root_table({ "object_name" => loaded.root_name }, path)
      end
      shredder = JSONToSQL::Shredder.new(
        registry: registry,
        max_depth: @max_depth,
        graphql_unwrap: @graphql_unwrap,
        json_column_paths: @json_columns,
        forced_json_paths: loaded&.forced_json
      )

      unless schema_path
        inferrer = JSONToSQL::SchemaInferrer.new(raw_dates: @raw_dates)
        result = stream_records(path) { |record, ordinal| inferrer.observe(shredder.shred(record, ordinal)) }
        # The emit pass re-shreds every record, so fallback/collision counts
        # are taken from the inference pass only.
        @stats[:json_fallback_columns] += shredder.json_fallbacks
        @stats[:column_collisions] += registry.collisions
        warn_total_records(path, result)
        tables = inferrer.profiles.transform_values { |profile| { defs: profile.finalize, child: profile.child? } }
        root_table = resolve_root_table(result.envelope, path)
      end

      definitions = build_definitions(path, tables, root_table, strict: !schema_path.nil?)
      definitions.each_value do |definition|
        @emitter.write_create_table(out, definition[:name], definition[:defs], child: definition[:child])
        @stats[:tables_processed] += 1
        report_progress(:table, current_table: definition[:name])
      end
      collect_pii(loaded, definitions, schema_path) if loaded

      unless @schema_only
        @current_file_progress[:pass] = 2 unless schema_path
        sid_counters = Hash.new(0)
        buffers = Hash.new { |hash, rel| hash[rel] = [] }
        emit_result = stream_records(path) do |record, ordinal|
          emit_row(out, shredder.shred(record, ordinal), nil, definitions, sid_counters, buffers)
        end
        buffers.each { |rel, rows| flush_batch(out, definitions[rel], rows) }
        warn_total_records(path, emit_result) if schema_path
      end

      @stats[:files_processed] += 1
      report_progress(:file_complete, force: true)
      @current_file_progress = nil
    end

    def find_schema(path)
      return nil unless @schema_dir

      base = File.basename(path.to_s).sub(/\.gz\z/, "").sub(/\.json\z/, "")
      candidate = File.join(@schema_dir, "#{base}.schema.json")
      return Pathname(candidate) if File.exist?(candidate)

      emit_warning "No JSON Schema found for #{File.basename(path)} in #{@schema_dir}; inferring schema from the data"
      nil
    end

    def warn_total_records(path, result)
      if result.truncated
        @stats[:files_recovered] += 1
        expected = result.envelope["total_records"]
        expected_clause = expected.is_a?(Integer) ? ", expected #{expected}" : ""
        emit_warning "#{File.basename(path)} is truncated (#{result.parse_error}); " \
                     "recovered #{result.record_count} complete record(s)#{expected_clause}. " \
                     "The remaining records are lost — re-export the file for the full data."
        return
      end

      total_records = result.envelope["total_records"]
      return unless total_records.is_a?(Integer) && total_records != result.record_count

      emit_warning "#{File.basename(path)}: total_records says #{total_records} but #{result.record_count} records were found"
    end

    def emit_warning(message)
      @stats[:warnings] << message
      report_progress(:warning, message: message, force: true)
      log "[WARN] #{message}"
    end

    def collect_pii(loaded, definitions, schema_path)
      loaded.pii.each do |entry|
        definition = definitions[entry.table_rel]
        next unless definition

        @pii_meta << [definition[:name], entry.column, entry.json_path, 1, entry.note, File.basename(schema_path)]
      end
    end

    def build_definitions(path, tables, root_table, strict: false)
      definitions = {}
      tables.each do |rel, table|
        name = final_table_name(root_table, rel)
        if (previous = @emitted_tables[name])
          raise UsageError, "Table name '#{name}' is produced by both #{previous} and #{path}. Rename one file or use --include-files/--exclude-files."
        end

        unless process_table?(name, root: root_table)
          @stats[:tables_skipped] += 1
          next
        end

        @emitted_tables[name] = path.to_s
        meta = table[:child] ? JSONToSQL::SqlEmitter::META_CHILD : JSONToSQL::SqlEmitter::META_ROOT
        definitions[rel] = {
          name: name,
          defs: table[:defs],
          child: table[:child],
          columns: meta + table[:defs].map(&:name),
          known_columns: strict ? table[:defs].map(&:name).to_set : nil
        }
      end
      definitions
    end

    def emit_row(out, row, parent_sid, definitions, sid_counters, buffers)
      sid = (sid_counters[row.table_rel] += 1)
      definition = definitions[row.table_rel]
      if definition
        values = if definition[:child]
                   [sid.to_s, parent_sid.to_s, SqlText.escape_sql_string(row.parent_natural_id), row.ordinal.to_s]
                 else
                   [sid.to_s]
                 end
        values.concat(definition[:defs].map { |col| @emitter.format_value(row.columns[col.name], col) })
        if (known = definition[:known_columns])
          row.columns.each_key { |column| @stats[:dropped_values] += 1 unless known.include?(column) }
        end
        buffer = buffers[row.table_rel]
        buffer << values
        if definition[:child]
          @stats[:child_rows_processed] += 1
        else
          @stats[:rows_processed] += 1
        end
        report_progress(:rows)
        flush_batch(out, definition, buffer) if buffer.length >= @batch_size
      end
      row.children.each { |child| emit_row(out, child, sid, definitions, sid_counters, buffers) }
    end

    def flush_batch(out, definition, rows)
      return if definition.nil? || rows.empty?

      @emitter.write_batch(out, definition[:name], definition[:columns], rows)
      rows.clear
    end

    def resolve_root_table(envelope, path)
      base = @table_name
      base ||= envelope["object_name"] if envelope["object_name"].is_a?(String)
      base ||= File.basename(path.to_s).sub(/\.gz\z/, "").sub(/\.json\z/, "")
      JSONToSQL::NameRegistry.sanitize(base)
    end

    def final_table_name(root_table, rel)
      rel.empty? ? root_table : JSONToSQL::NameRegistry.truncate("#{root_table}_#{rel}")
    end

    def stream_records(path, &block)
      open_input(path) do |io|
        counting = JSONToSQL::CountingIO.new(io) { |bytes| track_input_bytes(bytes) }
        JSONToSQL::RecordStreamer.new(records_path: @records_path).each_record(counting, recover: @recover_truncated, &block)
      end
    end

    def track_input_bytes(bytes)
      return unless @current_file_progress

      @current_file_progress[:bytes_read] += bytes
      report_progress(:bytes)
    end

    def report_progress(event, extra = {})
      return unless @progress_callback

      force = extra.delete(:force)
      now = Time.now
      return if !force && @last_progress_at && now - @last_progress_at < @progress_interval

      @last_progress_at = now
      @progress_callback.call(
        {
          event: event,
          elapsed: Time.now - @conversion_started_at,
          files_processed: @stats[:files_processed],
          tables_processed: @stats[:tables_processed],
          rows_processed: @stats[:rows_processed],
          current_file: @current_file_progress&.dup
        }.merge(extra)
      )
    end

    def temporary_output_path(path)
      Pathname("#{path}.tmp")
    end

    def open_input(path)
      if path.to_s.end_with?(".gz")
        Zlib::GzipReader.open(path.to_s) { |gz| yield gz }
      else
        File.open(path, "rb") { |file| yield file }
      end
    end

    def open_output(path, gzip: nil)
      gzip = path.to_s.end_with?(".gz") if gzip.nil?
      if gzip
        Zlib::GzipWriter.open(path.to_s) { |gz| yield gz }
      else
        File.open(path, "w:utf-8") { |file| yield file }
      end
    end

    def reset_stats
      @stats = {
        tables_processed: 0, rows_processed: 0, child_rows_processed: 0, bytes_written: 0,
        files_processed: 0, files_skipped: 0, tables_skipped: 0, column_collisions: 0,
        json_fallback_columns: 0, dropped_values: 0, files_recovered: 0, warnings: []
      }
    end

    def process_table?(table, root:)
      return false if @exclude_tables.include?(root) || @exclude_tables.include?(table)
      return @include_tables.include?(table) || @include_tables.include?(root) if @include_tables

      true
    end

    def process_file?(file)
      file_name = file.basename.to_s
      base = file_name.sub(/\.gz\z/, "").sub(/\.json\z/, "")
      return false if @include_files && !@include_files.include?(file_name) && !@include_files.include?(base)
      return false if @exclude_files.include?(file_name) || @exclude_files.include?(base)

      true
    end

    def log(message)
      puts(message) if @verbose
    end
  end
end
