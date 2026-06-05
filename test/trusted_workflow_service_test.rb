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
      project_path = project.project_path("acme")
      finding_path = write(File.join(project_path, "findings", "finding-20260601-120000-001.yml"), restricted_finding.to_yaml)

      artifacts = SiloMigrate::Services::TrustedWorkflowService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).review(
        "acme",
        finding_path,
        reviewer: "human",
        notes: "Schema-only taxonomy reviewed",
        timestamp: Time.utc(2026, 6, 1, 13, 5, 0)
      )

      reviewed = YAML.safe_load(File.read(artifacts.fetch(:reviewed_path)))
      audit = JSON.parse(File.read(artifacts.fetch(:audit_path)))
      assert_equal "finding-20260601-120000-001-reviewed", reviewed.fetch("id")
      assert_equal "safe", reviewed.fetch("dev_visibility")
      assert_equal "finding-20260601-120000-001", reviewed.fetch("source_trusted_finding_id")
      assert_equal false, reviewed.dig("review", "redacted")
      assert_equal "trusted_review", audit.fetch("event")
      assert_equal "safe", audit.dig("details", "decision")
    end
  end

  def test_redact_writes_safe_derivative_for_trusted_only_finding
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      project_path = project.project_path("acme")
      finding_path = write(File.join(project_path, "trusted", "findings", "finding-20260601-120000-001.yml"), trusted_finding.to_yaml)

      artifacts = SiloMigrate::Services::TrustedWorkflowService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).redact(
        "acme",
        finding_path,
        reviewer: "human",
        notes: "Removed raw message",
        timestamp: Time.utc(2026, 6, 1, 13, 10, 0)
      )

      reviewed = YAML.safe_load(File.read(artifacts.fetch(:reviewed_path)))
      audit = JSON.parse(File.read(artifacts.fetch(:audit_path)))
      assert_equal "safe", reviewed.fetch("dev_visibility")
      assert_equal "[REDACTED]", reviewed.fetch("message")
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
      project_path = project.project_path("acme")

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

  private

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
