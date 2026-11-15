# frozen_string_literal: true
require_relative "test_helper"
require "ostruct"
require "silo_migrate/standard_cli"

class StandardMergeValidationResetTest < SiloMigrateTest
  ID = "a" * 32
  RUN = "run-#{'b' * 32}"
  GENERATION = "c" * 64
  NAME = "silomig-fixture-review"
  PRIVATE = "private-path-settings-and-error"
  DATE = "2026-11-15T00:00:00Z"

  class Store
    attr_reader :root, :state, :locks
    def initialize(root, instance)
      @root, @locks = root, []
      @state = { "version" => 1, "runs" => { RUN => { "status" => "completed", "plan_id" => "p", "instances" => { "review" => NAME },
        "merge_environment" => { "preparation_run_id" => RUN, "generation" => GENERATION, "phase" => "ready", "instance" => NAME, "containers" => instance.fetch("containers").dup } } },
        "plans" => { "p" => { "body" => { "operation" => "standard_merge_prepare" } } }, "instances" => { NAME => instance } }
    end
    def load = state
    def with_host_lock
      raise "recursive host" unless locks.empty?
      locks << :host
      yield
    ensure
      locks.pop
    end
    def with_op_lock
      raise "order/recursive op" unless locks == [:host]
      locks << :op
      yield
    ensure
      locks.pop
    end
    def with_read_only_execution_locks(&block) = with_host_lock { with_op_lock(&block) }
  end

  class Runtime
    attr_reader :objects, :commands
    attr_accessor :daemon, :fault, :sidecar, :foreign_volume_user
    def initialize(instance)
      @objects, @commands, @daemon = {}, [], "fixture-daemon-id"
      labels = { "silo-migrate.managed" => "true", "silo-migrate.instance" => NAME, "silo-migrate.run" => RUN }
      instance["containers"].each do |role, id|
        volume = { "db" => "pg", "redis" => "redis", "web" => "shared" }[role]
        @objects[["container", id]] = { "id" => id, "name" => "/#{NAME}-#{role}", "created" => DATE, "started" => DATE,
          "labels" => labels.dup, "mounts" => volume ? [{ "Type" => "volume", "Name" => "#{NAME}-#{volume}" }] : [] }
      end
      instance["networks"].each_with_index do |name, index|
        @objects[["network", name]] = { "id" => (index + 5).to_s * 64, "name" => name, "created" => DATE, "labels" => labels.dup, "containers" => {} }
      end
      instance["volumes"].each do |name|
        @objects[["volume", name]] = { "name" => name, "created" => DATE, "driver" => "local", "options" => nil, "labels" => labels.dup }
      end
    end
    def run(argv, **options)
      commands << [argv, options]
      raise PRIVATE if fault
      stdout = if argv[1] == "info"
        daemon
      elsif argv[1] == "ps"
        ""
      elsif argv[2] == "inspect"
        JSON.generate(objects.fetch([argv[1], argv.last]))
      elsif argv[2] == "ls"
        kind = argv[1]
        filter = argv.fetch(argv.index("--filter") + 1)
        found = objects.select { |(type, _), _| type == kind }.values
        found = case filter
        when /\Aid=(.*)/ then found.select { |value| value["id"] == Regexp.last_match(1) }
        when /\Aname=(.*)/
          expression = Regexp.new(Regexp.last_match(1))
          found.select { |value| expression.match?(value["name"]) }
        when /\Alabel=(.*?)=(.*)/
          key, value = Regexp.last_match(1), Regexp.last_match(2)
          found.select { |object| object["labels"][key] == value }
        when /\Avolume=/ then []
        else raise "unknown list filter"
        end
        output = found.map { |value| kind == "volume" ? value["name"] : value["id"] }
        output << "f" * 64 if sidecar && filter.include?("silo-val-redis-")
        output << "f" * 64 if foreign_volume_user && filter.start_with?("volume=")
        output.join("\n")
      else
        raise "unexpected effect/query"
      end
      OpenStruct.new(stdout: stdout, stderr: PRIVATE, success?: true, status: 0)
    end
  end

  class Host
    include SiloMigrate::Services::StandardMergeValidation
    attr_reader :store, :runtime, :reset_calls
    attr_accessor :work, :fail_after, :lose_work
    def initialize(root)
      @workspace = "fixture"
      instance = { "name" => NAME, "state" => "running", "containers" => %w[db proxy redis web].each_with_index.to_h { |role, i| [role, (i + 1).to_s * 64] },
        "networks" => ["#{NAME}-int", "#{NAME}-pub"], "volumes" => %w[pg redis shared].map { |suffix| "#{NAME}-#{suffix}" } }
      @store, @runtime, @reset_calls = Store.new(root, instance), Runtime.new(instance), 0
      @work = { "merger_commit" => "d" * 40, "inputs_sha256" => "e" * 64, "registry_sha256" => "f" * 64 }
    end
    def mr_persistent_work!(_settings) = work.dup
    def reset_run_locked(run)
      raise "locks missing" unless store.locks == [:host, :op] && run == RUN
      @reset_calls += 1
      runtime.objects.keys.each_with_index do |key, index|
        runtime.objects.delete(key)
        if fail_after && index == fail_after
          self.fail_after = nil
          raise SiloMigrate::StandardWorkflowError, "STANDARD_CLEANUP_FAILED"
        end
      end
      store.state["instances"][NAME]["state"] = "removed"
      store.state["runs"][RUN]["merge_environment"]["phase"] = "reset"
      work["merger_commit"] = "0" * 40 if lose_work
    end
  end

  def setup
    @root = Dir.mktmpdir
    @host = Host.new(@root)
    @receipt = { "version" => 1, "receipt_id" => ID, "prepared_from" => RUN, "generation" => GENERATION, "status" => "refused",
      "templates" => {}, "settings" => "input-#{'e' * 32}", "reason" => "STANDARD_MERGE_VALIDATION_UNPROVEN" }
    @journal = { "version" => 1, "id" => ID, "prepared_from" => RUN, "generation" => GENERATION,
      "source" => "silo_val_s_#{ID}", "base" => "silo_val_b_#{ID}", "role" => "silo_val_r_#{ID}",
      "templates" => {}, "cleanup_confirmed" => false, "status" => "owned_unknown" }
    save
  end
  def teardown = FileUtils.remove_entry(@root)
  def path(suffix) = @host.send(:mv_path, ID, suffix)
  def save
    @host.send(:mv_write!, path("json"), @receipt)
    @host.send(:mv_write!, path("resources.json"), @journal)
  end
  def preview = @host.merge_validation_reset_preview(attempt_id: ID)
  def apply(digest) = @host.merge_validation_reset_apply(attempt_id: ID, intent_sha256: digest, yes: true)
  def gate = @host.send(:mv_no_resources!)
  def refuse(code = nil)
    error = assert_raises(SiloMigrate::StandardWorkflowError) { yield }
    assert_equal code, error.code if code
    refute_includes error.message, PRIVATE
  end

  def test_preview_does_not_write_or_reset_and_returns_only_safe_scope
    before = Dir.children(File.dirname(path("json"))).to_h { |name| [name, File.binread(File.join(File.dirname(path("json")), name))] }
    result = preview
    assert_equal "preview", result["status"]
    assert_equal RUN, result["prepared_from"]
    assert_equal "unproven", result["historical_producer"]
    assert_equal 64, result["intent_sha256"].size
    refute_includes JSON.generate(result), PRIVATE
    assert_equal 0, @host.reset_calls
    assert_equal before, Dir.children(File.dirname(path("json"))).to_h { |name| [name, File.binread(File.join(File.dirname(path("json")), name))] }
    assert @host.runtime.commands.all? { |argv, options| options[:capture] && (argv & %w[rm stop kill exec create start]).empty? }
  end

  def test_exact_apply_preserves_originals_and_unblocks_only_with_separate_proof
    original = %w[json resources.json].to_h { |suffix| [suffix, File.binread(path(suffix))] }
    refuse("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") { gate }
    intent = preview.fetch("intent_sha256")
    result = apply(intent)
    assert_equal "reset_retired", result["status"]
    assert_equal "prepare_new_environment", result["next_action"]
    assert_empty @host.runtime.objects
    assert_equal 1, @host.reset_calls
    assert_equal original, %w[json resources.json].to_h { |suffix| [suffix, File.binread(path(suffix))] }
    gate
    assert_equal result, apply(intent)
    assert_equal result, preview
    assert_equal 1, @host.reset_calls
    assert_equal false, JSON.parse(File.binread(path("resources.json")))["cleanup_confirmed"]
  end

  def test_unapproved_or_stale_digest_never_resets
    digest = preview.fetch("intent_sha256")
    refuse("STANDARD_CONFIRMATION_REQUIRED") { @host.merge_validation_reset_apply(attempt_id: ID, intent_sha256: digest) }
    refuse("STANDARD_MERGE_RESET_INTENT_STALE") { apply("0" * 64) }
    assert_equal 0, @host.reset_calls
    assert_equal 2, Dir.children(File.dirname(path("json"))).size
  end

  def test_code_or_registered_input_drift_requires_new_preview
    digest = preview.fetch("intent_sha256")
    @host.work["inputs_sha256"] = "0" * 64
    refuse("STANDARD_MERGE_RESET_INTENT_STALE") { apply(digest) }
    assert_equal 0, @host.reset_calls
  end

  def test_unknown_ownership_external_mounts_volume_users_and_sidecars_refuse
    object = @host.runtime.objects[["container", "1" * 64]]
    object["labels"]["silo-migrate.run"] = "other"
    refuse { preview }
    object["labels"]["silo-migrate.run"] = RUN
    object["mounts"] = [{ "Type" => "bind", "Source" => PRIVATE }]
    refuse { preview }
    object["mounts"] = [{ "Type" => "volume", "Name" => "#{NAME}-pg" }]
    @host.runtime.foreign_volume_user = true
    refuse { preview }
    @host.runtime.foreign_volume_user = false
    @host.runtime.sidecar = true
    refuse("STANDARD_MERGE_RESET_AUXILIARY_PRESENT") { preview }
    assert_equal 0, @host.reset_calls
  end

  def test_present_host_staging_and_foreign_network_attachment_refuse
    Dir.mkdir(File.join(@root, "validations", ID), 0o700)
    refuse("STANDARD_MERGE_RESET_AUXILIARY_PRESENT") { preview }
    Dir.rmdir(File.join(@root, "validations", ID))
    @host.runtime.objects[["network", "#{NAME}-int"]]["containers"] = { "f" * 64 => {} }
    refuse { preview }
  end

  def test_partial_reset_resumes_exact_durable_intent_without_adopting_absence
    digest = preview.fetch("intent_sha256")
    @host.fail_after = 1
    refuse("STANDARD_CLEANUP_FAILED") { apply(digest) }
    refute_path_exists path("reset-retirement.json")
    refuse("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") { gate }
    assert_equal digest, preview.fetch("intent_sha256")
    assert_equal "reset_retired", apply(digest)["status"]
    gate
    assert_equal 2, @host.reset_calls
  end

  def test_partial_reset_replacement_daemon_change_and_evidence_drift_refuse
    digest = preview.fetch("intent_sha256")
    @host.fail_after = 0
    refuse { apply(digest) }
    replacement = @host.runtime.objects[["container", "2" * 64]].dup
    replacement["name"], replacement["id"] = "/#{NAME}-db", "9" * 64
    @host.runtime.objects[["container", "9" * 64]] = replacement
    refuse { apply(digest) }
    @host.runtime.objects.delete(["container", "9" * 64])
    @host.runtime.daemon = "different-daemon"
    refuse { apply(digest) }
    @host.runtime.daemon = "fixture-daemon-id"
    @receipt["reason"] = "another"
    save
    refuse { apply(digest) }
    assert_equal 1, @host.reset_calls
  end

  def test_no_retirement_if_final_persistence_verification_fails
    digest = preview.fetch("intent_sha256")
    @host.lose_work = true
    refuse("STANDARD_MERGE_RESET_WORK_UNSAVED") { apply(digest) }
    refute_path_exists path("reset-retirement.json")
    refuse("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") { gate }
  end

  def test_retirement_does_not_accept_changed_original_state_or_daemon
    digest = preview.fetch("intent_sha256")
    apply(digest)
    @host.runtime.daemon = "different-daemon"
    refuse("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") { gate }
    @host.runtime.daemon = "fixture-daemon-id"
    @host.store.state["runs"][RUN]["merge_environment"]["generation"] = "0" * 64
    refuse("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") { gate }
    @host.store.state["runs"][RUN]["merge_environment"]["generation"] = GENERATION
    @journal["status"] = "changed"
    save
    refuse("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") { gate }
  end

  def test_plain_reset_or_forged_completion_is_not_retirement
    @host.store.with_host_lock { @host.store.with_op_lock { @host.reset_run_locked(RUN) } }
    refuse { preview }
    refuse("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") { gate }
    @host.send(:mv_write!, path("reset-retirement.json"), { "intent_sha256" => "0" * 64 })
    refuse("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") { gate }
  end

  def test_other_unresolved_attempt_is_not_silently_retired
    id = "e" * 32
    journal = @journal.merge("id" => id, "source" => "silo_val_s_#{id}", "base" => "silo_val_b_#{id}", "role" => "silo_val_r_#{id}")
    @host.send(:mv_write!, @host.send(:mv_path, id, "resources.json"), journal)
    refuse { preview }
    assert_equal 0, @host.reset_calls
  end

  def test_cli_requires_exact_id_digest_confirmation_and_engineer_surface
    args = ["workflow", "validation-reset-preview", "invented", "--attempt", ID]
    output, error = StringIO.new, StringIO.new
    cli = SiloMigrate::StandardCLI.new(output: output, error: error)
    assert_equal 0, cli.stub(:service, @host) { cli.run(args) }
    digest = JSON.parse(output.string).fetch("intent_sha256")
    apply_args = ["workflow", "validation-reset-apply", "invented", "--attempt", ID, "--intent-sha256", digest, "--yes"]
    [args[0...-1] + ["latest"], ["agent", *args], apply_args[0...-1], apply_args + ["--yes"], apply_args + ["extra"]].each do |bad|
      output.truncate(0); output.rewind; error.truncate(0); error.rewind
      assert_equal 1, cli.stub(:service, @host) { cli.run(bad) }
      assert_empty output.string
      assert_equal "Error: STANDARD_ARGUMENTS_INVALID\n", error.string
    end
    assert_equal 0, cli.stub(:service, @host) { cli.run(apply_args) }
  end
end
