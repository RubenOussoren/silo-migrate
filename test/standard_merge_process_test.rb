# frozen_string_literal: true

require_relative "test_helper"

class StandardMergeProcessTest < SiloMigrateTest
  PROCESS = SiloMigrate::Services::StandardMergeProcess
  class FixtureStore
    def initialize(root) = @root = root
    def run_dir(run, *parts) = File.join(@root, run, *parts)
    def write_private(path, bytes)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.write(path, bytes, mode: "wb", perm: 0o600)
    end
  end
  class Host
    include PROCESS
    attr_reader :store
    def initialize(root, body)
      @store = FixtureStore.new(root)
      @plan = { "body" => body }
    end
    def plan_for(*) = @plan
  end
  class FixtureStack
    def initialize(bytes, references, baseline) = (@bytes, @references, @baseline = bytes, references, baseline)
    def copy_out(guest, path)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      bytes = guest.end_with?("/references.json") ? @references : guest.end_with?("/baseline-assets.json") ? @baseline : @bytes
      File.binwrite(path, bytes)
    end
  end

  def with_process
    Dir.mktmpdir do |dir|
      @manifest = { "version" => 1, "policy" => "carried", "entries" => [
        { "key" => "invented-id", "source" => "original/a.txt", "destination" => "original/a.txt", "bytes" => 1,
          "digest" => { "algorithm" => "sha256", "value" => Digest::SHA256.hexdigest("a") }, "disposition" => "copy", "required" => true }
      ] }
      @bytes = JSON.generate(@manifest) + "\n"
      @contract = { "audit_aggregates" => { "preflight" => ["selected"], "postflight" => ["verified"] } }
      @body = { "merge" => { "process" => { "engine" => "discourse-merger-v1", "physical_policy" => "carried" }, "contract" => @contract } }
      @host = Host.new(dir, @body)
      @references = JSON.generate({ "version" => 1, "excluded_inserted_ids" => [12, 13], "dangling_ids" => [] }) + "\n"
      @baseline = JSON.generate({ "version" => 1, "files" => [], "derived_files" => 0 }) + "\n"
      @stack = FixtureStack.new(@bytes, @references, @baseline)
      yield
    end
  end

  def report(phase)
    audit = { "preflight" => { "selected" => 1 } }
    audit["postflight"] = { "verified" => 1 } if phase == "postflight"
    result = { "version" => 1, "engine" => "discourse-merger-v1", "phase" => phase, "complete" => phase == "postflight",
      "physical_policy" => "carried", "audit_aggregates" => audit }
    if phase != "preflight"
      result["transfer"] = { "files_copied" => 1, "files_reused" => 0, "files_skipped_by_policy" => 2 }
      result["manifest_sha256"] = Digest::SHA256.hexdigest(@bytes)
      result["references_sha256"] = Digest::SHA256.hexdigest(@references)
      result["baseline_sha256"] = Digest::SHA256.hexdigest(@baseline)
    end
    if phase == "postflight"
      result["upload_rows_inserted"] = 3
      result["upload_rows_inserted_without_references"] = 2
    end
    result
  end

  def output(phases = PROCESS::PROCESS_PHASES)
    phases.map { |phase| PROCESS::PROCESS_PREFIX + JSON.generate(report(phase)) + "\n" }.join
  end

  def result(text, success: true)
    SiloMigrate::Runtime::CommandResult.new(stdout: text, stderr: "PRIVATE error body", success?: success, status: success ? 0 : 1)
  end

  def test_machine_protocol_and_private_manifest_reach_evidence_without_log_scraping
    with_process do
      @host.merge_process_collect!("run-invented", @stack, result("free form PRIVATE data\n" + output))
      evidence = @host.merge_process_evidence("run-invented")
      assert evidence["complete"]
      assert_equal({ "selected" => 1 }, evidence.dig("audit_aggregates", "preflight"))
      assert_equal 2, evidence.dig("engine", "upload_rows_inserted_without_references")
      assert_equal 1, evidence.dig("runner", "files_copied")
      refute_match(/PRIVATE|invented-id|original\/a/, JSON.generate(evidence))
      assert_equal @manifest, @host.merge_process_manifest("run-invented")
      assert_equal 0o600, File.stat(@host.store.run_dir("run-invented", "private", "merge-asset-manifest.json")).mode & 0o777
    end
  end

  def test_failed_execution_retains_partial_evidence_without_making_counts_zero
    with_process do
      @host.merge_process_collect!("run-invented", @stack, result(output(["preflight"]), success: false))
      evidence = @host.merge_process_evidence("run-invented")
      assert evidence["available"]
      refute evidence["complete"]
      assert_nil evidence["runner"]
      assert_equal({}, evidence["engine"])
    end
  end

  def refusal_frame(phase = "preflight", counts = nil)
    counts ||= phase == "preflight" ? { "selected" => 4 } : {}
    merger = Object.new
    merger.define_singleton_method(:silo_merge_audit) { |_| counts }
    envelope = SiloMergeRefusal.capture(contract: @contract, merger: merger, context: "execution",
      phase: phase, reason: "#{phase}_refused", error: RuntimeError.new("PRIVATE primary"))
    SiloMergeRefusal::PREFIX + JSON.generate(envelope) + "\n"
  end

  def test_preconstructor_refusal_is_available_without_ordinary_evidence_or_backup_artifacts
    with_process do
      @host.merge_process_collect!("run-invented", @stack, result(refusal_frame, success: false))
      evidence = @host.merge_process_evidence("run-invented")
      assert evidence["available"]
      refute evidence["complete"]
      assert_equal "preflight_refused", evidence.dig("failure", "reason")
      assert_equal({ "selected" => 4 }, evidence.dig("audit_aggregates", "preflight"))
      refute File.exist?(@host.store.run_dir("run-invented", "private", "merge-process.json"))
      refute File.exist?(@host.store.run_dir("run-invented", "private", "merge-asset-manifest.json"))
      assert_equal 0o600, File.stat(@host.store.run_dir("run-invented", "private", "merge-refusal.json")).mode & 0o777
      error = assert_raises(SiloMigrate::StandardWorkflowError) { @host.merge_process_manifest("run-invented") }
      assert_equal "STANDARD_BACKUP_FAILED", error.code
      refute_includes JSON.generate(evidence), "PRIVATE"
    end
  end

  def test_postflight_refusal_keeps_earlier_counts_and_unknown_missing_counts
    with_process do
      @host.merge_process_collect!("run-invented", @stack,
        result(output(%w[preflight transfer]) + refusal_frame("postflight"), success: false))
      evidence = @host.merge_process_evidence("run-invented")
      assert evidence["available"]
      refute evidence["complete"]
      assert_equal({ "selected" => 1 }, evidence.dig("audit_aggregates", "preflight"))
      assert_equal({}, evidence.dig("audit_aggregates", "postflight"))
      assert_equal ["verified"], evidence.dig("failure", "missing_keys")
      assert_equal 1, evidence.dig("runner", "files_copied")
      refute File.exist?(@host.store.run_dir("run-invented", "private", "merge-asset-manifest.json"))
    end
  end

  def test_forged_malformed_and_multiple_refusals_do_not_replace_failed_subprocess
    with_process do
      valid = refusal_frame
      forged = JSON.parse(valid.delete_prefix(SiloMergeRefusal::PREFIX))
      forged["counts"] = { "PRIVATE_UNDECLARED" => 4 }
      wrong_context = JSON.parse(valid.delete_prefix(SiloMergeRefusal::PREFIX))
      wrong_context["context"] = "validation"
      [SiloMergeRefusal::PREFIX + "PRIVATE bad json\n", valid + valid,
        SiloMergeRefusal::PREFIX + JSON.generate(forged),
        SiloMergeRefusal::PREFIX + JSON.generate(wrong_context),
        SiloMergeRefusal::PREFIX + ('x' * (128 * 1024 + 1))].each do |frame|
        # A secondary parser error here would prevent the workflow from raising
        # its original subprocess failure. This collector must simply return.
        @host.merge_process_collect!("run-invented", @stack, result(frame, success: false))
        evidence = @host.merge_process_evidence("run-invented")
        refute evidence["complete"]
        assert_equal "evidence_invalid", evidence.dig("failure", "reason")
        refute evidence["audit_aggregates"]
        refute_match(/PRIVATE|bad json/, JSON.generate(evidence))
      end
    end
  end

  def test_secondary_private_evidence_write_error_does_not_replace_failed_subprocess
    with_process do
      @host.store.define_singleton_method(:write_private) { |*| raise IOError, "PRIVATE storage detail" }
      @host.merge_process_collect!("run-invented", @stack, result(refusal_frame, success: false))
      assert_equal false, @host.merge_process_evidence("run-invented")["available"]
      error = assert_raises(SiloMigrate::StandardWorkflowError) do
        @host.merge_process_collect!("run-invented", @stack, result(refusal_frame))
      end
      assert_equal "STANDARD_MERGE_EVIDENCE_INVALID", error.code
      refute_includes error.message, "PRIVATE"
    end
  end

  def test_success_with_any_refusal_frame_rejects_before_copying_backup_artifacts
    with_process do
      [refusal_frame, SiloMergeRefusal::PREFIX + "broken\n", refusal_frame + refusal_frame].each do |frame|
        error = assert_raises(SiloMigrate::StandardWorkflowError) do
          @host.merge_process_collect!("run-invented", @stack, result(output + frame))
        end
        assert_equal "STANDARD_MERGE_EVIDENCE_INVALID", error.code
        refute @host.merge_process_evidence("run-invented")["complete"]
        refute File.exist?(@host.store.run_dir("run-invented", "private", "merge-asset-manifest.json"))
      end
    end
  end

  def test_missing_final_report_or_duplicate_phase_cannot_claim_success
    with_process do
      [output(["preflight"]), output(["preflight", "preflight"])].each do |text|
        error = assert_raises(SiloMigrate::StandardWorkflowError) { @host.merge_process_collect!("run-invented", @stack, result(text)) }
        assert_equal "STANDARD_MERGE_EVIDENCE_INVALID", error.code
      end
    end
  end

  def test_unknown_metric_or_false_count_refuses_without_exposing_values
    with_process do
      record = report("preflight")
      record["audit_aggregates"]["preflight"] = { "PRIVATE_DYNAMIC_KEY" => 1 }
      error = assert_raises(SiloMigrate::StandardWorkflowError) do
        @host.merge_process_collect!("run-invented", @stack, result(PROCESS::PROCESS_PREFIX + JSON.generate(record)))
      end
      refute_includes error.message, "PRIVATE_DYNAMIC_KEY"
      assert_equal "STANDARD_MERGE_EVIDENCE_INVALID", error.code
    end
  end

  def test_manifest_tampering_prevents_backup_use
    with_process do
      @host.merge_process_collect!("run-invented", @stack, result(output))
      path = @host.store.run_dir("run-invented", "private", "merge-asset-manifest.json")
      File.write(path, @bytes.sub("original/a", "original/b"))
      error = assert_raises(SiloMigrate::StandardWorkflowError) { @host.merge_process_manifest("run-invented") }
      assert_equal "STANDARD_BACKUP_FAILED", error.code
    end
  end

  def test_clean_plan_projection_drops_receipt_selection_and_contract_fields
    service = SiloMigrate::Services::StandardWorkflowService.allocate
    merge = { "layer" => { "present" => true }, "contract" => { "PRIVATE_FIELD" => 1 },
      "process" => { "version" => 1, "engine" => "discourse-merger-v1", "physical_policy" => "carried",
                     "selection_sha256" => "PRIVATE_SELECTION", "receipt_sha256" => "PRIVATE_RECEIPT" } }
    clean = service.send(:public_merge_plan, merge, detail: false)
    refute_match(/PRIVATE/, JSON.generate(clean))
    assert_equal true, clean.dig("process", "validated")
    assert_equal merge, service.send(:public_merge_plan, merge, detail: true)
  end
end
