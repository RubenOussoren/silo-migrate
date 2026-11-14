# frozen_string_literal: true

require "digest"
require "json"

# Private, engine-owned evidence for the canonical destination upload root. The
# caller must resolve the public/uploads symlink separately and fence writers.
# This is read-only: it never creates a missing root or repairs missing bytes.
# Only optimized/ is an engine-declared regenerable cache. Its regular files are
# counted, NOT byte-verified invariants; all other files (including emoji and
# root-level files) are originals regardless of their name or SQL references.
# Linux /proc/self/fd anchors traversal to opened, no-follow directories so a
# concurrent path replacement cannot redirect reads through a symlink. Identity
# and timestamp checks detect observed mutation; this is not a filesystem snapshot
# or a substitute for the parent's custody/locking guarantees. File counts
# include originals plus derivatives; directory traversal is separately capped
# at MAX_FILES to bound even trees containing only empty directories.
module SiloDiscourseBaselineAssets
  MAX_FILES = 100_000
  MAX_JSON = 64 * 1024 * 1024
  MAX_PATH_BYTES = 4096
  CHUNK_BYTES = 64 * 1024

  class Error < StandardError
    attr_reader :tag

    def initialize(tag)
      @tag = tag
      super(tag)
    end
  end

  class << self
    def capture(root)
      guarded do
        root!(root)
        anchors = []
        frames = []
        inventory = { "version" => 1, "files" => [], "derived_files" => 0 }
        json_bytes = JSON.generate(inventory).bytesize
        file_count = 0
        directory_count = 0
        begin
          # Keep every existing ancestor pinned until the capture completes.
          current = open_directory("/", anchors)
          root.split("/").reject(&:empty?).each do |part|
            path = "#{fd_path(current)}/#{part}"
            begin
              File.lstat(path)
            rescue Errno::ENOENT
              verify_directories!(anchors)
              return inventory
            end
            current = open_directory(path, anchors)
          end
          frames << frame(current, "")
          until frames.empty?
            top = frames.last
            name = top[:directory].read
            unless name
              verify_directory!(top[:anchor])
              top[:directory].close
              frames.pop
              # Ancestors of root remain open; walked subdirectories do not.
              top[:anchor][:io].close unless top[:relative].empty?
              next
            end
            next if name == "." || name == ".."
            relative = top[:relative].empty? ? name : "#{top[:relative]}/#{name}"
            relative!(relative)
            path = "#{fd_path(top[:anchor])}/#{name}"
            before = File.lstat(path)
            if before.directory?
              directory_count += 1
              refuse!("baseline_limit") if directory_count > MAX_FILES
              child = open_directory(path, nil, before)
              begin
                frames << frame(child, relative)
              rescue StandardError
                child[:io].close
                raise
              end
            elsif before.file?
              file_count += 1
              refuse!("baseline_limit") if file_count > MAX_FILES
              if relative.start_with?("optimized/")
                # Still reject unstable files and unsafe nodes in the cache.
                stable!(before, File.lstat(path))
                inventory["derived_files"] += 1
              else
                entry = hash_file(path, relative, before)
                json_bytes += JSON.generate(entry).bytesize + (inventory["files"].empty? ? 0 : 1)
                refuse!("baseline_limit") if json_bytes > MAX_JSON
                inventory["files"] << entry
              end
            else
              refuse!("baseline_unsafe_path")
            end
          end
          verify_directories!(anchors)
          inventory["files"].sort_by! { |entry| entry["path"] }
          validate!(inventory)
          inventory
        ensure
          frames.reverse_each do |item|
            item[:directory].close
            item[:anchor][:io].close unless item[:anchor][:io].closed?
          end
          anchors.reverse_each { |anchor| anchor[:io].close unless anchor[:io].closed? }
        end
      end
    end

    # Exact JSON-shaped schema. Ordering of caller-supplied files/keys is not
    # significant; digest always uses sorted paths and the fixed key order below.
    def validate!(inventory)
      guarded do
        exact_keys!(inventory, %w[version files derived_files])
        refuse!("baseline_invalid") unless inventory["version"].is_a?(Integer) && inventory["version"] == 1
        files, derived = inventory.values_at("files", "derived_files")
        refuse!("baseline_invalid") unless files.is_a?(Array) && derived.is_a?(Integer) && derived >= 0
        refuse!("baseline_limit") if files.size > MAX_FILES || derived > MAX_FILES || files.size + derived > MAX_FILES
        seen = {}
        json_bytes = JSON.generate("version" => 1, "files" => [], "derived_files" => derived).bytesize
        refuse!("baseline_limit") if json_bytes > MAX_JSON
        files.each_with_index do |entry, index|
          exact_keys!(entry, %w[path sha256 bytes])
          path, sha256, bytes = entry.values_at("path", "sha256", "bytes")
          relative!(path)
          refuse!("baseline_invalid") if path.start_with?("optimized/")
          refuse!("baseline_duplicate") if seen.key?(path)
          seen[path] = true
          refuse!("baseline_invalid") unless sha256.is_a?(String) && sha256.valid_encoding? && /\A[0-9a-f]{64}\z/.match?(sha256)
          refuse!("baseline_invalid") unless bytes.is_a?(Integer) && bytes >= 0
          # Bound pathological caller-supplied integer conversion as well as JSON.
          refuse!("baseline_limit") if bytes.bit_length > MAX_JSON * 4
          json_bytes += JSON.generate(canonical_entry(entry)).bytesize + (index.zero? ? 0 : 1)
          refuse!("baseline_limit") if json_bytes > MAX_JSON
        end
        # A regular file cannot simultaneously be a parent directory.
        seen.each_key do |path|
          parts = path.split("/")
          parts.pop
          until parts.empty?
            refuse!("baseline_collision") if seen.key?(parts.join("/"))
            parts.pop
          end
        end
        true
      end
    end

    def digest(inventory)
      guarded do
        validate!(inventory)
        sha = Digest::SHA256.new
        sha.update('{"version":1,"files":[')
        inventory["files"].sort_by { |entry| entry["path"] }.each_with_index do |entry, index|
          sha.update(",") unless index.zero?
          sha.update(JSON.generate(canonical_entry(entry)))
        end
        sha.update('],"derived_files":' + inventory["derived_files"].to_s + "}")
        sha.hexdigest
      end
    end

    private

    def canonical_entry(entry)
      { "path" => entry["path"], "sha256" => entry["sha256"], "bytes" => entry["bytes"] }
    end

    def root!(root)
      refuse!("baseline_unsafe_path") unless root.is_a?(String) && root.start_with?("/")
      relative!(root.delete_prefix("/"))
    end

    def relative!(path)
      refuse!("baseline_unsafe_path") unless path.is_a?(String) && path.bytesize.between?(1, MAX_PATH_BYTES) && path.valid_encoding?
      utf8 = path.dup.force_encoding(Encoding::UTF_8)
      refuse!("baseline_unsafe_path") unless utf8.valid_encoding? && !utf8.match?(/[\p{Cc}\\]/) && path.split("/", -1).none? { |part| part.empty? || part == "." || part == ".." }
    end

    def exact_keys!(value, keys)
      refuse!("baseline_invalid") unless value.is_a?(Hash) && value.size == keys.size && keys.all? { |key| value.key?(key) }
    end

    def signature(stat)
      [stat.dev, stat.ino, stat.mode, stat.size, stat.mtime, stat.ctime]
    end

    def stable!(before, after)
      refuse!("baseline_changed") unless signature(before) == signature(after)
    end

    def fd_path(anchor)
      "/proc/self/fd/#{anchor[:io].fileno}"
    end

    def open_directory(path, anchors, before = File.lstat(path))
      refuse!("baseline_unsafe_path") unless before.directory?
      io = File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
      begin
        stable!(before, io.stat)
        anchor = { io: io, path: path, before: before }
        anchors << anchor if anchors
        anchor
      rescue StandardError
        io.close
        raise
      end
    end

    def frame(anchor, relative)
      { anchor: anchor, relative: relative, directory: Dir.open(fd_path(anchor)) }
    end

    def verify_directory!(anchor)
      stable!(anchor[:before], anchor[:io].stat)
      stable!(anchor[:before], File.lstat(anchor[:path]))
    end

    def verify_directories!(anchors)
      anchors.reverse_each { |anchor| verify_directory!(anchor) }
    end

    def hash_file(path, relative, before)
      sha = Digest::SHA256.new
      count = 0
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        stable!(before, file.stat)
        while (chunk = file.read(CHUNK_BYTES))
          count += chunk.bytesize
          refuse!("baseline_changed") if count > before.size
          sha.update(chunk)
        end
        refuse!("baseline_changed") unless count == before.size
        stable!(before, file.stat)
      end
      stable!(before, File.lstat(path))
      { "path" => relative, "sha256" => sha.hexdigest, "bytes" => count }
    end

    def refuse!(tag)
      raise Error.new(tag), cause: nil
    end

    def guarded
      yield
    rescue Error
      raise
    rescue StandardError
      refuse!("baseline_io_failed")
    end
  end
end
