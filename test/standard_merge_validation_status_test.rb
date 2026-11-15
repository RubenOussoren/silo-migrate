# frozen_string_literal: true
require_relative "test_helper"
require "silo_migrate/standard_cli"
require "silo_migrate/services/standard_merge_validation"

class StandardMergeValidationStatusTest < SiloMigrateTest
  ID = "a" * 32
  OTHER = "b" * 32
  PRIVATE = "PRIVATE /customer/secret.sql SELECT password;"

  class Host
    include SiloMigrate::Services::StandardMergeValidation
    attr_reader :store
    attr_accessor :validation_result
    def initialize(root)
      @store = Struct.new(:root).new(root)
    end
    def validate_merge_settings(**) = validation_result
    def binding! = merge_process_binding!(prepared_from: "unused", generation: "unused", settings: "unused", layer: {})
    def method_missing(*) = raise("status performed work")
    def respond_to_missing?(*); false; end
  end

  def setup
    @root = Dir.mktmpdir
    @host = Host.new(@root)
    @directory = File.join(@root, "validations")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def journal(id = ID)
    { "version" => 1, "id" => id, "source" => "silo_val_s_#{id}", "base" => "silo_val_b_#{id}",
      "role" => "silo_val_r_#{id}", "status" => "cleaned", "cleanup_confirmed" => true }
  end

  def receipt(id = ID)
    { "version" => 1, "receipt_id" => id, "status" => "refused", "reason" => "policy_conflict",
      "key_path" => [PRIVATE, 1], "audit" => { PRIVATE => 123456 }, "approved_ids" => [123456],
      "settings" => PRIVATE, "failure" => { "error_class" => PRIVATE } }
  end

  def save(id = ID, record = receipt(id), resource = journal(id))
    @host.send(:mv_write!, File.join(@directory, "#{id}.json"), record) if record
    @host.send(:mv_write!, File.join(@directory, "#{id}.resources.json"), resource) if resource
  end

  def test_missing_does_not_create_a_directory_or_run_work
    assert_equal "no_saved_attempt", @host.merge_validation_status.fetch("next_action")
    refute_path_exists @directory
  end

  def test_safe_saved_projection_is_read_only_and_independent
    save
    before = Dir.glob(File.join(@directory, "*")).to_h { |path| [path, [File.binread(path), File.stat(path).mtime]] }
    result = @host.merge_validation_status
    assert_equal ID, result.fetch("attempt_id")
    assert_equal "policy_conflict", result.dig("work", "reason")
    assert_equal "confirmed", result.dig("cleanup", "status")
    assert_equal "unknown", result.fetch("producer_outcome") # legacy evidence cannot prove completion
    assert_equal 2, result.fetch("key_path_segments")
    refute_includes JSON.generate(result), PRIVATE
    refute_includes JSON.generate(result), "123456"
    assert_equal before, Dir.glob(File.join(@directory, "*")).to_h { |path| [path, [File.binread(path), File.stat(path).mtime]] }
  end

  def test_cleanup_failure_does_not_hide_work_diagnostic
    record = receipt.merge("reason" => "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", "diagnostics" => {
      "work" => { "reason" => "STANDARD_MERGE_TEMPLATE_CUSTODY", "step" => "template_custody", "deadline_reached" => false, "command_outcome" => "failed", "stderr" => PRIVATE },
      "cleanup" => { "reason" => "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", "step" => "cleanup_source", "deadline_reached" => true } })
    save(ID, record, journal.merge("cleanup_confirmed" => false, "status" => "owned_unknown"))
    result = @host.merge_validation_status(attempt: ID)
    assert_equal "STANDARD_MERGE_TEMPLATE_CUSTODY", result.dig("work", "reason")
    assert_equal "template_custody", result.dig("work", "stage")
    assert_equal false, result.dig("work", "deadline_reached")
    assert_equal "cleanup_source", result.dig("cleanup", "stage")
    assert_equal "unconfirmed", result.dig("cleanup", "status")
    refute_includes JSON.generate(result), PRIVATE
  end

  def test_dynamic_reason_and_stage_are_not_echoed
    save(ID, receipt.merge("reason" => PRIVATE, "diagnostics" => { "work" => { "reason" => PRIVATE, "step" => PRIVATE, "command_outcome" => PRIVATE } }))
    result = @host.merge_validation_status
    assert_equal "unknown", result.fetch("reason")
    assert_equal "unknown", result.dig("work", "stage")
    refute_includes JSON.generate(result), PRIVATE
  end

  def test_latest_is_workspace_scoped_and_ambiguous_ties_require_exact_id
    save
    save(OTHER)
    Dir.glob(File.join(@directory, "*")).each { |path| File.utime(Time.at(100), Time.at(100), path) }
    assert_equal "ambiguous", @host.merge_validation_status.dig("evidence", "receipt")
    assert_equal ID, @host.merge_validation_status(attempt: ID).fetch("attempt_id")
    File.utime(Time.at(101), Time.at(101), File.join(@directory, "#{OTHER}.json"))
    assert_equal OTHER, @host.merge_validation_status.fetch("attempt_id")
  end

  def test_missing_receipt_never_claims_success
    save(ID, nil, journal.merge("status" => "owned_unknown", "cleanup_confirmed" => false))
    result = @host.merge_validation_status
    assert_equal ID, result.fetch("attempt_id")
    assert_equal "unknown", result.fetch("status")
    assert_equal "missing", result.dig("evidence", "receipt")
    assert_equal "unconfirmed", result.dig("cleanup", "status")
  end

  def test_symlink_malformed_wrong_id_public_and_fifo_evidence_are_unknown
    save
    path = File.join(@directory, "#{ID}.json")
    ["not json", JSON.generate(receipt(OTHER))].each do |bytes|
      File.write(path, bytes)
      assert_equal "invalid", @host.merge_validation_status(attempt: ID).dig("evidence", "receipt")
    end
    File.chmod(0o644, path)
    assert_equal "invalid", @host.merge_validation_status(attempt: ID).dig("evidence", "receipt")
    File.unlink(path)
    File.symlink(File.join(@directory, "#{ID}.resources.json"), path)
    assert_equal "invalid", @host.merge_validation_status(attempt: ID).dig("evidence", "receipt")
    File.unlink(path)
    File.mkfifo(path, 0o600)
    assert_equal "invalid", @host.merge_validation_status(attempt: ID).dig("evidence", "receipt")
    File.unlink(path)
    File.rename(@directory, @directory + "-actual")
    File.symlink(@directory + "-actual", @directory)
    assert_equal "invalid", @host.merge_validation_status(attempt: ID).dig("evidence", "receipt")
  end

  def invoke(args, service = @host)
    output, error = StringIO.new, StringIO.new
    cli = SiloMigrate::StandardCLI.new(output: output, error: error)
    code = cli.stub(:service, service) { cli.run(args) }
    [code, output.string, error.string]
  end

  def test_cli_strict_engineer_only_read_surface
    save
    code, output, error = invoke(%w[workflow validation-status invented --attempt latest])
    assert_equal 0, code
    assert_empty error
    assert_equal ID, JSON.parse(output).fetch("attempt_id")
    [%w[workflow validation-status invented], %w[workflow validation-status invented --attempt ../secret],
     %w[workflow validation-status invented --attempt latest extra], %w[agent workflow validation-status invented --attempt latest],
     %w[workflow validation-status invented --attempt latest --attempt latest]].each do |args|
      assert_equal [1, "", "Error: STANDARD_ARGUMENTS_INVALID\n"], invoke(args)
    end
  end

  def test_proposal_failure_keeps_outer_code_and_emits_safe_attempt_reference_through_cli
    save
    @host.validation_result = receipt
    service = Object.new
    service.define_singleton_method(:status) { @host.binding! }
    service.instance_variable_set(:@host, @host)
    code, output, error = invoke(%w[status invented], service)
    assert_equal 1, code
    assert_equal "Error: STANDARD_MERGE_VALIDATION_FAILED\n", error
    result = JSON.parse(output)
    assert_equal "STANDARD_MERGE_VALIDATION_FAILED", result.fetch("error")
    assert_equal ID, result.dig("validation", "attempt_id")
    assert_equal "policy_conflict", result.dig("validation", "work", "reason")
    refute_includes output, PRIVATE
  end

  def test_pre_attempt_refusal_has_no_fabricated_receipt
    @host.validation_result = { "version" => 1, "status" => "refused", "reason" => "STANDARD_MERGE_SETTINGS_INVALID", "key_path" => [PRIVATE] }
    error = assert_raises(SiloMigrate::StandardMergeValidationFailure) { @host.binding! }
    assert_nil error.validation.fetch("attempt_id")
    assert_equal "STANDARD_MERGE_SETTINGS_INVALID", error.validation.dig("work", "reason")
    assert_equal "missing", error.validation.dig("evidence", "receipt")
    refute_path_exists @directory
  end
end
