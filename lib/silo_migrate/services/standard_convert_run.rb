# frozen_string_literal: true

require "etc"

module SiloMigrate
  module Services
    # Convert-only runs on real data (operation "standard_convert"): a registered source
    # dump, converter settings and an optional reconciliation spec, all chosen by input ID
    # and bound by the plan digest. Stages: preflight -> convert -> reconcile. Nothing is
    # imported into Discourse.
    #
    # The run loads the dump into its own disposable MariaDB (data on disk under the
    # run's private folder, no network), measures the source side of every
    # reconciliation check right after the load (before the converter can touch the
    # database), runs the workspace platform's converter at the bound commit with the
    # checkout's locked gems (the converter-deps cache bin/converter_dev.py prepares) and
    # deletes the database and the dump copy afterwards. Reconciliation only reports:
    # per-check numbers stay private (evidence and analyst view); public status shows
    # totals.
    module StandardConvertRun
      CONVERT_OPERATION = "standard_convert"
      CONVERT_STAGES = %w[preflight convert reconcile].freeze
      CONVERT_IMAGE_ROLES = %w[converter source_db].freeze
      # Real dumps need far more than the synthetic profile's conversion limits: up to this
      # per container, at most a quarter of the host's memory each (see convert_limits).
      CONVERT_MAX_CPUS = 2.0
      CONVERT_MAX_MEMORY_MIB = 8192
      CONVERT_MIN_MEMORY_MIB = 1024
      LOAD_TIMEOUT = 6 * 3600
      CONVERT_TIMEOUT = 12 * 3600
      QUERY_TIMEOUT = 1800
      # Free disk needed above the profile's minimum, per byte of dump.
      DISK_FACTOR = { plain: 3, compressed: 12 }.freeze
      CHARSETS = %w[utf8mb4 utf8mb3 utf8 latin1 binary].freeze
      PLATFORM = /\A[a-z][a-z0-9_-]{0,31}\z/
      SETTINGS_TYPE = "converter-settings"
      RECONCILIATION_TYPE = "reconciliation"
      PLACEHOLDER = /\$\{(SILO_[A-Z_]+)\}/
      MAX_SPEC_BYTES = 256 * 1024
      MAX_CHECKS = 100
      MAX_SQL_BYTES = 4096
      CHECK_NAME = /\A[a-z][a-z0-9_.-]{0,63}\z/
      EXPECT = %w[equal report].freeze
      DEPS_RECIPE = 1
      CONVERT_LOG_TAIL = 1024 * 1024

      # -- planning -------------------------------------------------------------

      # What the engineer said this data is for, read from the record only they can write. Part of
      # the plan body, so it's covered by the approval.
      def delivery_binding!(dataset_id)
        record = delivery_record!(dataset_id)
        # A launch run repeats the accepted process (site-reviews.json); running on launch data isn't built yet.
        raise StandardWorkflowError, "STANDARD_LAUNCH_NOT_READY" if record["kind"] == "launch"

        { "dataset_id" => dataset_id, "kind" => record["kind"], "version" => record["version"] }
      end

      def delivery_record!(dataset_id)
        path = File.join(@store.workspace_root, ".silo-migrate", "named", "deliveries.json")
        document = File.file?(path) && !File.symlink?(path) ? JSON.parse(File.read(path)) : nil
        deliveries = document.is_a?(Hash) ? document["deliveries"] : nil
        record = deliveries.is_a?(Hash) ? deliveries[dataset_id] : nil
        unless record.is_a?(Hash) && %w[development launch].include?(record["kind"]) && record["version"].is_a?(Integer) && !record["replaced_by"]
          raise StandardWorkflowError, "STANDARD_DELIVERY_UNLABELLED"
        end

        record
      rescue JSON::ParserError, SystemCallError, TypeError, NoMethodError
        raise StandardWorkflowError, "STANDARD_DELIVERY_UNLABELLED"
      end

      # Settings and checks may come from an earlier delivery, but never from data of the other kind.
      def delivery_roles!(named, roles, delivery)
        roles.each do |role, id|
          next if role == "source"

          other = delivery_record!(named.fetch("inputs").fetch(id).fetch("dataset_id"))
          raise StandardWorkflowError, "STANDARD_DELIVERY_MIXED" unless other["kind"] == delivery["kind"]
        end
      end

      def propose_convert_plan(source:, settings:, reconciliation: nil, charset: "utf8mb4", allow_unqualified_runtime: false)
        state = @store.load
        raise StandardWorkflowError, "STANDARD_SIZE_LIMIT" if state.fetch("plans").size >= self.class::MAX_PLANS
        raise StandardWorkflowError, "STANDARD_STALE_PLAN" unless profile_current?(state.fetch("config"))
        raise StandardWorkflowError, "STANDARD_STALE_PLAN" unless check_converter!(state.fetch("config"))
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless CHARSETS.include?(charset)

        qualified = lock.dig("qualification", "status") == "qualified"
        raise StandardWorkflowError, "STANDARD_RUNTIME_UNQUALIFIED" unless qualified || allow_unqualified_runtime

        named = @store.named_state
        roles = { "source" => source, "settings" => settings, "reconciliation" => reconciliation }.compact
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless roles.values.all? { |id| id.is_a?(String) } && roles.values.uniq.size == roles.size

        inputs = roles.transform_values { |id| named.fetch("inputs")[id] || raise(StandardWorkflowError, "STANDARD_REFERENCE_INVALID") }
        raise StandardWorkflowError.new("STANDARD_INPUTS_INCOMPLETE", SETTINGS_TYPE) unless inputs.fetch("settings")["type"] == SETTINGS_TYPE
        if inputs["reconciliation"] && inputs["reconciliation"]["type"] != RECONCILIATION_TYPE
          raise StandardWorkflowError.new("STANDARD_INPUTS_INCOMPLETE", RECONCILIATION_TYPE)
        end
        raise StandardWorkflowError, "STANDARD_INPUT_CHANGED" unless inputs_unchanged?(inputs.values)

        dump_kind(File.join(@store.workspace_root, inputs.fetch("source").fetch("path").unpack1("m0")))
        if inputs["reconciliation"]
          spec = read_registered_small(inputs["reconciliation"], MAX_SPEC_BYTES)
          reconciliation_spec(spec)
        end
        settings_template!(read_registered_small(inputs.fetch("settings"), MAX_SPEC_BYTES))

        delivery = delivery_binding!(inputs.fetch("source").fetch("dataset_id"))
        delivery_roles!(named, roles, delivery)
        dataset = named.fetch("datasets").fetch(inputs.fetch("source").fetch("dataset_id"))
        platform = named.fetch("sources").fetch(dataset.fetch("source_id")).fetch("platform").unpack1("m0").force_encoding("UTF-8")
        raise StandardWorkflowError.new("STANDARD_CONVERTER_PLATFORM_MISSING", "platform name") unless platform.valid_encoding? && platform.match?(PLATFORM)

        config = state.fetch("config")
        revision = config.fetch("converter_revision")
        converter_platform!(config.fetch("converter_worktree"), revision, platform)
        image = ImageIdentity.resolve(@runtime, lock.dig("images", "converter"))
        deps = converter_deps_binding(config.fetch("converter_worktree"), revision, image)
        deps_ready!(deps)

        ids = roles.values.sort
        plan_id = @store.new_id("plan")
        body = {
          "operation" => CONVERT_OPERATION,
          "workspace_id" => named.fetch("workspace_id"),
          "dataset_id" => inputs.fetch("source").fetch("dataset_id"),
          "delivery" => delivery,
          "platform" => platform,
          "roles" => roles,
          "input_binding" => ids.map { |id| named.fetch("inputs").fetch(id).slice("id", "sha256", "bytes", "type") },
          "input_stat_binding" => @store.named.input_binding(named, ids),
          "source_charset" => charset,
          "code_identity" => code_identity,
          "runtime_lock_sha256" => config["discourse_profile_sha256"],
          "discourse_profile" => config["discourse_profile"],
          "runtime_qualified" => qualified, "allow_unqualified_runtime" => allow_unqualified_runtime,
          "image_content_ids" => lock.fetch("images").slice(*CONVERT_IMAGE_ROLES).transform_values { |entry| entry.fetch("content_id") },
          "converter" => config["converter"], "converter_binding" => config["converter_binding"],
          "converter_revision" => revision,
          "converter_deps" => deps,
          "site_settings_sha256" => config["site_settings_sha256"],
          "limits" => convert_limits,
          "reconciliation_policy" => "report",
          "instances" => {},
          "outputs" => {},
          "mutations" => [
            "load the source dump into a disposable database for this run only (no network; deleted after conversion)",
            "run converters/#{platform} at the bound commit; write the intermediate database to this run's artifacts",
            roles["reconciliation"] ? "count each reconciliation check on the source copy and the intermediate database (report only)" : "no reconciliation checks"
          ],
          "not_included" => ["import into Discourse", "uploads", "hosted restore", "DNS or cutover", "remote pushes"]
        }
        digest = Digest::SHA256.hexdigest(canonical_json(body))
        @store.update do |current|
          current.fetch("plans")[plan_id] = {
            "id" => plan_id, "digest" => digest, "body" => body, "status" => "proposed", "created_at" => now, "approval" => nil, "run_id" => nil
          }
        end
        show_plan(plan_id)
      end

      private

      def convert_plan?(plan)
        plan.dig("body", "operation") == CONVERT_OPERATION
      end

      def stages_for(plan)
        return CONVERT_STAGES if convert_plan?(plan)
        return StandardReviewRun::REVIEW_STAGES if review_plan?(plan)

        self.class::STAGES
      end

      def convert_stale_reason(plan, state)
        body = plan.fetch("body")
        named = @store.named_state
        ids = body.fetch("input_binding").map { |input| input["id"] }
        return "inputs" unless ids.all? { |id| named.fetch("inputs").key?(id) }
        return "inputs" unless @store.named.input_binding(named, ids) == body.fetch("input_stat_binding")
        return "inputs" unless inputs_unchanged?(ids.map { |id| named.fetch("inputs").fetch(id) })
        return "code" unless code_identity == body.fetch("code_identity")
        return "runtime" unless profile_current?(state.fetch("config")) && state.dig("config", "discourse_profile_sha256") == body.fetch("runtime_lock_sha256")
        return "converter" unless state.dig("config", "converter_binding") == body.fetch("converter_binding")
        return "converter" unless check_converter!(state.fetch("config")) && state.dig("config", "converter") == body.fetch("converter")
        return "site_settings" unless Digest::SHA256.file(state.dig("config", "site_settings")).hexdigest == body.fetch("site_settings_sha256")
        return "converter_deps" unless deps_ready?(body.fetch("converter_deps"))

        nil
      end

      def read_registered_small(input, limit)
        raise StandardWorkflowError, "STANDARD_INPUT_CHANGED" if input.fetch("bytes") > limit

        @store.named.verify_input_identity(input)
        bytes = File.binread(File.join(@store.workspace_root, input.fetch("path").unpack1("m0")))
        raise StandardWorkflowError, "STANDARD_INPUT_CHANGED" unless Digest::SHA256.hexdigest(bytes) == input.fetch("sha256")

        bytes
      rescue NamedError, Errno::ENOENT
        raise StandardWorkflowError, "STANDARD_INPUT_CHANGED"
      end

      # -- converter platform and its locked gems -------------------------------

      def converter_platform!(worktree, revision, platform)
        assert_converter_config!(worktree)
        found = @runtime.run([*converter_git_argv(worktree), "cat-file", "-e", "#{revision}:converters/#{platform}/converter.rb"], capture: true, timeout: 30)
        raise StandardWorkflowError.new("STANDARD_CONVERTER_PLATFORM_MISSING", platform) unless found.success?
      end

      def committed_file(worktree, revision, name)
        shown = @runtime.run([*converter_git_argv(worktree), "show", "#{revision}:#{name}"], capture: true, timeout: 30, binary: true)
        raise StandardWorkflowError.new("STANDARD_CONVERTER_DEPS_MISSING", name) unless shown.success?

        shown.stdout.to_s.b
      end

      # Same key as bin/converter_dev.py prepare_dependencies.
      def converter_deps_binding(worktree, revision, image_id)
        gemfile = committed_file(worktree, revision, "Gemfile")
        lockfile = committed_file(worktree, revision, "Gemfile.lock")
        key_body = { "recipe" => DEPS_RECIPE, "image" => image_id, "gemfile" => Digest::SHA256.hexdigest(gemfile),
                     "lockfile" => Digest::SHA256.hexdigest(lockfile) }
        { "key" => Digest::SHA256.hexdigest(canonical_json(key_body)), "image" => image_id,
          "gemfile_sha256" => key_body["gemfile"], "lockfile_sha256" => key_body["lockfile"] }
      end

      def deps_root
        @env["SILO_CONVERTER_DEPS"] || File.join(File.dirname(File.dirname(@store.workspace_root)), "state", "converter-deps")
      end

      def deps_dir(deps)
        raise StandardWorkflowError, "STANDARD_CONVERTER_DEPS_MISSING" unless deps["key"].to_s.match?(/\A[0-9a-f]{64}\z/)

        File.join(deps_root, deps["key"])
      end

      def deps_ready?(deps)
        dir = deps_dir(deps)
        record = JSON.parse(File.read(File.join(dir, "ready.json")))
        !File.symlink?(dir) && record["image"] == deps["image"] && record["lockfile_sha256"] == deps["lockfile_sha256"] &&
          record["gemfile_sha256"] == deps["gemfile_sha256"] &&
          %w[gems emoji_cache].all? { |name| File.directory?(File.join(dir, name)) && !File.symlink?(File.join(dir, name)) }
      rescue Errno::ENOENT, Errno::ENOTDIR, JSON::ParserError, TypeError
        false
      end

      def deps_ready!(deps)
        raise StandardWorkflowError.new("STANDARD_CONVERTER_DEPS_MISSING", "run dev_test once on this commit, or converter deps WS") unless deps_ready?(deps)
      end

      # Environment that layers the dependency overlay over the converter image's bundle;
      # same derivation as bin/converter_dev.py image_gem_env.
      def overlay_env(image_id)
        inspected = @runtime.run(["docker", "image", "inspect", image_id], capture: true, timeout: 30)
        raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH" unless inspected.success?

        env = Array(JSON.parse(inspected.stdout).fetch(0).dig("Config", "Env")).filter_map { |item| item.split("=", 2) if item.include?("=") }.to_h
        version = env["RUBY_VERSION"].to_s.match(/\A(\d+)\.(\d+)\.\d+\z/)
        safe = %r{\A/[A-Za-z0-9/._-]+\z}
        path = env["PATH"].to_s
        unless version && env["BUNDLE_PATH"].to_s.match?(safe) && env["GEM_HOME"].to_s.match?(safe) && path.split(":").all? { |part| part.match?(safe) }
          raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH"
        end

        gems = "#{env['BUNDLE_PATH'].chomp('/')}/ruby/#{version[1]}.#{version[2]}.0"
        ["BUNDLE_APP_CONFIG=/tmp/bundle-config", "BUNDLE_USER_HOME=/tmp/bundle-home", "BUNDLE_FROZEN=true", "GEM_HOME=/deps",
         "GEM_PATH=/deps:#{gems}:#{env['GEM_HOME']}", "PATH=/deps/bin:#{gems}/bin:#{path}"]
      rescue JSON::ParserError, IndexError, NoMethodError
        raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH"
      end

      # -- settings and the reconciliation spec ---------------------------------

      def settings_template!(bytes)
        text = bytes.dup.force_encoding("UTF-8")
        raise StandardWorkflowError.new("STANDARD_SETTINGS_INVALID", "not UTF-8") unless text.valid_encoding?

        names = text.scan(PLACEHOLDER).flatten.uniq
        unknown = names - settings_values("x").keys
        raise StandardWorkflowError.new("STANDARD_SETTINGS_INVALID", "unknown placeholder #{unknown.first[0, 32]}") unless unknown.empty?
        raise StandardWorkflowError.new("STANDARD_SETTINGS_INVALID", "missing ${SILO_DB_PASSWORD}") unless names.include?("SILO_DB_PASSWORD")

        filled = text.gsub(PLACEHOLDER) { |_match| settings_values("p0").fetch(Regexp.last_match(1)) }
        parsed = YAML.safe_load(filled, aliases: false)
        raise StandardWorkflowError.new("STANDARD_SETTINGS_INVALID", "not a YAML mapping") unless parsed.is_a?(Hash)

        text
      rescue Psych::Exception
        raise StandardWorkflowError.new("STANDARD_SETTINGS_INVALID", "not YAML")
      end

      def settings_values(password)
        { "SILO_DB_HOST" => "127.0.0.1", "SILO_DB_PORT" => "3306", "SILO_DB_USER" => "silo_convert", "SILO_DB_PASSWORD" => password, "SILO_DB_NAME" => "source" }
      end

      def reconciliation_spec(bytes)
        spec = JSON.parse(bytes.dup.force_encoding("UTF-8"))
        checks = spec["checks"] if spec.is_a?(Hash) && spec["version"] == 1 && spec.keys.sort == %w[checks version]
        raise StandardWorkflowError.new("STANDARD_RECONCILIATION_INVALID", "shape") unless checks.is_a?(Array) && checks.size.between?(1, MAX_CHECKS)

        names = []
        checks.each_with_index do |check, index|
          label = "check #{index + 1}"
          raise StandardWorkflowError.new("STANDARD_RECONCILIATION_INVALID", label) unless check.is_a?(Hash) && (check.keys - %w[name source_sql intermediate_sql destination_sql expect note]).empty?
          raise StandardWorkflowError.new("STANDARD_RECONCILIATION_INVALID", "#{label}: name") unless check["name"].is_a?(String) && check["name"].match?(CHECK_NAME) && !names.include?(check["name"])
          raise StandardWorkflowError.new("STANDARD_RECONCILIATION_INVALID", "#{label}: expect") unless EXPECT.include?(check.fetch("expect", "equal"))
          raise StandardWorkflowError.new("STANDARD_RECONCILIATION_INVALID", "#{label}: note") unless check["note"].nil? || (check["note"].is_a?(String) && check["note"].bytesize <= 500)

          %w[source_sql intermediate_sql].each do |key|
            raise StandardWorkflowError.new("STANDARD_RECONCILIATION_INVALID", "#{label}: #{key}") unless count_sql?(check[key], intermediate: key == "intermediate_sql")
          end
          # Optional: the review site's count (review runs only; convert runs ignore it).
          if check.key?("destination_sql") && !count_sql?(check["destination_sql"], destination: true)
            raise StandardWorkflowError.new("STANDARD_RECONCILIATION_INVALID", "#{label}: destination_sql")
          end
          names << check["name"]
        end
        checks.map { |check| check.merge("expect" => check.fetch("expect", "equal")) }
      rescue JSON::ParserError, EncodingError
        raise StandardWorkflowError.new("STANDARD_RECONCILIATION_INVALID", "not JSON")
      end

      # One read-only counting query: a single SELECT/WITH statement, no comments, no
      # statement separators. Source queries also run as a SELECT-only user on the
      # run's own copy; intermediate queries on a read-only SQLite connection; destination
      # queries as a SELECT-only PostgreSQL role in a read-only transaction.
      def count_sql?(sql, intermediate: false, destination: false)
        return false unless sql.is_a?(String) && sql.bytesize.between?(1, MAX_SQL_BYTES) && sql.valid_encoding?
        return false if sql.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f]/) || sql.include?("--") || sql.include?("/*") || sql.include?("#")

        body = sql.strip.sub(/;\z/, "")
        return false if body.include?(";") || body.include?("\\") || !body.match?(/\A(?:SELECT|WITH)\b/i)
        return false if intermediate && body.match?(/\b(?:ATTACH|DETACH|PRAGMA|LOAD_EXTENSION|VACUUM|INSERT|UPDATE|DELETE|REPLACE|CREATE|DROP|ALTER)\b/i)
        return false if !intermediate && !destination && body.match?(/\b(?:INTO|OUTFILE|DUMPFILE|LOAD_FILE|SLEEP|BENCHMARK|GET_LOCK|FOR\s+UPDATE|LOCK\s+IN)\b/i)
        return false if destination && body.match?(/\b(?:INTO|COPY|INSERT|UPDATE|DELETE|MERGE|TRUNCATE|CREATE|DROP|ALTER|GRANT|REVOKE|SET|RESET|LOCK|FOR\s+(?:UPDATE|SHARE|NO\s+KEY|KEY)|pg_\w+|lo_\w+|dblink\w*|set_config|current_setting|txid_\w+|UESCAPE)\b|U&/i)

        true
      end

      # -- stages -------------------------------------------------------------------

      def convert_preflight(run_id, plan)
        body = plan.fetch("body")
        named = @store.named_state
        resolved = lock.fetch("images").slice(*CONVERT_IMAGE_ROLES).to_h { |role, image| [role, ImageIdentity.resolve(@runtime, image)] }
        raise StandardWorkflowError.new("STANDARD_RUNTIME_MISMATCH", "converter image") unless resolved.fetch("converter") == body.dig("converter_deps", "image")

        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("artifacts")["resolved_image_ids"] = resolved }
        evidence(run_id, "runtime-images.json", JSON.pretty_generate(resolved) + "\n")
        deps_ready!(body.fetch("converter_deps"))
        source = named.fetch("inputs").fetch(body.dig("roles", "source"))
        @store.named.verify_input_identity(source)
        _decompress, kind = dump_kind(File.join(@store.workspace_root, source.fetch("path").unpack1("m0")))
        # The copy, then the database it becomes: refuse before copying anything.
        disk_headroom!((1 + DISK_FACTOR.fetch(kind)) * source.fetch("bytes"))
        manifest = materialize_inputs(run_id, body, named, layout: false)
        manifest.each { |input| input["role"] = body.fetch("roles").key(input.fetch("id")) }
        @store.write_private(@store.run_dir(run_id, "work", "inputs.json"), JSON.pretty_generate(manifest) + "\n")
        snapshot_site_settings(run_id, body)
        record_results(run_id, input_count: manifest.size, input_bytes: manifest.sum { |input| input["bytes"] })
      rescue NamedError => error
        raise StandardWorkflowError.new("STANDARD_INPUT_CHANGED", error.message)
      end

      # Sized for this host when the plan is proposed, then bound by its digest.
      def convert_limits
        host_cpus, host_memory = host_capacity
        memory = [CONVERT_MAX_MEMORY_MIB, host_memory / 4].min
        cpus = [CONVERT_MAX_CPUS, host_cpus / 2.0].min
        raise StandardWorkflowError.new("STANDARD_CAPACITY", "host too small for a convert run") if memory < CONVERT_MIN_MEMORY_MIB || cpus < 0.5

        { "db" => { "cpus" => cpus, "memory_mib" => memory, "pids" => 512, "buffer_pool" => "#{memory / 2}M" },
          "converter" => { "cpus" => cpus, "memory_mib" => memory, "pids" => 512 } }
      end

      def disk_headroom!(needed)
        minimum = lock.dig("limits", "host_free_min_gib") * 1024**3
        raise StandardWorkflowError.new("STANDARD_CAPACITY", "disk for the source database") if @disk_free.call < minimum + needed
      end

      # Convert runs aren't sized by the profile's synthetic stack envelope: their memory caps,
      # added to those of the managed containers already running, must fit in three quarters
      # of the host's memory. CPU quotas reserve nothing; each must only exist on this host.
      def convert_admission!(body)
        _used_cpus, used_memory = measured_usage
        limits = body.fetch("limits").values_at("db", "converter")
        host_cpus, host_memory = host_capacity
        if limits.any? { |limit| limit["cpus"] > host_cpus } || used_memory + limits.sum { |limit| limit["memory_mib"] } > host_memory * 3 / 4
          raise StandardWorkflowError.new("STANDARD_CAPACITY", "reset an earlier run's retained instances first")
        end
      end

      # The host's, as the control container sees /proc (Docker limits don't change these).
      def host_capacity
        memory = File.read("/proc/meminfo")[/^MemTotal:\s+(\d+) kB/, 1].to_i / 1024
        [Etc.nprocessors, memory]
      end

      def role_input(inputs, role)
        inputs.find { |input| input["role"] == role }
      end

      def dump_kind(path)
        head = File.binread(path, 6).to_s.b
        return ["gzip -dc", :compressed] if head.start_with?("\x1f\x8b".b)
        return ["bzip2 -dc", :compressed] if head.start_with?("BZh".b)
        return ["xz -dc", :compressed] if head.start_with?("\xFD7zXZ\x00".b)
        # zip, 7z, zstd, tar...: extract or convert first (migration-data's tools).
        raise StandardWorkflowError.new("STANDARD_DUMP_KIND_UNSUPPORTED", "archive") if head.start_with?("PK".b, "7z\xBC\xAF".b, "\x28\xB5\x2F\xFD".b)

        ["cat", :plain]
      end

      def convert_real(run_id, plan)
        body = plan.fetch("body")
        inputs = run_inputs(run_id)
        config = @store.load.fetch("config")
        work = @store.run_dir(run_id, "work")
        code = File.join(work, "code")
        output = File.join(work, "converter-output")
        secrets = @store.run_dir(run_id, "private", "converter")
        db_data = @store.run_dir(run_id, "private", "source-db")
        db_tmp = @store.run_dir(run_id, "private", "source-db-tmp")
        source = role_input(inputs, "source")
        dump = input_path(run_id, source)
        convert_on_source_db(run_id, body, inputs, config, source, dump, [code, output, secrets, db_data, db_tmp])
      ensure
        begin
          convert_leftovers!(run_id) if run_id
        rescue SystemCallError => error
          # Never hide the run's own failure behind a cleanup error; reset retries it.
          @store.write_private(@store.run_dir(run_id, "private", "cleanup-error.txt"), "#{error.class}\n")
        end
      end

      # The database copy and the dump copy are the run's largest files, and the generated
      # passwords die with the database: none is kept. Also called by `run reset` (after a
      # killed run). Settings stay for investigation, with the password removed.
      def convert_leftovers!(run_id)
        private_dir = @store.run_dir(run_id, "private")
        %w[source-db source-db-tmp].each { |name| FileUtils.rm_rf(File.join(private_dir, name)) }
        %w[root-password root.cnf count.cnf bootstrap.sql users.sql].each { |name| FileUtils.rm_f(File.join(private_dir, "converter", name)) }
        settings = File.join(private_dir, "converter", "settings.yml")
        if File.file?(settings) && !File.symlink?(settings)
          @store.write_private(settings, File.read(settings).gsub(/\bp[0-9a-f]{62}\b/, "[removed]"))
        end
        manifest = @store.run_dir(run_id, "work", "inputs.json")
        return unless File.file?(manifest)

        JSON.parse(File.read(manifest)).each do |input|
          FileUtils.rm_f(input_path(run_id, input)) if input["role"] == "source"
        end
      rescue JSON::ParserError
        nil
      end

      def convert_on_source_db(run_id, body, inputs, config, source, dump, dirs)
        code, output, secrets, db_data, db_tmp = dirs
        dirs.each { |dir| FileUtils.mkdir_p(dir, mode: 0o700) }
        decompress, kind = dump_kind(dump)
        disk_headroom!(DISK_FACTOR.fetch(kind) * source.fetch("bytes"))
        # Defence in depth: both reach a shell string below (bound and checked at proposal).
        unless CHARSETS.include?(body.fetch("source_charset")) && body.fetch("platform").match?(PLATFORM)
          raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID"
        end

        materialize_converter(run_id, config, code)
        FileUtils.mkdir_p(File.join(code, "tmp", "emoji_cache"))
        deps = deps_dir(body.fetch("converter_deps"))
        root_password = SecureRandom.hex(32)
        converter_password = "p#{SecureRandom.hex(31)}"
        count_password = SecureRandom.hex(32)
        template = File.read(input_path(run_id, role_input(inputs, "settings")))
        settings_template!(template.b)
        values = settings_values(converter_password)
        @store.write_private(File.join(secrets, "settings.yml"), template.gsub(PLACEHOLDER) { |_match| values.fetch(Regexp.last_match(1)) })
        @store.write_private(File.join(secrets, "root-password"), root_password)
        @store.write_private(File.join(secrets, "root.cnf"), "[client]\nuser=root\nsocket=/run/mysqld/mysqld.sock\npassword=#{root_password}\n")
        @store.write_private(File.join(secrets, "count.cnf"), "[client]\nuser=silo_count\nsocket=/run/mysqld/mysqld.sock\npassword=#{count_password}\n")
        @store.write_private(File.join(secrets, "bootstrap.sql"), "CREATE DATABASE source CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n")
        # Created after the load, so nothing in the dump can change or drop them.
        @store.write_private(File.join(secrets, "users.sql"), <<~SQL)
          DROP USER IF EXISTS 'silo_convert'@'127.0.0.1', 'silo_count'@'localhost';
          CREATE USER 'silo_convert'@'127.0.0.1' IDENTIFIED BY '#{converter_password}';
          GRANT ALL PRIVILEGES ON source.* TO 'silo_convert'@'127.0.0.1';
          CREATE USER 'silo_count'@'localhost' IDENTIFIED BY '#{count_password}';
          GRANT SELECT ON source.* TO 'silo_count'@'localhost';
        SQL
        spec_input = role_input(inputs, "reconciliation")
        checks = spec_input ? reconciliation_spec(File.binread(input_path(run_id, spec_input))) : []

        short = run_id.delete_prefix("run-")[0, 8]
        common = ["--pull=never", "--restart", "no", "--read-only", "--user", "#{Process.uid}:#{Process.gid}", "--cap-drop", "ALL",
                  "--security-opt", "no-new-privileges", "--log-driver", "local", "--log-opt", "max-size=1m",
                  "--label", "silo-migrate.managed=true", "--label", "silo-migrate.instance=#{short}-conversion", "--label", "silo-migrate.run=#{run_id}"]
        tmpfs_opts = "rw,uid=#{Process.uid},gid=#{Process.gid},mode=0700"
        db_limits = body.dig("limits", "db")
        converter_limits = body.dig("limits", "converter")
        created = []
        begin
          db_id = checked(run_id, "conversion-db-start", ["docker", "run", "-d", *common, "--name", "silomig-#{short}-source-db", "--network", "none",
            "--cpus", db_limits["cpus"].to_s, "--memory", "#{db_limits['memory_mib']}m", "--memory-swap", "#{db_limits['memory_mib']}m", "--pids-limit", db_limits["pids"].to_s,
            "--mount", "type=bind,src=#{db_data},dst=/var/lib/mysql", "--mount", "type=bind,src=#{db_tmp},dst=/var/lib/mysql-tmp",
            "--tmpfs", "/tmp:#{tmpfs_opts},size=256m", "--tmpfs", "/run/mysqld:#{tmpfs_opts},size=16m",
            "-v", "#{File.join(secrets, 'root-password')}:/run-fixture/root-password:ro",
            "-v", "#{File.join(secrets, 'root.cnf')}:/run-fixture/root.cnf:ro",
            "-v", "#{File.join(secrets, 'count.cnf')}:/run-fixture/count.cnf:ro",
            "-v", "#{File.join(secrets, 'bootstrap.sql')}:/run-fixture/bootstrap.sql:ro",
            "-v", "#{File.join(secrets, 'users.sql')}:/run-fixture/users.sql:ro",
            "-v", "#{dump}:/run-fixture/dump:ro",
            "-e", "MARIADB_ROOT_PASSWORD_FILE=/run-fixture/root-password", "-e", "MARIADB_ROOT_HOST=localhost",
            image_id(run_id, "source_db"), "mariadbd", "--bind-address=127.0.0.1", "--skip-name-resolve", "--event-scheduler=DISABLED",
            "--innodb-buffer-pool-size=#{db_limits['buffer_pool']}", "--innodb-log-file-size=512M", "--innodb-flush-log-at-trx-commit=2",
            # LOAD DATA / INTO OUTFILE only inside the (empty, run-owned) tmp folder.
            "--max-allowed-packet=1G", "--max-connections=20", "--tmpdir=/var/lib/mysql-tmp", "--secure-file-priv=/var/lib/mysql-tmp"], timeout: 60).stdout.strip
          created << db_id
          wait_source_db(db_id)
          client = "mariadb --defaults-extra-file=/run-fixture/root.cnf --batch"
          checked(run_id, "conversion-db-bootstrap", ["docker", "exec", db_id, "/bin/sh", "-c", "exec #{client} < /run-fixture/bootstrap.sql"], timeout: 60)
          # --sandbox: the client refuses \! and system, so the dump can't run commands.
          checked(run_id, "conversion-db-load", ["docker", "exec", db_id, "bash", "-c",
            "set -o pipefail; #{decompress} /run-fixture/dump | mariadb --defaults-extra-file=/run-fixture/root.cnf --sandbox " \
            "--default-character-set=#{body.fetch('source_charset')} source > /dev/null"], timeout: LOAD_TIMEOUT)
          # A dump made with `mysqldump --databases` creates and USEs its own database: its
          # tables would be outside `source` and the converter would see nothing.
          tables = @runtime.run(["docker", "exec", db_id, "/bin/sh", "-c", "exec #{client} --skip-column-names -e " \
                                 "\"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'source'\""], capture: true, timeout: 120)
          raise StandardWorkflowError.new("STANDARD_CONVERSION_FAILED", "source check") unless tables.success? && single_count(tables.stdout)
          raise StandardWorkflowError.new("STANDARD_SOURCE_EMPTY", "no tables in source") unless single_count(tables.stdout).positive?

          checked(run_id, "conversion-db-users", ["docker", "exec", db_id, "/bin/sh", "-c", "exec #{client} < /run-fixture/users.sql"], timeout: 60)
          # Measured before the converter runs: converters may add indexes or tables.
          source_counts = checks.map { |check| source_count(db_id, check) }
          @store.write_private(@store.run_dir(run_id, "private", "source-counts.json"), JSON.pretty_generate(source_counts) + "\n")

          converter_args = ["docker", "run", "-d", *common, "--name", "silomig-#{short}-converter", "--network", "container:#{db_id}",
            "--cpus", converter_limits["cpus"].to_s, "--memory", "#{converter_limits['memory_mib']}m", "--memory-swap", "#{converter_limits['memory_mib']}m",
            "--pids-limit", converter_limits["pids"].to_s,
            "--tmpfs", "/tmp:#{tmpfs_opts},size=2g", "-v", "#{code}:/app:ro", "-v", "#{output}:/app/output",
            "-v", "#{File.join(secrets, 'settings.yml')}:/run-fixture/settings.yml:ro",
            "--mount", "type=bind,src=#{File.join(deps, 'gems')},dst=/deps,readonly",
            "--mount", "type=bind,src=#{File.join(deps, 'emoji_cache')},dst=/app/tmp/emoji_cache,readonly",
            "-e", "HOME=/tmp", "-e", "TMPDIR=/tmp", "-e", "LANG=C.UTF-8", "-e", "LC_ALL=C.UTF-8",
            *overlay_env(image_id(run_id, "converter")).flat_map { |item| ["-e", item] }, "-w", "/app",
            "--entrypoint", "/bin/sh", image_id(run_id, "converter"), "-c", "exec sleep infinity"]
          converter_id = checked(run_id, "conversion-container-start", converter_args, timeout: 60).stdout.strip
          created << converter_id
          # Output goes to a file, not memory: a real conversion can print for hours.
          convert = @runtime.run(["docker", "exec", "-w", "/app", converter_id, "/bin/sh", "-c",
                                  'exec env -u BUNDLE_PATH bundle _2.6.3_ exec ruby ./convert --from="$1" --settings=/run-fixture/settings.yml ' \
                                  '--output-db=intermediate.sqlite --reset > /app/output/convert.log 2>&1', "convert", body.fetch("platform")],
                                 capture: true, timeout: CONVERT_TIMEOUT)
        ensure
          # Anything that survives this is removed by the run's reset, via its label.
          created.reverse_each { |id| @runtime.run(["docker", "rm", "--force", "--volumes", id], capture: true, timeout: 120) }
        end
        tail = converter_log!(run_id, output, convert)
        raise StandardWorkflowError.new("STANDARD_CONVERSION_FAILED", "converter exit") unless convert.success?

        summary = tail.to_s.dup.force_encoding("UTF-8").scrub.split("== Run Summary ==", 2)[1]
        evidence(run_id, "conversion-summary.txt", summary[0, 8192]) if summary
        record_results(run_id, conversion_summary: summary ? "present" : "missing")
        produced = File.join(output, "intermediate.sqlite")
        raise StandardWorkflowError.new("STANDARD_CONVERSION_FAILED", "no output database") unless File.file?(produced) && !File.symlink?(produced)

        checkpoint_closed!(produced)
        intermediate = @store.run_dir(run_id, "artifacts", "intermediate.sqlite")
        FileUtils.mkdir_p(File.dirname(intermediate), mode: 0o700)
        FileUtils.cp(produced, intermediate)
        File.chmod(0o400, intermediate)
        FileUtils.rm_f(produced)
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("artifacts")["intermediate"] = artifact_identity(intermediate) }
      end

      # Read once the container is gone; never through a symlink. The whole output stays
      # private (logs/conversion-output.log) beside a bounded tail in logs/convert.log.
      def converter_log!(run_id, output, convert)
        path = File.join(output, "convert.log")
        tail = ""
        begin
          # NONBLOCK: a FIFO left in its place must not hang the run (stat.file? refuses it).
          File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
            raise Errno::ENOENT unless file.stat.file?

            file.seek([file.size - CONVERT_LOG_TAIL, 0].max)
            tail = file.read.to_s
          end
          FileUtils.mv(path, @store.run_dir(run_id, "logs", "conversion-output.log.tmp"))
        rescue SystemCallError
          tail = ""
        end
        log(run_id, "convert", SiloMigrate::Runtime::CommandResult.new(success?: convert.success?, stdout: tail, stderr: convert.stderr.to_s, status: convert.status))
        moved = @store.run_dir(run_id, "logs", "conversion-output.log.tmp")
        File.rename(moved, @store.run_dir(run_id, "logs", "conversion-output.log")) if File.file?(moved)
        tail
      end

      def source_count(db_id, check)
        # A scalar subquery: MariaDB itself refuses more than one row or column, so a query
        # that isn't a count can't stream a table into this process.
        sql = "SET SESSION max_statement_time=#{QUERY_TIMEOUT};\nSELECT (#{check.fetch('source_sql').strip.sub(/;\z/, '')});\n"
        result = @runtime.run(["docker", "exec", "-i", db_id, "mariadb", "--defaults-extra-file=/run-fixture/count.cnf", "--batch", "--skip-column-names",
                               "--sandbox", "source"], capture: true, timeout: QUERY_TIMEOUT + 60, stdin_data: sql)
        value = single_count(result.success? ? result.stdout.to_s : nil)
        { "name" => check.fetch("name"), "count" => value, "error" => value.nil? ? (result.success? ? "not a single count" : "query failed: #{result.stderr.to_s[0, 300]}") : nil }
      end

      def single_count(text)
        lines = text.to_s.lines.map(&:strip).reject(&:empty?)
        lines.size == 1 && lines.first.match?(/\A\d{1,18}\z/) ? lines.first.to_i : nil
      end

      def stage_reconcile(run_id)
        inputs = run_inputs(run_id)
        spec_input = role_input(inputs, "reconciliation")
        unless spec_input
          evidence(run_id, "reconciliation.json", { "policy" => "report", "checks" => [] })
          record_results(run_id, reconciliation_checks: 0, reconciliation_matched: 0, reconciliation_differs: 0, reconciliation_errors: 0)
          return
        end

        checks = reconciliation_spec(File.binread(input_path(run_id, spec_input)))
        source = JSON.parse(File.read(@store.run_dir(run_id, "private", "source-counts.json"))).to_h { |entry| [entry["name"], entry] }
        raise StandardWorkflowError, "STANDARD_INTERNAL" unless defined?(SQLite3::Database)

        path = @store.run_dir(run_id, "artifacts", "intermediate.sqlite")
        raise StandardWorkflowError, "STANDARD_INTERNAL" unless File.file?(path)

        rows = checks.map do |check|
          measured = source.fetch(check["name"], {})
          intermediate, error = intermediate_count(path, check.fetch("intermediate_sql"))
          problem = measured["error"] ? "source: #{measured['error']}" : (error && "intermediate: #{error}")
          status = if problem then "error"
                   elsif check["expect"] == "report" then "reported"
                   elsif measured["count"] == intermediate then "matched"
                   else "differs"
                   end
          { "name" => check["name"], "expect" => check["expect"], "source" => measured["count"], "intermediate" => intermediate,
            "difference" => problem ? nil : intermediate - measured["count"], "status" => status, "error" => problem, "note" => check["note"] }
        end
        evidence(run_id, "reconciliation.json", { "policy" => "report", "checks" => rows })
        record_results(run_id, reconciliation: rows, reconciliation_checks: rows.size,
                       reconciliation_matched: rows.count { |row| row["status"] == "matched" },
                       reconciliation_differs: rows.count { |row| row["status"] == "differs" },
                       reconciliation_errors: rows.count { |row| row["status"] == "error" })
      end

      def intermediate_query_timeout
        QUERY_TIMEOUT
      end

      # Read-only and immutable: a plain read-only open of a WAL database still creates
      # -shm/-wal files beside the artifact.
      def open_immutable(path)
        uri = "file:#{path.gsub('%', '%25').gsub('?', '%3f').gsub('#', '%23')}?immutable=1"
        SQLite3::Database.new(uri, flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI)
      end

      # Each count runs in a forked child that is killed at the deadline. The sqlite3 gem
      # can't time a query out in-process: 2.8.1's statement_timeout sets its deadline to
      # the moment the query starts, so any row-scanning query is interrupted within
      # ~2,000 VM steps, and the gem holds the GVL while stepping, so a watchdog thread
      # calling db.interrupt never runs. The child's CPU limit also ends it if this
      # process dies first.
      # The child inherits the store's lock descriptors; this process always kills and
      # reaps it before returning, and in the control container (ruby is PID 1) the
      # child dies with it.
      def intermediate_count(path, sql, timeout: intermediate_query_timeout)
        limit = timeout.ceil
        reader, writer = IO.pipe
        pid = Process.fork do
          # Only exit! leaves the child: no at_exit handlers or ensure blocks of the parent's stack.
          begin
            # No core dump: its memory holds pages of the intermediate database.
            Process.setrlimit(Process::RLIMIT_CORE, 0, 0)
            reader.close
            Process.setrlimit(Process::RLIMIT_CPU, limit + 5, limit + 10)
            result = begin
              db = open_immutable(path)
              intermediate_count_in(db, sql)
            rescue SQLite3::Exception => error
              [nil, "query failed: #{error.message.to_s.dup.force_encoding(Encoding::UTF_8).scrub[0, 300]}"]
            rescue StandardError => error
              [nil, "query failed: #{error.class}"]
            ensure
              db&.close
            end
            writer.write(JSON.generate(result))
            writer.close
          ensure
            exit!(0)
          end
        end
        writer.close
        read_child_result(reader, limit) || [nil, "query failed: timed out after #{limit} s"]
      rescue SystemCallError, IOError => error
        [nil, "query failed: #{error.class}"]
      ensure
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
        if pid
          begin
            Process.kill("KILL", pid)
          rescue Errno::ESRCH
            nil
          end
          begin
            Process.wait(pid)
          rescue Errno::ECHILD
            nil
          end
        end
      end

      # The child's [count, error] pair, [nil, error] if it died without one, or nil at the deadline.
      def read_child_result(reader, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        data = +""
        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil unless remaining.positive? && IO.select([reader], nil, nil, remaining)

          chunk = reader.read_nonblock(4096, exception: false)
          break if chunk.nil?
          next if chunk == :wait_readable

          data << chunk
          return [nil, "query failed: invalid result"] if data.bytesize > 4096
        end
        value, error = JSON.parse(data)
        return [value, nil] if value.is_a?(Integer) && value >= 0 && error.nil?
        return [nil, error] if value.nil? && error.is_a?(String)

        [nil, "query failed: invalid result"]
      rescue JSON::ParserError, TypeError
        [nil, "query failed: no result"]
      end

      def intermediate_count_in(db, sql)
        statement = db.prepare(sql.strip.sub(/;\z/, ""))
        return [nil, "more than one statement"] unless statement.remainder.to_s.strip.empty?

        results = statement.execute
        first = results.next
        # Never more than two rows read, whatever the query returns.
        value = first && first.size == 1 && results.next.nil? ? first.first : nil
        value.is_a?(Integer) && value >= 0 ? [value, nil] : [nil, "not a single count"]
      ensure
        statement&.close
      end
    end
  end
end
