# frozen_string_literal: true

require "fileutils"

module SiloMigrate
  # User-level configuration stored outside any project, e.g. the base path
  # chosen during the interactive first run.
  module UserConfig
    module_function

    def path(env = ENV)
      explicit = env["SILO_MIGRATE_USER_CONFIG"]
      return explicit if explicit && !explicit.empty?

      config_home = env["XDG_CONFIG_HOME"]
      config_home = File.join(Dir.home, ".config") if config_home.nil? || config_home.empty?
      File.join(config_home, "silo-migrate", "config.env")
    end

    def load(env = ENV)
      file = path(env)
      return {} unless File.exist?(file)

      Project.read_env_file(file)
    end

    def save(values, env = ENV)
      file = path(env)
      merged = load(env).merge(values.transform_keys(&:to_s))
      Project.atomic_write(file, Project.env_file_content(merged))
      File.chmod(0o600, file)
      file
    end
  end
end
