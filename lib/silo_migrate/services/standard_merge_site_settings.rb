# frozen_string_literal: true

require "digest"
require "json"

module SiloMigrate
  module Services
    # Host authority for the one temporary stock-merger setting. Snapshot values never
    # enter argv, ordinary logs, public results or agent projections. The Rails helper
    # owns restoration/cache refresh; this host independently compares stored rows at
    # each later boundary and guards restoration on failed/interrupted execution.
    module StandardMergeSiteSettings
      MERGE_SITE_SETTINGS_BYTES = 8 * 1024 * 1024
      MERGE_SITE_SETTINGS_GUEST = "/shared/merge/site-settings.json"
      MERGE_SITE_SETTINGS_NAME = "authorized_extensions"
      MERGE_SITE_SETTINGS_CODE = "STANDARD_MERGE_SITE_SETTINGS_FAILED"
      MERGE_SITE_SETTINGS_SQL = "SELECT COALESCE(json_object_agg(name, json_build_array(value, data_type)), '{}'::json) FROM site_settings".freeze
      MERGE_SITE_SETTINGS_POLICY = {
        "version" => 1, "temporary_setting" => MERGE_SITE_SETTINGS_NAME,
        "restore_before" => "postflight", "verify_before_backup" => true
      }.freeze

      private

      def merge_site_settings_path(run_id)
        @store.run_dir(run_id, "private", "merge-site-settings.json")
      end

      def merge_site_settings_binding(run_id)
        @store.load.fetch("runs").fetch(run_id)["merge_site_settings"]
      end

      def merge_site_settings_snapshot!(run_id)
        binding = merge_site_settings_binding(run_id)
        path = merge_site_settings_path(run_id)
        unless binding.is_a?(Hash) && binding["sha256"].is_a?(String) && binding["sha256"].match?(/\A[0-9a-f]{64}\z/) &&
               File.file?(path) && !File.symlink?(path) && File.size(path) <= MERGE_SITE_SETTINGS_BYTES
          raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE
        end
        bytes = File.binread(path)
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless Digest::SHA256.hexdigest(bytes) == binding["sha256"]

        snapshot = JSON.parse(bytes)
        valid = snapshot.is_a?(Hash) && snapshot["version"] == 1 && valid_merge_site_settings?(snapshot["settings"]) &&
                snapshot["authorized_extensions_effective"].is_a?(String)
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless valid

        [snapshot, binding]
      rescue JSON::ParserError, SystemCallError, TypeError
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE
      end

      def valid_merge_site_settings?(settings)
        settings.is_a?(Hash) && settings.all? do |name, pair|
          name.is_a?(String) && !name.empty? && pair.is_a?(Array) && pair.size == 2 &&
            (pair[0].nil? || pair[0].is_a?(String)) && pair[1].is_a?(Integer)
        end
      end

      def merge_site_settings_json!(result, prefix, allow_failure: false)
        # A boot/validation exception may contain a setting value. Never log raw output.
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless (result.success? || allow_failure) && result.stdout.to_s.bytesize <= MERGE_SITE_SETTINGS_BYTES

        lines = result.stdout.to_s.lines.grep(/\A#{Regexp.escape(prefix)}/)
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless lines.size == 1

        JSON.parse(lines.first.delete_prefix(prefix))
      rescue JSON::ParserError, TypeError
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE
      end

      def merge_site_settings_helper(stack, action, binding: nil, uncertain: false)
        env = ["SILO_MERGE_SITE_SETTINGS_ACTION=#{action}"]
        env << "SILO_MERGE_SITE_SETTINGS_EXECUTION_UNCERTAIN=1" if uncertain
        env << "SILO_MERGE_SITE_SETTINGS_SHA256=#{binding.fetch('sha256')}" if binding
        stack.discourse_shell(["env", *env, "bundle", "exec", "rails", "runner", "/tmp/merge_site_settings.rb"], timeout: 300)
      end

      def merge_site_settings_install!(run_id, stack, binding)
        # Reinstall from the host's immutable bound copy for failure/recovery too. Never
        # trust a file left in the container by the failed process.
        merge_site_settings_snapshot!(run_id)
        stack.copy_in(merge_site_settings_path(run_id), MERGE_SITE_SETTINGS_GUEST, owner: "root:root")
        result = stack.web_exec(["chmod", "0444", MERGE_SITE_SETTINGS_GUEST])
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless result.success?
      end

      def merge_site_settings_capture!(run_id, stack)
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE if merge_site_settings_binding(run_id)

        snapshot = merge_site_settings_json!(merge_site_settings_helper(stack, "capture"), "SILO_SETTINGS_SNAPSHOT:")
        before = JSON.parse(File.read(@store.run_dir(run_id, "evidence", "merge-before.json")))
        unless snapshot.is_a?(Hash) && snapshot["version"] == 1 && valid_merge_site_settings?(snapshot["settings"]) &&
               snapshot["settings"] == before.fetch("settings") && snapshot["authorized_extensions_effective"].is_a?(String)
          raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE
        end
        bytes = JSON.generate(snapshot) + "\n"
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE if bytes.bytesize > MERGE_SITE_SETTINGS_BYTES

        @store.write_private(merge_site_settings_path(run_id), bytes)
        binding = { "version" => 1, "sha256" => Digest::SHA256.hexdigest(bytes), "execution" => "not_started" }
        @store.update { |state| state.fetch("runs").fetch(run_id)["merge_site_settings"] = binding }
        merge_site_settings_install!(run_id, stack, binding)
        merge_result(run_id, site_settings_preservation: "captured")
        binding
      rescue JSON::ParserError, KeyError, TypeError
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE
      end

      def merge_site_settings_execution!(run_id, phase)
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("merge_site_settings")["execution"] = phase }
      end

      def merge_site_settings_report!(run_id, phase, report)
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless phase.match?(/\A[a-z_-]+\z/)

        # Only this fixed projection is retained. The helper's arbitrary fields/values
        # cannot turn an error response into a settings dump.
        safe = { "version" => 1, "phase" => phase, "state" => report.fetch("state") }
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless %w[verified changed restored unproven].include?(safe["state"])

        %w[restoration_failed unexpected_names].each do |key|
          names = report.fetch(key, [])
          raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) }

          safe[key] = names.uniq.sort
        end
        count = report["remaining_differences"]
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless count.nil? || (count.is_a?(Integer) && count >= 0)

        if safe["state"] == "restored" && (count != 0 || safe["restoration_failed"].any? || safe["unexpected_names"].any?)
          safe["state"] = "unproven"
        end
        safe["remaining_differences"] = count
        safe["execution_uncertain"] = true if report["execution_uncertain"] == true
        @store.write_private(@store.run_dir(run_id, "private", "merge-site-settings-#{phase}.json"), JSON.generate(safe) + "\n")
        merge_result(run_id, site_settings_preservation: safe["state"], site_settings_changed: count)
        safe
      end

      def merge_site_settings_compare!(run_id, settings, phase:, effective: nil)
        snapshot, = merge_site_settings_snapshot!(run_id)
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless valid_merge_site_settings?(settings)

        expected = snapshot.fetch("settings")
        names = (expected.keys | settings.keys).reject { |name| expected[name] == settings[name] }
        if !effective.nil? && effective != snapshot.fetch("authorized_extensions_effective")
          names |= [MERGE_SITE_SETTINGS_NAME]
        end
        merge_site_settings_report!(run_id, phase, "state" => names.empty? ? "verified" : "changed",
                                    "unexpected_names" => names, "remaining_differences" => names.size)
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless names.empty?
      end

      def merge_site_settings_check!(run_id, stack, phase:)
        # Fast, fixed SQL after the expensive Rails merge/after finalization and before
        # backup/completion. Values are compared in memory, never printed or repaired.
        settings = begin
          merge_site_settings_json!(stack.db_query(MERGE_SITE_SETTINGS_SQL), "")
        rescue StandardWorkflowError, JSON::ParserError, TypeError
          merge_site_settings_report!(run_id, phase, "state" => "unproven", "remaining_differences" => nil) rescue nil
          raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE
        end
        # Do not replace a proven difference's private names/count with an unreadable
        # state just because comparison deliberately raises to fail the run.
        merge_site_settings_compare!(run_id, settings, phase: phase)
      end

      def merge_site_settings_verify_state!(run_id, state)
        raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless state["effective_authorized_extensions"].is_a?(String)

        merge_site_settings_compare!(run_id, state.fetch("settings"), phase: "verify",
                                    effective: state.fetch("effective_authorized_extensions"))
      end

      def merge_site_settings_failure_cleanup(run_id, phase: "failure")
        # No snapshot => no constructor was started through this contract. Do not touch
        # a preparation or another run's databases. An interrupted exec may still run:
        # attempt the guarded restoration, but refuse unsafe concurrent writes when the
        # guest's termination is unknown. A matching read cannot prove it has stopped.
        binding = merge_site_settings_binding(run_id)
        return unless binding

        _, binding = merge_site_settings_snapshot!(run_id)
        stack = stack_for(run_id, "review")
        %w[db web].each do |role|
          endpoint = { "id" => stack.record.fetch("containers").fetch(role), "instance" => stack.name }
          raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE unless inspection_container_owned?(endpoint, role)
        end
        merge_site_settings_install!(run_id, stack, binding)
        uncertain = phase == "recovery" || %w[running uncertain].include?(binding["execution"])
        result = merge_site_settings_helper(stack, "restore", binding: binding, uncertain: uncertain)
        # A legitimate failed restore exits nonzero but still supplies names/counts.
        # Keep those diagnostics, without ever treating the exit as successful.
        report = merge_site_settings_json!(result, "SILO_SETTINGS_REPORT:", allow_failure: true)
        unless report.is_a?(Hash) && %w[restored unproven].include?(report["state"])
          raise StandardWorkflowError, MERGE_SITE_SETTINGS_CODE
        end
        report = report.merge("state" => "unproven") unless result.success?
        if uncertain
          report = report.merge("state" => "unproven", "execution_uncertain" => true)
        end
        merge_site_settings_report!(run_id, phase, report)
      rescue StandardError
        # Preserve the original run failure. Missing/bad snapshot or dead stack is NOT
        # a successful restore and never makes a dirty generation ready.
        merge_site_settings_report!(run_id, phase, "state" => "unproven", "restoration_failed" => [MERGE_SITE_SETTINGS_NAME],
                                    "remaining_differences" => nil) rescue nil
      end
    end
  end
end
