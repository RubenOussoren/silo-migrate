# frozen_string_literal: true
# Invoked only by merge_validation_postgres_live_test.py in the pinned local image.
# This deliberately tests production SQL helpers, not a copied provisioning recipe.
require "open3"
require "timeout"
require "ostruct"
require "tmpdir"
# Load the actual top-level workflow error without test_helper's autorun or a
# Services-local stand-in, which would mask production constant lookup bugs.
require_relative "../../lib/silo_migrate/named_workspace_store"
require_relative "../../lib/silo_migrate/standard_store"
require_relative "../../lib/silo_migrate/services/standard_merge_validation"

class LiveRuntime
  def initialize(id)
    @id = id
  end

  def run(argv, stdin_data: nil, capture:, timeout:)
    metadata = argv == ["docker", "info", "--format", "{{.ID}}"] || (argv[0, 3] == ["docker", "inspect", "--format"] && argv.last == @id)
    unless metadata
      raise "bridge target mismatch" unless argv[0, 3] == ["docker", "exec", "-i"]
      if argv[3] == "-e"
        raise "bridge application mismatch" unless argv[4] == "PGAPPNAME=silo_validation_#{ENV.fetch('VALIDATION_LIVE_TOKEN')}"
        raise "bridge target mismatch" unless argv[5] == @id
        raise "bridge wrapper mismatch" unless argv[6, 2] == ["sh", "-c"] && argv[9] == "silo-validation-sql" && argv[11].match?(/\A[0-9a-f]{32}\z/)
      else
        raise "bridge executable mismatch" unless argv[3] == @id && argv[4] == "psql"
      end
    end
    raise "bridge capture required" unless capture
    output = error = status = nil
    Open3.popen3(*argv, pgroup: true) do |input, stdout, stderr, waiter|
      begin
        Timeout.timeout([timeout, 20].min) do
          input.write(stdin_data) if stdin_data
          input.close
          readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
          output, error = readers.map(&:value)
          status = waiter.value
        end
      rescue Timeout::Error
        statement = stdin_data.to_s
        phase = if statement.start_with?("CREATE DATABASE merge_source;")
          "create_template_source"
        elsif statement.start_with?("CREATE DATABASE silo_clean_base;")
          "create_template_base"
        else
          "metadata_or_fixture"
        end
        warn "VALIDATION_SQL_BRIDGE:#{phase}:timeout"
        raise
      ensure
        unless waiter.join(0)
          Process.kill("KILL", -waiter.pid)
          waiter.join
        end
      end
    end
    OpenStruct.new(success?: status.success?, stdout: output, stderr: error, status: status.exitstatus)
  end
end

class LiveValidation
  include SiloMigrate::Services::StandardMergeValidation
  CONTEXT = { "prepared_from" => "invented-live", "runtime_profile" => {} }.freeze
  TABLES = %w[categories groups site_settings uploads users].freeze

  def initialize(id, root)
    @id = id
    @store = OpenStruct.new(root: root)
    @runtime = LiveRuntime.new(id)
  end

  def stack_for(*)
    id = @id
    Object.new.tap do |stack|
      stack.define_singleton_method(:container) do |service|
        raise "unexpected service" unless %w[db web].include?(service)
        id
      end
      stack.define_singleton_method(:record) { { "name" => "validation-live", "containers" => { "db" => id, "web" => id } } }
    end
  end

  # SQL-only acceptance uses the same exact PG fixture for both bound services;
  # it does not claim that a web/guest lifecycle was exercised.
  def with_review_runtime(_profile) = yield

  def mv_create_resource!(context, journal, key, &block)
    super
    return if key == "role"
    database = journal.fetch(key)
    assert(sql("SELECT datallowconn FROM pg_database WHERE datname='#{database}';").strip == "f", "clone open during identity journal window")
    attempt = raw("SELECT 1;", database, journal.fetch("role"))
    assert(!attempt.success? && attempt.stderr.include?("not currently accepting connections"), "reader connected before database ACL restriction")
  end

  def assert(condition, message)
    raise message unless condition
  end

  def sql(statement, database = "postgres")
    mv_sql!(CONTEXT, statement, database: database)
  end

  def snapshot(database)
    TABLES.to_h do |table|
      [table, sql("SELECT row_to_json(t) FROM #{table} t ORDER BY id;", database)]
    end
  end

  def privilege_snapshot(database)
    sql("SELECT datacl::text FROM pg_database WHERE datname=current_database();\nSELECT nspname, nspowner, nspacl::text FROM pg_namespace WHERE nspname IN ('public','discourse_functions') ORDER BY nspname;\nSELECT relname, relowner, relacl::text FROM pg_class WHERE relnamespace='public'::regnamespace AND relkind IN ('r','S') ORDER BY relname;\nSELECT proowner, prosecdef, proacl::text, pg_get_functiondef(oid) FROM pg_proc WHERE oid='discourse_functions.live_insert()'::regprocedure;", database)
  end

  def raw(statement, database, role)
    @runtime.run(["docker", "exec", "-i", @id, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1",
                  "-U", role, "-d", database, "-At"],
                 stdin_data: statement, capture: true, timeout: 20)
  end

  def refuse_custody
    begin
      mv_custody!(CONTEXT)
    rescue SiloMigrate::StandardWorkflowError => error
      assert(error.code == "STANDARD_MERGE_TEMPLATE_CUSTODY", "wrong custody refusal")
      return
    end
    raise "custody accepted an open or active template"
  end

  def review_runtime_for(_body) = {}
  def merge_environment_phase(_state, environment) = environment.fetch("phase")

  # Real catalogue/SQL observations with invented saved state. This does not
  # pretend the shared PG endpoint is an actual web runtime or host producer.
  def reconciliation_acceptance!(journal)
    run_id = "run-#{journal.fetch('id')}"
    generation = "a" * 64
    legacy = journal.merge("version" => 1, "prepared_from" => run_id, "generation" => generation,
      "owned_identities" => journal.fetch("owned_identities").map { |row| row.size == 4 ? row.values_at(0, 1, 3) : row })
    %w[resources producers runtime_binding runtime_profile].each { |key| legacy.delete(key) }
    state = { "runs" => { run_id => { "status" => "completed", "plan_id" => "invented",
      "merge_environment" => { "preparation_run_id" => run_id, "phase" => "ready", "generation" => generation } } },
      "plans" => { "invented" => { "body" => { "operation" => "standard_merge_prepare" } } } }
    @store.define_singleton_method(:load) { state }
    @store.define_singleton_method(:with_read_only_execution_locks) { |&block| block.call }
    mv_write!(mv_path(journal.fetch("id"), "resources.json"), legacy)
    mv_write!(mv_path(journal.fetch("id"), "json"), { "version" => 1, "receipt_id" => journal.fetch("id"),
      "status" => "refused", "prepared_from" => run_id, "generation" => generation, "templates" => legacy.fetch("templates") })
    paths = Dir.glob(File.join(@store.root, "validations", "*"))
    before = paths.to_h { |path| [path, [File.binread(path), File.stat(path).mtime]] }
    state_before = JSON.generate(state)
    report = merge_validation_reconcile_inspect(attempt_id: journal.fetch("id"))
    assert(report["inspection"] == "observed", "legacy inspection incomplete")
    assert(report["resources"].values.all? { |row| row == { "presence" => "present", "identity" => "matches_saved_fields" } }, "legacy saved-field comparison failed")
    assert(report["templates"] == "matches_saved_custody" && report["sessions"] == "none_observed", "legacy catalogue observations failed")
    assert(report["cleanup_authorized"] == false && report["historical_producer"] == "unproven" && report["current_host_producer"] == "unproven", "legacy observation granted authority")
    assert(before == paths.to_h { |path| [path, [File.binread(path), File.stat(path).mtime]] } && paths.sort == Dir.glob(File.join(@store.root, "validations", "*")).sort && state_before == JSON.generate(state), "inspection changed saved evidence/state")
    context = mv_reconcile_context!(legacy)
    context["lifecycle_journal"] = legacy.merge("runtime_binding" => mv_runtime_snapshot!(context))
    settings = mv_sql!(context, "SELECT current_setting('transaction_read_only'), current_setting('statement_timeout'), current_setting('lock_timeout');\n")
    assert(settings.strip == "on|5s|1s", "diagnostic SQL not bounded/read-only")
  end

  def acceptance!
    originals = {}
    original_privileges = {}
    %w[merge_source silo_clean_base].each_with_index do |name, index|
      sql("CREATE DATABASE #{name};")
      sql(<<~SQL, name)
        CREATE TABLE categories (id integer PRIMARY KEY, name text);
        CREATE TABLE groups (id integer PRIMARY KEY, name text);
        CREATE TABLE site_settings (id integer PRIMARY KEY, name text, value text);
        CREATE TABLE uploads (id integer PRIMARY KEY, url text, sha1 text);
        CREATE TABLE users (id integer PRIMARY KEY, username text);
        CREATE SCHEMA discourse_functions;
        GRANT USAGE ON SCHEMA discourse_functions TO PUBLIC;
        CREATE FUNCTION discourse_functions.live_insert() RETURNS void
          LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog
          AS $$ INSERT INTO public.categories VALUES (2, 'forbidden function write'); $$;
        -- PostgreSQL grants EXECUTE to PUBLIC by default. Do not remove that
        -- original grant to make the test pass: only the clones may be hardened.
        INSERT INTO categories VALUES (1, 'Invented category #{index}');
        INSERT INTO groups VALUES (1, 'Invented group #{index}');
        INSERT INTO site_settings VALUES (1, 'title', 'Invented title #{index}');
        INSERT INTO uploads VALUES (1, '/invented/upload#{index}.png', '#{'a' * 40}');
        INSERT INTO users VALUES (1, 'invented_user_#{index}');
      SQL
      originals[name] = snapshot(name)
      original_privileges[name] = privilege_snapshot(name)
      assert(sql("SELECT count(*) FROM pg_proc p, LATERAL aclexplode(COALESCE(p.proacl, acldefault('f',p.proowner))) a WHERE p.oid='discourse_functions.live_insert()'::regprocedure AND a.grantee=0 AND a.privilege_type='EXECUTE';", name).strip == "1", "fixture lacks default PUBLIC execute")
    end
    identities = sql("SELECT datname, oid, datdba FROM pg_database WHERE datname IN ('merge_source','silo_clean_base') ORDER BY datname;")
    # Running inspection copies deliberately disagree with both sealed originals.
    { "silo_inspect_source" => "merge_source", "discourse" => "silo_clean_base" }.each do |name, template|
      sql("CREATE DATABASE #{name} TEMPLATE #{template};")
      sql("UPDATE categories SET name='DRIFTED'; UPDATE site_settings SET value='CHANGED'; UPDATE groups SET name='RENAMED';", name)
      assert(snapshot(name) != originals.fetch(template), "inspection fixture did not drift")
    end
    refuse_custody # Open templates are not accepted, even without sessions.

    # Establish a real session BEFORE closing the template. Closing is never an
    # implicit disconnect; custody must reject the surviving session explicitly.
    session = nil
    begin
      session = Open3.popen3("docker", "exec", @id, "psql", "-X", "-U", "postgres",
                            "-d", "dbname=merge_source application_name=live_custody",
                            "-c", "SELECT pg_sleep(60)", pgroup: true)
      session[0].close
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='live_custody';").strip == "1"
        raise "active session startup timeout" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
      sql("ALTER DATABASE merge_source ALLOW_CONNECTIONS false; ALTER DATABASE silo_clean_base ALLOW_CONNECTIONS false;")
      refuse_custody
    ensure
      sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='live_custody';")
      if session
        session[1].close
        session[2].close
        unless session[3].join(5)
          Process.kill("KILL", -session[3].pid)
          session[3].join
          raise "active session cleanup timeout"
        end
      end
    end

    id = ENV.fetch("VALIDATION_LIVE_TOKEN")
    role = "silo_val_r_#{id}"
    journal = { "id" => id, "role" => role, "source" => "silo_val_s_#{id}", "base" => "silo_val_b_#{id}",
                "templates" => mv_custody!(CONTEXT) }
    begin
      # CREATE DATABASE TEMPLATE must work with datallowconn=false throughout.
      mv_provision!(CONTEXT.dup, journal, SecureRandom.hex(32))
      reconciliation_acceptance!(journal)
      { "source" => "merge_source", "base" => "silo_clean_base" }.each do |side, template|
        database = journal.fetch(side)
        assert(snapshot(database) == originals.fetch(template), "clone used drifted inspection contents")
        TABLES.each do |table|
          result = raw("SELECT * FROM #{table};", database, journal.fetch("role"))
          assert(result.success? && !result.stdout.empty?, "SELECT grant missing")
        end
        flags = raw("SELECT rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls FROM pg_roles WHERE rolname=current_user;", database, journal.fetch("role"))
        assert(flags.success? && flags.stdout.strip == "f|f|f|f|f", "reader has privileged role flags")
        assert(sql("SELECT datdba = (SELECT oid FROM pg_roles WHERE rolname='#{role}') FROM pg_database WHERE datname='#{database}';").strip == "f", "reader owns clone")
        function_attempt = raw("SET default_transaction_read_only=off;\nSELECT discourse_functions.live_insert();", database, journal.fetch("role"))
        assert(!function_attempt.success? && function_attempt.stderr.include?("permission denied"), "SECURITY DEFINER function was callable")
        assert(sql("SELECT has_function_privilege('#{role}', 'discourse_functions.live_insert()', 'EXECUTE');", database).strip == "f", "non-public function EXECUTE not revoked")
        statements = ["INSERT INTO categories VALUES (2,'forbidden');", "UPDATE categories SET name='forbidden';",
                      "DELETE FROM uploads;", "CREATE TABLE forbidden (id integer);",
                      "CREATE TEMP TABLE forbidden (id integer);"]
        statements.each do |statement|
          # Test both the default read-only guard and the underlying ACL after
          # deliberately disabling that user-settable guard in the SAME session.
          ["", "SET default_transaction_read_only=off;\n"].each do |prefix|
            result = raw(prefix + statement, database, journal.fetch("role"))
            assert(!result.success?, "validator write unexpectedly succeeded")
            assert(result.stderr.match?(/read-only transaction|permission denied/), "write failed for unrelated reason")
          end
        end
        assert(snapshot(database) == originals.fetch(template), "attempted writes changed clone")
      end
      assert(mv_same_template_custody?(mv_custody!(CONTEXT), journal.fetch("templates")), "template identity/owner changed during grants")
    ensure
      mv_cleanup!(CONTEXT.dup, journal)
    end
    # DROP ROLE above proves clone grants/default role settings left no shared
    # dependencies. Cleanup is identity-bound, not repeatable name-only deletion.
    assert(sql("SELECT count(*) FROM pg_shdepend WHERE refobjid=(SELECT oid FROM pg_roles WHERE rolname='#{role}');").strip == "0", "role dependencies survived")
    assert(sql("SELECT datname, oid, datdba FROM pg_database WHERE datname IN ('merge_source','silo_clean_base') ORDER BY datname;") == identities, "template identities changed")
    assert(mv_same_template_custody?(mv_custody!(CONTEXT), journal.fetch("templates")), "custody changed after cleanup")
    # Reopen ONLY after the complete cloning/grants/cleanup phase to compare all
    # original invented rows against the snapshot recorded before closure.
    originals.each do |name, expected|
      sql("ALTER DATABASE #{name} ALLOW_CONNECTIONS true;")
      assert(snapshot(name) == expected, "original template contents changed")
      assert(privilege_snapshot(name) == original_privileges.fetch(name), "original template privileges changed")
      sql("ALTER DATABASE #{name} ALLOW_CONNECTIONS false;")
    end
    { "status" => "passed", "postgres_id" => @id, "templates_unchanged" => true,
      "cleanup_confirmed" => true, "clone_identity_window_closed" => true, "active_session_refused" => true,
      "inspection_drift_ignored" => true, "readonly_acl_verified" => true, "legacy_reconciliation_read_only" => true,
      "nonpublic_function_denied" => true, "original_privileges_unchanged" => true }
  end
end

id = ENV.fetch("VALIDATION_LIVE_PG")
token = ENV.fetch("VALIDATION_LIVE_TOKEN")
raise "invalid fixture identity" unless id.match?(/\A[0-9a-f]{64}\z/) && token.match?(/\A[0-9a-f]{32}\z/)
metadata, error, status = Open3.capture3("docker", "inspect", id)
raise "fixture inspect failed" unless status.success?
fixture = JSON.parse(metadata).fetch(0)
raise "fixture ownership mismatch" unless fixture.fetch("Id") == id && fixture.fetch("Config").fetch("Labels").fetch("silo-migrate.validation-live") == token
raise "fixture network mismatch" unless fixture.fetch("HostConfig").fetch("NetworkMode") == "none"
Dir.mktmpdir("validation-live-") do |root|
  puts JSON.generate(LiveValidation.new(id, root).acceptance!)
end
