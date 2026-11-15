# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "open3"
require "rbconfig"
require "silo_migrate/standard_cli"

class StandardMergeValidationReconciliationTest < SiloMigrateTest
  ID = "a" * 32
  RUN = "run-#{'b' * 32}"
  GENERATION = "c" * 64
  PRIVATE = "private-customer-payload"

  class Store
    attr_reader :root, :state
    attr_accessor :busy
    def initialize(root)
      @root = root
      @state = { "runs" => { RUN => { "status" => "completed", "plan_id" => "p", "merge_environment" => {
        "preparation_run_id" => RUN, "generation" => GENERATION, "phase" => "ready" } } },
        "plans" => { "p" => { "body" => { "operation" => "standard_merge_prepare" } } } }
    end
    def load = state
    def with_read_only_execution_locks
      raise SiloMigrate::StandardWorkflowError, "STANDARD_BUSY" if busy
      yield
    end
  end

  class Runtime
    attr_reader :calls, :sql_payloads, :inventory
    attr_accessor :sessions, :guest, :processes, :redis_id, :redis_running, :redis_label,
      :fault, :drift_after_sql, :template_oid, :template_open
    def initialize
      @calls, @sql_payloads = [], []
      @inventory = {
        "silo_val_s_#{ID}" => ["silo_val_s_#{ID}", "102", "10", "postgres"],
        "silo_val_b_#{ID}" => ["silo_val_b_#{ID}", "101", "10", "postgres"],
        "silo_val_r_#{ID}" => ["silo_val_r_#{ID}", "201", *%w[f f f f f f t]] }
      @sessions, @guest, @processes, @redis_label = "0", "absent", "none_observed", ID
    end
    def result(value, status = 0)
      OpenStruct.new(stdout: value, stderr: PRIVATE, status: status, success?: status == 0)
    end
    def run(argv, **options)
      calls << [argv, options]
      raise PRIVATE if fault == :all
      if options.key?(:stdin_data)
        sql = options.fetch(:stdin_data)
        sql_payloads << sql
        output = if sql.include?("silo_validation_identity_")
          name = sql[/silo_val_[sbr]_[0-9a-f]{32}/]
          inventory[name] ? inventory.fetch(name).join("|") + "\n" : ""
        elsif sql.include?("pg_database_size")
          "merge_source|#{template_oid || 11}|10|#{template_open ? 't' : 'f'}|0|100\nsilo_clean_base|12|10|f|0|200\n"
        elsif sql.include?("pg_stat_activity")
          "#{sessions}\n"
        else
          raise "unexpected query"
        end
        return result(output + "\nSILO_VALIDATION_SQL_DONE:#{argv.last}:0\n")
      end
      case argv[0, 2]
      when %w[docker info]
        result("fixture-daemon-id")
      when %w[docker inspect]
        if argv.last == redis_id
          result("#{redis_id}|#{redis_label}|true|#{redis_running ? 'true' : 'false'}")
        else
          id = argv.last.start_with?("web") ? "e" * 64 : "d" * 64
          id = "9" * 64 if fault == :binding || (drift_after_sql && !sql_payloads.empty?)
          result("#{id}|true|2026-11-15T00:00:00Z|true|fixture")
        end
      when %w[docker container]
        fault == :redis ? result(PRIVATE, 1) : result(redis_id || "")
      when %w[docker exec]
        if argv.include?("ruby")
          fault == :process ? result(PRIVATE, 1) : result(processes)
        elsif argv.include?("silo-validation-stat")
          result(guest)
        else
          raise "unexpected exec"
        end
      else
        raise "unexpected runtime operation"
      end
    end
  end

  class Host
    include SiloMigrate::Services::StandardMergeValidation
    attr_reader :store, :runtime
    def initialize(root)
      @store, @runtime = Store.new(root), Runtime.new
    end
    def review_runtime_for(_) = {}
    def with_review_runtime(_) = yield
    def merge_environment_phase(*) = raise("must not revisit delivery/input registries")
    def stack_for(*)
      Object.new.tap do |stack|
        stack.define_singleton_method(:container) { |service| "#{service}-fixture" }
        stack.define_singleton_method(:record) { { "name" => "fixture", "containers" => { "db" => "d" * 64, "web" => "e" * 64 } } }
      end
    end
  end

  def setup
    @root = Dir.mktmpdir
    @host = Host.new(@root)
    @templates = { "merge_source" => { "oid" => 11, "owner" => 10, "bytes" => 100 },
      "silo_clean_base" => { "oid" => 12, "owner" => 10, "bytes" => 200 } }
    @journal = { "version" => 1, "id" => ID, "prepared_from" => RUN, "generation" => GENERATION,
      "source" => "silo_val_s_#{ID}", "base" => "silo_val_b_#{ID}", "role" => "silo_val_r_#{ID}",
      "guest_directory" => "/shared/silo-validation-#{ID}", "redis" => "silo-val-redis-#{ID}",
      "templates" => @templates, "status" => "owned_unknown", "cleanup_confirmed" => false,
      "owned_identities" => @host.runtime.inventory.values.map { |row| row.size == 4 ? row.values_at(0, 1, 3) : row } }
    @receipt = { "version" => 1, "receipt_id" => ID, "prepared_from" => RUN, "generation" => GENERATION,
      "templates" => @templates, "status" => "refused", "settings" => PRIVATE }
    save
  end

  def teardown = FileUtils.remove_entry(@root)

  def save
    @host.send(:mv_write!, @host.send(:mv_path, ID, "json"), @receipt)
    @host.send(:mv_write!, @host.send(:mv_path, ID, "resources.json"), @journal)
  end

  def inspect_attempt = @host.merge_validation_reconcile_inspect(attempt_id: ID)

  def assert_no_authority(report)
    assert_equal false, report.fetch("cleanup_authorized")
    assert_equal false, report.fetch("reset_retires_validation_journal")
    assert_equal "unproven", report.fetch("historical_producer")
    assert_equal "unproven", report.fetch("current_host_producer")
    refute_includes JSON.generate(report), PRIVATE
  end

  def test_real_helpers_observe_legacy_fields_without_writes_or_mutating_sql
    paths = Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
    before = paths.to_h { |path| [path, [File.binread(path), File.stat(path).mtime]] }
    state = JSON.generate(@host.store.state)
    report = inspect_attempt
    assert_equal "observed", report["inspection"], JSON.generate(report)
    assert_equal "matches_current_preparation_record", report["runtime"]
    assert_equal "matches_saved_custody", report["templates"]
    assert_equal "none_observed", report["sessions"]
    assert_equal "none_observed", report["current_guest_process"]
    report["resources"].each_value { |row| assert_equal({ "presence" => "present", "identity" => "matches_saved_fields" }, row) }
    assert_no_authority(report)
    assert_equal state, JSON.generate(@host.store.state)
    assert_equal before, paths.to_h { |path| [path, [File.binread(path), File.stat(path).mtime]] }
    assert_equal paths.sort, Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort
    assert_equal 5, @host.runtime.sql_payloads.size
    @host.runtime.sql_payloads.each do |sql|
      assert_match(/\ABEGIN READ ONLY;/, sql)
      assert_includes sql, "SET LOCAL statement_timeout = '5s'"
      assert_includes sql, "SET LOCAL lock_timeout = '1s'"
      refute_match(/\b(?:CREATE|DROP|ALTER|GRANT|REVOKE|INSERT|UPDATE|DELETE|pg_terminate_backend)\b/i, sql)
    end
    @host.runtime.calls.each do |argv, options|
      assert_equal true, options[:capture]
      assert_includes %w[info inspect exec container], argv[1]
      refute (argv & %w[rm stop kill cp start create run]).any?
    end
  end

  def test_all_absent_is_observation_not_producer_completion
    @host.runtime.inventory.clear
    report = inspect_attempt
    assert_equal "observed", report["inspection"]
    assert_equal "absent", report["guest_directory"]
    assert_equal "absent", report["host_staging_directory"]
    assert_equal "absent", report["redis"]
    assert report["resources"].values.all? { |row| row["presence"] == "absent" }
    assert_no_authority(report)
  end

  def test_present_substitute_and_unrecorded_identity_are_distinct
    @host.runtime.inventory.fetch(@journal["source"])[1] = "999"
    assert_equal "differs_saved_fields", inspect_attempt.dig("resources", "source", "identity")
    @journal.delete("owned_identities")
    save
    assert_equal "not_recorded", inspect_attempt.dig("resources", "source", "identity")
  end

  def test_sessions_template_changes_and_guest_presence_are_not_cleanup_permission
    @host.runtime.sessions = "2"
    @host.runtime.template_oid = 99
    @host.runtime.guest = "1:2:1000:directory"
    @host.runtime.processes = "present"
    report = inspect_attempt
    assert_equal "present", report["sessions"]
    assert_equal "differs_saved_custody", report["templates"]
    assert_equal "present_identity_not_recorded", report["guest_directory"]
    assert_equal "present", report["current_guest_process"]
    assert_no_authority(report)
    @journal["guest_identity"] = @host.runtime.guest
    save
    assert_equal "present_saved_identity_matches", inspect_attempt["guest_directory"]
    @host.runtime.guest = "1:3:1000:directory"
    assert_equal "present_saved_identity_differs", inspect_attempt["guest_directory"]
  end

  def test_redis_identity_and_running_state_are_only_observations
    @host.runtime.redis_id = "f" * 64
    assert_equal "present_identity_not_recorded", inspect_attempt["redis"]
    @journal["redis_id"] = @host.runtime.redis_id
    save
    assert_equal "present_saved_identity_stopped", inspect_attempt["redis"]
    @host.runtime.redis_running = true
    assert_equal "present_saved_identity_running", inspect_attempt["redis"]
    @host.runtime.redis_label = PRIVATE
    report = inspect_attempt
    assert_equal "present_identity_mismatch", report["redis"]
    assert_no_authority(report)
  end

  def test_failed_redis_and_process_queries_are_unknown_not_absent
    %i[redis process].each do |fault|
      @host.runtime.fault = fault
      report = inspect_attempt
      assert_equal "partial", report["inspection"]
      assert_equal "unknown", report[fault == :redis ? "redis" : "current_guest_process"]
      assert_no_authority(report)
    end
  end

  def test_runtime_drift_or_unavailable_runtime_never_certifies_absence
    @host.runtime.drift_after_sql = true
    report = inspect_attempt
    assert_equal "unproven", report["inspection"]
    assert_equal "unproven", report["runtime"]
    assert_equal "runtime_changed_or_unproven", report["reason"]
    assert_no_authority(report)
    @host.runtime.fault = :all
    assert_equal "unproven", inspect_attempt["runtime"]
  end

  def test_invalid_preparation_and_evidence_bindings_make_no_runtime_calls
    original = JSON.generate(@host.store.state)
    mutations = [
      -> { @host.store.state["runs"][RUN]["status"] = "running" },
      -> { @host.store.state["runs"][RUN]["merge_environment"]["generation"] = "0" * 64 },
      -> { @host.store.state["runs"][RUN]["merge_environment"]["preparation_run_id"] = "run-#{'0' * 32}" },
      -> { @host.store.state["runs"][RUN]["merge_environment"]["phase"] = "dirty" },
      -> { @host.store.state["runs"][RUN]["merge_environment"]["consumed_by"] = "run-#{'0' * 32}" },
      -> { @host.store.state["runs"]["other"] = { "status" => "claimed" } },
      -> { @host.store.state["plans"]["p"]["body"]["operation"] = "standard_merge" }
    ]
    mutations.each do |mutate|
      @host.store.state.replace(JSON.parse(original))
      mutate.call
      assert_equal "preparation_binding_unproven", inspect_attempt["reason"]
      assert_empty @host.runtime.calls
    end
    @host.store.state.replace(JSON.parse(original))
    @receipt["generation"] = "0" * 64
    save
    assert_equal "evidence_unproven", inspect_attempt["reason"]
    assert_empty @host.runtime.calls
    @receipt["generation"] = GENERATION
    @receipt["templates"] = {}
    save
    assert_equal "evidence_unproven", inspect_attempt["reason"]
    assert_empty @host.runtime.calls
  end

  def test_bad_or_missing_evidence_and_busy_locks_fail_closed
    path = @host.send(:mv_path, ID, "json")
    File.write(path, "{corrupt")
    assert_equal "invalid", inspect_attempt.dig("evidence", "receipt")
    File.unlink(path)
    assert_equal "missing", inspect_attempt.dig("evidence", "receipt")
    File.symlink(@host.send(:mv_path, ID, "resources.json"), path)
    assert_equal "invalid", inspect_attempt.dig("evidence", "receipt")
    File.unlink(path)
    File.mkfifo(path, 0o600)
    assert_equal "invalid", inspect_attempt.dig("evidence", "receipt")
    File.unlink(path)
    save
    File.chmod(0o644, path)
    assert_equal "invalid", inspect_attempt.dig("evidence", "receipt")
    @host.store.busy = true
    assert_equal "execution_lock_unavailable", inspect_attempt["reason"]
    assert_empty @host.runtime.calls
  end

  def test_host_staging_metadata_does_not_open_private_contents
    directory = File.join(@root, "validations", ID)
    Dir.mkdir(directory, 0o700)
    File.mkfifo(File.join(directory, "context.json"), 0o600)
    assert_equal "present_private_directory", inspect_attempt["host_staging_directory"]
    FileUtils.remove_entry(directory)
    File.symlink(@root, directory)
    assert_equal "present_unproven", inspect_attempt["host_staging_directory"]
  end

  def test_engineer_cli_is_exact_id_only
    args = ["workflow", "validation-reconcile-inspect", "invented", "--attempt", ID]
    output, error = StringIO.new, StringIO.new
    cli = SiloMigrate::StandardCLI.new(output: output, error: error)
    assert_equal 0, cli.stub(:service, @host) { cli.run(args) }
    assert_empty error.string
    assert_equal "observed", JSON.parse(output.string)["inspection"]
    [args + ["extra"], args + ["--attempt", ID], args[0...-1] + ["latest"], ["agent", *args], args[0...-2]].each do |bad|
      output.truncate(0); output.rewind; error.truncate(0); error.rewind
      assert_equal 1, cli.stub(:service, @host) { cli.run(bad) }
      assert_empty output.string
      assert_equal "Error: STANDARD_ARGUMENTS_INVALID\n", error.string
    end
    [nil, "latest", "../#{ID}", "#{ID}\n", "A" * 32].each do |bad|
      assert_raises(SiloMigrate::StandardWorkflowError) { @host.merge_validation_reconcile_inspect(attempt_id: bad) }
    end
  end

  def test_process_scanner_runs_against_synthetic_proc_without_echoing_arguments
    proc_root = File.join(@root, "proc")
    path = File.join(proc_root, "123", "cmdline")
    FileUtils.mkdir_p(File.dirname(path))
    scan = SiloMigrate::Services::StandardMergeValidationReconciliation::RECONCILE_PROCESS_SCAN.gsub("/proc/", "#{proc_root}/")
    run = lambda do |bytes|
      File.binwrite(path, bytes)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", scan, @journal["guest_directory"], @journal["role"])
      assert status.success?
      assert_empty stderr
      refute_includes stdout, PRIVATE
      stdout
    end
    assert_equal "present", run.call("ruby\0#{@journal['guest_directory']}/merge_validate.rb\0#{PRIVATE}")
    assert_equal "present", run.call("ruby\0--role=#{@journal['role']}\0#{PRIVATE}")
    assert_equal "none_observed", run.call("ruby\0unrelated\0#{PRIVATE}")
    assert_equal "unknown", run.call(PRIVATE * 4000)
  end

  def test_real_store_readonly_locks_never_create_files_and_respect_contention
    store = SiloMigrate::StandardStore.new("locks", env: { "SILO_MIGRATE_BASE_PATH" => @root })
    host_path = File.join(File.dirname(store.workspace_root), ".silo-standard-execution.lock")
    op_path = File.join(store.root, "op.lock")
    assert_raises(Errno::ENOENT) { store.with_read_only_execution_locks { flunk } }
    refute_path_exists host_path
    FileUtils.mkdir_p(store.root, mode: 0o700)
    File.write(host_path, "", perm: 0o600)
    assert_raises(Errno::ENOENT) { store.with_read_only_execution_locks { flunk } }
    refute_path_exists op_path
    File.write(op_path, "", perm: 0o600)
    before = [host_path, op_path].map { |path| [File.binread(path), File.stat(path).mtime] }
    assert_equal :observed, store.with_read_only_execution_locks { :observed }
    assert_equal before, [host_path, op_path].map { |path| [File.binread(path), File.stat(path).mtime] }
    File.open(op_path, File::RDONLY) do |lock|
      assert lock.flock(File::LOCK_EX | File::LOCK_NB)
      assert_raises(SiloMigrate::StandardWorkflowError) { store.with_read_only_execution_locks { flunk } }
    end
    File.chmod(0o644, op_path)
    assert_raises(SiloMigrate::StandardWorkflowError) { store.with_read_only_execution_locks { flunk } }
    File.unlink(op_path)
    File.symlink(host_path, op_path)
    assert_raises(Errno::ELOOP) { store.with_read_only_execution_locks { flunk } }
    File.unlink(op_path)
    File.mkfifo(op_path, 0o600)
    assert_raises(SiloMigrate::StandardWorkflowError) { store.with_read_only_execution_locks { flunk } }
  end
end
