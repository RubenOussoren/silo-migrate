# frozen_string_literal: true
# Invented-data live adapter. All protocol SQL comes from the production module.
require "json"
require "digest"
require "open3"
require "fileutils"
module SiloMigrate
  module Services
    class StandardWorkflowError < StandardError
      attr_reader :code
      def initialize(code, detail = nil)
        @code = code
        super([code, detail].compact.join(": "))
      end
    end
  end
end
require_relative "standard_merge_preparation"

Result = Struct.new(:stdout, :stderr, :status) do
  def success? = status == 0
end

class LiveRuntime
  attr_reader :commands, :redis_flushes
  def initialize
    @commands = []
    @redis_flushes = 0
  end

  def run(command, **_options)
    @commands << command
    if command == %w[docker exec invented-redis redis-cli FLUSHALL]
      @redis_flushes += 1
      return Result.new("OK\n", "", 0)
    end
    prefix = %w[docker exec invented-db psql -X -v ON_ERROR_STOP=1 -U]
    raise "unexpected runtime command" unless command[0, 8] == prefix && command.size == 13 && command[9] == "-d" && command[11] == "-Atc"
    # The SQL, database and role are unchanged; only the Docker transport is adapted.
    execute(command[12], database: command[10], user: command[8])
  end

  def execute(sql, database: "postgres", user: "postgres")
    stdout, stderr, status = Open3.capture3("psql", "-h", "db", "-X", "-v", "ON_ERROR_STOP=1", "-U", user, "-d", database, "-Atc", sql)
    Result.new(stdout, stderr, status.exitstatus)
  end

  def sql(sql, database: "postgres")
    result = execute(sql, database: database)
    raise "fixture SQL failed" unless result.success?
    result.stdout.strip
  end
end

class LiveStack
  def name = "invented-stack"
  def record = { "containers" => { "db" => "invented-db", "web" => "invented-web", "redis" => "invented-redis" } }
  def container(role) = record.fetch("containers").fetch(role)
  def live? = true
  def web_exec(*) = Result.new("SILO_QUIESCED\n", "", 0)
end

class LiveStore
  attr_reader :state
  def initialize
    @state = { "runs" => { "prepare" => { "id" => "prepare", "merge_environment" => { "preparation_run_id" => "prepare" } }, "merge" => { "id" => "merge", "instances" => {} } }, "instances" => {} }
  end
  def update = yield @state
  def load = @state
  def run_dir(*parts) = File.join("/tmp/checkpoint-protocol", *parts)
end

class LiveProtocol
  include SiloMigrate::Services::StandardMergePreparation
  attr_reader :runtime, :store, :labels, :inspection_closed, :disk_bytes
  def initialize
    @runtime = LiveRuntime.new
    @store = LiveStore.new
    @stack = LiveStack.new
    @labels = []
  end
  def stack_for(*) = @stack
  def now = "2026-01-01T00:00:00Z"
  def canonical_json(value) = JSON.generate(value)
  def log(_run_id, label, _result) = @labels << label
  def plan_for(run_id)
    return { "digest" => "invented-plan-digest" } if run_id == "prepare"
    { "body" => { "prepared_from" => { "run_id" => "prepare", "generation" => environment.fetch("generation") } } }
  end
  def environment = @store.state.fetch("runs").fetch("prepare").fetch("merge_environment")
  def set_instance_state(_stack, state)
    @store.state.fetch("instances")[@stack.name] = @stack.record.merge("name" => @stack.name, "run_id" => "prepare", "state" => state)
  end
  def disk_headroom!(bytes) = @disk_bytes = bytes
  def merge_result(*) = nil
  def nap(seconds) = sleep(seconds)
  def merge_inspection_close(run_id) = @inspection_closed = run_id
  def install_helpers(*) = nil
  def merge_state(_stack, source: false, **)
    # Rails state/compatibility are deliberately outside this PostgreSQL protocol test.
    { "database" => source ? "merge_source" : "discourse", "base_url" => "https://invented.invalid", "counts" => {} }
  end
  def merge_source_url?(*) = true
  def evidence(*) = nil
  def merge_compatibility!(*) = nil

  def check(condition, message)
    raise message unless condition
  end

  def refused
    yield
    raise "guard unexpectedly accepted invalid catalogue"
  rescue SiloMigrate::Services::StandardWorkflowError => error
    check(error.code == "STANDARD_MERGE_ENVIRONMENT_DIRTY", "unexpected refusal code")
    check(error.message.end_with?("unexpected databases"), "unexpected refusal reason")
  end

  def setup_databases
    @runtime.sql("DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'discourse') THEN CREATE ROLE discourse LOGIN SUPERUSER; END IF; END $$")
    @runtime.sql("DROP DATABASE IF EXISTS discourse WITH (FORCE)")
    %w[discourse merge_source].each_with_index do |database, index|
      @runtime.sql("CREATE DATABASE #{database} OWNER discourse")
      schema = "CREATE TABLE schema_migrations(version text); INSERT INTO schema_migrations VALUES ('invented-v1');"
      %w[users topics posts categories groups tags uploads].each do |table|
        schema += "CREATE TABLE #{table}(id bigint PRIMARY KEY, marker text); INSERT INTO #{table} VALUES (#{index + 1}, 'invented-#{database}');"
      end
      @runtime.sql(schema, database: database)
      @runtime.sql("GRANT SELECT ON ALL TABLES IN SCHEMA public TO discourse", database: database)
    end
    # Copy the ephemeral postgres password to discourse inside the helper, never argv/output.
    password = ENV.fetch("PGPASSWORD")
    _stdout, _stderr, status = Open3.capture3("psql", "-h", "db", "-X", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-f", "-",
                                            stdin_data: "ALTER ROLE discourse PASSWORD '#{password}';\n")
    check(status.success?, "disposable role password setup failed")
  end

  def run(baseline: false)
    fresh = nil
    unless baseline
      # Observe the actual pinned image's catalogue before creating any fixture DB.
      fresh = merge_databases("prepare", label: "initial-databases", code: "STANDARD_STACK_FAILED")
      check(fresh == %w[discourse:t], "fresh image database protocol differs")
      check(@runtime.execute("SELECT 1", database: "discourse").success?, "fresh discourse database not accepting connections")
    end
    setup_databases
    raw = @runtime.sql("SELECT datname || ':' || datallowconn FROM pg_database WHERE datname IN ('discourse', 'merge_source') ORDER BY datname").lines.map(&:strip)
    check(raw == %w[discourse:true merge_source:true], "raw boolean cast changed")
    actual = merge_databases("prepare")
    if baseline
      check(actual == raw, "baseline requires unfixed production source")
      refused { stage_checkpoint("prepare") }
      check(@runtime.sql("SELECT COUNT(*) FROM pg_database WHERE datname = 'silo_clean_base'") == "0", "baseline mutated databases")
      return { "mode" => "baseline", "raw" => raw, "actual" => actual, "checkpoint_refused" => true }
    end
    check(actual == %w[discourse:t merge_source:t], "production inventory still emits raw boolean text")
    check(merge_databases("prepare", label: "initial-databases") == actual, "initial database inventory differs")
    check(@labels.include?("merge-environment-initial-databases"), "initial database label absent")
    # Unexpected reserved name and wrong connection state must refuse before cloning.
    @runtime.sql("CREATE DATABASE silo_inspect_source")
    refused { stage_checkpoint("prepare") }
    @runtime.sql("DROP DATABASE silo_inspect_source")
    @runtime.sql("ALTER DATABASE merge_source ALLOW_CONNECTIONS false")
    refused { stage_checkpoint("prepare") }
    @runtime.sql("ALTER DATABASE merge_source ALLOW_CONNECTIONS true")
    originals = { "base" => merge_seal("prepare", "discourse"), "source" => merge_seal("prepare", "merge_source") }
    # Keep a real client connected across checkpoint's first session drain.
    Open3.popen3({ "PGAPPNAME" => "invented-checkpoint-held" }, "psql", "-h", "db", "-X", "-U", "postgres", "-d", "discourse", "-Atc", "SELECT pg_sleep(90)") do |input, _output, _error, waiter|
      input.close
      begin
        present = false
        50.times do
          present = @runtime.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name = 'invented-checkpoint-held' AND datname = 'discourse'") == "1"
          break if present
          sleep 0.1
        end
        check(present, "held session did not connect")
        stage_checkpoint("prepare")
        check(waiter.join(5) && !waiter.value.success?, "checkpoint did not terminate held session")
        check(@runtime.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name = 'invented-checkpoint-held'") == "0", "held session remains")
      ensure
        Process.kill("TERM", waiter.pid) if waiter.alive?
        waiter.join(5)
      end
    end
    check(environment.fetch("phase") == "inspection", "checkpoint phase")
    check(environment.fetch("seals") == originals, "checkpoint seals changed")
    check(environment.fetch("generation").match?(self.class::MERGE_GENERATION), "checkpoint generation")
    check(@disk_bytes.to_i > 0, "disk admission seam not called")
    check(merge_databases("prepare") == %w[discourse:t merge_source:f silo_clean_base:f silo_inspect_source:t], "postclone guard")
    %w[silo_clean_base merge_source].each do |database|
      check(!@runtime.execute("SELECT 1", database: database).success?, "sealed database permits connection")
    end
    check(merge_seal("prepare", "discourse") == originals.fetch("base"), "base clone differs")
    check(merge_seal("prepare", "silo_inspect_source") == originals.fetch("source"), "source clone differs")
    # Inspection mutations must disappear when the actual activation SQL path runs.
    @runtime.sql("INSERT INTO users VALUES (99, 'inspection-only')", database: "discourse")
    @runtime.sql("INSERT INTO users VALUES (99, 'inspection-only')", database: "silo_inspect_source")
    environment.merge!("phase" => "consumed", "consumed_by" => "merge")
    set_instance_state(@stack, "prepared")
    path = @store.run_dir("prepare", "evidence", "merge-uploads.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate("uploads" => []))
    stage_activate("merge")
    check(merge_databases("merge") == %w[discourse:t merge_source:t], "activation guard")
    check(environment.fetch("phase") == "merging", "activation phase")
    check(@inspection_closed == "prepare" && @runtime.redis_flushes == 1, "activation effect seams")
    check(merge_seal("merge", "discourse") == originals.fetch("base"), "activated base differs")
    check(merge_seal("merge", "merge_source") == originals.fetch("source"), "activated source differs")
    %w[discourse merge_source].each do |database|
      check(@runtime.sql("SELECT count(*) FROM users WHERE marker = 'inspection-only'", database: database) == "0", "inspection mutation survived")
    end
    { "mode" => "fixed", "fresh" => fresh, "fresh_connections_accepted" => true, "raw" => raw, "actual" => actual, "checkpoint" => true, "activation" => true, "canaries" => 2, "sealed_connections_refused" => true, "held_session_terminated" => true, "inspection_mutations_discarded" => true }
  end
end

begin
  puts JSON.generate(LiveProtocol.new.run(baseline: ENV["SILO_CHECKPOINT_BASELINE"] == "1"))
rescue StandardError => error
  # Never print SQL, credentials, process output, or backtraces from a live adapter.
  detail = error.is_a?(SiloMigrate::Services::StandardWorkflowError) && error.message.match?(/\ASTANDARD_[A-Z_]+: [a-z -]+\z/) ? error.message : "details suppressed"
  warn "checkpoint protocol live failed (#{error.class}); #{detail}"
  exit 1
end
