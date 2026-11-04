# frozen_string_literal: true

require_relative "test_helper"

# Exercise the capture adapter with mocked pipes/wait status, never a process.
class TrustedCaptureContractTest < SiloMigrateTest
  SECRET = "sensitive-reader-canary@example.test"

  class MockPipe
    attr_reader :binary, :reporting

    def initialize(bytes, failure: false)
      @bytes = bytes
      @failure = failure
      @binary = false
    end

    def binmode
      @binary = true
      self
    end

    def read
      @reporting = Thread.current.report_on_exception
      raise IOError, SECRET if @failure

      binary ? @bytes.b : @bytes.dup.force_encoding(Encoding::UTF_8)
    end
  end

  def with_capture(stdout:, stderr:, success: true, status: 0, reader_failure: false)
    out = MockPipe.new(stdout, failure: reader_failure)
    err = MockPipe.new(stderr)
    stdin = StringIO.new
    process_status = Object.new
    process_status.define_singleton_method(:success?) { success }
    process_status.define_singleton_method(:exitstatus) { status }
    wait = Struct.new(:pid, :value).new(12345, process_status)
    calls = []
    mock = lambda do |*command, **options, &block|
      calls << [command, options]
      block.call(stdin, out, err, wait)
    end
    Open3.stub(:popen3, mock) { yield out, err, stdin, calls }
  end

  def test_opt_in_binary_capture_sets_pipe_modes_without_changing_default_capture
    with_capture(stdout: "synthetic", stderr: "") do |out, err, stdin, calls|
      result = SiloMigrate::Runtime::Docker.new.run(["synthetic-no-process"], capture: true)
      assert_equal "synthetic", result.stdout
      refute out.binary
      refute err.binary
      assert stdin.closed?
      assert_equal 1, calls.length
    end
    invalid = "\xFF\0".b
    with_capture(stdout: invalid, stderr: invalid) do |out, err, stdin, calls|
      result = SiloMigrate::Runtime::Docker.new.run(["synthetic-no-process"], capture: true, binary: true)
      assert_equal invalid, result.stdout
      assert_equal invalid, result.stderr
      assert_equal Encoding::BINARY, result.stdout.encoding
      assert_equal Encoding::BINARY, result.stderr.encoding
      assert out.binary
      assert err.binary
      assert_equal false, out.reporting
      assert_equal false, err.reporting
      assert stdin.closed?
      assert_equal 1, calls.length
    end
  end

  def test_private_inspection_uses_binary_capture_and_preserves_signal_killed_bytes
    with_tmp_base do |_dir, env|
      root = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).init("acme")
      output = StringIO.new
      service = SiloMigrate::Services::TrustedWorkflowService.new(runtime: SiloMigrate::Runtime::Docker.new, env: env, output: output)
      bytes = "\xFF\0".b + SECRET.b
      with_capture(stdout: bytes, stderr: bytes, success: nil, status: nil) do |out, err, _stdin, calls|
        failure = assert_raises(SiloMigrate::UsageError) { service.inspect("acme", reason: "synthetic", command: ["synthetic-no-process"]) }
        assert_equal "TRUSTED_INSPECT_COMMAND_FAILED", failure.message
        assert_nil failure.cause
        assert out.binary
        assert err.binary
        assert_equal 1, calls.length
      end
      record = JSON.parse(File.read(Dir[File.join(root, "trusted/inspections/*.json")].fetch(0)))
      assert_equal bytes, record.fetch("stdout").fetch("data").unpack1("m0")
      assert_equal bytes, record.fetch("stderr").fetch("data").unpack1("m0")
      assert_equal false, record.fetch("success")
      assert_nil record.fetch("exit_status")
      assert_empty output.string
    end
  end

  def test_reader_thread_errors_cannot_report_private_values_to_global_stderr
    with_tmp_base do |_dir, env|
      SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new).init("acme")
      service = SiloMigrate::Services::TrustedWorkflowService.new(runtime: SiloMigrate::Runtime::Docker.new, env: env, output: StringIO.new)
      actual_out, actual_err = capture_io do
        with_capture(stdout: "", stderr: "", reader_failure: true) do |out, _err, _stdin, _calls|
          failure = assert_raises(SiloMigrate::UsageError) { service.inspect("acme", reason: "synthetic", command: ["synthetic-no-process"]) }
          assert_equal "TRUSTED_INSPECT_FAILED", failure.message
          assert_nil failure.cause
          refute_includes failure.full_message, SECRET
          assert_equal false, out.reporting
        end
      end
      assert_empty actual_out
      assert_empty actual_err
    end
  end

  def test_binary_mode_cannot_dispatch_an_attached_process
    runtime = SiloMigrate::Runtime::Docker.new
    runtime.stub(:run_attached, ->(*) { flunk "attached execution must never be reached" }) do
      assert_raises(SiloMigrate::UsageError) { runtime.run(["synthetic-no-process"], binary: true) }
    end
    fake = SiloMigrate::Runtime::Fake.new
    fake.run(["synthetic-no-process"], capture: true, binary: true)
    assert_equal true, fake.last_run_options.fetch(:binary)
  end
end
