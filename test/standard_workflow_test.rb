# frozen_string_literal: true
require_relative 'test_helper'
require 'silo_migrate/services/named_workspace_service'
require 'silo_migrate/services/standard_workflow_service'

# Scripted command results only; no subprocess, Docker socket or host port use.
class StandardScriptedRuntime < SiloMigrate::Runtime::Fake
  attr_accessor :high_usage, :ownership, :images_match, :import_failure
  def run(cmd, **options)
    result = super
    stdout = if cmd.first == 'df'
      "Avail\n107374182400\n"
    elsif cmd[0, 2] == %w[docker ps]
      high_usage ? "recorded-id\n" : ''
    elsif cmd.include?('{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}')
      "99000000000 999999999999\n"
    elsif cmd[0, 3] == %w[docker image inspect]
      images_match ? cmd.last : 'wrong-image'
    elsif cmd.include?('{{json .Config.Labels}}') || cmd.include?('{{json .Labels}}')
      JSON.generate('silo-migrate.managed' => 'true', 'silo-migrate.instance' => ownership)
    else
      result.stdout
    end
    failed = import_failure && cmd.join(' ').include?('generic_bulk.rb')
    SiloMigrate::Runtime::CommandResult.new(success?: !failed, stdout: stdout, stderr: failed ? import_failure : '', status: failed ? 1 : 0)
  end
end

# Shared synthetic fixture for the other new standard tests. All writes stay in
# with_tmp_base, including the code identity tree (never the read-only checkout).
module StandardTestWorkspace
  def with_standard
    with_tmp_base do |dir, env|
      @env = env
      @named = SiloMigrate::Services::NamedWorkspaceService.new(env: env)
      @named.init('synthetic')
      @root = File.join(env.fetch('SILO_MIGRATE_BASE_PATH'), 'synthetic')
      source = @named.add_source('synthetic', platform: 'synthetic')[:source_id]
      @dataset = @named.add_dataset('synthetic', source_id: source)[:dataset_id]
      @paths = {}
      %w[source-sql converter-settings expected].each do |type|
        @paths[type] = add_standard_input(type, "synthetic #{type}")
      end
      @code_root = File.join(dir, 'code')
      FileUtils.mkdir_p(File.join(@code_root, 'runtime'))
      FileUtils.cp_r(File.expand_path('../runtime/prebuilt-discourse', __dir__), File.join(@code_root, 'runtime'))
      write(File.join(@code_root, 'lib', 'identity.rb'), '# synthetic code identity')
      @runtime = StandardScriptedRuntime.new
      @service = new_standard
      settings = write(File.join(dir, 'site-settings.yml'), "title: Synthetic\n")
      converter = File.join(dir, 'converter')
      FileUtils.mkdir_p(converter)
      @service.init(converter_worktree: converter, converter_revision: 'a' * 40, site_settings: settings)
      yield
    end
  end

  def add_standard_input(type, bytes, name: type)
    relative = "inputs/#{name}"
    path = write(File.join(@root, relative), bytes)
    @named.add_input('synthetic', dataset_id: @dataset, path: relative, sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize, type: type)
    path
  end

  def new_standard(port_probe: ->(_port) { true })
    SiloMigrate::Services::StandardWorkflowService.new('synthetic', env: @env, runtime: @runtime, code_root: @code_root,
      port_probe: port_probe, disk_free: -> { 100 * 1024**3 }, sleeper: ->(_seconds) {})
  end

  def propose
    @service.propose_plan(dataset_id: @dataset)
  end

  def approve(plan = propose)
    @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'synthetic engineer')
    plan
  end

  def standard_error(code)
    error = assert_raises(SiloMigrate::StandardWorkflowError) { yield }
    assert_equal code, error.code
    error
  end

  def claim(plan = approve)
    @service.send(:claim_plan!, plan[:plan_id])
  end

  def attach_instance(run_id, state: 'dirty')
    name = 'synthetic-owned-instance'
    @service.store.update do |current|
      current['runs'].fetch(run_id)['instances']['review'] = name
      current['instances'][name] = { 'name' => name, 'role' => 'review', 'run_id' => run_id, 'state' => state, 'port' => 18000,
        'containers' => { 'web' => 'exact-container-id' }, 'networks' => ['exact-network-id'], 'volumes' => ['exact-volume-id'] }
    end
    name
  end
end

class StandardWorkflowTest < SiloMigrateTest
  include StandardTestWorkspace

  def test_propose_digest_requires_exact_approval
    with_standard do
      plan = propose
      assert_match(/\A[0-9a-f]{64}\z/, plan[:digest])
      assert_equal 'proposed', @service.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_NOT_APPROVED') { @service.run_plan(plan_id: plan[:plan_id]) }
      standard_error('STANDARD_APPROVAL_MISMATCH') { @service.approve_plan(plan_id: plan[:plan_id], sha256: '0' * 64, reviewer: 'engineer') }
      assert_equal 'proposed', @service.show_plan(plan[:plan_id])[:status]
      approve(plan)
      assert_equal 'approved', new_standard.show_plan(plan[:plan_id])[:status]
    end
  end

  %w[bytes mtime dataset code].each do |change|
    define_method("test_#{change}_change_invalidates_approval") do
      with_standard do
        plan = approve
        case change
        when 'bytes'
          path = @paths.fetch('source-sql')
          replacement = "#{path}.replacement"
          File.binwrite(replacement, 'changed input bytes')
          File.rename(replacement, path)
          File.utime(Time.now + 5, Time.now + 5, path)
        when 'mtime'
          path = @paths.fetch('source-sql')
          File.utime(Time.now + 5, Time.now + 5, path)
        when 'dataset' then add_standard_input('binary', 'extra', name: 'additional')
        when 'code' then File.write(File.join(@code_root, 'lib', 'identity.rb'), '# changed code')
        end
        assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
        standard_error('STANDARD_STALE_PLAN') { @service.run_plan(plan_id: plan[:plan_id]) }
        assert_empty @service.store.load['runs']
      end
    end
  end

  def test_input_change_refuses_approval_before_any_run_is_claimed
    with_standard do
      plan = propose
      path = @paths.fetch('source-sql')
      File.utime(Time.now + 5, Time.now + 5, path)
      standard_error('STANDARD_STALE_PLAN') { approve(plan) }
      assert_empty @service.store.load['runs']
    end
  end

  def test_changed_input_cannot_consume_an_approved_plan
    with_standard do
      plan = approve
      path = @paths.fetch('source-sql')
      File.binwrite(path, 'replacement source SQL')
      File.utime(Time.now + 5, Time.now + 5, path)
      standard_error('STANDARD_STALE_PLAN') { @service.run_plan(plan_id: plan[:plan_id]) }
      assert_empty @service.store.load['runs']
      assert_equal 'approved', @service.store.load['plans'][plan[:plan_id]]['status']
    end
  end

  def test_run_is_consumed_even_when_first_stage_fails
    with_standard do
      plan = approve
      run = @service.run_plan(plan_id: plan[:plan_id])
      assert_equal 'failed', run[:status]
      assert_equal 'preflight', run[:stage]
      assert_equal 'failed', run[:stages]['preflight']
      assert_equal 'pending', run[:stages]['convert']
      assert_equal 'STANDARD_RUNTIME_MISMATCH', run[:failure]['code']
      assert_equal SiloMigrate::Services::StandardWorkflowService::RECOVERY['STANDARD_RUNTIME_MISMATCH'], run[:failure]['recovery']
      assert_equal run, new_standard.show_run(run[:run_id])
      standard_error('STANDARD_PLAN_CONSUMED') { @service.run_plan(plan_id: plan[:plan_id]) }
    end
  end

  def test_operation_lock_refuses_execution_and_recovery
    with_standard do
      plan = approve
      run_id = claim(plan)
      @service.store.with_op_lock do
        standard_error('STANDARD_BUSY') { new_standard.run_plan(plan_id: plan[:plan_id]) }
        standard_error('STANDARD_BUSY') { new_standard.recover(run_id: run_id) }
        assert_equal 'running', new_standard.show_run(run_id)[:status]
        assert new_standard.status[:executor_active]
      end
    end
  end

  def test_abandoned_run_survives_new_service_and_requires_recovery
    with_standard do
      run_id = claim
      name = attach_instance(run_id, state: 'ready')
      reopened = new_standard
      assert_equal 'abandoned', reopened.show_run(run_id)[:status]
      assert_includes reopened.show_run(run_id)[:recovery], 'run recover'
      assert_equal 'abandoned', reopened.status[:runs].first[:status]
      recovered = reopened.recover(run_id: run_id)
      assert_equal 'interrupted', recovered[:status]
      assert_equal 'STANDARD_INTERRUPTED', recovered[:failure]['code']
      assert_equal 'dirty', new_standard.store.load['instances'][name]['state']
      standard_error('STANDARD_TRANSITION_INVALID') { new_standard.recover(run_id: run_id) }
    end
  end

  def test_dirty_instance_refuses_new_run
    with_standard do
      first = claim
      attach_instance(first)
      second = approve
      standard_error('STANDARD_DIRTY_INSTANCE') { @service.run_plan(plan_id: second[:plan_id]) }
    end
  end

  def test_measured_capacity_refusal
    with_standard do
      plan = approve
      @runtime.high_usage = true
      standard_error('STANDARD_CAPACITY') { @service.run_plan(plan_id: plan[:plan_id]) }
      assert @runtime.commands.any? { |op| op[1].is_a?(Array) && op[1].include?('{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}') }
      assert_empty @service.store.load['runs']
    end
  end

  def test_occupied_port_refused_at_proposal_and_execution
    with_standard do
      standard_error('STANDARD_PORT_OCCUPIED') { new_standard(port_probe: ->(_port) { false }).propose_plan(dataset_id: @dataset) }
      plan = approve
      standard_error('STANDARD_PORT_OCCUPIED') { new_standard(port_probe: ->(_port) { false }).run_plan(plan_id: plan[:plan_id]) }
    end
  end

  def test_output_name_reuse_refused
    with_standard do
      plan = approve
      output = @service.store.load['plans'][plan[:plan_id]]['body']['outputs']['final']
      @service.store.update { |state| state['consumed_outputs'] << output }
      standard_error('STANDARD_OUTPUT_CONSUMED') { @service.run_plan(plan_id: plan[:plan_id]) }
    end
  end

  def test_preflight_success_with_scripted_image_identities
    with_standard do
      run_id = claim
      @runtime.images_match = true
      @service.send(:stage_preflight, run_id)
      assert_equal 3, @service.show_run(run_id)[:results]['input_count']
      assert_equal @service.lock.fetch('images').size, @runtime.commands.count { |op| op[1].is_a?(Array) && op[1][0, 3] == %w[docker image inspect] }
    end
  end

  def test_import_stage_failure_persists_fixed_failure_and_dirties_instance
    with_standard do
      run_id = claim
      name = attach_instance(run_id, state: 'baseline')
      marker = 'PRIVATE-IMPORT-DETAIL-6b0d77'
      @runtime.import_failure = marker
      @service.send(:begin_stage, run_id, 'import')
      error = standard_error('STANDARD_IMPORT_FAILED') { @service.send(:stage_import, run_id) }
      @service.send(:fail_run, run_id, 'import', error.code, marker)
      view = new_standard.show_run(run_id)
      assert_equal 'failed', view[:status]
      assert_equal 'STANDARD_IMPORT_FAILED', view[:failure]['code']
      assert_equal SiloMigrate::Services::StandardWorkflowService::RECOVERY['STANDARD_IMPORT_FAILED'], view[:failure]['recovery']
      assert_equal 'dirty', new_standard.store.load['instances'][name]['state']
      refute_includes JSON.generate(view), marker
      assert_includes File.read(@service.store.run_dir(run_id, 'private', 'failure.json')), marker
    end
  end

  def test_reset_requires_confirmation_and_exact_id_label_checks
    with_standard do
      run_id = claim
      name = attach_instance(run_id)
      @service.recover(run_id: run_id)
      standard_error('STANDARD_CONFIRMATION_REQUIRED') { @service.reset_run(run_id: run_id) }
      @runtime.ownership = name
      retained = @service.store.run_dir(run_id, 'evidence', 'retained.txt')
      @service.store.write_private(retained, 'retain exact evidence')
      before = @runtime.commands.length
      assert_equal 'reset', @service.reset_run(run_id: run_id, yes: true)[:status]
      commands = @runtime.commands.drop(before).map { |op| op[1] }
      [['container', 'exact-container-id'], ['network', 'exact-network-id'], ['volume', 'exact-volume-id']].each do |kind, id|
        inspect_index = commands.index { |cmd| cmd[0, 3] == ['docker', kind, 'inspect'] && cmd.last == id }
        remove_index = commands.index { |cmd| cmd.include?('rm') && cmd.last == id }
        refute_nil inspect_index
        refute_nil remove_index
        assert_operator inspect_index, :<, remove_index
      end
      assert_equal [
        ['docker', 'rm', '--force', '--volumes', 'exact-container-id'],
        ['docker', 'network', 'rm', 'exact-network-id'],
        ['docker', 'volume', 'rm', 'exact-volume-id']
      ], commands.select { |cmd| cmd.include?('rm') }
      assert_equal 'removed', new_standard.store.load['instances'][name]['state']
      assert_equal 'retain exact evidence', File.binread(retained)
      assert new_standard.store.load['runs'].key?(run_id)
    end
  end

  def test_reset_ownership_mismatch_never_removes_foreign_resources
    with_standard do
      run_id = claim
      name = attach_instance(run_id)
      @service.recover(run_id: run_id)
      @runtime.ownership = 'foreign-instance'
      standard_error('STANDARD_CLEANUP_FAILED') { @service.reset_run(run_id: run_id, yes: true) }
      refute @runtime.commands.any? { |op| op[1].is_a?(Array) && op[1].include?('rm') }
      assert_equal 'dirty', @service.store.load['instances'][name]['state']
    end
  end
end
