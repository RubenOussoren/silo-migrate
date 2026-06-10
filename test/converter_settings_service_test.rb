# frozen_string_literal: true

require_relative "test_helper"

class ConverterSettingsServiceTest < SiloMigrateTest
  FLAT_DEFAULTS = <<~YAML
    # MySQL connection settings
    database:
      host: "127.0.0.1"
      port: 3306
      username: "someuser"
      password: "defaultpw"
      database: "somedb"
      table_prefix: "vb_"
    import:
      uploads_base_path: "/uploads/initial"
  YAML

  NESTED_DEFAULTS = <<~YAML
    database:
      table_prefix: "phpbb_"
      type: mysql
      mysql:
        host: "127.0.0.1"
        port: 3306
        username: "root"
        password: "yourpassword"
        database: "yourdatabase"
      postgres:
        host: "127.0.0.1"
        port: 5432
        user: ""
        password: "yourpassword"
        dbname: "yourdatabase"
  YAML

  def setup_project(env, platform, defaults, db_type: "mariadb")
    project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
    project.init("acme", { db_type: db_type, password: "topsecret" })
    converter_dir = File.join(project.project_path("acme"), "discourse-converters")
    write(File.join(converter_dir, "Gemfile"), "source 'https://rubygems.org'\n")
    write(File.join(converter_dir, "convert"), "#!/usr/bin/env ruby\n")
    write(File.join(converter_dir, "converters", platform, "settings.yml"), defaults)
    project
  end

  def test_flat_shape_merges_container_connection_and_preserves_other_keys
    with_tmp_base do |_dir, env|
      setup_project(env, "vbulletin", FLAT_DEFAULTS)
      result = SiloMigrate::Services::ConverterSettingsService.new(env: env, output: StringIO.new).generate("acme", "vbulletin")

      assert_equal "/converter-settings/vbulletin.yml", result[:container_path]
      settings = YAML.safe_load(File.read(result[:host_path]))
      assert_equal "acme_initial_mariadb", settings.dig("database", "host")
      assert_equal 3306, settings.dig("database", "port")
      assert_equal "root", settings.dig("database", "username")
      assert_equal "topsecret", settings.dig("database", "password")
      assert_equal "vb_", settings.dig("database", "table_prefix")
      assert_equal "/uploads/initial", settings.dig("import", "uploads_base_path")
      assert_equal "600", format("%o", File.stat(result[:host_path]).mode & 0o777)
      assert File.exist?(File.join(File.dirname(result[:host_path]), "README.md"))
    end
  end

  def test_nested_shape_sets_engine_type_and_fills_matching_subsection
    with_tmp_base do |_dir, env|
      setup_project(env, "phpbb", NESTED_DEFAULTS)
      result = SiloMigrate::Services::ConverterSettingsService.new(env: env, output: StringIO.new).generate("acme", "phpbb")

      settings = YAML.safe_load(File.read(result[:host_path]))
      assert_equal "mysql", settings.dig("database", "type")
      assert_equal "acme_initial_mariadb", settings.dig("database", "mysql", "host")
      assert_equal "topsecret", settings.dig("database", "mysql", "password")
      assert_equal "phpbb_", settings.dig("database", "table_prefix")
    end
  end

  def test_nested_shape_with_postgres_project_uses_postgres_keys
    with_tmp_base do |_dir, env|
      setup_project(env, "phpbb", NESTED_DEFAULTS, db_type: "postgres")
      result = SiloMigrate::Services::ConverterSettingsService.new(env: env, output: StringIO.new).generate("acme", "phpbb")

      settings = YAML.safe_load(File.read(result[:host_path]))
      assert_equal "postgres", settings.dig("database", "type")
      assert_equal "acme_initial_postgres", settings.dig("database", "postgres", "host")
      assert_equal 5432, settings.dig("database", "postgres", "port")
      assert_equal "postgres", settings.dig("database", "postgres", "user")
      assert_equal "topsecret", settings.dig("database", "postgres", "password")
    end
  end

  def test_missing_settings_file_raises_actionable_error
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      error = assert_raises(SiloMigrate::UsageError) do
        SiloMigrate::Services::ConverterSettingsService.new(env: env, output: StringIO.new).generate("acme", "vbulletin")
      end
      assert_includes error.message, "no default settings.yml"
    end
  end

  def test_sql_server_platform_is_rejected_with_guidance
    with_tmp_base do |_dir, env|
      setup_project(env, "forza", "database:\n  dataserver: \"127.0.0.1\"\n  username: \"SA\"\n")
      error = assert_raises(SiloMigrate::UsageError) do
        SiloMigrate::Services::ConverterSettingsService.new(env: env, output: StringIO.new).generate("acme", "forza")
      end
      assert_includes error.message, "SQL Server"
      assert_includes error.message, "--settings"
    end
  end
end
