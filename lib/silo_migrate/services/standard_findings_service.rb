# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require_relative "../standard_store"
require_relative "standard_convert_run"
require_relative "standard_review_run"

module SiloMigrate
  module Services
    # The investigation/release boundary. A trusted analyst proposes a private
    # finding; only an engineer can release a bounded derivative, bound to its exact
    # bytes. Clean coding context sees released derivatives and nothing else.
    # A proposal never self-certifies: the proposer cannot select what is released.
    # This is a storage and interface boundary on one operator-owned filesystem, not
    # an OS sandbox; OS/container isolation of the analyst is a separate control.
    class StandardFindingsService
      MAX_BYTES = 256 * 1024
      # schema: tables, columns, counts and invented examples of a source, proposed by the
      # data agent from the project's source data. It belongs to no run.
      KINDS = %w[finding reproduction schema].freeze
      EVIDENCE_TAIL_BYTES = 16 * 1024
      # term-llm 0.9.93 cuts a custom tool's output at 50 KiB (DefaultOutputLimits.MaxBytes),
      # mid-JSON. The whole evidence document stays under this so it always arrives intact.
      EVIDENCE_OUTPUT_BYTES = 40 * 1024
      EVIDENCE_MIN_TAIL_BYTES = 512
      EVIDENCE_FAILURE_BYTES = 4 * 1024
      EVIDENCE_STATE_BYTES = 4 * 1024
      EVIDENCE_INDEX_ENTRIES = 200
      # Which stage writes each private log (StandardWorkflowService#log and #checked
      # names). Keep in step with those calls; a full-run test checks every log maps.
      LOG_STAGES = {
        /\A(convert|conversion-[a-z-]+)\z/ => "convert",
        /\A(backup-baseline|baseline-restore(-disable)?)\z/ => "baseline",
        /\Auploads\z/ => "uploads",
        /\Aimport(-consistency)?\z/ => "import",
        /\Abackup-final\z/ => "final_backup",
        /\Afinal-restore(-disable)?\z/ => "restore"
      }.freeze

      # Real-data runs: their completed results (reconciliation differences, import issues)
      # are what converter work fixes, so findings on them are allowed.
      def convert_run?(state, run_id)
        plan = state.fetch("plans")[state.fetch("runs").fetch(run_id)["plan_id"]]
        [StandardConvertRun::CONVERT_OPERATION, StandardReviewRun::REVIEW_OPERATION].include?(plan&.dig("body", "operation"))
      end

      def self.log_stage(name)
        LOG_STAGES.find { |pattern, _stage| pattern.match?(name) }&.last
      end

      def initialize(workspace, env: ENV)
        @store = StandardStore.new(workspace, env: env)
      end

      # Trusted analyst path. Returns only an ID: content is never echoed back.
      # A completed full run has nothing to diagnose, so it gets no finding. A completed
      # convert run does: its reconciliation differences are what converter work fixes.
      def propose(run_id:, text:, kind: "finding")
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless KINDS.include?(kind) && text.is_a?(String) && text.bytesize.between?(1, MAX_BYTES) && text.valid_encoding?

        id = @store.new_id("finding")
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless (kind == "schema") == run_id.nil?

        @store.update do |state|
          unless kind == "schema"
            raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless state.fetch("runs").key?(run_id)
            raise StandardWorkflowError, "STANDARD_RUN_COMPLETED" if state.fetch("runs").fetch(run_id)["status"] == "completed" && !convert_run?(state, run_id)
          end

          @store.write_private(@store.finding_dir(id, "private", "proposal.txt"), text)
          state.fetch("findings")[id] = { "id" => id, "run_id" => run_id, "kind" => kind, "status" => "proposed", "proposed_at" => Time.now.utc.iso8601,
                                          "proposal_sha256" => Digest::SHA256.hexdigest(text), "release" => nil }
        end
        { version: 1, finding_id: id, status: "proposed" }
      end

      # Trusted analyst path only. Bounded read of one run's private evidence. Never
      # reachable from `standard agent`; do not expose it to a coding session.
      #
      # Structured state comes first (stages, assertions, results, failure), then an
      # index of every evidence file and log with its size and stage (up to
      # EVIDENCE_INDEX_ENTRIES each, with totals), then tails in priority order:
      # failed assertion groups, the log named by the failure, the failed stage's
      # logs (latest first), then earlier stages. Tails stop at the byte budget of
      # the serialized document. An entry whose tail_bytes is below its bytes was not
      # read in full; `tails_omitted` counts files with no tail at all.
      def private_evidence(run_id, budget: EVIDENCE_OUTPUT_BYTES)
        run = @store.load.fetch("runs")[run_id]
        raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless run

        directory = @store.run_dir(run_id)
        stages = run.fetch("stages", {})
        detail = failure_detail(File.join(directory, "private", "failure.json"))
        failed_stage = run.dig("failure", "stage") || (detail.is_a?(Hash) ? detail["stage"] : nil)
        completed = run["status"] == "completed" && !convert_run?(@store.load, run_id)
        all_evidence = files(File.join(directory, "evidence"), "*")
        all_logs = files(File.join(directory, "logs"), "*.log")
        evidence_files = all_evidence.first(EVIDENCE_INDEX_ENTRIES).map { |path| { name: File.basename(path), bytes: File.size(path), path: path } }
        logs = all_logs.first(EVIDENCE_INDEX_ENTRIES).map do |path|
          name = File.basename(path, ".log")
          { name: File.basename(path), bytes: File.size(path), stage: self.class.log_stage(name) || stage_by_time(stages, File.mtime(path)), path: path, mtime: File.mtime(path) }
        end
        result = {
          version: 1, run_id: run_id, status: run["status"], stage: run["stage"], failed_stage: failed_stage,
          stages: stages.to_h { |name, entry| [name, entry.slice("status", "started_at", "finished_at")] },
          assertions: bounded(run.fetch("assertions", {})), results: bounded(run.fetch("results", {})),
          failure: run["failure"], failure_detail: detail,
          finding: completed ? "not_applicable: run completed; summarise it, do not propose a finding" : "may_propose",
          budget_bytes: budget,
          evidence_files_total: all_evidence.size, logs_total: all_logs.size,
          evidence_files: evidence_files.map { |file| { name: file[:name], bytes: file[:bytes], tail_bytes: 0 } },
          logs: logs.map { |log| { name: log[:name], bytes: log[:bytes], stage: log[:stage], tail_bytes: 0 } },
          tails: {}, tails_omitted: 0
        }
        candidates = tail_candidates(run, result, evidence_files, logs, failed_stage, detail)
        fill_tails(result, candidates, budget)
        result
      end

      # Engineer path: the private proposal, plus exact-digest gated release.
      def review_text(finding_id)
        record!(finding_id)
        path = @store.finding_dir(finding_id, "private", "proposal.txt")
        # An amendment has no proposal of its own: it is the engineer's text.
        raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless File.file?(path)

        File.read(path)
      end

      def reject(finding_id:, reviewer:)
        decide(finding_id, reviewer) do |record|
          record["status"] = "rejected"
          record["rejected_by"] = reviewer
          record["rejected_at"] = Time.now.utc.iso8601
          { version: 1, finding_id: finding_id, status: "rejected" }
        end
      end

      # Correct a released finding: the engineer's new text is released as a new finding
      # that replaces it. Coding agents then see only the replacement; the old one is
      # kept, marked superseded, for the record.
      def amend(finding_id:, released_text:, sha256:, reviewer:)
        raise StandardWorkflowError, "STANDARD_APPROVAL_MISMATCH" unless released_text.is_a?(String) && released_text.bytesize.between?(1, MAX_BYTES) && released_text.valid_encoding? && Digest::SHA256.hexdigest(released_text) == sha256

        id = @store.new_id("finding")
        decide(finding_id, reviewer, from: "released") do |record, state|
          now = Time.now.utc.iso8601
          # A released synthetic reproduction stays with the corrected text (verified first).
          reproduction_sha256 = record.dig("release", "reproduction_sha256")
          if reproduction_sha256
            reproduction = File.read(@store.finding_dir(finding_id, "released", "reproduction.txt"))
            raise StandardWorkflowError, "STANDARD_RELEASE_TAMPERED" unless Digest::SHA256.hexdigest(reproduction) == reproduction_sha256

            @store.write_private(@store.finding_dir(id, "released", "reproduction.txt"), reproduction)
          end
          @store.write_private(@store.finding_dir(id, "released", "summary.txt"), released_text)
          state.fetch("findings")[id] = { "id" => id, "run_id" => record["run_id"], "kind" => record["kind"], "status" => "released", "proposed_at" => now,
                                          "proposal_sha256" => nil, "supersedes" => finding_id,
                                          "release" => { "sha256" => sha256, "bytes" => released_text.bytesize, "reproduction_sha256" => reproduction_sha256, "reviewer" => reviewer, "released_at" => now } }
          record["status"] = "superseded"
          record["superseded_by"] = id
          record["superseded_at"] = now
          { version: 1, finding_id: id, status: "released", supersedes: finding_id, sha256: sha256 }
        end
      end

      # Take a released finding back without a replacement (e.g. it should never have gone out).
      def withdraw(finding_id:, reviewer:)
        decide(finding_id, reviewer, from: "released") do |record|
          record["status"] = "withdrawn"
          record["withdrawn_by"] = reviewer
          record["withdrawn_at"] = Time.now.utc.iso8601
          { version: 1, finding_id: finding_id, status: "withdrawn" }
        end
      end

      # The released text is engineer-authored or engineer-reviewed and need not equal
      # the proposal. Stored separately; only that derivative is ever projected.
      def release(finding_id:, released_text:, sha256:, reviewer:, reproduction: nil, reproduction_sha256: nil)
        raise StandardWorkflowError, "STANDARD_APPROVAL_MISMATCH" unless released_text.is_a?(String) && released_text.bytesize.between?(1, MAX_BYTES) && released_text.valid_encoding? && Digest::SHA256.hexdigest(released_text) == sha256
        unless reproduction.nil? == reproduction_sha256.nil? && (reproduction.nil? || (reproduction.bytesize <= MAX_BYTES && Digest::SHA256.hexdigest(reproduction) == reproduction_sha256))
          raise StandardWorkflowError, "STANDARD_APPROVAL_MISMATCH"
        end

        decide(finding_id, reviewer) do |record|
          @store.write_private(@store.finding_dir(finding_id, "released", "summary.txt"), released_text)
          @store.write_private(@store.finding_dir(finding_id, "released", "reproduction.txt"), reproduction) if reproduction
          record["status"] = "released"
          record["release"] = { "sha256" => sha256, "bytes" => released_text.bytesize, "reproduction_sha256" => reproduction_sha256, "reviewer" => reviewer, "released_at" => Time.now.utc.iso8601 }
          { version: 1, finding_id: finding_id, status: "released", sha256: sha256 }
        end
      end

      # Coding-context views. Unreleased findings are not even enumerated.
      def released_list
        findings = @store.load.fetch("findings").values.select { |record| record["status"] == "released" }
        { version: 1, findings: findings.map { |record| { finding_id: record["id"], run_id: record["run_id"], kind: record["kind"], sha256: record.dig("release", "sha256"), released_at: record.dig("release", "released_at"), supersedes: record["supersedes"] } } }
      end

      def released_show(finding_id)
        record = @store.load.fetch("findings")[finding_id]
        raise StandardWorkflowError, "STANDARD_NOT_RELEASED" unless record && record["status"] == "released"

        summary = File.read(@store.finding_dir(finding_id, "released", "summary.txt"))
        raise StandardWorkflowError, "STANDARD_RELEASE_TAMPERED" unless Digest::SHA256.hexdigest(summary) == record.dig("release", "sha256")

        repro_path = @store.finding_dir(finding_id, "released", "reproduction.txt")
        reproduction = nil
        if record.dig("release", "reproduction_sha256")
          reproduction = File.read(repro_path)
          raise StandardWorkflowError, "STANDARD_RELEASE_TAMPERED" unless Digest::SHA256.hexdigest(reproduction) == record.dig("release", "reproduction_sha256")
        end
        { version: 1, finding_id: finding_id, kind: record["kind"], run_id: record["run_id"], summary: summary, reproduction: reproduction, sha256: record.dig("release", "sha256"), supersedes: record["supersedes"] }
      end

      private

      def files(directory, pattern)
        return [] if File.symlink?(directory)

        Dir[File.join(directory, pattern)].select { |path| File.file?(path) && !File.symlink?(path) }.sort
      end

      # Workflow-recorded state is small; this bounds it anyway so the document fits.
      def bounded(hash)
        return hash if JSON.generate(hash).bytesize <= EVIDENCE_STATE_BYTES

        kept = {}
        hash.each do |key, value|
          break if JSON.generate(kept.merge(key => value)).bytesize > EVIDENCE_STATE_BYTES - 64

          kept[key] = value
        end
        kept.merge("_truncated" => "#{hash.size - kept.size} of #{hash.size} entries omitted")
      end

      # The private failure record, or its bounded tail if it is large or not JSON.
      def failure_detail(path)
        return nil unless File.file?(path) && !File.symlink?(path)

        if File.size(path) <= EVIDENCE_FAILURE_BYTES
          parsed = JSON.parse(File.read(path))
          return parsed if JSON.generate(parsed).bytesize <= EVIDENCE_FAILURE_BYTES
        end
        { "tail" => fitted_tail(path, EVIDENCE_FAILURE_BYTES).to_s }
      rescue JSON::ParserError
        { "tail" => fitted_tail(path, EVIDENCE_FAILURE_BYTES).to_s }
      end

      # Fallback for log names LOG_STAGES does not know: the stage running when the
      # log was last written (timestamps are whole seconds).
      def stage_by_time(stages, mtime)
        stages.select do |_name, entry|
          started = entry["started_at"] && Time.parse(entry["started_at"])
          finished = entry["finished_at"] && Time.parse(entry["finished_at"])
          started && mtime >= started - 1 && (finished.nil? || mtime <= finished + 1)
        end.keys.last
      rescue ArgumentError
        nil
      end

      def tail_candidates(run, result, evidence_files, logs, failed_stage, detail)
        assertions = run.fetch("assertions", {})
        failures = evidence_files.each_with_index.select { |file, _index| file[:name].end_with?(".failures.json") }
        failures = failures.sort_by { |file, _index| [assertions.dig(file[:name].delete_suffix(".failures.json"), "result") == "failed" ? 0 : 1, file[:name]] }
        order = run.fetch("stages", {}).keys
        # A failed checked step records its log name as the failure detail.
        named = detail.is_a?(Hash) && detail["detail"].is_a?(String) ? "#{detail['detail']}.log" : nil
        ranked = logs.each_with_index.sort_by do |log, _index|
          [log[:name] == named ? 0 : 1, log[:stage] && log[:stage] == failed_stage ? 0 : 1, -(order.index(log[:stage]) || -1), -log[:mtime].to_f, log[:name]]
        end
        failures.map { |file, index| { key: "evidence/#{file[:name]}", path: file[:path], entry: result[:evidence_files][index] } } +
          ranked.map { |log, index| { key: "logs/#{log[:name]}", path: log[:path], entry: result[:logs][index] } }
      end

      def fill_tails(result, candidates, budget)
        # Room for the index's tail_bytes values.
        used = JSON.generate(result).bytesize + 64 + candidates.size * 8
        candidates.each do |candidate|
          room = [budget - used, EVIDENCE_TAIL_BYTES].min
          text = room >= EVIDENCE_MIN_TAIL_BYTES ? fitted_tail(candidate[:path], room) : nil
          next unless text

          result[:tails][candidate[:key]] = text
          candidate[:entry][:tail_bytes] = text.bytesize
          used += JSON.generate(candidate[:key]).bytesize + JSON.generate(text).bytesize + 2
        end
        # The serialized document must fit: drop the lowest-priority tails, then (for
        # pathological runs) trailing index entries; the totals still show the count.
        while JSON.generate(result).bytesize > budget
          if (key = result[:tails].keys.last)
            result[:tails].delete(key)
            candidates.find { |candidate| candidate[:key] == key }[:entry][:tail_bytes] = 0
          elsif !result[:logs].empty?
            result[:logs].pop
          elsif !result[:evidence_files].empty?
            result[:evidence_files].pop
          else
            break
          end
        end
        result[:tails_omitted] = candidates.size - result[:tails].size
      end

      # The longest whole-line tail whose JSON encoding fits in `limit` bytes.
      def fitted_tail(path, limit)
        want = [limit, File.size(path)].min
        4.times do
          text = read_tail(path, want)
          encoded = JSON.generate(text).bytesize
          return text if encoded <= limit

          want = (want * limit / encoded) - 16
          return nil if want < EVIDENCE_MIN_TAIL_BYTES / 2
        end
        nil
      end

      def read_tail(path, bytes)
        File.open(path, "rb") do |file|
          size = file.size
          file.seek([size - bytes, 0].max)
          text = file.read(bytes).to_s.force_encoding("UTF-8").scrub
          newline = bytes < size ? text.index("\n") : nil
          newline && newline < text.length - 1 ? text[(newline + 1)..] : text
        end
      end

      def record!(finding_id)
        @store.load.fetch("findings")[finding_id] || raise(StandardWorkflowError, "STANDARD_REFERENCE_INVALID")
      end

      def decide(finding_id, reviewer, from: "proposed")
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless reviewer.is_a?(String) && reviewer.match?(/\A[[:print:]]{1,120}\z/)

        @store.update do |state|
          record = state.fetch("findings")[finding_id]
          raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless record
          raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" unless record["status"] == from

          yield record, state
        end
      end
    end
  end
end
