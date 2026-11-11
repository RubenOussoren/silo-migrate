# frozen_string_literal: true
require_relative 'standard_review_run_test'

class BaseSiteScriptedRuntime < ReviewScriptedRuntime
  attr_accessor :site_version, :site_schema, :backup_content, :prior_ids, :admin_before_backup, :stored_allow_restore

  attr_accessor :runtime_image_documents

  def run(cmd, **options)
    if cmd[0, 3] == %w[docker image inspect] && runtime_image_documents&.key?(cmd.last)
      @calls << cmd
      return review_ok(JSON.generate([runtime_image_documents.fetch(cmd.last)]))
    end
    line = cmd.join(' ')
    if cmd[0, 2] == %w[docker run] && cmd.include?('--entrypoint') && cmd.include?('ruby')
      @calls << cmd
      return review_ok(JSON.generate(service.lock.dig('review_runtime', 'core_migrations') || ['20261104011110']))
    elsif line.include?('-review') && line.include?('review_state.rb') && cmd[1] == 'exec' && !cmd.include?('chown')
      @calls << cmd
      settings = service.send(:review_environment, 18080).to_h do |key, value|
        [key.delete_prefix('DISCOURSE_').downcase, %w[true false].include?(value) ? value == 'true' : value]
      end
      port = service.store.load.fetch('instances').values.last.fetch('port')
      settings['port'] = port
      image_schema = site_schema || service.lock.dig('review_runtime', 'schema_version') || '20261104011110'
      schema = @restored ? [service.store.load.fetch('plans').values.last.dig('body', 'base_site', 'schema_version'), image_schema].max : image_schema
      return site_json('discourse_version' => site_version || service.lock.dig('app', 'version'), 'schema_version' => schema,
                       'migration_versions' => service.lock.dig('review_runtime', 'core_migrations') || ['20261104011110'], 'prior_import_id_rows' => prior_ids || 7, 'settings' => settings.merge('disable_emails' => 'yes', 'allow_restore' => (@restored ? stored_allow_restore : false)))
    elsif line.include?('-review') && line.include?('review_access.rb') && cmd[1] == 'exec' && !cmd.include?('chown')
      @calls << cmd
      run = service.store.load.fetch('runs').values.last
      self.admin_before_backup = !run.dig('artifacts', 'backup')
      port = service.store.load.fetch('instances').values.last.fetch('port')
      return site_json('admin_username' => 'silo_review_admin', 'disable_emails' => 'yes', 'login_required' => true, 'allow_restore' => false,
                       'base_url' => "http://127.0.0.1:#{port}")
    elsif line.include?('script/discourse restore')
      @calls << cmd
      @restored = true
      self.stored_allow_restore = true # the invented sandbox stored allow_restore: on
      return review_ok("[SUCCESS]\n")
    elsif line.include?('script/discourse disable_restore')
      @calls << cmd
      self.stored_allow_restore = false
      return review_ok
    elsif line.include?('find /shared/silo-review-backup')
      @calls << cmd
      run_id = service.store.load.fetch('runs').keys.last
      schema = service.store.load.fetch('plans').values.last.dig('body', 'base_site', 'schema_version')
      return review_ok("synthetic-#{run_id}-v2026-11-0-latest-#{schema}.sql.gz\n")
    elsif cmd[0, 2] == %w[docker cp] && cmd[2].include?(':/shared/silo-review-backup/')
      @calls << cmd
      Zlib::GzipWriter.open(cmd[3]) { |gzip| gzip.write(backup_content || "-- PostgreSQL database dump\nCREATE TABLE invented (id integer);\n") }
      return review_ok
    end
    super
  end
end

class StandardBaseSiteReviewTest < StandardReviewRunTest
  def self.runnable_methods
    public_instance_methods.grep(/^test_base_/).map(&:to_s)
  end

  def with_base(ahead: false)
    with_review do
      runtime = BaseSiteScriptedRuntime.new
      runtime.service = @service
      @runtime = runtime
      @service.instance_variable_set(:@runtime, runtime)
      source = @service.store.named_state.fetch('sources').keys.first
      dataset = @named.add_dataset('synthetic', source_id: source)[:dataset_id]
      path = File.join(@root, '.silo-migrate/named/deliveries.json')
      deliveries = JSON.parse(File.read(path))
      deliveries.fetch('deliveries')[dataset] = { 'dataset_id' => dataset, 'kind' => 'base_site', 'version' => 2 }
      File.write(path, JSON.generate(deliveries))
      previous = @dataset
      @dataset = dataset
      buffer = StringIO.new
      gzip = Zlib::GzipWriter.new(buffer)
      @base_schema = ahead ? '20261109000000' : '20261104011110'
      gzip.write("-- PostgreSQL database dump\nCOPY public.schema_migrations (version) FROM stdin;\n20261104011110\n#{ahead ? @base_schema + "\n" : ""}\\.\n")
      gzip.close
      @base = add_input("customer-secret-v2026-11-0-latest-#{@base_schema}.sql.gz", buffer.string, 'base_site')
      @dataset = previous
      @base_dataset = dataset
      yield
    end
  end

  def base_plan
    propose_review(base_site: @base)
  end

  def base_run
    run_review(base_plan)
  end

  def edit_delivery(dataset)
    path = File.join(@root, '.silo-migrate/named/deliveries.json')
    deliveries = JSON.parse(File.read(path))
    yield deliveries.fetch('deliveries').fetch(dataset)
    File.write(path, JSON.generate(deliveries))
  end

  def test_base_plan_binding_and_stage_order
    with_base do
      plan = base_plan
      assert_equal @base, plan.dig(:base_site, 'input_id')
      assert_equal({ 'kind' => 'base_site', 'version' => 2 }, plan.dig(:base_site, 'delivery'))
      refute_includes JSON.generate(plan), 'customer-secret'
      refute_equal plan[:outputs], base_plan[:outputs]
      body = @service.store.load.fetch('plans').fetch(plan[:plan_id])
      assert_equal %w[preflight site_up base_restore import verify backup site_setup review_url], @service.send(:stages_for, body)
      fresh_id = propose_review[:plan_id]
      fresh = @service.store.load.fetch('plans').fetch(fresh_id)
      assert_equal %w[preflight site_up site_setup import verify review_url], @service.send(:stages_for, fresh)
      assert_equal 2, body.dig('body', 'input_binding').size
    end
  end

  def test_base_wrong_input_type
    with_base { standard_error('STANDARD_INPUTS_INCOMPLETE') { propose_review(base_site: @ids['settings']) } }
  end

  def test_base_wrong_delivery_kind_and_replaced
    with_base do
      edit_delivery(@base_dataset) { |d| d['kind'] = 'development' }
      standard_error('STANDARD_DELIVERY_MIXED') { base_plan }
      edit_delivery(@base_dataset) { |d| d['kind'] = 'base_site'; d['replaced_by'] = 'other' }
      standard_error('STANDARD_DELIVERY_UNLABELLED') { base_plan }
    end
  end

  def test_base_cannot_be_source_delivery_or_other_role
    with_base do
      standard_error('STANDARD_DELIVERY_MIXED') { @service.send(:delivery_binding!, @base_dataset) }
      named = @service.store.named_state
      standard_error('STANDARD_DELIVERY_MIXED') { @service.send(:delivery_roles!, named, { 'settings' => @base }, { 'kind' => 'development' }) }
    end
  end

  def test_base_input_change_stales_plan
    with_base do
      plan = base_plan
      path = File.join(@root, @service.store.named_state.fetch('inputs').fetch(@base).fetch('path').unpack1('m0'))
      File.chmod(0600, path)
      File.write(path, 'changed')
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
    end
  end

  def test_base_invalid_and_newer_versions
    with_base do
      standard_error('STANDARD_BASE_SITE_INVALID') { @service.send(:base_site_versions!, 'invented.sql.gz') }
      older = { 'discourse_version' => '2026.10.0', 'schema_version' => '20261001000000' }
      newer = { 'discourse_version' => '2026.11.0-latest', 'schema_version' => '20261104011110' }
      standard_error('STANDARD_BASE_SITE_NEWER') { @service.send(:base_site_compatible!, newer, older) }
      assert_nil @service.send(:base_site_compatible!, older, newer)
      @runtime.site_version = '2026.10.0'
      run = base_run
      assert_equal 'STANDARD_REVIEW_RUNTIME_CHANGED', run.dig(:failure, 'code'), Dir.glob(@service.store.run_dir(run[:run_id], '**/*')).select { |p| File.file?(p) && p.include?('failure') }.map { |p| File.read(p) }.join
      refute @runtime.calls.any? { |cmd| cmd.join(' ').include?('script/discourse restore') }
    end
  end

  def test_base_whole_run_shadows_backup_then_admin
    with_base do
      run = base_run
      assert_equal 'completed', run[:status], run.inspect
      assert_equal true, run.dig(:results, 'base_site')
      refute run.fetch(:results).key?('prior_import_id_rows')
      refute run.fetch(:results).key?('base_site_newer_migrations')
      assert_equal 7, @service.store.load.dig('runs', run[:run_id], 'results', 'prior_import_id_rows')
      assert run.dig(:artifacts, 'backup', 'sha256')
      assert_equal false, @runtime.admin_before_backup
      web = @runtime.calls.find { |cmd| cmd[0, 2] == %w[docker run] && cmd.include?('DISCOURSE_LOGIN_REQUIRED=true') }
      refute_nil web
      @service.send(:review_environment, 18080).each_key { |key| assert web.any? { |arg| arg.start_with?("#{key}=") }, key }
      restore = @runtime.calls.find { |cmd| cmd.join(' ').include?('script/discourse restore') }
      assert_includes restore.join(' '), 'silo-base-v2026-11-0-latest-20261104011110.sql.gz'
      refute_includes restore.join(' '), 'customer-secret'
      assert @runtime.calls.any? { |cmd| cmd.join(' ').include?('script/discourse disable_restore') }
    end
  end

  def test_base_restore_disables_stored_allow_restore_before_verification
    with_base do
      run = base_run
      assert_equal 'completed', run[:status], run.inspect
      assert_equal false, @runtime.stored_allow_restore
      restore = @runtime.calls.index { |cmd| cmd.join(' ').include?('script/discourse restore') }
      disable = @runtime.calls.index { |cmd| cmd.join(' ').include?('script/discourse disable_restore') }
      assert_operator disable, :>, restore
    end
  end

  def test_base_ahead_is_approved_and_restored_under_image_suffix
    with_base(ahead: true) do
      plan = base_plan
      assert_equal true, plan.dig(:base_site, 'ahead')
      assert_equal '20261104011110', plan.dig(:base_site, 'site_schema_version')
      assert plan[:mutations].any? { |text| text.include?("It will be restored anyway.") }
      run = run_review(plan)
      assert_equal 'completed', run[:status], run.inspect
      assert_equal 1, run.dig(:results, 'base_site_unknown_migrations')
      assert_equal ['20261109000000'], @service.store.load.dig('runs', run[:run_id], 'results', 'base_site_newer_migrations')
      assert_equal '20261109000000', run.dig(:results, 'schema_version')
      assert_includes run.dig(:artifacts, 'backup', 'filename'), '20261109000000.sql.gz'
      restore = @runtime.calls.find { |cmd| cmd.join(' ').include?('script/discourse restore') }
      assert_includes restore.join(' '), 'silo-base-v2026-11-0-latest-20261104011110.sql.gz'
    end
  end

  def test_base_live_ahead_disagreement_is_refused
    with_base(ahead: true) do
      plan = base_plan
      @runtime.site_schema = '20261109000000'
      run = run_review(plan)
      assert_equal 'STANDARD_REVIEW_RUNTIME_CHANGED', run.dig(:failure, 'code')
    end
  end

  def test_base_newer_discourse_is_refused_at_propose
    with_base do
      previous = @dataset
      @dataset = @base_dataset
      newer = add_input('private-v2099-1-0-20261109000000.sql.gz', 'invented', 'base_site')
      @dataset = previous
      standard_error('STANDARD_REVIEW_RUNTIME_UNRESOLVED') { propose_review(base_site: newer) }
    end
  end

  def test_base_dump_migration_scan_is_bounded_and_requires_copy_block
    with_base do
      path = File.join(@dir, 'dump.sql.gz')
      dump = "-- PostgreSQL database dump\n" + ('x' * 200_000) + "\nCOPY public.schema_migrations (version) FROM stdin;\n20261104011110\n20261109000000\n\\.\n"
      Zlib::GzipWriter.open(path) { |gzip| gzip.write(dump) }
      assert_equal %w[20261104011110 20261109000000], @service.send(:base_site_dump_migrations!, path)
      Zlib::GzipWriter.open(path) { |gzip| gzip.write('-- PostgreSQL database dump') }
      standard_error('STANDARD_BASE_SITE_INVALID') { @service.send(:base_site_dump_migrations!, path) }
      Zlib::GzipWriter.open(path) { |gzip| gzip.write("COPY public.schema_migrations (version) FROM stdin;\nnot-a-version\n\\.\n") }
      standard_error('STANDARD_BASE_SITE_INVALID') { @service.send(:base_site_dump_migrations!, path) }
    end
  end

  def test_base_fresh_mode_does_not_receive_base_site_shadows
    with_base do
      plan = propose_review
      run = run_review(plan)
      assert_equal 'completed', run[:status], run.inspect
      web = @runtime.calls.find { |cmd| cmd[0, 2] == %w[docker run] && cmd.include?("#{instance_name(plan)}-web") }
      refute_nil web
      @service.send(:review_environment, 18080).each_key do |key|
        refute web.any? { |arg| arg.start_with?("#{key}=") }, key
      end
      refute run.fetch(:artifacts).key?('backup')
      refute run.key?(:release)
    end
  end

  def test_base_admin_refuses_without_backup
    with_base do
      plan = base_plan
      @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'engineer')
      claim = @service.claim(plan_id: plan[:plan_id])
      # Refusal is before any helper execution, even with no running stack.
      @service.define_singleton_method(:stack_for) { |*_args| Object.new }
      standard_error('STANDARD_RELEASE_NOT_READY') { @service.send(:review_site_setup, claim[:run_id]) }
    end
  end

  def test_base_backup_validation_streams_and_checks_gzip
    with_base do
      path = File.join(@dir, 'invented-v2026-11-0-latest-20261104011110.sql.gz')
      validate = ->(text) do
        Zlib::GzipWriter.open(path) { |gzip| gzip.write(text) }
        @service.send(:validate_sql_backup!, path)
      end
      assert_equal '20261104011110', validate.call("-- PostgreSQL database dump\n" + 'x' * 100_000).fetch('schema_version')
      standard_error('STANDARD_BACKUP_FAILED') { validate.call('not sql') }
      %w[silo_review_admin review-admin@example.invalid].each do |forbidden|
        standard_error('STANDARD_BACKUP_FAILED') { validate.call("-- PostgreSQL database dump\n".ljust(65_530, 'x') + forbidden) }
      end
      validate.call('-- PostgreSQL database dump')
      File.open(path, 'r+b') { |file| file.truncate(File.size(path) - 5) }
      standard_error('STANDARD_BACKUP_FAILED') { @service.send(:validate_sql_backup!, path) }
    end
  end

  def test_base_scanners_refuse_concatenated_gzip_members
    with_base do
      path = File.join(@dir, 'invented-v2026-11-0-latest-20261104011110.sql.gz')
      Zlib::GzipWriter.open(path) { |gzip| gzip.write("-- PostgreSQL database dump\nCOPY public.schema_migrations (version) FROM stdin;\n20261104011110\n\\.\n") }
      File.open(path, 'ab') do |file|
        gzip = Zlib::GzipWriter.new(file)
        gzip.write("-- silo_review_admin hidden in a second member\n")
        gzip.close
      end
      standard_error('STANDARD_BASE_SITE_INVALID') { @service.send(:base_site_dump_migrations!, path) }
      standard_error('STANDARD_BACKUP_FAILED') { @service.send(:validate_sql_backup!, path) }
    end
  end

  def test_base_public_results_exclude_private_dump_facts
    with_base(ahead: true) do
      run = base_run
      private_results = @service.store.load.dig('runs', run[:run_id], 'results')
      assert_equal ['20261109000000'], private_results['base_site_newer_migrations']
      assert_equal 7, private_results['prior_import_id_rows']
      shown = @service.show_run(run[:run_id]).fetch(:results)
      refute shown.key?('base_site_newer_migrations')
      refute shown.key?('prior_import_id_rows')
      assert_equal 1, shown['base_site_unknown_migrations']
      assert_equal true, shown['base_site_ahead']
    end
  end

  def test_base_cli_propose_and_release_contract
    with_base do
      invoke = lambda do |args|
        output = StringIO.new
        error = StringIO.new
        cli = SiloMigrate::StandardCLI.new(env: @env, output: output, error: error)
        service = @service
        cli.define_singleton_method(:service) { |_workspace| service }
        [cli.run(args), output.string, error.string]
      end
      code, output, error = invoke.call(['plan', 'propose', 'synthetic', '--operation', 'review', '--from-run', @convert[:run_id], '--base-site', @base])
      assert_equal 0, code, error
      assert_equal @base, JSON.parse(output).dig('base_site', 'input_id')
      run = base_run
      args = ['run', 'release', 'synthetic', run[:run_id], '--reviewer', 'engineer']
      code, _output, error = invoke.call(args.dup)
      assert_equal 1, code
      assert_includes error, 'STANDARD_RELEASE_CHECKS'
      code, output, error = invoke.call(args + ['--acknowledge-differences'])
      assert_equal 0, code, error
      assert_equal %w[bytes filename manifest outbox released_at released_by run_id sha256], JSON.parse(output).keys.sort
      assert_equal 1, invoke.call(args + ['--acknowledge-differences', '--acknowledge-differences']).first
      assert_equal 1, invoke.call(['agent', 'run-release', 'synthetic', run[:run_id], '--reviewer', 'engineer']).first
    end
  end

  def test_base_release_manifest_idempotence_modes_and_missing_file
    with_base do
      run = base_run
      release = @service.release_backup(run_id: run[:run_id], reviewer: 'engineer', acknowledge_differences: true)
      output = File.join(release[:outbox], release[:filename])
      assert_equal File.join(@root, 'outbox'), release[:outbox]
      assert_equal 0400, File.stat(output).mode & 0777
      assert_equal 0700, File.stat(release[:outbox]).mode & 0777
      assert_equal 0400, File.stat(File.join(release[:outbox], release[:manifest])).mode & 0777
      manifest = JSON.parse(File.read(File.join(release[:outbox], release[:manifest])))
      assert_equal @base, manifest.dig('base_site', 'input_id')
      assert_equal 2, manifest.dig('base_site', 'delivery', 'version')
      assert_equal true, manifest['differences_acknowledged']
      assert_equal 'Restore on a site at schema version 20261104011110 or newer (same or newer Discourse).', manifest['restore_note']
      refute_includes JSON.generate(manifest), 'customer-secret'
      assert_equal release, @service.release_backup(run_id: run[:run_id], reviewer: 'another')
      File.unlink(output)
      assert_equal release, @service.release_backup(run_id: run[:run_id], reviewer: 'another')
      assert_equal release[:sha256], Digest::SHA256.file(output).hexdigest
      public_release = @service.show_run(run[:run_id]).fetch(:release)
      assert_equal 'engineer', public_release['released_by']
      assert_equal release[:outbox], public_release['outbox']
      assert_equal release[:filename], public_release['filename']
      assert_equal release[:manifest], public_release['manifest']
      assert_equal true, public_release['acknowledged_differences']
      recorded = @service.store.load.dig('runs', run[:run_id], 'release')
      assert_equal release[:outbox], recorded['outbox']
      assert_equal release[:filename], recorded['filename']
      assert_equal release[:manifest], recorded['manifest']
      assert_equal true, recorded['acknowledged_differences']
    end
  end

  def test_base_release_checks_and_changed_artifact
    with_base do
      run = base_run
      standard_error('STANDARD_RELEASE_CHECKS') { @service.release_backup(run_id: run[:run_id], reviewer: 'engineer') }
      @service.store.update { |state| state.fetch('runs').fetch(run[:run_id])['results'].merge!('reconciliation_checks' => 2, 'reconciliation_matched' => 2, 'reconciliation_errors' => 0) }
      assert @service.release_backup(run_id: run[:run_id], reviewer: 'engineer')[:filename]
      path = @service.store.load.dig('runs', run[:run_id], 'artifacts', 'backup', 'path')
      File.chmod(0600, path)
      File.write(path, 'changed')
      standard_error('STANDARD_ARTIFACT_CHANGED') { @service.release_backup(run_id: run[:run_id], reviewer: 'engineer', acknowledge_differences: true) }
    end
  end

  def test_base_release_survives_reset_and_refuses_backup_symlinks
    with_base do
      run = base_run
      release = @service.release_backup(run_id: run[:run_id], reviewer: 'engineer', acknowledge_differences: true)
      source = @service.store.load.dig('runs', run[:run_id], 'artifacts', 'backup', 'path')
      output = File.join(release[:outbox], release[:filename])
      assert_equal File.stat(source).ino, File.stat(output).ino
      @service.reset_run(run_id: run[:run_id], yes: true)
      File.unlink(source)
      assert_equal release[:sha256], Digest::SHA256.file(output).hexdigest
      File.symlink(output, source)
      standard_error('STANDARD_ARTIFACT_CHANGED') { @service.release_backup(run_id: run[:run_id], reviewer: 'engineer') }
    end
  end

  def test_base_release_falls_back_to_streamed_copy
    with_base do
      run = base_run
      File.stub(:link, ->(*_args) { raise Errno::EXDEV }) do
        release = @service.release_backup(run_id: run[:run_id], reviewer: 'engineer', acknowledge_differences: true)
        source = @service.store.load.dig('runs', run[:run_id], 'artifacts', 'backup', 'path')
        output = File.join(release[:outbox], release[:filename])
        assert_equal 0400, File.stat(output).mode & 0777
        assert_equal 0400, File.stat(File.join(release[:outbox], release[:manifest])).mode & 0777
        refute_equal File.stat(source).ino, File.stat(output).ino
        assert_equal release[:sha256], Digest::SHA256.file(output).hexdigest
      end
    end
  end

  def test_base_release_refuses_existing_output_with_different_bytes
    with_base do
      run = base_run
      artifact = @service.store.load.dig('runs', run[:run_id], 'artifacts', 'backup')
      outbox = File.join(@root, 'outbox')
      Dir.mkdir(outbox, 0700)
      output = File.join(outbox, artifact.fetch('filename'))
      File.write(output, 'different invented bytes')
      standard_error('STANDARD_ARTIFACT_CHANGED') do
        @service.release_backup(run_id: run[:run_id], reviewer: 'engineer', acknowledge_differences: true)
      end
      assert_equal 'different invented bytes', File.read(output)
      refute @service.show_run(run[:run_id]).key?(:release)
    end
  end

  def test_base_release_not_ready_and_symlink_refusal
    with_base do
      standard_error('STANDARD_RELEASE_NOT_READY') { @service.release_backup(run_id: @convert[:run_id], reviewer: 'engineer') }
      run = base_run
      File.symlink(@dir, File.join(@root, 'outbox'))
      standard_error('STANDARD_RELEASE_NOT_READY') { @service.release_backup(run_id: run[:run_id], reviewer: 'engineer', acknowledge_differences: true) }
      File.unlink(File.join(@root, 'outbox'))
      File.write(File.join(@root, 'outbox'), 'not a directory')
      standard_error('STANDARD_RELEASE_NOT_READY') { @service.release_backup(run_id: run[:run_id], reviewer: 'engineer', acknowledge_differences: true) }
    end
  end
end
