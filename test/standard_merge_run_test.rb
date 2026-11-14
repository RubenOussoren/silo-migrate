# frozen_string_literal: true
require_relative 'standard_base_site_review_test'

class MergeScriptedRuntime < BaseSiteScriptedRuntime
  attr_accessor :layer_entries, :layer_blobs, :merger_result, :target_state, :source_state, :quiesce_result
  # Site-setting preservation. Left alone, these model a faithful helper and database; a test
  # sets one to script a broken helper, a changed setting or a container that isn't the run's.
  #   settings_hook      called with each command line before it is answered (change stored_settings there)
  #   capture_result     the capture helper's whole result
  #   restore_result     the restore helper's whole result
  #   restore_fails      the restore helper can't put the temporary setting back
  #   settings_query_result  the fixed settings query's whole result
  #   effective_extensions   the effective value when it no longer follows the stored row (a stale cache)
  #   finalize_results   { finalize step => result }: import:ensure_consistency, posts:rebake
  #                      (the step merge_rebake.rb now does), search:reindex
  #   container_identity ->(id) { result } for the ownership inspect
  attr_accessor :settings_hook, :capture_result, :restore_result, :restore_fails, :settings_query_result,
                :effective_extensions, :finalize_results, :container_identity
  attr_writer :stored_settings

  MERGE_TABLES = %w[users topics posts categories groups tags uploads].freeze
  SETTINGS_SQL = SiloMigrate::Services::StandardMergeSiteSettings::MERGE_SITE_SETTINGS_SQL
  SETTINGS_GUEST = '/shared/merge/site-settings.json'
  SETTINGS_HELPER = 'rails runner /tmp/merge_site_settings.rb'
  REBAKE_HELPER = 'rails runner /tmp/merge_rebake.rb'
  # The stock rebake task's own setting write, which is why the host must not run that task.
  REBAKE_SETTING = 'disable_system_edit_notifications'
  SETTINGS_NAME = 'authorized_extensions'
  DEFAULT_EXTENSIONS = 'jpg|jpeg|png|gif|heic|heif|webp|avif'
  OWNERSHIP_FORMAT = "{{.Id}}\n{{.Name}}\n{{json .Config.Labels}}"

  def commands = (@commands ||= [])

  # The destination's stored site_settings rows, {name => [raw value or nil, data type]}: what
  # merge_state.rb, the capture helper and the fixed query all read. It starts as the target
  # state's settings, so a capture agrees with the state recorded before the merge.
  def stored_settings
    @stored_settings ||= JSON.parse(JSON.generate((target_state || {}).fetch('settings', {})))
  end

  def effective_authorized_extensions
    effective_extensions || stored_settings.dig(SETTINGS_NAME, 0) || DEFAULT_EXTENSIONS
  end

  # The snapshot file as last copied into the stack (nil until the host installs one). A test
  # assigns it to stand for something in the stack having replaced the file.
  attr_accessor :guest_snapshot

  # Whether the merger was constructed and ran (it refuses to without its bound snapshot).
  def merged? = @merged == true

  def settings_failed(tag, stdout = '')
    SiloMigrate::Runtime::CommandResult.new(success?: false, status: 4, stdout: stdout, stderr: "SILO_SETTINGS_ERROR: #{tag}\n")
  end

  # merge_site_settings.rb capture: every stored row raw (a setting with no row has no entry)
  # and the temporary setting's effective value. Nothing else: no row identity, no timestamps.
  def settings_snapshot
    { 'version' => 1, 'settings' => JSON.parse(JSON.generate(stored_settings)),
      'authorized_extensions_effective' => effective_authorized_extensions }
  end

  # merge_site_settings.rb validate!: exactly the snapshot's three fields, rows as raw pairs.
  def snapshot_valid?(snapshot)
    snapshot.is_a?(Hash) && snapshot.keys.sort == %w[authorized_extensions_effective settings version] && snapshot['version'] == 1 &&
      snapshot['authorized_extensions_effective'].is_a?(String) && snapshot['settings'].is_a?(Hash) &&
      snapshot['settings'].all? { |name, pair| name.is_a?(String) && pair.is_a?(Array) && pair.size == 2 && (pair[0].nil? || pair[0].is_a?(String)) && pair[1].is_a?(Integer) }
  end

  # The digest the command names must be the installed snapshot's, as load_snapshot requires.
  def bound_snapshot(line)
    # The stack's shell quoting writes NAME\=value.
    digest = line[/SILO_MERGE_SITE_SETTINGS_SHA256\\?=([^\s\\]+)/, 1]
    return 'snapshot-digest-missing' unless digest.to_s.match?(/\A[0-9a-f]{64}\z/)
    return 'snapshot-missing' unless guest_snapshot
    return 'snapshot-digest-mismatch' unless Digest::SHA256.hexdigest(guest_snapshot) == digest

    snapshot = JSON.parse(guest_snapshot)
    snapshot_valid?(snapshot) ? snapshot : 'snapshot-invalid'
  rescue JSON::ParserError
    'snapshot-invalid'
  end

  # merge_site_settings.rb restore: puts back the temporary setting (its row or its absence) and
  # nothing else; any other differing setting is named, never repaired. Exit 0 only when restored.
  # Told the execution is uncertain, it writes nothing at all: it reports what it reads, and
  # that is "unproven" (and a nonzero exit) even when nothing differs.
  def settings_restore(line)
    snapshot = bound_snapshot(line)
    return settings_failed(snapshot) if snapshot.is_a?(String)

    expected = snapshot.fetch('settings')
    read_only = line.match?(/SILO_MERGE_SITE_SETTINGS_EXECUTION_UNCERTAIN\\?=1(?=[\s\\])/)
    in_place = lambda do
      expected[SETTINGS_NAME] == stored_settings[SETTINGS_NAME] && effective_authorized_extensions == snapshot.fetch('authorized_extensions_effective')
    end
    unless read_only || restore_fails || in_place.call
      expected.key?(SETTINGS_NAME) ? stored_settings[SETTINGS_NAME] = expected[SETTINGS_NAME] : stored_settings.delete(SETTINGS_NAME)
      self.effective_extensions = nil
    end
    unexpected = (expected.keys | stored_settings.keys).reject { |name| name == SETTINGS_NAME || expected[name] == stored_settings[name] }.sort
    matches = effective_authorized_extensions == snapshot.fetch('authorized_extensions_effective')
    restored = in_place.call
    clean = restored && unexpected.empty? && !read_only
    report = { 'version' => 1, 'state' => clean ? 'restored' : 'unproven', 'restoration_failed' => restored ? [] : [SETTINGS_NAME],
               'unexpected_names' => unexpected, 'remaining_differences' => unexpected.size + (restored ? 0 : 1), 'effective_matches' => matches }
    line = "SILO_SETTINGS_REPORT:#{JSON.generate(report)}\n"
    clean ? review_ok(line) : settings_failed('restore-unproven', line)
  end

  # Which finalize step a command runs, by the name finalize_results uses for it.
  def finalize_step(line)
    return 'posts:rebake' if line.include?(REBAKE_HELPER)

    line[/bundle exec rake (import:ensure_consistency|search:reindex)(?!\S)/, 1]
  end

  # The ownership inspect of one recorded container: its exact ID, name and managed labels.
  def owned_container(id)
    record = service.store.load.fetch('instances').values.find { |instance| instance.fetch('containers', {}).value?(id) }
    return review_fail('Error: No such object') unless record

    labels = { 'silo-migrate.managed' => 'true', 'silo-migrate.instance' => record.fetch('name') }
    review_ok("#{id}\n/#{record.fetch('name')}-#{record.fetch('containers').key(id)}\n#{JSON.generate(labels)}\n")
  end

  def run(cmd, **options)
    commands << cmd.join(' ')
    if cmd.include?('ls-tree')
      return review_ok(layer_entries || '')
    elsif cmd.include?('cat-file') && cmd.include?('-s')
      return review_ok((layer_blobs || {}).fetch(cmd.last, '').bytesize.to_s)
    elsif cmd.include?('show') && cmd.last.include?(':mergers/')
      return review_ok((layer_blobs || {}).fetch(cmd.last.split(':', 2).last, ''))
    end
    line = cmd.join(' ')
    settings_hook&.call(line)
    if cmd[0, 4] == ['docker', 'inspect', '--format', OWNERSHIP_FORMAT] && cmd.size == 5
      return container_identity ? container_identity.call(cmd.last) : owned_container(cmd.last)
    elsif cmd[0, 2] == %w[docker cp] && cmd[3].to_s.end_with?(":#{SETTINGS_GUEST}")
      @guest_snapshot = File.binread(cmd[2])
    elsif cmd[0, 2] == %w[docker exec] && line.include?(SETTINGS_HELPER) && !cmd.include?('chown')
      # Only the two actions the host may ask for; anything else is the helper's own refusal.
      case line[/SILO_MERGE_SITE_SETTINGS_ACTION\\?=([^\s\\]+)/, 1]
      when 'capture' then return capture_result || review_ok("noise\nSILO_SETTINGS_SNAPSHOT:#{JSON.generate(settings_snapshot)}\n")
      when 'restore' then return restore_result || settings_restore(line)
      else return settings_failed('action-invalid')
      end
    elsif cmd[0, 2] == %w[docker exec] && cmd.include?('psql') && cmd.last == SETTINGS_SQL
      # psql -At prints the one aggregate and nothing else.
      return settings_query_result || review_ok(JSON.generate(stored_settings) + "\n")
    elsif cmd[0, 2] == %w[docker exec] && !cmd.include?('chown') && line.match?(/bundle exec rake posts:rebake(?!\S)/)
      # The stock task assigns its own setting and puts the old value back through the setter,
      # which leaves a row where there was none. Running it is what the host no longer does.
      stored_settings[REBAKE_SETTING] ||= ['f', 5]
    elsif cmd[0, 2] == %w[docker exec] && !cmd.include?('chown') && (step = finalize_step(line))
      return finalize_results.fetch(step) if (finalize_results || {}).key?(step)

      if step == 'posts:rebake'
        # merge_rebake.rb works under the same bound snapshot as the merger, or not at all.
        # Its completion marker is its last line; a settings refusal has its own fixed prefix.
        snapshot = bound_snapshot(line)
        if snapshot.is_a?(String)
          return SiloMigrate::Runtime::CommandResult.new(success?: false, status: 4, stdout: '', stderr: "SILO_MERGE_REBAKE: settings #{snapshot}\n")
        end
        return review_ok("SILO_MERGE_REBAKE: posts=1\n")
      end
    end
    if line.include?('merge_state.rb') && !cmd.include?('chown') && cmd[1] == 'exec'
      source = line.include?('SILO_MERGE_CONFIG')
      state = { 'database' => source ? 'merge_source' : 'discourse', 'pending' => false,
                'base_url' => 'https://private-source.example.invalid', 'counts' => MERGE_TABLES.to_h { |key| [key, @merged ? 3 : 1] },
                'migrations' => ['20261104011110'],
                'columns' => (MERGE_TABLES + %w[schema_migrations]).map { |table| [table, table == 'schema_migrations' ? 'version' : 'id', 'bigint'] },
                'merger' => { 'available' => true, 'layer_scanned' => false, 'tables' => MERGE_TABLES }, 'settings' => {} }
      # The destination reports its stored rows and effective value as they are now.
      return site_json(state.merge(source_state || {})) if source

      state.merge!('settings' => stored_settings, 'effective_authorized_extensions' => effective_authorized_extensions)
      return site_json(state.merge((target_state || {}).reject { |key, _| key == 'settings' }))
    elsif line.include?('SILO_QUIESCED')
      return quiesce_result || review_ok("ok: down: unicorn: 0s, normally up\nSILO_QUIESCED\n")
    elsif line.include?('ruby /tmp/merge_run.rb')
      # The runner refuses to start without the snapshot the host bound: it never runs unprotected.
      snapshot = bound_snapshot(line)
      if snapshot.is_a?(String)
        return SiloMigrate::Runtime::CommandResult.new(success?: false, status: 4, stdout: '', stderr: "SILO_MERGE: settings #{snapshot}\n")
      end
      @merged = true
      report = { 'version' => 1, 'state' => 'restored', 'restoration_failed' => [], 'unexpected_names' => [], 'remaining_differences' => 0, 'effective_matches' => true }
      return merger_result || review_ok("SILO_MERGE_TOTAL: routed=1\nSILO_SETTINGS_REPORT:#{JSON.generate(report)}\nSILO_MERGE: done\n")
    elsif line.include?('find /shared/silo-migrate-backup-')
      id = service.store.load.fetch('runs').keys.last
      return review_ok("merged-#{id}-v2026-11-0-latest-20261109000000.tar.gz\n")
    elsif cmd[0, 2] == %w[docker cp] && cmd[2].include?(':/shared/silo-migrate-backup-')
      dump = StringIO.new
      Zlib::GzipWriter.wrap(dump) { |g| g.write('invented SQL') }
      Zlib::GzipWriter.open(cmd[3]) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          tar.add_file_simple('dump.sql.gz', 0600, dump.string.bytesize) { |f| f.write(dump.string) }
          tar.add_file_simple('uploads/default/secret.png', 0600, 3) { |f| f.write('png') }
        end
      end
      return review_ok
    end
    super
  end
end

class StandardMergeRunTest < StandardBaseSiteReviewTest
  def self.runnable_methods
    public_instance_methods.grep(/^test_merge/).map(&:to_s)
  end

  def with_merge(ahead: false)
    with_base(ahead: ahead) do
      runtime = MergeScriptedRuntime.new
      runtime.service = @service
      @runtime = runtime
      @service.instance_variable_set(:@runtime, runtime)
      source = @named.add_source('synthetic', platform: 'discourse')[:source_id]
      dataset = @named.add_dataset('synthetic', source_id: source)[:dataset_id]
      old = @dataset
      @dataset = dataset
      edit = File.join(@root, '.silo-migrate/named/deliveries.json')
      data = JSON.parse(File.read(edit))
      data['deliveries'][dataset] = { 'dataset_id' => dataset, 'kind' => 'development', 'version' => 1 }
      File.write(edit, JSON.generate(data))
      dump = StringIO.new
      Zlib::GzipWriter.wrap(dump) { |g| g.write("CREATE SCHEMA public;\nSELECT 1;\n") }
      archive = StringIO.new
      Zlib::GzipWriter.wrap(archive) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          tar.add_file_simple('dump.sql.gz', 0600, dump.string.bytesize) { |f| f.write(dump.string) }
          tar.add_file_simple('uploads/default/secret.png', 0600, 3) { |f| f.write('png') }
        end
      end
      @merge_source = add_input('private-site-v2026-11-0-latest-20261104011110.tar.gz', archive.string, 'discourse-backup')
      @merge_settings = add_input('private-settings.yml', "category_routes: {}\n", 'merge-settings')
      @dataset = old
      yield
    end
  end

  # The scripted runtime's shared command log holds argv arrays and joined lines.
  def merge_lines
    @runtime.commands.map { |command| Array(command).join(' ') }
  end

  def merge_plan(**opts)
    @service.propose_merge_plan(source: @merge_source, base_site: @base, **opts)
  end

  def test_merge_propose_public_and_stages
    with_merge do
      plan = merge_plan(settings: @merge_settings)
      assert_equal 'standard_merge', plan[:operation]
      assert_equal({ 'present' => false }, plan.dig(:merge, 'layer'))
      assert_equal true, plan.dig(:merge, 'settings')
      assert_equal 'a' * 40, plan[:converter_revision]
      assert_equal ['review'], plan[:instances].keys
      refute_match(/private-site|private-settings|#{Regexp.escape(@root)}/, JSON.generate(plan))
      body = @service.store.load.fetch('plans').fetch(plan[:plan_id])
      assert_equal SiloMigrate::Services::StandardMergeRun::MERGE_STAGES, @service.send(:stages_for, body)
      # No option promises a restore proof: this version has none.
      assert_equal %w[ignore_global_pins separate_same_named_groups], plan.dig(:merge, 'options').keys
    end
  end

  def test_merge_propose_refusals
    with_merge do
      standard_error('STANDARD_INPUTS_INCOMPLETE') { @service.propose_merge_plan(source: @ids['source'], base_site: @base) }
      standard_error('STANDARD_INPUTS_INCOMPLETE') { @service.propose_merge_plan(source: @merge_source, base_site: @base, settings: @ids['settings']) }
      standard_error('STANDARD_REFERENCE_INVALID') { @service.propose_merge_plan(source: 'missing', base_site: @base) }
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.propose_merge_plan(source: @merge_source, base_site: @merge_source) }
      standard_error('STANDARD_INPUTS_INCOMPLETE') { @service.propose_merge_plan(source: @merge_source, base_site: @merge_settings) }
      standard_error('STANDARD_MERGE_SOURCE_INVALID') { @service.send(:merge_source_versions!, 'private.tar.gz') }
      assert_equal '2026.11.0-latest', @service.send(:merge_source_versions!, 'x-v2026-11-0-latest-20261104011110.tar.gz')['discourse_version']
    end
  end

  def test_merge_settings_validation
    with_merge do
      ['[]', 'null', '--- !ruby/object:Object {}', "a: &a [1]\nb: *a", 'x' * (256 * 1024 + 1)].each do |value|
        standard_error('STANDARD_MERGE_SETTINGS_INVALID') { @service.send(:merge_settings!, value) }
      end
      assert_equal({ 'a' => 1 }, @service.send(:merge_settings!, 'a: 1'))
    end
  end

  def test_merge_totals_and_failure_classification
    with_merge do
      text = +"customer secret\nSILO_MERGE_TOTAL: routed=1\nSILO_MERGE_TOTAL: routed=2\nSILO_MERGE_TOTAL: bad=1234567890123\nSILO_MERGE_TOTAL: Name=2\n"
      25.times { |n| text << "SILO_MERGE_TOTAL: metric_#{n}=#{n}\n" }
      declared = "puts \"SILO_MERGE_TOTAL: routed=\#{n}\"\n" + 25.times.map { |n| "total(:metric_#{n}, n)\n" }.join + "bad Name\n"
      totals = @service.send(:merge_totals, text, declared)
      assert_equal 20, totals.size
      assert_equal 2, totals['routed']
      refute totals.key?('bad')
      # A name the layer's code doesn't spell out was built from data: dropped, also as part of a longer word.
      built = "SILO_MERGE_TOTAL: routed=1\nSILO_MERGE_TOTAL: routed_invented_slug=4\nSILO_MERGE_TOTAL: route=2\n"
      assert_equal({ 'routed' => 1 }, @service.send(:merge_totals, built, "puts \"SILO_MERGE_TOTAL: routed_\#{slug}=1\"; total('routed')"))
      assert_equal({}, @service.send(:merge_totals, built, ''))
      [[3, 'SILO_MERGE: layer broken', 'STANDARD_MERGE_LAYER_INVALID'], [1, 'PG::UndefinedColumn secret', 'STANDARD_MERGE_SCHEMA'], [1, 'secret', 'STANDARD_MERGE_FAILED']].each do |status, output, code|
        result = SiloMigrate::Runtime::CommandResult.new(success?: false, status: status, stdout: output, stderr: '')
        assert_equal code, @service.send(:merge_failure, result)
      end
    end
  end

  def test_merge_layer_materialization_limits
    with_merge do
      prefix = 'mergers/synthetic/'
      sha = 'b' * 40
      @runtime.layer_entries = "100644 blob #{sha}\t#{prefix}merger.rb\0"
      @runtime.layer_blobs = { sha => 'abc', prefix + 'merger.rb' => 'abc' }
      layer, files = @service.send(:merge_layer!, File.join(@dir, 'converter'), 'a' * 40, 'synthetic')
      assert_equal 3, layer['bytes']
      assert_equal({ 'merger.rb' => 'abc' }, files)
      assert_equal Digest::SHA256.hexdigest("#{sha} #{prefix}merger.rb\n"), layer['sha256']
      ['120000 blob', '100755 blob', '040000 tree'].each do |header|
        @runtime.layer_entries = "#{header} #{sha}\t#{prefix}merger.rb\0"
        standard_error('STANDARD_MERGE_LAYER_INVALID') { @service.send(:merge_layer!, File.join(@dir, 'converter'), 'a' * 40, 'synthetic') }
      end
      @runtime.layer_entries = "100644 blob #{sha}\t#{prefix}data.yml\0"
      standard_error('STANDARD_MERGE_LAYER_INVALID') { @service.send(:merge_layer!, File.join(@dir, 'converter'), 'a' * 40, 'synthetic') }
      @runtime.layer_entries = "100644 blob #{sha}\t#{prefix}merger.rb\0"
      @runtime.layer_blobs[sha] = 'x' * (512 * 1024 + 1)
      standard_error('STANDARD_MERGE_LAYER_INVALID') { @service.send(:merge_layer!, File.join(@dir, 'converter'), 'a' * 40, 'synthetic') }
    end
  end

  def test_merge_staleness_and_preflight
    with_merge do
      plan = merge_plan
      assert_equal 'proposed', plan[:status]
      run = @service.claim(plan_id: approve(plan))
      @service.send(:stage_preflight, run[:run_id])
      assert_equal 'skipped', @service.store.load.dig('runs', run[:run_id], 'results', 'merge', 'restore_proof')
      another = merge_plan
      @service.store.update { |s| s['config']['converter_revision'] = 'b' * 40 }
      assert_equal 'stale', @service.show_plan(another[:plan_id])[:status]
    end
  end

  def approve(plan)
    @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'Invented engineer')
    plan[:plan_id]
  end

  def test_merge_streaming_archive_and_sql
    with_merge do
      archive = File.join(@dir, 'source.tar.gz')
      Zlib::GzipWriter.open(archive) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          tar.add_file_simple('dump.sql.gz', 0600, 3) { |f| f.write('abc') }
          tar.add_file_simple('uploads/default/secret.png', 0600, 3) { |f| f.write('png') }
        end
      end
      extracted = @service.send(:merge_extract!, archive, File.join(@dir, 'extract'), 1000)
      assert_equal 'default', extracted['root']
      standard_error('STANDARD_CAPACITY') { @service.send(:merge_extract!, archive, File.join(@dir, 'small'), 1) }
      Zlib::GzipWriter.open(archive) do |gzip|
        Gem::Package::TarWriter.new(gzip) { |tar| tar.add_symlink('dump.sql.gz', '/etc/passwd', 0777) }
      end
      standard_error('STANDARD_MERGE_SOURCE_INVALID') { @service.send(:merge_extract!, archive, File.join(@dir, 'links'), 1000) }
      dump = File.join(@dir, 'dump.gz')
      Zlib::GzipWriter.open(dump) { |g| g.write("CREATE SCHEMA public;\nSELECT 1;\n") }
      adapted = File.join(@dir, 'adapted.gz')
      @service.send(:merge_adapt_dump!, dump, adapted, 1000)
      assert_equal "CREATE SCHEMA IF NOT EXISTS public;\nSELECT 1;\n", Zlib::GzipReader.open(adapted, &:read)
    end
  end

  def test_merge_release_tar_requires_acknowledgement
    with_merge do
      plan = merge_plan
      run = @service.claim(plan_id: approve(plan))
      path = @service.store.run_dir(run[:run_id], 'artifacts', 'merged-v2026-11-0-latest-20261109000000.tar.gz')
      @service.store.write_private(path, 'invented full backup')
      @service.store.update do |state|
        r = state['runs'][run[:run_id]]
        r['status'] = 'completed'
        r['artifacts']['backup'] = @service.send(:artifact_identity, path).merge('path' => path)
        r['results']['backup_schema_version'] = '20261109000000'
        r['results']['merge'] = { 'restore_proof' => 'skipped', 'target_only_columns' => 0 }
      end
      standard_error('STANDARD_RELEASE_CHECKS') { @service.release_backup(run_id: run[:run_id], reviewer: 'Invented engineer') }
      released = @service.release_backup(run_id: run[:run_id], reviewer: 'Invented engineer', acknowledge_differences: true)
      assert released
      public_run = @service.show_run(run[:run_id])
      assert_equal 'skipped', public_run.dig(:results, 'merge', 'restore_proof')
      assert_equal 'merged-v2026-11-0-latest-20261109000000.manifest.json', public_run.dig(:release, 'manifest')
    end
  end
  def test_merge_whole_fake_run_count_evidence_admin_reset
    with_merge do
      sha = 'c' * 40
      source = "class InventedMerger < BulkImport::DiscourseMerger; def finish = puts(\"SILO_MERGE_TOTAL: routed=1\"); end\n"
      @runtime.layer_entries = "100644 blob #{sha}\tmergers/synthetic/merger.rb\0"
      @runtime.layer_blobs = { sha => source, 'mergers/synthetic/merger.rb' => source }
      plan = merge_plan(settings: @merge_settings)
      run = @service.run_plan(plan_id: approve(plan))
      assert_equal 'completed', run[:status], run[:failure].inspect + Dir.glob(@service.store.run_dir(run[:run_id], '{private/failure.json,logs/merge*.log}')).map { |p| File.read(p)[0, 2000] }.join
      assert run[:stages].values.all? { |status| status == 'passed' }
      assert_equal 1, run.dig(:results, 'merge', 'layer_totals', 'routed')
      assert_equal 1, run.dig(:results, 'merge', 'archive_upload_files')
      refute_match(/private-source|secret.png/, JSON.generate(run))
      # The source site's address reaches the merger from a file in the stack, not a command line.
      assert @runtime.commands.any? { |line| line.include?('ruby /tmp/merge_run.rb') && line.include?('/shared/merge/source-base-url') }
      refute @runtime.commands.any? { |line| line.include?('private-source') }
      evidence = @service.merge_evidence(run[:run_id])
      assert_equal [], evidence['target_only_columns']
      assert_includes evidence['log_tail'], 'SILO_MERGE_TOTAL'
      assert @service.admin_password(run[:run_id])[:password].size > 10
      @runtime.destination_counts = { 'SELECT COUNT(*) FROM posts' => 3 }
      name = plan.dig(:instances, 'review', 'name')
      @runtime.live_result = %w[db redis web proxy].map { |_role| "true #{name}" }.join("\n") + "\n"
      assert_equal 3, @service.analyst_count(run[:run_id], side: 'destination', sql: 'SELECT COUNT(*) FROM posts')[:count]
      directory = @service.store.run_dir(run[:run_id], 'private', 'merge-source')
      assert File.directory?(directory)
      @runtime.ownership = name
      @service.reset_run(run_id: run[:run_id], yes: true)
      refute File.exist?(directory)
      standard_error('STANDARD_TRANSITION_INVALID') { @service.admin_password(run[:run_id]) }
    end
  end

  # The Base is ahead of the pinned runtime (a migration this code doesn't have). The old
  # bridge edited the source's schema_migrations to satisfy the merger; now it is refused.
  def test_merge_ahead_base_is_refused_without_marker_edits
    with_merge(ahead: true) do
      @runtime.target_state = { 'migrations' => %w[20261104011110 20261109000000] }
      run = @service.run_plan(plan_id: approve(merge_plan))
      assert_equal 'STANDARD_MERGE_INCOMPATIBLE', run.dig(:failure, 'code')
      assert_equal 'failed', run.dig(:stages, 'compatibility')
      assert_equal 'pending', run.dig(:stages, 'merge')
      assert_equal 'refused', run.dig(:results, 'merge', 'compatibility', 'status')
      refute merge_lines.any? { |line| line.include?('ruby /tmp/merge_run.rb') }
      refute merge_lines.any? { |line| line.match?(/schema_migrations/i) && line.match?(/DELETE|INSERT|UPDATE/i) }
      checks = JSON.parse(File.read(@service.store.run_dir(run[:run_id], 'evidence', 'merge-compatibility.json'))).fetch('failures').map { |f| f['check'] }
      assert_equal %w[schema-version-differs target-newer-than-runtime], checks.sort
      refute_includes JSON.generate(run.dig(:results, 'merge')), '20261109000000'
    end
  end

  def test_merge_never_edits_migration_markers_and_quiesces_sidekiq
    with_merge do
      run = @service.run_plan(plan_id: approve(merge_plan))
      assert_equal 'completed', run[:status], run[:failure].inspect
      assert_equal 'passed', run.dig(:results, 'merge', 'compatibility', 'status')
      refute merge_lines.any? { |line| line.match?(/schema_migrations/i) && line.match?(/DELETE|INSERT|UPDATE/i) }
      quiesce = merge_lines.index { |line| line.include?('SILO_QUIESCED') }
      assert_includes merge_lines[quiesce], 'sidekiq'
      assert_operator quiesce, :<, merge_lines.index { |line| line.include?('CREATE DATABASE merge_source') }
      refute run.dig(:results, 'merge').key?('source_migration_added')
      assert_nil run[:merge_environment]
    end
    with_merge do
      @runtime.quiesce_result = review_ok_without_marker
      run = @service.run_plan(plan_id: approve(merge_plan))
      assert_equal 'STANDARD_STACK_FAILED', run.dig(:failure, 'code')
      assert_equal 'failed', run.dig(:stages, 'source_load')
    end
  end

  def review_ok_without_marker
    SiloMigrate::Runtime::CommandResult.new(success?: true, stdout: "ok: down: unicorn: 0s\n", stderr: '', status: 0)
  end

  def test_merge_legacy_callers_cannot_name_intent_or_generation
    with_merge do
      standard_error('STANDARD_ARGUMENT_INVALID') { merge_plan(intent: 'stock') }
      standard_error('STANDARD_ARGUMENT_INVALID') { merge_plan(generation: 'a' * 64) }
      plan = merge_plan(intent: nil, generation: nil, prepared_from: nil, port: nil)
      assert_nil plan[:prepared_from]
      assert_nil plan[:intent]
    end
  end

  def test_merge_failed_merger_public_projection
    with_merge do
      @runtime.merger_result = SiloMigrate::Runtime::CommandResult.new(success?: false, status: 1, stdout: 'PG::UndefinedColumn private-customer-name', stderr: '')
      run = @service.run_plan(plan_id: approve(merge_plan))
      assert_equal 'STANDARD_MERGE_SCHEMA', run.dig(:failure, 'code')
      assert_equal 'failed', run.dig(:stages, 'merge')
      refute_includes JSON.generate(run), 'private-customer-name'
      assert_includes @service.merge_evidence(run[:run_id])['log_tail'], 'private-customer-name'
    end
  end

  def test_merge_source_and_delivery_refusals
    with_merge do
      source_input = @service.store.named_state.fetch('inputs').fetch(@merge_source)
      dataset = source_input.fetch('dataset_id')
      edit_delivery(dataset) { |d| d['kind'] = 'launch' }
      standard_error('STANDARD_LAUNCH_NOT_READY') { merge_plan }
      edit_delivery(dataset) { |d| d['kind'] = 'development' }
      edit_delivery(@base_dataset) { |d| d['kind'] = 'development' }
      standard_error('STANDARD_DELIVERY_MIXED') { merge_plan }
      edit_delivery(@base_dataset) { |d| d['kind'] = 'base_site' }
      old = @dataset; @dataset = dataset
      newer = add_input('private-v2099-1-0-20990101000000.tar.gz', 'invented', 'discourse-backup')
      invalid_settings = add_input('bad-merge.yml', '[]', 'merge-settings')
      @dataset = old
      standard_error('STANDARD_MERGE_SOURCE_NEWER') { @service.propose_merge_plan(source: newer, base_site: @base) }
      standard_error('STANDARD_MERGE_SETTINGS_INVALID') { merge_plan(settings: invalid_settings) }
    end
  end

  def test_merge_stale_inputs_code_and_runtime
    with_merge do
      plan = merge_plan
      @service.store.update { |state| state['config']['discourse_profile_sha256'] = '0' * 64 }
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
    end
    with_merge do
      plan = merge_plan
      File.write(File.join(@code_root, 'lib', 'identity.rb'), '# changed')
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
    end
    with_merge do
      plan = merge_plan
      input = @service.store.named_state.fetch('inputs').fetch(@merge_source)
      path = File.join(@root, input.fetch('path').unpack1('m0'))
      File.chmod(0600, path); File.write(path, 'changed')
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
    end
  end

  def test_merge_layer_preflight_binds_git_blobs_and_limits_count
    with_merge do
      sha = 'b' * 40
      prefix = 'mergers/synthetic/'
      @runtime.layer_entries = "100644 blob #{sha}\t#{prefix}merger.rb\0"
      @runtime.layer_blobs = { sha => 'abc', prefix + 'merger.rb' => 'abc' }
      plan = merge_plan
      claim = @service.claim(plan_id: approve(plan))
      @service.send(:stage_preflight, claim[:run_id])
      path = @service.store.run_dir(claim[:run_id], 'private', 'merge', 'layer', 'merger.rb')
      assert_equal 'abc', File.read(path)
      assert_equal 0700, File.stat(File.dirname(path)).mode & 0777
      manifest = @service.send(:run_inputs, claim[:run_id])
      @service.define_singleton_method(:materialize_inputs) { |*_args, **_kwargs| manifest }
      @runtime.layer_entries = ''
      standard_error('STANDARD_MERGE_LAYER_INVALID') { @service.send(:merge_preflight, claim[:run_id], @service.send(:plan_for, claim[:run_id])) }
      paths = ['merger.rb'] + 32.times.map { |n| "extra_#{n}.rb" }
      paths.each { |name| @runtime.layer_blobs[prefix + name] = 'abc' }
      @runtime.layer_entries = paths.map { |name| "100644 blob #{sha}\t#{prefix}#{name}\0" }.join
      standard_error('STANDARD_MERGE_LAYER_INVALID') { merge_plan }
    end
  end

  def test_merge_archive_duplicate_unsafe_and_multiple_upload_roots
    with_merge do
      [['dump.sql.gz', 'dump.sql.gz'], ['../escape', 'dump.sql.gz'], ['/absolute', 'dump.sql.gz'],
       ['dump.sql.gz', 'uploads/one/a', 'uploads/two/b']].each_with_index do |names, index|
        archive = File.join(@dir, "bad-#{index}.tar.gz")
        Zlib::GzipWriter.open(archive) do |gzip|
          Gem::Package::TarWriter.new(gzip) do |tar|
            names.each { |name| tar.add_file_simple(name, 0600, 1) { |f| f.write('x') } }
          end
        end
        standard_error('STANDARD_MERGE_SOURCE_INVALID') { @service.send(:merge_extract!, archive, File.join(@dir, "bad-#{index}"), 1000) }
      end
    end
  end

  def test_merge_sql_adaptation_does_not_rewrite_copy_values_or_owners
    with_merge do
      input = File.join(@dir, 'input.gz')
      output = File.join(@dir, 'output.gz')
      sql = "CREATE SCHEMA public;\nCOPY public.invented (value) FROM stdin;\nCREATE SCHEMA public;\n\\.\nALTER TABLE public.invented OWNER TO invented;\n"
      Zlib::GzipWriter.open(input) { |g| g.write(sql) }
      @service.send(:merge_adapt_dump!, input, output, 1000)
      assert_equal sql.sub('CREATE SCHEMA public;', 'CREATE SCHEMA IF NOT EXISTS public;'), Zlib::GzipReader.open(output, &:read)
      Zlib::GzipWriter.open(input) { |g| g.write('SELECT 1;') }
      standard_error('STANDARD_MERGE_SOURCE_INVALID') { @service.send(:merge_adapt_dump!, input, output, 1000) }
      Zlib::GzipWriter.open(input) { |g| g.write("CREATE SCHEMA public;\nCREATE SCHEMA public;\n") }
      standard_error('STANDARD_MERGE_SOURCE_INVALID') { @service.send(:merge_adapt_dump!, input, output, 1000) }
    end
  end

end
