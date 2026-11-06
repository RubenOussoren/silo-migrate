# frozen_string_literal: true
require_relative 'standard_workflow_test'
require 'rubygems/package'
require 'sqlite3'

# Models command results and synthetic files, not workflow methods. The real
# service, stack, SQLite validators, archive readers, oracles and manifest writer
# all execute. No runtime command is forwarded to a shell or Docker.
class StandardCompleteRuntime < StandardScriptedRuntime
  SANDBOX = SiloMigrate::Services::StandardWorkflowService::SANDBOX_ATTACHMENT
  SOURCE = "Synthetic source attachment.\n"
  DATE = '2026-01-01T00:00:00Z'
  attr_accessor :service, :fail_stage, :occupied_kind, :stage_hook, :restore_runtime_failure
  attr_reader :observations, :http_requests, :backups

  def self.expected
    { 'users' => [{ 'user_id' => 1, 'username' => 'alice', 'email' => 'alice@example.test' }],
      'categories' => [{ 'category_id' => 2, 'slug' => 'imported', 'parent_category_id' => nil }],
      'topics' => [{ 'topic_id' => 3, 'topic_subject' => 'Imported topic', 'category_id' => 2, 'user_id' => 1, 'created_at' => DATE }],
      'posts' => [{ 'post_id' => 4, 'raw' => '<p>Complete source body.</p>', 'topic_id' => 3, 'post_number' => 1, 'user_id' => 1, 'created_at' => DATE,
        'attachments' => [{ 'attachment_id' => 5, 'file_name' => 'source.txt', 'bytes' => SOURCE.bytesize }] }],
      'counts' => { 'users' => 1, 'categories' => 1, 'topics' => 1, 'posts' => 1, 'attachments' => 1 } }
  end

  def initialize
    super
    self.images_match = true
    @sites = {}
    @backups = {}
    @remote_backups = {}
    @observations = []
    @http_requests = []
    @id_sequence = 0
    @seen_stages = {}
  end

  def current_run
    service.store.load.fetch('runs').values.last
  end

  def stage
    current_run&.fetch('stage')
  end

  def observe
    return unless service && current_run

    key = [current_run['id'], stage]
    unless @seen_stages[key]
      @seen_stages[key] = true
      stage_hook&.call(stage)
    end
    final = current_run.dig('artifacts', 'final')
    manifest = service.store.run_dir(current_run['id'], 'evidence', 'final.manifest.json')
    @observations << [stage, final && final['label'], File.file?(manifest) ? JSON.parse(File.read(manifest))['restore_status'] : nil]
  end

  def response(stdout = '', success: true)
    SiloMigrate::Runtime::CommandResult.new(success?: success, stdout: stdout, stderr: success ? '' : 'synthetic private failure', status: success ? 0 : 1)
  end

  def upload(id, filename, bytes, post)
    { 'id' => id, 'original_filename' => filename, 'extension' => 'txt', 'sha1' => Digest::SHA1.hexdigest(bytes),
      'filesize' => bytes.bytesize, 'url' => "/uploads/default/original/#{filename}", 'short_path' => "/short/#{filename}",
      'user_id' => 100, 'local_path_present' => true, 'file_sha256' => Digest::SHA256.hexdigest(bytes), 'post_references' => [post] }
  end

  def baseline
    { 'users' => [{ 'id' => 100, 'username' => 'sandbox_admin', 'email' => 'sandbox_admin@example.invalid', 'admin' => true },
                  { 'id' => 101, 'username' => 'sandbox_member', 'email' => 'sandbox_member@example.invalid' }],
      'categories' => [{ 'id' => 100, 'name' => 'Sandbox', 'slug' => 'sandbox' }],
      'topics' => [{ 'id' => 100, 'title' => 'Sandbox welcome topic', 'posts_count' => 1 }],
      'posts' => [{ 'id' => 100, 'topic_id' => 100, 'post_number' => 1, 'user' => 'sandbox_admin', 'raw' => 'Sandbox welcome.',
        'cooked' => '<p>Sandbox welcome.</p>' }],
      'uploads' => [upload(100, 'sandbox.txt', SANDBOX, 100)], 'groups' => [{ 'name' => 'sandbox', 'users' => ['sandbox_member'] }],
      'settings' => { 'disable_emails' => 'yes', 'title' => 'Synthetic sandbox' },
      'custom_fields' => %w[user category topic post].to_h { |kind| ["#{kind}_import_ids", []] } }
  end

  def imported
    site = baseline
    site['users'] << { 'id' => 200, 'import_id' => '1', 'username' => 'alice', 'email' => 'alice@example.test' }
    site['categories'] << { 'id' => 200, 'import_id' => '2', 'name' => 'Imported', 'slug' => 'imported', 'parent_import_id' => nil }
    site['topics'] << { 'id' => 200, 'import_id' => '3', 'title' => 'Imported topic', 'category_import_id' => '2', 'user' => 'alice', 'created_at' => DATE, 'posts_count' => 1 }
    site['posts'] << { 'id' => 200, 'import_id' => '4', 'topic_id' => 200, 'topic_import_id' => '3', 'post_number' => 1,
      'user' => 'alice', 'created_at' => DATE, 'raw' => 'Complete source body.',
      'cooked' => "<p>Complete source body. <a class=\"attachment\" href=\"/short/source.txt\">source.txt</a> (#{SOURCE.bytesize} Bytes)</p>" }
    site['uploads'] << upload(200, 'source.txt', SOURCE, 200)
    site['custom_fields'] = %w[user category topic post].zip(%w[1 2 3 4]).to_h { |kind, id| ["#{kind}_import_ids", [id]] }
    site
  end

  def fingerprint(web)
    site = Marshal.load(Marshal.dump(@sites.fetch(web, baseline)))
    app = service.lock.fetch('app')
    site['versions'] = { 'discourse' => app['version'], 'git' => app['revision'], 'ruby' => app['ruby'] }
    site['runtime'] = { 'base_url' => web.include?('-restore-') ? 'http://localhost' : 'http://127.0.0.1',
      'store_local' => true, 's3' => false, 'disable_emails' => 'yes', 'extensions' => app['required_extensions'],
      'pg_version' => "#{app['postgres_major']}.1", 'redis_version' => "#{app['redis_major']}.1", 'allow_restore' => false }
    if stage == 'verify_restore'
      site['runtime']['allow_restore'] = true if restore_runtime_failure == 'allow_restore'
      site['versions']['git'] = 'wrong-restored-revision' if restore_runtime_failure == 'revision'
    end
    if fail_stage == stage && %w[verify_site verify_restore].include?(stage)
      site['posts'].last['cooked'] = '<p>Wrong visible text.</p>'
    end
    site
  end

  def write_intermediate(path)
    db = SQLite3::Database.new(path)
    db.execute('CREATE TABLE users (username TEXT, email TEXT)')
    db.execute("INSERT INTO users VALUES ('alice', 'alice@example.test')")
    db.execute('CREATE TABLE categories (name TEXT, slug TEXT)')
    db.execute("INSERT INTO categories VALUES ('Imported', 'imported')")
    %w[topics posts].each do |table|
      db.execute("CREATE TABLE #{table} (id INTEGER)")
      db.execute("INSERT INTO #{table} VALUES (1)")
    end
    db.execute('CREATE TABLE uploads (display_filename TEXT, filename TEXT)')
    db.execute("INSERT INTO uploads VALUES ('source.txt', 'source.txt')")
  ensure
    db&.close
  end

  def write_processing(path)
    db = SQLite3::Database.new(path)
    db.execute('CREATE TABLE uploads (upload TEXT, markdown TEXT, skip_reason TEXT, skip_details TEXT)')
    db.execute("INSERT INTO uploads VALUES ('{}', 'upload://source.txt', NULL, NULL)")
  ensure
    db&.close
  end

  def write_archive(path, site)
    dump = StringIO.new
    gzip = Zlib::GzipWriter.new(dump)
    gzip.write('-- synthetic DB dump')
    gzip.finish
    members = { 'dump.sql.gz' => dump.string }
    site['uploads'].each do |record|
      members[record['url'].delete_prefix('/')] = record['original_filename'] == 'sandbox.txt' ? SANDBOX : SOURCE
    end
    members.delete('uploads/default/original/source.txt') if fail_stage == 'final_backup' && stage == 'final_backup'
    Zlib::GzipWriter.open(path) do |outer|
      Gem::Package::TarWriter.new(outer) do |tar|
        members.each { |name, bytes| tar.add_file_simple(name, 0o600, bytes.bytesize) { |entry| entry.write(bytes) } }
      end
    end
  end

  def run(cmd, **options)
    recorded = super
    observe
    text = cmd.join(' ')
    if %w[network volume container].include?(cmd[1]) && cmd[2] == 'inspect' && !cmd.include?('--format')
      return response('', success: cmd[1] == occupied_kind)
    elsif cmd.include?('git') && cmd.include?('rev-parse')
      return recorded
    elsif cmd.include?('./convert')
      write_intermediate(service.store.run_dir(current_run['id'], 'work', 'converter-output', 'intermediate.sqlite'))
      return response("== Run Summary ==\nErrors : 0 (conversion) + 0 (setup)\nSkipped by policy : 0\n")
    elsif cmd[0, 3] == %w[docker run -d]
      @id_sequence += 1
      return response(format('%064x', @id_sequence))
    elsif text.include?("ruby -e 'print RUBY_VERSION'")
      app = service.lock.fetch('app')
      return response([app['ruby'], app['bundler'], app['gemfile_lock_sha256'], app['revision']].join("\n"))
    elsif cmd.include?('curl')
      return response('200')
    elsif text.include?('rails runner')
      web = cmd.find { |arg| arg.end_with?('-web') }
      value = if text.include?('site_fingerprint.rb')
        fingerprint(web)
      elsif text.include?('baseline_seed.rb')
        @sites[web] = baseline
        { 'seeded' => true }
      elsif text.include?('set_review_port.rb')
        return response('', success: false) if fail_stage == stage && stage == 'review_url'
        port = cmd.grep(/\ASILO_SITE_PORT=/).first.split('=').last
        { 'base_url' => "http://127.0.0.1:#{port}" }
      else
        { 'restored' => true }
      end
      return response("SILO_JSON:#{JSON.generate(value)}\n")
    elsif text.include?('generic_bulk.rb')
      @sites[cmd[2]] = imported
      return response("Done! (0 minutes)\n")
    elsif text.include?('script/discourse backup ')
      web = cmd[2]
      path = Shellwords.split(cmd.last).last
      filename = "#{File.basename(path, '.tar.gz')}-v1.tar.gz"
      @remote_backups[web] = [filename, fingerprint(web)]
      return response
    elsif cmd[0, 2] == %w[docker exec] && cmd[3] == 'find'
      return response(@remote_backups.fetch(cmd[2])[0] + "\n")
    elsif cmd[0, 2] == %w[docker cp] && cmd[2].include?(':/')
      guest = cmd[2].split(':', 2).last
      if guest.end_with?('/uploads.sqlite3')
        write_processing(cmd[3])
      else
        filename, site = @remote_backups.fetch(cmd[2].split(':', 2).first)
        write_archive(cmd[3], site)
        @backups[filename] = Marshal.load(Marshal.dump(site))
      end
      return response
    elsif text.include?('script/discourse restore ')
      return response('restore rejected', success: false) if fail_stage == stage && stage == 'restore'
      tokens = Shellwords.split(cmd.last)
      filename = tokens[tokens.index('restore') + 1]
      @sites[cmd[2]] = Marshal.load(Marshal.dump(@backups.fetch(filename)))
      return response('[SUCCESS]')
    elsif cmd.include?('psql') && text.include?('COUNT(*)')
      return response('3|2|2|2')
    elsif cmd.include?('{{json .Mounts}}')
      return response('[]')
    end
    recorded
  end

  def http(url, _limit)
    observe
    @http_requests << url
    body = if url.end_with?('/latest.json')
      JSON.generate('topic_list' => { 'topics' => [{ 'title' => 'Sandbox welcome topic' }, { 'title' => 'Imported topic' }] })
    elsif url.end_with?('sandbox.txt')
      SANDBOX
    elsif url.end_with?('source.txt')
      SOURCE
    else
      'ok'
    end
    { status: 200, body: body }
  end
end

class StandardFullRunTest < SiloMigrateTest
  include StandardTestWorkspace

  def with_complete
    inputs = { 'source-sql' => '-- synthetic SQL', 'converter-settings' => "db:\n  host: synthetic-source\n  password: \"\"\n  sql_layout_override: inline_community_database\n",
      'expected' => JSON.generate(StandardCompleteRuntime.expected), 'upload' => StandardCompleteRuntime::SOURCE }
    with_standard(inputs: inputs) do
      @runtime = StandardCompleteRuntime.new
      @service = SiloMigrate::Services::StandardWorkflowService.new('synthetic', env: @env, runtime: @runtime, code_root: @code_root, execute_lock_wait: 0,
        http: @runtime.method(:http), port_probe: ->(_) { true }, disk_free: -> { 100 * 1024**3 }, sleeper: ->(_) {})
      @runtime.service = @service
      yield
    end
  end

  def completed_run(plan = approve)
    result = @service.run_plan(plan_id: plan[:plan_id])
    detail = @service.store.run_dir(result[:run_id], 'private', 'failure.json')
    assert_equal 'completed', result[:status], File.file?(detail) ? File.read(detail) : result.inspect
    assert_equal SiloMigrate::Services::StandardWorkflowService::STAGES.to_h { |stage| [stage, 'passed'] }, result[:stages]
    assert_equal 'restore-proven', result.dig(:artifacts, 'final', 'label')
    result
  end

  def test_all_stages_complete_and_manifest_describes_actual_lineage
    with_complete do
      plan = approve
      result = completed_run(plan)
      run = @service.store.load['runs'].fetch(result[:run_id])
      body = @service.store.load['plans'][plan[:plan_id]]['body']
      manifest = JSON.parse(File.read(@service.store.run_dir(result[:run_id], 'evidence', 'final.manifest.json')))
      assert_equal 'final', manifest['kind']
      assert_equal result[:run_id], manifest['run_id']
      assert_equal plan[:plan_id], manifest['plan_id']
      assert_equal plan[:digest], manifest['plan_digest']
      assert_equal 'restore-proven', manifest['restore_status']
      assert_equal run['artifacts']['final'].slice('filename', 'sha256', 'bytes'), manifest['archive']
      assert_equal Digest::SHA256.file(run['artifacts']['final']['path']).hexdigest, manifest['archive']['sha256']
      assert_equal File.size(run['artifacts']['final']['path']), manifest['archive']['bytes']
      %w[dataset_id code_identity converter_revision converter app_revision image_content_ids discourse_profile runtime_qualified runtime_lock_sha256 site_settings_sha256].each do |field|
        assert_equal body[field], manifest['lineage'][field], field
      end
      assert_equal run['artifacts']['resolved_image_ids'], manifest['lineage']['image_ids']
      image_ids = run['artifacts']['resolved_image_ids'].values
      creates = @runtime.commands.map { |op| op[1] }.select { |cmd| cmd[0, 2] == %w[docker run] }
      refute_empty creates
      assert creates.all? { |cmd| image_ids.any? { |id| cmd.include?(id) } }, 'every run uses a resolved local ID, never a tag'
      assert_equal image_ids.size, image_ids.uniq.size, 'fake stores expose distinct local IDs per ref'
      creates.each do |cmd|
        name = cmd.fetch(cmd.index('--name') + 1)
        role = name.end_with?('-source-db') ? 'source_db' : name.split('-').last
        role = 'web' if role == 'proxy'
        assert_includes cmd, run['artifacts']['resolved_image_ids'].fetch(role), name
      end
      assert_equal true, manifest['runtime_qualified']
      assert_equal body['input_binding'], manifest['lineage']['inputs']
      assert_equal({ 'mode' => 'seed' }, manifest['lineage']['baseline'])
      assert_equal run['artifacts']['baseline'].slice('filename', 'sha256', 'bytes'), manifest['lineage']['baseline_archive']
      %w[intermediate uploads_db].each { |kind| assert_equal run['artifacts'][kind], manifest['lineage'][kind] }
      assert_equal @runtime.fingerprint(run['instances']['restore'] + '-web')['versions'], manifest['lineage']['site_versions']
      assert_equal({ 'uploads/default/original/sandbox.txt' => Digest::SHA256.hexdigest(StandardCompleteRuntime::SANDBOX),
        'uploads/default/original/source.txt' => Digest::SHA256.hexdigest(StandardCompleteRuntime::SOURCE) }, manifest['required_uploads'])
      assert_equal [
        'synthetic sandbox_admin and sandbox_member accounts with a local password',
        "disable_emails=yes and the baseline's seeded site settings",
        'backup metadata base URL of the local review hostname; upstream restore remaps it',
        'posts not yet rebaked can still hold the local hostname in protocol-relative image URLs'
      ], manifest['carried_state']
      restored = JSON.parse(File.read(@service.store.run_dir(result[:run_id], 'evidence', 'site.restored.json')))
      assert_equal %w[sandbox_admin sandbox_member], restored['users'].reject { |user| user['import_id'] }.map { |user| user['username'] }
      assert_equal true, restored['users'].find { |user| user['username'] == 'sandbox_admin' }['admin']
      assert_equal 'yes', restored['settings']['disable_emails']
      refute_empty File.binread(@service.store.run_dir(result[:run_id], 'private', 'admin-password'))
      assert_equal 'http://127.0.0.1', JSON.parse(File.read(@service.store.run_dir(result[:run_id], 'evidence', 'site.imported.json')))['runtime']['base_url']
      assert run['restore_proven_at']
      %w[review_url restore verify_restore].each do |stage|
        samples = @runtime.observations.select { |entry| entry[0] == stage }
        refute_empty samples, stage
        assert samples.all? { |entry| entry[1] == 'archive-validated' && entry[2] == 'archive-validated' }, samples.inspect
      end
      assert @runtime.observations.none? { |entry| entry[1] == 'restore-proven' }
      assert @runtime.http_requests.any? { |url| url.end_with?('/latest.json') }
      assert @runtime.http_requests.any? { |url| url.end_with?('/short/source.txt') }
      assert_equal 1, result[:results]['imported_users']
      assert_equal 1, result[:results]['imported_topics']
      assert_equal 1, result[:results]['imported_posts']
      assert_equal 1, result[:results]['imported_attachments']
    end
  end

  { 'verify_site' => 'STANDARD_VERIFY_FAILED', 'final_backup' => 'STANDARD_BACKUP_FAILED',
    'review_url' => 'STANDARD_RUNNER_FAILED', 'restore' => 'STANDARD_RESTORE_FAILED', 'verify_restore' => 'STANDARD_RESTORE_FAILED' }.each do |stage, code|
    define_method("test_#{stage}_failure_never_promotes_final_to_restore_proven") do
      with_complete do
        @runtime.fail_stage = stage
        result = @service.run_plan(plan_id: approve[:plan_id])
        detail = @service.store.run_dir(result[:run_id], 'private', 'failure.json')
        assert_equal 'failed', result[:status], File.file?(detail) ? File.read(detail) : result.inspect
        assert_equal stage, result[:stage], File.read(detail)
        assert_equal code, result[:failure]['code']
        assert_equal SiloMigrate::Services::StandardWorkflowService::RECOVERY.fetch(code), result[:failure]['recovery']
        assert_equal 'failed', result[:stages][stage]
        refute_equal 'restore-proven', result.dig(:artifacts, 'final', 'label')
        record = @service.store.load['runs'][result[:run_id]]
        refute record.key?('restore_proven_at')
        assert @runtime.observations.none? { |entry| entry[1] == 'restore-proven' }
        if %w[review_url restore verify_restore].include?(stage)
          assert_equal 'passed', result[:stages]['final_backup']
          assert_equal 'archive-validated', result.dig(:artifacts, 'final', 'label')
          manifest = JSON.parse(File.read(@service.store.run_dir(result[:run_id], 'evidence', 'final.manifest.json')))
          assert_equal 'archive-validated', manifest['restore_status']
        end
        if %w[verify_site verify_restore].include?(stage)
          group = stage == 'verify_site' ? 'site' : 'restore'
          assert_equal 'failed', result[:assertions][group]['result']
          assert_operator result[:assertions][group]['failed'], :>, 0
        end
      end
    end
  end

  def test_full_run_uses_bound_copies_after_originals_are_changed
    with_complete do
      originals = @paths.transform_values { |path| File.binread(path) }
      mutated = false
      @runtime.stage_hook = lambda do |stage|
        next unless stage == 'convert'

        @paths.each_value { |path| File.binwrite(path, 'changed after preflight') }
        write(File.join(@root, 'inputs/dataset/uploads/.new-after-preflight'), 'not bound')
        mutated = true
      end
      result = completed_run
      assert mutated
      inputs = @service.send(:run_inputs, result[:run_id])
      assert_equal originals.size, inputs.size
      inputs.each do |input|
        assert_equal originals.fetch(input['type']), File.binread(@service.send(:input_path, result[:run_id], input))
      end
      @paths.each_value { |path| assert_equal 'changed after preflight', File.binread(path) }
      refute inputs.any? { |input| input['relative'].include?('.new-after-preflight') }
      sql_mount = @runtime.commands.flat_map { |op| op[1] }.grep(%r{:/run-fixture/snapshot\.sql:ro\z})
      assert_equal [@service.store.run_dir(result[:run_id], 'work', 'inputs/dataset/source-sql') + ':/run-fixture/snapshot.sql:ro'], sql_mount
      actual, shas, bytes = @service.send(:expected_for, result[:run_id])
      assert_equal StandardCompleteRuntime.expected, actual
      assert_equal [Digest::SHA256.hexdigest(StandardCompleteRuntime::SOURCE)], shas
      assert_equal [StandardCompleteRuntime::SOURCE], bytes.values
    end
  end

  def test_db_and_admin_passwords_are_not_in_any_runtime_argv
    with_complete do
      result = completed_run
      dir = @service.store.run_dir(result[:run_id], 'private')
      passwords = %w[review.env restore.env].flat_map { |name| File.readlines(File.join(dir, name)).map { |line| line.strip.split('=', 2).last } }
      passwords << File.binread(File.join(dir, 'admin-password'))
      passwords << File.binread(File.join(dir, 'converter', 'root-password'))
      argv = JSON.generate(@runtime.commands)
      passwords.uniq.each do |password|
        refute_empty password
        refute_includes argv, password
      end
      assert @runtime.commands.any? { |op| op[1].is_a?(Array) && op[1].include?('--env-file') }
    end
  end

  %w[network volume container].each do |kind|
    define_method("test_stack_refuses_existing_#{kind}_names_before_creating_resources") do
      with_complete do
        @runtime.occupied_kind = kind
        env_file = write(File.join(@root, 'synthetic-secret.env'), "DB_PASSWORD=not-in-argv\n")
        stack = SiloMigrate::Services::PrebuiltStack.new(runtime: @runtime, lock: @service.lock, name: 'synthetic-test-only')
        standard_error('STANDARD_STACK_FAILED') { stack.create!(hostname: 'localhost', port: 18000, env_file: env_file) }
        refute @runtime.commands.any? { |op| op[1].include?('create') || op[1][0, 3] == %w[docker run -d] }
      end
    end
  end

  def test_launch_from_accepted_baseline_preserves_lineage_and_skips_seed
    with_complete do
      first = completed_run
      accepted = @service.accept_baseline(run_id: first[:run_id], reviewer: 'engineer')
      plan = approve(@service.propose_plan(dataset_id: @dataset, baseline: accepted[:baseline_id]))
      before = @runtime.commands.size
      launched = completed_run(plan)
      commands = @runtime.commands.drop(before).map { |op| op[1].join(' ') }
      refute commands.any? { |text| text.include?('rails runner /tmp/baseline_seed.rb') }
      assert commands.any? { |text| text.include?('script/discourse restore baseline-') }
      assert_equal 'restore', launched[:results]['baseline_mode']
      manifest = JSON.parse(File.read(@service.store.run_dir(launched[:run_id], 'evidence', 'final.manifest.json')))
      assert_equal accepted[:baseline_id], manifest['lineage']['baseline']['baseline_id']
      assert_equal @service.store.load['accepted_baselines'][accepted[:baseline_id]]['sha256'], manifest['lineage']['baseline_archive']['sha256']
    end
  end

  { 'allow_restore' => 'runtime-restore-left-enabled', 'revision' => 'runtime-revision-mismatch' }.each do |field, failure|
    define_method("test_verify_restore_rejects_#{field}_even_with_matching_durable_content") do
      with_complete do
        @runtime.restore_runtime_failure = field
        result = @service.run_plan(plan_id: approve[:plan_id])
        assert_equal 'failed', result[:status]
        assert_equal 'verify_restore', result[:stage]
        assert_equal 'STANDARD_RESTORE_FAILED', result[:failure]['code']
        assert_equal 'passed', result[:stages]['restore']
        assert_equal 'failed', result[:assertions]['restore']['result']
        failures = JSON.parse(File.read(@service.store.run_dir(result[:run_id], 'evidence', 'restore.failures.json')))
        assert_includes failures, failure
        assert_equal 'archive-validated', result.dig(:artifacts, 'final', 'label')
        refute @service.store.load['runs'][result[:run_id]].key?('restore_proven_at')
        manifest = JSON.parse(File.read(@service.store.run_dir(result[:run_id], 'evidence', 'final.manifest.json')))
        assert_equal 'archive-validated', manifest['restore_status']
      end
    end
  end

  %w[fingerprint archive].each do |changed|
    define_method("test_execute_rechecks_accepted_baseline_#{changed}_after_claim") do
      with_complete do
        first = completed_run
        accepted = @service.accept_baseline(run_id: first[:run_id], reviewer: 'engineer')
        plan = approve(@service.propose_plan(dataset_id: @dataset, baseline: accepted[:baseline_id]))
        run_id = claim(plan)
        record = @service.store.load['accepted_baselines'][accepted[:baseline_id]]
        path = record.fetch(changed == 'fingerprint' ? 'fingerprint' : 'path')
        File.chmod(0o600, path)
        File.binwrite(path, 'changed after claim')
        result = new_standard.execute(run_id: run_id)
        assert_equal 'failed', result[:status]
        assert_equal 'preflight', result[:stage]
        assert_equal 'STANDARD_STALE_PLAN', result[:failure]['code']
        assert_equal 'pending', result[:stages]['convert']
        assert_equal result, new_standard.show_run(run_id)
        assert_empty result[:artifacts]
      end
    end
  end

  def test_tampered_accepted_baseline_fingerprint_invalidates_plan
    with_complete do
      first = completed_run
      accepted = @service.accept_baseline(run_id: first[:run_id], reviewer: 'engineer')
      plan = approve(@service.propose_plan(dataset_id: @dataset, baseline: accepted[:baseline_id]))
      path = @service.store.load['accepted_baselines'][accepted[:baseline_id]]['fingerprint']
      File.write(path, '{"tampered":true}')
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_STALE_PLAN') { @service.claim(plan_id: plan[:plan_id]) }
      assert_equal 1, @service.store.load['runs'].size
    end
  end
end
