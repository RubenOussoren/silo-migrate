# frozen_string_literal: true

require_relative "test_helper"
require "silo_migrate/services/named_workspace_service"

class NamedWorkspaceServiceTest < SiloMigrateTest
  Store = SiloMigrate::NamedWorkspaceStore
  Service = SiloMigrate::Services::NamedWorkspaceService

  def setup_workspace
    with_tmp_base do |dir, env|
      service = Service.new(env: env)
      initial = service.init("synthetic")
      root = File.join(env.fetch("SILO_MIGRATE_BASE_PATH"), "synthetic")
      source = service.add_source("synthetic", platform: "synthetic", label: "private source")
      dataset = service.add_dataset("synthetic", source_id: source[:source_id], label: "private dataset")
      yield service, env, root, source[:source_id], dataset[:dataset_id], initial
    end
  end

  def add_file(service, root, dataset_id, name: "sample", content: "synthetic bytes")
    File.binwrite(File.join(root, "inputs", name), content)
    service.add_input("synthetic", dataset_id: dataset_id, path: "inputs/".b + name.b,
      sha256: Digest::SHA256.hexdigest(content), bytes: content.bytesize, type: "binary")
  end

  def named_error(code)
    error = assert_raises(SiloMigrate::NamedError) { yield }
    assert_equal code, error.message
    assert_nil error.cause
    error
  end

  def test_fresh_private_file_only_init_and_reopen
    setup_workspace do |service, env, root, _source, dataset, initial|
      assert_match(/\Aworkspace-[0-9a-f]{32}\z/, initial[:workspace_id])
      refute File.exist?(File.join(root, "config.env"))
      assert_equal 0o700, File.stat(File.join(root, Store::ROOT)).mode & 0o777
      assert_equal 0o600, File.stat(File.join(root, Store::ROOT, "state.json")).mode & 0o777
      input = add_file(service, root, dataset)
      plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
      reopened = Service.new(env: env)
      assert_equal "planned", reopened.show("synthetic", run_id: plan[:run_id])[:status]
      final = reopened.execute("synthetic", run_id: plan[:run_id])
      assert_equal "completed", final[:status]
      assert_equal "NAMED_OK", final[:code]
      assert_equal 1, final[:input_count]
      assert_equal "synthetic bytes".bytesize, final[:bytes]
      assert_equal final, Service.new(env: env).show("synthetic", run_id: plan[:run_id])
      assert_match(/\Ainput-[0-9a-f]{32}\z/, input[:input_id])
      named_error("NAMED_TRANSITION_INVALID") { reopened.execute("synthetic", run_id: plan[:run_id]) }
      named_error("NAMED_TRANSITION_INVALID") { reopened.recover("synthetic", run_id: plan[:run_id]) }
    end
  end

  def test_workspace_argument_and_mixed_mode_fail_closed
    with_tmp_base do |_dir, env|
      service = Service.new(env: env)
      [nil, "../private", "x\nprivate", "\xff".b, "\xff".b.force_encoding(Encoding::UTF_8)].each do |name|
        named_error("NAMED_WORKSPACE_INVALID") { service.init(name) }
      end
      %w[config.env .silo-migrate/workflow.json .silo-migrate/releases/state.json unrelated].each_with_index do |marker, index|
        workspace = "mixed#{index}"
        root = File.join(env["SILO_MIGRATE_BASE_PATH"], workspace)
        write(File.join(root, marker), "private")
        named_error("NAMED_MODE_CONFLICT") { service.init(workspace) }
        refute File.exist?(File.join(root, Store::ROOT, "state.json"))
        refute File.exist?(File.join(root, Store::ROOT)) if marker == "unrelated"
      end
    end
  end

  def test_foreign_references_and_two_datasets_keep_exact_lineage
    setup_workspace do |service, _env, root, source, dataset, _initial|
      second = service.add_dataset("synthetic", source_id: source)[:dataset_id]
      one = add_file(service, root, dataset, name: "development")
      two = add_file(service, root, second, name: "launch")
      plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
      state = JSON.parse(File.binread(File.join(root, Store::ROOT, "state.json")))
      assert_equal [one[:input_id]], state["plans"][plan[:plan_id]]["input_ids"]
      refute_includes state["plans"][plan[:plan_id]]["input_ids"], two[:input_id]
      named_error("NAMED_REFERENCE_INVALID") { service.add_dataset("synthetic", source_id: dataset) }
      named_error("NAMED_REFERENCE_INVALID") { service.plan_validate_inputs("synthetic", dataset_id: source) }
      named_error("NAMED_REFERENCE_INVALID") { service.show("synthetic", run_id: plan[:plan_id]) }
      service.init("foreign")
      named_error("NAMED_REFERENCE_INVALID") { service.add_dataset("foreign", source_id: source) }
      named_error("NAMED_REFERENCE_INVALID") { service.execute("foreign", run_id: plan[:run_id]) }
      assert_equal "completed", service.execute("synthetic", run_id: plan[:run_id])[:status]
    end
  end

  def test_registry_mutations_invalidate_prior_plans
    setup_workspace do |service, _env, root, _source, dataset, _initial|
      add_file(service, root, dataset)
      plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
      service.add_source("synthetic", platform: "another")
      named_error("NAMED_STALE_PLAN") { service.execute("synthetic", run_id: plan[:run_id]) }
      assert_equal "planned", service.show("synthetic", run_id: plan[:run_id])[:status]
    end
  end

  def test_mutated_replaced_and_linked_inputs_cannot_complete
    %i[mutate replace symlink hardlink].each do |mutation|
      setup_workspace do |service, _env, root, _source, dataset, _initial|
        add_file(service, root, dataset)
        plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
        path = File.join(root, "inputs", "sample")
        case mutation
        when :mutate then File.binwrite(path, "different bytes")
        when :replace
          File.rename(path, path + ".old")
          File.binwrite(path, "synthetic bytes")
        when :symlink
          File.rename(path, path + ".old")
          File.symlink(path + ".old", path)
        when :hardlink then File.link(path, path + ".link")
        end
        result = service.execute("synthetic", run_id: plan[:run_id])
        assert_equal "failed", result[:status], mutation.to_s
        assert_equal "NAMED_VALIDATION_FAILED", result[:code]
        named_error("NAMED_TRANSITION_INVALID") { service.execute("synthetic", run_id: plan[:run_id]) }
      end
    end
  end

  def test_path_confinement_and_expected_size_digest_type
    setup_workspace do |service, _env, root, _source, dataset, _initial|
      File.binwrite(File.join(root, "inputs", "safe"), "ok")
      args = { dataset_id: dataset, path: "inputs/safe", sha256: Digest::SHA256.hexdigest("ok"), bytes: 2, type: "binary" }
      %w[../safe /inputs/safe inputs/../safe inputs//safe inputs/./safe].each do |path|
        named_error("NAMED_PATH_INVALID") { service.add_input("synthetic", **args.merge(path: path)) }
      end
      File.symlink(root, File.join(root, "inputs", "linked"))
      named_error("NAMED_PATH_INVALID") { service.add_input("synthetic", **args.merge(path: "inputs/linked/safe")) }
      FileUtils.mkdir_p(File.join(root, "inputs", "unsafe"))
      File.chmod(0o777, File.join(root, "inputs", "unsafe"))
      named_error("NAMED_PATH_INVALID") { service.add_input("synthetic", **args.merge(path: "inputs/unsafe/safe")) }
      named_error("NAMED_INPUT_CHANGED") { service.add_input("synthetic", **args.merge(bytes: 1)) }
      named_error("NAMED_INPUT_CHANGED") { service.add_input("synthetic", **args.merge(sha256: "0" * 64)) }
      named_error("NAMED_ARGUMENT_INVALID") { service.add_input("synthetic", **args.merge(type: "private/type")) }
      named_error("NAMED_SIZE_LIMIT") { service.add_input("synthetic", **args.merge(bytes: Store::MAX_BYTES + 1)) }
    end
  end

  def test_invalid_bytes_remain_private_and_round_trip
    setup_workspace do |service, _env, root, source, dataset, _initial|
      private_bytes = "secret-\xff\n".b
      result = service.add_source("synthetic", platform: private_bytes, label: private_bytes)
      input = add_file(service, root, dataset, name: private_bytes, content: private_bytes)
      plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
      final = service.execute("synthetic", run_id: plan[:run_id])
      assert_equal "completed", final[:status]
      [result, input, plan, final].each do |public_result|
        refute_includes public_result.inspect, "secret"
        refute_includes public_result.inspect, Digest::SHA256.hexdigest(private_bytes)
        refute_includes public_result.inspect, root
      end
      state = JSON.parse(File.binread(File.join(root, Store::ROOT, "state.json")))
      assert_equal private_bytes, (state["sources"][result[:source_id]]["label"]).unpack1("m0")
      assert state["sources"].key?(source)
    end
  end

  # Total-budget accounting with small limits: the real limits are tens of GiB.
  def with_named_limits(bytes, total)
    saved = [Store::MAX_BYTES, Store::MAX_TOTAL_BYTES]
    [[:MAX_BYTES, bytes], [:MAX_TOTAL_BYTES, total]].each do |name, value|
      Store.send(:remove_const, name)
      Store.const_set(name, value)
    end
    yield
  ensure
    [[:MAX_BYTES, saved[0]], [:MAX_TOTAL_BYTES, saved[1]]].each do |name, value|
      Store.send(:remove_const, name)
      Store.const_set(name, value)
    end
  end

  def test_real_export_sizes_are_accepted
    assert_operator Store::MAX_BYTES, :>=, 32 * 1024**3
    assert_operator Store::MAX_TOTAL_BYTES, :>=, 4 * Store::MAX_BYTES
  end

  def test_count_metadata_state_and_total_byte_budgets
    with_named_limits(16 * 1024 * 1024, 64 * 1024 * 1024) { count_metadata_state_and_total_byte_budgets }
  end

  def count_metadata_state_and_total_byte_budgets
    setup_workspace do |service, env, root, _source, dataset, _initial|
      named_error("NAMED_ARGUMENT_INVALID") { service.add_source("synthetic", platform: "x" * (Store::MAX_METADATA_BYTES + 1)) }
      (Store::MAX_RECORDS - 1).times { service.add_source("synthetic", platform: "x") }
      named_error("NAMED_SIZE_LIMIT") { service.add_source("synthetic", platform: "x") }
      # Sparse bounded synthetic files exercise total accounting without fixtures.
      4.times do |i|
        path = File.join(root, "inputs", "large#{i}")
        File.open(path, "wb") { |f| f.truncate(Store::MAX_BYTES) }
        service.add_input("synthetic", dataset_id: dataset, path: "inputs/large#{i}", sha256: Digest::SHA256.file(path).hexdigest, bytes: Store::MAX_BYTES, type: "binary")
      end
      named_error("NAMED_SIZE_LIMIT") { add_file(service, root, dataset, name: "overflow", content: "x") }
      path = File.join(root, Store::ROOT, "state.json")
      File.binwrite(path, "x" * (Store::MAX_STATE_BYTES + 1))
      named_error("NAMED_SIZE_LIMIT") { Service.new(env: env).plan_validate_inputs("synthetic", dataset_id: dataset) }
    end
  end

  def test_strict_schema_references_and_relocation
    setup_workspace do |service, env, root, _source, dataset, _initial|
      add_file(service, root, dataset)
      plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
      path = File.join(root, Store::ROOT, "state.json")
      original = File.binread(path)
      corruptions = [
        ->(s) { s["extra"] = 1 },
        ->(s) { s["version"] = 2 },
        ->(s) { s["datasets"][dataset]["source_id"] = dataset },
        ->(s) { s["plans"][plan[:plan_id]]["input_ids"] = [] },
        ->(s) { s["runs"][plan[:run_id]]["status"] = "completed" },
        ->(s) { s["inputs"].values.first["identity"]["extra"] = 1 },
        ->(s) { s["inputs"].values.first["path"] = ["inputs/../outside"].pack("m0") }
      ]
      corruptions.each do |change|
        state = JSON.parse(original)
        change.call(state)
        File.binwrite(path, JSON.generate(state))
        named_error("NAMED_STATE_INVALID") { service.show("synthetic", run_id: plan[:run_id]) }
      end
      File.binwrite(path, original)
      File.rename(root, root + "-moved")
      named_error("NAMED_STATE_INVALID") { Service.new(env: env).show("synthetic-moved", run_id: plan[:run_id]) }
    end
  end

  def test_nonblocking_lock_across_instances_and_processes_including_init
    setup_workspace do |service, env, _root, _source, dataset, _initial|
      store = Store.new("synthetic", env: env)
      store.with_lock do
        named_error("NAMED_BUSY") { Service.new(env: env).add_source("synthetic", platform: "x") }
        named_error("NAMED_BUSY") { service.init("synthetic") }
        named_error("NAMED_BUSY") { service.plan_validate_inputs("synthetic", dataset_id: dataset) }
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          begin
            Service.new(env: env).add_source("synthetic", platform: "x")
            writer.write("unexpected")
          rescue SiloMigrate::NamedError => e
            writer.write(e.message)
          ensure
            writer.close
          end
          exit! 0
        end
        writer.close
        assert_equal "NAMED_BUSY", reader.read
        reader.close
        Process.wait(pid)
      end
      assert_equal "registered", service.add_source("synthetic", platform: "x")[:status]
    end
  end

  def test_running_persisted_before_check_and_explicit_crash_recovery
    setup_workspace do |service, env, root, _source, dataset, _initial|
      add_file(service, root, dataset)
      plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        Store.class_eval do
          alias_method :original_inspect_input_for_crash, :inspect_input
          define_method(:inspect_input) do |*args, **kwargs|
            writer.write("running")
            writer.flush
            sleep 60
          end
        end
        service.execute("synthetic", run_id: plan[:run_id])
        exit! 1
      end
      writer.close
      begin
        assert_equal "running", reader.read(7)
        state = JSON.parse(File.binread(File.join(root, Store::ROOT, "state.json")))
        assert_equal "running", state["runs"][plan[:run_id]]["status"]
        other = Service.new(env: env)
        named_error("NAMED_BUSY") { other.recover("synthetic", run_id: plan[:run_id]) }
        named_error("NAMED_BUSY") { other.add_source("synthetic", platform: "x") }
        named_error("NAMED_BUSY") { other.execute("synthetic", run_id: plan[:run_id]) }
        named_error("NAMED_BUSY") { other.plan_validate_inputs("synthetic", dataset_id: dataset) }
      ensure
        Process.kill("KILL", pid)
        Process.wait(pid)
        reader.close
      end
      reopened = Service.new(env: env)
      assert_equal "running", reopened.show("synthetic", run_id: plan[:run_id])[:status]
      named_error("NAMED_TRANSITION_INVALID") { reopened.execute("synthetic", run_id: plan[:run_id]) }
      result = reopened.recover("synthetic", run_id: plan[:run_id])
      assert_equal "interrupted", result[:status]
      assert_equal "NAMED_INTERRUPTED", result[:code]
      named_error("NAMED_TRANSITION_INVALID") { reopened.recover("synthetic", run_id: plan[:run_id]) }
    end
  end

  def test_write_failure_does_not_return_success_and_retains_recoverable_running
    setup_workspace do |service, env, root, _source, dataset, _initial|
      add_file(service, root, dataset)
      plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
      store = Store.new("synthetic", env: env)
      original = store.method(:save)
      store.define_singleton_method(:save) do |state|
        raise IOError, "private failure path" if state["runs"].values.any? { |r| r["status"] == "completed" }
        original.call(state)
      end
      Store.stub(:new, store) do
        named_error("NAMED_IO_ERROR") { service.execute("synthetic", run_id: plan[:run_id]) }
      end
      assert_equal "running", service.show("synthetic", run_id: plan[:run_id])[:status]
      assert_equal "interrupted", service.recover("synthetic", run_id: plan[:run_id])[:status]
    end
  end

  def test_plan_exact_binding_and_duplicate_private_path_corruption
    setup_workspace do |service, _env, root, _source, dataset, _initial|
      first = add_file(service, root, dataset, name: "one", content: "one")
      second = add_file(service, root, dataset, name: "two", content: "two")
      plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
      path = File.join(root, Store::ROOT, "state.json")
      original = File.binread(path)
      state = JSON.parse(original)
      assert_match(/\A[0-9a-f]{64}\z/, state["plans"][plan[:plan_id]]["input_binding"])
      %w[sha256 identity bytes type path].each do |field|
        altered = JSON.parse(original)
        input = altered["inputs"][first[:input_id]]
        case field
        when "sha256" then input[field] = "0" * 64
        when "identity" then input[field]["ino"] += 1
        when "bytes"
          input[field] += 1
          input["identity"]["size"] += 1
        when "type" then input[field] = "text"
        when "path" then input[field] = ["inputs/different"].pack("m0")
        end
        File.binwrite(path, JSON.generate(altered))
        named_error("NAMED_STATE_INVALID") { service.execute("synthetic", run_id: plan[:run_id]) }
      end
      # Even if someone rewrites the binding to match, duplicate paths are invalid.
      state["inputs"][second[:input_id]]["path"] = state["inputs"][first[:input_id]]["path"]
      store = Store.new("synthetic", env: { "SILO_MIGRATE_BASE_PATH" => File.dirname(root) })
      state["plans"][plan[:plan_id]]["input_binding"] = store.input_binding(state, state["plans"][plan[:plan_id]]["input_ids"])
      File.binwrite(path, JSON.generate(state))
      named_error("NAMED_STATE_INVALID") { service.show("synthetic", run_id: plan[:run_id]) }
      ["{", "\xff".b].each do |invalid|
        File.binwrite(path, invalid)
        named_error("NAMED_STATE_INVALID") { service.show("synthetic", run_id: plan[:run_id]) }
      end
    end
  end

  def test_input_mutation_during_read_fails_postcheck
    setup_workspace do |service, env, root, _source, dataset, _initial|
      add_file(service, root, dataset)
      plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
      input_path = File.join(root, "inputs", "sample")
      input_ino = File.stat(input_path).ino
      store = Store.new("synthetic", env: env)
      original = store.method(:identity)
      input_calls = 0
      store.define_singleton_method(:identity) do |stat|
        if stat.ino == input_ino
          input_calls += 1
          File.binwrite(input_path, "changed while reading") if input_calls == 2
        end
        original.call(stat)
      end
      Store.stub(:new, store) do
        result = service.execute("synthetic", run_id: plan[:run_id])
        assert_equal "failed", result[:status]
        assert_equal "NAMED_VALIDATION_FAILED", result[:code]
      end
      assert_operator input_calls, :>=, 2
      assert_equal "failed", service.show("synthetic", run_id: plan[:run_id])[:status]
    end
  end

  def test_directory_and_fifo_inputs_rejected_without_reading
    setup_workspace do |service, _env, root, _source, dataset, _initial|
      Dir.mkdir(File.join(root, "inputs", "directory"))
      File.mkfifo(File.join(root, "inputs", "fifo"), 0o600)
      %w[directory fifo].each do |name|
        named_error("NAMED_PATH_INVALID") do
          service.add_input("synthetic", dataset_id: dataset, path: "inputs/#{name}", sha256: Digest::SHA256.hexdigest(""), bytes: 0, type: "binary")
        end
      end
    end
  end

  def test_precheck_failure_records_failed_and_running_write_failure_does_not_check
    setup_workspace do |service, env, root, _source, dataset, _initial|
      add_file(service, root, dataset)
      plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
      store = Store.new("synthetic", env: env)
      store.define_singleton_method(:save) { |_state| raise IOError, "private" }
      inspected = false
      store.define_singleton_method(:inspect_input) { |*| inspected = true }
      Store.stub(:new, store) { named_error("NAMED_IO_ERROR") { service.execute("synthetic", run_id: plan[:run_id]) } }
      refute inspected, "must not check before durable running"
      assert_equal "planned", service.show("synthetic", run_id: plan[:run_id])[:status]
      store = Store.new("synthetic", env: env)
      store.define_singleton_method(:inspect_input) { |*| raise IOError, "private path" }
      Store.stub(:new, store) do
        result = service.execute("synthetic", run_id: plan[:run_id])
        assert_equal "failed", result[:status]
        refute_includes result.inspect, "private"
      end
      assert_equal "failed", service.show("synthetic", run_id: plan[:run_id])[:status]
    end
  end

  def with_state_limit(limit)
    original = Store::MAX_STATE_BYTES
    Store.send(:remove_const, :MAX_STATE_BYTES)
    Store.const_set(:MAX_STATE_BYTES, limit)
    yield
  ensure
    Store.send(:remove_const, :MAX_STATE_BYTES)
    Store.const_set(:MAX_STATE_BYTES, original)
  end

  def test_state_budget_reserves_every_run_terminal_before_accepting_growth
    %i[completed failed interrupted].each do |terminal|
      setup_workspace do |service, env, root, _source, dataset, _initial|
        add_file(service, root, dataset)
        first = service.plan_validate_inputs("synthetic", dataset_id: dataset)
        second = service.plan_validate_inputs("synthetic", dataset_id: dataset)
        store = Store.new("synthetic", env: env)
        state = store.with_lock { store.load }
        limit = store.reserved_state_bytes(state)
        assert_operator limit, :>, JSON.generate(state).bytesize
        before = File.binread(File.join(root, Store::ROOT, "state.json"))
        with_state_limit(limit) do
          named_error("NAMED_SIZE_LIMIT") { service.add_source("synthetic", platform: "extra") }
          named_error("NAMED_SIZE_LIMIT") { service.plan_validate_inputs("synthetic", dataset_id: dataset) }
          assert_equal before, File.binread(File.join(root, Store::ROOT, "state.json"))
          case terminal
          when :failed
            File.binwrite(File.join(root, "inputs", "sample"), "mutation")
          when :interrupted
            store.with_lock do
              current = store.load
              [first, second].each do |plan|
                run = current["runs"].fetch(plan[:run_id])
                run["status"] = "running"
                run["attempt_id"] = store.new_id("attempt")
              end
              store.save(current)
            end
            named_error("NAMED_SIZE_LIMIT") { service.add_source("synthetic", platform: "extra") }
            named_error("NAMED_SIZE_LIMIT") { service.plan_validate_inputs("synthetic", dataset_id: dataset) }
          end
          [first, second].each do |plan|
            result = terminal == :interrupted ? service.recover("synthetic", run_id: plan[:run_id]) : service.execute("synthetic", run_id: plan[:run_id])
            assert_equal terminal.to_s, result[:status]
          end
          assert_operator File.size(File.join(root, Store::ROOT, "state.json")), :<=, limit
        end
      end
    end
  end

  def test_plan_refuses_when_only_actual_planned_bytes_would_fit
    setup_workspace do |service, env, root, _source, dataset, _initial|
      add_file(service, root, dataset)
      path = File.join(root, Store::ROOT, "state.json")
      original = File.binread(path)
      service.plan_validate_inputs("synthetic", dataset_id: dataset)
      projected = JSON.parse(File.binread(path))
      File.binwrite(path, original)
      with_state_limit(JSON.generate(projected).bytesize) do
        named_error("NAMED_SIZE_LIMIT") { service.plan_validate_inputs("synthetic", dataset_id: dataset) }
        assert_equal original, File.binread(path)
      end
      limit = Store.new("synthetic", env: env).reserved_state_bytes(projected)
      with_state_limit(limit) do
        plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
        assert_equal "completed", service.execute("synthetic", run_id: plan[:run_id])[:status]
      end
    end
  end

  def test_init_retry_only_adopts_empty_private_inputs_and_never_cleans_temps
    with_tmp_base do |_dir, env|
      service = Service.new(env: env)
      store = Store.new("synthetic", env: env)
      store.define_singleton_method(:save) { |_| raise IOError, "crash before save" }
      Store.stub(:new, store) { named_error("NAMED_IO_ERROR") { service.init("synthetic") } }
      root = File.join(env["SILO_MIGRATE_BASE_PATH"], "synthetic")
      assert_empty Dir.children(File.join(root, "inputs"))
      assert_equal "initialized", service.init("synthetic")[:status]

      store = Store.new("tempcrash", env: env)
      store.define_singleton_method(:save) { |_| raise IOError, "crash before save" }
      Store.stub(:new, store) { named_error("NAMED_IO_ERROR") { service.init("tempcrash") } }
      temp_root = File.join(env["SILO_MIGRATE_BASE_PATH"], "tempcrash")
      temp = File.join(temp_root, Store::ROOT, ".state-crash.tmp")
      File.binwrite(temp, "private")
      named_error("NAMED_MODE_CONFLICT") { service.init("tempcrash") }
      assert_equal "private", File.binread(temp)
      refute File.exist?(File.join(temp_root, Store::ROOT, "state.json"))
      File.binwrite(File.join(temp_root, "inputs", "unregistered"), "private")
      # Even absent a temp, nonempty inputs must not be silently adopted.
      other = Store.new("inputcrash", env: env)
      other.define_singleton_method(:save) { |_| raise IOError, "crash" }
      Store.stub(:new, other) { named_error("NAMED_IO_ERROR") { service.init("inputcrash") } }
      input_root = File.join(env["SILO_MIGRATE_BASE_PATH"], "inputcrash")
      File.binwrite(File.join(input_root, "inputs", "unregistered"), "private")
      named_error("NAMED_MODE_CONFLICT") { service.init("inputcrash") }
    end
  end

  def test_init_parent_fsync_failure_never_resets_persisted_identity
    with_tmp_base do |_dir, env|
      service = Service.new(env: env)
      store = Store.new("synthetic", env: env)
      store.define_singleton_method(:sync_init_directories!) { raise IOError, "private fsync failure" }
      Store.stub(:new, store) { named_error("NAMED_IO_ERROR") { service.init("synthetic") } }
      path = File.join(env["SILO_MIGRATE_BASE_PATH"], "synthetic", Store::ROOT, "state.json")
      before = File.binread(path)
      named_error("NAMED_ALREADY_INITIALIZED") { service.init("synthetic") }
      assert_equal before, File.binread(path)
    end
  end

  def test_final_selection_identity_pass_detects_early_input_mutation
    setup_workspace do |service, env, root, _source, dataset, _initial|
      first = add_file(service, root, dataset, name: "first")
      add_file(service, root, dataset, name: "later")
      plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
      store = Store.new("synthetic", env: env)
      original = store.method(:inspect_input)
      store.define_singleton_method(:inspect_input) do |path, **args|
        result = original.call(path, **args)
        File.binwrite(File.join(root, "inputs", "first"), "mutated during later input") if path == "inputs/later"
        result
      end
      Store.stub(:new, store) do
        result = service.execute("synthetic", run_id: plan[:run_id])
        assert_equal "failed", result[:status]
        refute result.key?(:failed_input_id)
        refute result.key?(:reason)
      end
      state = JSON.parse(File.binread(File.join(root, Store::ROOT, "state.json")))
      outcome = state["runs"][plan[:run_id]]["outcome"]
      assert_equal first[:input_id], outcome["failed_input_id"]
      assert_equal "NAMED_INPUT_CHANGED", outcome["reason"]
      outcome["failed_input_id"] = "input-#{'0' * 32}"
      File.binwrite(File.join(root, Store::ROOT, "state.json"), JSON.generate(state))
      named_error("NAMED_STATE_INVALID") { service.show("synthetic", run_id: plan[:run_id]) }
    end
  end

  def test_missing_workspace_missing_marker_and_empty_state_have_fixed_errors
    with_tmp_base do |_dir, env|
      service = Service.new(env: env)
      named_error("NAMED_NOT_INITIALIZED") { service.show("missing", run_id: "run-invalid") }
      FileUtils.mkdir_p(File.join(env["SILO_MIGRATE_BASE_PATH"], "unmarked"))
      named_error("NAMED_NOT_INITIALIZED") { service.show("unmarked", run_id: "run-invalid") }
      service.init("synthetic")
      File.binwrite(File.join(env["SILO_MIGRATE_BASE_PATH"], "synthetic", Store::ROOT, "state.json"), "")
      named_error("NAMED_STATE_INVALID") { service.show("synthetic", run_id: "run-invalid") }
    end
  end

  def test_nonascii_base_and_nested_binary_input_path
    with_tmp_base do |dir, env|
      env["SILO_MIGRATE_BASE_PATH"] = File.join(dir, "clients-café")
      service = Service.new(env: env)
      service.init("synthetic")
      source = service.add_source("synthetic", platform: "test")[:source_id]
      dataset = service.add_dataset("synthetic", source_id: source)[:dataset_id]
      root = File.join(env["SILO_MIGRATE_BASE_PATH"], "synthetic")
      relative = "inputs/données-".b + "\xff/nested-\xfe".b
      full = File.join(root.b, relative)
      FileUtils.mkdir_p(File.dirname(full), mode: 0o700)
      File.binwrite(full, "bytes")
      service.add_input("synthetic", dataset_id: dataset, path: relative, sha256: Digest::SHA256.hexdigest("bytes"), bytes: 5, type: "binary")
      plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
      assert_equal "completed", service.execute("synthetic", run_id: plan[:run_id])[:status]
    end
  end

  def test_replaced_lock_fails_after_flock_before_yield
    setup_workspace do |_service, env, root, _source, _dataset, _initial|
      store = Store.new("synthetic", env: env)
      original = store.method(:verify_lock!)
      store.define_singleton_method(:verify_lock!) do |lock, path|
        File.rename(path, path + ".old")
        File.open(path, File::WRONLY | File::CREAT, 0o600) { |file| file.write("") }
        original.call(lock, path)
      end
      yielded = false
      named_error("NAMED_PATH_INVALID") { store.with_lock { yielded = true } }
      refute yielded
      assert File.exist?(File.join(root, Store::ROOT, "lock.old"))
    end
  end

  def test_legacy_authority_inserted_after_init_is_rejected
    %w[config.env .silo-migrate/releases/state.json].each do |marker|
      setup_workspace do |service, _env, root, _source, dataset, _initial|
        add_file(service, root, dataset)
        plan = service.plan_validate_inputs("synthetic", dataset_id: dataset)
        write(File.join(root, marker), "private legacy")
        named_error("NAMED_MODE_CONFLICT") { service.add_source("synthetic", platform: "x") }
        named_error("NAMED_MODE_CONFLICT") { service.execute("synthetic", run_id: plan[:run_id]) }
        named_error("NAMED_MODE_CONFLICT") { service.show("synthetic", run_id: plan[:run_id]) }
      end
    end
  end

end
