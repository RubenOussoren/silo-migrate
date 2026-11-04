# frozen_string_literal: true

require_relative "test_helper"

class TrustedPrivacyTest < SiloMigrateTest
  SECRET = "sensitive-byte-canary@example.test"

  # Never invokes a process, database, provider, session or runtime backend.
  class MockExecution
    attr_reader :calls

    def initialize(*results)
      @results = results
      @calls = []
    end

    def run(command, **options)
      @calls << [command, options]
      raise "uncaptured invocation" unless options[:capture] == true && options[:binary] == true

      result = @results.shift
      raise result if result.is_a?(Exception)

      result || SiloMigrate::Runtime::CommandResult.new(success?: true, status: 0, stdout: "", stderr: "")
    end
  end

  def with_private_project(runtime = MockExecution.new)
    with_tmp_base do |_dir, env|
      env["SILO_MIGRATE_FORCE_LINUX"] = "1"
      root = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).init("acme")
      out = StringIO.new
      service = SiloMigrate::Services::TrustedWorkflowService.new(runtime: runtime, env: env, output: out)
      yield File.realpath(root), env, service, out, runtime
    end
  end

  def command_result(stdout: "", stderr: "", success: true, status: 0)
    SiloMigrate::Runtime::CommandResult.new(success?: success, status: status, stdout: stdout, stderr: stderr)
  end

  def assert_envelope(original, envelope)
    assert_equal "base64", envelope.fetch("encoding")
    assert_equal original.encoding.name, envelope.fetch("original_encoding")
    assert_equal original.bytesize, envelope.fetch("bytes")
    decoded = envelope.fetch("data").unpack1("m0")
    assert_equal original.b, decoded
    assert_equal Digest::SHA256.hexdigest(original.b), envelope.fetch("sha256")
  end

  def assert_private_error(code = nil)
    error = assert_raises(SiloMigrate::UsageError) { yield }
    assert_match(/\ATRUSTED_[A-Z_]+\z/, error.message)
    assert_equal code, error.message if code
    assert_nil error.cause
    refute_includes error.full_message, SECRET
    error
  end

  def test_all_raw_bytes_and_invalid_metadata_round_trip_privately_without_loss
    stdout = (0..255).to_a.pack("C*").force_encoding("UTF-8")
    stderr = ("\xFF\xFE\0".b + SECRET.b).force_encoding("UTF-16LE")
    reason = (SECRET.b + "\xFF\0".b).force_encoding("UTF-8")
    message = reason.dup.force_encoding("ASCII-8BIT")
    runtime = MockExecution.new(command_result(stdout: stdout, stderr: stderr))
    with_private_project(runtime) do |root, env, svc, out, execution|
      env["SILO_MIGRATE_ACTOR"] = reason
      result = svc.inspect("acme", reason: reason, message: message, command: ["synthetic-inspection", reason.b.delete("\0"), ""], as_finding: true)
      inspection = JSON.parse(File.binread(result.fetch(:inspection_path)))
      assert_equal 2, inspection.fetch("artifact_version")
      assert_envelope(stdout, inspection.fetch("stdout"))
      assert_envelope(stderr, inspection.fetch("stderr"))
      assert_envelope(reason, inspection.fetch("reason"))
      assert_envelope(message, inspection.fetch("message"))
      assert_equal 3, inspection.fetch("command").length
      assert_envelope("", inspection.fetch("command").last)
      audit = JSON.parse(File.binread(result.fetch(:audit_path)))
      assert_envelope(reason, audit.fetch("actor"))
      assert_equal "trusted_only", inspection.fetch("dev_visibility")
      assert_equal true, inspection.fetch("contains_raw_rows")
      assert_equal 1, execution.calls.length
      assert_equal 0o600, File.stat(result.fetch(:inspection_path)).mode & 0o777
      assert_equal 0o700, File.stat(File.join(root, "trusted/inspections")).mode & 0o777
      assert_equal 0o700, File.stat(File.join(root, "trusted/audit")).mode & 0o777
      refute result.key?(:result)
      refute_includes out.string, SECRET
      refute_includes out.string, root
      stub = YAML.safe_load(File.read(result.fetch(:finding_path)))
      refute_includes File.read(result.fetch(:finding_path)), SECRET
      assert_equal "trusted_only", stub.fetch("dev_visibility")
    end
  end

  def test_nonzero_inspection_keeps_output_privately_and_returns_only_a_fixed_failure
    runtime = MockExecution.new(command_result(stdout: SECRET, stderr: "\xFF".b, success: false, status: 7))
    with_private_project(runtime) do |root, _env, svc, out, _execution|
      assert_private_error("TRUSTED_INSPECT_COMMAND_FAILED") { svc.inspect("acme", reason: "synthetic", command: ["synthetic-inspection"]) }
      artifact = JSON.parse(File.read(Dir[File.join(root, "trusted/inspections/*.json")].fetch(0)))
      assert_envelope(SECRET, artifact.fetch("stdout"))
      assert_envelope("\xFF".b, artifact.fetch("stderr"))
      assert_equal false, artifact.fetch("success")
      assert_equal 7, artifact.fetch("exit_status")
      assert_equal 2, Dir[File.join(root, "trusted/audit/*.json")].length
      assert_empty out.string
    end
  end

  def test_signal_killed_results_preserve_inspection_and_session_bytes
    %w[inspect snapshot launch].each do |stage|
      killed = command_result(stdout: SECRET, stderr: "\xFF".b, success: nil, status: nil)
      runtime = stage == "launch" ? MockExecution.new(command_result, killed) : MockExecution.new(killed)
      with_private_project(runtime) do |root, _env, svc, out, execution|
        code = stage == "inspect" ? "TRUSTED_INSPECT_COMMAND_FAILED" : "TRUSTED_SESSION_#{stage.upcase}_FAILED"
        assert_private_error(code) do
          stage == "inspect" ? svc.inspect("acme", reason: SECRET, command: ["synthetic-inspection"]) : svc.session("acme", reason: SECRET)
        end
        files = stage == "inspect" ? Dir[File.join(root, "trusted/inspections/*.json")] : Dir[File.join(root, "trusted/session-results/*-#{stage}.json")]
        record = JSON.parse(File.read(files.fetch(0)))
        assert_equal false, record.fetch("success")
        assert_nil record.fetch("exit_status")
        assert_envelope(SECRET, record.fetch("stdout"))
        assert_envelope("\xFF".b, record.fetch("stderr"))
        assert_equal(stage == "launch" ? 2 : 1, execution.calls.length)
        assert_empty out.string
      end
    end
  end

  def test_nil_capture_is_distinct_from_captured_empty_bytes
    runtime = MockExecution.new(command_result(stdout: nil, stderr: ""))
    with_private_project(runtime) do |_root, _env, svc, _out, _execution|
      result = svc.inspect("acme", reason: "synthetic", command: ["synthetic-inspection"])
      record = JSON.parse(File.read(result.fetch(:inspection_path)))
      assert_nil record.fetch("stdout")
      assert_envelope("", record.fetch("stderr"))
    end
  end

  def test_runtime_exceptions_and_nested_causes_never_escape_inspect_or_session
    [IOError, NotImplementedError, SiloMigrate::UsageError, SiloMigrate::Services::TrustedWorkflowService::OperationError].each do |klass|
      %i[inspect session].each do |operation|
        error = begin
          begin
            raise EncodingError, SECRET
          rescue EncodingError
            raise klass, SECRET
          end
        rescue StandardError, ScriptError => caught
          caught
        end
        with_private_project(MockExecution.new(error)) do |root, _env, svc, out, _execution|
          assert_private_error("TRUSTED_#{operation.to_s.upcase}_FAILED") do
            if operation == :inspect
              svc.inspect("acme", reason: SECRET, command: ["synthetic-inspection"])
            else
              svc.session("acme", reason: SECRET)
            end
          end
          assert_empty out.string
          audits = Dir[File.join(root, "trusted/audit/*.json")]
          assert_equal 1, audits.length
          intent = JSON.parse(File.read(audits.first))
          assert_equal "requested", intent.dig("details", "status")
        end
      end
    end
  end

  def test_serialization_and_storage_exceptions_are_fixed_without_sensitive_causes
    %i[inspect session].each do |operation|
      with_private_project do |_root, _env, svc, out, execution|
        invoke = lambda do
          operation == :inspect ? svc.inspect("acme", reason: SECRET, command: ["synthetic-inspection"]) : svc.session("acme", reason: SECRET)
        end
        failure = ->(*) { raise JSON::GeneratorError, SECRET }
        JSON.stub(:pretty_generate, failure) do
          assert_private_error("TRUSTED_#{operation.to_s.upcase}_FAILED", &invoke)
        end
        failure = ->(*) { raise Errno::EIO, SECRET }
        svc.stub(:write_review_artifact, failure) do
          assert_private_error("TRUSTED_#{operation.to_s.upcase}_FAILED", &invoke)
        end
        assert_empty execution.calls
        assert_empty out.string
      end
    end
  end

  def test_session_snapshot_and_launch_outputs_are_captured_as_private_bytes
    invalid = (SECRET.b + "\xFF\0".b).force_encoding("UTF-8")
    runtime = MockExecution.new(command_result(stdout: invalid, stderr: "snapshot stderr"), command_result(stdout: "launch stdout", stderr: invalid))
    with_private_project(runtime) do |root, _env, svc, out, execution|
      result = svc.session("acme", reason: invalid, session_id: "private-session-name")
      snapshot = JSON.parse(File.read(result.fetch(:snapshot_path)))
      launch = JSON.parse(File.read(result.fetch(:launch_path)))
      assert_envelope(invalid, snapshot.fetch("stdout"))
      assert_envelope(invalid, launch.fetch("stderr"))
      assert_equal "snapshot", snapshot.fetch("stage")
      assert_equal "launch", launch.fetch("stage")
      assert_equal 2, execution.calls.length
      execution.calls.each { |_command, options| assert_equal true, options.fetch(:capture) }
      assert_equal %w[silo snapshot create], execution.calls.first.first.first(3)
      assert_equal %w[silo agent claude], execution.calls.last.first.first(3)
      audit = JSON.parse(File.read(result.fetch(:audit_path)))
      assert_envelope(invalid, audit.dig("details", "reason"))
      config = YAML.safe_load(File.read(result.fetch(:config_path)))
      refute_includes config.fetch("reason"), SECRET
      refute_includes File.read(result.fetch(:config_path)), SECRET
      snapshot_message = execution.calls.first.first.last
      refute_includes snapshot_message, "acme"
      refute_includes snapshot_message, "private-session-name"
      execution.calls.each { |_command, options| assert_equal true, options.fetch(:binary) }
      assert_equal "requested", audit.dig("details", "status")
      refute_includes out.string, "private-session-name"
      refute_includes out.string, SECRET
      refute_includes out.string, root
      %i[snapshot_path launch_path audit_path config_path].each do |key|
        assert_equal 0o600, File.stat(result.fetch(key)).mode & 0o777
      end
    end
  end

  def test_session_stage_failures_preserve_private_output_and_stop_the_next_stage
    %w[snapshot launch].each do |stage|
      failed = command_result(stdout: SECRET, stderr: "\xFF".b, success: false, status: 2)
      runtime = stage == "snapshot" ? MockExecution.new(failed) : MockExecution.new(command_result, failed)
      with_private_project(runtime) do |root, _env, svc, out, execution|
        assert_private_error("TRUSTED_SESSION_#{stage.upcase}_FAILED") { svc.session("acme", reason: SECRET) }
        assert_equal(stage == "snapshot" ? 1 : 2, execution.calls.length)
        artifact = JSON.parse(File.read(Dir[File.join(root, "trusted/session-results/*-#{stage}.json")].fetch(0)))
        assert_envelope(SECRET, artifact.fetch("stdout"))
        assert_envelope("\xFF".b, artifact.fetch("stderr"))
        assert_empty out.string
      end
    end
  end

  def test_validation_errors_and_missing_workspaces_do_not_execute_or_echo_values
    with_private_project do |_root, _env, svc, out, execution|
      [
        -> { svc.inspect("acme", reason: nil, command: ["synthetic"]) },
        -> { svc.inspect("acme", phase: SECRET, reason: "synthetic", command: ["synthetic"]) },
        -> { svc.inspect("acme", reason: "synthetic", command: ["synthetic", "\0"]) },
        -> { svc.inspect("acme", reason: SECRET, command: []) },
        -> { svc.session("acme", reason: SECRET, provider: SECRET) },
        -> { svc.session("acme", reason: SECRET, runtime: SECRET) },
        -> { svc.session("acme", reason: SECRET, session_id: "../#{SECRET}") },
        -> { svc.session("missing-private-workspace", reason: SECRET) },
        -> { svc.inspect("../private-workspace", reason: SECRET, command: ["synthetic"]) }
      ].each { |invoke| assert_private_error(&invoke) }
      assert_empty execution.calls
      assert_empty out.string
    end
  end

  def test_workspace_failures_have_the_specific_fixed_code_before_execution
    with_private_project do |root, _env, svc, out, execution|
      ["missing-private-workspace", "../private-workspace"].each do |customer|
        assert_private_error("TRUSTED_WORKSPACE_INVALID") { svc.inspect(customer, reason: SECRET, command: ["synthetic"]) }
        assert_private_error("TRUSTED_WORKSPACE_INVALID") { svc.session(customer, reason: SECRET) }
      end
      File.unlink(File.join(root, "config.env"))
      assert_private_error("TRUSTED_WORKSPACE_INVALID") { svc.inspect("acme", reason: SECRET, command: ["synthetic"]) }
      assert_private_error("TRUSTED_WORKSPACE_INVALID") { svc.session("acme", reason: SECRET) }
      assert_empty execution.calls
      assert_empty out.string
    end
  end

  def test_private_destination_symlinks_are_rejected_before_execution
    with_private_project do |root, _env, svc, out, execution|
      clone = File.join(root, "discourse-converters")
      FileUtils.mkdir_p(clone)
      File.symlink(clone, File.join(root, "trusted"))
      assert_private_error { svc.inspect("acme", reason: SECRET, command: ["synthetic-inspection"]) }
      assert_private_error { svc.session("acme", reason: SECRET) }
      assert_empty execution.calls
      assert_empty Dir.children(clone)
      assert_empty out.string
    end
  end

  def test_repeated_same_timestamp_inspections_do_not_overwrite_any_private_artifact
    with_private_project do |_root, _env, svc, _out, _execution|
      results = 2.times.map { svc.inspect("acme", reason: "synthetic", command: ["synthetic-inspection"], timestamp: Time.utc(2026, 1, 1)) }
      assert_equal 2, results.map { |result| result.fetch(:inspection_path) }.uniq.size
      assert_equal 2, results.map { |result| result.fetch(:audit_path) }.uniq.size
    end
  end

  def test_output_errors_are_sanitized_and_raw_records_are_not_published
    with_private_project do |root, env, svc, out, _execution|
      FileUtils.mkdir_p(File.join(root, "discourse-converters"))
      out.define_singleton_method(:puts) { |*| raise IOError, SECRET }
      assert_private_error("TRUSTED_INSPECT_FAILED") { svc.inspect("acme", reason: SECRET, command: ["synthetic-inspection"]) }
      assert_equal 1, Dir[File.join(root, "trusted/inspections/*.json")].size
      result = SiloMigrate::Services::AIWorkspaceService.new(env: env, output: StringIO.new).prepare("acme")
      assert_empty result.fetch("artifacts")
      svc = SiloMigrate::Services::TrustedWorkflowService.new(runtime: MockExecution.new, env: env, output: StringIO.new)
      session = svc.session("acme", reason: SECRET)
      assert File.exist?(session.fetch(:launch_path))
      result = SiloMigrate::Services::AIWorkspaceService.new(env: env, output: StringIO.new).prepare("acme")
      assert_empty result.fetch("artifacts")
      text = Dir.glob("**/*", base: File.join(root, "discourse-converters/safe-artifacts")).select { |file| File.file?(File.join(root, "discourse-converters/safe-artifacts", file)) }.map { |file| File.read(File.join(root, "discourse-converters/safe-artifacts", file)) }.join
      refute_includes text, SECRET
    end
  end
end
