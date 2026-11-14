# frozen_string_literal: true

require "json"
require "digest"
require_relative "../../../runtime/shared/merge_assets"
require_relative "../../../runtime/shared/merge_refusal"
require_relative "../../../runtime/prebuilt-discourse/merge_baseline_assets"

module SiloMigrate
  module Services
    # Host integration for the shared process envelope. All data-bearing records
    # stay private; the ordinary run projection contains no new policy metrics.
    module StandardMergeProcess
      PROCESS_PREFIX = "SILO_MERGE_PROCESS:"
      PROCESS_PHASES = %w[preflight transfer postflight].freeze
      PROCESS_KEYS = %w[version engine phase complete physical_policy audit_aggregates transfer manifest_sha256 baseline_sha256 references_sha256 bookkeeping_references upload_rows_inserted upload_rows_inserted_without_references].freeze
      PROCESS_COUNT_KEYS = %w[files_copied files_reused files_skipped_by_policy].freeze
      PROCESS_MANIFEST_LIMIT = 64 * 1024 * 1024

      def merge_process_install!(run_id, stack, env)
        process = plan_for(run_id).dig("body", "merge", "process")
        return unless process
        path = @store.run_dir(run_id, "private", "merge", "layer", "workflow-contract.json")
        raise StandardWorkflowError, "STANDARD_MERGE_CONTRACT_INVALID" unless File.file?(path) && !File.symlink?(path)
        contract = SiloMergeContract.load(File.binread(path))
        expected = plan_for(run_id).dig("body", "merge", "contract")
        raise StandardWorkflowError, "STANDARD_MERGE_CONTRACT_INVALID" unless contract == expected
        env << "SILO_MERGE_CONTRACT=/shared/merge/layer/workflow-contract.json"
        env << "SILO_MERGE_UPLOAD_COPY_POLICY=#{process.fetch('physical_policy')}"
        env << "SILO_MERGE_SELECTION_SHA256=#{process.fetch('selection_sha256')}"
        env << "SILO_MERGE_ASSET_PREFLIGHT_SHA256=#{process.fetch('asset_preflight_sha256')}"
        env << "SILO_MERGE_OWNER_PREFLIGHT_SHA256=#{process.fetch('owner_preflight_sha256')}"
        merge_checked(run_id, "merge-process-directory", stack.web_exec(%w[mkdir -p /shared/merge-process]))
        merge_checked(run_id, "merge-process-owner", stack.web_exec(%w[chown discourse:discourse /shared/merge-process]))
        merge_checked(run_id, "merge-process-mode", stack.web_exec(%w[chmod 0700 /shared/merge-process]))
      end

      def merge_process_collect!(run_id, stack, result)
        process = plan_for(run_id).dig("body", "merge", "process")
        return unless process
        contract = plan_for(run_id).dig("body", "merge", "contract")
        refusal = merge_refusal_collect!(run_id, result, contract)
        records = []
        result.stdout.to_s.each_line do |line|
          next unless line.start_with?(PROCESS_PREFIX)
          value = SiloMergeContract.parse(line.delete_prefix(PROCESS_PREFIX), max_bytes: 128 * 1024)
          unless value.is_a?(Hash) && (value.keys - PROCESS_KEYS).empty? && value["version"] == 1 &&
                 value["engine"] == "discourse-merger-v1" && value["physical_policy"] == process["physical_policy"] &&
                 PROCESS_PHASES.include?(value["phase"]) && [true, false].include?(value["complete"])
            raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID"
          end
          raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID" if records.any? { |r| r["phase"] == value["phase"] }
          expected_phase = PROCESS_PHASES[records.size]
          raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID" unless value["phase"] == expected_phase
          audit = value.fetch("audit_aggregates")
          raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID" unless audit.is_a?(Hash) && (audit.keys - %w[preflight postflight]).empty?
          audit.each { |phase, counts| SiloMergeContract.audit!(contract, phase, counts) }
          raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID" unless audit.key?("preflight")
          if value["transfer"]
            counts = value["transfer"]
            unless counts.is_a?(Hash) && counts.keys.sort == PROCESS_COUNT_KEYS.sort && counts.values.all? { |v| v.is_a?(Integer) && v.between?(0, SiloMergeContract::MAX_COUNT) }
              raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID"
            end
          end
          %w[upload_rows_inserted upload_rows_inserted_without_references bookkeeping_references].each do |key|
            count = value[key]
            raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID" if value.key?(key) && !(count.is_a?(Integer) && count.between?(0, SiloMergeContract::MAX_COUNT))
          end
          if value["complete"] && (value["phase"] != "postflight" || !audit.key?("postflight") || !value["manifest_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/))
            raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID"
          end
          records << value
          @store.write_private(@store.run_dir(run_id, "private", "merge-process.json"), JSON.generate({ "version" => 1, "phases" => records }) + "\n")
        end
        return unless result.success?
        raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID" if refusal
        final = records.last
        unless records.size == 3 && final["complete"] == true && final["transfer"] && final.key?("upload_rows_inserted_without_references")
          raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID"
        end
        manifest_path = @store.run_dir(run_id, "private", "merge-asset-manifest.json")
        stack.copy_out("/shared/merge-process/asset-manifest.json", manifest_path)
        unless File.file?(manifest_path) && !File.symlink?(manifest_path) && File.size(manifest_path) <= PROCESS_MANIFEST_LIMIT && Digest::SHA256.file(manifest_path).hexdigest == final["manifest_sha256"]
          raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID"
        end
        File.chmod(0o600, manifest_path)
        references = @store.run_dir(run_id, "private", "merge-asset-references.json")
        unless final["references_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
          raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID"
        end
        stack.copy_out("/shared/merge-process/references.json", references)
        unless File.file?(references) && !File.symlink?(references) && File.size(references) <= 4 * 1024 * 1024 && Digest::SHA256.file(references).hexdigest == final["references_sha256"]
          raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID"
        end
        File.chmod(0o600, references)
        baseline_path = @store.run_dir(run_id, "private", "merge-baseline-assets.json")
        raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID" unless final["baseline_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
        stack.copy_out("/shared/merge-process/baseline-assets.json", baseline_path)
        unless File.file?(baseline_path) && !File.symlink?(baseline_path) && File.size(baseline_path) <= PROCESS_MANIFEST_LIMIT && Digest::SHA256.file(baseline_path).hexdigest == final["baseline_sha256"]
          raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID"
        end
        File.chmod(0o600, baseline_path)
        SiloDiscourseBaselineAssets.validate!(SiloMergeContract.parse(File.binread(baseline_path), max_bytes: PROCESS_MANIFEST_LIMIT))
        manifest = SiloMergeContract.parse(File.binread(manifest_path), max_bytes: PROCESS_MANIFEST_LIMIT)
        SiloMergeAssets.validate!(manifest)
        raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID" unless manifest["policy"] == process["physical_policy"]
      rescue SiloMergeContract::Error, SiloMergeAssets::Error, SiloDiscourseBaselineAssets::Error, KeyError, JSON::ParserError, StandardWorkflowError, SystemCallError, IOError
        # Evidence parsing is secondary to an already-failed subprocess.
        # Earlier individually validated process frames remain private evidence.
        raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID" if result.success?
        nil
      end

      def merge_refusal_collect!(run_id, result, contract)
        frames = []
        result.stdout.to_s.each_line do |line|
          next unless line.start_with?(SiloMergeRefusal::PREFIX)
          frames << line
          break if frames.size > 1
        end
        return nil if frames.empty? && result.success?
        value = if frames.empty?
          merge_refusal_unavailable("evidence_unavailable")
        else
          begin
            raise SiloMergeRefusal::Error unless frames.size == 1
            parsed = SiloMergeContract.parse(frames.first.delete_prefix(SiloMergeRefusal::PREFIX), max_bytes: SiloMergeRefusal::MAX_BYTES)
            SiloMergeRefusal.validate!(contract, parsed, context: "execution")
          rescue SiloMergeContract::Error, SiloMergeRefusal::Error
            merge_refusal_unavailable("evidence_invalid")
          end
        end
        @store.write_private(@store.run_dir(run_id, "private", "merge-refusal.json"), JSON.generate(value) + "\n")
        value
      end

      def merge_refusal_unavailable(reason)
        { "version" => 1, "available" => false, "complete" => false, "reason" => reason }
      end

      def merge_process_evidence(run_id)
        path = @store.run_dir(run_id, "private", "merge-process.json")
        evidence = { "version" => 1, "available" => false }
        if File.file?(path)
          value = JSON.parse(File.read(path))
          final = value.fetch("phases").last || {}
          evidence = { "version" => 1, "available" => true, "complete" => final["complete"] == true,
            "physical_policy" => final["physical_policy"], "audit_aggregates" => final["audit_aggregates"],
            "runner" => final["transfer"], "engine" => final.slice("upload_rows_inserted", "upload_rows_inserted_without_references", "bookkeeping_references"),
            "phases" => value.fetch("phases").map { |phase| phase.slice("phase", "complete") } }
        end
        refusal_path = @store.run_dir(run_id, "private", "merge-refusal.json")
        if File.file?(refusal_path)
          failure = SiloMergeContract.parse(File.binread(refusal_path, SiloMergeRefusal::MAX_BYTES + 1))
          raise SiloMergeRefusal::Error unless failure.is_a?(Hash)
          if failure.key?("audit_status")
            contract = plan_for(run_id).dig("body", "merge", "contract")
            SiloMergeRefusal.validate!(contract, failure, context: "execution")
            evidence["available"] = true
            # Keep earlier successful phase counts; add only trusted numeric
            # counters for the refused phase, with missing values left unknown.
            evidence["audit_aggregates"] = (evidence["audit_aggregates"] || {}).merge(failure["phase"] => failure["counts"])
          else
            failure = merge_refusal_unavailable(failure["reason"] == "evidence_invalid" ? "evidence_invalid" : "evidence_unavailable")
          end
          evidence["failure"] = failure
          evidence["complete"] = false
        end
        evidence
      rescue SiloMergeContract::Error, SiloMergeRefusal::Error
        evidence.merge("complete" => false, "failure" => merge_refusal_unavailable("evidence_invalid"))
      end

      def merge_process_baseline(run_id)
        report = JSON.parse(File.read(@store.run_dir(run_id, "private", "merge-process.json"))).fetch("phases").last
        path = @store.run_dir(run_id, "private", "merge-baseline-assets.json")
        bytes = mv_read!(path, PROCESS_MANIFEST_LIMIT)
        raise StandardWorkflowError, "STANDARD_BACKUP_FAILED" unless Digest::SHA256.hexdigest(bytes) == report.fetch("baseline_sha256")
        value = SiloMergeContract.parse(bytes, max_bytes: PROCESS_MANIFEST_LIMIT)
        SiloDiscourseBaselineAssets.validate!(value)
        value
      rescue SystemCallError, KeyError, SiloDiscourseBaselineAssets::Error, SiloMergeContract::Error
        raise StandardWorkflowError, "STANDARD_BACKUP_FAILED"
      end

      def merge_process_validation_evidence(run_id)
        binding = plan_for(run_id).dig("body", "merge", "process")
        return nil unless binding
        path = File.join(@store.root, "validations", "#{binding.fetch('receipt_id')}.json")
        bytes = mv_read!(path, 4 * 1024 * 1024)
        raise StandardWorkflowError, "STANDARD_MERGE_VALIDATION_STALE" unless Digest::SHA256.hexdigest(bytes) == binding["receipt_sha256"]
        receipt = SiloMergeContract.parse(bytes, max_bytes: 4 * 1024 * 1024)
        receipt.slice("version", "receipt_id", "status", "reason", "key_path", "cleanup_confirmed", "generation", "audit", "checks")
      end

      def merge_process_references_check!(run_id, stack)
        return unless plan_for(run_id).dig("body", "merge", "process")
        report = JSON.parse(File.read(@store.run_dir(run_id, "private", "merge-process.json"))).fetch("phases").last
        expected = report.fetch("references_sha256")
        path = @store.run_dir(run_id, "private", "merge-asset-references.json")
        raise StandardWorkflowError, "STANDARD_MERGE_EVIDENCE_INVALID" unless Digest::SHA256.file(path).hexdigest == expected
        stack.copy_in(path, "/shared/merge-process/references.json", owner: "root:root")
        merge_checked(run_id, "merge-reference-mode", stack.web_exec(%w[chmod 0444 /shared/merge-process/references.json]))
        checked = stack.discourse_shell(["env", "SILO_MERGE_REFERENCE_CHECK=1", "SILO_MERGE_REFERENCES_SHA256=#{expected}",
          "bundle", "exec", "rails", "runner", "/tmp/merge_asset_references.rb"], timeout: 300)
        unless checked.success? && checked.stdout.to_s.lines.grep(/\ASILO_MERGE_REFERENCES: clean\r?\n?\z/).size == 1
          raise StandardWorkflowError, "STANDARD_MERGE_ASSETS_FAILED"
        end
      end

      def merge_process_manifest(run_id)
        return nil unless plan_for(run_id).dig("body", "merge", "process")
        if File.exist?(@store.run_dir(run_id, "private", "merge-refusal.json"))
          raise StandardWorkflowError, "STANDARD_BACKUP_FAILED"
        end
        path = @store.run_dir(run_id, "private", "merge-asset-manifest.json")
        bytes = File.binread(path, PROCESS_MANIFEST_LIMIT + 1)
        raise StandardWorkflowError, "STANDARD_BACKUP_FAILED" if bytes.bytesize > PROCESS_MANIFEST_LIMIT
        saved = JSON.parse(File.read(@store.run_dir(run_id, "private", "merge-process.json")))
        expected = saved.fetch("phases").last.fetch("manifest_sha256")
        raise StandardWorkflowError, "STANDARD_BACKUP_FAILED" unless Digest::SHA256.hexdigest(bytes) == expected
        manifest = SiloMergeContract.parse(bytes, max_bytes: PROCESS_MANIFEST_LIMIT)
        SiloMergeAssets.validate!(manifest)
        manifest
      rescue SystemCallError, KeyError, JSON::ParserError, SiloMergeAssets::Error, SiloMergeContract::Error
        raise StandardWorkflowError, "STANDARD_BACKUP_FAILED"
      end
    end
  end
end
