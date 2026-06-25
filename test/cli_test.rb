# frozen_string_literal: true

require_relative "test_helper"

class CLITest < SiloMigrateTest
  def test_help_output
    out = StringIO.new
    code = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, output: out, error: StringIO.new).run(["--help"])
    assert_equal 0, code
    assert_includes out.string, "Usage: silo-migrate"
    assert_includes out.string, "convert-xml"
    assert_includes out.string, "convert-json"
    assert_includes out.string, "schema bundle"
    assert_includes out.string, "findings generate"
    assert_includes out.string, "fixtures generate"
    assert_includes out.string, "ai prepare"
    assert_includes out.string, "trusted inspect"
    assert_includes out.string, "trusted session"
    assert_includes out.string, "discourse setup"
    assert_includes out.string, "discourse import"
    assert_includes out.string, "--bundle-install also builds/starts"
    assert_includes out.string, "doctor"
    assert_includes out.string, "self-update"
    assert_includes out.string, "uninstall"
    assert_includes out.string, "converter summary"
    assert_includes out.string, "alias: go"
    assert_includes out.string, "migration-tool = silo-migrate"
  end

  def test_per_command_help
    out = StringIO.new
    cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, output: out, error: StringIO.new)

    assert_equal 0, cli.run(["help", "import-dump"])
    assert_includes out.string, "--fix-collations"
    assert_includes out.string, "--skip-health-wait"

    assert_equal 0, cli.run(["run-converter", "--help"])
    assert_includes out.string, "--settings PATH"
    assert_includes out.string, "/converter-settings"

    assert_equal 0, cli.run(["convert-xml", "--help"])
    assert_includes out.string, "--batch-size"
    assert_includes out.string, "--no-scrub-invalid-xml-chars"
    assert_includes out.string, "--invalid-xml-report"

    assert_equal 0, cli.run(["convert-json", "--help"])
    assert_includes out.string, "--schema-dir"
    assert_includes out.string, "--records-path"
    assert_includes out.string, "--no-graphql-unwrap"

    assert_equal 0, cli.run(["trusted", "--help"])
    assert_includes out.string, "mysql -u root -e"

    assert_equal 0, cli.run(["discourse", "--help"])
    assert_includes out.string, "restore-import"
    assert_includes out.string, "--no-uploads-db"

    assert_equal 0, cli.run(["self-update", "--help"])
    assert_includes out.string, "Pulls the managed Git checkout"
    assert_includes out.string, "Skips Docker host package and service management"

    assert_equal 0, cli.run(["uninstall", "--help"])
    assert_includes out.string, "Does not remove migration projects"
  end

  def test_self_update_command_uses_install_service
    Dir.mktmpdir do |dir|
      source_root = File.join(dir, "source")
      FileUtils.mkdir_p(File.join(source_root, ".git"))
      env = {
        "HOME" => dir,
        "SILO_MIGRATE_SOURCE_ROOT" => source_root,
        "SILO_MIGRATE_BIN_DIR" => File.join(dir, "bin")
      }
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)

      assert_equal 0, cli.run(["self-update"])
      assert_includes runtime.commands, [:run, ["git", "pull", "--ff-only"], source_root, true, 120, nil]
      assert_includes runtime.commands, [
        :run,
        [
          File.join(source_root, "script", "install"),
          "--install-deps",
          "--skip-docker",
          "--install-dir", source_root,
          "--bin-dir", File.join(dir, "bin"),
          "--repo", "https://github.com/RubenOussoren/silo-migrate.git",
          "--branch", "main"
        ],
        source_root,
        false,
        1_200,
        nil
      ]
      assert_includes out.string, "silo-migrate"
    end
  end

  def test_uninstall_command_uses_install_service
    Dir.mktmpdir do |dir|
      source_root = File.join(dir, "source")
      FileUtils.mkdir_p(File.join(source_root, ".git"))
      env = {
        "HOME" => dir,
        "SILO_MIGRATE_SOURCE_ROOT" => source_root,
        "SILO_MIGRATE_BIN_DIR" => File.join(dir, "bin")
      }
      runtime = SiloMigrate::Runtime::Fake.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: StringIO.new, error: StringIO.new)

      assert_equal 0, cli.run(["uninstall"])
      assert_includes runtime.commands, [
        :run,
        [
          File.join(source_root, "script", "install"),
          "--uninstall",
          "--install-dir", source_root,
          "--bin-dir", File.join(dir, "bin"),
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

  def test_convert_json_command_writes_sql_output
    with_tmp_base do |dir, env|
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out, error: StringIO.new)
      input = write(File.join(dir, "users.json"), '{"object_name": "users", "data": [{"id": "user:1"}]}')

      capture_io do
        assert_equal 0, cli.run(["convert-json", input])

        cli.run(["init", "acme"])
        assert_equal 0, cli.run(["convert-json", input, "-c", "acme"])
      end

      assert_includes File.read(File.join(dir, "users.sql")), "CREATE TABLE `users`"
      customer_sql = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "users.sql")
      assert File.exist?(customer_sql)
      assert_includes out.string, "import-dump acme initial"
    end
  end

  def test_convert_xml_command_scrubs_invalid_controls_and_honors_custom_report_path
    with_tmp_base do |dir, env|
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out, error: StringIO.new)
      input = write(File.join(dir, "messages.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump>
          <database name="forum">
            <table_structure name="messages"><field Field="body" Type="text" Null="YES" /></table_structure>
            <table_data name="messages"><row><field name="body"><![CDATA[before\x1Bafter]]></field></row></table_data>
          </database>
        </mysqldump>
      XML
      report = File.join(dir, "audit.summary.json")

      capture_io do
        assert_equal 0, cli.run(["convert-xml", input, "--invalid-xml-report", report])
      end

      assert_includes File.read(File.join(dir, "messages.sql")), "'beforeafter'"
      assert_equal 1, JSON.parse(File.read(report)).fetch("total_scrubbed")
      assert File.exist?(File.join(dir, "audit.events.jsonl"))
    end
  end

  def test_convert_xml_command_can_disable_invalid_control_scrubbing
    with_tmp_base do |dir, env|
      err = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new, error: err)
      input = write(File.join(dir, "messages.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump><database name="forum"><table_data name="messages"><row><field name="body">bad\x1Bbody</field></row></table_data></database></mysqldump>
      XML

      capture_io do
        assert_equal 1, cli.run(["convert-xml", input, "--no-scrub-invalid-xml-chars"])
      end

      assert_includes err.string, "Invalid XML control character U+001B"
      assert_includes err.string, "--no-scrub-invalid-xml-chars"
      refute File.exist?(File.join(dir, "messages.sql"))
    end
  end

  def test_converter_summary_standalone_command
    with_tmp_base do |_dir, env|
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme"])

      assert_equal 0, cli.run(["converter", "summary", "acme"])

      artifact_dir = File.join(SiloMigrate::Project.project_path("acme", env), "findings", "redacted-logs")
      assert File.exist?(File.join(artifact_dir, "latest.summary.json"))
      summary = JSON.parse(File.read(File.join(artifact_dir, "latest.summary.json")))
      assert_equal false, summary.dig("sources", "intermediate_db", "available")
      assert_includes out.string, "Redacted converter summary:"
    end
  end

  def test_discourse_cli_setup_and_import_commands
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)
      assert_equal 0, cli.run(["init", "acme"])

      docker_path = File.join(dir, "discourse")
      FileUtils.mkdir_p(docker_path)
      launcher = write(File.join(docker_path, "launcher"), "#!/usr/bin/env bash\n")
      FileUtils.chmod(0o755, launcher)
      assert_equal 0, cli.run(["discourse", "setup", "acme", "--docker-path", docker_path, "--uploads-port", "18080", "--import-port", "18081"])
      write(File.join(SiloMigrate::Project.project_path("acme", env), "output", "intermediate.db"), "sqlite")
      assert_equal 0, cli.run(["discourse", "import", "acme"])

      assert File.exist?(File.join(docker_path, "containers", "acme-uploads.yml"))
      import_command = runtime.commands.reverse.find { |entry| entry[0] == :run && entry[1].join(" ").include?("generic_bulk.rb") }
      assert_equal "acme-import", import_command[1][2]
      refute_includes import_command[1].join(" "), "uploads.sqlite3"
      assert_includes out.string, "Discourse containers configured"
    end
  end

  def test_discourse_cli_install_launcher_command
    with_tmp_base do |dir, env|
      env = env.merge("SILO_MIGRATE_HOST_OS" => "linux")
      runtime = SiloMigrate::Runtime::Fake.new
      def runtime.run(cmd, **kwargs)
        result = super
        if cmd[0, 3] == ["git", "clone", "-b"] && cmd[4].include?("discourse_docker")
          target = cmd.last
          FileUtils.mkdir_p(target)
          File.write(File.join(target, "launcher"), "#!/usr/bin/env bash\n")
          FileUtils.chmod(0o755, File.join(target, "launcher"))
        end
        result
      end

      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)
      docker_path = File.join(dir, "discourse")

      assert_equal 0, cli.run(["discourse", "install-launcher", "--docker-path", docker_path])

      assert File.executable?(File.join(docker_path, "launcher"))
      assert runtime.commands.any? { |command| command[0] == :run && command[1][0, 3] == ["git", "clone", "-b"] }
      assert_includes out.string, "Discourse Docker launcher installed"
    end
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

  def test_import_preflight_queries_mysql_variables_and_disk_on_default_runtime
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      service = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new).init("acme", db_type: "mariadb")
      dump = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      write(dump, "-- MySQL dump\nCREATE TABLE users (id int);\n")

      service.import_dump("acme", "initial", file: "dump.sql", progress_callback: proc { |_stats| })

      assert runtime.operations.any? { |operation| operation.first == :mysql_variables }
      assert runtime.operations.any? { |operation| operation.first == :container_disk_free }
      assert_includes out.string, "Import preflight:"
      assert_includes out.string, "innodb_flush_method=fsync"
    end
  end

  def test_macos_docker_desktop_large_mariadb_preflight_blocks_unsafe_innodb_settings
    with_tmp_base do |_dir, env|
      env["SILO_MIGRATE_HOST_OS"] = "darwin"
      env["SILO_MIGRATE_LARGE_IMPORT_BYTES"] = "1"
      runtime = SiloMigrate::Runtime::Fake.new
      runtime.docker_desktop_result = true
      runtime.mysql_variables_result = {
        "innodb_flush_method" => "O_DIRECT",
        "innodb_use_native_aio" => "ON",
        "innodb_flush_log_at_trx_commit" => "0"
      }
      out = StringIO.new
      service = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new).init("acme", db_type: "mariadb")
      dump = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      write(dump, "-- XML dumps are generated in autocommit mode\nCREATE TABLE users (id int);\n")

      error = assert_raises(SiloMigrate::UsageError) do
        service.import_dump("acme", "initial", file: "dump.sql", progress_callback: proc { |_stats| })
      end

      assert_includes out.string, "Large XML-converted MariaDB imports on macOS Docker Desktop"
      assert_includes error.message, "Unsafe MariaDB InnoDB settings"
      assert_includes error.message, "silo-migrate regenerate acme"
      assert_includes error.message, "silo-migrate replace-dump acme initial --yes"
      assert_includes error.message, "silo-migrate start acme --profile initial-db --wait"
      assert_includes error.message, "silo-migrate import-dump acme initial --file dump.sql"
      refute runtime.operations.any? { |operation| operation.first == :run_with_stdin }
    end
  end

  def test_import_failure_1180_reports_statement_diagnostics_without_row_values
    with_tmp_base do |_dir, env|
      runtime = FailingImportRuntime.new("ERROR 1180 (HY000) at line 3: Got error 1 \"Operation not permitted\" during COMMIT\n")
      out = StringIO.new
      service = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new).init("acme", db_type: "mariadb")
      dump = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql")
      write(dump, <<~SQL)
        -- XML dumps are generated in autocommit mode
        CREATE TABLE `users` (`id` int, `name` varchar(255));
        INSERT INTO `users` (`id`, `name`) VALUES
          (1, 'synthetic-secret-one'),
          (2, 'synthetic-secret-two');
      SQL

      error = assert_raises(SiloMigrate::UsageError) do
        service.import_dump("acme", "initial", file: "dump.sql", progress_callback: proc { |_stats| })
      end

      assert_includes error.message, "Import failure diagnostics:"
      assert_includes error.message, "Reported SQL line: 3"
      assert_includes error.message, "Statement table: users"
      assert_includes error.message, "Statement lines: 3-5"
      assert_includes error.message, "Statement rows: 2"
      assert_includes error.message, "Dump transaction markers: no"
      assert_includes error.message, "retry the same import on Linux"
      refute_includes error.message, "synthetic-secret-one"
      refute_includes error.message, "synthetic-secret-two"
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

  def test_ai_prepare_writes_safe_artifacts_into_converter_clone
    with_tmp_base do |_dir, env|
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme"])
      project_path = SiloMigrate::Project.project_path("acme", env)
      create_converter_platform(env, "acme", "fixture")
      write(File.join(project_path, "schema", "initial", "summary.json"), "{}\n")

      assert_equal 0, cli.run(["ai", "prepare", "acme"])

      clone = File.join(project_path, "discourse-converters")
      assert File.exist?(File.join(clone, "AGENTS.md"))
      assert File.exist?(File.join(clone, "safe-artifacts", "schema", "initial", "summary.json"))
      assert File.exist?(File.join(clone, "safe-artifacts", "manifest.json"))
      assert_includes out.string, "Safe artifacts prepared"
    end
  end

  def test_ai_prepare_without_converter_clone_fails_with_setup_hint
    with_tmp_base do |_dir, env|
      err = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new, error: err)
      cli.run(["init", "acme"])

      assert_equal 1, cli.run(["ai", "prepare", "acme"])
      assert_includes err.string, "setup-converter"
    end
  end

  def test_findings_generate_auto_refreshes_safe_artifacts
    with_tmp_base do |_dir, env|
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme"])
      project_path = SiloMigrate::Project.project_path("acme", env)
      create_converter_platform(env, "acme", "fixture")
      write(File.join(project_path, "findings", "redacted-logs", "latest.summary.json"), JSON.pretty_generate(cli_redacted_summary))

      assert_equal 0, cli.run(["ai", "prepare", "acme"])
      safe = File.join(project_path, "discourse-converters", "safe-artifacts")
      stale = write(File.join(safe, "findings", "finding-stale.yml"), "id: finding-stale\ndev_visibility: safe\n")

      assert_equal 0, cli.run(["findings", "generate", "acme"])

      refute File.exist?(stale), "auto-refresh should have rebuilt safe-artifacts"
      assert(Dir[File.join(safe, "findings", "finding-*.yml")].any?, "fresh findings should be mirrored into safe-artifacts")
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

  def test_run_converter_platform_shortcut_generates_in_network_settings
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme", "--db-type", "mariadb", "--password", "topsecret"])
      create_converter_platform(env, "acme", "vbulletin")
      settings_defaults = File.join(SiloMigrate::Project.project_path("acme", env), "discourse-converters", "converters", "vbulletin", "settings.yml")
      write(settings_defaults, "database:\n  host: \"127.0.0.1\"\n  port: 3306\n  username: \"root\"\n  password: \"x\"\n  database: \"y\"\n")

      assert_equal 0, cli.run(["run-converter", "acme", "vbulletin"])

      exec_args = runtime.commands.last[2]
      assert_includes exec_args, "--settings"
      assert_includes exec_args, "/converter-settings/vbulletin.yml"
      generated = File.join(SiloMigrate::Project.project_path("acme", env), "converter-settings", "vbulletin.yml")
      assert File.exist?(generated)
      assert_includes File.read(generated), "acme_initial_mariadb"
    end
  end

  def test_run_converter_platform_shortcut_falls_back_when_settings_cannot_be_generated
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: StringIO.new)
      cli.run(["init", "acme"])
      create_converter_platform(env, "acme", "vbulletin")

      assert_equal 0, cli.run(["run-converter", "acme", "vbulletin"])

      assert_equal [:compose, "acme", ["--profile", "converter", "exec", "-T", "converter", "./convert", "--from", "vbulletin", "--reset"], true, nil], runtime.commands.last
      assert_includes out.string, "Could not generate converter settings"
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
      prompt = FakePrompt.new(["Converter setup", "y", ""])

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
      assert_includes out.string, "Import target:"
      assert_includes out.string, "Dump: dump.sql"
      assert_includes out.string, "Path: #{staged}"
      assert File.exist?(File.join(project.project_path("acme"), "schema", "initial", "summary.json"))
      marker = File.join(project.project_path("acme"), "dumps", "initial", ".imported.json")
      assert File.exist?(marker)
    end
  end

  def test_guided_import_requires_selection_when_multiple_dumps_are_staged
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme", db_type: "mariadb")
      first = write(File.join(project.project_path("acme"), "dumps", "initial", "first.sql"), "-- MySQL dump\nCREATE TABLE first_table (id int);\n")
      second = write(File.join(project.project_path("acme"), "dumps", "initial", "second.sql"), "-- MySQL dump\nCREATE TABLE second_table (id int);\n")
      selected_label = "#{File.basename(second)} (#{SiloMigrate::DumpTools.format_size(File.size(second))})"
      prompt = FakePrompt.new(["Initial dump", "y", "Use existing dump", selected_label, "y", "n", "n", "n"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_includes prompt.selected, "Select initial dump to import"
      assert_includes out.string, "Dump: second.sql"
      assert_includes out.string, "Path: #{second}"
      refute_includes out.string, "Path: #{first}\n"
      assert_includes runtime.last_stdin, "CREATE TABLE second_table"
    end
  end

  def test_guided_import_port_conflict_cancel_does_not_start_docker
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme", db_type: "mariadb", initial_port: 3310)
      runtime.running_containers["acme_initial_mariadb"] = false
      write(File.join(project.project_path("acme"), "dumps", "initial", "dump.sql"), "-- MySQL dump\nCREATE TABLE users (id int);\n")
      prompt = FakePrompt.new(["Initial dump", "y", "Use existing dump", "y", "Cancel start/import"])

      project.stub(:port_listening?, ->(_port) { true }) do
        SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")
      end

      refute runtime.commands.any? { |command| command[0] == :compose && command[2].include?("up") }
      refute File.exist?(File.join(project.project_path("acme"), "dumps", "initial", ".imported.json"))
      assert_includes out.string, "Docker cannot start these database services"
      assert_includes out.string, "Start cancelled because configured port is in use"
    end
  end

  def test_guided_import_port_conflict_can_change_port_and_retry
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme", db_type: "mariadb", initial_port: 3310)
      runtime.running_containers["acme_initial_mariadb"] = false
      write(File.join(project.project_path("acme"), "dumps", "initial", "dump.sql"), "-- MySQL dump\nCREATE TABLE users (id int);\n")
      prompt = FakePrompt.new(["Initial dump", "y", "Use existing dump", "y", "Use another available port", "n", "n"])

      project.stub(:port_listening?, ->(port) { port.to_i == 3310 }) do
        project.stub(:available_port, ->(_preferred, avoid: []) { 3311 }) do
          SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")
        end
      end

      config = SiloMigrate::Project.load_config("acme", env)
      assert_equal "3311", config["INITIAL_PORT"]
      assert runtime.commands.any? { |command| command[0] == :compose && command[2].include?("up") }
      assert File.exist?(File.join(project.project_path("acme"), "dumps", "initial", ".imported.json"))
      assert_includes out.string, "Retrying start with updated ports"
      assert_includes out.string, "Dump imported successfully"
    end
  end

  def test_guided_import_failure_skips_marker_and_schema_bundle
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = FailingImportService.new
      schema = SiloMigrate::Services::SchemaService.new(runtime: runtime, env: env, output: out)
      project.init("acme", db_type: "mariadb")
      dump = write(File.join(project.project_path("acme"), "dumps", "initial", "dump.sql"), "-- MySQL dump\nCREATE TABLE users (id int);\n")
      prompt = FakePrompt.new(["Initial dump", "y", "Use existing dump", "y", "n", "n"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, schema_service: schema, prompt: prompt, output: out).run("acme")

      refute File.exist?(File.join(project.project_path("acme"), "dumps", "initial", ".imported.json"))
      refute File.exist?(File.join(project.project_path("acme"), "schema", "initial", "summary.json"))
      assert_includes out.string, "Dump: dump.sql"
      assert_includes out.string, "Path: #{dump}"
      assert_includes out.string, "[WARN] synthetic import failure"
      assert_includes out.string, "[WARN] Import did not complete; reset DB data before retrying this dump."
    end
  end

  def test_guided_mode_accepts_converter_start_and_bundle_flow
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = FakeProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      prompt = FakePrompt.new(["Converter setup", "y", ""])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_equal ["setup_converter", ["start_converter", true, false]], project.calls
    end
  end

  def test_guided_main_menu_uses_workflow_actions
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      prompt = FakePrompt.new(["Quit"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      main_menu = prompt.choice_sets.find { |message, _choices| message == "Migration workflow" }.last
      assert_includes main_menu, "Initial dump"
      assert_includes main_menu, "Final dump"
      assert_includes main_menu, "Converter setup"
      assert_includes main_menu, "Discourse uploads container"
      assert_includes main_menu, "Discourse import container"
      refute_includes main_menu, "Generate initial schema bundle"
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
      prompt = FakePrompt.new(["Advanced actions", "Initial dump/database actions", "Generate initial schema bundle"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, schema_service: schema, prompt: prompt, output: out).run("acme")

      assert File.exist?(File.join(project.project_path("acme"), "schema", "initial", "summary.json"))
    end
  end

  def test_guided_advanced_actions_are_grouped
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      prompt = FakePrompt.new(["Advanced actions", "Back", "Quit"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      groups = prompt.choice_sets.find { |message, _choices| message == "Advanced action group" }.last
      assert_includes groups, "Initial dump/database actions"
      assert_includes groups, "Final dump/database actions"
      assert_includes groups, "Conversion actions"
      assert_includes groups, "Converter actions"
      assert_includes groups, "Discourse uploads container actions"
      assert_includes groups, "Discourse import container actions"
      assert_includes groups, "Project/service actions"
    end
  end

  def test_guided_discourse_uploads_workflow_uses_uploads_role
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      discourse = FakeDiscourseService.new
      project.init("acme")
      prompt = FakePrompt.new(["Discourse uploads container", "y"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, discourse_service: discourse, prompt: prompt, output: out).run("acme")

      assert_equal [
        [:setup, "acme"],
        [:rebuild, "acme", "uploads"],
        [:start, "acme", "uploads"],
        [:prepare_deps, "acme", "uploads"],
        [:run_uploads, "acme"]
      ], discourse.calls
    end
  end

  def test_guided_discourse_uploads_workflow_stops_after_setup_without_intermediate_db
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      discourse = FakeDiscourseService.new(status_details: { intermediate_db: false })
      project.init("acme")
      prompt = FakePrompt.new(["Discourse uploads container", "y"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, discourse_service: discourse, prompt: prompt, output: out).run("acme")

      assert_equal [
        [:setup, "acme"],
        [:rebuild, "acme", "uploads"],
        [:start, "acme", "uploads"]
      ], discourse.calls
      assert_includes out.string, "output/intermediate.db is missing"
      assert_includes out.string, "Run the converter"
    end
  end

  def test_guided_discourse_import_workflow_imports_intermediate_only_when_selected
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      discourse = FakeDiscourseService.new
      project.init("acme")
      prompt = FakePrompt.new(["Discourse import container", "y", "Import intermediate.db only"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, discourse_service: discourse, prompt: prompt, output: out).run("acme")

      assert_equal [
        [:setup, "acme"],
        [:rebuild, "acme", "import"],
        [:start, "acme", "import"],
        [:prepare_deps, "acme", "import"],
        [:import, "acme", true]
      ], discourse.calls
    end
  end

  def test_guided_discourse_import_workflow_can_restore_only
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      discourse = FakeDiscourseService.new(status_details: { intermediate_db: false })
      project.init("acme")
      backup = write(File.join(dir, "backup.tar.gz"), "backup")
      prompt = FakePrompt.new(["Discourse import container", "y", "Restore backup onto import container", backup])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, discourse_service: discourse, prompt: prompt, output: out).run("acme")

      assert_equal [
        [:setup, "acme"],
        [:rebuild, "acme", "import"],
        [:start, "acme", "import"],
        [:restore_import, "acme", backup]
      ], discourse.calls
    end
  end

  def test_guided_discourse_import_workflow_can_run_uploads_then_final_import
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      discourse = FakeDiscourseService.new
      project.init("acme")
      prompt = FakePrompt.new(["Discourse import container", "y", "Run uploads importer, then import intermediate.db + uploads.sqlite3"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, discourse_service: discourse, prompt: prompt, output: out).run("acme")

      assert_equal [
        [:setup, "acme"],
        [:rebuild, "acme", "import"],
        [:start, "acme", "import"],
        [:rebuild, "acme", "uploads"],
        [:start, "acme", "uploads"],
        [:prepare_deps, "acme", "uploads"],
        [:run_uploads, "acme"],
        [:prepare_deps, "acme", "import"],
        [:import, "acme", false]
      ], discourse.calls
    end
  end

  def test_guided_discourse_import_workflow_can_generate_backup_only
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      discourse = FakeDiscourseService.new(status_details: { intermediate_db: false })
      project.init("acme")
      prompt = FakePrompt.new(["Discourse import container", "y", "Generate final backup"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, discourse_service: discourse, prompt: prompt, output: out).run("acme")

      assert_equal [
        [:setup, "acme"],
        [:rebuild, "acme", "import"],
        [:start, "acme", "import"],
        [:backup_import, "acme"]
      ], discourse.calls
    end
  end

  def test_guided_discourse_import_workflow_bootstraps_and_done_without_intermediate_db
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      discourse = FakeDiscourseService.new(status_details: { intermediate_db: false })
      project.init("acme")
      prompt = FakePrompt.new(["Discourse import container", "y", "Done"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, discourse_service: discourse, prompt: prompt, output: out).run("acme")

      assert_equal [
        [:setup, "acme"],
        [:rebuild, "acme", "import"],
        [:start, "acme", "import"]
      ], discourse.calls
      refute discourse.calls.any? { |call| call.first == :restore_import }
      refute_includes discourse.calls, [:import, "acme", false]
      refute discourse.calls.any? { |call| call.first == :backup_import }
      menu = prompt.choice_sets.find { |message, _choices| message == "Discourse import container action" }.last
      assert_includes menu, "Restore backup onto import container"
      assert_includes menu, "Generate final backup"
      refute_includes menu, "Import intermediate.db only"
      refute_includes menu, "Run uploads importer, then import intermediate.db + uploads.sqlite3"
    end
  end

  def test_guided_advanced_import_restore_action_remains_explicitly_available_without_intermediate_db
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      discourse = FakeDiscourseService.new(status_details: { intermediate_db: false })
      project.init("acme")
      backup = write(File.join(dir, "backup.tar.gz"), "backup")
      prompt = FakePrompt.new(["Advanced actions", "Discourse import container actions", "Restore backup onto import container", backup])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, discourse_service: discourse, prompt: prompt, output: out).run("acme")

      assert_includes discourse.calls, [:restore_import, "acme", backup]
    end
  end

  def test_guided_discourse_dependency_actions_are_role_specific
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      discourse = FakeDiscourseService.new
      project.init("acme")
      prompt = FakePrompt.new(["Advanced actions", "Discourse uploads container actions", "Prepare uploads-container dependencies"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, discourse_service: discourse, prompt: prompt, output: out).run("acme")

      assert_includes discourse.calls, [:prepare_deps, "acme", "uploads"]

      discourse = FakeDiscourseService.new
      prompt = FakePrompt.new(["Advanced actions", "Discourse import container actions", "Prepare import-container dependencies"])
      SiloMigrate::Interactive.new(project_service: project, import_service: import, discourse_service: discourse, prompt: prompt, output: out).run("acme")

      assert_includes discourse.calls, [:prepare_deps, "acme", "import"]
    end
  end

  def test_guided_advanced_convert_xml_shows_progress_and_stages_dump
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      xml_dir = File.join(dir, "xml")
      write(File.join(xml_dir, "users.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump>
          <database name="forum">
            <table_structure name="users">
              <field Field="id" Type="int" Null="NO" Key="PRI" />
              <options Name="users" Rows="1234567" Data_length="157286400" Index_length="524288" />
            </table_structure>
            <table_data name="users"><row><field name="id">1</field></row></table_data>
          </database>
        </mysqldump>
      XML
      prompt = FakePrompt.new(["Advanced actions", "Conversion actions", "Convert XML dump", "initial", xml_dir])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      staged = File.join(project.project_path("acme"), "dumps", "initial", "combined.sql.gz")
      assert File.exist?(staged)
      assert_includes out.string, "Converting XML dump..."
      assert_includes out.string, "XML files found:"
      assert_includes out.string, "Largest tables discovered (showing 1 of 1, sorted by total size):"
      assert_includes out.string, "- users (rows 1234567, data 150.0 MB, index 512.0 KB, total 150.5 MB)"
      assert_includes out.string, "Files to process: 1"
      assert_includes out.string, "Processing 1/1: users.xml"
      assert_includes out.string, "First table detected: users"
      assert_includes out.string, "First row converted from users"
      assert_includes out.string, "Conversion output size:"
      assert_includes out.string, "[OK] XML converted and staged"
      assert_includes out.string, "[OK] XML converted:"
      assert_includes prompt.asked, "XML table filter: all, include, or exclude (blank for all; largest: users)"
    end
  end

  def test_guided_initial_dump_flow_converts_single_xml_file
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      xml_file = write(File.join(dir, "intel_20260609.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump>
          <database name="forum">
            <table_structure name="users">
              <field Field="id" Type="int" Null="NO" Key="PRI" />
              <options Name="users" Rows="12" Data_length="1048576" Index_length="524288" />
            </table_structure>
            <table_data name="users"><row><field name="id">1</field></row></table_data>
          </database>
        </mysqldump>
      XML
      prompt = FakePrompt.new([
        "Initial dump",
        "y",
        "XML dump files (mysqldump --xml)",
        xml_file,
        "",
        "",
        "",
        "n",
        "Quit"
      ])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      staged = File.join(project.project_path("acme"), "dumps", "initial", "intel_20260609.sql.gz")
      assert File.exist?(staged)
      refute File.exist?(File.join(project.project_path("acme"), "dumps", "initial", "combined.sql.gz"))
      sql = Zlib::GzipReader.open(staged, &:read)
      assert_includes sql, "CREATE TABLE `users`"
      assert_includes out.string, "Files found: 1"
      assert_includes out.string, "Input size:"
      assert_includes out.string, "across 1 file"
      assert_includes out.string, "Largest tables discovered (showing 1 of 1, sorted by total size):"
      assert_includes out.string, "- users (rows 12, data 1.0 MB, index 512.0 KB, total 1.5 MB)"
      assert_includes out.string, "Processing 1/1: intel_20260609.xml"
      assert_includes out.string, "Dump: intel_20260609.sql.gz"
      refute_includes prompt.asked, "Exclude any XML files from conversion? [y/N]"
    end
  end

  def test_guided_xml_discovery_shows_no_more_than_50_tables_sorted_by_size
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      structures = (1..55).map do |index|
        <<~XML
          <table_structure name="table_#{format('%03d', index)}">
            <field Field="id" Type="int" Null="NO" Key="PRI" />
            <options Name="table_#{format('%03d', index)}" Rows="#{index}" Data_length="#{index * 1024}" Index_length="0" />
          </table_structure>
        XML
      end.join
      xml_file = write(File.join(dir, "many.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump><database name="forum">#{structures}</database></mysqldump>
      XML
      prompt = FakePrompt.new(["Advanced actions", "Conversion actions", "Convert XML dump", "initial", xml_file, "", "", "n", "Quit"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_includes out.string, "Largest tables discovered (showing 50 of 55, sorted by total size):"
      table_lines = out.string.lines.drop_while { |line| !line.include?("Largest tables discovered") }.drop(1).take_while { |line| !line.include?("Discovery by file:") }
      table_lines = table_lines.select { |line| line.start_with?("  - ") }
      assert_equal 50, table_lines.length
      assert_includes table_lines.first, "table_055"
      refute table_lines.any? { |line| line.include?("table_001") }
    end
  end

  def test_guided_convert_xml_writes_project_invalid_control_report
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      xml_file = write(File.join(dir, "forum.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump>
          <database name="forum">
            <table_structure name="messages"><field Field="body" Type="text" Null="YES" /></table_structure>
            <table_data name="messages"><row><field name="body"><![CDATA[before\x1Bafter]]></field></row></table_data>
          </database>
        </mysqldump>
      XML
      prompt = FakePrompt.new(["Advanced actions", "Conversion actions", "Convert XML dump", "initial", xml_file, "", "", "n", "n"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      dump_dir = File.join(project.project_path("acme"), "dumps", "initial")
      reports = Dir[File.join(dump_dir, "xml-invalid-chars-*.summary.json")]
      assert_equal 1, reports.length
      summary = JSON.parse(File.read(reports.first))
      assert_equal 1, summary.fetch("total_scrubbed")
      assert_equal true, summary.fetch("success")
      assert File.exist?(reports.first.sub(/\.summary\.json\z/, ".events.jsonl"))
      assert_includes out.string, "Removed 1 XML-forbidden control character."
      assert_includes out.string, "Invalid XML audit: #{reports.first}"
    end
  end

  def test_guided_advanced_convert_xml_can_exclude_files_by_base_name
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      xml_dir = File.join(dir, "xml")
      write(File.join(xml_dir, "users.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump>
          <database name="forum">
            <table_structure name="users"><field Field="id" Type="int" Null="NO" Key="PRI" /></table_structure>
            <table_data name="users"><row><field name="id">1</field></row></table_data>
          </database>
        </mysqldump>
      XML
      write(File.join(xml_dir, "email_tracking2.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump>
          <database name="forum">
            <table_structure name="email_tracking"><field Field="id" Type="int" Null="NO" Key="PRI" /></table_structure>
            <table_data name="email_tracking"><row><field name="id">1</field></row></table_data>
          </database>
        </mysqldump>
      XML
      prompt = FakePrompt.new(["Advanced actions", "Conversion actions", "Convert XML dump", "initial", xml_dir, "y", "email_tracking2"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      staged = File.join(project.project_path("acme"), "dumps", "initial", "combined.sql.gz")
      sql = Zlib::GzipReader.open(staged, &:read)
      assert_includes sql, "CREATE TABLE `users`"
      refute_includes sql, "email_tracking"
      assert_includes out.string, "Files found: 2"
      assert_includes out.string, "Files to skip: 1"
      assert_includes out.string, "- email_tracking2.xml"
      assert_includes out.string, "Files skipped before table discovery: 1"
      assert_includes out.string, "Files to process: 1"
      assert_includes prompt.asked, "Exclude any XML files from conversion? [y/N]"
      assert_includes prompt.asked, "XML files to exclude (comma-separated, names or base names)"
    end
  end

  def test_guided_advanced_convert_xml_warns_when_all_files_are_excluded
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      xml_dir = File.join(dir, "xml")
      write(File.join(xml_dir, "users.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump><database name="forum"></database></mysqldump>
      XML
      prompt = FakePrompt.new(["Advanced actions", "Conversion actions", "Convert XML dump", "initial", xml_dir, "y", "users"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      staged = File.join(project.project_path("acme"), "dumps", "initial", "combined.sql.gz")
      refute File.exist?(staged)
      assert_includes out.string, "Files found: 1"
      assert_includes out.string, "Files to skip: 1"
      assert_includes out.string, "No XML files to process after filtering"
      refute_includes out.string, "[OK] XML converted:"
    end
  end

  def test_guided_advanced_convert_xml_can_keep_existing_output
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      xml_dir = File.join(dir, "xml")
      write(File.join(xml_dir, "users.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump><database name="forum"></database></mysqldump>
      XML
      staged = File.join(project.project_path("acme"), "dumps", "initial", "combined.sql.gz")
      gzip_write(staged, "existing")
      prompt = FakePrompt.new(["Advanced actions", "Conversion actions", "Convert XML dump", "initial", xml_dir, "n", "", "n", "", "n"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_equal "existing", Zlib::GzipReader.open(staged, &:read)
      assert_includes prompt.asked, "Replace existing converted dump combined.sql.gz? [y/N]"
      assert_includes out.string, "existing dump left unchanged"
      refute_includes out.string, "Converting XML dump..."
    end
  end

  def test_guided_advanced_convert_xml_can_exclude_tables_during_conversion
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      xml_file = write(File.join(dir, "forum.xml"), xml_with_users_and_logs)
      prompt = FakePrompt.new([
        "Advanced actions",
        "Conversion actions",
        "Convert XML dump",
        "initial",
        xml_file,
        "exclude",
        "logs",
        "",
        "",
        "n"
      ])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      staged = File.join(project.project_path("acme"), "dumps", "initial", "forum.sql.gz")
      sql = Zlib::GzipReader.open(staged, &:read)
      assert_includes sql, "CREATE TABLE `users`"
      assert_includes sql, "INSERT INTO `users`"
      refute_includes sql, "CREATE TABLE `logs`"
      refute_includes sql, "INSERT INTO `logs`"
      assert_includes out.string, "Table filter: exclude logs"
    end
  end

  def test_guided_advanced_convert_xml_progress_identifies_excluded_table
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      xml_file = write(File.join(dir, "forum.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump>
          <database name="forum">
            <table_structure name="user_log"><field Field="id" Type="int" Null="NO" Key="PRI" /></table_structure>
            <table_data name="user_log"><row><field name="id">1</field></row><!-- #{"x" * 2048} --></table_data>
            <table_structure name="messages"><field Field="id" Type="int" Null="NO" Key="PRI" /></table_structure>
            <table_data name="messages"><row><field name="id">2</field></row></table_data>
          </database>
        </mysqldump>
      XML
      prompt = FakePrompt.new([
        "Advanced actions",
        "Conversion actions",
        "Convert XML dump",
        "initial",
        xml_file,
        "exclude",
        "user_log",
        "",
        "",
        "n"
      ])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      assert_includes out.string, "reading user_log excluded"
      assert_includes out.string, "converted rows 0, converted tables 0"
      assert_includes out.string, "reading messages included"
    end
  end

  def test_guided_advanced_convert_xml_can_include_only_selected_tables
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      xml_file = write(File.join(dir, "forum.xml"), xml_with_users_and_logs)
      prompt = FakePrompt.new([
        "Advanced actions",
        "Conversion actions",
        "Convert XML dump",
        "initial",
        xml_file,
        "include",
        "users",
        "",
        "",
        "n"
      ])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      staged = File.join(project.project_path("acme"), "dumps", "initial", "forum.sql.gz")
      sql = Zlib::GzipReader.open(staged, &:read)
      assert_includes sql, "CREATE TABLE `users`"
      assert_includes sql, "INSERT INTO `users`"
      refute_includes sql, "CREATE TABLE `logs`"
      refute_includes sql, "INSERT INTO `logs`"
      assert_includes out.string, "Table filter: include only users"
    end
  end

  def test_guided_advanced_convert_xml_blank_table_filter_converts_all_tables
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      xml_file = write(File.join(dir, "forum.xml"), xml_with_users_and_logs)
      prompt = FakePrompt.new(["Advanced actions", "Conversion actions", "Convert XML dump", "initial", xml_file, "", ""])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      staged = File.join(project.project_path("acme"), "dumps", "initial", "forum.sql.gz")
      sql = Zlib::GzipReader.open(staged, &:read)
      assert_includes sql, "CREATE TABLE `users`"
      assert_includes sql, "CREATE TABLE `logs`"
      assert_includes out.string, "Table filter: all tables"
    end
  end

  def test_guided_advanced_convert_xml_can_write_plain_sql_output
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      xml_file = write(File.join(dir, "forum.xml"), xml_with_users_and_logs)
      prompt = FakePrompt.new(["Advanced actions", "Conversion actions", "Convert XML dump", "initial", xml_file, "", "", "n", "n"])

      SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: prompt, output: out).run("acme")

      staged = File.join(project.project_path("acme"), "dumps", "initial", "forum.sql")
      assert File.exist?(staged)
      refute File.exist?("#{staged}.gz")
      assert_includes File.read(staged), "CREATE TABLE `users`"
      assert_includes out.string, "Output compression: plain SQL (.sql)"
    end
  end

  def test_guided_large_xml_source_defaults_to_larger_insert_batches
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      out = StringIO.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: out)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out)
      project.init("acme")
      xml_file = File.join(dir, "large.xml")
      write(xml_file, xml_with_users_and_logs)
      File.open(xml_file, "ab") { |file| file.truncate(1024 * 1024 * 1024) }
      interactive = SiloMigrate::Interactive.new(
        project_service: project,
        import_service: import,
        prompt: FakePrompt.new([""]),
        output: out
      )

      assert_equal 5000, interactive.send(:prompt_xml_batch_size, Pathname(xml_file))
      assert_includes out.string, "Large XML source detected; using 5000 rows per INSERT batch"
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
      prompt = FakePrompt.new(["Advanced actions", "Converter actions", "Run converter command", "ruby converter.rb --dry-run"])

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
      prompt = FakePrompt.new(["Advanced actions", "Converter actions", "Generate redacted summary from latest converter logs"])

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
      prompt = FakePrompt.new(["Advanced actions", "Converter actions", "Run converter command", "ruby converter.rb --dry-run", "", "", ""])

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
      prompt = FakePrompt.new(["Advanced actions", "Converter actions", "Generate findings from latest redacted summary", ""])

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

      prompt = FakePrompt.new(["Advanced actions", "Converter actions", "Generate synthetic fixtures from latest findings"])
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
      prompt = FakePrompt.new(["Initial dump", "y", "Back", "Quit"])

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
      prompt = FakePrompt.new(["Initial dump", "y", "SQL dump file (.sql or .sql.gz)", "back", "Quit"])

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

  def test_readline_path_prompt_does_not_restore_nil_word_break_characters
    require "readline"

    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: StringIO.new)
      interactive = SiloMigrate::Interactive.new(project_service: project, import_service: import, prompt: FakePrompt.new([]), output: StringIO.new)

      Readline.stub(:completer_word_break_characters, nil) do
        Readline.stub(:readline, "source.xml") do
          assert_equal "source.xml", interactive.send(:ask_path_with_readline, "Path to source data")
        end
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
        "Converter setup",
        "y",
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
        "Converter setup",
        "y",
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

  def xml_with_users_and_logs
    <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="users">
            <field Field="id" Type="int" Null="NO" Key="PRI" />
          </table_structure>
          <table_data name="users">
            <row><field name="id">1</field></row>
          </table_data>
          <table_structure name="logs">
            <field Field="id" Type="int" Null="NO" Key="PRI" />
          </table_structure>
          <table_data name="logs">
            <row><field name="id">1</field></row>
          </table_data>
        </database>
      </mysqldump>
    XML
  end

  def create_converter_platform(env, customer, platform)
    converter_dir = File.join(SiloMigrate::Project.project_path(customer, env), "discourse-converters")
    write(File.join(converter_dir, "Gemfile"), "source 'https://rubygems.org'\n")
    write(File.join(converter_dir, "convert"), "#!/usr/bin/env ruby\n")
    FileUtils.mkdir_p(File.join(converter_dir, "converters", platform))
  end

  class FakePrompt
    attr_reader :asked, :selected, :choice_sets

    def initialize(answers)
      @answers = answers
      @asked = []
      @selected = []
      @choice_sets = []
    end

    def ask(message)
      @asked << message
      @answers.shift
    end

    def select(message, choices)
      @selected << message
      @choice_sets << [message, choices]
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

  class FailingImportService
    def import_dump(*)
      raise SiloMigrate::UsageError, "synthetic import failure"
    end
  end

  class FakeDiscourseService
    attr_reader :calls

    def initialize(status_details: nil)
      @calls = []
      @configured = false
      @status_details = default_status_details.merge(status_details || {})
    end

    def configured?(_customer)
      @configured
    end

    def setup(customer)
      @configured = true
      @calls << [:setup, customer]
    end

    def rebuild(customer, role:)
      @calls << [:rebuild, customer, role]
    end

    def start(customer, role:)
      @calls << [:start, customer, role]
    end

    def prepare_deps(customer, role:)
      @calls << [:prepare_deps, customer, role]
    end

    def run_uploads(customer)
      @calls << [:run_uploads, customer]
    end

    def restore_import(customer, backup:)
      @calls << [:restore_import, customer, backup]
    end

    def import(customer, no_uploads_db:)
      @calls << [:import, customer, no_uploads_db]
    end

    def backup_import(customer)
      @calls << [:backup_import, customer]
    end

    def status(customer, role:)
      @calls << [:status, customer, role]
    end

    def status_details(_customer)
      @status_details
    end

    def default_status_details
      {
        intermediate_db: true,
        uploads_db: false,
        uploads_container: { name: "acme-uploads", running: false },
        import_container: { name: "acme-import", running: false },
        uploads_importer_config: false,
        import_restored: false,
        import_complete: false,
        final_backups: []
      }
    end
  end

  class FailingImportRuntime < SiloMigrate::Runtime::Fake
    def initialize(stderr)
      super()
      @stderr = stderr
    end

    def run_with_stdin(cmd, chdir: nil)
      @operations << [:run_with_stdin, cmd, chdir]
      sink = StringIO.new
      yield sink
      @last_stdin = sink.string
      @commands << [:run_stream, cmd, chdir, @last_stdin.bytesize]
      SiloMigrate::Runtime::CommandResult.new(success?: false, stdout: "", stderr: @stderr, status: 1)
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
