# frozen_string_literal: true

require_relative "test_helper"

class ImportServiceTest < SiloMigrateTest
  MYSQL8_DUMP = "-- MySQL dump\nCREATE TABLE t (id int) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;\n"

  def build_import(env, runtime, db_type: "mariadb", dump: "-- MySQL dump\nCREATE TABLE t (id int);\n")
    project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
    project.init("acme", { db_type: db_type })
    write(File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial", "dump.sql"), dump)
    out = StringIO.new
    [SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: out), out]
  end

  def test_import_skips_health_wait_when_container_already_healthy
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      import, = build_import(env, runtime)
      import.import_dump("acme", "initial", { file: "dump.sql" })

      assert(runtime.operations.any? { |op| op.first == :container_health_state })
      refute(runtime.operations.any? { |op| op.first == :wait_for_container_healthy })
    end
  end

  def test_import_waits_for_health_before_streaming_when_container_starting
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      runtime.container_health_states["acme_initial_mariadb"] = "starting"
      import, = build_import(env, runtime)
      import.import_dump("acme", "initial", { file: "dump.sql" })

      wait_index = runtime.operations.index { |op| op.first == :wait_for_container_healthy }
      stream_index = runtime.operations.index { |op| op.first == :run_with_stdin }
      refute_nil wait_index
      refute_nil stream_index
      assert_operator wait_index, :<, stream_index
    end
  end

  def test_import_fails_with_guidance_when_container_unhealthy
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      runtime.container_health_states["acme_initial_mariadb"] = "unhealthy"
      runtime.healthy_containers["acme_initial_mariadb"] = false
      import, = build_import(env, runtime)

      error = assert_raises(SiloMigrate::UsageError) { import.import_dump("acme", "initial", { file: "dump.sql" }) }
      assert_includes error.message, "not healthy"
      assert_includes error.message, "--skip-health-wait"
    end
  end

  def test_import_skip_health_wait_flag_bypasses_check
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      runtime.container_health_states["acme_initial_mariadb"] = "unhealthy"
      runtime.healthy_containers["acme_initial_mariadb"] = false
      import, = build_import(env, runtime)
      import.import_dump("acme", "initial", { file: "dump.sql", skip_health_wait: true })

      refute(runtime.operations.any? { |op| op.first == :wait_for_container_healthy })
    end
  end

  class NoHealthStateRuntime < SiloMigrate::Runtime::Fake
    undef_method :container_health_state
  end

  def test_import_skips_health_wait_when_runtime_cannot_report_health_state
    with_tmp_base do |_dir, env|
      runtime = NoHealthStateRuntime.new
      import, = build_import(env, runtime)
      import.import_dump("acme", "initial", { file: "dump.sql" })

      refute(runtime.operations.any? { |op| op.first == :wait_for_container_healthy })
      assert(runtime.operations.any? { |op| op.first == :run_with_stdin })
    end
  end

  def test_import_proceeds_with_warning_when_no_healthcheck
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      runtime.container_health_states["acme_initial_mariadb"] = "none"
      import, out = build_import(env, runtime)
      import.import_dump("acme", "initial", { file: "dump.sql" })

      assert_includes out.string, "no healthcheck"
      refute(runtime.operations.any? { |op| op.first == :wait_for_container_healthy })
    end
  end

  def test_mariadb_auto_fixes_mysql8_collations
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      import, = build_import(env, runtime, dump: MYSQL8_DUMP)
      import.import_dump("acme", "initial", { file: "dump.sql" })

      assert_includes runtime.last_stdin, "utf8mb4_unicode_ci"
      refute_includes runtime.last_stdin, "utf8mb4_0900_ai_ci"
    end
  end

  def test_mysql_keeps_mysql8_collations_by_default
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      import, = build_import(env, runtime, db_type: "mysql", dump: MYSQL8_DUMP)
      import.import_dump("acme", "initial", { file: "dump.sql" })

      assert_includes runtime.last_stdin, "utf8mb4_0900_ai_ci"
    end
  end

  def test_mysql_honors_explicit_fix_collations_flag
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      import, out = build_import(env, runtime, db_type: "mysql", dump: MYSQL8_DUMP)
      import.import_dump("acme", "initial", { file: "dump.sql", fix_collations: true })

      assert_includes runtime.last_stdin, "utf8mb4_unicode_ci"
      refute_includes runtime.last_stdin, "utf8mb4_0900_ai_ci"
      assert_includes out.string, "as requested"
    end
  end

  def test_postgres_warns_and_ignores_fix_collations_flag
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      import, out = build_import(env, runtime, db_type: "postgres", dump: "-- PostgreSQL database dump\nCREATE TABLE t (id int);\n")
      import.import_dump("acme", "initial", { file: "dump.sql", fix_collations: true })

      assert_includes out.string, "ignoring it for postgres"
    end
  end

  def test_corrupt_gzip_dump_blocks_import_with_actionable_error
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      import, = build_import(env, runtime)
      dump_dir = File.join(SiloMigrate::Project.project_path("acme", env), "dumps", "initial")
      gz_path = File.join(dump_dir, "dump.sql.gz")
      gzip_write(gz_path, "-- MySQL dump\n#{"INSERT INTO t VALUES (1);\n" * 5000}")
      File.truncate(gz_path, File.size(gz_path) / 2)
      FileUtils.rm(File.join(dump_dir, "dump.sql"))

      error = assert_raises(SiloMigrate::UsageError) { import.import_dump("acme", "initial", {}) }
      assert_includes error.message, "gzip integrity check failed"
      assert_includes error.message, "re-transfer"
    end
  end

  def test_failure_diagnostics_for_duplicate_entry_includes_recovery
    diagnostic = SiloMigrate::Services::ImportService::ImportFailureDiagnostic.new(
      path: write(File.join(Dir.mktmpdir, "dump.sql"), "INSERT INTO users VALUES (1);\n"),
      output: "ERROR 1062 (23000) at line 1: Duplicate entry '1' for key 'PRIMARY'",
      db_type: "mariadb",
      customer: "acme",
      phase: "initial"
    )
    summary = diagnostic.summary.join("\n")
    assert_includes summary, "Duplicate entry"
    assert_includes summary, "silo-migrate replace-dump acme initial --yes"
    assert_includes summary, "Reported SQL line: 1"
  end

  def test_failure_diagnostics_for_eperm_during_commit_explains_bulk_insert_duplicates
    dump = <<~SQL
      INSERT INTO `users` (`id`, `bio`) VALUES
        (1, 'please COMMIT to the BEGIN of this plan'),
        (2, '');
    SQL
    summary = SiloMigrate::Services::ImportService::ImportFailureDiagnostic.new(
      path: write(File.join(Dir.mktmpdir, "dump.sql"), dump),
      output: %(ERROR 1180 (HY000) at line 1: Got error 1 "Operation not permitted" during COMMIT),
      db_type: "mariadb", customer: "acme", phase: "initial"
    ).summary.join("\n")

    # Words like COMMIT inside string data must not count as transaction markers.
    assert_includes summary, "Dump transaction markers: no"
    assert_includes summary, "UNIQUE-keyed columns"
    assert_includes summary, "Check users for duplicate"
    assert_includes summary, "retry the same import on Linux"
  end

  def test_failure_diagnostics_detects_real_transaction_markers
    dump = <<~SQL
      START TRANSACTION;
      INSERT INTO `users` (`id`) VALUES (1);
      COMMIT;
    SQL
    summary = SiloMigrate::Services::ImportService::ImportFailureDiagnostic.new(
      path: write(File.join(Dir.mktmpdir, "dump.sql"), dump),
      output: %(ERROR 1180 (HY000) at line 2: Got error 1 "Operation not permitted" during COMMIT),
      db_type: "mariadb", customer: "acme", phase: "initial"
    ).summary.join("\n")

    assert_includes summary, "Dump transaction markers: yes"
    assert_includes summary, "UNIQUE-keyed columns"
    refute_includes summary, "retry the same import on Linux"
  end

  def test_failure_diagnostics_for_unknown_collation_depends_on_engine
    path = write(File.join(Dir.mktmpdir, "dump.sql"), "CREATE TABLE t (id int);\n")
    mariadb = SiloMigrate::Services::ImportService::ImportFailureDiagnostic.new(
      path: path, output: "ERROR 1273 (HY000) at line 1: Unknown collation: 'utf8mb4_0900_ai_ci'",
      db_type: "mariadb", customer: "acme", phase: "initial"
    ).summary.join("\n")
    assert_includes mariadb, "--no-fix-collations"

    mysql = SiloMigrate::Services::ImportService::ImportFailureDiagnostic.new(
      path: path, output: "ERROR 1273 (HY000) at line 1: Unknown collation: 'weird_collation'",
      db_type: "mysql", customer: "acme", phase: "initial"
    ).summary.join("\n")
    assert_includes mysql, "--fix-collations"
  end

  def test_failure_diagnostics_for_postgres_messages
    path = write(File.join(Dir.mktmpdir, "dump.sql"), "INSERT INTO users VALUES (1);\n")
    summary = SiloMigrate::Services::ImportService::ImportFailureDiagnostic.new(
      path: path,
      output: 'ERROR:  duplicate key value violates unique constraint "users_pkey"',
      db_type: "postgres", customer: "acme", phase: "initial"
    ).summary.join("\n")
    assert_includes summary, "Duplicate key"
    assert_includes summary, "replace-dump acme initial"
  end

  def test_postgres_plpgsql_context_line_numbers_do_not_trigger_statement_scan
    path = write(File.join(Dir.mktmpdir, "dump.sql"), "INSERT INTO users VALUES (1);\n")
    summary = SiloMigrate::Services::ImportService::ImportFailureDiagnostic.new(
      path: path,
      output: "ERROR:  division by zero\nCONTEXT:  PL/pgSQL function check_value() at line 4 at assignment",
      db_type: "postgres", customer: "acme", phase: "initial"
    ).summary.join("\n")
    refute_includes summary, "Reported SQL line"
    assert_includes summary, "replace-dump acme initial"
  end
end
