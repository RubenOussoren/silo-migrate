# frozen_string_literal: true

require_relative "../named_workspace_store"

module SiloMigrate
  module Services
    # Shared engineer/application authority. Results deliberately contain no
    # private metadata; registry records never leave this boundary.
    class NamedWorkspaceService
      def initialize(env: ENV)
        @env = env
      end

      def init(workspace)
        operate(workspace, create: true) do |store|
          state = store.init!
          { version: 1, workspace_id: state.fetch("workspace_id"), status: "initialized" }
        end
      end

      def add_source(workspace, platform:, label: nil)
        mutate(workspace) do |store, state|
          r = base_record(store, state, "source").merge("platform" => store.metadata(platform), "label" => store.metadata(label, optional: true))
          store.insert!(state, "sources", r)
          { version: 1, source_id: r["id"], status: "registered" }
        end
      end

      def add_dataset(workspace, source_id:, label: nil)
        mutate(workspace) do |store, state|
          store.record!(state, "sources", source_id)
          r = base_record(store, state, "dataset").merge("source_id" => source_id, "label" => store.metadata(label, optional: true))
          store.insert!(state, "datasets", r)
          { version: 1, source_id: source_id, dataset_id: r["id"], status: "registered" }
        end
      end

      def add_input(workspace, dataset_id:, path:, sha256:, bytes:, type:)
        mutate(workspace) do |store, state|
          store.record!(state, "datasets", dataset_id)
          unless sha256.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(sha256) && bytes.is_a?(Integer) && bytes >= 0 && store.type?(type)
            store.fail!("NAMED_ARGUMENT_INVALID")
          end
          if bytes > NamedWorkspaceStore::MAX_BYTES || state["inputs"].values.sum { |r| r["bytes"] } + bytes > NamedWorkspaceStore::MAX_TOTAL_BYTES
            store.fail!("NAMED_SIZE_LIMIT")
          end
          encoded_path = store.metadata(path)
          store.fail!("NAMED_ARGUMENT_INVALID") if state["inputs"].values.any? { |i| i["path"] == encoded_path }
          identity = store.inspect_input(path, sha256: sha256, bytes: bytes)
          r = base_record(store, state, "input").merge("dataset_id" => dataset_id, "path" => encoded_path,
            "sha256" => sha256, "bytes" => bytes, "type" => type, "identity" => identity)
          store.insert!(state, "inputs", r)
          { version: 1, dataset_id: dataset_id, input_id: r["id"], status: "registered" }
        end
      end

      def plan_validate_inputs(workspace, dataset_id:)
        operate(workspace) do |store|
          state = store.load
          store.record!(state, "datasets", dataset_id)
          inputs = state["inputs"].values.select { |i| i["dataset_id"] == dataset_id }
          store.fail!("NAMED_ARGUMENT_INVALID") if inputs.empty?
          plan = base_record(store, state, "plan").merge("dataset_id" => dataset_id, "generation" => state["generation"],
            "operation" => "validate-inputs", "input_ids" => inputs.map { |i| i["id"] })
          plan["input_binding"] = store.input_binding(state, plan["input_ids"])
          run = base_record(store, state, "run").merge("dataset_id" => dataset_id, "plan_id" => plan["id"],
            "status" => "planned", "attempt_id" => nil, "outcome" => nil)
          plan["run_id"] = run["id"]
          store.insert!(state, "plans", plan)
          store.insert!(state, "runs", run)
          store.save(state)
          descriptor(run)
        end
      end

      def execute(workspace, run_id:)
        operate(workspace) do |store|
          state = store.load
          run = store.record!(state, "runs", run_id)
          store.fail!("NAMED_TRANSITION_INVALID") unless run["status"] == "planned"
          plan = state["plans"].fetch(run["plan_id"])
          store.fail!("NAMED_STALE_PLAN") unless plan["generation"] == state["generation"] && plan["input_binding"] == store.input_binding(state, plan["input_ids"])
          run["status"] = "running"
          run["attempt_id"] = store.new_id("attempt")
          store.save(state) # durable intent precedes any input validation
          failed_input_id = nil
          begin
            plan["input_ids"].each do |id|
              failed_input_id = id
              input = state["inputs"].fetch(id)
              store.inspect_input((input["path"]).unpack1("m0"), sha256: input["sha256"], bytes: input["bytes"], expected: input["identity"])
            end
            # Recheck the entire selection after hashing: an early input may
            # have changed while a later one was being read.
            plan["input_ids"].each do |id|
              failed_input_id = id
              store.verify_input_identity(state["inputs"].fetch(id))
            end
          rescue StandardError => error
            reason = error.is_a?(NamedError) && NamedWorkspaceStore::INPUT_FAILURE_CODES.include?(error.message) ? error.message : "NAMED_IO_ERROR"
            run["status"] = "failed"
            run["outcome"] = { "code" => "NAMED_VALIDATION_FAILED", "input_count" => 0, "bytes" => 0,
              "failed_input_id" => failed_input_id, "reason" => reason }
            store.save(state)
            next descriptor(run)
          end
          run["status"] = "completed"
          run["outcome"] = { "code" => "NAMED_OK", "input_count" => plan["input_ids"].size,
            "bytes" => plan["input_ids"].sum { |id| state["inputs"].fetch(id)["bytes"] } }
          store.save(state) # a failed final write must never return success
          descriptor(run)
        end
      end

      def show(workspace, run_id:)
        operate(workspace) { |store| descriptor(store.record!(store.load, "runs", run_id)) }
      end

      def recover(workspace, run_id:)
        operate(workspace) do |store|
          state = store.load
          run = store.record!(state, "runs", run_id)
          store.fail!("NAMED_TRANSITION_INVALID") unless run["status"] == "running"
          run["status"] = "interrupted"
          run["outcome"] = { "code" => "NAMED_INTERRUPTED", "input_count" => 0, "bytes" => 0 }
          store.save(state)
          descriptor(run)
        end
      end

      private

      def operate(workspace, create: false, &block)
        NamedWorkspaceStore.boundary do
          NamedWorkspaceStore.new(workspace, env: @env).with_lock(create: create, &block)
        end
      end

      def mutate(workspace)
        operate(workspace) do |store|
          state = store.load
          result = yield store, state
          state["generation"] += 1
          store.save(state)
          result
        end
      end

      def base_record(store, state, prefix)
        { "id" => store.new_id(prefix), "workspace_id" => state["workspace_id"] }
      end

      def descriptor(run)
        result = { version: 1, run_id: run["id"], plan_id: run["plan_id"], dataset_id: run["dataset_id"], status: run["status"] }
        result[:attempt_id] = run["attempt_id"] if run["attempt_id"]
        if run["outcome"]
          result[:code] = run["outcome"]["code"]
          result[:input_count] = run["outcome"]["input_count"]
          result[:bytes] = run["outcome"]["bytes"]
        end
        result
      end
    end
  end
end
