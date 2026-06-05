# frozen_string_literal: true

require_relative "test_helper"

class SyntheticFixtureServiceTest < SiloMigrateTest
  def test_generates_shape_only_fixture_values
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      project_path = project.project_path("acme")
      finding_path = write(File.join(project_path, "findings", "finding-20260601-120000-001.yml"), finding_with_all_shapes.to_yaml)
      write_index(project_path, finding_path)

      artifacts = SiloMigrate::Services::SyntheticFixtureService.new(env: env, output: StringIO.new).generate("acme")

      assert_equal 1, artifacts.fetch(:fixtures).length
      fixture = YAML.safe_load(File.read(artifacts.fetch(:fixtures).first))
      assert_equal "synthetic-finding-20260601-120000-001", fixture.fetch("id")
      assert_equal "safe", fixture.fetch("dev_visibility")
      assert_equal(
        {
          "email" => "synthetic@example.test",
          "text" => "Synthetic text preserving only field shape.",
          "string" => "synthetic-value",
          "integer" => 1,
          "float" => 1.0,
          "boolean" => true,
          "null" => nil,
          "array" => [],
          "object" => {}
        },
        fixture.fetch("values")
      )
    end
  end

  def test_supports_single_finding_file_and_directory_inputs
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      project_path = project.project_path("acme")
      first = write(File.join(project_path, "findings", "finding-20260601-120000-001.yml"), scalar_finding("finding-20260601-120000-001", "string").to_yaml)
      second = write(File.join(project_path, "findings", "finding-20260601-120000-002.yml"), scalar_finding("finding-20260601-120000-002", "integer").to_yaml)
      service = SiloMigrate::Services::SyntheticFixtureService.new(env: env, output: StringIO.new)

      single = service.generate("acme", from: first)
      from_dir = service.generate("acme", from: File.dirname(second))

      assert_equal [File.join(project_path, "synthetic-fixtures", "finding-20260601-120000-001.yml")], single.fetch(:fixtures)
      assert_equal 2, from_dir.fetch(:fixtures).length
    end
  end

  def test_skips_findings_without_usable_observed_shape
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      project_path = project.project_path("acme")
      finding_path = write(File.join(project_path, "findings", "finding-20260601-120000-001.yml"), scalar_finding("finding-20260601-120000-001", "url").to_yaml)
      write_index(project_path, finding_path)
      out = StringIO.new

      artifacts = SiloMigrate::Services::SyntheticFixtureService.new(env: env, output: out).generate("acme")

      assert_empty artifacts.fetch(:fixtures)
      assert_includes out.string, "Skipping finding-20260601-120000-001.yml"
      assert_empty Dir[File.join(project_path, "synthetic-fixtures", "*.yml")]
    end
  end

  def test_skips_restricted_and_trusted_only_findings
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      project_path = project.project_path("acme")
      restricted = scalar_finding("finding-20260601-120000-001", "string").merge("dev_visibility" => "restricted")
      trusted = scalar_finding("finding-20260601-120000-002", "integer").merge("dev_visibility" => "trusted_only")
      first = write(File.join(project_path, "findings", "#{restricted.fetch('id')}.yml"), restricted.to_yaml)
      second = write(File.join(project_path, "findings", "#{trusted.fetch('id')}.yml"), trusted.to_yaml)
      write_index(project_path, first, second)
      out = StringIO.new

      artifacts = SiloMigrate::Services::SyntheticFixtureService.new(env: env, output: out).generate("acme")

      assert_empty artifacts.fetch(:fixtures)
      assert_includes out.string, "dev_visibility=restricted requires trusted review or redaction"
      assert_includes out.string, "dev_visibility=trusted_only requires trusted review or redaction"
    end
  end

  def test_missing_default_findings_index_has_recovery_guidance
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")

      error = assert_raises(SiloMigrate::UsageError) do
        SiloMigrate::Services::SyntheticFixtureService.new(env: env, output: StringIO.new).generate("acme")
      end

      assert_includes error.message, "findings generate acme"
    end
  end

  private

  def finding_with_all_shapes
    {
      "id" => "finding-20260601-120000-001",
      "observed_shape" => {
        "keys" => %w[email text string integer float boolean null array object],
        "value_types" => {
          "email" => "email",
          "text" => "text",
          "string" => "string",
          "integer" => "integer",
          "float" => "float",
          "boolean" => "boolean",
          "null" => "null",
          "array" => "array",
          "object" => "object"
        },
        "redacted" => true
      }
    }
  end

  def scalar_finding(id, type)
    {
      "id" => id,
      "observed_shape" => {
        "value_type" => type,
        "redacted" => true
      }
    }
  end

  def write_index(project_path, *finding_paths)
    write(
      File.join(project_path, "findings", "latest-findings.json"),
      JSON.pretty_generate(
        "artifact_version" => 1,
        "findings" => finding_paths.map do |finding_path|
          {
            "id" => File.basename(finding_path, ".yml"),
            "path" => File.basename(finding_path)
          }
        end
      )
    )
  end
end
