# frozen_string_literal: true

require "fileutils"
require "shellwords"

module SiloMigrate
  module Services
    class InstallService
      DEFAULT_REPO = "https://github.com/RubenOussoren/silo-migrate.git"
      DEFAULT_BRANCH = "main"
      EXECUTABLES = %w[silo-migrate migration-tool xml-to-sql].freeze

      def initialize(runtime: Runtime::Docker.new, env: ENV, output: $stdout, source_root: nil)
        @runtime = runtime
        @env = env
        @output = output
        @source_root = File.expand_path(source_root || env["SILO_MIGRATE_SOURCE_ROOT"] || SiloMigrate.root)
      end

      def self.install_dir(env)
        return env["SILO_MIGRATE_INSTALL_DIR"] unless env["SILO_MIGRATE_INSTALL_DIR"].to_s.empty?

        data_home = env["XDG_DATA_HOME"].to_s.empty? ? File.join(home(env), ".local", "share") : env["XDG_DATA_HOME"]
        File.join(data_home, "silo-migrate", "source")
      end

      def self.bin_dir(env)
        return env["SILO_MIGRATE_BIN_DIR"] unless env["SILO_MIGRATE_BIN_DIR"].to_s.empty?

        Process.uid.zero? ? "/usr/local/bin" : File.join(home(env), ".local", "bin")
      end

      def self.repo(env)
        env["SILO_MIGRATE_REPO"].to_s.empty? ? DEFAULT_REPO : env["SILO_MIGRATE_REPO"]
      end

      def self.branch(env)
        env["SILO_MIGRATE_BRANCH"].to_s.empty? ? DEFAULT_BRANCH : env["SILO_MIGRATE_BRANCH"]
      end

      def self.home(env)
        env["HOME"] || Dir.home
      end

      def self.write_shims(source_root, bin_dir)
        FileUtils.mkdir_p(bin_dir)
        EXECUTABLES.each do |name|
          path = File.join(bin_dir, name)
          File.write(path, shim_content(source_root, name))
          FileUtils.chmod(0o755, path)
        end
      end

      def self.shim_content(source_root, executable)
        <<~SH
          #!/usr/bin/env bash
          set -euo pipefail
          cd #{Shellwords.escape(File.expand_path(source_root))}
          exec bundle exec ruby bin/#{executable} "$@"
        SH
      end

      def self.path_contains?(env, dir)
        env["PATH"].to_s.split(File::PATH_SEPARATOR).include?(dir)
      end

      def self.path_hint(env)
        bin_dir = self.bin_dir(env)
        return nil if path_contains?(env, bin_dir)

        "Add #{bin_dir} to PATH, for example: export PATH=\"#{bin_dir}:$PATH\""
      end

      def self_update
        ensure_git_checkout!

        @output.puts "Updating #{@source_root}..."
        run!(["git", "pull", "--ff-only"], chdir: @source_root, timeout: 120)

        bin_dir = self.class.bin_dir(@env)
        run_installer!(bin_dir)
        @output.puts "[OK] silo-migrate #{VERSION} is ready."
        hint = self.class.path_hint(@env)
        @output.puts "[WARN] #{hint}" if hint
      end

      private

      def ensure_git_checkout!
        return if Dir.exist?(File.join(@source_root, ".git"))

        raise UsageError, "self-update requires a Git checkout. Install with script/install or set SILO_MIGRATE_SOURCE_ROOT to the managed checkout."
      end

      def run_installer!(bin_dir)
        installer = File.join(@source_root, "script", "install")
        run!(
          [
            installer,
            "--install-deps",
            "--install-dir", @source_root,
            "--bin-dir", bin_dir,
            "--repo", self.class.repo(@env),
            "--branch", self.class.branch(@env)
          ],
          chdir: @source_root,
          timeout: 1_200,
          capture: false
        )
      end

      def run!(cmd, chdir:, timeout:, capture: true)
        result = @runtime.run(cmd, chdir: chdir, capture: capture, timeout: timeout)
        return result if result.success?

        detail = [result.stderr, result.stdout].compact.join("\n").strip
        message = "Command failed: #{cmd.join(' ')}"
        message = "#{message}\n#{detail}" unless detail.empty?
        raise UsageError, message
      end
    end
  end
end
