# frozen_string_literal: true
require_relative 'standard_base_site_review_test'
require_relative 'standard_merge_run_test'

class StandardReviewRuntimeTest < StandardBaseSiteReviewTest
  def self.runnable_methods
    public_instance_methods.grep(/^test_runtime_/).map(&:to_s)
  end

  def runtime_profile(name, version:, schema: '20261104011110')
    profile = JSON.parse(File.read(File.join(@code_root, 'runtime/profiles', SiloMigrate::RuntimeProfiles::DEFAULT + '.json')))
    document = JSON.parse(File.read(File.join(__dir__, 'fixtures/image-inspect-sample.json'))).first
    document['RootFS']['Layers'] = [name]
    document['Id'] = 'sha256:' + Digest::SHA256.hexdigest(name)
    ref = "synthetic/#{name}:web"
    profile['images']['web'].merge!('ref' => ref, 'content_id' => SiloMigrate::ImageIdentity.content_id(document))
    @runtime.runtime_image_documents ||= {}
    @runtime.runtime_image_documents[ref] = document
    profile['app']['version'] = version
    parsed = SiloMigrate::DiscourseVersion.parse(version)
    profile['selector'] = { 'channel' => parsed[:track], 'release' => parsed[:release] }
    profile['qualification'] = { 'status' => 'review_ready', 'scope' => %w[review merge], 'full_stack_qualified' => false }
    profile['review_runtime'] = { 'schema_version' => schema, 'core_migrations' => ['20261104011110', schema].uniq.sort }
    path = File.join(@code_root, 'runtime/profiles', name + '.json')
    File.write(path, JSON.generate(profile))
    path
  end

  def replace_base(version:, schema:)
    source = @service.store.named_state.fetch('sources').keys.first
    dataset = @named.add_dataset('synthetic', source_id: source)[:dataset_id]
    path = File.join(@root, '.silo-migrate/named/deliveries.json')
    deliveries = JSON.parse(File.read(path))
    deliveries['deliveries'][@base_dataset]['replaced_by'] = dataset
    deliveries['deliveries'][dataset] = { 'dataset_id' => dataset, 'kind' => 'base_site', 'version' => 3 }
    File.write(path, JSON.generate(deliveries))
    previous, @dataset = @dataset, dataset
    buffer = StringIO.new
    gzip = Zlib::GzipWriter.new(buffer)
    gzip.write("-- PostgreSQL database dump\nCOPY public.schema_migrations (version) FROM stdin;\n20261104011110\n#{schema}\n\\.\n")
    gzip.close
    @base = add_input("private-replacement-v#{version.tr('.', '-')}-#{schema}.sql.gz", buffer.string, 'base_site')
    @dataset, @base_dataset = previous, dataset
  end

  def test_runtime_beta_filename_matches_dot_profile_and_rc_is_newer
    with_base do
      replace_base(version: '3.4.0.beta3', schema: '20261104011110')
      runtime_profile('matching-beta', version: '3.4.0.beta3')
      @env['SILO_REVIEW_RUNTIME_PROFILE'] = 'matching-beta'
      plan = base_plan
      assert_equal 'matched', plan.dig(:review_runtime, 'mode')
      assert_equal '3.4.0.beta3', plan.dig(:base_site, 'discourse_version')
      assert_nil @service.send(:base_site_compatible!, { 'discourse_version' => '3.4.0-beta3' }, { 'discourse_version' => '3.4.0.beta3' })
      runtime_profile('newer-rc', version: '3.4.0.rc1')
      @env['SILO_REVIEW_RUNTIME_PROFILE'] = 'newer-rc'
      assert_equal 'newer', base_plan.dig(:review_runtime, 'mode')
    end
  end

  def test_runtime_schema_only_backup_does_not_guess_a_track
    with_base do
      previous, @dataset = @dataset, @base_dataset
      input = add_input('invented-v20261104011110.sql.gz', 'invented-not-loaded', 'base_site')
      @dataset = previous
      assert_nil @service.send(:base_site_versions!, 'invented-v20261104011110.sql.gz')['discourse_version']
      standard_error('STANDARD_REVIEW_RUNTIME_UNRESOLVED') { propose_review(base_site: input) }
    end
  end

  def test_runtime_comparison_is_bound_to_own_plan_not_public_profile
    with_base do
      path = runtime_profile('public-only', version: '2026.11.0-latest')
      @env['SILO_REVIEW_RUNTIME_PROFILE'] = 'public-only'
      @env['SILO_REVIEW_RUNTIME_COMPARISON'] = JSON.generate('core_comparison_complete' => false, 'missing_known_core_migrations' => 2)
      plan = base_plan
      assert_equal false, plan.dig(:review_runtime, 'core_comparison_complete')
      assert_equal 2, plan.dig(:review_runtime, 'missing_known_core_migrations')
      refute_includes File.read(path), 'core_comparison_complete'
      refute_includes File.read(path), 'missing_known_core_migrations'
      @env['SILO_REVIEW_RUNTIME_COMPARISON'] = JSON.generate('private_customer' => 'never-forward')
      standard_error('STANDARD_RUNTIME_MISMATCH') { base_plan }
      @env['SILO_REVIEW_RUNTIME_COMPARISON'] = JSON.generate('missing_known_core_migrations' => true)
      standard_error('STANDARD_RUNTIME_MISMATCH') { base_plan }
    end
  end

  def test_runtime_no_base_selects_newest_latest_and_execution_uses_bound_profile
    with_base do
      original = @service.store.load.fetch('config').dup
      runtime_profile('new-latest', version: '2026.12.0-latest')
      plan = propose_review
      assert_equal 'new-latest', plan[:discourse_profile]
      assert_equal 'latest', plan.dig(:review_runtime, 'mode')
      run = run_review(plan)
      assert_equal 'completed', run[:status], run.inspect
      assert_equal '2026.12.0-latest', run.dig(:results, 'review_runtime', 'running_version')
      assert_equal original, @service.store.load.fetch('config')
      assert_equal '2026.11.0-latest', @service.lock.dig('app', 'version')
    end
  end

  def test_runtime_new_base_same_version_but_new_schema_stales_old_plan_and_uses_new_runtime
    with_base do
      old_plan = base_plan
      @service.approve_plan(plan_id: old_plan[:plan_id], sha256: old_plan[:digest], reviewer: 'engineer')
      replace_base(version: '2026.11.0-latest', schema: '20261109000000')
      runtime_profile('new-same-version', version: '2026.11.0-latest', schema: '20261109000000')
      @env['SILO_REVIEW_RUNTIME_PROFILE'] = 'new-same-version'
      assert_equal 'stale', @service.show_plan(old_plan[:plan_id])[:status]
      standard_error('STANDARD_STALE_PLAN') { @service.claim(plan_id: old_plan[:plan_id]) }
      plan = base_plan
      assert_equal 'new-same-version', plan[:discourse_profile]
      assert_equal '20261109000000', plan.dig(:base_site, 'site_schema_version')
      run = run_review(plan)
      assert_equal 'completed', run[:status], run.inspect
      assert_equal '20261109000000', run.dig(:results, 'review_runtime', 'schema_after_restore')
      assert_equal true, run.dig(:results, 'review_runtime', 'known_migrations_complete')
      refute_includes JSON.generate(@service.status), 'private-replacement'
    end
  end

  def test_runtime_relabel_to_stable_selects_stable_without_changing_workspace
    with_base do
      old = run_review(base_plan)
      original_runtime = old.dig(:results, 'review_runtime').dup
      replace_base(version: '2026.11.0', schema: '20261104011110')
      runtime_profile('stable-current', version: '2026.11.0')
      plan = base_plan
      assert_equal 'stable', plan.dig(:review_runtime, 'track')
      assert_equal 'stable-current', plan[:discourse_profile]
      assert_equal '2026.11.0', plan.dig(:review_runtime, 'actual_version')
      assert_equal original_runtime, @service.show_run(old[:run_id]).dig(:results, 'review_runtime')
      assert_equal SiloMigrate::RuntimeProfiles::DEFAULT, @service.store.load.dig('config', 'discourse_profile')
    end
  end

  def test_runtime_profile_change_stales_approval_in_a_new_process
    with_base do
      path = runtime_profile('host-prepared', version: '2026.11.0-latest')
      @env['SILO_REVIEW_RUNTIME_PROFILE'] = 'host-prepared'
      plan = base_plan
      @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'engineer')
      File.write(path, File.read(path) + "\n")
      assert_equal 'stale', new_standard.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_STALE_PLAN') { @service.claim(plan_id: plan[:plan_id]) }
      refute @service.store.load.fetch('config')['discourse_profile'] == 'host-prepared'
    end
  end

  def test_runtime_base_replacement_stales_pending_fresh_proposal
    with_base do
      plan = propose_review
      replace_base(version: '2026.11.0-latest', schema: '20261109000000')
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
    end
  end

  def test_runtime_missing_after_claim_is_a_durable_failure_not_an_abandoned_claim
    with_base do
      path = runtime_profile('host-prepared', version: '2026.11.0-latest')
      @env['SILO_REVIEW_RUNTIME_PROFILE'] = 'host-prepared'
      plan = base_plan
      @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'engineer')
      run = @service.claim(plan_id: plan[:plan_id])
      File.unlink(path)
      result = @service.execute(run_id: run[:run_id])
      assert_equal 'failed', result[:status]
      assert_equal 'STANDARD_RUNTIME_MISMATCH', result.dig(:failure, 'code')
    end
  end
end

class StandardMergeRuntimeTest < StandardMergeRunTest
  def self.runnable_methods
    public_instance_methods.grep(/^test_runtime_/).map(&:to_s)
  end

  def test_runtime_newer_merge_source_has_an_input_compatibility_error_not_reset_guidance
    with_merge do
      dataset = @service.store.named_state.fetch('inputs').fetch(@merge_source).fetch('dataset_id')
      previous, @dataset = @dataset, dataset
      newer = add_input('invented-source-v2026-12-0-latest-20261201000000.tar.gz', 'invented-not-loaded', 'discourse-backup')
      @dataset = previous
      standard_error('STANDARD_MERGE_SOURCE_NEWER') { @service.propose_merge_plan(source: newer, base_site: @base) }
      message = SiloMigrate::Services::StandardWorkflowService::RECOVERY['STANDARD_MERGE_SOURCE_NEWER']
      assert_includes message, 'resetting alone will not fix it'
    end
  end

  def test_runtime_merge_pins_a_separate_review_profile_without_rebinding_converter
    with_merge do
      original = @service.store.load.fetch('config').dup
      profile = JSON.parse(File.read(File.join(@code_root, 'runtime/profiles', SiloMigrate::RuntimeProfiles::DEFAULT + '.json')))
      profile['qualification'] = { 'status' => 'review_ready', 'scope' => %w[review merge] }
      File.write(File.join(@code_root, 'runtime/profiles', 'merge-runtime.json'), JSON.generate(profile))
      @env['SILO_REVIEW_RUNTIME_PROFILE'] = 'merge-runtime'
      plan = merge_plan
      assert_equal 'merge-runtime', plan[:discourse_profile]
      assert_equal original, @service.store.load.fetch('config')
      run = run_review(plan)
      assert_equal 'completed', run[:status], run.inspect
      assert_equal '2026.11.0-latest', run.dig(:results, 'review_runtime', 'running_version')
      assert_equal original, @service.store.load.fetch('config')
    end
  end
end
