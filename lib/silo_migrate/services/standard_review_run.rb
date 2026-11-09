# frozen_string_literal: true

module SiloMigrate
  module Services
    # Review runs on real data (operation "standard_review"): a completed convert run's
    # intermediate database is imported with Discourse's generic bulk importer into one
    # local review site, which stays until the engineer resets the run.
    #
    # The site is the profile's prebuilt stack: web on an --internal network with no
    # route out, published only on 127.0.0.1, SMTP pointed at smtp.invalid and emails
    # disabled, plus login_required, so imported accounts can neither be mailed nor
    # browsed without the review admin's sign-in. The engineer opens it through an SSH
    # tunnel. Reconciliation adds a destination column, counted on the site's PostgreSQL
    # by a SELECT-only role in read-only transactions. Per-check numbers stay private;
    # public status shows totals, the review URL and the importer's issue count.
    #
    # Not included: uploads and avatars, backups, restore proof, hosted review, DNS.
    module StandardReviewRun
      REVIEW_OPERATION = "standard_review"
      REVIEW_STAGES = %w[preflight site_up site_setup import verify review_url].freeze
      REVIEW_ADMIN = "silo_review_admin"
      # The importer, its consistency pass and up to 10 minutes of waiting for background jobs.
      REVIEW_IMPORT_TIMEOUT = 12 * 3600
      DESTINATION_TIMEOUT = 1800
      DESTINATION_ROLE = "silo_count"
      # With the liveness check (10 s), the role step (30 s) and exec margin, the locked section
      # ends before the migration-data tool's control call gives up (285 s).
      ANALYST_COUNT_TIMEOUT = 230
      ANALYST_ROLE_TIMEOUT = 30
      # review_import.rb prints these only when Sidekiq and the scheduler stayed paused.
      REVIEW_IMPORT_MARKERS = [/^SILO_SIDEKIQ: paused=true running=0 \(before import\)$/, /^SILO_SIDEKIQ: paused=true \(after import\)$/].freeze
      RUN_ID = /\Arun-[0-9a-f]{32}\z/
      ISSUE_LOG = %r{\A/tmp/generic_bulk_import_issues_\d{8}_\d{6}\.log\z}
      # Sized per host when the plan is proposed (never below the profile's), bound by the digest.
      REVIEW_MAX_WEB_MIB = 6144
      REVIEW_MAX_DB_MIB = 4096
      REVIEW_MAX_CPUS = 2.0

      # -- planning -------------------------------------------------------------

      def propose_review_plan(from_run:, reconciliation: nil, port: nil, allow_unqualified_runtime: false)
        state = @store.load
        raise StandardWorkflowError, "STANDARD_SIZE_LIMIT" if state.fetch("plans").size >= self.class::MAX_PLANS
        raise StandardWorkflowError, "STANDARD_STALE_PLAN" unless profile_current?(state.fetch("config"))
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless from_run.is_a?(String) && from_run.match?(RUN_ID)
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless reconciliation.nil? || reconciliation.is_a?(String)

        qualified = lock.dig("qualification", "status") == "qualified"
        raise StandardWorkflowError, "STANDARD_RUNTIME_UNQUALIFIED" unless qualified || allow_unqualified_runtime

        source_run, source_plan = review_source!(state, from_run)
        artifact = review_artifact_binding!(from_run, source_run, hash: true)
        named = @store.named_state
        roles = {}
        recon_id = reconciliation || source_plan.dig("body", "roles", "reconciliation")
        if recon_id
          input = named.fetch("inputs")[recon_id] || raise(StandardWorkflowError, "STANDARD_REFERENCE_INVALID")
          raise StandardWorkflowError.new("STANDARD_INPUTS_INCOMPLETE", StandardConvertRun::RECONCILIATION_TYPE) unless input["type"] == StandardConvertRun::RECONCILIATION_TYPE
          raise StandardWorkflowError, "STANDARD_INPUT_CHANGED" unless inputs_unchanged?([input])

          reconciliation_spec(read_registered_small(input, StandardConvertRun::MAX_SPEC_BYTES))
          roles["reconciliation"] = recon_id
        end

        delivery = delivery_binding!(source_plan.dig("body", "dataset_id"))
        limits = review_limits
        review_capacity!(limits, running: false)
        review_port = select_review_port(state, port)
        plan_id = @store.new_id("plan")
        short = plan_id.delete_prefix("plan-")[0, 8]
        ids = roles.values
        source_body = source_plan.fetch("body")
        body = {
          "operation" => REVIEW_OPERATION,
          "workspace_id" => named.fetch("workspace_id"),
          "dataset_id" => source_body["dataset_id"],
          "delivery" => delivery,
          "platform" => source_body["platform"],
          "from_run" => { "run_id" => from_run, "plan_id" => source_plan.fetch("id"), "plan_digest" => source_plan.fetch("digest"),
                          "converter_revision" => source_body["converter_revision"] }.merge(artifact),
          "roles" => roles,
          "input_binding" => ids.map { |id| named.fetch("inputs").fetch(id).slice("id", "sha256", "bytes", "type") },
          "input_stat_binding" => @store.named.input_binding(named, ids),
          "code_identity" => code_identity,
          "runtime_lock_sha256" => state.dig("config", "discourse_profile_sha256"),
          "discourse_profile" => state.dig("config", "discourse_profile"),
          "runtime_qualified" => qualified, "allow_unqualified_runtime" => allow_unqualified_runtime,
          "image_content_ids" => lock.fetch("images").transform_values { |image| image.fetch("content_id") },
          "app_revision" => lock.dig("app", "revision"),
          "limits" => limits,
          "reconciliation_policy" => "report",
          "instances" => { "review" => { "name" => "silomig-#{short}-review", "hostname" => "127.0.0.1", "port" => review_port } },
          "outputs" => {},
          "mutations" => [
            "create one local review site (loopback port #{review_port}, no outbound network, emails disabled, login required) with its own networks and volumes",
            "create the review admin account (its password is shown only to the engineer)",
            "import #{from_run}'s intermediate database with the generic bulk importer and its consistency pass, with background jobs paused",
            roles["reconciliation"] ? "count each reconciliation check on the intermediate database and, where it has destination_sql, on the site (report only)" : "no reconciliation checks",
            "keep the site running until the engineer resets this run"
          ],
          "not_included" => ["uploads and avatars", "backups", "restore proof", "hosted review", "DNS or cutover", "remote pushes"]
        }
        digest = Digest::SHA256.hexdigest(canonical_json(body))
        @store.update do |current|
          current.fetch("plans")[plan_id] = {
            "id" => plan_id, "digest" => digest, "body" => body, "status" => "proposed", "created_at" => now, "approval" => nil, "run_id" => nil
          }
        end
        show_plan(plan_id)
      end

      # Engineer only (the Runs widget, behind the web UI sign-in): the review admin's
      # sign-in while its site exists.
      def admin_password(run_id)
        state = @store.load
        run = state.fetch("runs")[run_id]
        raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless run
        raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" unless review_plan?(state.fetch("plans").fetch(run.fetch("plan_id"), {}))

        record = state.fetch("instances")[run.dig("instances", "review").to_s]
        path = @store.run_dir(run_id, "private", "admin-password")
        unless record && record["state"] != "removed" && File.file?(path) && !File.symlink?(path)
          raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID"
        end

        { version: 1, run_id: run_id, username: REVIEW_ADMIN, password: File.read(path).strip, review_url: "http://127.0.0.1:#{record.fetch('port')}" }
      end

      # Trusted analyst path (migration-data): one count, as reconciliation does it, on a run's
      # intermediate database (a convert run's own, or the one a review run imported) or on a
      # review run's live site. The number is private; nothing is recorded.
      def analyst_count(run_id, side:, sql:)
        state = @store.load
        run = state.fetch("runs")[run_id]
        raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless run

        plan = state.fetch("plans").fetch(run.fetch("plan_id"), {})
        case side
        when "intermediate"
          raise StandardWorkflowError, "STANDARD_RECONCILIATION_INVALID" unless count_sql?(sql, intermediate: true)

          source = review_plan?(plan) ? plan.dig("body", "from_run", "run_id") : run_id
          source_run = state.fetch("runs")[source]
          unless (convert_plan?(plan) || review_plan?(plan)) && source_run&.dig("artifacts", "intermediate")
            raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID"
          end

          binding = review_artifact_binding!(source, source_run, hash: false)
          # A review run counts the very file it imported (stat identity bound by its plan).
          if review_plan?(plan) && binding != plan.dig("body", "from_run").slice("intermediate_sha256", "intermediate_bytes", "intermediate_stat")
            raise StandardWorkflowError.new("STANDARD_REVIEW_SOURCE_INVALID", "artifact changed")
          end
          count, error = intermediate_count(review_artifact_path(source), sql, timeout: ANALYST_COUNT_TIMEOUT)
        when "destination"
          raise StandardWorkflowError, "STANDARD_RECONCILIATION_INVALID" unless count_sql?(sql, destination: true)

          raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" unless review_plan?(plan)

          @store.with_op_lock do
            # Checked again under the lock: a reset may have removed the site meanwhile.
            current = @store.load
            record = current.fetch("instances")[current.dig("runs", run_id, "instances", "review").to_s]
            raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" unless record && %w[imported review dirty].include?(record["state"])

            stack = stack_for(run_id, "review")
            raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" unless stack.live?

            prepared = destination_role!(stack, timeout: ANALYST_ROLE_TIMEOUT)
            count, error = prepared ? destination_count(stack, sql, timeout: ANALYST_COUNT_TIMEOUT, margin: 5) : [nil, "query failed: count role unavailable"]
          end
        else
          raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID"
        end
        { version: 1, run_id: run_id, side: side, count: count, error: error }
      end

      private

      def review_plan?(plan)
        plan.dig("body", "operation") == REVIEW_OPERATION
      end

      def review_source!(state, from_run)
        run = state.fetch("runs")[from_run]
        plan = run && state.fetch("plans")[run["plan_id"]]
        unless run && plan && convert_plan?(plan) && run["status"] == "completed" && run.dig("artifacts", "intermediate")
          raise StandardWorkflowError.new("STANDARD_REVIEW_SOURCE_INVALID", "not a completed convert run")
        end

        [run, plan]
      end

      def review_artifact_path(run_id)
        @store.run_dir(run_id, "artifacts", "intermediate.sqlite")
      end

      # The recorded identity of the convert run's artifact, plus its stat identity for
      # cheap staleness checks; `hash: true` also reads the bytes.
      def review_artifact_binding!(run_id, run, hash:)
        recorded = run.dig("artifacts", "intermediate")
        path = review_artifact_path(run_id)
        stat = File.lstat(path)
        raise StandardWorkflowError.new("STANDARD_REVIEW_SOURCE_INVALID", "artifact") unless stat.file? && stat.size == recorded["bytes"]
        if hash && Digest::SHA256.file(path).hexdigest != recorded["sha256"]
          raise StandardWorkflowError.new("STANDARD_REVIEW_SOURCE_INVALID", "artifact changed")
        end

        { "intermediate_sha256" => recorded.fetch("sha256"), "intermediate_bytes" => recorded.fetch("bytes"),
          "intermediate_stat" => [stat.ino, stat.mtime.to_i, stat.mtime.nsec, stat.size] }
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise StandardWorkflowError.new("STANDARD_REVIEW_SOURCE_INVALID", "artifact missing")
      end

      def review_stale_reason(plan, state)
        body = plan.fetch("body")
        named = @store.named_state
        ids = body.fetch("input_binding").map { |input| input["id"] }
        return "inputs" unless ids.all? { |id| named.fetch("inputs").key?(id) }
        return "inputs" unless @store.named.input_binding(named, ids) == body.fetch("input_stat_binding")
        return "inputs" unless inputs_unchanged?(ids.map { |id| named.fetch("inputs").fetch(id) })
        return "code" unless code_identity == body.fetch("code_identity")
        return "runtime" unless profile_current?(state.fetch("config")) && state.dig("config", "discourse_profile_sha256") == body.fetch("runtime_lock_sha256")

        source = body.fetch("from_run")
        run = state.fetch("runs")[source.fetch("run_id")]
        return "from_run" unless run && run["status"] == "completed" && run["plan_id"] == source.fetch("plan_id")
        return "from_run" unless review_artifact_binding!(source.fetch("run_id"), run, hash: false) == source.slice("intermediate_sha256", "intermediate_bytes", "intermediate_stat")

        nil
      rescue StandardWorkflowError
        "from_run"
      end

      def review_limits
        host_cpus, host_memory = host_capacity
        base = lock.dig("limits", "stack")
        sized = lambda do |role, cpus, memory|
          entry = base.fetch(role)
          { "cpus" => [entry.fetch("cpus"), cpus].max.round(2), "memory_mib" => [entry.fetch("memory_mib"), memory].max, "pids" => entry.fetch("pids") }
        end
        { "web" => sized.call("web", [REVIEW_MAX_CPUS, host_cpus / 2.0].min, [REVIEW_MAX_WEB_MIB, host_memory / 4].min),
          "db" => sized.call("db", [REVIEW_MAX_CPUS, host_cpus / 4.0].min, [REVIEW_MAX_DB_MIB, host_memory / 8].min),
          "redis" => base.fetch("redis").slice("cpus", "memory_mib", "pids"), "proxy" => base.fetch("proxy").slice("cpus", "memory_mib", "pids") }
      end

      # Memory caps of this site plus those of running managed containers must fit in
      # three quarters of the host's memory; each CPU quota must exist on this host. At
      # proposal only the site itself must fit: running ones may be reset before the start.
      def review_capacity!(limits, running: true)
        used_memory = running ? measured_usage.last : 0
        host_cpus, host_memory = host_capacity
        if limits.values.any? { |limit| limit["cpus"] > host_cpus } || used_memory + limits.values.sum { |limit| limit["memory_mib"] } > host_memory * 3 / 4
          raise StandardWorkflowError.new("STANDARD_CAPACITY", "reset an earlier run's retained instances first")
        end
      end

      def select_review_port(state, requested)
        low, high = lock.dig("limits", "ports")
        reserved = state.fetch("instances").values.reject { |record| record["state"] == "removed" }.map { |record| record["port"] } +
                   state.fetch("plans").values.select { |plan| %w[proposed approved].include?(plan["status"]) }.flat_map { |plan| (plan.dig("body", "instances") || {}).values.map { |target| target["port"] } }
        if requested
          raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless requested.is_a?(Integer) && requested.between?(low, high)
          raise StandardWorkflowError, "STANDARD_PORT_OCCUPIED" if reserved.include?(requested) || !@port_probe.call(requested)

          return requested
        end
        (low..high).find { |candidate| !reserved.include?(candidate) && @port_probe.call(candidate) } || raise(StandardWorkflowError, "STANDARD_PORT_OCCUPIED")
      end

      # -- stages -------------------------------------------------------------------

      def review_preflight(run_id, plan)
        body = plan.fetch("body")
        resolved = lock.fetch("images").transform_values { |image| ImageIdentity.resolve(@runtime, image) }
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("artifacts")["resolved_image_ids"] = resolved }
        evidence(run_id, "runtime-images.json", JSON.pretty_generate(resolved) + "\n")
        source = body.fetch("from_run")
        run = @store.load.fetch("runs").fetch(source.fetch("run_id"))
        unless review_artifact_binding!(source.fetch("run_id"), run, hash: true) == source.slice("intermediate_sha256", "intermediate_bytes", "intermediate_stat")
          raise StandardWorkflowError.new("STANDARD_REVIEW_SOURCE_INVALID", "artifact changed")
        end

        manifest = materialize_inputs(run_id, body, @store.named_state, layout: false)
        manifest.each { |input| input["role"] = body.fetch("roles").key(input.fetch("id")) }
        @store.write_private(@store.run_dir(run_id, "work", "inputs.json"), JSON.pretty_generate(manifest) + "\n")
        snapshot_helpers(run_id)
        # The site's database grows from the imported data: refuse early without room for
        # several copies of it.
        disk_headroom!(4 * source.fetch("intermediate_bytes"))
      rescue NamedError => error
        raise StandardWorkflowError.new("STANDARD_INPUT_CHANGED", error.message)
      end

      def review_site_setup(run_id)
        stack = stack_for(run_id, "review")
        secrets = @store.run_dir(run_id, "private", "review-setup.env")
        FileUtils.rm_f(secrets)
        password = SecureRandom.urlsafe_base64(24)
        @store.write_private(@store.run_dir(run_id, "private", "admin-password"), password)
        @store.write_private(secrets, "SILO_ADMIN_PASSWORD=#{password}\n")
        port = stack.record.fetch("port")
        result = begin
          stack.rails_runner("/tmp/review_setup.rb", env: { "SILO_SITE_PORT" => port.to_s }, env_file: secrets)
        ensure
          FileUtils.rm_f(secrets)
        end
        evidence(run_id, "review-setup.json", result)
        failures = []
        failures << "review-base-url" unless result["base_url"] == "http://127.0.0.1:#{port}"
        failures << "review-admin-missing" unless result["admin_username"] == REVIEW_ADMIN
        failures << "review-email-not-disabled" unless result["disable_emails"] == "yes"
        failures << "review-login-not-required" unless result["login_required"] == true
        failures << "review-restore-enabled" unless result["allow_restore"] == false
        assert_clean!(run_id, "review_setup", failures, "STANDARD_RUNNER_FAILED")
        set_instance_state(stack, "setup")
      end

      def review_import(run_id, plan)
        stack = stack_for(run_id, "review")
        source = plan.dig("body", "from_run")
        artifact = review_artifact_path(source.fetch("run_id"))
        run = @store.load.fetch("runs").fetch(source.fetch("run_id"))
        unless review_artifact_binding!(source.fetch("run_id"), run, hash: true) == source.slice("intermediate_sha256", "intermediate_bytes", "intermediate_stat")
          raise StandardWorkflowError.new("STANDARD_REVIEW_SOURCE_INVALID", "artifact changed")
        end

        prepared = stack.web_exec(["sh", "-c", "mkdir -p /shared/import && chown discourse:discourse /shared/import"], timeout: 30)
        raise StandardWorkflowError.new("STANDARD_IMPORT_FAILED", "import folder") unless prepared.success?

        stack.copy_in(artifact, "/shared/import/intermediate.sqlite")
        # generic_bulk through review_import.rb, which holds a Sidekiq pause for the whole import
        # including the importer's own import:ensure_consistency (background jobs deadlocked
        # its bulk UPDATEs on arc). No uploads database: no uploads (deferred this slice).
        result = stack.discourse_shell(["bundle", "exec", "ruby", "/tmp/review_import.rb", "/shared/import/intermediate.sqlite"],
                                       timeout: REVIEW_IMPORT_TIMEOUT)
        log(run_id, "import", result)
        raise StandardWorkflowError.new("STANDARD_IMPORT_FAILED", review_import_failure(result)) unless result.success?
        unless REVIEW_IMPORT_MARKERS.all? { |marker| result.stdout.to_s.b.match?(marker) }
          raise StandardWorkflowError.new("STANDARD_IMPORT_FAILED", "sidekiq not paused")
        end

        report = review_import_report(result.stdout.to_s)
        raise StandardWorkflowError.new("STANDARD_IMPORT_FAILED", "no completion line") unless report

        if report[:log]
          begin
            stack.copy_out(report[:log], @store.run_dir(run_id, "private", "import-issues.log"))
          rescue StandardWorkflowError
            nil # the counts are in the import log; the details file is a convenience
          end
        end
        record_results(run_id, import_issues: report[:issues])
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("results")["import_issue_counts"] = report[:counts] }
        set_instance_state(stack, "imported")
      end

      # Private detail: the wrapper's fixed refusal reason, or where the importer stopped.
      def review_import_failure(result)
        refused = result.stderr.to_s.b[/REVIEW_IMPORT_REFUSED: ([A-Za-z ]{1,60})/, 1]
        return "refused: #{refused}" if refused
        return "after the completion line (consistency pass or directory refresh)" if result.stdout.to_s.b.match?(/^Done! \(\d+ minutes\)$/)

        "importer exit"
      end

      # Real data has issues (e.g. a post with null bytes): they are counted and kept for
      # review rather than failing the run. Only the importer's completion line is required.
      def review_import_report(text)
        return nil unless text.match?(/^Done! \(\d+ minutes\)$/)

        counts = {}
        log = nil
        if (section = text.split(/^Import issues \(details in /, 2)[1])
          path, rest = section.split(/\):[ \t]*\r?\n/, 2)
          log = path if path.to_s.match?(ISSUE_LOG)
          rest.to_s.each_line do |line|
            break unless (match = line.match(/\A  (.{1,200}): (\d+)\s*\z/))

            counts[match[1]] = match[2].to_i
          end
          counts = { "unparsed" => 1 } if counts.empty?
        end
        { issues: counts.values.sum, counts: counts, log: log }
      end

      def review_verify(run_id, plan)
        stack = stack_for(run_id, "review")
        failures = review_safety_failures(stack)
        assert_clean!(run_id, "review_site", failures, "STANDARD_VERIFY_FAILED")
        review_reconcile(run_id, plan, stack)
        set_instance_state(stack, "review")
      end

      # Over the published loopback port, as the engineer's tunnel will reach it: the site
      # answers, and an anonymous visitor gets no topic list (login required).
      def review_url_check(run_id)
        stack = stack_for(run_id, "review")
        base = "http://127.0.0.1:#{stack.record.fetch('port')}"
        failures = []
        failures << "review-site-unreachable" unless @http.call("#{base}/srv/status", 1000)[:status] == 200
        latest = @http.call("#{base}/latest.json", 200_000)
        listed = begin
          parsed = JSON.parse(latest[:body])
          parsed.is_a?(Hash) && parsed.key?("topic_list")
        rescue JSON::ParserError
          false
        end
        failures << "review-site-public" if latest[:status] == 200 && listed
        assert_clean!(run_id, "review_url", failures, "STANDARD_VERIFY_FAILED")
        record_results(run_id, review_url: base)
      end

      # Read straight from the database, after the import and its consistency pass.
      def review_safety_failures(stack)
        result = stack.db_query("SELECT name || '=' || value FROM site_settings WHERE name IN ('disable_emails', 'login_required', 'allow_restore') ORDER BY name", timeout: 60)
        return ["review-settings-unreadable"] unless result.success?

        settings = result.stdout.to_s.lines.to_h { |line| line.strip.split("=", 2) }
        # The stack's DISCOURSE_DISABLE_EMAILS=yes shadows the site setting, so normally
        # no row is stored; a stored value must not say otherwise.
        environment = stack.web_exec(%w[printenv DISCOURSE_DISABLE_EMAILS], timeout: 30)
        failures = []
        unless environment.success? && environment.stdout.to_s.strip == "yes" && [nil, "yes"].include?(settings["disable_emails"])
          failures << "review-email-not-disabled"
        end
        failures << "review-login-not-required" unless settings["login_required"] == "t"
        failures << "review-restore-enabled" if settings["allow_restore"] == "t"
        failures
      end

      def review_reconcile(run_id, plan, stack)
        inputs = run_inputs(run_id)
        spec_input = role_input(inputs, "reconciliation")
        unless spec_input
          evidence(run_id, "reconciliation.json", { "policy" => "report", "checks" => [] })
          record_results(run_id, reconciliation_checks: 0, reconciliation_matched: 0, reconciliation_differs: 0, reconciliation_errors: 0)
          return
        end

        checks = reconciliation_spec(File.binread(input_path(run_id, spec_input)))
        source_run = plan.dig("body", "from_run", "run_id")
        measured = convert_source_counts(source_run)
        artifact = review_artifact_path(source_run)
        prepared = checks.any? { |check| check["destination_sql"] } && destination_role!(stack)
        rows = checks.map do |check|
          entry = measured[[check["name"], check["source_sql"]]]
          intermediate, intermediate_error = intermediate_count(artifact, check.fetch("intermediate_sql"))
          destination, destination_error = if check["destination_sql"].nil? then [nil, nil]
                                           elsif prepared then destination_count(stack, check["destination_sql"])
                                           else [nil, "query failed: count role unavailable"]
                                           end
          problem = if entry.nil? then "source: not measured by the convert run (name and source_sql must match it exactly)"
                    elsif entry["error"] then "source: #{entry['error']}"
                    elsif intermediate_error then "intermediate: #{intermediate_error}"
                    elsif destination_error then "destination: #{destination_error}"
                    end
          values = [entry&.fetch("count", nil), intermediate, destination].compact
          status = if problem then "error"
                   elsif check["expect"] == "report" then "reported"
                   elsif values.uniq.size == 1 then "matched"
                   else "differs"
                   end
          { "name" => check["name"], "expect" => check["expect"], "source" => entry&.fetch("count", nil), "intermediate" => intermediate, "destination" => destination,
            "difference" => entry&.fetch("count", nil) && intermediate ? intermediate - entry["count"] : nil,
            "destination_difference" => destination && intermediate ? destination - intermediate : nil,
            "status" => status, "error" => problem, "note" => check["note"] }
        end
        evidence(run_id, "reconciliation.json", { "policy" => "report", "checks" => rows })
        record_results(run_id, reconciliation: rows, reconciliation_checks: rows.size,
                       reconciliation_matched: rows.count { |row| row["status"] == "matched" },
                       reconciliation_differs: rows.count { |row| row["status"] == "differs" },
                       reconciliation_errors: rows.count { |row| row["status"] == "error" })
      end

      # The convert run measured the source before its database was deleted: reuse a count
      # only for the check with the same name and byte-identical source_sql.
      def convert_source_counts(run_id)
        counts = JSON.parse(File.read(@store.run_dir(run_id, "private", "source-counts.json"))).to_h { |entry| [entry["name"], entry] }
        spec_input = role_input(run_inputs(run_id), "reconciliation")
        return {} unless spec_input

        reconciliation_spec(File.binread(input_path(run_id, spec_input))).each_with_object({}) do |check, result|
          result[[check["name"], check["source_sql"]]] = counts[check["name"]] if counts.key?(check["name"])
        end
      rescue Errno::ENOENT, JSON::ParserError
        {}
      end

      # A login role that can only read: SELECT on the public schema's tables, read-only
      # transactions and a statement timeout as role defaults. Created after the import.
      def destination_role!(stack, timeout: 120)
        sql = <<~SQL
          DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{DESTINATION_ROLE}') THEN
              CREATE ROLE #{DESTINATION_ROLE} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION;
            END IF;
          END $$;
          REVOKE ALL ON DATABASE discourse FROM #{DESTINATION_ROLE};
          GRANT CONNECT ON DATABASE discourse TO #{DESTINATION_ROLE};
          GRANT USAGE ON SCHEMA public TO #{DESTINATION_ROLE};
          GRANT SELECT ON ALL TABLES IN SCHEMA public TO #{DESTINATION_ROLE};
          ALTER ROLE #{DESTINATION_ROLE} SET default_transaction_read_only = on;
          ALTER ROLE #{DESTINATION_ROLE} SET statement_timeout = '#{DESTINATION_TIMEOUT}s';
          ALTER ROLE #{DESTINATION_ROLE} CONNECTION LIMIT 2;
          DO $$ DECLARE target text; BEGIN
            FOREACH target IN ARRAY ARRAY['api_keys', 'user_api_keys', 'user_api_key_clients', 'user_auth_tokens', 'user_auth_token_logs',
                                        'email_tokens', 'user_second_factors', 'user_security_keys', 'user_passwords', 'oauth2_user_infos'] LOOP
              IF to_regclass('public.' || target) IS NOT NULL THEN
                EXECUTE format('REVOKE ALL ON %I FROM #{DESTINATION_ROLE}', target);
              END IF;
            END LOOP;
          END $$;
        SQL
        @runtime.run(["docker", "exec", "-i", stack.container("db"), "psql", "-X", "-q", "-U", "postgres", "-d", "discourse", "-v", "ON_ERROR_STOP=1"],
                     capture: true, timeout: timeout, stdin_data: sql).success?
      end

      # One count, as the read-only role, inside a scalar subquery: one value at most. An
      # error keeps only its SQLSTATE: PostgreSQL messages can quote values.
      def destination_count(stack, sql, timeout: DESTINATION_TIMEOUT, margin: 60)
        body = sql.strip.sub(/;\z/, "")
        script = "BEGIN TRANSACTION READ ONLY;\nSET LOCAL statement_timeout = '#{timeout.to_i}s';\nSELECT (#{body});\nROLLBACK;\n"
        result = @runtime.run(["docker", "exec", "-i", stack.container("db"), "psql", "-X", "-q", "-A", "-t", "-U", DESTINATION_ROLE, "-d", "discourse",
                               "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=sqlstate"],
                              capture: true, timeout: timeout + margin, stdin_data: script)
        unless result.success?
          state = result.stderr.to_s.b[/ERROR:\s+([0-9A-Z]{5})\b/, 1]
          return [nil, state ? "query failed: SQLSTATE #{state}" : "query failed"]
        end

        value = single_count(result.stdout.to_s)
        value ? [value, nil] : [nil, "not a single count"]
      end
    end
  end
end
