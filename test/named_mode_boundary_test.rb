# frozen_string_literal: true

require_relative "test_helper"

class NamedModeBoundaryTest < SiloMigrateTest
  def with_named_marker
    with_tmp_base do |_dir, env|
      root = File.join(env.fetch("SILO_MIGRATE_BASE_PATH"), "synthetic")
      FileUtils.mkdir_p(File.join(root, ".silo-migrate", "named"))
      yield env, root
    end
  end

  def test_legacy_services_refuse_even_with_a_corrupt_named_marker
    with_named_marker do |env, root|
      write(File.join(root, ".silo-migrate", "named", "state.json"), "broken-private-sentinel")
      runtime = SiloMigrate::Runtime::Fake.new
      output = StringIO.new
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: output)
      [-> { service.init("synthetic") }, -> { service.start("synthetic") },
       -> { service.stop("synthetic") }, -> { service.status("synthetic") },
       -> { service.cleanup("synthetic", yes: true, force: true) },
       -> { SiloMigrate::WorkflowStore.new("synthetic", env: env) },
       -> { SiloMigrate::Services::HistoryService.new(env: env).list("synthetic") }].each do |operation|
        error = assert_raises(SiloMigrate::UsageError, &operation)
        assert_equal "NAMED_MODE_UNSUPPORTED", error.message
        assert_nil error.cause
      end
      assert_empty runtime.operations
      assert_empty output.string
      refute File.exist?(File.join(root, "config.env"))
      refute File.exist?(File.join(root, ".silo-migrate", "workflow.json"))
      assert Dir.exist?(root)
    end
  end

  def test_release_and_ai_refuse_before_creating_a_second_identity
    with_named_marker do |env, root|
      output = StringIO.new
      service = SiloMigrate::Services::ArtifactReleaseService.new(env: env, output: output)
      [-> { service.prepare("synthetic", source: "inputs/private", artifact_class: "fixture") },
       -> { service.approve("synthetic", id: "artifact-#{'a' * 32}", sha256: "a" * 64, bytes: 0) },
       -> { service.publish("synthetic") }, -> { service.status("synthetic") },
       -> { service.revoke("synthetic", id: "artifact-#{'a' * 32}") },
       -> { SiloMigrate::Services::AIWorkspaceService.new(env: env, output: output).prepare("synthetic") }].each do |operation|
        error = assert_raises(SiloMigrate::ReleaseError, &operation)
        assert_equal "RELEASE_NAMED_MODE_UNSUPPORTED", error.message
        assert_nil error.cause
      end
      assert_empty output.string
      refute File.exist?(File.join(root, ".silo-migrate", "releases"))
    end
  end

  def test_dangling_mode_marker_is_not_treated_as_legacy
    with_named_marker do |env, root|
      FileUtils.rmdir(File.join(root, ".silo-migrate", "named"))
      File.symlink("absent", File.join(root, ".silo-migrate", "named"))
      error = assert_raises(SiloMigrate::UsageError) { SiloMigrate::Project.load_config("synthetic", env) }
      assert_equal "NAMED_MODE_UNSUPPORTED", error.message
    end
  end

  def test_legacy_list_refuses_mixed_mode_before_reading_private_config
    with_named_marker do |env, root|
      write(File.join(root, "config.env"), 'INITIAL_DB_TYPE="private-sentinel"')
      output = StringIO.new
      service = SiloMigrate::Services::ProjectService.new(env: env, output: output)
      error = assert_raises(SiloMigrate::UsageError) { service.list }
      assert_equal "NAMED_MODE_UNSUPPORTED", error.message
      assert_empty output.string
    end
  end

  def test_unreadable_or_looping_authority_directory_is_not_treated_as_legacy
    with_named_marker do |env, root|
      authority = File.join(root, ".silo-migrate")
      begin
        File.chmod(0o000, authority)
        error = assert_raises(SiloMigrate::UsageError) { SiloMigrate::Project.project_path("synthetic", env) }
        assert_equal "NAMED_MODE_UNSUPPORTED", error.message
        error = assert_raises(SiloMigrate::ReleaseError) { SiloMigrate::ReleaseStore.new("synthetic", env: env) }
        assert_equal "RELEASE_NAMED_MODE_UNSUPPORTED", error.message
      ensure
        File.chmod(0o700, authority)
      end
    end
    with_tmp_base do |_dir, env|
      root = File.join(env.fetch("SILO_MIGRATE_BASE_PATH"), "synthetic")
      FileUtils.mkdir_p(root)
      File.symlink(".silo-migrate", File.join(root, ".silo-migrate"))
      error = assert_raises(SiloMigrate::UsageError) { SiloMigrate::Project.project_path("synthetic", env) }
      assert_equal "NAMED_MODE_UNSUPPORTED", error.message
    end
  end

  def test_named_cli_file_only_flow_never_calls_execution_adapters
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      SiloMigrate::Runtime::Fake.instance_methods(false).each do |method|
        runtime.define_singleton_method(method) { |*| raise "execution adapter must not be called" }
      end
      output, error = StringIO.new, StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: output, error: error)
      invoke = lambda do |*args|
        output.truncate(0)
        output.rewind
        assert_equal 0, cli.run(["named", *args]), error.string
        JSON.parse(output.string)
      end
      SiloMigrate::Runtime::Docker.stub(:new, -> { flunk "no Docker adapter" }) do
        SiloMigrate::Runtime::Silo.stub(:new, -> { flunk "no analyst/provider adapter" }) do
          invoke.call("init", "synthetic")
          source = invoke.call("source", "add", "synthetic", "--platform", "synthetic").fetch("source_id")
          dataset = invoke.call("dataset", "add", "synthetic", "--source", source).fetch("dataset_id")
          root = File.join(env.fetch("SILO_MIGRATE_BASE_PATH"), "synthetic")
          content = "-- synthetic opaque bytes; not executed\n"
          File.binwrite(File.join(root, "inputs", "fixture.sql"), content)
          invoke.call("input", "add", "synthetic", "--dataset", dataset, "--path", "inputs/fixture.sql",
                      "--sha256", Digest::SHA256.hexdigest(content), "--bytes", content.bytesize.to_s, "--type", "sql")
          run = invoke.call("plan", "validate-inputs", "synthetic", "--dataset", dataset).fetch("run_id")
          assert_equal "completed", invoke.call("run", "execute", "synthetic", run).fetch("status")
          assert_equal "completed", invoke.call("run", "show", "synthetic", run).fetch("status")
          assert_empty error.string
          refute File.exist?(File.join(root, ".silo-migrate", "releases"))
          refute File.exist?(File.join(root, "docker-compose.yml"))
          refute File.exist?(File.join(root, "config.env"))
        end
      end
    end
  end

  def test_legacy_cli_commands_refuse_named_workspace_without_runtime_execution
    with_named_marker do |env, _root|
      runtime = SiloMigrate::Runtime::Fake.new
      [%w[init synthetic], %w[start synthetic], %w[cleanup synthetic --yes --force],
       %w[release status synthetic], %w[ai prepare synthetic]].each do |argv|
        output, error = StringIO.new, StringIO.new
        cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: output, error: error)
        assert_equal 1, cli.run(argv)
        assert_empty output.string
        assert_match(/\AError: (?:RELEASE_)?NAMED_MODE_UNSUPPORTED\n\z/, error.string)
      end
      assert_empty runtime.operations
    end
  end
end
