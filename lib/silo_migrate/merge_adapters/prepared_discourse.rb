# frozen_string_literal: true

require_relative "../../../runtime/prebuilt-discourse/merge_baseline_assets"

module SiloMigrate
  module MergeAdapters
    class PreparedDiscourseAdapter
      ID = "discourse-merger-v1"

      def describe
        { "engine" => ID, "version" => 1, "physical_policies" => %w[carried all],
          "capabilities" => %w[settings_schema read_only_validation asset_manifest preservation audit_aggregates backup_verification] }
      end

      def validate(context)
        contract = context.fetch(:contract)
        raise MergeProcess::Refused, "engine_mismatch" unless contract["engine"] == ID
        result = SiloMergeContract.validate_settings!(contract, context.fetch(:settings))
        { "valid" => true, "binding" => result }
      end

      def verify_output(context, manifest)
        members = context.fetch(:upload_sha256)
        baseline = context.fetch(:baseline_assets)
        SiloDiscourseBaselineAssets.validate!(baseline)
        return false unless baseline.fetch("files").all? { |file| members["uploads/default/#{file.fetch('path')}"] == file.fetch("sha256") }
        selected = manifest.fetch("entries").reject { |entry| entry["disposition"] == "exclude" }
        allowed = selected.to_h { |entry| ["uploads/default/#{entry.fetch('destination')}", entry.fetch("digest")] }
        return false unless allowed.all? do |member, digest|
          digest["algorithm"] == "sha256" && members[member] == digest["value"]
        end
        manifest.fetch("entries").select { |entry| entry["disposition"] == "exclude" }.none? do |entry|
          member = "uploads/default/#{entry.fetch('destination')}"
          !allowed.key?(member) && members.key?(member)
        end
      end
    end

  end
end
