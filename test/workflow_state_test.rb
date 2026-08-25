# frozen_string_literal: true

require_relative "test_helper"

class WorkflowStateTest < SiloMigrateTest
  class NonEmptyRuntime < SiloMigrate::Runtime::Fake
    def run(cmd, **options)
      if cmd.any? { |part| part.to_s.include?("information_schema.tables") }
        @operations << [:run, cmd, options[:chdir], options[:capture], options[:timeout], nil, true]
        return SiloMigrate::Runtime::CommandResult.new(success?: true, stdout: "2\n", stderr: "", status: 0)
      end
      super
    end
  end

  class FailedImportRuntime < SiloMigrate::Runtime::Fake
    def run_with_stdin(cmd, chdir: nil)
      super
      SiloMigrate::Runtime::CommandResult.new(success?: false, stdout: "", stderr: "import exploded", status: 1)
    end
  end

  def build_project(env, runtime: SiloMigrate::Runtime::Fake.new)
    output = StringIO.new
    project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: output)
    project.init("acme")
    dump = write(File.join(project.project_path("acme"), "dumps", "initial", "dump.sql"), "-- MySQL dump\nCREATE TABLE t (id int);\n")
    [project, SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: output), runtime, dump, output]
  end

  def test_init_writes_versioned_credential_free_state
    with_tmp_base do |_dir, env|
      project, = build_project(env)
      state_path = File.join(project.project_path("acme"), ".silo-migrate", "workflow.json")
      state = JSON.parse(File.read(state_path))

      assert_equal 1, state.fetch("version")
      assert_equal "empty", state.dig("phases", "initial", "state")
      assert_equal "initial", state.dig("converter", "active_source")
      refute_includes File.read(state_path), "migration_password"
    end
  end

  def test_second_import_is_blocked_without_streaming_bytes
    with_tmp_base do |_dir, env|
      _project, importer, runtime, = build_project(env)
      importer.import_dump("acme", "initial", file: "dump.sql", report_progress: false)
      first_streams = runtime.operations.count { |operation| operation.first == :run_with_stdin }

      error = assert_raises(SiloMigrate::UsageError) do
        importer.import_dump("acme", "initial", file: "dump.sql", report_progress: false)
      end

      assert_includes error.message, "reset-db acme initial --yes"
      assert_equal first_streams, runtime.operations.count { |operation| operation.first == :run_with_stdin }
      state = SiloMigrate::WorkflowStore.new("acme", env: env, runtime: runtime).read
      assert_equal "ready", state.dig("phases", "initial", "state")
      assert_match(/\A[0-9a-f]{64}\z/, state.dig("phases", "initial", "import", "sha256"))
    end
  end

  def test_failed_stream_marks_database_dirty
    with_tmp_base do |_dir, env|
      runtime = FailedImportRuntime.new
      _project, importer, = build_project(env, runtime: runtime)

      assert_raises(SiloMigrate::UsageError) do
        importer.import_dump("acme", "initial", file: "dump.sql", report_progress: false)
      end
      state = SiloMigrate::WorkflowStore.new("acme", env: env, runtime: runtime).read
      assert_equal "dirty", state.dig("phases", "initial", "state")
    end
  end

  def test_reset_archives_lineage_artifacts_but_preserves_inputs_and_backups
    with_tmp_base do |_dir, env|
      project, importer, runtime, dump, = build_project(env)
      importer.import_dump("acme", "initial", file: "dump.sql", report_progress: false)
      root = project.project_path("acme")
      sqlite = write(File.join(root, "output", "custom.db"), "SQLite format 3\0payload", mode: "wb")
      write(File.join(root, "output", "uploads.sqlite3"), "uploads")
      backup = write(File.join(root, "output", "discourse-backups", "final.tar.gz"), "backup")
      schema = write(File.join(root, "schema", "initial", "summary.json"), "{}")
      store = SiloMigrate::WorkflowStore.new("acme", env: env, runtime: runtime)
      store.update do |state|
        generation = state.dig("phases", "initial", "generation")
        state.fetch("converter").merge!(
          "output_db" => "output/custom.db",
          "output_lineage" => { "phase" => "initial", "generation" => generation }
        )
      end

      importer.replace_dump("acme", "initial", yes: true)

      assert File.exist?(dump)
      assert File.exist?(backup)
      refute File.exist?(sqlite)
      refute File.exist?(schema)
      manifest = Dir[File.join(root, "history", "*", "manifest.json")].first
      refute_nil manifest
      moved = JSON.parse(File.read(manifest)).fetch("moved")
      assert_includes moved, "output/custom.db"
      assert_includes moved, "schema/initial"
      assert_equal "empty", store.read.dig("phases", "initial", "state")
    end
  end

  def test_interrupted_import_is_reconciled_to_dirty
    with_tmp_base do |_dir, env|
      _project, _importer, runtime, = build_project(env)
      store = SiloMigrate::WorkflowStore.new("acme", env: env, runtime: runtime)
      store.update { |state| state.dig("phases", "initial")["state"] = "importing" }

      assert_equal "dirty", store.read.dig("phases", "initial", "state")
    end
  end

  def test_live_import_pid_survives_reads_and_blocks_reset_while_dead_pid_reconciles_dirty
    with_tmp_base do |_dir, env|
      _project, importer, = build_project(env)
      store = SiloMigrate::WorkflowStore.new("acme", env: env)
      store.update { |state| state.dig("phases", "initial").merge!("state" => "importing", "import_pid" => Process.pid) }

      assert_equal "importing", store.read.dig("phases", "initial", "state")
      error = assert_raises(SiloMigrate::UsageError) { importer.replace_dump("acme", "initial", yes: true) }
      assert_includes error.message, "currently running"

      dead = Process.spawn("true")
      Process.wait(dead)
      store.update { |state| state.dig("phases", "initial").merge!("state" => "importing", "import_pid" => dead) }

      assert_equal "dirty", store.read.dig("phases", "initial", "state")
    end
  end

  def test_arbitrary_converter_command_runs_untracked_while_default_run_is_gated
    with_tmp_base do |_dir, env|
      project, = build_project(env)

      project.run_converter("acme", command: ["bundle", "install"])
      state = SiloMigrate::WorkflowStore.new("acme", env: env).read
      assert_nil state.dig("converter", "output_lineage")
      assert_equal "pristine", state.dig("discourse", "state")

      error = assert_raises(SiloMigrate::UsageError) { project.run_converter("acme") }
      assert_includes error.message, "Converter source initial is empty"
    end
  end

  def test_live_nonempty_database_becomes_untracked_and_sends_no_dump_bytes
    with_tmp_base do |_dir, env|
      runtime = NonEmptyRuntime.new
      _project, importer, = build_project(env, runtime: runtime)

      error = assert_raises(SiloMigrate::UsageError) do
        importer.import_dump("acme", "initial", file: "dump.sql", report_progress: false)
      end
      assert_includes error.message, "contains 2 user table(s)"
      refute runtime.operations.any? { |operation| operation.first == :run_with_stdin }
      state = SiloMigrate::WorkflowStore.new("acme", env: env, runtime: runtime).read
      assert_equal "untracked", state.dig("phases", "initial", "state")
    end
  end

  def test_legacy_marker_is_migrated_and_stopped_unmarked_phase_is_unknown
    with_tmp_base do |_dir, env|
      project, _importer, runtime, dump, = build_project(env)
      root = project.project_path("acme")
      marker = { file: File.basename(dump), size: File.size(dump), imported_at: "2026-08-25T00:00:00Z" }
      write(File.join(root, "dumps", "initial", ".imported.json"), JSON.pretty_generate(marker))
      FileUtils.rm_rf(File.join(root, ".silo-migrate"))
      runtime.running_containers["acme_final_mariadb"] = false

      state = SiloMigrate::WorkflowStore.new("acme", env: env, runtime: runtime).read
      assert_equal "ready", state.dig("phases", "initial", "state")
      assert_equal true, state.dig("phases", "initial", "import", "legacy_marker")
      assert_equal "unknown", state.dig("phases", "final", "state")
    end
  end
end

class ConverterOutputTest < SiloMigrateTest
  def test_discovers_and_persists_the_sole_custom_sqlite_database
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      root = project.init("acme")
      custom = write(File.join(root, "output", "nested", "converted.sqlite"), "SQLite format 3\0payload", mode: "wb")
      write(File.join(root, "output", "uploads.sqlite3"), "SQLite format 3\0uploads", mode: "wb")

      resolver = SiloMigrate::ConverterOutput.new("acme", env: env)
      assert_equal custom, resolver.selected_path
      assert_equal "output/nested/converted.sqlite", SiloMigrate::WorkflowStore.new("acme", env: env).read.dig("converter", "output_db")
      assert_raises(SiloMigrate::UsageError) { resolver.select!("../outside.db") }
    end
  end
end

class PortValidatorTest < SiloMigrateTest
  def test_reports_duplicate_and_occupied_ports_with_suggestions
    availability = ->(port) { port == 4002 }
    validator = SiloMigrate::PortValidator.new(availability: availability)

    duplicate = assert_raises(SiloMigrate::UsageError) { validator.validate!(4000, label: "Final", used: { "initial" => 4000 }) }
    assert_includes duplicate.message, "suggested free port: 4002"
    occupied = assert_raises(SiloMigrate::UsageError) { validator.validate!(4001, label: "Initial") }
    assert_includes occupied.message, "suggested free port: 4002"
  end
end

class ProjectPortSelectionTest < SiloMigrateTest
  def test_init_auto_picks_free_default_port_but_rejects_explicit_conflicts
    with_tmp_base do |_dir, env|
      env = env.merge("SILO_MIGRATE_SKIP_PORT_CHECK" => "0")
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out)

      project.stub(:port_available?, ->(port) { port >= 3309 }) do
        project.init("acme")
        assert_equal "3309", SiloMigrate::Project.load_config("acme", env)["INITIAL_PORT"]
        assert_includes out.string, "selected free port 3309"

        error = assert_raises(SiloMigrate::UsageError) { project.init("beta", initial_port: 3307) }
        assert_includes error.message, "already in use"
      end
    end
  end
end

class DiscourseWorkflowStateTest < SiloMigrateTest
  def test_restore_and_import_are_one_shot_until_confirmed_reset
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      root = project.init("acme")
      docker_root = File.join(dir, "discourse")
      write(File.join(docker_root, "launcher"), "#!/bin/sh\n")
      File.chmod(0o755, File.join(docker_root, "launcher"))
      service = SiloMigrate::Services::DiscourseService.new(runtime: runtime, env: env, output: StringIO.new)
      service.setup("acme", docker_path: docker_root)
      backup = write(File.join(dir, "baseline.tar.gz"), "backup")
      service.restore_import("acme", backup: backup)

      copy_count = runtime.commands.count { |entry| entry[0] == :run && entry[1][0, 2] == ["docker", "cp"] }
      error = assert_raises(SiloMigrate::UsageError) { service.restore_import("acme", backup: backup) }
      assert_includes error.message, "reset-import acme --yes"
      assert_equal copy_count, runtime.commands.count { |entry| entry[0] == :run && entry[1][0, 2] == ["docker", "cp"] }

      selected = write(File.join(root, "output", "intermediate.db"), "SQLite format 3\0payload", mode: "wb")
      final_backup = write(File.join(root, "output", "discourse-backups", "final.tar.gz"), "final")
      service.import("acme", no_uploads_db: true)
      assert_raises(SiloMigrate::UsageError) { service.import("acme", no_uploads_db: true) }

      service.reset_import("acme", yes: true)
      assert File.exist?(selected)
      assert File.exist?(final_backup)
      state = SiloMigrate::WorkflowStore.new("acme", env: env, runtime: runtime).read
      assert_equal "pristine", state.dig("discourse", "state")
      assert runtime.commands.any? { |entry| entry[0] == :run && entry[1][0, 3] == ["./launcher", "rebuild", "acme-import"] }
    end
  end
end
