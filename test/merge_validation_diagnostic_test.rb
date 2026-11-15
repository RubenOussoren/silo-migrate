# frozen_string_literal: true

require_relative "test_helper"
require_relative "../runtime/shared/merge_validation_diagnostic"

class MergeValidationDiagnosticTest < SiloMigrateTest
  class SecretCustomerPolicyError < StandardError; end

  def test_constants_and_wire_fields_match_contract
    assert_equal %w[version stage error_class component line], SiloMergeValidationDiagnostic::FIELDS
    %w[
      unknown bootstrap context checks_database rails_boot runtime_binding
      contract_settings contract_validation settings layer_load connections
      hook_validation policy_preflight asset_selection audit
      existence_checks asset_preflight result_persistence result_close unknown
    ].each do |stage|
      assert_includes SiloMergeValidationDiagnostic::STAGES, stage
    end
    assert_equal %w[
      validation_runner validation_config contract asset_adapter
      asset_references baseline_assets stock_runtime custom_layer unknown
    ], SiloMergeValidationDiagnostic::COMPONENTS
    assert_includes SiloMergeValidationDiagnostic::ERROR_CLASSES, "none"
    assert_includes SiloMergeValidationDiagnostic::ERROR_CLASSES, "other"
  end

  def test_nil_error_uses_none_sentinel_and_stage_component
    diag = SiloMergeValidationDiagnostic.capture(stage: "existence_checks", error: nil)
    assert_equal({
      "version" => 1,
      "stage" => "existence_checks",
      "error_class" => "none",
      "component" => "validation_runner",
      "line" => nil
    }, diag)
    assert_same diag, SiloMergeValidationDiagnostic.validate!(diag)

    boot = SiloMergeValidationDiagnostic.capture(stage: "bootstrap", error: nil)
    assert_equal "validation_config", boot["component"]
    assert_equal "none", boot["error_class"]
    assert_nil boot["line"]
    SiloMergeValidationDiagnostic.validate!(boot)
  end

  def test_custom_classes_and_messages_never_leak
    canary_message = "CANARY_SECRET_MESSAGE_password=supersecret"
    error = SecretCustomerPolicyError.new(canary_message)
    error.set_backtrace(["/shared/silo-validation-#{'a' * 32}/layer/merger.rb:42:in `silo_merge_preflight!'"])
    diag = SiloMergeValidationDiagnostic.capture(stage: "policy_preflight", error: error)
    serialized = JSON.generate(diag)

    assert_equal "policy_preflight", diag["stage"]
    assert_equal "other", diag["error_class"]
    assert_equal "custom_layer", diag["component"]
    assert_nil diag["line"]
    refute_includes serialized, "SecretCustomerPolicyError"
    refute_includes serialized, canary_message
    refute_includes serialized, "merger.rb"
    refute_includes serialized, "42"
    SiloMergeValidationDiagnostic.validate!(diag)
  end

  def test_shipped_and_stock_components_preserve_bounded_lines_while_custom_and_unknown_hide_lines
    guest_dir = "/shared/silo-validation-#{'b' * 32}"
    cases = [
      ["#{guest_dir}/merge_validate.rb:128:in `run!'", "validation_runner", 128],
      ["#{guest_dir}/merge_validation_config.rb:35:in `build!'", "validation_config", 35],
      ["#{guest_dir}/merge_contract.rb:214:in `validate!'", "contract", 214],
      ["#{guest_dir}/merge_refusal.rb:61:in `capture'", "contract", 61],
      ["#{guest_dir}/merge_adapter.rb:90:in `prepare!'", "asset_adapter", 90],
      ["#{guest_dir}/merge_assets.rb:44:in `verify!'", "asset_adapter", 44],
      ["#{guest_dir}/merge_asset_references.rb:19:in `destination_root'", "asset_references", 19],
      ["#{guest_dir}/merge_baseline_assets.rb:72:in `scan!'", "baseline_assets", 72],
      ["/var/www/discourse/config/environment.rb:17:in `<top (required)>'", "stock_runtime", 17],
      ["/gems/ruby/3.3.0/gems/activerecord-7.1.0/lib/active_record/connection_adapters/postgresql_adapter.rb:88:in `exec'", "stock_runtime", 88],
      ["#{guest_dir}/layer/merger.rb:55:in `silo_merge_preflight!'", "custom_layer", nil],
      ["#{guest_dir}/layer/merge_validate.rb:55:in `spoofed_helper'", "custom_layer", nil],
      ["/private/customer/secret/merge_validate.rb:55:in `spoofed_dir'", "unknown", nil],
      ["/home/customer/private_app/secret.rb:99:in `run'", "unknown", nil]
    ]

    cases.each do |frame, expected_component, expected_line|
      error = RuntimeError.new("PRIVATE_CANARY_TEXT")
      error.set_backtrace([frame])
      diag = SiloMergeValidationDiagnostic.capture(stage: "rails_boot", error: error)
      assert_equal "RuntimeError", diag["error_class"], "wrong class for #{frame}"
      assert_equal expected_component, diag["component"], "wrong component for #{frame}"
      if expected_line.nil?
        assert_nil diag["line"], "expected nil line for #{frame}"
      else
        assert_equal expected_line, diag["line"], "wrong line for #{frame}"
      end
      refute_includes JSON.generate(diag), "PRIVATE_CANARY_TEXT"
      refute_includes JSON.generate(diag), "customer"
      SiloMergeValidationDiagnostic.validate!(diag)
    end
  end

  def test_internal_raise_helper_and_ruby_internal_frames_unwrap_to_caller_line
    guest_dir = "/shared/silo-validation-#{'c' * 32}"
    error = RuntimeError.new("SECRET")
    error.set_backtrace([
      "<internal:kernel>:187:in `Integer'",
      "#{guest_dir}/merge_validate.rb:43:in `refuse!'",
      "#{guest_dir}/merge_validate.rb:134:in `run!'"
    ])
    diag = SiloMergeValidationDiagnostic.capture(stage: "policy_preflight", error: error)
    assert_equal "validation_runner", diag["component"]
    assert_equal 134, diag["line"]
    SiloMergeValidationDiagnostic.validate!(diag)
  end

  def test_known_ar_wrapper_walks_bounded_causes_for_known_pg_class_and_handles_cycles
    ar_class = Class.new(StandardError) { def self.name = "ActiveRecord::StatementInvalid" }
    pg_class = Class.new(StandardError) { def self.name = "PG::InsufficientPrivilege" }
    mid_class = Class.new(StandardError) { def self.name = "CustomIntermediateWrapper" }

    pg_error = pg_class.new("ERROR: permission denied for table secret_users")
    ar_error = nil
    begin
      begin
        raise pg_error
      rescue StandardError
        raise ar_class, "PG::InsufficientPrivilege: ERROR: permission denied for table secret_users"
      end
    rescue StandardError => caught
      ar_error = caught
    end

    diag = SiloMergeValidationDiagnostic.capture(stage: "policy_preflight", error: ar_error)
    assert_equal "PG::InsufficientPrivilege", diag["error_class"]
    refute_includes JSON.generate(diag), "secret_users"
    SiloMergeValidationDiagnostic.validate!(diag)

    # Cause deeper than 4 hops is not walked; retains known top AR class.
    current = pg_error
    5.times do
      previous = current
      begin
        begin
          raise previous
        rescue StandardError
          raise mid_class, "PRIVATE"
        end
      rescue StandardError => wrapped
        current = wrapped
      end
    end
    deep_ar = nil
    begin
      begin
        raise current
      rescue StandardError
        raise ar_class, "PRIVATE DEEP"
      end
    rescue StandardError => caught
      deep_ar = caught
    end
    deep_diag = SiloMergeValidationDiagnostic.capture(stage: "policy_preflight", error: deep_ar)
    assert_equal "ActiveRecord::StatementInvalid", deep_diag["error_class"]
    SiloMergeValidationDiagnostic.validate!(deep_diag)

    # Cyclic cause chain must terminate safely.
    cycle_a = ar_class.new("PRIVATE A")
    cycle_b = mid_class.new("PRIVATE B")
    cycle_a.define_singleton_method(:cause) { cycle_b }
    cycle_b.define_singleton_method(:cause) { cycle_a }
    cycle_diag = SiloMergeValidationDiagnostic.capture(stage: "policy_preflight", error: cycle_a)
    assert_equal "ActiveRecord::StatementInvalid", cycle_diag["error_class"]
    SiloMergeValidationDiagnostic.validate!(cycle_diag)

    # AR wrapper around SiloMergeValidationConfig::Refused (cause: nil) still
    # recovers the pre-masked static PG class without retaining raw PG cause.
    ENV["SILO_MERGE_VALIDATION_CONFIG_TEST"] = "1"
    require_relative "../runtime/prebuilt-discourse/merge_validation_config"
    ENV.delete("SILO_MERGE_VALIDATION_CONFIG_TEST")
    refused_pg = SiloMergeValidationConfig::Refused.new({
      "version" => 1,
      "stage" => "connections",
      "error_class" => "PG::InvalidAuthorizationSpecification",
      "component" => "validation_config",
      "line" => 126
    })
    ar_wrapped = nil
    begin
      begin
        raise refused_pg
      rescue StandardError
        raise ar_class, "STANDARD_MERGE_VALIDATION_CONFIG"
      end
    rescue StandardError => caught
      ar_wrapped = caught
    end
    ar_diag = SiloMergeValidationDiagnostic.capture(stage: "rails_boot", error: ar_wrapped)
    assert_equal "rails_boot", ar_diag["stage"]
    assert_equal "PG::InvalidAuthorizationSpecification", ar_diag["error_class"]
    SiloMergeValidationDiagnostic.validate!(ar_diag)
  end

  def test_validate_enforces_strict_bounds_types_and_enums
    valid = {
      "version" => 1,
      "stage" => "policy_preflight",
      "error_class" => "SiloMergeValidation::Refused",
      "component" => "validation_runner",
      "line" => 122
    }
    assert_equal valid, SiloMergeValidationDiagnostic.validate!(valid)

    invalid_cases = [
      valid.merge("extra" => "x"),
      valid.reject { |k, _| k == "line" },
      valid.merge("version" => 2),
      valid.merge("version" => 1.0),
      valid.merge("stage" => "unknown_stage"),
      valid.merge("error_class" => "SecretCustomerPolicyError"),
      valid.merge("error_class" => nil),
      valid.merge("component" => "private_file.rb"),
      valid.merge("component" => "custom_layer", "line" => 10),
      valid.merge("component" => "unknown", "line" => 1),
      valid.merge("line" => 0),
      valid.merge("line" => -1),
      valid.merge("line" => 12.0),
      valid.merge("line" => SiloMergeValidationDiagnostic::MAX_LINE + 1),
      valid.merge("line" => "122"),
      nil,
      []
    ]

    invalid_cases.each do |bad|
      error = assert_raises(SiloMergeValidationDiagnostic::Error) do
        SiloMergeValidationDiagnostic.validate!(bad)
      end
      assert_equal "MERGE_VALIDATION_DIAGNOSTIC_INVALID", error.message
      assert_nil error.cause
    end
  end
end
