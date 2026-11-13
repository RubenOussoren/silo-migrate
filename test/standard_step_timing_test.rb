# frozen_string_literal: true
require_relative 'standard_merge_preparation_test'

# Invented data and scripted runtime only. The production process-drain tests live
# in standard_merge_preparation_test; here we verify ordering, timings and plans.
class StandardStepTimingTest < StandardMergePreparationTest
  def self.runnable_methods
    public_instance_methods.grep(/^test_performance_/).map(&:to_s)
  end

  def test_performance_prepare_records_fixed_step_timings_and_preserves_worker_configuration
    with_prepare do
      run = prepared
      timings = run.dig(:results, 'step_timings_ms')
      assert_equal SiloMigrate::Services::StandardWorkflowService::STEP_TIMING_NAMES.sort, timings.keys.sort
      assert timings.values.all? { |value| value.is_a?(Integer) && value >= 0 }
      web = @runtime.calls.find { |cmd| cmd[0, 2] == %w[docker run] && cmd.include?('UNICORN_SIDEKIQS=1') }
      refute_nil web
      refute_includes web, 'UNICORN_SIDEKIQS=0'
      early = index_of(/SILO_QUIESCED/)
      restore = index_of(/script\/discourse restore/)
      assert_operator early, :<, restore
      app_up = index_of(/sv up unicorn/)
      assert_operator restore, :<, app_up
      assert_operator app_up, :<, index_of(/CREATE DATABASE merge_source/)
      refute_includes JSON.generate(timings), 'customer-secret'
      refute_includes JSON.generate(timings), '/shared/'
    end
  end

  def test_performance_bad_quiesce_fails_before_base_restore_and_keeps_timing
    with_prepare do
      @runtime.quiesce_result = SiloMigrate::Runtime::CommandResult.new(success?: false, status: 2,
        stdout: "SILO_QUIESCE: reason=workers_timeout workers=1\n", stderr: '')
      run = run_prepare
      assert_equal 'failed', run[:status]
      assert_equal 'failed', run.dig(:stages, 'site_up')
      assert_equal 'pending', run.dig(:stages, 'base_restore')
      assert_equal 'STANDARD_STACK_FAILED', run.dig(:failure, 'code')
      assert run.dig(:results, 'step_timings_ms', 'workers.pre_restore').is_a?(Integer)
      refute merge_lines.any? { |line| line.include?('script/discourse restore') }
      refute merge_lines.any? { |line| line.include?('CREATE DATABASE merge_source') }
      assert_equal 'dirty', environment(run[:run_id])['phase']
    end
  end

  def test_performance_timing_survives_a_failure_and_projection_drops_unknown_fields
    with_prepare do
      id = @service.claim(plan_id: approve(prepare_plan)).fetch(:run_id)
      standard_error('STANDARD_STACK_FAILED') do
        @service.send(:measure_run_step, id, 'base.hash') do
          raise SiloMigrate::StandardWorkflowError.new('STANDARD_STACK_FAILED', 'INVENTED-PRIVATE-EXCEPTION')
        end
      end
      assert_equal 42, @service.send(:measure_run_step, id, 'base.copy') { 42 }
      standard_error('STANDARD_INTERNAL') { @service.send(:measure_run_step, id, 'INVENTED-PRIVATE-LABEL') { flunk } }
      @service.store.update do |state|
        timings = state.fetch('runs').fetch(id).fetch('results').fetch('step_timings_ms')
        timings['INVENTED-PRIVATE-LABEL'] = 1
        timings['base.restore'] = 'INVENTED-PRIVATE-VALUE'
        timings['base.inventory'] = -1
        timings['source.load'] = Float::INFINITY.to_s
        timings['source.migrate'] = true
        timings['source.copy_dump'] = SiloMigrate::Services::StandardWorkflowService::MAX_STEP_TIMING_MS + 1
      end
      shown = @service.show_run(id).dig(:results, 'step_timings_ms')
      assert_equal %w[base.copy base.hash], shown.keys.sort
      refute_includes JSON.generate(shown), 'INVENTED-PRIVATE'
    end
  end

  def test_performance_timing_storage_failure_never_masks_the_step_outcome
    with_prepare do
      id = @service.claim(plan_id: approve(prepare_plan)).fetch(:run_id)
      store = @service.store
      store.define_singleton_method(:update) { |&_block| raise IOError, 'invented telemetry store failure' }
      standard_error('STANDARD_STACK_FAILED') do
        @service.send(:measure_run_step, id, 'base.hash') { raise SiloMigrate::StandardWorkflowError, 'STANDARD_STACK_FAILED' }
      end
      assert_equal 42, @service.send(:measure_run_step, id, 'base.copy') { 42 }
      store.singleton_class.send(:remove_method, :update)
    end
  end

  def test_performance_bound_large_restore_timeout_reaches_the_runner
    with_prepare do
      @service.define_singleton_method(:host_capacity) { [8, 128 * 1024] }
      original_limits = @service.method(:review_limits)
      @service.define_singleton_method(:review_limits) do |input_bytes: 0|
        original_limits.call(input_bytes: 4 * 1024**3)
      end
      observed = []
      original_run = @runtime.method(:run)
      @runtime.define_singleton_method(:run) do |cmd, **options|
        observed << [cmd, options]
        original_run.call(cmd, **options)
      end
      plan = prepare_plan
      timeout = plan.dig(:limits, 'db', 'restore_timeout_seconds')
      assert_operator timeout, :>, 1200
      run = run_prepare(plan)
      assert_equal 'completed', run[:status], failure_detail(run)
      restore = observed.find { |cmd, _options| cmd.join(' ').include?('script/discourse restore') }
      refute_nil restore
      assert_equal timeout, restore.last[:timeout]
      # A prepared continuation carries the original limits; it does not silently resize.
      continuation = prepared_plan(run)
      assert_equal plan[:limits], continuation[:limits]
    end
  end
end
