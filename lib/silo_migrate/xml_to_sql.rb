# frozen_string_literal: true

require "rexml/parsers/streamparser"
require "rexml/streamlistener"
begin
  require "nokogiri"
rescue LoadError
  nil
end
require "pathname"
require "fileutils"
require "set"
require "zlib"
require "time"
require "json"
require "shellwords"
require_relative "sql_text"

module SiloMigrate
  class TableStructure
    attr_reader :name, :columns, :primary_keys, :indexes, :unique_keys

    def initialize(name)
      @name = name
      @columns = []
      @primary_keys = []
      @indexes = {}
      @unique_keys = {}
    end

    def add_column(attrs)
      col = {
        name: attrs["Field"].to_s,
        type: attrs["Type"] || "text",
        null: attrs["Null"] == "YES",
        key: attrs["Key"].to_s,
        default: attrs["Default"],
        extra: attrs["Extra"].to_s
      }
      @columns << col
      case col[:key]
      when "PRI" then @primary_keys << col[:name]
      when "UNI" then @unique_keys["uk_#{col[:name]}"] = [col[:name]]
      when "MUL" then @indexes["idx_#{col[:name]}"] = [col[:name]]
      end
    end

    def column_names
      @columns.map { |col| col[:name] }
    end

    def to_create_table_sql
      lines = @columns.map do |col|
        definition = "  #{SQLXML.escape_identifier(col[:name])} #{col[:type]}"
        definition += " NOT NULL" unless col[:null]
        if col[:default] && col[:default] != "null"
          default = col[:default]
          definition += if default.start_with?("CURRENT_") || default == "NULL" || numeric_type?(col[:type])
                          " DEFAULT #{default}"
                        else
                          " DEFAULT #{SQLXML.escape_sql_string(default)}"
                        end
        elsif col[:null] && col[:default] == "null"
          definition += " DEFAULT NULL"
        end
        if col[:extra].downcase.include?("auto_increment")
          definition += " AUTO_INCREMENT"
        elsif col[:extra].downcase.include?("on update current_timestamp") || col[:extra].include?("DEFAULT_GENERATED")
          definition += " ON UPDATE CURRENT_TIMESTAMP" unless definition.upcase.include?("ON UPDATE CURRENT_TIMESTAMP")
        end
        definition
      end

      lines << "  PRIMARY KEY (#{@primary_keys.map { |key| SQLXML.escape_identifier(key) }.join(', ')})" if @primary_keys.any?
      @unique_keys.each { |name, cols| lines << "  UNIQUE KEY #{SQLXML.escape_identifier(name)} (#{cols.map { |col| SQLXML.escape_identifier(col) }.join(', ')})" }
      @indexes.each { |name, cols| lines << "  KEY #{SQLXML.escape_identifier(name)} (#{cols.map { |col| SQLXML.escape_identifier(col) }.join(', ')})" }

      "DROP TABLE IF EXISTS #{SQLXML.escape_identifier(@name)};\n" \
        "CREATE TABLE #{SQLXML.escape_identifier(@name)} (\n" \
        "#{lines.join(",\n")}\n" \
        ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;\n"
    end

    private

    def numeric_type?(type)
      type.match?(/\A(?:int|bigint|tinyint|smallint|mediumint|float|double|decimal|numeric)/i)
    end
  end

  SQLXML = SqlText

  class XMLToSQLConverter
    attr_reader :stats

    UNESCAPED_AMP = /&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)/
    XML_CHUNK_SIZE = 64 * 1024
    XML_SANITIZER_TAIL = 128
    DEFAULT_PROGRESS_INTERVAL = 5
    ZERO_PROGRESS_WARNING_BYTES = 64 * 1024 * 1024

    def initialize(batch_size: 1000, include_tables: nil, exclude_tables: nil, include_files: nil, exclude_files: nil, schema_only: false, verbose: true,
                   scrub_invalid_xml_chars: true, invalid_xml_report_path: nil, zero_progress_warning_bytes: ZERO_PROGRESS_WARNING_BYTES)
      raise UsageError, "XML batch size must be greater than 0" unless batch_size.to_i.positive?

      @batch_size = batch_size
      @include_tables = include_tables&.to_set
      @exclude_tables = Array(exclude_tables).to_set
      @include_files = include_files&.to_set
      @exclude_files = Array(exclude_files).to_set
      @schema_only = schema_only
      @verbose = verbose
      @scrub_invalid_xml_chars = scrub_invalid_xml_chars
      @invalid_xml_report_path = invalid_xml_report_path
      @zero_progress_warning_bytes = zero_progress_warning_bytes
      reset_stats
    end

    def convert(source, output_path, file_pattern: "*.xml", progress_callback: nil, atomic: true, progress_interval: DEFAULT_PROGRESS_INTERVAL)
      reset_stats
      @progress_callback = progress_callback
      @progress_interval = progress_interval
      @last_progress_at = nil
      @current_file_progress = nil
      @conversion_started_at = Time.now
      @total_input_bytes = 0
      @invalid_xml_report = nil
      @invalid_xml_report_finalized = false
      source = Pathname(source)
      @source_path = source
      @zero_progress_warning_emitted = false
      output_path = Pathname(output_path)
      prepare_invalid_xml_report(source, output_path)
      files = source.file? ? [source] : source.glob(file_pattern).to_a.concat(source.glob("#{file_pattern}.gz").to_a).sort
      raise UsageError, "No XML files found in #{source}" if files.empty?

      files_to_process, skipped = files.partition { |file| process_file?(file) }
      @stats[:files_skipped] += skipped.length
      raise UsageError, "No XML files to process after filtering. All #{files.length} files were excluded." if files_to_process.empty?

      log "\n#{'=' * 60}\nXML TO SQL CONVERTER\n#{'=' * 60}"
      log "\nSource: #{source}"
      log "Output: #{output_path}"
      log "Files found: #{files.length}"
      log "Files to skip: #{skipped.length}" if skipped.any?
      log "Files to process: #{files_to_process.length}"
      @total_input_bytes = files_to_process.sum { |file| file.size rescue 0 }
      report_progress(:start, file_count: files_to_process.length, total_input_bytes: @total_input_bytes, output_path: output_path.to_s, force: true)

      write_path = atomic ? temporary_output_path(output_path) : output_path
      FileUtils.rm_f(write_path) if atomic
      open_output(write_path, gzip: output_path.to_s.end_with?(".gz")) do |out|
        out.write("-- Generated by xml-to-sql converter\n")
        out.write("-- Source: #{source}\n")
        out.write("-- Generated at: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        out.write("-- XML dumps are generated in autocommit mode to avoid huge transaction commits.\n")
        out.write("SET NAMES utf8mb4;\nSET sql_mode = '';\nSET FOREIGN_KEY_CHECKS = 0;\nSET UNIQUE_CHECKS = 0;\n\n")
        files_to_process.each_with_index { |file, index| convert_file(file, out, index: index + 1, count: files_to_process.length) }
        out.write("\nSET FOREIGN_KEY_CHECKS = 1;\nSET UNIQUE_CHECKS = 1;\n")
      end
      FileUtils.mv(write_path, output_path) if atomic

      @stats[:bytes_written] = File.size(output_path)
      report_progress(:complete, bytes_written: @stats[:bytes_written], force: true)
      finalize_invalid_xml_report(success: true)
      log "\n#{'=' * 60}\nCONVERSION COMPLETE\n#{'=' * 60}"
      log "\nFiles processed:  #{@stats[:files_processed]}"
      log "Files skipped:    #{@stats[:files_skipped]}" if @stats[:files_skipped].positive?
      log "Tables converted: #{@stats[:tables_processed]}"
      log "Tables skipped:   #{@stats[:tables_skipped]}" if @stats[:tables_skipped].positive?
      log "Rows converted:   #{@stats[:rows_processed]}"
      if @stats[:invalid_xml_chars_removed].positive?
        log "Invalid XML chars removed: #{@stats[:invalid_xml_chars_removed]}"
        log "Invalid XML audit: #{@invalid_xml_report.summary_path}"
      end
      log "Output size:      #{DumpTools.format_size(@stats[:bytes_written])}"
      log "\nOutput written to: #{output_path}"
      @stats
    ensure
      finalize_invalid_xml_report(success: false)
      FileUtils.rm_f(write_path) if atomic && write_path && output_path && write_path != output_path && File.exist?(write_path)
      @progress_callback = nil
      @current_file_progress = nil
      @invalid_xml_report = nil
    end

    def convert_file(xml_path, output, index: 1, count: 1)
      log "\nProcessing: #{File.basename(xml_path)}"
      file_size = xml_path.size rescue 0
      @current_file_progress = { path: xml_path.to_s, name: File.basename(xml_path), index: index, count: count, size: file_size, bytes_read: 0 }
      report_progress(:file_start, force: true)
      structures = {}
      current_rows = []
      current_table = nil
      current_column_formats = []

      parse_xml_file(xml_path) do |event_type, table, data|
        case event_type
        when :structure
          unless process_table?(table)
            @stats[:tables_skipped] += 1
            next
          end

          if current_rows.any?
            write_rows_batch(output, current_table, current_rows, column_formats: current_column_formats)
            current_rows = []
          end
          structures[table] = data
          output.write("\n-- Table: #{table}\n")
          output.write(data.to_create_table_sql)
          output.write("\n")
          @stats[:tables_processed] += 1
          report_progress(:table, current_table: table, force: @stats[:tables_processed] == 1)
        when :row
          next unless process_table?(table)
          next if @schema_only

          if current_table != table
            write_rows_batch(output, current_table, current_rows, column_formats: current_column_formats) if current_rows.any?
            current_table = table
            current_rows = []
            current_column_formats = column_formats_for(structures[table], data)
          end

          current_rows << data
          @stats[:rows_processed] += 1
          report_progress(:rows, current_table: table, force: @stats[:rows_processed] == 1)
          if current_rows.length >= @batch_size
            write_rows_batch(output, current_table, current_rows, column_formats: current_column_formats)
            current_rows = []
          end
        end
      end

      write_rows_batch(output, current_table, current_rows, column_formats: current_column_formats) if current_rows.any?
      @stats[:files_processed] += 1
      report_progress(:file_complete, force: true)
      @current_file_progress = nil
    end

    private

    class XMLStreamHandler
      def initialize(&event_handler)
        @event_handler = event_handler
        @current_structure = nil
        @current_table_data = nil
        @current_row = nil
        @current_field_name = nil
        @current_field_text = nil
      end

      def tag_start(name, attrs)
        case name
        when "table_structure"
          @current_structure = TableStructure.new(attrs["name"].to_s)
        when "table_data"
          @current_table_data = attrs["name"].to_s
        when "row"
          @current_row = {}
        when "field"
          if @current_structure
            @current_structure.add_column(attrs)
          elsif @current_table_data
            @current_field_name = attrs["name"].to_s
            @current_field_text = +""
          end
        end
      end

      def text(value)
        @current_field_text << value if @current_field_name
      end

      def cdata(value)
        @current_field_text << value if @current_field_name
      end

      def tag_end(name)
        case name
        when "table_structure"
          if @current_structure
            @event_handler.call(:structure, @current_structure.name, @current_structure)
            @current_structure = nil
          end
        when "field"
          @current_row[@current_field_name] = @current_field_text if @current_field_name && @current_row
          @current_field_name = nil
          @current_field_text = nil
        when "row"
          @event_handler.call(:row, @current_table_data, @current_row) if @current_table_data && @current_row
          @current_row = nil
        when "table_data"
          @current_table_data = nil
        end
      end
    end

    class REXMLStreamListener < XMLStreamHandler
      include REXML::StreamListener
    end

    if defined?(Nokogiri::XML::SAX::Document)
      class NokogiriStreamListener < Nokogiri::XML::SAX::Document
        def initialize(&event_handler)
          @handler = XMLStreamHandler.new(&event_handler)
        end

        def start_element(name, attrs = [])
          @handler.tag_start(name, attrs.to_h)
        end

        def characters(value)
          @handler.text(value)
        end

        def cdata_block(value)
          @handler.cdata(value)
        end

        def end_element(name)
          @handler.tag_end(name)
        end
      end
    end

    class XMLStreamSanitizer
      CDATA_START = "<![CDATA["
      CDATA_END = "]]>"

      def initialize(path:, scrub_invalid_xml_chars:, invalid_xml_handler:)
        @buffer = +""
        @in_cdata = false
        @path = path
        @scrub_invalid_xml_chars = scrub_invalid_xml_chars
        @invalid_xml_handler = invalid_xml_handler
        @input_byte_offset = 0
      end

      def feed(chunk, &block)
        @buffer << clean_chunk(chunk)
        drain(final: false, &block)
      end

      def finish(&block)
        drain(final: true, &block)
      end

      private

      def drain(final:, &block)
        loop do
          progressed = @in_cdata ? drain_cdata(final, &block) : drain_text(final, &block)
          break unless progressed
        end
      end

      def drain_cdata(final)
        index = @buffer.index(CDATA_END)
        if index
          yield @buffer.slice!(0, index + CDATA_END.length)
          @in_cdata = false
          true
        else
          length = final ? @buffer.length : [@buffer.length - (CDATA_END.length - 1), 0].max
          yield @buffer.slice!(0, length) if length.positive?
          false
        end
      end

      def drain_text(final)
        index = @buffer.index(CDATA_START)
        if index
          yield fix_text(@buffer.slice!(0, index))
          yield @buffer.slice!(0, CDATA_START.length)
          @in_cdata = true
          true
        elsif final
          yield fix_text(@buffer.slice!(0, @buffer.length)) unless @buffer.empty?
          false
        else
          length = [@buffer.length - XML_SANITIZER_TAIL, 0].max
          yield fix_text(@buffer.slice!(0, length)) if length.positive?
          false
        end
      end

      def fix_text(text)
        text.gsub(UNESCAPED_AMP, "&amp;")
      end

      def clean_chunk(chunk)
        raw = chunk.to_s.b
        cleaned = scrub_invalid_controls(raw)
        cleaned.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace)
      end

      def scrub_invalid_controls(raw)
        result = nil
        keep_from = 0
        raw.bytes.each_with_index do |byte, index|
          next unless invalid_xml_control_byte?(byte)

          offset = @input_byte_offset + index
          unless @scrub_invalid_xml_chars
            raise UsageError,
                  "Invalid XML control character #{format_codepoint(byte)} in #{@path} at input byte offset #{offset}. " \
                  "XML 1.0 forbids this character; remove --no-scrub-invalid-xml-chars to scrub it and write an audit report."
          end

          result ||= +"".b
          result << raw.byteslice(keep_from, index - keep_from) if index > keep_from
          @invalid_xml_handler&.call(file: @path, offset: offset, codepoint: byte)
          keep_from = index + 1
        end
        @input_byte_offset += raw.bytesize
        return raw unless result

        result << raw.byteslice(keep_from, raw.bytesize - keep_from) if keep_from < raw.bytesize
        result
      end

      def invalid_xml_control_byte?(byte)
        byte <= 0x08 || byte == 0x0B || byte == 0x0C || (byte >= 0x0E && byte <= 0x1F)
      end

      def format_codepoint(codepoint)
        format("U+%04X", codepoint)
      end
    end

    class InvalidXMLCharReport
      attr_reader :summary_path, :events_path, :total

      def initialize(source_path:, output_path:, summary_path:, events_path:, started_at:)
        @source_path = source_path.to_s
        @output_path = output_path.to_s
        @summary_path = Pathname(summary_path)
        @events_path = Pathname(events_path)
        @started_at = started_at
        @total = 0
        @per_file = Hash.new(0)
        @per_codepoint = Hash.new(0)
        @events = nil
      end

      def record(file:, offset:, codepoint:)
        open_events
        hex = format("U+%04X", codepoint)
        event = {
          source_file: file.to_s,
          input_byte_offset: offset,
          codepoint: hex,
          decimal: codepoint,
          hex: hex,
          action: "removed"
        }
        @events.write("#{JSON.generate(event)}\n")
        @total += 1
        @per_file[file.to_s] += 1
        @per_codepoint[hex] += 1
      end

      def finish(success:)
        return if @total.zero?

        @events&.close
        @events = nil
        FileUtils.mkdir_p(@summary_path.dirname)
        summary = {
          source_path: @source_path,
          output_path: @output_path,
          started_at: @started_at.utc.iso8601,
          completed_at: Time.now.utc.iso8601,
          success: success,
          total_scrubbed: @total,
          per_file_totals: @per_file,
          per_codepoint_totals: @per_codepoint,
          events_path: @events_path.to_s
        }
        File.write(@summary_path, JSON.pretty_generate(summary), mode: "w:utf-8")
      end

      private

      def open_events
        return if @events

        FileUtils.mkdir_p(@events_path.dirname)
        @events = File.open(@events_path, "w:utf-8")
      end
    end

    def parse_xml_file(xml_path, &block)
      if defined?(NokogiriStreamListener)
        parse_xml_file_with_nokogiri(xml_path, &block)
      else
        parse_xml_file_with_rexml(xml_path, &block)
      end
    end

    def parse_xml_file_with_nokogiri(xml_path, &block)
      parser = Nokogiri::XML::SAX::PushParser.new(NokogiriStreamListener.new(&block))
      stream_fixed_xml(xml_path) { |chunk| parser << chunk }
      parser.finish
    rescue Nokogiri::XML::SyntaxError => e
      raise REXML::ParseException, e.message
    end

    def parse_xml_file_with_rexml(xml_path, &block)
      reader, writer = IO.pipe
      writer_error = nil
      parser_error = nil
      writer_thread = Thread.new do
        begin
          stream_fixed_xml(xml_path) { |chunk| writer.write(chunk) }
        rescue Errno::EPIPE, IOError
          raise unless parser_error
        rescue StandardError => e
          writer_error = e
        ensure
          writer.close unless writer.closed?
        end
      end

      REXML::Parsers::StreamParser.new(reader, REXMLStreamListener.new(&block)).parse
    rescue StandardError => e
      parser_error = e
      raise
    ensure
      reader.close unless reader.closed?
      writer.close unless writer.closed?
      writer_thread&.join
      raise writer_error if writer_error && !parser_error
    end

    def stream_fixed_xml(path)
      sanitizer = XMLStreamSanitizer.new(
        path: path.to_s,
        scrub_invalid_xml_chars: @scrub_invalid_xml_chars,
        invalid_xml_handler: method(:record_invalid_xml_char)
      )
      open_input(path) do |input|
        while (chunk = input.read(XML_CHUNK_SIZE))
          track_input_bytes(chunk.bytesize)
          sanitizer.feed(chunk) { |fixed| yield fixed }
        end
      end
      sanitizer.finish { |fixed| yield fixed }
    end

    def track_input_bytes(bytes)
      return unless @current_file_progress

      @current_file_progress[:bytes_read] += bytes
      @stats[:bytes_read] += bytes
      warn_if_no_tables_after_bytes
      report_progress(:bytes)
    end

    def warn_if_no_tables_after_bytes
      return if @zero_progress_warning_emitted
      return unless @zero_progress_warning_bytes && @zero_progress_warning_bytes.positive?
      return unless @stats[:bytes_read] >= @zero_progress_warning_bytes
      return unless @stats[:tables_processed].zero? && @stats[:rows_processed].zero?

      @zero_progress_warning_emitted = true
      emit_warning(
        "Read #{DumpTools.format_size(@stats[:bytes_read])} from XML source #{@source_path} without discovering any tables or rows. " \
        "Check: input path, command path, file format, current checkout. " \
        "Recommended command: #{recommended_convert_command}"
      )
    end

    def recommended_convert_command
      repo_root = Pathname(__dir__).parent.parent
      source = @source_path ? @source_path.to_s : "SOURCE"
      "cd #{Shellwords.escape(repo_root.to_s)} && bin/silo-migrate convert-xml #{Shellwords.escape(source)}"
    end

    def emit_warning(message)
      @stats[:warnings] << message
      log "[WARN] #{message}"
      report_progress(:warning, message: message, force: true)
    end

    def record_invalid_xml_char(file:, offset:, codepoint:)
      @stats[:invalid_xml_chars_removed] += 1
      @invalid_xml_report&.record(file: file, offset: offset, codepoint: codepoint)
    end

    def prepare_invalid_xml_report(source, output_path)
      return unless @scrub_invalid_xml_chars

      summary_path, events_path = invalid_xml_report_paths(output_path)
      @invalid_xml_report = InvalidXMLCharReport.new(
        source_path: source,
        output_path: output_path,
        summary_path: summary_path,
        events_path: events_path,
        started_at: @conversion_started_at
      )
    end

    def finalize_invalid_xml_report(success:)
      return unless @invalid_xml_report
      return if @invalid_xml_report_finalized

      @invalid_xml_report.finish(success: success)
      @invalid_xml_report_finalized = true
    end

    def invalid_xml_report_paths(output_path)
      summary_path = Pathname(@invalid_xml_report_path || "#{output_path}.invalid-xml-chars.json")
      events_path = if summary_path.to_s.end_with?(".summary.json")
                      Pathname(summary_path.to_s.sub(/\.summary\.json\z/, ".events.jsonl"))
                    elsif summary_path.to_s.end_with?(".json")
                      Pathname(summary_path.to_s.sub(/\.json\z/, ".events.jsonl"))
                    else
                      Pathname("#{summary_path}.events.jsonl")
                    end
      [summary_path, events_path]
    end

    def report_progress(event, extra = {})
      return unless @progress_callback

      force = extra.delete(:force)
      now = Time.now
      return if !force && @last_progress_at && now - @last_progress_at < @progress_interval

      @last_progress_at = now
      payload = progress_snapshot(event, extra)
      @progress_callback.call(payload)
    end

    def progress_snapshot(event, extra)
      {
        event: event,
        elapsed: Time.now - @conversion_started_at,
        files_processed: @stats[:files_processed],
        tables_processed: @stats[:tables_processed],
        rows_processed: @stats[:rows_processed],
        bytes_read: @stats[:bytes_read],
        total_input_bytes: @total_input_bytes,
        current_file: @current_file_progress&.dup
      }.merge(extra)
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

    def reset_stats
      @stats = { tables_processed: 0, rows_processed: 0, bytes_read: 0, bytes_written: 0, files_processed: 0, files_skipped: 0, tables_skipped: 0, invalid_xml_chars_removed: 0, warnings: [] }
    end

    def open_output(path, gzip: nil)
      gzip = path.to_s.end_with?(".gz") if gzip.nil?
      if gzip
        Zlib::GzipWriter.open(path.to_s) { |gz| yield gz }
      else
        File.open(path, "w:utf-8") { |file| yield file }
      end
    end

    def process_table?(table)
      return false if @include_tables && !@include_tables.include?(table)
      return false if @exclude_tables.include?(table)

      true
    end

    def process_file?(file)
      file_name = file.basename.to_s
      base = file_name.sub(/\.gz\z/, "").sub(/\.xml\z/, "")
      return false if @include_files && !@include_files.include?(file_name) && !@include_files.include?(base)
      return false if @exclude_files.include?(file_name) || @exclude_files.include?(base)

      true
    end

    def column_formats_for(structure, sample_row)
      if structure
        structure.columns.map do |col|
          {
            name: col[:name],
            escaped_name: SQLXML.escape_identifier(col[:name]),
            type: col[:type],
            allows_null: col[:null],
            unique: col[:key] == "UNI",
            numeric: numeric_type?(col[:type])
          }
        end
      else
        sample_row.keys.map do |name|
          {
            name: name,
            escaped_name: SQLXML.escape_identifier(name),
            type: "text",
            allows_null: true,
            unique: false,
            numeric: false
          }
        end
      end
    end

    def write_rows_batch(out, table, rows, column_formats:)
      return if rows.empty?

      buffer = +"INSERT INTO #{SQLXML.escape_identifier(table)} ("
      column_formats.each_with_index do |format, index|
        buffer << ", " if index.positive?
        buffer << format[:escaped_name]
      end
      buffer << ") VALUES\n"

      rows.each_with_index do |row, row_index|
        buffer << ",\n" if row_index.positive?
        buffer << "  ("
        column_formats.each_with_index do |format, column_index|
          buffer << ", " if column_index.positive?
          buffer << format_value(row[format[:name]], format)
        end
        buffer << ")"
      end
      buffer << ";\n"
      out.write(buffer)
    end

    def format_value(value, format)
      allows_null = format[:allows_null]
      if value.nil? || value == "null"
        return "NULL" if allows_null
        return "0" if format[:numeric]

        return "''"
      end

      if format[:numeric]
        return allows_null ? "NULL" : "0" if value == ""
        return value if value.to_s.match?(/\A-?\d+(?:\.\d+)?\z/)
      end

      # Empty values in nullable UNIQUE-keyed columns must be NULL: repeated ''
      # values violate the unique index, and under UNIQUE_CHECKS=0 MariaDB's
      # bulk-insert path reports that only at COMMIT as a misleading
      # "Got error 1 'Operation not permitted'" failure.
      return "NULL" if format[:unique] && allows_null && value == ""

      SQLXML.escape_sql_string(value)
    end

    def numeric_type?(type)
      type.match?(/\A(?:int|bigint|tinyint|smallint|mediumint|float|double|decimal|numeric)/i)
    end

    def log(message)
      puts(message) if @verbose
    end
  end

  class XMLTableDiscovery
    FileResult = Struct.new(:path, :tables, :table_metadata, :bytes_scanned, :truncated, keyword_init: true) do
      def count
        tables.length
      end
    end

    Result = Struct.new(:tables, :files, :files_found, :files_skipped, :skipped, :table_metadata, :bytes_scanned, :truncated, keyword_init: true)

    CDATA_START = "<![CDATA[".b
    CDATA_END = "]]>".b
    COMMENT_START = "<!--".b
    COMMENT_END = "-->".b
    PROCESSING_START = "<?".b
    PROCESSING_END = "?>".b
    INTERESTING_TAG = /<\s*(?:table_structure|table_data|options)\b/n
    TAG_NAME = /\A<\s*([A-Za-z_:][\w:.-]*)/n
    ATTR = /\b([A-Za-z_:][\w:.-]*)\s*=\s*(['"])(.*?)\2/mn
    SCAN_TAIL_BYTES = 64

    def initialize(include_files: nil, exclude_files: nil, chunk_size: XMLToSQLConverter::XML_CHUNK_SIZE, max_bytes: nil)
      @include_files = include_files&.to_set
      @exclude_files = Array(exclude_files).to_set
      @chunk_size = chunk_size
      @max_bytes = max_bytes
    end

    def discover(source, file_pattern: "*.xml")
      source = Pathname(source)
      files = source.file? ? [source] : source.glob(file_pattern).to_a.concat(source.glob("#{file_pattern}.gz").to_a).sort
      raise UsageError, "No XML files found in #{source}" if files.empty?

      selected, skipped = files.partition { |file| process_file?(file) }
      raise UsageError, "No XML files to scan after filtering. All #{files.length} files were excluded." if selected.empty?

      file_results = selected.map do |file|
        tables, metadata, bytes_scanned, truncated = discover_file(file)
        FileResult.new(path: file, tables: tables.sort, table_metadata: metadata, bytes_scanned: bytes_scanned, truncated: truncated)
      end
      Result.new(
        tables: file_results.flat_map(&:tables).uniq.sort,
        files: file_results,
        files_found: files.length,
        files_skipped: skipped.length,
        skipped: skipped,
        table_metadata: merge_table_metadata(file_results),
        bytes_scanned: file_results.sum(&:bytes_scanned),
        truncated: file_results.any?(&:truncated)
      )
    end

    private

    def discover_file(path)
      tables = Set.new
      metadata = {}
      bytes_scanned = 0
      truncated = false
      scanner = TableTagScanner.new(chunk_size: @chunk_size) do |event, table, info|
        case event
        when :table
          tables << table
        when :metadata
          tables << table
          metadata[table] = merge_metadata(metadata[table], info)
        end
      end
      open_input(path) do |input|
        while (chunk = input.read(@chunk_size))
          if @max_bytes && bytes_scanned + chunk.bytesize > @max_bytes
            remaining = @max_bytes - bytes_scanned
            scanner.feed(chunk.byteslice(0, remaining)) if remaining.positive?
            bytes_scanned += remaining if remaining.positive?
            truncated = true
            break
          end

          scanner.feed(chunk)
          bytes_scanned += chunk.bytesize
        end
      end
      scanner.finish
      [tables.to_a, metadata, bytes_scanned, truncated]
    end

    def merge_table_metadata(file_results)
      file_results.each_with_object({}) do |file, merged|
        file.table_metadata.each do |table, info|
          merged[table] = merge_metadata(merged[table], info)
        end
      end
    end

    def merge_metadata(existing, incoming)
      return incoming if existing.nil?

      existing.merge(incoming) do |_key, old_value, new_value|
        if old_value.is_a?(Integer) && new_value.is_a?(Integer)
          [old_value, new_value].max
        else
          old_value || new_value
        end
      end
    end

    class TableTagScanner
      def initialize(chunk_size:, &event_handler)
        @event_handler = event_handler
        @chunk_size = chunk_size
        @buffer = +"".b
        @skip_until = nil
        @current_structure_table = nil
      end

      def feed(chunk)
        @buffer << chunk.to_s.b
        scan(final: false)
      end

      def finish
        scan(final: true)
      end

      private

      def scan(final:)
        loop do
          if @skip_until
            break unless drain_skip(final: final)

            next
          end

          marker = next_marker
          unless marker
            trim_buffer(final: final)
            break
          end

          index, type = marker
          if type == :tag
            tag_end = start_tag_end(index)
            unless tag_end
              @buffer.slice!(0, index) if index.positive?
              trim_oversized_partial_tag
              break
            end

            process_tag(@buffer.byteslice(index, tag_end - index + 1))
            @buffer.slice!(0, tag_end + 1)
          else
            start, ending = skip_markers(type)
            @buffer.slice!(0, index + start.bytesize)
            @skip_until = ending
            drain_skip(final: final)
          end
        end
      end

      def next_marker
        candidates = []
        tag = @buffer.index(INTERESTING_TAG)
        candidates << [tag, :tag] if tag
        cdata = @buffer.index(CDATA_START)
        candidates << [cdata, :cdata] if cdata
        comment = @buffer.index(COMMENT_START)
        candidates << [comment, :comment] if comment
        processing = @buffer.index(PROCESSING_START)
        candidates << [processing, :processing] if processing
        candidates.min_by(&:first)
      end

      def start_tag_end(index)
        quote = nil
        i = index
        while i < @buffer.bytesize
          char = @buffer.getbyte(i)
          if quote
            quote = nil if char == quote
          elsif char == 34 || char == 39
            quote = char
          elsif char == 62
            return i
          end
          i += 1
        end
        nil
      end

      def process_tag(tag)
        tag_name = tag[TAG_NAME, 1]
        attrs = parse_attributes(tag)

        case tag_name
        when "table_structure"
          table = decoded_attribute(attrs["name"])
          return if table.empty?

          @current_structure_table = table
          @event_handler.call(:table, table, nil)
        when "table_data"
          table = decoded_attribute(attrs["name"])
          @event_handler.call(:table, table, nil) unless table.empty?
        when "options"
          table = decoded_attribute(attrs["Name"] || attrs["name"]) || @current_structure_table
          table = @current_structure_table if table.to_s.empty?
          metadata = options_metadata(attrs)
          @event_handler.call(:metadata, table, metadata) if table && !table.empty? && metadata.any?
        end
      end

      def parse_attributes(tag)
        tag.scan(ATTR).each_with_object({}) do |(name, _quote, value), attrs|
          attrs[name] = value
        end
      end

      def decoded_attribute(value)
        return "" if value.nil?

        value = value.dup.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace)
        unescape_xml_attribute(value)
      end

      def options_metadata(attrs)
        {
          rows: integer_attribute(attrs["Rows"] || attrs["rows"]),
          data_length: integer_attribute(attrs["Data_length"] || attrs["data_length"]),
          index_length: integer_attribute(attrs["Index_length"] || attrs["index_length"])
        }.compact
      end

      def integer_attribute(value)
        return nil if value.nil? || value.empty?

        Integer(value, 10)
      rescue ArgumentError
        nil
      end

      def unescape_xml_attribute(value)
        value.gsub(/&(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);/) do |entity|
          case entity
          when "&amp;" then "&"
          when "&lt;" then "<"
          when "&gt;" then ">"
          when "&quot;" then '"'
          when "&apos;" then "'"
          when /\A&#(\d+);\z/ then Regexp.last_match(1).to_i.chr(Encoding::UTF_8)
          when /\A&#x([0-9a-fA-F]+);\z/ then Regexp.last_match(1).to_i(16).chr(Encoding::UTF_8)
          else entity
          end
        rescue RangeError
          entity
        end
      end

      def skip_markers(type)
        case type
        when :cdata then [CDATA_START, CDATA_END]
        when :comment then [COMMENT_START, COMMENT_END]
        when :processing then [PROCESSING_START, PROCESSING_END]
        end
      end

      def drain_skip(final:)
        index = @buffer.index(@skip_until)
        if index
          @buffer.slice!(0, index + @skip_until.bytesize)
          @skip_until = nil
          true
        else
          keep = final ? 0 : [SCAN_TAIL_BYTES, @skip_until.bytesize - 1].max
          @buffer = keep.positive? ? buffer_tail(keep) : +"".b
          false
        end
      end

      def trim_buffer(final:)
        keep = final ? 0 : SCAN_TAIL_BYTES
        @buffer = keep.positive? ? buffer_tail(keep) : +"".b
      end

      def trim_oversized_partial_tag
        return unless @buffer.bytesize > @chunk_size + SCAN_TAIL_BYTES

        @buffer = @buffer.byteslice(1, @buffer.bytesize - 1) || +"".b
      end

      def buffer_tail(bytes)
        return @buffer if @buffer.bytesize <= bytes

        @buffer.byteslice(-bytes, bytes) || +"".b
      end
    end

    def open_input(path)
      if path.to_s.end_with?(".gz")
        Zlib::GzipReader.open(path.to_s) { |gz| yield gz }
      else
        File.open(path, "rb") { |file| yield file }
      end
    end

    def process_file?(file)
      file_name = file.basename.to_s
      base = file_name.sub(/\.gz\z/, "").sub(/\.xml\z/, "")
      return false if @include_files && !@include_files.include?(file_name) && !@include_files.include?(base)
      return false if @exclude_files.include?(file_name) || @exclude_files.include?(base)

      true
    end
  end
end
