# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "tempfile"
require "time"

module SiloMigrate
  class ReleaseError < UsageError; end

  # Private, operator-owned state. This is not an authorization sandbox against
  # malicious administrators or concurrently replaced filesystem components.
  class ReleaseStore
    VERSION = 1
    MAX_BYTES = 16 * 1024 * 1024
    MAX_ARTIFACTS = 128
    MAX_STATE_BYTES = 8 * 1024 * 1024
    MAX_TOTAL_BYTES = 64 * 1024 * 1024
    CLASSES = { "schema" => "sql", "log" => "log", "summary" => "json", "finding" => "yml", "fixture" => "yml" }.freeze
    ID_PATTERN = /\Aartifact-[0-9a-f]{32}\z/
    DIGEST_PATTERN = /\A[0-9a-f]{64}\z/
    ROOT = ".silo-migrate/releases"

    attr_reader :project_path, :nominal_path

    def initialize(customer, env: ENV)
      unless customer.is_a?(String) && CUSTOMER_NAME_PATTERN.match?(customer)
        raise ReleaseError, "RELEASE_WORKSPACE_INVALID"
      end
      @nominal_path = File.expand_path(Project.project_path(customer, env))
      raise ReleaseError, "RELEASE_WORKSPACE_INVALID" if File.symlink?(@nominal_path)

      @project_path = File.realpath(@nominal_path)
      regular_path("config.env")
    end

    def with_lock
      directory(ROOT, create: true)
      File.chmod(0o700, path(ROOT))
      lock_path = path("#{ROOT}/lock", missing: true)
      File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        raise ReleaseError, "RELEASE_PATH_INVALID" unless lock.stat.file? && lock.stat.nlink == 1

        lock.flock(File::LOCK_EX)
        begin
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
    end

    def load
      state_path = path("#{ROOT}/state.json", missing: true)
      unless File.exist?(state_path)
        state = {
          "version" => VERSION, "workspace_id" => "workspace-#{SecureRandom.hex(16)}",
          "root_digest" => Digest::SHA256.hexdigest(project_path), "generation" => 0,
          "publication" => "absent", "published_ids" => [], "artifacts" => {}
        }
        save(state)
        return state
      end
      state = JSON.parse(read_regular(state_path, max: MAX_STATE_BYTES))
      validate!(state)
      state
    end

    def save(state)
      validate!(state)
      serialized = JSON.pretty_generate(state) + "\n"
      raise ReleaseError, "RELEASE_SIZE_LIMIT" if serialized.bytesize > MAX_STATE_BYTES

      write_atomic("#{ROOT}/state.json", serialized)
    end

    def validate!(state)
      exact_keys!(state, %w[version workspace_id root_digest generation publication published_ids artifacts])
      valid = state["version"] == VERSION && state["workspace_id"].is_a?(String) &&
        /\Aworkspace-[0-9a-f]{32}\z/.match?(state["workspace_id"]) &&
        state["root_digest"] == Digest::SHA256.hexdigest(project_path) &&
        state["generation"].is_a?(Integer) && state["generation"] >= 0 &&
        %w[absent publishing published blocked].include?(state["publication"]) &&
        state["artifacts"].is_a?(Hash) && state["artifacts"].size <= MAX_ARTIFACTS &&
        state["published_ids"].is_a?(Array) && state["published_ids"].uniq.size == state["published_ids"].size &&
        state["published_ids"].all? { |id| valid_id?(id) && state["artifacts"].key?(id) }
      raise ReleaseError, "RELEASE_STATE_INVALID" unless valid

      state.fetch("artifacts").each do |id, record|
        exact_keys!(record, %w[id workspace_id class sha256 bytes state approval source])
        valid = valid_id?(id) && record["id"] == id && record["workspace_id"] == state["workspace_id"] &&
          CLASSES.key?(record["class"]) && valid_digest?(record["sha256"]) &&
          record["bytes"].is_a?(Integer) && record["bytes"].between?(0, MAX_BYTES) &&
          %w[candidate approved revoked].include?(record["state"]) && text?(record["source"])
        raise ReleaseError, "RELEASE_STATE_INVALID" unless valid

        approval = record["approval"]
        if approval
          exact_keys!(approval, %w[id workspace_id class sha256 bytes reviewed reviewer notes approved_at])
          valid = %w[id workspace_id class sha256 bytes].all? { |key| approval[key] == record[key] } &&
            approval["reviewed"] == true && reviewer_text?(approval["reviewer"]) &&
            (approval["notes"].nil? || text?(approval["notes"])) && text?(approval["approved_at"])
          raise ReleaseError, "RELEASE_APPROVAL_INVALID" unless valid
        end
        if (record["state"] == "approved" && !approval) || (record["state"] == "candidate" && approval)
          raise ReleaseError, "RELEASE_APPROVAL_INVALID"
        end
      end
      if state["publication"] == "published" && state["published_ids"].any? { |id| state["artifacts"][id]["state"] != "approved" }
        raise ReleaseError, "RELEASE_STATE_INVALID"
      end
      state
    end

    def descriptor(record)
      record.slice("id", "class", "sha256", "bytes", "state")
    end

    def valid_id?(id)
      id.is_a?(String) && ID_PATTERN.match?(id)
    end

    def valid_digest?(digest)
      digest.is_a?(String) && DIGEST_PATTERN.match?(digest)
    end

    def text?(value)
      value.is_a?(String) && value.valid_encoding? && value.bytesize <= 4096 && !value.include?("\0")
    end

    def reviewer_text?(value)
      text?(value) && !value.strip.empty? && value.bytesize <= 256 && !value.match?(/[[:cntrl:]]/)
    end

    def snapshot(id)
      raise ReleaseError, "RELEASE_ID_INVALID" unless valid_id?(id)

      "#{ROOT}/snapshots/#{id}.bin"
    end

    def source_path(source)
      raise ReleaseError, "RELEASE_SOURCE_INVALID" unless text?(source) && !source.split("/").include?("..")

      expanded = File.expand_path(source, project_path)
      if expanded.start_with?(nominal_path + File::SEPARATOR)
        expanded = File.join(project_path, expanded.delete_prefix(nominal_path + File::SEPARATOR))
      end
      relative = expanded.delete_prefix(project_path + File::SEPARATOR)
      unless %w[schema findings synthetic-fixtures].any? { |root| relative.start_with?(root + "/") }
        raise ReleaseError, "RELEASE_SOURCE_INVALID"
      end
      regular_path(relative)
    end

    def path(relative, missing: false)
      expanded = File.expand_path(relative, project_path)
      prefix = project_path + File::SEPARATOR
      raise ReleaseError, "RELEASE_PATH_INVALID" unless expanded.start_with?(prefix)

      current = project_path
      parts = expanded.delete_prefix(prefix).split(File::SEPARATOR)
      parts.each_with_index do |part, index|
        current = File.join(current, part)
        begin
          stat = File.lstat(current)
          raise ReleaseError, "RELEASE_PATH_INVALID" if stat.symlink?
          unless index == parts.length - 1
            raise ReleaseError, "RELEASE_PATH_INVALID" unless stat.directory?
          end
        rescue Errno::ENOENT
          raise ReleaseError, "RELEASE_PATH_MISSING" unless missing && index == parts.length - 1
        end
      end
      expanded
    end

    def regular_path(relative)
      candidate = path(relative)
      stat = File.lstat(candidate)
      raise ReleaseError, "RELEASE_PATH_INVALID" unless stat.file? && stat.nlink == 1

      candidate
    end

    def directory(relative, create: false)
      current = ""
      relative.split("/").each do |part|
        current = current.empty? ? part : "#{current}/#{part}"
        candidate = path(current, missing: create)
        Dir.mkdir(candidate, 0o700) if create && !File.exist?(candidate)
        raise ReleaseError, "RELEASE_PATH_INVALID" unless File.directory?(candidate)
      end
      path(relative)
    end

    def read_regular(candidate, max: MAX_BYTES)
      relative = candidate.delete_prefix(project_path + File::SEPARATOR)
      regular_path(relative)
      File.open(candidate, File::RDONLY | File::NOFOLLOW) do |file|
        stat = file.stat
        raise ReleaseError, "RELEASE_PATH_INVALID" unless stat.file? && stat.nlink == 1
        raise ReleaseError, "RELEASE_SIZE_LIMIT" if stat.size > max

        content = file.read(max + 1) || "".b
        raise ReleaseError, "RELEASE_SIZE_LIMIT" if content.bytesize > max

        content
      end
    end

    def write_atomic(relative, content, mode: 0o600, replace: true)
      directory(File.dirname(relative), create: true)
      target = path(relative, missing: true)
      regular_path(relative) if File.exist?(target)
      staged = Tempfile.create([".release-", ".tmp"], File.dirname(target))
      begin
        staged.binmode
        staged.write(content)
        staged.flush
        staged.chmod(mode)
        staged.fsync
        staged.close
        replace ? File.rename(staged.path, target) : File.link(staged.path, target)
        sync_directory(File.dirname(target))
      ensure
        primary = $!
        begin
          staged.close unless staged.closed?
        rescue SystemCallError, IOError => error
          raise error unless primary
        ensure
          File.unlink(staged.path) if File.exist?(staged.path)
        end
      end
      target
    end

    def sync_directory(candidate)
      File.open(candidate, File::RDONLY) { |dir| dir.fsync }
    end

    private

    def exact_keys!(object, keys)
      unless object.is_a?(Hash) && object.keys.sort == keys.sort
        raise ReleaseError, "RELEASE_STATE_INVALID"
      end
    end
  end
end
