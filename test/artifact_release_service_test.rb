# frozen_string_literal: true

require_relative "test_helper"
require "digest"

class ArtifactReleaseServiceTest < SiloMigrateTest
  CLASSES = {
    "schema" => ["schema/initial/private-schema.sql", "sql", "CREATE TABLE synthetic (id integer);\n"],
    "log" => ["findings/redacted-logs/private-run.log", "log", "synthetic run completed\n"],
    "summary" => ["schema/initial/private-summary.json", "json", "{\"synthetic\":true}\n"],
    "finding" => ["findings/private-finding.yml", "yml", "message: synthetic\ndev_visibility: safe\n"],
    "fixture" => ["synthetic-fixtures/private-fixture.yml", "yml", "values: {}\n"]
  }.freeze

  def test_complete_release_flow_for_every_class_uses_only_opaque_names_and_clean_metadata
    with_release_project do |_env, project, safe, svc|
      candidates = CLASSES.map do |klass, (source, _extension, content)|
        write(File.join(project, source), content)
        candidate = svc.prepare("acme", source: source, artifact_class: klass)
        assert_safe_hash(candidate, project)
        assert_equal "candidate", candidate.fetch("state")
        assert_equal Digest::SHA256.hexdigest(content), candidate.fetch("sha256")
        assert_equal content.bytesize, candidate.fetch("bytes")
        assert_equal "candidate", svc.status("acme", id: candidate.fetch("id")).fetch("state")
        approved = approve(svc, candidate, notes: "private-review-note-sentinel")
        assert_equal "approved", approved.fetch("state")
        assert_safe_hash(approved, project)
        [klass, candidate]
      end

      result = svc.publish("acme")
      assert_safe_hash(result, project)
      candidates.each do |klass, candidate|
        _source, extension, content = CLASSES.fetch(klass)
        file = "artifacts/#{candidate.fetch('id')}.#{extension}"
        assert_equal content, File.binread(File.join(safe, file))
        entries = JSON.parse(File.read(File.join(safe, "manifest.json"))).fetch("artifacts")
        assert_includes entries, {
          "id" => candidate.fetch("id"), "sha256" => candidate.fetch("sha256"),
          "bytes" => candidate.fetch("bytes"), "file" => file, "class" => klass
        }
      end
      metadata = File.read(File.join(safe, "manifest.json"))
      instructions = %w[AGENTS.md CLAUDE.md allowed-commands.json].map do |name|
        File.read(File.join(safe, name))
      end.join("\n")
      [metadata, instructions, JSON.generate(result)].each do |text|
        ([project, "acme", "private-review-note-sentinel"] + CLASSES.values.map(&:first) + CLASSES.values.map { |source, _extension, _content| File.basename(source) }).each do |private_value|
          refute_includes text, private_value
        end
        refute_match(/"(?:reviewer|notes|source|customer)"\s*:/, text)
      end
      assert_equal candidates.map { |klass, record| "#{record.fetch('id')}.#{CLASSES.fetch(klass)[1]}" }.sort,
                   Dir.children(File.join(safe, "artifacts")).sort
    end
  end

  def test_approval_requires_explicit_review_and_exact_snapshot_attestation
    with_release_project do |_env, project, _safe, svc|
      candidate = prepare_summary(svc, project)
      attestation = { id: candidate.fetch("id"), sha256: candidate.fetch("sha256"), bytes: candidate.fetch("bytes"), reviewer: "engineer" }
      [{}, { reviewed: false }, { reviewed: "true" }, { reviewed: true, sha256: "0" * 64 },
       { reviewed: true, bytes: candidate.fetch("bytes") + 1 }].each do |changes|
        assert_release_error { svc.approve("acme", **attestation.merge(changes)) }
        assert_equal "candidate", svc.status("acme", id: candidate.fetch("id")).fetch("state")
      end
      assert_equal "approved", approve(svc, candidate).fetch("state")
    end
  end

  def test_labels_and_candidate_state_never_authorize_publication
    with_release_project do |_env, project, safe, svc|
      write(File.join(project, "findings", "safe.yml"), "dev_visibility: safe\nreviewed: true\napproved: true\n")
      candidate = svc.prepare("acme", source: "findings/safe.yml", artifact_class: "finding")
      svc.publish("acme")
      assert_no_artifacts(safe)
      assert_release_error { svc.publish("acme", ids: [candidate.fetch("id")]) }
      assert_no_artifacts(safe)
    end
  end

  def test_snapshot_is_independent_of_source_changes_and_deletion
    with_release_project do |_env, project, safe, svc|
      candidate = prepare_summary(svc, project)
      source = File.join(project, "schema/initial/summary.json")
      original = File.binread(source)
      File.write(source, "mutated-source-sentinel")
      approve(svc, candidate)
      File.unlink(source)
      svc.publish("acme")
      assert_equal original, File.binread(File.join(safe, "artifacts", "#{candidate.fetch('id')}.json"))
    end
  end

  def test_snapshot_tampering_refuses_publication_and_invalidates_existing_view
    with_release_project do |_env, project, safe, svc|
      candidate = prepare_summary(svc, project)
      approve(svc, candidate)
      svc.publish("acme")
      snapshot = File.join(project, ".silo-migrate/releases/snapshots", "#{candidate.fetch('id')}.bin")
      File.chmod(0o600, snapshot)
      File.binwrite(snapshot, "tampered-snapshot-sentinel")
      assert_release_error { svc.publish("acme") }
      refute File.exist?(File.join(safe, "manifest.json")), "failed publish left an old view current"
      refute File.exist?(File.join(safe, "artifacts", "#{candidate.fetch('id')}.json"))
    end
  end

  def test_tampered_missing_or_extra_view_files_block_status_and_require_explicit_republish
    with_release_project do |_env, project, safe, svc|
      candidate = prepare_summary(svc, project)
      approve(svc, candidate)
      filename = "artifacts/#{candidate.fetch('id')}.json"
      mutations = [
        -> { File.binwrite(File.join(safe, filename), "unreviewed-view-sentinel") },
        -> { File.unlink(File.join(safe, filename)) },
        -> { write(File.join(safe, "extra-private-file.json"), "synthetic extra file") },
        -> { File.binwrite(File.join(safe, "AGENTS.md"), "unreviewed instructions") },
        -> { File.unlink(File.join(safe, "CLAUDE.md")) },
        -> { File.binwrite(File.join(safe, "allowed-commands.json"), '{"commands":["unreviewed"]}') },
        -> { File.binwrite(File.join(safe, ".gitignore"), "unreviewed pattern\n") }
      ]
      mutations.each do |mutate|
        svc.publish("acme")
        mutate.call
        assert_release_error { svc.status("acme") }
        refute File.exist?(File.join(safe, "manifest.json"))
        blocked = svc.status("acme")
        assert_equal "blocked", blocked.fetch("state")
        assert_safe_hash(blocked, project)
        assert_equal "approved", svc.status("acme", id: candidate.fetch("id")).fetch("state")
        svc.publish("acme")
        assert_equal "published", svc.status("acme").fetch("state")
        assert_equal "{\"synthetic\":true}\n", File.binread(File.join(safe, filename))
      end
    end
  end

  def test_manifest_integrity_includes_safe_generation_and_controlled_artifact_paths
    with_release_project do |_env, project, safe, svc|
      candidate = prepare_summary(svc, project)
      approve(svc, candidate)
      mutations = [
        ->(manifest) { manifest["version"] = 2 },
        ->(manifest) { manifest["generation"] += 1 },
        ->(manifest) { manifest["artifacts"] = [] },
        ->(manifest) { manifest["private_extra_key"] = "synthetic sentinel" },
        ->(manifest) { manifest.fetch("artifacts").first["file"] = "../private-path.json" }
      ]
      mutations.each do |mutate|
        svc.publish("acme")
        path = File.join(safe, "manifest.json")
        manifest = JSON.parse(File.binread(path))
        assert_kind_of Integer, manifest.fetch("generation")
        mutate.call(manifest)
        File.binwrite(path, JSON.generate(manifest))
        # The first explicit publish must refuse a corrupt current view, not silently replace it.
        assert_release_error { svc.publish("acme") }
        refute File.exist?(path)
        assert_equal "blocked", svc.status("acme").fetch("state")
        svc.publish("acme")
        assert_equal "published", svc.status("acme").fetch("state")
      end
    end
  end

  def test_interrupted_publication_withdraws_existing_view_and_refuses_once
    with_release_project do |_env, project, safe, svc|
      candidate = prepare_summary(svc, project)
      approve(svc, candidate)
      svc.publish("acme")
      state_path = File.join(project, ".silo-migrate/releases/state.json")
      state = JSON.parse(File.binread(state_path))
      state["publication"] = "publishing"
      state["published_ids"] = []
      File.binwrite(state_path, JSON.generate(state))
      error = assert_release_error { svc.publish("acme") }
      assert_equal "RELEASE_INTERRUPTED", error.message
      refute File.exist?(File.join(safe, "manifest.json"))
      assert_equal "blocked", svc.status("acme").fetch("state")
      svc.publish("acme")
      assert_equal "published", svc.status("acme").fetch("state")
      assert File.file?(File.join(safe, "artifacts", "#{candidate.fetch('id')}.json"))
    end
  end

  def test_revocation_is_terminal_and_removes_the_whole_view
    with_release_project do |_env, project, safe, svc|
      first = prepare_summary(svc, project)
      second = prepare_summary(svc, project, source: "schema/initial/second.json")
      [first, second].each { |record| approve(svc, record) }
      svc.publish("acme")
      revoked = svc.revoke("acme", id: first.fetch("id"))
      assert_safe_hash(revoked, project)
      assert_equal "revoked", svc.status("acme", id: first.fetch("id")).fetch("state")
      refute File.exist?(File.join(safe, "manifest.json"))
      refute File.exist?(File.join(safe, "artifacts", "#{second.fetch('id')}.json"))
      assert_release_error { approve(svc, first) }
      assert_release_error { svc.publish("acme", ids: [first.fetch("id")]) }
      svc.publish("acme")
      refute File.exist?(File.join(safe, "artifacts", "#{first.fetch('id')}.json"))
      assert File.file?(File.join(safe, "artifacts", "#{second.fetch('id')}.json"))
    end
  end

  def test_explicit_selection_publishes_only_selected_approved_snapshots
    with_release_project do |_env, project, safe, svc|
      first = prepare_summary(svc, project)
      second = prepare_summary(svc, project, source: "schema/initial/second.json")
      [first, second].each { |record| approve(svc, record) }
      svc.publish("acme", ids: [second.fetch("id")])
      refute File.exist?(File.join(safe, "artifacts", "#{first.fetch('id')}.json"))
      assert File.file?(File.join(safe, "artifacts", "#{second.fetch('id')}.json"))
    end
  end

  def test_legacy_view_without_release_state_is_replaced_by_empty_unapproved_view
    with_release_project do |_env, project, safe, svc|
      write(File.join(safe, "manifest.json"), '{"customer":"legacy-private-name"}')
      stale = write(File.join(safe, "schema", "legacy.sql"), "legacy-private-sentinel")
      refute File.exist?(File.join(project, ".silo-migrate/releases/state.json"))
      svc.publish("acme")
      refute File.exist?(stale)
      manifest = JSON.parse(File.binread(File.join(safe, "manifest.json")))
      assert_equal 1, manifest.fetch("version")
      assert_kind_of Integer, manifest.fetch("generation")
      assert_empty manifest.fetch("artifacts")
      assert_no_artifacts(safe)
      refute_includes File.binread(File.join(safe, "manifest.json")), "legacy-private-name"
    end
  end

  def test_legacy_view_is_invalidated_even_when_explicit_publication_is_refused
    with_release_project do |_env, project, safe, svc|
      candidate = prepare_summary(svc, project)
      write(File.join(safe, "manifest.json"), '{"customer":"legacy-private-name"}')
      stale = write(File.join(safe, "schema", "legacy.sql"), "legacy-private-sentinel")
      assert_release_error { svc.publish("acme", ids: [candidate.fetch("id")]) }
      refute File.exist?(stale)
      refute File.exist?(File.join(safe, "manifest.json"))
    end
  end

  def test_source_confinement_and_class_validation
    with_release_project do |_env, project, _safe, svc|
      %w[dumps/raw.sql trusted/raw.yml output/raw.json converter-settings/raw.yml].each do |source|
        write(File.join(project, source), "synthetic disallowed source")
        assert_release_error { svc.prepare("acme", source: source, artifact_class: "summary") }
      end
      write(File.join(project, "schema/initial/summary.json"), "{}")
      ["../schema/initial/summary.json", "schema/../schema/initial/summary.json"].each do |source|
        assert_release_error { svc.prepare("acme", source: source, artifact_class: "summary") }
      end
      assert_release_error { svc.prepare("acme", source: "schema/initial", artifact_class: "summary") }
      ["unknown", "../summary", nil].each do |klass|
        assert_release_error { svc.prepare("acme", source: "schema/initial/summary.json", artifact_class: klass) }
      end
      assert_release_error { svc.prepare("acme", source: "schema/missing-private-sentinel.json", artifact_class: "summary") }
    end
  end

  def test_source_symlinks_hardlinks_and_symlinked_ancestors_are_rejected
    with_release_project do |_env, project, _safe, svc|
      original = write(File.join(project, "schema/initial/original.json"), "{}")
      File.symlink(original, File.join(project, "schema/initial/link.json"))
      File.link(original, File.join(project, "schema/initial/hardlink.json"))
      File.symlink(File.dirname(original), File.join(project, "schema/linked"))
      %w[schema/initial/link.json schema/initial/hardlink.json schema/initial/original.json schema/linked/original.json].each do |source|
        assert_release_error { svc.prepare("acme", source: source, artifact_class: "summary") }
      end
    end
  end

  def test_artifact_size_limit_and_private_permissions
    with_release_project do |_env, project, _safe, svc|
      candidate = prepare_summary(svc, project)
      releases = File.join(project, ".silo-migrate/releases")
      assert_equal 0o600, File.stat(File.join(releases, "state.json")).mode & 0o777
      assert_equal 0o400, File.stat(File.join(releases, "snapshots", "#{candidate.fetch('id')}.bin")).mode & 0o777
      %w[.silo-migrate/releases .silo-migrate/releases/snapshots].each do |relative|
        assert_equal 0, File.stat(File.join(project, relative)).mode & 0o077
      end
      oversized = write(File.join(project, "schema/initial/oversized.json"), "x" * (16 * 1024 * 1024 + 1))
      assert_release_error { svc.prepare("acme", source: oversized.delete_prefix("#{project}/"), artifact_class: "summary") }
    end
  end

  def test_total_publication_bytes_are_bounded
    with_release_project do |_env, project, safe, svc|
      # Five maximum-sized synthetic artifacts exceed the documented 64 MiB view bound.
      source = "schema/initial/large.sql"
      write(File.join(project, source), "x" * (16 * 1024 * 1024))
      candidates = 5.times.map { svc.prepare("acme", source: source, artifact_class: "schema") }
      candidates.each { |record| approve(svc, record) }
      svc.publish("acme", ids: [candidates.first.fetch("id")])
      assert_release_error { svc.publish("acme") }
      refute File.exist?(File.join(safe, "manifest.json"))
      assert_no_artifacts(safe)
    end
  end

  def test_record_count_is_bounded
    with_release_project do |_env, project, _safe, svc|
      source = "schema/initial/summary.json"
      write(File.join(project, source), "{}")
      128.times { svc.prepare("acme", source: source, artifact_class: "summary") }
      assert_release_error { svc.prepare("acme", source: source, artifact_class: "summary") }
    end
  end

  def test_private_approval_is_strictly_bound_to_record_and_workspace
    with_release_project do |_env, project, safe, svc|
      candidate = prepare_summary(svc, project)
      approve(svc, candidate)
      state_path = File.join(project, ".silo-migrate/releases/state.json")
      original = File.binread(state_path)
      [
        { "sha256" => "0" * 64 }, { "bytes" => candidate.fetch("bytes") + 1 },
        { "class" => "fixture" }, { "id" => "artifact-#{'0' * 32}" },
        { "workspace_id" => "workspace-#{'0' * 32}" }, { "reviewed" => false },
        { "unknown_private_key" => "synthetic sentinel" }
      ].each do |changes|
        File.binwrite(state_path, original)
        svc.publish("acme")
        state = JSON.parse(original)
        state.fetch("artifacts").fetch(candidate.fetch("id")).fetch("approval").merge!(changes)
        File.binwrite(state_path, JSON.generate(state))
        assert_release_error { svc.publish("acme") }
        refute File.exist?(File.join(safe, "manifest.json"))
      end
    end
  end

  def test_corrupt_and_unknown_private_state_fail_closed_without_parser_details
    with_release_project do |_env, project, safe, svc|
      candidate = prepare_summary(svc, project)
      approve(svc, candidate)
      state_path = File.join(project, ".silo-migrate/releases/state.json")
      valid = File.binread(state_path)
      ["private-parser-sentinel{", JSON.generate(JSON.parse(valid).merge("unknown_private_key" => "sentinel"))].each do |corrupt|
        File.binwrite(state_path, valid)
        svc.publish("acme")
        File.binwrite(state_path, corrupt)
        assert_release_error { svc.status("acme") }
        assert_release_error { svc.publish("acme") }
        refute File.exist?(File.join(safe, "manifest.json"))
      end
    end
  end

  def test_private_record_unknown_keys_and_invalid_class_id_or_state_are_rejected
    with_release_project do |_env, project, safe, svc|
      candidate = prepare_summary(svc, project)
      approve(svc, candidate)
      state_path = File.join(project, ".silo-migrate/releases/state.json")
      original = File.binread(state_path)
      [{ "unknown_private_key" => "sentinel" }, { "class" => "unsupported" },
       { "id" => "../private-id-sentinel" }, { "state" => "published-by-label" }].each do |changes|
        File.binwrite(state_path, original)
        svc.publish("acme")
        state = JSON.parse(original)
        record = state.fetch("artifacts").fetch(candidate.fetch("id"))
        record.merge!(changes)
        File.binwrite(state_path, JSON.generate(state))
        assert_release_error { svc.publish("acme") }
        refute File.exist?(File.join(safe, "manifest.json"))
      end
    end
  end

  def test_approval_cannot_be_replayed_in_another_workspace_or_root
    with_release_project do |env, project, _safe, svc|
      candidate = prepare_summary(svc, project)
      approve(svc, candidate)
      other = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).init("other")
      FileUtils.mkdir_p(File.join(other, "discourse-converters"))
      FileUtils.cp_r(File.join(project, ".silo-migrate/releases"), File.join(other, ".silo-migrate/releases"))
      assert_release_error { svc.publish("other") }
      assert_release_error { svc.approve("other", id: candidate.fetch("id"), sha256: candidate.fetch("sha256"), bytes: candidate.fetch("bytes"), reviewed: true, reviewer: "engineer") }
      relocated = File.join(File.dirname(project), "relocated-base")
      FileUtils.mkdir_p(relocated)
      FileUtils.cp_r(project, File.join(relocated, "acme"))
      relocated_service = SiloMigrate::Services::ArtifactReleaseService.new(env: env.merge("SILO_MIGRATE_BASE_PATH" => relocated), output: StringIO.new)
      assert_release_error { relocated_service.publish("acme") }
    end
  end

  private

  def with_release_project
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).init("acme")
      FileUtils.mkdir_p(File.join(project, "discourse-converters"))
      svc = SiloMigrate::Services::ArtifactReleaseService.new(env: env, output: StringIO.new)
      yield env, project, File.join(project, "discourse-converters/safe-artifacts"), svc
    end
  end

  def prepare_summary(svc, project, source: "schema/initial/summary.json")
    write(File.join(project, source), "{\"synthetic\":true}\n")
    svc.prepare("acme", source: source, artifact_class: "summary")
  end

  def approve(svc, record, notes: nil)
    svc.approve("acme", id: record.fetch("id"), sha256: record.fetch("sha256"), bytes: record.fetch("bytes"), reviewed: true, reviewer: "engineer", notes: notes)
  end

  def assert_release_error
    error = assert_raises(SiloMigrate::UsageError) { yield }
    assert_match(/\ARELEASE_[A-Z0-9_]+\z/, error.message)
    error
  end

  def assert_safe_hash(value, project)
    assert_kind_of Hash, value
    assert value.keys.all? { |key| key.is_a?(String) }
    refute_includes JSON.generate(value), project
    refute_match(/"(?:source|reviewer|notes|customer|clone_path|safe_artifacts_path)"\s*:/, JSON.generate(value))
  end

  def assert_no_artifacts(safe)
    assert_empty Dir.glob(File.join(safe, "artifacts", "**", "*")).select { |file| File.file?(file) }
  end
end
