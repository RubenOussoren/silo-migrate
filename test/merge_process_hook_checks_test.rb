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

  def refusal(result)
    frames = result.out.lines.grep(/\ASILO_MERGE_REFUSAL:/)
    assert_equal 1, frames.size
    JSON.parse(frames.first.delete_prefix("SILO_MERGE_REFUSAL:"))
  end

  def test_raised_and_false_preflight_refusals_capture_before_constructor
    ["raise 'PRIVATE refusal detail'", "false", "exit 0"].each do |action|
      layer = checked_layer(<<~RUBY)
        def self.silo_merge_preflight!
          @refused_in_same_process = true
          #{action}
        end
        def self.silo_merge_audit(phase)
          raise 'lost state' unless @refused_in_same_process && phase == 'preflight'
          { 'selected' => 4 }
        end
      RUBY
      result = process_run(layer: layer)
      assert_equal 3, result.status.exitstatus
      assert_includes result.err, "layer policy check failed"
      refute_includes result.err, "PRIVATE"
      frame = refusal(result)
      assert_equal "preflight_refused", frame["reason"]
      assert_equal "before_constructor", frame["write_boundary"]
      assert_equal "partial", frame["audit_status"]
      assert_equal({ "selected" => 4 }, frame["counts"])
      assert_equal ["checked"], frame["missing_keys"]
      %w[EVENT:constructor EVENT:copy EVENT:process-transfer].each { |event| refute_includes events(result), event }
      refute_includes result.out, "SILO_MERGE: done"
      assert_untouched(result, SITE)
    end
  end

  def test_postflight_refusal_captures_same_process_partial_counts_after_restore
    layer = checked_layer(<<~RUBY)
      def self.silo_merge_preflight!
        @token = 7
        true
      end
      def self.silo_merge_postflight!
        raise 'PRIVATE postflight'
      end
      def self.silo_merge_audit(phase)
        raise 'lost state' unless @token == 7 && phase == 'postflight'
        { 'verified' => @token }
      end
    RUBY
    result = process_run(layer: layer)
    assert_equal 3, result.status.exitstatus
    frame = refusal(result)
    assert_equal "postflight", frame["phase"]
    assert_equal "after_constructor", frame["write_boundary"]
    assert_equal({ "verified" => 7 }, frame["counts"])
    assert_equal ["pending"], frame["missing_keys"]
    assert_includes events(result), "EVENT:process-transfer"
    refute_includes events(result), "EVENT:process-postflight"
    assert_untouched(result, SITE)
  end

  def test_secondary_audit_exit_cannot_mask_primary_or_settings_restoration
    ["raise 'PRIVATE audit'", "exit 0", "exit 12"].each do |action|
      layer = checked_layer(<<~RUBY)
        def self.silo_merge_preflight!
          raise ArgumentError, 'PRIVATE primary'
        end
        def self.silo_merge_audit(*)
          #{action}
        end
      RUBY
      result = process_run(layer: layer)
      assert_equal 3, result.status.exitstatus
      assert_includes result.err, "policy check failed (ArgumentError)"
      frame = refusal(result)
      assert_equal "hook_failed", frame["audit_status"]
      assert_equal "ArgumentError", frame["error_class"]
      assert_equal({}, frame["counts"])
      assert_equal %w[checked selected], frame["missing_keys"]
      refute_includes result.out + result.err, "PRIVATE"
      assert_untouched(result, SITE)
    end
  end

  def test_refused_contract_without_audit_hook_reports_unknown_counts
    result = process_run(layer: checked_layer("def self.silo_merge_preflight!; false; end"))
    assert_equal 3, result.status.exitstatus
    frame = refusal(result)
    assert_equal "unavailable", frame["audit_status"]
    assert_equal({}, frame["counts"])
    assert_equal %w[checked selected], frame["missing_keys"]
    assert_untouched(result, SITE)
  end

  def test_no_contract_refusal_does_not_add_audit_requirements_or_frames
    result = run_merge(layer: checked_layer("def self.silo_merge_preflight!; false; end"))
    assert_equal 3, result.status.exitstatus
    refute_includes result.out, "SILO_MERGE_REFUSAL:"
    assert_untouched(result, SITE)
  end

  def test_contract_implies_mandatory_checks_and_physical_transfer_precedes_restore
    result = process_run(required: false)
    assert result.status.success?, result.err
    refute_includes result.out, "SILO_MERGE_REFUSAL:"
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
