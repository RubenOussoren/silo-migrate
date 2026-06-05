# frozen_string_literal: true

require "zlib"

module SiloMigrate
  module SQLTools
    module_function

    def detect_dump_type(path, num_lines: 100)
      result = { detected: nil, recommended: nil, compatible: [], notes: "", markers_found: [] }
      header = +""
      DumpTools.open_text(path) do |file|
        num_lines.times do
          line = file.gets
          break unless line

          header << line
        end
      end

      DUMP_SIGNATURES.each do |name, info|
        found = info[:markers].select { |marker| header.include?(marker) }
        excluded = Array(info[:exclude_markers]).any? { |marker| header.include?(marker) }
        next if found.empty? || excluded

        return {
          detected: name,
          recommended: info[:recommended],
          compatible: info[:compatible],
          notes: info[:notes],
          markers_found: found
        }
      end

      if path.to_s.end_with?(".sql", ".sql.gz", ".gz")
        result.merge(detected: "unknown_sql", recommended: "mariadb", compatible: ["mariadb", "mysql"], notes: "SQL dump detected but source database unknown. MariaDB recommended as default.")
      else
        result
      end
    rescue StandardError => e
      result.merge(notes: "Could not read dump file: #{e.message}")
    end

    def dump_type_summary(detection)
      if detection[:detected] && detection[:detected] != "unknown_sql"
        ["Detected source type: #{detection[:detected]}"]
      elsif detection[:recommended]
        ["Source type: unknown SQL dump"]
      else
        []
      end.tap do |lines|
        lines << "Recommended DB: #{detection[:recommended]}" if detection[:recommended]
      end
    end

    def detect_mysql8_collations(path, sample_bytes: 10 * 1024 * 1024)
      sample = read_sample(path, sample_bytes)
      found = MYSQL8_COLLATION_MAP.each_with_object({}) do |(mysql8, replacement), memo|
        memo[mysql8] = replacement if sample.include?(mysql8)
      end
      { has_incompatible_collations: found.any?, collations_found: found }
    end

    def fix_mysql8_collations(text)
      MYSQL8_COLLATION_MAP.reduce(text) do |line, (mysql8, replacement)|
        line.gsub(/\b#{Regexp.escape(mysql8)}\b/, replacement)
      end
    end

    def analyze_sql_dump(path, sample_bytes: 200 * 1024 * 1024)
      file_size = File.size(path)
      compressed = DumpTools.gzip_file?(path)
      result = {
        file_size: file_size,
        compressed: compressed,
        tables: {},
        total_tables: 0,
        uncompressed_size: 0,
        sampled: false,
        sample_ratio: 1.0
      }

      table_order = []
      current_insert_table = nil
      total_bytes = 0

      DumpTools.open_text(path) do |file|
        file.each_line do |line|
          bytes = line.bytesize
          total_bytes += bytes
          if sample_bytes && total_bytes >= sample_bytes
            result[:sampled] = true
            estimated_total = compressed ? file_size * DumpTools::GZIP_COMPRESSION_RATIO_ESTIMATE : file_size
            result[:sample_ratio] = total_bytes.to_f / estimated_total
            break
          end

          if (match = line.match(/CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:[`"]?(\w+)[`"]?\.)?[`"]?(\w+)[`"]?/i))
            table = extract_table_name(match)
            result[:tables][table] ||= { size: 0, rows: 0 }
            table_order << table unless table_order.include?(table)
          elsif (match = line.match(/INSERT\s+INTO\s+(?:[`"]?(\w+)[`"]?\.)?[`"]?(\w+)[`"]?/i))
            table = extract_table_name(match)
            result[:tables][table] ||= { size: 0, rows: 0 }
            table_order << table unless table_order.include?(table)
            result[:tables][table][:size] += bytes
            result[:tables][table][:rows] += line.upcase.include?("VALUES") ? line.scan(/\),\s*\(/).length + 1 : 1
            current_insert_table = table
          end
        end
      end

      if result[:sampled] && result[:sample_ratio].positive?
        scale = 1.0 / result[:sample_ratio]
        result[:uncompressed_size] = (total_bytes * scale).to_i
        if current_insert_table && result[:tables][current_insert_table]
          result[:tables][current_insert_table][:size] = (result[:tables][current_insert_table][:size] * scale).to_i
          result[:tables][current_insert_table][:rows] = (result[:tables][current_insert_table][:rows] * scale).to_i
          result[:tables][current_insert_table][:estimated] = true
        end
      else
        result[:uncompressed_size] = total_bytes
      end

      result[:total_tables] = result[:tables].length
      result
    end

    def detect_generated_columns(path, sample_bytes: nil, validate_inserts: true)
      result = { has_generated_columns: false, has_problematic_inserts: false, tables: {}, total_generated_columns: 0, scanned_bytes: 0 }
      in_create = false
      current_table = nil
      buffer = []

      DumpTools.open_text(path) do |file|
        file.each_line do |line|
          result[:scanned_bytes] += line.bytesize
          break if sample_bytes && result[:scanned_bytes] > sample_bytes

          if !in_create && (match = line.match(/CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:[`"]?(\w+)[`"]?\.)?[`"]?(\w+)[`"]?\s*\(/i))
            current_table = extract_table_name(match)
            in_create = true
            buffer = [line]
            next
          end

          next unless in_create

          buffer << line
          next unless line.include?(";")

          columns = []
          generated = []
          buffer.each do |create_line|
            stripped = create_line.strip
            next if stripped.match?(/\A(PRIMARY|KEY|INDEX|UNIQUE|CONSTRAINT|FOREIGN|CHECK|FULLTEXT|SPATIAL|\)|CREATE|ENGINE)\b/i)

            col_match = stripped.match(/\A[`"]?(\w+)[`"]?\s+\w+/i)
            next unless col_match

            col = col_match[1].downcase
            columns << col
            generated << col if stripped.match?(/(?:GENERATED\s+ALWAYS\s+)?AS\s*\(/i)
          end

          if generated.any?
            result[:tables][current_table] = {
              columns: generated,
              column_indices: generated.to_h { |col| [col, columns.index(col)] },
              all_columns: columns
            }
            result[:total_generated_columns] += generated.length
          end
          in_create = false
          current_table = nil
          buffer = []
        end
      end

      result[:has_generated_columns] = result[:total_generated_columns].positive?
      validate_inserts_for_generated_columns(path, result, sample_bytes) if validate_inserts && result[:has_generated_columns]
      result
    end

    def validate_inserts_for_generated_columns(path, result, sample_bytes = nil)
      tables = result[:tables]
      scanned = 0
      DumpTools.open_text(path) do |file|
        file.each_line do |line|
          scanned += line.bytesize
          break if sample_bytes && scanned > sample_bytes

          table, columns = insert_table_and_columns(line)
          next unless table && tables[table]

          gen_cols = tables[table][:columns]
          problematic = if columns
                          columns.map(&:downcase) & gen_cols
                        else
                          gen_cols
                        end
          next if problematic.empty?

          tables[table][:problematic_inserts] ||= []
          tables[table][:problematic_inserts] |= problematic
          result[:has_problematic_inserts] = true
        end
      end
    end

    def preprocess_mysql_dump(path, output_path, generated_cols_info = nil)
      generated_cols_info ||= detect_generated_columns(path)
      return { success: false, error: "No generated columns found in dump - preprocessing not needed", lines_processed: 0, lines_modified: 0, tables_affected: [], bytes_written: 0 } unless generated_cols_info[:has_generated_columns]

      tmp = "#{output_path}.tmp"
      lines_processed = 0
      lines_modified = 0
      tables_affected = []
      writer = output_path.to_s.end_with?(".gz") ? Zlib::GzipWriter.open(tmp) : File.open(tmp, "w:utf-8")
      begin
        DumpTools.open_text(path) do |reader|
          reader.each_line do |line|
            lines_processed += 1
            modified = rewrite_generated_insert(line, generated_cols_info)
            if modified != line
              lines_modified += 1
              table, = insert_table_and_columns(line)
              tables_affected << table if table && !tables_affected.include?(table)
            end
            writer.write(modified)
          end
        end
      ensure
        writer.close
      end
      File.rename(tmp, output_path)
      { success: true, error: nil, lines_processed: lines_processed, lines_modified: lines_modified, tables_affected: tables_affected, bytes_written: File.size(output_path) }
    rescue StandardError => e
      File.delete(tmp) if File.exist?(tmp)
      { success: false, error: e.message, lines_processed: lines_processed || 0, lines_modified: lines_modified || 0, tables_affected: tables_affected || [], bytes_written: 0 }
    end

    def rewrite_generated_insert(line, info)
      table, columns = insert_table_and_columns(line)
      return line unless table && info[:tables][table]

      indices = if columns
                  gen = info[:tables][table][:columns]
                  columns.each_index.select { |idx| gen.include?(columns[idx].downcase) }
                else
                  info[:tables][table][:column_indices].values.compact
                end
      rewrite_insert_values(line, indices)
    end

    def rewrite_insert_values(line, indices)
      return line if indices.empty?

      marker = line.match(/\)\s*VALUES\s*/i)
      if marker
        prefix = line[0...marker.end(0)]
        values = line[marker.end(0)..]
      elsif (marker = line.match(/\sVALUES\s*/i))
        prefix = line[0...marker.end(0)]
        values = line[marker.end(0)..]
      else
        return line
      end
      prefix + rewrite_values_tuples(values, indices)
    end

    def rewrite_values_tuples(values_part, indices)
      out = +""
      i = 0
      while i < values_part.length
        if values_part[i] == "("
          tuple, i = read_tuple(values_part, i)
          values = split_tuple_values(tuple[1...-1])
          indices.each { |idx| values[idx] = "DEFAULT" if idx < values.length }
          out << "(" << values.join(", ") << ")"
        else
          out << values_part[i]
          i += 1
        end
      end
      out
    end

    def read_tuple(text, start)
      i = start
      depth = 0
      quote = nil
      escaped = false
      out = +""
      while i < text.length
        ch = text[i]
        out << ch
        if escaped
          escaped = false
        elsif ch == "\\"
          escaped = true
        elsif quote
          quote = nil if ch == quote
        elsif ch == "'" || ch == '"'
          quote = ch
        elsif ch == "("
          depth += 1
        elsif ch == ")"
          depth -= 1
          return [out, i + 1] if depth.zero?
        end
        i += 1
      end
      [out, i]
    end

    def split_tuple_values(text)
      values = []
      current = +""
      depth = 0
      quote = nil
      escaped = false
      text.each_char do |ch|
        if escaped
          current << ch
          escaped = false
        elsif ch == "\\"
          current << ch
          escaped = true
        elsif quote
          current << ch
          quote = nil if ch == quote
        elsif ch == "'" || ch == '"'
          current << ch
          quote = ch
        elsif ch == "("
          current << ch
          depth += 1
        elsif ch == ")"
          current << ch
          depth -= 1
        elsif ch == "," && depth.zero?
          values << current.strip
          current = +""
        else
          current << ch
        end
      end
      values << current.strip
      values
    end

    def insert_table_and_columns(line)
      match = line.match(/INSERT\s+(?:IGNORE\s+)?INTO\s+(?:[`"]?(\w+)[`"]?\.)?[`"]?(\w+)[`"]?\s*(?:\(([^)]+)\))?\s+VALUES\s*/i)
      return nil unless match

      table = extract_table_name(match)
      columns = match[3]&.split(",")&.map { |col| col.strip.delete('`"') }
      [table, columns]
    end

    def extract_table_name(match)
      (match[2] || match[1]).downcase
    end

    def read_sample(path, sample_bytes)
      out = +""
      DumpTools.open_text(path) do |file|
        until file.eof? || out.bytesize >= sample_bytes
          out << (file.read([8192, sample_bytes - out.bytesize].min) || "")
        end
      end
      out
    end
  end
end
