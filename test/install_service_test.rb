# frozen_string_literal: true

require_relative "test_helper"
require "bundler"
require "open3"

class InstallServiceTest < SiloMigrateTest
  def test_self_update_pulls_and_runs_installer
    with_tmp_base do |dir, _env|
      source_root = File.join(dir, "source")
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(File.join(source_root, ".git"))
      env = {
        "HOME" => dir,
        "SILO_MIGRATE_BIN_DIR" => bin_dir
      }
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new

      SiloMigrate::Services::InstallService.new(
        runtime: runtime,
        env: env,
        output: out,
        source_root: source_root
      ).self_update

      assert_includes runtime.commands, [:run, ["git", "pull", "--ff-only"], source_root, true, 120, nil]
      assert_includes runtime.commands, [
        :run,
        [
          File.join(source_root, "script", "install"),
          "--install-deps",
          "--skip-docker",
          "--install-dir", source_root,
          "--bin-dir", bin_dir,
          "--repo", "https://github.com/RubenOussoren/silo-migrate.git",
          "--branch", "main"
        ],
        source_root,
        false,
        1_200,
        nil
      ]
      assert_includes out.string, "[OK] silo-migrate"
    end
  end

  def test_self_update_runs_installer_without_bundler_environment
    with_tmp_base do |dir, _env|
      source_root = File.join(dir, "source")
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(File.join(source_root, ".git"))
      env = {
        "HOME" => dir,
        "SILO_MIGRATE_BIN_DIR" => bin_dir
      }
      runtime = Class.new(SiloMigrate::Runtime::Fake) do
        attr_reader :installer_env

        def run(cmd, **kwargs)
          if cmd.first == File.join(kwargs.fetch(:chdir), "script", "install")
            @installer_env = {
              "BUNDLE_GEMFILE" => ENV["BUNDLE_GEMFILE"],
              "BUNDLE_BIN_PATH" => ENV["BUNDLE_BIN_PATH"],
              "RUBYOPT" => ENV["RUBYOPT"]
            }
          end

          super
        end
      end.new

      original_env = {
        "BUNDLE_GEMFILE" => ENV["BUNDLE_GEMFILE"],
        "BUNDLE_BIN_PATH" => ENV["BUNDLE_BIN_PATH"],
        "RUBYOPT" => ENV["RUBYOPT"]
      }

      begin
        ENV["BUNDLE_GEMFILE"] = File.join(dir, "Gemfile")
        ENV["BUNDLE_BIN_PATH"] = File.join(dir, "bundle")
        ENV["RUBYOPT"] = "-rbundler/setup"

        SiloMigrate::Services::InstallService.new(
          runtime: runtime,
          env: env,
          output: StringIO.new,
          source_root: source_root
        ).self_update

        assert_includes runtime.commands, [
          :run,
          [
            File.join(source_root, "script", "install"),
            "--install-deps",
            "--skip-docker",
            "--install-dir", source_root,
            "--bin-dir", bin_dir,
            "--repo", "https://github.com/RubenOussoren/silo-migrate.git",
            "--branch", "main"
          ],
          source_root,
          false,
          1_200,
          nil
        ]
        assert_equal(
          {
            "BUNDLE_GEMFILE" => nil,
            "BUNDLE_BIN_PATH" => nil,
            "RUBYOPT" => nil
          },
          runtime.installer_env
        )
      ensure
        original_env.each do |name, value|
          value.nil? ? ENV.delete(name) : ENV[name] = value
        end
      end

      assert_equal original_env, {
        "BUNDLE_GEMFILE" => ENV["BUNDLE_GEMFILE"],
        "BUNDLE_BIN_PATH" => ENV["BUNDLE_BIN_PATH"],
        "RUBYOPT" => ENV["RUBYOPT"]
      }
    end
  end

  def test_self_update_rejects_unmanaged_source_root
    Dir.mktmpdir do |dir|
      error = assert_raises(SiloMigrate::UsageError) do
        SiloMigrate::Services::InstallService.new(
          runtime: SiloMigrate::Runtime::Fake.new,
          env: { "HOME" => dir },
          output: StringIO.new,
          source_root: dir
        ).self_update
      end

      assert_includes error.message, "requires a Git checkout"
    end
  end

  def test_uninstall_runs_installer_uninstall
    with_tmp_base do |dir, _env|
      source_root = File.join(dir, "source")
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(File.join(source_root, ".git"))
      env = {
        "HOME" => dir,
        "SILO_MIGRATE_BIN_DIR" => bin_dir
      }
      runtime = SiloMigrate::Runtime::Fake.new

      SiloMigrate::Services::InstallService.new(
        runtime: runtime,
        env: env,
        output: StringIO.new,
        source_root: source_root
      ).uninstall

      assert_includes runtime.commands, [
        :run,
        [
          File.join(source_root, "script", "install"),
          "--uninstall",
          "--install-dir", source_root,
          "--bin-dir", bin_dir,
          "--repo", "https://github.com/RubenOussoren/silo-migrate.git",
          "--branch", "main"
        ],
        source_root,
        false,
        300,
        nil
      ]
    end
  end

  def test_install_paths_respect_environment_overrides
    env = {
      "HOME" => "/home/example",
      "XDG_DATA_HOME" => "/data",
      "SILO_MIGRATE_INSTALL_DIR" => "/custom/source",
      "SILO_MIGRATE_BIN_DIR" => "/custom/bin",
      "SILO_MIGRATE_REPO" => "git@example.invalid:custom/repo.git",
      "SILO_MIGRATE_BRANCH" => "stable"
    }

    assert_equal "/custom/source", SiloMigrate::Services::InstallService.install_dir(env)
    assert_equal "/custom/bin", SiloMigrate::Services::InstallService.bin_dir(env)
    assert_equal "git@example.invalid:custom/repo.git", SiloMigrate::Services::InstallService.repo(env)
    assert_equal "stable", SiloMigrate::Services::InstallService.branch(env)
  end

  def test_default_repo_uses_https_for_fresh_machines
    assert_equal "https://github.com/RubenOussoren/silo-migrate.git", SiloMigrate::Services::InstallService.repo("HOME" => "/home/example")
  end

  def test_lifecycle_shim_bypasses_bundler_environment
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, "bin")
      SiloMigrate::Services::InstallService.write_shims(SiloMigrate.root, bin_dir)

      stdout, stderr, status = Open3.capture3(
        {
          "BUNDLE_GEMFILE" => File.join(dir, "missing-gemfile"),
          "BUNDLE_BIN_PATH" => File.join(dir, "missing-bundle"),
          "RUBYOPT" => "-rbundler/setup"
        },
        File.join(bin_dir, "silo-migrate"),
        "self-update",
        "--help"
      )

      assert status.success?, stderr
      assert_includes stdout, "Usage: silo-migrate self-update"
    end
  end

  def test_install_script_includes_pkg_config_for_native_gem_builds
    script = File.read(File.expand_path("../script/install", __dir__))

    assert_match(/formulas\+=\(pkg-config\)/, script)
    assert_match(/install_apt_base_packages\(\).*pkg-config/m, script)
    assert_match(/install_dnf_base_packages\(\).*pkgconf-pkg-config/m, script)
  end

  def test_install_script_writes_lifecycle_shims_that_bypass_bundler
    script = File.read(File.expand_path("../script/install", __dir__))

    assert_includes script, 'if [[ "\${1:-}" == "self-update" || "\${1:-}" == "uninstall" ]]; then'
    assert_includes script, 'for var in \${!BUNDLE_@}; do unset "\$var"; done'
    assert_includes script, "unset BUNDLER_VERSION RUBYOPT"
    assert_includes script, 'exec ruby bin/$name "\$@"'
    assert_includes script, 'exec bundle exec ruby bin/$name "\$@"'
  end

  def test_install_script_uninstall_removes_only_cli_artifacts
    Dir.mktmpdir do |dir|
      source_root = File.join(dir, "source")
      bin_dir = File.join(dir, "bin")
      project_data = File.join(dir, "customers", "acme", "dumps")
      custom_dir = File.join(dir, ".oh-my-zsh", "custom")
      profile = File.join(dir, ".zshrc")
      FileUtils.mkdir_p(File.join(source_root, ".git"))
      FileUtils.mkdir_p(File.join(source_root, "script"))
      FileUtils.mkdir_p(File.join(source_root, "bin"))
      FileUtils.mkdir_p(bin_dir)
      FileUtils.mkdir_p(project_data)
      FileUtils.mkdir_p(File.join(custom_dir, "plugins", "zsh-autosuggestions"))
      FileUtils.mkdir_p(File.join(custom_dir, "plugins", "zsh-syntax-highlighting"))
      FileUtils.mkdir_p(File.join(custom_dir, "themes", "powerlevel10k"))
      FileUtils.touch(File.join(source_root, "script", "install"))
      FileUtils.touch(File.join(source_root, "bin", "silo-migrate"))
      FileUtils.touch(File.join(source_root, "silo-migrate.gemspec"))
      FileUtils.touch(File.join(custom_dir, "plugins", "zsh-autosuggestions", ".silo-migrate-installed"))
      FileUtils.touch(File.join(custom_dir, "plugins", "zsh-syntax-highlighting", ".silo-migrate-installed"))
      FileUtils.touch(File.join(custom_dir, "themes", "powerlevel10k", ".silo-migrate-installed"))
      File.write(File.join(project_data, "dump.sql"), "-- project data\n")
      File.write(profile, <<~ZSH)
        export PATH="/before:$PATH"
        # >>> silo-migrate PATH >>>
        export PATH="#{bin_dir}:$PATH"
        # <<< silo-migrate PATH <<<
        # >>> silo-migrate zsh preset >>>
        plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
        # <<< silo-migrate zsh preset <<<
        export PATH="/after:$PATH"
      ZSH

      %w[silo-migrate migration-tool xml-to-sql].each do |name|
        File.write(File.join(bin_dir, name), <<~SH)
          #!/usr/bin/env bash
          set -euo pipefail
          cd #{source_root}
          exec bundle exec ruby bin/#{name} "$@"
        SH
      end
      File.write(File.join(bin_dir, "custom-tool"), "#!/usr/bin/env bash\n")

      stdout, stderr, status = Open3.capture3(
        { "HOME" => dir, "SHELL" => "/bin/zsh", "ZSH_CUSTOM" => custom_dir },
        File.expand_path("../script/install", __dir__),
        "--uninstall",
        "--install-dir", source_root,
        "--bin-dir", bin_dir
      )

      assert status.success?, stderr
      assert_includes stdout, "Uninstalled silo-migrate CLI artifacts"
      refute_path_exists source_root
      refute_path_exists File.join(bin_dir, "silo-migrate")
      refute_path_exists File.join(bin_dir, "migration-tool")
      refute_path_exists File.join(bin_dir, "xml-to-sql")
      assert_path_exists File.join(bin_dir, "custom-tool")
      assert_path_exists File.join(project_data, "dump.sql")
      refute_path_exists File.join(custom_dir, "plugins", "zsh-autosuggestions")
      refute_path_exists File.join(custom_dir, "plugins", "zsh-syntax-highlighting")
      refute_path_exists File.join(custom_dir, "themes", "powerlevel10k")
      refute_includes File.read(profile), "# >>> silo-migrate PATH >>>"
      refute_includes File.read(profile), "# >>> silo-migrate zsh preset >>>"
      assert_includes File.read(profile), "/before"
      assert_includes File.read(profile), "/after"
    end
  end

  def test_install_script_shell_preset_dry_run_outputs_secure_zsh_config
    Dir.mktmpdir do |dir|
      stdout, stderr, status = Open3.capture3(
        { "HOME" => dir, "SHELL" => "/bin/zsh", "ZSH" => File.join(dir, ".oh-my-zsh"), "ZSH_CUSTOM" => File.join(dir, ".oh-my-zsh", "custom") },
        File.expand_path("../script/install", __dir__),
        "--dry-run",
        "--shell-preset", "migration",
        "--skip-docker"
      )

      assert status.success?, stderr
      assert_includes stdout, "https://github.com/zsh-users/zsh-autosuggestions.git"
      assert_includes stdout, "https://github.com/zsh-users/zsh-syntax-highlighting.git"
      assert_includes stdout, "plugins=(git zsh-autosuggestions zsh-syntax-highlighting)"
      assert_includes stdout, "ZSH_AUTOSUGGEST_STRATEGY=(completion)"
      assert_includes stdout, "ZSH_AUTOSUGGEST_HISTORY_IGNORE"
      assert_includes stdout, "HIST_IGNORE_SPACE HIST_NO_STORE HIST_REDUCE_BLANKS"
      assert_includes stdout, 'export ZSH="${ZSH:-$HOME/.oh-my-zsh}"'
      assert_includes stdout, 'source "$ZSH/oh-my-zsh.sh"'
      refute_includes stdout, "source \"#{dir}/.oh-my-zsh/oh-my-zsh.sh\""
      refute_includes stdout, "chsh -s"
    end
  end

  def test_install_script_shell_preset_dry_run_sets_zsh_login_shell
    Dir.mktmpdir do |dir|
      stdout, stderr, status = Open3.capture3(
        { "HOME" => dir, "SHELL" => "/bin/bash", "ZSH" => File.join(dir, ".oh-my-zsh"), "ZSH_CUSTOM" => File.join(dir, ".oh-my-zsh", "custom") },
        File.expand_path("../script/install", __dir__),
        "--dry-run",
        "--shell-preset", "migration",
        "--skip-docker"
      )

      assert status.success?, stderr
      assert_includes stdout, "Setting login shell for"
      assert_match(/\+ chsh -s \S+zsh \S+/, stdout)
    end
  end

  def test_install_script_shell_preset_recovers_incomplete_oh_my_zsh
    Dir.mktmpdir do |dir|
      zsh_dir = File.join(dir, ".oh-my-zsh")
      FileUtils.mkdir_p(zsh_dir)

      stdout, stderr, status = Open3.capture3(
        { "HOME" => dir, "SHELL" => "/bin/zsh", "ZSH" => zsh_dir, "ZSH_CUSTOM" => File.join(zsh_dir, "custom") },
        File.expand_path("../script/install", __dir__),
        "--dry-run",
        "--shell-preset", "migration",
        "--zsh-theme", "powerlevel10k",
        "--skip-docker"
      )

      assert status.success?, stderr
      assert_includes stderr, "looks incomplete"
      assert_includes stdout, "Moving incomplete Oh My Zsh directory"
      assert_match(/\+ mv .*\.oh-my-zsh .*\.oh-my-zsh\.broken-\d{14}/, stdout)
      assert_includes stdout, "raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
      assert_includes stdout, 'ZSH_THEME="powerlevel10k/powerlevel10k"'
    end
  end

  def test_install_script_with_oh_my_zsh_rejects_incomplete_oh_my_zsh
    Dir.mktmpdir do |dir|
      zsh_dir = File.join(dir, ".oh-my-zsh")
      FileUtils.mkdir_p(zsh_dir)

      _stdout, stderr, status = Open3.capture3(
        { "HOME" => dir, "SHELL" => "/bin/zsh", "ZSH" => zsh_dir, "ZSH_CUSTOM" => File.join(zsh_dir, "custom") },
        File.expand_path("../script/install", __dir__),
        "--dry-run",
        "--install-deps",
        "--with-oh-my-zsh",
        "--skip-docker"
      )

      refute status.success?
      assert_includes stderr, "Refusing to overwrite incomplete Oh My Zsh directory"
      assert_includes stderr, "mv #{zsh_dir}"
    end
  end

  def test_install_script_skips_complete_oh_my_zsh_install
    Dir.mktmpdir do |dir|
      zsh_dir = File.join(dir, ".oh-my-zsh")
      FileUtils.mkdir_p(zsh_dir)
      FileUtils.touch(File.join(zsh_dir, "oh-my-zsh.sh"))

      stdout, stderr, status = Open3.capture3(
        { "HOME" => dir, "SHELL" => "/bin/zsh", "ZSH" => zsh_dir, "ZSH_CUSTOM" => File.join(zsh_dir, "custom") },
        File.expand_path("../script/install", __dir__),
        "--dry-run",
        "--shell-preset", "migration",
        "--skip-docker"
      )

      assert status.success?, stderr
      refute_includes stderr, "looks incomplete"
      refute_includes stdout, "raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
      assert_includes stdout, "https://github.com/zsh-users/zsh-autosuggestions.git"
    end
  end

  def test_install_script_replaces_marker_owned_incomplete_zsh_addon
    Dir.mktmpdir do |dir|
      zsh_dir = File.join(dir, ".oh-my-zsh")
      addon_dir = File.join(zsh_dir, "custom", "plugins", "zsh-autosuggestions")
      FileUtils.mkdir_p(addon_dir)
      FileUtils.touch(File.join(zsh_dir, "oh-my-zsh.sh"))
      FileUtils.touch(File.join(addon_dir, ".silo-migrate-installed"))

      stdout, stderr, status = Open3.capture3(
        { "HOME" => dir, "SHELL" => "/bin/zsh", "ZSH" => zsh_dir, "ZSH_CUSTOM" => File.join(zsh_dir, "custom") },
        File.expand_path("../script/install", __dir__),
        "--dry-run",
        "--shell-preset", "migration",
        "--skip-docker"
      )

      assert status.success?, stderr
      assert_includes stdout, "Replacing incomplete installer-managed zsh add-on at #{addon_dir}"
      assert_match(/\+ rm -rf .*zsh-autosuggestions/, stdout)
      assert_includes stdout, "git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git"
    end
  end

  def test_install_script_rejects_unmanaged_incomplete_zsh_addon
    Dir.mktmpdir do |dir|
      zsh_dir = File.join(dir, ".oh-my-zsh")
      addon_dir = File.join(zsh_dir, "custom", "plugins", "zsh-autosuggestions")
      FileUtils.mkdir_p(addon_dir)
      FileUtils.touch(File.join(zsh_dir, "oh-my-zsh.sh"))

      _stdout, stderr, status = Open3.capture3(
        { "HOME" => dir, "SHELL" => "/bin/zsh", "ZSH" => zsh_dir, "ZSH_CUSTOM" => File.join(zsh_dir, "custom") },
        File.expand_path("../script/install", __dir__),
        "--dry-run",
        "--shell-preset", "migration",
        "--skip-docker"
      )

      refute status.success?
      assert_includes stderr, "#{addon_dir} exists but is not a Git checkout"
    end
  end

  def test_install_script_shell_preset_can_request_powerlevel10k
    Dir.mktmpdir do |dir|
      stdout, stderr, status = Open3.capture3(
        { "HOME" => dir, "SHELL" => "/bin/zsh", "ZSH" => File.join(dir, ".oh-my-zsh"), "ZSH_CUSTOM" => File.join(dir, ".oh-my-zsh", "custom") },
        File.expand_path("../script/install", __dir__),
        "--dry-run",
        "--shell-preset", "migration",
        "--zsh-theme", "powerlevel10k",
        "--skip-docker"
      )

      assert status.success?, stderr
      assert_includes stdout, "https://github.com/romkatv/powerlevel10k.git"
      assert_includes stdout, 'ZSH_THEME="powerlevel10k/powerlevel10k"'
    end
  end

  def test_install_script_rejects_unsupported_zsh_plugins
    Dir.mktmpdir do |dir|
      _stdout, stderr, status = Open3.capture3(
        { "HOME" => dir, "SHELL" => "/bin/zsh", "ZSH" => File.join(dir, ".oh-my-zsh"), "ZSH_CUSTOM" => File.join(dir, ".oh-my-zsh", "custom") },
        File.expand_path("../script/install", __dir__),
        "--dry-run",
        "--zsh-plugins", "git,unknown-plugin"
      )

      refute status.success?
      assert_includes stderr, "unsupported plugin: unknown-plugin"
    end
  end
end
