# frozen_string_literal: true
require_relative 'standard_merge_preparation_test'
require_relative 'standard_run_inputs_test'

# Loading run-input tests must not replace the Prepare lifecycle suite's filter.
class PrepareTestDiscoveryTest < Minitest::Test
  def test_lifecycle_and_input_preparation_have_independent_discovery
    assert_includes StandardMergePreparationTest.runnable_methods, 'test_prepare_run_reaches_ready_without_constructing_a_merger'
    assert_includes StandardMergePreparationTest.runnable_methods, 'test_prepare_database_inventory_checks_the_fresh_stack_before_restore'
    assert_includes StandardMergePreparationTest.runnable_methods, 'test_prepare_initial_database_probe_command_failure_is_stack_failure'
    assert_includes StandardMergePreparationInputsTest.runnable_methods, 'test_merge_preparation_code_readiness_comes_from_the_pinned_layer'
    refute_equal StandardMergePreparationTest, StandardMergePreparationInputsTest
  end
end
