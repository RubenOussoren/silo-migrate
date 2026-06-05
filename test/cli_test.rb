# frozen_string_literal: true

require_relative "test_helper"

class CLITest < SiloMigrateTest
  def test_help_output
    out = StringIO.new
    code = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, output: out, error: StringIO.new).run(["--help"])
    assert_equal 0, code
    assert_includes out.string, "Usage: silo-migrate"
    assert_includes out.string, "convert-xml"
    assert_includes out.string, "schema bundle"
    assert_includes out.string, "findings generate"
    assert_includes out.string, "fixtures generate"
    assert_includes out.string, "ai prepare"
    assert_includes out.string, "trusted inspect"
    assert_includes out.string, "trusted session"
    assert_includes out.string, "--bundle-install also builds/starts"
  end

  def test_cli_init_and_start_use_fake_runtime
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)

      assert_equal 0, cli.run(["init", "acme", "--db-type", "mariadb", "--initial-port", "3311"])
      assert_equal 0, cli.run(["start", "acme", "--profile", "initial-db", "--build"])
      assert_equal [:compose, "acme", ["--profile", "initial-db", "up", "--build", "-d"], false, 300], runtime.commands.last
    end
  end

  def test_start_wait_flag_waits_for_database_health
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: StringIO.new)

      cli.run(["init", "acme", "--db-type", "mariadb"])
      assert_equal 0, cli.run(["start", "acme", "--profile", "initial-db", "--wait", "--health-timeout", "7"])

      assert_includes runtime.commands, [:wait_for_health, "acme_initial_mariadb", 7]
    end
  end

  def test_import_command_construction_without_docker
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme", "--db-type", "mariadb"])
      dump = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      write(dump, "-- MySQL dump\nCREATE TABLE t (id int);\n")

      assert_equal 0, cli.run(["import-dump", "acme", "initial", "--file", "dump.sql", "--fast"])
      command = runtime.commands.last
      assert_equal :run_stream, command[0]
      assert_includes command[1], "docker"
      assert_includes command[1], "--max-allowed-packet=512M"
    end
  end

  def test_import_uses_chunked_path_without_filters_or_collation_fixes
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      service = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: StringIO.new)
      SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new).init("acme", db_type: "mariadb")
      dump = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      write(dump, "-- MySQL dump\nCREATE TABLE users (id int);\nINSERT INTO users VALUES (1);\n")
      snapshots = []

      service.import_dump("acme", "initial", file: "dump.sql", progress_callback: proc { |stats| snapshots << stats })

      assert_equal :chunked, snapshots.last[:stream_mode]
      assert_nil snapshots.last[:current_table]
      assert_includes runtime.last_stdin, "CREATE TABLE users"
    end
  end

  def test_import_uses_chunked_path_for_gzip_dump_without_transforms
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      service = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: StringIO.new)
      SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new).init("acme", db_type: "mariadb")
      dump = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql.gz")
      gzip_write(dump, "-- MySQL dump\nCREATE TABLE users (id int);\n")
      snapshots = []

      service.import_dump("acme", "initial", file: "dump.sql.gz", progress_callback: proc { |stats| snapshots << stats })

      assert_equal :chunked, snapshots.last[:stream_mode]
      assert_includes runtime.last_stdin, "CREATE TABLE users"
    end
  end

  def test_stage_dump_command_copies_dump_into_project
    with_tmp_base do |dir, env|
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out, error: StringIO.new)
      source = write(File.join(dir, "dump.sql"), "-- MySQL dump\nCREATE TABLE t (id int);\n")

      assert_equal 0, cli.run(["init", "acme"])
      assert_equal 0, cli.run(["stage-dump", "acme", "initial", source])

      staged = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      assert File.exist?(staged)
      assert_includes out.string, "[OK] Dump staged"
      assert_includes out.string, "Detected source format: sql"
      assert_includes out.string, "Detected source type: mysql5"
    end
  end

  def test_stage_dump_command_describes_unknown_sql_without_detected_type
    with_tmp_base do |dir, env|
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out, error: StringIO.new)
      source = write(File.join(dir, "dump.sql"), "CREATE TABLE t (id int);\n")

      assert_equal 0, cli.run(["init", "acme"])
      assert_equal 0, cli.run(["stage-dump", "acme", "initial", source])

      assert_includes out.string, "Source type: unknown SQL dump"
      refute_includes out.string, "Detected source type: unknown_sql"
      assert_includes out.string, "Recommended DB: mariadb"
    end
  end

  def test_import_exclude_tables_filters_streamed_sql
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: StringIO.new)
      cli.run(["init", "acme", "--db-type", "mariadb"])
      dump = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      write(dump, <<~SQL)
        -- MySQL dump
        CREATE TABLE keepers (id int);
        INSERT INTO keepers VALUES (1);
        CREATE TABLE sessions (
          id int
        );
        INSERT INTO sessions
        VALUES
          ('value with ; inside'),
          (2);
        /*!40000 ALTER TABLE `sessions` ENABLE KEYS */;
      SQL

      assert_equal 0, cli.run(["import-dump", "acme", "initial", "--file", "dump.sql", "--exclude-tables", "sessions"])
      command = runtime.commands.last
      assert_equal :run_stream, command[0]
      assert_includes runtime.last_stdin, "CREATE TABLE keepers"
      refute_includes runtime.last_stdin, "sessions"
    end
  end

  def test_import_collation_fix_uses_filtered_path
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      service = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: StringIO.new)
      SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new).init("acme", db_type: "mariadb")
      dump = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      write(dump, "-- MySQL dump\nCREATE TABLE users (name varchar(255) COLLATE utf8mb4_0900_ai_ci);\n")
      snapshots = []

      service.import_dump("acme", "initial", file: "dump.sql", progress_callback: proc { |stats| snapshots << stats })

      assert_equal :filtered, snapshots.last[:stream_mode]
      assert_includes runtime.last_stdin, "utf8mb4_unicode_ci"
      refute_includes runtime.last_stdin, "utf8mb4_0900_ai_ci"
    end
  end

  def test_import_progress_tracks_bytes_lines_and_table
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      service = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: StringIO.new)
      SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new).init("acme", db_type: "mariadb")
      dump = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      write(dump, "-- MySQL dump\nCREATE TABLE users (id int);\nINSERT INTO users VALUES (1);\n")
      snapshots = []

      service.import_dump("acme", "initial", file: "dump.sql", exclude_tables: "missing_table", progress_callback: proc { |stats| snapshots << stats })

      assert snapshots.any? { |stats| stats[:bytes_processed].positive? && stats[:lines_processed].positive? }
      assert snapshots.any? { |stats| stats[:current_table] == "users" }
    end
  end

  def test_custom_import_progress_callback_suppresses_builtin_progress_output
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      service = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new).init("acme", db_type: "mariadb")
      dump = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      write(dump, "-- MySQL dump\nCREATE TABLE users (id int);\n")

      service.import_dump("acme", "initial", file: "dump.sql", progress_callback: proc { |_stats| })

      refute_includes out.string, "Progress:"
      assert_includes out.string, "[OK] Dump imported successfully"
    end
  end

  def test_filtered_import_streams_large_single_line_insert
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      service = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: StringIO.new)
      SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new).init("acme", db_type: "mariadb")
      dump = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      large_value = "x" * (2 * 1024 * 1024)
      write(dump, "-- MySQL dump\nCREATE TABLE keepers (body longtext);\nINSERT INTO keepers VALUES ('#{large_value}');\n")
      snapshots = []

      service.import_dump("acme", "initial", file: "dump.sql", exclude_tables: "sessions", progress_callback: proc { |stats| snapshots << stats })

      assert_equal :filtered, snapshots.last[:stream_mode]
      assert_equal runtime.last_stdin.bytesize, snapshots.last[:bytes_processed]
      assert_includes runtime.last_stdin, large_value
    end
  end

  def test_import_success_includes_elapsed_time_and_progress_is_not_per_line_for_non_tty
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme", "--db-type", "mariadb"])
      dump = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      write(dump, "-- MySQL dump\nCREATE TABLE users (id int);\nINSERT INTO users VALUES (1);\nINSERT INTO users VALUES (2);\n")

      assert_equal 0, cli.run(["import-dump", "acme", "initial", "--file", "dump.sql"])

      assert_includes out.string, "Time elapsed:"
      progress_lines = out.string.lines.grep(/Progress:/)
      assert_operator progress_lines.length, :<=, 4
    end
  end

  def test_trusted_inspect_command_writes_audit_artifacts
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme"])

      assert_equal 0, cli.run(["trusted", "inspect", "acme", "--reason", "Narrow check", "--", "echo", "raw-value"])

      project_path = SiloMigrate::Project.project_path("acme", env)
      assert_equal 1, Dir[File.join(project_path, "trusted", "inspections", "*.json")].length
      assert_equal 1, Dir[File.join(project_path, "trusted", "audit", "*.json")].length
      assert_includes out.string, "Trusted inspection artifact"
      refute_includes out.string, "raw-value"
    end
  end

  def test_ai_prepare_command_creates_safe_workspace
    with_tmp_base do |dir, env|
      env["SILO_MIGRATE_SAFE_AI_BASE_PATH"] = File.join(dir, "safe-ai")
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme"])
      project_path = SiloMigrate::Project.project_path("acme", env)
      write(File.join(project_path, "schema", "initial", "summary.json"), "{}\n")

      assert_equal 0, cli.run(["ai", "prepare", "acme"])

      assert File.exist?(File.join(dir, "safe-ai", "acme", "AGENTS.md"))
      assert File.exist?(File.join(dir, "safe-ai", "acme", "schema", "initial", "summary.json"))
      assert_includes out.string, "Safe AI workspace prepared"
    end
  end

  def test_schema_export_writes_schema_file
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme", "--db-type", "mariadb"])

      assert_equal 0, cli.run(["schema", "export", "acme"])

      schema = File.join(SiloMigrate::Project.project_path("acme", env), "schema", "initial_schema.sql")
      assert_includes File.read(schema), "CREATE TABLE exported"
      assert_includes runtime.commands.last[1], "mysqldump"
    end
  end

  def test_schema_bundle_writes_safe_metadata_artifacts
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme", "--db-type", "mariadb"])

      assert_equal 0, cli.run(["schema", "bundle", "acme"])

      bundle_dir = File.join(SiloMigrate::Project.project_path("acme", env), "schema", "initial")
      %w[schema.sql tables.json columns.json indexes.json summary.json migration_notes.md].each do |filename|
        assert File.exist?(File.join(bundle_dir, filename)), "Expected #{filename} to be written"
      end
      summary = JSON.parse(File.read(File.join(bundle_dir, "summary.json")))
      assert_equal 1, summary.fetch("artifact_version")
      assert_equal false, summary.fetch("contains_raw_rows")
      assert_equal "safe", summary.fetch("dev_ai_visibility")
      assert_equal 1, summary.fetch("table_count")
      tables = JSON.parse(File.read(File.join(bundle_dir, "tables.json")))
      assert_equal "exported", tables.first.fetch("name")
      assert_equal 2, tables.first.fetch("row_count_estimate")
      columns = JSON.parse(File.read(File.join(bundle_dir, "columns.json")))
      refute columns.any? { |column| column.key?("sample_values") }
      assert_includes out.string, "[OK] Schema bundle exported"
    end
  end

  def test_schema_bundle_supports_output_override_and_final_phase
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: StringIO.new)
      cli.run(["init", "acme", "--db-type", "mariadb", "--final-db-type", "postgres"])
      output_dir = File.join(dir, "custom-schema")

      assert_equal 0, cli.run(["schema", "bundle", "acme", "--phase", "final", "--output", output_dir])

      assert File.exist?(File.join(output_dir, "summary.json"))
      summary = JSON.parse(File.read(File.join(output_dir, "summary.json")))
      assert_equal "final", summary.fetch("phase")
      assert_equal "postgres", summary.fetch("db_type")
    end
  end

  def test_schema_bundle_requires_running_container
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      err = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: err)
      cli.run(["init", "acme", "--db-type", "mariadb"])
      runtime.running_containers["acme_initial_mariadb"] = false

      assert_equal 1, cli.run(["schema", "bundle", "acme"])
      assert_includes err.string, "Container acme_initial_mariadb is not running"
    end
  end

  def test_run_converter_uses_converter_profile_and_custom_command
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: StringIO.new)
      cli.run(["init", "acme"])

      assert_equal 0, cli.run(["run-converter", "acme", "--", "ruby", "converter.rb", "--dry-run"])

      assert_equal [:compose, "acme", ["--profile", "converter", "exec", "-T", "converter", "ruby", "converter.rb", "--dry-run"], true, nil], runtime.commands.last
    end
  end

  def test_run_converter_platform_shortcut_defaults_to_reset
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: StringIO.new)
      cli.run(["init", "acme"])
      create_converter_platform(env, "acme", "vbulletin")

      assert_equal 0, cli.run(["run-converter", "acme", "vbulletin"])

      assert_equal [:compose, "acme", ["--profile", "converter", "exec", "-T", "converter", "./convert", "--from", "vbulletin", "--reset"], true, nil], runtime.commands.last
    end
  end

  def test_run_converter_platform_shortcut_can_disable_reset
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: StringIO.new)
      cli.run(["init", "acme"])
      create_converter_platform(env, "acme", "vbulletin")

      assert_equal 0, cli.run(["run-converter", "acme", "vbulletin", "--no-reset"])

      assert_equal [:compose, "acme", ["--profile", "converter", "exec", "-T", "converter", "./convert", "--from", "vbulletin"], true, nil], runtime.commands.last
    end
  end

  def test_run_converter_platform_shortcut_accepts_settings_path
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: StringIO.new)
      cli.run(["init", "acme"])
      create_converter_platform(env, "acme", "vbulletin")

      assert_equal 0, cli.run(["run-converter", "acme", "vbulletin", "--settings", "/tmp/settings.yml"])

      assert_equal [:compose, "acme", ["--profile", "converter", "exec", "-T", "converter", "./convert", "--from", "vbulletin", "--reset", "--settings", "/tmp/settings.yml"], true, nil], runtime.commands.last
    end
  end

  def test_run_converter_platform_shortcut_requires_existing_platform
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      err = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: err)
      cli.run(["init", "acme"])
      create_converter_platform(env, "acme", "phpbb")

      assert_equal 1, cli.run(["run-converter", "acme", "vbulletin"])

      assert_includes err.string, "Converter platform not found: vbulletin"
      assert_includes err.string, "Available converters: phpbb"
    end
  end

  def test_run_converter_custom_command_without_separator_explains_escape_hatch
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      err = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: err)
      cli.run(["init", "acme"])

      assert_equal 1, cli.run(["run-converter", "acme", "ruby", "converter.rb"])

      assert_includes err.string, "Custom converter commands must be passed after '--'"
    end
  end

  def test_run_converter_redacted_logs_writes_timestamped_and_latest_artifacts
    with_tmp_base do |_dir, env|
      runtime = ConverterOutputRuntime.new
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme", "--password", "supersecret"])

      assert_equal 0, cli.run(["run-converter", "acme", "--redacted-logs", "--", "ruby", "converter.rb", "--dry-run"])

      artifact_dir = File.join(SiloMigrate::Project.project_path("acme", env), "findings", "redacted-logs")
      summaries = Dir[File.join(artifact_dir, "converter-run-*.summary.json")]
      logs = Dir[File.join(artifact_dir, "converter-run-*.log")]
      assert_equal 1, summaries.length
      assert_equal 1, logs.length
      assert File.exist?(File.join(artifact_dir, "latest.summary.json"))
      assert File.exist?(File.join(artifact_dir, "latest.log"))

      summary = JSON.parse(File.read(summaries.first))
      assert_equal ["ruby", "converter.rb", "--dry-run"], summary.fetch("command")
      assert_equal true, summary.fetch("success")
      assert_equal 0, summary.fetch("exit_status")
      assert_equal false, summary.dig("sources", "intermediate_db", "available")
      assert_includes out.string, "Redacted converter summary:"
      refute_includes File.read(logs.first), "supersecret"
    end
  end

  def test_failed_run_converter_redacted_logs_writes_artifacts_before_returning_failure
    with_tmp_base do |_dir, env|
      runtime = FailingConverterRuntime.new
      err = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: err)
      cli.run(["init", "acme"])

      assert_equal 1, cli.run(["run-converter", "acme", "--redacted-summary"])

      summary_path = File.join(SiloMigrate::Project.project_path("acme", env), "findings", "redacted-logs", "latest.summary.json")
      assert File.exist?(summary_path)
      summary = JSON.parse(File.read(summary_path))
      assert_equal false, summary.fetch("success")
      assert_equal 17, summary.fetch("exit_status")
      assert_includes err.string, "Converter command failed with exit code 17"
    end
  end

  def test_findings_generate_command_writes_findings_and_latest_index
    with_tmp_base do |_dir, env|
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme"])
      project_path = SiloMigrate::Project.project_path("acme", env)
      write(File.join(project_path, "findings", "redacted-logs", "latest.summary.json"), JSON.pretty_generate(cli_redacted_summary))

      assert_equal 0, cli.run(["findings", "generate", "acme"])

      findings = Dir[File.join(project_path, "findings", "finding-*.yml")]
      assert_equal 1, findings.length
      assert File.exist?(File.join(project_path, "findings", "latest-findings.json"))
      assert_includes out.string, "Findings index:"
    end
  end

  def test_findings_generate_command_supports_from_file
    with_tmp_base do |dir, env|
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new, error: StringIO.new)
      cli.run(["init", "acme"])
      summary_path = write(File.join(dir, "summary.json"), JSON.pretty_generate(cli_redacted_summary))

      assert_equal 0, cli.run(["findings", "generate", "acme", "--from", summary_path])

      index = JSON.parse(File.read(File.join(SiloMigrate::Project.project_path("acme", env), "findings", "latest-findings.json")))
      assert_equal "summary.json", index.fetch("source")
    end
  end

  def test_fixtures_generate_command_writes_shape_only_fixture_from_latest_findings
    with_tmp_base do |_dir, env|
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme"])
      project_path = SiloMigrate::Project.project_path("acme", env)
      finding_path = write(File.join(project_path, "findings", "finding-20260601-120000-001.yml"), cli_finding.to_yaml)
      write(
        File.join(project_path, "findings", "latest-findings.json"),
        JSON.pretty_generate("artifact_version" => 1, "findings" => [{ "id" => "finding-20260601-120000-001", "path" => File.basename(finding_path) }])
      )

      assert_equal 0, cli.run(["fixtures", "generate", "acme"])

      fixture_path = File.join(project_path, "synthetic-fixtures", "finding-20260601-120000-001.yml")
      assert File.exist?(fixture_path)
      fixture = YAML.safe_load(File.read(fixture_path))
      assert_equal "synthetic@example.test", fixture.dig("values", "email")
      assert_includes out.string, "Synthetic fixture:"
    end
  end

  def test_fixtures_generate_command_supports_from_file_or_dir
    with_tmp_base do |_dir, env|
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new, error: StringIO.new)
      cli.run(["init", "acme"])
      project_path = SiloMigrate::Project.project_path("acme", env)
      finding_dir = File.join(project_path, "findings")
      first = write(File.join(finding_dir, "finding-20260601-120000-001.yml"), cli_finding.to_yaml)
      second = write(File.join(finding_dir, "finding-20260601-120000-002.yml"), cli_finding("finding-20260601-120000-002").to_yaml)

      assert_equal 0, cli.run(["fixtures", "generate", "acme", "--from", first])
      assert_equal 0, cli.run(["fixtures", "generate", "acme", "--from", File.dirname(second)])

      assert File.exist?(File.join(project_path, "synthetic-fixtures", "finding-20260601-120000-001.yml"))
      assert File.exist?(File.join(project_path, "synthetic-fixtures", "finding-20260601-120000-002.yml"))
    end
  end

  def test_setup_converter_start_and_bundle_install_flags
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme"])
      converter_dir = File.join(SiloMigrate::Project.project_path("acme", env), "discourse-converters")
      FileUtils.mkdir_p(converter_dir)
      write(File.join(converter_dir, "Gemfile"), "source 'https://rubygems.org'\n")
      write(File.join(converter_dir, "convert"), "#!/usr/bin/env ruby\n")

      assert_equal 0, cli.run(["setup-converter", "acme", "--start", "--bundle-install"])

      assert_includes runtime.commands, [:compose, "acme", ["--profile", "converter", "up", "--build", "-d"], false, 300]
      assert_includes runtime.commands, [:run, ["docker", "exec", "acme_converter", "bundle", "install"], nil, false, 600, nil]
      assert_includes out.string, "[OK] Dependencies installed"
    end
  end

  def test_setup_converter_bundle_install_implies_start
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: StringIO.new)
      cli.run(["init", "acme"])
      converter_dir = File.join(SiloMigrate::Project.project_path("acme", env), "discourse-converters")
      FileUtils.mkdir_p(converter_dir)
      write(File.join(converter_dir, "Gemfile"), "source 'https://rubygems.org'\n")
      write(File.join(converter_dir, "convert"), "#!/usr/bin/env ruby\n")

      assert_equal 0, cli.run(["setup-converter", "acme", "--bundle-install"])

      assert_includes runtime.commands, [:compose, "acme", ["--profile", "converter", "up", "--build", "-d"], false, 300]
      assert_includes runtime.commands, [:run, ["docker", "exec", "acme_converter", "bundle", "install"], nil, false, 600, nil]
    end
  end

  def test_setup_converter_allows_terminal_ssh_prompt_flag
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: StringIO.new)
      cli.run(["init", "acme"])

      assert_equal 0, cli.run(["setup-converter", "acme", "--allow-ssh-prompt"])

      project_path = SiloMigrate::Project.project_path("acme", env)
      assert_includes runtime.commands, [
        :run,
        ["git", "clone", "-b", "main", SiloMigrate::Services::ProjectService::DEFAULT_CONVERTER_REPO, File.join(project_path, "discourse-converters")],
        nil,
        false,
        300,
        nil
      ]
      assert_equal false, runtime.last_run_options[:separate_process_group]
    end
  end

  def test_interactive_converter_bundle_failure_prints_fallback_and_continues
    with_tmp_base do |_dir, env|
      runtime = FailingBundleRuntime.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      prompt = FakePrompt.new(["Set up converter", ""])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_includes out.string, "bundle install failed or timed out"
      assert_includes out.string, "docker exec -it acme_converter bundle install"
    end
  end

  def test_guided_mode_uses_command_services
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      prompt = FakePrompt.new(["", "acme", "mariadb", "", "Skip for now"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run
      assert File.exist?(File.join(SiloMigrate::Project.project_path("acme", env), "config.env"))
      refute_includes out.string, "Project 'acme' not found."
      assert_empty prompt.asked.grep(/\ACreate it now\?/)
    end
  end

  def test_guided_mode_with_direct_missing_customer_confirms_before_create
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      prompt = FakePrompt.new(["", "mariadb", "", "Skip for now"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert File.exist?(File.join(SiloMigrate::Project.project_path("acme", env), "config.env"))
      assert_includes out.string, "Project 'acme' not found."
      assert_includes prompt.asked, "Create it now? [Y/n]"
    end
  end

  def test_guided_mode_stages_starts_and_imports_dump
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      schema = SiloMigrate::Services::SchemaService.new(runtime: runtime, env: env, output: out)
      source = write(File.join(dir, "dump.sql"), "-- MySQL dump\nCREATE TABLE users (id int);\nINSERT INTO users VALUES (1);\n")
      prompt = FakePrompt.new([
        "", "acme", "mariadb", "",
        "SQL dump file (.sql or .sql.gz)", source,
        "", "n", "n", ""
      ])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, schema_service: schema, prompt: prompt, output: out).run

      staged = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      assert File.exist?(staged)
      assert_includes runtime.commands, [:compose, "acme", ["--profile", "initial-db", "up", "-d"], false, 300]
      assert_includes runtime.commands, [:wait_for_health, "acme_initial_mariadb", 60]
      assert runtime.commands.any? { |command| command[0] == :run_stream }
      assert_includes runtime.last_stdin, "CREATE TABLE users"
      assert_equal 1, out.string.scan("Detected source format: sql").length
      refute_includes out.string, "Detected dump format: sql"
      assert File.exist?(File.join(project.project_path("acme"), "schema", "initial", "summary.json"))
    end
  end

  def test_guided_mode_accepts_converter_start_and_bundle_flow
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = FakeProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      prompt = FakePrompt.new(["Set up converter", ""])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_equal ["setup_converter", ["start_converter", true, false]], project.calls
    end
  end

  def test_guided_mode_can_generate_schema_bundle_from_main_actions
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      schema = SiloMigrate::Services::SchemaService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      write(File.join(project.project_path("acme"), "dumps", "initial", "dump.sql"), "-- MySQL dump\nCREATE TABLE users (id int);\n")
      prompt = FakePrompt.new(["Generate initial schema bundle"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, schema_service: schema, prompt: prompt, output: out).run("acme")

      assert File.exist?(File.join(project.project_path("acme"), "schema", "initial", "summary.json"))
      assert_includes out.string, "Container status:"
    end
  end

  def test_guided_mode_can_generate_schema_bundle_from_advanced_actions
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      schema = SiloMigrate::Services::SchemaService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      prompt = FakePrompt.new(["Advanced actions", "Generate schema bundle", "initial"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, schema_service: schema, prompt: prompt, output: out).run("acme")

      assert File.exist?(File.join(project.project_path("acme"), "schema", "initial", "summary.json"))
    end
  end

  def test_guided_mode_warns_when_automatic_schema_bundle_generation_fails
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      schema = FailingSchemaService.new
      source = write(File.join(dir, "dump.sql"), "-- MySQL dump\nCREATE TABLE users (id int);\nINSERT INTO users VALUES (1);\n")
      prompt = FakePrompt.new([
        "", "acme", "mariadb", "",
        "SQL dump file (.sql or .sql.gz)", source,
        "", "n", "n", ""
      ])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, schema_service: schema, prompt: prompt, output: out).run

      assert_includes out.string, "[OK] Dump imported successfully"
      assert_includes out.string, "[WARN] synthetic schema bundle failure"
    end
  end

  def test_guided_mode_shows_schema_bundle_status_in_summary
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      write(File.join(project.project_path("acme"), "schema", "initial", "summary.json"), "{}")
      prompt = FakePrompt.new(["Quit"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_includes out.string, "Schema bundle: initial"
    end
  end

  def test_guided_mode_can_run_converter_from_main_actions
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      converter_dir = File.join(project.project_path("acme"), "discourse-converters")
      FileUtils.mkdir_p(converter_dir)
      write(File.join(converter_dir, "Gemfile"), "source 'https://rubygems.org'\n")
      write(File.join(converter_dir, "convert"), "#!/usr/bin/env ruby\n")
      prompt = FakePrompt.new(["Run converter command", "ruby converter.rb --dry-run"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_includes runtime.commands, [:compose, "acme", ["--profile", "converter", "exec", "-T", "converter", "ruby", "converter.rb", "--dry-run"], true, nil]
      assert File.exist?(File.join(project.project_path("acme"), "findings", "redacted-logs", "latest.summary.json"))
      assert_includes prompt.asked, "Generate AI-safe redacted converter summary? [Y/n]"
    end
  end

  def test_guided_advanced_action_generates_redacted_converter_summary
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      prompt = FakePrompt.new(["Advanced actions", "Generate redacted summary from latest converter logs"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert File.exist?(File.join(project.project_path("acme"), "findings", "redacted-logs", "latest.summary.json"))
      assert_includes out.string, "Redacted converter summary:"
    end
  end

  def test_guided_post_summary_prompt_generates_findings_and_fixtures
    with_tmp_base do |_dir, env|
      runtime = FailingConverterRuntime.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      findings = SiloMigrate::Services::ConverterFindingsService.new(env: env, output: out)
      fixtures = SiloMigrate::Services::SyntheticFixtureService.new(env: env, output: out)
      project.init("acme")
      converter_dir = File.join(project.project_path("acme"), "discourse-converters")
      FileUtils.mkdir_p(converter_dir)
      write(File.join(converter_dir, "Gemfile"), "source 'https://rubygems.org'\n")
      write(File.join(converter_dir, "convert"), "#!/usr/bin/env ruby\n")
      prompt = FakePrompt.new(["Run converter command", "ruby converter.rb --dry-run", "", "", ""])

      SiloMigrate::Interactive.new(
        project_service: project,
        import_service: import,
        findings_service: findings,
        fixture_service: fixtures,
        prompt: prompt,
        output: out
      ).run("acme")

      assert File.exist?(File.join(project.project_path("acme"), "findings", "latest-findings.json"))
      assert_equal 1, Dir[File.join(project.project_path("acme"), "synthetic-fixtures", "*.yml")].length
      assert_includes prompt.asked, "Generate structured findings from this summary? [Y/n]"
      assert_includes prompt.asked, "Generate shape-only synthetic fixtures? [Y/n]"
    end
  end

  def test_guided_advanced_actions_generate_findings_and_fixtures
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      findings = SiloMigrate::Services::ConverterFindingsService.new(env: env, output: out)
      fixtures = SiloMigrate::Services::SyntheticFixtureService.new(env: env, output: out)
      project.init("acme")
      write(File.join(project.project_path("acme"), "findings", "redacted-logs", "latest.summary.json"), JSON.pretty_generate(cli_redacted_summary))
      prompt = FakePrompt.new(["Advanced actions", "Generate findings from latest redacted summary", ""])

      SiloMigrate::Interactive.new(
        project_service: project,
        import_service: import,
        findings_service: findings,
        fixture_service: fixtures,
        prompt: prompt,
        output: out
      ).run("acme")

      assert File.exist?(File.join(project.project_path("acme"), "findings", "latest-findings.json"))
      assert_equal 1, Dir[File.join(project.project_path("acme"), "synthetic-fixtures", "*.yml")].length

      prompt = FakePrompt.new(["Advanced actions", "Generate synthetic fixtures from latest findings"])
      SiloMigrate::Interactive.new(
        project_service: project,
        import_service: import,
        findings_service: findings,
        fixture_service: fixtures,
        prompt: prompt,
        output: out
      ).run("acme")

      assert_includes out.string, "Synthetic fixture:"
    end
  end

  def test_guided_mode_can_go_back_from_dump_format_menu
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      prompt = FakePrompt.new(["Add/import initial source dump", "Back", "Quit"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_includes out.string, "No changes made."
      refute runtime.commands.any? { |command| command[0] == :run_stream }
    end
  end

  def test_guided_mode_can_go_back_from_source_path_prompt
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      prompt = FakePrompt.new(["Add/import initial source dump", "SQL dump file (.sql or .sql.gz)", "back", "Quit"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_includes out.string, "No changes made."
      assert_empty Dir[File.join(project.project_path("acme"), "dumps", "initial", "*.sql")]
    end
  end

  def test_path_completion_returns_matching_files_and_directories
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: StringIO.new)
      interactive = SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: FakePrompt.new([]), output: StringIO.new)
      write(File.join(dir, "source.sql"), "-- MySQL dump\n")
      FileUtils.mkdir_p(File.join(dir, "source_dir"))

      Dir.chdir(dir) do
        completions = interactive.send(:complete_path, "source")
        assert_includes completions, "source.sql"
        assert_includes completions, "source_dir/"
      end
    end
  end

  def test_guided_mode_retries_converter_setup_with_terminal_ssh_prompt
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = RetryConverterProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      prompt = FakePrompt.new([
        "Set up converter",
        "y",
        "n"
      ])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_includes out.string, "Git SSH access is not available for github.com"
      assert_equal [
        [:setup_converter, SiloMigrate::Services::ProjectService::DEFAULT_CONVERTER_REPO, false],
        [:setup_converter, SiloMigrate::Services::ProjectService::DEFAULT_CONVERTER_REPO, true]
      ], project.calls
      refute_includes project.calls, [:start_converter, true, false]
    end
  end

  def test_guided_mode_retries_converter_setup_with_alternate_repo
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = RetryConverterProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      prompt = FakePrompt.new([
        "Set up converter",
        "n",
        "y",
        "https://github.com/discourse/discourse-converters.git",
        "n"
      ])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_equal [
        [:setup_converter, SiloMigrate::Services::ProjectService::DEFAULT_CONVERTER_REPO, false],
        [:setup_converter, "https://github.com/discourse/discourse-converters.git", false]
      ], project.calls
    end
  end

  def test_cli_guided_shortcut_returns_exit_status
    with_tmp_base do |_dir, env|
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out, error: StringIO.new)
      SiloMigrate::Interactive.stub(:new, FakeInteractive.new("/tmp/project")) do
        assert_equal 0, cli.run([])
        assert_equal 0, cli.run(["acme"])
      end
    end
  end

  def cli_redacted_summary
    {
      "artifact_version" => 1,
      "sources" => {
        "intermediate_db" => {
          "entries" => [
            {
              "type" => "error",
              "message" => "Failed for [EMAIL]",
              "exception" => "NoMethodError: undefined method",
              "details" => "[REDACTED_DETAILS]",
              "details_shape" => {
                "keys" => %w[email],
                "value_types" => { "email" => "email" },
                "redacted" => true
              }
            }
          ]
        },
        "process_output" => {
          "detected_errors" => []
        }
      }
    }
  end

  def cli_finding(id = "finding-20260601-120000-001")
    {
      "id" => id,
      "observed_shape" => {
        "keys" => %w[email],
        "value_types" => { "email" => "email" },
        "redacted" => true
      }
    }
  end

  def create_converter_platform(env, customer, platform)
    converter_dir = File.join(SiloMigrate::Project.project_path(customer, env), "discourse-converters")
    write(File.join(converter_dir, "Gemfile"), "source 'https://rubygems.org'\n")
    write(File.join(converter_dir, "convert"), "#!/usr/bin/env ruby\n")
    FileUtils.mkdir_p(File.join(converter_dir, "converters", platform))
  end

  class FakePrompt
    attr_reader :asked, :selected

    def initialize(answers)
      @answers = answers
      @asked = []
      @selected = []
    end

    def ask(message)
      @asked << message
      @answers.shift
    end

    def select(message, choices)
      @selected << message
      answer = @answers.shift
      choices.is_a?(Hash) ? choices.fetch(answer) : answer
    end
  end

  class FakeInteractive
    def initialize(result)
      @result = result
    end

    def run(_customer = nil)
      @result
    end
  end

  class FakeProjectService < SiloMigrate::Services::ProjectService
    attr_reader :calls

    def initialize(**kwargs)
      super(**kwargs)
      @calls = []
    end

    def setup_converter(customer, **_options)
      @calls << "setup_converter"
      FileUtils.mkdir_p(File.join(project_path(customer), "discourse-converters"))
    end

    def start_converter(_customer, bundle_install:, hard_fail:)
      @calls << ["start_converter", bundle_install, hard_fail]
    end
  end

  class FailingSchemaService
    def bundle(*)
      raise SiloMigrate::UsageError, "synthetic schema bundle failure"
    end
  end

  class RetryConverterProjectService < SiloMigrate::Services::ProjectService
    attr_reader :calls

    def initialize(**kwargs)
      super(**kwargs)
      @calls = []
    end

    def setup_converter(customer, repo: SiloMigrate::Services::ProjectService::DEFAULT_CONVERTER_REPO, allow_ssh_prompt: false, **_options)
      @calls << [:setup_converter, repo, allow_ssh_prompt]
      if @calls.length == 1
        raise SiloMigrate::UsageError, "Git SSH access is not available for github.com.\n1Password SSH agent"
      end

      FileUtils.mkdir_p(File.join(project_path(customer), "discourse-converters"))
    end

    def start_converter(_customer, bundle_install:, hard_fail:)
      @calls << [:start_converter, bundle_install, hard_fail]
    end
  end

  class FailingBundleRuntime < SiloMigrate::Runtime::Fake
    def run(cmd, chdir: nil, capture: false, timeout: nil, stdin_data: nil, separate_process_group: true)
      if cmd == ["docker", "exec", "acme_converter", "bundle", "install"]
        @commands << [:run, cmd, chdir, capture, timeout, stdin_data&.bytesize]
        return SiloMigrate::Runtime::CommandResult.new(success?: false, stdout: "", stderr: "Command timed out after #{timeout}s", status: nil)
      end

      super
    end
  end

  class ConverterOutputRuntime < SiloMigrate::Runtime::Fake
    def compose(customer, args, capture: false, timeout: 300)
      @operations << [:compose, customer, args, capture, timeout]
      @commands << [:compose, customer, args, capture, timeout]
      if args[0, 4] == ["--profile", "converter", "exec", "-T"]
        return SiloMigrate::Runtime::CommandResult.new(
          success?: true,
          stdout: "connected with supersecret\n",
          stderr: "warning: user jane.customer@example.com\n",
          status: 0
        )
      end

      super
    end
  end

  class FailingConverterRuntime < SiloMigrate::Runtime::Fake
    def compose(customer, args, capture: false, timeout: 300)
      @operations << [:compose, customer, args, capture, timeout]
      @commands << [:compose, customer, args, capture, timeout]
      if args[0, 4] == ["--profile", "converter", "exec", "-T"]
        return SiloMigrate::Runtime::CommandResult.new(
          success?: false,
          stdout: "partial output\n",
          stderr: "RuntimeError: failed converter\n",
          status: 17
        )
      end

      super
    end
  end
end
