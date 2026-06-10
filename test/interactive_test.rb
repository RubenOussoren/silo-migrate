# frozen_string_literal: true

require_relative "test_helper"

class InteractiveTest < SiloMigrateTest
  class AskOnlyPrompt
    def initialize(answers)
      @answers = answers
    end

    def ask(_message)
      @answers.shift
    end
  end

  def build_services(env)
    runtime = SiloMigrate::Runtime::Fake.new
    project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
    import = SiloMigrate::Services::ImportService.new(runtime: runtime, env: env, output: StringIO.new)
    [project, import]
  end

  def test_non_tty_stdin_fails_fast_with_command_list
    with_tmp_base do |_dir, env|
      project, import = build_services(env)
      interactive = SiloMigrate::Interactive.new(
        project_service: project,
        import_service: import,
        output: StringIO.new,
        stdin: StringIO.new
      )
      error = assert_raises(SiloMigrate::UsageError) { interactive.run }
      assert_includes error.message, "stdin is not a TTY"
      assert_includes error.message, "import-dump"
    end
  end

  def test_first_run_prompts_for_base_path_and_persists_it
    Dir.mktmpdir do |dir|
      env = { "SILO_MIGRATE_USER_CONFIG" => File.join(dir, "user-config.env") }
      chosen = File.join(dir, "my-projects")
      project, import = build_services(env)
      out = StringIO.new
      prompt = AskOnlyPrompt.new([chosen, "n"])
      interactive = SiloMigrate::Interactive.new(
        project_service: project,
        import_service: import,
        prompt: prompt,
        output: out
      )
      interactive.run

      assert Dir.exist?(chosen)
      assert_equal chosen, SiloMigrate::UserConfig.load(env)["SILO_MIGRATE_BASE_PATH"]
      assert_includes out.string, "Projects will be stored in #{chosen}"
    end
  end

  def test_select_fallback_reprompts_on_invalid_input
    with_tmp_base do |_dir, env|
      project, import = build_services(env)
      out = StringIO.new
      prompt = AskOnlyPrompt.new(["5", "nope", "2"])
      interactive = SiloMigrate::Interactive.new(
        project_service: project,
        import_service: import,
        prompt: prompt,
        output: out
      )
      result = interactive.send(:select, "Pick one", { "first" => :a, "second" => :b })
      assert_equal :b, result
      assert_includes out.string, "Invalid selection"
    end
  end
end
