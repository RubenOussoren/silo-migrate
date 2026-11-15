# frozen_string_literal: true
begin
  gem "minitest", ">= 5.0", "< 6.0"
rescue Gem::LoadError
  nil
end
require "minitest/autorun"
require "ostruct"
require "tmpdir"
require_relative "../runtime/prebuilt-discourse/merge_validate"
require_relative "../runtime/prebuilt-discourse/merge_adapter"
ENV["SILO_MERGE_VALIDATION_CONFIG_TEST"] = "1"
require_relative "../runtime/prebuilt-discourse/merge_validation_config"
ENV.delete("SILO_MERGE_VALIDATION_CONFIG_TEST")

class MergeValidateTest < Minitest::Test
  class InventedPolicyDenied < StandardError; end

  def contract
    SiloMergeContract.load(JSON.generate({ "version" => 1, "engine" => "discourse-merger-v1", "settings_schema" => { "type" => "object", "properties" => { "policy" => { "type" => "string", "enum" => ["carried"] } }, "required" => ["policy"], "additionalProperties" => false }, "asset_policy_key" => "policy", "asset_policies" => { "carried" => "carried" }, "audit_aggregates" => { "preflight" => ["uploads"], "postflight" => [] } }))
  end

  def merger
    Class.new do
      def self.new = raise("NO CONSTRUCTOR")
      def self.silo_merge_preflight! = true
      def self.silo_merge_asset_ids = [3, 1]
      def self.silo_merge_audit(_) = { "uploads" => 2 }
    end
  end

  def validate(klass = merger, **options)
    SiloMergeValidation.run!(merger: klass, contract: contract, settings: { "policy" => "carried" }, asset_preflight: ->(*) { OpenStruct.new(preflight_manifest_digest: "b" * 64, selection_digest: "c" * 64, owner_preflight_digest: "d" * 64) }, **options)
  end

  def test_preflight_precedes_selection_and_never_constructs
    klass = merger
    order = []
    klass.define_singleton_method(:silo_merge_preflight!) { order << :preflight; true }
    klass.define_singleton_method(:silo_merge_asset_ids) { order << :ids; [1] }
    klass.define_singleton_method(:silo_merge_audit) { |phase| order << phase; { "uploads" => 1 } }
    assert_equal "passed", validate(klass)["status"]
    assert_equal [:preflight, :ids, "preflight"], order
  end

  def test_semantic_finding_returns_offending_private_key_without_values_in_message
    klass = merger
    error = SiloMergeValidation::Finding.new(["routes", 17, "mode"], "destination_exists")
    refute_includes error.message, "routes"
    klass.define_singleton_method(:silo_merge_preflight!) { raise error }
    result = validate(klass)
    assert_equal "refused", result["status"]
    assert_equal "destination_exists", result["reason"]
    assert_equal ["routes", 17, "mode"], result["key_path"]
    assert_equal [], SiloMergeValidation.projection(result)["key_path"]
    assert_raises(ArgumentError) { SiloMergeValidation::Finding.new(["routes"], "CUSTOMER-DERIVED-CODE") }
  end

  def test_finding_rejects_binary_non_utf8_key_path_with_fixed_error
    binary = "\xFF".b
    assert binary.valid_encoding?
    error = assert_raises(ArgumentError) do
      SiloMergeValidation::Finding.new(["routes", binary], "destination_exists")
    end
    assert_equal "MERGE_FINDING_INVALID", error.message
    assert_nil error.cause
    assert_equal Encoding::BINARY, binary.encoding
  end

  def test_finding_normalizes_binary_ascii_key_path_for_json
    binary = "routes".b
    finding = SiloMergeValidation::Finding.new([binary, 17, "mode".b], "destination_exists")
    assert_equal ["routes", 17, "mode"], finding.key_path
    assert_equal [Encoding::UTF_8, Encoding::UTF_8], finding.key_path.grep(String).map(&:encoding)
    assert_equal Encoding::BINARY, binary.encoding
    assert finding.key_path.frozen?
    assert finding.key_path.grep(String).all?(&:frozen?)
    klass = merger
    klass.define_singleton_method(:silo_merge_preflight!) { raise finding }
    result = JSON.parse(JSON.generate(validate(klass)))
    assert_equal "refused", result.fetch("status")
    assert_equal "destination_exists", result.fetch("reason")
    assert_equal ["routes", 17, "mode"], result.fetch("key_path")
  end

  def test_hook_failure_never_calls_selection_or_adapter
    klass = merger
    klass.define_singleton_method(:silo_merge_preflight!) { false }
    klass.define_singleton_method(:silo_merge_asset_ids) { raise "unreachable" }
    assert_equal "preflight_refused", validate(klass)["reason"]
  end

  def test_raised_preflight_collects_private_partial_counters_before_selection
    klass = merger
    declared = JSON.parse(JSON.generate(contract))
    declared["audit_aggregates"]["preflight"] = %w[observed refused_policy]
    calls = []
    klass.define_singleton_method(:silo_merge_preflight!) do
      calls << :preflight
      @refused_policy = 1
      raise InventedPolicyDenied, "PRIVATE POLICY VALUE"
    end
    klass.define_singleton_method(:silo_merge_asset_ids) { calls << :selection; raise "unreachable" }
    klass.define_singleton_method(:silo_merge_audit) do |phase|
      calls << phase
      raise "lost policy environment" unless ENV["SILO_MERGE_UPLOAD_COPY_POLICY"] == "carried"
      { "refused_policy" => @refused_policy }
    end
    result = validate(klass, contract: declared)
    assert_equal "refused", result["status"]
    assert_equal "validation_unproven", result["reason"]
    assert_equal [:preflight, "preflight"], calls
    assert_equal({ "refused_policy" => 1 }, result["audit"])
    failure = result.fetch("failure")
    assert_equal "partial", failure["audit_status"]
    assert_equal ["observed"], failure["missing_keys"]
    assert_equal "read_only_clones", failure["write_boundary"]
    assert_equal "MergeValidateTest::InventedPolicyDenied", failure["error_class"]
    assert_equal false, failure["complete"]
    refute_includes JSON.generate(result), "PRIVATE POLICY VALUE"
    refute SiloMergeValidation.projection(result).key?("failure")
    refute SiloMergeValidation.projection(result).key?("audit")
  end

  def test_failure_audit_exception_does_not_replace_boolean_policy_refusal
    klass = merger
    klass.define_singleton_method(:silo_merge_preflight!) { false }
    klass.define_singleton_method(:silo_merge_audit) { |_| raise SystemExit, "PRIVATE AUDIT VALUE" }
    result = validate(klass)
    assert_equal "preflight_refused", result["reason"]
    assert_equal "hook_failed", result.dig("failure", "audit_status")
    assert_equal({}, result["audit"])
    assert_equal ["uploads"], result.dig("failure", "missing_keys")
    refute_includes JSON.generate(result), "PRIVATE AUDIT VALUE"
  end

  def test_failure_audit_rejects_undeclared_data_without_replacing_policy_refusal
    klass = merger
    klass.define_singleton_method(:silo_merge_preflight!) { false }
    klass.define_singleton_method(:silo_merge_audit) { |_| { "PRIVATE_DYNAMIC_KEY" => 1 } }
    result = validate(klass)
    assert_equal "preflight_refused", result["reason"]
    assert_equal "invalid", result.dig("failure", "audit_status")
    assert_equal({}, result["audit"])
    refute_includes JSON.generate(result), "PRIVATE_DYNAMIC_KEY"
  end

  def test_success_does_not_add_refusal_metadata_or_repeat_audit
    klass = merger
    calls = []
    klass.define_singleton_method(:silo_merge_audit) { |phase| calls << phase; { "uploads" => 2 } }
    result = validate(klass)
    assert_equal "passed", result["status"]
    refute result.key?("failure")
    assert_equal ["preflight"], calls
  end

  def test_later_asset_refusal_uses_the_already_validated_audit_snapshot
    klass = merger
    calls = 0
    klass.define_singleton_method(:silo_merge_audit) do |_phase|
      calls += 1
      raise "PRIVATE SECOND CALLBACK" if calls > 1
      { "uploads" => 2 }
    end
    result = validate(klass, asset_preflight: ->(*) { raise SiloDiscourseMergeAdapter::Error, "PRIVATE ASSET" })
    assert_equal "assets_unproven", result["reason"]
    assert_equal 1, calls
    assert_equal({ "uploads" => 2 }, result["audit"])
    assert_equal "partial", result.dig("failure", "audit_status")
    assert_equal [], result.dig("failure", "missing_keys")
    refute_includes JSON.generate(result), "PRIVATE"
  end

  def test_system_exit_becomes_fixed_refusal
    klass = merger
    klass.define_singleton_method(:silo_merge_preflight!) { raise SystemExit, "SECRET" }
    result = validate(klass)
    assert_equal "validation_unproven", result["reason"]
    refute_includes JSON.generate(result), "SECRET"
  end

  def test_ids_are_unique_positive_and_private
    [ [1, 1], [0], [-1], ["1"] ].each do |ids|
      klass = merger
      klass.define_singleton_method(:silo_merge_asset_ids) { ids }
      assert_equal "asset_selection_invalid", validate(klass)["reason"]
    end
    result = validate
    assert_equal [1, 3], result["approved_ids"]
    assert_equal Digest::SHA256.hexdigest("[1,3]"), result["selected_ids_sha256"]
    refute SiloMergeValidation.projection(result).key?("approved_ids")
    refute SiloMergeValidation.projection(result).key?("audit")
  end

  def test_unknown_or_missing_audit_is_not_zero
    klass = merger
    klass.define_singleton_method(:silo_merge_audit) { |_| {} }
    assert_equal "audit_invalid", validate(klass)["reason"]
  end

  def test_typed_adapter_refusal_is_assets_unproven_without_relaying_private_details
    private_detail = "private asset path or metadata"
    result = validate(asset_preflight: ->(*) { raise SiloDiscourseMergeAdapter::Error, private_detail })
    assert_equal "refused", result["status"]
    assert_equal "assets_unproven", result["reason"]
    refute_includes JSON.generate(result), private_detail
    assert_nil result["asset_preflight_sha256"]
    result = validate(asset_preflight: ->(*) { raise private_detail })
    assert_equal "validation_unproven", result["reason"]
    refute_includes JSON.generate(result), private_detail
  end

  def test_adapter_is_required_and_policy_is_set_only_after_contract_validation
    before = ENV["SILO_MERGE_UPLOAD_COPY_POLICY"]
    observed = nil
    result = validate(asset_preflight: ->(*) { observed = ENV["SILO_MERGE_UPLOAD_COPY_POLICY"]; OpenStruct.new(preflight_manifest_digest: "b" * 64, selection_digest: "c" * 64, owner_preflight_digest: "d" * 64) })
    assert_equal "passed", result["status"]
    assert_equal "carried", observed
    before.nil? ? assert_nil(ENV["SILO_MERGE_UPLOAD_COPY_POLICY"]) : assert_equal(before, ENV["SILO_MERGE_UPLOAD_COPY_POLICY"])
    assert_equal "assets_unproven", validate(asset_preflight: nil)["reason"]
  end

  def test_exact_existence_statuses_and_parameterized_names
    requests = [ { "kind" => "group", "name" => "x' OR true--" }, { "kind" => "tag", "name" => "absent" }, { "kind" => "tag", "name" => "double" } ]
    seen = []
    query = lambda do |sql, values|
      seen << [sql, values]
      case values.first
      when "absent" then []
      when "double" then [{ "id" => "1" }, { "id" => "2" }]
      else [{ "id" => "3" }]
      end
    end
    results = SiloMergeValidation.existence(requests, query: query)
    assert_equal %w[found absent ambiguous], results.map { |row| row["status"] }
    assert seen.all? { |sql, _| sql.include?("lower(name) = lower($1)") && !sql.include?("OR true") }
    assert_equal "x' OR true--", seen.first.last.first
    assert_equal "unproven", SiloMergeValidation.existence([requests.first]).first["status"]
    assert_equal "unproven", SiloMergeValidation.existence([requests.first], query: ->(*) { raise "private" }).first["status"]
  end

  def test_category_hierarchy_is_not_a_slash_or_global_name_guess
    query_calls = []
    query = lambda do |sql, values|
      query_calls << [sql, values]
      values == ["Root", nil] ? [{ "id" => "17" }] : []
    end
    result = SiloMergeValidation.existence([{ "kind" => "category", "path" => ["Root", "Child"] }], query: query)
    assert_equal "absent", result.first["status"]
    assert_equal ["Child", 17], query_calls.last.last
    assert_includes query_calls.last.first, "parent_category_id IS NOT DISTINCT FROM $2"
    assert_raises(SiloMergeValidation::Refused) { SiloMergeValidation.existence([{ "kind" => "category", "name" => "Root/Child" }], query: query) }
  end

  def test_projection_is_fixed_key_bounded_and_drops_customer_key_paths
    result = validate
    result["key_path"] = ["private project identifier"]
    projection = SiloMergeValidation.projection(result)
    assert_equal [], projection["key_path"]
    assert_equal %w[asset_preflight_sha256 key_path reason selected_ids_sha256 selection_sha256 status version], projection.keys.sort
  end

  def test_pg_string_metadata_is_typed_at_boundary
    rows = [{ "id" => "12", "filesize" => "42", "sha1" => "a" * 40, "url" => "/original/a.png" }]
    typed = SiloMergeValidation.upload_rows(rows)
    assert_equal 12, typed.first["id"]
    assert_equal 42, typed.first["filesize"]
    assert_equal "12", rows.first["id"]
    assert_raises(SiloMergeValidation::Refused) { SiloMergeValidation.upload_rows([{ "id" => "not an int", "filesize" => "4" }]) }
  end

  def test_pg_first_page_does_not_silently_filter_nonpositive_source_ids
    calls = []
    source = Object.new
    source.define_singleton_method(:exec_params) do |sql, parameters|
      calls << [sql, parameters]
      if calls.size == 1
        [{ "id" => "-1", "filesize" => "42", "sha1" => "a" * 40, "original_sha1" => "b" * 40, "secure" => "t", "url" => "/original/a.png" }]
      else
        []
      end
    end
    rows = SiloMergeValidation.source_upload_rows(source)
    assert_equal(-1, rows.first["id"])
    assert_equal 42, rows.first["filesize"]
    assert_equal "b" * 40, rows.first["original_sha1"]
    refute_includes calls.first.first, "WHERE"
    assert_equal [], calls.first.last
    assert_equal [-1], calls.last.last
    assert_includes calls.first.first, "original_sha1, secure"
  end

  def test_required_owner_feasibility_skips_only_proven_digest_reuse
    calls = []
    source = Object.new
    source.define_singleton_method(:exec_params) { |sql, values| calls << [sql, values]; [{ "id" => "1" }] }
    rows = [{ "id" => 1, "filesize" => 42, "sha1" => "a" * 40 }]
    assert_raises(SiloMergeValidation::Refused) { SiloMergeValidation.required_owners!(source, rows, [], [1]) }
    assert_includes calls.first.first, "user_emails.primary = TRUE"
    assert_equal [1], calls.first.last
    calls.clear
    assert SiloMergeValidation.required_owners!(source, rows, [{ "sha1" => "a" * 40 }], [1])
    assert_empty calls
  end

  def test_category_path_depth_matches_public_32_level_contract
    accepted = [{ "kind" => "category", "path" => Array.new(32) { |index| "level#{index}" } }]
    assert_equal accepted, SiloMergeValidation.request!(accepted)
    rejected = [{ "kind" => "category", "path" => Array.new(33) { |index| "level#{index}" } }]
    assert_raises(SiloMergeValidation::Refused) { SiloMergeValidation.request!(rejected) }
  end

  def test_pg_constructor_aliases_enforce_clones_and_bound_credentials
    context = { "source" => "silo_val_s_#{'a' * 32}", "base" => "silo_val_b_#{'a' * 32}", "role" => "silo_val_r_#{'a' * 32}", "host" => "validation-db", "port" => 5432, "password" => "b" * 64 }
    calls = []
    connection = Class.new do
      attr_reader :options
      define_method(:initialize) do |**options|
        calls << options
        @options = options
      end
    end
    aliases = %i[connect open connect_start sync_connect async_connect setdb setdblogin]
    aliases.each { |name| connection.define_singleton_method(name) { |**options| new(**options) } }
    pg = Module.new
    pg.const_set(:Connection, connection)
    aliases.each { |name| pg.define_singleton_method(name) { |**options| connection.public_send(name, **options) } }
    pg.define_singleton_method(:escape_literal) { |value| "untouched:#{value}" }
    SiloMergeValidationConfig.install_connection_guards!(pg, context)

    [[pg, aliases], [connection, [:new, *aliases]]].each do |target, methods|
      methods.each do |name|
        before = calls.size
        error = assert_raises(RuntimeError) { target.public_send(name, dbname: "discourse", user: "postgres", password: "ORIGINAL_SECRET") }
        assert_equal "STANDARD_MERGE_VALIDATION_CONFIG", error.message
        assert_nil error.cause
        refute_includes error.message, "ORIGINAL_SECRET"
        assert_equal before, calls.size
        options = target.public_send(name, dbname: context.fetch("base"), user: "postgres", host: "original-db", password: "ORIGINAL_SECRET", port: 123).options
        assert_equal context.fetch("base"), options.fetch(:dbname)
        %w[role host password port].each do |key|
          option_key = key == "role" ? :user : key.to_sym
          assert_equal context.fetch(key), options.fetch(option_key)
        end
      end
    end
    before = calls.size
    assert_raises(RuntimeError) { connection.new("dbname=discourse password=ORIGINAL_SECRET") }
    assert_raises(RuntimeError) { connection.connect({ dbname: context.fetch("base") }, user: "postgres") }
    assert_raises(RuntimeError) { connection.new({ "dbname" => context.fetch("base"), dbname: context.fetch("source") }) }
    assert_equal before, calls.size
    %i[hostaddr service servicefile passfile].each do |key|
      options = connection.new(dbname: context.fetch("source"), key => "unbound").options
      refute options.key?(key)
      assert_equal context.fetch("host"), options.fetch(:host)
    end
    assert_equal "untouched:value", pg.escape_literal("value")
    assert_equal context.fetch("source"), connection.new({ "dbname" => context.fetch("source") }).options.fetch(:dbname)
  end

  def test_nested_pg_connect_start_options_are_rebound_and_errors_are_fixed
    context = { "source" => "silo_val_s_#{'a' * 32}", "base" => "silo_val_b_#{'a' * 32}", "role" => "silo_val_r_#{'a' * 32}", "host" => "validation-db", "port" => 5432, "password" => "b" * 64 }
    connection = Class.new
    connection.define_singleton_method(:new) do |**options|
      # Match PG's internal async hostname expansion before connect_start.
      connect_start(options.merge(hostaddr: "127.0.0.1", host: "validation-db,validation-db", port: "5432,5432"))
    end
    connection.define_singleton_method(:connect_start) { |**options| options }
    pg = Module.new
    pg.const_set(:Connection, connection)
    SiloMergeValidationConfig.install_connection_guards!(pg, context)
    options = connection.new(dbname: context.fetch("base"))
    refute options.key?(:hostaddr)
    assert_equal context.fetch("host"), options.fetch(:host)
    assert_equal context.fetch("port"), options.fetch(:port)
    assert_equal context.fetch("role"), options.fetch(:user)
    assert_equal context.fetch("password"), options.fetch(:password)
    pg_conn_bad = Class.new(StandardError) { def self.name = "PG::ConnectionBad" }
    connection.define_singleton_method(:connect_start) { |**_| raise pg_conn_bad, "password=ORIGINAL_SECRET host=private.internal" }
    error = assert_raises(RuntimeError) { connection.new(dbname: context.fetch("base")) }
    assert_kind_of SiloMergeValidationConfig::Refused, error
    assert_equal "STANDARD_MERGE_VALIDATION_CONFIG", error.message
    assert_nil error.cause
    assert_equal "PG::ConnectionBad", error.guest_diagnostic["error_class"]
    refute_includes JSON.generate(error.guest_diagnostic), "ORIGINAL_SECRET"
    refute_includes JSON.generate(error.guest_diagnostic), "private.internal"
    captured = SiloMergeValidationDiagnostic.capture(stage: "rails_boot", error: error)
    assert_equal "rails_boot", captured["stage"]
    assert_equal "PG::ConnectionBad", captured["error_class"]
    SiloMergeValidationDiagnostic.validate!(captured)
  end

  def test_config_override_matches_pinned_core_keyword_signature
    provider = Class.new do
      def self.configure!(path: "original.conf", use_blank_provider: false)
        [path, use_blank_provider]
      end
    end
    provider.singleton_class.prepend(SiloMergeValidationConfig::GlobalSettingOverride)
    previous = ENV["SILO_MERGE_VALIDATION_CONFIG"]
    ENV["SILO_MERGE_VALIDATION_CONFIG"] = "/private/discourse-validation.conf"
    assert_equal ["/private/discourse-validation.conf", false], provider.configure!
    assert_equal ["/private/discourse-validation.conf", true], provider.configure!(path: "owner.conf", use_blank_provider: true)
  ensure
    previous.nil? ? ENV.delete("SILO_MERGE_VALIDATION_CONFIG") : ENV["SILO_MERGE_VALIDATION_CONFIG"] = previous
  end

  def test_config_requires_private_context_and_cannot_name_original_databases
    Dir.mktmpdir do |root|
      path = File.join(root, "context.json")
      context = { "source" => "merge_source", "base" => "discourse", "role" => "discourse", "password" => "a" * 64, "host" => "db", "port" => 5432 }
      File.write(path, JSON.generate(context), mode: "w", perm: 0o600)
      assert_raises(RuntimeError) { SiloMergeValidationConfig.read_context(path) }
      id = "b" * 32
      context.merge!("source" => "silo_val_s_#{id}", "base" => "silo_val_b_#{id}", "role" => "silo_val_r_#{id}", "redis_isolated" => true, "redis_host" => "validation-redis", "redis_port" => 6379)
      File.write(path, JSON.generate(context))
      assert_equal context, SiloMergeValidationConfig.read_context(path)
      File.chmod(0o644, path)
      assert_raises(RuntimeError) { SiloMergeValidationConfig.read_context(path) }
    end
  end

  def test_config_copy_overrides_owner_credentials_without_touching_original
    Dir.mktmpdir do |root|
      original = File.join(root, "original.conf")
      target = File.join(root, "discourse-validation.conf")
      bytes = "db_username = 'discourse'\ndb_password = 'OLD_SECRET'\nredis_host = 'existing'\nmessage_bus_redis_enabled = true\nmessage_bus_redis_host = 'existing-messagebus'\nhostname = 'fixture.invalid'\n"
      File.write(original, bytes, mode: "w", perm: 0o600)
      old_context = ENV["SILO_MERGE_VALIDATION_CONTEXT"]
      ENV["SILO_MERGE_VALIDATION_CONTEXT"] = File.join(root, "context.json")
      context = { "original_config_path" => original, "validation_config_path" => target, "host" => "db", "port" => 5432, "role" => "silo_val_r_#{'a' * 32}", "base" => "silo_val_b_#{'a' * 32}", "password" => "b" * 64, "redis_host" => "validation-redis", "redis_port" => 6379 }
      SiloMergeValidationConfig.build!(context)
      assert_equal bytes, File.read(original)
      refute_includes File.read(target), "OLD_SECRET"
      refute_includes File.read(target), "'discourse'"
      refute_includes File.read(target), "existing-messagebus"
      assert_includes File.read(target), "message_bus_redis_enabled = 'false'"
      assert_equal 0, File.stat(target).mode & 0o077
    ensure
      old_context.nil? ? ENV.delete("SILO_MERGE_VALIDATION_CONTEXT") : ENV["SILO_MERGE_VALIDATION_CONTEXT"] = old_context
    end
  end

  def test_refused_results_include_privacy_safe_guest_diagnostic_and_passing_results_do_not
    passed = validate
    refute passed.key?("guest_diagnostic")
    refute SiloMergeValidation.projection(passed).key?("guest_diagnostic")

    klass = merger
    klass.define_singleton_method(:silo_merge_preflight!) { false }
    refused = validate(klass)
    diag = refused.fetch("guest_diagnostic")
    assert_equal({
      "version" => 1,
      "stage" => "policy_preflight",
      "error_class" => "SiloMergeValidation::Refused",
      "component" => "validation_runner",
      "line" => diag["line"]
    }, diag)
    assert diag["line"].is_a?(Integer) && diag["line"].positive?
    assert_equal diag, SiloMergeValidation.projection(refused).fetch("guest_diagnostic")

    finding_klass = merger
    finding = SiloMergeValidation::Finding.new(["PRIVATE_SETTING_KEY", 7], "policy_conflict")
    finding.set_backtrace(["/shared/silo-validation-#{'a' * 32}/layer/merger.rb:88:in `silo_merge_preflight!'"])
    finding_klass.define_singleton_method(:silo_merge_preflight!) { raise finding }
    finding_result = validate(finding_klass)
    finding_diag = finding_result.fetch("guest_diagnostic")
    assert_equal "policy_preflight", finding_diag["stage"]
    assert_equal "SiloMergeValidation::Finding", finding_diag["error_class"]
    assert_equal "custom_layer", finding_diag["component"]
    assert_nil finding_diag["line"]
    projected = SiloMergeValidation.projection(finding_result)
    assert_equal [], projected["key_path"]
    assert_equal finding_diag, projected["guest_diagnostic"]
    refute_includes JSON.generate(projected), "PRIVATE_SETTING_KEY"

    tampered = finding_result.merge("guest_diagnostic" => finding_diag.merge("error_class" => "PRIVATE_CLASS"))
    refute SiloMergeValidation.projection(tampered).key?("guest_diagnostic")
  end

  def test_flat_guest_copy_and_main_retain_top_level_stage_and_safe_error_class
    Dir.mktmpdir do |root|
      runtime_root = File.expand_path("../runtime", __dir__)
      %w[merge_validate.rb merge_validation_config.rb merge_adapter.rb merge_asset_references.rb merge_baseline_assets.rb].each do |name|
        File.write(File.join(root, name), File.binread(File.join(runtime_root, "prebuilt-discourse", name)), mode: "wb", perm: 0o600)
      end
      %w[merge_contract.rb merge_assets.rb merge_refusal.rb merge_validation_diagnostic.rb].each do |name|
        File.write(File.join(root, name), File.binread(File.join(runtime_root, "shared", name)), mode: "wb", perm: 0o600)
      end
      context_path = File.join(root, "context.json")
      result_path = File.join(root, "result.json")
      File.write(context_path, JSON.generate({ "mode" => "full" }), mode: "w", perm: 0o600)

      stdout_r, stdout_w = IO.pipe
      pid = Process.spawn(
        {
          "SILO_MERGE_VALIDATION_CONTEXT" => context_path,
          "SILO_MERGE_VALIDATION_RESULT" => result_path
        },
        RbConfig.ruby,
        File.join(root, "merge_validate.rb"),
        out: stdout_w,
        err: File::NULL
      )
      stdout_w.close
      output = stdout_r.read
      stdout_r.close
      _, status = Process.wait2(pid)

      assert_equal 4, status.exitstatus
      assert output.start_with?(SiloMergeValidation::PREFIX)
      projected = JSON.parse(output.delete_prefix(SiloMergeValidation::PREFIX).strip)
      persisted = JSON.parse(File.read(result_path))
      assert_equal "refused", persisted["status"]
      assert_equal "validation_unproven", persisted["reason"]
      diag = persisted.fetch("guest_diagnostic")
      assert_equal "rails_boot", diag["stage"]
      assert_equal "SiloMergeValidation::Refused", diag["error_class"]
      assert_equal "validation_runner", diag["component"]
      assert diag["line"].is_a?(Integer) && diag["line"].positive?
      assert_equal diag, projected.fetch("guest_diagnostic")
      SiloMergeValidationDiagnostic.validate!(diag)

      # Existing result file causes result_persistence failure when context fails,
      # preserving the primary context stage diagnostic; if context+checks pass
      # and result file already exists, result_persistence is reported.
      File.write(context_path, JSON.generate({ "mode" => "checks", "host" => "127.0.0.1", "port" => 1, "base" => "b", "role" => "r", "password" => "SECRET_DB_PASSWORD", "checks" => [] }), mode: "w", perm: 0o600)
      db_result_path = File.join(root, "db-result.json")
      out2_r, out2_w = IO.pipe
      pid2 = Process.spawn(
        {
          "SILO_MERGE_VALIDATION_CONTEXT" => context_path,
          "SILO_MERGE_VALIDATION_RESULT" => db_result_path
        },
        RbConfig.ruby,
        File.join(root, "merge_validate.rb"),
        out: out2_w,
        err: File::NULL
      )
      out2_w.close
      out2 = out2_r.read
      out2_r.close
      _, status2 = Process.wait2(pid2)
      assert_equal 4, status2.exitstatus
      refute_includes out2, "SECRET_DB_PASSWORD"
      refute_includes File.read(db_result_path), "SECRET_DB_PASSWORD"
      db_diag = JSON.parse(File.read(db_result_path)).fetch("guest_diagnostic")
      assert_equal "checks_database", db_diag["stage"]
      SiloMergeValidationDiagnostic.validate!(db_diag)

      # Secondary persistence failure (pre-existing result file with File::EXCL)
      # preserves an already refused primary reason and first diagnostic instead
      # of masking it with validation_unproven / result_persistence.
      stub_pg = File.join(root, "stub_pg.rb")
      File.write(stub_pg, <<~RUBY, mode: "w", perm: 0o600)
        $LOADED_FEATURES << "pg.rb" << "pg"
        module PG
          def self.connect(**)
            conn = Object.new
            conn.define_singleton_method(:exec_params) { |*, **| [{}] }
            conn.define_singleton_method(:close) { nil }
            conn
          end
        end
      RUBY
      File.write(
        context_path,
        JSON.generate({
          "mode" => "checks",
          "host" => "127.0.0.1",
          "port" => 5432,
          "base" => "b",
          "role" => "r",
          "password" => "SECRET_DB_PASSWORD",
          "checks" => [{ "kind" => "tag", "name" => "alpha" }]
        }),
        mode: "w",
        perm: 0o600
      )
      existing_result_path = File.join(root, "existing-result.json")
      File.write(existing_result_path, "{}", mode: "w", perm: 0o600)
      out3_r, out3_w = IO.pipe
      pid3 = Process.spawn(
        {
          "SILO_MERGE_VALIDATION_CONTEXT" => context_path,
          "SILO_MERGE_VALIDATION_RESULT" => existing_result_path
        },
        RbConfig.ruby,
        "-r#{stub_pg}",
        File.join(root, "merge_validate.rb"),
        out: out3_w,
        err: File::NULL
      )
      out3_w.close
      out3 = out3_r.read
      out3_r.close
      _, status3 = Process.wait2(pid3)
      assert_equal 4, status3.exitstatus
      projected3 = JSON.parse(out3.delete_prefix(SiloMergeValidation::PREFIX).strip)
      assert_equal "refused", projected3["status"]
      assert_equal "checks_invalid", projected3["reason"]
      assert_equal "existence_checks", projected3.dig("guest_diagnostic", "stage")
      assert_equal "none", projected3.dig("guest_diagnostic", "error_class")

      # When primary work passed ("checks": []), secondary persistence failure
      # converts passing result to refused validation_unproven + result_persistence.
      File.write(
        context_path,
        JSON.generate({
          "mode" => "checks",
          "host" => "127.0.0.1",
          "port" => 5432,
          "base" => "b",
          "role" => "r",
          "password" => "SECRET_DB_PASSWORD",
          "checks" => []
        }),
        mode: "w",
        perm: 0o600
      )
      out4_r, out4_w = IO.pipe
      pid4 = Process.spawn(
        {
          "SILO_MERGE_VALIDATION_CONTEXT" => context_path,
          "SILO_MERGE_VALIDATION_RESULT" => existing_result_path
        },
        RbConfig.ruby,
        "-r#{stub_pg}",
        File.join(root, "merge_validate.rb"),
        out: out4_w,
        err: File::NULL
      )
      out4_w.close
      out4 = out4_r.read
      out4_r.close
      _, status4 = Process.wait2(pid4)
      assert_equal 4, status4.exitstatus
      projected4 = JSON.parse(out4.delete_prefix(SiloMergeValidation::PREFIX).strip)
      assert_equal "refused", projected4["status"]
      assert_equal "validation_unproven", projected4["reason"]
      assert_equal "result_persistence", projected4.dig("guest_diagnostic", "stage")
      assert_equal "Errno::EEXIST", projected4.dig("guest_diagnostic", "error_class")

      # Bootstrap abort via RUBYOPT=-r emits ONE bounded safe diagnostic prefix
      # line + fixed abort tag, with no raw private path or secret content.
      secret_context_path = File.join(root, "PRIVATE_CANARY_PATH_SECRET_context.json")
      File.write(secret_context_path, "{bad_json_SECRET_TOKEN", mode: "w", perm: 0o600)
      err_r, err_w = IO.pipe
      pid5 = Process.spawn(
        {
          "RUBYOPT" => "-r#{File.join(root, 'merge_validation_config.rb')}",
          "SILO_MERGE_VALIDATION_CONTEXT" => secret_context_path
        },
        RbConfig.ruby,
        "-e",
        "exit 0",
        out: File::NULL,
        err: err_w
      )
      err_w.close
      stderr5 = err_r.read
      err_r.close
      _, status5 = Process.wait2(pid5)
      refute status5.success?
      refute_includes stderr5, "PRIVATE_CANARY_PATH_SECRET"
      refute_includes stderr5, "SECRET_TOKEN"
      assert_includes stderr5, "STANDARD_MERGE_VALIDATION_CONFIG"
      diag_lines = stderr5.lines.select { |line| line.start_with?(SiloMergeValidationDiagnostic::PREFIX) }
      assert_equal 1, diag_lines.size
      assert_operator diag_lines.first.bytesize, :<=, 1024
      boot_diag = JSON.parse(diag_lines.first.delete_prefix(SiloMergeValidationDiagnostic::PREFIX).strip)
      assert_equal({
        "version" => 1,
        "stage" => "bootstrap",
        "error_class" => "JSON::ParserError",
        "component" => "validation_config",
        "line" => boot_diag["line"]
      }, boot_diag)
      assert boot_diag["line"].is_a?(Integer) && boot_diag["line"].positive?
      SiloMergeValidationDiagnostic.validate!(boot_diag)
    end
  end
end
