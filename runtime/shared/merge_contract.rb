# frozen_string_literal: true

require "json"
require "digest"

# Structural validation only: engine registration, YAML loading, settings byte
# limits (256 KiB), receipt facts and evidence release remain host responsibilities.
# This is deliberately NOT full JSON Schema. Only KEYWORDS below are supported;
# constraints apply to their JSON type, combinators are intersected with siblings.
# Types do not coerce: integer excludes Float and boolean excludes numbers. Enum,
# const and uniqueness compare canonical JSON. Required names must be declared
# properties; tuple items and boolean schemas are unsupported. Description is at
# most 1024 bytes with no controls. Size/length bounds are integers 0..262144;
# numeric bounds must be finite. Contract/settings trees have depth <=16 (root is
# depth zero), no shared container references, <=4096 contract values or
# <=262144 settings values. Validation has a 1000000-work-unit budget, charging
# schema applications and each node visited by canonical validation, sorting and
# serialization (one unit per value per traversal).
# Contract depth includes its envelope; settings byte limits remain host-owned.
# Object schemas must explicitly close additional properties, or describe dynamic
# values with a schema. No references, patterns, coercion, defaults or IO exist.
module SiloMergeContract
  MAX_BYTES = 128 * 1024
  MAX_DEPTH = 16
  MAX_NODES = 4096
  MAX_SETTINGS_NODES = 262_144
  MAX_VALIDATION_APPLICATIONS = 1_000_000
  MAX_COUNT = 999_999_999_999
  TYPES = %w[object array string integer number boolean null].freeze
  KEYWORDS = %w[type properties required additionalProperties items minItems maxItems uniqueItems minLength maxLength minimum maximum enum const anyOf oneOf allOf description].freeze
  FIELDS = %w[version engine settings_schema asset_policy_key asset_policies audit_aggregates].freeze
  KEY = /\A[a-z][a-z0-9_]{0,63}\z/
  ENGINE = /\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/

  # These attributes are PRIVATE evidence: callers must not project them into
  # clean output. The exception message contains only the fixed refusal tag.
  class Error < StandardError
    attr_reader :key_path, :reason

    def initialize(key_path, reason)
      @key_path = key_path
      @reason = reason
      super("MERGE_CONTRACT_REFUSED")
    end
  end

  class UniqueObject < Hash
    def []=(key, value)
      raise Error.new([], "duplicate_key") if key?(key)
      super
    end
  end

  module_function

  def refuse(path, reason)
    raise Error.new(path, reason), cause: nil
  end

  def parse(bytes, max_bytes: MAX_BYTES)
    refuse([], "input_size") unless bytes.is_a?(String) && bytes.bytesize <= max_bytes
    JSON.parse(bytes, object_class: UniqueObject, max_nesting: 64, allow_nan: false, create_additions: false)
  rescue JSON::ParserError, JSON::NestingError, EncodingError, ArgumentError
    refuse([], "invalid_json")
  end

  # Bounds all Ruby inputs as JSON trees, rejecting aliases/cycles and foreign
  # objects before recursive validation or serialization. Shared references are
  # refused too; the host's YAML parser must independently disable aliases.
  def tree!(value, path = [], depth = 0, state = { nodes: 0, seen: {} }, max_depth: MAX_DEPTH, max_nodes: MAX_NODES, budget: nil)
    charge!(budget, path) if budget
    state[:nodes] += 1
    refuse(path, "tree_limit") if depth > max_depth || state[:nodes] > max_nodes
    case value
    when Hash, Array
      refuse(path, "alias") if state[:seen][value.object_id]
      state[:seen][value.object_id] = true
      if value.is_a?(Hash)
        value.each do |key, child|
          refuse(path, "object_key") unless key.is_a?(String) && key.valid_encoding? && key.bytesize <= 1024
          tree!(child, path + [key], depth + 1, state, max_depth: max_depth, max_nodes: max_nodes, budget: budget)
        end
      else
        value.each_with_index { |child, index| tree!(child, path + [index], depth + 1, state, max_depth: max_depth, max_nodes: max_nodes, budget: budget) }
      end
    when String
      refuse(path, "string_limit") unless value.valid_encoding? && value.bytesize <= 256 * 1024
    when Float
      refuse(path, "number") unless value.finite?
    when Integer, TrueClass, FalseClass, NilClass
      # JSON scalar
    else
      refuse(path, "json_type")
    end
    value
  end

  def load(bytes)
    contract = parse(bytes)
    tree!(contract)
    refuse([], "contract_fields") unless contract.is_a?(Hash) && contract.keys.sort == FIELDS.sort
    refuse(["version"], "version") unless contract["version"].is_a?(Integer) && contract["version"] == 1
    engine = contract["engine"]
    refuse(["engine"], "identifier") unless engine.is_a?(String) && engine.bytesize <= 64 && ENGINE.match?(engine)
    schema = contract["settings_schema"]
    schema!(schema)
    refuse(["settings_schema"], "root_closed_object") unless schema["type"] == "object" && schema["additionalProperties"] == false
    key = contract["asset_policy_key"]
    refuse(["asset_policy_key"], "policy_key") unless clean_literal?(key, 64)
    policy_schema = schema.fetch("properties", {})[key]
    literals = policy_schema && policy_schema["enum"]
    policies = contract["asset_policies"]
    unless literals.is_a?(Array) && !literals.empty? && literals.all? { |v| clean_literal?(v, 128) } &&
        schema.fetch("required", []).include?(key) && policies.is_a?(Hash) && policies.keys.sort == literals.sort &&
        policies.values.all? { |v| %w[carried all].include?(v) }
      refuse(["asset_policies"], "policy_mapping")
    end
    audits = contract["audit_aggregates"]
    refuse(["audit_aggregates"], "phases") unless audits.is_a?(Hash) && audits.keys.sort == %w[postflight preflight]
    audits.each do |phase, keys|
      unless keys.is_a?(Array) && keys.size <= 64 && keys.uniq.size == keys.size && keys.all? { |v| v.is_a?(String) && KEY.match?(v) }
        refuse(["audit_aggregates", phase], "audit_declaration")
      end
    end
    canonical_value(contract)
  end

  def schema!(schema, path = ["settings_schema"], depth = 0)
    refuse(path, "schema_depth") if depth > MAX_DEPTH
    refuse(path, "schema_keywords") unless schema.is_a?(Hash) && (schema.keys - KEYWORDS).empty?
    if schema.key?("type")
      types = schema["type"].is_a?(Array) ? schema["type"] : [schema["type"]]
      refuse(path, "schema_type") unless !types.empty? && types.uniq == types && (types - TYPES).empty?
    end
    if schema.key?("description")
      description = schema["description"]
      refuse(path, "description") unless description.is_a?(String) && description.bytesize <= 1024 && !description.match?(/[[:cntrl:]]/)
    end
    if schema.key?("properties")
      refuse(path, "properties") unless schema["properties"].is_a?(Hash)
      schema["properties"].each { |key, child| schema!(child, path + ["properties", key], depth + 1) }
    end
    if schema.key?("required")
      required = schema["required"]
      refuse(path, "required") unless required.is_a?(Array) && required.all? { |k| k.is_a?(String) } && required.uniq == required && (required - schema.fetch("properties", {}).keys).empty?
    end
    object = Array(schema["type"]).include?("object") || schema.key?("properties")
    additional = schema["additionalProperties"]
    if object || schema.key?("additionalProperties")
      allowed = additional == false || additional.is_a?(Hash) || (!object && additional == true)
      refuse(path, "object_closure") unless allowed
      schema!(additional, path + ["additionalProperties"], depth + 1) if additional.is_a?(Hash)
    end
    schema!(schema["items"], path + ["items"], depth + 1) if schema.key?("items")
    %w[minItems maxItems minLength maxLength].each do |key|
      next unless schema.key?(key)
      refuse(path + [key], "bound") unless schema[key].is_a?(Integer) && schema[key].between?(0, 256 * 1024)
    end
    %w[minimum maximum].each do |key|
      next unless schema.key?(key)
      refuse(path + [key], "bound") unless numeric?(schema[key])
    end
    [%w[minItems maxItems], %w[minLength maxLength], %w[minimum maximum]].each do |lo, hi|
      refuse(path, "bound_order") if schema.key?(lo) && schema.key?(hi) && schema[lo] > schema[hi]
    end
    if schema.key?("uniqueItems")
      refuse(path, "unique_items") unless [true, false].include?(schema["uniqueItems"])
    end
    if schema.key?("enum")
      values = schema["enum"]
      refuse(path, "enum") unless values.is_a?(Array) && !values.empty? && values.map { |v| canonical_json(v) }.uniq.size == values.size
    end
    %w[anyOf oneOf allOf].each do |key|
      next unless schema.key?(key)
      children = schema[key]
      refuse(path + [key], "combinator") unless children.is_a?(Array) && !children.empty?
      children.each_with_index { |child, i| schema!(child, path + [key, i], depth + 1) }
    end
  end

  def clean_literal?(value, max_bytes)
    value.is_a?(String) && !value.empty? && value.bytesize <= max_bytes && !value.match?(/[[:cntrl:]]/)
  end

  def numeric?(value)
    value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
  end

  def type?(value, type)
    case type
    when "object" then value.is_a?(Hash)
    when "array" then value.is_a?(Array)
    when "string" then value.is_a?(String)
    when "integer" then value.is_a?(Integer)
    when "number" then numeric?(value)
    when "boolean" then value == true || value == false
    when "null" then value.nil?
    end
  end

  def matches?(schema, value, path, budget)
    validate!(schema, value, path, budget)
    true
  rescue Error => error
    raise if error.reason == "validation_limit"
    false
  end

  def charge!(budget, path, units = 1)
    budget[:remaining] -= units
    refuse(path, "validation_limit") if budget[:remaining].negative?
  end

  def validate!(schema, value, path = [], budget = { remaining: MAX_VALIDATION_APPLICATIONS })
    charge!(budget, path)
    if schema.key?("type")
      refuse(path, "type") unless Array(schema["type"]).any? { |type| type?(value, type) }
    end
    actual = canonical_json(value, budget: budget) if schema.key?("enum") || schema.key?("const")
    %w[enum const].each do |key|
      next unless schema.key?(key)
      choices = key == "enum" ? schema[key] : [schema[key]]
      refuse(path, key) unless choices.any? { |choice| canonical_json(choice, budget: budget) == actual }
    end
    %w[anyOf oneOf allOf].each do |key|
      next unless schema.key?(key)
      count = schema[key].count { |child| matches?(child, value, path, budget) }
      ok = key == "anyOf" ? count.positive? : (key == "oneOf" ? count == 1 : count == schema[key].size)
      refuse(path, key) unless ok
    end
    case value
    when Hash
      schema.fetch("required", []).each { |key| refuse(path + [key], "required") unless value.key?(key) }
      value.each do |key, child|
        child_schema = schema.fetch("properties", {})[key]
        unless child_schema
          additional = schema.fetch("additionalProperties", true)
          refuse(path + [key], "unknown_key") if additional == false
          child_schema = additional if additional.is_a?(Hash)
        end
        validate!(child_schema, child, path + [key], budget) if child_schema
      end
    when Array
      bounds!(schema, value.size, "minItems", "maxItems", path)
      if schema["uniqueItems"] && value.map { |v| canonical_json(v, budget: budget) }.uniq.size != value.size
        refuse(path, "unique_items")
      end
      value.each_with_index { |child, i| validate!(schema["items"], child, path + [i], budget) } if schema.key?("items")
    when String
      bounds!(schema, value.length, "minLength", "maxLength", path)
    when Integer, Float
      bounds!(schema, value, "minimum", "maximum", path)
    end
    true
  end

  def bounds!(schema, value, low, high, path)
    refuse(path, low) if schema.key?(low) && value < schema[low]
    refuse(path, high) if schema.key?(high) && value > schema[high]
  end

  def validate_settings!(contract, value)
    tree!(value, max_nodes: MAX_SETTINGS_NODES)
    validate!(contract.fetch("settings_schema"), value)
    policy = contract.fetch("asset_policies")[value[contract.fetch("asset_policy_key")]]
    refuse([contract.fetch("asset_policy_key")], "policy_mapping") unless policy
    { "physical_policy" => policy }
  end

  # A complete phase requires every declared key; missing never means zero.
  # JSON bytes are also accepted to preserve duplicate-key detection at ingestion.
  def audit!(contract, phase, value)
    keys = contract.fetch("audit_aggregates")[phase]
    refuse([], "phase") unless keys
    value = parse(value) if value.is_a?(String)
    tree!(value)
    refuse([], "audit_fields") unless value.is_a?(Hash) && value.keys.sort == keys.sort
    value.each do |key, count|
      refuse([key], "audit_count") unless count.is_a?(Integer) && count.between?(0, MAX_COUNT)
    end
    canonical_value(value)
  end

  def canonical_value(value, budget: nil)
    charge!(budget, []) if budget
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical_value(value[key], budget: budget)] }
    when Array then value.map { |child| canonical_value(child, budget: budget) }
    else value
    end
  end

  # Canonical sorted JSON, not a signature or a claim about engine facts.
  def canonical_json(value, max_nodes: MAX_SETTINGS_NODES, budget: nil)
    state = { nodes: 0, seen: {} }
    tree!(value, [], 0, state, max_nodes: max_nodes, budget: budget)
    sorted = canonical_value(value, budget: budget)
    # JSON.generate traverses the sorted tree internally: reserve its complete
    # node cost before entering the native serializer, rather than after work.
    charge!(budget, [], state[:nodes]) if budget
    JSON.generate(sorted, allow_nan: false, max_nesting: 64)
  end

  def binding(contract)
    Digest::SHA256.hexdigest(canonical_json(contract, max_nodes: MAX_NODES))
  end
end
