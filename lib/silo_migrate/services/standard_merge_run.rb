# frozen_string_literal: true

require "yaml"
require_relative "../discourse_version"

module SiloMigrate
  module Services
    # A native Discourse merge into an isolated, restored sandbox. All data-bearing
    # diagnostics stay under the private run directory; only fixed counters leave it.
    module StandardMergeRun
      MERGE_OPERATION = "standard_merge"
      MERGE_STAGES = %w[preflight site_up base_restore source_load compatibility merge finalize verify backup site_setup review_url].freeze
      MERGE_TOTAL_KEYS = %w[users topics posts categories groups tags uploads].freeze
      MERGE_LAYER_BYTES = 512 * 1024
      MERGE_SETTINGS_BYTES = 256 * 1024

      def propose_merge_plan(**options)
        options = options.compact
        # A prepared merge consumes one environment generation; intent exists only there.
        return propose_prepared_merge_plan(**options) if options.key?(:prepared_from)
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" if options.key?(:generation) || options.key?(:intent)

        ids = options.values_at(:source, :base_site, :settings).compact
        unless options[:source].is_a?(String) && options[:base_site].is_a?(String) && ids.uniq.size == ids.size
          raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID"
        end
        # Never silently ignore a standalone layer by taking the legacy converter path.
        raise StandardWorkflowError, "STANDARD_MERGE_PREPARATION_REQUIRED" if merger_present?

        selection = select_review_runtime(options[:base_site], allow_unqualified: options.fetch(:allow_unqualified_runtime, false))
        with_review_runtime(selection.fetch("profile")) do
          build_merge_plan(**options, runtime_selection: selection)
        end
      end

      def build_merge_plan(source:, base_site:, settings: nil, ignore_global_pins: false, separate_same_named_groups: false, port: nil, allow_unqualified_runtime: false, preparation: nil, runtime_selection:, prepared: nil, intent: nil)
        state = @store.load
        config = state.fetch("config")
        raise StandardWorkflowError, "STANDARD_SIZE_LIMIT" if state.fetch("plans").size >= self.class::MAX_PLANS
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless prepared ? StandardMergePreparation::MERGE_INTENTS.include?(intent) : intent.nil?
        # An explicit stock merge of a prepared environment uses no converter code at all.
        stock = prepared && intent == "stock"
        # A new prepared custom merge runs the project's standalone local merger store, and
        # only it: never a converter checkout, so no converter identity is consulted either.
        standalone = prepared && intent == "custom"
        raise StandardWorkflowError, "STANDARD_STALE_PLAN" unless profile_current?(config) && (stock || standalone || check_converter!(config))
        qualified = lock.dig("qualification", "status") == "qualified"
        review_ready = lock.dig("qualification", "status") == "review_ready"
        raise StandardWorkflowError, "STANDARD_RUNTIME_UNQUALIFIED" unless qualified || review_ready || allow_unqualified_runtime
        named = @store.named_state
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless source.is_a?(String) && base_site.is_a?(String) && (settings.nil? || settings.is_a?(String))
        roles = { "source" => source, "base_site" => base_site, "settings" => settings }.compact
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless roles.values.all? { |id| id.is_a?(String) } && roles.values.uniq.size == roles.size
        inputs = roles.transform_values { |id| named.fetch("inputs")[id] || raise(StandardWorkflowError, "STANDARD_REFERENCE_INVALID") }
        { "source" => "discourse-backup", "base_site" => "base_site", "settings" => "merge-settings" }.each do |role, type|
          raise StandardWorkflowError, "STANDARD_INPUTS_INCOMPLETE" if inputs[role] && inputs[role]["type"] != type
        end
        raise StandardWorkflowError, "STANDARD_INPUT_CHANGED" unless inputs_unchanged?(inputs.values)
        delivery = delivery_binding!(inputs.fetch("source").fetch("dataset_id"))
        delivery_roles!(named, roles, delivery)
        dataset = named.fetch("datasets").fetch(inputs.fetch("source").fetch("dataset_id"))
        platform = named.fetch("sources").fetch(dataset.fetch("source_id")).fetch("platform").unpack1("m0")
        raise StandardWorkflowError, "STANDARD_INPUTS_INCOMPLETE" unless platform == "discourse"
        source_versions, base = merge_side_bindings!(inputs, base_site)
        # Settings are read by a merge layer only: a stock merge would silently ignore the mapping.
        raise StandardWorkflowError, "STANDARD_MERGE_INTENT_MISMATCH" if stock && settings
        merge_settings!(merge_settings_input!(inputs.fetch("settings"))) if settings
        layer = if stock then { "present" => false }
                elsif standalone then merger_proposal_layer!
                else merge_layer!(config.fetch("converter_worktree"), config.fetch("converter_revision"), @workspace).first
                end
        raise StandardWorkflowError, "STANDARD_MERGE_INTENT_MISMATCH" if prepared && intent == "custom" && layer["present"] != true
        plan_id = @store.new_id("plan")
        if prepared
          prepared_body = prepared.fetch("body")
          # Same inputs under the same runtime bind the same facts; anything else is another environment.
          unless base == prepared_body["base_site"] && source_versions == prepared_body.dig("merge", "source").slice(*source_versions.keys) && delivery == prepared_body["delivery"]
            raise StandardWorkflowError, "STANDARD_MERGE_ENVIRONMENT_STALE"
          end
          limits = prepared_body.fetch("limits")
          instance = prepared_body.dig("instances", "review")
        else
          limits = review_limits(input_bytes: inputs.fetch("source").fetch("bytes") + inputs.fetch("base_site").fetch("bytes"))
          review_capacity!(limits, running: false)
          instance = { "name" => "silomig-#{plan_id.delete_prefix('plan-')[0, 8]}-review", "hostname" => "127.0.0.1", "port" => select_review_port(state, port) }
        end
        disk_headroom!(3 * inputs.fetch("source").fetch("bytes"))
        ids = roles.values.sort
        role_binding = file_role_binding(named, roles)
        body = {
          "operation" => MERGE_OPERATION, "workspace_id" => named.fetch("workspace_id"), "dataset_id" => delivery.fetch("dataset_id"),
          "delivery" => delivery, "platform" => "discourse", "roles" => roles, "base_site" => base,
          "merge" => { "source" => { "input_id" => source, "delivery" => delivery.slice("kind", "version") }.merge(source_versions),
                       "layer" => layer, "settings" => !!settings, "site_settings_preservation" => StandardMergeSiteSettings::MERGE_SITE_SETTINGS_POLICY.dup,
                       "options" => { "ignore_global_pins" => !!ignore_global_pins, "separate_same_named_groups" => !!separate_same_named_groups } },
          "input_binding" => ids.map { |id| inputs.values.find { |i| i["id"] == id }.slice("id", "sha256", "bytes", "type") },
          "input_stat_binding" => @store.named.input_binding(named, ids), "code_identity" => code_identity,
          "runtime_lock_sha256" => runtime_selection.fetch("sha256"), "discourse_profile" => runtime_selection.fetch("name"),
          "workspace_runtime_profile_sha256" => config["discourse_profile_sha256"],
          "review_runtime" => runtime_selection.fetch("selection"), "base_site_generation" => review_base_generation,
          "image_content_ids" => lock.fetch("images").transform_values { |image| image.fetch("content_id") },
          "runtime_qualified" => qualified, "allow_unqualified_runtime" => allow_unqualified_runtime,
          "converter" => stock || standalone ? nil : config["converter"], "converter_binding" => stock || standalone ? nil : config["converter_binding"],
          "converter_revision" => stock || standalone ? nil : config["converter_revision"],
          "app_revision" => lock.dig("app", "revision"), "limits" => limits,
          "instances" => { "review" => instance },
          "outputs" => { "backup" => "validated full merged backup for #{plan_id}; engineer release to outbox" },
          "mutations" => ["restore the target sandbox in one isolated local review site", "load and migrate a disposable source copy, then merge it into the target", "take a full backup before creating the local review admin", "keep the review site until reset"],
          "not_included" => ["automatic count checks", "restore proof", StandardMergePreparation::MERGE_NOT_CARRIED, "hosted restore", "DNS or cutover", "remote pushes"]
        }
        if prepared
          body["prepared_from"] = prepared.slice("run_id", "generation")
          body["intent"] = intent
          body["mutations"] = ["use prepared merge environment #{prepared.fetch('run_id')} once: close its inspection access and drop its inspection copies",
                               "return the sealed prepared databases to their working names, then merge the prepared source into the prepared Base",
                               "take a full backup before creating the local review admin and before any new inspection access", "keep the review site until reset"]
        end
        body["mutations"] << "permit only the stock authorized_extensions assignment temporarily; restore exact prior state before postflight and verify all settings before backup"
        body["file_role_binding"] = role_binding if role_binding
        if preparation
          readiness = { "kind" => "merge_layer", "present" => layer["present"] == true }.merge(layer.slice("path", "revision", "sha256", "files"))
          body["preparation"] = preparation_binding!(preparation, roles: roles, run_inputs: nil, code_readiness: readiness)
          body["not_included"] += preparation_not_included(body["preparation"])
        end
        # Retained before the plan exists, so no stored plan names a collectable commit.
        merger_retain!(plan_id, layer.fetch("revision")) if merger_store_layer?(layer)
        @store.update do |current|
          verify_file_role_proposal!(body, @store.named_state)
          current.fetch("plans")[plan_id] = { "id" => plan_id, "digest" => Digest::SHA256.hexdigest(canonical_json(body)), "body" => body,
                                            "status" => "proposed", "created_at" => now, "approval" => nil, "run_id" => nil }
        end
        # The proposer (engineer, or the trusted private analyst session that wrote these documents)
        # sees its own full plan; clean agent/operator surfaces use the default projection.
        show_plan(plan_id, detail: true)
      end

      # Trusted analyst/engineer projection only; never used by public_run.
      def merge_evidence(run_id)
        run = @store.load.fetch("runs")[run_id]
        raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless run
        return nil unless merge_plan?(plan_for(run_id)) || prepare_plan?(plan_for(run_id))

        columns = @store.run_dir(run_id, "evidence", "merge-target-only-columns.json")
        log_path = @store.run_dir(run_id, "logs", "merge.log")
        tail = if File.file?(log_path)
          File.open(log_path, "rb") do |file|
            file.seek([file.size - 65_536, 0].max)
            file.read.force_encoding("UTF-8").scrub
          end
        end
        { "totals" => run.fetch("results").fetch("merge", {}),
          "target_only_columns" => File.file?(columns) ? JSON.parse(File.read(columns)) : [], "log_tail" => tail }
      end

      private

      def merge_plan?(plan)
        plan.dig("body", "operation") == MERGE_OPERATION
      end

      def merge_source_versions!(name)
        DiscourseVersion.backup(name, extension: "tar.gz") || raise(StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID")
      end

      def merge_settings_input!(input)
        raise StandardWorkflowError, "STANDARD_MERGE_SETTINGS_INVALID" if input.fetch("bytes") > MERGE_SETTINGS_BYTES
        read_registered_small(input, MERGE_SETTINGS_BYTES)
      end

      def merge_settings!(bytes)
        raise StandardWorkflowError, "STANDARD_MERGE_SETTINGS_INVALID" if bytes.bytesize > MERGE_SETTINGS_BYTES
        value = YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
        raise StandardWorkflowError, "STANDARD_MERGE_SETTINGS_INVALID" unless value.is_a?(Hash)
        value
      rescue Psych::Exception, ArgumentError
        raise StandardWorkflowError, "STANDARD_MERGE_SETTINGS_INVALID"
      end

      def merge_layer!(worktree, revision, workspace)
        # Use the public workspace slug, not its opaque registry ID or an input path.
        prefix = "mergers/#{workspace}/"
        raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID" unless workspace.match?(/\A[A-Za-z0-9_-]+\z/)
        result = @runtime.run([*converter_git_argv(worktree), "ls-tree", "-rz", revision, "--", prefix], capture: true, binary: true, timeout: 30)
        raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID" unless result.success?
        entries = result.stdout.to_s.split("\0")
        return [{ "present" => false }, {}] if entries.empty?
        files = {}
        canonical = []
        entries.each do |entry|
          match = entry.match(/\A100644 blob ([0-9a-f]{40})\t(.+)\z/)
          raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID" unless match
          path = match[2]
          relative = path.delete_prefix(prefix)
          unless path.start_with?(prefix) && relative.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.\/-]*\.rb\z/) && relative.split("/").none? { |part| %w[. ..].include?(part) }
            raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID"
          end
          size = @runtime.run([*converter_git_argv(worktree), "cat-file", "-s", match[1]], capture: true, timeout: 30)
          unless size.success? && size.stdout.to_s.strip.match?(/\A\d+\z/) && size.stdout.to_i + files.values.sum(&:bytesize) <= MERGE_LAYER_BYTES && files.size < 32
            raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID"
          end
          files[relative] = committed_file(worktree, revision, path)
          raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID" unless files[relative].bytesize == size.stdout.to_i
          canonical << "#{match[1]} #{path}\n"
        end
        raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID" unless files.key?("merger.rb")
        [{ "present" => true, "path" => "#{prefix}merger.rb", "revision" => revision, "files" => files.size,
           "bytes" => files.values.sum(&:bytesize), "sha256" => Digest::SHA256.hexdigest(canonical.sort.join) }, files]
      end

      def merge_stale_reason(plan, state)
        body = plan.fetch("body")
        # Historical Merge approvals must be re-proposed, not consume a ready
        # generation before discovering they never approved this preservation policy.
        return "code" unless body.dig("merge", "site_settings_preservation") == StandardMergeSiteSettings::MERGE_SITE_SETTINGS_POLICY
        return "delivery" if !body["file_role_binding"] && body["base_site_generation"] && body["base_site_generation"] != review_base_generation

        named = @store.named_state
        ids = body.fetch("roles").values
        return "inputs" unless ids.all? { |id| named.fetch("inputs").key?(id) }
        return "inputs" unless @store.named.input_binding(named, ids.sort) == body.fetch("input_stat_binding") && inputs_unchanged?(ids.map { |id| named.fetch("inputs").fetch(id) })
        return "delivery" unless delivery_binding!(body.fetch("dataset_id")) == body.fetch("delivery")
        delivery_roles!(named, body.fetch("roles"), body.fetch("delivery"))
        base_record = delivery_record!(named.fetch("inputs").fetch(body.dig("roles", "base_site")).fetch("dataset_id"))
        return "delivery" unless base_record.slice("kind", "version") == body.dig("base_site", "delivery")
        return "code" unless body["code_identity"] == code_identity
        return "runtime" unless review_runtime_current?(body, state.fetch("config"))
        if merger_store_layer?(body.dig("merge", "layer"))
          # Exactly a prepared custom plan; its bound commit and manifest, never the converter.
          return "merger" unless body["prepared_from"] && body["intent"] == "custom" && body["converter_revision"].nil? && merger_layer_current?(body.dig("merge", "layer"))
        elsif !(body["prepared_from"] && body["intent"] == "stock")
          return "converter" unless check_converter!(state.fetch("config")) && state.dig("config", "converter_revision") == body["converter_revision"] && state.dig("config", "converter_binding") == body["converter_binding"]
        end
        return prepared_environment_stale_reason(plan, state) if body["prepared_from"]
        nil
      rescue StandardWorkflowError, NamedError, Errno::ENOENT
        "inputs"
      end

      def merge_preflight(run_id, plan)
        return prepared_merge_preflight(run_id, plan) if prepared_merge_plan?(plan)

        body = plan.fetch("body")
        resolved = lock.fetch("images").transform_values { |image| ImageIdentity.resolve(@runtime, image) }
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("artifacts")["resolved_image_ids"] = resolved }
        evidence(run_id, "runtime-images.json", JSON.pretty_generate(resolved) + "\n")
        record_review_runtime(run_id, resolved_image_id: resolved.fetch("web"))
        manifest = materialize_inputs(run_id, body, @store.named_state, layout: false)
        manifest.each { |input| input["role"] = body.fetch("roles").key(input.fetch("id")) }
        @store.write_private(@store.run_dir(run_id, "work", "inputs.json"), JSON.pretty_generate(manifest) + "\n")
        snapshot_helpers(run_id)
        config = @store.load.fetch("config")
        layer, files = merge_layer!(config.fetch("converter_worktree"), body.fetch("converter_revision"), @workspace)
        raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID" unless layer == body.dig("merge", "layer")
        files.each { |path, bytes| @store.write_private(@store.run_dir(run_id, "private", "merge", "layer", path), bytes) }
        settings = role_input(manifest, "settings")
        merge_settings!(File.binread(input_path(run_id, settings))) if settings
        source = role_input(manifest, "source")
        disk_headroom!(3 * source.fetch("bytes"))
        record_results(run_id, input_count: manifest.size, input_bytes: manifest.sum { |input| input.fetch("bytes") }, merge: { "restore_proof" => "skipped" })
      end

      def merge_result(run_id, **values)
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("results").fetch("merge").merge!(values.transform_keys(&:to_s)) }
      end

      def merge_checked(run_id, label, result, code = "STANDARD_MERGE_SOURCE_INVALID")
        log(run_id, label, result)
        raise StandardWorkflowError, code unless result.success?
        result.stdout.to_s
      end

      # Strict host extraction: bounded chunks, no external tar, no links or PAX.
      def merge_extract!(archive, directory, cap)
        FileUtils.mkdir_p(directory, mode: 0o700)
        seen = Set.new
        total = 0
        uploads = []
        upload_hashes = {}
        roots = Set.new
        Zlib::GzipReader.open(archive) do |gzip|
          Gem::Package::TarReader.new(gzip) do |tar|
            tar.each do |entry|
              name = entry.full_name.delete_suffix("/")
              parts = name.split("/", -1)
              unless !name.empty? && !name.start_with?("/") && !name.match?(/[\x00-\x1f\\]/) && parts.none? { |part| part.empty? || %w[. ..].include?(part) } && seen.add?(name) && (entry.file? || entry.directory?)
                raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID"
              end
              roots << parts[1] if parts.first == "uploads" && parts.size >= 2
              raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID" if roots.size > 1
              total += entry.header.size
              raise StandardWorkflowError, "STANDARD_CAPACITY" if total > cap
              target = File.join(directory, name)
              if entry.directory?
                FileUtils.mkdir_p(target, mode: 0o700)
              else
                FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
                written = 0
                digest = Digest::SHA256.new
                File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
                  until entry.eof?
                    chunk = entry.read(64 * 1024)
                    raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID" if chunk.nil? || chunk.empty?
                    digest.update(chunk)
                    written += chunk.bytesize
                    file.write(chunk)
                  end
                end
                raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID" unless written == entry.header.size
                if name.start_with?("uploads/")
                  raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID" if parts.size < 3
                  roots << parts[1]
                  uploads << name
                  upload_hashes[name] = digest.hexdigest
                end
              end
            end
          end
          gzip.read(64 * 1024) until gzip.eof?
        end
        unless File.file?(File.join(directory, "dump.sql.gz")) && seen.count { |name| File.basename(name) == "dump.sql.gz" } == 1 && roots.size <= 1
          raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID"
        end
        { "uploads" => uploads, "root" => roots.first, "sha256" => upload_hashes }
      rescue Zlib::Error, Gem::Package::TarInvalidError, EOFError, SystemCallError, ArgumentError
        raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID"
      end

      def merge_db(run_id, sql, db: "merge_source", user: "discourse")
        stack = stack_for(run_id, "review")
        result = @runtime.run(["docker", "exec", stack.container("db"), "psql", "-v", "ON_ERROR_STOP=1", "-U", user, "-d", db, "-Atc", sql], capture: true, timeout: 7200)
        merge_checked(run_id, "merge-db", result)
      end

      def merge_source_url?(url)
        url.is_a?(String) && url.match?(%r{\Ahttps?://[A-Za-z0-9.-]+(?::[0-9]{1,5})?(?:/[^\s?#]*)?\z})
      end

      def merge_state(stack, source: false, run_id: nil, env: {})
        env = (source ? { "SILO_MERGE_CONFIG" => "/shared/merge-source.conf", "RUBYOPT" => "-r/tmp/merge_source_config.rb" } : {}).merge(env)
        result = stack.discourse_shell(["env", *env.map { |key, value| "#{key}=#{value}" }, "bundle", "exec", "rails", "runner", "/tmp/merge_state.rb"], timeout: 300)
        log(run_id, "merge-state", result) if run_id
        raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID" unless result.success?
        lines = result.stdout.to_s.lines.grep(/\ASILO_JSON:/)
        raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID" unless lines.size == 1
        state = JSON.parse(lines.first.delete_prefix("SILO_JSON:"))
        counts = state.fetch("counts")
        raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID" unless counts.keys.sort == MERGE_TOTAL_KEYS.sort && counts.values.all? { |v| v.is_a?(Integer) && v >= 0 }
        state
      end

      def stage_source_load(run_id)
        stack = stack_for(run_id, "review")
        # Unicorn and Sidekiq: nothing may write the restored Base while the source is loaded.
        measure_run_step(run_id, "source.quiesce") { merge_quiesce_web!(run_id, stack, code: "STANDARD_STACK_FAILED") }
        before = merge_state(stack, run_id: run_id)
        evidence(run_id, "merge-before.json", before)
        source = role_input(run_inputs(run_id), "source")
        directory = @store.run_dir(run_id, "private", "merge-source")
        extracted = measure_run_step(run_id, "source.extract") { merge_extract!(input_path(run_id, source), directory, [@disk_free.call / 3, 1].max) }
        evidence(run_id, "merge-uploads.json", extracted)
        # Checked before any database object exists for it: a refused dump changes nothing.
        adapted = File.join(directory, "adapted.sql.gz")
        measure_run_step(run_id, "source.validate_dump") { merge_adapt_dump!(File.join(directory, "dump.sql.gz"), adapted, @disk_free.call / 2) }
        merge_db(run_id, "CREATE DATABASE merge_source OWNER discourse", db: "postgres", user: "postgres")
        merge_db(run_id, "CREATE EXTENSION IF NOT EXISTS hstore; CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS unaccent; CREATE EXTENSION IF NOT EXISTS vector;", user: "postgres")
        functions = @runtime.run(["docker", "exec", stack.container("db"), "pg_dump", "-U", "discourse", "-d", "discourse", "--schema=discourse_functions", "--schema-only", "--no-owner", "--no-acl"], capture: true, timeout: 120)
        merge_checked(run_id, "merge-functions", functions)
        merge_checked(run_id, "merge-functions-load", @runtime.run(["docker", "exec", "-i", stack.container("db"), "psql", "-v", "ON_ERROR_STOP=1", "-U", "discourse", "-d", "merge_source"], capture: true, stdin_data: functions.stdout, timeout: 120))
        measure_run_step(run_id, "source.copy_dump") { merge_checked(run_id, "merge-dump-copy", @runtime.run(["docker", "cp", adapted, "#{stack.container('db')}:/tmp/silo-merge.sql.gz"], capture: true, timeout: 7200)) }
        # pipefail propagates either gzip CRC failures or psql ON_ERROR_STOP failures.
        measure_run_step(run_id, "source.load") do
          load = @runtime.run(["docker", "exec", stack.container("db"), "bash", "-o", "pipefail", "-c", "gzip -dc /tmp/silo-merge.sql.gz | psql -v ON_ERROR_STOP=1 -U discourse -d merge_source"], capture: true, timeout: 7200)
          merge_checked(run_id, "merge-source-load", load)
        end
        merge_checked(run_id, "merge-source-config", stack.web_exec(["sh", "-c", "cp /var/www/discourse/config/discourse.conf /shared/merge-source.conf; printf \"\\ndb_name = 'merge_source'\\n\" >> /shared/merge-source.conf; chown discourse:discourse /shared/merge-source.conf; chmod 600 /shared/merge-source.conf"]))
        measure_run_step(run_id, "source.migrate") do
          migration = stack.discourse_shell(["env", "SILO_MERGE_CONFIG=/shared/merge-source.conf", "SKIP_POST_DEPLOYMENT_MIGRATIONS=0", "RUBYOPT=-r/tmp/merge_source_config.rb", "bundle", "exec", "rake", "db:migrate"], timeout: 7200)
          merge_checked(run_id, "merge-migrate", migration)
        end
        source_state = merge_state(stack, source: true, run_id: run_id)
        unless source_state["database"] == "merge_source" && source_state["pending"] == false
          raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID"
        end
        raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID" unless merge_source_url?(source_state["base_url"])
        # The source is migrated by the pinned runtime and then left exactly as migrated: no
        # schema_migrations row is added or removed to satisfy the merger. The compatibility
        # stage decides, from both actual inventories, whether a merger may be constructed.
        evidence(run_id, "merge-source.json", source_state)
        measure_run_step(run_id, "source.copy_uploads") do
          if extracted["root"]
            stack.copy_in(File.join(directory, "uploads", extracted.fetch("root")), "/shared/source-uploads")
          else
            merge_checked(run_id, "merge-empty-uploads", stack.web_exec(%w[mkdir -p /shared/source-uploads]))
          end
        end
        merge_result(run_id, target_before: before.fetch("counts"), source: source_state.fetch("counts"), source_upload_files: extracted.fetch("uploads").size)
      end

      # The source dump is replayed by psql inside the PostgreSQL cluster that also holds the
      # restored Base, so it may only ever act on the declared merge_source database. Outside COPY
      # data a standard pg_dump needs no psql command (bar the \restrict pair newer versions
      # write) and no database, role, system or session-identity statement: a dump that carries
      # one is refused before anything is loaded. This is a guard for standard dump directives
      # (--create/--clean, pg_dumpall, hand-edited dumps), by line; it is not a SQL sandbox.
      MERGE_DUMP_IDENT = /(?:[A-Za-z_\x80-\xff][A-Za-z0-9_$\x80-\xff]*|"(?:[^"\x00\n]|"")+")/n
      MERGE_DUMP_COPY = /\ACOPY (?:#{MERGE_DUMP_IDENT}\.)?#{MERGE_DUMP_IDENT} (?:\(#{MERGE_DUMP_IDENT}(?:, #{MERGE_DUMP_IDENT})*\))? FROM stdin;\r?\n\z/n
      MERGE_DUMP_RESTRICT = /\A\\(?:un)?restrict [A-Za-z0-9]{1,128}\r?\n\z/n
      MERGE_DUMP_METACOMMAND = /(?:\A|[\s;])\\(?:!|(?:c|connect|copy|i|ir|include|include_relative|o|out|w|write|g|gx|gexec|gset|gdesc|e|edit|ef|ev|s|set|setenv|cd|bind|lo_import|lo_export|lo_unlink|password|watch)(?![A-Za-z0-9_]))/n
      MERGE_DUMP_DIRECTIVE = /(?:\A|;)\s*(?:(?:CREATE|ALTER|DROP)\s+(?:DATABASE|ROLE|USER|GROUP|TABLESPACE)|ALTER\s+SYSTEM|(?:REASSIGN|DROP)\s+OWNED|(?:SET|RESET)\s+(?:(?:SESSION|LOCAL)\s+)?(?:ROLE|SESSION\s+AUTHORIZATION))(?![A-Za-z0-9_$])/in

      # Only the single exact schema declaration is adapted. Owners/roles/ACLs are
      # deliberately not rewritten: PostgreSQL refuses unsupported dumps. COPY data (customer
      # cell values) is passed through byte for byte and never inspected for directives.
      def merge_adapt_dump!(source, destination, cap)
        declarations = 0
        bytes = 0
        copy_data = false
        line_start = true
        refuse = ->(reason) { raise StandardWorkflowError.new("STANDARD_MERGE_SOURCE_INVALID", reason) }
        Zlib::GzipReader.open(source) do |input|
          Zlib::GzipWriter.open(destination) do |output|
            until input.eof?
              line = input.gets(64 * 1024).b
              bytes += line.bytesize
              raise StandardWorkflowError, "STANDARD_CAPACITY" if bytes > cap
              # psql reads C strings: a NUL would make it see a different script than this check.
              refuse.call("dump-nul") if line.include?("\0")
              if copy_data
                # The terminator exactly as psql recognises it, at a true line start.
                copy_data = false if line_start && (line == "\\.\n" || line == "\\.\r\n")
              else
                # A statement line too long to judge as a whole is not a standard dump's.
                refuse.call("dump-line") unless line_start && (line.end_with?("\n") || input.eof?)
                if line == "CREATE SCHEMA public;\n"
                  declarations += 1
                  line = "CREATE SCHEMA IF NOT EXISTS public;\n"
                elsif line.start_with?("\\")
                  refuse.call("dump-metacommand") unless line.match?(MERGE_DUMP_RESTRICT)
                elsif line.match?(/\ACOPY\s/in)
                  # Anything but the exact pg_dump form would leave data and statements confused.
                  refuse.call("dump-copy-form") unless line.match?(MERGE_DUMP_COPY)
                  copy_data = true
                elsif line.match?(MERGE_DUMP_METACOMMAND)
                  refuse.call("dump-metacommand")
                elsif line.match?(MERGE_DUMP_DIRECTIVE)
                  refuse.call("dump-directive")
                end
              end
              line_start = line.end_with?("\n")
              output.write(line)
            end
          end
        end
        refuse.call("dump-copy-open") if copy_data
        refuse.call("dump-schema") unless declarations == 1
      rescue Zlib::Error, EOFError
        FileUtils.rm_f(destination)
        raise StandardWorkflowError, "STANDARD_MERGE_SOURCE_INVALID"
      rescue StandardWorkflowError
        # Nothing refused is left behind to be loaded; the extracted original stays as evidence.
        FileUtils.rm_f(destination)
        raise
      end

      # A total's name must be written out in the committed layer: a name built from a
      # row (a slug, a user name) would carry customer data out with the totals, so it is dropped.
      def merge_totals(text, layer_source)
        totals = {}
        text.b.each_line do |line|
          match = line.match(/\ASILO_MERGE_TOTAL: ([a-z][a-z0-9_]{0,40})=(\d{1,12})\r?\n?\z/)
          next unless match && (totals.key?(match[1]) || totals.size < 20)
          next unless layer_source.b.match?(/(?<![A-Za-z0-9_])#{Regexp.escape(match[1])}(?![A-Za-z0-9_])/n)
          totals[match[1]] = match[2].to_i
        end
        totals
      end

      def merge_layer_source(run_id)
        Dir.glob(File.join(@store.run_dir(run_id, "private", "merge", "layer"), "**", "*.rb")).sort.map { |path| File.binread(path) }.join("\n")
      end

      def merge_failure(result)
        text = (result.stdout.to_s + "\n" + result.stderr.to_s).b
        return "STANDARD_MERGE_SITE_SETTINGS_FAILED" if text.match?(/^SILO_MERGE: settings /)
        return "STANDARD_MERGE_LAYER_INVALID" if result.status == 3 && text.match?(/^SILO_MERGE: layer/)
        return "STANDARD_MERGE_SCHEMA" if text.include?("PG::UndefinedColumn")
        "STANDARD_MERGE_FAILED"
      end

      def stage_merge(run_id)
        plan = plan_for(run_id)
        stack = stack_for(run_id, "review")
        merge_checked(run_id, "merge-directory", stack.web_exec(%w[mkdir -p /shared/merge]))
        env = ["DB_NAME=merge_source", "DB_HOST=db", "UPLOADS_PATH=/shared/source-uploads"]
        prepared = prepared_merge_plan?(plan)
        # A prepared custom merge must run its layer's destination-policy checks.
        env << "SILO_MERGE_REQUIRE_CHECKS=1" if prepared && plan.dig("body", "intent") == "custom"
        source = JSON.parse(File.read(@store.run_dir(run_id, "evidence", "merge-source.json")))
        # The source site's address names the customer: it reaches the merger from a file inside
        # the stack, never on a command line the host's process list would show.
        address = @store.run_dir(run_id, "private", "merge", "source-base-url")
        @store.write_private(address, Regexp.escape(source.fetch("base_url")))
        stack.copy_in(address, "/shared/merge/source-base-url", owner: "root:root")
        if plan.dig("body", "merge", "layer", "present")
          stack.copy_in(@store.run_dir(run_id, "private", "merge", "layer"), "/shared/merge/layer", owner: "root:root")
          env << "SILO_MERGE_LAYER=/shared/merge/layer/merger.rb"
        end
        if (settings = role_input(run_inputs(run_id), "settings"))
          stack.copy_in(input_path(run_id, settings), "/shared/merge/settings.yml", owner: "root:root")
          env << "SILO_MERGE_SETTINGS=/shared/merge/settings.yml"
        end
        merge_checked(run_id, "merge-permissions", stack.web_exec(["sh", "-c", "chown -R root:root /shared/merge && chmod -R a+rX,go-w /shared/merge"]))
        unless plan.dig("body", "merge", "site_settings_preservation") == StandardMergeSiteSettings::MERGE_SITE_SETTINGS_POLICY
          raise StandardWorkflowError, "STANDARD_MERGE_SITE_SETTINGS_FAILED"
        end
        settings_binding = merge_site_settings_capture!(run_id, stack)
        env << "SILO_MERGE_SITE_SETTINGS_SHA256=#{settings_binding.fetch('sha256')}"
        options = plan.dig("body", "merge", "options")
        env << "IGNORE_GLOBAL_PINS=1" if options["ignore_global_pins"]
        env << "SEPARATE_SAME_NAMED_GROUPS=1" if options["separate_same_named_groups"]
        merge_site_settings_execution!(run_id, "running")
        result = stack.discourse_shell(["sh", "-c", 'SOURCE_BASE_URL="$(cat /shared/merge/source-base-url)" exec "$@"', "sh",
                                        "env", *env, "bundle", "exec", "ruby", "/tmp/merge_run.rb"], timeout: 6 * 3600)
        merge_site_settings_execution!(run_id, result.status.nil? ? "uncertain" : "finished")
        log(run_id, "merge", result)
        # The shared logger keeps a bounded prefix; retain the actual end as well.
        File.open(@store.run_dir(run_id, "logs", "merge.log"), "ab") do |file|
          file.write("\n--- final output\n")
          [result.stdout, result.stderr].each do |stream|
            bytes = stream.to_s.b
            file.write(bytes.byteslice([bytes.bytesize - 65_536, 0].max, 65_536).to_s)
          end
        end
        declared = plan.dig("body", "merge", "layer", "present") ? merge_layer_source(run_id) : ""
        merge_result(run_id, layer_totals: merge_totals(result.stdout.to_s + "\n" + result.stderr.to_s, declared))
        raise StandardWorkflowError, merge_failure(result) unless result.success?
        merge_site_settings_check!(run_id, stack, phase: "after-merge")
        return unless prepared

        # Exit status alone can be forged by an early exit: the entry point's own last line,
        # printed once after the merger and its checks, is required as well.
        lines = result.stdout.to_s.lines.map(&:chomp).reject(&:empty?)
        unless lines.count("SILO_MERGE: done") == 1 && lines.last == "SILO_MERGE: done"
          raise StandardWorkflowError.new("STANDARD_MERGE_FAILED", "merger did not report completion")
        end
      end

      def stage_finalize(run_id)
        stack = stack_for(run_id, "review")
        merge_site_settings_check!(run_id, stack, phase: "before-finalize")
        %w[import:ensure_consistency posts:rebake search:reindex].each do |task|
          args = if task == "posts:rebake"
            # The stock rake wrapper writes disable_system_edit_notifications. Use
            # the supported rebake API without a second temporary setting exception.
            _, binding = merge_site_settings_snapshot!(run_id)
            merge_site_settings_install!(run_id, stack, binding)
            ["env", "SILO_MERGE_SITE_SETTINGS_SHA256=#{binding.fetch('sha256')}", "bundle", "exec", "rails", "runner", "/tmp/merge_rebake.rb"]
          else
            ["bundle", "exec", "rake", task]
          end
          merge_site_settings_execution!(run_id, "running")
          result = stack.discourse_shell(args, timeout: 7200)
          merge_site_settings_execution!(run_id, result.status.nil? ? "uncertain" : "finished")
          settings_failed = (result.stdout.to_s + "\n" + result.stderr.to_s).match?(/^SILO_MERGE_REBAKE: settings /)
          code = settings_failed ? "STANDARD_MERGE_SITE_SETTINGS_FAILED" : "STANDARD_MERGE_FAILED"
          merge_checked(run_id, "merge-finalize", result, code)
          raise StandardWorkflowError, code if settings_failed
          if task == "posts:rebake"
            lines = result.stdout.to_s.lines.map(&:chomp).reject(&:empty?)
            markers = lines.grep(/\ASILO_MERGE_REBAKE: posts=[0-9]+\z/)
            unless markers.size == 1 && lines.last == markers.first
              raise StandardWorkflowError.new("STANDARD_MERGE_FAILED", "rebake did not report completion")
            end
          end
        end
        merge_checked(run_id, "merge-start", stack.web_exec(%w[sv start unicorn]), "STANDARD_MERGE_FAILED")
        wait_restored_web(stack, internal: true)
        merge_site_settings_check!(run_id, stack, phase: "after-finalize")
      end

      def merge_verify(run_id)
        stack = stack_for(run_id, "review")
        state = merge_state(stack, run_id: run_id)
        merge_site_settings_verify_state!(run_id, state)
        before = JSON.parse(File.read(@store.run_dir(run_id, "evidence", "merge-before.json")))
        changed = (before.fetch("settings").keys | state.fetch("settings").keys).count { |key| before["settings"][key] != state["settings"][key] }
        merge_result(run_id, after: state.fetch("counts"), site_settings_changed: changed)
        failures = review_safety_failures(stack, base_site: true)
        failures << "merge-settings-changed" unless changed.zero?
        assert_clean!(run_id, "merge", failures, "STANDARD_VERIFY_FAILED")
        set_instance_state(stack, "review")
      end

      def merge_backup(run_id)
        stack = stack_for(run_id, "review")
        merge_site_settings_check!(run_id, stack, phase: "before-backup")
        extracted = JSON.parse(File.read(@store.run_dir(run_id, "evidence", "merge-uploads.json")))
        # The merger renames the upload site root to the target's default root.
        required = extracted.fetch("uploads").map { |name| name.sub(%r{\Auploads/[^/]+/}, "uploads/default/") }
        artifact = make_backup(run_id, stack, "merged-#{run_id}.tar.gz", "merge", required_uploads: required)
        versions = merge_source_versions!(artifact.fetch("filename"))
        record_results(run_id, backup_discourse_version: versions["discourse_version"], backup_schema_version: versions["schema_version"])
        checked = validate_full_archive!(artifact.fetch("path"), required)
        extracted.fetch("sha256").each do |name, sha256|
          member = name.sub(%r{\Auploads/[^/]+/}, "uploads/default/")
          raise StandardWorkflowError, "STANDARD_BACKUP_FAILED" unless checked.fetch("upload_sha256")[member] == sha256
        end
        merge_result(run_id, archive_upload_files: checked.fetch("upload_sha256").size)
        # A prepared merge's backup names the one environment generation it came from, so result
        # access can be tied to exactly this backup and never to an older artifact.
        if (binding = plan_for(run_id).dig("body", "prepared_from"))
          artifact = artifact.merge("merge_generation" => binding.fetch("generation"), "preparation_run_id" => binding.fetch("run_id"))
        end
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("artifacts")["backup"] = artifact }
      end
    end
  end
end
