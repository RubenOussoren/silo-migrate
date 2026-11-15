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

  def run(argv, stdin_data:, capture:, timeout:)
    raise "bridge target mismatch" unless argv[0, 4] == ["docker", "exec", "-i", @id]
    raise "bridge executable mismatch" unless argv[4] == "psql" && capture
    output = error = status = nil
    Open3.popen3(*argv, pgroup: true) do |input, stdout, stderr, waiter|
      begin
        Timeout.timeout([timeout, 20].min) do
          input.write(stdin_data)
          input.close
          readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
          output, error = readers.map(&:value)
          status = waiter.value
        end
      ensure
        unless waiter.join(0)
          Process.kill("KILL", -waiter.pid)
          waiter.join
        end
      end
    end
    OpenStruct.new(success?: status.success?, stdout: output, stderr: error)
  end
end

class LiveValidation
  include SiloMigrate::Services::StandardMergeValidation
  CONTEXT = { "prepared_from" => "invented-live" }.freeze
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
        raise "unexpected service" unless service == "db"
        id
      end
    end
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
      mv_provision!(CONTEXT, journal, SecureRandom.hex(32))
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
      mv_cleanup!(CONTEXT, journal)
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
      "cleanup_confirmed" => true, "active_session_refused" => true,
      "inspection_drift_ignored" => true, "readonly_acl_verified" => true,
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
