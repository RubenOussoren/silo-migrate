# frozen_string_literal: true

module SiloMigrate
  module VisibilityPolicy
    SAFE = "safe"
    RESTRICTED = "restricted"
    TRUSTED_ONLY = "trusted_only"
    VISIBILITY_ORDER = {
      SAFE => 0,
      RESTRICTED => 1,
      TRUSTED_ONLY => 2
    }.freeze

    module_function

    def normalize(value)
      case value.to_s.strip.downcase.tr("-", "_")
      when "", SAFE then SAFE
      when RESTRICTED then RESTRICTED
      when "trusted", TRUSTED_ONLY then TRUSTED_ONLY
      else
        raise UsageError, "Invalid dev visibility: #{value}. Expected safe, restricted, or trusted_only."
      end
    end

    def max(*levels)
      levels.flatten.compact.map { |level| normalize(level) }.max_by { |level| VISIBILITY_ORDER.fetch(level) } || SAFE
    end

    def summary_visibility(summary)
      return TRUSTED_ONLY if summary["contains_raw_rows"] == true

      normalize(summary["dev_ai_visibility"] || summary["visibility"])
    end

    def finding_visibility(summary, entry)
      levels = [
        summary_visibility(summary),
        normalize(entry["dev_visibility"] || entry["visibility"])
      ]
      levels << TRUSTED_ONLY if entry["contains_raw_rows"] == true

      details = entry["details"]
      levels << TRUSTED_ONLY if details && !details.to_s.empty? && details != "[REDACTED_DETAILS]"

      shape = entry["details_shape"] || entry["observed_shape"]
      levels << RESTRICTED if shape.is_a?(Hash) && shape.key?("redacted") && shape["redacted"] != true

      max(levels)
    end

    def fixture_allowed?(finding)
      normalize(finding["dev_visibility"]) == SAFE
    end
  end
end
