# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "tempfile"
require_relative "errors"

module SiloMigrate
  class NamedError < UsageError; end

  # Private operator-owned registry, not a sandbox against hostile administrators.
  # All callers (including init and explicit recovery) use the same lock.
  class NamedWorkspaceStore
    VERSION = 1
    ROOT = ".silo-migrate/named"
    # Real exports: a forum SQL dump is hundreds of MB and uploads can be many GB. Disk
    # capacity is checked when a run is admitted; these only stop absurd registrations.
    MAX_BYTES = 64 * 1024 * 1024 * 1024
    MAX_TOTAL_BYTES = 256 * 1024 * 1024 * 1024
    MAX_STATE_BYTES = 1024 * 1024
    MAX_RECORDS = 128
    MAX_METADATA_BYTES = 1024
    KINDS = %w[sources datasets inputs plans runs].freeze
    PREFIXES = %w[source dataset input plan run].freeze
    STATUSES = %w[planned running completed failed interrupted].freeze
    INPUT_FAILURE_CODES = %w[NAMED_INPUT_CHANGED NAMED_PATH_INVALID NAMED_SIZE_LIMIT NAMED_IO_ERROR].freeze
    CODES = %w[NAMED_BUSY NAMED_WORKSPACE_INVALID NAMED_MODE_CONFLICT NAMED_NOT_INITIALIZED NAMED_ALREADY_INITIALIZED NAMED_PATH_INVALID NAMED_STATE_INVALID NAMED_SIZE_LIMIT NAMED_ARGUMENT_INVALID NAMED_REFERENCE_INVALID NAMED_STALE_PLAN NAMED_TRANSITION_INVALID NAMED_INPUT_CHANGED NAMED_IO_ERROR].freeze

    attr_reader :root

    def self.error!(code)
      raise NamedError, code, cause: nil
    end

    def self.boundary
      yield
    rescue NamedError => e
      error!(CODES.include?(e.message) ? e.message : "NAMED_IO_ERROR")
    rescue StandardError
      error!("NAMED_IO_ERROR")
    end

    def initialize(workspace, env: ENV)
      self.class.boundary do
        unless workspace.is_a?(String) && workspace.valid_encoding? && /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/.match?(workspace)
          fail!("NAMED_WORKSPACE_INVALID")
        end
        @root = File.expand_path(File.join(Project.base_path(env), workspace))
      end
    end

    def fail!(code)
      self.class.error!(code)
    end

    def with_lock(create: false)
      self.class.boundary do
        if create
          @created_base_parents = []
          ancestor = File.dirname(root)
          until File.exist?(ancestor) || File.symlink?(ancestor)
            @created_base_parents << File.dirname(ancestor)
            ancestor = File.dirname(ancestor)
          end
          FileUtils.mkdir_p(File.dirname(root), mode: 0o700)
          directory_absolute!(File.dirname(root))
          Dir.mkdir(root, 0o700) unless File.exist?(root) || File.symlink?(root)
        end
        unless create
          fail!("NAMED_NOT_INITIALIZED") unless File.exist?(root) || File.symlink?(root)
        end
        directory_absolute!(root)
        reject_legacy!
        unless create
          marker = File.join(root, ROOT)
          fail!("NAMED_NOT_INITIALIZED") unless File.exist?(marker) || File.symlink?(marker)
        end
        if create && !(File.exist?(File.join(root, ROOT)) || File.symlink?(File.join(root, ROOT)))
          # Refuse unrelated content before leaving a named-mode marker behind.
          fail!("NAMED_MODE_CONFLICT") unless Dir.children(root).empty?
        end
        directory!(".silo-migrate", create: create)
        directory!(ROOT, create: create, private: true)
        lock_path = File.join(root, ROOT, "lock")
        File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
          regular!(lock.stat, private: true)
          fail!("NAMED_BUSY") unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          begin
            verify_lock!(lock, lock_path)
            reject_legacy!
            yield self
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      end
    end

    def reject_legacy!
      %w[config.env .silo-migrate/workflow.json .silo-migrate/workflow.lock .silo-migrate/releases].each do |name|
        p = File.join(root, name)
        fail!("NAMED_MODE_CONFLICT") if File.exist?(p) || File.symlink?(p)
      end
    end

    def init!
      p = File.join(root, ROOT, "state.json")
      fail!("NAMED_ALREADY_INITIALIZED") if File.exist?(p) || File.symlink?(p)
      # A fresh opt-in must not adopt unrelated existing workspace contents.
      fail!("NAMED_MODE_CONFLICT") unless (Dir.children(root) - [".silo-migrate", "inputs"]).empty?
      fail!("NAMED_MODE_CONFLICT") unless (Dir.children(File.join(root, ".silo-migrate")) - ["named"]).empty?
      fail!("NAMED_MODE_CONFLICT") unless (Dir.children(File.join(root, ROOT)) - ["lock"]).empty?
      # Retry only a never-initialized empty private input area. Unknown named
      # files (including crash-left .state temps) require manual operator recovery;
      # no cleanup, adoption of contents, or deletion is performed here.
      directory!("inputs", create: true, private: true)
      fail!("NAMED_MODE_CONFLICT") unless Dir.children(File.join(root, "inputs")).empty?
      state = { "version" => VERSION, "workspace_id" => new_id("workspace"),
                "root_digest" => root_digest, "generation" => 0 }
      KINDS.each { |kind| state[kind] = {} }
      save(state)
      sync_init_directories!
      state
    end

    def load
      p = File.join(root, ROOT, "state.json")
      fail!("NAMED_NOT_INITIALIZED") unless File.exist?(p) || File.symlink?(p)
      data = read_file(p, MAX_STATE_BYTES, private: true)
      fail!("NAMED_STATE_INVALID") if data.nil? || data.empty?
      state = JSON.parse(data)
      validate!(state)
      state
    rescue JSON::ParserError, EncodingError
      fail!("NAMED_STATE_INVALID")
    end

    def save(state)
      validate!(state)
      bytes = JSON.generate(state)
      fail!("NAMED_SIZE_LIMIT") if reserved_state_bytes(state, serialized: bytes) > MAX_STATE_BYTES
      temp = Tempfile.new([".state-", ".tmp"], File.join(root, ROOT))
      begin
        temp.binmode
        temp.chmod(0o600)
        temp.write(bytes)
        temp.flush
        temp.fsync
        temp.close
        File.rename(temp.path, File.join(root, ROOT, "state.json"))
        File.open(File.join(root, ROOT)) { |dir| dir.fsync }
      ensure
        temp.close!
      end
      state
    end

    # Reserve the largest possible representation of each nonterminal run at
    # planning time, not at running time. Registry growth cannot consume the
    # bytes needed to persist any already accepted attempt's final outcome.
    def reserved_state_bytes(state, serialized: JSON.generate(state))
      serialized.bytesize + state.fetch("runs").values.sum do |run|
        next 0 unless %w[planned running].include?(run["status"])

        attempt = run.merge("attempt_id" => "attempt-#{'f' * 32}")
        outcomes = {
          "completed" => { "code" => "NAMED_OK", "input_count" => MAX_RECORDS, "bytes" => MAX_TOTAL_BYTES },
          "interrupted" => { "code" => "NAMED_INTERRUPTED", "input_count" => 0, "bytes" => 0 },
          "failed" => { "code" => "NAMED_VALIDATION_FAILED", "input_count" => 0, "bytes" => 0,
                        "failed_input_id" => "input-#{'f' * 32}", "reason" => INPUT_FAILURE_CODES.max_by(&:bytesize) }
        }
        actual_bytes = JSON.generate(run).bytesize
        variants = [actual_bytes, JSON.generate(attempt.merge("status" => "running")).bytesize]
        outcomes.each { |status, outcome| variants << JSON.generate(attempt.merge("status" => status, "outcome" => outcome)).bytesize }
        variants.max - actual_bytes
      end
    end

    def new_id(prefix)
      "#{prefix}-#{SecureRandom.hex(16)}"
    end

    def insert!(state, kind, record)
      fail!("NAMED_SIZE_LIMIT") if state.fetch(kind).size >= MAX_RECORDS
      fail!("NAMED_STATE_INVALID") if state.fetch(kind).key?(record.fetch("id"))
      state.fetch(kind)[record.fetch("id")] = record
    end

    def metadata(value, optional: false)
      return nil if value.nil? && optional
      fail!("NAMED_ARGUMENT_INVALID") unless value.is_a?(String) && value.bytesize.between?(1, MAX_METADATA_BYTES)
      [value.b].pack("m0")
    end

    def record!(state, kind, id)
      fail!("NAMED_REFERENCE_INVALID") unless id.is_a?(String) && state.fetch(kind).key?(id)
      state.fetch(kind).fetch(id)
    end

    def input_path(value)
      fail!("NAMED_PATH_INVALID") unless value.is_a?(String) && value.bytesize <= MAX_METADATA_BYTES && !value.include?("\0")
      parts = value.b.split("/", -1)
      fail!("NAMED_PATH_INVALID") unless parts.size >= 2 && parts.first == "inputs" && parts.all? { |part| !["", ".", ".."].include?(part) }
      parts[0...-1].each_index { |index| directory!(parts[0..index].join("/")) }
      File.join(root.b, value.b)
    end

    def identity(stat)
      { "dev" => stat.dev, "ino" => stat.ino, "size" => stat.size,
        "mtime" => [stat.mtime.to_i, stat.mtime.nsec], "ctime" => [stat.ctime.to_i, stat.ctime.nsec] }
    end

    def inspect_input(path, sha256:, bytes:, expected: nil)
      full = input_path(path)
      File.open(full, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        regular!(file.stat)
        before = identity(file.stat)
        fail!("NAMED_INPUT_CHANGED") unless before["size"] == bytes && (!expected || before == expected)
        digest = Digest::SHA256.new
        count = 0
        while (chunk = file.read(64 * 1024))
          count += chunk.bytesize
          fail!("NAMED_SIZE_LIMIT") if count > MAX_BYTES || count > bytes
          digest.update(chunk)
        end
        regular!(File.lstat(full))
        after = identity(file.stat)
        fail!("NAMED_INPUT_CHANGED") unless before == after && after == identity(File.lstat(full)) && count == bytes && digest.hexdigest == sha256
        before
      end
    rescue Errno::ENOENT, Errno::ELOOP
      fail!("NAMED_INPUT_CHANGED")
    end

    def verify_input_identity(input)
      full = input_path(input.fetch("path").unpack1("m0"))
      stat = File.lstat(full)
      regular!(stat)
      fail!("NAMED_INPUT_CHANGED") unless identity(stat) == input.fetch("identity")
    rescue Errno::ENOENT, Errno::ELOOP
      fail!("NAMED_INPUT_CHANGED")
    end

    # Canonical binding over all immutable private input records, independent of
    # JSON object key order. This pins exact IDs, metadata and stat identities.
    def input_binding(state, ids)
      canonical = lambda do |value|
        case value
        when Hash then value.keys.sort.to_h { |key| [key, canonical.call(value.fetch(key))] }
        when Array then value.map { |item| canonical.call(item) }
        else value
        end
      end
      Digest::SHA256.hexdigest(JSON.generate(canonical.call(ids.map { |id| state.fetch("inputs").fetch(id) })))
    end

    def validate!(s)
      keys!(s, %w[version workspace_id root_digest generation] + KINDS)
      valid!(s["version"] == VERSION && id?(s["workspace_id"], "workspace") && s["root_digest"] == root_digest && integer?(s["generation"]))
      KINDS.each do |kind|
        valid!(s[kind].is_a?(Hash) && s[kind].size <= MAX_RECORDS)
        s[kind].each do |id, r|
          valid!(r.is_a?(Hash) && id?(id, PREFIXES[KINDS.index(kind)]) && r["id"] == id && r["workspace_id"] == s["workspace_id"])
          common = %w[id workspace_id]
          case kind
          when "sources"
            keys!(r, common + %w[platform label]); encoded!(r["platform"]); encoded!(r["label"], optional: true)
          when "datasets"
            keys!(r, common + %w[source_id label]); reference!(s, "sources", r["source_id"]); encoded!(r["label"], optional: true)
          when "inputs"
            keys!(r, common + %w[dataset_id path sha256 bytes type identity])
            reference!(s, "datasets", r["dataset_id"]); encoded!(r["path"])
            decoded = (r["path"]).unpack1("m0")
            valid!(decoded.start_with?("inputs/") && !decoded.include?("\0") && decoded.split("/", -1).none? { |v| ["", ".", ".."].include?(v) })
            valid!(r["sha256"].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(r["sha256"]) && integer?(r["bytes"]) && r["bytes"] <= MAX_BYTES && type?(r["type"]))
            identity!(r["identity"]); valid!(r["identity"]["size"] == r["bytes"])
          when "plans"
            keys!(r, common + %w[dataset_id generation operation input_ids input_binding run_id])
            reference!(s, "datasets", r["dataset_id"]); reference!(s, "runs", r["run_id"])
            valid!(integer?(r["generation"]) && r["generation"] <= s["generation"] && r["operation"] == "validate-inputs")
            ids = r["input_ids"]
            valid!(ids.is_a?(Array) && !ids.empty? && ids.size <= MAX_RECORDS && ids.uniq == ids)
            ids.each { |i| reference!(s, "inputs", i); valid!(s["inputs"][i]["dataset_id"] == r["dataset_id"]) }
            valid!(r["input_binding"] == input_binding(s, ids))
            run = s["runs"][r["run_id"]]; valid!(run["plan_id"] == id && run["dataset_id"] == r["dataset_id"])
            if r["generation"] == s["generation"]
              valid!(ids.sort == s["inputs"].values.select { |i| i["dataset_id"] == r["dataset_id"] }.map { |i| i["id"] }.sort)
            end
          when "runs"
            keys!(r, common + %w[plan_id dataset_id attempt_id status outcome])
            reference!(s, "plans", r["plan_id"]); reference!(s, "datasets", r["dataset_id"])
            plan = s["plans"][r["plan_id"]]
            valid!(plan["run_id"] == id && plan["dataset_id"] == r["dataset_id"] && STATUSES.include?(r["status"]))
            valid!(r["status"] == "planned" ? r["attempt_id"].nil? : id?(r["attempt_id"], "attempt"))
            outcome = r["outcome"]
            if %w[planned running].include?(r["status"])
              valid!(outcome.nil?)
            else
              outcome_keys = %w[code input_count bytes]
              outcome_keys += %w[failed_input_id reason] if r["status"] == "failed"
              keys!(outcome, outcome_keys)
              valid!(integer?(outcome["input_count"]) && integer?(outcome["bytes"]))
              if r["status"] == "completed"
                valid!(outcome["code"] == "NAMED_OK" && outcome["input_count"] == plan["input_ids"].size && outcome["bytes"] == plan["input_ids"].sum { |i| s["inputs"][i]["bytes"] })
              else
                if r["status"] == "failed"
                  valid!(plan["input_ids"].include?(outcome["failed_input_id"]) && INPUT_FAILURE_CODES.include?(outcome["reason"]))
                end
                valid!(outcome["code"] == (r["status"] == "interrupted" ? "NAMED_INTERRUPTED" : "NAMED_VALIDATION_FAILED") && outcome["input_count"] == 0 && outcome["bytes"] == 0)
              end
            end
          end
        end
      end
      valid!(s["inputs"].values.map { |r| r["path"] }.uniq.size == s["inputs"].size)
      valid!(s["inputs"].values.sum { |r| r["bytes"] } <= MAX_TOTAL_BYTES)
      valid!(s["runs"].values.map { |r| r["attempt_id"] }.compact.uniq.size == s["runs"].values.count { |r| r["attempt_id"] })
      s
    rescue ArgumentError, TypeError, NoMethodError, KeyError
      fail!("NAMED_STATE_INVALID")
    end

    def type?(value)
      value.is_a?(String) && /\A[a-z][a-z0-9_-]{0,31}\z/.match?(value)
    end

    private

    def sync_init_directories!
      # Persist the newly created directory entries as well as state.json.
      # A failure after rename remains fail-closed: state may already exist and
      # init will never reset it or silently mint a replacement identity.
      directories = [File.join(root, "inputs"), File.join(root, ".silo-migrate"), root, File.dirname(root)]
      (directories + (@created_base_parents || [])).uniq.each do |directory|
        File.open(directory) { |file| file.fsync }
      end
    end

    def root_digest
      Digest::SHA256.hexdigest(File.realpath(root).b)
    end

    def directory_absolute!(path)
      # Check every existing ancestor; never follow a symlink into authority.
      current = "/".b
      File.expand_path(path.b).split("/".b).reject(&:empty?).each do |part|
        current = File.join(current, part)
        st = File.lstat(current)
        fail!("NAMED_PATH_INVALID") unless st.directory? && !st.symlink?
      end
      st = File.lstat(path)
      fail!("NAMED_PATH_INVALID") unless st.uid == Process.uid && (st.mode & 0o022).zero?
    end

    def directory!(relative, create: false, private: false)
      p = File.join(root.b, relative.b)
      Dir.mkdir(p, 0o700) if create && !File.exist?(p) && !File.symlink?(p)
      directory_absolute!(p)
      fail!("NAMED_PATH_INVALID") if private && (File.stat(p).mode & 0o077) != 0
      p
    end

    def verify_lock!(lock, path)
      held = lock.stat
      current = File.lstat(path)
      regular!(held, private: true)
      regular!(current, private: true)
      fail!("NAMED_PATH_INVALID") unless held.dev == current.dev && held.ino == current.ino && held.nlink == current.nlink
    rescue Errno::ENOENT
      fail!("NAMED_PATH_INVALID")
    end

    def regular!(stat, private: false)
      fail!("NAMED_PATH_INVALID") unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid && (stat.mode & 0o022).zero?
      fail!("NAMED_PATH_INVALID") if private && (stat.mode & 0o077) != 0
    end

    def read_file(path, limit, private: false)
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        regular!(file.stat, private: private)
        fail!("NAMED_SIZE_LIMIT") if file.stat.size > limit
        before = identity(file.stat)
        data = file.read(limit + 1) || "".b
        fail!("NAMED_SIZE_LIMIT") if data.bytesize > limit
        fail!("NAMED_STATE_INVALID") unless before == identity(file.stat) && before == identity(File.lstat(path))
        data
      end
    end

    def integer?(v)
      v.is_a?(Integer) && v >= 0
    end

    def id?(v, prefix)
      v.is_a?(String) && /\A#{prefix}-[0-9a-f]{32}\z/.match?(v)
    end

    def valid!(condition)
      fail!("NAMED_STATE_INVALID") unless condition
    end

    def keys!(value, keys)
      valid!(value.is_a?(Hash) && value.keys.sort == keys.sort)
    end

    def reference!(state, kind, id)
      valid!(id.is_a?(String) && state[kind].key?(id))
    end

    def encoded!(value, optional: false)
      return if optional && value.nil?
      valid!(value.is_a?(String) && value.bytesize <= 4 * ((MAX_METADATA_BYTES + 2) / 3))
      decoded = (value).unpack1("m0")
      valid!(decoded.bytesize.between?(1, MAX_METADATA_BYTES) && [decoded].pack("m0") == value)
    end

    def identity!(v)
      keys!(v, %w[dev ino size mtime ctime])
      valid!(%w[dev ino size].all? { |k| integer?(v[k]) })
      %w[mtime ctime].each { |k| valid!(v[k].is_a?(Array) && v[k].size == 2 && v[k][0].is_a?(Integer) && integer?(v[k][1]) && v[k][1] < 1_000_000_000) }
    end
  end
end
