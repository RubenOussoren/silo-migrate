# frozen_string_literal: true

require "securerandom"

module SiloMigrate
  module Services
    # Prepared Discourse merge: one approved "prepare" run restores Base and loads the source in
    # one pinned stack, proves compatibility, seals both databases and exposes disposable
    # inspection clones. A later, separately approved merge consumes exactly one environment
    # generation: it fences inspection, drops the clones, returns the sealed databases to their
    # working names and only then constructs the merger.
    #
    # Database names inside the stack:
    #   silo_clean_base      sealed prepared Base (no connections allowed while inspecting)
    #   discourse            Base inspection clone the app runs on (renamed back from clean at merge)
    #   merge_source         sealed prepared source (no connections allowed while inspecting)
    #   silo_inspect_source  source inspection clone (DBHub read role)
    #
    # The environment record lives on the preparation run (run["merge_environment"]) and is
    # mirrored as {preparation_run_id, generation, phase} on the consuming merge run. Credentials
    # are never part of it: see StandardMergeInspection for the private access manifest.
    module StandardMergePreparation
      PREPARE_OPERATION = "standard_merge_prepare"
      PREPARE_STAGES = %w[preflight site_up base_restore source_load compatibility checkpoint inspection].freeze
      PREPARED_MERGE_STAGES = %w[preflight activate merge finalize verify backup site_setup review_url result_inspection].freeze
      MERGE_INTENTS = %w[stock custom].freeze
      MERGE_GENERATION = /\A[0-9a-f]{64}\z/
      MERGE_CLEAN_BASE_DB = "silo_clean_base"
      MERGE_BASE_DB = "discourse"
      MERGE_CLEAN_SOURCE_DB = "merge_source"
      MERGE_INSPECT_SOURCE_DB = "silo_inspect_source"
      # Engine/metadata bookkeeping no merge is expected to carry; every other source table the
      # pinned merger never names is counted as unhandled.
      MERGE_BOOKKEEPING_TABLES = %w[ar_internal_metadata backup_metadata schema_migration_details schema_migrations].freeze
      MERGE_NOT_CARRIED = "source tables and columns the pinned merger does not copy (plugin or custom data included): counted as unhandled in the compatibility evidence, never implied carried"
      # preparing -> checkpointing -> inspection -> ready -> consumed -> fencing -> merging -> result
      # plus dirty (uncertain, reset required), reset, and the computed "stale" for a ready
      # environment whose inputs or runtime changed.
      MERGE_ENVIRONMENT_PHASES = %w[preparing checkpointing inspection ready consumed fencing merging result dirty reset].freeze
      MERGE_SEAL_SQL = <<~SQL.tr("\n", " ").strip
        /* silo_seal */ SELECT
        (SELECT md5(COALESCE(string_agg(table_schema || '.' || table_name || '.' || column_name || ':' || data_type || ':' || COALESCE(udt_name, ''), ',' ORDER BY table_schema, table_name, column_name), '')) FROM information_schema.columns WHERE table_schema NOT IN ('pg_catalog', 'information_schema'))
        || '|' || (SELECT md5(COALESCE(string_agg(version, ',' ORDER BY version), '')) || ':' || COUNT(*) FROM schema_migrations)
        || '|' || (SELECT COUNT(*) FROM users) || ',' || (SELECT COUNT(*) FROM topics) || ',' || (SELECT COUNT(*) FROM posts) || ',' || (SELECT COUNT(*) FROM categories)
        || ',' || (SELECT COUNT(*) FROM groups) || ',' || (SELECT COUNT(*) FROM tags) || ',' || (SELECT COUNT(*) FROM uploads)
        || '|' || (SELECT COALESCE(MAX(id), 0) FROM users) || ',' || (SELECT COALESCE(MAX(id), 0) FROM topics) || ',' || (SELECT COALESCE(MAX(id), 0) FROM posts) || ',' || (SELECT COALESCE(MAX(id), 0) FROM uploads)
      SQL
      MERGE_SEAL = /\A[0-9a-f]{32}\|[0-9a-f]{32}:\d{1,9}\|\d{1,12}(?:,\d{1,12}){6}\|\d{1,18}(?:,\d{1,18}){3}\z/
      # Unicorn and every Sidekiq process (forked by unicorn in this image, or its own service)
      # must be gone before a database is sealed, cloned, dropped or renamed.
      #
      # This script's own command line names the services, as do its parents' and children's,
      # and app-server titles carry request paths: a Sidekiq process is therefore never found by
      # a command-line substring search. It is a live process of the verified service user,
      # outside this shell's own ancestors and descendants, whose launch form is Sidekiq's: the
      # program (or title) is "sidekiq" ("sidekiq 7.3.9 discourse [0 of 5 busy]", ".../bin/sidekiq
      # -q ..."), the pinned image's demon title "discourse sidekiq", or ruby/bundle launching
      # that program ("ruby .../bin/sidekiq", "bundle exec sidekiq"). Other arguments never count.
      # A zombie holds no connection and cannot write, so it is counted, not waited for.
      #
      # Drain: TERM (Sidekiq's graceful shutdown; the image uses -t 5 plus a 10 s demon stop)
      # once, again every 10 s, for at most MERGE_QUIESCE_GRACE seconds. Each signal re-checks
      # the PID's owner and launch form first (PID reuse). Nothing is ever KILLed: workers still
      # alive at the deadline fail (exit 2). A missing tool or unreadable process table refuses
      # (exit 4) instead of assuming nothing is running. Exit codes 1-4 and the final
      # SILO_QUIESCED are unchanged; one "SILO_QUIESCE reason=..." line carries a fixed reason
      # and counts only (never process arguments).
      MERGE_QUIESCE_GRACE = 60
      MERGE_SERVICE_STOP_WAIT = 30
      MERGE_QUIESCE_DIAGNOSTIC = /\ASILO_QUIESCE reason=(?:quiesced|stop_failed|workers_remain|app_server_not_down|no_service_user|no_ps|no_sv|process_table_unreadable) workers=\d{1,6} zombies=\d{1,6} stopped=\d{1,6} signalled=\d{1,6} waited=\d{1,6}s grace=\d{1,6}s\z/
      MERGE_QUIESCE_SCRIPT = (<<~SH + <<~'SH').freeze
        set -f
        grace=#{MERGE_QUIESCE_GRACE}
        stop_wait=#{MERGE_SERVICE_STOP_WAIT}
        case "${SILO_QUIESCE_GRACE:-}" in ''|*[!0-9]*) ;; *) [ "$SILO_QUIESCE_GRACE" -ge 1 ] && [ "$SILO_QUIESCE_GRACE" -le #{MERGE_QUIESCE_GRACE} ] && grace=$SILO_QUIESCE_GRACE ;; esac
      SH
        count=0; zombies=0; stopped=0; signalled=0; waited=0
        report() { echo "SILO_QUIESCE reason=$1 workers=$count zombies=$zombies stopped=$stopped signalled=$signalled waited=${waited}s grace=${grace}s"; }
        service_uid=$(id -u discourse 2>/dev/null) || { report no_service_user; exit 4; }
        case "$service_uid" in ''|0|*[!0-9]*) report no_service_user; exit 4 ;; esac
        command -v ps >/dev/null 2>&1 || { report no_ps; exit 4; }
        command -v sv >/dev/null 2>&1 || { report no_sv; exit 4; }
        self=$$

        # $@: one process's arguments, split on whitespace (globbing is off).
        sidekiq_form() {
          [ "$#" -gt 0 ] || return 1
          [ "$*" = "discourse sidekiq" ] && return 0
          case "${1##*/}" in
            sidekiq) return 0 ;;
            ruby|ruby[0-9]*)
              shift
              case "${1##*/}" in
                sidekiq) return 0 ;;
                bundle) [ "$2" = exec ] && [ "${3##*/}" = sidekiq ] && return 0 ;;
              esac ;;
            bundle) [ "$2" = exec ] && [ "${3##*/}" = sidekiq ] && return 0 ;;
          esac
          return 1
        }

        workers() {
          found=""; count=0; zombies=0; stopped=0
          table=$(ps -eo pid=,ppid=,uid=,stat=,args= 2>/dev/null) || return 4
          case "$table" in *[0-9]*) ;; *) return 4 ;; esac
          # Ancestors of this shell.
          chain=" $self "
          cursor=$self
          depth=0
          while [ "$cursor" -gt 1 ] && [ "$depth" -lt 64 ]; do
            parent=0
            while read -r pid ppid owner stat args; do
              [ "$pid" = "$cursor" ] && parent=$ppid
            done <<SILO_TABLE
        $table
        SILO_TABLE
            case "$parent" in ''|*[!0-9]*) return 4 ;; esac
            chain="$chain$parent "
            cursor=$parent
            depth=$((depth + 1))
          done
          # Descendants of this shell, to any depth.
          own=" $self "
          pass=0
          while [ "$pass" -lt 64 ]; do
            grown=""
            while read -r pid ppid owner stat args; do
              case "$own" in *" $pid "*) continue ;; esac
              case "$own" in *" $ppid "*) grown="$grown$pid " ;; esac
            done <<SILO_TABLE
        $table
        SILO_TABLE
            [ -z "$grown" ] && break
            own="$own$grown"
            pass=$((pass + 1))
          done
          chain="$chain$own"
          while read -r pid ppid owner stat args; do
            case "$pid$ppid$owner" in ''|*[!0-9]*) return 4 ;; esac
            [ -n "$stat" ] || return 4
            [ "$owner" = "$service_uid" ] || continue
            case "$chain" in *" $pid "*) continue ;; esac
            sidekiq_form $args || continue
            case "$stat" in
              Z*) zombies=$((zombies + 1)); continue ;;
              T*|t*) stopped=$((stopped + 1)) ;;
            esac
            found="$found $pid"
            count=$((count + 1))
          done <<SILO_TABLE
        $table
        SILO_TABLE
          return 0
        }

        # Signal one PID only if it is still the service user's live Sidekiq.
        term() {
          target=$1
          row=$(ps -o uid=,stat=,args= -p "$target" 2>/dev/null) || return 0
          set -- $row
          [ "$1" = "$service_uid" ] || return 0
          case "$2" in Z*) return 0 ;; esac
          shift 2
          sidekiq_form "$@" || return 0
          kill -TERM "$target" 2>/dev/null && signalled=$((signalled + 1))
          return 0
        }

        sv -w "$stop_wait" stop unicorn || { report stop_failed; exit 1; }
        if [ -d /etc/service/sidekiq ]; then sv -w "$stop_wait" stop sidekiq || { report stop_failed; exit 1; }; fi
        while :; do
          workers || { report process_table_unreadable; exit 4; }
          [ -z "$found" ] && break
          [ "$waited" -ge "$grace" ] && { report workers_remain; exit 2; }
          if [ $((waited % 10)) -eq 0 ]; then
            for pid in $found; do term "$pid"; done
          fi
          sleep 1
          waited=$((waited + 1))
        done
        case "$(sv status unicorn 2>/dev/null)" in down:*) ;; *) report app_server_not_down; exit 3 ;; esac
        report quiesced
        echo SILO_QUIESCED
      SH

      def propose_merge_preparation_plan(source:, base_site:, port: nil, allow_unqualified_runtime: false)
        unless source.is_a?(String) && base_site.is_a?(String) && source != base_site
          raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID"
        end
        selection = select_review_runtime(base_site, allow_unqualified: allow_unqualified_runtime)
        with_review_runtime(selection.fetch("profile")) do
          build_merge_preparation_plan(source: source, base_site: base_site, port: port, allow_unqualified_runtime: allow_unqualified_runtime, runtime_selection: selection)
        end
      end

      # Private host use only (never a model/agent projection): where the inspection endpoints
      # of a run are, as non-secret locators. Credentials stay in the private files the
      # inspection manifest names; this returns paths, not their content.
      def merge_access(run_id, side:)
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless run_id.is_a?(String) && run_id.match?(StandardReviewRun::RUN_ID) && %w[source base result].include?(side)

        state = @store.load
        run = state.fetch("runs")[run_id] || raise(StandardWorkflowError, "STANDARD_REFERENCE_INVALID")
        environment = merge_environment_record(state, run) || raise(StandardWorkflowError, "STANDARD_TRANSITION_INVALID")
        phase = merge_environment_phase(state, environment)
        owner = side == "result" ? environment["consumed_by"] : environment.fetch("preparation_run_id")
        unless owner == run_id && (side == "result" ? phase == "result" : phase == "ready")
          raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID"
        end
        record = state.fetch("instances")[environment["instance"].to_s]
        raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" unless record && record["state"] != "removed"

        { version: 1, run_id: run_id, side: side, preparation_run_id: environment.fetch("preparation_run_id"),
          generation: environment.fetch("generation"), phase: phase, instance: record.fetch("name"),
          database: side == "source" ? MERGE_INSPECT_SOURCE_DB : MERGE_BASE_DB,
          manifest: @store.run_dir(run_id, "private", "merge-access.json") }
      end

      private

      def prepare_plan?(plan)
        plan.dig("body", "operation") == PREPARE_OPERATION
      end

      def prepared_merge_plan?(plan)
        merge_plan?(plan) && plan.dig("body", "prepared_from").is_a?(Hash)
      end

      # -- planning ---------------------------------------------------------------------

      def build_merge_preparation_plan(source:, base_site:, port:, allow_unqualified_runtime:, runtime_selection:)
        state = @store.load
        config = state.fetch("config")
        raise StandardWorkflowError, "STANDARD_SIZE_LIMIT" if state.fetch("plans").size >= self.class::MAX_PLANS
        # No converter, layer or settings: preparing needs none of them.
        raise StandardWorkflowError, "STANDARD_STALE_PLAN" unless profile_current?(config)
        qualified = lock.dig("qualification", "status") == "qualified"
        review_ready = lock.dig("qualification", "status") == "review_ready"
        raise StandardWorkflowError, "STANDARD_RUNTIME_UNQUALIFIED" unless qualified || review_ready || allow_unqualified_runtime
        named = @store.named_state
        roles = { "source" => source, "base_site" => base_site }
        inputs = roles.transform_values { |id| named.fetch("inputs")[id] || raise(StandardWorkflowError, "STANDARD_REFERENCE_INVALID") }
        { "source" => "discourse-backup", "base_site" => "base_site" }.each do |role, type|
          raise StandardWorkflowError, "STANDARD_INPUTS_INCOMPLETE" unless inputs.fetch(role)["type"] == type
        end
        raise StandardWorkflowError, "STANDARD_INPUT_CHANGED" unless inputs_unchanged?(inputs.values)
        delivery = delivery_binding!(inputs.fetch("source").fetch("dataset_id"))
        delivery_roles!(named, roles, delivery)
        dataset = named.fetch("datasets").fetch(inputs.fetch("source").fetch("dataset_id"))
        platform = named.fetch("sources").fetch(dataset.fetch("source_id")).fetch("platform").unpack1("m0")
        raise StandardWorkflowError, "STANDARD_INPUTS_INCOMPLETE" unless platform == "discourse"
        source_versions, base = merge_side_bindings!(inputs, base_site)
        limits = review_limits(input_bytes: inputs.fetch("source").fetch("bytes") + inputs.fetch("base_site").fetch("bytes"))
        review_capacity!(limits, running: false)
        source_bytes = inputs.fetch("source").fetch("bytes")
        base_bytes = inputs.fetch("base_site").fetch("bytes")
        # Extraction and loading of the source, as the one-shot merge needs. The inspection
        # copies are admitted on the measured database sizes just before they are made.
        headroom = 3 * source_bytes + 2 * base_bytes
        disk_headroom!(headroom)
        plan_id = @store.new_id("plan")
        review_port = select_review_port(state, port)
        ids = roles.values.sort
        role_binding = file_role_binding(named, roles)
        body = {
          "operation" => PREPARE_OPERATION, "workspace_id" => named.fetch("workspace_id"), "dataset_id" => delivery.fetch("dataset_id"),
          "delivery" => delivery, "platform" => "discourse", "roles" => roles, "base_site" => base,
          "merge" => { "source" => { "input_id" => source, "delivery" => delivery.slice("kind", "version") }.merge(source_versions) },
          "input_binding" => ids.map { |id| inputs.values.find { |i| i["id"] == id }.slice("id", "sha256", "bytes", "type") },
          "input_stat_binding" => @store.named.input_binding(named, ids), "code_identity" => code_identity,
          "runtime_lock_sha256" => runtime_selection.fetch("sha256"), "discourse_profile" => runtime_selection.fetch("name"),
          "workspace_runtime_profile_sha256" => config["discourse_profile_sha256"],
          "review_runtime" => runtime_selection.fetch("selection"), "base_site_generation" => review_base_generation,
          "image_content_ids" => lock.fetch("images").transform_values { |image| image.fetch("content_id") },
          "runtime_qualified" => qualified, "allow_unqualified_runtime" => allow_unqualified_runtime,
          "app_revision" => lock.dig("app", "revision"), "limits" => limits,
          "capacity" => { "inspection_copies" => 2, "proposal_headroom_bytes" => headroom,
                          "copies_admitted_on" => "measured prepared database sizes before cloning" },
          "instances" => { "review" => { "name" => "silomig-#{plan_id.delete_prefix('plan-')[0, 8]}-review", "hostname" => "127.0.0.1", "port" => review_port } },
          "outputs" => { "environment" => "prepared merge environment for #{plan_id}" },
          "mutations" => ["restore the Base sandbox in one isolated local site", "load and migrate a disposable source copy with the same pinned runtime",
                          "check source/Base compatibility for the pinned merger without merging",
                          "seal both prepared databases and create one inspection copy of each (about one more database copy per side)",
                          "start the Base inspection copy and open local read-only inspection access", "keep the prepared environment until it is merged or reset"],
          "not_included" => ["the merge itself (a separate approved plan consumes this environment once)", "merge layer or settings",
                             "a backup of the prepared state", MERGE_NOT_CARRIED, "hosted restore", "DNS or cutover", "remote pushes"]
        }
        body["file_role_binding"] = role_binding if role_binding
        @store.update do |current|
          verify_file_role_proposal!(body, @store.named_state)
          current.fetch("plans")[plan_id] = { "id" => plan_id, "digest" => Digest::SHA256.hexdigest(canonical_json(body)), "body" => body,
                                            "status" => "proposed", "created_at" => now, "approval" => nil, "run_id" => nil }
        end
        show_plan(plan_id, detail: true)
      end

      # Source and Base version bindings against the selected runtime (shared with the merge plan).
      def merge_side_bindings!(inputs, base_site)
        source_versions = merge_source_versions!(inputs.fetch("source").fetch("path").unpack1("m0"))
        begin
          base_site_compatible!(source_versions, { "discourse_version" => lock.fetch("app").fetch("version") })
        rescue StandardWorkflowError => error
          raise unless error.code == "STANDARD_BASE_SITE_NEWER"
          raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_NEWER"
        end
        base_versions = base_site_versions!(inputs.fetch("base_site").fetch("path").unpack1("m0"))
        base_site_compatible!(base_versions, { "discourse_version" => lock.fetch("app").fetch("version") })
        migrations = review_image_migrations
        base_delivery = delivery_record!(inputs.fetch("base_site").fetch("dataset_id"))
        base = { "input_id" => base_site, "delivery" => base_delivery.slice("kind", "version"), "site_schema_version" => migrations.last,
                 "ahead" => base_versions.fetch("schema_version") > migrations.last }.merge(base_versions)
        [source_versions, base]
      end

      # Inputs, delivery and runtime of a preparation: what makes its environment stale.
      # Code identity is deliberately separate (see prepare_stale_reason): a later merge plan
      # binds the code that will run and reinstalls its helpers when it activates.
      def merge_environment_stale_reason(plan, state)
        body = plan.fetch("body")
        return "delivery" if !body["file_role_binding"] && body["base_site_generation"] && body["base_site_generation"] != review_base_generation

        named = @store.named_state
        ids = body.fetch("roles").values
        return "inputs" unless ids.all? { |id| named.fetch("inputs").key?(id) }
        return "inputs" unless @store.named.input_binding(named, ids.sort) == body.fetch("input_stat_binding") && inputs_unchanged?(ids.map { |id| named.fetch("inputs").fetch(id) })
        return "delivery" unless delivery_binding!(body.fetch("dataset_id")) == body.fetch("delivery")
        delivery_roles!(named, body.fetch("roles"), body.fetch("delivery"))
        base_record = delivery_record!(named.fetch("inputs").fetch(body.dig("roles", "base_site")).fetch("dataset_id"))
        return "delivery" unless base_record.slice("kind", "version") == body.dig("base_site", "delivery")
        return "runtime" unless review_runtime_current?(body, state.fetch("config"))
        nil
      rescue StandardWorkflowError, NamedError, Errno::ENOENT
        "inputs"
      end

      def prepare_stale_reason(plan, state)
        reason = merge_environment_stale_reason(plan, state)
        return reason if reason
        return "code" unless plan.dig("body", "code_identity") == code_identity
        nil
      end

      # The environment a prepared merge plan binds must be exactly that generation, ready and
      # unused (or already claimed by this very plan's run).
      def prepared_environment_stale_reason(plan, state)
        binding = plan.dig("body", "prepared_from")
        prepared = state.fetch("runs")[binding.fetch("run_id")]
        environment = prepared && prepared["merge_environment"]
        prepared_plan = prepared && state.fetch("plans")[prepared["plan_id"]]
        return "environment" unless environment && prepared_plan && prepare_plan?(prepared_plan) && environment["generation"] == binding.fetch("generation")

        claimed = plan["run_id"] && environment["consumed_by"] == plan["run_id"]
        return "environment" unless claimed || (environment["phase"] == "ready" && environment["consumed_by"].nil? && prepared["status"] == "completed")
        return nil if claimed && environment["phase"] != "consumed"

        merge_environment_stale_reason(prepared_plan, state) && "environment"
      end

      # -- environment record -------------------------------------------------------------

      def merge_environment_record(state, run)
        environment = run["merge_environment"]
        return nil unless environment.is_a?(Hash)

        prepared = state.fetch("runs")[environment["preparation_run_id"].to_s]
        prepared && prepared["merge_environment"].is_a?(Hash) ? prepared["merge_environment"] : nil
      end

      def merge_environment_phase(state, environment)
        phase = environment["phase"]
        return phase unless phase == "ready"

        prepared = state.fetch("runs")[environment["preparation_run_id"]]
        plan = prepared && state.fetch("plans")[prepared["plan_id"]]
        plan && merge_environment_stale_reason(plan, state).nil? ? "ready" : "stale"
      end

      # The only projection of an environment: three fixed, non-secret fields.
      def merge_environment_summary(run, state = nil)
        own = run["merge_environment"]
        return nil unless own.is_a?(Hash)

        state ||= @store.load
        # The preparation run holds the record itself; a consumer mirrors it. A consumer that
        # released, dirtied or lost its preparation keeps its own last view.
        environment = own["preparation_run_id"] == run["id"] ? own : merge_environment_record(state, run)
        current = environment && !%w[released dirty].include?(own["phase"]) && (environment.equal?(own) || environment["consumed_by"] == run["id"])
        phase = current ? merge_environment_phase(state, environment) : own["phase"]
        { "preparation_run_id" => own["preparation_run_id"], "generation" => own["generation"], "phase" => phase }
      rescue StandardError
        { "preparation_run_id" => own["preparation_run_id"], "generation" => own["generation"], "phase" => own["phase"] }
      end

      def update_merge_environment(prepared_run_id, phase = nil, **values)
        @store.update do |state|
          environment = state.fetch("runs").fetch(prepared_run_id).fetch("merge_environment")
          yield environment, state if block_given?
          environment["phase"] = phase if phase
          environment.merge!(values.transform_keys(&:to_s))
          environment["updated_at"] = now
          consumer = environment["consumed_by"] && state.fetch("runs")[environment["consumed_by"]]
          consumer["merge_environment"] = environment.slice("preparation_run_id", "generation", "phase") if consumer
        end
      end

      # Inside the claim's state update: one generation, one merge.
      def claim_prepared_environment!(state, plan, run_id)
        binding = plan.dig("body", "prepared_from")
        prepared = state.fetch("runs")[binding.fetch("run_id")]
        environment = prepared && prepared["merge_environment"]
        record = environment && state.fetch("instances")[environment["instance"].to_s]
        unless environment && environment["generation"] == binding.fetch("generation") && environment["phase"] == "ready" && environment["consumed_by"].nil? &&
               prepared["status"] == "completed" && record && record["state"] == "prepared" && record["run_id"] == prepared["id"]
          raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_STALE", "environment not ready")
        end
        environment["phase"] = "consumed"
        environment["consumed_by"] = run_id
        environment["updated_at"] = now
        environment.slice("preparation_run_id", "generation", "phase")
      end

      # A failed or interrupted run: an environment nothing has mutated yet (claimed, never
      # fenced) returns to ready; anything later is uncertain and therefore dirty.
      def merge_environment_failed(state, run)
        own = run["merge_environment"]
        return unless own.is_a?(Hash)

        environment = merge_environment_record(state, run)
        return unless environment && %w[reset dirty].none?(environment["phase"])

        if environment["preparation_run_id"] == run["id"]
          return if environment["consumed_by"] # a completed preparation's record belongs to its consumer now

          environment["phase"] = "dirty"
        elsif environment["consumed_by"] == run["id"]
          if environment["phase"] == "consumed"
            environment["phase"] = "ready"
            environment["consumed_by"] = nil
            own["phase"] = "released"
            environment["updated_at"] = now
            return
          end
          environment["phase"] = "dirty"
          own["phase"] = "dirty"
        end
        environment["updated_at"] = now
      end

      # -- preparation stages -----------------------------------------------------------

      def prepare_preflight(run_id, plan)
        body = plan.fetch("body")
        resolved = lock.fetch("images").transform_values { |image| ImageIdentity.resolve(@runtime, image) }
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("artifacts")["resolved_image_ids"] = resolved }
        evidence(run_id, "runtime-images.json", JSON.pretty_generate(resolved) + "\n")
        record_review_runtime(run_id, resolved_image_id: resolved.fetch("web"))
        manifest = materialize_inputs(run_id, body, @store.named_state, layout: false)
        manifest.each { |input| input["role"] = body.fetch("roles").key(input.fetch("id")) }
        @store.write_private(@store.run_dir(run_id, "work", "inputs.json"), JSON.pretty_generate(manifest) + "\n")
        snapshot_helpers(run_id)
        disk_headroom!(3 * role_input(manifest, "source").fetch("bytes"))
        record_results(run_id, input_count: manifest.size, input_bytes: manifest.sum { |input| input.fetch("bytes") }, merge: {})
      end

      def merge_environment_sql(run_id, label, sql, db: "postgres", user: "postgres", code: "STANDARD_MERGE_ENVIRONMENT_DIRTY")
        stack = stack_for(run_id, "review")
        result = @runtime.run(["docker", "exec", stack.container("db"), "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", user, "-d", db, "-Atc", sql], capture: true, timeout: 7200)
        log(run_id, "merge-environment-#{label}", result)
        raise StandardWorkflowError.new(code, label) unless result.success?

        result.stdout.to_s
      end

      def merge_quiesce_web!(run_id, stack, code: "STANDARD_MERGE_ENVIRONMENT_DIRTY")
        # Explicit service-stop waits plus the bounded drain and an exec margin.
        timeout = MERGE_QUIESCE_GRACE + 2 * MERGE_SERVICE_STOP_WAIT + 30
        result = stack.web_exec(["sh", "-c", MERGE_QUIESCE_SCRIPT], timeout: timeout)
        log(run_id, "merge-quiesce", result)
        return if result.success? && result.stdout.to_s.lines.last.to_s.strip == "SILO_QUIESCED"

        # Only the script's own fixed-format line (reason and counts) reaches the failure detail.
        diagnostic = result.stdout.to_s.lines.map(&:strip).grep(MERGE_QUIESCE_DIAGNOSTIC).last
        raise StandardWorkflowError.new(code, diagnostic ? "quiesce: #{diagnostic.delete_prefix('SILO_QUIESCE ')}" : "quiesce")
      end

      # No session may remain on the named databases: terminate, then verify the drain.
      def merge_drain_sessions!(run_id, databases)
        list = databases.map { |name| "'#{name}'" }.join(", ")
        10.times do
          merge_environment_sql(run_id, "terminate", "SELECT COUNT(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname IN (#{list}) AND pid <> pg_backend_pid()")
          remaining = merge_environment_sql(run_id, "sessions", "SELECT COUNT(*) FROM pg_stat_activity WHERE datname IN (#{list}) AND pid <> pg_backend_pid()")
          return if remaining.strip == "0"

          nap(0.5)
        end
        raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "sessions remain")
      end

      def merge_seal(run_id, database)
        seal = merge_environment_sql(run_id, "seal", MERGE_SEAL_SQL, db: database, user: "discourse").strip
        raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "seal") unless seal.match?(MERGE_SEAL)

        seal
      end

      def merge_databases(run_id)
        names = [MERGE_CLEAN_BASE_DB, MERGE_BASE_DB, MERGE_CLEAN_SOURCE_DB, MERGE_INSPECT_SOURCE_DB]
        merge_environment_sql(run_id, "databases", "SELECT datname || ':' || datallowconn FROM pg_database WHERE datname IN (#{names.map { |name| "'#{name}'" }.join(', ')}) ORDER BY datname").lines.map(&:strip).reject(&:empty?).sort
      end

      # Quiesce, seal and copy. The clean databases keep every byte restored/migrated by this
      # run; the copies are the only thing inspection (the app included) ever touches.
      def stage_checkpoint(run_id)
        stack = stack_for(run_id, "review")
        # Ownership and the phase are durable before the first fallible action.
        update_merge_environment(run_id, "checkpointing", instance: stack.name, containers: stack.record.fetch("containers"),
                                 clean_base_database: MERGE_CLEAN_BASE_DB, base_inspection_database: MERGE_BASE_DB,
                                 clean_source_database: MERGE_CLEAN_SOURCE_DB, source_inspection_database: MERGE_INSPECT_SOURCE_DB)
        set_instance_state(stack, "checkpointing")
        merge_quiesce_web!(run_id, stack)
        merge_drain_sessions!(run_id, [MERGE_BASE_DB, MERGE_CLEAN_SOURCE_DB])
        unless merge_databases(run_id) == ["#{MERGE_BASE_DB}:t", "#{MERGE_CLEAN_SOURCE_DB}:t"]
          raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "unexpected databases")
        end
        seals = { "base" => merge_seal(run_id, MERGE_BASE_DB), "source" => merge_seal(run_id, MERGE_CLEAN_SOURCE_DB) }
        sizes = merge_environment_sql(run_id, "sizes", "SELECT pg_database_size('#{MERGE_BASE_DB}') || ',' || pg_database_size('#{MERGE_CLEAN_SOURCE_DB}')").strip
        raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "sizes") unless sizes.match?(/\A\d{1,15},\d{1,15}\z/)

        copy_bytes = sizes.split(",").sum(&:to_i)
        # One more copy of each prepared database, with a fifth again for WAL and indexes in flight.
        disk_headroom!(copy_bytes + copy_bytes / 5)
        merge_result(run_id, inspection_copy_bytes: copy_bytes)
        merge_drain_sessions!(run_id, [MERGE_BASE_DB, MERGE_CLEAN_SOURCE_DB])
        merge_environment_sql(run_id, "base-seal-name", "ALTER DATABASE #{MERGE_BASE_DB} RENAME TO #{MERGE_CLEAN_BASE_DB}")
        merge_environment_sql(run_id, "base-copy", "CREATE DATABASE #{MERGE_BASE_DB} TEMPLATE #{MERGE_CLEAN_BASE_DB} OWNER discourse")
        merge_environment_sql(run_id, "base-seal", "ALTER DATABASE #{MERGE_CLEAN_BASE_DB} ALLOW_CONNECTIONS false")
        merge_environment_sql(run_id, "source-copy", "CREATE DATABASE #{MERGE_INSPECT_SOURCE_DB} TEMPLATE #{MERGE_CLEAN_SOURCE_DB} OWNER discourse")
        merge_environment_sql(run_id, "source-seal", "ALTER DATABASE #{MERGE_CLEAN_SOURCE_DB} ALLOW_CONNECTIONS false")
        unless merge_databases(run_id) == ["#{MERGE_BASE_DB}:t", "#{MERGE_CLEAN_SOURCE_DB}:f", "#{MERGE_CLEAN_BASE_DB}:f", "#{MERGE_INSPECT_SOURCE_DB}:t"].sort
          raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "copies not as expected")
        end
        unless merge_seal(run_id, MERGE_BASE_DB) == seals.fetch("base") && merge_seal(run_id, MERGE_INSPECT_SOURCE_DB) == seals.fetch("source")
          raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "copy differs from sealed state")
        end
        base_oid = merge_environment_sql(run_id, "base-inspection-oid", "SELECT oid::text FROM pg_database WHERE datname = '#{MERGE_BASE_DB}'").strip
        unless base_oid.match?(/\A[1-9][0-9]{0,9}\z/)
          raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "inspection database identity")
        end
        plan = plan_for(run_id)
        generation = Digest::SHA256.hexdigest(canonical_json(
          "preparation_run_id" => run_id, "plan_digest" => plan.fetch("digest"), "instance" => stack.name,
          "containers" => stack.record.fetch("containers"), "base_inspection_database_oid" => base_oid,
          "seals" => seals, "nonce" => SecureRandom.hex(16), "sealed_at" => now
        ))
        update_merge_environment(run_id, "inspection", generation: generation, seals: seals, sealed_at: now,
                                 base_inspection_database_oid: base_oid)
      end

      # The app starts on the Base inspection copy; only then is local read access opened.
      def stage_inspection(run_id)
        stack = stack_for(run_id, "review")
        environment = @store.load.dig("runs", run_id, "merge_environment")
        raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "no generation") unless environment["phase"] == "inspection" && environment["generation"].to_s.match?(MERGE_GENERATION)

        merge_checked(run_id, "merge-inspection-start", stack.web_exec(%w[sv start unicorn]), "STANDARD_STACK_FAILED")
        wait_restored_web(stack, internal: true)
        summary = merge_inspection_open(run_id, phase: "base", generation: environment.fetch("generation"), preparation_run_id: run_id,
                                        source_database: MERGE_INSPECT_SOURCE_DB)
        merge_result(run_id, inspection: merge_inspection_counts(summary))
        @store.update do |state|
          state.fetch("instances").fetch(stack.name)["state"] = "prepared"
          state.fetch("runs").fetch(run_id).fetch("merge_environment").merge!("phase" => "ready", "updated_at" => now)
        end
      end

      # Counts and fixed labels only; table names and credentials stay in the private manifest.
      def merge_inspection_counts(summary)
        return { "state" => "open" } unless summary.is_a?(Hash)

        { "state" => summary["state"].to_s[0, 16], "endpoints" => Array(summary["endpoints"]).size,
          "granted_tables" => summary["granted_tables"], "unreviewed_tables" => summary["unreviewed_tables"] }
          .select { |_key, value| value.is_a?(String) || value.is_a?(Integer) }
      end

      # -- compatibility gate -------------------------------------------------------------

      # Before any merger is constructed: actual migration inventories, pending state and the
      # schema the pinned merger copies. Nothing here edits a marker; a mismatch refuses.
      def stage_compatibility(run_id)
        merge_compatibility!(run_id, JSON.parse(File.read(@store.run_dir(run_id, "evidence", "merge-before.json"))),
                             JSON.parse(File.read(@store.run_dir(run_id, "evidence", "merge-source.json"))))
      end

      def merge_compatibility!(run_id, target, source)
        report = merge_compatibility(target, source, review_image_migrations)
        # Names of tables/columns/migrations are customer-shaped: private evidence only.
        evidence(run_id, "merge-compatibility.json", report)
        evidence(run_id, "merge-target-only-columns.json", report.fetch("target_only_columns"))
        merge_result(run_id, target_only_columns: report.fetch("target_only_columns").size,
                     compatibility: { "status" => report.fetch("failures").empty? ? "passed" : "refused", "failures" => report.fetch("failures").size,
                                      "merger_tables" => report.fetch("merger_tables"), "source_tables" => report.fetch("source_tables"),
                                      # Not carried, whichever side also has them: counts only.
                                      "unhandled_source_tables" => report.fetch("unhandled_source_tables").size,
                                      "unhandled_shared_tables" => (report.fetch("unhandled_source_tables") - report.fetch("source_only_tables")).size,
                                      "source_only_tables" => report.fetch("source_only_tables").size,
                                      "source_only_columns" => report.fetch("source_only_columns").size,
                                      "carried_scope" => report.fetch("carried_scope"),
                                      "source_unknown_migrations" => report.fetch("source_unknown_migrations").size,
                                      "target_unknown_migrations" => report.fetch("target_unknown_migrations").size })
        return if report.fetch("failures").empty?

        raise StandardWorkflowError.new("STANDARD_MERGE_INCOMPATIBLE", report.fetch("failures").map { |failure| failure["check"] }.uniq.join(","))
      end

      def merge_compatibility(target, source, known)
        failures = []
        fail_with = ->(check, items = []) { failures << { "check" => check, "items" => items.first(200) } }
        inventories = [target, source].map do |state|
          versions = state["migrations"]
          versions.is_a?(Array) && !versions.empty? && versions.all? { |v| v.is_a?(String) && v.match?(/\A\d{14}\z/) } ? versions.uniq.sort : nil
        end
        fail_with.call("target-pending") unless target["pending"] == false
        fail_with.call("source-pending") unless source["pending"] == false
        target_versions, source_versions = inventories
        unknown = { "target" => [], "source" => [] }
        if target_versions && source_versions
          { "target" => target_versions, "source" => source_versions }.each do |side, versions|
            missing = known - versions
            fail_with.call("#{side}-missing-runtime-migrations", missing) unless missing.empty?
            unknown[side] = versions - known
            newer = unknown[side].select { |version| version > known.last }
            # A schema newer than the pinned code (for example a schema-only backup of a newer
            # or differently equipped site) is unsupported, whatever the filename says.
            fail_with.call("#{side}-newer-than-runtime", newer) unless newer.empty?
          end
          # The pinned merger's own admission condition, met by real migrations only.
          fail_with.call("schema-version-differs") unless target_versions.last == source_versions.last
        else
          fail_with.call("migration-inventory")
        end
        columns = lambda do |state|
          rows = state["columns"]
          next nil unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Array) && row.size.between?(2, 3) && row.first(2).all?(String) }

          rows.each_with_object({}) { |(table, column, type), tables| (tables[table] ||= {})[column] = type }
        end
        target_columns = columns.call(target)
        source_columns = columns.call(source)
        merger = target["merger"]
        tables = merger.is_a?(Hash) && merger["available"] == true && merger["tables"].is_a?(Array) && merger["tables"].all?(String) ? merger["tables"] : nil
        target_only = []
        if target_columns.nil? || source_columns.nil?
          fail_with.call("schema-inventory")
        elsif tables.nil? || tables.empty?
          fail_with.call("merger-tables-unknown")
        else
          required = (tables + StandardMergeRun::MERGE_TOTAL_KEYS + %w[schema_migrations]).uniq.sort
          fail_with.call("target-missing-tables", required - target_columns.keys) unless (required - target_columns.keys).empty?
          fail_with.call("source-missing-tables", required - source_columns.keys) unless (required - source_columns.keys).empty?
          missing = []
          types = []
          (required & target_columns.keys & source_columns.keys).each do |table|
            target_columns.fetch(table).each do |column, type|
              if !source_columns.fetch(table).key?(column) then missing << "#{table}.#{column}"
              elsif type && source_columns.fetch(table)[column] && source_columns.fetch(table)[column] != type then types << "#{table}.#{column}"
              end
            end
          end
          # The merger selects the target model's columns from the source: one missing column
          # fails mid-copy, so it is refused here instead.
          fail_with.call("source-missing-columns", missing) unless missing.empty?
          fail_with.call("column-types-differ", types) unless types.empty?
          (target_columns.keys & source_columns.keys).each do |table|
            (target_columns.fetch(table).keys - source_columns.fetch(table).keys).each { |column| target_only << [table, column] }
          end
        end
        source_only_tables = target_columns && source_columns ? source_columns.keys - target_columns.keys : []
        # A table on both sides is not thereby carried: only what the pinned merger names can be.
        # The scan is a superset of what it copies, so this list is a floor, not the full set.
        unhandled = source_columns && tables ? source_columns.keys - tables - MERGE_BOOKKEEPING_TABLES : nil
        source_only_columns = if target_columns && source_columns
                                (target_columns.keys & source_columns.keys).flat_map { |table| (source_columns.fetch(table).keys - target_columns.fetch(table).keys).map { |column| [table, column] } }
                              else []
                              end
        { "version" => 1, "failures" => failures, "runtime_schema_version" => known.last,
          "target_schema_version" => target_versions&.last, "source_schema_version" => source_versions&.last,
          "target_unknown_migrations" => unknown.fetch("target"), "source_unknown_migrations" => unknown.fetch("source"),
          "merger_tables" => tables ? tables.size : 0, "layer_scanned" => merger.is_a?(Hash) && merger["layer_scanned"] == true,
          "target_only_columns" => target_only.sort,
          # Not carried by the pinned merger: explicit exclusions, never an implied preservation.
          "source_tables" => source_columns ? source_columns.size : 0,
          "carried_scope" => unhandled ? "merger_named_tables_only" : "unknown",
          "unhandled_source_tables" => (unhandled || []).sort,
          "source_only_tables" => source_only_tables.sort, "source_only_columns" => source_only_columns.sort }
      end

      # -- consuming merge ------------------------------------------------------------------

      def propose_prepared_merge_plan(prepared_from:, generation: nil, intent: nil, source: nil, base_site: nil, port: nil, allow_unqualified_runtime: false, **options)
        unless prepared_from.is_a?(String) && prepared_from.match?(StandardReviewRun::RUN_ID) && generation.is_a?(String) && generation.match?(MERGE_GENERATION) &&
               MERGE_INTENTS.include?(intent) && port.nil?
          raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID"
        end
        state = @store.load
        prepared = state.fetch("runs")[prepared_from] || raise(StandardWorkflowError, "STANDARD_REFERENCE_INVALID")
        prepared_plan = state.fetch("plans")[prepared["plan_id"]]
        raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless prepared_plan && prepare_plan?(prepared_plan)

        environment = prepared["merge_environment"] || {}
        unless prepared["status"] == "completed" && environment["generation"] == generation && environment["consumed_by"].nil? &&
               merge_environment_phase(state, environment) == "ready"
          raise StandardWorkflowError, "STANDARD_MERGE_ENVIRONMENT_STALE"
        end
        body = prepared_plan.fetch("body")
        roles = body.fetch("roles")
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless [[source, "source"], [base_site, "base_site"]].all? { |given, role| given.nil? || given == roles.fetch(role) }
        # The preparation's runtime decision stands; a merge cannot widen it.
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" if allow_unqualified_runtime && body["allow_unqualified_runtime"] != true

        # The preparation's pinned runtime, never a new selection.
        profile = begin
          review_runtime_for(body)
        rescue StandardWorkflowError, SystemCallError
          raise StandardWorkflowError, "STANDARD_MERGE_ENVIRONMENT_STALE"
        end
        selection = { "profile" => profile, "sha256" => body.fetch("runtime_lock_sha256"), "name" => body.fetch("discourse_profile"), "selection" => body.fetch("review_runtime") }
        with_review_runtime(profile) do
          build_merge_plan(source: roles.fetch("source"), base_site: roles.fetch("base_site"), runtime_selection: selection, intent: intent,
                           allow_unqualified_runtime: body["allow_unqualified_runtime"] == true,
                           prepared: { "run_id" => prepared_from, "generation" => generation, "body" => body }, **options)
        end
      end

      # A prepared merge materializes only what the preparation doesn't already hold.
      def prepared_merge_preflight(run_id, plan)
        body = plan.fetch("body")
        binding = body.fetch("prepared_from")
        resolved = lock.fetch("images").transform_values { |image| ImageIdentity.resolve(@runtime, image) }
        prepared = @store.load.fetch("runs").fetch(binding.fetch("run_id"))
        # One pinned runtime: the images this merge resolves are the ones the stack was built from.
        raise StandardWorkflowError.new("STANDARD_RUNTIME_MISMATCH", "prepared images") unless resolved == prepared.dig("artifacts", "resolved_image_ids")

        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("artifacts")["resolved_image_ids"] = resolved }
        evidence(run_id, "runtime-images.json", JSON.pretty_generate(resolved) + "\n")
        record_review_runtime(run_id, resolved_image_id: resolved.fetch("web"))
        settings_id = body.dig("roles", "settings")
        only = body.merge("input_binding" => body.fetch("input_binding").select { |input| input["id"] == settings_id })
        manifest = materialize_inputs(run_id, only, @store.named_state, layout: false)
        manifest.each { |input| input["role"] = body.fetch("roles").key(input.fetch("id")) }
        @store.write_private(@store.run_dir(run_id, "work", "inputs.json"), JSON.pretty_generate(manifest) + "\n")
        snapshot_helpers(run_id)
        if body["intent"] == "custom"
          config = @store.load.fetch("config")
          layer, files = merge_layer!(config.fetch("converter_worktree"), body.fetch("converter_revision"), @workspace)
          raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID" unless layer == body.dig("merge", "layer") && layer["present"] == true
          files.each { |path, bytes| @store.write_private(@store.run_dir(run_id, "private", "merge", "layer", path), bytes) }
        end
        settings = role_input(manifest, "settings")
        merge_settings!(File.binread(input_path(run_id, settings))) if settings
        source_bytes = body.fetch("input_binding").find { |input| input["id"] == body.dig("roles", "source") }.fetch("bytes")
        disk_headroom!(3 * source_bytes)
        record_results(run_id, input_count: manifest.size, input_bytes: manifest.sum { |input| input.fetch("bytes") }, merge: { "restore_proof" => "skipped" })
      end

      # Fence inspection, drop the copies and return the sealed databases to their working names.
      # Serialized by the run's op lock; nothing before the recorded "fencing" phase mutates.
      def stage_activate(run_id)
        plan = plan_for(run_id)
        binding = plan.dig("body", "prepared_from")
        prepared_id = binding.fetch("run_id")
        seals = nil
        @store.update do |state|
          environment = state.fetch("runs").fetch(prepared_id)["merge_environment"] || {}
          record = state.fetch("instances")[environment["instance"].to_s]
          unless environment["generation"] == binding.fetch("generation") && environment["phase"] == "consumed" && environment["consumed_by"] == run_id &&
                 record && record["state"] == "prepared" && record["run_id"] == prepared_id && record["containers"] == environment["containers"]
            raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_STALE", "environment changed before activation")
          end
          # Ownership moves with the first mutation: from here a failure is this run's to reset.
          environment.merge!("phase" => "fencing", "updated_at" => now)
          record.merge!("state" => "activating", "run_id" => run_id, "prepared_by" => prepared_id)
          run = state.fetch("runs").fetch(run_id)
          run.fetch("instances")["review"] = record.fetch("name")
          run["merge_environment"] = environment.slice("preparation_run_id", "generation", "phase")
          seals = environment.fetch("seals")
        end
        stack = stack_for(run_id, "review")
        raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "stack not running") unless stack.live? == true

        # Connectors, API keys and the read role go first; then every writer and reader.
        merge_inspection_close(prepared_id)
        merge_quiesce_web!(run_id, stack)
        copies = [MERGE_BASE_DB, MERGE_INSPECT_SOURCE_DB]
        unless merge_databases(run_id) == ["#{MERGE_BASE_DB}:t", "#{MERGE_CLEAN_SOURCE_DB}:f", "#{MERGE_CLEAN_BASE_DB}:f", "#{MERGE_INSPECT_SOURCE_DB}:t"].sort
          raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "unexpected databases")
        end
        copies.each { |name| merge_environment_sql(run_id, "fence-#{name}", "ALTER DATABASE #{name} ALLOW_CONNECTIONS false") }
        merge_drain_sessions!(run_id, copies)
        copies.each { |name| merge_environment_sql(run_id, "drop-#{name}", "DROP DATABASE #{name}") }
        merge_environment_sql(run_id, "base-open", "ALTER DATABASE #{MERGE_CLEAN_BASE_DB} ALLOW_CONNECTIONS true")
        merge_environment_sql(run_id, "base-name", "ALTER DATABASE #{MERGE_CLEAN_BASE_DB} RENAME TO #{MERGE_BASE_DB}")
        merge_environment_sql(run_id, "source-open", "ALTER DATABASE #{MERGE_CLEAN_SOURCE_DB} ALLOW_CONNECTIONS true")
        unless merge_databases(run_id) == ["#{MERGE_BASE_DB}:t", "#{MERGE_CLEAN_SOURCE_DB}:t"]
          raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "clean databases not active")
        end
        # Sessions, queued jobs and caches the inspection site left in Redis must not reach the merge.
        flushed = @runtime.run(["docker", "exec", stack.container("redis"), "redis-cli", "FLUSHALL"], capture: true, timeout: 120)
        log(run_id, "merge-environment-redis", flushed)
        raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "redis") unless flushed.success?

        unless merge_seal(run_id, MERGE_BASE_DB) == seals.fetch("base") && merge_seal(run_id, MERGE_CLEAN_SOURCE_DB) == seals.fetch("source")
          raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "sealed state changed")
        end
        install_helpers(run_id, stack)
        env = {}
        if plan.dig("body", "merge", "layer", "present")
          merge_checked(run_id, "merge-layer-scan", stack.web_exec(%w[rm -rf /shared/silo-merge-layer-scan]), "STANDARD_MERGE_ENVIRONMENT_DIRTY")
          stack.copy_in(@store.run_dir(run_id, "private", "merge", "layer"), "/shared/silo-merge-layer-scan", owner: "root:root")
          env["SILO_MERGE_SCAN_LAYER"] = "/shared/silo-merge-layer-scan"
        end
        before = merge_state(stack, run_id: run_id, env: env)
        source_state = merge_state(stack, source: true, run_id: run_id)
        unless before["database"] == MERGE_BASE_DB && source_state["database"] == MERGE_CLEAN_SOURCE_DB && merge_source_url?(source_state["base_url"])
          raise StandardWorkflowError.new("STANDARD_MERGE_ENVIRONMENT_DIRTY", "state after activation")
        end
        evidence(run_id, "merge-before.json", before)
        evidence(run_id, "merge-source.json", source_state)
        uploads = File.read(@store.run_dir(prepared_id, "evidence", "merge-uploads.json"))
        evidence(run_id, "merge-uploads.json", uploads)
        merge_result(run_id, target_before: before.fetch("counts"), source: source_state.fetch("counts"),
                     source_upload_files: JSON.parse(uploads).fetch("uploads").size)
        # Again, on the activated databases and with this plan's layer in view.
        merge_compatibility!(run_id, before, source_state)
        update_merge_environment(prepared_id, "merging")
      end

      # Only after the clean backup is recorded and the review admin exists. Inspection of the
      # result is a convenience: its absence is reported, it never fails a backed-up merge.
      def stage_result_inspection(run_id)
        binding = plan_for(run_id).dig("body", "prepared_from")
        raise StandardWorkflowError, "STANDARD_RELEASE_NOT_READY" unless @store.load.dig("runs", run_id, "artifacts", "backup")

        state = begin
          summary = merge_inspection_open(run_id, phase: "result", generation: binding.fetch("generation"), preparation_run_id: binding.fetch("run_id"))
          merge_inspection_counts(summary).fetch("state", "open")
        rescue StandardWorkflowError => error
          raise unless error.code.to_s.start_with?("STANDARD_MERGE_INSPECTION_")

          "unavailable"
        end
        merge_result(run_id, result_inspection: state)
        update_merge_environment(binding.fetch("run_id"), "result")
      end

      # -- reset --------------------------------------------------------------------------

      # What a reset of this run owns. A preparation whose environment a merge run has taken over
      # is reset through that merge run, never underneath it.
      def merge_reset_scope!(state, run, plan)
        own = run["merge_environment"]
        return nil unless own.is_a?(Hash) && (prepare_plan?(plan) || prepared_merge_plan?(plan))

        environment = merge_environment_record(state, run)
        return { close: [run["id"]], prepared: nil, owner: false } unless environment

        if environment["preparation_run_id"] == run["id"]
          consumer = environment["consumed_by"]
          record = state.fetch("instances")[environment["instance"].to_s]
          if consumer && environment["phase"] != "reset" && record && record["state"] != "removed"
            raise StandardWorkflowError.new("STANDARD_TRANSITION_INVALID", "reset the merge run that consumed this environment")
          end
          { close: [run["id"]], prepared: run["id"], owner: consumer.nil? }
        elsif environment["consumed_by"] == run["id"] && run.fetch("instances", {})["review"]
          { close: [environment["preparation_run_id"], run["id"]], prepared: environment["preparation_run_id"], owner: true }
        else
          { close: [run["id"]], prepared: nil, owner: false } # released or never activated: nothing of the environment is this run's
        end
      end

      # Fence what can be fenced now; a stack Docker can't describe is retried once it is gone.
      def merge_reset_close(scope)
        scope.fetch(:close).reject do |id|
          merge_inspection_close(id)
          true
        rescue StandardWorkflowError
          false
        end
      end

      def merge_reset_finish!(scope, pending)
        pending.each do |id|
          merge_inspection_close(id)
        rescue StandardWorkflowError
          raise StandardWorkflowError.new("STANDARD_CLEANUP_FAILED", "inspection access")
        end
        return unless scope[:owner] && scope[:prepared]

        sweep_run_resources(scope[:prepared])
        FileUtils.rm_rf(@store.run_dir(scope[:prepared], "private", "merge-source"))
        update_merge_environment(scope[:prepared], "reset")
      end
    end
  end
end
