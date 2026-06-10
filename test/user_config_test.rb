# frozen_string_literal: true

require_relative "test_helper"

class UserConfigTest < SiloMigrateTest
  def test_path_prefers_explicit_override
    env = { "SILO_MIGRATE_USER_CONFIG" => "/tmp/custom.env" }
    assert_equal "/tmp/custom.env", SiloMigrate::UserConfig.path(env)
  end

  def test_path_uses_xdg_config_home
    env = { "XDG_CONFIG_HOME" => "/tmp/xdg" }
    assert_equal "/tmp/xdg/silo-migrate/config.env", SiloMigrate::UserConfig.path(env)
  end

  def test_load_returns_empty_hash_when_missing
    with_tmp_base do |_dir, env|
      assert_equal({}, SiloMigrate::UserConfig.load(env))
    end
  end

  def test_save_and_load_round_trip
    with_tmp_base do |_dir, env|
      file = SiloMigrate::UserConfig.save({ "SILO_MIGRATE_BASE_PATH" => "/tmp/projects" }, env)
      assert File.exist?(file)
      assert_equal "600", format("%o", File.stat(file).mode & 0o777)
      assert_equal "/tmp/projects", SiloMigrate::UserConfig.load(env)["SILO_MIGRATE_BASE_PATH"]
    end
  end

  def test_save_merges_existing_values
    with_tmp_base do |_dir, env|
      SiloMigrate::UserConfig.save({ "A" => "1" }, env)
      SiloMigrate::UserConfig.save({ "B" => "2" }, env)
      config = SiloMigrate::UserConfig.load(env)
      assert_equal "1", config["A"]
      assert_equal "2", config["B"]
    end
  end
end
