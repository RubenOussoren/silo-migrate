# frozen_string_literal: true

require "digest"
require "rubygems/package"
require "zlib"
begin
  require "sqlite3"
rescue LoadError
  # Other CLI/converter modes need not inspect SQLite. Fail only when required.
end

module SiloMigrate
  module Services
    # Deterministic checks on importer output and full backups, shared by the
    # launcher-based legacy profile and the prebuilt standard workflow.
    module DiscourseArchive
      STANDARD_IMPORT_LOG_LIMIT = 65_536

      private

      def ensure_single_link_db!(path)
        raise UsageError, "Use an independent scratch DB copy, not a hardlink" unless File.stat(path).nlink == 1
      end

      def validate_processing_db!(path)
        raise UsageError, "SQLite3 is required to validate the processing database" unless defined?(SQLite3::Database)
        ensure_regular_file!(path, "Upload processing database is required; use --no-uploads-db only for an intentional no-upload migration.")
        ensure_single_link_db!(path)
        raise UsageError, "Processing database must be closed/checkpointed" if %w[-wal -shm].any? { |suffix| File.exist?("#{path}#{suffix}") }
        db = SQLite3::Database.new(path, readonly: true)
        bad = db.get_first_value("SELECT COUNT(*) FROM uploads WHERE upload IS NULL OR markdown IS NULL OR skip_reason IS NOT NULL OR skip_details IS NOT NULL")
        raise UsageError, "Upload processing contains errors or skips" unless bad == 0
        raise UsageError, "Processing database failed integrity check" unless db.get_first_value("PRAGMA quick_check") == "ok"
      rescue StandardError => error
        raise if error.is_a?(UsageError)
        raise UsageError, "Invalid upload processing database: #{error.class}"
      ensure
        db&.close
      end

      def validate_upload_member!(member)
        unless member.is_a?(String) && member.start_with?("uploads/") &&
               member.split("/").none? { |part| part.empty? || %w[. ..].include?(part) } && !member.match?(/[\x00-\x1f\\]/)
          raise UsageError, "Expected an exact safe uploads/ archive member"
        end
      end

      def validate_full_archive!(path, required_uploads)
        raise UsageError, "Empty full backup" unless File.size(path).positive?
        members = {}
        upload_hashes = {}
        Zlib::GzipReader.open(path) do |gzip|
          Gem::Package::TarReader.new(gzip) do |tar|
            tar.each do |entry|
              name = entry.full_name.delete_suffix("/")
              if name.empty? || name.start_with?("/") || name.split("/").any? { |part| part.empty? || %w[. ..].include?(part) } || name.match?(/[\x00-\x1f\\]/) || members.key?(name)
                raise UsageError, "Unsafe or duplicate backup archive member"
              end
              if entry.file?
                members[name] = entry.header.size
                if name == "dump.sql.gz"
                  dump = Zlib::GzipReader.new(entry)
                  dump_bytes = 0
                  until dump.eof?
                    dump_bytes += dump.read(64 * 1024).bytesize
                  end
                  dump.finish
                  raise UsageError, "Empty database dump" if dump_bytes.zero?
                else
                  digest = Digest::SHA256.new
                  read_bytes = 0
                  until entry.eof?
                    chunk = entry.read(64 * 1024)
                    raise UsageError, "Truncated backup member" if chunk.nil? || chunk.empty?
                    digest.update(chunk)
                    read_bytes += chunk.bytesize
                  end
                  raise UsageError, "Truncated backup member" unless read_bytes == entry.header.size
                  upload_hashes[name] = digest.hexdigest if name.start_with?("uploads/")
                end
              elsif entry.header.typeflag == "1" && members[entry.header.linkname].to_i.positive?
                members[name] = members.fetch(entry.header.linkname)
                upload_hashes[name] = upload_hashes[entry.header.linkname] if name.start_with?("uploads/")
              elsif entry.directory?
                next
              else
                raise UsageError, "Unsupported backup archive member (including PAX/links)"
              end
            end
          end
          gzip.read(64 * 1024) until gzip.eof? # Force gzip trailer/CRC verification.
        end
        unless members["dump.sql.gz"].to_i.positive? && members.any? { |name, bytes| name.start_with?("uploads/") && bytes.positive? }
          raise UsageError, "Backup must contain a DB dump and local uploads, not SQL-only"
        end
        unless required_uploads.all? { |name| members[name].to_i.positive? }
          raise UsageError, "Backup is missing required sandbox/source upload bytes"
        end
        { "sizes" => members, "upload_sha256" => upload_hashes }
      rescue Zlib::Error, Gem::Package::TarInvalidError, EOFError => error
        raise UsageError, "Invalid full backup archive: #{error.class}"
      end

      def assert_clean_import_output!(text)
        text = text.to_s
        unless text.bytesize <= STANDARD_IMPORT_LOG_LIMIT &&
               text.match?(/^Done! \(\d+ minutes\)$/) &&
               !text.match?(/Import issues \(|\bERROR:|\b[1-9]\d* (?:errors|skipped)\b/i)
          raise UsageError, "Standard import report is incomplete or contains errors/skips; destination remains dirty"
        end
      end

      def ensure_regular_file!(path, message)
        raise UsageError, message unless File.file?(path) && !File.symlink?(path)
      end
    end
  end
end
