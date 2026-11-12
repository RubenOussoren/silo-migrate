# frozen_string_literal: true
require_relative 'standard_review_run_test'
require_relative 'standard_merge_run_test'

module FileRoleFixtures
  def install_roles
    named = @service.store.named_state
    @role_document = { 'version' => 1, 'revision' => 1, 'active' => {}, 'snapshots' => {}, 'files' => {}, 'history' => [], 'invalidated_plans' => [] }
    deliveries = JSON.parse(File.read(File.join(@root, '.silo-migrate/named/deliveries.json'))).fetch('deliveries')
    named.fetch('datasets').each_key do |dataset|
      kind = deliveries.fetch(dataset).fetch('kind')
      @role_document['snapshots'][dataset] = { 'kind' => kind, 'revision' => 1, 'eligible' => true }
      @role_document['active'][kind] = dataset
    end
    named.fetch('inputs').each_with_index do |(id, input), index|
      file_id = 'file-%032x' % index
      @role_document['files'][file_id] = { 'id' => file_id, 'role' => input['type'] == 'base_site' ? 'base_site' : 'source',
        'dataset_id' => input['dataset_id'], 'input_id' => id, 'sha256' => input['sha256'] }
    end
    save_roles
  end

  def save_roles
    directory = File.join(@root, '.silo-migrate', 'data')
    FileUtils.mkdir_p(directory, mode: 0o700)
    @role_path = File.join(directory, 'file-roles.json')
    File.write(@role_path, JSON.generate(@role_document), perm: 0o600)
    File.chmod(0o600, @role_path)
  end

  def role_item(id)
    @role_document.fetch('files').values.find { |entry| entry['input_id'] == id }
  end

  def private_plan(plan)
    @service.store.load.fetch('plans').fetch(plan[:plan_id])
  end

  def assert_lineage_current(expected, plan_id)
    assert_equal expected, @service.show_plan(plan_id)[:file_role_lineage_current]
    summary = @service.status.fetch(:plans).find { |plan| plan[:plan_id] == plan_id }
    assert_equal expected, summary.fetch(:file_role_lineage_current)
  end
end

class FileRoleStoreTest < StandardConvertRunTest
  include FileRoleFixtures

  def self.runnable_methods
    public_instance_methods.grep(/^test_roles/).map(&:to_s)
  end

  def test_roles_lineage_current_ignores_ordinary_code_and_runtime_staleness
    with_convert do
      install_roles
      plan = propose_convert
      assert_lineage_current true, plan[:plan_id]
      original_identity = @service.send(:code_identity)
      @service.define_singleton_method(:code_identity) { 'changed-code' }
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      assert_lineage_current true, plan[:plan_id]
      @service.define_singleton_method(:code_identity) { original_identity }
      @service.define_singleton_method(:profile_current?) { |_config| false }
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      assert_lineage_current true, plan[:plan_id]
    end
  end

  def test_roles_missing_optional_registry_preserves_legacy_readable_parent
    with_convert do
      directory = File.join(@root, '.silo-migrate', 'data')
      FileUtils.mkdir_p(directory, mode: 0o700)
      File.chmod(0o755, File.join(@root, '.silo-migrate'))
      assert_nil SiloMigrate::FileRoleStore.new(@root).load
      assert_equal 'proposed', propose_convert[:status]
      install_roles
      error = assert_raises(SiloMigrate::StandardWorkflowError) { SiloMigrate::FileRoleStore.new(@root).load }
      assert_equal 'STANDARD_FILE_ROLES_INVALID', error.message
    end
  end

  def test_roles_reader_rejects_schema_symlinks_and_nonprivate_files
    with_convert do
      install_roles
      reader = SiloMigrate::FileRoleStore.new(@root)
      assert_equal @role_document, reader.load
      valid = Marshal.dump(@role_document)
      [
        -> { @role_document['version'] = 1.0 },
        -> { @role_document['invalidated_plans'] = ['customer-filename'] },
        -> { @role_document['active']['unknown'] = nil },
        -> { @role_document['active']['development'] = 'dataset-' + 'f' * 32 },
        -> { role_item(@ids['source'])['dataset_id'] = false },
        -> { role_item(@ids['source'])['input_id'] = false },
        -> { role_item(@ids['source'])['role'] = 'unknown' },
        -> { @role_document['snapshots'][@dataset]['eligible'] = nil }
      ].each do |mutate|
        mutate.call
        save_roles
        standard_error('STANDARD_FILE_ROLES_INVALID') { reader.load }
        @role_document = Marshal.load(valid)
      end
      [false, 0, '1'].each do |revision|
        @role_document['snapshots'][@dataset]['revision'] = revision
        save_roles
        error = assert_raises(SiloMigrate::StandardWorkflowError) { reader.load }
        assert_equal 'STANDARD_FILE_ROLES_INVALID', error.message
      end
      @role_document['snapshots'][@dataset]['revision'] = 1
      save_roles
      File.chmod(0o644, @role_path)
      standard_error('STANDARD_FILE_ROLES_INVALID') { reader.load }
      File.chmod(0o600, @role_path)
      target = @role_path + '.private'
      File.rename(@role_path, target)
      File.symlink(target, @role_path)
      standard_error('STANDARD_FILE_ROLES_INVALID') { reader.load }
      File.unlink(@role_path)
      File.rename(target, @role_path)
      directory = File.dirname(@role_path)
      File.rename(directory, directory + '.private')
      File.symlink(directory + '.private', directory)
      standard_error('STANDARD_FILE_ROLES_INVALID') { reader.load }
      File.unlink(directory)
      File.rename(directory + '.private', directory)
      File.chmod(0o755, directory)
      standard_error('STANDARD_FILE_ROLES_INVALID') { reader.load }
    end
  end

  def test_roles_reader_bounds_bytes_and_sanitizes_parser_errors
    with_convert do
      install_roles
      reader = SiloMigrate::FileRoleStore.new(@root)
      File.write(@role_path, '{"private-customer-file":broken}')
      standard_error('STANDARD_FILE_ROLES_INVALID') { reader.load }
      File.open(@role_path, 'w') { |file| file.truncate(SiloMigrate::FileRoleStore::MAX_BYTES + 1) }
      standard_error('STANDARD_FILE_ROLES_INVALID') { reader.load }
    end
  end

  def test_roles_binding_revocation_is_pending_only_and_immutable
    with_convert do
      install_roles
      plan = propose_convert
      stored = private_plan(plan)
      original = JSON.generate(stored['body'])
      assert_equal 3, stored.dig('body', 'file_role_binding', 'inputs').size
      assert_equal true, plan[:file_role_selection].first['active']
      @role_document['active'].clear
      @role_document['snapshots'][@dataset]['eligible'] = false
      @role_document['snapshots'][@dataset]['revision'] += 1
      save_roles
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_STALE_PLAN') { @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'engineer') }
      standard_error('STANDARD_FILE_ROLES_INELIGIBLE') { propose_convert }
      @service.store.update { |state| state['plans'][plan[:plan_id]]['status'] = 'consumed' }
      assert_equal 'consumed', @service.show_plan(plan[:plan_id])[:status]
      assert_equal original, JSON.generate(private_plan(plan)['body'])
    end
  end

  def test_roles_reject_original_reference_uploads_unassigned_and_moved_memberships
    with_convert do
      install_roles
      %w[reference uploads unassigned].each do |role|
        role_item(@ids['source'])['role'] = role
        save_roles
        standard_error('STANDARD_FILE_ROLES_INELIGIBLE') { propose_convert }
      end
      role_item(@ids['source'])['role'] = 'source'
      role_item(@ids['settings'])['dataset_id'] = 'dataset-' + 'f' * 32
      save_roles
      standard_error('STANDARD_FILE_ROLES_INELIGIBLE') { propose_convert }
      role_item(@ids['settings'])['dataset_id'] = @dataset
      role_item(@ids['reconciliation'])['role'] = 'reference'
      save_roles
      standard_error('STANDARD_FILE_ROLES_INELIGIBLE') { propose_convert }
    end
  end

  def test_roles_reference_additions_active_switch_and_derived_settings
    with_convert do
      install_roles
      @role_document['files'].delete_if { |_id, entry| entry['input_id'] == @ids['settings'] }
      save_roles
      plan = propose_convert
      other = 'dataset-' + 'f' * 32
      @role_document['snapshots'][other] = { 'kind' => 'development', 'revision' => 1, 'eligible' => true }
      @role_document['active']['development'] = other
      file_id = 'file-' + 'f' * 32
      @role_document['files'][file_id] = { 'id' => file_id, 'role' => 'reference', 'dataset_id' => nil }
      @role_document['revision'] += 1
      @role_document['history'] << { 'change' => { 'action' => 'activate' }, 'impacts' => { 'pending' => [{ 'plan_id' => plan[:plan_id] }] } }
      save_roles
      assert_equal 'proposed', @service.show_plan(plan[:plan_id])[:status]
      assert_equal false, @service.show_plan(plan[:plan_id])[:file_role_selection].first['active']
      delivery_path = File.join(@root, '.silo-migrate/named/deliveries.json')
      deliveries = JSON.parse(File.read(delivery_path))
      deliveries['deliveries'][@dataset]['replaced_by'] = other
      File.write(delivery_path, JSON.generate(deliveries))
      assert_equal 'proposed', propose_convert[:status] # explicitly selected intact older dataset
      @role_document['snapshots'][@dataset]['revision'] += 1
      save_roles
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
    end
  end

  def test_roles_explicit_null_active_does_not_stale_unrelated_or_intact_selected_dataset
    with_convert do
      install_roles
      plan = propose_convert
      other = 'dataset-' + 'f' * 32
      @role_document['snapshots'][other] = { 'kind' => 'launch', 'revision' => 2, 'eligible' => false }
      @role_document['active']['launch'] = nil
      save_roles
      reader = SiloMigrate::FileRoleStore.new(@root)
      assert_nil reader.load.fetch('active').fetch('launch')
      assert_equal 'proposed', @service.show_plan(plan[:plan_id])[:status]
      assert_equal true, @service.show_plan(plan[:plan_id])[:file_role_selection].first['active']
      @role_document['active']['development'] = nil
      save_roles
      assert_equal 'proposed', @service.show_plan(plan[:plan_id])[:status]
      assert_equal false, @service.show_plan(plan[:plan_id])[:file_role_selection].first['active']
      assert_equal 'proposed', propose_convert[:status] # explicit intact selection is still legal
      @role_document['snapshots'][@dataset]['eligible'] = false
      save_roles
      standard_error('STANDARD_FILE_ROLES_INELIGIBLE') { propose_convert }
    end
  end

  def test_roles_legacy_manifest_creation_does_not_rebind_and_impact_ids_stale_only_pending
    with_convert do
      plan = propose_convert
      original = private_plan(plan)['body']
      install_roles
      assert_equal 'proposed', @service.show_plan(plan[:plan_id])[:status]
      refute private_plan(plan)['body'].key?('file_role_binding')
      @role_document['history'] << { 'impacts' => { 'pending' => [{ 'plan_id' => plan[:plan_id] }] } }
      save_roles
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      @role_document['history'] = []
      @role_document['invalidated_plans'] = [plan[:plan_id]]
      save_roles
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      assert_equal original, private_plan(plan)['body']
    end
  end

  def test_roles_approved_legacy_claim_checks_invalidation_under_state_lock
    with_convert do
      plan = propose_convert
      @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'engineer')
      install_roles
      @role_document['invalidated_plans'] = [plan[:plan_id]]
      save_roles
      standard_error('STANDARD_STALE_PLAN') { @service.send(:claim_plan!, plan[:plan_id]) }
      assert_empty @service.store.load.fetch('runs')
      assert_equal 'approved', private_plan(plan)['status']
    end
  end

  def test_roles_earlier_settings_snapshot_revision_is_a_dependency
    with_convert do
      source = @service.store.named_state.fetch('sources').keys.first
      earlier = @named.add_dataset('synthetic', source_id: source)[:dataset_id]
      delivery_path = File.join(@root, '.silo-migrate/named/deliveries.json')
      deliveries = JSON.parse(File.read(delivery_path))
      deliveries['deliveries'][earlier] = { 'kind' => 'development', 'version' => 1 }
      File.write(delivery_path, JSON.generate(deliveries))
      current = @dataset
      @dataset = earlier
      settings = add_input('earlier-settings.yml', SETTINGS, 'converter-settings')
      @dataset = current
      install_roles
      plan = propose_convert(settings: settings)
      @role_document['snapshots'][earlier]['revision'] += 1
      save_roles
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      assert_equal 1, @role_document['snapshots'][@dataset]['revision']
    end
  end

  def test_roles_proposal_race_is_rechecked_inside_update
    with_convert do
      install_roles
      store = @service.store
      path = @role_path
      document = @role_document
      store.singleton_class.prepend(Module.new do
        define_method(:update) do |&block|
          super() do |current|
            document['snapshots'].each_value { |snapshot| snapshot['revision'] += 1 }
            File.write(path, JSON.generate(document))
            block.call(current)
          end
        end
      end)
      standard_error('STANDARD_STALE_PLAN') { propose_convert }
      assert_empty store.load.fetch('plans')
    end
  end
end

class FileRoleReviewTest < StandardReviewRunTest
  include FileRoleFixtures

  def self.runnable_methods
    public_instance_methods.grep(/^test_roles/).map(&:to_s)
  end

  def test_roles_review_preserves_exact_completed_source_binding_and_rejects_corrected_lineage
    with_review do
      install_roles
      @ids.delete('reconciliation') # Isolate inherited lineage from review's own bindings.
      @convert = run_convert
      source = @service.store.load.fetch('plans').fetch(@convert[:plan_id])
      original_source = JSON.generate(source)
      original_runs = JSON.generate(@service.store.load.fetch('runs'))
      binding = source.dig('body', 'file_role_binding')
      plan = propose_review
      assert_lineage_current true, source['id']
      assert_lineage_current true, plan[:plan_id]
      assert_equal binding, private_plan(plan).dig('body', 'source_file_role_binding')
      assert_empty private_plan(plan).dig('body', 'file_role_binding', 'inputs')
      @role_document['snapshots'][@dataset]['revision'] += 1
      save_roles
      assert_lineage_current false, source['id']
      assert_lineage_current false, plan[:plan_id]
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_STALE_PLAN') { propose_review }
      assert_equal 'consumed', @service.show_plan(source['id'])[:status]
      assert_equal binding, @service.store.load.dig('plans', source['id'], 'body', 'file_role_binding')
      assert_equal original_source, JSON.generate(@service.store.load.dig('plans', source['id']))
      assert_equal original_runs, JSON.generate(@service.store.load.fetch('runs'))
      refute source.fetch('body').key?('file_role_lineage_current')
    end
  end

  def test_roles_consumed_lineage_stays_current_for_unrelated_reference_and_pointer_switch
    with_review do
      install_roles
      @convert = run_convert
      source_id = @convert[:plan_id]
      original_source = JSON.generate(@service.store.load.dig('plans', source_id))
      original_runs = JSON.generate(@service.store.load.fetch('runs'))
      plan = propose_review
      other = 'dataset-' + 'f' * 32
      @role_document['snapshots'][other] = { 'kind' => 'development', 'revision' => 1, 'eligible' => true }
      @role_document['active']['development'] = other
      file_id = 'file-' + 'f' * 32
      @role_document['files'][file_id] = { 'id' => file_id, 'role' => 'reference', 'dataset_id' => nil }
      @role_document['revision'] += 1
      @role_document['history'] << { 'change' => { 'action' => 'activate' }, 'impacts' => { 'completed' => [{ 'plan_id' => source_id }] } }
      save_roles
      assert_lineage_current true, source_id
      assert_lineage_current true, plan[:plan_id]
      assert_equal 'consumed', @service.show_plan(source_id)[:status]
      assert_equal 'proposed', propose_review[:status]
      assert_equal original_source, JSON.generate(@service.store.load.dig('plans', source_id))
      assert_equal original_runs, JSON.generate(@service.store.load.fetch('runs'))
    end
  end

  def test_roles_review_proposal_rechecks_inherited_source_at_commit
    with_review do
      install_roles
      @convert = run_convert
      before = @service.store.load.fetch('plans').size
      store = @service.store
      path = @role_path
      document = @role_document
      store.singleton_class.prepend(Module.new do
        define_method(:update) do |&block|
          super() do |current|
            document['snapshots'].each_value { |snapshot| snapshot['revision'] += 1 }
            File.write(path, JSON.generate(document))
            block.call(current)
          end
        end
      end)
      standard_error('STANDARD_STALE_PLAN') { propose_review }
      assert_equal before, store.load.fetch('plans').size
    end
  end

  def test_roles_review_rejects_invalidated_legacy_source_without_rebinding
    with_review do
      source_id = @convert[:plan_id]
      original_source = JSON.generate(@service.store.load.dig('plans', source_id))
      assert_lineage_current true, source_id
      install_roles
      plan = propose_review
      assert_lineage_current true, source_id
      assert_lineage_current true, plan[:plan_id]
      refute private_plan(plan)['body'].key?('source_file_role_binding')
      @role_document['history'] << { 'change' => { 'action' => 'correct' }, 'impacts' => { 'completed' => [{ 'plan_id' => source_id }] } }
      save_roles
      assert_lineage_current false, source_id
      assert_lineage_current false, plan[:plan_id]
      standard_error('STANDARD_STALE_PLAN') { propose_review }
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      assert_equal 'consumed', @service.show_plan(source_id)[:status]
      assert_equal original_source, JSON.generate(@service.store.load.dig('plans', source_id))
    end
  end
end

class FileRoleBaseAndMergeTest < StandardMergeRunTest
  include FileRoleFixtures

  def self.runnable_methods
    public_instance_methods.grep(/^test_roles/).map(&:to_s)
  end

  def test_roles_base_snapshot_revision_stales_only_dependent_pending_review
    with_base do
      install_roles
      plain = propose_review
      base = base_plan
      bound = private_plan(base).dig('body', 'file_role_binding', 'inputs').find { |entry| entry['role'] == 'base_site' }
      assert_equal @base_dataset, bound['dataset_id']
      @role_document['snapshots'][@base_dataset]['revision'] += 1
      save_roles
      assert_equal 'stale', @service.show_plan(base[:plan_id])[:status]
      assert_equal 'proposed', @service.show_plan(plain[:plan_id])[:status]
      role_item(@base)['role'] = 'uploads'
      save_roles
      standard_error('STANDARD_FILE_ROLES_INELIGIBLE') { base_plan }
    end
  end

  def test_roles_merge_binds_base_source_and_settings_and_rejects_effective_reference
    with_merge do
      install_roles
      plan = merge_plan(settings: @merge_settings)
      binding = private_plan(plan).dig('body', 'file_role_binding')
      assert_equal %w[base_site settings source], binding['inputs'].map { |entry| entry['role'] }
      refute_match(/customer-secret|private-site|private-settings|#{Regexp.escape(@root)}/, JSON.generate(binding))
      role_item(@merge_settings)['role'] = 'reference'
      save_roles
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_FILE_ROLES_INELIGIBLE') { merge_plan(settings: @merge_settings) }
    end
  end
end
