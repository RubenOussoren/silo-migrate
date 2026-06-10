# frozen_string_literal: true

require_relative "test_helper"

class DoctorServiceTest < SiloMigrateTest
  class FailingDockerRuntime < SiloMigrate::Runtime::Fake
    def run(cmd, **kwargs, &block)
      if cmd[0, 2] == %w[docker version] || cmd[0, 2] == %w[docker compose]
        return SiloMigrate::Runtime::CommandResult.new(success?: false, stdout: "", stderr: "Cannot connect", status: 1)
      end

      super
    end
  end

  def test_doctor_passes_with_healthy_environment
    with_tmp_base do |_dir, env|
      FileUtils.mkdir_p(env["SILO_MIGRATE_BASE_PATH"])
      out = StringIO.new
      ok = SiloMigrate::Services::DoctorService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out).run

      assert ok
      assert_includes out.string, "Ruby"
      assert_includes out.string, "Docker daemon"
      assert_includes out.string, "Environment looks ready"
    end
  end

  def test_doctor_reports_docker_failure_with_fix
    with_tmp_base do |_dir, env|
      out = StringIO.new
      ok = SiloMigrate::Services::DoctorService.new(runtime: FailingDockerRuntime.new, env: env, output: out).run

      refute ok
      assert_includes out.string, "[FAIL] Docker daemon"
      assert_includes out.string, "start Docker"
      assert_includes out.string, "required check(s) failed"
    end
  end

  def test_doctor_flags_unconfigured_base_path
    Dir.mktmpdir do |dir|
      env = { "SILO_MIGRATE_USER_CONFIG" => File.join(dir, "missing.env") }
      out = StringIO.new
      ok = SiloMigrate::Services::DoctorService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out).run

      if Dir.exist?(SiloMigrate::DEFAULT_BASE_PATH) && File.writable?(SiloMigrate::DEFAULT_BASE_PATH)
        assert ok
      else
        refute ok
        assert_includes out.string, "[FAIL] Base path"
        assert_includes out.string, "SILO_MIGRATE_BASE_PATH"
      end
    end
  end

  def test_doctor_cli_command_exits_nonzero_on_failure
    with_tmp_base do |_dir, env|
      out = StringIO.new
      code = SiloMigrate::CLI.new(runtime: FailingDockerRuntime.new, env: env, output: out, error: StringIO.new).run(["doctor"])
      assert_equal 1, code

      ok_code = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new, error: StringIO.new).run(["doctor"])
      assert_equal 0, ok_code
    end
  end
end
