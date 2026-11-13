# frozen_string_literal: true

require "json"
require "shellwords"

module SiloMigrate
  module Services
    # One disposable local Discourse instance (web, Postgres, Redis, loopback proxy)
    # from the frozen prebuilt images. It has no host mounts: inputs arrive via
    # `docker cp` as independent copies, so a restored instance cannot silently
    # depend on the original input or upload stores.
    #
    # Web sits on an --internal network without a default route. Only the small
    # socat proxy is attached to a publishing network, bound to 127.0.0.1. Removal
    # acts only on exact recorded IDs whose ownership labels still match.
    class PrebuiltStack
      LABEL_MANAGED = "silo-migrate.managed"
      LABEL_INSTANCE = "silo-migrate.instance"
      ROLES = %w[db redis web proxy].freeze
      BOOT_TIMEOUT = 300
      DISCOURSE_ROOT = "/var/www/discourse"
      BUNDLE_ENV = ["env", "-u", "IMPORT", "-u", "DELTA_IMPORT", "-u", "MERGE_IMPORT",
                    "BUNDLE_WITH=generic_import", "RAILS_ENV=production",
                    "PGHOST=db", "PGUSER=discourse", "PGPORT=5432", "PGDATABASE=discourse"].freeze

      # The pinned web image's config/pitchfork.conf.rb starts supervised Sidekiq only
      # when ENV["UNICORN_SIDEKIQS"].to_i > 0; "0" leaves background jobs off.
      SIDEKIQS = %w[0 1].freeze
      DEFAULT_SIDEKIQS = "1"
      ENV_KEY = /\A[A-Z][A-Z0-9_]*\z/
      # The pinned discourse/postgres image's configure-postgres.sh writes DB_SHARED_BUFFERS
      # and DB_WORK_MEM into postgresql.conf; its official entrypoint passes `postgres -c`.
      DEFAULT_SHARED_BUFFERS = "128MB"
      DEFAULT_WORK_MEM = "8MB"
      SHARED_BUFFERS_MIB = (128..8192)
      MAINTENANCE_WORK_MEM_MIB = (64..2048)
      DEFAULT_DB_SHM = "128m"
      DB_SHM_MIB = (128..2048)

      attr_reader :name, :record

      def initialize(runtime:, lock:, name:, record: nil, sleeper: nil)
        @runtime = runtime
        @lock = lock
        @name = name
        @record = record || { "name" => name, "containers" => {}, "networks" => [], "volumes" => [], "state" => "absent" }
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      end

      # Yields after each owned resource is created so the caller can persist the
      # record durably before any fallible next step: every resource stays
      # removable even if this process dies mid-creation.
      def create!(hostname:, port:, env_file:, labels: {}, extra_env: {}, &progress)
        limits = @lock.fetch("limits").fetch("stack")
        images = @lock.fetch("images")
        # Refused before any resource exists.
        sidekiqs = extra_env.fetch("UNICORN_SIDEKIQS", DEFAULT_SIDEKIQS).to_s
        raise StandardWorkflowError.new("STANDARD_STACK_FAILED", "sidekiqs") unless SIDEKIQS.include?(sidekiqs)
        unless extra_env.all? { |key, value| key.is_a?(String) && key.match?(ENV_KEY) && !value.to_s.match?(/[\r\n\0]/) }
          raise StandardWorkflowError.new("STANDARD_STACK_FAILED", "environment")
        end
        db_env, db_command, db_shm = db_settings(limits.fetch("db"))
        label_args = labels.merge(LABEL_MANAGED => "true", LABEL_INSTANCE => @name)
                           .flat_map { |key, value| ["--label", "#{key}=#{value}"] }
        record["port"] = port
        record["hostname"] = hostname
        record["state"] = "creating"
        progress&.call(record)

        internal = "#{@name}-int"
        published = "#{@name}-pub"
        refuse_existing!(internal, published)
        command!(["docker", "network", "create", "--internal", *label_args, internal], timeout: 30)
        record["networks"] << internal
        progress&.call(record)
        command!(["docker", "network", "create", *label_args, published], timeout: 30)
        record["networks"] << published
        progress&.call(record)

        %w[pg redis shared].each do |volume|
          full = "#{@name}-#{volume}"
          command!(["docker", "volume", "create", *label_args, full], timeout: 30)
          record["volumes"] << full
          progress&.call(record)
        end

        start_container("db", images.fetch("db").fetch("id"), limits.fetch("db"), label_args, [
          "--network", internal, "--network-alias", "db", "--shm-size", db_shm,
          "-v", "#{@name}-pg:/var/lib/postgresql", "--env-file", env_file, *db_env
        ], db_command, &progress)
        wait_for("database") { success?(["docker", "exec", container("db"), "pg_isready", "-U", "postgres"], timeout: 10) }

        start_container("redis", images.fetch("redis").fetch("id"), limits.fetch("redis"), label_args, [
          "--network", internal, "--network-alias", "redis", "-v", "#{@name}-redis:/data"
        ], [], &progress)

        start_container("web", images.fetch("web").fetch("id"), limits.fetch("web"), label_args, [
          "--network", internal, "--network-alias", "web", "--hostname", "#{hostname.tr('.', '-')}-web",
          "--shm-size", "256m", "-v", "#{@name}-shared:/shared",
          "-e", "DISCOURSE_DB_HOST=db", "--env-file", env_file,
          "-e", "DISCOURSE_REDIS_HOST=redis", "-e", "DISCOURSE_HOSTNAME=#{hostname}",
          "-e", "DISCOURSE_DEVELOPER_EMAILS=sandbox_admin@example.invalid",
          "-e", "DISCOURSE_SMTP_ADDRESS=smtp.invalid", "-e", "DISCOURSE_SMTP_PORT=25",
          *extra_env.reject { |key, _value| key == "UNICORN_SIDEKIQS" }.flat_map { |key, value| ["-e", "#{key}=#{value}"] },
          "-e", "DISCOURSE_DISABLE_EMAILS=yes", "-e", "UNICORN_WORKERS=1", "-e", "UNICORN_SIDEKIQS=#{sidekiqs}"
        ], [], &progress)

        start_container("proxy", images.fetch("web").fetch("id"), limits.fetch("proxy"), label_args, [
          "--network", published, "-p", "127.0.0.1:#{port}:8080", "--entrypoint", "socat"
        ], ["TCP-LISTEN:8080,fork,reuseaddr", "TCP:#{container('web')}:80"], &progress)
        command!(["docker", "network", "connect", internal, container("proxy")], timeout: 30)
        wait_for("Discourse web", timeout: BOOT_TIMEOUT, interval: 5) do
          http_status_in_web("/srv/status") == "200"
        end
        record["state"] = "running"
        progress&.call(record)
        record
      end

      def container(role)
        "#{@name}-#{role}"
      end

      # Values reach the script through the exec environment; pass secrets by
      # env_file so they are not in this process's arguments.
      def rails_runner(script_path, env: {}, env_file: nil, timeout: 300)
        inner = ["cd", DISCOURSE_ROOT, "&&", "exec", *BUNDLE_ENV, "bundle", "exec", "rails", "runner", Shellwords.escape(script_path)].join(" ")
        exec_args = env.flat_map { |key, value| ["-e", "#{key}=#{value}"] }
        exec_args += ["--env-file", env_file] if env_file
        result = @runtime.run(["docker", "exec", *exec_args, container("web"), "su", "discourse", "-c", inner], capture: true, timeout: timeout)
        lines = result.stdout.to_s.lines.grep(/\ASILO_JSON:/)
        unless result.success? && lines.length == 1
          raise StandardWorkflowError.new("STANDARD_RUNNER_FAILED", "#{File.basename(script_path)} failed")
        end

        JSON.parse(lines.first.delete_prefix("SILO_JSON:"))
      end

      def copy_in(host_path, guest_path, owner: "discourse:discourse")
        command!(["docker", "cp", host_path, "#{container('web')}:#{guest_path}"], timeout: 300)
        command!(["docker", "exec", container("web"), "chown", "-R", owner, guest_path], timeout: 60)
      end

      def copy_out(guest_path, host_path)
        command!(["docker", "cp", "#{container('web')}:#{guest_path}", host_path], timeout: 600)
      end

      def discourse_shell(args, env_password: true, timeout: 900, pin_cpu: false)
        prefix = BUNDLE_ENV.dup
        prefix << "PGPASSWORD=\"$DISCOURSE_DB_PASSWORD\"" if env_password
        inner = ["cd", DISCOURSE_ROOT, "&&", "exec", *prefix, *args.map { |arg| Shellwords.escape(arg) }].join(" ")
        @runtime.run(["docker", "exec", container("web"), *(pin_cpu ? ["taskset", "-c", "0"] : []), "su", "discourse", "-c", inner],
                     capture: true, timeout: timeout)
      end

      def web_exec(args, timeout: 60)
        @runtime.run(["docker", "exec", container("web"), *args], capture: true, timeout: timeout)
      end

      def db_query(sql, timeout: 60)
        @runtime.run(["docker", "exec", container("db"), "psql", "-U", "discourse", "-d", "discourse", "-Atc", sql], capture: true, timeout: timeout)
      end

      # true/false from recorded IDs and ownership labels; nil if Docker can't answer.
      def live?
        ids = record.fetch("containers").values
        return false unless record.fetch("containers").keys.sort == ROLES.sort

        result = @runtime.run(["docker", "inspect", "--format", "{{.State.Running}} {{index .Config.Labels \"#{LABEL_INSTANCE}\"}}", *ids], capture: true, timeout: 10)
        unless result.success?
          return false if result.stderr.to_s.match?(/no such|not found/i)

          return nil
        end
        rows = result.stdout.to_s.lines.map(&:split)
        rows.size == ids.size && rows.all? { |running, instance| running == "true" && instance == @name }
      end

      # Exact-ID removal only. Anything whose label no longer matches is refused
      # and reported rather than forced.
      def remove!
        problems = []
        record.fetch("containers").each_value do |id|
          next unless owned?("container", id, problems)

          removed = @runtime.run(["docker", "rm", "--force", "--volumes", id], capture: true, timeout: 120)
          problems << "container-remove" unless removed.success?
        end
        record.fetch("networks").each do |network|
          next unless owned?("network", network, problems)

          removed = @runtime.run(["docker", "network", "rm", network], capture: true, timeout: 60)
          problems << "network-remove" unless removed.success?
        end
        record.fetch("volumes").each do |volume|
          next unless owned?("volume", volume, problems)

          removed = @runtime.run(["docker", "volume", "rm", volume], capture: true, timeout: 60)
          problems << "volume-remove" unless removed.success?
        end
        raise StandardWorkflowError.new("STANDARD_CLEANUP_FAILED", problems.uniq.join(",")) unless problems.empty?

        record["state"] = "removed"
        record
      end

      private

      def refuse_existing!(*networks)
        taken = networks.any? { |network| @runtime.run(["docker", "network", "inspect", network], capture: true, timeout: 20).success? }
        taken ||= %w[pg redis shared].any? { |volume| @runtime.run(["docker", "volume", "inspect", "#{@name}-#{volume}"], capture: true, timeout: 20).success? }
        taken ||= ROLES.any? { |role| @runtime.run(["docker", "container", "inspect", container(role)], capture: true, timeout: 20).success? }
        raise StandardWorkflowError.new("STANDARD_STACK_FAILED", "name already in use") if taken
      end

      def owned?(kind, identity, problems)
        result = @runtime.run(["docker", kind, "inspect", "--format", "{{json .#{kind == 'container' ? 'Config.Labels' : 'Labels'}}}", identity], capture: true, timeout: 20)
        # Already gone (e.g. a partial creation or earlier reset) needs no action.
        return false if !result.success? && result.stderr.to_s.match?(/no such|not found/i)

        labels = result.success? ? (JSON.parse(result.stdout) rescue nil) : nil
        unless labels.is_a?(Hash) && labels[LABEL_INSTANCE] == @name && labels[LABEL_MANAGED] == "true"
          problems << "ownership-mismatch"
          return false
        end
        true
      end

      # Plan-bound numeric settings only; absent keys keep the legacy defaults and the
      # image's own command. Each must fit well inside the container's memory cap.
      def db_settings(limit)
        shared = limit["shared_buffers_mib"]
        maintenance = limit["maintenance_work_mem_mib"]
        shm = limit["shm_mib"]
        memory = limit.fetch("memory_mib")
        valid = (shared.nil? || (shared.is_a?(Integer) && SHARED_BUFFERS_MIB.cover?(shared) && shared <= memory / 4)) &&
                (maintenance.nil? || (maintenance.is_a?(Integer) && MAINTENANCE_WORK_MEM_MIB.cover?(maintenance) && maintenance <= memory / 8)) &&
                (shm.nil? || (shm.is_a?(Integer) && DB_SHM_MIB.cover?(shm) && shm <= memory / 8))
        raise StandardWorkflowError.new("STANDARD_STACK_FAILED", "db settings") unless valid

        env = ["-e", "DB_SHARED_BUFFERS=#{shared ? "#{shared}MB" : DEFAULT_SHARED_BUFFERS}", "-e", "DB_WORK_MEM=#{DEFAULT_WORK_MEM}"]
        [env, maintenance ? ["postgres", "-c", "maintenance_work_mem=#{maintenance}MB"] : [], shm ? "#{shm}m" : DEFAULT_DB_SHM]
      end

      def start_container(role, image, limit, label_args, options, command)
        name = container(role)
        result = @runtime.run([
          "docker", "run", "-d", "--pull=never", "--restart", "no", "--name", name, *label_args,
          "--cpus", limit.fetch("cpus").to_s, "--memory", "#{limit.fetch('memory_mib')}m",
          "--memory-swap", "#{limit.fetch('memory_mib')}m", "--pids-limit", limit.fetch("pids").to_s,
          "--log-opt", "max-size=8m", "--log-opt", "max-file=2",
          "--security-opt", "no-new-privileges", *options, image, *command
        ], capture: true, timeout: 60)
        raise StandardWorkflowError.new("STANDARD_STACK_FAILED", "create #{role}") unless result.success?

        id = result.stdout.to_s.strip
        raise StandardWorkflowError.new("STANDARD_STACK_FAILED", "id #{role}") unless id.match?(/\A[0-9a-f]{64}\z/)

        record.fetch("containers")[role] = id
        yield record if block_given?
        id
      end

      def http_status_in_web(path)
        result = @runtime.run(["docker", "exec", container("web"), "curl", "-s", "-o", "/dev/null", "-m", "5", "-w", "%{http_code}", "http://127.0.0.1#{path}"], capture: true, timeout: 15)
        result.success? ? result.stdout.to_s.strip : "000"
      end

      def wait_for(what, timeout: 60, interval: 2)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          return true if yield
          raise StandardWorkflowError.new("STANDARD_STACK_FAILED", "#{what} not ready") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          @sleeper.call(interval)
        end
      end

      def success?(cmd, timeout:)
        @runtime.run(cmd, capture: true, timeout: timeout).success?
      end

      def command!(cmd, timeout:)
        result = @runtime.run(cmd, capture: true, timeout: timeout)
        raise StandardWorkflowError.new("STANDARD_STACK_FAILED", cmd[1, 2].join(" ")) unless result.success?

        result
      end
    end
  end
end
