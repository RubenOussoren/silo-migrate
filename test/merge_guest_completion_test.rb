# frozen_string_literal: true
require_relative "standard_merge_validation_lifecycle_test"
require "open3"
require "rbconfig"

class MergeGuestCompletionTest < SiloMigrateTest
  IMPLEMENTATION = SiloMigrate::Services::StandardMergeValidation
  PRIVATE = "PRIVATE /customer/settings.yml password=NEVER_ECHO"

  def setup
    @directory = Dir.mktmpdir
    klass = Class.new(MergeValidationTransportTest::Host) { prepend IMPLEMENTATION }
    @host = klass.new(@directory)
    @host.define_singleton_method(:merge_validation_context!) do |**options|
      MergeValidationTransportTest::Host.instance_method(:merge_validation_context!).bind_call(self, **options)
    end
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def execute(&block)
    @host.stack.define_singleton_method(:discourse_shell) do |args, **options|
      raise "missing wrapper" unless args.first(3) == ["sh", "-c", IMPLEMENTATION::VALIDATION_GUEST_WRAPPER]
      block.call(args.fetch(3), options)
    end
    @host.validate
  end

  def result(status:, stdout:, stderr: PRIVATE)
    OpenStruct.new(success?: status == 0, status: status, stdout: stdout, stderr: stderr)
  end

  def frame(token, status)
    "\nSILO_VALIDATION_GUEST_DONE:#{token}:#{status}\n"
  end

  def drops
    @host.runtime.calls.select { |_, options| options[:stdin_data].to_s.include?("DROP DATABASE") }
  end

  def test_pre_guest_host_failure_preserves_fixed_boundary_and_class_without_message
    @host.define_singleton_method(:merger_layer!) { |*| raise Errno::EACCES, PRIVATE }
    answer = @host.validate
    assert_equal "refused", answer["status"]
    assert_equal true, answer["cleanup_confirmed"]
    assert_equal "private_staging", answer.dig("diagnostics", "work", "step")
    assert_equal "Errno::EACCES", answer.dig("diagnostics", "work", "error_class")
    projection = @host.merge_validation_status(attempt: answer.fetch("receipt_id"))
    assert_equal "private_staging", projection.dig("work", "stage")
    assert_equal "Errno::EACCES", projection.dig("work", "error_class")
    refute_includes JSON.generate(answer), PRIVATE
    refute_includes JSON.generate(projection), PRIVATE
  end

  def test_real_wrapper_waits_for_child_and_echoes_only_nonce_and_actual_exit_status
    token = "a" * 32
    stdout, stderr, status = Open3.capture3("sh", "-c", IMPLEMENTATION::VALIDATION_GUEST_WRAPPER,
      token, RbConfig.ruby, "-e", 'STDOUT.write("invented"); exit 7')
    assert_equal 7, status.exitstatus
    assert_equal "invented" + frame(token, 7), stdout
    assert_empty stderr
  end

  def test_known_bootstrap_refusal_cleans_but_never_passes_and_retains_only_fixed_guard_tag
    answer = execute { |token, _| result(status: 1, stdout: frame(token, 1), stderr: PRIVATE + " STANDARD_MERGE_VALIDATION_CONFIG") }
    assert_equal "refused", answer["status"]
    assert_equal "STANDARD_MERGE_VALIDATION_UNPROVEN", answer["primary_reason"]
    assert_equal "failed", answer.dig("diagnostics", "work", "command_outcome")
    assert_equal "completed", answer["producer_outcome"]
    assert_equal true, answer["cleanup_confirmed"]
    assert_equal "bootstrap", answer.dig("guest_diagnostic", "stage")
    assert_equal "validation_config", answer.dig("guest_diagnostic", "component")
    assert_nil answer["binding"]
    refute_empty drops
    projection = @host.merge_validation_status(attempt: answer.fetch("receipt_id"))
    assert_equal answer["guest_diagnostic"], projection["guest_diagnostic"]
    refute_includes JSON.generate(answer), PRIVATE
    refute_includes JSON.generate(projection), PRIVATE
  end

  def test_known_bootstrap_exit_preserves_only_the_validated_typed_prefix
    diagnostic = { "version" => 1, "stage" => "connections", "error_class" => "PG::ConnectionBad", "component" => "validation_config", "line" => 108 }
    answer = execute do |token, _|
      stderr = PRIVATE + "\nSILO_MERGE_BOOTSTRAP_DIAGNOSTIC:#{JSON.generate(diagnostic)}\nSTANDARD_MERGE_VALIDATION_CONFIG\n"
      result(status: 1, stdout: frame(token, 1), stderr: stderr)
    end
    assert_equal diagnostic, answer["guest_diagnostic"]
    assert_equal "refused", answer["status"]
    assert_equal true, answer["cleanup_confirmed"]
    refute_includes JSON.generate(answer), PRIVATE
  end

  def test_bootstrap_prefix_parser_rejects_ambiguous_oversized_or_private_payloads_without_runtime_calls
    diagnostic = { "version" => 1, "stage" => "unknown", "error_class" => "other", "component" => "unknown", "line" => nil }
    prefix = "SILO_MERGE_BOOTSTRAP_DIAGNOSTIC:"
    good = prefix + JSON.generate(diagnostic) + "\n"
    [good + good, prefix + JSON.generate(diagnostic.merge("message" => PRIVATE)),
     prefix + JSON.generate(diagnostic.merge("error_class" => PRIVATE)), prefix + "{" + PRIVATE,
     prefix + JSON.generate(diagnostic.merge("component" => "custom_layer", "line" => 3)),
     "x" * (64 * 1024 + 1) + good, prefix + "\xFF".b].each do |stderr|
      value = @host.send(:mv_bootstrap_diagnostic, stderr)
      assert_equal diagnostic, value
      refute_includes JSON.generate(value), PRIVATE
    end
    assert_empty @host.runtime.calls
  end

  def test_unknown_or_substituted_terminal_frames_never_cleanup
    [nil, "f" * 32, :wrong_status].each do |kind|
      Dir.mktmpdir do |directory|
        setup_host = @host
        setup_directory = @directory
        @directory = directory
        klass = Class.new(MergeValidationTransportTest::Host) { prepend IMPLEMENTATION }
        @host = klass.new(directory)
        @host.define_singleton_method(:merge_validation_context!) do |**options|
          MergeValidationTransportTest::Host.instance_method(:merge_validation_context!).bind_call(self, **options)
        end
        answer = execute do |token, _|
          suffix = kind.nil? ? "" : frame(kind == :wrong_status ? token : kind, kind == :wrong_status ? 0 : 1)
          result(status: 1, stdout: suffix)
        end
        assert_equal "unknown", answer["producer_outcome"]
        assert_equal false, answer["cleanup_confirmed"]
        assert_empty drops
      ensure
        @host = setup_host
        @directory = setup_directory
      end
    end
  end

  def test_malformed_or_invalid_utf8_envelope_from_known_exited_child_is_clean_failed_work
    ["NOT A RESULT #{PRIVATE}", "\xFF".b].each do |bytes|
      answer = execute { |token, _| result(status: 4, stdout: bytes + frame(token, 4)) }
      assert_equal "refused", answer["status"]
      assert_equal "STANDARD_MERGE_VALIDATION_PROTOCOL", answer["primary_reason"]
      assert_equal "completed", answer["producer_outcome"]
      assert_equal true, answer["cleanup_confirmed"]
      assert_nil answer["binding"]
      refute_includes JSON.generate(answer), PRIVATE
    end
  end
end
