# frozen_string_literal: true

module SiloMigrate
  DEFAULT_BASE_PATH = "/migrations/customers"
  DEFAULT_DB_NAME = "forum_db"
  DEFAULT_PASSWORD = "migration_password"
  CUSTOMER_NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/

  DATABASE_TYPES = {
    "mariadb" => {
      display_name: "MariaDB 10.11",
      image: "mariadb:10.11",
      default_port: 3307,
      internal_port: 3306,
      extensions: [".sql", ".sql.gz"],
      env_vars: {
        "MYSQL_ROOT_PASSWORD" => "{password}",
        "MYSQL_DATABASE" => "{db_name}"
      },
      import_cmd: ["mysql", "-u", "root", "--default-character-set=utf8mb4"],
      password_env: "MYSQL_PWD",
      healthcheck_cmd: 'MYSQL_PWD="$$MYSQL_ROOT_PASSWORD" mysqladmin ping -h localhost'
    },
    "mysql" => {
      display_name: "MySQL 8.0",
      image: "mysql:8.0",
      default_port: 3308,
      internal_port: 3306,
      extensions: [".sql", ".sql.gz"],
      env_vars: {
        "MYSQL_ROOT_PASSWORD" => "{password}",
        "MYSQL_DATABASE" => "{db_name}"
      },
      import_cmd: ["mysql", "-u", "root", "--default-character-set=utf8mb4"],
      password_env: "MYSQL_PWD",
      healthcheck_cmd: 'MYSQL_PWD="$$MYSQL_ROOT_PASSWORD" mysqladmin ping -h localhost'
    },
    "postgres" => {
      display_name: "PostgreSQL 15",
      image: "postgres:15",
      default_port: 5432,
      internal_port: 5432,
      extensions: [".sql", ".sql.gz", ".dump"],
      env_vars: {
        "POSTGRES_PASSWORD" => "{password}",
        "POSTGRES_DB" => "{db_name}"
      },
      import_cmd: ["psql", "-U", "postgres", "--set=client_encoding=UTF8"],
      password_env: "PGPASSWORD",
      healthcheck_cmd: "pg_isready -U postgres -d {db_name}"
    }
  }.freeze

  DUMP_SIGNATURES = {
    "mysql8" => {
      markers: ["utf8mb4_0900", "caching_sha2_password", "MySQL dump 10.13"],
      recommended: "mysql",
      compatible: ["mysql"],
      notes: "MySQL 8.0+ dump detected. Use mysql container for native support."
    },
    "mysql5" => {
      markers: ["MySQL dump"],
      exclude_markers: ["utf8mb4_0900"],
      recommended: "mariadb",
      compatible: ["mysql", "mariadb"],
      notes: "MySQL 5.x dump detected. Compatible with both MySQL and MariaDB."
    },
    "mariadb" => {
      markers: ["MariaDB dump"],
      recommended: "mariadb",
      compatible: ["mariadb"],
      notes: "MariaDB dump detected."
    },
    "postgres" => {
      markers: ["PostgreSQL database dump", "pg_dump version"],
      recommended: "postgres",
      compatible: ["postgres"],
      notes: "PostgreSQL dump detected."
    }
  }.freeze

  MYSQL8_COLLATION_MAP = {
    "utf8mb4_0900_ai_ci" => "utf8mb4_unicode_ci",
    "utf8_0900_ai_ci" => "utf8_unicode_ci",
    "utf8mb4_0900_as_cs" => "utf8mb4_bin",
    "utf8_0900_as_cs" => "utf8_bin",
    "utf8mb4_0900_as_ci" => "utf8mb4_unicode_ci",
    "utf8_0900_as_ci" => "utf8_unicode_ci",
    "utf8mb4_0900_bin" => "utf8mb4_bin",
    "utf8mb4_de_pb_0900_ai_ci" => "utf8mb4_unicode_ci",
    "utf8mb4_de_pb_0900_as_cs" => "utf8mb4_bin",
    "utf8mb4_es_0900_ai_ci" => "utf8mb4_unicode_ci",
    "utf8mb4_es_0900_as_cs" => "utf8mb4_bin",
    "utf8mb4_es_trad_0900_ai_ci" => "utf8mb4_unicode_ci",
    "utf8mb4_es_trad_0900_as_cs" => "utf8mb4_bin",
    "utf8mb4_hr_0900_ai_ci" => "utf8mb4_unicode_ci",
    "utf8mb4_hr_0900_as_cs" => "utf8mb4_bin",
    "utf8mb4_ja_0900_as_cs" => "utf8mb4_bin",
    "utf8mb4_ja_0900_as_cs_ks" => "utf8mb4_bin",
    "utf8mb4_la_0900_ai_ci" => "utf8mb4_unicode_ci",
    "utf8mb4_la_0900_as_cs" => "utf8mb4_bin",
    "utf8mb4_ru_0900_ai_ci" => "utf8mb4_unicode_ci",
    "utf8mb4_ru_0900_as_cs" => "utf8mb4_bin",
    "utf8mb4_tr_0900_ai_ci" => "utf8mb4_unicode_ci",
    "utf8mb4_tr_0900_as_cs" => "utf8mb4_bin",
    "utf8mb4_vi_0900_ai_ci" => "utf8mb4_unicode_ci",
    "utf8mb4_vi_0900_as_cs" => "utf8mb4_bin",
    "utf8mb4_zh_0900_as_cs" => "utf8mb4_bin"
  }.freeze
end
