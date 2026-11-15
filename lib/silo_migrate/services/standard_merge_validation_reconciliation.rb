# frozen_string_literal: true

module SiloMigrate
  module Services
    # Current observations, NOT historical completion/ownership proof. No apply
    # counterpart: legacy retirement requires separately reviewed authority.
    module StandardMergeValidationReconciliation
      RECONCILE_PROCESS_SCAN = <<~'RUBY'.freeze
        begin
          guest, role = ARGV
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          paths = Dir.glob('/proc/[0-9]*/cmdline')
          unknown = paths.size > 4096
          found = false
          paths.first(4096).each do |path|
            next if path == "/proc/#{Process.pid}/cmdline"
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              unknown = true
              break
            end
            begin
              bytes = File.open(path, 'rb') { |file| file.read(65_537) }
              if bytes.bytesize > 65_536
                unknown = true
                next
              end
              found ||= bytes.split("\0").any? { |arg| arg == guest || arg.include?(guest + '/') || arg.include?(role) }
            rescue Errno::ENOENT, Errno::ESRCH
              # A process exiting while sampled does not prove historical completion.
            rescue StandardError
              unknown = true
            end
          end
          print(found ? 'present' : unknown ? 'unknown' : 'none_observed')
        rescue StandardError
          print 'unknown'
        end
      RUBY

      def merge_validation_reconcile_inspect(attempt_id:)
        unless attempt_id.is_a?(String) && StandardMergeValidation::VALIDATION_ID.match?(attempt_id)
          mv_error!("STANDARD_ARGUMENTS_INVALID")
        end
        report = { "version" => 1, "attempt_id" => attempt_id, "inspection" => "unproven",
          "reason" => "evidence_unproven", "evidence" => { "receipt" => "unknown", "journal" => "unknown" },
          "preparation" => "unproven", "runtime" => "unproven", "templates" => "unproven",
          "resources" => %w[source base role].to_h { |key| [key, { "presence" => "unknown", "identity" => "unproven" }] },
          "sessions" => "unknown", "guest_directory" => "unknown", "redis" => "unknown", "host_staging_directory" => "unknown",
          "current_guest_process" => "unknown", "historical_producer" => "unproven",
          "current_host_producer" => "unproven", "cleanup_authorized" => false,
          "reset_retires_validation_journal" => false, "next_action" => "review_legacy_reconciliation" }
        mv_saved_directory!(File.join(@store.root, "validations"))
        report["reason"] = "execution_lock_unavailable"
        @store.with_read_only_execution_locks do
          report["reason"] = "evidence_unproven"
          receipt, report["evidence"]["receipt"] = mv_saved_record(attempt_id, "json")
          journal, report["evidence"]["journal"] = mv_saved_record(attempt_id, "resources.json")
          return report unless receipt && journal
          return report unless journal["version"] == 1 && receipt["prepared_from"] == journal["prepared_from"] &&
            receipt["generation"] == journal["generation"] && receipt["templates"] == journal["templates"]
          report["reason"] = "preparation_binding_unproven"
          context = mv_reconcile_context!(journal)
          report["preparation"] = "matches_saved_generation"
          report["reason"] = "runtime_binding_unproven"
          binding = mv_runtime_snapshot!(context)
          # This is a NEW observation bound to the preparation record, never an
          # invented original runtime binding added to a legacy journal.
          context["lifecycle_journal"] = journal.merge("runtime_binding" => binding)
          report["runtime"] = "matches_current_preparation_record"
          report["reason"] = "read_only_observations"
          report["host_staging_directory"] = mv_reconcile_observe("unknown") do
            begin
              stat = File.lstat(File.join(@store.root, "validations", attempt_id))
              stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero? ? "present_private_directory" : "present_unproven"
            rescue Errno::ENOENT
              "absent"
            end
          end
          %w[source base role].each do |key|
            report["resources"][key] = mv_reconcile_observe(report["resources"][key]) do
              current = mv_resource_identity!(context, journal, key)
              { "presence" => current ? "present" : "absent",
                "identity" => mv_reconcile_identity(journal, key, current) }
            end
          end
          report["sessions"] = mv_reconcile_observe("unknown") do
            name = journal.fetch("role")
            sql = "SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND (datname IN ('#{journal.fetch('source')}','#{journal.fetch('base')}') OR usename='#{name}' OR application_name='silo_validation_#{attempt_id}');\n"
            output = mv_sql!(context, sql, max_seconds: 10).strip
            output == "0" ? "none_observed" : output.match?(/\A[1-9][0-9]*\z/) ? "present" : "unknown"
          end
          report["templates"] = mv_reconcile_observe("unproven") do
            mv_same_template_custody?(mv_custody!(context), journal["templates"]) ? "matches_saved_custody" : "differs_saved_custody"
          end
          if journal["guest_directory"]
            report["guest_directory"] = mv_reconcile_observe("unknown") do
              mv_runtime_verify!(context, context.fetch("lifecycle_journal"))
              current = mv_guest_identity!(context, context.fetch("lifecycle_journal"))
              if current == "absent"
                "absent"
              elsif !journal["guest_identity"]
                "present_identity_not_recorded"
              else
                current == journal["guest_identity"] ? "present_saved_identity_matches" : "present_saved_identity_differs"
              end
            end
            report["current_guest_process"] = mv_reconcile_observe("unknown") do
              mv_runtime_verify!(context, context.fetch("lifecycle_journal"))
              result = @runtime.run(["docker", "exec", binding.fetch("web_id"), "ruby", "-e", RECONCILE_PROCESS_SCAN,
                journal.fetch("guest_directory"), journal.fetch("role")], capture: true, timeout: mv_timeout(context, 10))
              value = result.stdout.to_s
              result.success? && %w[present none_observed unknown].include?(value) ? value : "unknown"
            end
          else
            report["guest_directory"] = "not_recorded"
          end
          report["redis"] = journal["redis"] ? mv_reconcile_observe("unknown") { mv_reconcile_redis!(context, journal) } : "not_recorded"
          # Recheck endpoints after the observations; external Docker operations
          # do not honor our cooperative execution locks.
          begin
            mv_runtime_verify!(context, context.fetch("lifecycle_journal"))
          rescue StandardError
            report["runtime"] = "unproven"
            report["reason"] = "runtime_changed_or_unproven"
            raise
          end
          unknown = report["resources"].values.any? { |value| value["presence"] == "unknown" } ||
            %w[sessions templates guest_directory redis host_staging_directory].any? { |key| %w[unknown unproven].include?(report[key]) } ||
            (journal["guest_directory"] && report["current_guest_process"] == "unknown")
          report["inspection"] = unknown ? "partial" : "observed"
        end
        report
      rescue StandardError
        # Do not echo exception text, class names, stderr, argv or saved records.
        # A transport failure is never projected as resource absence.
        report["inspection"] = "unproven" if report
        report || raise
      end

      private

      def mv_reconcile_context!(journal)
        run_id, generation = journal.values_at("prepared_from", "generation")
        mv_recovery_refuse! unless run_id.is_a?(String) && run_id.match?(/\Arun-[0-9a-f]{32}\z/) &&
          generation.is_a?(String) && StandardMergeValidation::VALIDATION_SHA.match?(generation)
        state = @store.load
        run = state.fetch("runs").fetch(run_id)
        environment = run.fetch("merge_environment")
        mv_recovery_refuse! unless run["status"] == "completed" && environment["generation"] == generation &&
          environment["preparation_run_id"] == run_id && environment["consumed_by"].nil? && environment["phase"] == "ready"
        mv_recovery_refuse! if state.fetch("runs").values.any? { |entry| %w[claimed running].include?(entry["status"]) }
        body = state.fetch("plans").fetch(run.fetch("plan_id")).fetch("body")
        mv_recovery_refuse! unless body["operation"] == "standard_merge_prepare"
        # Do not run the ordinary readiness check: it visits delivery/input
        # registries. This observer binds saved metadata; it cannot approve use.
        { "prepared_from" => run_id, "runtime_profile" => review_runtime_for(body), "deadline" => mv_clock + 120,
          "read_only_lifecycle" => true, "reconciliation_read_only" => true }
      end

      def mv_reconcile_observe(fallback)
        yield
      rescue StandardError
        fallback
      end

      def mv_reconcile_identity(journal, key, current)
        rows = journal["owned_identities"]
        return "not_recorded" unless rows.is_a?(Array)
        saved = rows.select { |row| row.is_a?(Array) && row.first == journal.fetch(key) }
        return "not_recorded" if saved.empty?
        return "unproven" unless saved.size == 1 && current
        # Legacy database rows stored the owner NAME, not its OID. Report only a
        # match of the fields actually saved, never complete v2 custody proof.
        comparison = key != "role" && saved.first.size == 3 ? [current.first.values_at(0, 1, 3)] : current
        saved == comparison ? "matches_saved_fields" : "differs_saved_fields"
      end

      def mv_reconcile_redis!(context, journal)
        result = @runtime.run(["docker", "container", "ls", "-aq", "--no-trunc", "--filter", "name=^/#{journal.fetch('redis')}$"], capture: true, timeout: mv_timeout(context, 10))
        mv_recovery_refuse! unless result.success?
        id = result.stdout.to_s.strip
        return "absent" if id.empty?
        mv_recovery_refuse! unless StandardMergeValidation::VALIDATION_SHA.match?(id)
        result = @runtime.run(["docker", "inspect", "--format", '{{.Id}}|{{index .Config.Labels "silo-migrate.validation"}}|{{index .Config.Labels "silo-migrate.managed"}}|{{.State.Running}}', id], capture: true, timeout: mv_timeout(context, 10))
        row = result.stdout.to_s.strip.split("|", -1)
        mv_recovery_refuse! unless result.success? && row.size == 4 && row[0] == id && %w[true false].include?(row[3])
        return "present_identity_not_recorded" unless journal["redis_id"]
        return "present_identity_mismatch" unless id == journal["redis_id"] && row[1..2] == [journal.fetch("id"), "true"]
        row[3] == "true" ? "present_saved_identity_running" : "present_saved_identity_stopped"
      end
    end
  end
end
