# frozen_string_literal: true

require_relative "test_helper"

class ProjectTest < SiloMigrateTest
  def test_customer_name_validation
    assert_equal "acme_2026", SiloMigrate::Project.validate_customer_name!("acme_2026")
    assert_raises(SiloMigrate::UsageError) { SiloMigrate::Project.validate_customer_name!("../acme") }
    assert_raises(SiloMigrate::UsageError) { SiloMigrate::Project.validate_customer_name!("") }
  end

  def test_base_path_resolution_chain
    with_tmp_base do |dir, env|
      assert_equal env["SILO_MIGRATE_BASE_PATH"], SiloMigrate::Project.base_path(env)
      assert SiloMigrate::Project.base_path_configured?(env)

      config_only_env = { "SILO_MIGRATE_USER_CONFIG" => env["SILO_MIGRATE_USER_CONFIG"] }
      SiloMigrate::UserConfig.save({ "SILO_MIGRATE_BASE_PATH" => "/tmp/from-user-config" }, config_only_env)
      assert_equal "/tmp/from-user-config", SiloMigrate::Project.base_path(config_only_env)

      env_var_wins = config_only_env.merge("SILO_MIGRATE_BASE_PATH" => "/tmp/from-env")
      assert_equal "/tmp/from-env", SiloMigrate::Project.base_path(env_var_wins)

      empty_env = { "SILO_MIGRATE_USER_CONFIG" => File.join(dir, "missing-user-config.env") }
      unless Dir.exist?(SiloMigrate::DEFAULT_BASE_PATH) && File.writable?(SiloMigrate::DEFAULT_BASE_PATH)
        refute SiloMigrate::Project.base_path_configured?(empty_env)
        error = assert_raises(SiloMigrate::UsageError) { SiloMigrate::Project.base_path(empty_env) }
        assert_includes error.message, "SILO_MIGRATE_BASE_PATH"
        assert_includes error.message, "interactive"
      end
    end
  end

  def test_config_env_read_write_compatibility
    with_tmp_base do |_dir, env|
      SiloMigrate::Project.ensure_project_dirs("acme", env)
      config = {
        "CUSTOMER" => "acme",
        "INITIAL_DB_TYPE" => "mariadb",
        "INITIAL_DB_PASSWORD" => 'quoted " password'
      }
      SiloMigrate::Project.save_config("acme", config, env)
      assert_equal config, SiloMigrate::Project.load_config("acme", env)
      assert_includes File.read(SiloMigrate::Project.config_path("acme", env)), 'INITIAL_DB_PASSWORD="quoted \" password"'
    end
  end

  def test_project_service_init_writes_layout_compose_and_connection_readme
    with_tmp_base do |_dir, env|
      out = StringIO.new
      service = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out)
      path = service.init("acme", db_type: "mysql", initial_port: 3310, final_db_type: "postgres", final_port: 5434)

      assert File.directory?(File.join(path, "dumps", "initial"))
      assert File.directory?(File.join(path, "dumps", "final"))
      assert File.exist?(File.join(path, "config.env"))
      assert File.exist?(File.join(path, "docker-compose.yml"))
      assert File.exist?(File.join(path, "dumps", "initial", "CONNECTION.md"))
      assert_includes out.string, "[OK] Project initialized"
    end
  end

  def test_service_ports_for_profile_maps_initial_final_and_all
    service = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: {}, output: StringIO.new)
    config = {
      "INITIAL_PORT" => "3310",
      "FINAL_DB_TYPE" => "postgres",
      "FINAL_PORT" => "5434"
    }

    assert_equal [{ service: "initial-db", port: 3310 }], service.service_ports_for_profile(config, "initial-db")
    assert_equal [{ service: "final-db", port: 5434 }], service.service_ports_for_profile(config, "final-db")
    assert_equal [
      { service: "initial-db", port: 3310 },
      { service: "final-db", port: 5434 }
    ], service.service_ports_for_profile(config, "all")
    assert_empty service.service_ports_for_profile(config, "converter")
  end

  def test_start_blocks_port_conflict_without_force
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      service.init("acme", db_type: "mariadb", initial_port: 3310)
      runtime.running_containers["acme_initial_mariadb"] = false

      service.stub(:port_listening?, ->(_port) { true }) do
        error = assert_raises(SiloMigrate::UsageError) { service.start("acme", profile: "initial-db") }
        assert_includes error.message, "Port 3310"
      end
      assert_equal [], runtime.commands
    end
  end

  def test_repeated_start_ignores_port_owned_by_expected_running_container
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      runtime.running_containers["acme_initial_mariadb"] = true
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      service.init("acme", db_type: "mariadb", initial_port: 3310)

      service.stub(:port_listening?, ->(_port) { true }) do
        service.start("acme", profile: "initial-db")
      end

      assert_equal [:compose, "acme", ["--profile", "initial-db", "up", "-d"], false, 300], runtime.commands.last
    end
  end

  def test_start_allows_port_conflict_with_force
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      service.init("acme", db_type: "mariadb", initial_port: 3310)
      runtime.running_containers["acme_initial_mariadb"] = false

      service.stub(:port_listening?, ->(_port) { true }) do
        service.start("acme", profile: "initial-db", force: true)
      end

      assert_equal [:compose, "acme", ["--profile", "initial-db", "up", "-d"], false, 300], runtime.commands.last
    end
  end

  def test_start_all_profile_reports_only_unknown_port_conflicts
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      runtime.running_containers["acme_initial_mariadb"] = true
      runtime.running_containers["acme_final_postgres"] = false
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      service.init("acme", db_type: "mariadb", initial_port: 3310, final_db_type: "postgres", final_port: 5434)

      service.stub(:port_listening?, ->(_port) { true }) do
        error = assert_raises(SiloMigrate::UsageError) { service.start("acme", profile: "all") }
        refute_includes error.message, "Port 3310"
        assert_includes error.message, "Port 5434"
      end
    end
  end

  def test_update_phase_port_persists_config_and_regenerates_compose
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      service.init("acme", db_type: "mariadb", initial_port: 3310)

      service.update_phase_port("acme", "initial", 3312)

      config = SiloMigrate::Project.load_config("acme", env)
      compose = File.read(File.join(service.project_path("acme"), "docker-compose.yml"))
      assert_equal "3312", config["INITIAL_PORT"]
      assert_includes compose, "127.0.0.1:3312:3306"
      assert_includes out.string, "Updated initial database port to 3312"
    end
  end

  def test_available_port_skips_listening_and_avoided_ports
    with_tmp_base do |_dir, env|
      service = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)

      service.stub(:port_available?, ->(port) { port == 3313 }) do
        assert_equal 3313, service.available_port(3310, avoid: [3312])
      end
    end
  end

  def test_start_waits_for_database_health_when_requested
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      service.init("acme", db_type: "mariadb", initial_port: 3310)
      service.start("acme", profile: "initial-db", wait_for_health: true)

      assert_includes runtime.commands, [:wait_for_health, "acme_initial_mariadb", 60]
    end
  end

  def test_start_fails_when_health_wait_leaves_container_stopped
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      runtime.healthy_containers["acme_initial_mariadb"] = false
      runtime.running_containers["acme_initial_mariadb"] = false
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      service.init("acme", db_type: "mariadb", initial_port: 3310)

      assert_raises(SiloMigrate::UsageError) { service.start("acme", profile: "initial-db", wait_for_health: true) }
    end
  end

  def test_start_warns_when_health_wait_times_out_but_container_keeps_running
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      runtime.healthy_containers["acme_initial_mariadb"] = false
      runtime.running_containers["acme_initial_mariadb"] = true
      out = StringIO.new
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      service.init("acme", db_type: "mariadb", initial_port: 3310)

      service.start("acme", profile: "initial-db", wait_for_health: true)

      assert_includes out.string, "did not become healthy within 60s; continuing because it is running"
    end
  end

  def test_incomplete_converter_directory_fails_with_repair_guidance
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      project_path = service.init("acme")
      FileUtils.mkdir_p(File.join(project_path, "discourse-converters"))

      error = assert_raises(SiloMigrate::UsageError) { service.setup_converter("acme") }
      assert_includes error.message, "incomplete"
      assert_includes error.message, "Gemfile"
      assert_includes error.message, "convert"
      assert_includes error.message, "rerun setup-converter"
    end
  end

  def test_setup_converter_fails_fast_when_github_ssh_preflight_fails
    with_tmp_base do |_dir, env|
      runtime = FailingSshRuntime.new
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      project_path = service.init("acme")

      error = assert_raises(SiloMigrate::UsageError) { service.setup_converter("acme") }

      assert_includes error.message, "Git SSH access is not available for github.com"
      assert_includes error.message, "1Password SSH agent"
      assert_includes error.message, "macOS ssh-agent"
      assert_includes error.message, "--allow-ssh-prompt"
      assert_includes error.message, "ssh -T git@github.com"
      assert_includes error.message, "ssh-add -l"
      assert_includes error.message, "--repo <alternate-url>"
      assert_includes runtime.commands, [:run, ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "git@github.com"], nil, true, 12, nil]
      refute runtime.commands.any? { |command| command[0] == :run && command[1][0, 2] == ["git", "clone"] }
      refute Dir.exist?(File.join(project_path, "discourse-converters"))
    end
  end

  def test_setup_converter_can_use_terminal_ssh_prompt_clone
    with_tmp_base do |_dir, env|
      runtime = FailingSshRuntime.new
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      project_path = service.init("acme")

      service.setup_converter("acme", allow_ssh_prompt: true)

      refute runtime.commands.any? { |command| command[0] == :run && command[1][0] == "ssh" }
      assert_includes runtime.commands, [
        :run,
        ["git", "clone", "-b", "main", SiloMigrate::Services::ProjectService::DEFAULT_CONVERTER_REPO, File.join(project_path, "discourse-converters")],
        nil,
        false,
        300,
        nil
      ]
      assert_equal false, runtime.last_run_options[:separate_process_group]
      assert File.exist?(File.join(project_path, "discourse-converters", "Dockerfile"))
    end
  end

  def test_setup_converter_accepts_github_authenticated_nonzero_preflight
    with_tmp_base do |_dir, env|
      runtime = GithubAuthenticatedRuntime.new
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      project_path = service.init("acme")

      service.setup_converter("acme")

      assert runtime.commands.any? { |command| command[0] == :run && command[1][0] == "ssh" }
      assert runtime.commands.any? { |command| command[0] == :run && command[1][0, 3] == ["git", "clone", "-b"] && command[4] == 120 }
      assert File.exist?(File.join(project_path, "discourse-converters", "Dockerfile"))
    end
  end

  def test_setup_converter_with_https_repo_skips_ssh_preflight
    with_tmp_base do |_dir, env|
      runtime = FailingSshRuntime.new
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      service.init("acme")

      service.setup_converter("acme", repo: "https://github.com/discourse/discourse-converters.git")

      refute runtime.commands.any? { |command| command[0] == :run && command[1][0] == "ssh" }
      assert runtime.commands.any? { |command| command[0] == :run && command[1][0, 3] == ["git", "clone", "-b"] }
    end
  end

  def test_existing_valid_converter_directory_skips_clone
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      service = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      project_path = service.init("acme")
      converter_dir = File.join(project_path, "discourse-converters")
      FileUtils.mkdir_p(converter_dir)
      write(File.join(converter_dir, "Gemfile"), "source 'https://rubygems.org'\n")
      write(File.join(converter_dir, "convert"), "#!/usr/bin/env ruby\n")

      service.setup_converter("acme")

      refute runtime.commands.any? { |command| command[0] == :run && command[1].include?("git") }
    end
  end

  class FailingSshRuntime < SiloMigrate::Runtime::Fake
    def run(cmd, chdir: nil, capture: false, timeout: nil, stdin_data: nil, separate_process_group: true)
      if cmd[0] == "ssh"
        @commands << [:run, cmd, chdir, capture, timeout, stdin_data&.bytesize]
        return SiloMigrate::Runtime::CommandResult.new(success?: false, stdout: "", stderr: "Permission denied (publickey).", status: 255)
      end

      super
    end
  end

  class GithubAuthenticatedRuntime < SiloMigrate::Runtime::Fake
    def run(cmd, chdir: nil, capture: false, timeout: nil, stdin_data: nil, separate_process_group: true)
      if cmd[0] == "ssh"
        @commands << [:run, cmd, chdir, capture, timeout, stdin_data&.bytesize]
        return SiloMigrate::Runtime::CommandResult.new(
          success?: false,
          stdout: "",
          stderr: "Hi user! You've successfully authenticated, but GitHub does not provide shell access.",
          status: 1
        )
      end

      super
    end
  end
end
