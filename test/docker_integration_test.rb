# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"
require "socket"

class DockerIntegrationTest < SiloMigrateTest
  def test_docker_runtime_phase_1_smoke_when_enabled
    skip "Set RUN_DOCKER_TESTS=1 to run Docker integration checks" unless ENV["RUN_DOCKER_TESTS"] == "1"
    skip "git is required for the local converter fixture" unless system("git", "--version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir("silo-migrate-docker-", "/private/tmp") do |dir|
      env = {
        "SILO_MIGRATE_BASE_PATH" => File.join(dir, "customers"),
        "SILO_MIGRATE_USER_CONFIG" => File.join(dir, "user-config.env"),
        "SILO_MIGRATE_SAFE_AI_BASE_PATH" => File.join(dir, "safe-ai")
      }
      runtime = SiloMigrate::Runtime::Docker.new(env: env)
      runtime.ensure_available!
      out = StringIO.new
      err = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: err)
      customer = "smoke#{Time.now.to_i}"
      password_sentinel = "e2e_secret_pw_123"
      port = available_port
      dump = write(File.join(dir, "dump.sql"), <<~SQL)
        -- MySQL dump
        CREATE TABLE users (id int primary key, username varchar(32));
        INSERT INTO users VALUES (1, 'alice');
      SQL
      converter_repo = create_converter_fixture_repo(dir)

      begin
        assert_cli_success cli, err, out, ["init", customer, "--db-type", "mariadb", "--initial-port", port.to_s, "--password", password_sentinel]
        assert_cli_success cli, err, out, ["stage-dump", customer, "initial", dump]
        assert_cli_success cli, err, out, ["start", customer, "--profile", "initial-db", "--wait", "--health-timeout", "90"]
        assert_cli_success cli, err, out, ["import-dump", customer, "initial", "--file", "dump.sql"]
        assert_cli_success cli, err, out, ["schema", "export", customer]
        assert_cli_success cli, err, out, ["schema", "bundle", customer]
        assert_cli_success cli, err, out, ["setup-converter", customer, "--repo", converter_repo, "--start", "--bundle-install"]
        assert_cli_success cli, err, out, ["run-converter", customer]

        project_path = SiloMigrate::Project.project_path(customer, env)
        schema = File.join(project_path, "schema", "initial_schema.sql")
        assert_includes File.read(schema), "CREATE TABLE"
        summary = JSON.parse(File.read(File.join(project_path, "schema", "initial", "summary.json")))
        assert_equal false, summary.fetch("contains_raw_rows")
        assert_operator summary.fetch("table_count"), :>=, 1
        assert_includes out.string, "fixture converter ran"

        # Phase 2 loop: platform run with generated in-network settings,
        # real intermediate.db, then the full redaction/findings pipeline.
        assert_cli_success cli, err, out, ["run-converter", customer, "fixture", "--redacted-logs"]

        generated_settings = File.join(project_path, "converter-settings", "fixture.yml")
        assert File.exist?(generated_settings), "expected generated converter settings"
        assert_includes File.read(generated_settings), "#{customer}_initial_mariadb"
        assert_includes out.string, "fixture converter connected"
        assert File.exist?(File.join(project_path, "output", "intermediate.db")), "converter should write intermediate.db"

        run_summary = JSON.parse(File.read(File.join(project_path, "findings", "redacted-logs", "latest.summary.json")))
        assert_equal true, run_summary.dig("sources", "intermediate_db", "available")
        assert_operator run_summary.dig("sources", "intermediate_db", "log_entry_count"), :>=, 1

        assert_cli_success cli, err, out, ["converter", "summary", customer]
        assert_cli_success cli, err, out, ["findings", "generate", customer]
        assert_cli_success cli, err, out, ["fixtures", "generate", customer]
        assert_cli_success cli, err, out, ["ai", "prepare", customer]

        workspace = Dir[File.join(dir, "safe-ai", "*")].first
        refute_nil workspace, "expected a safe AI workspace"
        assert_redaction_holds(workspace, %w[alice e2e_secret_pw_123], label: "AI workspace")
        assert_redaction_holds(File.join(project_path, "findings"), %w[alice e2e_secret_pw_123], label: "findings artifacts")
        refute Dir.exist?(File.join(workspace, "converter-settings")), "generated settings must not reach the AI workspace"
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
    write(File.join(repo, "Gemfile"), <<~GEMFILE)
      source "https://rubygems.org"
      gem "mysql2"
      gem "sqlite3"
    GEMFILE
    write(File.join(repo, "converter.rb"), "puts 'fixture converter ran'\n")
    # Defaults intentionally point at localhost so the test proves the
    # generated settings file overrides them with the container hostname.
    write(File.join(repo, "converters", "fixture", "settings.yml"), <<~YAML)
      database:
        host: "127.0.0.1"
        port: 3306
        username: "root"
        password: "wrong"
        database: "wrong"
    YAML
    write(File.join(repo, "convert"), <<~RUBY)
      #!/usr/bin/env ruby
      # Minimal stand-in for discourse-converters' convert script: reads the
      # --settings YAML, queries the source DB over the compose network, and
      # writes output/intermediate.db with a log_entries table whose details
      # JSON embeds real row values (so redaction is genuinely exercised).
      require "optparse"
      require "yaml"
      require "json"
      require "fileutils"
      require "mysql2"
      require "sqlite3"

      options = {}
      OptionParser.new do |opts|
        opts.on("--from PLATFORM") { |value| options[:from] = value }
        opts.on("--reset") { options[:reset] = true }
        opts.on("--settings PATH") { |value| options[:settings] = File.expand_path(value, __dir__) }
      end.parse!(ARGV)

      settings_path = options[:settings] || File.expand_path("converters/fixture/settings.yml", __dir__)
      settings = YAML.safe_load(File.read(settings_path))
      db = settings.fetch("database")
      client = Mysql2::Client.new(
        host: db.fetch("host"),
        port: db.fetch("port"),
        username: db.fetch("username"),
        password: db.fetch("password"),
        database: db.fetch("database")
      )
      rows = client.query("SELECT id, username FROM users ORDER BY id").to_a

      output_dir = File.expand_path("output", __dir__)
      FileUtils.mkdir_p(output_dir)
      out_db = SQLite3::Database.new(File.join(output_dir, "intermediate.db"))
      out_db.execute("DROP TABLE IF EXISTS log_entries")
      out_db.execute("CREATE TABLE log_entries (created_at DATETIME, type TEXT, message TEXT, exception TEXT, details TEXT)")
      out_db.execute(
        "INSERT INTO log_entries (created_at, type, message, exception, details) VALUES (?, ?, ?, ?, ?)",
        [Time.now.utc.strftime("%F %T"), "warning", "imported \#{rows.length} user row(s)", nil, JSON.generate({ "rows" => rows })]
      )
      out_db.close
      puts "fixture converter connected to \#{db['host']} and processed \#{rows.length} row(s)"
    RUBY
    FileUtils.chmod(0o755, File.join(repo, "convert"))
    write(File.join(repo, "Dockerfile"), <<~DOCKERFILE)
      FROM ruby:3.3
      RUN apt-get update && apt-get install -y --no-install-recommends default-libmysqlclient-dev libsqlite3-dev && rm -rf /var/lib/apt/lists/*
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

  def assert_redaction_holds(root, sentinels, label:)
    offenders = []
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).each do |path|
      next unless File.file?(path)

      content = File.read(path, encoding: "BINARY")
      sentinels.each do |sentinel|
        offenders << "#{path} contains #{sentinel.inspect}" if content.include?(sentinel)
      end
    end
    assert_empty offenders, "raw data leaked into #{label}:\n#{offenders.join("\n")}"
  end
end
