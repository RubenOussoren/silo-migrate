# frozen_string_literal: true

require_relative "test_helper"

class InstallServiceTest < SiloMigrateTest
  def test_self_update_pulls_and_runs_installer
    with_tmp_base do |dir, _env|
      source_root = File.join(dir, "source")
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(File.join(source_root, ".git"))
      env = {
        "HOME" => dir,
        "SILO_MIGRATE_BIN_DIR" => bin_dir
      }
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new

      SiloMigrate::Services::InstallService.new(
        runtime: runtime,
        env: env,
        output: out,
        source_root: source_root
      ).self_update

      assert_includes runtime.commands, [:run, ["git", "pull", "--ff-only"], source_root, true, 120, nil]
      assert_includes runtime.commands, [
        :run,
        [
          File.join(source_root, "script", "install"),
          "--install-deps",
          "--install-dir", source_root,
          "--bin-dir", bin_dir,
          "--repo", "https://github.com/RubenOussoren/silo-migrate.git",
          "--branch", "main"
        ],
        source_root,
        false,
        1_200,
        nil
      ]
      assert_includes out.string, "[OK] silo-migrate"
    end
  end

  def test_self_update_rejects_unmanaged_source_root
    Dir.mktmpdir do |dir|
      error = assert_raises(SiloMigrate::UsageError) do
        SiloMigrate::Services::InstallService.new(
          runtime: SiloMigrate::Runtime::Fake.new,
          env: { "HOME" => dir },
          output: StringIO.new,
          source_root: dir
        ).self_update
      end

      assert_includes error.message, "requires a Git checkout"
    end
  end

  def test_install_paths_respect_environment_overrides
    env = {
      "HOME" => "/home/example",
      "XDG_DATA_HOME" => "/data",
      "SILO_MIGRATE_INSTALL_DIR" => "/custom/source",
      "SILO_MIGRATE_BIN_DIR" => "/custom/bin",
      "SILO_MIGRATE_REPO" => "git@example.invalid:custom/repo.git",
      "SILO_MIGRATE_BRANCH" => "stable"
    }

    assert_equal "/custom/source", SiloMigrate::Services::InstallService.install_dir(env)
    assert_equal "/custom/bin", SiloMigrate::Services::InstallService.bin_dir(env)
    assert_equal "git@example.invalid:custom/repo.git", SiloMigrate::Services::InstallService.repo(env)
    assert_equal "stable", SiloMigrate::Services::InstallService.branch(env)
  end

  def test_default_repo_uses_https_for_fresh_machines
    assert_equal "https://github.com/RubenOussoren/silo-migrate.git", SiloMigrate::Services::InstallService.repo("HOME" => "/home/example")
  end
end
