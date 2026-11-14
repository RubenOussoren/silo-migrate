# frozen_string_literal: true
require_relative "standard_merge_preparation_test"

class StandardMergeProcessIntegrationTest < StandardMergePreparationTest
  def self.runnable_methods
    public_instance_methods(false).grep(/^test_/).map(&:to_s)
  end

  def test_process_failures_keep_their_typed_code_and_dirty_the_consumed_environment
    {
      "STANDARD_MERGE_EVIDENCE_INVALID" => :merge_process_collect!,
      "STANDARD_MERGE_ASSETS_FAILED" => :merge_process_references_check!
    }.each do |code, hook|
      with_prepare do
        prep = prepared
        use_layer
        plan = prepared_plan(prep, intent: "custom", settings: @merge_settings)
        @service.define_singleton_method(hook) { |*| raise SiloMigrate::StandardWorkflowError, code }
        run = @service.run_plan(plan_id: approve(plan))
        assert_equal "failed", run[:status]
        assert_equal code, run.dig(:failure, "code")
        refute_equal "STANDARD_INTERNAL", run.dig(:failure, "code")
        assert_equal "dirty", environment(prep[:run_id])["phase"]
        assert_nil run.dig(:artifacts, "backup")
        assert_instance_of String, run.dig(:failure, "recovery")
      end
    end
  end

  def test_preclaim_refusal_leaves_plan_generation_and_inspection_unconsumed
    with_prepare do
      prep = prepared
      use_layer
      plan = prepared_plan(prep, intent: "custom", settings: @merge_settings)
      plan_id = approve(plan)
      state = @service.store.load
      @service.define_singleton_method(:merge_validation_gate!) do |*, **|
        raise SiloMigrate::StandardWorkflowError, "STANDARD_MERGE_VALIDATION_STALE"
      end
      issued = @runtime.commands.size
      error = assert_raises(SiloMigrate::StandardWorkflowError) { @service.run_plan(plan_id: plan_id) }
      assert_equal "STANDARD_MERGE_VALIDATION_STALE", error.code
      assert_equal state, @service.store.load
      assert_equal [], @runtime.commands.drop(issued).grep(/\Adocker /)
      assert_equal "ready", environment(prep[:run_id])["phase"]
      assert_nil environment(prep[:run_id])["consumed_by"]
    end
  end
end
