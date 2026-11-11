# frozen_string_literal: true

require_relative "test_helper"
require "silo_migrate/review_runtime"

class ReviewRuntimeTest < SiloMigrateTest
  SCHEMA = "20261101000000"

  def setup
    @dir = Dir.mktmpdir("review-runtime")
    @documents = {}
    @commands = []
    documents, commands = @documents, @commands
    @runtime = Object.new
    @runtime.define_singleton_method(:run) do |args, **options|
      commands << [args, options]
      raise "unexpected runtime operation" unless args.take(3) == %w[docker image inspect]

      document = documents[args.last]
      Struct.new(:stdout, :success?).new(JSON.generate(document ? [document] : []), !!document)
    end
    @profiles = SiloMigrate::RuntimeProfiles.new(code_root: @dir, env: {}, runtime: @runtime)
    @selector = SiloMigrate::ReviewRuntime.new(profiles: @profiles, runtime: @runtime)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def add(name, version: "2026.11.0-latest", schema: nil, migrations: nil, status: "qualified", channel: :infer)
    document = { "Id" => "sha256:" + "a" * 64, "Config" => {}, "RootFS" => { "Layers" => [name] } }
    images = %w[web db redis converter source_db].to_h do |role|
      ref = "synthetic/#{name}:#{role}"
      @documents[ref] = document
      [role, { "ref" => ref, "content_id" => SiloMigrate::ImageIdentity.content_id(document), "source" => "package" }]
    end
    profile = { "images" => images, "app" => { "version" => version, "revision" => "b" * 40 },
      "qualification" => { "status" => status }, "review_runtime" => {} }
    profile["review_runtime"]["schema"] = schema if schema
    profile["review_runtime"]["core_migrations"] = migrations if migrations
    profile["selector"] = { "channel" => channel } unless channel == :infer
    save(name, profile)
    profile
  end

  def save(name, profile)
    write(File.join(@dir, "runtime/profiles", "#{name}.json"), JSON.generate(profile))
  end

  def base(version = "2026.11.0-latest", schema = SCHEMA)
    { "discourse_version" => version, "schema_version" => schema }
  end

  def unresolved(**options)
    error = assert_raises(SiloMigrate::StandardWorkflowError) { @selector.select(**options) }
    assert_equal "STANDARD_REVIEW_RUNTIME_UNRESOLVED", error.code
  end

  def test_explicit_engineer_unqualified_override_is_not_an_automatic_fallback
    add('candidate', status: 'candidate')
    unresolved(preferred: 'candidate')
    result = @selector.select(preferred: 'candidate', allow_unqualified: true)
    assert_equal 'candidate', result['name']
    assert_equal 'candidate', result.dig('profile', 'qualification', 'status')
  end

  def test_no_base_chooses_newest_latest_not_stable_or_tests_passed
    add("old", version: "2026.9.0-latest")
    add("new", version: "2026.11.0-latest.2", channel: "latest")
    add("stable", version: "2027.1.0")
    add("beta", version: "2027.1.0-beta1")
    result = @selector.select
    assert_equal "new", result["name"]
    assert_equal "latest", result.dig("selection", "mode")
    assert_equal "latest", result.dig("selection", "track")
    assert_nil result.dig("selection", "requested_version")
    assert @commands.all? { |args, _| args.take(3) == %w[docker image inspect] }
  end

  def test_latest_dot_tag_and_hyphen_filename_are_the_same_public_version
    [["2026.11.0-latest.1", "2026.11.0-latest-1"],
     ["2026.11.0-latest-1", "2026.11.0-latest.1"]].each do |actual, requested|
      add("alias", version: actual, schema: SCHEMA, channel: "latest")
      result = @selector.select(base: base(requested))
      assert_equal "matched", result.dig("selection", "mode")
      assert_equal "latest", result.dig("selection", "track")
      assert_equal requested, result.dig("selection", "requested_version")
      assert_equal actual, result.dig("selection", "actual_version")
      add("alias", version: actual, channel: "latest")
      assert_equal "version_match", @selector.select(base: base(requested)).dig("selection", "mode")
    end
  end

  def test_stable_uses_public_version_without_assuming_a_stable_tag
    add("stable", version: "2026.7.5", channel: "stable")
    result = @selector.select(base: base("2026.7.5"))
    assert_equal "stable", result.dig("selection", "track")
    assert_equal "version_match", result.dig("selection", "mode")
    unresolved # Without a Base, a stable-only catalog is not a latest fallback.
  end

  def test_same_version_inventory_match_precedes_unknown_and_newer_without_preferred
    add("unknown")
    add("behind", schema: "20260101000000")
    add("match", migrations: [SCHEMA, "20261102000000"])
    add("newer", version: "2026.12.0-latest")
    result = @selector.select(base: base)
    assert_equal "match", result["name"]
    assert_equal "matched", result.dig("selection", "mode")
    assert_equal "20261102000000", result.dig("selection", "schema_version")
    assert_equal "b" * 40, result.dig("selection", "app_revision")
    refute_includes result["selection"].values, "exact"
  end

  def test_filename_version_without_known_core_schema_is_only_version_match
    add("unknown")
    result = @selector.select(base: base)
    assert_equal "version_match", result.dig("selection", "mode")
    assert_nil result.dig("selection", "schema_version")
  end

  def test_schema_ahead_hosted_plugin_is_nonblocking_but_prefers_new_schema
    add("behind", schema: "20260101000000")
    assert_equal "behind", @selector.select(base: base)["name"]
    add("ahead", schema: "20261102000000")
    result = @selector.select(base: base)
    assert_equal "ahead", result["name"]
    assert_equal "version_match", result.dig("selection", "mode")
  end

  def test_lowest_newer_same_track_and_changed_base_reselects
    add("patch", version: "3.10.1")
    add("minor", version: "3.11.0")
    add("latest", version: "2026.11.0-latest")
    add("beta", version: "3.10.2-beta1")
    result = @selector.select(base: base("3.10.0"))
    assert_equal "patch", result["name"]
    assert_equal "newer", result.dig("selection", "mode")
    assert_equal "minor", @selector.select(base: base("3.10.2"))["name"]
    assert_equal "latest", @selector.select["name"]
  end

  def test_prereleases_are_ordered_with_gem_version_but_never_cross_tracks
    add("beta2", version: "3.9.0-beta2", channel: "tests-passed")
    add("beta10", version: "3.9.0-beta10")
    add("rc", version: "3.9.0-rc1")
    add("stable", version: "3.9.0")
    assert_equal "beta10", @selector.select(base: base("3.9.0-beta3"))["name"]
    assert_equal "rc", @selector.select(base: base("3.9.0-rc1"))["name"]
    unresolved(base: base("3.9.0-latest"))
    unresolved(base: base("3.10.0"))
  end

  def test_catalog_is_reread_and_profiles_are_sha_bound_without_mutation
    add("first")
    path = @profiles.path("first")
    bytes = File.binread(path)
    first = @selector.select
    assert_equal Digest::SHA256.hexdigest(bytes), first["sha256"]
    assert_equal JSON.parse(bytes), first["profile"]
    add("second", version: "2026.12.0-latest", status: "review_ready")
    assert_equal "second", @selector.select["name"]
    assert_equal bytes, File.binread(path)
    assert_equal "qualified", JSON.parse(bytes).dig("qualification", "status")
  end

  def test_skips_bad_candidates_but_refuses_bad_preferred
    add("good")
    bad = add("bad", version: "2027.1.0-latest")
    @documents.delete(bad.dig("images", "db", "ref"))
    add("unqualified", status: "candidate")
    write(File.join(@dir, "runtime/profiles/broken.json"), "{")
    assert_equal "good", @selector.select["name"]
    %w[bad broken unqualified absent ../good].each { |name| unresolved(preferred: name) }
    unresolved(preferred: {})
  end

  def test_rejects_image_identity_drift_in_each_review_role
    %w[web db redis].each do |role|
      profile = add("only")
      @documents[profile.dig("images", role, "ref")] = { "Id" => "sha256:" + "c" * 64,
        "Config" => {}, "RootFS" => { "Layers" => ["drift"] } }
      unresolved
    end
  end

  def test_unknown_base_or_app_metadata_never_silently_selects_latest
    add("good")
    [nil, "unknown", "2026.11", 2026, "2026.11.0-dev"].each { |v| unresolved(base: base(v)) }
    unresolved(base: {})
    unresolved(base: base("2026.11.0-latest", "bad"))
    [nil, {}, "unknown", "2026.11.0-dev"].each do |v|
      profile = add("bad", version: v)
      unresolved(preferred: "bad")
      profile["app"] = { "version" => "2026.11.0-latest", "revision" => "not-a-commit" }
      save("bad", profile)
      unresolved(preferred: "bad")
    end
  end

  def test_dotted_historical_prerelease_versions_and_schema_alias
    profile = add("historical", version: "3.4.0.beta10", channel: "tests-passed")
    profile["selector"]["release"] = "3.4.0"
    profile["review_runtime"]["schema_version"] = SCHEMA
    save("historical", profile)
    result = @selector.select(base: base("3.4.0.beta9"))
    assert_equal "newer", result.dig("selection", "mode")
    assert_equal "tests-passed", result.dig("selection", "track")
    assert_equal SCHEMA, result.dig("selection", "schema_version")
  end

  def test_preferred_uses_the_host_prepared_profile
    add("a")
    add("b", status: "review_ready")
    assert_equal "b", @selector.select(preferred: "b")["name"]
    assert_equal "b", @selector.select(base: base, preferred: "b")["name"]
    unresolved(preferred: { "name" => "b" })
  end

  def test_preferred_new_core_below_hosted_plugin_schema_beats_unknown_baseline
    add("baseline")
    add("prepared", schema: "20261102000000", status: "review_ready")
    result = @selector.select(base: base("2026.11.0-latest", "20261103000000"), preferred: "prepared")
    assert_equal "prepared", result["name"]
    assert_equal "20261102000000", result.dig("selection", "schema_version")
    assert_equal "version_match", result.dig("selection", "mode")
  end

  def test_preferred_incompatible_profile_refuses_instead_of_falling_back
    add("compatible")
    add("older", version: "2026.10.0-latest")
    add("stable", version: "2026.11.0")
    add("newest", version: "2026.12.0-latest")
    unresolved(base: base, preferred: "older")
    unresolved(base: base, preferred: "stable")
    unresolved(preferred: "stable")
    assert_equal "older", @selector.select(preferred: "older")["name"]
    result = @selector.select(base: base, preferred: "newest")
    assert_equal "newest", result["name"]
    assert_equal "newer", result.dig("selection", "mode")
  end

  def test_malformed_inventory_and_app_objects_are_not_selectable
    [nil, [], "invalid", { "version" => [], "revision" => "b" * 40 }].each do |app|
      profile = add("bad")
      profile["app"] = app
      save("bad", profile)
      unresolved(preferred: "bad")
    end
    [nil, "invalid", ["bad"], [SCHEMA, 123]].each do |migrations|
      profile = add("bad")
      profile["review_runtime"]["core_migrations"] = migrations
      save("bad", profile)
      unresolved(preferred: "bad")
    end
  end

  def test_selector_must_agree_with_version_and_safe_evidence_is_allowlisted
    profile = add("bad", channel: "stable")
    unresolved(preferred: "bad")
    profile["selector"] = { "channel" => "latest", "release" => "2026.10.0" }
    save("bad", profile)
    unresolved(preferred: "bad")
    profile["selector"] = { "channel" => "latest", "stock_index_digest" => "sha256:" + "d" * 64 }
    profile["private_note"] = "do-not-copy"
    profile["review_runtime"]["core_comparison_complete"] = true
    profile["review_runtime"]["missing_known_core_migrations"] = [SCHEMA]
    save("bad", profile)
    result = @selector.select
    refute result.fetch("selection").key?("core_comparison_complete")
    refute result.fetch("selection").key?("missing_known_core_migrations")
    assert_equal "sha256:" + "d" * 64, result.dig("selection", "stock_digest")
    assert_equal profile.dig("images", "web", "ref"), result.dig("selection", "image_ref")
    assert_equal profile.dig("images", "web", "content_id"), result.dig("selection", "content_id")
    refute_includes JSON.generate(result["selection"]), "do-not-copy"
  end
  def test_hyphen_beta_request_matches_dotted_profile_exactly
    add("beta", version: "3.4.0.beta3", schema: SCHEMA)
    result = @selector.select(base: base("3.4.0-beta3"))
    assert_equal "matched", result.dig("selection", "mode")
    assert_equal "tests-passed", result.dig("selection", "track")
  end

  def test_base_site_compatibility_uses_canonical_prerelease_versions
    service = Object.new.extend(SiloMigrate::Services::StandardReviewRun)
    versions = service.send(:base_site_versions!, "synthetic-v3-4-0-beta3-#{SCHEMA}.sql.gz")
    assert_equal "3.4.0.beta3", versions.fetch("discourse_version")
    assert_nil service.send(:base_site_compatible!, versions, base("3.4.0.beta3"))
    rc = service.send(:base_site_versions!, "synthetic-v3-4-0-rc1-#{SCHEMA}.sql.gz")
    assert_nil service.send(:base_site_compatible!, rc, base("3.4.0.rc1"))
    assert_nil service.send(:base_site_compatible!, rc, base("3.4.0.rc2"))
    error = assert_raises(SiloMigrate::StandardWorkflowError) do
      service.send(:base_site_compatible!, base("3.4.0-rc2"), base("3.4.0.rc1"))
    end
    assert_equal "STANDARD_BASE_SITE_NEWER", error.code
  end

  def test_schema_only_legacy_backups_are_scannable_but_not_selectable
    service = Object.new.extend(SiloMigrate::Services::StandardReviewRun)
    legacy = service.send(:base_site_versions!, "legacy-v#{SCHEMA}.sql.gz")
    assert_nil legacy.fetch("discourse_version")
    add("latest")
    unresolved(base: legacy)
  end

end
