# frozen_string_literal: true

require_relative "test_helper"

class AIWorkspaceServiceTest < SiloMigrateTest
  def test_prepare_copies_only_safe_artifacts_and_generates_agent_files
    with_tmp_base do |dir, env|
      env["SILO_MIGRATE_SAFE_AI_BASE_PATH"] = File.join(dir, "safe-ai")
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      project_path = project.project_path("acme")

      write(File.join(project_path, "discourse-converters", "Gemfile"), "source 'https://rubygems.org'\n")
      write(File.join(project_path, "discourse-converters", "convert"), "#!/usr/bin/env ruby\n")
      write(File.join(project_path, "schema", "initial", "summary.json"), JSON.pretty_generate("contains_raw_rows" => false))
      write(File.join(project_path, "findings", "redacted-logs", "latest.log"), "[EMAIL]\n")
      write(File.join(project_path, "findings", "finding-safe.yml"), finding("finding-safe", "safe").to_yaml)
      write(File.join(project_path, "findings", "finding-restricted.yml"), finding("finding-restricted", "restricted").to_yaml)
      write(File.join(project_path, "trusted", "findings", "finding-trusted.yml"), finding("finding-trusted", "trusted_only").to_yaml)
      write(File.join(project_path, "synthetic-fixtures", "synthetic-finding-safe.yml"), "values: {}\n")
      write(File.join(project_path, "dumps", "initial", "dump.sql"), "raw row\n")
      write(File.join(project_path, "output", "intermediate.db"), "sqlite raw\n")
      write(File.join(project_path, "converter-settings", "vbulletin.yml"), "database:\n  password: \"sentinel_pw_123\"\n")

      out = StringIO.new
      artifacts = SiloMigrate::Services::AIWorkspaceService.new(env: env, output: out).prepare("acme")
      workspace = artifacts.fetch(:workspace_path)

      assert File.exist?(File.join(workspace, "discourse-converters", "Gemfile"))
      assert File.exist?(File.join(workspace, "schema", "initial", "summary.json"))
      assert File.exist?(File.join(workspace, "findings", "redacted-logs", "latest.log"))
      assert File.exist?(File.join(workspace, "findings", "finding-safe.yml"))
      assert File.exist?(File.join(workspace, "synthetic-fixtures", "synthetic-finding-safe.yml"))
      assert File.exist?(File.join(workspace, "AGENTS.md"))
      assert File.exist?(File.join(workspace, "CLAUDE.md"))
      assert File.exist?(File.join(workspace, "allowed-commands.json"))
      assert File.exist?(File.join(workspace, ".silo", "normal-dev-ai.yml"))

      refute File.exist?(File.join(workspace, "config.env"))
      refute File.exist?(File.join(workspace, "dumps", "initial", "dump.sql"))
      refute File.exist?(File.join(workspace, "trusted", "findings", "finding-trusted.yml"))
      refute File.exist?(File.join(workspace, "output", "intermediate.db"))
      refute File.exist?(File.join(workspace, "findings", "finding-restricted.yml"))
      refute File.exist?(File.join(workspace, "converter-settings"))
      workspace_files = Dir.glob(File.join(workspace, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }
      refute(workspace_files.any? { |f| File.read(f).include?("sentinel_pw_123") }, "generated converter settings leaked into the AI workspace")

      agent_instructions = File.read(File.join(workspace, "AGENTS.md"))
      refute_includes agent_instructions, project_path
      assert_includes agent_instructions, "silo-migrate ai refresh acme"
      allowed = JSON.parse(File.read(File.join(workspace, "allowed-commands.json")))
      assert allowed.fetch("denied").any? { |entry| entry.include?("dumps/") }
      silo_config = YAML.safe_load(File.read(File.join(workspace, ".silo", "normal-dev-ai.yml")))
      assert_equal "normal-dev-ai", silo_config.fetch("kind")
      refute_includes silo_config.fetch("mounts").first.fetch("source"), project_path
      assert_includes out.string, "Skipped non-safe findings"
    end
  end

  def test_refresh_removes_stale_files
    with_tmp_base do |dir, env|
      env["SILO_MIGRATE_SAFE_AI_BASE_PATH"] = File.join(dir, "safe-ai")
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      project_path = project.project_path("acme")
      write(File.join(project_path, "findings", "finding-safe.yml"), finding("finding-safe", "safe").to_yaml)

      service = SiloMigrate::Services::AIWorkspaceService.new(env: env, output: StringIO.new)
      workspace = service.prepare("acme").fetch(:workspace_path)
      stale = File.join(workspace, "findings", "finding-stale.yml")
      write(stale, finding("finding-stale", "safe").to_yaml)

      service.refresh("acme")

      refute File.exist?(stale)
      assert File.exist?(File.join(workspace, "findings", "finding-safe.yml"))
    end
  end

  def test_prepare_rejects_workspace_inside_raw_project
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      raw_child = File.join(project.project_path("acme"), "safe-ai")

      error = assert_raises(SiloMigrate::UsageError) do
        SiloMigrate::Services::AIWorkspaceService.new(env: env, output: StringIO.new).prepare("acme", output_dir: raw_child)
      end

      assert_includes error.message, "outside the raw customer project"
    end
  end

  private

  def finding(id, visibility)
    {
      "id" => id,
      "message" => "Redacted",
      "observed_shape" => { "value_type" => "text" },
      "dev_visibility" => visibility
    }
  end
end
