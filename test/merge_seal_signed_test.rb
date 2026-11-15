# frozen_string_literal: true
require_relative "standard_merge_preparation_test"

class MergeSealSignedTest < SiloMigrateTest
  PREPARATION = SiloMigrate::Services::StandardMergePreparation
  PREFIX = "#{'a' * 32}|#{'b' * 32}:2611|2,1,1,1,1,0,2|"

  def test_only_bounded_canonical_maximum_ids_may_be_signed
    %w[-1,0,1,-42 0,0,0,0 999999999999999999,-999999999999999999,1,0].each do |ids|
      assert_match PREPARATION::MERGE_SEAL, PREFIX + ids
    end
    %w[-0,0,0,0 +1,0,0,0 -01,0,0,0 01,0,0,0 --1,0,0,0 1.0,0,0,0 1000000000000000000,0,0,0 -1000000000000000000,0,0,0 0,0,0 0,0,0,0,0].each do |ids|
      refute_match PREPARATION::MERGE_SEAL, PREFIX + ids
    end
    refute_match PREPARATION::MERGE_SEAL, PREFIX.sub("|2,", "|-2,") + "-1,0,0,0"
    refute_match PREPARATION::MERGE_SEAL, PREFIX.sub(":2611", ":-2611") + "-1,0,0,0"
    refute_match PREPARATION::MERGE_SEAL, PREFIX + "-1, 0,0,0"
  end

  def test_merge_seal_preserves_observed_negative_signs_without_normalizing
    value = PREFIX + "-1,0,-42,-2"
    host = Object.new.extend(PREPARATION)
    host.define_singleton_method(:merge_environment_sql) { |*_, **| value + "\n" }
    assert_equal value, host.send(:merge_seal, "invented", "discourse")
    value = PREFIX + "+1,0,0,0"
    error = assert_raises(SiloMigrate::StandardWorkflowError) { host.send(:merge_seal, "invented", "discourse") }
    assert_equal "STANDARD_MERGE_ENVIRONMENT_DIRTY", error.code
  end
end

class StandardMergePreparationTest
  def test_prepare_negative_system_ids_are_sealed_and_sign_changes_still_fence_activation
    with_prepare do
      base = PrepareScriptedRuntime.seal("a").sub(/\|1,1,1,1\z/, "|-1,0,-42,-2")
      source = PrepareScriptedRuntime.seal("c").sub(/\|1,1,1,1\z/, "|-2,0,0,-3")
      @runtime.content.merge!("discourse" => base, "merge_source" => source)
      prep = prepared
      assert_equal base, record(prep[:run_id]).fetch("seals").fetch("base")
      assert_equal source, record(prep[:run_id]).fetch("seals").fetch("source")
      assert_equal base, @runtime.content.fetch("discourse")
      assert_equal source, @runtime.content.fetch("silo_inspect_source")
      @runtime.content["silo_clean_base"] = base.sub("|-1,", "|1,")
      run = @service.run_plan(plan_id: approve(prepared_plan(prep)))
      assert_equal "STANDARD_MERGE_ENVIRONMENT_DIRTY", run.dig(:failure, "code")
      assert_equal "failed", run.dig(:stages, "activate")
      refute index_of(%r{ruby /tmp/merge_run\.rb})
      assert_equal "dirty", environment(prep[:run_id])["phase"]
    end
  end
end
