# frozen_string_literal: true

require_relative "test_helper"

class TrustedWorkflowServiceTest < SiloMigrateTest
  def test_trusted_inspection_writes_raw_artifact_and_audit_without_printing_output
    with_tmp_base do |_dir, env|
      env["SILO_MIGRATE_ACTOR"] = "reviewer@example.test"
      runtime = SiloMigrate::Runtime::Fake.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      project.init("acme")
      out = StringIO.new

      artifacts = SiloMigrate::Services::TrustedWorkflowService.new(runtime: runtime, env: env, output: out).inspect(
        "acme",
        phase: "initial",
        reason: "Check one source value shape",
        command: %w[echo customer@example.test],
        timestamp: Time.utc(2026, 6, 1, 13, 0, 0)
      )

      inspection = JSON.parse(File.read(artifacts.fetch(:inspection_path)))
      audit = JSON.parse(File.read(artifacts.fetch(:audit_path)))
      assert_equal "trusted_only", inspection.fetch("dev_visibility")
      assert_equal true, inspection.fetch("contains_raw_rows")
      assert_equal %w[echo customer@example.test], inspection.fetch("command")
      assert_equal "trusted_inspect", audit.fetch("event")
      assert_equal "trusted/inspections/inspection-20260601-130000.json", audit.dig("details", "artifact")
      refute_includes out.string, "customer@example.test"
    end
  end

  def test_review_writes_safe_derivative_for_restricted_finding_and_audit
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      project_path = File.realpath(project.project_path("acme"))
      finding_path = write(File.join(project_path, "findings", "finding-20260601-120000-001.yml"), restricted_finding.to_yaml)

      artifacts = SiloMigrate::Services::TrustedWorkflowService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).review(
        "acme",
        finding_path,
        reviewer: "human",
        notes: "Schema-only taxonomy reviewed",
        released_message: "Synthetic taxonomy reviewed",
        timestamp: Time.utc(2026, 6, 1, 13, 5, 0)
      )

      reviewed = YAML.safe_load(File.read(artifacts.fetch(:reviewed_path)))
      audit = JSON.parse(File.read(artifacts.fetch(:audit_path)))
      assert_match(/\Afinding-[0-9a-f]{32}-reviewed\z/, reviewed.fetch("id"))
      assert_equal "safe", reviewed.fetch("dev_visibility")
      refute reviewed.key?("source_trusted_finding_id")
      assert_equal "finding-20260601-120000-001", audit.dig("details", "source_finding_id")
      assert_equal false, reviewed.dig("review", "redacted")
      assert_equal "trusted_review", audit.fetch("event")
      assert_equal "safe", audit.dig("details", "decision")
    end
  end

  def test_redact_writes_safe_derivative_for_trusted_only_finding
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      project_path = File.realpath(project.project_path("acme"))
      finding_path = write(File.join(project_path, "trusted", "findings", "finding-20260601-120000-001.yml"), trusted_finding.to_yaml)

      artifacts = SiloMigrate::Services::TrustedWorkflowService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).redact(
        "acme",
        finding_path,
        reviewer: "human",
        notes: "Removed raw message",
        released_message: "Synthetic encoding issue confirmed",
        timestamp: Time.utc(2026, 6, 1, 13, 10, 0)
      )

      reviewed = YAML.safe_load(File.read(artifacts.fetch(:reviewed_path)))
      audit = JSON.parse(File.read(artifacts.fetch(:audit_path)))
      assert_equal "safe", reviewed.fetch("dev_visibility")
      assert_equal "Synthetic encoding issue confirmed", reviewed.fetch("message")
      assert_nil reviewed.fetch("exception_class")
      assert_equal true, reviewed.dig("review", "redacted")
      assert_equal "trusted_redact", audit.fetch("event")
    end
  end

  def test_review_rejects_trusted_only_finding_without_redaction
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      finding_path = write(File.join(project.project_path("acme"), "trusted", "findings", "finding-20260601-120000-001.yml"), trusted_finding.to_yaml)

      error = assert_raises(SiloMigrate::UsageError) do
        SiloMigrate::Services::TrustedWorkflowService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).review("acme", finding_path)
      end

      assert_includes error.message, "trusted_only findings require"
    end
  end

  def test_trusted_session_rejects_non_linux_host
    with_tmp_base do |_dir, env|
      env["SILO_MIGRATE_FORCE_NON_LINUX"] = "1"
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")

      error = assert_raises(SiloMigrate::UsageError) do
        SiloMigrate::Services::TrustedWorkflowService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).session(
          "acme",
          reason: "Need raw edge-case inspection"
        )
      end

      assert_includes error.message, "Linux/Silo host"
      assert_includes error.message, "ai prepare"
    end
  end

  def test_trusted_session_generates_silo_config_audit_and_commands
    with_tmp_base do |_dir, env|
      env["SILO_MIGRATE_FORCE_LINUX"] = "1"
      runtime = SiloMigrate::Runtime::Fake.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      project.init("acme")
      project_path = File.realpath(project.project_path("acme"))

      artifacts = SiloMigrate::Services::TrustedWorkflowService.new(runtime: runtime, env: env, output: StringIO.new).session(
        "acme",
        provider: "bedrock",
        runtime: "silo",
        reason: "Need raw edge-case inspection",
        session_id: "case-123",
        timestamp: Time.utc(2026, 6, 1, 14, 0, 0)
      )

      config = YAML.safe_load(File.read(artifacts.fetch(:config_path)))
      audit = JSON.parse(File.read(artifacts.fetch(:audit_path)))
      assert_equal "trusted-data-ai", config.fetch("kind")
      assert_equal ["trusted redact", "release prepare", "engineer reviews exact snapshot", "release approve", "release publish"], config.fetch("safe_handoff")
      assert_equal "bedrock", config.fetch("provider")
      assert_equal "claude", config.dig("agent", "name")
      assert_equal "bedrock", config.dig("agent", "mode")
      assert_equal true, config.dig("snapshots", "before_agent_launch")
      assert_equal project_path, config.fetch("mounts").first.fetch("source")
      assert_equal "raw_customer_project", config.fetch("mounts").first.fetch("classification")
      assert_equal "trusted_only", config.fetch("dev_visibility")
      assert_equal "trusted_session", audit.fetch("event")
      assert_equal "case-123", audit.dig("details", "session_id")
      assert_equal "before_agent_launch", audit.dig("details", "snapshot")

      snapshot_command = runtime.commands.find { |entry| entry[0] == :run && entry[1][0, 3] == %w[silo snapshot create] }
      launch_command = runtime.commands.find { |entry| entry[0] == :run && entry[1] == ["silo", "agent", "claude", "--config", artifacts.fetch(:config_path)] }
      refute_nil snapshot_command
      refute_nil launch_command
    end
  end

  def test_inspect_as_finding_writes_stub_without_raw_payload
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      project.init("acme")

      artifacts = SiloMigrate::Services::TrustedWorkflowService.new(runtime: runtime, env: env, output: StringIO.new).inspect(
        "acme",
        phase: "initial",
        reason: "Verify malformed user rows",
        message: "Some users rows have malformed encoding",
        command: ["echo", "raw-value-sentinel SELECT * FROM users WHERE email='real@customer.test'"],
        as_finding: true,
        timestamp: Time.utc(2026, 6, 1, 13, 0, 0)
      )

      finding_path = artifacts.fetch(:finding_path)
      assert_includes finding_path, File.join("trusted", "findings", "finding-inspect-20260601-130000.yml")
      content = File.read(finding_path)
      refute_includes content, "raw-value-sentinel"
      refute_includes content, "real@customer.test"

      finding = YAML.safe_load(content)
      assert_equal "trusted_only", finding.fetch("dev_visibility")
      assert_equal "trusted_inspection", finding.fetch("failure")
      assert_equal "Some users rows have malformed encoding", finding.fetch("message")
      assert_includes finding.fetch("source"), "trusted/inspections/inspection-20260601-130000.json"

      audit = JSON.parse(File.read(artifacts.fetch(:audit_path)))
      assert_includes audit.dig("details", "finding"), "finding-inspect-20260601-130000.yml"
    end
  end

  def test_redacting_inspection_finding_yields_safe_derivative_without_payload_keys
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      project.init("acme")
      project_path = File.realpath(project.project_path("acme"))
      service = SiloMigrate::Services::TrustedWorkflowService.new(runtime: runtime, env: env, output: StringIO.new)

      inspect_artifacts = service.inspect(
        "acme",
        reason: "Check rows",
        command: %w[echo raw-value-sentinel],
        as_finding: true,
        timestamp: Time.utc(2026, 6, 1, 13, 0, 0)
      )
      # Even if someone enriches a trusted finding with raw payload keys by
      # hand, the safe derivative must drop them.
      enriched = YAML.safe_load(File.read(inspect_artifacts.fetch(:finding_path)))
      enriched["stdout"] = "raw-value-sentinel"
      enriched["command"] = ["echo", "raw-value-sentinel"]
      write(inspect_artifacts.fetch(:finding_path), enriched.to_yaml)

      redacted = service.redact(
        "acme",
        inspect_artifacts.fetch(:finding_path),
        reviewer: "human",
        notes: "Encoding issue confirmed; converter must scrub utf8mb3 remnants",
        released_message: "Synthetic encoding issue confirmed",
        timestamp: Time.utc(2026, 6, 1, 13, 10, 0)
      )

      derivative_path = redacted.fetch(:reviewed_path)
      assert File.exist?(derivative_path)
      content = File.read(derivative_path)
      refute_includes content, "raw-value-sentinel"

      derivative = YAML.safe_load(content, permitted_classes: [Time])
      assert_equal "safe", derivative.fetch("dev_visibility")
      assert_equal "Synthetic encoding issue confirmed", derivative.fetch("message")
      refute derivative.key?("stdout")
      refute derivative.key?("command")

      # The safe derivative lands in findings/ and is picked up by safe-artifacts.
      assert_equal File.join(project_path, "findings"), File.dirname(derivative_path)
    end
  end

  def test_derivative_is_an_explicit_projection_and_notes_and_metadata_stay_private
    with_review_workspace do |root, _env, service, out|
      sentinel = "private-payload-sentinel"
      finding = trusted_finding.merge(
        "id" => "finding-#{sentinel}",
        "source" => sentinel,
        "phase" => sentinel,
        "failure" => sentinel,
        "severity" => sentinel,
        "message" => sentinel,
        "exception_class" => sentinel,
        "observed_shape" => { "keys" => [sentinel], "value_types" => { sentinel => "string" } },
        "unknown" => { "nested" => [sentinel] },
        "review" => { "notes" => sentinel },
        "contains_raw_rows" => true
      )
      path = write(File.join(root, "trusted", "findings", "finding-private.yml"), finding.to_yaml)
      result = service.redact("acme", path, reviewer: sentinel, notes: sentinel, released_message: "Reviewed synthetic reproduction")
      content = File.read(result.fetch(:reviewed_path))
      refute_includes content, sentinel
      refute_includes out.string, sentinel
      derivative = YAML.safe_load(content)
      assert_equal %w[artifact_version contains_raw_rows dev_visibility exception_class failure generated_at id message observed_shape recommended_next_step review severity source], derivative.keys.sort
      assert_nil derivative.fetch("observed_shape")
      assert_equal %w[redacted reviewed_at], derivative.fetch("review").keys.sort
      audit = JSON.parse(File.read(result.fetch(:audit_path)))
      assert_equal sentinel, audit.dig("details", "reviewer")
      assert_equal sentinel, audit.dig("details", "notes")
      assert_equal finding.fetch("id"), audit.dig("details", "source_finding_id")
      assert_equal 0o600, File.stat(result.fetch(:audit_path)).mode & 0o777
      assert_equal 0o600, File.stat(result.fetch(:reviewed_path)).mode & 0o777
    end
  end

  def test_safe_review_also_drops_source_free_text_and_shape
    with_review_workspace do |root, _env, service, _out|
      path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.to_yaml)
      result = service.review("acme", path, released_message: "Explicitly released summary")
      content = File.read(result.fetch(:reviewed_path))
      refute_includes content, "Restricted taxonomy label"
      assert_nil YAML.safe_load(content).fetch("observed_shape")
    end
  end

  def test_safe_decisions_require_explicit_release_text_not_private_notes
    with_review_workspace do |root, _env, service, out|
      path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.to_yaml)
      [nil, "", "  ", { "nested" => "private-sentinel" }, "x" * 4097, "private-sentinel\0", "\xFF".b.force_encoding("UTF-8"), "--notes"].each do |message|
        error = assert_raises(SiloMigrate::UsageError) do
          service.review("acme", path, notes: "private-sentinel", released_message: message)
        end
        assert_includes error.message, "--released-message"
        refute_includes error.message, "private-sentinel"
      end
      assert_empty Dir[File.join(root, "trusted", "audit", "*.json")]
      assert_equal [path], Dir[File.join(root, "findings", "*.yml")]
      assert_empty out.string
    end
  end

  def test_rejection_needs_no_release_text_and_writes_only_private_audit
    with_review_workspace do |root, _env, service, _out|
      path = write(File.join(root, "trusted", "findings", "finding-private.yml"), trusted_finding.to_yaml)
      result = service.review("acme", path, decision: "reject", notes: "private-sentinel")
      assert_nil result.fetch(:reviewed_path)
      assert_equal "reject", JSON.parse(File.read(result.fetch(:audit_path))).dig("details", "decision")
      assert_empty Dir[File.join(root, "findings", "*.yml")]
    end
  end

  def test_relative_finding_paths_are_workspace_relative
    with_review_workspace do |root, _env, service, _out|
      write(File.join(root, "trusted", "findings", "finding-private.yml"), trusted_finding.to_yaml)
      result = service.redact("acme", "trusted/findings/finding-private.yml", released_message: "Reviewed summary")
      assert_equal File.join(root, "findings"), File.dirname(result.fetch(:reviewed_path))
    end
  end

  def test_invalid_identifiers_and_visibility_are_rejected_without_echoing_values
    with_review_workspace do |root, _env, service, out|
      invalid = [nil, 1, [], "../../private-sentinel", "finding-private-sentinel.yml", "finding-" + "x" * 129]
      invalid.each do |id|
        path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.merge("id" => id).to_yaml)
        error = assert_raises(SiloMigrate::UsageError) { service.review("acme", path, released_message: "Reviewed") }
        assert_equal "Invalid finding identifier.", error.message
      end
      [nil, "private-sentinel", { "secret" => "private-sentinel" }].each do |visibility|
        path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.merge("dev_visibility" => visibility).to_yaml)
        error = assert_raises(SiloMigrate::UsageError) { service.review("acme", path, released_message: "Reviewed") }
        assert_equal "Invalid finding visibility.", error.message
      end
      assert_empty Dir[File.join(root, "trusted", "audit", "*.json")]
      assert_empty out.string
    end
  end

  def test_external_cross_workspace_and_traversal_paths_are_rejected
    with_review_workspace do |root, _env, service, _out|
      paths = [
        File.join(File.dirname(root), "other", "findings", "private-sentinel.yml"),
        File.join(root, "findings-extra", "private-sentinel.yml"),
        File.join(root, "shared", "private-sentinel.yml")
      ]
      paths.each do |path|
        write(path, trusted_finding.to_yaml)
        before = File.read(path)
        error = assert_raises(SiloMigrate::UsageError) { service.redact("acme", path, released_message: "Reviewed") }
        refute_includes error.message, "private-sentinel"
        assert_equal before, File.read(path)
      end
      assert_raises(SiloMigrate::UsageError) { service.redact("acme", "../other/findings/private-sentinel.yml", released_message: "Reviewed") }
      assert_empty Dir[File.join(root, "trusted", "audit", "*.json")]
    end
  end

  def test_symlinked_finding_file_and_ancestor_are_rejected
    with_review_workspace do |root, _env, service, _out|
      source = write(File.join(root, "shared", "private-sentinel.yml"), trusted_finding.to_yaml)
      FileUtils.mkdir_p(File.join(root, "findings"))
      link = File.join(root, "findings", "finding-link.yml")
      File.symlink(source, link)
      error = assert_raises(SiloMigrate::UsageError) { service.redact("acme", link, released_message: "Reviewed") }
      refute_includes error.message, "private-sentinel"
      File.symlink(File.dirname(source), File.join(root, "findings", "linked"))
      assert_raises(SiloMigrate::UsageError) { service.redact("acme", "findings/linked/private-sentinel.yml", released_message: "Reviewed") }
      assert_empty Dir[File.join(root, "trusted", "audit", "*.json")]
    end
  end

  def test_symlinked_output_and_audit_directories_are_rejected_without_publication
    ["findings", "trusted", "trusted/audit"].each do |relative|
      with_review_workspace do |root, _env, service, _out|
        source_relative = relative == "findings" ? "trusted/findings/finding-private.yml" : "findings/finding-private.yml"
        source = write(File.join(root, source_relative), trusted_finding.to_yaml)
        outside = File.join(File.dirname(root), "private-sentinel")
        FileUtils.mkdir_p(outside)
        target = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(target))
        File.symlink(outside, target)
        assert_raises(SiloMigrate::UsageError) { service.redact("acme", source, released_message: "Reviewed") }
        assert_empty Dir.children(outside)
        assert_empty Dir[File.join(root, "findings", "finding-*-redacted.yml")]
      end
    end
  end

  def test_hardlinked_and_nonregular_finding_inputs_are_rejected
    with_review_workspace do |root, _env, service, _out|
      source = write(File.join(root, "shared", "finding-private.yml"), restricted_finding.to_yaml)
      FileUtils.mkdir_p(File.join(root, "findings"))
      File.link(source, File.join(root, "findings", "finding-hardlink.yml"))
      Dir.mkdir(File.join(root, "findings", "finding-directory.yml"))
      ["findings/finding-hardlink.yml", "findings/finding-directory.yml"].each do |path|
        assert_raises(SiloMigrate::UsageError) { service.review("acme", path, released_message: "Reviewed") }
      end
      assert_empty Dir[File.join(root, "trusted", "audit", "*.json")]
    end
  end

  def test_symlinked_workspace_is_not_an_alias_for_another_customer
    with_review_workspace do |root, _env, service, _out|
      write(File.join(root, "findings", "finding-private.yml"), restricted_finding.to_yaml)
      File.symlink(root, File.join(File.dirname(root), "other"))
      assert_raises(SiloMigrate::UsageError) { service.review("other", "findings/finding-private.yml", released_message: "Reviewed") }
      assert_empty Dir[File.join(root, "trusted", "audit", "*.json")]
    end
  end

  def test_exclusive_creation_never_overwrites_previous_audit_or_derivative
    with_review_workspace do |root, _env, service, _out|
      path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.to_yaml)
      SecureRandom.stub(:hex, "a" * 32) do
        first = service.review("acme", path, released_message: "First reviewed message")
        before = File.read(first.fetch(:reviewed_path))
        audit = File.read(first.fetch(:audit_path))
        error = assert_raises(SiloMigrate::UsageError) { service.review("acme", path, released_message: "Second reviewed message") }
        assert_equal "Trusted finding review could not access workspace artifacts.", error.message
        assert_nil error.cause
        assert_equal before, File.read(first.fetch(:reviewed_path))
        assert_equal audit, File.read(first.fetch(:audit_path))
        assert_empty Dir[File.join(root, "**", ".review-*")]
      end
    end
  end

  def test_derivative_collision_with_fresh_audit_preserves_existing_derivative
    with_review_workspace do |root, _env, service, out|
      path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.to_yaml)
      ids = ["a" * 32, "b" * 32, "a" * 32, "c" * 32]
      next_id = ->(*) { ids.shift || flunk("Unexpected random ID request") }
      SecureRandom.stub(:hex, next_id) do
        first = service.review("acme", path, released_message: "First reviewed message")
        content = File.binread(first.fetch(:reviewed_path))
        first_audit = File.binread(first.fetch(:audit_path))
        out.truncate(0)
        out.rewind
        error = assert_raises(SiloMigrate::UsageError) do
          service.review("acme", path, released_message: "Second reviewed message")
        end
        assert_equal "Trusted finding review could not access workspace artifacts.", error.message
        assert_nil error.cause
        assert_empty ids
        assert_equal content, File.binread(first.fetch(:reviewed_path))
        assert_equal first_audit, File.binread(first.fetch(:audit_path))
        audits = Dir[File.join(root, "trusted", "audit", "*.json")]
        assert_equal 2, audits.length
        second_audit = JSON.parse(File.read((audits - [first.fetch(:audit_path)]).fetch(0)))
        assert_equal "Second reviewed message", second_audit.dig("details", "released_message")
        assert_equal "findings/#{File.basename(first.fetch(:reviewed_path))}", second_audit.dig("details", "reviewed_finding")
        assert_equal [first.fetch(:reviewed_path)], Dir[File.join(root, "findings", "finding-*-reviewed.yml")]
        assert_empty Dir[File.join(root, "**", ".review-*")]
        assert_empty out.string
      end
    end
  end

  def test_failed_audit_and_derivative_writes_remove_staging_without_partial_publication
    ["trusted/audit", "findings"].each do |relative|
      %i[write flush fsync close].each do |operation|
        with_review_workspace do |root, _env, service, out|
          path = write(File.join(root, "trusted", "findings", "finding-private.yml"), trusted_finding.to_yaml)
          create = Tempfile.method(:create)
          failed_paths = []
          failing_create = lambda do |*args|
            staged = create.call(*args)
            if File.dirname(staged.path) == File.join(root, relative)
              failed_paths << staged.path
              original = staged.method(operation)
              failed = false
              staged.define_singleton_method(operation) do |*values|
                return original.call(*values) if failed

                failed = true
                if operation == :write
                  original.call(values.fetch(0).byteslice(0, 8))
                  flush
                end
                raise IOError, "private-write-sentinel"
              end
            end
            staged
          end
          Tempfile.stub(:create, failing_create) do
            error = assert_raises(SiloMigrate::UsageError) do
              service.redact("acme", path, released_message: "Reviewed synthetic summary")
            end
            assert_equal "Trusted finding review could not access workspace artifacts.", error.message
            assert_nil error.cause
          end
          assert_equal 1, failed_paths.length, "#{relative}: #{operation} was not exercised"
          refute File.exist?(failed_paths.fetch(0))
          assert_empty Dir[File.join(root, "**", ".review-*")]
          assert_empty Dir[File.join(root, "findings", "finding-*-redacted.yml")]
          audits = Dir[File.join(root, "trusted", "audit", "*.json")]
          if relative == "trusted/audit"
            assert_empty audits
          else
            assert_equal 1, audits.length
            assert_equal "Reviewed synthetic summary", JSON.parse(File.read(audits.fetch(0))).dig("details", "released_message")
          end
          assert_equal trusted_finding.to_yaml, File.read(path)
          assert_empty out.string
        end
      end
    end
  end

  def test_audit_failure_prevents_derivative_publication_and_hides_io_details
    with_review_workspace do |root, _env, service, out|
      path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.to_yaml)
      failure = ->(*) { raise IOError, "private-sentinel" }
      service.stub(:write_review_artifact, failure) do
        error = assert_raises(SiloMigrate::UsageError) { service.review("acme", path, released_message: "Reviewed") }
        refute_includes error.message, "private-sentinel"
        assert_nil error.cause
      end
      assert_empty Dir[File.join(root, "findings", "finding-*-reviewed.yml")]
      assert_empty out.string
    end
  end

  def test_invalid_private_metadata_is_rejected_without_echoing_values
    with_review_workspace do |root, env, service, out|
      path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.to_yaml)
      ["private-sentinel\0", "private-sentinel\xFF".b.force_encoding("UTF-8"), { "private-sentinel" => true }].each do |value|
        %i[notes reviewer].each do |field|
          error = assert_raises(SiloMigrate::UsageError) do
            service.review("acme", path, released_message: "Reviewed", **{ field => value })
          end
          assert_equal "Invalid private review metadata.", error.message
        end
      end
      env["SILO_MIGRATE_ACTOR"] = "private-sentinel\0"
      error = assert_raises(SiloMigrate::UsageError) { service.review("acme", path, reviewer: "operator", released_message: "Reviewed") }
      assert_equal "Invalid private review metadata.", error.message
      assert_empty Dir[File.join(root, "trusted", "audit", "*.json")]
      assert_empty Dir[File.join(root, "findings", "finding-*-reviewed.yml")]
      assert_empty out.string
    end
  end

  def test_audit_serialization_errors_are_sanitized
    with_review_workspace do |root, _env, service, out|
      path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.to_yaml)
      [JSON::GeneratorError, Encoding::UndefinedConversionError].each do |error_class|
        failure = ->(*) { raise error_class, "private-sentinel" }
        JSON.stub(:pretty_generate, failure) do
          error = assert_raises(SiloMigrate::UsageError) { service.review("acme", path, released_message: "Reviewed") }
          assert_equal "Trusted finding review could not access workspace artifacts.", error.message
          assert_nil error.cause
        end
      end
      assert_empty Dir[File.join(root, "**", ".review-*")]
      assert_empty Dir[File.join(root, "trusted", "audit", "*.json")]
      assert_empty Dir[File.join(root, "findings", "finding-*-reviewed.yml")]
      assert_empty out.string
    end
  end

  def test_absolute_inspection_path_through_symlinked_base_is_accepted_but_inner_symlinks_are_not
    with_tmp_base do |dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      project.init("acme")
      canonical_root = File.realpath(project.project_path("acme"))
      alias_base = File.join(dir, "customers-alias")
      File.symlink(env.fetch("SILO_MIGRATE_BASE_PATH"), alias_base)
      env["SILO_MIGRATE_BASE_PATH"] = alias_base
      service = SiloMigrate::Services::TrustedWorkflowService.new(runtime: runtime, env: env, output: StringIO.new)
      inspection = service.inspect("acme", reason: "Synthetic check", command: %w[echo synthetic], as_finding: true)
      assert inspection.fetch(:finding_path).start_with?(alias_base + File::SEPARATOR)
      result = service.redact("acme", inspection.fetch(:finding_path), released_message: "Reviewed summary")
      assert_equal File.join(canonical_root, "findings"), File.dirname(result.fetch(:reviewed_path))
      assert_equal "Reviewed summary", YAML.safe_load(File.read(result.fetch(:reviewed_path))).fetch("message")
      File.symlink(File.join(canonical_root, "trusted", "findings"), File.join(canonical_root, "findings", "linked"))
      alias_link = File.join(alias_base, "acme", "findings", "linked", File.basename(inspection.fetch(:finding_path)))
      assert_raises(SiloMigrate::UsageError) { service.redact("acme", alias_link, released_message: "Reviewed") }
    end
  end

  def test_link_failures_clean_staging_and_do_not_publish_partial_artifacts
    ["trusted/audit", "findings"].each do |relative|
      with_review_workspace do |root, _env, service, out|
        path = write(File.join(root, "trusted", "findings", "finding-private.yml"), trusted_finding.to_yaml)
        link = File.method(:link)
        calls = []
        failing_link = lambda do |source, target|
          if File.dirname(target) == File.join(root, relative)
            calls << target
            raise Errno::EPERM, "private-sentinel"
          end
          link.call(source, target)
        end
        File.stub(:link, failing_link) do
          error = assert_raises(SiloMigrate::UsageError) { service.redact("acme", path, released_message: "Reviewed") }
          assert_equal "Trusted finding review could not access workspace artifacts.", error.message
          assert_nil error.cause
        end
        assert_equal 1, calls.length
        refute File.exist?(calls.fetch(0))
        assert_empty Dir[File.join(root, "**", ".review-*")]
        assert_empty Dir[File.join(root, "findings", "finding-*-redacted.yml")]
        assert_equal(relative == "findings" ? 1 : 0, Dir[File.join(root, "trusted", "audit", "*.json")].length)
        assert_empty out.string
      end
    end
  end

  def test_post_publication_cleanup_failure_distinguishes_audit_from_derivative
    ["trusted/audit", "findings"].each do |relative|
      with_review_workspace do |root, _env, service, out|
        path = write(File.join(root, "trusted", "findings", "finding-private.yml"), trusted_finding.to_yaml)
        unlink = File.method(:unlink)
        leftovers = []
        failing_unlink = lambda do |target|
          if File.dirname(target) == File.join(root, relative)
            leftovers << target
            raise Errno::EPERM, "private-sentinel"
          end
          unlink.call(target)
        end
        File.stub(:unlink, failing_unlink) do
          error = assert_raises(SiloMigrate::UsageError) { service.redact("acme", path, released_message: "Reviewed") }
          outcome = relative == "findings" ? "Derivative published" : "Audit written; derivative not published"
          assert_equal "#{outcome}; staging cleanup failed. Inspect the private workspace before retrying.", error.message
          assert_nil error.cause
        end
        assert_equal 1, leftovers.length
        assert File.exist?(leftovers.fetch(0))
        published_derivatives = Dir[File.join(root, "findings", "finding-*-redacted.yml")]
        if relative == "findings"
          assert_equal "Reviewed", YAML.safe_load(File.read(published_derivatives.fetch(0))).fetch("message")
        else
          assert_empty published_derivatives
        end
        assert_equal 1, Dir[File.join(root, "trusted", "audit", "*.json")].length
        assert_empty out.string
        published = Dir[File.join(root, relative, relative == "findings" ? "*.yml" : "*.json")].fetch(0)
        File.unlink(leftovers.fetch(0))
        assert_equal 1, File.stat(published).nlink
      end
    end
  end

  def test_close_failure_during_error_cleanup_does_not_mask_write_failure_or_leave_staging
    with_review_workspace do |root, _env, service, _out|
      path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.to_yaml)
      create = Tempfile.method(:create)
      original_close = nil
      failing_create = lambda do |*args|
        staged = create.call(*args)
        original_close = staged.method(:close)
        staged.define_singleton_method(:write) { |*| raise Errno::ENOSPC, "private-sentinel" }
        staged.define_singleton_method(:close) { raise Errno::ENOSPC, "private-sentinel" }
        staged
      end
      begin
        Tempfile.stub(:create, failing_create) do
          error = assert_raises(SiloMigrate::UsageError) { service.review("acme", path, released_message: "Reviewed") }
          assert_equal "Trusted finding review could not access workspace artifacts.", error.message
          assert_nil error.cause
        end
        assert_empty Dir[File.join(root, "**", ".review-*")]
        assert_empty Dir[File.join(root, "trusted", "audit", "*.json")]
        assert_empty Dir[File.join(root, "findings", "finding-*-reviewed.yml")]
      ensure
        original_close&.call
      end
    end
  end

  def test_status_output_failure_reports_that_artifacts_were_written
    with_review_workspace do |root, _env, service, out|
      path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.to_yaml)
      out.define_singleton_method(:puts) { |*| raise Errno::EPIPE, "private-sentinel" }
      error = assert_raises(SiloMigrate::UsageError) { service.review("acme", path, released_message: "Reviewed") }
      assert_equal "Review artifacts were written, but status output failed. Inspect the workspace before retrying.", error.message
      assert_nil error.cause
      assert_equal 1, Dir[File.join(root, "trusted", "audit", "*.json")].length
      assert_equal 1, Dir[File.join(root, "findings", "finding-*-reviewed.yml")].length
      assert_empty Dir[File.join(root, "**", ".review-*")]
    end
  end

  def test_success_output_identifies_only_opaque_artifact_paths
    with_review_workspace do |root, _env, service, out|
      path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.to_yaml)
      result = service.review("acme", path, reviewer: "private-reviewer", notes: "private-notes", released_message: "Reviewed")
      assert_includes out.string, "findings/#{File.basename(result.fetch(:reviewed_path))}"
      assert_includes out.string, "trusted/audit/#{File.basename(result.fetch(:audit_path))}"
      refute_includes out.string, root
      refute_includes out.string, "private-reviewer"
      refute_includes out.string, "private-notes"
    end
  end

  def test_repeated_reviews_get_distinct_ids_and_audits_even_at_same_timestamp
    with_review_workspace do |root, _env, service, _out|
      path = write(File.join(root, "findings", "finding-private.yml"), restricted_finding.to_yaml)
      results = 2.times.map { service.review("acme", path, released_message: "Reviewed", timestamp: Time.utc(2026, 6, 1)) }
      assert_equal 2, results.map { |result| result.fetch(:reviewed_path) }.uniq.length
      assert_equal 2, results.map { |result| result.fetch(:audit_path) }.uniq.length
    end
  end

  def test_malformed_and_missing_inputs_fail_without_private_parser_details
    with_review_workspace do |root, _env, service, out|
      ["[private-sentinel", "- private-sentinel", "--- !ruby/object:PrivateSentinel {}"].each do |content|
        path = write(File.join(root, "findings", "finding-private.yml"), content)
        error = assert_raises(SiloMigrate::UsageError) { service.review("acme", path, released_message: "Reviewed") }
        refute_includes error.message, "private-sentinel"
        refute_includes error.message, "PrivateSentinel"
      end
      error = assert_raises(SiloMigrate::UsageError) { service.review("acme", "findings/private-sentinel.yml", released_message: "Reviewed") }
      refute_includes error.message, "private-sentinel"
      assert_empty out.string
    end
  end

  private

  def with_review_workspace
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      project.init("acme")
      out = StringIO.new
      service = SiloMigrate::Services::TrustedWorkflowService.new(runtime: runtime, env: env, output: out)
      yield File.realpath(project.project_path("acme")), env, service, out
    end
  end

  def restricted_finding
    {
      "id" => "finding-20260601-120000-001",
      "message" => "Restricted taxonomy label",
      "exception_class" => nil,
      "observed_shape" => {
        "value_type" => "string",
        "redacted" => true
      },
      "dev_visibility" => "restricted"
    }
  end

  def trusted_finding
    restricted_finding.merge(
      "message" => "Raw customer value",
      "exception_class" => "RuntimeError",
      "dev_visibility" => "trusted_only"
    )
  end
end
