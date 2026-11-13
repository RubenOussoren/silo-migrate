# frozen_string_literal: true

require_relative "test_helper"
require "silo_migrate/services/standard_merge_inspection"

# StandardMergeInspection against a fake store/runtime/stack. Invented identifiers only.
class StandardMergeInspectionTest < SiloMigrateTest
  RUN = "run-#{'a' * 32}"
  CLONE_OID = "16384"
  PRISTINE_OID = "16001"
  GEN = "c" * 64
  INSTANCE = "silomig-0123abcd-review"
  WEB = "1" * 64
  DB = "2" * 64
  KEY = "f" * 64
  Result = SiloMigrate::Runtime::CommandResult

  class Store
    attr_reader :root, :state

    def initialize(root, state)
      @root = root
      @state = state
    end

    def load = JSON.parse(JSON.generate(@state))
    def run_dir(run_id, *parts) = File.join(@root, "runs", run_id, *parts)

    def write_private(path, content, mode: 0o600)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open("#{path}.tmp", File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, mode) { |file| file.write(content) }
      File.rename("#{path}.tmp", path)
      path
    end
  end

  class Runtime
    attr_reader :calls
    attr_accessor :launchers, :roles, :fail_role_sql, :relations, :columns, :hba, :hba_broken, :db_names, :databases

    def initialize
      @calls = []
      @launchers = []
      @roles = 0
      # name => [kind, rls, partition, children]; columns: name => { column => builtin type? }
      @relations = { "users" => ["r", 0, 0, 0], "plugin_secret_tokens" => ["r", 0, 0, 0], "api_keys" => ["r", 0, 0, 0], "posts" => ["r", 0, 0, 0] }
      @columns = { "users" => { "id" => true, "username" => true, "password_hash" => true }, "plugin_secret_tokens" => { "token" => true },
                   "api_keys" => { "key_hash" => true }, "posts" => { "id" => true, "raw" => true } }
      @hba = ""
      @db_names = { DB => "/#{INSTANCE}-db", "5" * 64 => "/silomig-other-review-db" }
      # pg_database: OID => name. The checkpoint's Base clone is "discourse"; the sealed pristine is renamed.
      @databases = { CLONE_OID => "discourse", PRISTINE_OID => "silo_clean_base" }
    end

    def hex(text) = text.unpack1("H*")

    def inventory
      rows = @relations.map { |name, (kind, rls, part, kids)| "R|#{hex('public')}|#{hex(name)}|#{kind}|#{rls}|#{part}|#{kids}\n" }
      rows += @columns.flat_map { |table, cols| cols.map { |col, builtin| "C|#{hex(table)}|#{hex(col)}|#{builtin ? 1 : 0}\n" } }
      rows.join
    end

    def run(cmd, capture: true, timeout: nil, stdin_data: nil)
      @calls << [cmd, stdin_data]
      line = cmd.join(" ")
      return ok(@launchers.join("\n")) if cmd[0, 3] == %w[docker ps -aq]
      return ok(@launchers.delete(cmd.last) ? "" : "") if cmd[0, 3] == %w[docker rm --force]
      if cmd[0, 2] == %w[docker inspect] && cmd[3].to_s.start_with?("{{.Id}}")
        name = @db_names[cmd.last] or return Result.new(success?: false, stdout: "", stderr: "No such object", status: 1)
        instance = name.delete_prefix("/").delete_suffix("-db")
        return ok("#{cmd.last}\n#{name}\n#{JSON.generate('silo-migrate.managed' => 'true', 'silo-migrate.instance' => instance)}\n")
      end
      if cmd[0, 2] == %w[docker inspect]
        labels = if cmd.last == WEB || cmd.last == DB then { "silo-migrate.managed" => "true", "silo-migrate.instance" => INSTANCE }
                 else { "silo.role" => "merge-mcp", "silo.merge-run" => RUN, "silo.workspace" => "arc" }
                 end
        return ok(JSON.generate(labels))
      end
      if cmd[0, 3] == %w[docker exec -i] && cmd[4, 2] == %w[sh -c]
        marker = cmd.last
        @hba = stdin_data.to_s + @hba.lines.reject { |l| l.include?(marker) }.join
        return ok("")
      end
      if line.include?("psql")
        sql = stdin_data.to_s
        if sql.start_with?("SELECT oid FROM pg_database WHERE datname = 'discourse'")
          return ok("#{@databases.key('discourse')}\n")
        elsif (oid = sql[/SELECT datname FROM pg_database WHERE oid = (\d+)/, 1])
          return ok("#{@databases[oid]}\n")
        elsif (oid = sql[/SELECT count\(\*\) FROM pg_database WHERE oid = (\d+)/, 1])
          return ok("#{@databases.key?(oid) ? 1 : 0}\n")
        end
        return ok("1\n") if sql.include?("FROM pg_database")
        return ok(inventory) if sql.start_with?("SELECT 'R|'")
        return ok("/var/lib/postgresql/data/pg_hba.conf\n") if sql.include?("SHOW hba_file")
        if sql.include?("pg_hba_file_rules")
          rules = @hba.lines.map do |l|
            type, db, user, _addr_or_method, *rest = l.split
            type == "local" ? "local|#{db}|#{user}|#{_addr_or_method}" : "#{type}|#{db}|#{user}|#{rest.first}"
          end
          return ok("#{hba_broken ? 1 : 0}\n#{rules.first(3).join("\n")}\n")
        end
        if sql.include?("CREATE ROLE")
          return Result.new(success?: false, stdout: "", stderr: "ERROR: boom #{sql}", status: 1) if fail_role_sql

          @roles = 1
          return ok("")
        end
        return ok("#{@roles}\n") if sql.include?("FROM pg_roles")
        return ok("0\n0\n") if sql.include?("pg_terminate_backend")
        @roles = 0 if sql.include?("DROP ROLE")
        return ok("")
      end
      ok("")
    end

    def ok(out) = Result.new(success?: true, stdout: out, stderr: "", status: 0)
  end

  class Stack
    attr_reader :name, :record, :runner_calls, :exec_calls
    attr_accessor :live, :unsupported, :revoke_fails, :serving_oid, :identity_missing

    def initialize
      @name = INSTANCE
      @record = { "containers" => { "db" => DB, "redis" => "3" * 64, "web" => WEB, "proxy" => "4" * 64 },
                  "networks" => ["#{INSTANCE}-int", "#{INSTANCE}-pub"], "port" => 41_000, "state" => "review" }
      @live = true
      @runner_calls = []
      @exec_calls = []
      @guest = {}
      @serving_oid = CLONE_OID # the database the web is connected to
    end

    def live? = @live
    def copy_in(_host, _guest) = true

    def rails_runner(script, env: {}, env_file: nil, timeout: 300)
      @runner_calls << [script, env]
      # As merge_inspection_access.rb: current_database()/OID must equal the binding before anything.
      raise SiloMigrate::StandardWorkflowError.new("STANDARD_RUNNER_FAILED", "x") unless env["SILO_INSPECTION_DATABASE"] == "discourse" && env["SILO_INSPECTION_DATABASE_OID"] == serving_oid

      case env["SILO_INSPECTION_ACTION"]
      when "create"
        raise SiloMigrate::StandardWorkflowError.new("STANDARD_RUNNER_FAILED", "x") if unsupported

        @guest["#{env['SILO_INSPECTION_KEY_DIR']}/key"] = KEY
        { "database" => "discourse", "database_oid" => serving_oid, "user_id" => 7, "username" => env["SILO_INSPECTION_USERNAME"], "api_key_id" => 9,
          "scope_mode" => "read_only", "scopes" => ["global:read"] }
      when "revoke"
        raise SiloMigrate::StandardWorkflowError.new("STANDARD_RUNNER_FAILED", "x") if revoke_fails

        if identity_missing
          raise SiloMigrate::StandardWorkflowError.new("STANDARD_RUNNER_FAILED", "x") if env["SILO_INSPECTION_MINT_ACKNOWLEDGED"] == "1"

          return { "database" => "discourse", "database_oid" => serving_oid, "revoked" => 1, "active_remaining" => 0, "identity_present" => false, "never_minted" => true }
        end
        { "database" => "discourse", "database_oid" => serving_oid, "revoked" => 1, "active_remaining" => 0, "identity_present" => true, "never_minted" => false }
      end
    end

    def copy_out(guest, host)
      File.write(host, @guest.fetch(guest))
    end

    def web_exec(args, timeout: 60)
      @exec_calls << args
      Result.new(success?: true, stdout: "", stderr: "", status: 0)
    end
  end

  class Host
    include SiloMigrate::Services::StandardMergeInspection
    attr_reader :stack

    def initialize(store, runtime, stack)
      @store = store
      @runtime = runtime
      @stack = stack
      @workspace = "arc"
      @sleeper = ->(_) {}
    end

    private

    def stack_for(_run_id, _role) = @stack
    def helper_dir = File.expand_path("../runtime/prebuilt-discourse", __dir__)
    def now = "2026-11-12T00:00:00Z"
  end

  def setup
    @dir = Dir.mktmpdir
    @state = { "runs" => { RUN => { "merge_environment" => { "generation" => GEN, "preparation_run_id" => RUN,
                                                               "source_inspection_database" => "merge_source_inspect",
                                                               "base_inspection_database_oid" => CLONE_OID } } } }
    @store = Store.new(File.join(@dir, "standard"), @state)
    @runtime = Runtime.new
    @stack = Stack.new
    @host = Host.new(@store, @runtime, @stack)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def private_path(*parts) = @store.run_dir(RUN, "private", *parts)
  def manifest = JSON.parse(File.read(private_path("merge-access.json")))

  def everything_logged
    JSON.generate([@runtime.calls.map(&:first), @stack.runner_calls, @stack.exec_calls])
  end

  def test_base_open_mints_private_read_only_credentials_bound_to_the_generation
    summary = @host.merge_inspection_open(RUN, phase: "base")
    assert_equal %w[base source], summary["endpoints"]
    assert_equal "open", summary["state"]
    refute_includes JSON.generate(summary), KEY
    record = manifest
    assert_equal [1, RUN, RUN, GEN, "base", "open"], record.values_at("version", "run_id", "preparation_run_id", "generation", "phase", "state")
    assert_equal({ "web" => WEB, "db" => DB }, record["containers"])
    assert_equal "#{INSTANCE}-int", record["network"]
    assert_equal({ "workspace" => "arc", "instance" => INSTANCE }, record["owner"])
    base = record.dig("endpoints", "base")
    assert_equal ["read_only", ["global:read"], "http://web"], base.values_at("scope_mode", "scopes", "site")
    assert_match(/\Asilo_inspect_[0-9a-f]{8}\z/, base["username"])
    key_path = private_path("merge-inspection", "base.key")
    assert_equal KEY, File.read(key_path)
    assert_equal Digest::SHA256.hexdigest(KEY), base["credential_sha256"]
    [private_path("merge-access.json"), key_path, private_path("merge-inspection", "source.env")].each do |path|
      assert_equal 0o600, File.stat(path).mode & 0o777, path
    end
    assert_equal 0o700, File.stat(private_path).mode & 0o777
    refute_includes File.read(private_path("merge-access.json")), KEY
    # The key never appears in argv, runner env or exec calls; the container copy is removed.
    refute_includes everything_logged, KEY
    assert(@stack.exec_calls.any? { |args| args[0, 2] == ["rm", "-rf"] && args[2].start_with?("/tmp/silo-inspection-") })
    password = File.read(private_path("merge-inspection", "source.env"))[/SILO_MI_PASSWORD=([0-9a-f]{48})/, 1]
    refute_nil password
    refute_includes JSON.generate(@runtime.calls.map(&:first)), password
    refute_includes File.read(private_path("merge-access.json")), password
  end

  def test_source_role_grants_only_reviewed_existing_columns
    @host.merge_inspection_open(RUN, phase: "base")
    sql = @runtime.calls.map(&:last).compact.find { |text| text.include?("CREATE ROLE") }
    assert_includes sql, 'GRANT SELECT ("id", "username") ON TABLE public."users"'
    assert_includes sql, 'GRANT SELECT ("id", "raw") ON TABLE public."posts"'
    assert_includes sql, "default_transaction_read_only = on"
    assert_includes sql, "NOINHERIT"
    refute_includes sql, "password_hash"
    refute_includes sql, "plugin_secret_tokens"
    refute_includes sql, "api_keys"
    refute_match(/GRANT SELECT ON ALL/, sql)
    policy = JSON.parse(File.read(private_path("merge-inspection", "source-read-policy.json")))
    assert_equal ["plugin_secret_tokens"], policy["unreviewed"]
    assert_equal ["api_keys"], policy["excluded_present"]
    assert_equal 1, manifest.dig("endpoints", "source", "policy", "unreviewed_tables")
    assert_empty SiloMigrate::Services::StandardMergeInspection::SOURCE_READ_POLICY.keys &
                 SiloMigrate::Services::StandardMergeInspection::SOURCE_READ_EXCLUDED
  end

  def role_sql = @runtime.calls.map(&:last).compact.find { |text| text.include?("CREATE ROLE") }

  def test_source_role_strips_public_privileges_and_verifies_effective_access_in_one_transaction
    @host.merge_inspection_open(RUN, phase: "base")
    sql = role_sql
    assert sql.start_with?("BEGIN;") && sql.end_with?("COMMIT;\n")
    %w[TABLES SEQUENCES ROUTINES].each { |kind| assert_includes sql, "REVOKE ALL ON ALL #{kind} IN SCHEMA %I FROM PUBLIC" }
    ["REVOKE ALL ON SCHEMA %I FROM PUBLIC", "REVOKE ALL ON LARGE OBJECT", "REVOKE ALL ON FOREIGN SERVER",
     'REVOKE ALL ON DATABASE "merge_source_inspect" FROM PUBLIC', "search_path = pg_catalog, public",
     "has_function_privilege", "has_table_privilege", "has_column_privilege", "lo_compat_privileges", "has_server_privilege",
     "('users', 'id'), ('users', 'username')"].each { |text| assert_includes sql, text }
    # PUBLIC is stripped before the exact grants, and the check runs after them, before COMMIT.
    assert_operator sql.index("REVOKE ALL ON ALL ROUTINES"), :<, sql.index('GRANT SELECT ("id", "raw")')
    assert_operator sql.index('GRANT SELECT ("id", "username")'), :<, sql.index("silo inspection: column privilege")
    # Only the clone is touched: no statement names the clean Base or other databases.
    refute_match(/DATABASE "?(discourse|postgres|merge_source)"?[ ;]/, sql)
    # The role may only log in to the clone; its lines come first and are verified before reload.
    role = manifest.dig("endpoints", "source", "role")
    assert_equal ["host merge_source_inspect #{role} all md5", "host all #{role} all reject", "local all #{role} reject"],
                 @runtime.hba.lines.first(3).map { |l| l.split(" # ").first }
    hba = @runtime.calls.index { |cmd, _| cmd[4, 2] == %w[sh -c] }
    assert_operator hba, :<, @runtime.calls.index { |_, input| input.to_s.include?("CREATE ROLE") }
    assert(@runtime.calls.any? { |_, input| input.to_s.include?("pg_reload_conf") })
    assert_equal "merge-source-read-v2", manifest.dig("endpoints", "source", "policy", "version")
    @host.merge_inspection_close(RUN)
    assert_equal "", @runtime.hba  # fence removes exactly this role's lines
  end

  def test_reviewed_names_that_are_not_plain_tables_refuse_the_open_and_fence
    { "view" => ["v", 0, 0, 0], "materialized view" => ["m", 0, 0, 0], "foreign table" => ["f", 0, 0, 0],
      "partitioned" => ["p", 0, 0, 0], "inheritance parent" => ["r", 0, 0, 1], "partition" => ["r", 0, 1, 0],
      "row level security" => ["r", 1, 0, 0] }.each do |label, relation|
      setup
      @runtime.relations["users"] = relation
      assert_code("STANDARD_MERGE_INSPECTION_POLICY_UNSAFE") { @host.merge_inspection_open(RUN, phase: "base") }
      assert_nil role_sql, label
      refute_equal "open", manifest["state"], label
      assert_equal "", @runtime.hba, label
      teardown
    end
  end

  def test_unreviewed_and_non_builtin_columns_are_never_granted_and_names_cannot_forge_lines
    @runtime.columns["users"]["username"] = false # e.g. a custom type with its own output function
    @runtime.relations["users\nR|7075626c6963|7573657273|r|0|0|0"] = ["r", 0, 0, 0]
    @runtime.relations["evil_view"] = ["v", 0, 0, 0]
    @host.merge_inspection_open(RUN, phase: "base")
    sql = role_sql
    assert_includes sql, 'GRANT SELECT ("id") ON TABLE public."users"'
    refute_includes sql, '"username"'
    refute_includes sql, "evil_view"
    policy = JSON.parse(File.read(private_path("merge-inspection", "source-read-policy.json")))
    assert_equal({ "users" => ["username"] }, policy["non_builtin_type_columns"])
    assert_includes policy["unreviewed"], "evil_view"
  end

  def test_a_failed_privilege_check_or_unparsable_hba_fails_closed
    @runtime.fail_role_sql = true # e.g. the in-transaction check raised: everything rolled back
    assert_code("STANDARD_MERGE_INSPECTION_POLICY_UNSAFE") { @host.merge_inspection_open(RUN, phase: "base") }
    assert_equal "", @runtime.hba
    setup
    @runtime.hba_broken = true
    assert_code("STANDARD_MERGE_INSPECTION_UNAVAILABLE") { @host.merge_inspection_open(RUN, phase: "base") }
    assert_nil role_sql
    assert_equal "", @runtime.hba # our lines were taken out again
  end

  def test_result_needs_a_recorded_backup_and_phases_do_not_overlap
    assert_code("STANDARD_MERGE_INSPECTION_ORDER") { @host.merge_inspection_open(RUN, phase: "result") }
    @host.merge_inspection_open(RUN, phase: "base")
    calls = @stack.runner_calls.size
    assert_equal "open", @host.merge_inspection_open(RUN, phase: "base")["state"] # idempotent
    assert_equal calls, @stack.runner_calls.size
    bind_result_backup
    assert_code("STANDARD_MERGE_INSPECTION_ORDER") { @host.merge_inspection_open(RUN, phase: "result") }
    @host.merge_inspection_close(RUN)
    summary = @host.merge_inspection_open(RUN, phase: "result")
    assert_equal ["result"], summary["endpoints"]
    assert_nil manifest.dig("endpoints", "source")
  end

  PREP = "run-#{'b' * 32}"

  # As standard_merge_run#merge_backup records it for a prepared merge.
  def bind_result_backup(generation: GEN, preparation: PREP, plan_generation: GEN, plan_run: RUN)
    @state["runs"][RUN].merge!("plan_id" => "plan-1", "merge_environment" => { "generation" => GEN, "preparation_run_id" => PREP },
                               "artifacts" => { "backup" => { "sha256" => "0" * 64, "merge_generation" => generation, "preparation_run_id" => preparation }.compact })
    @state["plans"] = { "plan-1" => { "run_id" => plan_run, "body" => { "operation" => "standard_merge",
                                                                         "prepared_from" => { "run_id" => PREP, "generation" => plan_generation } } } }
  end

  def test_result_access_is_bound_to_this_runs_own_backup_of_exactly_this_generation
    {
      "plain truthy backup" => { generation: nil, preparation: nil },
      "older generation's backup" => { generation: "d" * 64 },
      "other preparation" => { preparation: "run-#{'e' * 32}" },
      "plan of another environment" => { plan_generation: "d" * 64 },
      "plan started another run" => { plan_run: "run-#{'f' * 32}" }
    }.each do |label, binding|
      bind_result_backup(**binding)
      assert_code("STANDARD_MERGE_INSPECTION_STALE") { @host.merge_inspection_open(RUN, phase: "result") }
      assert_empty @stack.runner_calls, label
    end
    @state["plans"]["plan-1"]["body"]["operation"] = "standard_review"
    assert_code("STANDARD_MERGE_INSPECTION_STALE") { @host.merge_inspection_open(RUN, phase: "result") }
    bind_result_backup
    assert_code("STANDARD_MERGE_INSPECTION_STALE") { @host.merge_inspection_open(RUN, phase: "result", generation: "d" * 64) }
    assert_equal "open", @host.merge_inspection_open(RUN, phase: "result")["state"]
    assert_equal [GEN, PREP], manifest.values_at("generation", "preparation_run_id")
  end

  def test_stopped_or_unrecorded_stack_keeps_the_fence_incomplete_until_removal_is_proven
    @host.merge_inspection_open(RUN, phase: "base")
    @stack.live = false # stopped containers, volumes (keys, role) retained
    assert_code("STANDARD_MERGE_INSPECTION_FENCE_FAILED") { @host.merge_inspection_close(RUN) }
    assert_equal "fencing", manifest["state"]
    refute_equal "closed", manifest.dig("endpoints", "base", "state")
    assert File.exist?(private_path("merge-inspection", "base.key"))
    @host.define_singleton_method(:stack_for) { |*| raise KeyError } # record missing: still unknown
    assert_code("STANDARD_MERGE_INSPECTION_FENCE_FAILED") { @host.merge_inspection_close(RUN) }
    other = Stack.new
    other.instance_variable_set(:@name, "silomig-other-review")
    @host.define_singleton_method(:stack_for) { |*| other } # another instance is not this one's removal
    other.record["state"] = "removed"
    assert_code("STANDARD_MERGE_INSPECTION_FENCE_FAILED") { @host.merge_inspection_close(RUN) }
    # Only the owner instance's exact removal (containers AND volumes) proves keys/roles are gone.
    @stack.record["state"] = "removed"
    @host.define_singleton_method(:stack_for) { |*| @stack }
    revokes = @stack.runner_calls.size
    assert_equal "closed", @host.merge_inspection_close(RUN)["state"]
    assert_equal revokes, @stack.runner_calls.size
    refute File.exist?(private_path("merge-inspection", "base.key"))
  end

  def test_database_access_is_bound_to_the_manifest_owner_container
    @host.merge_inspection_open(RUN, phase: "base")
    record = manifest
    record["containers"]["db"] = "5" * 64 # swapped to another managed stack's db
    File.write(private_path("merge-access.json"), JSON.generate(record))
    before = @runtime.calls.count { |cmd, _| cmd.include?("psql") }
    assert_code("STANDARD_MERGE_INSPECTION_FENCE_FAILED") { @host.merge_inspection_close(RUN) }
    assert_equal before, @runtime.calls.count { |cmd, _| cmd.include?("psql") } # nothing ran on it
    refute(@runtime.calls.any? { |cmd, _| cmd[0, 4] == ["docker", "exec", "-i", "5" * 64] })
    db = { "id" => DB, "instance" => "silomig-other-review" }
    refute @host.send(:inspection_container_owned?, db) # right ID, wrong owner
    refute @host.send(:inspection_container_owned?, { "id" => DB, "instance" => INSTANCE }, "web")
    assert @host.send(:inspection_container_owned?, { "id" => DB, "instance" => INSTANCE })
  end

  def test_source_password_reaches_postgres_only_as_a_scram_verifier
    @host.merge_inspection_open(RUN, phase: "base")
    password = File.read(private_path("merge-inspection", "source.env"))[/SILO_MI_PASSWORD=([0-9a-f]{48})/, 1]
    sql = role_sql
    assert_match(/PASSWORD 'SCRAM-SHA-256\$4096:[A-Za-z0-9+\/=]+\$[A-Za-z0-9+\/=]+:[A-Za-z0-9+\/=]+'/, sql)
    refute_includes JSON.generate(@runtime.calls), password
    # RFC 7677 test vector (user "user", password "pencil").
    verifier = @host.send(:scram_verifier, "pencil", salt: "W22ZaJ0SNY7soEsUEjb6gQ==".unpack1("m0"))
    assert_equal "SCRAM-SHA-256$4096:W22ZaJ0SNY7soEsUEjb6gQ==$WG5d8oPm3OtcPnkdi4Uo7BkeZkBFzpcXkuLmtbsT4qY=:wfPLwcE6nTWhTAmQ7tl2KeoiWGPlZqQxSrmfPwDl2dU=", verifier
  end

  def runner_actions = @stack.runner_calls.map { |_, env| env["SILO_INSPECTION_ACTION"] }

  def test_base_key_is_minted_only_in_the_bound_clone_database
    @host.merge_inspection_open(RUN, phase: "base")
    assert_equal({ "name" => "discourse", "oid" => CLONE_OID }, manifest.dig("endpoints", "base", "database"))
    create = @stack.runner_calls.find { |_, env| env["SILO_INSPECTION_ACTION"] == "create" }[1]
    assert_equal ["discourse", CLONE_OID], create.values_at("SILO_INSPECTION_DATABASE", "SILO_INSPECTION_DATABASE_OID")
  end

  def test_base_open_refuses_without_or_with_a_wrong_database_identity
    @state["runs"][RUN]["merge_environment"].delete("base_inspection_database_oid")
    assert_code("STANDARD_MERGE_INSPECTION_INVALID") { @host.merge_inspection_open(RUN, phase: "base") }
    # The pristine Base's OID (it is named silo_clean_base now) is not the clone.
    assert_code("STANDARD_MERGE_INSPECTION_STALE") { @host.merge_inspection_open(RUN, phase: "base", site_database_oid: PRISTINE_OID) }
    assert_empty runner_actions.grep("create")
    # The web serving another database than the bound clone: the helper refuses before minting.
    @state["runs"][RUN]["merge_environment"]["base_inspection_database_oid"] = CLONE_OID
    @stack.serving_oid = PRISTINE_OID
    assert_code("STANDARD_MERGE_INSPECTION_UNAVAILABLE") { @host.merge_inspection_open(RUN, phase: "base") }
    refute(runner_actions.include?("create") && @stack.runner_calls.any? { |_, env| env["SILO_INSPECTION_ACTION"] == "create" && env["SILO_INSPECTION_DATABASE_OID"] != CLONE_OID })
    refute File.exist?(private_path("merge-inspection", "base.key"))
  end

  def test_revoke_runs_only_in_the_bound_clone_and_never_closes_on_an_unproven_state
    @host.merge_inspection_open(RUN, phase: "base")
    # The pristine is renamed back to "discourse" while the clone still exists (under another name):
    # revoking there would touch the clean Base and prove nothing about the clone.
    @runtime.databases = { CLONE_OID => "silo_inspect_old", PRISTINE_OID => "discourse" }
    @stack.serving_oid = PRISTINE_OID
    assert_code("STANDARD_MERGE_INSPECTION_FENCE_FAILED") { @host.merge_inspection_close(RUN) }
    refute_equal "closed", manifest.dig("endpoints", "base", "state")
    assert_equal "fencing", manifest["state"]
    revoke = @stack.runner_calls.reverse.find { |_, env| env["SILO_INSPECTION_ACTION"] == "revoke" }[1]
    assert_equal CLONE_OID, revoke["SILO_INSPECTION_DATABASE_OID"]
    # Identity missing for an acknowledged key in the bound clone: unknown, stays fenced.
    @runtime.databases = { CLONE_OID => "discourse", PRISTINE_OID => "silo_clean_base" }
    @stack.serving_oid = CLONE_OID
    @stack.identity_missing = true
    assert_code("STANDARD_MERGE_INSPECTION_FENCE_FAILED") { @host.merge_inspection_close(RUN) }
    refute_equal "closed", manifest.dig("endpoints", "base", "state")
    assert File.exist?(private_path("merge-inspection", "base.key"))
    # The bound clone is gone (activation dropped it): its identity and keys went with it.
    @runtime.databases = { PRISTINE_OID => "discourse" }
    @stack.serving_oid = PRISTINE_OID
    revokes = runner_actions.count("revoke")
    assert_equal "closed", @host.merge_inspection_close(RUN)["state"]
    assert_equal revokes, runner_actions.count("revoke") # nothing ran against the pristine Base
  end

  def test_unacknowledged_mint_without_identity_closes_only_when_proven_never_minted
    @stack.unsupported = true # create failed before any key ID was acknowledged
    @stack.identity_missing = true
    assert_code("STANDARD_MERGE_INSPECTION_UNAVAILABLE") { @host.merge_inspection_open(RUN, phase: "base") }
    assert_equal "closed", manifest["state"]
    revoke = @stack.runner_calls.find { |_, env| env["SILO_INSPECTION_ACTION"] == "revoke" }[1]
    assert_equal ["0", CLONE_OID], revoke.values_at("SILO_INSPECTION_MINT_ACKNOWLEDGED", "SILO_INSPECTION_DATABASE_OID")
  end

  def test_result_binds_the_database_observed_after_the_clean_backup
    bind_result_backup
    @runtime.databases = { "17000" => "discourse" } # activation/merge: the merged result database
    @stack.serving_oid = "17000"
    @host.merge_inspection_open(RUN, phase: "result")
    assert_equal({ "name" => "discourse", "oid" => "17000" }, manifest.dig("endpoints", "result", "database"))
    @host.merge_inspection_close(RUN)
    assert_code("STANDARD_MERGE_INSPECTION_INVALID") { @host.merge_inspection_open(RUN, phase: "result", site_database_oid: "x1") }
  end

  def test_bad_arguments_and_unsafe_paths_fail_closed
    assert_code("STANDARD_MERGE_INSPECTION_INVALID") { @host.merge_inspection_open("../x", phase: "base") }
    assert_code("STANDARD_MERGE_INSPECTION_INVALID") { @host.merge_inspection_open(RUN, phase: "source") }
    assert_code("STANDARD_MERGE_INSPECTION_INVALID") { @host.merge_inspection_open(RUN, phase: "base", generation: "short") }
    assert_code("STANDARD_MERGE_INSPECTION_INVALID") { @host.merge_inspection_open(RUN, phase: "base", source_database: "discourse") }
    assert_code("STANDARD_MERGE_INSPECTION_INVALID") { @host.merge_inspection_open(RUN, phase: "base", source_database: "x; DROP") }
    FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
    FileUtils.mkdir_p(@store.run_dir(RUN))
    File.symlink(File.join(@dir, "elsewhere"), private_path)
    assert_code("STANDARD_MERGE_INSPECTION_INVALID") { @host.merge_inspection_open(RUN, phase: "base") }
    assert_empty Dir.children(File.join(@dir, "elsewhere"))
  end

  def test_unsupported_scope_or_unavailable_stack_leaves_no_credentials
    @stack.live = false
    assert_code("STANDARD_MERGE_INSPECTION_UNAVAILABLE") { @host.merge_inspection_open(RUN, phase: "base") }
    @stack.live = true
    @stack.unsupported = true
    assert_code("STANDARD_MERGE_INSPECTION_UNAVAILABLE") { @host.merge_inspection_open(RUN, phase: "base") }
    assert_equal "closed", manifest["state"]
    refute File.exist?(private_path("merge-inspection", "base.key"))
    refute File.exist?(private_path("merge-inspection", "source.env"))
    @stack.unsupported = false
    @runtime.fail_role_sql = true
    error = assert_code("STANDARD_MERGE_INSPECTION_POLICY_UNSAFE") { @host.merge_inspection_open(RUN, phase: "base") }
    refute_includes error.message, "boom"
    assert_equal "closed", manifest["state"]
    assert(@stack.runner_calls.any? { |_, env| env["SILO_INSPECTION_ACTION"] == "revoke" })
  end

  def test_close_fences_launchers_keys_and_read_sessions
    @host.merge_inspection_open(RUN, phase: "base")
    launcher = "9" * 64
    @runtime.launchers = [launcher]
    summary = @host.merge_inspection_close(RUN)
    assert_equal "closed", summary["state"]
    assert_empty summary["endpoints"]
    commands = @runtime.calls.map(&:first)
    assert_includes commands, ["docker", "rm", "--force", launcher]
    sqls = @runtime.calls.map(&:last).compact.join("\n")
    assert_match(/ALTER ROLE "silo_mi_[0-9a-f]{8}" NOLOGIN/, sqls)
    assert_includes sqls, "pg_terminate_backend"
    assert_match(/DROP ROLE "silo_mi_[0-9a-f]{8}"/, sqls)
    revoke = @stack.runner_calls.find { |_, env| env["SILO_INSPECTION_ACTION"] == "revoke" }
    assert_equal "9", revoke[1]["SILO_INSPECTION_KEY_IDS"]
    assert_equal ["source-read-policy.json"], Dir.children(private_path("merge-inspection"))
    assert_equal "closed", manifest["state"]
    calls = @runtime.calls.size
    assert_equal "closed", @host.merge_inspection_close(RUN)["state"]
    assert_equal calls, @runtime.calls.size
  end

  def test_failed_revocation_keeps_the_fence_closed_to_launches_and_retries
    @host.merge_inspection_open(RUN, phase: "base")
    @stack.revoke_fails = true
    assert_code("STANDARD_MERGE_INSPECTION_FENCE_FAILED") { @host.merge_inspection_close(RUN) }
    assert_equal "fencing", manifest["state"] # bin/merge_mcp.py launches only "open"
    assert File.exist?(private_path("merge-inspection", "base.key")) # kept until revoked
    @stack.revoke_fails = false
    assert_equal "closed", @host.merge_inspection_close(RUN)["state"]
    refute File.exist?(private_path("merge-inspection", "base.key"))
  end

  def test_close_without_manifest_still_removes_owned_launchers
    launcher = "8" * 64
    @runtime.launchers = [launcher]
    assert_equal "closed", @host.merge_inspection_close(RUN)["state"]
    assert_includes @runtime.calls.map(&:first), ["docker", "rm", "--force", launcher]
  end

  private

  def assert_code(code)
    error = assert_raises(SiloMigrate::StandardWorkflowError) { yield }
    assert_equal code, error.code
    error
  end
end
