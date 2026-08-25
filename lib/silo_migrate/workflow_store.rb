# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"

module SiloMigrate
  # Credential-free, durable authority for the migration workflow. All writers
  # take the same project lock and replace the JSON file atomically.
  class WorkflowStore
    VERSION = 1
    PHASES = %w[initial final].freeze
    PHASE_STATES = %w[empty importing ready dirty untracked unknown].freeze
    DISCOURSE_STATES = %w[pristine restored imported dirty stale unknown].freeze

    attr_reader :customer, :env

    def initialize(customer, env: ENV, runtime: nil)
      @customer = Project.validate_customer_name!(customer)
      @env = env
      @runtime = runtime
    end

    def path
      File.join(project_path, ".silo-migrate", "workflow.json")
    end

    def lock_path
      File.join(project_path, ".silo-migrate", "workflow.lock")
    end

    def read(reconcile: true)
      with_lock { |state| reconcile ? reconcile_state!(state) : state }
    end

    def update
      with_lock do |state|
        result = yield state
        write_locked(state)
        result || state
      end
    end

    def with_lock
      lock_key = "silo_migrate_workflow_#{File.expand_path(lock_path)}"
      if (held = Thread.current[lock_key])
        return yield held
      end

      FileUtils.mkdir_p(File.dirname(path))
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        state = load_locked
        Thread.current[lock_key] = state
        result = yield state
        result
      ensure
        Thread.current[lock_key] = nil
        lock&.flock(File::LOCK_UN)
      end
    end

    def write_locked(state)
      validate!(state)
      state["updated_at"] = Time.now.utc.iso8601
      Project.atomic_write(path, JSON.pretty_generate(state) + "\n")
      File.chmod(0o600, path)
      state
    end

    def phase(state, name)
      raise UsageError, "Invalid phase: #{name}" unless PHASES.include?(name)

      state.fetch("phases").fetch(name)
    end

    def dump_identity(path)
      {
        "filename" => File.basename(path),
        "relative_path" => relative_project_path(path),
        "sha256" => Digest::SHA256.file(path).hexdigest,
        "bytes" => File.size(path)
      }
    end

    def user_table_count(name)
      probe_phase(name)
    end

    def default_state
      now = Time.now.utc.iso8601
      {
        "version" => VERSION,
        "created_at" => now,
        "updated_at" => now,
        "phases" => PHASES.to_h do |name|
          [name, { "generation" => 0, "state" => "empty", "import" => nil, "schema_bundle" => nil }]
        end,
        "converter" => {
          "active_source" => "initial",
          "output_db" => "output/intermediate.db",
          "output_lineage" => nil
        },
        "discourse" => {
          "state" => "pristine",
          "restored_at" => nil,
          "imported_at" => nil,
          "output_lineage" => nil
        }
      }
    end

    def reconcile_state!(state)
      changed = migrate_legacy_markers!(state)
      PHASES.each do |name|
        data = phase(state, name)
        if data["state"] == "importing" && !import_in_progress?(data)
          data["state"] = "dirty"
          data["interrupted_at"] = Time.now.utc.iso8601
          data.delete("import_pid")
          changed = true
        end
        next unless %w[empty unknown].include?(data["state"])

        probed = probe_phase(name)
        unless probed
          if @state_was_missing
            data["state"] = "unknown"
            changed = true
          end
          next
        end

        desired = probed.positive? ? "untracked" : "empty"
        if data["state"] != desired
          data["state"] = desired
          data["user_table_count"] = probed
          data["probed_at"] = Time.now.utc.iso8601
          changed = true
        end
      end
      changed = reconcile_discourse_markers!(state) || changed
      write_locked(state) if changed || !File.exist?(path)
      state
    end

    private

    # The importer records its PID; "importing" only reconciles to "dirty"
    # once that process is gone (i.e. the import crashed rather than running).
    def import_in_progress?(data)
      pid = data["import_pid"]
      return false unless pid.is_a?(Integer) && pid.positive?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def project_path
      Project.project_path(customer, env)
    end

    def load_locked
      unless File.exist?(path)
        @state_was_missing = true
        return default_state
      end
      @state_was_missing = false

      parsed = JSON.parse(File.read(path))
      validate!(parsed)
      parsed
    rescue JSON::ParserError => e
      raise UsageError, "Workflow state is corrupt at #{path}: #{e.message}"
    end

    def validate!(state)
      raise UsageError, "Unsupported workflow state version: #{state['version'].inspect}" unless state["version"] == VERSION
      raise UsageError, "Workflow state has no phases" unless state["phases"].is_a?(Hash)

      PHASES.each do |name|
        data = state["phases"][name]
        raise UsageError, "Workflow state has no #{name} phase" unless data.is_a?(Hash)
        raise UsageError, "Invalid #{name} database state: #{data['state'].inspect}" unless PHASE_STATES.include?(data["state"])
      end
      discourse = state["discourse"]
      raise UsageError, "Invalid Discourse workflow state" unless discourse.is_a?(Hash) && DISCOURSE_STATES.include?(discourse["state"])
      source = state.dig("converter", "active_source")
      raise UsageError, "Invalid converter source: #{source.inspect}" unless PHASES.include?(source)
    end

    def migrate_legacy_markers!(state)
      changed = false
      PHASES.each do |name|
        data = phase(state, name)
        next unless %w[empty unknown].include?(data["state"])

        marker_path = File.join(project_path, "dumps", name, ".imported.json")
        next unless File.exist?(marker_path)

        marker = JSON.parse(File.read(marker_path))
        filename = marker["file"] || marker["filename"] || marker["dump"]
        dump_path = filename && File.join(project_path, "dumps", name, File.basename(filename))
        identity = dump_path && File.file?(dump_path) ? dump_identity(dump_path) : { "filename" => filename }
        data["state"] = "ready"
        data["generation"] = [data["generation"].to_i, 1].max
        data["import"] = identity.merge(
          "imported_at" => marker["imported_at"] || marker["timestamp"] || File.mtime(marker_path).utc.iso8601,
          "options" => marker["options"] || {},
          "legacy_marker" => true
        ).compact
        changed = true
      rescue JSON::ParserError
        data["state"] = "unknown"
        changed = true
      end
      changed
    end

    def reconcile_discourse_markers!(state)
      discourse = state.fetch("discourse")
      return false unless %w[pristine unknown].include?(discourse["state"])

      restored = File.join(project_path, "output", "discourse-import-restored.txt")
      imported = File.join(project_path, "output", "discourse-import-complete.txt")
      desired = if File.exist?(imported)
                  "imported"
                elsif File.exist?(restored)
                  "restored"
                else
                  discourse["state"]
                end
      return false if desired == discourse["state"]

      discourse["state"] = desired
      true
    end

    def probe_phase(name)
      return nil unless @runtime

      config = Project.load_config(customer, env)
      db_type, db_name, password = Project.database_config(customer, name, config)
      container = "#{customer}_#{name}_#{db_type}"
      return nil unless @runtime.container_running?(container)

      command = database_count_command(container, db_type, db_name, password)
      result = @runtime.run(command, capture: true, timeout: 30)
      return nil unless result.success?

      text = result.stdout.to_s.strip
      text.empty? ? 0 : Integer(text.lines.last.strip)
    rescue UsageError, ArgumentError
      nil
    end

    def database_count_command(container, db_type, db_name, password)
      if db_type == "postgres"
        ["docker", "exec", "-e", "PGPASSWORD=#{password}", container, "psql", "-U", "postgres", "-d", db_name, "-Atc",
         "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'"]
      else
        ["docker", "exec", "-e", "MYSQL_PWD=#{password}", container, "mysql", "-u", "root", "-Nse",
         "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='#{db_name.gsub("'", "''")}' AND table_type='BASE TABLE'"]
      end
    end

    def relative_project_path(path)
      expanded = File.expand_path(path)
      prefix = "#{File.expand_path(project_path)}#{File::SEPARATOR}"
      expanded.start_with?(prefix) ? expanded.delete_prefix(prefix) : nil
    end
  end
end
