# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class ArtifactReleaseFailureTest < SiloMigrateTest
  def with_release
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      root = File.realpath(project.init("acme"))
      FileUtils.mkdir_p(File.join(root, "discourse-converters"))
      write(File.join(root, "schema", "source.txt"), "Reviewed synthetic bytes")
      out = StringIO.new
      service = SiloMigrate::Services::ArtifactReleaseService.new(env: env, output: out)
      yield root, env, service, out
    end
  end

  def approved(service)
    record = service.prepare("acme", source: "schema/source.txt", artifact_class: "schema")
    service.approve("acme", id: record.fetch("id"), sha256: record.fetch("sha256"), bytes: record.fetch("bytes"), reviewed: true, reviewer: "engineer")
    record
  end

  def state(root)
    JSON.parse(File.read(File.join(root, ".silo-migrate", "releases", "state.json")))
  end

  def test_snapshot_io_failures_leave_no_partial_or_registered_snapshot
    %i[write flush fsync close].each do |operation|
      with_release do |root, _env, service, out|
        create = Tempfile.method(:create)
        exercised = false
        injected = lambda do |*args|
          file = create.call(*args)
          if File.dirname(file.path).end_with?("/snapshots")
            exercised = true
            original = file.method(operation)
            failed = false
            file.define_singleton_method(operation) do |*values|
              return original.call(*values) if failed

              failed = true
              if operation == :write
                original.call(values.fetch(0).byteslice(0, 4))
                flush
              end
              raise IOError, "private-sentinel"
            end
          end
          file
        end
        Tempfile.stub(:create, injected) do
          error = assert_raises(SiloMigrate::UsageError) { service.prepare("acme", source: "schema/source.txt", artifact_class: "schema") }
          refute_includes error.message, "private-sentinel"
          assert_nil error.cause
        end
        assert exercised
        assert_empty state(root).fetch("artifacts")
        assert_empty Dir[File.join(root, ".silo-migrate", "releases", "**", ".release-*")]
        assert_empty Dir[File.join(root, ".silo-migrate", "releases", "snapshots", "*.bin")]
        assert_empty out.string
      end
    end
  end

  def test_publication_rename_failure_withdraws_old_view_and_marks_blocked
    with_release do |root, _env, service, _out|
      approved(service)
      service.publish("acme")
      before_generation = state(root).fetch("generation")
      rename = File.method(:rename)
      injected = lambda do |source, target|
        raise Errno::EIO, "private-sentinel" if target.end_with?("/safe-artifacts")

        rename.call(source, target)
      end
      File.stub(:rename, injected) do
        error = assert_raises(SiloMigrate::UsageError) { service.publish("acme") }
        refute_includes error.message, "private-sentinel"
      end
      refute File.exist?(File.join(root, "discourse-converters", "safe-artifacts"))
      assert_equal "blocked", state(root).fetch("publication")
      assert_operator state(root).fetch("generation"), :>, before_generation
      assert_empty Dir[File.join(root, ".silo-migrate", "releases", "view-*")]
      assert_equal "published", service.publish("acme").fetch("state")
    end
  end

  def test_revocation_cleanup_failure_is_not_reported_as_success_and_stays_revoked
    with_release do |root, _env, service, out|
      record = approved(service)
      service.publish("acme")
      out.truncate(0)
      out.rewind
      rename = File.method(:rename)
      injected = lambda do |source, target|
        raise Errno::EPERM, "private-sentinel" if source.end_with?("/safe-artifacts")

        rename.call(source, target)
      end
      File.stub(:rename, injected) do
        error = assert_raises(SiloMigrate::UsageError) { service.revoke("acme", id: record.fetch("id")) }
        assert_equal "RELEASE_VIEW_BLOCKED", error.message
        assert_nil error.cause
      end
      assert_equal "revoked", state(root).dig("artifacts", record.fetch("id"), "state")
      assert_equal "blocked", state(root).fetch("publication")
      assert_empty out.string
      assert_empty service.publish("acme").fetch("artifacts")
      refute File.exist?(File.join(root, "discourse-converters", "safe-artifacts", "artifacts", "#{record.fetch('id')}.sql"))
    end
  end

  def test_interrupted_publication_refuses_once_and_removes_the_untrusted_view
    with_release do |root, env, service, _out|
      approved(service)
      service.publish("acme")
      store = SiloMigrate::ReleaseStore.new("acme", env: env)
      store.with_lock do
        data = store.load
        data["publication"] = "publishing"
        store.save(data)
      end
      error = assert_raises(SiloMigrate::UsageError) { service.status("acme") }
      assert_equal "RELEASE_INTERRUPTED", error.message
      refute File.exist?(File.join(root, "discourse-converters", "safe-artifacts"))
      assert_equal "blocked", service.status("acme").fetch("state")
    end
  end

  def test_publication_and_revocation_are_serialized_by_the_same_private_lock
    with_release do |root, _env, service, _out|
      record = approved(service)
      reached = Queue.new
      proceed = Queue.new
      started = Queue.new
      rename = File.method(:rename)
      injected = lambda do |source, target|
        if target.end_with?("/safe-artifacts")
          reached << true
          Timeout.timeout(5) { proceed.pop }
        end
        rename.call(source, target)
      end
      publisher = nil
      revoker = nil
      begin
        File.stub(:rename, injected) do
          publisher = Thread.new { service.publish("acme") }
          Timeout.timeout(5) { reached.pop }
          revoker = Thread.new do
            started << true
            service.revoke("acme", id: record.fetch("id"))
          end
          Timeout.timeout(5) { started.pop }
          Timeout.timeout(5) { Thread.pass until revoker.backtrace&.any? { |frame| frame.include?("flock") } }
          assert revoker.alive?, "revoker must actually wait on the held publication lock"
          assert_equal "publishing", state(root).fetch("publication")
          assert_equal "approved", state(root).dig("artifacts", record.fetch("id"), "state")
          proceed << true
          Timeout.timeout(5) { publisher.value; revoker.value }
        end
      ensure
        proceed << true
        publisher&.join(6)
        revoker&.join(6)
      end
      assert_equal "revoked", state(root).dig("artifacts", record.fetch("id"), "state")
      refute File.exist?(File.join(root, "discourse-converters", "safe-artifacts"))
    end
  end
end
