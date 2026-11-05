# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "shellwords"
require "socket"
require "time"
require "uri"
require "yaml"
begin
  require "sqlite3"
rescue LoadError
  # Reported when an operation that needs it runs.
end
require_relative "../standard_store"
require_relative "prebuilt_stack"
require_relative "standard_oracle"
require_relative "discourse_archive"

module SiloMigrate
  module Services
    # Deterministic standard local migration: named dataset -> converter -> sandbox
    # baseline -> uploads + generic import -> validated DB+uploads backup -> proven
    # fresh local restore. Hosted restore and cutover are engineer handoffs.
    #
    # This is the first verified recipe, not a universal pipeline: see CAPABILITIES.
    # One approved plan runs at most once. A failure leaves durable state, evidence
    # and a fixed recovery instruction; nothing retries or repairs itself.
    class StandardWorkflowService
      include DiscourseArchive

      STAGES = %w[preflight convert site_up baseline uploads import verify_site final_backup review_url restore verify_restore].freeze

      CAPABILITIES = {
        "standard_full_snapshot" => "supported_synthetic",
        "launch_snapshot_from_preimport_baseline" => "supported_synthetic",
        "other_existing_converters" => "not_implemented_in_workbench",
        "new_converter_development" => "not_implemented_in_workbench",
        "delta_import" => "not_implemented_requires_base_lineage",
        "multi_source_merge" => "not_implemented_requires_namespaces_and_order",
        "native_discourse_merge" => "not_implemented_separate_engine"
      }.freeze

      RECOVERY = {
        "STANDARD_INPUT_CHANGED" => "An input changed. Do not edit inputs: register a new dataset, then propose and approve a new plan.",
        "STANDARD_COLLISION" => "Source records collide with the baseline. Decide policy, change the fixture or baseline, then re-plan.",
        "STANDARD_RUNTIME_MISMATCH" => "Runtime identity differs from the frozen lock. Rebuild or update the lock deliberately; do not bypass the check.",
        "STANDARD_CONVERSION_FAILED" => "Conversion failed. Inspect private evidence, then re-plan; containers were removed.",
        "STANDARD_UPLOADS_FAILED" => "Upload processing failed; the instance is dirty. Run the reset for this run, investigate privately, then re-plan.",
        "STANDARD_IMPORT_FAILED" => "Import failed; the instance is dirty. Run the reset for this run, investigate privately, then re-plan.",
        "STANDARD_VERIFY_FAILED" => "Assertions failed. Keep the instance for private inspection, then reset and re-plan with a fixed revision.",
        "STANDARD_BACKUP_FAILED" => "Backup failed and its name is consumed. Reset, then re-plan with a new run.",
        "STANDARD_RESTORE_FAILED" => "Restore or restore validation failed. The source backup is retained; reset and re-plan after investigation.",
        "STANDARD_INTERRUPTED" => "The executing process ended. The instance state is unknown: reset this run, then re-plan.",
        "STANDARD_INTERNAL" => "An unexpected failure occurred. Inspect private evidence, reset this run, then re-plan."
      }.freeze

      SANDBOX_ATTACHMENT = "Synthetic sandbox attachment created before migration.\n".b.freeze

      attr_reader :store

      def initialize(workspace, runtime: Runtime::Docker.new, env: ENV, code_root: nil, sleeper: nil, http: nil, port_probe: nil, disk_free: nil)
        @workspace = workspace
        @runtime = runtime
        @env = env
        @store = StandardStore.new(workspace, env: env)
        @code_root = code_root || File.expand_path("../../..", __dir__)
        @sleeper = sleeper
        @http = http || method(:http_fetch)
        @port_probe = port_probe || method(:port_free?)
        @disk_free = disk_free || method(:host_disk_free_bytes)
      end

      # -- configuration ------------------------------------------------------

      def init(converter_worktree:, converter_revision:, site_settings:)
        unless converter_revision.is_a?(String) && converter_revision.match?(/\A[0-9a-f]{40}\z/)
          raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID"
        end
        [converter_worktree, site_settings].each do |path|
          raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless path.is_a?(String) && path.start_with?("/") && File.exist?(path)
        end
        @store.init!("converter_worktree" => converter_worktree, "converter_revision" => converter_revision,
                     "site_settings" => site_settings, "site_settings_sha256" => Digest::SHA256.file(site_settings).hexdigest)
        { version: 1, status: "initialized" }
      end

      def lock
        @lock ||= JSON.parse(File.read(File.join(@code_root, "runtime", "prebuilt-discourse", "runtime-lock.json")))
      end

      # Identity of the code that will execute. Any source edit invalidates approval.
      def code_identity
        files = Dir.glob(%w[lib/**/*.rb bin/silo-migrate runtime/prebuilt-discourse/*], base: @code_root).select { |rel| File.file?(File.join(@code_root, rel)) }.sort
        digest = Digest::SHA256.new
        files.each do |rel|
          digest.update(rel)
          digest.update("\0")
          digest.update(Digest::SHA256.file(File.join(@code_root, rel)).hexdigest)
          digest.update("\n")
        end
        digest.hexdigest
      end

      # -- planning -----------------------------------------------------------

      def propose_plan(dataset_id:, baseline: "seed", ports: nil)
        state = @store.load
        named = @store.named_state
        dataset = named.fetch("datasets")[dataset_id]
        raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless dataset

        inputs = dataset_inputs(named, dataset_id)
        require_input_types!(inputs)
        raise StandardWorkflowError, "STANDARD_INPUT_CHANGED" unless inputs_unchanged?(inputs)

        baseline_decision = baseline_decision(state, baseline)
        ports = select_ports(state, ports)
        plan_id = @store.new_id("plan")
        short = plan_id.delete_prefix("plan-")[0, 8]
        body = {
          "operation" => "standard_full_snapshot",
          "workspace_id" => named.fetch("workspace_id"),
          "dataset_id" => dataset_id,
          "input_binding" => inputs.map { |input| input.slice("id", "sha256", "bytes", "type") }.sort_by { |input| input["id"] },
          "input_stat_binding" => @store.named.input_binding(named, inputs.map { |input| input["id"] }.sort),
          "code_identity" => code_identity,
          "runtime_lock_sha256" => Digest::SHA256.hexdigest(JSON.generate(lock)),
          "image_ids" => lock.fetch("images").transform_values { |image| image.fetch("id") },
          "app_revision" => lock.dig("app", "revision"),
          "converter_revision" => state.dig("config", "converter_revision"),
          "site_settings_sha256" => state.dig("config", "site_settings_sha256"),
          "baseline" => baseline_decision,
          "collision_policy" => "refuse",
          "instances" => {
            "review" => { "name" => "silomig-#{short}-review", "hostname" => "127.0.0.1", "port" => ports.fetch(0) },
            "restore" => { "name" => "silomig-#{short}-restore", "hostname" => "localhost", "port" => ports.fetch(1) }
          },
          "outputs" => {
            "baseline" => baseline_decision["mode"] == "seed" ? "baseline-#{short}.tar.gz" : nil,
            "final" => "final-#{short}.tar.gz"
          },
          "mutations" => [
            "create the two listed disposable local instances and their owned networks/volumes",
            baseline_decision["mode"] == "seed" ? "seed a synthetic baseline in the review instance" : "restore the accepted baseline archive into the review instance",
            "run upload processing and standard generic import in the review instance",
            "restore the final backup into the restore instance"
          ],
          "not_included" => ["customer data", "hosted restore", "DNS or cutover", "remote pushes"]
        }
        digest = Digest::SHA256.hexdigest(canonical_json(body))
        @store.update do |current|
          current.fetch("plans")[plan_id] = {
            "id" => plan_id, "digest" => digest, "body" => body, "status" => "proposed", "created_at" => now, "approval" => nil, "run_id" => nil
          }
        end
        { version: 1, plan_id: plan_id, digest: digest, status: "proposed" }
      end

      def approve_plan(plan_id:, sha256:, reviewer:)
        @store.update do |state|
          plan = state.fetch("plans")[plan_id]
          raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless plan
          raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" unless plan["status"] == "proposed"
          raise StandardWorkflowError, "STANDARD_APPROVAL_MISMATCH" unless sha256 == plan["digest"]
          unless reviewer.is_a?(String) && reviewer.match?(/\A[[:print:]]{1,120}\z/)
            raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID"
          end

          stale = stale_reason(plan, state)
          raise StandardWorkflowError.new("STANDARD_STALE_PLAN", stale) if stale

          plan["status"] = "approved"
          plan["approval"] = { "digest" => sha256, "reviewer" => reviewer, "approved_at" => now }
          { version: 1, plan_id: plan_id, digest: sha256, status: "approved" }
        end
      end

      # Baseline only: an accepted pre-import archive is what a launch run restores.
      def accept_baseline(run_id:, reviewer:)
        @store.update do |state|
          run = state.fetch("runs")[run_id]
          raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless run
          artifact = run.dig("artifacts", "baseline")
          unless artifact && %w[completed].include?(run["status"])
            raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID"
          end

          baseline_id = "baseline-#{artifact.fetch('sha256')[0, 16]}"
          state.fetch("accepted_baselines")[baseline_id] = artifact.merge("id" => baseline_id, "run_id" => run_id, "reviewer" => reviewer, "accepted_at" => now, "fingerprint" => run.dig("artifacts", "baseline_fingerprint"))
          { version: 1, baseline_id: baseline_id, status: "accepted" }
        end
      end

      # -- execution ----------------------------------------------------------

      def run_plan(plan_id:)
        @store.with_op_lock do
          run_id = claim_plan!(plan_id)
          execute_stages(run_id)
          public_run(@store.load.fetch("runs").fetch(run_id), held: true)
        end
      end

      # Explicit: only an abandoned running run (executor lock free) is marked.
      def recover(run_id:)
        @store.with_op_lock do
          @store.update do |state|
            run = state.fetch("runs")[run_id]
            raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless run
            raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" unless run["status"] == "running"

            run["status"] = "interrupted"
            run["failure"] = { "stage" => run["stage"], "code" => "STANDARD_INTERRUPTED", "recovery" => RECOVERY.fetch("STANDARD_INTERRUPTED") }
            run["finished_at"] = now
            mark_instances_dirty(state, run)
            public_run(run, held: true)
          end
        end
      end

      # Removes only this run's owned instances, by exact recorded ID. Evidence,
      # plans and retained backups are preserved. Requires explicit engineer intent.
      def reset_run(run_id:, yes: false)
        raise StandardWorkflowError, "STANDARD_CONFIRMATION_REQUIRED" unless yes

        @store.with_op_lock do
          state = @store.load
          run = state.fetch("runs")[run_id]
          raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless run
          raise StandardWorkflowError, "STANDARD_TRANSITION_INVALID" if run["status"] == "running"

          removed = []
          run.fetch("instances", {}).each_value do |name|
            record = state.fetch("instances")[name]
            next unless record && record["state"] != "removed"

            stack = PrebuiltStack.new(runtime: @runtime, lock: lock, name: name, record: record)
            stack.remove!
            @store.update { |current| current.fetch("instances")[name] = stack.record }
            removed << name
          end
          { version: 1, run_id: run_id, status: "reset", removed: removed }
        end
      end

      # -- read-only views ----------------------------------------------------

      def status
        state = @store.load
        held = @store.op_lock_held?
        runs = state.fetch("runs").values.sort_by { |run| run["started_at"].to_s }
        {
          version: 1, workspace: @workspace, executor_active: held,
          plans: state.fetch("plans").values.sort_by { |plan| plan["created_at"].to_s }.map { |plan| public_plan(plan, state, summary: true) },
          runs: runs.map { |run| public_run(run, held: held) },
          instances: state.fetch("instances").values.map { |record| public_instance(record) },
          accepted_baselines: state.fetch("accepted_baselines").values.map { |base| base.slice("id", "sha256", "bytes", "filename", "run_id") },
          capabilities: CAPABILITIES
        }
      end

      def show_plan(plan_id)
        state = @store.load
        plan = state.fetch("plans")[plan_id]
        raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless plan

        public_plan(plan, state)
      end

      def show_run(run_id)
        run = @store.load.fetch("runs")[run_id]
        raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless run

        public_run(run, held: @store.op_lock_held?)
      end

      # Engineer-only private view: where the evidence is on disk, not its content.
      def private_paths(run_id)
        run = @store.load.fetch("runs")[run_id]
        raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless run

        { version: 1, run_id: run_id, directory: @store.run_dir(run_id), admin_password_file: @store.run_dir(run_id, "private", "admin-password") }
      end

      private

      def now
        Time.now.utc.iso8601
      end

      def canonical_json(value)
        canonical = lambda do |item|
          case item
          when Hash then item.keys.sort.to_h { |key| [key, canonical.call(item.fetch(key))] }
          when Array then item.map { |entry| canonical.call(entry) }
          else item
          end
        end
        JSON.generate(canonical.call(value))
      end

      def dataset_inputs(named, dataset_id)
        named.fetch("inputs").values.select { |input| input["dataset_id"] == dataset_id }.sort_by { |input| input["path"] }
      end

      # Stat identity against what was registered: size, inode, mtime and ctime. The
      # full content hash is checked again in the preflight stage.
      def inputs_unchanged?(inputs)
        @store.named.with_lock { |store| inputs.each { |input| store.verify_input_identity(input) } }
        true
      rescue NamedError
        false
      end

      def require_input_types!(inputs)
        types = inputs.map { |input| input["type"] }
        %w[source-sql converter-settings expected].each do |type|
          raise StandardWorkflowError.new("STANDARD_INPUTS_INCOMPLETE", type) unless types.count(type) == 1
        end
      end

      def baseline_decision(state, baseline)
        return { "mode" => "seed" } if baseline == "seed"

        accepted = state.fetch("accepted_baselines")[baseline]
        raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless accepted

        { "mode" => "restore", "baseline_id" => baseline, "sha256" => accepted.fetch("sha256") }
      end

      def select_ports(state, requested)
        low, high = lock.dig("limits", "ports")
        if requested
          raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless requested.is_a?(Array) && requested.length == 2 && requested.uniq.length == 2 && requested.all? { |port| port.is_a?(Integer) && port.between?(low, high) }
          raise StandardWorkflowError, "STANDARD_PORT_OCCUPIED" unless requested.all? { |port| @port_probe.call(port) }

          return requested
        end
        reserved = state.fetch("instances").values.reject { |record| record["state"] == "removed" }.map { |record| record["port"] }
        free = (low..high).select { |port| !reserved.include?(port) && @port_probe.call(port) }
        raise StandardWorkflowError, "STANDARD_PORT_OCCUPIED" if free.length < 2

        free.first(2)
      end

      def port_free?(port)
        socket = TCPServer.new("127.0.0.1", port)
        socket.close
        true
      rescue SystemCallError
        false
      end

      def stale_reason(plan, state)
        body = plan.fetch("body")
        named = @store.named_state
        ids = body.fetch("input_binding").map { |input| input["id"] }
        return "inputs" unless ids.all? { |id| named.fetch("inputs").key?(id) }
        return "inputs" unless @store.named.input_binding(named, ids) == body.fetch("input_stat_binding")
        current = dataset_inputs(named, body.fetch("dataset_id"))
        return "dataset" unless current.map { |input| input["id"] }.sort == ids.sort
        return "inputs" unless inputs_unchanged?(current)
        return "code" unless code_identity == body.fetch("code_identity")
        return "runtime" unless Digest::SHA256.hexdigest(JSON.generate(lock)) == body.fetch("runtime_lock_sha256")
        return "converter" unless state.dig("config", "converter_revision") == body.fetch("converter_revision")
        return "site_settings" unless Digest::SHA256.file(state.dig("config", "site_settings")).hexdigest == body.fetch("site_settings_sha256")

        baseline = body.fetch("baseline")
        if baseline["mode"] == "restore"
          accepted = state.fetch("accepted_baselines")[baseline["baseline_id"]]
          return "baseline" unless accepted && accepted["sha256"] == baseline["sha256"] && File.file?(accepted.fetch("path")) && Digest::SHA256.file(accepted.fetch("path")).hexdigest == baseline["sha256"]
        end
        nil
      rescue NamedError, Errno::ENOENT
        "inputs"
      end

      # Consumes the approved plan before any mutation. A crash after this point
      # is visible and cannot run the same plan twice.
      def claim_plan!(plan_id)
        run_id = @store.new_id("run")
        @store.update do |state|
          plan = state.fetch("plans")[plan_id]
          raise StandardWorkflowError, "STANDARD_REFERENCE_INVALID" unless plan
          raise StandardWorkflowError, "STANDARD_NOT_APPROVED" if plan["status"] == "proposed"
          raise StandardWorkflowError, "STANDARD_PLAN_CONSUMED" unless plan["status"] == "approved"
          unless plan.dig("approval", "digest") == plan["digest"] && Digest::SHA256.hexdigest(canonical_json(plan["body"])) == plan["digest"]
            raise StandardWorkflowError, "STANDARD_APPROVAL_MISMATCH"
          end

          stale = stale_reason(plan, state)
          raise StandardWorkflowError.new("STANDARD_STALE_PLAN", stale) if stale

          instances = plan.dig("body", "instances")
          instances.each_value do |target|
            raise StandardWorkflowError, "STANDARD_INSTANCE_CONFLICT" if state.fetch("instances").key?(target["name"])
            raise StandardWorkflowError, "STANDARD_PORT_OCCUPIED" unless @port_probe.call(target["port"])
          end
          outputs = plan.dig("body", "outputs").values.compact
          raise StandardWorkflowError, "STANDARD_OUTPUT_CONSUMED" unless (outputs & state.fetch("consumed_outputs")).empty?

          dirty = state.fetch("instances").values.select { |record| %w[creating dirty].include?(record["state"]) }
          raise StandardWorkflowError.new("STANDARD_DIRTY_INSTANCE", "reset the earlier run first") unless dirty.empty?

          admission!(state)
          state.fetch("consumed_outputs").concat(outputs)
          plan["status"] = "consumed"
          plan["run_id"] = run_id
          state.fetch("runs")[run_id] = {
            "id" => run_id, "plan_id" => plan_id, "dataset_id" => plan.dig("body", "dataset_id"), "status" => "running",
            "stage" => nil, "stages" => STAGES.to_h { |stage| [stage, { "status" => "pending" }] },
            "started_at" => now, "finished_at" => nil, "failure" => nil,
            "instances" => {}, "artifacts" => {}, "results" => {}, "assertions" => {}
          }
        end
        run_id
      end

      # Measured admission against the aggregate envelope: docker enforces each
      # limit, this refuses a new run that would exceed the sum.
      def admission!(_state)
        stack = lock.dig("limits", "stack")
        needed_cpus = stack.values.sum { |limit| limit["cpus"] } * 2
        needed_memory = stack.values.sum { |limit| limit["memory_mib"] } * 2
        used_cpus, used_memory = measured_usage
        limits = lock.fetch("limits")
        if used_cpus + needed_cpus > limits["aggregate_cpus"] + 0.001 || used_memory + needed_memory > limits["aggregate_memory_mib"]
          raise StandardWorkflowError.new("STANDARD_CAPACITY", "reset an earlier run's retained instances first")
        end
        minimum = limits.fetch("host_free_min_gib") * 1024**3
        raise StandardWorkflowError.new("STANDARD_CAPACITY", "host disk headroom") if @disk_free.call < minimum + 6 * 1024**3
      end

      def measured_usage
        listed = @runtime.run(["docker", "ps", "--no-trunc", "--filter", "label=#{PrebuiltStack::LABEL_MANAGED}=true", "--format", "{{.ID}}"], capture: true, timeout: 20)
        raise StandardWorkflowError.new("STANDARD_CAPACITY", "cannot measure") unless listed.success?

        ids = listed.stdout.to_s.split
        return [0.0, 0] if ids.empty?

        inspected = @runtime.run(["docker", "inspect", "--format", "{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}", *ids], capture: true, timeout: 30)
        raise StandardWorkflowError.new("STANDARD_CAPACITY", "cannot measure") unless inspected.success?

        rows = inspected.stdout.to_s.lines.map { |line| line.split.map(&:to_i) }
        [rows.sum(&:first) / 1e9, rows.sum(&:last) / (1024 * 1024)]
      end

      def host_disk_free_bytes
        result = @runtime.run(["df", "-B1", "--output=avail", @store.workspace_root], capture: true, timeout: 15)
        result.stdout.to_s.lines.last.to_i
      end

      def execute_stages(run_id)
        STAGES.each do |stage|
          stage_method = "stage_#{stage}"
          begin_stage(run_id, stage)
          begin
            send(stage_method, run_id)
            finish_stage(run_id, stage, "passed")
          rescue StandardWorkflowError => error
            fail_run(run_id, stage, error.code, error.message)
            return
          rescue ::StandardError => error
            fail_run(run_id, stage, "STANDARD_INTERNAL", "#{error.class}: #{error.message}")
            return
          end
        end
        @store.update do |state|
          run = state.fetch("runs").fetch(run_id)
          run["status"] = "completed"
          run["finished_at"] = now
          run["stage"] = nil
        end
      end

      def begin_stage(run_id, stage)
        @store.update do |state|
          run = state.fetch("runs").fetch(run_id)
          run["stage"] = stage
          run.fetch("stages")[stage] = { "status" => "running", "started_at" => now }
        end
      end

      def finish_stage(run_id, stage, status)
        @store.update do |state|
          entry = state.fetch("runs").fetch(run_id).fetch("stages").fetch(stage)
          entry["status"] = status
          entry["finished_at"] = now
        end
      end

      def fail_run(run_id, stage, code, detail)
        @store.write_private(@store.run_dir(run_id, "private", "failure.json"),
                             JSON.pretty_generate("stage" => stage, "code" => code, "detail" => detail, "at" => now) + "\n")
        @store.update do |state|
          run = state.fetch("runs").fetch(run_id)
          run.fetch("stages")[stage] = run.fetch("stages").fetch(stage).merge("status" => "failed", "finished_at" => now)
          run["status"] = "failed"
          run["finished_at"] = now
          recovery = RECOVERY.fetch(code) { RECOVERY.fetch("STANDARD_INTERNAL") }
          run["failure"] = { "stage" => stage, "code" => RECOVERY.key?(code) ? code : "STANDARD_INTERNAL", "recovery" => recovery }
          mark_instances_dirty(state, run)
        end
      end

      def mark_instances_dirty(state, run)
        run.fetch("instances", {}).each_value do |name|
          record = state.fetch("instances")[name]
          record["state"] = "dirty" if record && record["state"] != "removed"
        end
      end

      def plan_for(run_id)
        state = @store.load
        state.fetch("plans").fetch(state.fetch("runs").fetch(run_id).fetch("plan_id"))
      end

      def record_results(run_id, **values)
        @store.update do |state|
          state.fetch("runs").fetch(run_id).fetch("results").merge!(values.transform_keys(&:to_s))
        end
      end

      def record_assertions(run_id, group, failures:)
        @store.write_private(@store.run_dir(run_id, "evidence", "#{group}.failures.json"), JSON.pretty_generate(failures) + "\n") unless failures.empty?
        @store.update do |state|
          state.fetch("runs").fetch(run_id).fetch("assertions")[group] = { "result" => failures.empty? ? "passed" : "failed", "failed" => failures.size }
        end
      end

      def assert_clean!(run_id, group, failures, code)
        record_assertions(run_id, group, failures: failures)
        raise StandardWorkflowError.new(code, "#{group}: #{failures.size} assertion(s) failed") unless failures.empty?
      end

      def evidence(run_id, name, value)
        @store.write_private(@store.run_dir(run_id, "evidence", name), value.is_a?(String) ? value : JSON.pretty_generate(value) + "\n")
      end

      def log(run_id, name, result)
        limit = 4 * 1024 * 1024
        text = "exit=#{result.status.inspect}\n--- stdout\n#{result.stdout.to_s[0, limit]}\n--- stderr\n#{result.stderr.to_s[0, limit]}\n"
        @store.write_private(@store.run_dir(run_id, "logs", "#{name}.log"), text)
      end

      # -- stages -------------------------------------------------------------

      def stage_preflight(run_id)
        body = plan_for(run_id).fetch("body")
        named = @store.named_state
        inputs = dataset_inputs(named, body.fetch("dataset_id"))
        @store.named.with_lock do |store|
          inputs.each do |input|
            store.inspect_input(input.fetch("path").unpack1("m0"), sha256: input["sha256"], bytes: input["bytes"], expected: input["identity"])
            store.verify_input_identity(input)
          end
        end
        lock.fetch("images").each do |role, image|
          inspected = @runtime.run(["docker", "image", "inspect", "--format", "{{.Id}}", image.fetch("id")], capture: true, timeout: 30)
          unless inspected.success? && inspected.stdout.to_s.strip == image.fetch("id")
            raise StandardWorkflowError.new("STANDARD_RUNTIME_MISMATCH", role)
          end
        end
        record_results(run_id, input_count: inputs.size, input_bytes: inputs.sum { |input| input["bytes"] })
      rescue NamedError => error
        raise StandardWorkflowError.new("STANDARD_INPUT_CHANGED", error.message)
      end

      def input_path(input)
        File.join(@store.workspace_root, input.fetch("path").unpack1("m0"))
      end

      def typed_input(inputs, type)
        inputs.find { |input| input["type"] == type } or raise StandardWorkflowError, "STANDARD_INPUTS_INCOMPLETE"
      end

      def stage_convert(run_id)
        body = plan_for(run_id).fetch("body")
        named = @store.named_state
        inputs = dataset_inputs(named, body.fetch("dataset_id"))
        config = @store.load.fetch("config")
        work = @store.run_dir(run_id, "work")
        code = File.join(work, "code")
        output = File.join(work, "converter-output")
        secrets = @store.run_dir(run_id, "private", "converter")
        [code, output, secrets].each { |dir| FileUtils.mkdir_p(dir, mode: 0o700) }

        materialize_converter(config, code)
        root_password = SecureRandom.hex(32)
        converter_password = SecureRandom.hex(32)
        settings = File.read(input_path(typed_input(inputs, "converter-settings")))
        { "  host: synthetic-source" => "  host: 127.0.0.1",
          "  password: \"\"" => "  password: \"#{converter_password}\"",
          "  sql_layout_override: inline_community_database" => "  sql_layout_override: null" }.each do |from, to|
          raise StandardWorkflowError.new("STANDARD_CONVERSION_FAILED", "settings shape") unless settings.scan(from).size == 1

          settings = settings.sub(from, to)
        end
        @store.write_private(File.join(secrets, "settings.yml"), settings)
        @store.write_private(File.join(secrets, "root-password"), root_password)
        @store.write_private(File.join(secrets, "root.cnf"), "[client]\nuser=root\nsocket=/run/mysqld/mysqld.sock\npassword=#{root_password}\n")
        @store.write_private(File.join(secrets, "bootstrap.sql"), <<~SQL)
          CREATE DATABASE khoros_fixture CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
          CREATE USER 'fixture_converter'@'127.0.0.1' IDENTIFIED BY '#{converter_password}';
          GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, CREATE TEMPORARY TABLES ON khoros_fixture.* TO 'fixture_converter'@'127.0.0.1';
        SQL

        sql = typed_input(inputs, "source-sql")
        uploads_dir = input_tree(inputs, "upload", "uploads")
        mappings_dir = input_tree(inputs, "mapping", "mappings")
        short = run_id.delete_prefix("run-")[0, 8]
        db_name = "silomig-#{short}-source-db"
        converter_name = "silomig-#{short}-converter"
        limits = lock.dig("limits", "conversion")
        common = ["--pull=never", "--restart", "no", "--read-only", "--user", "#{Process.uid}:#{Process.gid}", "--cap-drop", "ALL",
                  "--security-opt", "no-new-privileges", "--log-driver", "local", "--log-opt", "max-size=1m",
                  "--label", "silo-migrate.managed=true", "--label", "silo-migrate.instance=#{short}-conversion"]
        tmpfs_opts = "rw,uid=#{Process.uid},gid=#{Process.gid},mode=0700"
        created = []
        begin
          db_id = checked(run_id, "conversion-db-start", ["docker", "run", "-d", *common, "--name", db_name, "--network", "none",
            "--cpus", limits.dig("db", "cpus").to_s, "--memory", "#{limits.dig('db', 'memory_mib')}m", "--pids-limit", limits.dig("db", "pids").to_s,
            "--tmpfs", "/var/lib/mysql:#{tmpfs_opts},size=512m", "--tmpfs", "/tmp:#{tmpfs_opts},size=64m", "--tmpfs", "/run/mysqld:#{tmpfs_opts},size=16m",
            "-v", "#{File.join(secrets, 'root-password')}:/run-fixture/root-password:ro",
            "-v", "#{File.join(secrets, 'root.cnf')}:/run-fixture/root.cnf:ro",
            "-v", "#{File.join(secrets, 'bootstrap.sql')}:/run-fixture/bootstrap.sql:ro",
            "-v", "#{input_path(sql)}:/run-fixture/snapshot.sql:ro",
            "-e", "MARIADB_ROOT_PASSWORD_FILE=/run-fixture/root-password", "-e", "MARIADB_ROOT_HOST=localhost",
            lock.dig("images", "source_db", "id"), "mariadbd", "--bind-address=127.0.0.1", "--skip-name-resolve",
            "--innodb-buffer-pool-size=64M", "--innodb-log-file-size=32M", "--max-connections=10"], timeout: 60).stdout.strip
          created << db_id
          wait_source_db(db_id)
          client = "mariadb --defaults-extra-file=/run-fixture/root.cnf --batch"
          checked(run_id, "conversion-db-bootstrap", ["docker", "exec", db_id, "/bin/sh", "-c", "exec #{client} < /run-fixture/bootstrap.sql"], timeout: 60)
          checked(run_id, "conversion-db-load", ["docker", "exec", db_id, "/bin/sh", "-c", "exec #{client} khoros_fixture < /run-fixture/snapshot.sql"], timeout: 120)
          converter_args = ["docker", "run", "-d", *common, "--name", converter_name, "--network", "container:#{db_id}",
            "--cpus", limits.dig("converter", "cpus").to_s, "--memory", "#{limits.dig('converter', 'memory_mib')}m", "--pids-limit", limits.dig("converter", "pids").to_s,
            "--tmpfs", "/tmp:#{tmpfs_opts},size=128m", "-v", "#{code}:/app:ro", "-v", "#{output}:/app/output",
            "-v", "#{File.join(secrets, 'settings.yml')}:/run-fixture/settings.yml:ro",
            "-e", "HOME=/tmp", "-e", "LANG=C.UTF-8", "-e", "LC_ALL=C.UTF-8", "-w", "/app"]
          converter_args += ["-v", "#{mappings_dir}:/fixture-mappings:ro"] if mappings_dir
          converter_args += ["-v", "#{uploads_dir}:/fixture-uploads:ro"] if uploads_dir
          converter_args += ["--entrypoint", "/bin/sh", lock.dig("images", "converter", "id"), "-c", "exec sleep infinity"]
          converter_id = checked(run_id, "conversion-container-start", converter_args, timeout: 60).stdout.strip
          created << converter_id
          convert = @runtime.run(["docker", "exec", "-w", "/app", converter_id, "bundle", "_2.6.3_", "exec", "ruby", "./convert", "--from=khoros",
                                  "--settings=/run-fixture/settings.yml", "--output-db=intermediate.sqlite", "--reset"], capture: true, timeout: 600)
          log(run_id, "convert", convert)
          raise StandardWorkflowError.new("STANDARD_CONVERSION_FAILED", "converter exit") unless convert.success?

          assert_conversion_summary!(run_id, convert.stdout.to_s + convert.stderr.to_s)
        ensure
          created.reverse_each { |id| @runtime.run(["docker", "rm", "--force", "--volumes", id], capture: true, timeout: 60) }
        end
        produced = File.join(output, "intermediate.sqlite")
        raise StandardWorkflowError.new("STANDARD_CONVERSION_FAILED", "no output database") unless File.file?(produced) && !File.symlink?(produced)
        checkpoint_closed!(produced)

        intermediate = @store.run_dir(run_id, "artifacts", "intermediate.sqlite")
        FileUtils.mkdir_p(File.dirname(intermediate), mode: 0o700)
        FileUtils.cp(produced, intermediate)
        File.chmod(0o400, intermediate)
        identity = artifact_identity(intermediate)
        expected = JSON.parse(File.read(input_path(typed_input(inputs, "expected"))))
        failures = intermediate_failures(intermediate, expected)
        assert_clean!(run_id, "intermediate", failures, "STANDARD_CONVERSION_FAILED")
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("artifacts")["intermediate"] = identity }
      end

      def assert_conversion_summary!(run_id, text)
        summary = text.split("== Run Summary ==", 2)[1]
        unless summary && summary.match?(/Errors\s*:\s*0 \(conversion\) \+ 0 \(setup\)/) && summary.match?(/Skipped by policy\s*:\s*0(?:\n|$)/) && !text.match?(/^\s*Error:/)
          raise StandardWorkflowError.new("STANDARD_CONVERSION_FAILED", "summary reports errors or skips")
        end

        evidence(run_id, "conversion-summary.txt", summary[0, 8192])
      end

      def checkpoint_closed!(path)
        raise StandardWorkflowError.new("STANDARD_CONVERSION_FAILED", "database not closed") if %w[-wal -shm].any? { |suffix| File.exist?("#{path}#{suffix}") }
      end

      def intermediate_failures(path, expected)
        raise StandardWorkflowError, "STANDARD_INTERNAL" unless defined?(SQLite3::Database)

        db = SQLite3::Database.new(path, readonly: true)
        counts = expected.fetch("counts")
        failures = []
        { "users" => "users", "categories" => "categories", "topics" => "topics", "posts" => "posts", "uploads" => "attachments" }.each do |table, key|
          actual = db.get_first_value("SELECT COUNT(*) FROM #{table}")
          failures << "intermediate-count:#{table}:#{actual}!=#{counts.fetch(key)}" unless actual == counts.fetch(key)
        end
        failures
      ensure
        db&.close
      end

      # Clean code snapshot of an exact converter revision, plus its site-settings
      # cache. Writes only into this run's new directory.
      def materialize_converter(config, code)
        revision = config.fetch("converter_revision")
        worktree = config.fetch("converter_worktree")
        head = @runtime.run(["git", "-C", worktree, "rev-parse", "HEAD"], capture: true, timeout: 30)
        raise StandardWorkflowError.new("STANDARD_RUNTIME_MISMATCH", "converter revision") unless head.success? && head.stdout.strip == revision

        archive = File.join(File.dirname(code), "converter.tar")
        made = @runtime.run(["git", "-C", worktree, "archive", "--format=tar", "-o", archive, revision], capture: true, timeout: 120)
        raise StandardWorkflowError.new("STANDARD_CONVERSION_FAILED", "archive") unless made.success?
        extracted = @runtime.run(["tar", "-xf", archive, "-C", code, "--no-same-owner"], capture: true, timeout: 120)
        raise StandardWorkflowError.new("STANDARD_CONVERSION_FAILED", "extract") unless extracted.success?

        FileUtils.rm_f(archive)
        cache = File.join(code, "tmp", "requires", "discourse", "config")
        FileUtils.mkdir_p(cache)
        FileUtils.cp(config.fetch("site_settings"), File.join(cache, "site_settings.yml"))
        FileUtils.mkdir_p(File.join(code, "output"))
      end

      # Registered inputs of one type live under inputs/<dir>/<subdir>/; returns
      # that exact directory so bind mounts expose only registered files.
      def input_tree(inputs, type, subdir)
        selected = inputs.select { |input| input["type"] == type }
        return nil if selected.empty?

        roots = selected.map { |input| input.fetch("path").unpack1("m0")[%r{\A(.*?/#{subdir})/}, 1] }.uniq
        raise StandardWorkflowError.new("STANDARD_INPUTS_INCOMPLETE", subdir) unless roots.length == 1 && roots.first

        File.join(@store.workspace_root, roots.first)
      end

      def wait_source_db(db_id)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
        loop do
          ready = @runtime.run(["docker", "exec", db_id, "/bin/sh", "-c", "exec mariadb --defaults-extra-file=/run-fixture/root.cnf --batch --skip-column-names -e 'SELECT 1'"], capture: true, timeout: 5)
          return if ready.success?
          raise StandardWorkflowError.new("STANDARD_CONVERSION_FAILED", "source db readiness") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          nap(1)
        end
      end

      def nap(seconds)
        @sleeper ? @sleeper.call(seconds) : sleep(seconds)
      end

      def checked(run_id, name, command, timeout:)
        result = @runtime.run(command, capture: true, timeout: timeout)
        log(run_id, name, result)
        raise StandardWorkflowError.new("STANDARD_CONVERSION_FAILED", name) unless result.success?

        result
      end

      def stage_site_up(run_id)
        target = plan_for(run_id).dig("body", "instances", "review")
        stack = create_stack(run_id, "review", target)
        assert_runtime_identity!(run_id, stack, "review")
      end

      def create_stack(run_id, role, target)
        name = target.fetch("name")
        db_password = SecureRandom.hex(24)
        @store.write_private(@store.run_dir(run_id, "private", "#{role}-db-password"), db_password)
        @store.update do |state|
          state.fetch("instances")[name] = { "name" => name, "containers" => {}, "networks" => [], "volumes" => [], "state" => "creating", "role" => role, "run_id" => run_id, "port" => target.fetch("port"), "hostname" => target.fetch("hostname") }
          state.fetch("runs").fetch(run_id).fetch("instances")[role] = name
        end
        stack = PrebuiltStack.new(runtime: @runtime, lock: lock, name: name, record: @store.load.fetch("instances").fetch(name), sleeper: @sleeper)
        stack.create!(hostname: target.fetch("hostname"), port: target.fetch("port"), db_password: db_password,
                      labels: { "silo-migrate.run" => run_id, "silo-migrate.role" => role }) do |record|
          @store.update { |state| state.fetch("instances")[name] = record }
        end
        install_helpers(stack)
        stack
      end

      def stack_for(run_id, role)
        state = @store.load
        name = state.fetch("runs").fetch(run_id).fetch("instances").fetch(role)
        PrebuiltStack.new(runtime: @runtime, lock: lock, name: name, record: state.fetch("instances").fetch(name), sleeper: @sleeper)
      end

      def set_instance_state(stack, value)
        @store.update { |state| state.fetch("instances").fetch(stack.name)["state"] = value }
      end

      def helper_dir
        File.join(@code_root, "runtime", "prebuilt-discourse")
      end

      def install_helpers(stack)
        %w[baseline_seed.rb site_fingerprint.rb settings_restore.rb set_review_port.rb].each do |helper|
          stack.copy_in(File.join(helper_dir, helper), "/tmp/#{helper}")
        end
      end

      def fingerprint(stack)
        stack.rails_runner("/tmp/site_fingerprint.rb")
      end

      def assert_runtime_identity!(run_id, stack, label)
        app = lock.fetch("app")
        versions = stack.web_exec(["bash", "-c", "cd #{PrebuiltStack::DISCOURSE_ROOT} && ruby -e 'print RUBY_VERSION' && echo && bundle -v && sha256sum Gemfile.lock && cat config/git-utils-overrides.json"], timeout: 60)
        text = versions.stdout.to_s
        failures = []
        failures << "ruby" unless text.lines.first.to_s.strip == app.fetch("ruby")
        failures << "bundler" unless text.lines[1].to_s.strip == app.fetch("bundler")
        failures << "lock" unless text.include?(app.fetch("gemfile_lock_sha256"))
        failures << "revision" unless text.include?(app.fetch("revision"))
        bundle = stack.discourse_shell(%w[bundle check], env_password: false, timeout: 120)
        failures << "generic_import_bundle" unless bundle.success?
        site = fingerprint(stack)
        failures.concat(StandardOracle.runtime_failures(site, lock))
        evidence(run_id, "runtime-#{label}.json", site.slice("versions", "runtime"))
        assert_clean!(run_id, "runtime_#{label}", failures, "STANDARD_RUNTIME_MISMATCH")
      end

      def stage_baseline(run_id)
        body = plan_for(run_id).fetch("body")
        stack = stack_for(run_id, "review")
        decision = body.fetch("baseline")
        base_fp = decision["mode"] == "seed" ? seed_baseline(run_id, stack, body) : restore_baseline(run_id, stack, decision)
        evidence(run_id, "baseline.fingerprint.json", base_fp)
        set_instance_state(stack, "baseline")
        record_results(run_id, baseline_mode: decision["mode"])
        collisions = StandardOracle.collision_failures(base_fp, intermediate_identities(run_id))
        assert_clean!(run_id, "collision_policy", collisions, "STANDARD_COLLISION")
      end

      def seed_baseline(run_id, stack, body)
        password = SecureRandom.urlsafe_base64(18)
        @store.write_private(@store.run_dir(run_id, "private", "admin-password"), password)
        sandbox = SANDBOX_ATTACHMENT
        seeded = stack.rails_runner("/tmp/baseline_seed.rb", env: {
          "SILO_ADMIN_PASSWORD" => password, "SILO_SANDBOX_ATTACHMENT_B64" => [sandbox].pack("m0")
        })
        evidence(run_id, "baseline.seed.json", seeded)
        expected = Digest::SHA256.hexdigest(sandbox)
        base_fp = fingerprint(stack)
        upload = base_fp.fetch("uploads").find { |candidate| candidate["file_sha256"] == expected }
        failures = []
        failures << "sandbox-upload-absent" unless upload
        failures.concat(attachment_http_failures(run_id, stack.record.fetch("port"), upload, sandbox, "sandbox")) if upload
        assert_clean!(run_id, "baseline_seed", failures, "STANDARD_VERIFY_FAILED")
        @store.update do |state|
          state.fetch("runs").fetch(run_id).fetch("artifacts")["sandbox_attachment"] = { "sha256" => expected, "bytes" => sandbox.bytesize, "sha1" => upload.fetch("sha1") }
        end

        identity = make_backup(run_id, stack, body.dig("outputs", "baseline"), "baseline", required_uploads: [archive_member(upload)])
        evidence(run_id, "baseline.manifest.json", manifest(run_id, "baseline", identity, base_fp))
        @store.update do |state|
          artifacts = state.fetch("runs").fetch(run_id).fetch("artifacts")
          artifacts["baseline"] = identity
          artifacts["baseline_fingerprint"] = @store.run_dir(run_id, "evidence", "baseline.fingerprint.json")
        end
        base_fp
      end

      def restore_baseline(run_id, stack, decision)
        accepted = @store.load.fetch("accepted_baselines").fetch(decision.fetch("baseline_id"))
        path = accepted.fetch("path")
        unless Digest::SHA256.file(path).hexdigest == decision.fetch("sha256")
          raise StandardWorkflowError.new("STANDARD_RESTORE_FAILED", "accepted baseline bytes changed")
        end

        restore_archive(run_id, stack, path, "baseline-restore")
        prior_password = @store.run_dir(accepted.fetch("run_id"), "private", "admin-password")
        @store.write_private(@store.run_dir(run_id, "private", "admin-password"), File.read(prior_password)) if File.file?(prior_password)
        accepted_fp = JSON.parse(File.read(accepted.fetch("fingerprint")))
        current = fingerprint(stack)
        map = { accepted_base_url(accepted_fp) => current.dig("runtime", "base_url") }
        failures = StandardOracle.baseline_failures(accepted_fp, current, base_url_map: map)
        assert_clean!(run_id, "accepted_baseline_restored", failures, "STANDARD_RESTORE_FAILED")
        sandbox = accepted_fp.fetch("uploads").find { |upload| upload["extension"] == "txt" }
        @store.update do |state|
          artifacts = state.fetch("runs").fetch(run_id).fetch("artifacts")
          artifacts["sandbox_attachment"] = { "sha256" => sandbox.fetch("file_sha256"), "bytes" => sandbox.fetch("filesize"), "sha1" => sandbox.fetch("sha1") }
          artifacts["baseline"] = accepted.slice("id", "sha256", "bytes", "filename", "path")
          artifacts["baseline_fingerprint"] = accepted.fetch("fingerprint")
        end
        # The working copy keeps the site's restored hostname for later comparisons.
        current
      end

      def accepted_base_url(fingerprint)
        fingerprint.dig("runtime", "base_url")
      end

      def intermediate_identities(run_id)
        db = SQLite3::Database.new(@store.run_dir(run_id, "artifacts", "intermediate.sqlite"), readonly: true)
        db.results_as_hash = true
        {
          "users" => db.execute("SELECT username, email FROM users").map { |row| { "username" => row["username"], "email" => row["email"] } },
          "categories" => db.execute("SELECT name, slug FROM categories").map { |row| { "name" => row["name"], "slug" => row["slug"] } }
        }
      ensure
        db&.close
      end

      # Independent copies only. Both importer scripts mutate SQLite/WAL, so the
      # retained artifact is never handed to them directly.
      def stage_uploads(run_id)
        stack = stack_for(run_id, "review")
        body = plan_for(run_id).fetch("body")
        named = @store.named_state
        inputs = dataset_inputs(named, body.fetch("dataset_id"))
        work = @store.run_dir(run_id, "work", "import")
        FileUtils.mkdir_p(work, mode: 0o700)
        scratch = File.join(work, "intermediate.sqlite")
        FileUtils.cp(@store.run_dir(run_id, "artifacts", "intermediate.sqlite"), scratch)
        File.chmod(0o600, scratch)
        extensions = upload_extensions(scratch)
        config = {
          "source_db_path" => "/shared/import/intermediate.sqlite", "output_db_path" => "/shared/import/uploads.sqlite3",
          "root_paths" => ["/shared/import/files"], "download_cache_path" => "/shared/import/downloaded_files",
          "thread_count_factor" => 1.0, "path_replacements" => [], "fix_missing" => false,
          "delete_missing_uploads" => false, "delete_surplus_uploads" => false, "create_optimized_images" => false,
          "site_settings" => { "authorized_extensions" => extensions, "max_attachment_size_kb" => 1024, "max_image_size_kb" => 1024,
                               "max_image_megapixels" => 5, "secure_uploads" => false, "s3_enable_access_control_tags" => false,
                               "enable_s3_uploads" => false, "multisite" => false }
        }
        config_path = File.join(work, "uploads.yml")
        @store.write_private(config_path, YAML.dump(config))

        set_instance_state(stack, "dirty")
        make_guest = stack.web_exec(["mkdir", "-p", "/shared/import/files"])
        raise StandardWorkflowError.new("STANDARD_UPLOADS_FAILED", "scratch") unless make_guest.success?

        stack.copy_in(scratch, "/shared/import/intermediate.sqlite")
        stack.copy_in(config_path, "/shared/import/uploads.yml")
        tree = input_tree(inputs, "upload", "uploads")
        if tree
          Dir.children(tree).each { |entry| stack.copy_in(File.join(tree, entry), "/shared/import/files/#{entry}") }
        end
        stack.web_exec(["chown", "-R", "discourse:discourse", "/shared/import"])
        before = fingerprint(stack)
        result = stack.discourse_shell(["bundle", "exec", "ruby", "script/bulk_import/uploads_importer.rb", "/shared/import/uploads.yml"], env_password: false, timeout: 900, pin_cpu: true)
        log(run_id, "uploads", result)
        raise StandardWorkflowError.new("STANDARD_UPLOADS_FAILED", "importer exit") unless result.success?

        processed = File.join(work, "uploads.sqlite3")
        stack.copy_out("/shared/import/uploads.sqlite3", processed)
        begin
          validate_processing_db!(processed)
        rescue UsageError => error
          raise StandardWorkflowError.new("STANDARD_UPLOADS_FAILED", error.message)
        end

        # The uploader writes working values to the site; put the baseline's back.
        restored = stack.rails_runner("/tmp/settings_restore.rb", env: { "SILO_SETTINGS_JSON" => JSON.generate(before.fetch("settings")) })
        evidence(run_id, "uploads-settings-restore.json", restored)
        retained = @store.run_dir(run_id, "artifacts", "uploads.sqlite3")
        FileUtils.cp(processed, retained)
        File.chmod(0o400, retained)
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("artifacts")["uploads_db"] = artifact_identity(retained) }
      end

      def upload_extensions(path)
        db = SQLite3::Database.new(path, readonly: true)
        names = db.execute("SELECT display_filename, filename FROM uploads").flatten.compact
        extensions = names.map { |name| File.extname(name).delete_prefix(".").downcase }.reject(&:empty?).uniq.sort
        (extensions | ["txt"]).join("|")
      ensure
        db&.close
      end

      def stage_import(run_id)
        stack = stack_for(run_id, "review")
        args = ["bundle", "exec", "ruby", "script/bulk_import/generic_bulk.rb", "/shared/import/intermediate.sqlite", "/shared/import/uploads.sqlite3"]
        result = stack.discourse_shell(args, timeout: 1200)
        log(run_id, "import", result)
        raise StandardWorkflowError.new("STANDARD_IMPORT_FAILED", "importer exit") unless result.success?

        begin
          assert_clean_import_output!(result.stdout)
        rescue UsageError => error
          raise StandardWorkflowError.new("STANDARD_IMPORT_FAILED", error.message)
        end
        set_instance_state(stack, "imported")
      end

      def expected_for(run_id)
        named = @store.named_state
        inputs = dataset_inputs(named, plan_for(run_id).dig("body", "dataset_id"))
        expected = JSON.parse(File.read(input_path(typed_input(inputs, "expected"))))
        attachments = inputs.select { |input| input["type"] == "upload" }.map { |input| input["sha256"] }
        attachment_bytes = inputs.select { |input| input["type"] == "upload" }.to_h { |input| [input["sha256"], File.binread(input_path(input))] }
        [expected, attachments, attachment_bytes]
      end

      def stage_verify_site(run_id)
        stack = stack_for(run_id, "review")
        site = fingerprint(stack)
        evidence(run_id, "site.imported.json", site)
        state = @store.load
        base = JSON.parse(File.read(@store.run_dir(run_id, "evidence", "baseline.fingerprint.json")))
        expected, attachments, bytes = expected_for(run_id)
        failures = StandardOracle.baseline_failures(base, site)
        failures.concat(StandardOracle.imported_failures(expected, site, attachment_sha256s: attachments, baseline: base))
        failures.concat(http_content_failures(run_id, stack, site, expected, attachments, bytes, state, "review"))
        failures.concat(database_count_failures(stack, base, expected))
        assert_clean!(run_id, "site", failures, "STANDARD_VERIFY_FAILED")
        record_results(run_id, imported_users: expected.dig("counts", "users"), imported_topics: expected.dig("counts", "topics"), imported_posts: expected.dig("counts", "posts"), imported_attachments: attachments.size)
      end

      # Real downloads over the published loopback port, compared byte for byte.
      def http_content_failures(run_id, stack, site, expected, attachments, bytes, state, label)
        port = stack.record.fetch("port")
        failures = []
        sandbox = state.fetch("runs").fetch(run_id).dig("artifacts", "sandbox_attachment")
        sandbox_upload = sandbox && site.fetch("uploads").find { |upload| upload["sha1"] == sandbox["sha1"] }
        if sandbox_upload
          failures.concat(attachment_http_failures(run_id, port, sandbox_upload, SANDBOX_ATTACHMENT, "#{label}-sandbox"))
        else
          failures << "sandbox-upload-record-missing"
        end
        attachments.each do |sha|
          upload = site.fetch("uploads").find { |candidate| candidate["file_sha256"] == sha }
          next failures << "source-upload-record-missing" unless upload

          failures.concat(attachment_http_failures(run_id, port, upload, bytes.fetch(sha), "#{label}-source"))
        end
        # Public JSON, independent of the fingerprint script's process.
        latest = @http.call("http://127.0.0.1:#{port}/latest.json", 2_000_000)
        titles = begin
          JSON.parse(latest.fetch(:body))["topic_list"]["topics"].map { |topic| topic["title"] }
        rescue JSON::ParserError, NoMethodError, TypeError
          failures << "latest-json-invalid"
          []
        end
        expected.fetch("topics").each do |topic|
          failures << "http-topic-absent:#{topic['topic_id']}" unless titles.include?(topic["topic_subject"])
        end
        failures << "http-baseline-topic-absent" unless titles.any? { |title| title.start_with?("Sandbox welcome topic") }
        failures
      end

      def attachment_http_failures(run_id, port, upload, expected, label)
        failures = []
        [["direct", upload.fetch("url")], ["short", upload.fetch("short_path")]].each do |kind, path|
          response = @http.call("http://127.0.0.1:#{port}#{path}", 1_048_576)
          unless response.fetch(:status) == 200 && response.fetch(:body).b == expected.b
            failures << "attachment-http-#{label}-#{kind}:#{response.fetch(:status)}"
          end
        end
        evidence(run_id, "http-#{label}.json", { "url" => upload["url"], "short_path" => upload["short_path"], "sha256" => Digest::SHA256.hexdigest(expected), "failures" => failures })
        failures
      end

      def http_fetch(url, limit, redirects = 3)
        uri = URI(url)
        response = Net::HTTP.start(uri.host, uri.port, open_timeout: 10, read_timeout: 30) { |http| http.get(uri.request_uri) }
        if response.is_a?(Net::HTTPRedirection) && redirects.positive?
          target = URI.join(url, response["location"])
          # Stay on the published loopback listener: rewriting never escapes it.
          target.host = "127.0.0.1"
          target.port = uri.port
          return http_fetch(target.to_s, limit, redirects - 1)
        end
        { status: response.code.to_i, body: response.body.to_s[0, limit].to_s }
      rescue SystemCallError, SocketError, Net::OpenTimeout, Net::ReadTimeout, EOFError, IOError => error
        { status: 0, body: error.class.name }
      end

      def database_count_failures(stack, base, expected)
        result = stack.db_query("SELECT (SELECT COUNT(*) FROM users WHERE id > 0), (SELECT COUNT(*) FROM topics t JOIN users u ON u.id = t.user_id WHERE u.id > 0 AND t.archetype = 'regular'), (SELECT COUNT(*) FROM uploads WHERE id > 0)")
        return ["database-query-failed"] unless result.success?

        users, _topics, uploads = result.stdout.strip.split("|").map(&:to_i)
        failures = []
        failures << "database-user-count:#{users}" unless users == base.fetch("users").size + expected.dig("counts", "users")
        expected_uploads = base.fetch("uploads").size + expected.dig("counts", "attachments")
        failures << "database-upload-count:#{uploads}" unless uploads == expected_uploads
        failures
      end

      def archive_member(upload)
        upload.fetch("url").delete_prefix("/")
      end

      def stage_final_backup(run_id)
        stack = stack_for(run_id, "review")
        site = JSON.parse(File.read(@store.run_dir(run_id, "evidence", "site.imported.json")))
        _expected, attachments, _bytes = expected_for(run_id)
        sandbox = @store.load.fetch("runs").fetch(run_id).dig("artifacts", "sandbox_attachment")
        required = site.fetch("uploads").select { |upload| attachments.include?(upload["file_sha256"]) || upload["sha1"] == sandbox["sha1"] }.map { |upload| archive_member(upload) }
        raise StandardWorkflowError.new("STANDARD_BACKUP_FAILED", "required uploads") if required.size != attachments.size + 1

        identity = make_backup(run_id, stack, plan_for(run_id).dig("body", "outputs", "final"), "final", required_uploads: required)
        @store.update { |state| state.fetch("runs").fetch(run_id).fetch("artifacts")["final"] = identity }
        evidence(run_id, "final.manifest.json", manifest(run_id, "final", identity, site))
      end

      def make_backup(run_id, stack, filename, label, required_uploads:)
        stem = filename.delete_suffix(".tar.gz")
        remote_dir = "/shared/silo-migrate-backup-#{stem}"
        destination = @store.run_dir(run_id, "backups", stem)
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        begin
          Dir.mkdir(destination, 0o700)
        rescue Errno::EEXIST
          raise StandardWorkflowError.new("STANDARD_BACKUP_FAILED", "output identity exists")
        end
        made = stack.web_exec(["sh", "-c", "mkdir -m 700 #{Shellwords.escape(remote_dir)} && chown discourse:discourse #{Shellwords.escape(remote_dir)}"], timeout: 30)
        raise StandardWorkflowError.new("STANDARD_BACKUP_FAILED", "staging") unless made.success?

        backup = stack.discourse_shell(["bundle", "exec", "script/discourse", "backup", "#{remote_dir}/#{filename}"], timeout: 1200)
        log(run_id, "backup-#{label}", backup)
        raise StandardWorkflowError.new("STANDARD_BACKUP_FAILED", "backup exit") unless backup.success?

        # Upstream appends app/schema versions; our directory holds exactly one file.
        listing = stack.web_exec(["find", remote_dir, "-mindepth", "1", "-maxdepth", "1", "-printf", "%f\n"], timeout: 30)
        files = listing.stdout.to_s.lines.map(&:strip)
        unless listing.success? && files.length == 1 && files.first.match?(/\A#{Regexp.escape(stem)}-v[0-9A-Za-z.-]+\.tar\.gz\z/)
          raise StandardWorkflowError.new("STANDARD_BACKUP_FAILED", "ambiguous output")
        end

        archive = File.join(destination, files.first)
        stack.copy_out("#{remote_dir}/#{files.first}", archive)
        raise StandardWorkflowError.new("STANDARD_BACKUP_FAILED", "copy") unless File.file?(archive) && !File.symlink?(archive)

        File.chmod(0o400, archive)
        begin
          members = validate_full_archive!(archive, required_uploads)
        rescue UsageError => error
          raise StandardWorkflowError.new("STANDARD_BACKUP_FAILED", error.message)
        end
        artifact_identity(archive).merge("path" => archive, "label" => "archive-validated", "required_uploads" => required_uploads, "upload_sha256" => members.fetch("upload_sha256").slice(*required_uploads))
      end

      def manifest(run_id, label, identity, site)
        state = @store.load
        run = state.fetch("runs").fetch(run_id)
        plan = state.fetch("plans").fetch(run.fetch("plan_id"))
        {
          "kind" => label, "run_id" => run_id, "plan_id" => plan["id"], "plan_digest" => plan["digest"],
          "archive" => identity.slice("filename", "sha256", "bytes"), "restore_status" => identity["label"],
          "required_uploads" => identity["upload_sha256"],
          "lineage" => {
            "dataset_id" => plan.dig("body", "dataset_id"), "inputs" => plan.dig("body", "input_binding"),
            "baseline" => plan.dig("body", "baseline"), "baseline_archive" => run.dig("artifacts", "baseline")&.slice("filename", "sha256", "bytes"),
            "intermediate" => run.dig("artifacts", "intermediate"), "uploads_db" => run.dig("artifacts", "uploads_db"),
            "code_identity" => plan.dig("body", "code_identity"), "converter_revision" => plan.dig("body", "converter_revision"),
            "app_revision" => plan.dig("body", "app_revision"), "image_ids" => plan.dig("body", "image_ids"),
            "site_versions" => site["versions"]
          },
          "scope" => "synthetic local rehearsal; hosted restore, plugins and S3 remain engineer handoffs"
        }
      end

      # Local review convenience only, after the portable archive already exists.
      def stage_review_url(run_id)
        stack = stack_for(run_id, "review")
        result = stack.rails_runner("/tmp/set_review_port.rb", env: { "SILO_SITE_PORT" => stack.record.fetch("port").to_s })
        evidence(run_id, "review-url.json", result)
        record_results(run_id, review_url: result.fetch("base_url"))
      end

      def restore_archive(run_id, stack, archive, label)
        filename = File.basename(archive)
        ensure_dir = stack.web_exec(["sh", "-c", "mkdir -p #{PrebuiltStack::DISCOURSE_ROOT}/public/backups/default && chown -R discourse:discourse #{PrebuiltStack::DISCOURSE_ROOT}/public/backups /shared/backups"], timeout: 30)
        raise StandardWorkflowError.new("STANDARD_RESTORE_FAILED", "backup dir") unless ensure_dir.success?

        stack.copy_in(archive, "#{PrebuiltStack::DISCOURSE_ROOT}/public/backups/default/#{filename}")
        result = nil
        begin
          enabled = stack.discourse_shell(%w[bundle exec script/discourse enable_restore], env_password: false, timeout: 300)
          raise StandardWorkflowError.new("STANDARD_RESTORE_FAILED", "enable_restore") unless enabled.success?

          result = stack.discourse_shell(["bundle", "exec", "script/discourse", "restore", filename, "--location", "local"], timeout: 1200)
          log(run_id, label, result)
        ensure
          disabled = stack.discourse_shell(%w[bundle exec script/discourse disable_restore], env_password: false, timeout: 300)
          log(run_id, "#{label}-disable", disabled)
          raise StandardWorkflowError.new("STANDARD_RESTORE_FAILED", "disable_restore") unless disabled.success?
        end
        unless result&.success? && result.stdout.to_s.include?("[SUCCESS]")
          raise StandardWorkflowError.new("STANDARD_RESTORE_FAILED", "restore exit")
        end
      end

      def stage_restore(run_id)
        target = plan_for(run_id).dig("body", "instances", "restore")
        stack = create_stack(run_id, "restore", target)
        assert_runtime_identity!(run_id, stack, "restore")
        final = @store.load.fetch("runs").fetch(run_id).dig("artifacts", "final")
        set_instance_state(stack, "dirty")
        restore_archive(run_id, stack, final.fetch("path"), "final-restore")
        set_instance_state(stack, "restored")
        # Sidekiq and the app reload settings; give the restarted workers a moment.
        wait_restored_web(stack)
      end

      def wait_restored_web(stack)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
        loop do
          response = @http.call("http://127.0.0.1:#{stack.record.fetch('port')}/srv/status", 256)
          return if response.fetch(:status) == 200
          raise StandardWorkflowError.new("STANDARD_RESTORE_FAILED", "web unavailable") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          nap(2)
        end
      end

      def stage_verify_restore(run_id)
        stack = stack_for(run_id, "restore")
        state = @store.load
        source = JSON.parse(File.read(@store.run_dir(run_id, "evidence", "site.imported.json")))
        restored = fingerprint(stack)
        evidence(run_id, "site.restored.json", restored)
        map = { source.dig("runtime", "base_url") => restored.dig("runtime", "base_url") }
        expected, attachments, bytes = expected_for(run_id)
        base = JSON.parse(File.read(@store.run_dir(run_id, "evidence", "baseline.fingerprint.json")))
        failures = StandardOracle.restored_failures(source, restored, base_url_map: map)
        failures.concat(StandardOracle.imported_failures(expected, restored, attachment_sha256s: attachments, baseline: base))
        failures.concat(http_content_failures(run_id, stack, restored, expected, attachments, bytes, state, "restore"))
        failures.concat(database_count_failures(stack, base, expected))
        failures.concat(no_input_mount_failures(stack))
        assert_clean!(run_id, "restore", failures, "STANDARD_RESTORE_FAILED")

        stack.rails_runner("/tmp/set_review_port.rb", env: { "SILO_SITE_PORT" => stack.record.fetch("port").to_s }).tap do |result|
          record_results(run_id, restore_url: result.fetch("base_url"))
        end
        @store.update do |current|
          final = current.fetch("runs").fetch(run_id).fetch("artifacts").fetch("final")
          final["label"] = "restore-proven"
          current.fetch("runs").fetch(run_id)["restore_proven_at"] = now
        end
        identity = @store.load.fetch("runs").fetch(run_id).dig("artifacts", "final")
        evidence(run_id, "final.manifest.json", manifest(run_id, "final", identity, restored))
      end

      # The restored instance must not have any host path, including input stores.
      def no_input_mount_failures(stack)
        result = @runtime.run(["docker", "inspect", "--format", "{{json .Mounts}}", stack.container("web")], capture: true, timeout: 20)
        return ["restore-mounts-uninspectable"] unless result.success?

        mounts = JSON.parse(result.stdout)
        mounts.any? { |mount| mount["Type"] == "bind" } ? ["restore-instance-has-bind-mount"] : []
      rescue JSON::ParserError
        ["restore-mounts-uninspectable"]
      end

      def artifact_identity(path)
        { "filename" => File.basename(path), "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path) }
      end

      # -- safe projections ---------------------------------------------------
      # Fixed fields only. Logs, private evidence, paths, passwords and raw failure
      # detail never appear here; failures are a fixed code plus fixed recovery.

      def public_plan(plan, state, summary: false)
        body = plan.fetch("body")
        result = { plan_id: plan["id"], digest: plan["digest"], status: plan_status(plan, state), run_id: plan["run_id"], created_at: plan["created_at"], approved_by: plan.dig("approval", "reviewer") }
        return result if summary

        result.merge(
          operation: body["operation"], dataset_id: body["dataset_id"], baseline: body["baseline"].slice("mode", "baseline_id"),
          collision_policy: body["collision_policy"], inputs: body["input_binding"].map { |input| input.slice("id", "type", "bytes", "sha256") },
          app_revision: body["app_revision"], converter_revision: body["converter_revision"], code_identity: body["code_identity"],
          instances: body["instances"].transform_values { |target| target.slice("name", "port", "hostname") },
          outputs: body["outputs"], mutations: body["mutations"], not_included: body["not_included"], version: 1
        )
      end

      def plan_status(plan, state)
        return plan["status"] unless %w[proposed approved].include?(plan["status"])

        stale_reason(plan, state) ? "stale" : plan["status"]
      end

      def public_run(run, held: false)
        status = run["status"]
        status = "abandoned" if status == "running" && !held
        result = {
          version: 1, run_id: run["id"], plan_id: run["plan_id"], dataset_id: run["dataset_id"], status: status,
          stage: run["stage"], stages: run["stages"].transform_values { |entry| entry["status"] },
          assertions: run["assertions"], results: run["results"].slice("input_count", "input_bytes", "baseline_mode", "imported_users", "imported_topics", "imported_posts", "imported_attachments", "review_url", "restore_url"),
          artifacts: public_artifacts(run["artifacts"]), started_at: run["started_at"], finished_at: run["finished_at"]
        }
        if status == "abandoned"
          result[:recovery] = "The executing process is gone. Run: silo-migrate standard run recover #{@workspace} #{run['id']}, then reset and re-plan."
        end
        result[:failure] = run["failure"] if run["failure"]
        result
      end

      def public_artifacts(artifacts)
        %w[intermediate uploads_db baseline final].each_with_object({}) do |key, result|
          next unless artifacts[key]

          result[key] = artifacts[key].slice("filename", "sha256", "bytes", "label")
        end
      end

      def public_instance(record)
        { name: record["name"], role: record["role"], run_id: record["run_id"], state: record["state"], port: record["port"], url: record["state"] == "removed" ? nil : "http://127.0.0.1:#{record['port']}/" }
      end
    end
  end
end
