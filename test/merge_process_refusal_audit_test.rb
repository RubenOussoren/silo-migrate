# frozen_string_literal: true

require_relative "test_helper"
require_relative "../runtime/shared/merge_refusal"

class MergeProcessRefusalAuditTest < SiloMigrateTest
  def setup
    @contract = { "audit_aggregates" => { "preflight" => %w[selected checked], "postflight" => %w[verified pending] } }
  end

  def capture(value = {}, phase: "preflight", context: "execution", error: nil, reason: "preflight_refused", &block)
    merger = Object.new
    merger.define_singleton_method(:silo_merge_audit) { |received| block ? block.call(received) : value }
    SiloMergeRefusal.capture(contract: @contract, merger: merger, phase: phase, context: context, reason: reason, error: error)
  end

  def validate(value, context: "execution")
    assert_same value, SiloMergeRefusal.validate!(@contract, value, context: context)
  end

  def test_partial_counts_are_declared_numeric_and_never_complete
    value = capture({ "selected" => 7 })
    assert_equal "partial", value["audit_status"]
    assert_equal({ "selected" => 7 }, value["counts"])
    assert_equal ["checked"], value["missing_keys"]
    assert_equal "before_constructor", value["write_boundary"]
    refute value["complete"]
    validate(value)
    full = capture({ "selected" => 0, "checked" => SiloMergeContract::MAX_COUNT })
    assert_equal [], full["missing_keys"]
    refute full["complete"]
    validate(full)
  end

  def test_validation_and_postflight_boundaries
    value = capture({}, context: "validation")
    assert_equal "read_only_clones", value["write_boundary"]
    validate(value, context: "validation")
    post = capture({ "verified" => 3 }, phase: "postflight", reason: "postflight_refused")
    assert_equal "after_constructor", post["write_boundary"]
    assert_equal ["pending"], post["missing_keys"]
    validate(post)
    assert_raises(SiloMergeRefusal::Error) { SiloMergeRefusal.validate!(@contract, post, context: "validation") }
  end

  def test_absent_hook_and_invalid_declaration_do_not_call_project_code
    value = SiloMergeRefusal.capture(contract: @contract, merger: nil, phase: "preflight", context: "execution", reason: "preflight_refused")
    assert_equal "unavailable", value["audit_status"]
    assert_equal %w[checked selected], value["missing_keys"]
    validate(value)
    @contract["audit_aggregates"]["postflight"] = ["PRIVATE-undeclared"]
    value = capture { flunk "must not call hook" }
    assert_equal "invalid", value["audit_status"]
    refute_includes JSON.generate(value), "PRIVATE"
  end

  def test_malformed_audits_are_discarded_without_coercion_or_zero_filling
    [nil, [], { "unknown" => 5 }, { "selected" => -1 }, { "selected" => "2" },
      { "selected" => 2.0 }, { "selected" => false }, { "selected" => SiloMergeContract::MAX_COUNT + 1 },
      { "selected" => 1, "checked" => "PRIVATE" }].each do |raw|
      value = capture(raw)
      assert_equal "invalid", value["audit_status"]
      assert_equal({}, value["counts"])
      assert_equal %w[checked selected], value["missing_keys"]
      validate(value)
      refute_includes JSON.generate(value), "PRIVATE"
    end
  end

  def test_callback_exceptions_exits_and_timeout_are_secondary
    [RuntimeError.new("PRIVATE MESSAGE"), SystemExit.new(0, "PRIVATE EXIT")].each do |error|
      value = capture { raise error }
      assert_equal "hook_failed", value["audit_status"]
      assert_equal({}, value["counts"])
      assert_nil value["error_class"] # callback class is not the policy error
      validate(value)
      refute_includes JSON.generate(value), "PRIVATE"
    end
    value = capture { sleep 10 }
    assert_equal "hook_failed", value["audit_status"]
    validate(value)
  end

  def test_only_bounded_policy_class_metadata_and_fixed_reasons_survive
    value = capture({}, error: RuntimeError.new("PRIVATE MESSAGE"), reason: "PRIVATE REASON")
    assert_equal "RuntimeError", value["error_class"]
    assert_equal "validation_unproven", value["reason"]
    refute_includes JSON.generate(value), "PRIVATE"
    validate(value)
    anonymous = Class.new(StandardError).new("PRIVATE")
    assert_nil capture({}, error: anonymous)["error_class"]
    error = RuntimeError.new
    error.class.stub(:name, "A" * 257) { assert_nil capture({}, error: error)["error_class"] }
    error.class.stub(:name, "Private\nInjected") { assert_nil capture({}, error: error)["error_class"] }
  end

  def test_strict_validation_rejects_tampered_or_oversized_envelopes_with_fixed_errors
    value = capture({ "selected" => 1 })
    mutations = [value.merge("extra" => "PRIVATE"), value.merge("version" => 1.0), value.merge("complete" => true),
      value.merge("missing_keys" => []), value.merge("write_boundary" => "after_constructor"),
      value.merge("reason" => "PRIVATE"), value.merge("error_class" => "PRIVATE\nVALUE"),
      value.merge("audit_status" => "unavailable"), value.merge("counts" => { "selected" => "PRIVATE" }),
      value.merge("missing_keys" => ["x" * (128 * 1024 + 1)])]
    mutations.each do |bad|
      error = assert_raises(SiloMergeRefusal::Error) { SiloMergeRefusal.validate!(@contract, bad, context: "execution") }
      assert_equal "MERGE_REFUSAL_INVALID", error.message
    end
  end
end
