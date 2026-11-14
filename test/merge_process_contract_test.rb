# frozen_string_literal: true

require "minitest/autorun"
require_relative "../runtime/shared/merge_contract"

class MergeProcessContractTest < Minitest::Test
  C = SiloMergeContract

  def document
    {
      "version" => 1,
      "engine" => "toy-records-v1",
      "settings_schema" => {
        "type" => "object", "additionalProperties" => false,
        "required" => ["asset_mode"],
        "properties" => {
          "asset_mode" => { "type" => "string", "enum" => %w[selected everything] },
          "records" => {
            "type" => "array", "maxItems" => 4, "uniqueItems" => true,
            "items" => {
              "type" => "object", "additionalProperties" => false,
              "properties" => { "ordinal" => { "type" => "integer", "minimum" => 0, "maximum" => 10 } },
              "required" => ["ordinal"]
            }
          },
          "labels" => { "type" => "object", "additionalProperties" => { "type" => "string", "maxLength" => 8 } }
        }
      },
      "asset_policy_key" => "asset_mode",
      "asset_policies" => { "selected" => "carried", "everything" => "all" },
      "audit_aggregates" => { "preflight" => ["records_selected"], "postflight" => [] }
    }
  end

  def contract(doc = document)
    C.load(JSON.generate(doc))
  end

  def assert_refused(reason = nil)
    error = assert_raises(C::Error) { yield }
    assert_equal "MERGE_CONTRACT_REFUSED", error.message
    assert_equal reason, error.reason if reason
    error
  end

  def test_unrelated_engine_and_explicit_policy_resolution
    assert_equal "toy-records-v1", contract["engine"]
    assert_equal({ "physical_policy" => "carried" }, C.validate_settings!(contract, { "asset_mode" => "selected", "records" => [{ "ordinal" => 2 }] }))
    assert_equal({ "physical_policy" => "all" }, C.validate_settings!(contract, { "asset_mode" => "everything", "labels" => { "unrelated" => "value" } }))
    assert_refused("enum") { C.validate_settings!(contract, { "asset_mode" => "carried" }) }
    assert_refused("required") { C.validate_settings!(contract, {}) }
  end

  def test_unknown_fields_and_keywords_are_not_capabilities
    %w[capabilities clean_exposure].each do |field|
      doc = document.merge(field => true)
      assert_refused("contract_fields") { contract(doc) }
    end
    %w[$ref pattern default format unevaluatedProperties].each do |keyword|
      doc = document
      doc["settings_schema"]["properties"]["records"]["items"][keyword] = "private-sentinel"
      error = assert_refused("schema_keywords") { contract(doc) }
      refute_includes error.message, "private-sentinel"
    end
  end

  def test_unknown_nested_key_is_private_not_in_exception_message
    error = assert_refused("unknown_key") do
      C.validate_settings!(contract, { "asset_mode" => "selected", "records" => [{ "ordinal" => 1, "private-sentinel" => "secret-value" }] })
    end
    assert_equal ["records", 0, "private-sentinel"], error.key_path
    refute_includes error.message, "private-sentinel"
    refute_includes error.message, "secret-value"
  end

  def test_duplicates_at_json_boundary_and_in_declarations
    assert_refused("duplicate_key") { C.load('{"version":1,"version":1}') }
    assert_refused("duplicate_key") { C.load(JSON.generate(document).sub('"type":"string"', '"type":"string","type":"string"')) }
    assert_refused("duplicate_key") { C.audit!(contract, "preflight", '{"records_selected":1,"records_selected":2}') }
    doc = document
    doc["audit_aggregates"]["preflight"] *= 2
    assert_refused("audit_declaration") { contract(doc) }
    doc = document
    doc["settings_schema"]["properties"]["asset_mode"]["enum"] *= 2
    assert_refused("enum") { contract(doc) }
  end

  def test_audit_completeness_bounds_and_no_zero_substitution
    assert_equal({ "records_selected" => 0 }, C.audit!(contract, "preflight", { "records_selected" => 0 }))
    assert_equal({}, C.audit!(contract, "postflight", {}))
    assert_refused("audit_fields") { C.audit!(contract, "preflight", {}) }
    assert_refused("audit_fields") { C.audit!(contract, "postflight", { "private_key" => 0 }) }
    assert_refused("phase") { C.audit!(contract, "made_up", {}) }
    [true, false, 1.0, -1, C::MAX_COUNT + 1, "0", nil, Float::INFINITY].each do |count|
      assert_refused { C.audit!(contract, "preflight", { "records_selected" => count }) }
    end
    assert_equal({ "records_selected" => C::MAX_COUNT }, C.audit!(contract, "preflight", { "records_selected" => C::MAX_COUNT }))
  end

  def test_malicious_numeric_booleans_and_other_settings_types
    [true, false, "1", 1.0, nil].each do |ordinal|
      assert_refused("type") { C.validate_settings!(contract, { "asset_mode" => "selected", "records" => [{ "ordinal" => ordinal }] }) }
    end
    [-1, 11].each do |ordinal|
      assert_refused { C.validate_settings!(contract, { "asset_mode" => "selected", "records" => [{ "ordinal" => ordinal }] }) }
    end
    assert_refused("unique_items") { C.validate_settings!(contract, { "asset_mode" => "selected", "records" => [{ "ordinal" => 1 }, { "ordinal" => 1 }] }) }
    assert_refused("maxLength") { C.validate_settings!(contract, { "asset_mode" => "selected", "labels" => { "key" => "x" * 9 } }) }
  end

  def test_enum_mapping_is_exact_and_nonempty
    [ {}, { "selected" => "carried" }, { "selected" => "carried", "everything" => "skip" },
      { "selected" => "carried", "everything" => "all", "hidden" => "all" } ].each do |policies|
      assert_refused("policy_mapping") { contract(document.merge("asset_policies" => policies)) }
    end
    doc = document
    doc["settings_schema"]["properties"]["asset_mode"]["enum"] = [true, 1]
    assert_refused("policy_mapping") { contract(doc) }
  end

  def test_declared_policy_literals_need_not_be_metric_identifiers
    doc = document
    doc["settings_schema"]["properties"]["asset_mode"]["enum"] = ["copy-selected"]
    doc["asset_policies"] = { "copy-selected" => "carried" }
    assert_equal({ "physical_policy" => "carried" }, C.validate_settings!(contract(doc), { "asset_mode" => "copy-selected" }))
    doc["audit_aggregates"]["preflight"] = Array.new(65) { |i| "metric_#{i}" }
    assert_refused("audit_declaration") { contract(doc) }
    doc["audit_aggregates"]["preflight"] = ["not-a-metric"]
    assert_refused("audit_declaration") { contract(doc) }
  end

  def test_canonical_binding_is_independent_of_object_order_not_array_order
    original = contract
    reordered = document.to_a.reverse.to_h
    reordered["asset_policies"] = reordered["asset_policies"].to_a.reverse.to_h
    assert_equal original, contract(reordered)
    assert_equal C.binding(original), C.binding(contract(reordered))
    assert_match(/\A[0-9a-f]{64}\z/, C.binding(original))
    modified = document
    modified["asset_policies"]["selected"] = "all"
    refute_equal C.binding(original), C.binding(contract(modified))
  end

  def test_input_limits_invalid_json_and_aliases
    assert_refused("input_size") { C.load(" " * (C::MAX_BYTES + 1)) }
    assert_refused("invalid_json") { C.load('{"version":NaN}') }
    assert_refused("invalid_json") { C.load("[" * 65 + "0" + "]" * 65) }
    value = nil
    17.times { value = [value] }
    assert_refused("tree_limit") { C.validate_settings!(contract, value) }
    assert_refused("tree_limit") { C.validate_settings!(contract, Array.new(C::MAX_SETTINGS_NODES + 1, nil)) }
    cyclic = []; cyclic << cyclic
    assert_refused("alias") { C.validate_settings!(contract, cyclic) }
    shared = {}
    assert_refused("alias") { C.validate_settings!(contract, [shared, shared]) }
    # YAML alias refusal is the host parser's job, not a YAML reader here.
    assert_refused("invalid_json") { C.load("---\nvalue: &x {}\nother: *x\n") }
  end

  def test_thousands_of_routing_entries_fit_settings_byte_contract
    doc = document
    doc["settings_schema"]["properties"]["routes"] = {
      "type" => "object", "additionalProperties" => { "type" => "integer" }
    }
    loaded = contract(doc)
    settings = { "asset_mode" => "selected", "routes" => 5000.times.to_h { |id| [id.to_s, id] } }
    assert_operator JSON.generate(settings).bytesize, :<=, 256 * 1024
    assert_equal({ "physical_policy" => "carried" }, C.validate_settings!(loaded, settings))
    assert_equal JSON.generate(settings["routes"].sort.to_h), C.canonical_json(settings["routes"])
    assert_refused("tree_limit") { C.tree!(settings) }
    assert_same settings, C.tree!(settings, max_nodes: C::MAX_SETTINGS_NODES)

    doc["settings_schema"]["properties"]["too_complex"] = { "enum" => Array.new(C::MAX_NODES, nil) }
    assert_operator JSON.generate(doc).bytesize, :<, C::MAX_BYTES
    assert_refused("tree_limit") { contract(doc) }
  end

  def test_schema_closure_depth_and_description
    doc = document
    doc["settings_schema"]["additionalProperties"] = true
    assert_refused("object_closure") { contract(doc) }
    doc = document
    doc["settings_schema"]["properties"]["records"]["items"].delete("additionalProperties")
    assert_refused("object_closure") { contract(doc) }
    doc = document
    doc["settings_schema"]["description"] = "line\nbreak"
    assert_refused("description") { contract(doc) }
    doc = document
    child = { "type" => "string" }
    17.times { child = { "type" => "array", "items" => child } }
    doc["settings_schema"]["properties"]["deep"] = child
    assert_refused("tree_limit") { contract(doc) }
  end

  def test_validation_work_and_public_digest_helpers_are_bounded
    doc = document
    doc["settings_schema"]["properties"]["payload"] = {
      "type" => "array", "items" => { "allOf" => Array.new(101) { {} } }
    }
    assert_refused("validation_limit") do
      C.validate_settings!(contract(doc), { "asset_mode" => "selected", "payload" => Array.new(10_000, nil) })
    end
    cycle = []; cycle << cycle
    assert_refused("alias") { C.binding(cycle) }
  end

  def test_large_enum_serializes_actual_once_and_charges_every_canonical_visit
    doc = document
    doc["settings_schema"]["properties"]["payload"] = { "enum" => (0...1000).to_a }
    loaded = contract(doc)
    payload = 20_000.times.to_h { |id| [id.to_s, 0] }
    settings = { "asset_mode" => "selected", "payload" => payload }
    assert_operator JSON.generate(settings).bytesize, :<=, 256 * 1024
    # Each of 20001 actual nodes costs three visits (check/sort/serialize),
    # plus three visits per scalar enum choice and one schema application.
    budget = { remaining: 70_000 }
    assert_refused("enum") do
      C.validate!(loaded["settings_schema"]["properties"]["payload"], payload, [], budget)
    end
    assert_equal 70_000 - (3 * 20_001 + 3 * 1000 + 1), budget[:remaining]
    assert_refused("enum") { C.validate_settings!(loaded, settings) }

    budget = { remaining: 10 }
    assert C.validate!({ "enum" => [1], "const" => 1 }, 1, [], budget)
    assert_equal 0, budget[:remaining] # Actual shared across enum and const.
  end

  def test_nested_unique_items_reserve_serialization_work_before_exhaustion
    schema = { "type" => "array", "uniqueItems" => true, "items" => { "type" => "integer" } }
    2.times { schema = { "type" => "array", "uniqueItems" => true, "items" => schema } }
    budget = { remaining: 6000 }
    assert_refused("validation_limit") { C.validate!(schema, [[(0...1000).to_a]], [], budget) }
    # Root: 1 + 3*1002; next application: 1; next tree/sort: 2*1001;
    # reserving 1001 serialization visits refuses before entering JSON.generate.
    assert_equal(-11, budget[:remaining])

    doc = document
    nested = { "type" => "array", "uniqueItems" => true, "items" => { "type" => "integer" } }
    payload = (0...40_000).to_a
    9.times do
      nested = { "type" => "array", "uniqueItems" => true, "items" => nested }
      payload = [payload]
    end
    doc["settings_schema"]["properties"]["payload"] = { "anyOf" => [nested, {}] }
    settings = { "asset_mode" => "selected", "payload" => payload }
    assert_operator JSON.generate(settings).bytesize, :<=, 256 * 1024
    # Budget exhaustion is fatal even though another anyOf branch would pass.
    assert_refused("validation_limit") { C.validate_settings!(contract(doc), settings) }
  end

  def test_supported_combinators_types_and_scalar_constraints
    doc = document
    doc["settings_schema"]["properties"]["choice"] = {
      "type" => ["string", "number", "boolean", "null"],
      "allOf" => [{ "anyOf" => [{ "type" => "string", "minLength" => 2 }, { "type" => "number", "minimum" => 2 }, { "type" => "boolean" }, { "type" => "null" }] }],
      "oneOf" => [{ "const" => "ok" }, { "const" => 2 }, { "const" => true }, { "const" => nil }]
    }
    loaded = contract(doc)
    ["ok", 2, true, nil].each do |choice|
      assert_equal({ "physical_policy" => "carried" }, C.validate_settings!(loaded, { "asset_mode" => "selected", "choice" => choice }))
    end
    ["x", false, 1, 3, []].each do |choice|
      assert_refused { C.validate_settings!(loaded, { "asset_mode" => "selected", "choice" => choice }) }
    end
  end
end
