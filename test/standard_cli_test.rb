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

  def test_runtime_catalog_and_converter_commands_use_strict_new_grammar
    with_standard do
      @runtime.images_match = true
      code, output, error = invoke(%w[runtime list])
      assert_equal 0, code
      assert_empty error
      assert_equal true, JSON.parse(output).fetch('profiles').first.fetch('local_images_match')
      name = SiloMigrate::RuntimeProfiles::DEFAULT
      code, output, error = invoke(['runtime', 'show', name])
      assert_equal 0, code
      assert_equal name, JSON.parse(output).fetch('name')
      assert_equal 0, invoke(%w[converter status synthetic]).first
      assert_equal 0, invoke(%w[converter refresh synthetic]).first
      assert_equal 0, invoke(%w[converter refresh synthetic --if-changed]).first
      assert_equal 1, invoke(%w[converter refresh synthetic --if-changed extra]).first
      assert_equal 1, invoke(%w[converter status synthetic --if-changed]).first
      assert_equal 1, invoke(%w[runtime list extra]).first
      assert_equal 1, invoke(%w[converter fetch synthetic]).first
      assert_equal 1, invoke(%w[init synthetic --converter-revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa]).first
      @runtime.converter_dirty = true
      code, output, error = invoke(%w[converter refresh synthetic])
      assert_equal 1, code
      assert_empty output
      assert_includes error, 'STANDARD_CONVERTER_DIRTY'
      assert_includes error, 'development branch'
      assert_includes error, 'standard converter refresh'
    end
  end

  def test_engineer_override_is_recorded_and_agent_cannot_supply_it
    with_standard do
      args = ['plan', 'propose', 'synthetic', '--dataset', @dataset, '--allow-unqualified-runtime']
      code, output, error = invoke(args)
      assert_equal 0, code
      assert_empty error
      assert_equal true, JSON.parse(output).fetch('allow_unqualified_runtime')
      assert_equal true, JSON.parse(output).fetch('runtime_qualified')
      assert_equal 1, invoke(['agent', 'plan-propose', 'synthetic', '--dataset', @dataset, '--allow-unqualified-runtime']).first
      assert_equal 1, invoke(args + ['--allow-unqualified-runtime']).first
    end
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

  def test_failed_run_start_and_execute_emit_json_and_exit_one
    with_standard do
      [%w[run start], %w[agent run-execute]].each do |prefix|
        plan = approve
        # Services created by CLI use real port probes; inject a service whose
        # probes, disk measurements and runtime are all deterministic fakes.
        out = StringIO.new
        err = StringIO.new
        cli = SiloMigrate::StandardCLI.new(env: @env, output: out, error: err)
        cli.stub(:service, new_standard) do
          identifier = prefix == %w[run start] ? plan[:plan_id] : claim(plan)
          assert_equal 1, cli.run(prefix + ['synthetic', identifier])
        end
        assert_empty err.string
        result = JSON.parse(out.string)
        assert_equal 'failed', result.fetch('status')
        assert_equal 'STANDARD_RUNTIME_MISMATCH', result.fetch('failure').fetch('code')
        assert_equal 1, out.string.lines.size
      end
    end
  end
  def test_removed_agent_run_request_is_refused_without_consuming_plan
    with_standard do
      plan = approve
      code, out, err = invoke(['agent', 'run-request', 'synthetic', plan[:plan_id]])
      assert_equal 1, code
      assert_empty out
      assert_equal "Error: STANDARD_ARGUMENTS_INVALID\n", err
      assert_equal 'approved', @service.show_plan(plan[:plan_id])[:status]
      assert_empty @service.store.load['runs']
    end
  end

  def test_agent_claim_then_execute_returns_structured_state_and_failed_exit
    with_standard do
      plan = approve
      out = StringIO.new
      err = StringIO.new
      cli = SiloMigrate::StandardCLI.new(env: @env, output: out, error: err)
      cli.stub(:service, new_standard) do
        assert_equal 0, cli.run(['agent', 'run-claim', 'synthetic', plan[:plan_id]])
        claimed = JSON.parse(out.string)
        assert_equal 'claimed', claimed.fetch('status')
        assert_match(/\Arun-[0-9a-f]{32}\z/, claimed.fetch('run_id'))
        assert_equal plan[:plan_id], claimed.fetch('plan_id')
        assert_empty err.string
        assert_equal 'claimed', new_standard.show_run(claimed['run_id'])[:status]
        out.truncate(0)
        out.rewind
        assert_equal 1, cli.run(['agent', 'run-execute', 'synthetic', claimed['run_id']])
        run = JSON.parse(out.string)
        assert_equal claimed['run_id'], run.fetch('run_id')
        assert_equal 'failed', run.fetch('status')
        assert_equal 'STANDARD_RUNTIME_MISMATCH', run.fetch('failure').fetch('code')
        assert_empty err.string
      end
    end
  end

end
