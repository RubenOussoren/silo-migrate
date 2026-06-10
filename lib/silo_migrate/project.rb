# frozen_string_literal: true

require "fileutils"
require "tempfile"

module SiloMigrate
  module Project
    module_function

    def validate_customer_name!(name)
      return name if name.match?(CUSTOMER_NAME_PATTERN)

      raise UsageError, "Invalid customer name: #{name}. Must be 1-63 chars, alphanumeric with _ or -, starting with letter/number."
    end

    def base_path(env = ENV)
      resolved = resolve_base_path(env)
      return resolved if resolved

      raise UsageError, <<~MSG.strip
        No migration base path is configured (and the legacy default #{DEFAULT_BASE_PATH} is not writable).
        Fix one of:
          - run 'silo-migrate' (interactive mode) to choose a location on first run
          - export SILO_MIGRATE_BASE_PATH=/path/to/customers
          - add SILO_MIGRATE_BASE_PATH="/path/to/customers" to #{UserConfig.path(env)}
      MSG
    end

    def resolve_base_path(env = ENV)
      explicit = env["SILO_MIGRATE_BASE_PATH"]
      return explicit if explicit && !explicit.empty?

      configured = UserConfig.load(env)["SILO_MIGRATE_BASE_PATH"]
      return configured if configured && !configured.empty?

      return DEFAULT_BASE_PATH if Dir.exist?(DEFAULT_BASE_PATH) && File.writable?(DEFAULT_BASE_PATH)

      nil
    end

    def base_path_configured?(env = ENV)
      !resolve_base_path(env).nil?
    end

    def project_path(customer, env = ENV)
      File.join(base_path(env), customer)
    end

    def config_path(customer, env = ENV)
      File.join(project_path(customer, env), "config.env")
    end

    def load_config(customer, env = ENV)
      path = config_path(customer, env)
      raise UsageError, "Project not found: #{customer}\nRun 'init #{customer}' first." unless File.exist?(path)

      read_env_file(path)
    end

    def save_config(customer, config, env = ENV)
      atomic_write(config_path(customer, env), env_file_content(config))
    end

    def env_file_content(config)
      config.map do |key, value|
        escaped = value.to_s.gsub("\\", "\\\\\\").gsub('"', '\"')
        %(#{key}="#{escaped}"\n)
      end.join
    end

    def read_env_file(path)
      config = {}
      File.readlines(path, chomp: true).each do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        key, value = stripped.split("=", 2)
        next unless key && value

        value = value.strip
        if value.start_with?('"') && value.end_with?('"')
          value = value[1...-1].gsub('\"', '"').gsub("\\\\", "\\")
        elsif value.start_with?("'") && value.end_with?("'")
          value = value[1...-1]
        end
        config[key] = value
      end
      config
    end

    def atomic_write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      temp = Tempfile.new([File.basename(path), ".tmp"], File.dirname(path), encoding: "utf-8")
      begin
        temp.write(content)
        temp.close
        File.rename(temp.path, path)
      ensure
        temp.close! if temp && !temp.closed? && File.exist?(temp.path)
      end
    end

    def ensure_project_dirs(customer, env = ENV)
      base = project_path(customer, env)
      [
        File.join(base, "dumps", "initial"),
        File.join(base, "dumps", "final"),
        File.join(base, "output"),
        File.join(base, "uploads"),
        File.join(base, "shared")
      ].each { |dir| FileUtils.mkdir_p(dir) }
    end
  end
end
