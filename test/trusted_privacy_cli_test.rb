# frozen_string_literal: true

require_relative "test_helper"

class TrustedPrivacyCLITest < SiloMigrateTest
  SECRET = "sensitive-option-canary@example.test"

  def with_mock_cli
    with_tmp_base do |_dir, env|
      env["SILO_MIGRATE_FORCE_LINUX"] = "1"
      root = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).init("acme")
      calls = []
      runtime = SiloMigrate::Runtime::Fake.new
      runtime.define_singleton_method(:run) do |command, **options|
        calls << [command, options]
        raise "uncaptured synthetic invocation" unless options[:capture] && options[:binary]

        SiloMigrate::Runtime::CommandResult.new(success?: true, status: 0, stdout: "\xFF".b, stderr: "")
      end
      out = StringIO.new
      err = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: err)
      yield root, env, cli, out, err, calls, runtime
    end
  end

  def test_inspect_and_session_option_errors_never_echo_values_or_execute
    with_mock_cli do |_root, _env, cli, out, err, calls, _runtime|
      invalid = "#{SECRET}\xFF".b.force_encoding("UTF-8")
      [
        ["trusted", SECRET],
        ["trusted", "inspect"],
        ["trusted", "inspect", "acme", "--reazon=#{SECRET}", "--", "synthetic"],
        ["trusted", "inspect", "acme", "--reason=#{invalid}", "--bad=#{SECRET}", "--", "synthetic"],
        ["trusted", "inspect", "acme", "--phase", SECRET, "--reason", "synthetic", "--", "synthetic"],
        ["trusted", "inspect", "acme", "--reason", "synthetic", SECRET, "--", "synthetic"],
        ["trusted", "inspect", "acme", "--reason", SECRET],
        ["trusted", "session"],
        ["trusted", "session", "acme", "--reazon=#{SECRET}"],
        ["trusted", "session", "acme", "--reason=#{invalid}", "--bad=#{SECRET}"],
        ["trusted", "session", "acme", "--reason", SECRET, "--provider", SECRET],
        ["trusted", "session", "acme", "--reason", SECRET, "--session-id", "../#{SECRET}"],
        ["trusted", "session", "acme", "--reason", "synthetic", SECRET]
      ].each { |args| assert_equal 1, cli.run(args) }
      refute_includes err.string, SECRET
      assert_empty out.string
      assert_empty calls
      err.string.lines.each { |line| assert_match(/\AError: TRUSTED_[A-Z_]+\n\z/, line) }
    end
  end

  def test_nested_help_version_and_completion_cannot_print_or_exit
    with_mock_cli do |_root, _env, cli, out, err, calls, _runtime|
      captured_out, captured_err = capture_io do
        %w[--help -h --version -v --*-completion-bash --*-completion-zsh --completion-bash --rea=synthetic -rsynthetic -msynthetic].each do |flag|
          assert_equal 1, cli.run(["trusted", "inspect", "acme", "--reason", "synthetic", flag, "--", "synthetic"])
          assert_equal 1, cli.run(["trusted", "session", "acme", "--reason", "synthetic", flag])
        end
      end
      assert_equal 1, cli.run(["trusted", "inspect", "acme", "--reason", "synthetic", "-r", "synthetic", "--", "synthetic"])
      assert_equal 1, cli.run(["trusted", "session", "acme", "--reason", "synthetic", "-r", "synthetic"])
      assert_empty captured_out
      assert_empty captured_err
      assert_empty out.string
      assert_empty calls
      assert_includes err.string, "TRUSTED_INSPECT_OPTIONS_INVALID"
      assert_includes err.string, "TRUSTED_SESSION_OPTIONS_INVALID"
    end
  end

  def test_final_phase_finding_and_custom_session_id_remain_private
    with_mock_cli do |root, _env, cli, out, err, calls, _runtime|
      assert_equal 0, cli.run(["trusted", "inspect", "acme", "--phase", "final", "--as-finding", "--reason", SECRET, "--", "synthetic"])
      inspection = JSON.parse(File.read(Dir[File.join(root, "trusted/inspections/*.json")].first))
      assert_equal "final", inspection.fetch("phase")
      stub = YAML.safe_load(File.read(Dir[File.join(root, "trusted/findings/*.yml")].first))
      assert_equal "final", stub.fetch("phase")
      assert_equal "trusted_only", stub.fetch("dev_visibility")
      assert_equal 0, cli.run(["trusted", "session", "acme", "--session-id", "private-session-name", "--reason", SECRET])
      config = YAML.safe_load(File.read(Dir[File.join(root, "trusted/silo/*.yml")].first))
      assert_equal "private-session-name", config.fetch("session_id")
      refute_includes out.string, "private-session-name"
      assert_equal 3, calls.length
      assert_empty err.string
    end
  end

  def test_invalid_byte_metadata_in_separate_values_is_preserved_not_printed
    with_mock_cli do |root, _env, cli, out, err, calls, _runtime|
      reason = "#{SECRET}\xFF\0".b.force_encoding("UTF-8")
      assert_equal 0, cli.run(["trusted", "inspect", "acme", "--reason", reason, "--message", reason, "--", "synthetic-inspection"])
      artifact = JSON.parse(File.read(Dir[File.join(root, "trusted/inspections/*.json")].fetch(0)))
      assert_equal reason.b, artifact.fetch("reason").fetch("data").unpack1("m0")
      assert_equal reason.b, artifact.fetch("message").fetch("data").unpack1("m0")
      assert_equal "\xFF".b, artifact.fetch("stdout").fetch("data").unpack1("m0")
      assert_equal 0, cli.run(["trusted", "session", "acme", "--reason", reason])
      assert_equal 3, calls.length
      calls.each { |_command, options| assert_equal true, options.fetch(:capture) }
      refute_includes out.string, SECRET
      refute_includes out.string, root
      assert_empty err.string
    end
  end

  def test_parser_failures_suppress_causes_even_inside_private_rescue_context
    with_mock_cli do |_root, _env, cli, _out, _err, calls, _runtime|
      begin
        raise RuntimeError, SECRET
      rescue RuntimeError
        %i[trusted_inspect trusted_session].each do |method|
          error = assert_raises(SiloMigrate::UsageError) { cli.send(method, ["acme", "--unknown=#{SECRET}"]) }
          assert_nil error.cause
          refute_includes error.full_message, SECRET
        end
        error = assert_raises(SiloMigrate::UsageError) { cli.send(:trusted, [SECRET]) }
        assert_nil error.cause
        refute_includes error.full_message, SECRET
      end
      assert_empty calls
    end
  end

  def test_runtime_and_serialization_details_do_not_reach_cli_error_output
    with_mock_cli do |_root, _env, cli, out, err, _calls, runtime|
      runtime.define_singleton_method(:run) { |*args, **options| raise SiloMigrate::UsageError, SECRET }
      assert_equal 1, cli.run(["trusted", "inspect", "acme", "--reason", SECRET, "--", "synthetic"])
      assert_equal 1, cli.run(["trusted", "session", "acme", "--reason", SECRET])
      refute_includes err.string, SECRET
      assert_empty out.string
      assert_includes err.string, "TRUSTED_INSPECT_FAILED"
      assert_includes err.string, "TRUSTED_SESSION_FAILED"
    end
    with_mock_cli do |_root, _env, cli, out, err, _calls, _runtime|
      failure = ->(*) { raise JSON::GeneratorError, SECRET }
      JSON.stub(:pretty_generate, failure) do
        assert_equal 1, cli.run(["trusted", "inspect", "acme", "--reason", SECRET, "--", "synthetic"])
        assert_equal 1, cli.run(["trusted", "session", "acme", "--reason", SECRET])
      end
      refute_includes err.string, SECRET
      assert_empty out.string
    end
  end
end
