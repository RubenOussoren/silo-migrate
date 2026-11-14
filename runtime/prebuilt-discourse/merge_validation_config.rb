# frozen_string_literal: true

# RUBYOPT=-r hook for ONE isolated validation process, not a running app. It
# refuses missing private context rather than falling back to the owner's config.
require "json"

module SiloMergeValidationConfig
  module_function

  def read_context(path)
    File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
      stat = file.stat
      raise "invalid" unless stat.file? && [0, Process.uid].include?(stat.uid) && (stat.mode & 0o077).zero? && stat.size <= 256 * 1024
      value = JSON.parse(file.read(256 * 1024 + 1))
      raise "invalid" unless value.is_a?(Hash)
      %w[source base role].each do |key|
        prefix = { "source" => "silo_val_s_", "base" => "silo_val_b_", "role" => "silo_val_r_" }.fetch(key)
        raise "invalid" unless value[key].is_a?(String) && value[key].match?(/\A#{prefix}[0-9a-f]{32}\z/)
      end
      raise "invalid" unless value["source"].delete_prefix("silo_val_s_") == value["base"].delete_prefix("silo_val_b_") && value["source"].delete_prefix("silo_val_s_") == value["role"].delete_prefix("silo_val_r_")
      raise "invalid" unless value["password"].is_a?(String) && value["password"].match?(/\A[0-9a-f]{64}\z/)
      raise "invalid" unless value["host"].is_a?(String) && value["host"].match?(/\A[a-zA-Z0-9_.-]{1,128}\z/) && value["port"].is_a?(Integer) && value["port"].between?(1, 65535)
      # A dedicated Redis instance is mandatory until Rails boot is proved not to
      # mutate it. A namespace alone does not isolate FLUSHDB / global keys.
      raise "invalid" unless value["redis_isolated"] == true && value["redis_host"].is_a?(String) && value["redis_host"].match?(/\A[a-zA-Z0-9_.-]{1,128}\z/) && value["redis_port"].is_a?(Integer) && value["redis_port"].between?(1, 65535)
      value
    end
  rescue StandardError
    raise "STANDARD_MERGE_VALIDATION_CONFIG", cause: nil
  end

  def build!(context)
    original = context.fetch("original_config_path")
    target = context.fetch("validation_config_path")
    raise "invalid" unless original.is_a?(String) && target.is_a?(String) && File.dirname(target) == File.dirname(ENV.fetch("SILO_MERGE_VALIDATION_CONTEXT")) && File.basename(target) == "discourse-validation.conf"
    lines = File.open(original, File::RDONLY | File::NOFOLLOW) do |file|
      stat = file.stat
      raise "invalid" unless stat.file? && [0, Process.uid].include?(stat.uid) && (stat.mode & 0o022).zero? && stat.size <= 256 * 1024
      file.read(256 * 1024 + 1).lines
    end
    # Drop all inherited database/Redis settings, not just a guessed subset.
    lines.reject! { |line| line.match?(/\A\s*(?:db_|redis_|message_bus_redis_)[a-z_]*\s*=/) }
    overrides = { "db_host" => context.fetch("host"), "db_port" => context.fetch("port"), "db_name" => context.fetch("base"), "db_username" => context.fetch("role"),
                  "db_password" => context.fetch("password"), "redis_host" => context.fetch("redis_host"), "redis_port" => context.fetch("redis_port"),
                  "redis_db" => 0, "redis_namespace" => context.fetch("role"), "message_bus_redis_enabled" => false }
    bytes = lines.join + "\n" + overrides.map { |key, value| "#{key} = '#{value}'\n" }.join
    if File.exist?(target) || File.symlink?(target)
      File.open(target, File::RDONLY | File::NOFOLLOW) do |file|
        stat = file.stat
        raise "invalid" unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size == bytes.bytesize && file.read(bytes.bytesize + 1) == bytes
      end
    else
      File.open(target, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |file| file.write(bytes); file.flush; file.fsync }
    end
    target
  rescue StandardError
    raise "STANDARD_MERGE_VALIDATION_CONFIG", cause: nil
  end

  # Keep this override testable against the pinned core's exact keyword API.
  module GlobalSettingOverride
    def configure!(**options)
      super(**options.merge(path: ENV.fetch("SILO_MERGE_VALIDATION_CONFIG")))
    end
  end

  # libpq accepts conninfo strings and aliases its constructors. Only explicit
  # hash options for one of our two clone names may reach ANY constructor.
  def connection_options!(args, kwargs, context)
    unless args.is_a?(Array) && kwargs.is_a?(Hash) &&
        (args.empty? || (args.size == 1 && args.first.is_a?(Hash) && kwargs.empty?))
      raise "STANDARD_MERGE_VALIDATION_CONFIG", cause: nil
    end
    input = args.empty? ? kwargs : args.first
    unless input.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) } && input.keys.map(&:to_sym).uniq.size == input.size
      raise "STANDARD_MERGE_VALIDATION_CONFIG", cause: nil
    end
    options = input.transform_keys(&:to_sym)
    # PG's normal nested new -> connect_start path adds a resolved hostaddr.
    # Strip it (and service/credential-file indirections) rather than trusting
    # any caller-supplied route; libpq must resolve our exact bound host again.
    %i[hostaddr service servicefile passfile].each { |key| options.delete(key) }
    unless [context.fetch("source"), context.fetch("base")].include?(options[:dbname])
      raise "STANDARD_MERGE_VALIDATION_CONFIG", cause: nil
    end
    options.merge(host: context.fetch("host"), port: context.fetch("port"), user: context.fetch("role"), password: context.fetch("password"))
  rescue StandardError
    raise "STANDARD_MERGE_VALIDATION_CONFIG", cause: nil
  end

  def install_connection_guards!(pg, context)
    constructors = %i[connect open connect_start sync_connect async_connect setdb setdblogin]
    [[pg, constructors], [pg.const_get(:Connection), [:new, *constructors]]].each do |target, names|
      guard = Module.new
      names.select { |name| target.respond_to?(name) }.each do |name|
        guard.define_method(name) do |*args, **kwargs, &block|
          options = SiloMergeValidationConfig.connection_options!(args, kwargs, context)
          super(**options, &block)
        rescue StandardError
          raise "STANDARD_MERGE_VALIDATION_CONFIG", cause: nil
        end
      end
      target.singleton_class.prepend(guard)
    end
  end

  def install!
    context = read_context(ENV.fetch("SILO_MERGE_VALIDATION_CONTEXT"))
    target = build!(context)
    # Eliminate inherited owner overrides; GlobalSetting's file is authoritative.
    ENV.keys.grep(/\A(?:DISCOURSE_DB_|DISCOURSE_REDIS_|DISCOURSE_MESSAGE_BUS_REDIS_|PG|DATABASE_URL\z)/).each { |key| ENV.delete(key) }
    ENV["DB_NAME"] = context.fetch("source")
    ENV["DISCOURSE_DB_NAME"] = context.fetch("base")
    ENV["SILO_MERGE_VALIDATION_CONFIG"] = target
    require "pg"
    install_connection_guards!(PG, context)
    require "/var/www/discourse/app/models/global_setting"
    GlobalSetting.singleton_class.prepend(GlobalSettingOverride)
  rescue Exception
    # Fixed text only. Exception causes/PG messages may contain credentials.
    abort "STANDARD_MERGE_VALIDATION_CONFIG"
  end
end

SiloMergeValidationConfig.install! unless ENV["SILO_MERGE_VALIDATION_CONFIG_TEST"] == "1"
