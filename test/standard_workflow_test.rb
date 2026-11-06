# frozen_string_literal: true
require_relative 'test_helper'
require 'silo_migrate/services/named_workspace_service'
require 'silo_migrate/services/standard_workflow_service'

# Scripted command results only; no subprocess, Docker socket or host port use.
class StandardScriptedRuntime < SiloMigrate::Runtime::Fake
  attr_accessor :converter_config, :converter_head, :converter_branch, :converter_repo, :converter_dirty, :inspect_document, :high_usage, :ownership, :images_match, :import_failure, :sweep_resources, :sweep_failure, :live_result, :live_error
  def run(cmd, **options)
    result = super
    if sweep_failure && cmd.include?('ls') && cmd.include?('--filter')
      return SiloMigrate::Runtime::CommandResult.new(success?: false, stdout: '', stderr: 'private sweep failure', status: 1)
    end
    if cmd.include?('--format') && cmd.any? { |arg| arg.include?('{{.State.Running}} {{index .Config.Labels') }
      return SiloMigrate::Runtime::CommandResult.new(success?: live_error.nil?, stdout: live_result.to_s, stderr: live_error.to_s, status: live_error ? 1 : 0)
    end
    stdout = if cmd.first == 'docker' && cmd.include?('ls') && cmd.include?('--filter')
      (sweep_resources || {}).fetch(cmd[1], []).join("\n")
    elsif cmd.first == 'df'
      "Avail\n107374182400\n"
    elsif cmd[0, 2] == %w[docker ps]
      high_usage ? "recorded-id\n" : ''
    elsif cmd.include?('{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}')
      "99000000000 999999999999\n"
    elsif cmd[0, 3] == %w[docker image inspect]
      if images_match
        document = inspect_document || JSON.parse(File.read(File.join(__dir__, 'fixtures/image-inspect-sample.json'))).first
        document['Id'] = 'sha256:' + Digest::SHA256.hexdigest(cmd.last)
        JSON.generate([document])
      else
        'wrong-image'
      end
    elsif cmd.include?('git')
      if cmd.include?('--list') then converter_config.to_s
      elsif cmd.include?('status') then converter_dirty ? '?? untracked.txt' : ''
      elsif cmd.include?('--abbrev-ref') then converter_branch || 'main'
      elsif cmd.include?('rev-parse') then converter_head || 'a' * 40
      elsif cmd.include?('remote') then converter_repo || 'https://github.com/discourse-org/discourse-converters.git'
      else result.stdout
      end
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
  def with_standard(inputs: nil)
    with_tmp_base do |dir, env|
      @env = env
      @named = SiloMigrate::Services::NamedWorkspaceService.new(env: env)
      @named.init('synthetic')
      @root = File.join(env.fetch('SILO_MIGRATE_BASE_PATH'), 'synthetic')
      source = @named.add_source('synthetic', platform: 'synthetic')[:source_id]
      @dataset = @named.add_dataset('synthetic', source_id: source)[:dataset_id]
      @paths = {}
      (inputs || %w[source-sql converter-settings expected].to_h { |type| [type, "synthetic #{type}"] }).each do |type, bytes|
        @paths[type] = add_standard_input(type, bytes, name: type == 'upload' ? 'uploads/source.txt' : type)
      end
      @code_root = File.join(dir, 'code')
      FileUtils.mkdir_p(File.join(@code_root, 'runtime'))
      FileUtils.cp_r(File.expand_path('../runtime/prebuilt-discourse', __dir__), File.join(@code_root, 'runtime'))
      FileUtils.cp_r(File.expand_path('../runtime/profiles', __dir__), File.join(@code_root, 'runtime'))
      profile_path = File.join(@code_root, 'runtime/profiles', SiloMigrate::RuntimeProfiles::DEFAULT + '.json')
      profile = JSON.parse(File.read(profile_path))
      digest = File.read(File.join(__dir__, 'fixtures/image-inspect-sample.content_id')).strip
      profile.fetch('images').each_value { |image| image['content_id'] = digest }
      File.write(profile_path, JSON.pretty_generate(profile))
      write(File.join(@code_root, 'lib', 'identity.rb'), '# synthetic code identity')
      @runtime = StandardScriptedRuntime.new
      @service = new_standard
      settings = write(File.join(dir, 'site-settings.yml'), "title: Synthetic\n")
      converter = File.join(dir, 'converter')
      FileUtils.mkdir_p(File.join(converter, '.git'))
      @service.init(converter_worktree: converter, site_settings: settings)
      yield
    end
  end

  def add_standard_input(type, bytes, name: type, input_root: 'dataset')
    relative = "inputs/#{input_root}/#{name}"
    path = write(File.join(@root, relative), bytes)
    @named.add_input('synthetic', dataset_id: @dataset, path: relative, sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize, type: type)
    path
  end

  def new_standard(port_probe: ->(_port) { true })
    SiloMigrate::Services::StandardWorkflowService.new('synthetic', env: @env, runtime: @runtime, code_root: @code_root, execute_lock_wait: 0,
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
    @service.claim(plan_id: plan[:plan_id]).fetch(:run_id)
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
        assert_equal 'claimed', new_standard.show_run(run_id)[:status]
        assert new_standard.status[:executor_active]
      end
    end
  end

  def test_abandoned_run_survives_new_service_and_requires_recovery
    with_standard do
      run_id = claim
      name = attach_instance(run_id, state: 'ready')
      @service.store.update { |state| state['runs'][run_id]['status'] = 'running' }
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
      @service.recover(run_id: first)
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

  def test_claimed_and_running_runs_block_new_claims
    with_standard do
      first = claim
      assert_equal 'claimed', new_standard.show_run(first)[:status]
      refute new_standard.show_run(first).key?(:recovery)
      second = approve
      standard_error('STANDARD_BUSY') { new_standard.claim(plan_id: second[:plan_id]) }
      @service.store.update { |state| state['runs'][first]['status'] = 'running' }
      standard_error('STANDARD_BUSY') { new_standard.claim(plan_id: second[:plan_id]) }
    end
  end

  def test_claim_can_be_recovered_but_execute_requires_claimed_state
    with_standard do
      run_id = claim
      assert_equal 'interrupted', new_standard.recover(run_id: run_id)[:status]
      standard_error('STANDARD_TRANSITION_INVALID') { new_standard.execute(run_id: run_id) }
      next_run = claim
      assert_equal 'failed', new_standard.execute(run_id: next_run)[:status]
      standard_error('STANDARD_TRANSITION_INVALID') { new_standard.execute(run_id: next_run) }
    end
  end

  def test_unregistered_upload_dotfile_is_refused_before_conversion
    with_standard do
      plan = approve
      write(File.join(@root, 'inputs/dataset/uploads/.hidden'), 'unregistered private bytes')
      @runtime.images_match = true
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_INPUT_CHANGED') { propose }
      standard_error('STANDARD_STALE_PLAN') { @service.run_plan(plan_id: plan[:plan_id]) }
      assert_empty @service.store.load['runs']
    end
  end

  def test_registered_inputs_must_have_one_dataset_root
    with_standard do
      relative = 'inputs/other/extra'
      bytes = 'registered but wrong root'
      write(File.join(@root, relative), bytes)
      @named.add_input('synthetic', dataset_id: @dataset, path: relative, sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize, type: 'binary')
      standard_error('STANDARD_INPUTS_INCOMPLETE') { propose }
      assert_empty @service.store.load['plans']
      assert_empty @service.store.load['runs']
    end
  end

  def test_later_stages_read_only_preflight_snapshot
    with_standard do
      # A separate valid expected input makes expected_for exercise the same
      # path used by verify_site and verify_restore, not just a copy helper.
      expected = { 'users' => [], 'categories' => [], 'topics' => [], 'posts' => [], 'counts' => {} }
      # Re-register a fresh dataset; never mutate a registered input before planning.
      source = @named.add_source('synthetic', platform: 'synthetic')[:source_id]
      @dataset = @named.add_dataset('synthetic', source_id: source)[:dataset_id]
      add_standard_input('source-sql', 'original SQL', name: 'source.sql', input_root: 'snapshot')
      add_standard_input('converter-settings', 'original settings', name: 'settings.yml', input_root: 'snapshot')
      add_standard_input('expected', JSON.generate(expected), name: 'expected.json', input_root: 'snapshot')
      add_standard_input('upload', 'original attachment', name: 'uploads/one.txt', input_root: 'snapshot')
      @runtime.images_match = true
      run_id = claim
      @service.send(:stage_preflight, run_id)
      inputs = @service.send(:run_inputs, run_id)
      assert_equal 4, inputs.size
      inputs.each do |input|
        path = @service.send(:input_path, run_id, input)
        assert path.start_with?(@service.store.run_dir(run_id, 'work') + '/')
        assert_equal input['sha256'], Digest::SHA256.file(path).hexdigest
        assert_equal 0o400, File.stat(path).mode & 0o777
      end
      source_root = File.join(@root, 'inputs/snapshot')
      File.write(File.join(source_root, 'expected.json'), '{"changed":true}')
      File.write(File.join(source_root, 'uploads/one.txt'), 'changed attachment')
      actual, shas, bytes = @service.send(:expected_for, run_id)
      assert_equal expected, actual
      assert_equal [Digest::SHA256.hexdigest('original attachment')], shas
      assert_equal ['original attachment'], bytes.values
      tree = @service.send(:input_tree, run_id, inputs, 'upload', 'uploads')
      assert_equal 'original attachment', File.binread(File.join(tree, 'one.txt'))
    end
  end

  def test_status_and_plan_show_do_not_contend_with_named_lock_or_report_false_stale
    with_standard do
      plan = approve
      ready = Queue.new
      release = Queue.new
      holder = Thread.new do
        @service.store.named.with_lock { ready << true; release.pop }
      end
      ready.pop
      begin
        require 'timeout'
        Timeout.timeout(2) do
          assert_equal 'approved', new_standard.show_plan(plan[:plan_id])[:status]
          assert_equal 'approved', new_standard.status[:plans].find { |p| p[:plan_id] == plan[:plan_id] }[:status]
        end
      ensure
        release << true
        holder.value
      end
    end
  end

  def test_host_lock_blocks_second_workspace_execution
    with_standard do
      @named.init('second')
      source = @named.add_source('second', platform: 'synthetic')[:source_id]
      dataset = @named.add_dataset('second', source_id: source)[:dataset_id]
      %w[source-sql converter-settings expected].each do |type|
        relative = "inputs/dataset/#{type}"
        write(File.join(@env.fetch('SILO_MIGRATE_BASE_PATH'), 'second', relative), type)
        @named.add_input('second', dataset_id: dataset, path: relative, sha256: Digest::SHA256.hexdigest(type), bytes: type.bytesize, type: type)
      end
      second = SiloMigrate::Services::StandardWorkflowService.new('second', env: @env, runtime: @runtime, code_root: @code_root, execute_lock_wait: 0,
        port_probe: ->(_) { true }, disk_free: -> { 100 * 1024**3 })
      config = @service.store.load.fetch('config')
      second.init(converter_worktree: config['converter_worktree'], site_settings: config['site_settings'])
      plan = second.propose_plan(dataset_id: dataset)
      second.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'engineer')
      run_id = second.claim(plan_id: plan[:plan_id])[:run_id]
      @service.store.with_host_lock do
        standard_error('STANDARD_BUSY') { second.claim(plan_id: plan[:plan_id]) }
        result = second.execute(run_id: run_id)
        assert_equal 'failed', result[:status]
        assert_equal 'STANDARD_BUSY', result[:failure]['code']
        assert_equal result, second.show_run(run_id)
      end
      standard_error('STANDARD_TRANSITION_INVALID') { second.execute(run_id: run_id) }
    end
  end

  def test_reset_sweeps_orphans_using_exact_run_label_for_every_resource_kind
    with_standard do
      run_id = claim
      @service.recover(run_id: run_id)
      @runtime.sweep_resources = { 'container' => ['orphan-container-id'], 'network' => ['orphan-network-id'], 'volume' => ['orphan-volume-name'] }
      assert_equal 'reset', @service.reset_run(run_id: run_id, yes: true)[:status]
      commands = @runtime.commands.map { |op| op[1] }
      %w[container network volume].each do |kind|
        listing = commands.select { |cmd| cmd[0, 3] == ['docker', kind, 'ls'] }
        assert_equal 1, listing.size
        index = listing.first.index('--filter')
        refute_nil index
        assert_equal "label=silo-migrate.run=#{run_id}", listing.first[index + 1]
      end
      assert_equal [
        ['docker', 'container', 'rm', '--force', '--volumes', 'orphan-container-id'],
        ['docker', 'network', 'rm', 'orphan-network-id'],
        ['docker', 'volume', 'rm', 'orphan-volume-name']
      ], commands.select { |cmd| cmd.include?('rm') }
      assert_equal 'interrupted', new_standard.show_run(run_id)[:status]
      assert_equal 'consumed', new_standard.show_plan(@service.store.load['runs'][run_id]['plan_id'])[:status]
    end
  end

  %w[code runtime inputs unregistered].each do |change|
    define_method("test_execute_rechecks_#{change}_after_claim") do
      with_standard do
        plan = approve
        run_id = claim(plan)
        case change
        when 'code'
          File.write(File.join(@code_root, 'lib/identity.rb'), '# changed after claim')
        when 'runtime'
          path = File.join(@code_root, 'runtime/profiles/' + SiloMigrate::RuntimeProfiles::DEFAULT + '.json')
          content = JSON.parse(File.read(path))
          content['app']['revision'] = 'b' * 40
          File.write(path, JSON.generate(content))
        when 'inputs'
          File.write(@paths.fetch('source-sql'), 'modified after claim')
        when 'unregistered'
          write(File.join(@root, 'inputs/dataset/uploads/.late'), 'unbound')
        end
        @runtime.images_match = true
        result = new_standard.execute(run_id: run_id)
        assert_equal 'failed', result[:status]
        assert_equal 'preflight', result[:stage]
        assert_equal 'STANDARD_STALE_PLAN', result[:failure]['code']
        assert_equal SiloMigrate::Services::StandardWorkflowService::RECOVERY.fetch('STANDARD_STALE_PLAN'), result[:failure]['recovery']
        assert_equal 'pending', result[:stages]['convert']
        assert_equal result, new_standard.show_run(run_id)
        assert_equal 'consumed', new_standard.show_plan(plan[:plan_id])[:status]
        refute File.exist?(@service.store.run_dir(run_id, 'work/inputs.json'))
      end
    end
  end

  def test_duplicate_execute_never_fails_a_run_another_process_is_executing
    with_standard do
      run_id = claim
      @service.store.with_op_lock do
        # The other process has already moved this run past claimed.
        @service.store.update { |state| state['runs'][run_id]['status'] = 'running' }
        contender = new_standard
        store = contender.store
        def store.with_op_lock(wait: 0)
          raise SiloMigrate::StandardWorkflowError, 'STANDARD_BUSY'
        end
        standard_error('STANDARD_TRANSITION_INVALID') { contender.execute(run_id: run_id) }
      end
      assert_equal 'running', new_standard.store.load['runs'][run_id]['status']
      assert_nil new_standard.store.load['runs'][run_id]['failure']
    end
  end

  def test_execute_busy_while_still_claimed_fails_only_that_claim
    with_standard do
      run_id = claim
      other = new_standard
      store = other.store
      def store.with_host_lock(wait: 0)
        raise SiloMigrate::StandardWorkflowError, 'STANDARD_BUSY'
      end
      assert_equal 'STANDARD_BUSY', other.execute(run_id: run_id)[:failure]['code']
      # Moved on between the busy result and the guarded update: not rewritten.
      @service.store.update { |state| state['runs'][run_id].merge!('status' => 'running', 'failure' => nil) }
      refute other.send(:fail_unstarted_claim, run_id)
      assert_equal 'running', new_standard.store.load['runs'][run_id]['status']
      assert_nil new_standard.store.load['runs'][run_id]['failure']
    end
  end

  def test_execute_op_lock_contention_is_a_durable_busy_failure
    with_standard do
      run_id = claim
      @service.store.with_op_lock do
        result = new_standard.execute(run_id: run_id)
        assert_equal 'failed', result[:status]
        assert_equal 'STANDARD_BUSY', result[:failure]['code']
        assert_equal 'failed', result[:stages]['preflight']
        assert_equal 'pending', result[:stages]['convert']
        assert_equal result, new_standard.show_run(run_id)
      end
      assert_equal 'STANDARD_BUSY', new_standard.show_run(run_id)[:failure]['code']
      standard_error('STANDARD_TRANSITION_INVALID') { new_standard.execute(run_id: run_id) }
    end
  end

  def test_old_claim_projects_not_started_only_when_op_lock_is_free
    with_standard do
      run_id = claim
      assert_equal 'claimed', new_standard.show_run(run_id)[:status]
      refute new_standard.show_run(run_id).key?(:recovery)
      grace = SiloMigrate::Services::StandardWorkflowService::CLAIM_GRACE_SECONDS
      @service.store.update { |state| state['runs'][run_id]['started_at'] = (Time.now.utc - grace - 10).iso8601 }
      @service.store.with_op_lock do
        assert_equal 'claimed', new_standard.show_run(run_id)[:status]
      end
      view = new_standard.show_run(run_id)
      assert_equal 'not_started', view[:status]
      assert_includes view[:recovery], "run recover synthetic #{run_id}"
      assert_equal 'not_started', new_standard.status[:runs].first[:status]
      assert_equal 'claimed', @service.store.load['runs'][run_id]['status']
      assert_equal 'interrupted', new_standard.recover(run_id: run_id)[:status]
    end
  end

  def test_file_directly_under_inputs_is_refused_at_proposal
    with_standard do
      bytes = 'loose input'
      write(File.join(@root, 'inputs/loose'), bytes)
      @named.add_input('synthetic', dataset_id: @dataset, path: 'inputs/loose', sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize, type: 'binary')
      standard_error('STANDARD_INPUTS_INCOMPLETE') { propose }
      assert_empty @service.store.load['plans']
      assert_empty @service.store.load['runs']
    end
  end

  def test_unregistered_file_is_refused_at_initial_proposal
    with_standard do
      write(File.join(@root, 'inputs/dataset/uploads/.hidden'), 'unregistered')
      standard_error('STANDARD_INPUT_CHANGED') { propose }
      assert_empty @service.store.load['plans']
      assert_empty @service.store.load['runs']
    end
  end

  def test_non_ascii_registered_upload_name_passes_preflight_byte_exact
    with_standard do
      bytes = "Synthetic résumé attachment.\n"
      add_standard_input('upload', bytes, name: 'uploads/résumé.txt')
      @runtime.images_match = true
      run_id = claim
      @service.send(:stage_preflight, run_id)
      inputs = @service.send(:run_inputs, run_id)
      upload = inputs.find { |input| input['type'] == 'upload' }
      assert_equal 'inputs/dataset/uploads/résumé.txt'.b, upload.fetch('relative').b
      assert_equal bytes.b, File.binread(@service.send(:input_path, run_id, upload))
      assert_equal Digest::SHA256.hexdigest(bytes), upload['sha256']
      assert_equal 4, @service.show_run(run_id)[:results]['input_count']
    end
  end

  def test_live_instance_projection_uses_recorded_ids_and_handles_unknown_docker_state
    with_standard do
      run_id = claim
      name = attach_instance(run_id, state: 'ready')
      ids = SiloMigrate::Services::PrebuiltStack::ROLES.to_h { |role| [role, "recorded-#{role}-id"] }
      @service.store.update { |state| state['instances'][name]['containers'] = ids }
      @runtime.live_result = ids.map { |_role, _id| "true #{name}" }.join("\n")
      view = new_standard.status[:instances].first
      assert_equal true, view[:live]
      assert_equal 'http://127.0.0.1:18000/', view[:url]
      inspect_command = @runtime.commands.last[1]
      assert_equal ids.values, inspect_command.drop(4)
      refute inspect_command.include?(name)
      @runtime.live_result = ids.map { |_role, _id| 'true foreign-instance' }.join("\n")
      view = new_standard.status[:instances].first
      assert_equal false, view[:live]
      assert_nil view[:url]
      @runtime.live_error = 'Docker daemon unavailable private detail'
      view = new_standard.status[:instances].first
      assert_nil view[:live]
      assert_nil view[:url]
      refute_includes JSON.generate(view), @runtime.live_error
      @runtime.live_error = 'Error: No such container: recorded-web-id'
      view = new_standard.status[:instances].first
      assert_equal false, view[:live]
      assert_nil view[:url]
      @runtime.live_error = nil
      @runtime.live_result = ids.map { |_role, _id| "false #{name}" }.join("\n")
      view = new_standard.status[:instances].first
      assert_equal false, view[:live]
      assert_nil view[:url]
      @service.store.update { |state| state['instances'][name]['state'] = 'removed' }
      before = @runtime.commands.size
      assert_equal false, new_standard.status[:instances].first[:live]
      assert_nil new_standard.status[:instances].first[:url]
      assert_equal before, @runtime.commands.size
    end
  end

  def test_failed_sweep_keeps_instance_dirty_blocks_claim_and_retry_finishes_reset
    with_standard do
      run_id = claim
      name = attach_instance(run_id)
      @service.recover(run_id: run_id)
      @runtime.ownership = name
      @runtime.sweep_failure = true
      standard_error('STANDARD_CLEANUP_FAILED') { @service.reset_run(run_id: run_id, yes: true) }
      assert_equal 'dirty', new_standard.store.load['instances'][name]['state']
      next_plan = approve
      standard_error('STANDARD_DIRTY_INSTANCE') { new_standard.claim(plan_id: next_plan[:plan_id]) }
      assert_equal 'approved', new_standard.show_plan(next_plan[:plan_id])[:status]
      @runtime.sweep_failure = false
      result = new_standard.reset_run(run_id: run_id, yes: true)
      assert_equal 'reset', result[:status]
      assert_equal [name], result[:removed]
      assert_equal 'removed', new_standard.store.load['instances'][name]['state']
      assert_equal 'claimed', new_standard.claim(plan_id: next_plan[:plan_id])[:status]
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
