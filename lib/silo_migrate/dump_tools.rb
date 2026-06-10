# frozen_string_literal: true

require "fileutils"
require "zlib"
require "rubygems/package"
require "stringio"

module SiloMigrate
  module DumpTools
    GZIP_COMPRESSION_RATIO_ESTIMATE = 5
    SQL_INDICATORS = ["--", "/*", "CREATE ", "DROP ", "INSERT ", "SET ", "USE ", "START ", "BEGIN ", "LOCK "].freeze
    MACOS_METADATA_FILES = [".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd"].freeze

    module_function

    def format_size(size)
      size = size.to_i
      return format("%.1f GB", size / 1024.0 / 1024.0 / 1024.0) if size >= 1024 * 1024 * 1024
      return format("%.1f MB", size / 1024.0 / 1024.0) if size >= 1024 * 1024
      return format("%.1f KB", size / 1024.0) if size >= 1024

      "#{size} B"
    end

    def format_elapsed(seconds)
      seconds = seconds.to_i
      hours = seconds / 3600
      minutes = (seconds % 3600) / 60
      remaining_seconds = seconds % 60

      return format("%dh %02dm %02ds", hours, minutes, remaining_seconds) if hours.positive?
      return format("%dm %02ds", minutes, remaining_seconds) if minutes.positive?

      "#{remaining_seconds}s"
    end

    def gzip_file?(path)
      File.extname(path.to_s).downcase == ".gz"
    end

    # Quick mode decompresses the first ~1 MB (catches header/stream corruption).
    # Full mode streams to EOF so Zlib validates the trailing CRC32/length,
    # which catches truncated transfers before a multi-GB import starts.
    def verify_gzip(path, full: false)
      magic = File.open(path, "rb") { |f| f.read(2) }
      return { valid: false, message: "not a gzip file (bad magic bytes)" } unless magic == "\x1F\x8B".b

      if full
        Zlib::GzipReader.open(path.to_s) do |gz|
          nil while gz.read(1024 * 1024)
        end
        { valid: true, message: "gzip integrity verified" }
      else
        # A raw Inflate probe avoids GzipReader's unfinished-zstream warning
        # when we intentionally stop after the first compressed megabyte.
        inflater = Zlib::Inflate.new(32 + Zlib::MAX_WBITS)
        File.open(path, "rb") { |file| inflater.inflate(file.read(1024 * 1024)) }
        { valid: true, message: "gzip header and first block OK" }
      end
    rescue Zlib::Error, EOFError => e
      { valid: false, message: "#{e.class}: #{e.message}" }
    ensure
      inflater&.end if defined?(inflater)
    end

    def open_text(path, &block)
      if gzip_file?(path)
        Zlib::GzipReader.open(path.to_s) do |gz|
          gz.set_encoding("UTF-8", invalid: :replace, undef: :replace) if gz.respond_to?(:set_encoding)
          block.call(gz)
        end
      else
        File.open(path, "r:utf-8", invalid: :replace, undef: :replace, &block)
      end
    end

    def detect_file_format(path)
      result = { format: "unknown", is_valid: false, message: "", sql_files: [] }
      header = File.open(path, "rb") { |f| f.read(512) } || ""
      if header.bytesize < 2
        result[:message] = "File is too small to be a valid dump"
        return result
      end

      if header.byteslice(0, 2) == "\x1F\x8B".b
        return result.merge(format: "gzip", is_valid: true, message: "Gzip compressed file")
      end

      if tar_header?(header)
        sql_files = tar_sql_files(path)
        if sql_files.any?
          return result.merge(format: "tar", is_valid: true, message: "Tar archive containing #{sql_files.length} SQL file(s)", sql_files: sql_files)
        end
        return result.merge(format: "tar", is_valid: false, message: "Tar archive but no SQL files found inside")
      end

      text = header.force_encoding("UTF-8")
      if text.valid_encoding?
        stripped = text.lstrip.upcase
        if SQL_INDICATORS.any? { |indicator| stripped.start_with?(indicator) }
          return result.merge(format: "sql", is_valid: true, message: "Plain SQL dump file")
        end

        printable = text.each_char.count { |c| c.match?(/[[:print:]\n\r\t]/) }
        return result.merge(format: "sql", is_valid: true, message: "Text file (possibly SQL)") if printable.to_f / [text.length, 1].max > 0.95
      end

      result.merge(message: "Unknown binary format - not a valid SQL dump")
    rescue StandardError => e
      result.merge(message: "Could not read file: #{e.message}")
    end

    def tar_header?(header)
      return true if header.bytesize >= 262 && header.byteslice(257, 5) == "ustar"

      first_hundred = header.byteslice(0, 100) || ""
      null_pos = first_hundred.index("\x00")
      null_pos && null_pos.positive? && null_pos < 100 && first_hundred.byteslice(null_pos, 100).count("\x00") > 50
    end

    def tar_sql_files(path)
      files = []
      File.open(path, "rb") do |io|
        Gem::Package::TarReader.new(io) do |tar|
          tar.each do |entry|
            next unless entry.file?

            basename = File.basename(entry.full_name.sub(%r{/+\z}, ""))
            next if basename.start_with?("._") || MACOS_METADATA_FILES.include?(basename)
            next unless entry.full_name.end_with?(".sql", ".sql.gz")

            files << { name: entry.full_name, size: entry.header.size }
          end
        end
      end
      files
    rescue Gem::Package::TarInvalidError, Zlib::GzipFile::Error
      []
    end

    def extract_sql_from_tar(tar_path, output_dir, sql_filename = nil)
      FileUtils.mkdir_p(output_dir)
      target = nil
      File.open(tar_path, "rb") do |io|
        Gem::Package::TarReader.new(io) do |tar|
          tar.each do |entry|
            next unless entry.file?

            basename = File.basename(entry.full_name)
            next unless entry.full_name.end_with?(".sql", ".sql.gz")
            next if basename.start_with?("._") || MACOS_METADATA_FILES.include?(basename)
            next if sql_filename && entry.full_name != sql_filename && basename != sql_filename

            target = File.join(output_dir, basename)
            raise UsageError, "Invalid filename in archive: #{entry.full_name}" unless File.expand_path(target).start_with?(File.expand_path(output_dir))

            File.open(target, "wb") { |out| IO.copy_stream(entry, out) }
            break
          end
        end
      end
      target
    end

    def estimate_import_time(size)
      minutes = size.to_f / 1024 / 1024 / 50
      return "< 1 minute" if minutes < 1
      return "#{minutes.to_i}-#{(minutes * 1.5).to_i} minutes" if minutes < 60

      hours = minutes / 60
      format("%.1f-%.1f hours", hours, hours * 1.5)
    end
  end
end
