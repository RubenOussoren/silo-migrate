# frozen_string_literal: true

require_relative "standard_merge_preparation_test"

# Scripted workflow execution only: no live Docker, customer layer or database.
# The existing lifecycle fixture supplies custody/validation; restore the real
# collector to verify secondary refusal evidence cannot replace the runner exit.
class StandardMergeExecutionRefusalTest < StandardMergePreparationTest
  def self.runnable_methods
    public_instance_methods(false).grep(/^test_/).map(&:to_s)
  end

  def test_preconstructor_refusal_preserves_primary_failure_dirty_state_and_no_backup
    ["valid", "malformed", "multiple"].each do |kind|
      with_prepare do
        prep = prepared
        use_layer
        @service.singleton_class.remove_method(:merge_process_collect!)
        plan = prepared_plan(prep, intent: "custom", settings: @merge_settings)
        envelope = SiloMergeRefusal.capture(contract: { "audit_aggregates" => { "preflight" => [], "postflight" => [] } },
          merger: nil, phase: "preflight", context: "execution", reason: "preflight_refused", error: ArgumentError.new("PRIVATE primary"))
        frame = SiloMergeRefusal::PREFIX + JSON.generate(envelope) + "\n"
        frame = SiloMergeRefusal::PREFIX + "PRIVATE malformed\n" if kind == "malformed"
        frame += frame if kind == "multiple"
        @runtime.merger_result = SiloMigrate::Runtime::CommandResult.new(success?: false, status: 3,
          stdout: frame, stderr: "SILO_MERGE: layer policy check failed (ArgumentError)\n")
        run = @service.run_plan(plan_id: approve(plan))
        assert_equal "failed", run[:status]
        assert_equal "STANDARD_MERGE_LAYER_INVALID", run.dig(:failure, "code"), failure_detail(run)
        assert_equal "failed", run.dig(:stages, "merge")
        assert_equal "pending", run.dig(:stages, "backup")
        assert_equal "dirty", environment(prep[:run_id])["phase"]
        assert_nil run.dig(:artifacts, "backup")
        evidence = @service.send(:merge_process_evidence, run[:run_id])
        refute evidence["complete"]
        if kind == "valid"
          assert evidence["available"]
          assert_equal "preflight_refused", evidence.dig("failure", "reason")
        else
          assert_equal "evidence_invalid", evidence.dig("failure", "reason")
        end
        refute_match(/PRIVATE/, JSON.generate(evidence))
        refute File.exist?(@service.store.run_dir(run[:run_id], "private", "merge-asset-manifest.json"))
        refute File.exist?(@service.store.run_dir(run[:run_id], "private", "merge-process.json"))
      end
    end
  end
end
