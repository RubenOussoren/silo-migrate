# frozen_string_literal: true

require_relative "test_helper"

class AIWorkspaceServiceTest < SiloMigrateTest
  def setup_project_with_clone(env, git: true)
    project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
    project.init("acme")
    project_path = project.project_path("acme")
    clone = File.join(project_path, "discourse-converters")
    write(File.join(clone, "Gemfile"), "source 'https://rubygems.org'\n")
    write(File.join(clone, "convert"), "#!/usr/bin/env ruby\n")
    write(File.join(clone, "converters", "fixture", "importer.rb"), "class Importer; end\n")
    FileUtils.mkdir_p(File.join(clone, ".git", "info")) if git
    [project_path, clone]
  end

  def service(env, out: StringIO.new)
    SiloMigrate::Services::AIWorkspaceService.new(env: env, output: out)
  end

  def test_prepare_writes_safe_artifacts_inside_clone
    with_tmp_base do |_dir, env|
      project_path, clone = setup_project_with_clone(env)
      write(File.join(project_path, "schema", "initial", "summary.json"), JSON.pretty_generate("contains_raw_rows" => false))
      write(File.join(project_path, "findings", "redacted-logs", "latest.log"), "[EMAIL]\n")
      write(File.join(project_path, "findings", "finding-safe.yml"), finding("finding-safe", "safe").to_yaml)
      write(File.join(project_path, "findings", "finding-restricted.yml"), finding("finding-restricted", "restricted").to_yaml)
      write(File.join(project_path, "trusted", "findings", "finding-trusted.yml"), finding("finding-trusted", "trusted_only").to_yaml)
      write(File.join(project_path, "synthetic-fixtures", "synthetic-finding-safe.yml"), "values: {}\n")
      write(File.join(project_path, "dumps", "initial", "dump.sql"), "raw_row_sentinel\n")
      write(File.join(project_path, "output", "intermediate.db"), "raw_db_sentinel\n")
      write(File.join(project_path, "converter-settings", "fixture.yml"), "database:\n  password: \"settings_pw_sentinel\"\n")

      out = StringIO.new
      result = service(env, out: out).prepare("acme")
      safe = result.fetch(:safe_artifacts_path)

      assert_equal File.join(clone, "safe-artifacts"), safe
      assert_equal clone, result.fetch(:clone_path)
      assert File.exist?(File.join(safe, "schema", "initial", "summary.json"))
      assert File.exist?(File.join(safe, "findings", "redacted-logs", "latest.log"))
      assert File.exist?(File.join(safe, "findings", "finding-safe.yml"))
      assert File.exist?(File.join(safe, "synthetic-fixtures", "synthetic-finding-safe.yml"))
      assert File.exist?(File.join(safe, "manifest.json"))
      assert File.exist?(File.join(safe, "allowed-commands.json"))
      assert_equal "*\n", File.read(File.join(safe, ".gitignore"))
      assert File.exist?(File.join(clone, "AGENTS.md"))
      assert File.exist?(File.join(clone, "CLAUDE.md"))
      assert File.exist?(File.join(clone, ".claude", "settings.json"))
      assert File.exist?(File.join(clone, ".silo", "normal-dev-ai.yml"))

      refute File.exist?(File.join(safe, "findings", "finding-restricted.yml"))
      refute File.exist?(File.join(safe, "findings", "finding-trusted.yml"))
      refute Dir.exist?(File.join(safe, "converter-settings"))
      refute Dir.exist?(File.join(safe, "dumps"))
      refute Dir.exist?(File.join(safe, "output"))

      # No raw sentinel may appear anywhere under safe-artifacts or the generated root files.
      generated = Dir.glob(File.join(safe, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }
      generated += [File.join(clone, "AGENTS.md"), File.join(clone, "CLAUDE.md"), File.join(clone, ".claude", "settings.json"), File.join(clone, ".silo", "normal-dev-ai.yml")]
      %w[raw_row_sentinel raw_db_sentinel settings_pw_sentinel].each do |sentinel|
        leaked = generated.select { |f| File.read(f).include?(sentinel) }
        assert_empty leaked, "#{sentinel} leaked into: #{leaked.join(', ')}"
      end

      agents = File.read(File.join(clone, "AGENTS.md"))
      refute_includes agents, project_path
      assert_includes agents, "../dumps/"
      assert_includes agents, "run-converter acme TYPE --redacted-logs"

      silo = YAML.safe_load(File.read(File.join(clone, ".silo", "normal-dev-ai.yml")))
      assert_equal clone, silo.fetch("mounts").first.fetch("source")
      assert_includes out.string, "Skipped non-safe findings"
    end
  end

  def test_prepare_writes_idempotent_git_exclude_block
    with_tmp_base do |_dir, env|
      _project_path, clone = setup_project_with_clone(env)
      exclude = File.join(clone, ".git", "info", "exclude")
      write(exclude, "# user line\nuser-pattern.tmp\n")

      service(env).prepare("acme")
      service(env).prepare("acme")

      content = File.read(exclude)
      assert_includes content, "user-pattern.tmp"
      assert_includes content, "/safe-artifacts/"
      assert_includes content, "/AGENTS.md"
      assert_includes content, "/Dockerfile"
      assert_equal 1, content.scan("/safe-artifacts/").length, "exclude block duplicated"
    end
  end

  def test_prepare_converges_preexisting_duplicate_exclude_blocks
    with_tmp_base do |_dir, env|
      _project_path, clone = setup_project_with_clone(env)
      exclude = File.join(clone, ".git", "info", "exclude")
      marker = SiloMigrate::Services::AIWorkspaceService::EXCLUDE_BEGIN
      ender = SiloMigrate::Services::AIWorkspaceService::EXCLUDE_END
      write(exclude, "# user line\n#{marker}\n/safe-artifacts/\n#{ender}\n#{marker}\n/safe-artifacts/\n#{ender}\n")

      service(env).prepare("acme")

      content = File.read(exclude)
      assert_includes content, "# user line"
      assert_equal 1, content.scan(marker).length, "managed blocks did not converge to one"
    end
  end

  def test_refresh_preserves_code_edits_and_git_state
    with_tmp_base do |_dir, env|
      project_path, clone = setup_project_with_clone(env)
      svc = service(env)
      safe = svc.prepare("acme").fetch(:safe_artifacts_path)

      code_file = File.join(clone, "converters", "fixture", "importer.rb")
      File.write(code_file, "class Importer; def run; end; end\n")
      untracked = write(File.join(clone, "converters", "fixture", "new_step.rb"), "# new\n")
      git_sentinel = write(File.join(clone, ".git", "objects-sentinel"), "git data\n")
      stale = write(File.join(safe, "findings", "finding-stale.yml"), finding("finding-stale", "safe").to_yaml)
      write(File.join(project_path, "findings", "finding-safe.yml"), finding("finding-safe", "safe").to_yaml)

      svc.refresh("acme")

      assert_equal "class Importer; def run; end; end\n", File.read(code_file)
      assert File.exist?(untracked)
      assert File.exist?(git_sentinel)
      refute File.exist?(stale)
      assert File.exist?(File.join(safe, "findings", "finding-safe.yml"))
    end
  end

  def test_prepare_falls_back_when_unmanaged_root_files_exist
    with_tmp_base do |_dir, env|
      _project_path, clone = setup_project_with_clone(env)
      write(File.join(clone, "AGENTS.md"), "upstream instructions\n")
      write(File.join(clone, ".claude", "settings.json"), "{\"permissions\":{}}\n")

      out = StringIO.new
      service(env, out: out).prepare("acme")

      assert_equal "upstream instructions\n", File.read(File.join(clone, "AGENTS.md"))
      assert_equal "{\"permissions\":{}}\n", File.read(File.join(clone, ".claude", "settings.json"))
      assert File.exist?(File.join(clone, "safe-artifacts", "AGENTS.md"))
      assert_includes out.string, "AGENTS.md already exists"
      assert_includes out.string, ".claude/settings.json already exists"
    end
  end

  def test_prepare_overwrites_previously_generated_root_files
    with_tmp_base do |_dir, env|
      _project_path, clone = setup_project_with_clone(env)
      service(env).prepare("acme")
      first = File.read(File.join(clone, "AGENTS.md"))
      assert_includes first, "silo-migrate:generated"

      service(env).prepare("acme")
      assert_includes File.read(File.join(clone, "AGENTS.md")), "silo-migrate:generated"
      refute File.exist?(File.join(clone, "safe-artifacts", "AGENTS.md"))
    end
  end

  def test_prepare_requires_converter_clone
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")

      error = assert_raises(SiloMigrate::UsageError) { service(env).prepare("acme") }
      assert_includes error.message, "setup-converter"
    end
  end

  def test_prepare_warns_without_git_dir
    with_tmp_base do |_dir, env|
      _project_path, clone = setup_project_with_clone(env, git: false)
      out = StringIO.new
      service(env, out: out).prepare("acme")

      assert_includes out.string, "cannot be locally git-ignored"
      assert File.exist?(File.join(clone, "safe-artifacts", "manifest.json"))
    end
  end

  def test_refresh_if_prepared_is_gated_on_manifest
    with_tmp_base do |_dir, env|
      _project_path, clone = setup_project_with_clone(env)
      svc = service(env)

      refute svc.refresh_if_prepared("acme")
      refute File.exist?(File.join(clone, "safe-artifacts", "manifest.json"))

      svc.prepare("acme")
      assert svc.refresh_if_prepared("acme")
    end
  end

  def test_reset_guard_refuses_unexpected_path
    with_tmp_base do |_dir, env|
      _project_path, clone = setup_project_with_clone(env)
      svc = service(env)
      error = assert_raises(SiloMigrate::UsageError) do
        svc.send(:reset_safe_artifacts!, "/tmp/somewhere-else", clone)
      end
      assert_includes error.message, "Refusing to delete"
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
