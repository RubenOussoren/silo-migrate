# frozen_string_literal: true

require_relative "test_helper"

class ComposeGeneratorTest < SiloMigrateTest
  def test_generates_mariadb_initial_service
    with_tmp_base do |_dir, env|
      generator = SiloMigrate::ComposeGenerator.new(env: env)
      compose = generator.compose_hash("acme", {
        "INITIAL_DB_TYPE" => "mariadb",
        "INITIAL_PORT" => "3307",
        "INITIAL_DB_NAME" => "acme_initial_db",
        "INITIAL_DB_PASSWORD" => "secret"
      }, SiloMigrate::Project.project_path("acme", env))

      service = compose["services"]["initial-db"]
      assert_equal "mariadb:10.11", service["image"]
      assert_equal ["initial-db", "all"], service["profiles"]
      assert_equal ["127.0.0.1:3307:3306"], service["ports"]
      assert_equal "secret", service["environment"]["MYSQL_ROOT_PASSWORD"]
      assert_includes service["command"], "--innodb-flush-method=fsync"
      assert_includes service["command"], "--innodb-use-native-aio=0"
    end
  end

  def test_generates_mysql_postgres_and_converter_profiles
    with_tmp_base do |_dir, env|
      project_path = SiloMigrate::Project.project_path("acme", env)
      FileUtils.mkdir_p(File.join(project_path, "discourse-converters"))
      compose = SiloMigrate::ComposeGenerator.new(env: env).compose_hash("acme", {
        "INITIAL_DB_TYPE" => "mysql",
        "INITIAL_PORT" => "3308",
        "INITIAL_DB_NAME" => "in_db",
        "INITIAL_DB_PASSWORD" => "secret",
        "FINAL_DB_TYPE" => "postgres",
        "FINAL_PORT" => "5433",
        "FINAL_DB_NAME" => "out_db",
        "FINAL_DB_PASSWORD" => "secret2"
      }, project_path)

      assert_equal "mysql:8.0", compose["services"]["initial-db"]["image"]
      assert_equal "postgres:15", compose["services"]["final-db"]["image"]
      assert_equal ["final-db", "all"], compose["services"]["final-db"]["profiles"]
      assert_equal ["converter", "all"], compose["services"]["converter"]["profiles"]
    end
  end
end
