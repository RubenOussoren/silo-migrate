# frozen_string_literal: true
require_relative 'standard_workflow_test'
require 'silo_migrate/standard_cli'

class StandardCLITest < SiloMigrateTest
  include StandardTestWorkspace

  def invoke(args)
    output = StringIO.new
    error = StringIO.new
    cli = SiloMigrate::StandardCLI.new(env: @env, runtime: @runtime, code_root: @code_root, output: output, error: error)
    [cli.run(args), output.string, error.string]
  end

  def test_status_is_single_json_document
    with_standard do
      code, output, error = invoke(%w[status synthetic])
      assert_equal 0, code
      assert_empty error
      result = JSON.parse(output)
      assert_equal 1, result.fetch('version')
      assert_equal [], result.fetch('runs')
      assert_equal 1, output.lines.size
    end
  end

  def test_strict_grammar_and_unknown_options
    with_standard do
      [ %w[unknown synthetic], %w[status], %w[status synthetic extra], %w[status synthetic --help],
        %w[plan], %w[plan show synthetic], %w[run reset synthetic run-id], %w[run show synthetic run-id extra],
        ['plan', 'propose', 'synthetic', '--dataset', @dataset, '--unknown', 'value'],
        ['plan', 'propose', 'synthetic', '--dataset', @dataset, '--dataset', @dataset],
        ['plan', 'propose', 'synthetic', '--data', @dataset],
        ['plan', 'propose', 'synthetic', '--dataset', @dataset, '--ports', '1;2'],
        ['agent', 'status', 'synthetic', '--unknown'], ['status', nil], ['status', "\xff".b.force_encoding('UTF-8')]
      ].each do |args|
        code, out, err = invoke(args)
        assert_equal 1, code, args.inspect
        assert_empty out
        assert_equal "Error: STANDARD_ARGUMENTS_INVALID\n", err
      end
    end
  end

  def test_fixed_standard_error_does_not_print_private_detail
    with_standard do
      private_text = 'PRIVATE-EXCEPTION-8cb2f4'
      service = Object.new
      service.define_singleton_method(:status) { raise SiloMigrate::StandardWorkflowError.new('STANDARD_INPUT_CHANGED', private_text) }
      output = StringIO.new
      error = StringIO.new
      cli = SiloMigrate::StandardCLI.new(env: @env, output: output, error: error)
      cli.stub(:service, service) { assert_equal 1, cli.run(%w[status synthetic]) }
      assert_empty output.string
      assert_equal "Error: STANDARD_INPUT_CHANGED\n", error.string
      refute_includes error.string, private_text
    end
  end

  def test_unexpected_exception_is_fixed_operation_error
    with_standard do
      output = StringIO.new
      error = StringIO.new
      cli = SiloMigrate::StandardCLI.new(env: @env, output: output, error: error)
      cli.stub(:service, ->(_workspace) { raise 'PRIVATE RAW EXCEPTION /secret/path' }) do
        assert_equal 1, cli.run(%w[status synthetic])
      end
      assert_empty output.string
      assert_equal "Error: STANDARD_OPERATION_FAILED\n", error.string
    end
  end

  def test_failed_run_start_and_agent_request_emit_json_and_exit_one
    with_standard do
      [%w[run start], %w[agent run-request]].each do |prefix|
        plan = approve
        # Services created by CLI use real port probes; inject a service whose
        # probes, disk measurements and runtime are all deterministic fakes.
        out = StringIO.new
        err = StringIO.new
        cli = SiloMigrate::StandardCLI.new(env: @env, output: out, error: err)
        cli.stub(:service, new_standard) do
          assert_equal 1, cli.run(prefix + ['synthetic', plan[:plan_id]])
        end
        assert_empty err.string
        result = JSON.parse(out.string)
        assert_equal 'failed', result.fetch('status')
        assert_equal 'STANDARD_RUNTIME_MISMATCH', result.fetch('failure').fetch('code')
        assert_equal 1, out.string.lines.size
      end
    end
  end
end
