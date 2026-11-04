# frozen_string_literal: true

require_relative "test_helper"

class ArtifactReleaseReviewTest < SiloMigrateTest
  def with_release
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      root = File.realpath(project.init("acme"))
      FileUtils.mkdir_p(File.join(root, "discourse-converters"))
      write(File.join(root, "schema/source.json"), "Reviewed synthetic bytes")
      svc = SiloMigrate::Services::ArtifactReleaseService.new(env: env, output: StringIO.new)
      yield root, env, svc
    end
  end

  def candidate(svc)
    svc.prepare("acme", source: "schema/source.json", artifact_class: "summary")
  end

  def approve(svc, record, **options)
    svc.approve("acme", id: record.fetch("id"), sha256: record.fetch("sha256"), bytes: record.fetch("bytes"), reviewed: true, reviewer: "engineer", **options)
  end

  def state_path(root)
    File.join(root, ".silo-migrate/releases/state.json")
  end

  def view(root)
    File.join(root, "discourse-converters/safe-artifacts")
  end

  def test_revocation_is_durable_before_tampered_or_interrupted_view_checks
    %w[tampered interrupted].each do |condition|
      with_release do |root, _env, svc|
        record = candidate(svc)
        approve(svc, record)
        svc.publish("acme")
        if condition == "tampered"
          File.binwrite(File.join(view(root), "manifest.json"), "private-corrupt-sentinel")
        else
          data = JSON.parse(File.read(state_path(root)))
          data["publication"] = "publishing"
          File.binwrite(state_path(root), JSON.generate(data))
        end
        assert_equal "revoked", svc.revoke("acme", id: record.fetch("id")).fetch("state")
        refute File.exist?(view(root))
        assert_empty svc.publish("acme").fetch("artifacts")
        assert_equal "revoked", svc.status("acme", id: record.fetch("id")).fetch("state")
      end
    end
  end

  def test_status_alone_withdraws_legacy_absent_and_blocked_views
    with_release do |root, _env, svc|
      2.times do
        write(File.join(view(root), "legacy-private.json"), "private-sentinel")
        assert_equal "blocked", svc.status("acme").fetch("state")
        refute File.exist?(view(root))
      end
      assert_equal "candidate", candidate(svc).fetch("state")
      write(File.join(view(root), "legacy-private.json"), "private-sentinel")
      candidate(svc)
      refute File.exist?(view(root))
    end
  end

  def test_blocked_state_is_saved_even_when_view_withdrawal_cannot_succeed
    with_release do |root, _env, svc|
      record = candidate(svc)
      approve(svc, record)
      svc.publish("acme")
      FileUtils.remove_entry_secure(view(root))
      outside = File.join(File.dirname(root), "private-outside")
      write(File.join(outside, "sentinel.txt"), "private-sentinel")
      File.symlink(outside, view(root))
      error = assert_raises(SiloMigrate::UsageError) { svc.status("acme") }
      assert_equal "RELEASE_VIEW_BLOCKED", error.message
      assert_equal "blocked", JSON.parse(File.read(state_path(root))).fetch("publication")
      error = assert_raises(SiloMigrate::UsageError) { svc.revoke("acme", id: record.fetch("id")) }
      assert_equal "RELEASE_VIEW_BLOCKED", error.message
      assert_equal "revoked", JSON.parse(File.read(state_path(root))).dig("artifacts", record.fetch("id"), "state")
      assert_equal "private-sentinel", File.read(File.join(outside, "sentinel.txt"))
      File.unlink(view(root))
      assert_empty svc.publish("acme").fetch("artifacts")
    end
  end

  def test_combined_storage_and_withdrawal_failure_reports_both_unknowns
    with_release do |root, env, svc|
      record = candidate(svc)
      approve(svc, record)
      svc.publish("acme")
      File.binwrite(File.join(view(root), "manifest.json"), "private-corrupt-sentinel")
      store = SiloMigrate::ReleaseStore.new("acme", env: env)
      save = store.method(:save)
      store.define_singleton_method(:save) do |data|
        raise IOError, "private-save-sentinel" if data["publication"] == "blocked"

        save.call(data)
      end
      rename = File.method(:rename)
      failure = lambda do |source, target|
        raise Errno::EPERM, "private-withdraw-sentinel" if source == view(root)

        rename.call(source, target)
      end
      SiloMigrate::ReleaseStore.stub(:new, store) do
        File.stub(:rename, failure) do
          error = assert_raises(SiloMigrate::UsageError) { svc.status("acme") }
          assert_equal "RELEASE_STATE_AND_VIEW_BLOCKED", error.message
          assert_nil error.cause
        end
      end
      assert File.exist?(view(root)), "failed cleanup must not be claimed successful"
      assert_equal "revoked", svc.revoke("acme", id: record.fetch("id")).fetch("state")
      refute File.exist?(view(root))
    end
  end

  def test_input_errors_do_not_withdraw_healthy_approved_context
    with_release do |root, _env, svc|
      record = candidate(svc)
      approve(svc, record)
      pending = candidate(svc)
      svc.publish("acme")
      before = File.binread(File.join(view(root), "manifest.json"))
      unknown = "artifact-#{'0' * 32}"
      [
        -> { svc.status("acme", id: "private-typo") },
        -> { svc.revoke("acme", id: unknown) },
        -> { svc.prepare("acme", source: "schema/source.json", artifact_class: "bad") },
        -> { svc.prepare("acme", source: "../bad", artifact_class: "summary") },
        -> { svc.approve("acme", id: pending.fetch("id"), sha256: "0" * 64, bytes: pending.fetch("bytes"), reviewed: true, reviewer: "engineer") }
      ].each do |operation|
        assert_raises(SiloMigrate::UsageError, &operation)
        assert_equal before, File.binread(File.join(view(root), "manifest.json"))
        assert_equal "published", svc.status("acme").fetch("state")
      end
    end
  end

  def test_failed_prepare_and_approval_saves_do_not_commit_the_working_copy
    %w[prepare approve approve_after_write].each do |operation|
      with_release do |root, env, svc|
        record = candidate(svc) unless operation == "prepare"
        store = SiloMigrate::ReleaseStore.new("acme", env: env)
        save = store.method(:save)
        failed = false
        store.define_singleton_method(:save) do |data|
          changed = if operation == "prepare"
            !data.fetch("artifacts").empty?
          else
            data.fetch("artifacts").values.any? { |entry| entry["state"] == "approved" }
          end
          if changed && !failed
            failed = true
            save.call(data) if operation == "approve_after_write"
            raise IOError, "private-save-sentinel"
          end
          save.call(data)
        end
        SiloMigrate::ReleaseStore.stub(:new, store) do
          error = assert_raises(SiloMigrate::UsageError) do
            operation == "prepare" ? candidate(svc) : approve(svc, record)
          end
          assert_equal "RELEASE_OPERATION_FAILED", error.message
          assert_nil error.cause
        end
        assert failed
        persisted = JSON.parse(File.read(state_path(root)))
        assert_equal "blocked", persisted.fetch("publication")
        if operation == "prepare"
          assert_empty persisted.fetch("artifacts")
        else
          assert_equal "candidate", persisted.dig("artifacts", record.fetch("id"), "state")
          assert_nil persisted.dig("artifacts", record.fetch("id"), "approval")
        end
        assert_empty svc.publish("acme").fetch("artifacts")
      end
    end
  end

  def test_large_valid_state_remains_readable_and_serialized_limit_precedes_writes
    with_release do |root, env, svc|
      45.times do
        approve(svc, candidate(svc), notes: "\u0001" * 4096)
      end
      assert_operator File.size(state_path(root)), :>, 1024 * 1024
      assert_equal 45, svc.status("acme").fetch("artifacts").length
      store = SiloMigrate::ReleaseStore.new("acme", env: env)
      before = File.binread(state_path(root))
      store.with_lock do
        data = store.load
        JSON.stub(:pretty_generate, "x" * (SiloMigrate::ReleaseStore::MAX_STATE_BYTES + 1)) do
          error = assert_raises(SiloMigrate::UsageError) { store.save(data) }
          assert_equal "RELEASE_SIZE_LIMIT", error.message
        end
      end
      assert_equal before, File.binread(state_path(root))
    end
  end

  def test_extra_files_are_detected_when_configured_base_contains_glob_metacharacters
    with_tmp_base do |dir, env|
      env["SILO_MIGRATE_BASE_PATH"] = File.join(dir, "customers[synthetic]")
      root = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).init("acme")
      FileUtils.mkdir_p(File.join(root, "discourse-converters"))
      write(File.join(root, "schema/source.json"), "Reviewed")
      svc = SiloMigrate::Services::ArtifactReleaseService.new(env: env, output: StringIO.new)
      approve(svc, candidate(svc))
      svc.publish("acme")
      write(File.join(view(root), "unapproved.txt"), "private-sentinel")
      assert_raises(SiloMigrate::UsageError) { svc.status("acme") }
      refute File.exist?(view(root))
      assert_equal "blocked", svc.status("acme").fetch("state")
    end
  end

  def test_private_orphan_views_and_tempfiles_are_swept_without_deleting_snapshots
    with_release do |root, _env, svc|
      record = candidate(svc)
      base = File.join(root, ".silo-migrate/releases")
      orphans = [
        write(File.join(base, "view-#{'a' * 32}", "artifact.txt"), "orphan"),
        write(File.join(base, "retired-#{'b' * 32}", "artifact.txt"), "orphan"),
        write(File.join(base, ".release-orphan.tmp"), "orphan"),
        write(File.join(base, "snapshots/.release-orphan.tmp"), "orphan")
      ]
      svc.status("acme")
      orphans.each { |file| refute File.exist?(file) }
      assert File.exist?(File.join(base, "snapshots", "#{record.fetch('id')}.bin"))
    end
  end

  def test_history_archiving_cannot_move_a_generated_view_outside_revocation
    with_release do |root, env, svc|
      record = candidate(svc)
      approve(svc, record)
      svc.publish("acme")
      write(File.join(root, "schema/initial/schema.sql"), "Synthetic private schema")
      workflow = {
        "phases" => { "initial" => { "generation" => 1 } },
        "converter" => { "output_lineage" => { "phase" => "initial", "generation" => 1 }, "output_db" => "output/intermediate.db" }
      }
      archive = SiloMigrate::Services::HistoryService.new(env: env, output: StringIO.new).archive_for_phase("acme", "initial", state: workflow)
      assert File.directory?(view(root))
      refute_includes JSON.parse(File.read(File.join(archive, "manifest.json"))).fetch("moved"), "discourse-converters/safe-artifacts"
      assert_equal "revoked", svc.revoke("acme", id: record.fetch("id")).fetch("state")
      refute File.exist?(view(root))
      assert_empty Dir.glob("**/safe-artifacts", base: archive)
    end
  end
end
