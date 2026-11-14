# frozen_string_literal: true

require_relative "merge_contract"
require "timeout"

# Private, bounded diagnostics for a refused policy phase. A successful audit
# callback is still only partial evidence: the policy check itself failed.
module SiloMergeRefusal
  PREFIX = "SILO_MERGE_REFUSAL:"
  MAX_BYTES = 128 * 1024
  FIELDS = %w[version context phase reason error_class write_boundary audit_status counts missing_keys complete].freeze
  REASONS = %w[preflight_refused postflight_refused hooks_missing asset_selection_invalid audit_invalid checks_invalid assets_unproven validation_unproven unknown_source_id destination_exists destination_missing destination_ambiguous policy_conflict permission_unproven selection_unproven schema_unsupported].freeze
  STATUSES = %w[partial unavailable invalid hook_failed].freeze
  CLASS_NAME = /\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/n
  UNCAPTURED = Object.new.freeze

  class Error < StandardError
    def initialize = super("MERGE_REFUSAL_INVALID")
  end

  module_function

  # These boundaries describe runner control flow, not an attestation that
  # arbitrary project code performed no writes.
  def boundary(context, phase)
    return "read_only_clones" if context == "validation" && phase == "preflight"
    return "before_constructor" if context == "execution" && phase == "preflight"
    return "after_constructor" if context == "execution" && phase == "postflight"
    raise Error, cause: nil
  end

  # Validate declarations independently of callback data, including the phase
  # not being captured. Never call project code for an ineligible declaration.
  def declarations!(contract)
    audits = contract.is_a?(Hash) && contract["audit_aggregates"]
    raise Error unless audits.is_a?(Hash) && audits.size == 2 && audits.keys.sort == %w[postflight preflight]
    audits.each_value do |keys|
      raise Error unless keys.is_a?(Array) && keys.size <= 64 && keys.uniq.size == keys.size &&
        keys.all? { |key| key.is_a?(String) && key.bytesize <= 64 && key.ascii_only? && SiloMergeContract::KEY.match?(key) }
    end
    audits
  rescue Exception
    raise Error, cause: nil
  end

  def class_name(error)
    return nil unless error
    name = error.class.name
    name if name.is_a?(String) && name.bytesize <= 256 && name.ascii_only? && CLASS_NAME.match?(name)
  rescue Exception
    nil
  end

  def counts!(keys, value)
    raise Error unless value.is_a?(Hash) && value.size <= keys.size && (value.keys - keys).empty? &&
      value.values.all? { |count| count.is_a?(Integer) && count.between?(0, SiloMergeContract::MAX_COUNT) }
    # Copy just the declared numeric values; never retain layer-owned objects.
    keys.sort.each_with_object({}) { |key, result| result[key] = value[key] if value.key?(key) }
  end

  def capture(contract:, merger:, phase:, context:, reason:, error: nil, audit_value: UNCAPTURED)
    write_boundary = boundary(context, phase)
    envelope = { "version" => 1, "context" => context, "phase" => phase,
      "reason" => REASONS.include?(reason) ? reason : "validation_unproven",
      "error_class" => class_name(error), "write_boundary" => write_boundary,
      "audit_status" => "invalid", "counts" => {}, "missing_keys" => [], "complete" => false }
    begin
      keys = declarations!(contract).fetch(phase).sort
      envelope["missing_keys"] = keys
    rescue Exception
      return envelope
    end
    begin
      if audit_value.equal?(UNCAPTURED)
        unless merger.respond_to?(:silo_merge_audit)
          envelope["audit_status"] = "unavailable"
          return envelope
        end
        value = Timeout.timeout(2) { merger.silo_merge_audit(phase) }
      else
        # A validator may already have captured this phase before a later asset
        # refusal. Revalidate its snapshot without invoking project code twice.
        value = audit_value
      end
    rescue Exception # SystemExit is diagnostic failure, never a replacement exit
      envelope["audit_status"] = "hook_failed"
      return envelope
    end
    begin
      counts = counts!(keys, value)
      envelope["counts"] = counts
      envelope["missing_keys"] = keys - counts.keys
      envelope["audit_status"] = "partial"
    rescue Exception
      # Malformed callback values are discarded in full, not salvaged/coerced.
    end
    envelope
  rescue Exception
    # Caller bugs must not replace a primary refusal or expose arbitrary input.
    { "version" => 1, "context" => "execution", "phase" => "preflight",
      "reason" => "validation_unproven", "error_class" => nil,
      "write_boundary" => "before_constructor", "audit_status" => "unavailable",
      "counts" => {}, "missing_keys" => [], "complete" => false }
  end

  def validate!(contract, value, context:)
    SiloMergeContract.tree!(value)
    raise Error unless value.is_a?(Hash) && value.keys.sort == FIELDS.sort &&
      value["version"].is_a?(Integer) && value["version"] == 1 && value["complete"] == false &&
      value["context"] == context && value["write_boundary"] == boundary(context, value["phase"]) &&
      REASONS.include?(value["reason"]) && STATUSES.include?(value["audit_status"])
    name = value["error_class"]
    raise Error unless name.nil? || (name.is_a?(String) && name.bytesize <= 256 && name.ascii_only? && CLASS_NAME.match?(name))
    keys = declarations!(contract).fetch(value["phase"]).sort
    counts = counts!(keys, value["counts"])
    raise Error unless value["audit_status"] == "partial" || counts.empty?
    raise Error unless value["missing_keys"] == keys - counts.keys
    raise Error if JSON.generate(value).bytesize > MAX_BYTES
    value
  rescue Exception
    raise Error, cause: nil
  end
end
