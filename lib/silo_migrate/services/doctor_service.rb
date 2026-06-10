# frozen_string_literal: true

module SiloMigrate
  module Services
    # Environment preflight for new machines: checks the toolchain and Docker
    # before a user hits failures halfway through a migration. Docker/git
    # probes go through the runtime contract so the fake runtime can exercise
    # this service without Docker.
    class DoctorService
      MIN_RUBY_VERSION = Gem::Version.new("3.1.0")

      def initialize(runtime: Runtime::Docker.new, env: ENV, output: $stdout)
        @runtime = runtime
        @env = env
        @output = output
      end

      # Prints all checks and returns true when no required check failed.
      def run
        checks = [
          ruby_check,
          bundler_check,
          gem_check("sqlite3", why: "required to summarize converter output (intermediate.db)"),
          gem_check("tty-prompt", optional: true, why: "nicer interactive prompts (falls back to plain input)"),
          docker_check,
          compose_check,
          git_check,
          base_path_check
        ]

        checks.each { |check| print_check(check) }
        failures = checks.count { |check| !check[:ok] && !check[:optional] }
        if failures.zero?
          @output.puts "\n[OK] Environment looks ready."
          @output.puts "     Get started with: silo-migrate (guided mode) or silo-migrate init CUSTOMER --db-type mariadb"
        else
          @output.puts "\n[WARN] #{failures} required check(s) failed. Fix the items above, then re-run 'silo-migrate doctor'."
        end
        failures.zero?
      end

      private

      def print_check(check)
        marker = if check[:ok]
                   "[OK]  "
                 else
                   check[:optional] ? "[WARN]" : "[FAIL]"
                 end
        @output.puts "#{marker} #{check[:name]}: #{check[:detail]}"
        @output.puts "       Fix: #{check[:fix]}" if !check[:ok] && check[:fix]
      end

      def ruby_check
        version = Gem::Version.new(RUBY_VERSION)
        {
          name: "Ruby",
          ok: version >= MIN_RUBY_VERSION,
          detail: RUBY_VERSION,
          fix: "install Ruby >= #{MIN_RUBY_VERSION} (e.g. via rbenv, asdf, or Homebrew)"
        }
      end

      def bundler_check
        require "bundler"
        { name: "Bundler", ok: true, detail: Bundler::VERSION }
      rescue LoadError
        { name: "Bundler", ok: false, detail: "not installed", fix: "gem install bundler && bundle install" }
      end

      def gem_check(name, why:, optional: false)
        require name
        { name: "Gem #{name}", ok: true, optional: optional, detail: "available" }
      rescue LoadError
        {
          name: "Gem #{name}",
          ok: false,
          optional: optional,
          detail: "not available - #{why}",
          fix: "bundle install (or gem install #{name})"
        }
      end

      def docker_check
        result = @runtime.run(["docker", "version", "--format", "{{.Server.Version}}"], capture: true, timeout: 10)
        if result.success?
          version = result.stdout.strip
          { name: "Docker daemon", ok: true, detail: version.empty? ? "running" : "running (server #{version})" }
        else
          { name: "Docker daemon", ok: false, detail: "not reachable", fix: "start Docker Desktop (macOS) or the docker service (Linux)" }
        end
      rescue UsageError => e
        { name: "Docker daemon", ok: false, detail: e.message.lines.first.to_s.strip, fix: "install Docker: https://docs.docker.com/get-docker/" }
      end

      def compose_check
        result = @runtime.run(["docker", "compose", "version"], capture: true, timeout: 10)
        if result.success?
          { name: "Docker Compose v2", ok: true, detail: result.stdout.strip.empty? ? "available" : result.stdout.strip }
        else
          { name: "Docker Compose v2", ok: false, detail: "not available", fix: "upgrade Docker; 'docker compose' (v2 plugin) is required" }
        end
      rescue UsageError
        { name: "Docker Compose v2", ok: false, detail: "not available", fix: "install Docker with the compose plugin" }
      end

      def git_check
        result = @runtime.run(["git", "--version"], capture: true, timeout: 10)
        if result.success?
          { name: "Git", ok: true, detail: result.stdout.strip.empty? ? "available" : result.stdout.strip }
        else
          { name: "Git", ok: false, detail: "not available", fix: "install git (required for setup-converter)" }
        end
      rescue UsageError
        { name: "Git", ok: false, detail: "not available", fix: "install git (required for setup-converter)" }
      end

      def base_path_check
        unless Project.base_path_configured?(@env)
          return {
            name: "Base path",
            ok: false,
            detail: "not configured",
            fix: "run 'silo-migrate' once (first-run prompt) or export SILO_MIGRATE_BASE_PATH=/path/to/customers"
          }
        end

        path = Project.base_path(@env)
        if Dir.exist?(path) && !File.writable?(path)
          { name: "Base path", ok: false, detail: "#{path} (not writable)", fix: "choose a writable directory via SILO_MIGRATE_BASE_PATH" }
        else
          detail = Dir.exist?(path) ? path : "#{path} (will be created on first init)"
          { name: "Base path", ok: true, detail: detail }
        end
      end
    end
  end
end
