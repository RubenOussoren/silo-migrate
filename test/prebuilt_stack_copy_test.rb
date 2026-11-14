# frozen_string_literal: true
require_relative "test_helper"
require "ostruct"
require "silo_migrate/services/prebuilt_stack"

# Scripted commands and a deterministic monotonic clock; no Docker access.
class PrebuiltStackCopyTest < Minitest::Test
  def with_stack
    calls = []
    runtime = Object.new
    runtime.define_singleton_method(:run) do |argv, **options|
      calls << [argv, options]
      OpenStruct.new(success?: true)
    end
    stack = SiloMigrate::Services::PrebuiltStack.new(runtime: runtime, lock: {}, name: "invented")
    yield stack, calls
  end

  def test_explicit_copy_budget_is_shared_with_ownership_command
    with_stack do |stack, calls|
      clock = [100.0, 118.25]
      Process.stub(:clock_gettime, ->(*) { clock.shift }) do
        stack.copy_in("/invented/source", "/shared/invented", timeout: 30)
      end
      assert_equal [30, 11.75], calls.map { |_, options| options.fetch(:timeout) }
      assert_equal %w[docker exec invented-web chown -R discourse:discourse /shared/invented], calls.last.first
    end
  end

  def test_expired_copy_budget_does_not_start_another_subprocess
    with_stack do |stack, calls|
      clock = [100.0, 130.0]
      error = Process.stub(:clock_gettime, ->(*) { clock.shift }) do
        assert_raises(SiloMigrate::StandardWorkflowError) do
          stack.copy_in("/invented/source", "/shared/invented", timeout: 30)
        end
      end
      assert_equal "STANDARD_STACK_FAILED", error.code
      assert_equal 1, calls.size
    end
  end

  def test_unbudgeted_copy_keeps_existing_timeout_defaults
    with_stack do |stack, calls|
      stack.copy_in("/invented/source", "/shared/invented")
      assert_equal [300, 60], calls.map { |_, options| options.fetch(:timeout) }
      stack.copy_out("/shared/invented", "/invented/result", timeout: 7)
      assert_equal 7, calls.last.last.fetch(:timeout)
    end
  end
end
