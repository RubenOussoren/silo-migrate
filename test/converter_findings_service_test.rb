# frozen_string_literal: true

require_relative "test_helper"

class ConverterFindingsServiceTest < SiloMigrateTest
  def test_generates_findings_from_intermediate_errors_warnings_and_process_errors
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      project_path = project.project_path("acme")
      summary_path = write(File.join(project_path, "findings", "redacted-logs", "latest.summary.json"), JSON.pretty_generate(summary))

      artifacts = SiloMigrate::Services::ConverterFindingsService.new(env: env, output: StringIO.new).generate(
        "acme",
        from: summary_path,
        timestamp: Time.utc(2026, 6, 1, 12, 30, 45)
      )

      assert_equal 3, artifacts.fetch(:findings).length
      assert File.exist?(artifacts.fetch(:index_path))
      first = YAML.safe_load(File.read(artifacts.fetch(:findings).first))
      second = YAML.safe_load(File.read(artifacts.fetch(:findings)[1]))
      third = YAML.safe_load(File.read(artifacts.fetch(:findings)[2]))

      assert_equal "finding-20260601-123045-001", first.fetch("id")
      assert_equal "converter_log_error", first.fetch("failure")
      assert_equal "error", first.fetch("severity")
      assert_equal "NoMethodError", first.fetch("exception_class")
      assert_equal "email", first.dig("observed_shape", "value_types", "email")
      assert_equal "safe", first.fetch("dev_visibility")

      assert_equal "converter_log_warning", second.fetch("failure")
      assert_equal "warning", second.fetch("severity")
      assert_equal "converter_runtime_error", third.fetch("failure")
      assert_equal "[EMAIL]", third.fetch("message")

      combined = artifacts.fetch(:findings).map { |path| File.read(path) }.join("\n")
      refute_includes combined, "raw customer text"
      refute_includes combined, "customer@example.com"
      refute_includes combined, "details:"
      assert_includes combined, "observed_shape"

      index = JSON.parse(File.read(artifacts.fetch(:index_path)))
      assert_equal "findings/redacted-logs/latest.summary.json", index.fetch("source")
      assert_equal ["finding-20260601-123045-001.yml", "finding-20260601-123045-002.yml", "finding-20260601-123045-003.yml"], index.fetch("findings").map { |entry| entry.fetch("path") }
    end
  end

  def test_default_input_requires_latest_redacted_summary
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")

      error = assert_raises(SiloMigrate::UsageError) do
        SiloMigrate::Services::ConverterFindingsService.new(env: env, output: StringIO.new).generate("acme")
      end

      assert_includes error.message, "run-converter acme --redacted-logs"
    end
  end

  def test_preserves_restricted_and_trusted_visibility_from_summary_inputs
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      project_path = project.project_path("acme")
      restricted = summary
      restricted.dig("sources", "intermediate_db", "entries").first["dev_visibility"] = "restricted"
      restricted.dig("sources", "intermediate_db", "entries")[1]["details"] = "{\"raw\":\"customer value\"}"
      summary_path = write(File.join(project_path, "findings", "redacted-logs", "latest.summary.json"), JSON.pretty_generate(restricted))

      artifacts = SiloMigrate::Services::ConverterFindingsService.new(env: env, output: StringIO.new).generate(
        "acme",
        from: summary_path,
        timestamp: Time.utc(2026, 6, 1, 12, 30, 45)
      )

      first = YAML.safe_load(File.read(artifacts.fetch(:findings).first))
      second = YAML.safe_load(File.read(artifacts.fetch(:findings)[1]))
      assert_equal "restricted", first.fetch("dev_visibility")
      assert_equal "trusted_only", second.fetch("dev_visibility")
    end
  end

  def test_malformed_summary_raises_usage_error
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      path = write(File.join(project.project_path("acme"), "findings", "redacted-logs", "latest.summary.json"), "{")

      error = assert_raises(SiloMigrate::UsageError) do
        SiloMigrate::Services::ConverterFindingsService.new(env: env, output: StringIO.new).generate("acme", from: path)
      end

      assert_includes error.message, "Malformed redacted summary"
    end
  end

  private

  def summary
    {
      "artifact_version" => 1,
      "sources" => {
        "intermediate_db" => {
          "entries" => [
            {
              "type" => "error",
              "message" => "Failed for [EMAIL]",
              "exception" => "NoMethodError: undefined method",
              "details" => "[REDACTED_DETAILS]",
              "details_shape" => {
                "keys" => %w[email body],
                "value_types" => { "email" => "email", "body" => "text" },
                "value_categories" => { "email" => "[EMAIL]", "body" => "[TEXT length=120]" },
                "redacted" => true
              }
            },
            {
              "type" => "warning",
              "message" => "Skipped optional row",
              "exception" => nil,
              "details" => "[REDACTED_DETAILS]",
              "details_shape" => {
                "value_type" => "string",
                "redacted" => true
              }
            }
          ]
        },
        "process_output" => {
          "detected_errors" => [
            {
              "stream" => "stderr",
              "line" => 3,
              "text" => "[EMAIL]"
            }
          ]
        }
      }
    }
  end
end
