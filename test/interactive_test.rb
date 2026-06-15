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

  def build_interactive(env, answers: [], out: StringIO.new)
    project, import = build_services(env)
    interactive = SiloMigrate::Interactive.new(
      project_service: project,
      import_service: import,
      prompt: AskOnlyPrompt.new(answers),
      output: out
    )
    [interactive, project, out]
  end

  USERS_JSON = '{"object_name": "users", "total_records": 1, "data": [{"id": "user:1", "login": "alice"}]}'

  def test_convert_json_to_project_writes_staged_dump
    with_tmp_base do |dir, env|
      interactive, project, out = build_interactive(env)
      project.init("acme", {})
      source = write(File.join(dir, "users.json"), USERS_JSON)

      output = interactive.send(:convert_json_to_project, "acme", "initial", source,
                                exclude_files: [], batch_size: 1000, schema_dir: nil)

      expected = File.join(project.project_path("acme"), "dumps", "initial", "users.sql.gz")
      assert_equal expected, output.to_s
      sql = Zlib::GzipReader.open(expected, &:read)
      assert_includes sql, "CREATE TABLE `users`"
      assert_includes sql, "'user:1'"
      assert_includes out.string, "[OK] JSON converted and staged:"
    end
  end

  def test_convert_json_to_project_respects_replace_decline
    with_tmp_base do |dir, env|
      interactive, project, out = build_interactive(env, answers: ["n"])
      project.init("acme", {})
      source = write(File.join(dir, "users.json"), USERS_JSON)
      existing = File.join(project.project_path("acme"), "dumps", "initial", "users.sql.gz")
      write(existing, "keep me")

      output = interactive.send(:convert_json_to_project, "acme", "initial", source,
                                exclude_files: [], batch_size: 1000, schema_dir: nil)

      assert_nil output
      assert_equal "keep me", File.read(existing)
      assert_includes out.string, "JSON conversion skipped"
    end
  end

  def test_convert_json_offers_to_recover_truncated_file_and_retry
    with_tmp_base do |dir, env|
      # Answer "y" to "Recover the complete records before the truncation point...?"
      interactive, project, out = build_interactive(env, answers: ["y"])
      project.init("acme", {})
      source = File.join(dir, "exports")
      write(File.join(source, "users.json"), USERS_JSON)
      write(File.join(source, "messages.json"),
            '{"object_name": "messages", "data": [{"id": "message:1", "body": "ok"}, {"id": "message:2", "body": "cut off mid str')

      output = interactive.send(:convert_json_to_project, "acme", "initial", source,
                                exclude_files: [], batch_size: 1000, schema_dir: nil)

      refute_nil output
      sql = Zlib::GzipReader.open(output.to_s, &:read)
      assert_includes sql, "CREATE TABLE `users`"
      assert_includes sql, "CREATE TABLE `messages`"
      assert_includes sql, "'message:1'"
      refute_includes sql, "'message:2'"
      assert_includes out.string, "[WARN] Malformed JSON in messages.json"
      assert_includes out.string, "recovered 1 complete record(s)"
    end
  end

  def test_convert_json_offers_to_skip_malformed_file_when_recovery_declined
    with_tmp_base do |dir, env|
      # "n" declines recovery, "y" accepts skipping the file.
      interactive, project, out = build_interactive(env, answers: ["n", "y"])
      project.init("acme", {})
      source = File.join(dir, "exports")
      write(File.join(source, "users.json"), USERS_JSON)
      write(File.join(source, "messages.json"), '{"object_name": "messages", "data": [{"body": "cut off mid str')

      output = interactive.send(:convert_json_to_project, "acme", "initial", source,
                                exclude_files: [], batch_size: 1000, schema_dir: nil)

      refute_nil output
      sql = Zlib::GzipReader.open(output.to_s, &:read)
      assert_includes sql, "CREATE TABLE `users`"
      refute_includes sql, "CREATE TABLE `messages`"
      assert_includes out.string, "[WARN] Malformed JSON in messages.json"
      assert_includes out.string, "appears to be truncated"
    end
  end

  def test_prompt_json_schema_dir_detects_schema_directory
    with_tmp_base do |dir, env|
      source = File.join(dir, "exports")
      write(File.join(source, "users.json"), USERS_JSON)
      schema_dir = File.join(source, "schema")
      write(File.join(schema_dir, "users.schema.json"), "{}")

      interactive, = build_interactive(env, answers: ["y"])
      assert_equal schema_dir, interactive.send(:prompt_json_schema_dir, Pathname(source)).to_s

      interactive, = build_interactive(env, answers: ["n", ""])
      assert_nil interactive.send(:prompt_json_schema_dir, Pathname(source))
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
