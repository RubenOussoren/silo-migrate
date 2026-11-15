# frozen_string_literal: true

require "json"

module SiloMigrate
  # The outer refusal code remains compatible; only a deliberately constructed,
  # allowlisted projection may cross the CLI error boundary.
  class StandardMergeValidationFailure < StandardWorkflowError
    attr_reader :validation

    def initialize(validation)
      @validation = validation
      super("STANDARD_MERGE_VALIDATION_FAILED")
    end
  end

  module Services
    module StandardMergeValidationStatus
      SAVED_REASONS = (%w[ok STANDARD_MERGE_VALIDATION_UNPROVEN STANDARD_MERGE_VALIDATION_PROTOCOL
        STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED STANDARD_MERGE_TEMPLATE_CUSTODY
        STANDARD_MERGE_SETTINGS_INVALID STANDARD_MERGE_CONTRACT_REQUIRED STANDARD_MERGE_CONTRACT_INVALID
        STANDARD_MERGE_ENGINE_UNSUPPORTED STANDARD_MERGE_ENVIRONMENT_STALE STANDARD_MERGE_VALIDATION_STALE
        STANDARD_MERGE_VALIDATION_UNSUPPORTED STANDARD_MERGE_CHECKS_INVALID STANDARD_CAPACITY
        STANDARD_BUSY STANDARD_MERGE_VALIDATION_MODE_INVALID] + SiloMergeRefusal::REASONS).freeze
      SAVED_FILE_LIMIT = 4096

      # No locks, state writes, layer/settings reads or runtime calls. A snapshot
      # read may observe an in-progress attempt; missing evidence is never success.
      # Legacy attempts lack creation timestamps: latest means newest saved file
      # mtime, with ties refused rather than guessed. Pin the returned ID thereafter.
      def merge_validation_status(attempt: "latest")
        unless attempt == "latest" || (attempt.is_a?(String) && StandardMergeValidation::VALIDATION_ID.match?(attempt))
          mv_error!("STANDARD_ARGUMENTS_INVALID")
        end
        directory = File.join(@store.root, "validations")
        return mv_saved_projection(nil, nil, nil, "missing", "missing") unless File.exist?(directory) || File.symlink?(directory)
        mv_saved_directory!(directory)
        if attempt == "latest"
          files = Dir.children(directory)
          return mv_saved_unknown("ambiguous") if files.size > SAVED_FILE_LIMIT
          candidates = files.filter_map do |name|
            match = /\A([0-9a-f]{32})\.(?:resources\.)?json\z/.match(name)
            next unless match
            path = File.join(directory, name)
            stat = File.lstat(path)
            return mv_saved_unknown("invalid") unless stat.file? && !stat.symlink?
            [match[1], stat.mtime]
          end
          return mv_saved_projection(nil, nil, nil, "missing", "missing") if candidates.empty?
          newest = candidates.map(&:last).max
          ids = candidates.select { |_, time| time == newest }.map(&:first).uniq
          return mv_saved_unknown("ambiguous") unless ids.size == 1
          attempt = ids.first
        end
        receipt, receipt_state = mv_saved_record(attempt, "json")
        journal, journal_state = mv_saved_record(attempt, "resources.json")
        mv_saved_projection(attempt, receipt, journal, receipt_state, journal_state)
      rescue SystemCallError, JSON::ParserError, StandardWorkflowError, ArgumentError
        safe_id = attempt if attempt.is_a?(String) && StandardMergeValidation::VALIDATION_ID.match?(attempt)
        mv_saved_unknown("invalid", safe_id)
      end

      private

      def mv_saved_directory!(directory)
        # Never traverse a symlinked evidence parent. Store paths are owned by the
        # operator, not an authentication boundary against that same OS user.
        current = File.expand_path(directory)
        loop do
          stat = File.lstat(current)
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless stat.directory? && !stat.symlink?
          break if current == File.dirname(current)
          current = File.dirname(current)
        end
        stat = File.stat(directory)
        mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless stat.uid == Process.uid && (stat.mode & 0o077).zero?
      end

      def mv_saved_record(id, suffix)
        path = mv_path(id, suffix)
        bytes = File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          stat = file.stat
          limit = suffix == "json" ? 4 * 1024 * 1024 : 64 * 1024
          unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= limit
            return [nil, "invalid"]
          end
          data = file.read(limit + 1)
          return [nil, "invalid"] if data.bytesize > limit
          data
        end
        record = JSON.parse(bytes, max_nesting: 32)
        return [nil, "invalid"] unless record.is_a?(Hash) && record["version"] == 1
        if suffix == "json"
          return [nil, "invalid"] unless record["receipt_id"] == id && %w[passed refused].include?(record["status"])
        else
          mv_journal!(record)
          return [nil, "invalid"] unless record["id"] == id
        end
        [record, "saved"]
      rescue Errno::ENOENT
        [nil, "missing"]
      rescue SystemCallError, JSON::ParserError, StandardWorkflowError, ArgumentError
        [nil, "invalid"]
      end

      def mv_saved_reason(value)
        SAVED_REASONS.include?(value) ? value : "unknown"
      end

      def mv_saved_stage(value)
        StandardMergeValidation::VALIDATION_STEPS.include?(value) ? value : "unknown"
      end

      def mv_saved_diagnostic(value)
        value = {} unless value.is_a?(Hash)
        { "reason" => mv_saved_reason(value["reason"]), "stage" => mv_saved_stage(value["step"]),
          "deadline_reached" => [true, false].include?(value["deadline_reached"]) ? value["deadline_reached"] : nil,
          "command_outcome" => %w[completed failed timeout_or_interrupted unknown].include?(value["command_outcome"]) ? value["command_outcome"] : "unknown" }
      end

      def mv_saved_unknown(state, id = nil)
        mv_saved_projection(id, nil, nil, state, state)
      end

      def mv_saved_projection(id, receipt, journal, receipt_state, journal_state)
        receipt = {} unless receipt.is_a?(Hash)
        journal = {} unless journal.is_a?(Hash)
        diagnostics = receipt["diagnostics"].is_a?(Hash) ? receipt["diagnostics"] : {}
        work = mv_saved_diagnostic(diagnostics["work"])
        cleanup = mv_saved_diagnostic(diagnostics["cleanup"])
        reason = mv_saved_reason(receipt["reason"])
        primary = mv_saved_reason(receipt["primary_reason"])
        primary = work["reason"] if primary == "unknown"
        primary = reason if primary == "unknown"
        # A cleanup refusal must not hide a typed policy refusal, if preserved.
        failure = receipt["failure"]
        primary = mv_saved_reason(failure["reason"]) if failure.is_a?(Hash) && primary == "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED"
        work["reason"] = primary
        work["status"] = %w[passed refused].include?(receipt["work_status"]) ? receipt["work_status"] : receipt.fetch("status", "unknown")
        work["stage"] = mv_saved_stage(journal["last_stage"]) if work["stage"] == "unknown"
        producer = %w[completed unknown not_started].include?(journal["producer_outcome"]) ? journal["producer_outcome"] : "unknown"
        # Receipt and journal are independent snapshots. Require both proofs; a
        # repaired journal never rewrites a historical failed receipt as passing.
        cleanup["status"] = if journal_state == "saved" && journal["status"] == "cleaned" && journal["cleanup_confirmed"] == true
          "confirmed"
        elsif journal_state == "saved" && journal["cleanup_confirmed"] == false
          "unconfirmed"
        else
          "unknown"
        end
        path = receipt["key_path"]
        result = { "version" => 1, "attempt_id" => id, "evidence" => { "receipt" => receipt_state, "journal" => journal_state },
          "status" => receipt.fetch("status", "unknown"), "reason" => reason, "work" => work,
          "producer_outcome" => producer, "cleanup" => cleanup,
          "key_path_segments" => path.is_a?(Array) && path.size <= 32 ? path.size : nil }
        result["next_action"] = if [receipt_state, journal_state].any? { |state| %w[invalid ambiguous].include?(state) }
          "reconcile_saved_evidence"
        elsif id.nil?
          "no_saved_attempt"
        elsif cleanup["status"] == "confirmed"
          receipt["status"] == "passed" ? "review_exact_plan_before_separate_start" : "inspect_private_evidence_and_correct_cause"
        else
          "preview_exact_attempt_recovery"
        end
        result
      end
    end
  end
end
