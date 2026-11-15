# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"
require "ostruct"
require_relative "../runtime/prebuilt-discourse/merge_validate"
require_relative "../lib/silo_migrate/services/standard_merge_validation"

class StandardMergeValidationTest < Minitest::Test
  class Store
    attr_reader :root, :events
    attr_accessor :state
    def initialize(root)
      @root, @events = root, []
      @state = { "runs" => { "prep" => { "status" => "completed", "merge_environment" => { "phase" => "ready", "generation" => "a" * 64 } } } }
    end
    def load = state
    def workspace_root = root
    def with_host_lock
      raise "recursive" if @host
      @host = true
      events << :host
      yield
    ensure
      @host = false
    end
    def with_op_lock
      raise "order" unless @host
      raise "recursive" if @op
      @op = true
      events << :op
      yield
    ensure
      @op = false
    end
  end

  class Runtime
    attr_reader :calls
    attr_accessor :cleanup_failure, :custody_changed, :base_bytes, :template_owner, :template_open, :template_sessions
    def initialize
      @calls = []
      @inventory = {}
    end
    def run(argv, **options)
      unless options.key?(:stdin_data)
        output = if argv[1] == "info"
          "fixture-daemon-id"
        elsif argv[1] == "inspect"
          "#{(argv.last.start_with?('web') || argv.last == 'e' * 64) ? 'e' * 64 : 'd' * 64}|true|2026-11-14T00:00:00Z|true|fixture"
        else
          raise "unexpected non-SQL command"
        end
        return OpenStruct.new(success?: true, stdout: output, stderr: "", status: 0)
      end
      sql = options.fetch(:stdin_data)
      calls << [argv, options]
      if sql =~ /CREATE (?:DATABASE|ROLE) (silo_val_[sbr]_[0-9a-f]{32})/
        name = Regexp.last_match(1)
        @inventory[name] = name.include?("_r_") ? [name, "201", *%w[f f f f f f t]] : [name, name.include?("_s_") ? "102" : "101", "10", "postgres"]
      end
      sql.scan(/DROP (?:DATABASE|ROLE)(?: IF EXISTS)? (silo_val_[sbr]_[0-9a-f]{32})/).flatten.each { |name| @inventory.delete(name) unless cleanup_failure }
      output = if sql.include?("silo_validation_identity_")
        name = sql[/silo_val_[sbr]_[0-9a-f]{32}/]
        @inventory[name] ? @inventory.fetch(name).join("|") + "\n" : ""
      elsif sql.include?("silo_validation_producers")
        "0\n"
      elsif sql.include?("silo_validation_recovery_sessions")
        sql.lines.grep(/SELECT count/).map { "0\n" }.join
      elsif sql.include?("silo_validation_owned")
        source = sql[/silo_val_s_[0-9a-f]{32}/]
        base = sql[/silo_val_b_[0-9a-f]{32}/]
        role = sql[/silo_val_r_[0-9a-f]{32}/]
        "#{base}|101|postgres\n#{source}|102|postgres\n#{role}|201|f|f|f|f|f|f|t\n"
      elsif sql.include?("pg_database_size")
        "merge_source|#{custody_changed ? 99 : 11}|#{template_owner || 10}|#{template_open ? 't' : 'f'}|#{template_sessions || 0}|100\nsilo_clean_base|12|#{template_owner || 10}|#{template_open ? 't' : 'f'}|#{template_sessions || 0}|#{base_bytes || 200}\n"
      elsif sql.include?("SELECT count(*) FROM pg_database")
        "0\n0\n"
      else
        ""
      end
      okay = !(cleanup_failure && sql.include?("DROP DATABASE"))
      sql_result(OpenStruct.new(success?: okay, stdout: output, stderr: "PRIVATE NEVER LOG", status: okay ? 0 : 1), argv)
    end
    def sql_result(result, argv)
      return result unless argv.include?("silo-validation-sql") && result.status.is_a?(Integer)
      result.stdout = result.stdout.to_s.sub(/\nSILO_VALIDATION_SQL_DONE:[0-9a-f]{32}:[0-9]+\n\z/, "") + "\nSILO_VALIDATION_SQL_DONE:#{argv.last}:#{result.status}\n"
      result
    end
  end

  class Host
    include SiloMigrate::Services::StandardMergeValidation
    attr_reader :store, :runtime
    attr_accessor :contract_bytes, :settings_bytes, :code_sha, :guest_failure, :guest_exception, :capacity, :layer, :asset_digest, :owner_digest
    def initialize(root)
      @store, @runtime = Store.new(root), Runtime.new
      @store.state["runs"]["prep"]["plan_id"] = "prepare-plan"
      @store.state["plans"] = { "prepare-plan" => { "body" => { "runtime_lock_sha256" => "d" * 64 } } }
      @settings_bytes = "policy: carried\n"
      @code_sha = "b" * 64
      @asset_digest = "e" * 64
      @owner_digest = "d" * 64
      @layer = { "revision" => "c" * 40, "store" => "merger", "present" => true }
      @contract_bytes = JSON.generate({ "version" => 1, "engine" => "discourse-merger-v1", "settings_schema" => { "type" => "object", "properties" => { "policy" => { "type" => "string", "enum" => ["carried"] } }, "required" => ["policy"], "additionalProperties" => false }, "asset_policy_key" => "policy", "asset_policies" => { "carried" => "carried" }, "audit_aggregates" => { "preflight" => ["uploads"], "postflight" => [] } })
    end
    def merger_proposal_layer! = layer
    def merger_contract!(_) = contract_bytes
    def merge_environment_phase(_, env) = env["phase"]
    def merge_validation_context!(**)
      { "settings_bytes" => settings_bytes, "code_sha256" => code_sha, "runtime_sha256" => "d" * 64, "runtime_profile" => {} }
    end
    def merge_validation_execute!(context, journal)
      if context["mode"] == "checks"
        answers = SiloMergeValidation.existence(context.fetch("checks"), query: ->(*) { [] })
        return { "version" => 1, "status" => "passed", "reason" => "ok", "key_path" => [], "checks" => answers, "approved_ids" => [], "audit" => {}, "selected_ids_sha256" => Digest::SHA256.hexdigest("[]"), "selection_sha256" => nil, "asset_preflight_sha256" => nil, "owner_preflight_sha256" => nil }
      end
      raise "secret" if guest_exception
      raise "missing journal" unless File.file?(File.join(store.root, "validations", "#{journal.fetch('id')}.resources.json"))
      klass = Class.new do
        def self.new = raise("constructor forbidden")
        def self.silo_merge_preflight! = true
        def self.silo_merge_asset_ids = [2, 1]
        def self.silo_merge_audit(_) = { "uploads" => 2 }
      end
      klass.define_singleton_method(:silo_merge_preflight!) { false } if guest_failure
      SiloMergeValidation.run!(merger: klass, contract: context.fetch("contract"), settings: { "policy" => "carried" }, asset_preflight: ->(*) { OpenStruct.new(preflight_manifest_digest: asset_digest, selection_digest: "f" * 64, owner_preflight_digest: owner_digest) })
    end
    def review_runtime_for(_) = {}
    def with_review_runtime(_) = yield
    def disk_headroom!(bytes) = @capacity = bytes
    def stack_for(*)
      Object.new.tap do |stack|
        stack.define_singleton_method(:container) { |service| "#{service}-container" }
        stack.define_singleton_method(:record) { { "name" => "fixture", "containers" => { "db" => "d" * 64, "web" => "e" * 64 } } }
      end
    end
    def validate = validate_merge_settings(prepared_from: "prep", generation: "a" * 64, settings: "registered-settings")
    def body(receipt)
      { "prepared_from" => { "run_id" => "prep", "generation" => "a" * 64 }, "roles" => { "settings" => "registered-settings" },
        "code_identity" => code_sha, "runtime_lock_sha256" => "d" * 64,
        "input_binding" => [{ "id" => "registered-settings", "type" => "merge-settings", "bytes" => settings_bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(settings_bytes) }],
        "merge" => { "layer" => layer, "contract" => SiloMergeContract.load(contract_bytes), "process" => receipt.fetch("binding") } }
    end
    def gate(body, **options) = merge_validation_gate!(body, **options)
  end

  def setup
    @validation_mode = ENV.delete(SiloMigrate::Services::StandardMergeValidation::VALIDATION_MODE_ENV)
    @directory = Dir.mktmpdir
    @host = Host.new(@directory)
  end
  def teardown
    key = SiloMigrate::Services::StandardMergeValidation::VALIDATION_MODE_ENV
    @validation_mode.nil? ? ENV.delete(key) : ENV[key] = @validation_mode
    FileUtils.remove_entry(@directory)
  end

  def operator_validation!
    ENV[SiloMigrate::Services::StandardMergeValidation::VALIDATION_MODE_ENV] = "operator"
  end

  def test_operator_copy_can_exceed_chat_budget_without_changing_other_sql_or_cleanup_caps
    operator_validation!
    base_timeouts = []
    clock_runtime do |sql, options, clock, _result|
      clock[0] += 5 if sql.start_with?("CREATE DATABASE silo_val_s_")
      if sql.start_with?("CREATE DATABASE silo_val_b_")
        base_timeouts << options.fetch(:timeout)
        clock[0] += 300
      end
      nil
    end
    receipt = @host.validate
    assert_equal "passed", receipt["status"]
    assert_equal [1795], base_timeouts
    refute receipt.key?("diagnostics")
    # Start must perform its original fresh validation, not skip or auto-rebind it.
    assert @host.gate(@host.body(receipt))
    assert_equal [1795, 1795], base_timeouts
    @host.runtime.calls.each do |_, options|
      sql = options.fetch(:stdin_data)
      next if sql.start_with?("CREATE DATABASE silo_val_")
      assert_operator options.fetch(:timeout), :<=, sql.include?("DROP ") ? 45 : 120
    end
    assert_equal 180, SiloMigrate::Services::StandardMergeValidation::VALIDATION_BUDGET
    assert_equal 1800, SiloMigrate::Services::StandardMergeValidation::OPERATOR_VALIDATION_BUDGET
  end

  def test_operator_clones_share_one_budget_not_a_new_allowance_per_clone
    operator_validation!
    base_timeout = nil
    clock_runtime do |sql, options, clock, _result|
      clock[0] += 1400 if sql.start_with?("CREATE DATABASE silo_val_s_")
      if sql.start_with?("CREATE DATABASE silo_val_b_")
        base_timeout = options.fetch(:timeout)
        clock[0] += 300
      end
      nil
    end
    assert_equal "passed", @host.validate["status"]
    assert_equal 400, base_timeout
  end

  def test_operator_timeout_keeps_full_bounded_diagnostics_and_quarantine
    operator_validation!
    clock_runtime do |sql, options, clock, _result|
      if sql.start_with?("CREATE DATABASE silo_val_b_")
        clock[0] += options.fetch(:timeout)
        next OpenStruct.new(success?: false, status: nil, stdout: "PRIVATE", stderr: "PRIVATE")
      end
      nil
    end
    receipt = @host.validate
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", receipt["reason"]
    assert_equal 1800, receipt.dig("diagnostics", "work", "command_timeout_seconds")
    assert_equal true, receipt.dig("diagnostics", "work", "deadline_reached")
    assert_equal false, receipt["cleanup_confirmed"]
    refute receipt.key?("binding")
    refute @host.runtime.calls.any? { |_, options| options[:stdin_data].include?("DROP DATABASE") }
    refute_includes JSON.generate(receipt), "PRIVATE"
  end

  def test_invalid_validation_mode_fails_before_sql_or_new_journal
    ENV[SiloMigrate::Services::StandardMergeValidation::VALIDATION_MODE_ENV] = "unbounded"
    assert_equal "STANDARD_MERGE_VALIDATION_MODE_INVALID", @host.validate["reason"]
    assert_empty @host.runtime.calls
    assert_empty Dir.glob(File.join(@directory, "validations", "*"))
  end

  def test_operator_exact_existence_checks_use_the_same_long_work_budget
    operator_validation!
    @host.contract_bytes = nil
    timeout = nil
    clock_runtime do |sql, options, clock, _result|
      if sql.start_with?("CREATE DATABASE silo_val_b_")
        timeout = options.fetch(:timeout)
        clock[0] += 300
      end
      nil
    end
    result = @host.merge_exact_existence(prepared_from: "prep", generation: "a" * 64, queries: [{ "kind" => "tag", "name" => "fixture" }])
    assert_equal "passed", result["status"]
    assert_equal 1800, timeout
    refute result.key?("binding")
  end

  # Simulate elapsed monotonic time without slow or oversized fixture databases.
  def clock_runtime(&script)
    clock = [0.0]
    @host.define_singleton_method(:mv_clock) { clock.first }
    original = @host.runtime.method(:run)
    @host.runtime.define_singleton_method(:run) do |argv, **options|
      result = original.call(argv, **options)
      injected = script.call(options.fetch(:stdin_data, ""), options, clock, result)
      injected ? sql_result(injected, argv) : result
    end
    clock
  end

  def test_clone_can_use_remaining_global_budget_past_the_old_sql_cap
    clone_timeout = nil
    clock_runtime do |sql, options, clock, _result|
      clock[0] += 5 if sql.start_with?("CREATE DATABASE silo_val_s_")
      if sql.start_with?("CREATE DATABASE silo_val_b_")
        clone_timeout = options.fetch(:timeout)
        if clone_timeout < 125
          next OpenStruct.new(success?: false, status: nil, stdout: "PRIVATE", stderr: "PRIVATE")
        end
        clock[0] += 125
      end
      nil
    end
    result = @host.validate
    assert_equal "passed", result["status"]
    assert_equal 175, clone_timeout
    refute result.key?("diagnostics")
    assert_equal 180, SiloMigrate::Services::StandardMergeValidation::VALIDATION_BUDGET
    assert_equal 45, SiloMigrate::Services::StandardMergeValidation::VALIDATION_CLEANUP_BUDGET
    cleanup = @host.runtime.calls.select { |_, options| options[:stdin_data].include?("DROP ") }
    refute_empty cleanup
    assert cleanup.all? { |_, options| options.fetch(:timeout) <= 45 }
  end

  def test_clone_does_not_receive_a_fresh_budget_after_earlier_work
    clone_timeout = nil
    clock_runtime do |sql, options, clock, _result|
      clock[0] += 130 if sql.start_with?("CREATE DATABASE silo_val_s_")
      clone_timeout = options.fetch(:timeout) if sql.start_with?("CREATE DATABASE silo_val_b_")
      nil
    end
    assert_equal "passed", @host.validate["status"]
    assert_equal 50, clone_timeout
  end

  def test_expired_work_deadline_refuses_before_next_clone_command
    clock_runtime do |sql, _options, clock, _result|
      clock[0] += 60 if sql.start_with?("CREATE DATABASE silo_val_s_")
      clock[0] += 120 if sql.include?("DO $silo_validation$")
      nil
    end
    result = @host.validate
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", result["reason"]
    assert_equal "clone_base", result.dig("diagnostics", "work", "step")
    assert_equal true, result.dig("diagnostics", "work", "deadline_reached")
    refute result.fetch("diagnostics").fetch("work").key?("command_timeout_seconds")
    refute @host.runtime.calls.any? { |_, options| options[:stdin_data].start_with?("CREATE DATABASE silo_val_b_") }
  end

  def test_unknown_clone_outcome_retains_bounded_evidence_and_stays_quarantined
    clock_runtime do |sql, options, clock, _result|
      if sql.start_with?("CREATE DATABASE silo_val_b_")
        clock[0] += options.fetch(:timeout)
        next OpenStruct.new(success?: false, status: nil, stdout: "PRIVATE_OUTPUT", stderr: "PRIVATE_PASSWORD")
      end
      nil
    end
    result = @host.validate
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", result["reason"]
    assert_equal false, result["cleanup_confirmed"]
    assert_equal({ "step" => "clone_base", "reason" => "STANDARD_MERGE_VALIDATION_UNPROVEN", "error_class" => "other",
      "deadline_reached" => true, "command_outcome" => "timeout_or_interrupted", "command_timeout_seconds" => 180 },
      result.fetch("diagnostics").fetch("work"))
    refute result.key?("binding")
    refute @host.runtime.calls.any? { |_, options| options[:stdin_data].include?("DROP DATABASE") }
    journal = JSON.parse(File.read(File.join(@directory, "validations", "#{result.fetch('receipt_id')}.resources.json")))
    refute journal["provision_complete"]
    refute journal.key?("owned_identities")
    assert_equal false, journal["cleanup_confirmed"]
    count = @host.runtime.calls.size
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", @host.validate["reason"]
    assert_equal count, @host.runtime.calls.size
    assert_equal "ready", @host.store.state.dig("runs", "prep", "merge_environment", "phase")
    bytes = File.read(File.join(@directory, "validations", "#{result.fetch('receipt_id')}.json"))
    refute_includes bytes, "PRIVATE"
    refute_includes bytes, "CREATE DATABASE"
    password = @host.runtime.calls.map { |_, options| options[:stdin_data][/PASSWORD '([^']+)'/, 1] }.compact.first
    refute_includes bytes, password
  end

  def test_known_sql_failure_has_a_distinct_fixed_outcome
    clock_runtime do |sql, _options, _clock, _result|
      next OpenStruct.new(success?: false, status: 1, stdout: "PRIVATE", stderr: "PRIVATE") if sql.start_with?("CREATE DATABASE silo_val_b_")
      nil
    end
    result = @host.validate
    assert_equal "failed", result.dig("diagnostics", "work", "command_outcome")
    assert_equal false, result.dig("diagnostics", "work", "deadline_reached")
    assert_equal "clone_base", result.dig("diagnostics", "work", "step")
    refute_includes JSON.generate(result), "PRIVATE"
  end

  def test_checks_only_setup_failure_uses_the_same_diagnostics_and_fence
    @host.contract_bytes = nil
    clock_runtime do |sql, _options, _clock, _result|
      next OpenStruct.new(success?: false, status: nil, stdout: "PRIVATE", stderr: "PRIVATE") if sql.start_with?("CREATE DATABASE silo_val_b_")
      nil
    end
    result = @host.merge_exact_existence(prepared_from: "prep", generation: "a" * 64, queries: [{ "kind" => "tag", "name" => "fixture" }])
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", result["reason"]
    assert_equal "clone_base", result.dig("diagnostics", "work", "step")
    assert_equal "timeout_or_interrupted", result.dig("diagnostics", "work", "command_outcome")
    assert_equal false, result["cleanup_confirmed"]
    refute result.key?("binding")
  end

  def test_guest_error_does_not_inherit_the_last_sql_timeout_metadata
    @host.guest_exception = true
    result = @host.validate
    diagnostic = result.fetch("diagnostics").fetch("work")
    assert_equal "guest_validation", diagnostic["step"]
    assert_equal "STANDARD_MERGE_VALIDATION_UNPROVEN", diagnostic["reason"]
    refute diagnostic.key?("command_outcome")
    refute diagnostic.key?("command_timeout_seconds")
    refute_includes JSON.generate(result), "secret"
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", result["reason"]
  end

  def test_cleanup_failure_is_separate_from_successful_work
    @host.runtime.cleanup_failure = true
    result = @host.validate
    assert_equal ["cleanup"], result.fetch("diagnostics").keys
    assert_equal "cleanup_source", result.dig("diagnostics", "cleanup", "step")
    assert_equal "failed", result.dig("diagnostics", "cleanup", "command_outcome")
    assert_operator result.dig("diagnostics", "cleanup", "command_timeout_seconds"), :<=, 45
  end

  def test_failure_diagnostics_never_copy_arbitrary_context_or_exception_text
    value = @host.send(:mv_failure_diagnostic,
      { "validation_step" => "PRIVATE", "sql_outcome" => "PRIVATE", "sql_timeout_seconds" => "PRIVATE", "deadline" => "PRIVATE" },
      SiloMigrate::StandardWorkflowError.new("PRIVATE", "PRIVATE"))
    assert_equal({ "step" => "unknown", "error_class" => "other", "reason" => "STANDARD_MERGE_VALIDATION_UNPROVEN", "deadline_reached" => nil }, value)
  end

  def test_nonclone_sql_keeps_the_default_120_second_cap
    @host.define_singleton_method(:mv_clock) { 0.0 }
    @host.send(:mv_sql!, { "prepared_from" => "prep", "deadline" => 180.0 }, "SELECT 1")
    assert_equal 120, @host.runtime.calls.last.last.fetch(:timeout)
    @host.send(:mv_sql!, { "prepared_from" => "prep", "deadline" => 45.0 }, "SELECT 1")
    assert_equal 45, @host.runtime.calls.last.last.fetch(:timeout)
  end

  def test_direct_sql_adapter_accepts_an_immutable_context_without_mutating_it
    @host.define_singleton_method(:mv_clock) { 0.0 }
    context = { "prepared_from" => "prep", "deadline" => 180.0 }.freeze
    original = context.dup
    @host.send(:mv_sql!, context, "SELECT 1")
    assert_equal original, context
    assert_equal 120, @host.runtime.calls.last.last.fetch(:timeout)
  end

  def test_passing_private_receipt_clone_sql_and_locks
    result = @host.validate
    assert_equal "passed", result["status"]
    assert_equal [:host, :op], @host.store.events
    assert_equal "f" * 64, result.dig("binding", "selection_sha256")
    assert_equal "d" * 64, result.dig("binding", "owner_preflight_sha256")
    assert_equal Digest::SHA256.hexdigest(@host.settings_bytes), result.dig("binding", "settings_sha256")
    assert_equal 300 + 512 * 1024 * 1024, @host.capacity
    sql = @host.runtime.calls.map { |_, options| options[:stdin_data] }.join
    assert_match(/CREATE DATABASE silo_val_s_.* TEMPLATE merge_source OWNER postgres/, sql)
    assert_match(/CREATE DATABASE silo_val_b_.* TEMPLATE silo_clean_base OWNER postgres/, sql)
    assert_match(/NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT/, sql)
    assert_match(/REVOKE CREATE, TEMPORARY/, sql)
    assert_match(/GRANT SELECT ON ALL TABLES/, sql)
    grants = @host.runtime.calls.select { |_, options| options[:stdin_data].include?("DO $silo_validation$") }
    assert_equal 2, grants.size
    grants.each do |argv, options|
      assert_match(/\Asilo_val_[sb]_[0-9a-f]{32}\z/, (argv.include?("silo-validation-sql") ? argv[-2] : argv[argv.index("-d") + 1]))
      assert_includes options[:stdin_data], "FROM pg_namespace"
      assert_includes options[:stdin_data], "nspname <> 'information_schema' AND nspname !~ '^pg_'"
      assert_includes options[:stdin_data], "format('REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA %I FROM PUBLIC', application_schema)"
      assert_includes options[:stdin_data], "format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', application_schema)"
    end
    refute_match(/ALTER DATABASE (?:merge_source|silo_clean_base)|RENAME TO|GRANT.*discourse/, sql)
    @host.runtime.calls.each do |argv, options|
      # The fixed terminal-proof shell wrapper has -c; SQL still arrives only
      # on stdin, never as psql -c or interpolated shell source.
      if argv.include?("silo-validation-sql")
        assert_equal "sh", argv[argv.index("-c") - 1]
        assert_includes argv[argv.index("-c") + 1], 'psql -X -q -v ON_ERROR_STOP=1'
      else
        refute argv.include?("-c")
      end
      refute_includes argv.join(" "), "PASSWORD"
      assert options[:stdin_data]
    end
    assert @host.gate(@host.body(result))
    assert_equal "ready", @host.store.state.dig("runs", "prep", "merge_environment", "phase")
    path = File.join(@directory, "validations", "#{result['receipt_id']}.json")
    assert_equal 0, File.stat(path).mode & 0o077
    refute_includes File.read(path), "password"
  end

  def test_schema_failure_does_not_provision_or_consume
    @host.settings_bytes = "policy: carried\nextra: forbidden\n"
    result = @host.validate
    assert_equal "refused", result["status"]
    assert_equal ["extra"], result["key_path"]
    assert_empty @host.runtime.calls
    assert_equal "ready", @host.store.state.dig("runs", "prep", "merge_environment", "phase")
  end

  def large_contract!
    value = JSON.parse(@host.contract_bytes)
    25.times do |index|
      description = index.zero? ? "é" * 512 : "x" * 1024
      value["settings_schema"]["properties"]["option_#{index}"] = { "type" => "string", "description" => description }
    end
    @host.contract_bytes = JSON.generate(value)
  end

  def test_large_contract_is_available_as_digest_bound_private_paged_derivative
    large_contract!
    assert_operator @host.contract_bytes.bytesize, :>, 24 * 1024
    assert_operator @host.contract_bytes.bytesize, :<, 30 * 1024
    described = @host.merge_contract
    file = described.fetch("contract_file")
    assert_equal "work", file["area"]
    path = File.join(@directory, "work", file.fetch("path"))
    assert_equal @host.contract_bytes.b, File.binread(path)
    assert_equal Digest::SHA256.file(path).hexdigest, file.fetch("sha256")
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal described, @host.merge_contract
  end

  def test_concurrent_contract_describes_publish_complete_identical_derivatives
    large_contract!
    ready, release = Queue.new, Queue.new
    threads = 12.times.map do
      Thread.new { ready << true; release.pop; @host.merge_contract }
    end
    12.times { ready.pop }
    12.times { release << true }
    results = threads.map(&:value)
    assert_equal 1, results.uniq.size
    assert_empty Dir.glob(File.join(@directory, "work", "workflow-contracts", "*.tmp"))
    file = results.first.fetch("contract_file")
    assert_equal @host.contract_bytes.b, File.binread(File.join(@directory, "work", file.fetch("path")))
  end

  def test_contract_derivative_refuses_symlink_with_contract_specific_code
    large_contract!
    file = @host.merge_contract.fetch("contract_file")
    path = File.join(@directory, "work", file.fetch("path"))
    File.unlink(path)
    File.symlink("missing-private-target", path)
    error = assert_raises(SiloMigrate::StandardWorkflowError) { @host.merge_contract }
    assert_equal "STANDARD_MERGE_CONTRACT_INVALID", error.code
  end

  def test_private_result_key_path_is_bounded_and_json_compatible
    good = @host.validate
    context = { "contract" => SiloMergeContract.load(@host.contract_bytes) }
    result = good.slice(*SiloMigrate::Services::StandardMergeValidation::VALIDATION_RESULT_KEYS)
    result.merge!("status" => "refused", "reason" => "destination_missing")
    [[Object.new], ["x" * 257], ["\xFF".b], [-1], Array.new(33, "key")].each do |path|
      error = assert_raises(SiloMigrate::StandardWorkflowError) do
        @host.send(:mv_result!, result.merge("key_path" => path), context, [])
      end
      assert_equal "STANDARD_MERGE_VALIDATION_PROTOCOL", error.code
    end
    assert_equal ["routes", 1], @host.send(:mv_result!, result.merge("key_path" => ["routes", 1]), context, []).fetch("key_path")
  end

  def test_expired_validation_budget_refuses_before_sql_or_resources
    @host.define_singleton_method(:mv_clock) { 100.0 }
    assert_equal 3, @host.send(:mv_timeout, { "deadline" => 102.25 }, 60)
    error = assert_raises(SiloMigrate::StandardWorkflowError) do
      @host.send(:mv_validate!, prepared_from: "prep", generation: "a" * 64, settings: "settings", checks: [], deadline: 99.0)
    end
    assert_equal "STANDARD_MERGE_VALIDATION_UNPROVEN", error.code
    assert_empty @host.runtime.calls
    assert_empty Dir.glob(File.join(@directory, "validations", "*.resources.json"))
    assert_equal "ready", @host.store.state.dig("runs", "prep", "merge_environment", "phase")
  end

  def test_missing_contract_is_explicit
    @host.contract_bytes = nil
    assert_equal "STANDARD_MERGE_CONTRACT_REQUIRED", @host.validate["reason"]
    assert_empty @host.runtime.calls
  end

  def test_duplicate_yaml_is_refused_before_clone
    @host.settings_bytes = "policy: carried\npolicy: carried\n"
    assert_equal "STANDARD_MERGE_SETTINGS_INVALID", @host.validate["reason"]
    assert_empty @host.runtime.calls
  end

  def test_hook_refusal_cleans_and_keeps_ready
    @host.guest_failure = true
    result = @host.validate
    assert_equal "preflight_refused", result["reason"]
    assert_equal true, result["cleanup_confirmed"]
    refute result.key?("binding")
    assert_equal "ready", @host.store.state.dig("runs", "prep", "merge_environment", "phase")
    @host.guest_failure = false
    assert_equal "passed", @host.validate["status"]
  end

  def test_refused_validation_retains_partial_private_audit_without_consuming_ready_state
    before = JSON.generate(@host.store.state)
    @host.guest_failure = true
    result = @host.validate
    assert_equal "preflight_refused", result["reason"]
    assert_equal true, result["cleanup_confirmed"]
    assert_equal({ "uploads" => 2 }, result["audit"])
    assert_equal result["audit"], result.dig("failure", "counts")
    assert_equal "partial", result.dig("failure", "audit_status")
    assert_equal "read_only_clones", result.dig("failure", "write_boundary")
    assert_equal false, result.dig("failure", "complete")
    refute result.key?("binding")
    assert_equal before, JSON.generate(@host.store.state)
    path = File.join(@directory, "validations", "#{result.fetch('receipt_id')}.json")
    assert_equal result["failure"], JSON.parse(File.binread(path)).fetch("failure")
    assert_equal 0o600, File.stat(path).mode & 0o777
  end

  def test_real_duplicate_detecting_wire_parser_preserves_typed_refusal_during_normalization
    @host.guest_failure = true
    receipt = @host.validate
    keys = SiloMigrate::Services::StandardMergeValidation::VALIDATION_RESULT_KEYS + ["failure"]
    wire = SiloMergeContract.parse(JSON.generate(receipt.slice(*keys)))
    assert_instance_of SiloMergeContract::UniqueObject, wire
    checked = @host.send(:mv_result!, wire, { "contract" => SiloMergeContract.load(@host.contract_bytes) }, [])
    assert_instance_of Hash, checked
    assert_equal "refused", checked["status"]
    assert_equal "preflight_refused", checked["reason"]
    assert_equal checked.fetch("audit"), checked.dig("failure", "counts")
    assert_equal "partial", checked.dig("failure", "audit_status")
    assert_raises(SiloMergeContract::Error) { SiloMergeContract.parse('{"status":"refused","status":"passed"}') }
  end

  def test_bad_optional_audit_evidence_does_not_mask_a_valid_primary_refusal
    @host.guest_failure = true
    receipt = @host.validate
    keys = SiloMigrate::Services::StandardMergeValidation::VALIDATION_RESULT_KEYS + ["failure"]
    context = { "contract" => SiloMergeContract.load(@host.contract_bytes) }
    [->(record) { record["failure"]["counts"] = { "PRIVATE_DYNAMIC_KEY" => 1 } },
     ->(record) { record["failure"]["reason"] = "assets_unproven" },
     ->(record) { record["audit"] = { "PRIVATE_DYNAMIC_KEY" => 1 } },
     ->(record) { record["failure"] = nil }].each do |corrupt|
      record = JSON.parse(JSON.generate(receipt.slice(*keys)))
      corrupt.call(record)
      checked = @host.send(:mv_result!, record, context, [])
      assert_equal "refused", checked["status"]
      assert_equal "preflight_refused", checked["reason"]
      assert_equal "invalid", checked.dig("failure", "audit_status")
      assert_equal({}, checked["audit"])
      assert_equal ["uploads"], checked.dig("failure", "missing_keys")
      refute_includes JSON.generate(checked), "PRIVATE_DYNAMIC_KEY"
    end
  end

  def test_legacy_refusal_shape_remains_accepted_without_synthesizing_zero_metrics
    @host.guest_failure = true
    legacy = @host.validate.slice(*SiloMigrate::Services::StandardMergeValidation::VALIDATION_RESULT_KEYS)
    checked = @host.send(:mv_result!, legacy, { "contract" => SiloMergeContract.load(@host.contract_bytes) }, [])
    assert_equal legacy, checked
    refute checked.key?("failure")
  end

  def test_legacy_refusal_audit_discards_undeclared_or_nonnumeric_values
    @host.guest_failure = true
    legacy = @host.validate.slice(*SiloMigrate::Services::StandardMergeValidation::VALIDATION_RESULT_KEYS)
    context = { "contract" => SiloMergeContract.load(@host.contract_bytes) }
    [{ "PRIVATE_KEY" => "PRIVATE_VALUE" }, { "uploads" => -1 }, { "uploads" => "PRIVATE_VALUE" }].each do |audit|
      checked = @host.send(:mv_result!, legacy.merge("audit" => audit), context, [])
      assert_equal "preflight_refused", checked["reason"]
      assert_equal({}, checked["audit"])
      refute checked.key?("failure")
      refute_includes JSON.generate(checked), "PRIVATE"
    end
  end

  def test_success_cannot_carry_a_refusal_envelope
    passed = @host.validate.slice(*SiloMigrate::Services::StandardMergeValidation::VALIDATION_RESULT_KEYS)
    contract = SiloMergeContract.load(@host.contract_bytes)
    failure = SiloMergeRefusal.capture(contract: contract, merger: nil, phase: "preflight", context: "validation", reason: "preflight_refused")
    error = assert_raises(SiloMigrate::StandardWorkflowError) do
      @host.send(:mv_result!, passed.merge("failure" => failure), { "contract" => contract }, [])
    end
    assert_equal "STANDARD_MERGE_VALIDATION_PROTOCOL", error.code
  end

  def test_cleanup_failure_blocks_further_validation_and_start_without_dirtying_template
    @host.runtime.cleanup_failure = true
    result = @host.validate
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", result["reason"]
    assert_equal false, result["cleanup_confirmed"]
    @host.runtime.cleanup_failure = false
    count = @host.runtime.calls.size
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", @host.validate["reason"]
    assert_equal count, @host.runtime.calls.size
    error = assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate({}) }
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", error.code
    assert_equal "ready", @host.store.state.dig("runs", "prep", "merge_environment", "phase")
  end

  def test_exception_unknown_outcome_stays_quarantined_even_after_empty_catalogue
    @host.guest_exception = true
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", @host.validate["reason"]
    @host.guest_exception = false
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", @host.validate["reason"]
  end

  def test_stale_settings_and_code_are_not_reused
    result = @host.validate
    body = @host.body(result)
    @host.settings_bytes = "policy: carried\n#changed\n"
    assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate(body) }
    @host.settings_bytes = "policy: carried\n"
    @host.code_sha = "9" * 64
    assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate(body) }
  end

  def test_size_change_during_clone_keeps_original_capacity_snapshot_and_completes_cleanup
    runtime = @host.runtime
    clock_runtime do |sql, _options, _clock, _result|
      runtime.base_bytes = 8392 if sql.start_with?("CREATE DATABASE silo_val_b_")
      nil
    end
    result = @host.validate
    assert_equal "passed", result["status"]
    assert_equal true, result["cleanup_confirmed"]
    refute result.key?("diagnostics")
    receipt = JSON.parse(File.read(File.join(@directory, "validations", "#{result.fetch('receipt_id')}.json")))
    assert_equal 200, receipt.dig("templates", "silo_clean_base", "bytes")
    assert_equal 300 + SiloMigrate::Services::StandardMergeValidation::VALIDATION_ALLOWANCE, @host.capacity
    journal = JSON.parse(File.read(File.join(@directory, "validations", "#{result.fetch('receipt_id')}.resources.json")))
    assert_equal 200, journal.dig("templates", "silo_clean_base", "bytes")
    assert_equal true, journal["provision_complete"]
    assert_equal true, journal["cleanup_confirmed"]
  end

  def test_size_change_after_guest_does_not_make_confirmed_cleanup_a_failure
    original = @host.method(:merge_validation_execute!)
    @host.define_singleton_method(:merge_validation_execute!) do |context, journal|
      result = original.call(context, journal)
      runtime.base_bytes = 192
      result
    end
    result = @host.validate
    assert_equal "passed", result["status"]
    assert_equal true, result["cleanup_confirmed"]
    assert_equal 200, result.dig("templates", "silo_clean_base", "bytes")
    refute result.key?("diagnostics")
  end

  def test_preclaim_size_changes_revalidate_without_rebinding_or_rewriting_approved_receipt
    result = @host.validate
    body = @host.body(result)
    binding = Marshal.load(Marshal.dump(body.dig("merge", "process")))
    path = File.join(@directory, "validations", "#{result.fetch('receipt_id')}.json")
    bytes = File.binread(path)
    @host.runtime.base_bytes = 8392
    assert @host.gate(body)
    assert_equal binding, body.dig("merge", "process")
    assert_equal bytes, File.binread(path)
    receipts = Dir.glob(File.join(@directory, "validations", "*.json")).reject { |file| file.end_with?(".resources.json") }.map { |file| JSON.parse(File.read(file)) }
    assert_equal [200, 8392], receipts.map { |receipt| receipt.dig("templates", "silo_clean_base", "bytes") }.sort
    assert_equal 4, @host.runtime.calls.count { |_, options| options[:stdin_data].start_with?("CREATE DATABASE") }
    assert_equal "ready", @host.store.state.dig("runs", "prep", "merge_environment", "phase")
  end

  def test_checks_only_size_drift_still_completes_and_issues_no_start_binding
    runtime = @host.runtime
    clock_runtime do |sql, _options, _clock, _result|
      runtime.base_bytes = 8392 if sql.start_with?("CREATE DATABASE silo_val_b_")
      nil
    end
    result = @host.merge_exact_existence(prepared_from: "prep", generation: "a" * 64, queries: [{ "kind" => "tag", "name" => "fixture" }])
    assert_equal "passed", result["status"]
    assert_equal true, result["cleanup_confirmed"]
    refute result.key?("binding")
    refute result.key?("diagnostics")
  end

  def test_identity_change_during_clone_still_quarantines_without_finalized_ownership
    runtime = @host.runtime
    clock_runtime do |sql, _options, _clock, _result|
      runtime.custody_changed = true if sql.start_with?("CREATE DATABASE silo_val_b_")
      nil
    end
    result = @host.validate
    assert_equal "STANDARD_MERGE_TEMPLATE_CUSTODY", result.dig("diagnostics", "work", "reason")
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", result["reason"]
    assert_equal false, result["cleanup_confirmed"]
    journal = JSON.parse(File.read(File.join(@directory, "validations", "#{result.fetch('receipt_id')}.resources.json")))
    refute journal["provision_complete"]
    refute journal.key?("owned_identities")
    refute @host.runtime.calls.any? { |_, options| options[:stdin_data].include?("DROP DATABASE") }
  end

  def test_owner_open_connection_and_active_session_changes_still_refuse_gate
    result = @host.validate
    body = @host.body(result)
    before = @host.runtime.calls.count { |_, options| options[:stdin_data].start_with?("CREATE DATABASE") }
    { template_owner: 11, template_open: true, template_sessions: 1 }.each do |key, value|
      @host.runtime.public_send("#{key}=", value)
      assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate(body) }
      @host.runtime.public_send("#{key}=", nil)
    end
    assert_equal before, @host.runtime.calls.count { |_, options| options[:stdin_data].start_with?("CREATE DATABASE") }
    assert_equal "ready", @host.store.state.dig("runs", "prep", "merge_environment", "phase")
  end

  def test_custody_comparison_validates_complete_typed_snapshots_and_never_mutates_them
    original = @host.send(:mv_custody!, { "prepared_from" => "prep" })
    changed = Marshal.load(Marshal.dump(original))
    changed.fetch("silo_clean_base")["bytes"] += 8192
    assert @host.send(:mv_same_template_custody?, changed, original)
    assert_equal 200, original.dig("silo_clean_base", "bytes")
    assert_equal 8392, changed.dig("silo_clean_base", "bytes")
    [nil, {}, original.reject { |name, _| name == "merge_source" }, original.merge("extra" => {})].each do |bad|
      refute @host.send(:mv_same_template_custody?, bad, original)
      refute @host.send(:mv_same_template_custody?, original, bad)
    end
    { "oid" => [nil, 0, "12", true], "owner" => [nil, 0, 10.0, false], "bytes" => [nil, -1, "200", 200.0, true] }.each do |key, values|
      values.each do |value|
        bad = Marshal.load(Marshal.dump(original))
        bad.fetch("silo_clean_base")[key] = value
        refute @host.send(:mv_same_template_custody?, bad, original)
      end
    end
    bad = Marshal.load(Marshal.dump(original)); bad.fetch("silo_clean_base")["extra"] = true
    refute @host.send(:mv_same_template_custody?, bad, original)
  end

  def test_size_change_does_not_bypass_asset_freshness_or_policy_refusal
    result = @host.validate
    @host.runtime.base_bytes = 8392
    @host.asset_digest = "8" * 64
    error = assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate(@host.body(result)) }
    assert_equal "STANDARD_MERGE_VALIDATION_STALE", error.code
    @host.asset_digest = "e" * 64
    @host.guest_failure = true
    refused = @host.validate
    assert_equal "refused", refused["status"]
    assert_equal true, refused["cleanup_confirmed"]
    refute refused.key?("binding")
  end

  def test_custody_change_refuses_gate
    result = @host.validate
    @host.runtime.custody_changed = true
    assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate(@host.body(result)) }
  end

  def test_corrupt_journal_identifiers_refuse_before_any_sql_or_cleanup
    id = "1" * 32
    valid = { "id" => id, "source" => "silo_val_s_#{id}", "base" => "silo_val_b_#{id}", "role" => "silo_val_r_#{id}" }
    corruptions = {
      "id" => "1" * 31, "source" => "merge_source; DROP DATABASE discourse", "base" => "silo_clean_base", "role" => "postgres",
      "guest_directory" => "/shared", "redis" => "original-redis", "redis_id" => "not-a-full-container-id"
    }
    corruptions.each do |key, value|
      journal = valid.merge(key => value)
      [[:mv_provision!, {}, journal, "a" * 64], [:mv_owned_identities!, {}, journal], [:mv_cleanup!, {}, journal]].each do |arguments|
        assert_raises(SiloMigrate::StandardWorkflowError) { @host.send(*arguments) }
        assert_empty @host.runtime.calls
      end
    end
    [nil, "", "a" * 63, "'injected'", 12, ("a" * 63 + 255.chr).force_encoding("UTF-8")].each do |password|
      assert_raises(SiloMigrate::StandardWorkflowError) { @host.send(:mv_provision!, {}, valid, password) }
      assert_empty @host.runtime.calls
    end
    assert_same valid, @host.send(:mv_journal!, valid)
    assert_raises(SiloMigrate::StandardWorkflowError) { @host.send(:mv_journal!, valid.merge("redis_id" => "a" * 64)) }
    assert @host.send(:mv_journal!, valid.merge("redis" => "silo-val-redis-#{id}", "redis_id" => "a" * 64, "guest_directory" => "/shared/silo-validation-#{id}"))
  end

  def test_malformed_cleaned_journal_still_blocks_gate_without_sql
    id = "1" * 32
    journal = { "id" => id, "source" => "merge_source", "base" => "silo_val_b_#{id}", "role" => "silo_val_r_#{id}", "status" => "cleaned", "cleanup_confirmed" => true }
    @host.send(:mv_write!, @host.send(:mv_path, id, "resources.json"), journal)
    error = assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate({}) }
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", error.code
    assert_empty @host.runtime.calls
  end

  def test_validation_helper_digest_binds_adapter_assets_and_contract
    context = { "code_sha256" => "a" * 64 }
    original = File.method(:binread)
    before = @host.send(:mv_facts, context).fetch("validation_code_sha256")
    %w[merge_adapter.rb merge_assets.rb merge_contract.rb].each do |filename|
      reader = lambda do |path, *arguments|
        bytes = original.call(path, *arguments)
        File.basename(path) == filename ? bytes + "# invented changed helper bytes" : bytes
      end
      File.stub(:binread, reader) do
        refute_equal before, @host.send(:mv_facts, context).fetch("validation_code_sha256")
      end
    end
  end

  def test_owner_feasibility_digest_drift_refuses_preclaim_without_rebinding
    result = @host.validate
    body = @host.body(result)
    @host.owner_digest = "8" * 64
    error = assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate(body) }
    assert_equal "STANDARD_MERGE_VALIDATION_STALE", error.code
    assert_equal "d" * 64, body.dig("merge", "process", "owner_preflight_sha256")
    assert_equal "ready", @host.store.state.dig("runs", "prep", "merge_environment", "phase")
  end

  def test_preclaim_revalidates_asset_bytes_without_rebinding_approved_receipt
    result = @host.validate
    body = @host.body(result)
    original_binding = Marshal.load(Marshal.dump(body["merge"]["process"]))
    @host.asset_digest = "8" * 64
    error = assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate(body) }
    assert_equal "STANDARD_MERGE_VALIDATION_STALE", error.code
    assert_equal original_binding, body["merge"]["process"]
    assert_equal "ready", @host.store.state.dig("runs", "prep", "merge_environment", "phase")
    clones = @host.runtime.calls.count { |_, options| options.fetch(:stdin_data, "").start_with?("CREATE DATABASE") }
    assert_equal 4, clones
    journals = Dir.glob(File.join(@directory, "validations", "*.resources.json")).map { |path| JSON.parse(File.read(path)) }
    assert journals.all? { |journal| journal["cleanup_confirmed"] }
  end

  def test_new_preclaim_policy_refusal_is_clean_and_does_not_consume
    result = @host.validate
    @host.guest_failure = true
    assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate(@host.body(result)) }
    assert_equal "ready", @host.store.state.dig("runs", "prep", "merge_environment", "phase")
    @host.guest_failure = false
    assert_equal "passed", @host.validate["status"]
  end

  def test_exact_checks_need_no_layer_contract_or_settings
    @host.contract_bytes = nil
    result = @host.merge_exact_existence(prepared_from: "prep", generation: "a" * 64, queries: [{ "kind" => "tag", "name" => "fixture" }])
    assert_equal "passed", result["status"]
    assert_equal [{ "status" => "absent", "count" => 0 }], result["checks"]
    assert_equal true, result["cleanup_confirmed"]
    refute result.key?("binding")
  end

  def test_malformed_checks_refuse_before_provision
    result = @host.validate_merge_settings(prepared_from: "prep", generation: "a" * 64, settings: "registered-settings", checks: [{ "kind" => "sql", "name" => "SELECT secret" }])
    assert_equal "STANDARD_MERGE_CHECKS_INVALID", result["reason"]
    assert_empty @host.runtime.calls
  end

  def test_plan_metadata_tampering_refuses_without_provision
    result = @host.validate
    body = @host.body(result)
    body["merge"]["contract"]["version"] = 2
    before = @host.runtime.calls.size
    assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate(body) }
    assert_equal before, @host.runtime.calls.size
  end

  def test_claimed_backstop_only_accepts_exact_running_owner_plan_before_fencing
    result = @host.validate
    body = @host.body(result)
    state = @host.store.state
    state["runs"]["prep"]["merge_environment"].merge!("phase" => "consumed", "consumed_by" => "merge")
    state["runs"]["merge"] = { "status" => "running", "plan_id" => "plan" }
    state["plans"] = { "plan" => { "body" => body } }
    assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate(body) }
    assert @host.gate(body, claimed_run_id: "merge")
    assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate(body, claimed_run_id: "other") }
    state["runs"]["prep"]["merge_environment"]["phase"] = "fencing"
    assert_raises(SiloMigrate::StandardWorkflowError) { @host.gate(body, claimed_run_id: "merge") }
  end
end

# Scripted production bridge: real private file staging, no Docker/PG processes.
class MergeValidationTransportTest < Minitest::Test
  class TransportRuntime < StandardMergeValidationTest::Runtime
    attr_accessor :image_mismatch
    def redis_document
      { "Id" => "sha256:#{'8' * 64}", "Architecture" => "amd64", "Os" => "linux", "RootFS" => { "Layers" => [] }, "Config" => {} }
    end
    def guest_created! = @guest_present = true
    def run(argv, **options)
      return super if options[:stdin_data] || argv[1] == "info" || (argv[1] == "inspect" && argv.last != "9" * 64)
      calls << [argv, options]
      output = case argv[0, 2]
      when %w[docker image]
        JSON.generate([image_mismatch ? redis_document.merge("Os" => "other") : redis_document])
      when %w[docker create]
        @redis_attempt = argv[argv.index("--name") + 1].delete_prefix("silo-val-redis-")
        @redis_present = true
        "#{'9' * 64}\n"
      when %w[docker inspect] then "#{'9' * 64}|#{@redis_attempt}|true|true\n"
      when %w[docker container] then @redis_present ? "#{'9' * 64}\n" : ""
      when %w[docker rm]
        @redis_present = false
        ""
      when %w[docker exec]
        if argv.include?("silo-validation-stat")
          @guest_present ? "1:123:1000:directory" : "absent"
        elsif argv.include?("rm")
          @guest_present = false
          ""
        else
          "PONG\n"
        end
      else ""
      end
      OpenStruct.new(success?: true, stdout: output, status: 0)
    end
  end

  class Stack
    attr_reader :copied_context, :shell_args, :record, :guest_files
    def initialize(runtime: nil)
      @runtime = runtime
      @record = { "name" => "fixture", "containers" => { "db" => "d" * 64, "web" => "e" * 64 }, "networks" => ["internal-fixture"] }
    end
    def container(service) = "#{service}-container"
    def copy_in(host, guest, **)
      @runtime&.guest_created!
      @copied_context = JSON.parse(File.read(File.join(host, "work", "context.json")))
      @guest_files = Dir.glob("#{host}/**/*").select { |path| File.file?(path) }
    end
    def web_exec(*) = OpenStruct.new(success?: true, stdout: "1024\n", status: 0)
    def discourse_shell(args, **options)
      @shell_args = [args, options]
      @result = { "version" => 1, "status" => "passed", "reason" => "ok", "key_path" => [], "approved_ids" => [1], "audit" => { "uploads" => 1 }, "checks" => [],
                  "selected_ids_sha256" => Digest::SHA256.hexdigest("[1]"), "selection_sha256" => "a" * 64, "asset_preflight_sha256" => "b" * 64, "owner_preflight_sha256" => "d" * 64 }
      projection = @result.slice("version", "status", "reason", "selected_ids_sha256", "selection_sha256", "asset_preflight_sha256").merge("key_path" => [])
      OpenStruct.new(success?: true, status: 0, stdout: "SILO_MERGE_VALIDATION:#{JSON.generate(projection)}\n\nSILO_VALIDATION_GUEST_DONE:#{args.fetch(3)}:0\n")
    end
    def copy_out(_, destination, **)
      File.write(destination, JSON.generate(@result), mode: "w", perm: 0o600)
    end
  end

  class Host < StandardMergeValidationTest::Host
    attr_reader :stack
    def initialize(root)
      super
      @runtime = TransportRuntime.new
      @stack = Stack.new(runtime: @runtime)
    end
    def merge_validation_context!(**options)
      super.merge("runtime_profile" => { "images" => { "redis" => {
        "ref" => "redis@sha256:#{'7' * 64}", "content_id" => SiloMigrate::ImageIdentity.content_id(runtime.redis_document), "source" => "fixture"
      } } })
    end
    def merge_validation_execute!(context, journal)
      SiloMigrate::Services::StandardMergeValidation.instance_method(:merge_validation_execute!).bind_call(self, context, journal)
    end
    def merger_layer!(*) = [layer, { "merger.rb" => "# invented inert fixture\n" }]
    def stack_for(*) = stack
  end

  def test_real_catalog_shape_refuses_changed_content_before_sidecar_creation
    Dir.mktmpdir do |directory|
      host = Class.new(Host) { prepend SiloMigrate::Services::StandardMergeValidation }.new(directory)
      host.define_singleton_method(:merge_validation_context!) do |**options|
        Host.instance_method(:merge_validation_context!).bind_call(self, **options)
      end
      host.runtime.image_mismatch = true
      result = host.validate
      assert_equal "refused", result["status"]
      assert_equal true, result["cleanup_confirmed"]
      refute host.runtime.calls.any? { |argv, _| argv[0, 2] == %w[docker create] }
      assert_nil host.stack.shell_args
    end
  end

  def test_production_transport_uses_private_files_pinned_sidecar_and_no_password_argv
    Dir.mktmpdir do |directory|
      host = Host.new(directory)
      result = host.validate
      assert_equal "passed", result["status"], result.inspect
      assert host.runtime.calls.any? { |argv, _| argv == ["docker", "image", "inspect", "redis@sha256:#{'7' * 64}"] }
      context = host.stack.copied_context
      assert_equal true, context["redis_isolated"]
      assert_match(/\Asilo_val_r_[0-9a-f]{32}\z/, context["role"])
      arguments, options = host.stack.shell_args
      assert_equal false, options[:env_password]
      ruby_index = arguments.index("ruby")
      assert_equal ["bundle", "exec"], arguments[ruby_index - 2, 2]
      assert_match(%r{\A-r/shared/silo-validation-[0-9a-f]{32}/merge_validation_config\.rb\z}, arguments[ruby_index + 1])
      refute arguments.any? { |arg| arg.start_with?("RUBYOPT=") }
      refute_includes arguments.join(" "), context.fetch("password")
      create = host.runtime.calls.find { |argv, _| argv[0, 2] == %w[docker create] }.first
      %w[--cap-drop --read-only --pids-limit --memory --memory-swap --security-opt --pull=never --restart=no].each { |flag| assert_includes create, flag }
      assert_equal "redis:redis", create[create.index("--user") + 1]
      assert_equal "128m", create[create.index("--memory") + 1]
      assert_equal "128m", create[create.index("--memory-swap") + 1]
      refute_includes create, "--publish"
      assert_includes create, "sha256:#{'8' * 64}"
      host.runtime.calls.each { |argv, _| refute_includes argv.join(" "), context.fetch("password") }
      assert Dir.glob(File.join(directory, "validations", "*", "context.json")).empty?
      assert_equal true, result["cleanup_confirmed"]
    end
  end
end
