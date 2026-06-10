# frozen_string_literal: true

require "yaml"

module SiloMigrate
  class ComposeGenerator
    def initialize(env: ENV)
      @env = env
    end

    def generate(customer, config)
      project_path = Project.project_path(customer, @env)
      compose = compose_hash(customer, config, project_path)
      path = File.join(project_path, "docker-compose.yml")
      Project.atomic_write(path, YAML.dump(compose))
      path
    end

    def compose_hash(customer, config, project_path = Project.project_path(customer, @env))
      initial_type = config["INITIAL_DB_TYPE"] || "mariadb"
      final_type = config["FINAL_DB_TYPE"].to_s

      services = {}
      services["initial-db"] = db_service(
        initial_type,
        customer,
        "initial",
        config["INITIAL_PORT"] || DATABASE_TYPES.fetch("mariadb")[:default_port],
        config["INITIAL_DB_NAME"] || config["DB_NAME"] || "#{customer}_initial_db",
        config["INITIAL_DB_PASSWORD"] || config["DB_PASSWORD"] || DEFAULT_PASSWORD,
        config["TMPFS_SIZE"]
      ) if DATABASE_TYPES.key?(initial_type)

      if !final_type.empty? && !config["FINAL_PORT"].to_s.empty? && DATABASE_TYPES.key?(final_type)
        services["final-db"] = db_service(
          final_type,
          customer,
          "final",
          config["FINAL_PORT"],
          config["FINAL_DB_NAME"] || "#{customer}_final_db",
          config["FINAL_DB_PASSWORD"] || config["INITIAL_DB_PASSWORD"] || config["DB_PASSWORD"] || DEFAULT_PASSWORD,
          config["TMPFS_SIZE"]
        )
      end

      if Dir.exist?(File.join(project_path, "discourse-converters"))
        services["converter"] = {
          "container_name" => "#{customer}_converter",
          "profiles" => ["converter", "all"],
          "build" => { "context" => "./discourse-converters", "dockerfile" => "Dockerfile" },
          "restart" => "unless-stopped",
          "working_dir" => "/converters",
          "volumes" => [
            "./discourse-converters:/converters:rw",
            "./output:/converters/output:rw",
            "./uploads:/uploads:rw"
          ],
          "networks" => ["migration_network"]
        }
      end

      {
        "services" => services,
        "networks" => { "migration_network" => { "driver" => "bridge" } }
      }
    end

    def db_service(db_type, customer, phase, port, db_name, password, tmpfs_size = nil)
      type = DATABASE_TYPES.fetch(db_type)
      env_vars = type[:env_vars].transform_values do |value|
        value.gsub("{password}", password.to_s).gsub("{db_name}", db_name.to_s)
      end

      service = {
        "container_name" => "#{customer}_#{phase}_#{db_type}",
        "image" => type[:image],
        "profiles" => ["#{phase}-db", "all"],
        "restart" => "unless-stopped",
        "environment" => env_vars,
        "ports" => ["127.0.0.1:#{port}:#{type[:internal_port]}"],
        "networks" => ["migration_network"],
        "healthcheck" => {
          "test" => ["CMD-SHELL", type[:healthcheck_cmd].gsub("{db_name}", db_name.to_s)],
          "interval" => "10s",
          "timeout" => "5s",
          "retries" => 5
        }
      }

      if %w[mariadb mysql].include?(db_type)
        service["command"] = [
          "--character-set-server=utf8mb4",
          "--collation-server=utf8mb4_unicode_ci",
          "--innodb-flush-log-at-trx-commit=0",
          "--innodb-flush-method=fsync",
          "--innodb-use-native-aio=0",
          "--innodb-doublewrite=0",
          "--innodb-buffer-pool-size=1G",
          "--max-allowed-packet=1G",
          "--net-buffer-length=1M"
        ]
        service["tmpfs"] = ["/var/lib/mysql:size=#{tmpfs_size}"] if tmpfs_size && !tmpfs_size.empty?
      elsif db_type == "postgres"
        service["environment"]["POSTGRES_INITDB_ARGS"] = "--encoding=UTF8 --locale=C.UTF-8"
      end

      service
    end
  end
end
