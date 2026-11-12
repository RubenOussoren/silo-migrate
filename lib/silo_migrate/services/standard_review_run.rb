# frozen_string_literal: true

require "zlib"
require_relative "../discourse_version"
require "set"

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
    # Base-site mode restores a sandbox and takes a portable SQL-only backup before
    # local access setup. Uploads, hosted restore and cutover remain out of scope.
    module StandardReviewRun
      REVIEW_OPERATION = "standard_review"
      REVIEW_STAGES = %w[preflight site_up site_setup import verify review_url].freeze
      BASE_SITE_STAGES = %w[preflight site_up base_restore import verify backup site_setup review_url].freeze
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

      def propose_review_plan(**options)
        selection = select_review_runtime(options[:base_site], allow_unqualified: options.fetch(:allow_unqualified_runtime, false))
        with_review_runtime(selection.fetch("profile")) do
          build_review_plan(**options, runtime_selection: selection)
        end
      end

      def select_review_runtime(base_site, allow_unqualified: false)
        versions = nil
        if base_site
          input = @store.named_state.fetch("inputs")[base_site] || raise(StandardWorkflowError, "STANDARD_REFERENCE_INVALID")
          raise StandardWorkflowError, "STANDARD_INPUTS_INCOMPLETE" unless input["type"] == "base_site"

          versions = base_site_versions!(input.fetch("path").unpack1("m0"))
        end
        selection = ReviewRuntime.new(profiles: profiles, runtime: @runtime).select(base: versions, preferred: @env["SILO_REVIEW_RUNTIME_PROFILE"], allow_unqualified: allow_unqualified)
        # Request-derived comparison stays in this workspace's plan, not in the
        # shared public image profile. The host forwards only bounded fixed facts.
        comparison = JSON.parse(@env.fetch("SILO_REVIEW_RUNTIME_COMPARISON", "{}"))
        unless comparison.is_a?(Hash) && (comparison.keys - %w[core_comparison_complete missing_known_core_migrations]).empty? &&
               (!comparison.key?("core_comparison_complete") || [true, false].include?(comparison["core_comparison_complete"])) &&
               (!comparison.key?("missing_known_core_migrations") || (comparison["missing_known_core_migrations"].is_a?(Integer) && comparison["missing_known_core_migrations"].between?(0, 20_000)))
          raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH"
        end
        selection.fetch("selection").merge!(comparison)
        selection
      rescue JSON::ParserError
        raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH"
      end

      # Only Base delivery identity, never customer filenames. Replacing a Base
      # invalidates pending proposals, including an earlier automatic fresh-site one.
      def review_base_generation
        path = File.join(@store.workspace_root, ".silo-migrate", "named", "deliveries.json")
        document = if File.exist?(path) || File.symlink?(path)
                     File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
                       raise StandardWorkflowError, "STANDARD_DELIVERY_UNLABELLED" unless file.stat.file? && file.stat.size <= 1024 * 1024
                       bytes = file.read(1024 * 1024 + 1)
                       raise StandardWorkflowError, "STANDARD_DELIVERY_UNLABELLED" if bytes.bytesize > 1024 * 1024
                       JSON.parse(bytes)
                     end
                   else {}
                   end
        records = document.fetch("deliveries", {}).select { |_id, record| record["kind"] == "base_site" }
        identity = records.sort.map { |id, record| [id, record["version"], record["replaced_by"]] }
        Digest::SHA256.hexdigest(canonical_json(identity))
      rescue JSON::ParserError, SystemCallError, TypeError, NoMethodError, NamedError
        raise StandardWorkflowError, "STANDARD_DELIVERY_UNLABELLED"
      end

      def build_review_plan(from_run:, reconciliation: nil, base_site: nil, port: nil, allow_unqualified_runtime: false, runtime_selection:)
        state = @store.load
        raise StandardWorkflowError, "STANDARD_SIZE_LIMIT" if state.fetch("plans").size >= self.class::MAX_PLANS
        raise StandardWorkflowError, "STANDARD_STALE_PLAN" unless profile_current?(state.fetch("config"))
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless from_run.is_a?(String) && from_run.match?(RUN_ID)
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless reconciliation.nil? || reconciliation.is_a?(String)

        qualified = lock.dig("qualification", "status") == "qualified"
        review_ready = lock.dig("qualification", "status") == "review_ready"
        raise StandardWorkflowError, "STANDARD_RUNTIME_UNQUALIFIED" unless qualified || review_ready || allow_unqualified_runtime

        source_run, source_plan = review_source!(state, from_run)
        verify_review_lineage!(source_plan, file_roles.load, @store.named_state)
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

        base_binding = nil
        if base_site
          raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless base_site.is_a?(String)
          input = named.fetch("inputs")[base_site] || raise(StandardWorkflowError, "STANDARD_REFERENCE_INVALID")
          raise StandardWorkflowError.new("STANDARD_INPUTS_INCOMPLETE", "base_site") unless input["type"] == "base_site"
          raise StandardWorkflowError, "STANDARD_INPUT_CHANGED" unless inputs_unchanged?([input])

          record = delivery_record!(input.fetch("dataset_id"))
          raise StandardWorkflowError, "STANDARD_DELIVERY_MIXED" unless record["kind"] == "base_site"

          versions = base_site_versions!(input.fetch("path").unpack1("m0"))
          base_site_compatible!(versions, { "discourse_version" => lock.fetch("app").fetch("version") })
          migrations = review_image_migrations
          base_binding = { "input_id" => base_site, "delivery" => record.slice("kind", "version"),
                           "site_schema_version" => migrations.last, "ahead" => versions.fetch("schema_version") > migrations.last }.merge(versions)
          roles["base_site"] = base_site
        end
        delivery = delivery_binding!(source_plan.dig("body", "dataset_id"))
        delivery_roles!(named, roles, delivery)
        limits = review_limits
        review_capacity!(limits, running: false)
        review_port = select_review_port(state, port)
        plan_id = @store.new_id("plan")
        short = plan_id.delete_prefix("plan-")[0, 8]
        ids = roles.values
        source_body = source_plan.fetch("body")
        role_binding = file_role_binding(named, roles)
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
          "runtime_lock_sha256" => runtime_selection.fetch("sha256"),
          "discourse_profile" => runtime_selection.fetch("name"),
          "workspace_runtime_profile_sha256" => state.dig("config", "discourse_profile_sha256"),
          "review_runtime" => runtime_selection.fetch("selection"),
          "base_site_generation" => review_base_generation,
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
        if base_binding
          body["base_site"] = base_binding
          body["outputs"] = { "backup" => "validated SQL-only sandbox plus imported data for #{plan_id}; engineer release to outbox" }
          body["mutations"].insert(1, "restore the bound sandbox SQL backup before importing; preserve sandbox settings and theme")
          body["mutations"].insert(-2, "take a SQL-only backup before creating the local review admin")
          if base_binding["ahead"]
            body["mutations"] << "The base site's schema version (#{base_binding.fetch('schema_version')}) is newer than this server's Discourse (#{base_binding.fetch('site_schema_version')}); hosted sites carry migrations from plugins this image doesn't have. It will be restored anyway."
          end
          body["not_included"] = ["uploads and avatars", "hosted restore", "DNS or cutover", "remote pushes"]
        end
        body["source_file_role_binding"] = source_body["file_role_binding"] if source_body["file_role_binding"]
        body["file_role_binding"] = role_binding if role_binding
        digest = Digest::SHA256.hexdigest(canonical_json(body))
        @store.update do |current|
          verify_file_role_proposal!(body, @store.named_state, source_plan: current.fetch("plans").fetch(source_plan.fetch("id")))
          current.fetch("plans")[plan_id] = {
            "id" => plan_id, "digest" => digest, "body" => body, "status" => "proposed", "created_at" => now, "approval" => nil, "run_id" => nil
          }
        end
        show_plan(plan_id)
      end

      # Engineer only (the Project page's Runs tab, behind the web UI sign-in): the review admin's
      # sign-in while its site exists.
      def admin_password(run_id)
        state = @store.load
        run = state.fetch("runs")[run_id]
        raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless run
        raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" unless review_plan?(state.fetch("plans").fetch(run.fetch("plan_id"), {})) || merge_plan?(state.fetch("plans").fetch(run.fetch("plan_id"), {}))

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

          raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" unless review_plan?(plan) || merge_plan?(plan)

          @store.with_op_lock do
            # Checked again under the lock: a reset may have removed the site meanwhile.
            current = @store.load
            record = current.fetch("instances")[current.dig("runs", run_id, "instances", "review").to_s]
            raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" unless record && %w[imported review dirty setup].include?(record["state"])

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

      # Engineer-only release: never consumes a page/chat approval and never restores
      # remotely. The execution lock also serializes reset and repeated releases.
      def release_backup(run_id:, reviewer:, acknowledge_differences: false)
        unless reviewer.is_a?(String) && reviewer.match?(/\A[[:print:]]{1,120}\z/)
          raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID"
        end
        @store.with_op_lock do
          state = @store.load
          run = state.fetch("runs")[run_id]
          plan = run && state.fetch("plans")[run["plan_id"]]
          unless run && plan && (review_plan?(plan) || merge_plan?(plan)) && plan.dig("body", "base_site") && run["status"] == "completed" && run.dig("artifacts", "backup")
            raise StandardWorkflowError, "STANDARD_RELEASE_NOT_READY"
          end
          raise StandardWorkflowError, "STANDARD_RELEASE_CHECKS" if merge_plan?(plan) && !acknowledge_differences

          artifact = run.fetch("artifacts").fetch("backup")
          source = release_artifact!(artifact)
          results = run.fetch("results")
          checks = merge_plan?(plan) ? 0 : results.fetch("reconciliation_checks", 0)
          unless acknowledge_differences || run.dig("release", "acknowledged_differences") || run.dig("release", "differences_acknowledged") || (checks.positive? && results["reconciliation_matched"] == checks && results.fetch("reconciliation_errors", 0).zero?)
            raise StandardWorkflowError, "STANDARD_RELEASE_CHECKS"
          end
          body = plan.fetch("body")
          outbox = File.join(@store.workspace_root, "outbox")
          release_directory!(outbox)
          filename = artifact.fetch("filename")
          output = File.join(outbox, filename)
          manifest_name = filename.sub(/\.(?:sql|tar)\.gz\z/, "") + ".manifest.json"
          previous = run["release"]
          released_at = previous ? previous.fetch("released_at") : now
          released_by = previous ? previous.fetch("released_by") : reviewer
          acknowledged = previous ? previous.fetch("acknowledged_differences") { previous.fetch("differences_acknowledged") } : acknowledge_differences
          base = body.fetch("base_site")
          input = body.fetch("input_binding").find { |entry| entry["id"] == base.fetch("input_id") }
          manifest = {
            "workspace" => @workspace, "run_id" => run_id, "plan_id" => plan.fetch("id"), "plan_digest" => plan.fetch("digest"),
            "delivery" => body.fetch("delivery").slice("kind", "version"),
            "base_site" => base.merge("sha256" => input.fetch("sha256")),
            "converter_revision" => (body["converter_revision"] || body.dig("from_run", "converter_revision")), "app_revision" => body["app_revision"],
            "discourse_version" => results["discourse_version"], "schema_version" => results["schema_version"],
            "review_runtime" => results["review_runtime"],
            "check_totals" => { "checks" => checks, "matched" => results.fetch("reconciliation_matched", 0),
                                "differs" => results.fetch("reconciliation_differs", 0), "errors" => results.fetch("reconciliation_errors", 0) },
            "differences_acknowledged" => acknowledged,
            "imported_totals" => results.slice("imported_users", "imported_topics", "imported_posts", "imported_attachments"),
            "backup" => artifact.slice("filename", "sha256", "bytes"), "released_at" => released_at, "released_by" => released_by,
            "restore_note" => "Restore on a site at schema version #{results.fetch('backup_schema_version')} or newer (same or newer Discourse)."
          }
          release_backup_file!(source, output, artifact)
          # Re-hash the delivered bytes, too: a source modified during the copy is never released.
          release_artifact!(artifact.merge("path" => output))
          release_write!(File.join(outbox, manifest_name)) { |file| file.write(JSON.pretty_generate(manifest) + "\n") }
          release = { "released_at" => released_at, "released_by" => released_by, "sha256" => artifact.fetch("sha256"),
                      "path" => output, "filename" => filename, "outbox" => outbox, "manifest" => manifest_name,
                      "acknowledged_differences" => acknowledged }
          @store.update { |current| current.fetch("runs").fetch(run_id)["release"] = release }
          { run_id: run_id, outbox: outbox, filename: filename, sha256: artifact.fetch("sha256"), bytes: artifact.fetch("bytes"),
            manifest: manifest_name, released_at: released_at, released_by: released_by }
        end
      end

      private

      # The review module precedes the convert module in method lookup; all other plans
      # retain the existing stage selector.
      def stages_for(plan)
        return StandardMergeRun::MERGE_STAGES if merge_plan?(plan)
        return BASE_SITE_STAGES if review_plan?(plan) && plan.dig("body", "base_site")

        super
      end

      def review_environment(port)
        { "DISCOURSE_LOGIN_REQUIRED" => "true", "DISCOURSE_BACKUP_LOCATION" => "local",
          "DISCOURSE_ENABLE_S3_UPLOADS" => "false", "DISCOURSE_FORCE_HTTPS" => "false",
          "DISCOURSE_ENABLE_LOCAL_LOGINS" => "true", "DISCOURSE_ENABLE_DISCOURSE_CONNECT" => "false",
          "DISCOURSE_DOWNLOAD_REMOTE_IMAGES_TO_LOCAL" => "false", "DISCOURSE_ENFORCE_SECOND_FACTOR" => "no",
          "DISCOURSE_PORT" => port.to_s }
      end

      def base_site_versions!(filename)
        DiscourseVersion.backup(filename) || raise(StandardWorkflowError, "STANDARD_BASE_SITE_INVALID")
      end

      def base_site_compatible!(backup, site)
        return unless backup["discourse_version"]

        requested = DiscourseVersion.parse(backup.fetch("discourse_version"))
        actual = DiscourseVersion.parse(site.fetch("discourse_version"))
        raise StandardWorkflowError, "STANDARD_BASE_SITE_INVALID" unless requested && actual
        if requested[:version] > actual[:version]
          raise StandardWorkflowError, "STANDARD_BASE_SITE_NEWER"
        end
      end

      # Image files, not a mutable tag or a pinned profile edit. The resolved image
      # content ID keys this process-local cache; runtime staleness remains digest-bound.
      def review_image_migrations
        image = lock.fetch("images").fetch("web")
        @review_image_migrations ||= {}
        @review_image_migrations[image.fetch("content_id")] ||= begin
          id = ImageIdentity.resolve(@runtime, image)
          script = 'require "json"; root = "/var/www/discourse"; paths = %w[db/migrate db/post_migrate plugins/*/db/migrate plugins/*/db/post_migrate]; puts JSON.generate(paths.flat_map { |p| Dir.glob("#{root}/#{p}/[0-9]*_*.rb") }.filter_map { |p| File.basename(p)[/\A(\d{14})_/, 1] }.uniq.sort)'
          result = @runtime.run(["docker", "run", "--rm", "--pull=never", "--network", "none", "--entrypoint", "ruby", id, "-e", script], capture: true, timeout: 60)
          versions = result.success? ? JSON.parse(result.stdout) : nil
          unless versions.is_a?(Array) && !versions.empty? && versions.all? { |version| version.is_a?(String) && version.match?(/\A\d{14}\z/) }
            raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH"
          end
          versions.uniq.sort
        end
      rescue JSON::ParserError
        raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH"
      end

      # PostgreSQL's SQL-only dump uses COPY for schema_migrations. Never buffer a
      # dump line without a limit: other tables can contain multi-GB text values.
      def base_site_dump_migrations!(path)
        versions = Set.new
        buffer = +"".b
        oversized = false
        inside = false
        complete = false
        Zlib::GzipReader.open(path) do |gzip|
          while (chunk = gzip.read(64 * 1024)) && !chunk.empty?
            chunk.each_line do |part|
              if buffer.bytesize + part.bytesize > 1024
                oversized = true
                buffer.clear
              end
              buffer << part unless oversized
              next unless part.end_with?("\n")

              line = buffer.strip
              if inside
                if !oversized && line == '\\.'
                  inside = false
                  complete = true
                elsif !oversized && line.match?(/\A\d{14}\z/)
                  versions << line
                  raise StandardWorkflowError, "STANDARD_BASE_SITE_INVALID" if versions.size > 100_000
                else
                  raise StandardWorkflowError, "STANDARD_BASE_SITE_INVALID"
                end
              elsif !oversized && line.match?(/\ACOPY (?:public\.)?schema_migrations \(version\) FROM stdin;\z/)
                raise StandardWorkflowError, "STANDARD_BASE_SITE_INVALID" if complete

                # A COPY-header-looking data row can only cause refusal, never bypass validation.
                inside = true
              end
              buffer.clear
              oversized = false
            end
          end
          raise StandardWorkflowError, "STANDARD_BASE_SITE_INVALID" unless gzip.unused.to_s.empty?
        end
        raise StandardWorkflowError, "STANDARD_BASE_SITE_INVALID" unless complete && !inside && !versions.empty?

        versions.to_a.sort
      rescue Zlib::Error, EOFError, SystemCallError
        raise StandardWorkflowError, "STANDARD_BASE_SITE_INVALID"
      end

      def stage_base_restore(run_id)
        binding = plan_for(run_id).fetch("body").fetch("base_site")
        stack = stack_for(run_id, "review")
        site = stack.rails_runner("/tmp/review_state.rb")
        begin
          base_site_compatible!(binding, site)
        rescue StandardWorkflowError => error
          raise unless %w[STANDARD_BASE_SITE_NEWER STANDARD_BASE_SITE_INVALID].include?(error.code)
          raise StandardWorkflowError, "STANDARD_REVIEW_RUNTIME_CHANGED"
        end
        ahead = binding.fetch("schema_version") > site.fetch("schema_version").to_s
        unless ahead == binding.fetch("ahead") && site.fetch("schema_version").to_s == binding.fetch("site_schema_version")
          raise StandardWorkflowError, "STANDARD_REVIEW_RUNTIME_CHANGED"
        end
        input = role_input(run_inputs(run_id), "base_site")
        archive = input_path(run_id, input)
        versions = base_site_dump_migrations!(archive)
        raise StandardWorkflowError, "STANDARD_BASE_SITE_INVALID" unless versions.last == binding.fetch("schema_version")

        known = site.fetch("migration_versions").to_set
        record_results(run_id, base_site_unknown_migrations: versions.count { |version| !known.include?(version) },
                       base_site_newer_migrations: versions.select { |version| version > site.fetch("schema_version").to_s }.first(50))
        restore_versions = ahead ? site : binding
        suffix = "-v#{restore_versions["discourse_version"]&.tr(".", "-")&.+("-")}#{restore_versions.fetch("schema_version")}.sql.gz"
        restore_archive(run_id, stack, archive, "base-restore", expected_sha256: input.fetch("sha256"), safe_filename: "silo-base#{suffix}")
        wait_restored_web(stack, internal: true)
        restored = stack.rails_runner("/tmp/review_state.rb")
        unless restored.dig("settings", "allow_restore") == false && (review_image_migrations - restored.fetch("migration_versions")).empty?
          raise StandardWorkflowError, "STANDARD_RESTORE_FAILED"
        end
        record_review_runtime(run_id, schema_after_restore: restored.fetch("schema_version"),
                              known_migrations_complete: true)
        record_results(run_id, base_site: true, base_site_ahead: ahead, base_discourse_version: binding["discourse_version"], base_schema_version: binding["schema_version"],
                       discourse_version: site.fetch("discourse_version"), site_schema_version: site.fetch("schema_version"),
                       schema_version: restored.fetch("schema_version"), prior_import_id_rows: restored.fetch("prior_import_id_rows"))
      end

      # Stream the entire gzip, including its trailer, in bounded memory. Preserve a
      # small overlap so forbidden identities crossing a chunk boundary cannot escape.
      def validate_sql_backup!(path)
        versions = base_site_versions!(path)
        raise StandardWorkflowError, "STANDARD_BACKUP_FAILED" unless File.file?(path) && !File.symlink?(path) && File.size(path).positive?

        bytes = 0
        header = +"".b
        tail = +"".b
        Zlib::GzipReader.open(path) do |gzip|
          while (chunk = gzip.read(64 * 1024)) && !chunk.empty?
            bytes += chunk.bytesize
            header << chunk.byteslice(0, [8192 - header.bytesize, 0].max)
            scan = tail + chunk
            if scan.include?(REVIEW_ADMIN) || scan.include?("review-admin@example.invalid")
              raise StandardWorkflowError.new("STANDARD_BACKUP_FAILED", "local review identity in backup")
            end
            tail = scan.byteslice(-64, 64) || scan
          end
          raise StandardWorkflowError, "STANDARD_BACKUP_FAILED" unless gzip.unused.to_s.empty?
        end
        unless bytes.positive? && header.include?("PostgreSQL database dump")
          raise StandardWorkflowError.new("STANDARD_BACKUP_FAILED", "not a PostgreSQL dump")
        end
        versions
      rescue Zlib::Error, EOFError, SystemCallError
        raise StandardWorkflowError.new("STANDARD_BACKUP_FAILED", "invalid SQL gzip")
      end

      def stage_backup(run_id)
        return merge_backup(run_id) if merge_plan?(plan_for(run_id))
        stack = stack_for(run_id, "review")
        stem = "#{@workspace}-#{run_id}"
        remote = "/shared/silo-review-backup"
        made = stack.web_exec(["sh", "-c", "mkdir -m 700 #{remote} && chown discourse:discourse #{remote}"], timeout: 30)
        raise StandardWorkflowError, "STANDARD_BACKUP_FAILED" unless made.success?

        result = stack.discourse_shell(["bundle", "exec", "script/discourse", "backup", "#{remote}/#{stem}.sql.gz", "--sql-only"], timeout: 3600)
        log(run_id, "review-backup", result)
        raise StandardWorkflowError, "STANDARD_BACKUP_FAILED" unless result.success?

        listing = stack.web_exec(["find", remote, "-mindepth", "1", "-maxdepth", "1", "-printf", "%f\n"], timeout: 30)
        files = listing.stdout.to_s.lines.map(&:strip)
        unless listing.success? && files.size == 1 && files.first.start_with?("#{stem}-v") && File.basename(files.first) == files.first
          raise StandardWorkflowError, "STANDARD_BACKUP_FAILED"
        end
        base_site_versions!(files.first)
        dir = @store.run_dir(run_id, "artifacts")
        FileUtils.mkdir_p(dir, mode: 0o700)
        path = File.join(dir, files.first)
        stack.copy_out("#{remote}/#{files.first}", path)
        versions = validate_sql_backup!(path)
        File.chmod(0o400, path)
        identity = artifact_identity(path).merge("path" => path, "label" => "sql-validated")
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("artifacts")["backup"] = identity }
        record_results(run_id, backup_discourse_version: versions["discourse_version"], backup_schema_version: versions["schema_version"])
      end

      def release_artifact!(artifact)
        filename = artifact.fetch("filename")
        unless File.basename(filename) == filename && filename.match?(/\A[a-zA-Z0-9_.-]+\.(?:sql|tar)\.gz\z/)
          raise StandardWorkflowError, "STANDARD_ARTIFACT_CHANGED"
        end
        path = artifact.fetch("path")
        File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          stat = file.stat
          digest = Digest::SHA256.new
          while (chunk = file.read(1024 * 1024))
            digest.update(chunk)
          end
          unless stat.file? && stat.size == artifact.fetch("bytes") && digest.hexdigest == artifact.fetch("sha256")
            raise StandardWorkflowError, "STANDARD_ARTIFACT_CHANGED"
          end
        end
        path
      rescue SystemCallError, KeyError
        raise StandardWorkflowError, "STANDARD_ARTIFACT_CHANGED"
      end

      def release_directory!(path)
        begin
          Dir.mkdir(path, 0o700)
        rescue Errno::EEXIST
          # Refuse links even when they point to the expected location.
        end
        File.open(path, File::RDONLY | File::NOFOLLOW) do |directory|
          raise StandardWorkflowError, "STANDARD_RELEASE_NOT_READY" unless directory.stat.directory?

          directory.chmod(0o700)
        end
      rescue Errno::ELOOP, Errno::ENOTDIR
        raise StandardWorkflowError, "STANDARD_RELEASE_NOT_READY"
      end

      # Completed backup artifacts are immutable (0400); reset only unlinks them.
      # A hard link therefore survives reset without either path being rewritten.
      def release_backup_file!(source, output, artifact)
        raise StandardWorkflowError, "STANDARD_RELEASE_NOT_READY" if File.symlink?(output)
        if File.exist?(output)
          release_artifact!(artifact.merge("path" => output))
          return
        end
        temporary = "#{output}.tmp-#{SecureRandom.hex(12)}"
        begin
          begin
            File.link(source, temporary)
          rescue Errno::EXDEV, Errno::EPERM, Errno::EACCES, Errno::ENOTSUP
            release_write!(temporary) do |file|
              File.open(source, File::RDONLY | File::NOFOLLOW) { |input| IO.copy_stream(input, file) }
            end
          end
          release_artifact!(artifact.merge("path" => temporary))
          File.rename(temporary, output)
        ensure
          FileUtils.rm_f(temporary)
        end
      end

      def release_write!(path)
        raise StandardWorkflowError, "STANDARD_RELEASE_NOT_READY" if File.symlink?(path)

        temporary = "#{path}.tmp-#{SecureRandom.hex(12)}"
        begin
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
            yield file
            file.chmod(0o400)
            file.flush
            file.fsync
          end
          File.rename(temporary, path)
        ensure
          FileUtils.rm_f(temporary)
        end
      end


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
        return "delivery" if !body["file_role_binding"] && body["base_site_generation"] && body["base_site_generation"] != review_base_generation

        named = @store.named_state
        ids = body.fetch("input_binding").map { |input| input["id"] }
        return "inputs" unless ids.all? { |id| named.fetch("inputs").key?(id) }
        return "inputs" unless @store.named.input_binding(named, ids) == body.fetch("input_stat_binding")
        return "inputs" unless inputs_unchanged?(ids.map { |id| named.fetch("inputs").fetch(id) })
        delivery_roles!(named, body.fetch("roles"), delivery_binding!(body.fetch("dataset_id")))
        if body["base_site"]
          input = named.fetch("inputs").fetch(body.dig("roles", "base_site"))
          record = delivery_record!(input.fetch("dataset_id"))
          return "delivery" unless record.slice("kind", "version") == body.dig("base_site", "delivery")
        end
        return "code" unless code_identity == body.fetch("code_identity")
        return "runtime" unless review_runtime_current?(body, state.fetch("config"))

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

      def record_review_runtime(run_id, **observed)
        selection = plan_for(run_id).dig("body", "review_runtime")
        return unless selection

        previous = @store.load.dig("runs", run_id, "results", "review_runtime") || selection
        result = previous.merge(observed.transform_keys(&:to_s))
        record_results(run_id, review_runtime: result)
        evidence(run_id, "review-runtime.json", result)
      end

      def review_preflight(run_id, plan)
        body = plan.fetch("body")
        resolved = lock.fetch("images").transform_values { |image| ImageIdentity.resolve(@runtime, image) }
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("artifacts")["resolved_image_ids"] = resolved }
        evidence(run_id, "runtime-images.json", JSON.pretty_generate(resolved) + "\n")
        record_review_runtime(run_id, resolved_image_id: resolved.fetch("web"))
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
        base = plan_for(run_id).dig("body", "base_site")
        if base && !@store.load.dig("runs", run_id, "artifacts", "backup")
          raise StandardWorkflowError, "STANDARD_RELEASE_NOT_READY"
        end
        stack = stack_for(run_id, "review")
        secrets = @store.run_dir(run_id, "private", "review-setup.env")
        FileUtils.rm_f(secrets)
        password = SecureRandom.urlsafe_base64(24)
        @store.write_private(@store.run_dir(run_id, "private", "admin-password"), password)
        @store.write_private(secrets, "SILO_ADMIN_PASSWORD=#{password}\n")
        port = stack.record.fetch("port")
        result = begin
          stack.rails_runner(base ? "/tmp/review_access.rb" : "/tmp/review_setup.rb",
                             env: { "SILO_SITE_PORT" => port.to_s, "SILO_BACKUP_RECORDED" => base ? "true" : "false" }, env_file: secrets)
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
        failures = review_safety_failures(stack, base_site: !!plan.dig("body", "base_site"))
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
      def review_safety_failures(stack, base_site: false)
        if base_site
          facts = stack.rails_runner("/tmp/review_state.rb")
          effective = facts.fetch("settings")
          environment = stack.web_exec(%w[printenv DISCOURSE_DISABLE_EMAILS], timeout: 30)
          failures = []
          failures << "review-email-not-disabled" unless environment.success? && environment.stdout.to_s.strip == "yes" && effective["disable_emails"] == "yes"
          failures << "review-login-not-required" unless effective["login_required"] == true
          failures << "review-restore-enabled" unless effective["allow_restore"] == false
          review_environment(stack.record.fetch("port")).each do |key, value|
            setting = key.delete_prefix("DISCOURSE_").downcase
            expected = %w[true false].include?(value) ? value == "true" : value
            matches = setting == "port" ? effective[setting].to_s == value : effective[setting] == expected
            failures << "review-shadow-#{setting}" unless matches
          end
          return failures
        end
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
