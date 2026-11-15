# frozen_string_literal: true

module SiloMigrate
  module Services
    # Version two is deliberately not a provisioning-resume protocol. A missing
    # identity after CREATE is ambiguous even when the generated name exists.
    module StandardMergeValidationLifecycle
      def merge_validation_recovery_preview(attempt_id:)
        @store.with_host_lock do
          @store.with_op_lock do
            _context, _journal, intent = mv_recovery_review!(attempt_id)
            { "version" => 1, "attempt_id" => attempt_id, "actions" => intent.fetch("actions"),
              "intent_sha256" => Digest::SHA256.hexdigest(JSON.generate(intent)) }
          end
        end
      end

      def merge_validation_recovery_apply(attempt_id:, intent_sha256:)
        @store.with_host_lock do
          @store.with_op_lock do
            mv_recovery_refuse! unless intent_sha256.is_a?(String) && StandardMergeValidation::VALIDATION_SHA.match?(intent_sha256)
            context, journal, intent = mv_recovery_review!(attempt_id)
            mv_recovery_refuse! unless Digest::SHA256.hexdigest(JSON.generate(intent)) == intent_sha256
            # Preserve the receipt and workflow exactly. Recovery has its own
            # evidence, not a rewritten validation result or fresh approval.
            mv_recovery_intent!(attempt_id, intent_sha256, intent)
            context.delete("read_only_lifecycle")
            mv_lifecycle_cleanup!(context, journal, recovery: true)
            mv_recovery_refuse! unless mv_same_template_custody?(mv_custody!(context), journal.fetch("templates"))
            journal.merge!("status" => "cleaned", "cleanup_confirmed" => true)
            mv_save_journal!(journal)
            result = { "version" => 1, "attempt_id" => attempt_id, "intent_sha256" => intent_sha256, "cleanup_confirmed" => true }
            mv_write!(mv_path(attempt_id, "recovery.json"), result)
            result
          end
        end
      end

      private

      def mv_recovery_refuse!
        mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED")
      end

      def mv_save_journal!(journal)
        mv_write!(mv_path(journal.fetch("id"), "resources.json"), journal)
      end

      def mv_runtime_snapshot!(context)
        with_review_runtime(context.fetch("runtime_profile")) do
          stack = stack_for(context.fetch("prepared_from"), "review")
          info = @runtime.run(["docker", "info", "--format", "{{.ID}}"], capture: true, timeout: mv_timeout(context, 15))
          mv_recovery_refuse! unless info.success? && info.stdout.to_s.strip.match?(/\A[A-Za-z0-9:._-]{8,128}\z/)
          record = stack.record
          instance = record.fetch("name")
          mv_recovery_refuse! unless instance.is_a?(String) && instance.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/)
          binding = { "daemon_id" => info.stdout.strip, "instance" => instance }
          %w[db web].each do |service|
            name = stack.container(service)
            recorded_id = record.fetch("containers").fetch(service)
            mv_recovery_refuse! unless recorded_id.is_a?(String) && StandardMergeValidation::VALIDATION_SHA.match?(recorded_id)
            result = @runtime.run(["docker", "inspect", "--format", '{{.Id}}|{{.State.Running}}|{{.State.StartedAt}}|{{index .Config.Labels "silo-migrate.managed"}}|{{index .Config.Labels "silo-migrate.instance"}}', name], capture: true, timeout: mv_timeout(context, 15))
            row = result.stdout.to_s.strip.split("|", -1)
            mv_recovery_refuse! unless result.success? && row.size == 5 && row[0] == recorded_id && row[1] == "true" && row[2].match?(/\A[0-9TZ:.+-]{10,64}\z/) && row[3..] == ["true", instance]
            binding["#{service}_id"] = row[0]
            binding["#{service}_started_at"] = row[2]
          end
          binding
        end
      end

      def mv_runtime_verify!(context, journal)
        mv_recovery_refuse! unless mv_runtime_snapshot!(context) == journal.fetch("runtime_binding")
      end

      def mv_lifecycle_start!(context, journal)
        mv_journal!(journal)
        # There is deliberately no provisioning resume or ownership replacement.
        mv_recovery_refuse! if journal.key?("resources") || journal.key?("runtime_binding")
        journal.merge!("version" => 2, "resources" => {}, "producers" => {},
          "producer_outcome" => "not_started", "work_status" => "running", "events" => [],
          "runtime_profile" => context.fetch("runtime_profile"), "runtime_binding" => mv_runtime_snapshot!(context))
        # Only the context points at the journal; never serialize context into it.
        context["lifecycle_journal"] = journal
        mv_save_journal!(journal)
      end

      def mv_executor_begin!(journal)
        journal["executor_mode"] = "opaque"
        mv_producer!(journal, "executor", "unknown")
      end

      def mv_executor_handoff!(journal)
        mv_recovery_refuse! unless journal["executor_mode"] == "opaque" && journal.dig("producers", "executor") == "unknown"
        # No opaque child has been launched. From this point the built-in must
        # journal each redis/copy/guest/auxiliary effect before invoking it. This
        # is a tracking handoff, NOT proof that this Ruby method has returned.
        journal["executor_mode"] = "builtin_tracked"
        mv_producer!(journal, "executor", "not_started", token: journal.fetch("producer_tokens").fetch("executor"))
      end

      # A new invocation cannot overwrite an unresolved older invocation. Only
      # the exact nonce returned by begin may resolve its own pending outcome.
      def mv_producer!(journal, kind, outcome, token: nil)
        mv_recovery_refuse! unless %w[sql executor guest redis guest_copy auxiliary].include?(kind) && %w[not_started completed unknown].include?(outcome)
        tokens = journal["producer_tokens"] ||= {}
        if outcome == "unknown" && token.nil?
          mv_recovery_refuse! if journal.fetch("producers")[kind] == "unknown"
          token = SecureRandom.hex(16)
          tokens[kind] = token
        else
          mv_recovery_refuse! unless token && tokens[kind] == token
        end
        journal.fetch("producers")[kind] = outcome
        values = journal.fetch("producers").values
        journal["producer_outcome"] = values.include?("unknown") ? "unknown" : values.include?("completed") ? "completed" : "not_started"
        mv_save_journal!(journal)
        token
      end

      def mv_work_outcome!(journal, result, diagnostic = nil)
        return unless journal["version"] == 2
        journal["work_stage"] = journal["last_stage"]
        journal["work_producer_outcome"] = journal["producer_outcome"]
        journal["work_status"] = result.is_a?(Hash) && result["status"] == "passed" ? "passed" : "refused"
        reason = diagnostic.is_a?(Hash) ? diagnostic["reason"] : result.is_a?(Hash) && result["reason"]
        allowed = %w[ok preflight_refused hooks_missing asset_selection_invalid audit_invalid checks_invalid assets_unproven validation_unproven] + StandardMergeValidation::VALIDATION_FAILURE_REASONS
        allowed += SiloMergeValidation::FINDING_CODES if defined?(SiloMergeValidation::FINDING_CODES)
        journal["primary_reason"] = allowed.include?(reason) ? reason : "STANDARD_MERGE_VALIDATION_UNPROVEN"
        mv_save_journal!(journal)
      end

      def mv_resource_identity!(context, journal, key)
        mv_journal!(journal)
        mv_recovery_refuse! unless %w[source base role].include?(key)
        name = journal.fetch(key)
        sql = if key == "role"
          "/* silo_validation_identity_role */ SELECT rolname, oid, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolbypassrls, rolreplication, rolcanlogin FROM pg_roles WHERE rolname='#{name}';\n"
        else
          "/* silo_validation_identity_#{key} */ SELECT datname, oid, datdba, pg_get_userbyid(datdba) FROM pg_database WHERE datname='#{name}';\n"
        end
        rows = mv_sql!(context, sql, step: "resource_identity").lines.map { |line| line.strip.split("|", -1) }
        return nil if rows.empty?
        row = rows.first
        valid = rows.size == 1 && row[0] == name && row[1].to_s.match?(/\A[1-9][0-9]*\z/) &&
          (key == "role" ? row.size == 9 && row[2..] == %w[f f f f f f t] : row.size == 4 && row[2].match?(/\A[1-9][0-9]*\z/) && row[3] == "postgres")
        mv_recovery_refuse! unless valid
        [row]
      end

      def mv_create_resource!(context, journal, key)
        record = journal.fetch("resources")[key] = { "intent" => "create", "outcome" => "unknown" }
        mv_save_journal!(journal)
        begin
          yield
        rescue StandardError
          # A known failed single CREATE may prove absence, but never ownership
          # of an unexpected present object. Unknown completion is quarantined.
          if journal.dig("producers", "sql") == "completed"
            record["outcome"] = "absent" if mv_resource_identity!(context.dup, journal, key).nil?
            mv_save_journal!(journal)
          end
          raise
        end
        identity = mv_resource_identity!(context, journal, key)
        mv_recovery_refuse! unless identity
        record.merge!("outcome" => "created", "identity" => identity)
        mv_save_journal!(journal)
      end

      def mv_completed_producers!(context, journal)
        mv_recovery_refuse! unless journal["version"] == 2 && journal["resources"].is_a?(Hash) && journal["producers"].is_a?(Hash) &&
          %w[completed not_started].include?(journal["producer_outcome"]) && journal["producers"].values.all? { |value| %w[completed not_started].include?(value) }
        mv_runtime_verify!(context, journal)
        # psql exiting is not by itself server-side completion proof. Every
        # lifecycle SQL connection has an exact-attempt application_name.
        active = mv_sql!(context, "/* silo_validation_producers */ SELECT count(*) FROM pg_stat_activity WHERE application_name='silo_validation_#{journal.fetch('id')}' AND pid <> pg_backend_pid();\n")
        mv_recovery_refuse! unless active.strip == "0"
      end

      def mv_resource_snapshot!(context, journal)
        %w[source base role].to_h do |key|
          record = journal.fetch("resources")[key]
          mv_recovery_refuse! unless record.is_a?(Hash) && %w[absent created deleted].include?(record["outcome"])
          current = mv_resource_identity!(context, journal, key)
          if current
            mv_recovery_refuse! unless record["outcome"] == "created" && current == record["identity"]
          else
            # Missing owned objects are safe only after producer completion has
            # been established. Never adopt a different object with the same name.
            mv_recovery_refuse! if record["outcome"] == "created" && !record["identity"].is_a?(Array)
          end
          [key, current]
        end
      end

      def mv_guest_identity!(context, journal)
        guest = journal.fetch("guest_directory")
        result = @runtime.run(["docker", "exec", journal.fetch("runtime_binding").fetch("web_id"), "sh", "-c", 'if [ ! -e "$1" ] && [ ! -L "$1" ]; then printf absent; else stat -c "%d:%i:%u:%F" -- "$1"; fi', "silo-validation-stat", guest], capture: true, timeout: mv_timeout(context, 15))
        value = result.stdout.to_s.strip
        mv_recovery_refuse! unless result.success? && (value == "absent" || value.match?(/\A[0-9]+:[1-9][0-9]*:[0-9]+:directory\z/))
        value
      end

      def mv_auxiliary_snapshot!(context, journal, recovery:)
        # The shipped executor synchronously removes host credentials in ensure.
        # Never certify cleanup (or recursively adopt a host directory) if that
        # removal failed. A leftover needs explicit private-file reconciliation.
        host = File.join(@store.root, "validations", journal.fetch("id"))
        mv_recovery_refuse! if File.exist?(host) || File.symlink?(host)
        snapshot = {}
        if journal["guest_directory"]
          mv_recovery_refuse! if journal.dig("producers", "guest") == "unknown" || journal.dig("producers", "guest_copy") == "unknown"
          current = mv_guest_identity!(context, journal)
          if current == "absent"
            snapshot["guest"] = "absent"
          else
            mv_recovery_refuse! unless journal["guest_identity"] && journal.dig("producers", "guest_copy") == "completed" && journal["guest_cleaned"] != true && current == journal["guest_identity"]
            snapshot["guest_identity"] = current
          end
        end
        if journal["redis"]
          # ls distinguishes a known absent sidecar from inspect transport errors.
          result = @runtime.run(["docker", "container", "ls", "-aq", "--no-trunc", "--filter", "name=^/#{journal.fetch('redis')}$"], capture: true, timeout: mv_timeout(context, 15))
          mv_recovery_refuse! unless result.success?
          id = result.stdout.to_s.strip
          if id.empty?
            mv_recovery_refuse! unless journal["redis_id"] || journal["redis_deleted"] == true || [nil, "not_started", "completed"].include?(journal.dig("producers", "redis"))
            snapshot["redis"] = "absent"
          else
            mv_recovery_refuse! unless journal["redis_deleted"] != true && id == journal["redis_id"] && StandardMergeValidation::VALIDATION_SHA.match?(id)
            inspected = @runtime.run(["docker", "inspect", "--format", '{{.Id}}|{{index .Config.Labels "silo-migrate.validation"}}|{{index .Config.Labels "silo-migrate.managed"}}|{{.State.Running}}', id], capture: true, timeout: mv_timeout(context, 15))
            row = inspected.stdout.to_s.strip.split("|")
            mv_recovery_refuse! unless inspected.success? && row.first(3) == [id, journal.fetch("id"), "true"] && %w[true false].include?(row[3]) && row.size == 4
            # Recovery never force-removes/stops a running container. An exact
            # owned but running Redis sidecar requires separately reviewed stop.
            mv_recovery_refuse! if recovery && row[3] != "false"
            snapshot["redis"] = row
          end
        end
        snapshot
      end

      def mv_recovery_dependencies!(context, journal, snapshot)
        names = %w[source base].map { |key| "'#{journal.fetch(key)}'" }.join(",")
        role_oid = snapshot["role"]&.first&.[](1)
        sql = "/* silo_validation_recovery_sessions */ SELECT count(*) FROM pg_stat_activity WHERE datname IN (#{names}) OR usename='#{journal.fetch('role')}';\n"
        # The random role must have no memberships or dependencies outside the
        # clones we are about to drop. Never CASCADE or terminate sessions.
        if role_oid
          sql += "SELECT count(*) FROM pg_auth_members WHERE roleid=#{role_oid} OR member=#{role_oid};\n"
          sql += "SELECT count(*) FROM pg_shdepend WHERE refclassid='pg_authid'::regclass AND refobjid=#{role_oid} AND NOT (dbid IN (SELECT oid FROM pg_database WHERE datname IN (#{names})) OR (dbid=0 AND classid='pg_database'::regclass AND objid IN (SELECT oid FROM pg_database WHERE datname IN (#{names}))));\n"
        end
        mv_recovery_refuse! unless mv_sql!(context, sql).lines.map(&:strip) == (role_oid ? %w[0 0 0] : %w[0])
      end

      def mv_lifecycle_cleanup!(context, journal, recovery:)
        context = context.dup if context.frozen?
        mv_step!(context, "cleanup_resources")
        mv_journal!(journal)
        context["lifecycle_journal"] = journal
        mv_completed_producers!(context, journal)
        snapshot = mv_resource_snapshot!(context, journal)
        auxiliary = mv_auxiliary_snapshot!(context, journal, recovery: recovery)
        mv_recovery_dependencies!(context, journal, snapshot) if recovery
        mv_recovery_refuse! unless mv_same_template_custody?(mv_custody!(context), journal.fetch("templates"))
        if auxiliary["guest_identity"]
          journal["guest_cleanup_intent"] = true
          mv_save_journal!(journal)
          mv_command!(["docker", "exec", journal.fetch("runtime_binding").fetch("web_id"), "rm", "-rf", "--", journal.fetch("guest_directory")], context: context)
          journal["guest_cleaned"] = true
          mv_save_journal!(journal)
        end
        if auxiliary["redis"].is_a?(Array)
          journal["redis_cleanup_intent"] = true
          mv_save_journal!(journal)
          mv_command!(["docker", "rm", *(recovery ? [] : ["-f"]), journal.fetch("redis_id")], context: context)
          journal["redis_deleted"] = true
          mv_save_journal!(journal)
        end
        %w[source base role].each do |key|
          record = journal.fetch("resources").fetch(key)
          unless snapshot[key]
            record["outcome"] = "deleted" if record["identity"]
            mv_save_journal!(journal)
            next
          end
          # Recheck immediately before each destructive effect, including IDs.
          mv_runtime_verify!(context, journal)
          mv_recovery_refuse! unless mv_resource_identity!(context, journal, key) == snapshot[key]
          mv_recovery_dependencies!(context, journal, mv_resource_snapshot!(context, journal)) if recovery
          record["intent"] = "delete"
          mv_save_journal!(journal)
          name = journal.fetch(key)
          sql = if key == "role"
            "DROP ROLE #{name};\n"
          else
            (recovery ? "" : "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='#{name}' AND pid <> pg_backend_pid();\n") + "DROP DATABASE #{name};\n"
          end
          mv_sql!(context, sql, step: "cleanup_#{key}")
          mv_recovery_refuse! unless mv_resource_identity!(context, journal, key).nil?
          record["outcome"] = "deleted"
          mv_save_journal!(journal)
        end
        remaining = mv_sql!(context, "SELECT count(*) FROM pg_database WHERE datname IN ('#{journal.fetch('source')}','#{journal.fetch('base')}');\nSELECT count(*) FROM pg_roles WHERE rolname='#{journal.fetch('role')}';\n", step: "cleanup_absence")
        mv_recovery_refuse! unless remaining.lines.map(&:strip) == %w[0 0]
        mv_auxiliary_snapshot!(context, journal, recovery: recovery)
        mv_completed_producers!(context, journal)
        mv_finish_stage!(context, "completed")
      end

      def mv_finish_stage!(context, outcome)
        journal = context["lifecycle_journal"]
        return unless journal && !context["read_only_lifecycle"]
        previous = journal.delete("active_stage")
        return unless previous
        elapsed = [[((mv_clock - previous.fetch("started")) * 1000).round, 0].max, 86_400_000].min
        journal["events"] = (journal.fetch("events", []) + [{ "step" => previous.fetch("step"), "phase" => "finish", "elapsed_ms" => elapsed, "outcome" => outcome }]).last(128)
        mv_save_journal!(journal)
      end

      def mv_recovery_directory!
        path = File.expand_path(File.join(@store.root, "validations"))
        current = path
        loop do
          stat = File.lstat(current)
          mv_recovery_refuse! unless stat.directory? && !stat.symlink?
          break if current == File.dirname(current)
          current = File.dirname(current)
        end
        stat = File.stat(path)
        mv_recovery_refuse! unless stat.uid == Process.uid && (stat.mode & 0o077).zero?
      end

      def mv_recovery_read!(path, limit)
        File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          stat = file.stat
          mv_recovery_refuse! unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= limit
          bytes = file.read(limit + 1)
          mv_recovery_refuse! unless bytes.bytesize <= limit
          bytes
        end
      end

      def mv_recovery_intent!(id, digest, intent)
        path = mv_path(id, "recovery-#{digest}.intent.json")
        bytes = JSON.generate(intent) + "\n"
        temporary = "#{path}.#{SecureRandom.hex(8)}.tmp"
        begin
          mv_raw_write!(temporary, bytes)
          begin
            File.link(temporary, path)
          rescue Errno::EEXIST
            # Never replace a reviewed intention, including after partial apply.
          end
          mv_recovery_refuse! unless mv_recovery_read!(path, 256 * 1024) == bytes
          File.open(File.dirname(path), File::RDONLY) { |directory| directory.fsync }
        ensure
          File.unlink(temporary) if File.exist?(temporary)
        end
      end

      def mv_recovery_review!(id)
        mv_recovery_refuse! unless id.is_a?(String) && StandardMergeValidation::VALIDATION_ID.match?(id)
        mv_recovery_directory!
        bytes = mv_recovery_read!(mv_path(id, "resources.json"), 256 * 1024)
        journal = JSON.parse(bytes)
        mv_journal!(journal)
        mv_recovery_refuse! unless journal["id"] == id && journal["version"] == 2 && journal["cleanup_confirmed"] == false
        receipt_bytes = mv_recovery_read!(mv_path(id, "json"), 4 * 1024 * 1024)
        receipt = JSON.parse(receipt_bytes)
        mv_recovery_refuse! unless receipt["receipt_id"] == id && receipt["prepared_from"] == journal["prepared_from"] && receipt["generation"] == journal["generation"] && receipt["cleanup_confirmed"] == false && receipt["status"] == "refused"
        state = @store.load
        run = state.fetch("runs").fetch(journal.fetch("prepared_from"))
        body = state.fetch("plans").fetch(run.fetch("plan_id")).fetch("body")
        environment = run["merge_environment"]
        mv_recovery_refuse! unless run["status"] == "completed" && environment.is_a?(Hash) && environment["consumed_by"].nil? && merge_environment_phase(state, environment) == "ready"
        mv_recovery_refuse! if state.fetch("runs").values.any? { |entry| %w[claimed running].include?(entry["status"]) }
        profile = review_runtime_for(body)
        mv_recovery_refuse! unless profile == journal.fetch("runtime_profile") && run.dig("merge_environment", "generation") == journal["generation"]
        context = { "prepared_from" => journal.fetch("prepared_from"), "runtime_profile" => profile,
          "deadline" => mv_clock + StandardMergeValidation::VALIDATION_CLEANUP_BUDGET, "lifecycle_journal" => journal, "read_only_lifecycle" => true }
        mv_completed_producers!(context, journal)
        resources = mv_resource_snapshot!(context, journal)
        auxiliary = mv_auxiliary_snapshot!(context, journal, recovery: true)
        mv_recovery_dependencies!(context, journal, resources)
        templates = mv_custody!(context)
        mv_recovery_refuse! unless mv_same_template_custody?(templates, journal.fetch("templates"))
        intent = { "version" => 1, "attempt_id" => id, "journal_sha256" => Digest::SHA256.hexdigest(bytes),
          "receipt_sha256" => Digest::SHA256.hexdigest(receipt_bytes), "runtime_binding" => journal.fetch("runtime_binding"),
          "resources" => resources, "auxiliary" => auxiliary,
          "templates" => templates.transform_values { |row| row.slice("oid", "owner") },
          "actions" => [*(auxiliary["guest_identity"] ? ["remove_proved_guest"] : []),
            *(auxiliary["redis"].is_a?(Array) ? ["remove_stopped_owned_redis"] : []),
            *%w[source base role].filter_map { |key| "drop_proved_#{key}" if resources[key] }] }
        [context, journal, intent]
      rescue KeyError, JSON::ParserError, SystemCallError, TypeError, NoMethodError, ArgumentError
        mv_recovery_refuse!
      end
    end
  end
end
