# frozen_string_literal: true
require_relative 'standard_full_run_test'
require_relative 'standard_cli_test'

class StandardProfilesTest < SiloMigrateTest
  include StandardTestWorkspace

  def profile_path
    File.join(@code_root, 'runtime/profiles', SiloMigrate::RuntimeProfiles::DEFAULT + '.json')
  end

  def test_shared_content_identity_is_independent_of_store_id_and_nulls
    document = JSON.parse(File.read(File.join(__dir__, 'fixtures/image-inspect-sample.json'))).first
    expected = File.read(File.join(__dir__, 'fixtures/image-inspect-sample.content_id')).strip
    assert_equal 'sha256:e20fde703d5f512320bc06904f8a6cce9822525ad07479caafce80089306bb22', expected
    assert_equal expected, SiloMigrate::ImageIdentity.content_id(document)
    document['Id'] = 'sha256:' + 'f' * 64
    document['Config']['Entrypoint'] = []
    document['Config']['User'] = ''
    document['RepoTags'] = ['different/store:tag']
    assert_equal expected, SiloMigrate::ImageIdentity.content_id(document)
    document['Config']['WorkingDir'] = '/unicode/é'
    assert_equal 'sha256:39405c5c2f3e42752430fb90b687c065af80810c1a131cc3d5c59062eee83fad', SiloMigrate::ImageIdentity.content_id(document)
    document['Config']['WorkingDir'] = '/app'
    document['Config']['Env'].reverse!
    refute_equal expected, SiloMigrate::ImageIdentity.content_id(document), 'list ordering is content'
  end

  def test_profile_content_changes_and_deletion_stale_even_in_same_service
    with_standard do
      plan = approve
      contents = File.read(profile_path)
      File.write(profile_path, contents + "\n")
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_STALE_PLAN') { propose }
      File.write(profile_path, contents)
      assert_equal 'approved', @service.show_plan(plan[:plan_id])[:status]
      File.unlink(profile_path)
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_STALE_PLAN') { @service.claim(plan_id: plan[:plan_id]) }
    end
  end

  def test_server_profiles_are_explicit_and_duplicate_names_refused
    with_standard do
      extra = File.join(File.dirname(@code_root), 'server-profiles')
      FileUtils.mkdir_p(extra)
      @env['SILO_RUNTIME_PROFILES_DIR'] = extra
      @env['SILO_RUNTIME_PROFILES_DIR'] = File.dirname(profile_path)
      assert_equal [SiloMigrate::RuntimeProfiles::DEFAULT], @service.profiles.names
      assert_equal 'qualified', @service.profiles.show(SiloMigrate::RuntimeProfiles::DEFAULT)[:profile].dig('qualification', 'status')
      @env['SILO_RUNTIME_PROFILES_DIR'] = extra
      FileUtils.cp(profile_path, File.join(extra, 'candidate.json'))
      assert_includes @service.profiles.names, 'candidate'
      assert_equal 'qualified', @service.profiles.show('candidate')[:profile].dig('qualification', 'status')
      assert_equal SiloMigrate::RuntimeProfiles::DEFAULT, @service.store.load.dig('config', 'discourse_profile')
      FileUtils.cp(profile_path, File.join(extra, File.basename(profile_path)))
      standard_error('STANDARD_RUNTIME_MISMATCH') { @service.profiles.show(SiloMigrate::RuntimeProfiles::DEFAULT) }
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.profiles.show('../candidate') }
    end
  end

  def test_profile_list_checks_every_image_content_not_local_id
    with_standard do
      @runtime.images_match = true
      entry = @service.profiles.list.first
      assert_equal true, entry[:local_images_match]
      assert_equal 'latest', entry[:selector]['channel']
      @runtime.inspect_document = JSON.parse(File.read(File.join(__dir__, 'fixtures/image-inspect-sample.json'))).first
      @runtime.inspect_document['Config']['WorkingDir'] = '/wrong'
      assert_equal false, @service.profiles.list.first[:local_images_match]
      run = @service.run_plan(plan_id: approve[:plan_id])
      assert_equal 'STANDARD_RUNTIME_MISMATCH', run[:failure]['code']
      refute @runtime.commands.any? { |call| call[1][0, 2] == %w[docker run] }
    end
  end

  def test_converter_dirty_head_change_and_refresh_binding
    with_standard do
      plan = approve
      @runtime.converter_dirty = true
      assert_equal true, @service.converter_status[:dirty]
      assert_equal 'unknown', @service.converter_status[:ahead]
      standard_error('STANDARD_CONVERTER_DIRTY') { propose }
      standard_error('STANDARD_CONVERTER_DIRTY') { @service.claim(plan_id: plan[:plan_id]) }
      standard_error('STANDARD_CONVERTER_DIRTY') { @service.converter_refresh }
      @runtime.converter_dirty = false
      @runtime.converter_head = 'b' * 40
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_STALE_PLAN') { propose }
      @service.converter_refresh
      assert_equal 'b' * 40, propose[:converter]['commit']
      current = approve
      @service.converter_refresh
      assert_equal 'stale', @service.show_plan(current[:plan_id])[:status], 'explicit refresh invalidates approvals even at same HEAD'
    end
  end

  def test_converter_metadata_scrubs_credentials_and_detached_head
    with_standard do
      @runtime.converter_repo = 'https://user:private-token@example.test/org/converters.git'
      @runtime.converter_branch = 'HEAD'
      result = @service.converter_refresh
      assert_equal 'https://example.test/org/converters.git', result[:repo]
      assert_equal 'detached', result[:branch]
      refute_includes JSON.generate(propose), 'private-token'
      @runtime.converter_repo = 'git@example.test:org/converters.git'
      assert_equal 'example.test:org/converters.git', @service.converter_status[:repo]
    end
  end

  def test_init_defaults_to_workspace_converter_and_env_site_cache
    with_standard do
      @named.init('other')
      root = File.join(@env.fetch('SILO_MIGRATE_BASE_PATH'), 'other')
      FileUtils.mkdir_p(File.join(root, 'converter'))
      @env['SILO_CONTROL_SITE_CACHE'] = @service.store.load.dig('config', 'site_settings')
      other = SiloMigrate::Services::StandardWorkflowService.new('other', env: @env, runtime: @runtime, code_root: @code_root)
      assert_equal 'initialized', other.init[:status]
      config = other.store.load.fetch('config')
      assert_equal File.join(root, 'converter'), config['converter_worktree']
      assert_equal 'a' * 40, config.dig('converter', 'commit')
      assert_equal Digest::SHA256.file(profile_path).hexdigest, config['discourse_profile_sha256']
      assert @runtime.commands.none? { |call| %w[checkout reset clean pull fetch merge].any? { |verb| call[1].include?(verb) } }
    end
  end
end

class StandardFullRunTest
  def test_unqualified_override_is_explicit_and_carried_to_manifest
    with_complete do
      path = File.join(@code_root, 'runtime/profiles', SiloMigrate::RuntimeProfiles::DEFAULT + '.json')
      profile = JSON.parse(File.read(path))
      profile['qualification']['status'] = 'candidate'
      candidate = File.join(File.dirname(path), 'candidate.json')
      File.write(candidate, JSON.generate(profile))
      # Select before planning, just as init does; active selection is never automatic.
      @service.store.update do |state|
        state['config']['discourse_profile'] = 'candidate'
        state['config']['discourse_profile_sha256'] = Digest::SHA256.file(candidate).hexdigest
      end
      standard_error('STANDARD_RUNTIME_UNQUALIFIED') { propose }
      plan = @service.propose_plan(dataset_id: @dataset, allow_unqualified_runtime: true)
      assert_equal false, plan[:runtime_qualified]
      assert_equal true, plan[:allow_unqualified_runtime]
      approve(plan)
      run = completed_run(plan)
      manifest = JSON.parse(File.read(@service.store.run_dir(run[:run_id], 'evidence', 'final.manifest.json')))
      assert_equal false, manifest['runtime_qualified']
      assert_equal false, manifest.dig('lineage', 'runtime_qualified')
      assert_equal 'candidate', manifest.dig('lineage', 'discourse_profile')
      assert_equal 'a' * 40, manifest.dig('lineage', 'converter', 'commit')
    end
  end
end
