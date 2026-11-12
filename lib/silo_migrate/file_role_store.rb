# frozen_string_literal: true

require "json"

module SiloMigrate
  # Read-only effective assignments. Never exposes paths, labels or parser diagnostics.
  # The backend replaces this private document while holding standard/state.lock.
  class FileRoleStore
    MAX_BYTES = 16 * 1024 * 1024
    ID = { "dataset" => /\Adataset-[0-9a-f]{32}\z/, "input" => /\Ainput-[0-9a-f]{32}\z/,
           "file" => /\Afile-[0-9a-f]{32}\z/, "plan" => /\Aplan-[0-9a-f]{32}\z/ }.freeze
    KINDS = %w[development launch base_site].freeze
    ROLES = %w[source uploads reference base_site unassigned].freeze

    def initialize(root)
      @root = root
    end

    def load
      handles = []
      # Resolve every component through held directory descriptors, not a checked
      # pathname which could be replaced with a symlink between check and open.
      directory = File.open(@root, File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
      handles << directory
      directory!(directory, private: false)
      %w[.silo-migrate data].each do |component|
        directory = File.open("/proc/self/fd/#{directory.fileno}/#{component}", File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
        handles << directory
        # A missing optional registry must preserve legacy workspaces. Check
        # private modes on these held descriptors once the file actually exists.
        directory!(directory, private: false)
      end
      file = File.open("/proc/self/fd/#{directory.fileno}/file-roles.json", File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
      handles << file
      handles[1...-1].each { |parent| directory!(parent, private: true) }
      stat = file.stat
      invalid! unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= MAX_BYTES
      bytes = file.read(MAX_BYTES + 1)
      invalid! if bytes.bytesize > MAX_BYTES
      validate!(JSON.parse(bytes))
    rescue Errno::ENOENT
      nil # No registry is the unchanged legacy workflow.
    rescue JSON::ParserError, SystemCallError, IOError, TypeError, ArgumentError
      invalid!
    ensure
      handles&.reverse_each(&:close)
    end

    def binding(document, named, roles)
      return nil unless document

      entries = roles.sort.map do |role, input_id|
        input = named.fetch("inputs")[input_id]
        invalid! unless input
        dataset = input["dataset_id"]
        snapshot = document.fetch("snapshots")[dataset]
        raise StandardWorkflowError, "STANDARD_FILE_ROLES_INELIGIBLE" unless snapshot && snapshot["eligible"]
        expected = role == "base_site" ? "base_site" : "source"
        raise StandardWorkflowError, "STANDARD_FILE_ROLES_INELIGIBLE" unless (snapshot["kind"] == "base_site") == (expected == "base_site")
        originals = document.fetch("files").values.select { |item| (item["input_id"] || item["taken"]) == input_id }
        # Derived settings/checks need not have an original drop entry. Their
        # registered dataset membership is still bound and must remain eligible.
        originals.each do |item|
          unless item["role"] == expected && item["dataset_id"] == dataset && (!item["sha256"] || item["sha256"] == input["sha256"])
            raise StandardWorkflowError, "STANDARD_FILE_ROLES_INELIGIBLE"
          end
        end
        { "role" => role, "input_id" => input_id, "dataset_id" => dataset,
          "revision" => snapshot.fetch("revision"), "eligible" => true }
      end
      { "version" => 1, "inputs" => entries }
    end

    def current?(document, named, bound)
      return false unless document
      roles = bound.fetch("inputs").to_h { |entry| [entry.fetch("role"), entry.fetch("input_id")] }
      binding(document, named, roles) == bound
    rescue StandardWorkflowError, KeyError, TypeError
      false
    end

    def invalidated?(document, plan_id)
      return false unless document
      return true if document.fetch("invalidated_plans", []).include?(plan_id)

      document.fetch("history").any? do |event|
        next false if event.dig("change", "action") == "activate"

        event.fetch("impacts", {}).fetch("pending", []).any? do |entry|
          (entry.is_a?(Hash) ? entry["plan_id"] : entry) == plan_id
        end
      end
    end

    # A legacy completed conversion cannot be rebound to corrected input facts.
    # This gates future reviews only; it does not stale consumed plan projections.
    def lineage_invalidated?(document, plan_id)
      return true if invalidated?(document, plan_id)
      return false unless document

      document.fetch("history").any? do |event|
        next false if event.dig("change", "action") == "activate"

        event.fetch("impacts", {}).fetch("completed", []).any? { |entry| entry["plan_id"] == plan_id }
      end
    end

    def selection(document, bound)
      return nil unless document && bound
      bound.fetch("inputs").map do |entry|
        dataset = entry.fetch("dataset_id")
        kind = document.dig("snapshots", dataset, "kind")
        entry.slice("role", "input_id", "dataset_id", "revision", "eligible").merge("active" => document.dig("active", kind) == dataset)
      end
    end

    private

    def invalid!
      raise StandardWorkflowError, "STANDARD_FILE_ROLES_INVALID"
    end

    def directory!(file, private:)
      stat = file.stat
      invalid! unless stat.directory? && stat.uid == Process.uid && (stat.mode & (private ? 0o077 : 0o022)).zero?
    end

    def id?(value, kind)
      value.is_a?(String) && ID.fetch(kind).match?(value)
    end

    def validate!(doc)
      invalid! unless doc.is_a?(Hash) && doc["version"].is_a?(Integer) && doc["version"] == 1 && doc["revision"].is_a?(Integer) && doc["revision"] >= 1 &&
                       %w[active snapshots files].all? { |key| doc[key].is_a?(Hash) } && doc["history"].is_a?(Array)
      doc["snapshots"].each do |id, entry|
        invalid! unless id?(id, "dataset") && entry.is_a?(Hash) && entry["revision"].is_a?(Integer) && entry["revision"] >= 1 &&
                         [true, false].include?(entry["eligible"]) && KINDS.include?(entry["kind"]) && (!entry.key?("dataset_id") || entry["dataset_id"] == id)
      end
      doc["active"].each do |kind, id|
        invalid! unless KINDS.include?(kind)
        next if id.nil? # Explicitly cleared: no current snapshot, never a fallback.

        invalid! unless id?(id, "dataset") && doc.dig("snapshots", id, "kind") == kind && doc.dig("snapshots", id, "eligible") == true
      end
      doc["files"].each do |id, entry|
        invalid! unless id?(id, "file") && entry.is_a?(Hash) && entry["id"] == id && ROLES.include?(entry["role"]) && entry.key?("dataset_id")
        %w[dataset_id original_dataset_id].each { |key| invalid! if !entry[key].nil? && !id?(entry[key], "dataset") }
        %w[input_id taken].each { |key| invalid! if !entry[key].nil? && !id?(entry[key], "input") }
        invalid! if !entry["sha256"].nil? && !(entry["sha256"].is_a?(String) && entry["sha256"].match?(/\A[0-9a-f]{64}\z/))
      end
      invalid! unless doc.fetch("invalidated_plans", []).is_a?(Array) && doc.fetch("invalidated_plans", []).all? { |id| id?(id, "plan") }
      doc["history"].each do |event|
        invalid! unless event.is_a?(Hash)
        invalid! if event.key?("change") && !event["change"].is_a?(Hash)
        next unless event.key?("impacts")
        invalid! unless event["impacts"].is_a?(Hash) && event["impacts"].fetch("pending", []).is_a?(Array)
        event["impacts"].fetch("pending", []).each { |entry| invalid! unless id?(entry.is_a?(Hash) ? entry["plan_id"] : entry, "plan") }
        invalid! unless event["impacts"].fetch("completed", []).is_a?(Array)
        event["impacts"].fetch("completed", []).each { |entry| invalid! unless entry.is_a?(Hash) && id?(entry["plan_id"], "plan") }
      end
      doc
    end
  end
end
