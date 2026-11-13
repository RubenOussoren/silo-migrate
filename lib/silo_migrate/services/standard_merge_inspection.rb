# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "set"
require "openssl"

module SiloMigrate
  module Services
    # Trusted, local, generation-bound inspection access for a prepared merge environment.
    #
    # * Base/result: a dedicated local identity on the running review site with ONE single-user
    #   API key in server-enforced read_only scope mode (global:read, GET only). The key is
    #   written inside the web container to a private file, copied out with `docker cp` to the
    #   run's private directory (0600) and removed from the container. It is never printed,
    #   logged, put in argv or recorded in public state.
    # * Source: a login role on the prepared source inspection database with column-level SELECT
    #   from a versioned, reviewed policy (SOURCE_READ_POLICY). Unknown/plugin tables and known
    #   auth/secret tables are never granted; DBHub sessions are read-only.
    #
    # The private manifest (run_dir/private/merge-access.json, 0600, never public) binds the
    # endpoints to run/preparation/generation/phase and the exact stack container/network IDs.
    # bin/merge_mcp.py only launches connectors for an "open" manifest of the requested
    # generation, verified under the same flock this module holds exclusively while fencing.
    #
    # Lifecycle contract (the merge workflow calls these, already holding the run's op lock):
    #   merge_inspection_open(run_id, phase: "base")   after inspection clones are active and the
    #                                                  Base web is available;
    #   merge_inspection_close(run_id)                 before merge/reset (fences everything);
    #   merge_inspection_open(run_id, phase: "result") only after the clean backup is recorded.
    # Errors are fixed codes; raw exceptions, SQL output and HTTP logs never leave this module.
    module StandardMergeInspection
      INSPECTION_MANIFEST_VERSION = 1
      INSPECTION_PHASES = %w[base result].freeze
      INSPECTION_SITE = "http://web" # the stack's internal network alias; no published/external route
      INSPECTION_ROLE_PREFIX = "silo_mi_"
      INSPECTION_LABEL_RUN = "silo.merge-run"
      INSPECTION_LABEL_ROLE = "silo.role"
      INSPECTION_LAUNCH_ROLES = %w[merge-mcp merge-dbhub].freeze
      INSPECTION_STATEMENT_TIMEOUT = 120
      INSPECTION_GENERATION = /\A[0-9a-f]{64}\z/
      INSPECTION_DB_NAME = /\A[a-z_][a-z0-9_]{0,62}\z/
      INSPECTION_DB_OID = /\A[1-9][0-9]{0,9}\z/
      INSPECTION_SITE_DATABASE = "discourse" # the review web's database name (clone, then result)
      INSPECTION_CREDENTIALS = { "base" => "base.key", "result" => "result.key", "source" => "source.env" }.freeze

      # Reviewed Discourse core tables/columns readable on the prepared source. Anything not
      # listed (plugin tables, new core tables, new columns) stays ungranted and is reported
      # privately as unreviewed. Custom-field/site-setting VALUES are excluded: plugins store
      # tokens there. Emails are excluded in v1 (show_emails stays false on the API side too).
      SOURCE_READ_POLICY_VERSION = "merge-source-read-v2"
      SOURCE_READ_POLICY = {
        "schema_migrations" => %w[version],
        "users" => %w[id username username_lower name active approved admin moderator trust_level staged created_at updated_at
                      last_seen_at last_posted_at suspended_at suspended_till silenced_till primary_group_id title locale
                      flair_group_id uploaded_avatar_id views],
        "user_profiles" => %w[user_id location website bio_raw profile_background_upload_id card_background_upload_id views],
        "user_stats" => %w[user_id topics_entered time_read days_visited posts_read_count likes_given likes_received
                           topic_count post_count first_post_created_at],
        "user_emails" => %w[id user_id primary created_at updated_at],
        "user_custom_fields" => %w[id user_id name created_at updated_at],
        "user_fields" => %w[id name field_type editable description required show_on_profile show_on_user_card position],
        "user_avatars" => %w[id user_id custom_upload_id gravatar_upload_id],
        "groups" => %w[id name full_name automatic visibility_level members_visibility_level user_count created_at updated_at
                       primary_group title grant_trust_level mentionable_level messageable_level],
        "group_users" => %w[id group_id user_id owner created_at updated_at notification_level],
        "group_custom_fields" => %w[id group_id name created_at updated_at],
        "categories" => %w[id name slug parent_category_id position read_restricted topic_count post_count user_id
                           created_at updated_at description topic_id uploaded_logo_id uploaded_background_id],
        "category_groups" => %w[id category_id group_id permission_type created_at updated_at],
        "category_users" => %w[id category_id user_id notification_level],
        "category_custom_fields" => %w[id category_id name created_at updated_at],
        "category_tags" => %w[id category_id tag_id],
        "topics" => %w[id title slug user_id category_id archetype visible closed archived pinned_at pinned_globally
                       created_at updated_at bumped_at last_posted_at posts_count reply_count like_count views deleted_at
                       subtype featured_link],
        "topic_custom_fields" => %w[id topic_id name created_at updated_at],
        "topic_allowed_users" => %w[id topic_id user_id],
        "topic_allowed_groups" => %w[id topic_id group_id],
        "topic_tags" => %w[id topic_id tag_id],
        "posts" => %w[id topic_id user_id post_number reply_to_post_number raw post_type created_at updated_at deleted_at
                      hidden like_count reply_count quote_count version wiki],
        "post_custom_fields" => %w[id post_id name created_at updated_at],
        "post_actions" => %w[id post_id user_id post_action_type_id created_at deleted_at],
        "tags" => %w[id name topic_count created_at updated_at target_tag_id],
        "tag_groups" => %w[id name parent_tag_id one_per_topic],
        "tag_group_memberships" => %w[id tag_id tag_group_id],
        "uploads" => %w[id user_id original_filename filesize width height url sha1 extension origin created_at updated_at
                        secure access_control_post_id],
        "upload_references" => %w[id upload_id target_type target_id created_at],
        "badges" => %w[id name badge_type_id grant_count enabled system],
        "user_badges" => %w[id badge_id user_id granted_at post_id],
        "bookmarks" => %w[id user_id bookmarkable_id bookmarkable_type name created_at],
        "permalinks" => %w[id url topic_id post_id category_id tag_id user_id external_url],
        "site_settings" => %w[id name data_type created_at updated_at]
      }.freeze
      # Never granted, even if a later policy lists them: credentials, sessions and mail payloads.
      SOURCE_READ_EXCLUDED = %w[api_keys api_key_scopes user_api_keys user_api_key_scopes user_api_key_clients
                                user_auth_tokens user_auth_token_logs email_tokens user_second_factors user_security_keys
                                user_passwords oauth2_user_infos user_associated_accounts single_sign_on_records invites
                                web_hooks web_hook_events email_logs incoming_emails skipped_email_logs user_histories
                                screened_ip_addresses user_ip_address_histories].freeze

      def self.source_read_policy_sha256
        Digest::SHA256.hexdigest(JSON.generate([SOURCE_READ_POLICY_VERSION, SOURCE_READ_POLICY.sort, SOURCE_READ_EXCLUDED.sort]))
      end

      # -- lifecycle ------------------------------------------------------------------

      # Explicit keywords let the lifecycle pass its own facts; otherwise they are read from the
      # run's private merge_environment record (see merge_inspection_context).
      def merge_inspection_open(run_id, phase:, generation: nil, preparation_run_id: nil, source_database: nil, site_database_oid: nil)
        inspection_refuse!("STANDARD_MERGE_INSPECTION_INVALID") unless run_id.is_a?(String) && run_id.match?(StandardReviewRun::RUN_ID) && INSPECTION_PHASES.include?(phase)
        context = merge_inspection_context(run_id, phase).merge(
          { "generation" => generation, "preparation_run_id" => preparation_run_id, "source_database" => source_database,
            "site_database_oid" => site_database_oid&.to_s }.compact
        )
        generation = context["generation"]
        preparation = context["preparation_run_id"] || run_id
        source_db = context["source_database"]
        # Base: the checkpoint's inspection clone, by pg_database OID (the clone and the sealed
        # pristine Base share the name "discourse" at different times). Result: observed at open.
        site_oid = context["site_database_oid"]
        inspection_refuse!("STANDARD_MERGE_INSPECTION_INVALID") unless phase == "result" ? site_oid.nil? || site_oid.match?(INSPECTION_DB_OID) : site_oid.to_s.match?(INSPECTION_DB_OID)
        unless generation.is_a?(String) && generation.match?(INSPECTION_GENERATION) && preparation.is_a?(String) && preparation.match?(StandardReviewRun::RUN_ID) &&
               (phase == "result" || (source_db.is_a?(String) && source_db.match?(INSPECTION_DB_NAME) && !%w[discourse postgres template0 template1].include?(source_db)))
          inspection_refuse!("STANDARD_MERGE_INSPECTION_INVALID")
        end
        with_inspection_lock(run_id) do
          # Under the lock: result credentials only for this run's own recorded clean backup of
          # exactly this prepared environment generation (never any truthy/older artifact).
          state = @store.load
          run = state.fetch("runs")[run_id] || inspection_refuse!("STANDARD_MERGE_INSPECTION_INVALID")
          result_backup_bound!(state, run_id, run, generation, preparation) if phase == "result"
          existing = read_inspection_manifest(run_id)
          if existing && %w[opening open fencing].include?(existing["state"])
            # Idempotent re-open of the same phase/generation; anything else must be fenced first.
            if existing["state"] == "open" && existing["phase"] == phase && existing["generation"] == generation
              return inspection_summary(existing)
            end

            inspection_refuse!("STANDARD_MERGE_INSPECTION_ORDER")
          end

          stack = stack_for(run_id, "review")
          inspection_refuse!("STANDARD_MERGE_INSPECTION_UNAVAILABLE") unless stack.live? == true
          containers = stack.record.fetch("containers")
          internal = stack.record.fetch("networks").find { |name| name == "#{stack.name}-int" }
          inspection_refuse!("STANDARD_MERGE_INSPECTION_UNAVAILABLE") unless internal && containers["web"] && containers["db"]

          manifest = {
            "version" => INSPECTION_MANIFEST_VERSION, "run_id" => run_id, "preparation_run_id" => preparation,
            "generation" => generation, "phase" => phase, "state" => "opening",
            "owner" => { "workspace" => @workspace, "instance" => stack.name },
            "containers" => { "web" => containers.fetch("web"), "db" => containers.fetch("db") },
            "network" => internal, "port" => stack.record["port"], "endpoints" => {}, "updated_at" => now
          }
          # Recorded before anything is minted, so a crash leaves only owned, fenceable resources.
          write_inspection_manifest(run_id, manifest)
          begin
            open_site_endpoint(run_id, stack, manifest, phase, site_oid)
            open_source_endpoint(run_id, stack, manifest, source_db) if phase == "base"
            manifest["state"] = "open"
            manifest["updated_at"] = now
            write_inspection_manifest(run_id, manifest)
          rescue StandardError => error
            begin
              fence_inspection!(run_id, manifest)
            rescue StandardError
              nil # the manifest stays "fencing"; close retries
            end
            raise error if error.is_a?(StandardWorkflowError) && error.code.to_s.start_with?("STANDARD_MERGE_INSPECTION_")

            inspection_refuse!("STANDARD_MERGE_INSPECTION_UNAVAILABLE")
          end
          inspection_summary(manifest)
        end
      end

      # Fence: no new launches (manifest state under the exclusive lock), remove exact launcher
      # containers, revoke API keys, make the read role NOLOGIN, terminate its sessions, drop it
      # and delete private credential/profile files. Idempotent; safe without a manifest.
      def merge_inspection_close(run_id)
        inspection_refuse!("STANDARD_MERGE_INSPECTION_INVALID") unless run_id.is_a?(String) && run_id.match?(StandardReviewRun::RUN_ID)
        with_inspection_lock(run_id) do
          manifest = read_inspection_manifest(run_id)
          # Even without a manifest, owned launcher containers for this run are removed.
          unless manifest
            remove_inspection_launchers!(run_id)
            return { "version" => 1, "run_id" => run_id, "state" => "closed", "endpoints" => [] }
          end
          return inspection_summary(manifest) if manifest["state"] == "closed"

          fence_inspection!(run_id, manifest)
          inspection_summary(manifest)
        end
      rescue StandardWorkflowError
        raise
      rescue StandardError
        inspection_refuse!("STANDARD_MERGE_INSPECTION_FENCE_FAILED")
      end

      private

      # Override point for the lifecycle: the prepared environment facts for this run.
      def merge_inspection_context(run_id, _phase)
        run = @store.load.fetch("runs")[run_id] || {}
        environment = run["merge_environment"] || run.dig("results", "merge_environment") || {}
        environment = {} unless environment.is_a?(Hash)
        { "generation" => environment["generation"], "preparation_run_id" => environment["preparation_run_id"],
          "source_database" => environment["source_inspection_database"],
          "site_database_oid" => environment["base_inspection_database_oid"]&.to_s }.compact
      end

      def inspection_refuse!(code)
        raise StandardWorkflowError, code
      end

      def result_backup_bound!(state, run_id, run, generation, preparation)
        backup = run.dig("artifacts", "backup")
        inspection_refuse!("STANDARD_MERGE_INSPECTION_ORDER") unless backup.is_a?(Hash)
        plan = state.fetch("plans", {})[run["plan_id"]]
        body = plan.is_a?(Hash) ? plan["body"] : nil
        prepared = body.is_a?(Hash) ? body["prepared_from"] : nil
        unless body.is_a?(Hash) && body["operation"] == "standard_merge" && prepared.is_a?(Hash) && plan["run_id"] == run_id &&
               prepared["generation"] == generation && prepared["run_id"] == preparation &&
               backup["merge_generation"] == generation && backup["preparation_run_id"] == preparation
          inspection_refuse!("STANDARD_MERGE_INSPECTION_STALE")
        end
      end

      def inspection_summary(manifest)
        { "version" => 1, "run_id" => manifest["run_id"], "phase" => manifest["phase"], "generation" => manifest["generation"],
          "state" => manifest["state"], "endpoints" => manifest.fetch("endpoints", {}).select { |_, e| e["state"] == "open" }.keys.sort,
          "policy" => manifest.dig("endpoints", "source", "policy", "version"),
          "granted_tables" => manifest.dig("endpoints", "source", "policy", "granted_tables"),
          "unreviewed_tables" => manifest.dig("endpoints", "source", "policy", "unreviewed_tables") }.compact
      end

      # -- private files ---------------------------------------------------------------

      def inspection_private_dir(run_id)
        dir = @store.run_dir(run_id, "private")
        # Confined: no symlink anywhere from the standard root down to the private directory.
        path = @store.root
        ["runs", run_id, "private"].each do |part|
          path = File.join(path, part)
          inspection_refuse!("STANDARD_MERGE_INSPECTION_INVALID") if File.symlink?(path) || (File.exist?(path) && !File.directory?(path))
        end
        FileUtils.mkdir_p(dir, mode: 0o700)
        File.chmod(0o700, dir)
        dir
      end

      def inspection_credentials_dir(run_id)
        dir = File.join(inspection_private_dir(run_id), "merge-inspection")
        inspection_refuse!("STANDARD_MERGE_INSPECTION_INVALID") if File.symlink?(dir)
        Dir.mkdir(dir, 0o700) unless File.directory?(dir)
        File.chmod(0o700, dir)
        dir
      end

      def with_inspection_lock(run_id)
        path = File.join(inspection_private_dir(run_id), "merge-access.lock")
        File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
          until lock.flock(File::LOCK_EX | File::LOCK_NB)
            inspection_refuse!("STANDARD_BUSY") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            sleep 0.2
          end
          begin
            yield
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      rescue Errno::ELOOP, Errno::EACCES
        inspection_refuse!("STANDARD_MERGE_INSPECTION_INVALID")
      end

      def inspection_manifest_path(run_id)
        File.join(inspection_private_dir(run_id), "merge-access.json")
      end

      def read_inspection_manifest(run_id)
        path = inspection_manifest_path(run_id)
        return nil unless File.exist?(path) || File.symlink?(path)

        File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          stat = file.stat
          inspection_refuse!("STANDARD_MERGE_INSPECTION_INVALID") unless stat.file? && stat.size <= 256 * 1024 && (stat.mode & 0o077).zero?
          manifest = JSON.parse(file.read)
          unless manifest.is_a?(Hash) && manifest["version"] == INSPECTION_MANIFEST_VERSION && manifest["run_id"] == run_id
            inspection_refuse!("STANDARD_MERGE_INSPECTION_INVALID")
          end
          manifest
        end
      rescue JSON::ParserError, Errno::ELOOP
        inspection_refuse!("STANDARD_MERGE_INSPECTION_INVALID")
      end

      def write_inspection_manifest(run_id, manifest)
        @store.write_private(inspection_manifest_path(run_id), JSON.pretty_generate(manifest) + "\n")
      end

      def write_inspection_secret(run_id, name, content)
        inspection_refuse!("STANDARD_MERGE_INSPECTION_INVALID") unless INSPECTION_CREDENTIALS.value?(name)
        path = File.join(inspection_credentials_dir(run_id), name)
        @store.write_private(path, content)
        Digest::SHA256.hexdigest(content)
      end

      # -- base/result: Discourse API identity --------------------------------------------

      # The site database the web is expected to be serving, as {"name", "oid"}: the bound OID must
      # currently carry the site database name on the manifest's own db container.
      def site_database_binding!(manifest, oid)
        db = inspection_db(manifest)
        if oid.nil?
          oid = inspection_psql(db, "postgres", "SELECT oid FROM pg_database WHERE datname = '#{INSPECTION_SITE_DATABASE}';\n").to_s.strip
        end
        name = oid.match?(INSPECTION_DB_OID) ? inspection_psql(db, "postgres", "SELECT datname FROM pg_database WHERE oid = #{oid};\n").to_s.strip : nil
        inspection_refuse!("STANDARD_MERGE_INSPECTION_STALE") unless name == INSPECTION_SITE_DATABASE
        { "name" => INSPECTION_SITE_DATABASE, "oid" => oid }
      end

      def open_site_endpoint(run_id, stack, manifest, phase, site_oid)
        binding = site_database_binding!(manifest, site_oid)
        token = SecureRandom.hex(8)
        username = "silo_inspect_#{SecureRandom.hex(4)}"
        guest_dir = "/tmp/silo-inspection-#{token}"
        helper = File.join(helper_dir, "merge_inspection_access.rb")
        guest_helper = "/tmp/merge_inspection_access.rb"
        endpoint = { "state" => "opening", "kind" => "discourse-mcp", "site" => INSPECTION_SITE, "username" => username,
                     "database" => binding, "credential" => INSPECTION_CREDENTIALS.fetch(phase), "opened_at" => now }
        # Identity recorded before minting, so a fence can always find and revoke it.
        manifest["endpoints"][phase] = endpoint
        write_inspection_manifest(run_id, manifest)
        stack.copy_in(helper, guest_helper)
        facts = stack.rails_runner(guest_helper, env: { "SILO_INSPECTION_ACTION" => "create", "SILO_INSPECTION_USERNAME" => username,
                                                        "SILO_INSPECTION_KEY_DIR" => guest_dir }.merge(site_database_env(binding)), timeout: 300)
        unless facts.is_a?(Hash) && facts["database_oid"] == binding["oid"] && facts["username"] == username && facts["scope_mode"] == "read_only" && facts["scopes"] == ["global:read"] &&
               facts["api_key_id"].is_a?(Integer) && facts["user_id"].is_a?(Integer)
          inspection_refuse!("STANDARD_MERGE_INSPECTION_UNSUPPORTED")
        end
        endpoint.merge!("user_id" => facts["user_id"], "api_key_id" => facts["api_key_id"], "scope_mode" => "read_only", "scopes" => ["global:read"])
        write_inspection_manifest(run_id, manifest)

        target = File.join(inspection_credentials_dir(run_id), INSPECTION_CREDENTIALS.fetch(phase))
        staged = "#{target}.copy-#{token}"
        begin
          stack.copy_out("#{guest_dir}/key", staged)
          File.chmod(0o600, staged)
          key = File.open(staged, File::RDONLY | File::NOFOLLOW) { |file| file.read(129) }
          inspection_refuse!("STANDARD_MERGE_INSPECTION_UNAVAILABLE") unless key.is_a?(String) && key.match?(/\A[0-9a-f]{64}\z/)
          endpoint["credential_sha256"] = write_inspection_secret(run_id, INSPECTION_CREDENTIALS.fetch(phase), key)
        ensure
          FileUtils.rm_f(staged)
          stack.web_exec(["rm", "-rf", guest_dir, guest_helper], timeout: 30)
        end
        endpoint["state"] = "open"
        write_inspection_manifest(run_id, manifest)
      end

      def site_database_env(binding)
        { "SILO_INSPECTION_DATABASE" => binding.fetch("name"), "SILO_INSPECTION_DATABASE_OID" => binding.fetch("oid") }
      end

      # Revokes in exactly the bound database. Closed only when proven: the stack was removed, the
      # bound database no longer exists on the owner's db container, or the helper (after checking
      # current_database and its OID) revoked the present identity's keys. A missing identity is
      # accepted only when minting was never acknowledged and the bound database holds no active
      # tool-described key without a live owner; anything else stays unknown and keeps the fence.
      def revoke_site_endpoint!(run_id, stack, endpoint, manifest)
        return true unless endpoint["username"]
        return true if stack.nil? # the owner instance was removed with its volumes

        binding = endpoint["database"]
        return false unless binding.is_a?(Hash) && binding["name"] == INSPECTION_SITE_DATABASE && binding["oid"].to_s.match?(INSPECTION_DB_OID)

        present = inspection_psql(inspection_db(manifest), "postgres", "SELECT count(*) FROM pg_database WHERE oid = #{binding['oid']};\n")
        return false if present.nil?
        return true if present.strip == "0" # the bound clone was dropped: its keys and identity with it
        return false unless present.strip == "1"

        guest_helper = "/tmp/merge_inspection_access.rb"
        stack.copy_in(File.join(helper_dir, "merge_inspection_access.rb"), guest_helper)
        ids = [endpoint["api_key_id"]].compact
        if ids.empty?
          # Minting may have crashed after the key was saved: the helper revokes by identity too.
          ids = [0]
        end
        acknowledged = !endpoint["api_key_id"].nil?
        facts = stack.rails_runner(guest_helper, env: { "SILO_INSPECTION_ACTION" => "revoke", "SILO_INSPECTION_USERNAME" => endpoint["username"],
                                                        "SILO_INSPECTION_KEY_IDS" => ids.join(","),
                                                        "SILO_INSPECTION_MINT_ACKNOWLEDGED" => acknowledged ? "1" : "0" }.merge(site_database_env(binding)), timeout: 120)
        stack.web_exec(["sh", "-c", "rm -rf /tmp/silo-inspection-* #{guest_helper}"], timeout: 30)
        facts.is_a?(Hash) && facts["database_oid"] == binding["oid"] && facts["active_remaining"] == 0 &&
          (facts["identity_present"] == true || (!acknowledged && facts["identity_present"] == false && facts["never_minted"] == true))
      end

      # -- source: read role and versioned policy -----------------------------------------

      def open_source_endpoint(run_id, stack, manifest, database)
        role = "#{INSPECTION_ROLE_PREFIX}#{SecureRandom.hex(4)}"
        endpoint = { "state" => "opening", "kind" => "dbhub", "database" => database, "role" => role,
                     "credential" => INSPECTION_CREDENTIALS.fetch("source"), "opened_at" => now }
        manifest["endpoints"]["source"] = endpoint
        write_inspection_manifest(run_id, manifest)

        db = inspection_db(manifest)
        inventory = inspection_psql(db, "postgres", database_exists_sql(database))
        inspection_refuse!("STANDARD_MERGE_INSPECTION_UNAVAILABLE") unless inventory&.strip == "1"
        listing = inspection_psql(db, database, source_inventory_sql) || inspection_refuse!("STANDARD_MERGE_INSPECTION_UNAVAILABLE")
        plan = source_policy_plan(listing)
        # Before the role exists: it may only ever log in to this clone (pg_hba, role-specific lines).
        inspection_refuse!("STANDARD_MERGE_INSPECTION_UNAVAILABLE") unless source_hba!(db, role, database, present: true)
        endpoint["hba"] = true
        write_inspection_manifest(run_id, manifest)
        password = SecureRandom.hex(24)
        sql = source_role_sql(role, password, database, plan.fetch("grants"))
        # The same transaction verifies effective privileges and rolls back on any violation.
        inspection_refuse!("STANDARD_MERGE_INSPECTION_POLICY_UNSAFE") unless inspection_psql(db, database, sql)
        # The policy plan (customer table names) stays in private evidence only.
        @store.write_private(File.join(inspection_credentials_dir(run_id), "source-read-policy.json"),
                             JSON.pretty_generate(plan.reject { |key, _| key == "grants" }.merge("version" => SOURCE_READ_POLICY_VERSION)) + "\n")
        endpoint["credential_sha256"] = write_inspection_secret(run_id, INSPECTION_CREDENTIALS.fetch("source"),
                                                                "SILO_MI_ROLE=#{role}\nSILO_MI_PASSWORD=#{password}\n")
        endpoint["policy"] = { "version" => SOURCE_READ_POLICY_VERSION, "sha256" => StandardMergeInspection.source_read_policy_sha256,
                               "granted_tables" => plan.fetch("grants").size, "unreviewed_tables" => plan.fetch("unreviewed").size,
                               "missing_reviewed_tables" => plan.fetch("missing_tables").size }
        endpoint["state"] = "open"
        write_inspection_manifest(run_id, manifest)
      end

      # Relations and columns from pg_catalog (not information_schema, which hides relation kinds
      # and lists only what the caller may see). Every name is hex-encoded: a crafted relation or
      # column name can't forge inventory lines. System schemas are not listed.
      SOURCE_INVENTORY_SQL = <<~SQL
        SELECT 'R|' || encode(convert_to(n.nspname, 'UTF8'), 'hex') || '|' || encode(convert_to(c.relname, 'UTF8'), 'hex') || '|' || c.relkind::text
               || '|' || (c.relrowsecurity OR c.relforcerowsecurity)::int || '|' || c.relispartition::int
               || '|' || (EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhparent = c.oid))::int
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_%'
           AND c.relkind IN ('r', 'p', 'v', 'm', 'f');
        SELECT 'C|' || encode(convert_to(c.relname, 'UTF8'), 'hex') || '|' || encode(convert_to(a.attname, 'UTF8'), 'hex')
               || '|' || (t.typnamespace = 'pg_catalog'::regnamespace)::int
          FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_type t ON t.oid = a.atttypid
         WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped;
      SQL
      SAFE_IDENTIFIER = /\A[a-z_][a-z0-9_]{0,62}\z/

      def source_inventory_sql = SOURCE_INVENTORY_SQL

      def inventory_name(hex)
        return nil unless hex.is_a?(String) && hex.match?(/\A(?:[0-9a-f]{2}){1,256}\z/)

        name = [hex].pack("H*").force_encoding(Encoding::UTF_8)
        name.valid_encoding? ? name : nil
      end

      # Grants only reviewed identifiers that exist as plain, unshared tables with built-in column
      # types; customer-provided names never reach SQL. A reviewed name that is a view, materialized
      # view, foreign/partitioned table, inheritance parent, partition or RLS table refuses the open:
      # its SELECT could expose other relations (or run other code) beyond the reviewed columns.
      def source_policy_plan(listing)
        relations = {}
        others = 0
        columns = Hash.new { |hash, key| hash[key] = {} }
        listing.to_s.each_line do |line|
          fields = line.chomp.split("|")
          case fields[0]
          when "R"
            next unless fields.size == 7

            schema, name = inventory_name(fields[1]), inventory_name(fields[2])
            next others += 1 unless schema && name
            next others += 1 unless schema == "public"

            relations[name] = { "kind" => fields[3], "rls" => fields[4] == "1", "partition" => fields[5] == "1", "children" => fields[6] == "1" }
          when "C"
            next unless fields.size == 4

            table, column = inventory_name(fields[1]), inventory_name(fields[2])
            columns[table][column] = fields[3] == "1" if table && column
          end
        end
        unsafe = (SOURCE_READ_POLICY.keys + SOURCE_READ_EXCLUDED).select do |name|
          (relation = relations[name]) && (relation["kind"] != "r" || relation["rls"] || relation["partition"] || relation["children"])
        end
        inspection_refuse!("STANDARD_MERGE_INSPECTION_POLICY_UNSAFE") unless (unsafe & SOURCE_READ_POLICY.keys).empty?

        tables = relations.select { |_, relation| relation["kind"] == "r" }.keys.to_set
        grants = {}
        missing_columns = {}
        unsafe_columns = {}
        SOURCE_READ_POLICY.each do |table, allowed|
          next if SOURCE_READ_EXCLUDED.include?(table) || !tables.include?(table)

          present = allowed.select { |column| columns[table].key?(column) }
          safe = present.select { |column| columns[table][column] }
          grants[table] = safe unless safe.empty?
          absent = allowed - present
          missing_columns[table] = absent unless absent.empty?
          unsafe_columns[table] = present - safe unless (present - safe).empty?
        end
        { "grants" => grants, "granted" => grants.transform_values(&:size),
          "missing_tables" => SOURCE_READ_POLICY.keys.reject { |table| tables.include?(table) },
          "missing_columns" => missing_columns, "non_builtin_type_columns" => unsafe_columns,
          "excluded_present" => SOURCE_READ_EXCLUDED.select { |table| relations.key?(table) },
          "excluded_not_plain" => unsafe, "relations_outside_public" => others,
          "unreviewed" => (relations.keys - SOURCE_READ_POLICY.keys - SOURCE_READ_EXCLUDED).sort }
      end

      # In the disposable inspection clone only (never the clean source or Base): strip PUBLIC's
      # table/sequence/routine/schema/database/large-object/foreign-server privileges, then grant
      # exact reviewed columns. The same transaction checks the role's EFFECTIVE privileges and
      # raises (rolling everything back, role included) on any read beyond the reviewed columns,
      # any write/create/temp privilege, any callable non-catalog function or readable large object.
      # PostgreSQL's stored SCRAM-SHA-256 verifier (RFC 7677 / PG 10+), so the plaintext password
      # never appears in a statement that server logging could record.
      def scram_verifier(password, salt: SecureRandom.random_bytes(16), iterations: 4096)
        salted = OpenSSL::KDF.pbkdf2_hmac(password, salt: salt, iterations: iterations, length: 32, hash: "sha256")
        client = OpenSSL::HMAC.digest("sha256", salted, "Client Key")
        server = OpenSSL::HMAC.digest("sha256", salted, "Server Key")
        stored = OpenSSL::Digest::SHA256.digest(client)
        b64 = ->(bytes) { [bytes].pack("m0") }
        "SCRAM-SHA-256$#{iterations}:#{b64.call(salt)}$#{b64.call(stored)}:#{b64.call(server)}"
      end

      def source_role_sql(role, password, database, grants)
        raise ArgumentError unless role.match?(/\A#{INSPECTION_ROLE_PREFIX}[0-9a-f]{8}\z/) && password.match?(/\A[0-9a-f]{48}\z/) && database.match?(INSPECTION_DB_NAME)

        pairs = []
        grants.sort.each do |table, columns|
          raise ArgumentError unless SOURCE_READ_POLICY.key?(table) && (columns - SOURCE_READ_POLICY.fetch(table)).empty? &&
                                     table.match?(SAFE_IDENTIFIER) && columns.all? { |column| column.match?(SAFE_IDENTIFIER) }

          columns.each { |column| pairs << "('#{table}', '#{column}')" }
        end
        system = "n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_%'"
        allowed = pairs.empty? ? "SELECT NULL::name, NULL::name WHERE false" : "VALUES #{pairs.join(', ')}"
        statements = [
          "DO $$BEGIN IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{role}') THEN RAISE EXCEPTION 'role exists'; END IF; END$$;",
          "CREATE ROLE \"#{role}\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT CONNECTION LIMIT 3 PASSWORD '#{scram_verifier(password)}';",
          "ALTER ROLE \"#{role}\" SET default_transaction_read_only = on;",
          "ALTER ROLE \"#{role}\" SET statement_timeout = '#{INSPECTION_STATEMENT_TIMEOUT}s';",
          "ALTER ROLE \"#{role}\" SET idle_in_transaction_session_timeout = '60s';",
          # Catalog first: objects in public can't shadow built-in functions/operators.
          "ALTER ROLE \"#{role}\" SET search_path = pg_catalog, public;",
          "REVOKE ALL ON DATABASE \"#{database}\" FROM PUBLIC;",
          <<~SQL.chomp,
            DO $$DECLARE s name; o oid; BEGIN
              FOR s IN SELECT n.nspname FROM pg_namespace n WHERE #{system} LOOP
                EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM PUBLIC', s);
                EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM PUBLIC', s);
                EXECUTE format('REVOKE ALL ON ALL ROUTINES IN SCHEMA %I FROM PUBLIC', s);
                EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', s);
              END LOOP;
              FOR o IN SELECT oid FROM pg_largeobject_metadata LOOP
                EXECUTE format('REVOKE ALL ON LARGE OBJECT %s FROM PUBLIC', o);
              END LOOP;
              FOR s IN SELECT srvname FROM pg_foreign_server LOOP
                EXECUTE format('REVOKE ALL ON FOREIGN SERVER %I FROM PUBLIC', s);
              END LOOP;
            END$$;
          SQL
          "GRANT CONNECT ON DATABASE \"#{database}\" TO \"#{role}\";",
          "GRANT USAGE ON SCHEMA public TO \"#{role}\";"
        ]
        grants.sort.each do |table, columns|
          statements << "GRANT SELECT (#{columns.map { |column| "\"#{column}\"" }.join(', ')}) ON TABLE public.\"#{table}\" TO \"#{role}\";"
        end
        statements << <<~SQL.chomp
          DO $$DECLARE bad bigint := 0; BEGIN
            SELECT count(*) INTO bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE #{system} AND ((c.relkind IN ('r', 'p', 'v', 'm', 'f') AND has_table_privilege('#{role}', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'))
                OR (c.relkind = 'S' AND has_sequence_privilege('#{role}', c.oid, 'USAGE,SELECT,UPDATE')));
            IF bad > 0 THEN RAISE EXCEPTION 'silo inspection: relation privilege'; END IF;
            SELECT count(*) INTO bad FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE #{system} AND a.attnum > 0 AND NOT a.attisdropped AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
               AND (has_column_privilege('#{role}', c.oid, a.attnum, 'INSERT,UPDATE,REFERENCES')
                    OR (has_column_privilege('#{role}', c.oid, a.attnum, 'SELECT')
                        AND (n.nspname <> 'public' OR c.relkind <> 'r' OR (c.relname, a.attname) NOT IN (#{allowed}))));
            IF bad > 0 THEN RAISE EXCEPTION 'silo inspection: column privilege'; END IF;
            SELECT count(*) INTO bad FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND has_function_privilege('#{role}', p.oid, 'EXECUTE');
            IF bad > 0 THEN RAISE EXCEPTION 'silo inspection: callable function'; END IF;
            SELECT count(*) INTO bad FROM pg_namespace n
             WHERE #{system} AND (has_schema_privilege('#{role}', n.oid, 'CREATE') OR (n.nspname <> 'public' AND has_schema_privilege('#{role}', n.oid, 'USAGE')));
            IF bad > 0 THEN RAISE EXCEPTION 'silo inspection: schema privilege'; END IF;
            IF has_database_privilege('#{role}', current_database(), 'CREATE,TEMPORARY') THEN RAISE EXCEPTION 'silo inspection: database privilege'; END IF;
            IF current_setting('lo_compat_privileges')::boolean
               OR EXISTS (SELECT 1 FROM pg_largeobject_metadata m, aclexplode(m.lomacl) x WHERE x.grantee = 0) THEN
              RAISE EXCEPTION 'silo inspection: large object privilege';
            END IF;
            IF EXISTS (SELECT 1 FROM pg_foreign_server f WHERE has_server_privilege('#{role}', f.oid, 'USAGE')) THEN
              RAISE EXCEPTION 'silo inspection: foreign server privilege';
            END IF;
          END$$;
        SQL
        "BEGIN;\n#{statements.join("\n")}\nCOMMIT;\n"
      end

      # pg_hba lines for this role only: it may log in to the inspection clone (password), and is
      # rejected everywhere else (clean Base, original source, postgres, templates). Other roles and
      # database ACLs are untouched. Lines are prepended (first match wins) and tagged for removal.
      SOURCE_HBA_SCRIPT = <<~'SH'
        set -eu
        f="$1"; marker="$2"
        [ -f "$f" ] && [ ! -L "$f" ]
        t="$f.silo-inspection"
        { cat; grep -v -F -- "$marker" "$f" || true; } > "$t"
        cat "$t" > "$f"
        rm -f "$t"
      SH

      def source_hba_marker(role) = "# silo-merge-inspection:#{role}"

      def source_hba_lines(role, database)
        raise ArgumentError unless role.match?(/\A#{INSPECTION_ROLE_PREFIX}[0-9a-f]{8}\z/) && database.match?(INSPECTION_DB_NAME)

        marker = source_hba_marker(role)
        "host #{database} #{role} all md5 #{marker}\nhost all #{role} all reject #{marker}\nlocal all #{role} reject #{marker}\n"
      end

      SOURCE_HBA_RULES_SQL = "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;\n" \
                             "SELECT type || '|' || array_to_string(database, ',') || '|' || array_to_string(user_name, ',') || '|' || coalesce(auth_method, '') " \
                             "FROM pg_hba_file_rules ORDER BY line_number LIMIT 3;\n"

      # Writes (present) or removes this role's lines, checks the file parses with ours first, then
      # reloads. Fails closed: on a parse problem our lines are taken out again.
      def source_hba!(db, role, database, present:)
        return false unless inspection_container_owned?(db)

        path = inspection_psql(db, "postgres", "SHOW hba_file;\n").to_s.strip
        return false unless path.match?(%r{\A/[A-Za-z0-9_./-]{1,255}\z}) && !path.include?("..")

        lines = present ? source_hba_lines(role, database) : ""
        write = lambda do |content|
          @runtime.run(["docker", "exec", "-i", db.fetch("id"), "sh", "-c", SOURCE_HBA_SCRIPT, "sh", path, source_hba_marker(role)],
                       capture: true, timeout: 30, stdin_data: content).success?
        end
        return false unless write.call(lines)

        rules = inspection_psql(db, "postgres", SOURCE_HBA_RULES_SQL).to_s.lines.map(&:strip)
        expected = present ? ["host|#{database}|#{role}|md5", "host|all|#{role}|reject", "local|all|#{role}|reject"] : nil
        unless rules.first == "0" && (expected.nil? || rules[1, 3] == expected)
          write.call("") if present
          return false
        end
        !inspection_psql(db, "postgres", "SELECT pg_reload_conf();\n").nil?
      end

      def database_exists_sql(database)
        raise ArgumentError unless database.match?(INSPECTION_DB_NAME)

        "SELECT count(*) FROM pg_database WHERE datname = '#{database}';\n"
      end

      # Fence the role: no new logins, terminate and verify-drain its sessions, then drop it.
      def fence_source_role!(db, endpoint)
        role = endpoint["role"].to_s
        return true unless role.match?(/\A#{INSPECTION_ROLE_PREFIX}[0-9a-f]{8}\z/)

        exists = inspection_psql(db, "postgres", "SELECT count(*) FROM pg_roles WHERE rolname = '#{role}';\n")
        return false unless exists
        if exists.strip == "0"
          # An open that failed before (or rolled back) creating the role may have left its lines.
          endpoint["hba"] = false if endpoint["hba"] && source_hba!(db, role, endpoint["database"].to_s, present: false)
          return true
        end

        return false unless inspection_psql(db, "postgres", "ALTER ROLE \"#{role}\" NOLOGIN;\n")

        drained = false
        10.times do
          remaining = inspection_psql(db, "postgres",
                                      "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = '#{role}';\n" \
                                      "SELECT count(*) FROM pg_stat_activity WHERE usename = '#{role}';\n")
          if remaining && remaining.lines.last.to_s.strip == "0"
            drained = true
            break
          end
          (@sleeper || ->(seconds) { sleep(seconds) }).call(0.5)
        end
        return false unless drained

        database = endpoint["database"].to_s
        target = database.match?(INSPECTION_DB_NAME) && inspection_psql(db, "postgres", database_exists_sql(database))&.strip == "1" ? database : "postgres"
        # Dropping is cleanup; the fence itself already holds (NOLOGIN, no sessions).
        endpoint["role_dropped"] = !inspection_psql(db, target, "DROP OWNED BY \"#{role}\";\nDROP ROLE \"#{role}\";\n").nil?
        # Lines for a dropped/NOLOGIN role are inert; removing them is cleanup, not the fence.
        endpoint["hba"] = false if endpoint["hba"] && source_hba!(db, role, database, present: false)
        true
      end

      # psql as the database superuser on the exact recorded container (ownership re-checked).
      # Output is returned to the caller only; stderr (which can quote statements) is discarded.
      def inspection_psql(db, database, sql)
        return nil unless inspection_container_owned?(db)

        result = @runtime.run(["docker", "exec", "-i", db.fetch("id"), "psql", "-X", "-q", "-At", "-U", "postgres", "-d", database, "-v", "ON_ERROR_STOP=1"],
                              capture: true, timeout: INSPECTION_STATEMENT_TIMEOUT, stdin_data: sql)
        result.success? ? result.stdout.to_s : nil
      end

      # The manifest's exact db container: {"id", "instance"} from the manifest it was recorded in.
      def inspection_db(manifest)
        { "id" => manifest.dig("containers", "db"), "instance" => manifest.dig("owner", "instance") }
      end

      # Exactly the recorded container of the manifest's owner instance and role: managed label,
      # instance label and container name must all match (a swapped ID or another stack is refused).
      def inspection_container_owned?(db, role = "db")
        id, instance = db.is_a?(Hash) ? db.values_at("id", "instance") : [nil, nil]
        return false unless id.is_a?(String) && id.match?(/\A[0-9a-f]{64}\z/) && instance.is_a?(String) && instance.match?(/\A[a-z0-9][a-z0-9_.-]{0,127}\z/)

        result = @runtime.run(["docker", "inspect", "--format", "{{.Id}}\n{{.Name}}\n{{json .Config.Labels}}", id], capture: true, timeout: 20)
        return false unless result.success?

        found, name, json = result.stdout.to_s.split("\n", 3)
        labels = (JSON.parse(json.to_s) rescue nil)
        found == id && name == "/#{instance}-#{role}" && labels.is_a?(Hash) &&
          labels[PrebuiltStack::LABEL_MANAGED] == "true" && labels[PrebuiltStack::LABEL_INSTANCE] == instance
      end

      # -- fencing ------------------------------------------------------------------------

      def fence_inspection!(run_id, manifest)
        manifest["state"] = "fencing"
        manifest["updated_at"] = now
        write_inspection_manifest(run_id, manifest)
        problems = []
        problems << "launchers" unless remove_inspection_launchers!(run_id)

        stack = inspection_stack_state(run_id, manifest)
        endpoints = manifest.fetch("endpoints", {})
        %w[base result].each do |phase|
          endpoint = endpoints[phase]
          next unless endpoint && endpoint["state"] != "closed"

          ok = if stack == :unknown then false
               else
                 begin
                   revoke_site_endpoint!(run_id, stack, endpoint, manifest)
                 rescue StandardError
                   false
                 end
               end
          ok ? endpoint["state"] = "closed" : problems << "revoke-#{phase}"
        end
        if (source = endpoints["source"]) && source["state"] != "closed"
          ok = stack.nil? || (stack != :unknown && fence_source_role!(inspection_db(manifest), source))
          ok ? source["state"] = "closed" : problems << "source-role"
        end
        problems << "launchers" unless remove_inspection_launchers!(run_id)

        # Credentials and connector configs go once their server-side access is revoked.
        dir = File.join(inspection_private_dir(run_id), "merge-inspection")
        if File.directory?(dir) && !File.symlink?(dir)
          Dir.children(dir).each do |name|
            next if name == "source-read-policy.json"
            next if INSPECTION_CREDENTIALS.value?(name) && endpoints.any? { |_, e| e["credential"] == name && e["state"] != "closed" }

            FileUtils.rm_f(File.join(dir, name))
          end
        end
        manifest["updated_at"] = now
        if problems.empty?
          manifest["state"] = "closed"
          write_inspection_manifest(run_id, manifest)
          return manifest
        end
        write_inspection_manifest(run_id, manifest)
        inspection_refuse!("STANDARD_MERGE_INSPECTION_FENCE_FAILED")
      end

      # The stack's server-side state decides what "revoked" can mean:
      #   a live stack of the manifest's owner instance -> revoke there;
      #   nil (gone) ONLY when the instance record says "removed" (PrebuiltStack#remove! removed its
      #     exact containers AND volumes, so keys/roles/sessions no longer exist anywhere);
      #   :unknown otherwise (stopped containers with retained volumes, missing record, Docker
      #     unanswerable, another instance) -> the fence stays incomplete and close must be retried.
      def inspection_stack_state(run_id, manifest)
        candidate = stack_for(run_id, "review")
        return :unknown unless candidate.respond_to?(:name) && candidate.name == manifest.dig("owner", "instance")
        return nil if candidate.record.is_a?(Hash) && candidate.record["state"] == "removed"

        candidate.live? == true ? candidate : :unknown
      rescue KeyError, NoMethodError, TypeError
        :unknown
      end

      # Exact owned launcher containers for this run only (labels written by bin/merge_mcp.py).
      def remove_inspection_launchers!(run_id)
        listed = @runtime.run(["docker", "ps", "-aq", "--no-trunc", "--filter", "label=#{INSPECTION_LABEL_RUN}=#{run_id}",
                               "--filter", "label=silo.workspace=#{@workspace}"], capture: true, timeout: 30)
        return false unless listed.success?

        listed.stdout.to_s.split.each do |id|
          next unless id.match?(/\A[0-9a-f]{64}\z/)

          inspected = @runtime.run(["docker", "inspect", "--format", "{{json .Config.Labels}}", id], capture: true, timeout: 20)
          labels = inspected.success? ? (JSON.parse(inspected.stdout) rescue nil) : nil
          next unless labels.is_a?(Hash) && INSPECTION_LAUNCH_ROLES.include?(labels[INSPECTION_LABEL_ROLE]) &&
                      labels[INSPECTION_LABEL_RUN] == run_id && labels["silo.workspace"] == @workspace

          @runtime.run(["docker", "rm", "--force", id], capture: true, timeout: 60)
        end
        again = @runtime.run(["docker", "ps", "-aq", "--filter", "label=#{INSPECTION_LABEL_RUN}=#{run_id}",
                              "--filter", "label=silo.workspace=#{@workspace}"], capture: true, timeout: 30)
        again.success? && again.stdout.to_s.strip.empty?
      end
    end
  end
end
