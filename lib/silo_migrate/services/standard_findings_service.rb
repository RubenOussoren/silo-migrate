# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require_relative "../standard_store"

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
      KINDS = %w[finding reproduction].freeze

      def initialize(workspace, env: ENV)
        @store = StandardStore.new(workspace, env: env)
      end

      # Trusted analyst path. Returns only an ID: content is never echoed back.
      def propose(run_id:, text:, kind: "finding")
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless KINDS.include?(kind) && text.is_a?(String) && text.bytesize.between?(1, MAX_BYTES) && text.valid_encoding?

        id = @store.new_id("finding")
        @store.update do |state|
          raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless state.fetch("runs").key?(run_id)

          @store.write_private(@store.finding_dir(id, "private", "proposal.txt"), text)
          state.fetch("findings")[id] = { "id" => id, "run_id" => run_id, "kind" => kind, "status" => "proposed", "proposed_at" => Time.now.utc.iso8601,
                                          "proposal_sha256" => Digest::SHA256.hexdigest(text), "release" => nil }
        end
        { version: 1, finding_id: id, status: "proposed" }
      end

      # Engineer path: the private proposal, plus exact-digest gated release.
      def review_text(finding_id)
        record!(finding_id)
        File.read(@store.finding_dir(finding_id, "private", "proposal.txt"))
      end

      def reject(finding_id:, reviewer:)
        decide(finding_id, reviewer) do |record|
          record["status"] = "rejected"
          record["rejected_by"] = reviewer
          { version: 1, finding_id: finding_id, status: "rejected" }
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
        { version: 1, findings: findings.map { |record| { finding_id: record["id"], run_id: record["run_id"], kind: record["kind"], sha256: record.dig("release", "sha256"), released_at: record.dig("release", "released_at") } } }
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
        { version: 1, finding_id: finding_id, kind: record["kind"], run_id: record["run_id"], summary: summary, reproduction: reproduction, sha256: record.dig("release", "sha256") }
      end

      private

      def record!(finding_id)
        @store.load.fetch("findings")[finding_id] || raise(StandardWorkflowError, "STANDARD_REFERENCE_INVALID")
      end

      def decide(finding_id, reviewer)
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless reviewer.is_a?(String) && reviewer.match?(/\A[[:print:]]{1,120}\z/)

        @store.update do |state|
          record = state.fetch("findings")[finding_id]
          raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless record
          raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" unless record["status"] == "proposed"

          yield record
        end
      end
    end
  end
end
