# frozen_string_literal: true

# Reuse the deterministic catalogue/transport seam, not canned lifecycle success.
require_relative "standard_merge_validation_test"

class StandardMergeValidationLifecycleTest < Minitest::Test
  class Runtime < StandardMergeValidationTest::Runtime
    attr_accessor :fault, :db_identity, :web_identity, :daemon_identity, :sessions,
      :dependencies, :producer_sessions, :guest_identity, :redis_id, :redis_running
    attr_reader :effects, :metadata_calls

    def initialize
      super
      @effects, @metadata_calls = [], []
    end

    def run(argv, **options)
      sql = options[:stdin_data]
      if sql
        @effects << sql if sql.match?(/CREATE |DROP |REVOKE |GRANT |ALTER /)
        injected = fault&.call(sql, argv, options)
        return injected.terminal_proven == false ? injected : sql_result(injected, argv) if injected
        if sql.include?("silo_validation_producers")
          return sql_result(result((producer_sessions || 0).to_s), argv)
        elsif sql.include?("silo_validation_recovery_sessions")
          counts = [(sessions || 0)]
          counts += [0, dependencies || 0] if sql.include?("pg_shdepend")
          return sql_result(result(counts.join("\n") + "\n"), argv)
        end
        return super
      end
      @metadata_calls << argv
      case argv[0, 2]
      when %w[docker info]
        result(daemon_identity || "fixture-daemon-id")
      when %w[docker inspect]
        if argv.last == redis_id
          id = argv.last
          return result("#{id}|#{@attempt_id}|true|#{redis_running ? 'true' : 'false'}")
        end
        id = (argv.last.start_with?("web") || argv.last == "e" * 64) ? (web_identity || "e" * 64) : (db_identity || "d" * 64)
        result("#{id}|true|2026-11-14T00:00:00Z|true|fixture")
      when %w[docker container]
        result(redis_id || "")
      when %w[docker rm]
        self.redis_id = nil
        result("")
      when %w[docker exec]
        if argv.include?("silo-validation-stat")
          result(guest_identity || "absent")
        elsif argv.include?("rm")
          self.guest_identity = "absent"
          result("")
        else
          raise "unexpected auxiliary command"
        end
      else
        raise "unexpected metadata command"
      end
    end

    def result(stdout = "", status: 0)
      OpenStruct.new(success?: status == 0, status: status, stdout: stdout, stderr: "PRIVATE")
    end

    def substitute!(name)
      @inventory.fetch(name)[1] = "999"
    end

    def substitute_owner!(name)
      @inventory.fetch(name)[2] = "999"
    end

    def redis_attempt=(id)
      @attempt_id = id
    end
  end

  class Host < StandardMergeValidationTest::Host
    def initialize(root)
      super
      @runtime = Runtime.new
    end
  end

  def setup
    @mode = ENV.delete(SiloMigrate::Services::StandardMergeValidation::VALIDATION_MODE_ENV)
    @directory = Dir.mktmpdir
    @host = Host.new(@directory)
  end

  def teardown
    @mode.nil? ? ENV.delete(SiloMigrate::Services::StandardMergeValidation::VALIDATION_MODE_ENV) : ENV[SiloMigrate::Services::StandardMergeValidation::VALIDATION_MODE_ENV] = @mode
    FileUtils.remove_entry(@directory)
  end

  def journal(result)
    JSON.parse(File.binread(@host.send(:mv_path, result.fetch("receipt_id"), "resources.json")))
  end

  def save(record)
    @host.send(:mv_save_journal!, record)
  end

  def preview(result)
    @host.merge_validation_recovery_preview(attempt_id: result.fetch("receipt_id"))
  end

  def apply(result, review)
    @host.merge_validation_recovery_apply(attempt_id: result.fetch("receipt_id"), intent_sha256: review.fetch("intent_sha256"))
  end

  def refuse
    error = assert_raises(SiloMigrate::StandardWorkflowError) { yield }
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", error.code
  end

  def dirty_attempt
    @host.runtime.cleanup_failure = true
    result = @host.validate
    assert_equal false, result["cleanup_confirmed"]
    @host.runtime.cleanup_failure = false
    result
  end

  def drops
    @host.runtime.effects.grep(/DROP /)
  end

  def test_restriction_failure_has_incremental_identity_and_cleans_known_subset
    observed = nil
    @host.runtime.fault = lambda do |sql, *_|
      next unless sql.start_with?("REVOKE ALL ON DATABASE silo_val_s_")
      id = sql[/silo_val_s_([0-9a-f]{32})/, 1]
      observed = JSON.parse(File.binread(@host.send(:mv_path, id, "resources.json")))
      @host.runtime.result(status: 1)
    end
    result = @host.validate
    assert_equal "refused", result["status"]
    assert_equal true, result["cleanup_confirmed"]
    assert_equal "completed", result["producer_outcome"]
    assert_equal "created", observed.dig("resources", "source", "outcome")
    assert observed.dig("resources", "source", "identity")
    assert observed.dig("resources", "role", "identity")
    assert_equal "absent", observed.dig("resources", "base", "outcome")
    assert_equal 2, drops.size
    refute drops.any? { |sql| sql.include?("silo_val_b_") }
    assert_equal "ready", @host.store.state.dig("runs", "prep", "merge_environment", "phase")
    assert_equal "passed", (@host.runtime.fault = nil; @host.validate)["status"]
  end

  def test_known_failed_create_with_proved_absence_cleans_prior_resources
    @host.runtime.fault = ->(sql, *) { @host.runtime.result(status: 1) if sql.start_with?("CREATE DATABASE silo_val_b_") }
    result = @host.validate
    assert_equal true, result["cleanup_confirmed"]
    assert_equal "failed", result.dig("diagnostics", "work", "command_outcome")
    assert_equal "absent", journal(result).dig("resources", "base", "outcome")
    assert_equal 2, drops.size
  end

  def test_lost_create_response_never_adopts_present_or_absent_resource
    @host.runtime.fault = ->(sql, *) { @host.runtime.result(status: nil) if sql.start_with?("CREATE DATABASE silo_val_b_") }
    result = @host.validate
    assert_equal false, result["cleanup_confirmed"]
    assert_equal "unknown", result["producer_outcome"]
    assert_equal "unknown", journal(result).dig("resources", "base", "outcome")
    assert_empty drops
    refuse { preview(result) }
    assert_empty drops
  end

  def test_protocol_failure_after_returned_guest_is_failed_work_not_dirty_environment
    @host.define_singleton_method(:merge_validation_execute!) { |*, **| {} }
    result = @host.validate
    assert_equal "refused", result["status"]
    assert_equal true, result["cleanup_confirmed"]
    assert_equal "STANDARD_MERGE_VALIDATION_PROTOCOL", result["primary_reason"]
    assert_equal "completed", result["producer_outcome"]
    assert_equal 3, drops.size
  end

  def test_unknown_guest_never_cleans_or_recovers
    @host.guest_exception = true
    result = @host.validate
    assert_equal "unknown", result["producer_outcome"]
    assert_empty drops
    refuse { preview(result) }
  end

  def test_failed_work_reason_survives_cleanup_failure
    @host.guest_failure = true
    result = dirty_attempt
    assert_equal "preflight_refused", result["primary_reason"]
    assert_equal "refused", result["work_status"]
    assert_equal "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", result["reason"]
    assert_equal "preflight_refused", journal(result)["primary_reason"]
  end

  def test_partial_drop_and_exact_digest_recovery_preserve_original_receipt_and_workflow
    @host.runtime.fault = ->(sql, *) { @host.runtime.result(status: 1) if sql.include?("DROP DATABASE silo_val_b_") }
    result = @host.validate
    assert_equal "deleted", journal(result).dig("resources", "source", "outcome")
    assert_equal "created", journal(result).dig("resources", "base", "outcome")
    @host.runtime.fault = nil
    state = Marshal.dump(@host.store.state)
    path = @host.send(:mv_path, result.fetch("receipt_id"), "json")
    receipt_bytes = File.binread(path)
    journal_path = @host.send(:mv_path, result.fetch("receipt_id"), "resources.json")
    journal_bytes = File.binread(journal_path)
    journal_mtime = File.stat(journal_path).mtime
    before = drops.size
    review = preview(result)
    assert_equal journal_bytes, File.binread(@host.send(:mv_path, result.fetch("receipt_id"), "resources.json")), "preview must not write"
    assert_equal journal_mtime, File.stat(journal_path).mtime, "preview must not touch mtime"
    assert_equal before, drops.size
    assert_equal %w[actions attempt_id intent_sha256 version], review.keys.sort
    refute_includes review.fetch("actions"), "drop_proved_source"
    assert_equal true, apply(result, review)["cleanup_confirmed"]
    assert_equal receipt_bytes, File.binread(path)
    assert_equal state, Marshal.dump(@host.store.state)
    recovery_sql = drops.drop(before).join
    assert_includes recovery_sql, "DROP DATABASE silo_val_b_"
    assert_includes recovery_sql, "DROP ROLE silo_val_r_"
    refute_match(/FORCE|CASCADE|pg_terminate_backend|silo_val_s_/, recovery_sql)
    assert_equal "cleaned", journal(result)["status"]
    assert File.file?(@host.send(:mv_path, result.fetch("receipt_id"), "recovery-#{review.fetch('intent_sha256')}.intent.json"))
  end

  def test_normal_cleanup_is_reentrant_after_proved_deletions
    result = @host.validate
    record = journal(result)
    context = { "prepared_from" => "prep", "runtime_profile" => {} }
    before = drops.size
    2.times { @host.send(:mv_cleanup!, context, record) }
    assert_equal before, drops.size
    assert record.fetch("resources").values.all? { |row| row["outcome"] == "deleted" }
  end

  def test_recovery_binds_journal_and_receipt_bytes
    result = dirty_attempt
    review = preview(result)
    record = journal(result)
    record["extra_review_note"] = "changed"
    save(record)
    before = drops.size
    refuse { apply(result, review) }
    assert_equal before, drops.size
    review = preview(result)
    path = @host.send(:mv_path, result.fetch("receipt_id"), "json")
    receipt = JSON.parse(File.binread(path)).merge("private_note" => "changed")
    @host.send(:mv_write!, path, receipt)
    refuse { apply(result, review) }
    assert_equal before, drops.size
  end

  def test_changed_object_identity_refuses_without_any_cleanup
    result = dirty_attempt
    @host.runtime.substitute!(journal(result).fetch("source"))
    before = drops.size
    refuse { preview(result) }
    assert_equal before, drops.size
  end

  def test_changed_db_web_or_daemon_binding_refuses
    result = dirty_attempt
    %i[db_identity web_identity daemon_identity].each do |key|
      @host.runtime.public_send("#{key}=", key == :daemon_identity ? "new-daemon-identity" : "f" * 64)
      refuse { preview(result) }
      @host.runtime.public_send("#{key}=", nil)
    end
  end

  def test_recovery_refuses_sessions_dependencies_and_still_active_sql_backend
    result = dirty_attempt
    %i[sessions dependencies producer_sessions].each do |key|
      @host.runtime.public_send("#{key}=", 1)
      refuse { preview(result) }
      @host.runtime.public_send("#{key}=", nil)
    end
  end

  def test_unknown_drop_completion_is_not_recovered_even_if_object_is_absent
    @host.runtime.fault = ->(sql, *) { @host.runtime.result(status: nil) if sql.include?("DROP DATABASE silo_val_s_") }
    result = @host.validate
    assert_equal "unknown", journal(result)["producer_outcome"]
    @host.runtime.fault = nil
    refuse { preview(result) }
  end

  def test_legacy_and_missing_identity_evidence_refuse
    result = dirty_attempt
    record = journal(result)
    record["version"] = 1
    save(record)
    before = @host.runtime.metadata_calls.size
    refuse { preview(result) }
    assert_equal before, @host.runtime.metadata_calls.size
    record["version"] = 2
    record.fetch("resources").fetch("role").delete("identity")
    save(record)
    refuse { preview(result) }
  end

  def test_symlink_and_malformed_evidence_refuse_without_effects
    result = dirty_attempt
    path = @host.send(:mv_path, result.fetch("receipt_id"), "resources.json")
    bytes = File.binread(path)
    File.unlink(path)
    File.symlink("missing", path)
    refuse { preview(result) }
    File.unlink(path)
    File.write(path, "{", mode: "w", perm: 0o600)
    refuse { preview(result) }
    File.write(path, bytes, mode: "w", perm: 0o600)
    validations = File.dirname(path)
    File.rename(validations, "#{validations}-real")
    File.symlink("#{validations}-real", validations)
    refuse { preview(result) }
  end

  def add_guest(record)
    record.merge!("guest_directory" => "/shared/silo-validation-#{record.fetch('id')}", "guest_identity" => "1:123:1000:directory")
    record.fetch("producers").merge!("guest" => "completed", "guest_copy" => "completed")
    @host.runtime.guest_identity = record.fetch("guest_identity")
    save(record)
  end

  def test_recovery_guest_cleanup_requires_identity_and_accepts_proved_prior_absence
    result = dirty_attempt
    record = journal(result)
    add_guest(record)
    review = preview(result)
    @host.runtime.guest_identity = "1:999:1000:directory"
    refuse { apply(result, review) }
    @host.runtime.guest_identity = record.fetch("guest_identity")
    review = preview(result)
    assert_equal true, apply(result, review)["cleanup_confirmed"]
    assert_equal "absent", @host.runtime.guest_identity
  end

  def test_guest_copy_unknown_refuses_even_if_directory_currently_absent
    result = dirty_attempt
    record = journal(result)
    add_guest(record)
    record.fetch("producers")["guest_copy"] = "unknown"
    record["producer_outcome"] = "unknown"
    save(record)
    @host.runtime.guest_identity = "absent"
    refuse { preview(result) }
  end

  def test_recovery_removes_only_stopped_exact_redis_and_never_force_removes
    result = dirty_attempt
    record = journal(result)
    id = result.fetch("receipt_id")
    record.merge!("redis" => "silo-val-redis-#{id}", "redis_id" => "9" * 64)
    record.fetch("producers")["redis"] = "completed"
    save(record)
    @host.runtime.redis_id = record.fetch("redis_id")
    @host.runtime.redis_attempt = id
    @host.runtime.redis_running = true
    refuse { preview(result) }
    @host.runtime.redis_running = false
    review = preview(result)
    assert_equal true, apply(result, review)["cleanup_confirmed"]
    remove = @host.runtime.metadata_calls.select { |argv| argv[0, 2] == %w[docker rm] }
    assert_equal [["docker", "rm", "9" * 64]], remove
  end

  def test_events_are_bounded_fixed_and_sql_never_exposes_password_in_argv
    result = @host.validate
    record = journal(result)
    assert_equal 2, record["version"]
    assert_equal "completed", record["producer_outcome"]
    assert_equal "template_custody", record["last_stage"]
    assert_operator record.fetch("events").size, :<=, 128
    record.fetch("events").each do |event|
      assert_includes SiloMigrate::Services::StandardMergeValidation::VALIDATION_STEPS, event.fetch("step")
      assert_includes %w[start finish], event.fetch("phase")
      assert_kind_of Integer, event.fetch("elapsed_ms")
      assert_operator event.fetch("elapsed_ms"), :>=, 0
      assert_empty event.keys - %w[step phase elapsed_ms outcome]
    end
    password = @host.runtime.effects.join[/PASSWORD '([^']+)'/, 1]
    @host.runtime.calls.each do |argv, options|
      refute_includes argv.join(" "), password
      if argv.include?("PGAPPNAME=silo_validation_#{result.fetch('receipt_id')}")
        assert_includes argv, "d" * 64
      end
    end
    refute_includes File.binread(@host.send(:mv_path, result.fetch("receipt_id"), "resources.json")), password
  end
  def test_bare_docker_failure_does_not_prove_psql_completion
    @host.runtime.fault = lambda do |sql, *_|
      next unless sql.start_with?("REVOKE ALL ON DATABASE silo_val_s_")
      @host.runtime.result(status: 1).tap { |result| result.terminal_proven = false }
    end
    result = @host.validate
    assert_equal "unknown", result["producer_outcome"]
    assert_equal "timeout_or_interrupted", result.dig("diagnostics", "work", "command_outcome")
    assert_empty drops
    record = journal(result)
    context = { "prepared_from" => "prep", "runtime_profile" => {}, "lifecycle_journal" => record }
    refuse { @host.send(:mv_sql!, context, "SELECT 1;") }
    assert_equal "unknown", journal(result)["producer_outcome"]
    refuse { preview(result) }
  end

  def test_completion_cannot_resolve_a_different_invocation_nonce
    result = dirty_attempt
    record = journal(result)
    token = @host.send(:mv_producer!, record, "sql", "unknown")
    refuse { @host.send(:mv_producer!, record, "sql", "completed", token: "f" * 32) }
    refuse { @host.send(:mv_producer!, record, "sql", "unknown") }
    assert_equal "unknown", journal(result)["producer_outcome"]
    @host.send(:mv_producer!, record, "sql", "completed", token: token)
    assert_equal "completed", journal(result)["producer_outcome"]
  end

  def test_recovery_refuses_consumed_activated_or_unrelated_claimed_runs
    result = dirty_attempt
    environment = @host.store.state.fetch("runs").fetch("prep").fetch("merge_environment")
    environment["consumed_by"] = "other"
    refuse { preview(result) }
    environment["consumed_by"] = nil
    environment["phase"] = "activated"
    refuse { preview(result) }
    environment["phase"] = "ready"
    %w[claimed running].each do |status|
      @host.store.state.fetch("runs")["other"] = { "status" => status }
      refuse { preview(result) }
    end
  end

  def test_recovery_allows_absent_guest_intent_without_adopting_any_directory
    result = dirty_attempt
    record = journal(result)
    record["guest_directory"] = "/shared/silo-validation-#{record.fetch('id')}"
    save(record)
    review = preview(result)
    refute_includes review.fetch("actions"), "remove_proved_guest"
    @host.runtime.guest_identity = "1:999:1000:directory"
    refuse { preview(result) }
  end

  def test_actual_transport_guest_failure_without_terminal_envelope_stays_unknown
    host = MergeValidationTransportTest::Host.new(@directory)
    host.stack.define_singleton_method(:discourse_shell) do |*_, **|
      OpenStruct.new(success?: false, status: 1, stdout: "", stderr: "PRIVATE")
    end
    result = host.validate
    assert_equal "unknown", result["producer_outcome"]
    assert_equal false, result["cleanup_confirmed"]
    refute host.runtime.calls.any? { |_, options| options[:stdin_data].to_s.include?("DROP DATABASE") }
  end

  def test_guest_timeout_is_recorded_without_confusing_the_outer_work_deadline
    host = MergeValidationTransportTest::Host.new(@directory)
    host.stack.define_singleton_method(:discourse_shell) do |*_, **|
      OpenStruct.new(success?: false, status: nil, stdout: "", stderr: "PRIVATE")
    end
    result = host.validate
    assert_equal "timeout_or_interrupted", result.dig("diagnostics", "work", "command_outcome")
    assert_equal false, result.dig("diagnostics", "work", "deadline_reached")
    assert_operator result.dig("diagnostics", "work", "command_timeout_seconds"), :<=, 150
    assert_equal "unknown", result["producer_outcome"]
    assert_equal false, result["cleanup_confirmed"]
    refute host.runtime.calls.any? { |_, options| options[:stdin_data].to_s.include?("DROP DATABASE") }
  end

  def test_expired_allowance_before_guest_invocation_is_not_an_unknown_started_child
    implementation = SiloMigrate::Services::StandardMergeValidation
    klass = Class.new(MergeValidationTransportTest::Host) { prepend implementation }
    host = klass.new(@directory)
    host.define_singleton_method(:merge_validation_context!) do |**options|
      MergeValidationTransportTest::Host.instance_method(:merge_validation_context!).bind_call(self, **options)
    end
    original = host.method(:mv_timeout)
    host.define_singleton_method(:mv_timeout) do |context, maximum|
      mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") if maximum == 150
      original.call(context, maximum)
    end
    result = host.validate
    assert_equal "refused", result["status"]
    assert_equal true, result["cleanup_confirmed"]
    assert_equal "completed", result["producer_outcome"]
    assert_nil host.stack.shell_args
    assert host.runtime.calls.any? { |_, options| options[:stdin_data].to_s.include?("DROP DATABASE") }
  end

  def test_redis_intent_with_no_started_create_accepts_absence_but_never_adopts_presence
    result = dirty_attempt
    record = journal(result)
    record["redis"] = "silo-val-redis-#{record.fetch('id')}"
    save(record)
    review = preview(result)
    refute_includes review.fetch("actions"), "remove_stopped_owned_redis"
    @host.runtime.redis_id = "f" * 64
    @host.runtime.redis_attempt = record.fetch("id")
    refuse { preview(result) }
  end

  def test_actual_transport_typed_refusal_has_completed_guest_and_confirmed_cleanup
    host = MergeValidationTransportTest::Host.new(@directory)
    original = host.stack.method(:discourse_shell)
    host.stack.define_singleton_method(:discourse_shell) do |*args, **options|
      original.call(*args, **options)
      @result.merge!("status" => "refused", "reason" => "preflight_refused")
      projection = @result.slice("version", "status", "reason", "selected_ids_sha256", "selection_sha256", "asset_preflight_sha256").merge("key_path" => [])
      OpenStruct.new(success?: false, status: 4, stdout: "SILO_MERGE_VALIDATION:#{JSON.generate(projection)}\n\nSILO_VALIDATION_GUEST_DONE:#{args.first.fetch(3)}:4\n")
    end
    result = host.validate
    assert_equal "refused", result["status"]
    assert_equal "preflight_refused", result["primary_reason"]
    assert_equal "completed", result["producer_outcome"]
    assert_equal true, result["cleanup_confirmed"]
  end

  def test_orphan_host_credentials_and_provision_resume_are_never_adopted
    result = dirty_attempt
    record = journal(result)
    context = { "prepared_from" => "prep", "runtime_profile" => {} }
    before = File.binread(@host.send(:mv_path, result.fetch("receipt_id"), "resources.json"))
    refuse { @host.send(:mv_provision!, context, record, "a" * 64) }
    assert_equal before, File.binread(@host.send(:mv_path, result.fetch("receipt_id"), "resources.json"))
    host_directory = File.join(@directory, "validations", result.fetch("receipt_id"))
    Dir.mkdir(host_directory, 0o700)
    refuse { preview(result) }
    assert Dir.exist?(host_directory)
  end

  def test_changed_clone_owner_oid_is_identity_substitution_even_with_same_role_name
    result = dirty_attempt
    @host.runtime.substitute_owner!(journal(result).fetch("source"))
    before = drops.size
    refuse { preview(result) }
    assert_equal before, drops.size
  end

  def test_preexisting_guest_directory_is_not_adopted_by_copy
    host = MergeValidationTransportTest::Host.new(@directory)
    host.runtime.guest_created!
    result = host.validate
    assert_equal false, result["cleanup_confirmed"]
    refute host.runtime.calls.any? { |argv, options| argv.include?("rm") || options[:stdin_data].to_s.include?("DROP DATABASE") }
    assert_nil host.stack.copied_context
  end

  def test_preexisting_host_directory_is_not_removed_by_executor_ensure
    host = MergeValidationTransportTest::Host.new(@directory)
    existing = nil
    host.define_singleton_method(:merge_validation_execute!) do |context, record|
      existing = File.join(store.root, "validations", record.fetch("id"))
      Dir.mkdir(existing, 0o700)
      SiloMigrate::Services::StandardMergeValidation.instance_method(:merge_validation_execute!).bind_call(self, context, record)
    end
    result = host.validate
    assert_equal false, result["cleanup_confirmed"]
    assert Dir.exist?(existing)
    refute host.runtime.calls.any? { |_, options| options[:stdin_data].to_s.include?("DROP DATABASE") }
  end

  def test_builtin_tracking_handoff_does_not_fabricate_executor_completion
    result = dirty_attempt
    record = journal(result)
    token = @host.send(:mv_executor_begin!, record)
    assert_equal "unknown", record.dig("producers", "executor")
    @host.send(:mv_executor_handoff!, record)
    persisted = journal(result)
    assert_equal "builtin_tracked", persisted["executor_mode"]
    assert_equal "not_started", persisted.dig("producers", "executor")
    # Only the owning wrapper may record completion after its call returns.
    @host.send(:mv_producer!, record, "executor", "completed", token: token)
    assert_equal "completed", journal(result).dig("producers", "executor")
  end

  def test_opaque_delegating_hook_remains_unknown_if_it_fails_after_builtin_returns
    host = MergeValidationTransportTest::Host.new(@directory)
    original = host.method(:merge_validation_execute!)
    host.define_singleton_method(:merge_validation_execute!) do |context, record|
      original.call(context, record)
      raise "opaque executor has not proved completion"
    end
    result = host.validate
    record = JSON.parse(File.binread(host.send(:mv_path, result.fetch("receipt_id"), "resources.json")))
    assert_equal "opaque", record["executor_mode"]
    assert_equal "unknown", record.dig("producers", "executor")
    assert_equal "unknown", result["producer_outcome"]
    assert_equal false, result["cleanup_confirmed"]
    refute host.runtime.calls.any? { |_, options| options[:stdin_data].to_s.include?("DROP DATABASE") }
  end

  def test_direct_builtin_effects_have_intent_before_invocation_and_wrapper_completes_on_return
    implementation = SiloMigrate::Services::StandardMergeValidation
    klass = Class.new(MergeValidationTransportTest::Host) { prepend implementation }
    host = klass.new(@directory)
    host.define_singleton_method(:merge_validation_context!) do |**options|
      MergeValidationTransportTest::Host.instance_method(:merge_validation_context!).bind_call(self, **options)
    end
    observed = []
    original = host.runtime.method(:run)
    host.runtime.define_singleton_method(:run) do |argv, **options|
      if argv[0, 2] == %w[docker create] || (argv[0, 2] == %w[docker start])
        path = Dir.glob(File.join(host.store.root, "validations", "*.resources.json")).fetch(0)
        record = JSON.parse(File.binread(path))
        observed << record
      end
      original.call(argv, **options)
    end
    result = host.validate
    assert_equal "passed", result["status"], result.inspect
    refute_empty observed
    observed.each do |record|
      assert_equal "builtin_tracked", record["executor_mode"]
      assert_equal "not_started", record.dig("producers", "executor")
      assert record["redis"]
      assert record.fetch("producers").values.include?("unknown")
    end
    record = JSON.parse(File.binread(host.send(:mv_path, result.fetch("receipt_id"), "resources.json")))
    assert_equal "completed", record.dig("producers", "executor")
    assert_equal true, result["cleanup_confirmed"]
  end

  def test_a_genuinely_running_opaque_child_is_unknown_before_and_after_hook_failure
    started, release = Queue.new, Queue.new
    child = worker = nil
    @host.define_singleton_method(:merge_validation_execute!) do |_context, record|
      process = IO.popen([RbConfig.ruby, "-e", "sleep 60"], "r")
      started << [record.fetch("id"), process]
      release.pop
      raise "opaque child completion is unproved"
    end
    worker = Thread.new { @host.validate }
    id, child = Timeout.timeout(10) { started.pop }
    assert worker.alive?
    assert Process.kill(0, child.pid)
    record = JSON.parse(File.binread(@host.send(:mv_path, id, "resources.json")))
    assert_equal "opaque", record["executor_mode"]
    assert_equal "unknown", record.dig("producers", "executor")
    assert_empty drops
    release << true
    result = Timeout.timeout(10) { worker.value }
    assert Process.kill(0, child.pid), "opaque subprocess is still running"
    assert_equal "unknown", result["producer_outcome"]
    assert_equal false, result["cleanup_confirmed"]
    assert_empty drops
  ensure
    release << true if worker&.alive?
    worker&.join(10)
    if child
      begin
        Process.kill("TERM", child.pid)
      rescue Errno::ESRCH
        nil
      end
      child.close unless child.closed?
    end
  end

end
