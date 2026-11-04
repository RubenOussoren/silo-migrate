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

  def test_prepare_and_refresh_delegate_to_explicit_release_publication
    with_tmp_base do |_dir, env|
      setup_project_with_clone(env)
      calls = []
      release = Object.new
      release.define_singleton_method(:publish) do |customer|
        calls << customer
        { "state" => "synthetic-publication-result" }
      end
      SiloMigrate::Services::ArtifactReleaseService.stub(:new, release) do
        assert_equal({ "state" => "synthetic-publication-result" }, service(env).prepare("acme"))
        assert_equal({ "state" => "synthetic-publication-result" }, service(env).refresh("acme"))
      end
      assert_equal %w[acme acme], calls
    end
  end

  def test_prepare_and_refresh_do_not_auto_copy_or_auto_approve_classified_sources
    with_tmp_base do |_dir, env|
      project, clone = setup_project_with_clone(env)
      sources = {
        "schema/initial/summary.json" => '{"contains_raw_rows":false,"private":"schema-sentinel"}',
        "findings/redacted-logs/latest.log" => "private-log-sentinel\n",
        "findings/safe.yml" => "dev_visibility: safe\nmessage: private-finding-sentinel\n",
        "synthetic-fixtures/safe.yml" => "synthetic: true\nprivate: fixture-sentinel\n"
      }
      sources.each { |relative, content| write(File.join(project, relative), content) }
      release = release_service(env)
      candidate = release.prepare("acme", source: "schema/initial/summary.json", artifact_class: "summary")
      safe = File.join(clone, "safe-artifacts")
      write(File.join(safe, "findings/legacy.yml"), "legacy-private-sentinel")

      %i[prepare refresh].each do |method|
        result = service(env).public_send(method, "acme")
        assert_safe_result(result, project, clone)
        assert_empty published_artifacts(safe)
        refute File.exist?(File.join(safe, "findings/legacy.yml"))
        assert_equal "candidate", release.status("acme", id: candidate.fetch("id")).fetch("state")
        contents = view_contents(safe)
        %w[schema-sentinel private-log-sentinel private-finding-sentinel fixture-sentinel legacy-private-sentinel].each do |sentinel|
          refute_includes contents, sentinel
        end
      end
    end
  end

  def test_refresh_only_exposes_approved_snapshot_not_current_source
    with_tmp_base do |_dir, env|
      project, clone = setup_project_with_clone(env)
      release = release_service(env)
      source = write(File.join(project, "schema/initial/private-summary.json"), "{\"synthetic\":true}\n")
      candidate = release.prepare("acme", source: "schema/initial/private-summary.json", artifact_class: "summary")
      release.approve("acme", id: candidate.fetch("id"), sha256: candidate.fetch("sha256"), bytes: candidate.fetch("bytes"), reviewed: true, reviewer: "engineer", notes: "private-note-sentinel")
      File.write(source, "unreviewed-source-sentinel")
      result = service(env).refresh("acme")
      assert_safe_result(result, project, clone)
      safe = File.join(clone, "safe-artifacts")
      assert_equal "{\"synthetic\":true}\n", File.binread(File.join(safe, "artifacts", "#{candidate.fetch('id')}.json"))
      refute_includes view_contents(safe), "unreviewed-source-sentinel"
      refute_includes view_contents(safe), "private-note-sentinel"
      refute_includes view_contents(safe), "private-summary.json"
    end
  end

  def test_prepare_and_refresh_preserve_converter_code_git_and_existing_root_files
    with_tmp_base do |_dir, env|
      _project, clone = setup_project_with_clone(env)
      files = {
        "converters/fixture/importer.rb" => "class Importer; def run; end; end\n",
        "converters/fixture/new_step.rb" => "# untracked synthetic code\n",
        ".git/objects-sentinel" => "synthetic git data\n",
        ".git/index" => "synthetic index sentinel\n",
        ".git/info/exclude" => "# operator-owned excludes\nlocal-only.tmp\n",
        "AGENTS.md" => "upstream instructions\n",
        "CLAUDE.md" => "<!-- silo-migrate:generated -->\nold root instructions\n",
        ".claude/settings.json" => "{\"permissions\":{}}\n",
        ".silo/normal-dev-ai.yml" => "operator_owned: true\n",
        "Dockerfile" => "FROM synthetic-placeholder\n"
      }
      files.each { |relative, content| write(File.join(clone, relative), content) }
      %i[prepare refresh].each do |method|
        service(env).public_send(method, "acme")
        files.each { |relative, content| assert_equal content, File.binread(File.join(clone, relative)), relative }
      end
    end
  end

  def test_instructions_are_fixed_and_only_created_inside_safe_artifacts
    with_tmp_base do |_dir, env|
      _project, clone = setup_project_with_clone(env)
      service(env).prepare("acme")
      safe = File.join(clone, "safe-artifacts")
      before = %w[AGENTS.md CLAUDE.md allowed-commands.json].to_h do |name|
        [name, File.binread(File.join(safe, name))]
      end
      service(env).refresh("acme")
      before.each { |name, content| assert_equal content, File.binread(File.join(safe, name)) }
      %w[AGENTS.md CLAUDE.md allowed-commands.json .claude .silo Dockerfile].each do |relative|
        refute File.exist?(File.join(clone, relative)), "unexpected root instructions: #{relative}"
      end
      refute File.exist?(File.join(clone, ".git/info/exclude")), "publication must not write git excludes"
      JSON.parse(File.read(File.join(safe, "allowed-commands.json")))
      refute_includes view_contents(safe), "acme"
    end
  end

  def test_refresh_if_prepared_always_returns_false_and_never_publishes
    with_tmp_base do |_dir, env|
      project, clone = setup_project_with_clone(env)
      svc = service(env)
      refute svc.refresh_if_prepared("acme")
      refute File.exist?(File.join(clone, "safe-artifacts"))
      svc.prepare("acme")
      safe = File.join(clone, "safe-artifacts")
      release = release_service(env)
      write(File.join(project, "schema/initial/summary.json"), "{\"new_approved_sentinel\":true}")
      record = release.prepare("acme", source: "schema/initial/summary.json", artifact_class: "summary")
      release.approve("acme", id: record.fetch("id"), sha256: record.fetch("sha256"), bytes: record.fetch("bytes"), reviewed: true, reviewer: "engineer")
      svc.prepare("acme")
      before = view_contents(safe)
      # Even an existing approved view must never enable automatic publication.
      SiloMigrate::Services::ArtifactReleaseService.stub(:new, ->(**_args) { flunk "automatic hook constructed release service" }) do
        refute svc.refresh_if_prepared("acme")
        refute svc.refresh_if_prepared("missing-project")
      end
      assert_equal before, view_contents(safe)
      assert_equal 1, published_artifacts(safe).length
    end
  end

  def test_failed_refresh_propagates_release_refusal_and_invalidates_old_view
    with_tmp_base do |_dir, env|
      project, clone = setup_project_with_clone(env)
      write(File.join(project, "schema/initial/summary.json"), "{}")
      release = release_service(env)
      record = release.prepare("acme", source: "schema/initial/summary.json", artifact_class: "summary")
      release.approve("acme", id: record.fetch("id"), sha256: record.fetch("sha256"), bytes: record.fetch("bytes"), reviewed: true, reviewer: "engineer")
      service(env).prepare("acme")
      File.binwrite(File.join(project, ".silo-migrate/releases/state.json"), "private-corrupt-state-sentinel")
      error = assert_raises(SiloMigrate::UsageError) { service(env).refresh("acme") }
      assert_match(/\ARELEASE_[A-Z0-9_]+\z/, error.message)
      refute File.exist?(File.join(clone, "safe-artifacts/manifest.json"))
      assert_empty published_artifacts(File.join(clone, "safe-artifacts"))
    end
  end

  private

  def release_service(env)
    SiloMigrate::Services::ArtifactReleaseService.new(env: env, output: StringIO.new)
  end

  def assert_safe_result(result, project, clone)
    assert_kind_of Hash, result
    assert result.keys.all? { |key| key.is_a?(String) }
    text = JSON.generate(result)
    [project, clone, "clone_path", "safe_artifacts_path", "copied"].each { |value| refute_includes text, value }
  end

  def published_artifacts(safe)
    Dir.glob(File.join(safe, "artifacts", "**", "*")).select { |path| File.file?(path) }
  end

  def view_contents(safe)
    Dir.glob(File.join(safe, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort.map { |path| File.binread(path) }.join("\n")
  end
end
