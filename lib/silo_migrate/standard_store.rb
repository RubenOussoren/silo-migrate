# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "tempfile"
require "time"
require_relative "errors"

module SiloMigrate
  class StandardWorkflowError < UsageError
    attr_reader :code

    def initialize(code, detail = nil)
      @code = code
      super(detail ? "#{code}: #{detail}" : code)
    end
  end

  # Durable operator-owned state for the standard local workflow, stored next to
  # the named registry. Cooperative locking on an operator-owned filesystem; not
  # authentication or a sandbox. Execution holds op.lock for its whole duration;
  # state transitions take state.lock briefly so status stays readable.
  class StandardStore
    ROOT = File.join(NamedWorkspaceStore::ROOT, "standard")
    VERSION = 1
    MAX_STATE_BYTES = 4 * 1024 * 1024

    attr_reader :workspace, :root

    def initialize(workspace, env: ENV)
      @workspace = workspace
      @env = env
      @named = NamedWorkspaceStore.new(workspace, env: env)
      @root = File.join(@named.root, ROOT)
    end

    def named
      @named
    end

    def workspace_root
      @named.root
    end

    def named_state
      @named.with_lock { |store| store.load }
    end

    def ensure_ready!(create: false)
      # Going through the named lock also runs its mode/path authority checks.
      @named.with_lock { |store| store.load }
      Dir.mkdir(@root, 0o700) if create && !Dir.exist?(@root)
      raise StandardWorkflowError, "STANDARD_NOT_INITIALIZED" unless File.exist?(state_path)
    end

    def initialized?
      File.file?(state_path)
    end

    def init!(config)
      @named.with_lock { |store| store.load }
      Dir.mkdir(@root, 0o700) unless Dir.exist?(@root)
      raise StandardWorkflowError, "STANDARD_ALREADY_INITIALIZED" if File.exist?(state_path)

      write!({ "version" => VERSION, "config" => config, "plans" => {}, "runs" => {},
               "findings" => {}, "instances" => {}, "consumed_outputs" => [], "accepted_baselines" => {} })
    end

    def load
      raise StandardWorkflowError, "STANDARD_NOT_INITIALIZED" unless File.file?(state_path)
      raise StandardWorkflowError, "STANDARD_STATE_INVALID" if File.size(state_path) > MAX_STATE_BYTES

      state = JSON.parse(File.read(state_path))
      raise StandardWorkflowError, "STANDARD_STATE_INVALID" unless state.is_a?(Hash) && state["version"] == VERSION
      state
    rescue JSON::ParserError
      raise StandardWorkflowError, "STANDARD_STATE_INVALID"
    end

    def update
      with_state_lock do
        state = load
        result = yield state
        write!(state)
        result
      end
    end

    # A persisted "running" with this lock free means its process has gone away.
    def with_op_lock
      FileUtils.mkdir_p(@root, mode: 0o700)
      File.open(op_lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        raise StandardWorkflowError, "STANDARD_BUSY" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        begin
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
    end

    def op_lock_held?
      return false unless File.exist?(op_lock_path)

      File.open(op_lock_path, File::RDWR | File::NOFOLLOW) do |lock|
        got = lock.flock(File::LOCK_EX | File::LOCK_NB)
        lock.flock(File::LOCK_UN) if got
        !got
      end
    end

    def run_dir(run_id, *parts)
      File.join(@root, "runs", run_id, *parts)
    end

    def finding_dir(finding_id, *parts)
      File.join(@root, "findings", finding_id, *parts)
    end

    def write_private(path, content, mode: 0o600)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      staged = Tempfile.new([".standard-", ".tmp"], File.dirname(path))
      begin
        staged.binmode
        staged.chmod(mode)
        staged.write(content)
        staged.flush
        staged.fsync
        staged.close
        File.rename(staged.path, path)
        File.open(File.dirname(path)) { |dir| dir.fsync }
      ensure
        staged.close!
      end
      path
    end

    def new_id(prefix)
      "#{prefix}-#{SecureRandom.hex(16)}"
    end

    private

    def state_path
      File.join(@root, "state.json")
    end

    def op_lock_path
      File.join(@root, "op.lock")
    end

    def with_state_lock
      File.open(File.join(@root, "state.lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        begin
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
    end

    def write!(state)
      bytes = JSON.pretty_generate(state) + "\n"
      raise StandardWorkflowError, "STANDARD_STATE_INVALID" if bytes.bytesize > MAX_STATE_BYTES

      write_private(state_path, bytes)
      state
    end
  end
end
