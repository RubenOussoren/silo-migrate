# frozen_string_literal: true

require "digest"
require "tempfile"

# Engine-neutral, private asset IO. Callers own evidence persistence and dirty-run
# handling: a later IO failure does NOT roll back earlier successful copies.
# Roots and ancestors must be privately controlled with no concurrent untrusted
# writers. Source roots must exist; destination roots must exist by default.
# Trusted callers may opt into missing destination creation only after preflight,
# and only for selected copies. The caller authorizes the exact destination and
# its missing suffix under a controlled ancestor; symlink mountpoints must be
# resolved by a trusted adapter first. Opt-in roots cannot contain '..' segments.
# This is not an openat-based sandbox.
# No manifest values, paths or underlying IO messages are exposed by Error.
# Count hashes use Symbol keys (:copied, :reused, :skipped_by_policy) and
# nonnegative Integer values. Counts are unique destination paths, not records:
# excluded paths also selected elsewhere are not counted as skipped. Preflight
# projects transfer counts; verify reports selected verified files as reused.
# All selected bytes must resolve (even optional entries); required exclusions
# are invalid. Existing equal-content destinations are reused without chmod;
# newly created files default to 0600 and directories to 0700. Trusted callers
# may request public-read 0644/0755 via transfer! options, never the manifest.
# No roots/directories are created during preflight. Error#counts is nil before
# transfer execution; during execution it snapshots completed copies/processed
# reuses and preflight-confirmed policy skips. It is partial evidence, not a
# completion or rollback receipt.
module SiloMergeAssets
  MAX_ENTRIES = 100_000
  MAX_KEY_BYTES = 1_024
  MAX_PATH_BYTES = 4_096
  MAX_BYTES = (2**63) - 1
  CHUNK_BYTES = 64 * 1_024
  FIELDS = %w[key source destination digest bytes disposition required].freeze

  class Error < StandardError
    attr_reader :tag, :counts

    def initialize(tag, counts: nil)
      @tag = tag
      @counts = counts&.dup&.freeze
      super(tag)
    end
  end

  class << self
    # Strict JSON-shaped schema; no coercion or unknown fields. Policy is a
    # binding supplied by the adapter, not a business-selection algorithm here.
    def validate!(manifest)
      exact_keys!(manifest, %w[version policy entries])
      refuse!("invalid_manifest") unless manifest["version"].is_a?(Integer) && manifest["version"] == 1
      refuse!("invalid_manifest") unless %w[carried all].include?(manifest["policy"])
      entries = manifest["entries"]
      refuse!("invalid_manifest") unless entries.is_a?(Array) && entries.size <= MAX_ENTRIES
      keys = {}
      destinations = {}
      entries.each do |entry|
        exact_keys!(entry, FIELDS)
        key = entry["key"]
        refuse!("invalid_manifest") unless bounded_string?(key, MAX_KEY_BYTES)
        refuse!("duplicate_key") if keys.key?(key)
        keys[key] = true
        relative!(entry["source"])
        relative!(entry["destination"])
        exact_keys!(entry["digest"], %w[algorithm value])
        algorithm, value = entry["digest"].values_at("algorithm", "value")
        length = { "sha1" => 40, "sha256" => 64 }[algorithm]
        refuse!("invalid_manifest") unless length && value.is_a?(String) && value.valid_encoding? && value.ascii_only? && value.bytesize == length && /\A[0-9a-fA-F]+\z/.match?(value)
        bytes = entry["bytes"]
        refuse!("invalid_manifest") unless bytes.is_a?(Integer) && bytes.between?(0, MAX_BYTES)
        refuse!("invalid_manifest") unless %w[copy reuse exclude].include?(entry["disposition"])
        refuse!("invalid_manifest") unless [true, false].include?(entry["required"])
        refuse!("required_excluded") if entry["required"] && entry["disposition"] == "exclude"
        # Exclusions never participate in destination IO or conflict resolution.
        next if entry["disposition"] == "exclude"
        identity = [algorithm, value.downcase, bytes]
        previous = destinations[entry["destination"]]
        refuse!("destination_conflict") if previous && previous != identity
        destinations[entry["destination"]] = identity
      end
      # A selected file cannot also be another selected file's parent.
      destinations.each_key do |path|
        parts = path.split("/")
        parts.pop
        until parts.empty?
          refuse!("destination_conflict") if destinations.key?(parts.join("/"))
          parts.pop
        end
      end
      true
    end

    # Performs all checks, including reading selected source/target bytes, before
    # any destination mutation. Counts are projected, not persisted evidence.
    def preflight!(manifest, source_root:, destination_root:, allow_missing_destination: false)
      guarded do
        _, counts = prepare(manifest, source_root, destination_root, allow_missing_destination)
        counts
      end
    end

    def transfer!(manifest, source_root:, destination_root:, file_mode: 0o600, directory_mode: 0o700, allow_missing_destination: false)
      guarded do
        refuse!("invalid_mode") unless file_mode.is_a?(Integer) && [0o600, 0o644].include?(file_mode)
        refuse!("invalid_mode") unless directory_mode.is_a?(Integer) && [0o700, 0o755].include?(directory_mode)
        actions, projected = prepare(manifest, source_root, destination_root, allow_missing_destination)
        progress = counts(0, 0, projected[:skipped_by_policy])
        begin
          actions.each do |entry, source, target|
            if source
              copy!(entry, source, target, destination_root, file_mode, directory_mode, allow_missing_destination)
              progress[:copied] += 1
            else
              progress[:reused] += 1
            end
          end
        rescue Error, SystemCallError, IOError => error
          tag = error.is_a?(Error) ? error.tag : "asset_io_failed"
          refuse!(tag, counts: progress)
        end
        progress
      end
    end

    # Verifies every selected destination, including reuse; excluded paths are
    # never inspected. Returns physical counts, all verified files as reused.
    def verify!(manifest, destination_root:)
      guarded do
        validate!(manifest)
        root = root!(destination_root)
        selected, skipped = groups(manifest)
        selected.each_value do |entries|
          entry = entries.first
          target = contained!(root, entry["destination"])
          refuse!("missing_destination") unless target
          verify_file!(target, entry)
        end
        counts(0, selected.size, skipped)
      end
    end

    private

    def refuse!(tag, counts: nil)
      raise Error.new(tag, counts: counts), cause: nil
    end

    def guarded
      yield
    rescue SystemCallError, IOError
      refuse!("asset_io_failed")
    end

    def bounded_string?(value, maximum)
      value.is_a?(String) && value.valid_encoding? && value.encoding.ascii_compatible? && value.bytesize.between?(1, maximum)
    end

    def exact_keys!(value, fields)
      refuse!("invalid_manifest") unless value.is_a?(Hash) && value.size == fields.size && fields.all? { |field| value.key?(field) }
    end

    def relative!(path)
      refuse!("unsafe_path") unless bounded_string?(path, MAX_PATH_BYTES)
      refuse!("unsafe_path") if path.match?(/[\x00-\x1f\x7f\\]/) || path.start_with?("/") || path.match?(/\A[A-Za-z]:/)
      refuse!("unsafe_path") if path.split("/", -1).any? { |part| part.empty? || part == "." || part == ".." }
    end

    # lstat every existing component, including ancestors of the root. A trusted
    # caller may allow a missing suffix; this method never creates directories.
    def root!(root, allow_missing: false)
      refuse!("unsafe_root") unless bounded_string?(root, MAX_PATH_BYTES)
      refuse!("unsafe_root") if root.match?(/[\x00-\x1f\x7f\\]/)
      refuse!("unsafe_root") if allow_missing && root.split("/").include?("..")
      absolute = File.expand_path(root)
      current = File::SEPARATOR
      absolute.split(File::SEPARATOR).reject(&:empty?).each do |part|
        current = File.join(current, part)
        begin
          stat = File.lstat(current)
        rescue Errno::ENOENT
          raise unless allow_missing
          return absolute
        end
        refuse!("unsafe_file") unless stat.directory? && !stat.symlink?
      end
      absolute
    end

    def contained!(root, relative)
      current = root
      parts = relative.split("/")
      parts.each_with_index do |part, index|
        current = File.join(current, part)
        begin
          stat = File.lstat(current)
        rescue Errno::ENOENT
          return nil
        end
        refuse!("unsafe_file") if stat.symlink?
        if index == parts.length - 1
          refuse!("unsafe_file") unless stat.file?
        else
          refuse!("unsafe_file") unless stat.directory?
        end
      end
      current
    end

    def groups(manifest)
      selected = {}
      excluded = {}
      manifest["entries"].each do |entry|
        path = entry["destination"]
        if entry["disposition"] == "exclude"
          excluded[path] = true
        else
          (selected[path] ||= []) << entry
        end
      end
      [selected, (excluded.keys - selected.keys).size]
    end

    def counts(copied, reused, skipped)
      { copied: copied, reused: reused, skipped_by_policy: skipped }
    end

    def prepare(manifest, source_root, destination_root, allow_missing_destination)
      refuse!("invalid_option") unless allow_missing_destination.equal?(true) || allow_missing_destination.equal?(false)
      validate!(manifest)
      source_root = root!(source_root)
      destination_root = root!(destination_root, allow_missing: allow_missing_destination)
      selected, skipped = groups(manifest)
      actions = []
      copied = reused = 0
      selected.each_value do |entries|
        entry = entries.first
        target = contained!(destination_root, entry["destination"])
        if target
          verify_file!(target, entry)
          actions << [entry, nil, target]
          reused += 1
        else
          # Explicit reuse must independently resolve to existing verified bytes.
          refuse!("missing_destination") if entries.any? { |item| item["disposition"] == "reuse" }
          source = nil
          entries.each do |item|
            candidate = contained!(source_root, item["source"])
            next unless candidate
            verify_file!(candidate, item)
            source ||= candidate
          end
          refuse!("missing_source") unless source
          actions << [entry, source, File.join(destination_root, entry["destination"])]
          copied += 1
        end
      end
      [actions, counts(copied, reused, skipped)]
    end

    def digest_for(entry)
      entry["digest"]["algorithm"] == "sha1" ? Digest::SHA1.new : Digest::SHA256.new
    end

    # Bounded to declared bytes + one byte even for a growing or oversized file.
    def stream!(input, entry, output = nil)
      digest = digest_for(entry)
      total = 0
      while (chunk = input.read([CHUNK_BYTES, entry["bytes"] - total + 1].min))
        total += chunk.bytesize
        refuse!("content_mismatch") if total > entry["bytes"]
        digest.update(chunk)
        output.write(chunk) if output
      end
      refuse!("content_mismatch") unless total == entry["bytes"] && digest.hexdigest == entry["digest"]["value"].downcase
    end

    def verify_file!(path, entry)
      File.open(path, "rb") do |input|
        refuse!("unsafe_file") unless input.stat.file?
        refuse!("content_mismatch") unless input.stat.size == entry["bytes"]
        stream!(input, entry)
      end
    end

    # Only called while executing a preflighted copy, on its absolute parent.
    # No broad chmod: preserve every directory already present, including roots.
    def create_directories!(absolute, mode)
      current = File::SEPARATOR
      absolute.split(File::SEPARATOR).reject(&:empty?).each do |part|
        current = File.join(current, part)
        created = false
        begin
          stat = File.lstat(current)
        rescue Errno::ENOENT
          Dir.mkdir(current, mode)
          created = true
          stat = File.lstat(current)
        end
        refuse!("unsafe_file") unless stat.directory? && !stat.symlink?
        File.chmod(mode, current) if created
      end
    end

    def copy!(entry, source, target, destination_root, file_mode, directory_mode, allow_missing_destination)
      root = root!(destination_root, allow_missing: allow_missing_destination)
      # Recheck paths after preflight. Trusted-root custody remains essential.
      existing = contained!(root, entry["destination"])
      refuse!("destination_changed") if existing
      parent = File.dirname(target)
      create_directories!(parent, directory_mode)
      temporary = Tempfile.new([".silo-asset-", ".tmp"], parent, binmode: true)
      begin
        temporary.chmod(0o600)
        root!(File.dirname(source))
        source_stat = File.lstat(source)
        refuse!("unsafe_file") unless source_stat.file? && !source_stat.symlink?
        File.open(source, "rb") do |input|
          refuse!("unsafe_file") unless input.stat.file?
          stream!(input, entry, temporary)
        end
        temporary.flush
        # Remain private throughout streaming; publish the final mode atomically
        # with the verified bytes at rename, never chmod an existing target.
        temporary.chmod(file_mode)
        temporary.fsync
        temporary.close
        refuse!("destination_changed") if File.exist?(target) || File.symlink?(target)
        File.rename(temporary.path, target)
      ensure
        temporary.close!
      end
    end
  end
end
