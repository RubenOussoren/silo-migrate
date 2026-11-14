# frozen_string_literal: true
require_relative "test_helper"
require_relative "support/merge_settings_runner"

class MergeProcessHookChecksTest < SiloMigrateTest
  include MergeSettingsRunner
  STUB = File.expand_path("support/merge_process_stub.rb", __dir__)

  def process_run(layer: checked_layer, required: true, write: nil)
    run_merge(layer: layer, required: required, env: { "RUBYOPT" => "-r#{STUB}",
      "SILO_MERGE_CONTRACT" => "/test-only/contract.json", "TEST_PROCESS_WRITE" => write })
  end

  def test_contract_implies_mandatory_checks_and_physical_transfer_precedes_restore
    result = process_run(required: false)
    assert result.status.success?, result.err
    assert_equal %w[EVENT:preflight EVENT:process-preflight EVENT:constructor EVENT:copy], events(result).first(4)
    assert_operator events(result).index("EVENT:process-transfer"), :<, events(result).index("EVENT:postflight")
    assert_operator events(result).index("EVENT:postflight"), :<, events(result).index("EVENT:process-postflight")
    assert_includes events(result), "EVENT:postflight-sees=jpg|jpeg|png|gif|heic|heif|webp|avif"
    assert_untouched(result, SITE)
  end

  def test_process_preflight_hook_cannot_hide_a_setting_write_in_stock_window
    result = process_run(write: "preflight")
    assert_equal 4, result.status.exitstatus
    assert_includes result.err, "changed-by-process-preflight"
    refute_includes events(result), "EVENT:constructor"
    assert_untouched(result, SITE)
  end

  def test_postflight_audit_hook_is_guarded_and_never_reports_runner_success
    result = process_run(write: "postflight")
    assert_equal 4, result.status.exitstatus
    assert_includes result.err, "changed-by-process-postflight"
    refute_includes result.out, "SILO_MERGE: done"
    assert_untouched(result, SITE)
  end

  def test_contract_without_hooks_refuses_even_if_legacy_flag_is_off
    result = process_run(layer: "class InventedLayer < BulkImport::DiscourseMerger; end", required: false)
    assert_equal 3, result.status.exitstatus
    refute_includes events(result), "EVENT:constructor"
  end
end
