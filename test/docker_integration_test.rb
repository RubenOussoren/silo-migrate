# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"
require "socket"

class DockerIntegrationTest < SiloMigrateTest
  def test_docker_runtime_phase_1_smoke_when_enabled
    skip "Set RUN_DOCKER_TESTS=1 to run Docker integration checks" unless ENV["RUN_DOCKER_TESTS"] == "1"
    skip "git is required for the local converter fixture" unless system("git", "--version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir("silo-migrate-docker-", "/private/tmp") do |dir|
      env = { "SILO_MIGRATE_BASE_PATH" => File.join(dir, "customers") }
      runtime = SiloMigrate::Runtime::Docker.new(env: env)
      runtime.ensure_available!
      out = StringIO.new
      err = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: err)
      customer = "smoke#{Time.now.to_i}"
      port = available_port
      dump = write(File.join(dir, "dump.sql"), <<~SQL)
        -- MySQL dump
        CREATE TABLE users (id int primary key, username varchar(32));
        INSERT INTO users VALUES (1, 'alice');
      SQL
      converter_repo = create_converter_fixture_repo(dir)

      begin
        assert_cli_success cli, err, out, ["init", customer, "--db-type", "mariadb", "--initial-port", port.to_s]
        assert_cli_success cli, err, out, ["stage-dump", customer, "initial", dump]
        assert_cli_success cli, err, out, ["start", customer, "--profile", "initial-db", "--wait", "--health-timeout", "90"]
        assert_cli_success cli, err, out, ["import-dump", customer, "initial", "--file", "dump.sql"]
        assert_cli_success cli, err, out, ["schema", "export", customer]
        assert_cli_success cli, err, out, ["schema", "bundle", customer]
        assert_cli_success cli, err, out, ["setup-converter", customer, "--repo", converter_repo, "--start", "--bundle-install"]
        assert_cli_success cli, err, out, ["run-converter", customer]

        schema = File.join(SiloMigrate::Project.project_path(customer, env), "schema", "initial_schema.sql")
        assert_includes File.read(schema), "CREATE TABLE"
        summary = JSON.parse(File.read(File.join(SiloMigrate::Project.project_path(customer, env), "schema", "initial", "summary.json")))
        assert_equal false, summary.fetch("contains_raw_rows")
        assert_operator summary.fetch("table_count"), :>=, 1
        assert_includes out.string, "fixture converter ran"
      ensure
        cli.run(["stop", customer, "--profile", "all", "--remove"]) if File.exist?(SiloMigrate::Project.config_path(customer, env))
      end
    end
  end

  def test_docker_runtime_times_out_captured_commands
    runtime = SiloMigrate::Runtime::Docker.new
    result = runtime.run([RbConfig.ruby, "-e", "sleep 5"], capture: true, timeout: 0.1)

    refute result.success?
    assert_nil result.status
    assert_includes result.stderr, "Command timed out after 0.1s"
  end

  def test_docker_runtime_times_out_attached_commands
    runtime = SiloMigrate::Runtime::Docker.new
    result = runtime.run([RbConfig.ruby, "-e", "sleep 5"], timeout: 0.1)

    refute result.success?
    assert_nil result.status
    assert_includes result.stderr, "Command timed out after 0.1s"
  end

  private

  def available_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def create_converter_fixture_repo(dir)
    repo = File.join(dir, "fixture-converter")
    write(File.join(repo, "Gemfile"), "source 'https://rubygems.org'\n")
    write(File.join(repo, "convert"), "#!/usr/bin/env ruby\n")
    write(File.join(repo, "converter.rb"), "puts 'fixture converter ran'\n")
    write(File.join(repo, "Dockerfile"), <<~DOCKERFILE)
      FROM ruby:3.3
      WORKDIR /converters
      COPY Gemfile ./
      RUN bundle install
      CMD ["sleep", "infinity"]
    DOCKERFILE
    assert system("git", "-C", repo, "init", out: File::NULL, err: File::NULL)
    assert system("git", "-C", repo, "checkout", "-b", "main", out: File::NULL, err: File::NULL)
    assert system("git", "-C", repo, "config", "user.email", "silo-migrate@example.invalid", out: File::NULL, err: File::NULL)
    assert system("git", "-C", repo, "config", "user.name", "Silo Migrate Test", out: File::NULL, err: File::NULL)
    assert system("git", "-C", repo, "add", ".", out: File::NULL, err: File::NULL)
    assert system("git", "-C", repo, "commit", "-m", "Add fixture converter", out: File::NULL, err: File::NULL)
    repo
  end

  def assert_cli_success(cli, err, out, argv)
    err.truncate(0)
    err.rewind
    code = cli.run(argv)
    assert_equal 0, code, "command failed: #{argv.join(' ')}\nSTDERR:\n#{err.string}\nSTDOUT:\n#{out.string}"
  end
end
