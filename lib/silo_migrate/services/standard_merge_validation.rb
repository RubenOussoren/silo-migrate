# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "yaml"
require_relative "../../../runtime/shared/merge_contract"
require_relative "../../../runtime/shared/merge_refusal"
require_relative "../../../runtime/shared/merge_validation_diagnostic"
require_relative "../merge_process"
require_relative "../image_identity"
require_relative "standard_merge_validation_status"
require_relative "standard_merge_validation_lifecycle"
require_relative "standard_merge_validation_reconciliation"

module SiloMigrate
  module Services
    # Optional capability, NOT an orchestrator. Public validation owns host -> op locks;
    # the activation gate is lock-free and must be called before claim_plan! under both.
    # Production defaults below implement the two replaceable transport seams:
    #   merge_validation_context!(prepared_from:, generation:, settings:, layer:)
    #     => registered settings bytes and identities (see mv_context!). No arbitrary files.
    #   merge_validation_execute!(context, journal)
    #     => private guest result, after copying helpers/settings/context through private
    #        host files + docker cp. Never credentials in exec argv, env argv or logs.
    # Neither hook may mutate templates, grant analyst access or start an application.
    # Fixture success is not a claim of live PostgreSQL/Discourse acceptance.
    module StandardMergeValidation
      include StandardMergeValidationStatus
      include StandardMergeValidationLifecycle
      include StandardMergeValidationReconciliation
      VALIDATION_MAX_SETTINGS = 256 * 1024
      VALIDATION_ALLOWANCE = 512 * 1024 * 1024
      # Chat calls retain their bounded 180s work budget. A deliberate foreground
      # operator invocation may allow larger restored databases 30 minutes, without
      # changing any policy, non-clone SQL, guest or cleanup limit.
      VALIDATION_BUDGET = 180
      OPERATOR_VALIDATION_BUDGET = 1800
      VALIDATION_MODE_ENV = "SILO_MERGE_VALIDATION_MODE"
      VALIDATION_CLEANUP_BUDGET = 45
      VALIDATION_PREFIX = "SILO_MERGE_VALIDATION:"
      VALIDATION_GUEST_WRAPPER = '"$@"; rc=$?; printf "\nSILO_VALIDATION_GUEST_DONE:%s:%s\n" "$0" "$rc"; exit "$rc"'.freeze
      VALIDATION_RESULT_KEYS = %w[version status reason key_path approved_ids selected_ids_sha256 audit checks asset_preflight_sha256 selection_sha256 owner_preflight_sha256].freeze
      VALIDATION_ID = /\A[0-9a-f]{32}\z/
      VALIDATION_SHA = /\A[0-9a-f]{64}\z/
      VALIDATION_EXECUTOR_STEPS = %w[executor_preflight sidecar_image sidecar_create sidecar_ready private_staging guest_copy guest_launch guest_result].freeze
      VALIDATION_STEPS = (VALIDATION_EXECUTOR_STEPS + %w[sql resources_absent create_role clone_source restrict_source clone_base restrict_base template_custody resource_identity guest_validation result_verification cleanup_resources cleanup_source cleanup_base cleanup_role cleanup_absence]).freeze
      VALIDATION_FAILURE_REASONS = %w[STANDARD_MERGE_VALIDATION_UNPROVEN STANDARD_MERGE_VALIDATION_PROTOCOL STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED STANDARD_MERGE_TEMPLATE_CUSTODY].freeze

      def merge_contract
        layer = merger_proposal_layer!
        bytes = merger_contract!(layer.fetch("revision"))
        mv_error!("STANDARD_MERGE_CONTRACT_REQUIRED") unless bytes
        contract = SiloMergeContract.load(bytes)
        capability = SiloMigrate::MergeProcess.registry.fetch(contract.fetch("engine")).describe
        result = { "layer" => layer, "contract" => contract, "contract_sha256" => Digest::SHA256.hexdigest(bytes), "capability" => capability }
        # Stock tool responses are capped below 50 KiB. Large valid schemas are
        # shared as a digest-bound private derivative readable with data_peek's
        # existing offset paging, never by widening access to the layer checkout.
        if bytes.bytesize > 24 * 1024 || JSON.generate(result).bytesize > 24 * 1024
          relative = mv_contract_file!(bytes, result.fetch("contract_sha256"))
          result["contract_file"] = { "area" => "work", "path" => relative, "sha256" => result.fetch("contract_sha256"), "bytes" => bytes.bytesize }
        end
        result
      rescue SiloMergeContract::Error
        mv_error!("STANDARD_MERGE_CONTRACT_INVALID")
      rescue SiloMigrate::MergeProcess::Refused
        mv_error!("STANDARD_MERGE_ENGINE_UNSUPPORTED")
      end

      def validate_merge_settings(prepared_from:, generation:, settings:, checks: [])
        @store.with_host_lock do
          @store.with_op_lock do
            mv_validate!(prepared_from: prepared_from, generation: generation, settings: settings, checks: checks)
          end
        end
      rescue SiloMergeContract::Error => error
        { "version" => 1, "status" => "refused", "reason" => "STANDARD_MERGE_SETTINGS_INVALID", "key_path" => error.key_path }
      rescue StandardWorkflowError => error
        { "version" => 1, "status" => "refused", "reason" => error.code, "key_path" => [] }
      rescue StandardError
        { "version" => 1, "status" => "refused", "reason" => "STANDARD_MERGE_VALIDATION_UNPROVEN", "key_path" => [] }
      end

      # Exact destination discovery needs neither settings nor a project contract.
      # It never loads a layer/Rails or starts Redis; only explicit parameterized
      # SELECTs against isolated clones using the same SELECT-only role.
      def merge_exact_existence(prepared_from:, generation:, queries:)
        @store.with_host_lock do
          @store.with_op_lock do
            mv_no_resources!
            require_relative "../../../runtime/prebuilt-discourse/merge_validate"
            begin
              SiloMergeContract.tree!(queries)
              SiloMergeValidation.request!(queries)
              mv_error!("STANDARD_MERGE_CHECKS_INVALID") if queries.empty?
            rescue SiloMergeValidation::Refused, SiloMergeContract::Error
              mv_error!("STANDARD_MERGE_CHECKS_INVALID")
            end
            state = @store.load
            run = state.fetch("runs")[prepared_from]
            environment = run && run["merge_environment"]
            unless VALIDATION_SHA.match?(generation.to_s) && run && run["status"] == "completed" && environment && environment["generation"] == generation && environment["consumed_by"].nil? && merge_environment_phase(state, environment) == "ready"
              mv_error!("STANDARD_MERGE_ENVIRONMENT_STALE")
            end
            body = state.fetch("plans").fetch(run.fetch("plan_id")).fetch("body")
            context = { "prepared_from" => prepared_from, "generation" => generation, "mode" => "checks", "checks" => queries,
                        "runtime_profile" => review_runtime_for(body), "deadline" => mv_clock + mv_work_budget }
            templates = mv_custody!(context)
            disk_headroom!(templates.values.sum { |row| row.fetch("bytes") } + VALIDATION_ALLOWANCE)
            id = SecureRandom.hex(16)
            journal = { "version" => 1, "id" => id, "prepared_from" => prepared_from, "generation" => generation,
                        "source" => "silo_val_s_#{id}", "base" => "silo_val_b_#{id}", "role" => "silo_val_r_#{id}",
                        "templates" => templates, "status" => "owned_unknown", "cleanup_confirmed" => false }
            mv_write!(mv_path(id, "resources.json"), journal)
            result = nil
            diagnostics = {}
            begin
              password = SecureRandom.hex(32)
              mv_provision!(context, journal, password)
              mv_step!(context, "guest_validation")
              executor_token = mv_executor_begin!(journal)
              result = merge_validation_execute!(context.merge("password" => password, "builtin_executor_tracking" => method(:merge_validation_execute!).owner == StandardMergeValidation), journal)
              mv_producer!(journal, "executor", "completed", token: executor_token)
              mv_step!(context, "result_verification")
              # Checks-only uses the same complete private envelope, without
              # claiming a semantic merge validation or issuing a Start binding.
              allowed = result.is_a?(Hash) && (result.keys - ["guest_diagnostic"]).sort == VALIDATION_RESULT_KEYS.sort && result["version"] == 1 && result["approved_ids"] == [] && result["audit"] == {} &&
                result["checks"].is_a?(Array) && result["checks"].size == queries.size && result["key_path"] == [] &&
                %w[passed refused].include?(result["status"]) && %w[ok checks_invalid].include?(result["reason"]) && result["selection_sha256"].nil? && result["asset_preflight_sha256"].nil? && result["owner_preflight_sha256"].nil? && result["selected_ids_sha256"] == Digest::SHA256.hexdigest("[]")
              mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless allowed
              mv_guest_diagnostic!(result.fetch("guest_diagnostic")) if result.key?("guest_diagnostic")
              proven = result["checks"].none? { |answer| answer["status"] == "unproven" }
              mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless result["status"] == (proven ? "passed" : "refused") && result["reason"] == (proven ? "ok" : "checks_invalid")
              result["checks"].each do |answer|
                counts = { "found" => 1, "absent" => 0, "ambiguous" => 2, "unproven" => nil }
                mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless answer.is_a?(Hash) && answer.keys.sort == %w[count status] && counts.key?(answer["status"]) && answer["count"] == counts[answer["status"]]
              end
            rescue StandardError => error
              diagnostics["work"] = mv_failure_diagnostic(context, error)
              result = { "version" => 1, "status" => "refused", "reason" => "STANDARD_MERGE_VALIDATION_UNPROVEN", "key_path" => [] }
            ensure
              begin
                mv_work_outcome!(journal, result, diagnostics["work"])
                cleanup_context = context.merge("deadline" => mv_clock + VALIDATION_CLEANUP_BUDGET)
                mv_cleanup!(cleanup_context, journal)
                mv_error!("STANDARD_MERGE_TEMPLATE_CUSTODY") unless mv_same_template_custody?(mv_custody!(cleanup_context), templates)
                journal.merge!("status" => "cleaned", "cleanup_confirmed" => true)
                mv_write!(mv_path(id, "resources.json"), journal)
              rescue StandardError => error
                diagnostics["cleanup"] = mv_failure_diagnostic(cleanup_context, error)
                result = { "version" => 1, "status" => "refused", "reason" => "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", "key_path" => [] }
              end
            end
            result["diagnostics"] = diagnostics unless diagnostics.empty?
            result = result.merge(journal.slice("work_status", "primary_reason", "producer_outcome", "guest_diagnostic"), "receipt_id" => id, "cleanup_confirmed" => journal["cleanup_confirmed"])
            mv_write!(mv_path(id, "json"), result.merge("templates" => templates, "generation" => generation, "prepared_from" => prepared_from))
            result
          end
        end
      rescue StandardWorkflowError => error
        { "version" => 1, "status" => "refused", "reason" => error.code, "key_path" => [] }
      rescue StandardError
        { "version" => 1, "status" => "refused", "reason" => "STANDARD_MERGE_VALIDATION_UNPROVEN", "key_path" => [] }
      end

      private

      def merge_process_contract_for(layer)
        described = merge_contract
        mv_error!("STANDARD_MERGE_VALIDATION_STALE") unless described["layer"] == layer
        described.fetch("contract")
      end

      def merge_process_binding!(prepared_from:, generation:, settings:, layer:)
        result = validate_merge_settings(prepared_from: prepared_from, generation: generation, settings: settings)
        unless result["status"] == "passed"
          id = result["receipt_id"]
          id = nil unless id.is_a?(String) && VALIDATION_ID.match?(id)
          projection = mv_saved_projection(id, result, nil, id ? "saved" : "missing", "missing")
          projection = merge_validation_status(attempt: id) if id
          raise StandardMergeValidationFailure.new(projection), cause: nil
        end
        mv_error!("STANDARD_MERGE_VALIDATION_STALE") unless result.fetch("layer") == layer
        result.fetch("binding")
      end

      private

      # Production defaults; tests may override these narrow transport boundaries.
      def merge_validation_context!(prepared_from:, generation:, settings:, layer:)
        named = @store.named_state
        input = named.fetch("inputs")[settings]
        mv_error!("STANDARD_MERGE_SETTINGS_INVALID") unless input && input["type"] == "merge-settings" && inputs_unchanged?([input])
        bytes = merge_settings_input!(input)
        run = @store.load.fetch("runs").fetch(prepared_from)
        body = @store.load.fetch("plans").fetch(run.fetch("plan_id")).fetch("body")
        { "settings_bytes" => bytes, "runtime_sha256" => body.fetch("runtime_lock_sha256"), "code_sha256" => code_identity,
          "runtime_profile" => review_runtime_for(body) }
      end

      def merge_validation_execute!(context, journal)
        context = context.merge("deadline" => context.fetch("deadline", mv_clock + mv_work_budget))
        host_dir = nil
        host_identity = nil
        mv_journal!(journal)
        # Only a direct call to the shipped implementation may hand off the
        # opaque-producer guard. An override that delegates here remains opaque
        # until that override itself returns to the owning wrapper.
        mv_executor_handoff!(journal) if context["builtin_executor_tracking"] == true
        with_review_runtime(context.fetch("runtime_profile")) do
          stack = stack_for(context.fetch("prepared_from"), "review")
          mv_step!(context, "executor_preflight")
          mv_runtime_verify!(context, journal)
          binding = journal.fetch("runtime_binding")
          stack.define_singleton_method(:container) { |service| binding.fetch("#{service}_id") }
          host_dir = File.join(@store.root, "validations", journal.fetch("id"))
          Dir.mkdir(host_dir, 0o700)
          host_stat = File.lstat(host_dir)
          host_identity = [host_stat.dev, host_stat.ino]
          # The child runs with only these generated paths in argv. Passwords
          # exist solely in 0600 host files and 0400 guest context files.
          guest = "/shared/silo-validation-#{journal.fetch('id')}"
          # Journal the sidecar and private guest credentials BEFORE creation/copy.
          journal["guest_directory"] = guest
          journal["redis"] = "silo-val-redis-#{journal.fetch('id')}" unless context["mode"] == "checks"
          mv_write!(mv_path(journal.fetch("id"), "resources.json"), journal)
          unless context["mode"] == "checks"
          network = stack.record.fetch("networks").first
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless network.is_a?(String) && !network.empty?
          mv_step!(context, "sidecar_image")
          image = ImageIdentity.resolve(@runtime, context.fetch("runtime_profile").fetch("images").fetch("redis"))
          mv_step!(context, "sidecar_create")
          redis_seconds = mv_timeout(context, 60)
          redis_token = mv_producer!(journal, "redis", "unknown")
          # The pinned entrypoint drops root via gosu, which cannot run with ALL
          # capabilities dropped. Start as its existing non-root account instead;
          # keep every capability dropped and the root filesystem read-only.
          created = @runtime.run(["docker", "create", "--pull=never", "--restart=no", "--name", journal.fetch("redis"), "--label", "silo-migrate.managed=true", "--label", "silo-migrate.validation=#{journal.fetch('id')}",
                                  "--network", network, "--user", "redis:redis", "--memory", "128m", "--memory-swap", "128m", "--pids-limit", "64", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--cpus", "0.5", "--read-only", "--tmpfs", "/data:rw,noexec,nosuid,size=16m", image,
                                  "redis-server", "--save", "", "--appendonly", "no"], capture: true, timeout: redis_seconds)
          mv_producer!(journal, "redis", created.success? && created.status == 0 && created.stdout.to_s.strip.match?(/\A[0-9a-f]{64}\z/) ? "completed" : "unknown", token: redis_token)
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless created.success? && created.stdout.to_s.strip.match?(/\A[0-9a-f]{64}\z/)
          journal["redis_id"] = created.stdout.strip
          mv_write!(mv_path(journal.fetch("id"), "resources.json"), journal)
          mv_step!(context, "sidecar_ready")
          mv_command!(["docker", "start", journal.fetch("redis_id")], context: context)
          redis_ready = false
          10.times do
            ping = @runtime.run(["docker", "exec", journal.fetch("redis_id"), "redis-cli", "ping"], capture: true, timeout: mv_timeout(context, 5))
            if ping.success? && ping.stdout.to_s.strip == "PONG"
              redis_ready = true
              break
            end
            sleep 0.2
          end
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless redis_ready
          end
          mv_step!(context, "private_staging")
          # Immutable committed bytes, never the working tree.
          unless context["mode"] == "checks"
          current, files = merger_layer!(context.fetch("layer").fetch("revision"))
          mv_error!("STANDARD_MERGE_VALIDATION_STALE") unless current == context.fetch("layer")
          files.each do |path, bytes|
            next unless path.end_with?(".rb")
            target = File.join(host_dir, "layer", path)
            FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
            mv_raw_write!(target, bytes)
          end
          end
          helper_root = File.expand_path("../../../runtime", __dir__)
          %w[merge_validate.rb merge_validation_config.rb merge_adapter.rb merge_asset_references.rb merge_baseline_assets.rb].each do |name|
            mv_raw_write!(File.join(host_dir, name), File.binread(File.join(helper_root, "prebuilt-discourse", name)))
          end
          %w[merge_contract.rb merge_assets.rb merge_refusal.rb merge_validation_diagnostic.rb].each do |name|
            mv_raw_write!(File.join(host_dir, name), File.binread(File.join(helper_root, "shared", name)))
          end
          work = File.join(host_dir, "work")
          Dir.mkdir(work, 0o700)
          unless context["mode"] == "checks"
            mv_raw_write!(File.join(work, "settings.yml"), context.fetch("settings_bytes"))
            mv_raw_write!(File.join(work, "contract.json"), merger_contract!(context.fetch("layer").fetch("revision")))
          end
          private_context = context.slice("password", "checks", "mode").merge(journal.slice("source", "base", "role")).merge(
            "host" => "db", "port" => 5432, "redis_isolated" => true, "redis_host" => journal["redis"], "redis_port" => 6379,
            "original_config_path" => "/var/www/discourse/config/discourse.conf", "validation_config_path" => "#{guest}/work/discourse-validation.conf",
            "settings_path" => "#{guest}/work/settings.yml", "contract_path" => "#{guest}/work/contract.json", "layer_path" => "#{guest}/layer/merger.rb")
          mv_raw_write!(File.join(work, "context.json"), JSON.generate(private_context))
          # Docker cp into an existing directory has different semantics. Never
          # adopt a pre-existing generated path or a symlink as our credential dir.
          mv_step!(context, "guest_copy")
          mv_recovery_refuse! unless mv_guest_identity!(context, journal) == "absent"
          journal["guest_preflight_absent"] = true
          mv_save_journal!(journal)
          copy_seconds = [mv_timeout(context, 60) / 2, 1].max
          copy_token = mv_producer!(journal, "guest_copy", "unknown")
          stack.copy_in(host_dir, guest, owner: "discourse:discourse", timeout: copy_seconds)
          journal["guest_identity"] = mv_guest_identity!(context, journal)
          mv_producer!(journal, "guest_copy", "completed", token: copy_token)
          mv_web!(stack, ["sh", "-c", "find #{guest} -type f -exec chmod 400 {} + && find #{guest} -type d -exec chmod 700 {} +"], context: context)
          ruby_options = context["mode"] == "checks" ? [] : ["-r#{guest}/merge_validation_config.rb"]
          mv_step!(context, "guest_launch")
          guest_seconds = mv_timeout(context, 150)
          journal["guest_timeout_seconds"] = guest_seconds
          guest_token = mv_producer!(journal, "guest", "unknown")
          # The shell waits for the exact child and returns a nonce-bound final
          # frame, including bootstrap failures before Ruby can emit its envelope.
          # A Docker client exit code alone is never producer-completion proof.
          # Load the guard only in the bundled Ruby child. RUBYOPT here would
          # also preload it into the bundle launcher, before its native pg gem
          # is activated; no PG constructor or Rails code runs before this hook.
          result = stack.discourse_shell(["sh", "-c", VALIDATION_GUEST_WRAPPER, guest_token, "env",
                                          "SILO_MERGE_VALIDATION_CONTEXT=#{guest}/work/context.json",
                                          "SILO_MERGE_SETTINGS=#{guest}/work/settings.yml", "SILO_MERGE_VALIDATION_RESULT=#{guest}/work/result.json",
                                          "bundle", "exec", "ruby", *ruby_options, "#{guest}/merge_validate.rb"], env_password: false, timeout: guest_seconds)
          line = result.stdout.to_s.b
          suffix = /\nSILO_VALIDATION_GUEST_DONE:#{guest_token}:([0-9]{1,3})\n\z/n.match(line)
          terminal = suffix && result.status.is_a?(Integer) && result.status == suffix[1].to_i && result.status.between?(0, 255)
          journal["guest_command_outcome"] = terminal ? ([0, 4].include?(result.status) ? "completed" : "failed") : (result.status.nil? ? "timeout_or_interrupted" : "unknown")
          if terminal
            line = line[0...suffix.begin(0)]
            mv_producer!(journal, "guest", "completed", token: guest_token)
            unless [0, 4].include?(result.status)
              journal["guest_diagnostic"] = mv_bootstrap_diagnostic(result.stderr.to_s)
            end
          end
          mv_save_journal!(journal)
          # Unknown execution remains quarantined; a known failed child remains
          # failed work but can clean its exact-owned scratch resources normally.
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless terminal && [0, 4].include?(result.status)
          mv_step!(context, "guest_result")
          line.force_encoding(Encoding::UTF_8)
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless line.valid_encoding? && line.bytesize <= 2048 && line.lines.size == 1 && line.start_with?(VALIDATION_PREFIX)
          projection = SiloMergeContract.parse(line.delete_prefix(VALIDATION_PREFIX).strip, max_bytes: 2048)
          if projection.is_a?(Hash) && projection.key?("guest_diagnostic")
            journal["guest_diagnostic"] = mv_guest_diagnostic!(projection.fetch("guest_diagnostic"))
            mv_save_journal!(journal)
          end
          # Bound guest result BEFORE docker cp, not after a potentially huge copy.
          size = stack.web_exec(["stat", "-c", "%s", "#{guest}/work/result.json"], timeout: mv_timeout(context, 30))
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless size.success? && size.stdout.to_s.strip.match?(/\A[0-9]+\z/) && size.stdout.to_i <= 4 * 1024 * 1024
          private_result = File.join(host_dir, "result.json")
          stack.copy_out("#{guest}/work/result.json", private_result, timeout: mv_timeout(context, 30))
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") if File.symlink?(private_result) || !File.file?(private_result)
          File.chmod(0o600, private_result)
          record = SiloMergeContract.parse(mv_read!(private_result, 4 * 1024 * 1024), max_bytes: 4 * 1024 * 1024)
          expected = record.slice("version", "status", "reason", "selected_ids_sha256", "asset_preflight_sha256", "selection_sha256", "guest_diagnostic").merge("key_path" => [])
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless projection == expected
          # Known exited child: remove private credentials synchronously. Anything
          # failing here leaves an owned journal and blocks subsequent activation.
          mv_recovery_refuse! unless mv_guest_identity!(context, journal) == journal.fetch("guest_identity")
          journal["guest_cleanup_intent"] = true
          mv_save_journal!(journal)
          mv_command!(["docker", "exec", journal.fetch("runtime_binding").fetch("web_id"), "rm", "-rf", "--", guest], context: context)
          journal["guest_cleaned"] = true
          mv_write!(mv_path(journal.fetch("id"), "resources.json"), journal)
          record
        end
      ensure
        # Private host credentials are never receipt material. Unknown guest exec
        # retains its guest copy under the owned journal for scoped recovery.
        if host_identity && (File.exist?(host_dir) || File.symlink?(host_dir))
          stat = File.lstat(host_dir)
          mv_recovery_refuse! unless stat.directory? && !stat.symlink? && [stat.dev, stat.ino] == host_identity
          FileUtils.remove_entry(host_dir)
        end
      end

      def mv_clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def mv_timeout(context, maximum)
        return maximum unless context["deadline"]
        remaining = context.fetch("deadline") - mv_clock
        mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless remaining.positive?
        [maximum, remaining.ceil].min
      end

      def mv_command!(argv, context: {})
        journal = context["lifecycle_journal"]
        mv_runtime_verify!(context, journal) if journal
        seconds = mv_timeout(context, 60)
        command_token = mv_producer!(journal, "auxiliary", "unknown") if journal
        result = @runtime.run(argv, capture: true, timeout: seconds)
        mv_producer!(journal, "auxiliary", result.success? && result.status == 0 ? "completed" : "unknown", token: command_token) if journal
        mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless result.success?
        result
      end

      def mv_web!(stack, argv, context: {})
        result = stack.web_exec(argv, timeout: mv_timeout(context, 60))
        mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless result.success?
        result
      end

      def mv_contract_file!(bytes, digest)
        root = File.join(@store.workspace_root, "work")
        [root, File.join(root, "workflow-contracts")].each do |directory|
          begin
            Dir.mkdir(directory, 0o700)
          rescue Errno::EEXIST
            # Another describe/proposal may have created it. Verify, never adopt
            # an existing symlink, foreign owner or publicly readable directory.
          end
          stat = File.lstat(directory)
          mv_error!("STANDARD_MERGE_CONTRACT_INVALID") unless stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
        end
        relative = "workflow-contracts/#{digest}.json"
        path = File.join(root, relative)
        unless File.exist?(path) || File.symlink?(path)
          temporary = "#{path}.#{SecureRandom.hex(8)}.tmp"
          begin
            mv_raw_write!(temporary, bytes)
            begin
              # Publish only closed/fsynced bytes, without replacing any existing
              # derivative. Concurrent readers never observe a partial write.
              File.link(temporary, path)
            rescue Errno::EEXIST
              # The competing publisher's complete bytes are checked below.
            end
            File.open(File.dirname(path), File::RDONLY) { |directory| directory.fsync }
          ensure
            File.unlink(temporary) if File.exist?(temporary)
          end
        end
        mv_error!("STANDARD_MERGE_CONTRACT_INVALID") unless mv_read!(path, SiloMergeContract::MAX_BYTES).b == bytes.b
        relative
      rescue SystemCallError, StandardWorkflowError
        mv_error!("STANDARD_MERGE_CONTRACT_INVALID")
      end

      def mv_raw_write!(path, bytes)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |file| file.write(bytes); file.flush; file.fsync }
      end

      def mv_error!(code)
        raise StandardWorkflowError, code, cause: nil
      end

      # No recursive locks. Call before consumption, then optionally as a backstop
      # with the owning claimed run. Never accepts fenced/activated state.
      def merge_validation_gate!(body, claimed_run_id: nil)
        mv_no_resources!
        binding = body.dig("merge", "process")
        mv_error!("STANDARD_MERGE_VALIDATION_REQUIRED") unless binding.is_a?(Hash) && VALIDATION_ID.match?(binding["receipt_id"].to_s)
        bytes = mv_read!(mv_path(binding["receipt_id"], "json"), 4 * 1024 * 1024)
        mv_error!("STANDARD_MERGE_VALIDATION_STALE") unless Digest::SHA256.hexdigest(bytes) == binding["receipt_sha256"]
        receipt = SiloMergeContract.parse(bytes, max_bytes: 4 * 1024 * 1024)
        mv_error!("STANDARD_MERGE_VALIDATION_STALE") unless receipt["status"] == "passed" && receipt["cleanup_confirmed"] == true && binding == mv_binding(receipt, bytes)
        prepared = body.fetch("prepared_from")
        mv_error!("STANDARD_MERGE_VALIDATION_STALE") unless prepared["run_id"] == receipt["prepared_from"] && prepared["generation"] == receipt["generation"] && body.dig("roles", "settings") == receipt["settings"] && body.dig("merge", "layer") == receipt["layer"]
        context = mv_context!(prepared_from: receipt["prepared_from"], generation: receipt["generation"], settings: receipt["settings"], layer: receipt["layer"], claimed_run_id: claimed_run_id, claimed_body: body).merge("deadline" => mv_clock + mv_work_budget)
        mv_error!("STANDARD_MERGE_VALIDATION_STALE") unless mv_facts(context) == receipt.fetch("facts")
        unless body["code_identity"] == context.fetch("code_sha256") && body["runtime_lock_sha256"] == context.fetch("runtime_sha256") && body.dig("merge", "contract") == context.fetch("contract")
          mv_error!("STANDARD_MERGE_VALIDATION_STALE")
        end
        setting = body.fetch("input_binding").find { |input| input["id"] == receipt["settings"] }
        unless setting && setting["type"] == "merge-settings" && setting["sha256"] == context.fetch("settings_sha256") && setting["bytes"] == context.fetch("settings_bytes").bytesize
          mv_error!("STANDARD_MERGE_VALIDATION_STALE")
        end
        mv_error!("STANDARD_MERGE_VALIDATION_STALE") unless mv_same_template_custody?(mv_custody!(context), receipt.fetch("templates"))
        unless claimed_run_id
          # Sealed DB custody alone says nothing about mutable upload bytes or
          # destination reuse. Re-prove assets on fresh SELECT-only views BEFORE
          # claim/fencing; retain the approved receipt binding, never auto-rebind.
          current = mv_validate!(prepared_from: receipt.fetch("prepared_from"), generation: receipt.fetch("generation"), settings: receipt.fetch("settings"), checks: [], deadline: context.fetch("deadline"))
          compared = %w[selected_ids_sha256 selection_sha256 asset_preflight_sha256 owner_preflight_sha256 facts]
          unless current["status"] == "passed" && current["cleanup_confirmed"] == true && compared.all? { |key| current[key] == receipt[key] } && mv_same_template_custody?(current["templates"], receipt["templates"])
            mv_error!("STANDARD_MERGE_VALIDATION_STALE")
          end
        end
        true
      rescue KeyError, SiloMergeContract::Error, SystemCallError
        mv_error!("STANDARD_MERGE_VALIDATION_STALE")
      end

      def mv_context!(prepared_from:, generation:, settings:, layer: nil, claimed_run_id: nil, claimed_body: nil)
        mv_error!("STANDARD_MERGE_ENVIRONMENT_STALE") unless VALIDATION_SHA.match?(generation.to_s)
        state = @store.load
        run = state.fetch("runs", {})[prepared_from]
        env = run && run["merge_environment"]
        ready = env.is_a?(Hash) && env["consumed_by"].nil? && merge_environment_phase(state, env) == "ready"
        consumer = claimed_run_id && state.fetch("runs", {})[claimed_run_id]
        owner_plan = consumer && state.fetch("plans", {})[consumer["plan_id"]]
        claimed = claimed_run_id && env.is_a?(Hash) && env["phase"] == "consumed" && env["consumed_by"] == claimed_run_id &&
          consumer && consumer["status"] == "running" && owner_plan && owner_plan["body"] == claimed_body
        unless run && run["status"] == "completed" && env.is_a?(Hash) && env["generation"] == generation && (ready || claimed)
          mv_error!("STANDARD_MERGE_ENVIRONMENT_STALE")
        end
        described = merge_contract
        mv_error!("STANDARD_MERGE_VALIDATION_STALE") if layer && described["layer"] != layer
        mv_error!("STANDARD_MERGE_VALIDATION_UNSUPPORTED") unless respond_to?(:merge_validation_context!, true)
        context = merge_validation_context!(prepared_from: prepared_from, generation: generation, settings: settings, layer: described["layer"])
        unless context.is_a?(Hash) && %w[settings_bytes runtime_sha256 code_sha256].all? { |key| context.key?(key) } && %w[runtime_sha256 code_sha256].all? { |key| VALIDATION_SHA.match?(context[key].to_s) }
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN")
        end
        bytes = context.fetch("settings_bytes")
        mv_error!("STANDARD_MERGE_SETTINGS_INVALID") unless bytes.is_a?(String) && bytes.bytesize <= VALIDATION_MAX_SETTINGS
        # Reject duplicate mapping keys as well as aliases/tags: safe_load alone
        # silently accepts duplicate keys. No symbol/class/date coercions.
        tree = YAML.parse_stream(bytes)
        mv_error!("STANDARD_MERGE_SETTINGS_INVALID") unless tree.children.size == 1
        mv_yaml_unique!(tree)
        value = YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
        policy = SiloMigrate::MergeProcess::Gate.new(SiloMigrate::MergeProcess.registry).validate(
          engine: described.fetch("contract").fetch("engine"), context: { contract: described.fetch("contract"), settings: value }).fetch("binding").fetch("physical_policy")
        context.merge(described).merge("prepared_from" => prepared_from, "generation" => generation, "settings" => settings, "physical_policy" => policy,
                                      "settings_sha256" => Digest::SHA256.hexdigest(bytes))
      rescue Psych::Exception, ArgumentError, SiloMigrate::MergeProcess::Refused
        mv_error!("STANDARD_MERGE_SETTINGS_INVALID")
      end

      def mv_yaml_unique!(node, depth = 0)
        mv_error!("STANDARD_MERGE_SETTINGS_INVALID") if depth > 20
        if node.is_a?(Psych::Nodes::Mapping)
          keys = node.children.each_slice(2).map(&:first)
          unless keys.all? { |key| key.is_a?(Psych::Nodes::Scalar) } && keys.map(&:value).uniq.size == keys.size
            mv_error!("STANDARD_MERGE_SETTINGS_INVALID")
          end
        end
        Array(node.respond_to?(:children) ? node.children : []).each { |child| mv_yaml_unique!(child, depth + 1) }
      end

      def mv_facts(context)
        context.slice("prepared_from", "generation", "settings", "layer", "runtime_sha256", "code_sha256", "settings_sha256", "contract_sha256", "physical_policy").merge(
          "validation_code_sha256" => Digest::SHA256.hexdigest([__FILE__, "../../../runtime/prebuilt-discourse/merge_validate.rb", "../../../runtime/prebuilt-discourse/merge_validation_config.rb", "../../../runtime/prebuilt-discourse/merge_adapter.rb", "../../../runtime/prebuilt-discourse/merge_asset_references.rb", "../../../runtime/prebuilt-discourse/merge_baseline_assets.rb", "../../../runtime/shared/merge_assets.rb", "../../../runtime/shared/merge_contract.rb", "../../../runtime/shared/merge_refusal.rb", "../../../runtime/shared/merge_validation_diagnostic.rb"].map { |file| File.binread(file == __FILE__ ? file : File.expand_path(file, __dir__)) }.join))
      end

      def mv_validate!(prepared_from:, generation:, settings:, checks:, deadline: nil)
        mv_no_resources!
        context = mv_context!(prepared_from: prepared_from, generation: generation, settings: settings).merge("deadline" => deadline || mv_clock + mv_work_budget)
        mv_error!("STANDARD_MERGE_VALIDATION_UNSUPPORTED") unless respond_to?(:merge_validation_execute!, true)
        # Validate the bounded request shape before any provision, not in Rails.
        SiloMergeContract.tree!(checks)
        require_relative "../../../runtime/prebuilt-discourse/merge_validate"
        begin
          SiloMergeValidation.request!(checks)
        rescue SiloMergeValidation::Refused
          mv_error!("STANDARD_MERGE_CHECKS_INVALID")
        end
        templates = mv_custody!(context)
        required = templates.values.sum { |row| row.fetch("bytes") } + VALIDATION_ALLOWANCE
        disk_headroom!(required)
        id = SecureRandom.hex(16)
        journal = { "version" => 1, "id" => id, "prepared_from" => prepared_from, "generation" => generation,
                    "source" => "silo_val_s_#{id}", "base" => "silo_val_b_#{id}", "role" => "silo_val_r_#{id}",
                    "templates" => templates, "status" => "owned_unknown", "cleanup_confirmed" => false }
        # This fsynced private intent MUST precede CREATE, including CREATE ROLE.
        mv_write!(mv_path(id, "resources.json"), journal)
        result = nil
        diagnostics = {}
        begin
          password = SecureRandom.hex(32)
          mv_provision!(context, journal, password)
          mv_step!(context, "guest_validation")
          executor_token = mv_executor_begin!(journal)
          result = merge_validation_execute!(context.merge("password" => password, "checks" => checks, "builtin_executor_tracking" => method(:merge_validation_execute!).owner == StandardMergeValidation), journal)
          mv_producer!(journal, "executor", "completed", token: executor_token)
          mv_step!(context, "result_verification")
          result = mv_result!(result, context, checks)
        rescue StandardError => error
          diagnostics["work"] = mv_failure_diagnostic(context, error)
          result = { "version" => 1, "status" => "refused", "reason" => "STANDARD_MERGE_VALIDATION_UNPROVEN", "key_path" => [] }
        ensure
          # Cleanup failure/timeout is never swallowed into a passing receipt.
          begin
            mv_work_outcome!(journal, result, diagnostics["work"])
            cleanup_context = context.merge("deadline" => mv_clock + VALIDATION_CLEANUP_BUDGET)
            mv_cleanup!(cleanup_context, journal)
            unchanged = mv_same_template_custody?(mv_custody!(cleanup_context), templates)
            mv_error!("STANDARD_MERGE_TEMPLATE_CUSTODY") unless unchanged
            journal["status"] = "cleaned"
            journal["cleanup_confirmed"] = true
            mv_write!(mv_path(id, "resources.json"), journal)
          rescue StandardError => error
            diagnostics["cleanup"] = mv_failure_diagnostic(cleanup_context, error)
            result = { "version" => 1, "status" => "refused", "reason" => "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", "key_path" => [] }
          end
        end
        result["diagnostics"] = diagnostics unless diagnostics.empty?
        receipt = result.merge(journal.slice("work_status", "primary_reason", "producer_outcome", "guest_diagnostic"), "receipt_id" => id, "prepared_from" => prepared_from, "generation" => generation, "settings" => settings,
                               "layer" => context["layer"], "facts" => mv_facts(context), "templates" => templates, "cleanup_confirmed" => journal["cleanup_confirmed"])
        bytes = mv_write!(mv_path(id, "json"), receipt)
        receipt["binding"] = mv_binding(receipt, bytes) if receipt["status"] == "passed" && receipt["cleanup_confirmed"]
        receipt
      end

      def mv_bootstrap_diagnostic(stderr)
        # Only called after nonce-proven nonzero child termination. Read exactly
        # the safe shipped diagnostic prefix; never relay an arbitrary stderr line.
        bytes = stderr.b
        bounded = bytes.byteslice(0, 64 * 1024)
        component = bounded.match?(/\bSTANDARD_MERGE_VALIDATION_CONFIG\b/n) ? "validation_config" : "unknown"
        fallback = { "version" => 1, "stage" => component == "validation_config" ? "bootstrap" : "unknown", "error_class" => "other", "component" => component, "line" => nil }
        return fallback if bytes.bytesize > 64 * 1024
        prefix = SiloMergeValidationDiagnostic::PREFIX
        rows = bounded.lines.select { |line| line.start_with?(prefix) }
        return fallback unless rows.size == 1 && rows.first.bytesize <= prefix.bytesize + 1024 + 1
        value = SiloMergeContract.parse(rows.first.delete_prefix(prefix).strip, max_bytes: 1024)
        SiloMergeValidationDiagnostic.validate!(value)
        value.dup
      rescue SiloMergeContract::Error, SiloMergeValidationDiagnostic::Error, EncodingError
        fallback
      end

      def mv_guest_diagnostic!(value)
        SiloMergeValidationDiagnostic.validate!(value)
        value.dup
      rescue SiloMergeValidationDiagnostic::Error
        mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL")
      end

      def mv_binding(receipt, bytes)
        { "version" => 1, "receipt_id" => receipt.fetch("receipt_id"), "receipt_sha256" => Digest::SHA256.hexdigest(bytes),
          "engine" => "discourse-merger-v1", "contract_sha256" => receipt.fetch("facts").fetch("contract_sha256"),
          "physical_policy" => receipt.fetch("facts").fetch("physical_policy"), "settings_sha256" => receipt.fetch("facts").fetch("settings_sha256"), "selection_sha256" => receipt.fetch("selection_sha256"), "asset_preflight_sha256" => receipt.fetch("asset_preflight_sha256"), "owner_preflight_sha256" => receipt.fetch("owner_preflight_sha256") }
      end

      def mv_result!(result, context, requested_checks)
        if result.is_a?(String)
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless result.bytesize <= 4 * 1024 * 1024 && result.start_with?(VALIDATION_PREFIX) && result.lines.size == 1
          result = SiloMergeContract.parse(result.delete_prefix(VALIDATION_PREFIX).strip, max_bytes: 4 * 1024 * 1024)
        end
        valid_keys = result.is_a?(Hash) && (result.keys - %w[failure guest_diagnostic]).sort == VALIDATION_RESULT_KEYS.sort
        unless valid_keys && result["version"] == 1 && %w[passed refused].include?(result["status"]) && result["key_path"].is_a?(Array)
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL")
        end
        # Duplicate-key detection belongs to parsing, not later host updates.
        # The real wire parser returns UniqueObject; normalize its outer Hash
        # before replacing optional refusal evidence (without relaxing ingestion).
        result = result.to_h
        mv_guest_diagnostic!(result.fetch("guest_diagnostic")) if result.key?("guest_diagnostic")
        begin
          SiloMergeValidation::Finding.new(result["key_path"], "schema_unsupported")
        rescue ArgumentError
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL")
        end
        answers = result["checks"]
        unless answers.is_a?(Array) && answers.size == requested_checks.size && answers.all? { |answer| answer.is_a?(Hash) && answer.keys.sort == %w[count status] &&
          { "found" => 1, "absent" => 0, "ambiguous" => 2, "unproven" => nil }.key?(answer["status"]) && answer["count"] == { "found" => 1, "absent" => 0, "ambiguous" => 2, "unproven" => nil }[answer["status"]] }
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL")
        end
        ids = result["approved_ids"]
        unless ids.is_a?(Array) && ids.size <= 100_000 && ids.all? { |id| id.is_a?(Integer) && id.positive? } && ids.uniq == ids && Digest::SHA256.hexdigest(JSON.generate(ids.sort)) == result["selected_ids_sha256"]
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL")
        end
        if result["status"] == "passed"
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") if result.key?("failure")
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless result["reason"] == "ok" && result["key_path"] == [] && VALIDATION_SHA.match?(result["asset_preflight_sha256"].to_s) && VALIDATION_SHA.match?(result["selection_sha256"].to_s) && VALIDATION_SHA.match?(result["owner_preflight_sha256"].to_s)
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") if answers.any? { |answer| answer["status"] == "unproven" }
          SiloMergeContract.audit!(context.fetch("contract"), "preflight", result["audit"])
        else
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless (%w[preflight_refused hooks_missing asset_selection_invalid audit_invalid checks_invalid assets_unproven validation_unproven] + SiloMergeValidation::FINDING_CODES).include?(result["reason"])
          if result.key?("failure")
            result = mv_failure_evidence(result.dup, context.fetch("contract"))
          else
            # Older guests have no failure envelope. Retain only declared
            # numeric counters; never relay arbitrary legacy audit payloads.
            begin
              keys = SiloMergeRefusal.declarations!(context.fetch("contract")).fetch("preflight")
              result = result.merge("audit" => SiloMergeRefusal.counts!(keys, result["audit"]))
            rescue StandardError
              result = result.merge("audit" => {})
            end
          end
        end
        result
      end

      # Failure counters are optional diagnostics, not permission to pass. Bad
      # diagnostics must neither leak undeclared values nor replace a valid
      # primary refusal with an unrelated protocol/recovery failure.
      def mv_failure_evidence(result, contract)
        begin
          failure = SiloMergeRefusal.validate!(contract, result.fetch("failure"), context: "validation")
          unless failure.fetch("reason") == result.fetch("reason") && failure.fetch("counts") == result.fetch("audit")
            raise ArgumentError, "refusal_evidence_invalid", cause: nil
          end
        rescue StandardError
          failure = SiloMergeRefusal.capture(contract: contract, merger: nil, phase: "preflight",
            context: "validation", reason: result.fetch("reason")).merge("audit_status" => "invalid")
        end
        result["failure"], result["audit"] = failure, failure.fetch("counts")
        result
      rescue StandardError
        result.delete("failure")
        result["audit"] = {}
        result
      end

      # SQL always arrives on stdin. Do NOT use the older merge_environment_sql:
      # it uses -c and logs its result (both unsafe for generated credentials).
      # All values here come from fixed host steps, never SQL, stderr or error text.
      def mv_step!(context, step)
        step = VALIDATION_STEPS.include?(step) ? step : "unknown"
        journal = context["lifecycle_journal"]
        if journal && !context["read_only_lifecycle"]
          now = mv_clock
          previous = journal.delete("active_stage")
          events = journal["events"] ||= []
          if previous
            events << { "step" => previous.fetch("step"), "phase" => "finish",
              "elapsed_ms" => [[((now - previous.fetch("started")) * 1000).round, 0].max, 86_400_000].min,
              "outcome" => "boundary" }
          end
          events << { "step" => step, "phase" => "start", "elapsed_ms" => 0 }
          journal["events"] = events.last(128)
          journal["active_stage"] = { "step" => step, "started" => now }
          journal["last_stage"] = step
          mv_save_journal!(journal)
        end
        context["validation_step"] = step
        context.delete("sql_outcome")
        context.delete("sql_timeout_seconds")
      end

      def mv_work_budget
        case ENV.fetch(VALIDATION_MODE_ENV, "chat")
        when "chat" then VALIDATION_BUDGET
        when "operator" then OPERATOR_VALIDATION_BUDGET
        else mv_error!("STANDARD_MERGE_VALIDATION_MODE_INVALID")
        end
      end

      def mv_failure_diagnostic(context, error)
        mv_finish_stage!(context, context.dig("lifecycle_journal", "producer_outcome") == "unknown" ? "unknown" : "failed")
        step = context["validation_step"]
        journal = context["lifecycle_journal"]
        step = journal["last_stage"] if step == "guest_validation" && journal.is_a?(Hash) && VALIDATION_EXECUTOR_STEPS.include?(journal["last_stage"])
        reason = error.code if error.is_a?(StandardWorkflowError)
        record = { "step" => VALIDATION_STEPS.include?(step) ? step : "unknown",
          "error_class" => SiloMergeValidationDiagnostic.classify_error_class(error),
          "reason" => VALIDATION_FAILURE_REASONS.include?(reason) ? reason : "STANDARD_MERGE_VALIDATION_UNPROVEN",
          "deadline_reached" => context["deadline"].is_a?(Numeric) ? mv_clock >= context["deadline"] : nil }
        outcome, seconds = context.values_at("sql_outcome", "sql_timeout_seconds")
        journal = context["lifecycle_journal"]
        if %w[guest_validation guest_launch guest_result].include?(step) && journal.is_a?(Hash) && journal.key?("guest_command_outcome")
          outcome, seconds = journal.values_at("guest_command_outcome", "guest_timeout_seconds")
        end
        record["command_outcome"] = outcome if %w[failed timeout_or_interrupted unknown].include?(outcome)
        record["command_timeout_seconds"] = seconds if seconds.is_a?(Integer) && seconds.between?(1, OPERATOR_VALIDATION_BUDGET)
        record
      rescue StandardError
        { "step" => "unknown", "reason" => "STANDARD_MERGE_VALIDATION_UNPROVEN", "deadline_reached" => nil }
      end

      def mv_sql!(context, sql, database: "postgres", max_seconds: 120, step: "sql")
        context = context.dup if context.frozen?
        mv_step!(context, step)
        stack = if context["runtime_profile"]
          with_review_runtime(context.fetch("runtime_profile")) { stack_for(context.fetch("prepared_from"), "review") }
        else
          stack_for(context.fetch("prepared_from"), "review")
        end
        journal = context["lifecycle_journal"]
        if journal
          mv_runtime_verify!(context, journal)
          context["producer_command"] = "sql"
        end
        seconds = mv_timeout(context, max_seconds)
        tracking = journal && !context["read_only_lifecycle"]
        sql_token = tracking ? mv_producer!(journal, "sql", "unknown") : SecureRandom.hex(16)
        context["sql_timeout_seconds"] = seconds
        context["sql_outcome"] = "unknown"
        command = ["docker", "exec", "-i"]
        if journal
          command += ["-e", "PGAPPNAME=silo_validation_#{journal.fetch('id')}", journal.fetch("runtime_binding").fetch("db_id"),
            "sh", "-c", 'psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "$1" -At; rc=$?; printf "\\nSILO_VALIDATION_SQL_DONE:%s:%s\\n" "$2" "$rc"; exit "$rc"',
            "silo-validation-sql", database, sql_token]
        else
          command += [stack.container("db"), "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", database, "-At"]
        end
        if context["reconciliation_read_only"]
          sql = "BEGIN READ ONLY;\nSET LOCAL statement_timeout = '5s';\nSET LOCAL lock_timeout = '1s';\n#{sql}\nCOMMIT;\n"
        end
        result = @runtime.run(command, stdin_data: sql, capture: true, timeout: seconds)
        output = result.stdout.to_s
        terminal = !journal
        if journal
          suffix = /\nSILO_VALIDATION_SQL_DONE:#{sql_token}:([0-9]{1,3})\n\z/.match(output)
          terminal = suffix && result.status.is_a?(Integer) && result.status == suffix[1].to_i && result.status.between?(0, 255)
          output = output[0...suffix.begin(0)] if terminal
          mv_producer!(journal, "sql", terminal ? "completed" : "unknown", token: sql_token) if tracking
        end
        mv_finish_stage!(context, terminal ? (result.success? ? "completed" : "failed") : "unknown")
        unless terminal
          context["sql_outcome"] = "timeout_or_interrupted"
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN")
        end
        unless result.success?
          context["sql_outcome"] = result.respond_to?(:status) && result.status.is_a?(Integer) ? "failed" : "timeout_or_interrupted"
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN")
        end
        context.delete("sql_outcome")
        output
      end

      # pg_database_size is a capacity observation, not a custody identity.
      # PostgreSQL autovacuum can visit closed databases and change physical
      # storage without changing their logical rows. Retain both observations
      # verbatim; never rebind an approved receipt or allow a numeric tolerance.
      # The caller still obtains current state through mv_custody!, which proves
      # the exact names, closed connections and zero sessions on every sample.
      def mv_same_template_custody?(current, recorded)
        names = %w[merge_source silo_clean_base]
        valid = [current, recorded].all? do |snapshot|
          snapshot.is_a?(Hash) && snapshot.keys.sort == names && snapshot.values.all? do |row|
            row.is_a?(Hash) && row.keys.sort == %w[bytes oid owner] &&
              %w[oid owner].all? { |key| row[key].is_a?(Integer) && row[key].positive? } &&
              row["bytes"].is_a?(Integer) && row["bytes"] >= 0
          end
        end
        valid && names.all? { |name| current[name].values_at("oid", "owner") == recorded[name].values_at("oid", "owner") }
      end

      def mv_custody!(context)
        names = %w[merge_source silo_clean_base]
        sql = "SELECT datname, oid, datdba, datallowconn, (SELECT count(*) FROM pg_stat_activity a WHERE a.datid=d.oid), pg_database_size(oid) FROM pg_database d WHERE datname IN ('merge_source','silo_clean_base') ORDER BY datname;"
        rows = mv_sql!(context, sql, step: "template_custody").lines.map { |line| line.strip.split("|", -1) }
        unless rows.size == 2 && rows.map(&:first).sort == names.sort && rows.all? { |row| row.size == 6 && row[1].match?(/\A[1-9][0-9]*\z/) && row[2].match?(/\A[1-9][0-9]*\z/) && row[3] == "f" && row[4] == "0" && row[5].match?(/\A[0-9]+\z/) }
          mv_error!("STANDARD_MERGE_TEMPLATE_CUSTODY")
        end
        rows.to_h { |name, oid, owner, _, _, bytes| [name, { "oid" => oid.to_i, "owner" => owner.to_i, "bytes" => bytes.to_i }] }
      end

      # Never interpolate persisted recovery data into SQL/argv until every
      # resource name is proved to be derived from this exact generated ID.
      def mv_journal!(journal)
        valid = journal.is_a?(Hash) && journal["id"].is_a?(String) && journal["id"].valid_encoding? && journal["id"].bytesize == 32 && VALIDATION_ID.match?(journal["id"])
        mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") unless valid
        id = journal.fetch("id")
        { "source" => "silo_val_s_#{id}", "base" => "silo_val_b_#{id}", "role" => "silo_val_r_#{id}",
          "guest_directory" => "/shared/silo-validation-#{id}", "redis" => "silo-val-redis-#{id}" }.each do |key, expected|
          required = %w[source base role].include?(key)
          mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") if (required || journal.key?(key)) && journal[key] != expected
        end
        if journal.key?("redis_id")
          unless journal.key?("redis") && journal["redis_id"].is_a?(String) && journal["redis_id"].valid_encoding? && journal["redis_id"].bytesize == 64 && VALIDATION_SHA.match?(journal["redis_id"])
            mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED")
          end
        end
        journal
      end

      def mv_provision!(context, journal, password)
        mv_journal!(journal)
        mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") unless password.is_a?(String) && password.valid_encoding? && password.bytesize == 64 && VALIDATION_SHA.match?(password)
        mv_lifecycle_start!(context, journal)
        role = journal.fetch("role")
        absent = mv_sql!(context, "SELECT count(*) FROM pg_database WHERE datname IN ('#{journal.fetch('source')}','#{journal.fetch('base')}');\nSELECT count(*) FROM pg_roles WHERE rolname='#{role}';\n", step: "resources_absent")
        mv_recovery_refuse! unless absent.lines.map(&:strip) == %w[0 0]
        %w[source base role].each { |key| journal.fetch("resources")[key] = { "outcome" => "absent" } }
        mv_save_journal!(journal)
        mv_create_resource!(context, journal, "role") do
          mv_sql!(context, "CREATE ROLE #{role} LOGIN PASSWORD '#{password}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;\n", step: "create_role")
        end
        { "source" => "merge_source", "base" => "silo_clean_base" }.each do |side, template|
          name = journal.fetch(side)
          mv_create_resource!(context, journal, side) do
            # Isolate CREATE from restrictions: identity is fsynced before any
            # subsequent statement can fail. Lost CREATE responses stay unknown.
            mv_sql!(context, "CREATE DATABASE #{name} TEMPLATE #{template} OWNER postgres ALLOW_CONNECTIONS false;\n", max_seconds: mv_work_budget, step: "clone_#{side}")
          end
          mv_sql!(context, "REVOKE ALL ON DATABASE #{name} FROM PUBLIC;\nGRANT CONNECT ON DATABASE #{name} TO #{role};\nREVOKE CREATE, TEMPORARY ON DATABASE #{name} FROM #{role};\nALTER ROLE #{role} IN DATABASE #{name} SET default_transaction_read_only = on;\nALTER DATABASE #{name} ALLOW_CONNECTIONS true;\n", step: "restrict_#{side}")
          mv_sql!(context, <<~SQL, database: name, step: "restrict_#{side}")
            DO $silo_validation$
            DECLARE application_schema text;
            BEGIN
              FOR application_schema IN
                SELECT nspname FROM pg_namespace
                WHERE nspname <> 'information_schema' AND nspname !~ '^pg_'
              LOOP
                EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', application_schema);
                EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM PUBLIC', application_schema);
                EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM PUBLIC', application_schema);
                EXECUTE format('REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA %I FROM PUBLIC', application_schema);
              END LOOP;
            END;
            $silo_validation$;
            GRANT USAGE ON SCHEMA public TO #{role};
            GRANT SELECT ON ALL TABLES IN SCHEMA public TO #{role};
          SQL
        end
        mv_error!("STANDARD_MERGE_TEMPLATE_CUSTODY") unless mv_same_template_custody?(mv_custody!(context), journal.fetch("templates"))
        journal["owned_identities"] = mv_owned_identities!(context, journal)
        journal["provision_complete"] = true
        mv_save_journal!(journal)
      end

      def mv_owned_identities!(context, journal)
        mv_journal!(journal)
        rows = %w[source base role].flat_map { |key| mv_resource_identity!(context, journal, key) || [] }
        mv_recovery_refuse! unless rows.size == 3
        rows.sort_by(&:first)
      end

      def mv_cleanup!(context, journal)
        mv_lifecycle_cleanup!(context, journal, recovery: false)
      end

      def mv_path(id, suffix)
        File.join(@store.root, "validations", "#{id}.#{suffix}")
      end

      def mv_no_resources!
        Dir.glob(File.join(@store.root, "validations", "*.resources.json")).each do |path|
          record = JSON.parse(mv_read!(path, 64 * 1024))
          mv_journal!(record)
          mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") unless File.basename(path) == "#{record.fetch('id')}.resources.json"
          mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") unless record["status"] == "cleaned" && record["cleanup_confirmed"] == true
        end
      rescue JSON::ParserError, SystemCallError
        mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED")
      end

      def mv_read!(path, limit)
        mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") if File.symlink?(path)
        File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          stat = file.stat
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= limit
          bytes = file.read(limit + 1)
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") if bytes.bytesize > limit
          bytes
        end
      end

      def mv_write!(path, value)
        bytes = JSON.generate(value) + "\n"
        directory = File.dirname(path)
        mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") if File.symlink?(directory)
        FileUtils.mkdir_p(directory, mode: 0o700)
        stat = File.stat(directory)
        mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless stat.uid == Process.uid && (stat.mode & 0o077).zero?
        temporary = "#{path}.#{SecureRandom.hex(8)}.tmp"
        begin
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes); file.flush; file.fsync }
          File.rename(temporary, path)
          File.open(directory, File::RDONLY) { |file| file.fsync }
        ensure
          File.unlink(temporary) if File.exist?(temporary)
        end
        bytes
      end
    end
  end
end
