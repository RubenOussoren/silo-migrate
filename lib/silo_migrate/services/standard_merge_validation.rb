# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "yaml"
require_relative "../../../runtime/shared/merge_contract"
require_relative "../../../runtime/shared/merge_refusal"
require_relative "../merge_process"

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
      VALIDATION_RESULT_KEYS = %w[version status reason key_path approved_ids selected_ids_sha256 audit checks asset_preflight_sha256 selection_sha256 owner_preflight_sha256].freeze
      VALIDATION_ID = /\A[0-9a-f]{32}\z/
      VALIDATION_SHA = /\A[0-9a-f]{64}\z/
      VALIDATION_STEPS = %w[sql resources_absent create_role clone_source restrict_source clone_base restrict_base template_custody resource_identity guest_validation result_verification cleanup_resources cleanup_source cleanup_base cleanup_role cleanup_absence].freeze
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
            uncertain = false
            result = nil
            diagnostics = {}
            begin
              password = SecureRandom.hex(32)
              mv_provision!(context, journal, password)
              mv_step!(context, "guest_validation")
              result = merge_validation_execute!(context.merge("password" => password), journal)
              mv_step!(context, "result_verification")
              # Checks-only uses the same complete private envelope, without
              # claiming a semantic merge validation or issuing a Start binding.
              allowed = result.is_a?(Hash) && result.keys.sort == VALIDATION_RESULT_KEYS.sort && result["version"] == 1 && result["approved_ids"] == [] && result["audit"] == {} &&
                result["checks"].is_a?(Array) && result["checks"].size == queries.size && result["key_path"] == [] &&
                %w[passed refused].include?(result["status"]) && %w[ok checks_invalid].include?(result["reason"]) && result["selection_sha256"].nil? && result["asset_preflight_sha256"].nil? && result["owner_preflight_sha256"].nil? && result["selected_ids_sha256"] == Digest::SHA256.hexdigest("[]")
              mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless allowed
              proven = result["checks"].none? { |answer| answer["status"] == "unproven" }
              mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless result["status"] == (proven ? "passed" : "refused") && result["reason"] == (proven ? "ok" : "checks_invalid")
              result["checks"].each do |answer|
                counts = { "found" => 1, "absent" => 0, "ambiguous" => 2, "unproven" => nil }
                mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless answer.is_a?(Hash) && answer.keys.sort == %w[count status] && counts.key?(answer["status"]) && answer["count"] == counts[answer["status"]]
              end
            rescue StandardError => error
              diagnostics["work"] = mv_failure_diagnostic(context, error)
              uncertain = true
              result = { "version" => 1, "status" => "refused", "reason" => "STANDARD_MERGE_VALIDATION_UNPROVEN", "key_path" => [] }
            ensure
              begin
                cleanup_context = context.merge("deadline" => mv_clock + VALIDATION_CLEANUP_BUDGET)
                mv_cleanup!(cleanup_context, journal)
                mv_error!("STANDARD_MERGE_TEMPLATE_CUSTODY") unless mv_same_template_custody?(mv_custody!(cleanup_context), templates)
                mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") if uncertain
                journal.merge!("status" => "cleaned", "cleanup_confirmed" => true)
                mv_write!(mv_path(id, "resources.json"), journal)
              rescue StandardError => error
                diagnostics["cleanup"] = mv_failure_diagnostic(cleanup_context, error)
                result = { "version" => 1, "status" => "refused", "reason" => "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", "key_path" => [] }
              end
            end
            result["diagnostics"] = diagnostics unless diagnostics.empty?
            result = result.merge("receipt_id" => id, "cleanup_confirmed" => journal["cleanup_confirmed"])
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
        mv_error!("STANDARD_MERGE_VALIDATION_FAILED") unless result["status"] == "passed"
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
        mv_journal!(journal)
        with_review_runtime(context.fetch("runtime_profile")) do
          stack = stack_for(context.fetch("prepared_from"), "review")
          host_dir = File.join(@store.root, "validations", journal.fetch("id"))
          Dir.mkdir(host_dir, 0o700)
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
          image = context.fetch("runtime_profile").fetch("images").fetch("redis").fetch("id")
          created = @runtime.run(["docker", "create", "--pull=never", "--restart=no", "--name", journal.fetch("redis"), "--label", "silo-migrate.managed=true", "--label", "silo-migrate.validation=#{journal.fetch('id')}",
                                  "--network", network, "--memory", "128m", "--memory-swap", "128m", "--pids-limit", "64", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--cpus", "0.5", "--read-only", "--tmpfs", "/data:rw,noexec,nosuid,size=16m", image,
                                  "redis-server", "--save", "", "--appendonly", "no"], capture: true, timeout: mv_timeout(context, 60))
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless created.success? && created.stdout.to_s.strip.match?(/\A[0-9a-f]{64}\z/)
          journal["redis_id"] = created.stdout.strip
          mv_write!(mv_path(journal.fetch("id"), "resources.json"), journal)
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
          %w[merge_contract.rb merge_assets.rb merge_refusal.rb].each do |name|
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
          stack.copy_in(host_dir, guest, owner: "discourse:discourse", timeout: [mv_timeout(context, 60) / 2, 1].max)
          mv_web!(stack, ["sh", "-c", "find #{guest} -type f -exec chmod 400 {} + && find #{guest} -type d -exec chmod 700 {} +"], context: context)
          ruby_options = context["mode"] == "checks" ? [] : ["RUBYOPT=-r#{guest}/merge_validation_config.rb"]
          result = stack.discourse_shell(["env", *ruby_options, "SILO_MERGE_VALIDATION_CONTEXT=#{guest}/work/context.json",
                                          "SILO_MERGE_SETTINGS=#{guest}/work/settings.yml", "SILO_MERGE_VALIDATION_RESULT=#{guest}/work/result.json",
                                          "bundle", "exec", "ruby", "#{guest}/merge_validate.rb"], env_password: false, timeout: mv_timeout(context, 150))
          # A timeout may leave docker exec running. Never remove its evidence or
          # certify cleanup based on a merely empty catalogue at this instant.
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless [0, 4].include?(result.status)
          line = result.stdout.to_s
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless line.bytesize <= 2048 && line.lines.size == 1 && line.start_with?(VALIDATION_PREFIX)
          projection = SiloMergeContract.parse(line.delete_prefix(VALIDATION_PREFIX).strip, max_bytes: 2048)
          # Bound guest result BEFORE docker cp, not after a potentially huge copy.
          size = stack.web_exec(["stat", "-c", "%s", "#{guest}/work/result.json"], timeout: mv_timeout(context, 30))
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless size.success? && size.stdout.to_s.strip.match?(/\A[0-9]+\z/) && size.stdout.to_i <= 4 * 1024 * 1024
          private_result = File.join(host_dir, "result.json")
          stack.copy_out("#{guest}/work/result.json", private_result, timeout: mv_timeout(context, 30))
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") if File.symlink?(private_result) || !File.file?(private_result)
          File.chmod(0o600, private_result)
          record = SiloMergeContract.parse(mv_read!(private_result, 4 * 1024 * 1024), max_bytes: 4 * 1024 * 1024)
          expected = record.slice("version", "status", "reason", "selected_ids_sha256", "asset_preflight_sha256", "selection_sha256").merge("key_path" => [])
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL") unless projection == expected
          # Known exited child: remove private credentials synchronously. Anything
          # failing here leaves an owned journal and blocks subsequent activation.
          mv_web!(stack, ["rm", "-rf", "--", guest], context: context)
          journal["guest_cleaned"] = true
          mv_write!(mv_path(journal.fetch("id"), "resources.json"), journal)
          record
        end
      ensure
        # Private host credentials are never receipt material. Unknown guest exec
        # retains its guest copy under the owned journal for scoped recovery.
        FileUtils.remove_entry(host_dir) if host_dir && File.directory?(host_dir)
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
        result = @runtime.run(argv, capture: true, timeout: mv_timeout(context, 60))
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
          "validation_code_sha256" => Digest::SHA256.hexdigest([__FILE__, "../../../runtime/prebuilt-discourse/merge_validate.rb", "../../../runtime/prebuilt-discourse/merge_validation_config.rb", "../../../runtime/prebuilt-discourse/merge_adapter.rb", "../../../runtime/prebuilt-discourse/merge_asset_references.rb", "../../../runtime/prebuilt-discourse/merge_baseline_assets.rb", "../../../runtime/shared/merge_assets.rb", "../../../runtime/shared/merge_contract.rb", "../../../runtime/shared/merge_refusal.rb"].map { |file| File.binread(file == __FILE__ ? file : File.expand_path(file, __dir__)) }.join))
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
        uncertain = false
        diagnostics = {}
        begin
          password = SecureRandom.hex(32)
          mv_provision!(context, journal, password)
          mv_step!(context, "guest_validation")
          result = merge_validation_execute!(context.merge("password" => password, "checks" => checks), journal)
          mv_step!(context, "result_verification")
          result = mv_result!(result, context, checks)
        rescue StandardError => error
          diagnostics["work"] = mv_failure_diagnostic(context, error)
          uncertain = true
          result = { "version" => 1, "status" => "refused", "reason" => "STANDARD_MERGE_VALIDATION_UNPROVEN", "key_path" => [] }
        ensure
          # Cleanup failure/timeout is never swallowed into a passing receipt.
          begin
            cleanup_context = context.merge("deadline" => mv_clock + VALIDATION_CLEANUP_BUDGET)
            mv_cleanup!(cleanup_context, journal)
            unchanged = mv_same_template_custody?(mv_custody!(cleanup_context), templates)
            mv_error!("STANDARD_MERGE_TEMPLATE_CUSTODY") unless unchanged
            mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") if uncertain
            journal["status"] = "cleaned"
            journal["cleanup_confirmed"] = true
            mv_write!(mv_path(id, "resources.json"), journal)
          rescue StandardError => error
            diagnostics["cleanup"] = mv_failure_diagnostic(cleanup_context, error)
            result = { "version" => 1, "status" => "refused", "reason" => "STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED", "key_path" => [] }
          end
        end
        result["diagnostics"] = diagnostics unless diagnostics.empty?
        receipt = result.merge("receipt_id" => id, "prepared_from" => prepared_from, "generation" => generation, "settings" => settings,
                               "layer" => context["layer"], "facts" => mv_facts(context), "templates" => templates, "cleanup_confirmed" => journal["cleanup_confirmed"])
        bytes = mv_write!(mv_path(id, "json"), receipt)
        receipt["binding"] = mv_binding(receipt, bytes) if receipt["status"] == "passed" && receipt["cleanup_confirmed"]
        receipt
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
        valid_keys = result.is_a?(Hash) && [VALIDATION_RESULT_KEYS.sort, (VALIDATION_RESULT_KEYS + ["failure"]).sort].include?(result.keys.sort)
        unless valid_keys && result["version"] == 1 && %w[passed refused].include?(result["status"]) && result["key_path"].is_a?(Array)
          mv_error!("STANDARD_MERGE_VALIDATION_PROTOCOL")
        end
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
        step = context["validation_step"]
        reason = error.code if error.is_a?(StandardWorkflowError)
        record = { "step" => VALIDATION_STEPS.include?(step) ? step : "unknown",
          "reason" => VALIDATION_FAILURE_REASONS.include?(reason) ? reason : "STANDARD_MERGE_VALIDATION_UNPROVEN",
          "deadline_reached" => context["deadline"].is_a?(Numeric) ? mv_clock >= context["deadline"] : nil }
        outcome, seconds = context.values_at("sql_outcome", "sql_timeout_seconds")
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
        seconds = mv_timeout(context, max_seconds)
        context["sql_timeout_seconds"] = seconds
        context["sql_outcome"] = "unknown"
        result = @runtime.run(["docker", "exec", "-i", stack.container("db"), "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", database, "-At"],
                              stdin_data: sql, capture: true, timeout: seconds)
        unless result.success?
          context["sql_outcome"] = result.respond_to?(:status) && result.status.is_a?(Integer) ? "failed" : "timeout_or_interrupted"
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN")
        end
        context.delete("sql_outcome")
        result.stdout.to_s
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
        role = journal.fetch("role")
        absent = mv_sql!(context, "SELECT count(*) FROM pg_database WHERE datname IN ('#{journal.fetch('source')}','#{journal.fetch('base')}');\nSELECT count(*) FROM pg_roles WHERE rolname='#{role}';\n", step: "resources_absent")
        mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless absent.lines.map(&:strip) == %w[0 0]
        mv_sql!(context, "CREATE ROLE #{role} LOGIN PASSWORD '#{password}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;\n", step: "create_role")
        { "source" => "merge_source", "base" => "silo_clean_base" }.each do |side, template|
          name = journal.fetch(side)
          mv_sql!(context, "CREATE DATABASE #{name} TEMPLATE #{template} OWNER postgres;\nREVOKE ALL ON DATABASE #{name} FROM PUBLIC;\nGRANT CONNECT ON DATABASE #{name} TO #{role};\nREVOKE CREATE, TEMPORARY ON DATABASE #{name} FROM #{role};\nALTER ROLE #{role} IN DATABASE #{name} SET default_transaction_read_only = on;\n", max_seconds: mv_work_budget, step: "clone_#{side}")
          # No owner/default/analyst grants: only the random role sees either clone.
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
        mv_write!(mv_path(journal.fetch("id"), "resources.json"), journal)
      end

      def mv_owned_identities!(context, journal)
        mv_journal!(journal)
        sql = "/* silo_validation_owned */ SELECT datname, oid, pg_get_userbyid(datdba) FROM pg_database WHERE datname IN ('#{journal.fetch('source')}','#{journal.fetch('base')}') ORDER BY datname;\nSELECT rolname, oid, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolbypassrls, rolreplication, rolcanlogin FROM pg_roles WHERE rolname='#{journal.fetch('role')}';\n"
        rows = mv_sql!(context, sql, step: "resource_identity").lines.map { |line| line.strip.split("|", -1) }
        unless rows.size == 3 && rows.first(2).map(&:first).sort == [journal.fetch("source"), journal.fetch("base")].sort &&
            rows.first(2).all? { |row| row.size == 3 && row[1].match?(/\A[1-9][0-9]*\z/) && row[2] == "postgres" } &&
            rows.last.size == 9 && rows.last[0] == journal.fetch("role") && rows.last[1].match?(/\A[1-9][0-9]*\z/) && rows.last[2..] == %w[f f f f f f t]
          mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED")
        end
        rows
      end

      def mv_cleanup!(context, journal)
        context = context.dup if context.frozen?
        mv_step!(context, "cleanup_resources")
        mv_journal!(journal)
        # No name-only destructive cleanup after a partial/unknown CREATE. Such
        # resources require explicit scoped recovery, not an automatic guess.
        unless journal["provision_complete"] == true && mv_owned_identities!(context, journal) == journal.fetch("owned_identities")
          mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED")
        end
        mv_step!(context, "cleanup_resources")
        if journal["redis"]
          inspected = @runtime.run(["docker", "inspect", "--format", '{{.Id}}|{{index .Config.Labels "silo-migrate.validation"}}|{{index .Config.Labels "silo-migrate.managed"}}', journal.fetch("redis")], capture: true, timeout: mv_timeout(context, 30))
          mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") unless inspected.success? && inspected.stdout.to_s.strip.match?(/\A[0-9a-f]{64}\|#{journal.fetch('id')}\|true\z/)
          inspected_id = inspected.stdout.strip.split("|").first
          mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") if journal["redis_id"] && journal["redis_id"] != inspected_id
          mv_command!(["docker", "rm", "-f", inspected_id], context: context)
          absent = @runtime.run(["docker", "container", "ls", "-aq", "--filter", "name=^/#{journal.fetch('redis')}$"], capture: true, timeout: mv_timeout(context, 30))
          mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") unless absent.success? && absent.stdout.to_s.strip.empty?
        end
        if journal["guest_directory"] && journal["guest_cleaned"] != true
          mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED")
        end
        %w[source base].each do |side|
          name = journal.fetch(side)
          # Only generated owned clones, never original templates or inspection DBs.
          mv_sql!(context, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='#{name}' AND pid <> pg_backend_pid();\nDROP DATABASE IF EXISTS #{name};\n", step: "cleanup_#{side}")
        end
        mv_sql!(context, "DROP ROLE IF EXISTS #{journal.fetch('role')};\n", step: "cleanup_role")
        remaining = mv_sql!(context, "SELECT count(*) FROM pg_database WHERE datname IN ('#{journal.fetch('source')}','#{journal.fetch('base')}');\nSELECT count(*) FROM pg_roles WHERE rolname='#{journal.fetch('role')}';\n", step: "cleanup_absence")
        mv_error!("STANDARD_MERGE_VALIDATION_RECOVERY_REQUIRED") unless remaining.lines.map(&:strip) == %w[0 0]
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
        File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          stat = file.stat
          mv_error!("STANDARD_MERGE_VALIDATION_UNPROVEN") unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= limit
          file.read(limit + 1)
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
