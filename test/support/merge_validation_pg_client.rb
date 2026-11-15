# frozen_string_literal: true
# Native pg-gem acceptance only; no Rails boot, filesystem context, or Docker API.
# Invoked inside the cached app image, sharing only the owned network-none PG
# namespace. Context arrives on stdin, never in argv, environment or output.
require "json"
require "timeout"

class NativePGAcceptanceError < StandardError; end

module NativePGAcceptance
  module_function

  TAG = "STANDARD_MERGE_VALIDATION_CONFIG"
  ALIASES = %i[connect open connect_start sync_connect async_connect setdb setdblogin].freeze

  def assert(condition)
    raise NativePGAcceptanceError, "native_pg_query_unproven" unless condition
  end

  def finish_connect(connection)
    # connect_start is genuinely asynchronous. Do not confuse obtaining an object
    # with having connected successfully; poll it, then prove a server-side query.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    while connection.status != PG::CONNECTION_OK
      assert(Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline)
      case connection.connect_poll
      when PG::PGRES_POLLING_OK
        break
      when PG::PGRES_POLLING_READING
        IO.select([connection.socket_io], nil, nil, 0.1)
      when PG::PGRES_POLLING_WRITING
        IO.select(nil, [connection.socket_io], nil, 0.1)
      when PG::PGRES_POLLING_ACTIVE
        sleep 0.01
      else
        raise NativePGAcceptanceError, "native_pg_query_unproven"
      end
    end
    assert(connection.status == PG::CONNECTION_OK)
  end

  def prove_connection(target, method, args, kwargs, context, database)
    connection = nil
    Timeout.timeout(8) do
      connection = target.public_send(method, *args, **kwargs)
      @progress["check"] = "connection_class"
      assert(connection.is_a?(PG::Connection))
      @progress["check"] = "connection_poll"
      finish_connect(connection)
      @progress["check"] = "identity_query"
      # inet::text includes a /32 mask; host(inet) is the address-only identity.
      row = connection.exec("SELECT current_user, current_database(), host(inet_server_addr()), inet_server_port(), (SELECT rolsuper FROM pg_roles WHERE rolname=current_user)").values
      @progress["check"] = "identity_match"
      assert(row == [[context.fetch("role"), database, "127.0.0.1", "5432", "f"]])
      @progress["check"] = "readonly_query"
      assert(connection.exec("SHOW default_transaction_read_only").getvalue(0, 0) == "on")
    end
  ensure
    connection.finish if connection.is_a?(PG::Connection) && !connection.finished?
  end

  def prove_refusal(target, method, args, kwargs)
    connection = nil
    @progress["phase"], @progress["check"] = "guard_refusal", "guard_refusal_invocation"
    begin
      Timeout.timeout(8) { connection = target.public_send(method, *args, **kwargs) }
    rescue RuntimeError => error
      # A typed fixed-tag error counts only in deliberately invalid-input cases.
      # Native connection failures must never masquerade as guard acceptance.
      @progress["check"] = "guard_refusal_class"
      assert(error.class == SiloMergeValidationConfig::Refused && error.message == TAG && error.cause.nil?)
      diagnostic = SiloMergeValidationDiagnostic.validate!(error.guest_diagnostic)
      @progress["check"] = "guard_refusal_diagnostic"
      assert(diagnostic.fetch("error_class") == "RuntimeError" && diagnostic.fetch("component") == "validation_config")
      return
    ensure
      connection.finish if connection.is_a?(PG::Connection) && !connection.finished?
    end
    raise NativePGAcceptanceError, "native_pg_guard_refusal_unproven"
  end

  def progress = @progress || {}

  def run(context)
    token = context.fetch("source").delete_prefix("silo_val_s_")
    assert(token.match?(/\A[0-9a-f]{32}\z/))
    assert(context.fetch("source") == "silo_val_s_#{token}")
    assert(context.fetch("base") == "silo_val_b_#{token}")
    assert(context.fetch("role") == "silo_val_r_#{token}")
    assert(context.fetch("password").match?(/\A[0-9a-f]{64}\z/))
    assert(context.fetch("host") == "127.0.0.1" && context.fetch("port") == 5432)
    # First isolate fixture/authentication failures from guard failures.
    @progress = { "phase" => "unguarded_fixture_query" }
    prove_connection(PG, :connect, [], { dbname: context.fetch("base"), host: context.fetch("host"),
                                      port: context.fetch("port"), user: context.fetch("role"),
                                      password: context.fetch("password"), connect_timeout: 2 }, context, context.fetch("base"))
    SiloMergeValidationConfig.install_connection_guards!(PG, context)

    constructors = [[PG, ALIASES], [PG::Connection, [:new, *ALIASES]]].flat_map do |target, names|
      names.select { |method| target.respond_to?(method) }.map { |method| [target, method] }
    end
    @progress = { "phase" => "constructor_presence", "available" => constructors.map { |target, method| "#{target == PG ? 'PG' : 'Connection'}.#{method}" } }
    [[PG, :connect], *%i[new connect open connect_start].map { |method| [PG::Connection, method] }].each do |pair|
      assert(constructors.include?(pair))
    end
    queries = refusals = rebound = 0
    constructors.each do |target, method|
      @progress = { "phase" => "query", "constructor" => "#{target == PG ? 'PG' : 'Connection'}.#{method}" }
      [context.fetch("source"), context.fetch("base")].each do |database|
        options = { dbname: database, connect_timeout: 2 }
        prove_connection(target, method, [], options, context, database)
        queries += 1
        prove_connection(target, method, [options], {}, context, database)
        queries += 1
        # All supplied endpoint/credential indirections must be discarded or
        # rebound. A native PG error here is FAILURE, never evidence of a guard.
        hostile = options.merge(user: "postgres", password: "ignored-invented-value",
                                host: "invalid.example", hostaddr: "203.0.113.1", port: 9,
                                service: "nonexistent-live-service", servicefile: "/nonexistent-service",
                                passfile: "/nonexistent-password")
        prove_connection(target, method, [], hostile, context, database)
        queries += 1
        rebound += 1
      end
      %w[merge_source silo_clean_base discourse silo_inspect_source postgres].each do |database|
        prove_refusal(target, method, [], { dbname: database, user: "postgres", connect_timeout: 2 })
        refusals += 1
      end
      [
        [[{ dbname: context.fetch("base") }], { user: "postgres" }],
        [[{ dbname: context.fetch("base") }, { user: "postgres" }], {}],
        [["dbname=postgres user=postgres host=127.0.0.1 port=5432"], {}],
        [["127.0.0.1", "5432", nil, nil, "postgres", "postgres", "invented"], {}],
      ].each do |args, kwargs|
        prove_refusal(target, method, args, kwargs)
        refusals += 1
      end
    end
    { "status" => "passed", "native_pg_queries_proven" => true,
      "constructor_count" => constructors.size, "successful_query_count" => queries,
      "endpoint_role_rebinding_count" => rebound, "fixed_tag_refusal_count" => refusals }
  end
end

stage = "load"
begin
  # Mirror install!'s inherited-owner-environment removal, without booting Rails.
  ENV.keys.grep(/\APG|\ADATABASE_URL\z/).each { |key| ENV.delete(key) }
  ENV["SILO_MERGE_VALIDATION_CONFIG_TEST"] = "1"
  require "pg"
  require "/tmp/helper/merge_validation_config"
  stage = "context"
  bytes = STDIN.read(16 * 1024 + 1)
  raise NativePGAcceptanceError if bytes.bytesize > 16 * 1024
  context = JSON.parse(bytes)
  stage = "constructors"
  puts JSON.generate(NativePGAcceptance.run(context))
rescue StandardError
  # No libpq messages, causes, trace, context or credentials leave the container.
  puts JSON.generate({ "status" => "failed", "stage" => stage, "reason" => "native_pg_query_unproven" }.merge(NativePGAcceptance.progress))
  exit 1
end
