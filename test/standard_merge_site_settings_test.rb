# frozen_string_literal: true
require_relative 'standard_merge_preparation_test'

# The host's side of site-setting preservation in a merge run, against the scripted runtime:
# when the settings are captured, where each later check stands, what a failed or interrupted
# run restores and records, and what never leaves the private run directory. The Rails helper
# and the runner have their own tests (merge_site_settings_test.rb, merge_layer_checks_test.rb);
# here they are scripted, including broken ones.
module MergeSiteSettingsHostChecks
  SETTINGS = SiloMigrate::Services::StandardMergeSiteSettings
  CODE = 'STANDARD_MERGE_SITE_SETTINGS_FAILED'
  NAME = 'authorized_extensions'
  PRIVATE = 'PRIVATE-SETTING-VALUE'
  # Stored rows as the destination holds them: raw value (or NULL) and data type.
  SITE = {
    'title' => ["#{PRIVATE} title ünïcødé ✓", 1],
    NAME => ["jpg|png|#{PRIVATE}-ext", 8],
    'max_attachment_size_kb' => ['4096', 3],
    'empty_value' => ['', 1],
    'null_value' => [nil, 1]
  }.freeze
  # What the stock merger's constructor leaves behind when nothing puts it back.
  STOCK = ['jpg|jpeg|png|gif', 8].freeze
  # A setting no merge may write; its name must stay in private reports.
  EXTRA = 'silo_invented_plugin_setting'
  PHASES = %w[after-merge before-finalize after-finalize verify before-backup completion].freeze
  QUERY = /#{Regexp.escape(SETTINGS::MERGE_SITE_SETTINGS_SQL)}\z/
  CONSTRUCTOR = %r{ruby /tmp/merge_run\.rb}
  INSTALL = %r{\Adocker cp \S+ \S+:/shared/merge/site-settings\.json\z}
  OWNERSHIP = /\Adocker inspect --format \{\{\.Id\}\}/
  # Rebaking is merge_rebake.rb's, under the bound snapshot; the stock task is never run.
  REBAKE = %r{bundle exec rails runner /tmp/merge_rebake\.rb\z}
  STOCK_REBAKE = /rake\s+posts:rebake/
  FINALIZE_STEPS = { 'import:ensure_consistency' => /bundle exec rake import:ensure_consistency\z/, 'posts:rebake' => REBAKE,
                     'search:reindex' => /bundle exec rake search:reindex\z/ }.freeze
  FINALIZE = Regexp.union(*FINALIZE_STEPS.values, STOCK_REBAKE)
  # Tells the restore helper to write nothing: the host can't show the last execution ended.
  UNCERTAIN = /SILO_MERGE_SITE_SETTINGS_EXECUTION_UNCERTAIN\\?=1(?=[\s\\])/
  # A merge plan body as a checkout without this contract (or with a weaker one) would have it.
  WEAKENINGS = {
    'no policy' => ->(merge) { merge.delete('site_settings_preservation') },
    'no verification before the backup' => ->(merge) { merge['site_settings_preservation']['verify_before_backup'] = false },
    'another temporary setting' => ->(merge) { merge['site_settings_preservation']['temporary_setting'] = 'title' },
    'another version' => ->(merge) { merge['site_settings_preservation']['version'] = 0 }
  }.freeze
  # Installing the helper file itself, as every helper is installed at site_up.
  HELPER_INSTALL = %r{\Adocker (cp \S+/work/helpers/merge_site_settings\.rb \S+:/tmp/merge_site_settings\.rb|exec \S+ chown -R discourse:discourse /tmp/merge_site_settings\.rb)\z}
  DIGEST_ENV = 'SILO_MERGE_SITE_SETTINGS_SHA256'
  # Stands in for the host process dying: nothing in the service rescues it.
  class Aborted < Exception; end # rubocop:disable Lint/InheritException

  def with_settings(settings = SITE)
    with_merge do
      prepare_settings(settings)
      yield
    end
  end

  def prepare_settings(settings)
    @hooks = []
    @checks_answered = 0
    @runtime.target_state = { 'settings' => JSON.parse(JSON.generate(settings)) }
    @runtime.settings_hook = lambda do |line|
      @hooks.each do |hook|
        next unless @checks_answered >= hook[:after_checks] && line.match?(hook[:pattern])

        hook[:seen] += 1
        hook[:action].call if hook[:seen] == hook[:nth]
      end
      @checks_answered += 1 if line.match?(QUERY)
    end
  end

  # Runs the block just before the nth command matching pattern is answered, counting only
  # once the host has had after_checks answers to its fixed settings query.
  def before_command(pattern, nth: 1, after_checks: 0, &action)
    @hooks << { pattern: pattern, nth: nth, after_checks: after_checks, seen: 0, action: action }
  end

  def run_merge(**opts)
    @service.run_plan(plan_id: approve(merge_plan(**opts)))
  end

  # Rewrites a stored plan as another checkout would have proposed it: the changed body is
  # what its digest (and any approval) covers, so only the plan's content can refuse it.
  def historical_plan(plan_id, weaken)
    @service.store.update do |state|
      plan = state.fetch('plans').fetch(plan_id)
      weaken.call(plan.fetch('body').fetch('merge'))
      plan['digest'] = Digest::SHA256.hexdigest(@service.send(:canonical_json, plan.fetch('body')))
      plan['approval']['digest'] = plan['digest'] if plan['approval']
    end
    @service.store.load.dig('plans', plan_id, 'digest')
  end

  def docker_commands(from)
    issued.drop(from).grep(/\Adocker /)
  end

  def digest_env(run_id)
    /#{DIGEST_ENV}\\?=#{binding_for(run_id).fetch('sha256')}(?=[\s\\])/
  end

  # Each command once, in order, as one line.
  def issued
    @runtime.commands.grep(String)
  end

  def positions(pattern, from: 0)
    issued.each_index.select { |index| index >= from && issued[index].match?(pattern) }
  end

  def position(pattern, from: 0)
    positions(pattern, from: from).first || flunk("no command matching #{pattern.inspect} from #{from}")
  end

  def helper_calls(action = nil, from: 0)
    positions(%r{SILO_MERGE_SITE_SETTINGS_ACTION\\?=#{action || '\S+'}(?=[\s\\]).* rails runner /tmp/merge_site_settings\.rb\z}, from: from)
  end

  # Anything the host could do to the destination's settings or the installed snapshot.
  def settings_commands(from)
    positions(/merge_site_settings\.rb|site-settings\.json|site_settings/i, from: from).reject { |index| issued[index].match?(HELPER_INSTALL) }
  end

  def private_path(run_id, name)
    @service.store.run_dir(run_id, 'private', name)
  end

  def report(run_id, phase)
    path = private_path(run_id, "merge-site-settings-#{phase}.json")
    File.exist?(path) ? JSON.parse(File.read(path)) : nil
  end

  def expected_report(phase, state, unexpected: [], failed: [], remaining: unexpected.size + failed.size, uncertain: false)
    report = { 'version' => 1, 'phase' => phase, 'state' => state, 'restoration_failed' => failed, 'unexpected_names' => unexpected,
               'remaining_differences' => remaining }
    uncertain ? report.merge('execution_uncertain' => true) : report
  end

  # What the host records when it could neither restore nor read anything.
  def unproven(phase)
    expected_report(phase, 'unproven', failed: [NAME], remaining: nil)
  end

  def binding_for(run_id)
    @service.store.load.dig('runs', run_id, 'merge_site_settings')
  end

  def snapshot_for(run_id)
    JSON.parse(File.read(private_path(run_id, 'merge-site-settings.json')))
  end

  def last_run_id
    @service.store.load.fetch('runs').keys.last
  end

  def failed_result(status, stdout: '', stderr: '')
    SiloMigrate::Runtime::CommandResult.new(success?: false, status: status, stdout: stdout, stderr: stderr)
  end

  def ok_result(stdout = '')
    SiloMigrate::Runtime::CommandResult.new(success?: true, status: 0, stdout: stdout, stderr: '')
  end

  def assert_settings_failure(run, stage, message = nil)
    assert_equal 'failed', run[:status], message
    assert_equal({ 'stage' => stage, 'code' => CODE }, run[:failure].slice('stage', 'code'), message)
    assert_equal 'failed', run.dig(:stages, stage), message
  end

  # No projection of a run names a setting's value, a changed setting or the snapshot.
  def assert_public_projection_clean(run_id, *markers)
    record = @service.store.load.fetch('runs').fetch(run_id)
    public = JSON.generate([@service.show_run(run_id), @service.show_plan(record.fetch('plan_id')), @service.show_plan(record.fetch('plan_id'), detail: true)])
    [PRIVATE, EXTRA, 'merge_site_settings', 'authorized_extensions_effective', *markers].each { |text| refute_includes public, text }
    digest = record['merge_site_settings'].is_a?(Hash) ? record['merge_site_settings']['sha256'] : nil
    refute_includes public, digest if digest.is_a?(String)
    merge = @service.show_run(run_id).dig(:results, 'merge') || {}
    assert_equal [], merge.keys.grep(/setting/) - %w[site_settings_preservation site_settings_changed]
    assert_includes [nil, 'captured', 'verified', 'changed', 'restored', 'unproven'], merge['site_settings_preservation']
    assert(merge['site_settings_changed'].nil? || merge['site_settings_changed'].is_a?(Integer))
  end

  # merge-state.log is the state helper's own output, kept as before; no other log, no report
  # and no command line carries a stored value.
  def assert_values_stay_private(run_id, *markers)
    logs = Dir.glob(@service.store.run_dir(run_id, 'logs', '*')).reject { |path| File.basename(path) == 'merge-state.log' }
    reports = Dir.glob(private_path(run_id, 'merge-site-settings-*.json')) + Dir.glob(private_path(run_id, 'failure.json'))
    (logs + reports).each do |path|
      text = File.binread(path).force_encoding('UTF-8')
      [PRIVATE, 'SILO_SETTINGS_SNAPSHOT', *markers].each { |marker| refute_includes text, marker, File.basename(path) }
    end
    Dir.glob(@service.store.run_dir(run_id, 'logs', '*')).each do |path|
      markers.each { |marker| refute_includes File.binread(path).force_encoding('UTF-8'), marker, File.basename(path) }
    end
    [PRIVATE, *markers].each { |marker| refute(issued.any? { |line| line.include?(marker) }, 'a value reached a command line') }
    reports.each { |path| assert_equal 0600, File.stat(path).mode & 0777 }
  end
end

class StandardMergeSiteSettingsTest < StandardMergeRunTest
  include MergeSiteSettingsHostChecks

  # This file's own tests (an inherited class has unrelated tests under the same prefix).
  def self.runnable_methods
    public_instance_methods(false).grep(/^test_settings_/).map(&:to_s)
  end

  # -- the contract a plan binds --------------------------------------------------------------

  def test_settings_fixed_query_and_plan_policy
    # One constant statement: no interpolation, no row filter, values only as an aggregate the host parses.
    assert_equal "SELECT COALESCE(json_object_agg(name, json_build_array(value, data_type)), '{}'::json) FROM site_settings", SETTINGS::MERGE_SITE_SETTINGS_SQL
    assert_predicate SETTINGS::MERGE_SITE_SETTINGS_SQL, :frozen?
    with_settings do
      plan = merge_plan
      policy = { 'version' => 1, 'temporary_setting' => NAME, 'restore_before' => 'postflight', 'verify_before_backup' => true }
      assert_equal policy, @service.store.load.dig('plans', plan[:plan_id], 'body', 'merge', 'site_settings_preservation')
      assert_equal policy, plan.dig(:merge, 'site_settings_preservation')
      assert_equal 1, plan[:mutations].grep(/authorized_extensions/).size
      assert_includes @service.class::HELPERS, 'merge_site_settings.rb'
    end
  end

  # A plan approved without this contract (or with a weaker one) never reaches the merger.
  def test_settings_plan_without_the_policy_constructs_no_merger
    WEAKENINGS.each do |label, weaken|
      with_settings do
        before_command(/CREATE DATABASE merge_source/) do
          @service.store.update { |state| weaken.call(state.fetch('plans').values.last.fetch('body').fetch('merge')) }
        end
        run = run_merge
        assert_settings_failure(run, 'merge', label)
        assert_equal [], helper_calls, label
        assert_equal [], positions(CONSTRUCTOR), label
        assert_equal [], positions(QUERY), label
        assert_nil binding_for(run[:run_id]), label
        assert_equal SITE, @runtime.stored_settings, label
      end
    end
  end

  # An approval given before this contract existed never agreed to it. It is stale: refused
  # before a run exists or anything is touched, to be proposed and approved again.
  def test_settings_approval_without_the_policy_is_stale_before_anything_runs
    WEAKENINGS.each do |label, weaken|
      with_settings do
        approved = approve(merge_plan)
        historical_plan(approved, weaken)
        runs = @service.store.load.fetch('runs').keys
        from = issued.size
        assert_equal 'stale', @service.show_plan(approved)[:status], label
        standard_error('STANDARD_STALE_PLAN') { @service.run_plan(plan_id: approved) }
        assert_equal runs, @service.store.load.fetch('runs').keys, label
        assert_equal [], docker_commands(from), label
        assert_equal 'approved', @service.store.load.dig('plans', approved, 'status'), label
        assert_equal SITE, @runtime.stored_settings, label
      end
      # Nor can it be approved now.
      with_settings do
        plan = merge_plan
        digest = historical_plan(plan[:plan_id], weaken)
        standard_error('STANDARD_STALE_PLAN') { @service.approve_plan(plan_id: plan[:plan_id], sha256: digest, reviewer: 'Invented engineer') }
        assert_equal 'proposed', @service.store.load.dig('plans', plan[:plan_id], 'status'), label
      end
    end
    # The rewrite itself refuses nothing: the same plan with its policy intact still runs.
    with_settings do
      approved = approve(merge_plan)
      historical_plan(approved, ->(merge) { merge['site_settings_preservation'] = JSON.parse(JSON.generate(SETTINGS::MERGE_SITE_SETTINGS_POLICY)) })
      assert_equal 'completed', @service.run_plan(plan_id: approved)[:status]
    end
  end

  # -- phase order ---------------------------------------------------------------------------

  def test_settings_capture_precedes_the_constructor_and_every_boundary_is_checked
    with_settings do
      plan = merge_plan(settings: @merge_settings)
      run = @service.run_plan(plan_id: approve(plan))
      assert_equal 'completed', run[:status], run[:failure].inspect
      run_id = run[:run_id]
      instance = plan.dig(:instances, 'review', 'name')

      capture = helper_calls('capture')
      checks = positions(QUERY)
      assert_equal 1, capture.size
      assert_equal capture, helper_calls
      assert_equal 5, checks.size
      constructor = position(CONSTRUCTOR)
      install, reinstall = positions(INSTALL)
      consistency, rebake, reindex = FINALIZE_STEPS.values.map { |step| position(step) }
      order = [
        position(%r{chown -R root:root /shared/merge &&}), capture.first, install,
        position(%r{chown -R root:root /shared/merge/site-settings\.json\z}, from: install),
        position(%r{chmod 0444 /shared/merge/site-settings\.json\z}, from: install),
        constructor, checks[0], checks[1],
        consistency, reinstall,
        position(%r{chown -R root:root /shared/merge/site-settings\.json\z}, from: reinstall),
        position(%r{chmod 0444 /shared/merge/site-settings\.json\z}, from: reinstall),
        rebake, reindex,
        position(/sv start unicorn/, from: constructor), checks[2],
        position(%r{rails runner /tmp/merge_state\.rb\z}, from: checks[2]), checks[3],
        position(%r{script/discourse backup }), position(%r{rails runner /tmp/review_access\.rb}, from: checks[3]), checks[4]
      ]
      assert_equal order.sort, order, order.inspect
      assert_equal order.uniq, order
      # Nothing runs in the stack between the two checks of one boundary, or after the last one.
      refute(issued[(checks[0] + 1)...checks[1]].any? { |line| line.start_with?('docker exec', 'docker cp') })
      refute(issued[(checks[3] + 1)..].any? { |line| line.include?('merge_state.rb') })
      refute(issued[(checks[4] + 1)..].any? { |line| line.start_with?('docker exec', 'docker cp') })
      # Two installs, each of exactly the bound bytes: once for the constructor and again for
      # the rebake, which doesn't trust what the merger left. Both are told the same digest.
      assert_equal [install, reinstall], positions(INSTALL)
      [install, reinstall].each do |index|
        assert_equal "docker cp #{private_path(run_id, 'merge-site-settings.json')} #{instance}-web:/shared/merge/site-settings.json", issued[index]
      end
      bound = binding_for(run_id)
      bytes = File.binread(private_path(run_id, 'merge-site-settings.json'))
      assert_equal({ 'version' => 1, 'sha256' => Digest::SHA256.hexdigest(bytes), 'execution' => 'finished' }, bound)
      assert_equal bytes, @runtime.guest_snapshot.b
      assert_match digest_env(run_id), issued[constructor]
      refute_includes issued[constructor], 'SILO_MERGE_SITE_SETTINGS_ACTION'
      # Finalization is exactly three steps. Posts are rebaked by the run's own helper under
      # the same bound snapshot; the stock task (which writes a setting of its own) never runs.
      assert_equal [consistency, rebake, reindex], positions(FINALIZE)
      rebake = issued[rebake]
      assert rebake.start_with?("docker exec #{instance}-web su discourse -c ")
      assert_match digest_env(run_id), rebake
      assert_equal 1, rebake.scan(DIGEST_ENV).size
      refute_match(/SILO_MERGE_SITE_SETTINGS_ACTION|EXECUTION_UNCERTAIN|SILO_MERGE_CONFIG|merge_source/, rebake)
      assert_equal [], positions(STOCK_REBAKE)
      refute @runtime.stored_settings.key?(MergeScriptedRuntime::REBAKE_SETTING)
      (FINALIZE_STEPS.values - [REBAKE]).each { |step| refute_includes issued[position(step)], DIGEST_ENV }
      # The capture reads the destination, with no snapshot to check yet.
      refute_match(/SHA256|SILO_MERGE_CONFIG|merge_source/, issued[capture.first])
      assert issued[capture.first].start_with?("docker exec #{instance}-web su discourse -c ")
      checks.each do |index|
        assert_equal "docker exec #{instance}-db psql -U discourse -d discourse -Atc #{SETTINGS::MERGE_SITE_SETTINGS_SQL}", issued[index]
      end

      PHASES.each { |phase| assert_equal expected_report(phase, 'verified'), report(run_id, phase), phase }
      assert_equal PHASES.sort, Dir.glob(private_path(run_id, 'merge-site-settings-*.json')).map { |path| File.basename(path)[/settings-(.*)\.json/, 1] }.sort
      assert_equal 'verified', run.dig(:results, 'merge', 'site_settings_preservation')
      assert_equal 0, run.dig(:results, 'merge', 'site_settings_changed')
      assert_equal SITE, @runtime.stored_settings
      assert_public_projection_clean(run_id)
      assert_values_stay_private(run_id)
    end
  end

  # -- the snapshot --------------------------------------------------------------------------

  def test_settings_snapshot_is_the_recorded_target_state_bound_by_digest
    with_settings do
      run = run_merge
      assert_equal 'completed', run[:status], run[:failure].inspect
      path = private_path(run[:run_id], 'merge-site-settings.json')
      snapshot = snapshot_for(run[:run_id])
      # Three fields and no more: no row identity, no timestamps.
      assert_equal %w[authorized_extensions_effective settings version], snapshot.keys.sort
      assert_equal 1, snapshot['version']
      # Raw pairs, NULL and empty kept apart, exactly the state recorded before the merge.
      assert_equal SITE, snapshot['settings']
      assert_equal JSON.parse(File.read(@service.store.run_dir(run[:run_id], 'evidence', 'merge-before.json'))).fetch('settings'), snapshot['settings']
      assert_equal SITE.dig(NAME, 0), snapshot['authorized_extensions_effective']
      assert_equal 0600, File.stat(path).mode & 0777
      assert_equal 0700, File.stat(File.dirname(path)).mode & 0777
      assert File.binread(path).end_with?("\n")
      assert_equal Digest::SHA256.file(path).hexdigest, binding_for(run[:run_id])['sha256']
      # One capture per run: a second one would bless whatever the constructor left.
      stack = @service.send(:stack_for, run[:run_id], 'review')
      bytes = File.binread(path)
      standard_error(CODE) { @service.send(:merge_site_settings_capture!, run[:run_id], stack) }
      assert_equal 1, helper_calls('capture').size
      assert_equal bytes, File.binread(path)
    end
    # The temporary setting has no stored row: its absence is part of the snapshot.
    [SITE.reject { |name, _| name == NAME }, {}].each do |settings|
      with_settings(settings) do
        run = run_merge
        assert_equal 'completed', run[:status], run[:failure].inspect
        snapshot = snapshot_for(run[:run_id])
        assert_equal %w[authorized_extensions_effective settings version], snapshot.keys.sort
        assert_equal settings, snapshot['settings']
        refute snapshot['settings'].key?(NAME)
        assert_equal MergeScriptedRuntime::DEFAULT_EXTENSIONS, snapshot['authorized_extensions_effective']
        assert_equal 'verified', run.dig(:results, 'merge', 'site_settings_preservation')
      end
    end
  end

  def test_settings_capture_that_proves_nothing_starts_no_merger
    line = ->(snapshot) { "SILO_SETTINGS_SNAPSHOT:#{JSON.generate(snapshot)}\n" }
    marker = 'CAPTURE-BOOT-ERROR-VALUE'
    helpers = {
      'failed with a snapshot' => ->(good) { failed_result(4, stdout: line.call(good), stderr: "SILO_SETTINGS_ERROR: failed\n") },
      'failed, quoting a value' => ->(_good) { failed_result(1, stdout: "#{marker}\n", stderr: "ArgumentError: #{marker}\n") },
      'timed out' => ->(good) { failed_result(nil, stdout: line.call(good)) },
      'no snapshot' => ->(_good) { ok_result("booted\n") },
      'two snapshots' => ->(good) { ok_result(line.call(good) * 2) },
      'not JSON' => ->(_good) { ok_result("SILO_SETTINGS_SNAPSHOT:{\"version\":1,\n") },
      'not an object' => ->(_good) { ok_result("SILO_SETTINGS_SNAPSHOT:[]\n") },
      'indented marker' => ->(good) { ok_result(' ' + line.call(good)) },
      'another version' => ->(good) { ok_result(line.call(good.merge('version' => 2))) },
      'no version' => ->(good) { ok_result(line.call(good.except('version'))) },
      'settings as a list' => ->(good) { ok_result(line.call(good.merge('settings' => good['settings'].to_a))) },
      'no settings' => ->(good) { ok_result(line.call(good.except('settings'))) },
      'no effective value' => ->(good) { ok_result(line.call(good.except('authorized_extensions_effective'))) },
      'null effective value' => ->(good) { ok_result(line.call(good.merge('authorized_extensions_effective' => nil))) },
      'a changed value' => ->(good) { ok_result(line.call(good.merge('settings' => good['settings'].merge('title' => ['other', 1])))) },
      'a changed type' => ->(good) { ok_result(line.call(good.merge('settings' => good['settings'].merge('title' => [SITE.dig('title', 0), 2])))) },
      'a missing row' => ->(good) { ok_result(line.call(good.merge('settings' => good['settings'].except('title')))) },
      'an extra row' => ->(good) { ok_result(line.call(good.merge('settings' => good['settings'].merge(EXTRA => ['on', 5])))) },
      'null for empty' => ->(good) { ok_result(line.call(good.merge('settings' => good['settings'].merge('empty_value' => [nil, 1])))) },
      'too large' => ->(good) { ok_result(line.call(good) + ('x' * (SETTINGS::MERGE_SITE_SETTINGS_BYTES + 1))) }
    }
    helpers.each do |label, helper|
      with_settings do
        before_command(%r{chown -R root:root /shared/merge &&}) { @runtime.capture_result = helper.call(@runtime.settings_snapshot) }
        run = run_merge
        assert_settings_failure(run, 'merge', label)
        assert_equal 'pending', run.dig(:stages, 'finalize'), label
        assert_equal 1, helper_calls('capture').size, label
        # Nothing was bound, so nothing is constructed, installed, checked or "restored".
        assert_equal [], positions(CONSTRUCTOR), label
        assert_equal [], settings_commands(helper_calls('capture').first + 1), label
        assert_equal [], positions(OWNERSHIP), label
        assert_nil binding_for(run[:run_id]), label
        refute File.exist?(private_path(run[:run_id], 'merge-site-settings.json')), label
        assert_equal [], Dir.glob(private_path(run[:run_id], 'merge-site-settings-*.json')), label
        assert_nil run.dig(:results, 'merge', 'site_settings_preservation'), label
        assert_equal SITE, @runtime.stored_settings, label
        assert_public_projection_clean(run[:run_id], marker)
        assert_values_stay_private(run[:run_id], marker)
      end
    end
  end

  # The state helper and the capture agree on a row that isn't a raw (value, type) pair: still refused.
  def test_settings_capture_of_malformed_rows_is_refused
    [['on', 5, 'extra'], ['on'], [5, 5], ['on', '5'], ['on', nil], 'on', nil].each do |pair|
      with_settings do
        @runtime.stored_settings = SITE.merge(EXTRA => pair)
        run = run_merge
        assert_settings_failure(run, 'merge', pair.inspect)
        assert_equal [], positions(CONSTRUCTOR), pair.inspect
        assert_nil binding_for(run[:run_id]), pair.inspect
      end
    end
    with_settings do
      @runtime.stored_settings = SITE.merge('' => ['on', 5])
      assert_settings_failure(run_merge, 'merge')
      assert_equal [], positions(CONSTRUCTOR)
    end
  end

  # -- nothing is imported, nothing else is repaired -----------------------------------------

  def test_settings_of_the_source_are_never_imported
    source = { 'title' => ["#{PRIVATE} source title", 1], NAME => ['pdf|zip', 8], EXTRA => ['on', 5] }
    with_settings do
      @runtime.source_state = { 'settings' => source }
      run = run_merge
      assert_equal 'completed', run[:status], run[:failure].inspect
      assert_equal SITE, snapshot_for(run[:run_id])['settings']
      assert_equal SITE, @runtime.stored_settings
      # No settings command is pointed at the source copy.
      (helper_calls + positions(QUERY)).each { |index| refute_match(/merge_source|SILO_MERGE_CONFIG|merge-source\.conf/, issued[index]) }
      # Besides those, only the constructor and the rebake (each told the snapshot's digest) and the snapshot's own install.
      assert_equal [position(CONSTRUCTOR), position(REBAKE)], settings_commands(0) - helper_calls - positions(QUERY) - positions(%r{/shared/merge/site-settings\.json\z})
      assert_equal 5, positions(/ -d discourse -Atc #{QUERY.source}/).size
    end
    # A merger that copies source settings over the destination is caught at its own boundary.
    with_settings do
      @runtime.source_state = { 'settings' => source }
      before_command(CONSTRUCTOR) { @runtime.stored_settings.merge!(JSON.parse(JSON.generate(source))) }
      run = run_merge
      assert_settings_failure(run, 'merge')
      assert_equal 'pending', run.dig(:stages, 'finalize')
      assert_equal expected_report('after-merge', 'changed', unexpected: [NAME, EXTRA, 'title'].sort), report(run[:run_id], 'after-merge')
      assert_nil run.dig(:artifacts, 'backup')
      # Cleanup puts back the one temporary setting; the others are named and left as found.
      assert_equal 1, helper_calls('restore').size
      assert_equal expected_report('failure', 'unproven', unexpected: [EXTRA, 'title'].sort), report(run[:run_id], 'failure')
      assert_equal SITE[NAME], @runtime.stored_settings[NAME]
      assert_equal source['title'], @runtime.stored_settings['title']
      assert_equal source[EXTRA], @runtime.stored_settings[EXTRA]
      refute(issued.any? { |line| line.match?(/\b(UPDATE|INSERT|DELETE|TRUNCATE|COPY)\b[^|]*\bsite_settings\b/i) })
      assert_equal %w[capture restore], helper_calls.map { |index| issued[index][/ACTION\\?=(\w+)/, 1] }
      assert_equal 'unproven', run.dig(:results, 'merge', 'site_settings_preservation')
      assert_equal 2, run.dig(:results, 'merge', 'site_settings_changed')
      assert_public_projection_clean(run[:run_id], 'pdf|zip', 'source title')
      assert_values_stay_private(run[:run_id])
    end
  end

  # -- every later boundary ------------------------------------------------------------------

  def boundary_cases
    [
      ['after-merge', 'merge', [CONSTRUCTOR, {}]],
      ['before-finalize', 'finalize', [QUERY, { after_checks: 1 }]],
      ['after-finalize', 'finalize', [/bundle exec rake search:reindex/, {}]],
      ['verify', 'verify', [%r{rails runner /tmp/merge_state\.rb\z}, { after_checks: 3 }]],
      ['before-backup', 'backup', [QUERY, { after_checks: 3 }]],
      ['completion', 'review_url', [QUERY, { after_checks: 4 }]]
    ]
  end

  def test_settings_unexpected_change_fails_the_run_at_each_boundary
    changes = {
      'a new row' => ->(settings) { settings[EXTRA] = ['on', 5] },
      'a value' => ->(settings) { settings[EXTRA] = ['off', 5] },
      'a type' => ->(settings) { settings[EXTRA] = ['on', 1] },
      'a removed row' => ->(settings) { settings.delete(EXTRA) },
      'NULL for empty' => ->(settings) { settings[EXTRA] = [nil, 5] }
    }
    boundary_cases.each do |phase, stage, (pattern, options)|
      changes.each do |label, change|
        with_settings(label == 'a new row' ? SITE : SITE.merge(EXTRA => ['on', 5])) do
          before_command(pattern, **options) { change.call(@runtime.stored_settings) }
          run = run_merge
          message = "#{phase}: #{label}"
          assert_settings_failure(run, stage, message)
          reached = PHASES.index(phase)
          PHASES.first(reached).each { |earlier| assert_equal expected_report(earlier, 'verified'), report(run[:run_id], earlier), message }
          assert_equal expected_report(phase, 'changed', unexpected: [EXTRA]), report(run[:run_id], phase), message
          PHASES.drop(reached + 1).each { |later| assert_nil report(run[:run_id], later), message }
          stages = SiloMigrate::Services::StandardMergeRun::MERGE_STAGES
          stages.drop(stages.index(stage) + 1).each { |later| assert_equal 'pending', run.dig(:stages, later), message }
          # What the failed boundary guards never happens.
          assert_equal [], positions(FINALIZE), message if reached < 2
          assert_equal [], positions(%r{script/discourse backup }), message if reached < 5
          assert_nil run.dig(:artifacts, 'backup'), message if reached < 5
          assert_equal [], positions(/review_access\.rb/).select { |index| issued[index].start_with?('docker exec') && !issued[index].include?('chown') }, message if reached < 5
          standard_error('STANDARD_RELEASE_NOT_READY') { @service.release_backup(run_id: run[:run_id], reviewer: 'Invented engineer', acknowledge_differences: true) }
          # The other setting is reported by the cleanup too, and left exactly as it was found.
          changed = JSON.parse(JSON.generate(@runtime.stored_settings))
          assert_equal expected_report('failure', 'unproven', unexpected: [EXTRA]), report(run[:run_id], 'failure'), message
          assert_equal 1, helper_calls('restore').size, message
          assert_equal [], positions(QUERY, from: helper_calls('restore').first), message
          assert_equal changed, @runtime.stored_settings
          assert_equal 'unproven', run.dig(:results, 'merge', 'site_settings_preservation'), message
          assert_equal 1, run.dig(:results, 'merge', 'site_settings_changed'), message
          assert_public_projection_clean(run[:run_id])
          assert_values_stay_private(run[:run_id])
        end
      end
    end
  end

  # The stock assignment still in place at a later boundary is a failure there too, even though
  # the cleanup can then put it back: a restored failed run is still a failed run.
  def test_settings_leftover_stock_assignment_fails_each_boundary_and_is_restored
    boundary_cases.each do |phase, stage, (pattern, options)|
      [SITE, SITE.reject { |name, _| name == NAME }].each do |settings|
        with_settings(settings) do
          before_command(pattern, **options) { @runtime.stored_settings[NAME] = STOCK.dup }
          run = run_merge
          assert_settings_failure(run, stage, phase)
          assert_equal expected_report(phase, 'changed', unexpected: [NAME]), report(run[:run_id], phase), phase
          assert_equal expected_report('failure', 'restored'), report(run[:run_id], 'failure'), phase
          assert_equal settings, @runtime.stored_settings
          assert_equal 'failed', @service.show_run(run[:run_id])[:status]
          assert_equal 'restored', run.dig(:results, 'merge', 'site_settings_preservation')
          assert_equal 0, run.dig(:results, 'merge', 'site_settings_changed')
          assert_equal 'dirty', @service.store.load.fetch('instances').values.last['state']
        end
      end
    end
  end

  # Stored rows equal, effective value not (a cache that was never refreshed): only the
  # verify stage's Rails read can see it, and it must.
  def test_settings_verify_compares_the_effective_value
    with_settings do
      before_command(%r{rails runner /tmp/merge_state\.rb\z}, after_checks: 3) { @runtime.effective_extensions = STOCK.first }
      run = run_merge
      assert_settings_failure(run, 'verify')
      assert_equal expected_report('verify', 'changed', unexpected: [NAME]), report(run[:run_id], 'verify')
      assert_equal expected_report('after-finalize', 'verified'), report(run[:run_id], 'after-finalize')
      assert_nil run.dig(:artifacts, 'backup')
      assert_equal expected_report('failure', 'restored'), report(run[:run_id], 'failure')
    end
    # A state helper that doesn't report the effective value proves nothing about it.
    [nil, 5, ['jpg'], true].each do |value|
      with_settings do
        @runtime.target_state = @runtime.target_state.merge('effective_authorized_extensions' => value)
        run = run_merge
        assert_settings_failure(run, 'verify', value.inspect)
        refute_equal 'verified', report(run[:run_id], 'verify')&.fetch('state')
        assert_equal [], positions(%r{script/discourse backup })
        assert_nil run.dig(:artifacts, 'backup')
      end
    end
  end

  # A check that can't be read is recorded as unproven: never as verified, never skipped.
  def test_settings_unreadable_check_is_unproven_at_each_boundary
    marker = 'QUERY-ERROR-VALUE'
    answers = {
      'psql failed' => -> { failed_result(2, stderr: "psql: error: #{marker}\n") },
      'failed with rows' => -> { failed_result(1, stdout: JSON.generate(@runtime.stored_settings) + "\n", stderr: marker) },
      'timed out' => -> { failed_result(nil, stdout: JSON.generate(@runtime.stored_settings) + "\n") },
      'empty' => -> { ok_result('') },
      'not JSON' => -> { ok_result("#{marker}\n") },
      'two rows' => -> { ok_result((JSON.generate(@runtime.stored_settings) + "\n") * 2) },
      'trailing output' => -> { ok_result(JSON.generate(@runtime.stored_settings) + "\n#{marker}\n") }
    }
    stages = { 'after-merge' => 'merge', 'before-finalize' => 'finalize', 'after-finalize' => 'finalize', 'before-backup' => 'backup', 'completion' => 'review_url' }
    stages.each_with_index do |(phase, stage), ordinal|
      answers.each do |label, answer|
        with_settings do
          before_command(QUERY, after_checks: ordinal) { @runtime.settings_query_result = answer.call }
          run = run_merge
          message = "#{phase}: #{label}"
          assert_settings_failure(run, stage, message)
          assert_equal expected_report(phase, 'unproven', remaining: nil), report(run[:run_id], phase), message
          assert_equal [], positions(%r{script/discourse backup }), message unless phase == 'completion'
          assert_equal ordinal + 1, positions(QUERY).size, message
          assert_public_projection_clean(run[:run_id], marker)
          assert_values_stay_private(run[:run_id], marker)
        end
      end
    end
    # Rows that parse but aren't raw pairs are not a verified comparison either.
    [{ 'title' => 'x' }, { 'title' => ['x', '1'] }, [], 'x', nil].each do |rows|
      with_settings do
        before_command(QUERY) { @runtime.settings_query_result = ok_result(JSON.generate(rows) + "\n") }
        run = run_merge
        assert_settings_failure(run, 'merge', rows.inspect)
        refute_equal 'verified', report(run[:run_id], 'after-merge')&.fetch('state')
        assert_equal 'pending', run.dig(:stages, 'finalize')
      end
    end
  end

  # -- failure cleanup -----------------------------------------------------------------------

  def test_settings_failed_merger_is_restored_from_the_bound_snapshot
    with_settings do
      before_command(CONSTRUCTOR) do
        @runtime.stored_settings[NAME] = STOCK.dup
        @runtime.merger_result = failed_result(1, stdout: "SILO_MERGE: start layer=no\ncustomer row #{PRIVATE}\n", stderr: 'RuntimeError')
      end
      run = run_merge
      run_id = run[:run_id]
      # The run's own failure stands; the cleanup neither replaces nor hides it.
      assert_equal 'failed', run[:status]
      assert_equal({ 'stage' => 'merge', 'code' => 'STANDARD_MERGE_FAILED' }, run[:failure].slice('stage', 'code'))
      assert_equal [], positions(QUERY)
      assert_nil report(run_id, 'after-merge')
      # Both containers are proven to be this run's before anything is copied or executed.
      constructor = position(CONSTRUCTOR)
      record = @service.store.load.fetch('instances').values.last
      owned = positions(OWNERSHIP, from: constructor)
      assert_equal %w[db web].map { |role| record.fetch('containers').fetch(role) }, owned.map { |index| issued[index].split.last }
      install = position(INSTALL, from: constructor)
      restore = helper_calls('restore')
      assert_equal 1, restore.size
      order = [constructor, *owned, install, position(%r{chmod 0444 /shared/merge/site-settings\.json\z}, from: install), restore.first]
      assert_equal order.sort, order
      # The host's bound copy is installed again; whatever the failed process left is not trusted.
      assert_equal 2, positions(INSTALL).size
      assert_equal issued[position(INSTALL)], issued[install]
      assert_match digest_env(run_id), issued[restore.first]
      # It ended and said so: nothing is uncertain, so the helper may write.
      assert_equal 'finished', binding_for(run_id)['execution']
      refute_includes issued[restore.first], 'EXECUTION_UNCERTAIN'
      assert_equal SITE, @runtime.stored_settings
      assert_equal expected_report('failure', 'restored'), report(run_id, 'failure')
      assert_equal 'restored', run.dig(:results, 'merge', 'site_settings_preservation')
      assert_equal 0, run.dig(:results, 'merge', 'site_settings_changed')
      assert_equal 'dirty', record['state']
      assert_public_projection_clean(run_id)
      # The trusted merge log keeps the merger's own output, as before; nothing else gains a value.
      assert_includes @service.merge_evidence(run_id)['log_tail'], PRIVATE
      FileUtils.rm_f(@service.store.run_dir(run_id, 'logs', 'merge.log'))
      assert_values_stay_private(run_id)
    end
  end

  # A restore that exits nonzero still names what it found. The names and count are kept, in
  # the private report only, and the state is never better than unproven.
  def test_settings_failed_restore_keeps_names_and_counts_privately
    with_settings do
      before_command(CONSTRUCTOR) do
        @runtime.stored_settings[NAME] = STOCK.dup
        @runtime.stored_settings[EXTRA] = ['on', 5]
        @runtime.stored_settings.delete('max_attachment_size_kb')
        @runtime.merger_result = failed_result(1, stderr: 'RuntimeError')
      end
      run = run_merge
      assert_equal 'STANDARD_MERGE_FAILED', run.dig(:failure, 'code')
      assert_equal expected_report('failure', 'unproven', unexpected: ['max_attachment_size_kb', EXTRA]), report(run[:run_id], 'failure')
      assert_equal 0600, File.stat(private_path(run[:run_id], 'merge-site-settings-failure.json')).mode & 0777
      assert_equal 'unproven', run.dig(:results, 'merge', 'site_settings_preservation')
      assert_equal 2, run.dig(:results, 'merge', 'site_settings_changed')
      # Reported, not repaired.
      assert_equal ['on', 5], @runtime.stored_settings[EXTRA]
      refute @runtime.stored_settings.key?('max_attachment_size_kb')
      assert_equal SITE[NAME], @runtime.stored_settings[NAME]
      assert_public_projection_clean(run[:run_id], 'max_attachment_size_kb')
      assert_values_stay_private(run[:run_id])
    end
    # The temporary setting itself couldn't be put back.
    with_settings do
      before_command(CONSTRUCTOR) do
        @runtime.stored_settings[NAME] = STOCK.dup
        @runtime.restore_fails = true
        @runtime.merger_result = failed_result(1, stderr: 'RuntimeError')
      end
      run = run_merge
      assert_equal 'STANDARD_MERGE_FAILED', run.dig(:failure, 'code')
      assert_equal expected_report('failure', 'unproven', failed: [NAME]), report(run[:run_id], 'failure')
      assert_equal 'unproven', run.dig(:results, 'merge', 'site_settings_preservation')
      assert_equal 1, run.dig(:results, 'merge', 'site_settings_changed')
      assert_equal STOCK, @runtime.stored_settings[NAME]
      assert_equal 1, helper_calls('restore').size
    end
  end

  # The runner's own settings refusal is this failure, whatever else its output holds.
  def test_settings_runner_refusal_is_a_settings_failure
    %w[snapshot-digest-mismatch changed-by-layer-load changed-during-copy restore-unproven early-exit].each do |tag|
      with_settings do
        before_command(CONSTRUCTOR) do
          @runtime.stored_settings[EXTRA] = ['on', 5]
          @runtime.merger_result = failed_result(4, stdout: "SILO_MERGE: start layer=no\nPG::UndefinedColumn\n", stderr: "SILO_MERGE: settings #{tag}\n")
        end
        run = run_merge
        assert_settings_failure(run, 'merge', tag)
        assert_equal expected_report('failure', 'unproven', unexpected: [EXTRA]), report(run[:run_id], 'failure')
        assert_equal [], positions(FINALIZE)
      end
    end
    # Only at the start of a line: a row that quotes the phrase is not the runner speaking.
    with_settings do
      @runtime.merger_result = failed_result(1, stdout: "row: SILO_MERGE: settings changed\n")
      assert_equal 'STANDARD_MERGE_FAILED', run_merge.dig(:failure, 'code')
    end
    # The installed snapshot must be the bound one: the scripted runner checks the digest it is given.
    with_settings do
      before_command(INSTALL) { File.chmod(0600, private_path(last_run_id, 'merge-site-settings.json')); File.write(private_path(last_run_id, 'merge-site-settings.json'), '{}', mode: 'a') }
      run = run_merge
      assert_settings_failure(run, 'merge')
      assert_equal unproven('failure'), report(run[:run_id], 'failure')
    end
  end

  # A restore helper that doesn't answer as agreed proves nothing, whatever its exit status.
  def test_settings_restore_answers_that_prove_nothing_are_unproven
    marker = 'RESTORE-ERROR-VALUE'
    line = ->(report) { "SILO_SETTINGS_REPORT:#{JSON.generate(report)}\n" }
    good = { 'version' => 1, 'state' => 'restored', 'restoration_failed' => [], 'unexpected_names' => [], 'remaining_differences' => 0, 'effective_matches' => true }
    fallback = unproven('failure')
    answers = {
      'no report' => [ok_result("booted\n"), fallback],
      'failed without a report' => [failed_result(4, stdout: "#{marker}\n", stderr: "SILO_SETTINGS_ERROR: failed (#{marker})\n"), fallback],
      'two reports' => [ok_result(line.call(good) * 2), fallback],
      'not JSON' => [ok_result("SILO_SETTINGS_REPORT:{\n"), fallback],
      'not an object' => [ok_result("SILO_SETTINGS_REPORT:[\"restored\"]\n"), fallback],
      'indented marker' => [ok_result(' ' + line.call(good)), fallback],
      'no state' => [ok_result(line.call(good.except('state'))), fallback],
      'a verify state' => [ok_result(line.call(good.merge('state' => 'clean'))), fallback],
      'a host state' => [ok_result(line.call(good.merge('state' => 'verified'))), fallback],
      'names as a string' => [ok_result(line.call(good.merge('unexpected_names' => EXTRA))), fallback],
      'names that are not strings' => [ok_result(line.call(good.merge('unexpected_names' => [{ EXTRA => marker }]))), fallback],
      'failed names that are not strings' => [ok_result(line.call(good.merge('restoration_failed' => [1]))), fallback],
      'a negative count' => [ok_result(line.call(good.merge('remaining_differences' => -1))), fallback],
      'a count as text' => [ok_result(line.call(good.merge('remaining_differences' => '0'))), fallback],
      'too large' => [ok_result(line.call(good) + ('x' * (SETTINGS::MERGE_SITE_SETTINGS_BYTES + 1))), fallback],
      # Answered as agreed, but the process didn't succeed: its claim is not taken.
      'restored, exit 4' => [failed_result(4, stdout: line.call(good)), expected_report('failure', 'unproven')],
      'restored, timed out' => [failed_result(nil, stdout: line.call(good)), expected_report('failure', 'unproven')],
      # Only the fixed fields are kept: a helper can't turn its report into a dump of values.
      'extra fields' => [failed_result(4, stdout: line.call(good.merge('state' => 'unproven', 'unexpected_names' => [EXTRA, EXTRA, 'a_setting'], 'remaining_differences' => 2,
                                                                        'values' => { EXTRA => marker }, 'phase' => marker, 'version' => marker, 'execution_uncertain' => marker))),
                         expected_report('failure', 'unproven', unexpected: ['a_setting', EXTRA])]
    }
    answers.each do |label, (answer, expected)|
      with_settings do
        before_command(CONSTRUCTOR) do
          @runtime.stored_settings[NAME] = STOCK.dup
          @runtime.restore_result = answer
          @runtime.merger_result = failed_result(1, stderr: 'RuntimeError')
        end
        run = run_merge
        assert_equal 'STANDARD_MERGE_FAILED', run.dig(:failure, 'code'), label
        assert_equal expected, report(run[:run_id], 'failure'), label
        assert_equal 'unproven', run.dig(:results, 'merge', 'site_settings_preservation'), label
        changed = run.dig(:results, 'merge', 'site_settings_changed')
        expected['remaining_differences'].nil? ? assert_nil(changed, label) : assert_equal(expected['remaining_differences'], changed, label)
        assert_equal 1, helper_calls('restore').size, label
        assert_equal 'failed', @service.show_run(run[:run_id])[:status], label
        assert_public_projection_clean(run[:run_id], marker, 'a_setting')
        assert_values_stay_private(run[:run_id], marker)
      end
    end
  end

  # "restored" with settings still named as different is not a restoration.
  def test_settings_restore_claim_with_remaining_differences_is_not_restored
    line = ->(report) { "SILO_SETTINGS_REPORT:#{JSON.generate(report)}\n" }
    good = { 'version' => 1, 'state' => 'restored', 'restoration_failed' => [], 'unexpected_names' => [], 'remaining_differences' => 0 }
    claims = {
      'an unexpected name' => [good.merge('unexpected_names' => [EXTRA], 'remaining_differences' => 1), { unexpected: [EXTRA] }],
      'a failed restoration' => [good.merge('restoration_failed' => [NAME], 'remaining_differences' => 1), { failed: [NAME] }],
      'a count without names' => [good.merge('remaining_differences' => 3), { remaining: 3 }],
      'names without a count' => [good.merge('unexpected_names' => [EXTRA]), { unexpected: [EXTRA], remaining: 0 }],
      'a null count' => [good.merge('remaining_differences' => nil), { remaining: nil }],
      'no count' => [good.except('remaining_differences'), { remaining: nil }]
    }
    claims.each do |label, (claim, kept)|
      with_settings do
        before_command(CONSTRUCTOR) do
          @runtime.restore_result = ok_result(line.call(claim))
          @runtime.merger_result = failed_result(1, stderr: 'RuntimeError')
        end
        run = run_merge
        assert_equal 'failed', run[:status], label
        # What it named is kept as it named it; only the claim is not taken.
        assert_equal expected_report('failure', 'unproven', **kept), report(run[:run_id], 'failure'), label
        assert_equal 'unproven', run.dig(:results, 'merge', 'site_settings_preservation'), label
        assert_public_projection_clean(run[:run_id])
      end
    end
  end

  # -- the temporary setting's prior state ----------------------------------------------------

  # Whatever the destination held for the temporary setting (a row with any raw value and
  # type, or no row at all) is what a finished, failed run is left with: exactly that, with
  # nothing else touched.
  def test_settings_prior_override_present_or_absent_is_captured_and_put_back
    priors = {
      'a customer value' => SITE[NAME], 'the stock value' => STOCK.dup, 'an empty value' => ['', 8], 'a NULL value' => [nil, 8],
      'another type' => ['jpg|png', 1], 'no row' => nil
    }
    left = {
      'the stock assignment' => -> { @runtime.stored_settings[NAME] = STOCK.dup },
      'no row' => -> { @runtime.stored_settings.delete(NAME) },
      'the stock value under another type' => -> { @runtime.stored_settings[NAME] = [STOCK.first, 1] },
      'only a stale effective value' => -> { @runtime.effective_extensions = STOCK.first },
      'nothing' => -> {}
    }
    priors.each do |prior_label, prior|
      left.each do |left_label, leave|
        settings = SITE.reject { |name, _| name == NAME }
        settings = settings.merge(NAME => prior) if prior
        with_settings(settings) do
          label = "#{prior_label}, left with #{left_label}"
          effective = @runtime.effective_authorized_extensions
          before_command(CONSTRUCTOR) do
            leave.call
            @runtime.merger_result = failed_result(1, stderr: 'RuntimeError')
          end
          run = run_merge
          assert_equal 'STANDARD_MERGE_FAILED', run.dig(:failure, 'code'), label
          snapshot = snapshot_for(run[:run_id])
          assert_equal %w[authorized_extensions_effective settings version], snapshot.keys.sort, label
          assert_equal settings, snapshot['settings'], label
          assert_equal !prior.nil?, snapshot['settings'].key?(NAME), label
          assert_equal effective, snapshot['authorized_extensions_effective'], label
          # A known, finished failure: the helper may write, and puts back exactly the prior state.
          restore = helper_calls('restore')
          assert_equal 1, restore.size, label
          refute_includes issued[restore.first], 'EXECUTION_UNCERTAIN', label
          assert_equal settings, @runtime.stored_settings, label
          assert_equal !prior.nil?, @runtime.stored_settings.key?(NAME), label
          assert_equal effective, @runtime.effective_authorized_extensions, label
          assert_equal expected_report('failure', 'restored'), report(run[:run_id], 'failure'), label
          assert_equal 'restored', run.dig(:results, 'merge', 'site_settings_preservation'), label
          assert_equal 'failed', @service.show_run(run[:run_id])[:status], label
        end
      end
    end
    # The helper can't put it back: named, counted and left as the failed run left it.
    [SITE, SITE.reject { |name, _| name == NAME }].each do |settings|
      with_settings(settings) do
        before_command(CONSTRUCTOR) do
          @runtime.stored_settings[NAME] = STOCK.dup
          @runtime.restore_fails = true
          @runtime.merger_result = failed_result(1, stderr: 'RuntimeError')
        end
        run = run_merge
        assert_equal expected_report('failure', 'unproven', failed: [NAME]), report(run[:run_id], 'failure')
        assert_equal STOCK, @runtime.stored_settings[NAME]
        assert_equal 1, run.dig(:results, 'merge', 'site_settings_changed')
      end
    end
  end

  # -- an execution that may still be running ------------------------------------------------

  # The client's timeout says nothing about the process in the stack: it may still be writing,
  # and the host has no way to stop it. So the helper is told to write nothing; what it reads
  # is recorded, and the result is never called restored or proven.
  def test_settings_merger_timeout_is_failed_and_nothing_is_written
    cases = {
      'the stock assignment in place' => [-> { @runtime.stored_settings[NAME] = STOCK.dup }, { failed: [NAME] }],
      'no row where there was one' => [-> { @runtime.stored_settings.delete(NAME) }, { failed: [NAME] }],
      'another setting too' => [-> { @runtime.stored_settings.merge!(NAME => STOCK.dup, EXTRA => ['on', 5]) }, { failed: [NAME], unexpected: [EXTRA] }],
      # Nothing differs, and that still isn't proof: a read can't show the process has stopped.
      'nothing differing' => [-> {}, {}]
    }
    cases.each do |label, (leave, found)|
      with_settings do
        left = nil
        before_command(CONSTRUCTOR) do
          leave.call
          left = JSON.parse(JSON.generate(@runtime.stored_settings))
          @runtime.merger_result = failed_result(nil, stderr: 'timed out')
        end
        run = run_merge
        run_id = run[:run_id]
        assert_equal 'failed', run[:status], label
        assert_equal({ 'stage' => 'merge', 'code' => 'STANDARD_MERGE_FAILED' }, run[:failure].slice('stage', 'code'), label)
        assert_equal 'uncertain', binding_for(run_id)['execution'], label
        restore = helper_calls('restore')
        assert_equal 1, restore.size, label
        assert_match UNCERTAIN, issued[restore.first], label
        assert_match digest_env(run_id), issued[restore.first], label
        # Read against the bound snapshot, and nothing written.
        assert_equal 2, positions(INSTALL).size, label
        assert_equal left, @runtime.stored_settings, label
        assert_equal expected_report('failure', 'unproven', **found, uncertain: true), report(run_id, 'failure'), label
        assert_equal 'unproven', run.dig(:results, 'merge', 'site_settings_preservation'), label
        assert_equal found.values.sum(&:size), run.dig(:results, 'merge', 'site_settings_changed'), label
        assert_equal [], positions(QUERY), label
        assert_equal [], positions(FINALIZE), label
        assert_nil run.dig(:artifacts, 'backup'), label
        assert_equal 'dirty', @service.store.load.fetch('instances').values.last['state'], label
        standard_error('STANDARD_RELEASE_NOT_READY') { @service.release_backup(run_id: run_id, reviewer: 'Invented engineer', acknowledge_differences: true) }
        assert_public_projection_clean(run_id)
        assert_values_stay_private(run_id)
      end
    end
    # A helper that claims a restoration anyway (and exits 0) is not believed.
    with_settings do
      claim = { 'version' => 1, 'state' => 'restored', 'restoration_failed' => [], 'unexpected_names' => [], 'remaining_differences' => 0 }
      before_command(CONSTRUCTOR) do
        @runtime.restore_result = ok_result("SILO_SETTINGS_REPORT:#{JSON.generate(claim)}\n")
        @runtime.merger_result = failed_result(nil, stderr: 'timed out')
      end
      run = run_merge
      assert_equal 'failed', run[:status]
      assert_equal expected_report('failure', 'unproven', uncertain: true), report(run[:run_id], 'failure')
      assert_equal 'unproven', run.dig(:results, 'merge', 'site_settings_preservation')
    end
  end

  def test_settings_finalize_timeout_is_failed_and_nothing_is_written
    FINALIZE_STEPS.each_with_index do |(step, pattern), ordinal|
      [false, true].each do |stock|
        with_settings do
          label = "#{step}#{' with the stock assignment in place' if stock}"
          @runtime.finalize_results = { step => failed_result(nil, stderr: 'timed out') }
          before_command(pattern) { @runtime.stored_settings[NAME] = STOCK.dup } if stock
          run = run_merge
          run_id = run[:run_id]
          assert_equal({ 'stage' => 'finalize', 'code' => 'STANDARD_MERGE_FAILED' }, run[:failure].slice('stage', 'code'), label)
          assert_equal 'uncertain', binding_for(run_id)['execution'], label
          assert_equal ordinal + 1, positions(FINALIZE).size, label
          assert_equal [], positions(/sv start unicorn/, from: position(FINALIZE)), label
          restore = helper_calls('restore')
          assert_equal 1, restore.size, label
          assert_match UNCERTAIN, issued[restore.first], label
          # Even a helper that found nothing differing has proven nothing here; one that found
          # the stock assignment leaves it, named and counted.
          assert_equal expected_report('failure', 'unproven', failed: stock ? [NAME] : [], uncertain: true), report(run_id, 'failure'), label
          assert_equal stock ? SITE.merge(NAME => STOCK) : SITE, @runtime.stored_settings, label
          assert_equal 'unproven', run.dig(:results, 'merge', 'site_settings_preservation'), label
          assert_equal stock ? 1 : 0, run.dig(:results, 'merge', 'site_settings_changed'), label
          assert_equal expected_report('before-finalize', 'verified'), report(run_id, 'before-finalize'), label
          assert_nil report(run_id, 'after-finalize'), label
          assert_equal 2, positions(QUERY).size, label
          assert_nil run.dig(:artifacts, 'backup'), label
          assert_equal 'pending', run.dig(:stages, 'verify'), label
          assert_equal 'failed', @service.show_run(run_id)[:status], label
        end
      end
    end
    # A step that ended (and failed) is not still running: the helper may write, and its answer stands.
    FINALIZE_STEPS.each do |step, pattern|
      with_settings do
        @runtime.finalize_results = { step => failed_result(1, stderr: 'aborted!') }
        before_command(pattern) { @runtime.stored_settings[NAME] = STOCK.dup }
        run = run_merge
        assert_equal({ 'stage' => 'finalize', 'code' => 'STANDARD_MERGE_FAILED' }, run[:failure].slice('stage', 'code'), step)
        assert_equal 'finished', binding_for(run[:run_id])['execution'], step
        refute_includes issued[helper_calls('restore').first], 'EXECUTION_UNCERTAIN', step
        assert_equal expected_report('failure', 'restored'), report(run[:run_id], 'failure'), step
        assert_equal SITE, @runtime.stored_settings, step
        assert_equal 'failed', run[:status], step
      end
    end
    # A finished step that changed a setting is caught by the check after finalization.
    FINALIZE_STEPS.each_value do |pattern|
      with_settings do
        before_command(pattern) { @runtime.stored_settings[EXTRA] = ['on', 5] }
        run = run_merge
        assert_settings_failure(run, 'finalize')
        assert_equal 3, positions(FINALIZE).size
        assert_equal expected_report('after-finalize', 'changed', unexpected: [EXTRA]), report(run[:run_id], 'after-finalize')
        assert_nil run.dig(:artifacts, 'backup')
      end
    end
  end

  # -- rebaking ------------------------------------------------------------------------------

  # The stock rebake task assigns a setting of its own (disable_system_edit_notifications) and
  # leaves a row behind. It is never run; a host that ran it would be caught after finalization.
  def test_settings_stock_rebake_task_is_never_run_and_would_be_caught
    with_settings do
      run = run_merge
      assert_equal 'completed', run[:status], run[:failure].inspect
      assert_equal [], positions(STOCK_REBAKE)
      assert_equal 1, positions(REBAKE).size
      assert_equal SITE, @runtime.stored_settings
    end
    name = MergeScriptedRuntime::REBAKE_SETTING
    # What that task leaves, left by the step that replaced it: reported by name, never repaired.
    with_settings do
      before_command(REBAKE) { @runtime.stored_settings[name] = ['f', 5] }
      run = run_merge
      assert_settings_failure(run, 'finalize')
      assert_equal expected_report('after-finalize', 'changed', unexpected: [name]), report(run[:run_id], 'after-finalize')
      assert_equal expected_report('failure', 'unproven', unexpected: [name]), report(run[:run_id], 'failure')
      assert_equal ['f', 5], @runtime.stored_settings[name]
      assert_equal [], positions(%r{script/discourse backup })
      assert_nil run.dig(:artifacts, 'backup')
      assert_public_projection_clean(run[:run_id], name)
    end
    # The scripted stack models the stock task itself, so a host that issued it could not pass.
    with_settings do
      before_command(REBAKE) { @service.send(:stack_for, last_run_id, 'review').discourse_shell(%w[bundle exec rake posts:rebake], timeout: 60) }
      run = run_merge
      assert_equal 1, positions(STOCK_REBAKE).size
      assert_settings_failure(run, 'finalize')
      assert_equal expected_report('after-finalize', 'changed', unexpected: [name]), report(run[:run_id], 'after-finalize')
    end
  end

  # The rebake runs under the host's bound snapshot, installed again just before it: whatever
  # the merger left in the stack under that name is not what it reads.
  def test_settings_rebake_runs_under_the_reinstalled_bound_snapshot
    ['{}', "not json\n", nil].each do |left|
      with_settings do
        before_command(FINALIZE_STEPS.fetch('import:ensure_consistency')) { @runtime.guest_snapshot = left }
        run = run_merge
        assert_equal 'completed', run[:status], left.inspect
        assert_equal File.binread(private_path(run[:run_id], 'merge-site-settings.json')), @runtime.guest_snapshot.b
        assert_operator positions(INSTALL).last, :<, position(REBAKE)
        assert_operator positions(INSTALL).last, :>, position(FINALIZE_STEPS.fetch('import:ensure_consistency'))
      end
    end
    # A bound snapshot that is no longer the bound one is not installed, and nothing is rebaked or reindexed.
    snapshot_tampering.slice('bytes changed', 'removed', 'another digest', 'not JSON').each do |label, tamper|
      with_settings do
        before_command(FINALIZE_STEPS.fetch('import:ensure_consistency')) { tamper.call(last_run_id) }
        run = run_merge
        assert_settings_failure(run, 'finalize', label)
        assert_equal 1, positions(INSTALL).size, label
        assert_equal [], positions(REBAKE), label
        assert_equal [], positions(FINALIZE_STEPS.fetch('search:reindex')), label
        assert_equal [], helper_calls('restore'), label
        assert_equal unproven('failure'), report(run[:run_id], 'failure'), label
        assert_nil run.dig(:artifacts, 'backup'), label
      end
    end
  end

  # Exit status alone doesn't say the posts were rebaked: the helper's own completion marker
  # must be its one last line. Without it nothing is reindexed, started or backed up.
  def test_settings_rebake_without_its_completion_marker_finalizes_nothing
    marker = "SILO_MERGE_REBAKE: posts=1\n"
    answers = {
      'no output' => ok_result(''),
      'no marker' => ok_result("Rebaking posts\n"),
      'the marker twice' => ok_result(marker * 2),
      'two different markers' => ok_result("SILO_MERGE_REBAKE: posts=1\nSILO_MERGE_REBAKE: posts=2\n"),
      'the marker not last' => ok_result("#{marker}warning: something else\n"),
      'an indented marker' => ok_result(" #{marker}"),
      'a marker with more on its line' => ok_result("SILO_MERGE_REBAKE: posts=1 of 2\n"),
      'no count' => ok_result("SILO_MERGE_REBAKE: posts=\n"),
      'a negative count' => ok_result("SILO_MERGE_REBAKE: posts=-1\n"),
      'the marker inside a line' => ok_result("row: #{marker}"),
      'the marker on the error stream only' => SiloMigrate::Runtime::CommandResult.new(success?: true, status: 0, stdout: "done\n", stderr: marker),
      'the marker and a nonzero exit' => failed_result(1, stdout: marker)
    }
    answers.each do |label, answer|
      with_settings do
        @runtime.finalize_results = { 'posts:rebake' => answer }
        run = run_merge
        assert_equal({ 'stage' => 'finalize', 'code' => 'STANDARD_MERGE_FAILED' }, run[:failure].slice('stage', 'code'), label)
        rebake = position(REBAKE)
        assert_equal [], positions(FINALIZE, from: rebake + 1), label
        assert_equal [], positions(/sv start unicorn/, from: rebake), label
        assert_equal [], positions(%r{script/discourse backup }), label
        assert_nil run.dig(:artifacts, 'backup'), label
        assert_nil report(run[:run_id], 'after-finalize'), label
        assert_equal 'pending', run.dig(:stages, 'verify'), label
        # The step ended, so the cleanup may write; the run is failed all the same.
        assert_equal 'finished', binding_for(run[:run_id])['execution'], label
        assert_equal expected_report('failure', 'restored'), report(run[:run_id], 'failure'), label
        assert_equal 'dirty', @service.store.load.fetch('instances').values.last['state'], label
      end
    end
    # Output before the marker is fine; the marker is what ends it.
    with_settings do
      @runtime.finalize_results = { 'posts:rebake' => ok_result("Rebaking 12 posts\n\n#{marker}") }
      assert_equal 'completed', run_merge[:status]
    end
  end

  # The rebake's own settings refusal is this failure, at the start of a line only.
  def test_settings_rebake_refusal_is_a_settings_failure
    %w[snapshot-digest-mismatch snapshot-invalid changed-during-rebake restore-unproven].each do |tag|
      [failed_result(4, stderr: "SILO_MERGE_REBAKE: settings #{tag}\n"),
       failed_result(4, stdout: "Rebaking posts\nSILO_MERGE_REBAKE: settings #{tag}\n", stderr: "PG::UndefinedColumn\n")].each do |answer|
        with_settings do
          @runtime.finalize_results = { 'posts:rebake' => answer }
          before_command(REBAKE) { @runtime.stored_settings[EXTRA] = ['on', 5] }
          run = run_merge
          assert_settings_failure(run, 'finalize', tag)
          assert_equal [], positions(FINALIZE, from: position(REBAKE) + 1), tag
          assert_equal [], positions(%r{script/discourse backup }), tag
          assert_equal expected_report('failure', 'unproven', unexpected: [EXTRA]), report(run[:run_id], 'failure'), tag
          assert_public_projection_clean(run[:run_id])
        end
      end
    end
    with_settings do
      @runtime.finalize_results = { 'posts:rebake' => failed_result(1, stdout: "row: SILO_MERGE_REBAKE: settings changed\n") }
      assert_equal 'STANDARD_MERGE_FAILED', run_merge.dig(:failure, 'code')
    end
    # Said with a zero exit, or alongside the completion marker, it is still not a rebake that completed.
    ["SILO_MERGE_REBAKE: settings changed-during-rebake\n", "SILO_MERGE_REBAKE: settings changed-during-rebake\nSILO_MERGE_REBAKE: posts=1\n"].each do |output|
      with_settings do
        @runtime.finalize_results = { 'posts:rebake' => ok_result(output) }
        run = run_merge
        assert_settings_failure(run, 'finalize', output)
        assert_equal [], positions(FINALIZE, from: position(REBAKE) + 1), output
        assert_nil run.dig(:artifacts, 'backup'), output
      end
    end
    # The scripted helper refuses by itself when the file it finds is not the bound snapshot.
    ["{}\n", nil].each do |found|
      with_settings do
        before_command(REBAKE) { @runtime.guest_snapshot = found }
        run = run_merge
        assert_settings_failure(run, 'finalize', found.inspect)
        assert_equal [], positions(FINALIZE, from: position(REBAKE) + 1), found.inspect
        assert_equal expected_report('failure', 'restored'), report(run[:run_id], 'failure'), found.inspect
      end
    end
  end

  # -- a host that died ----------------------------------------------------------------------

  # The host process died mid-run. Whatever had finished before, an exec may have outlived its
  # client: recovery reads against the bound snapshot, writes nothing and never claims proof.
  def test_settings_recovery_writes_nothing_and_never_claims_proof
    backup = %r{script/discourse backup }
    [[CONSTRUCTOR, 'running', true], [CONSTRUCTOR, 'running', false], [REBAKE, 'running', true], [backup, 'finished', true], [backup, 'finished', false]].each do |pattern, execution, stock|
      with_settings do
        label = "#{pattern.source}#{' with the stock assignment in place' if stock}"
        before_command(pattern) do
          @runtime.stored_settings[NAME] = STOCK.dup if stock
          raise Aborted
        end
        assert_raises(Aborted) { run_merge }
        run_id = last_run_id
        assert_equal 'running', @service.store.load.dig('runs', run_id, 'status')
        assert_equal execution, binding_for(run_id)['execution'], label
        assert_equal [], helper_calls('restore')
        @hooks.clear
        from = issued.size
        recovered = @service.recover(run_id: run_id)
        assert_equal 'interrupted', recovered[:status]
        assert_equal 'STANDARD_INTERRUPTED', recovered.dig(:failure, 'code')
        assert_equal 2, positions(OWNERSHIP, from: from).size
        assert_equal 1, positions(INSTALL, from: from).size
        restore = helper_calls('restore', from: from)
        assert_equal 1, restore.size
        assert_match UNCERTAIN, issued[restore.first], label
        assert_match digest_env(run_id), issued[restore.first], label
        assert_equal [], helper_calls('capture', from: from)
        assert_equal [], positions(QUERY, from: from), label
        assert_equal stock ? SITE.merge(NAME => STOCK) : SITE, @runtime.stored_settings, label
        assert_equal expected_report('recovery', 'unproven', failed: stock ? [NAME] : [], uncertain: true), report(run_id, 'recovery'), label
        assert_nil report(run_id, 'failure')
        assert_equal 'unproven', recovered.dig(:results, 'merge', 'site_settings_preservation')
        assert_equal stock ? 1 : 0, recovered.dig(:results, 'merge', 'site_settings_changed'), label
        assert_public_projection_clean(run_id)
      end
    end
    # Another setting is named too, and equally left alone.
    with_settings do
      before_command(CONSTRUCTOR) do
        @runtime.stored_settings[EXTRA] = ['on', 5]
        raise Aborted
      end
      assert_raises(Aborted) { run_merge }
      @service.recover(run_id: last_run_id)
      assert_equal expected_report('recovery', 'unproven', unexpected: [EXTRA], uncertain: true), report(last_run_id, 'recovery')
      assert_equal ['on', 5], @runtime.stored_settings[EXTRA]
    end
  end

  # No snapshot was bound, so no merger was constructed under this contract: nothing is touched.
  def test_settings_cleanup_without_a_snapshot_touches_nothing
    with_settings do
      before_command(/CREATE DATABASE merge_source/) { raise Aborted }
      assert_raises(Aborted) { run_merge }
      from = issued.size
      recovered = @service.recover(run_id: last_run_id)
      assert_equal 'interrupted', recovered[:status]
      assert_nil binding_for(last_run_id)
      assert_equal [], settings_commands(0)
      assert_equal [], positions(OWNERSHIP, from: from)
      assert_equal [], Dir.glob(private_path(last_run_id, 'merge-site-settings*'))
      assert_nil recovered.dig(:results, 'merge', 'site_settings_preservation')
    end
    with_settings do
      @runtime.target_state = @runtime.target_state.merge('migrations' => %w[20261104011110 20261109000000])
      run = run_merge
      assert_equal 'STANDARD_MERGE_INCOMPATIBLE', run.dig(:failure, 'code')
      assert_equal [], settings_commands(0)
      assert_equal [], positions(OWNERSHIP)
      assert_equal [], Dir.glob(private_path(run[:run_id], 'merge-site-settings*'))
    end
  end

  # -- whose containers --------------------------------------------------------------------

  def unowned_identities
    good = ->(id) { @runtime.owned_container(id).stdout.split("\n", 3) }
    answer = ->(id, name, labels) { ok_result("#{id}\n#{name}\n#{labels}\n") }
    relabel = ->(labels, change) { JSON.generate(JSON.parse(labels).merge(change)) }
    {
      'gone' => ->(_id) { failed_result(1, stderr: 'Error: No such object') },
      'docker unreachable' => ->(_id) { failed_result(nil, stderr: 'timed out') },
      'no answer' => ->(_id) { ok_result('') },
      'another container under the recorded name' => ->(id) { answer.call('f' * 64, *good.call(id).drop(1)) },
      'a short ID' => ->(id) { answer.call(id[0, 12], *good.call(id).drop(1)) },
      'another name' => ->(id) { answer.call(id, '/silomig-00000000-review-db', good.call(id)[2]) },
      'the other role' => ->(id) { answer.call(id, good.call(id)[1].sub(/-(db|web)\z/) { $1 == 'db' ? '-web' : '-db' }, good.call(id)[2]) },
      'not managed' => ->(id) { answer.call(id, good.call(id)[1], relabel.call(good.call(id)[2], 'silo-migrate.managed' => 'false')) },
      'no managed label' => ->(id) { answer.call(id, good.call(id)[1], JSON.generate(JSON.parse(good.call(id)[2]).except('silo-migrate.managed'))) },
      'another instance' => ->(id) { answer.call(id, good.call(id)[1], relabel.call(good.call(id)[2], 'silo-migrate.instance' => 'silomig-00000000-review')) },
      'labels not JSON' => ->(id) { answer.call(id, good.call(id)[1], 'map[]') },
      'only the database is the run\'s' => ->(id) { good.call(id)[1].end_with?('-db') ? @runtime.owned_container(id) : failed_result(1, stderr: 'Error: No such object') },
      'only the site is the run\'s' => ->(id) { good.call(id)[1].end_with?('-web') ? @runtime.owned_container(id) : failed_result(1, stderr: 'Error: No such object') }
    }
  end

  # The recorded containers can't be shown to be this run's: no snapshot is copied into them
  # and no helper runs in them. The failure is recorded as unproven, not skipped.
  def test_settings_failure_cleanup_runs_no_helper_in_unowned_containers
    unowned_identities.each do |label, identity|
      with_settings do
        before_command(CONSTRUCTOR) do
          @runtime.stored_settings[NAME] = STOCK.dup
          @runtime.container_identity = identity
          @runtime.merger_result = failed_result(1, stderr: 'RuntimeError')
        end
        run = run_merge
        constructor = position(CONSTRUCTOR)
        assert_equal 'STANDARD_MERGE_FAILED', run.dig(:failure, 'code'), label
        refute_empty positions(OWNERSHIP, from: constructor), label
        assert_equal [], settings_commands(constructor + 1), label
        assert_equal [], helper_calls('restore'), label
        assert_equal [], issued.drop(constructor + 1).select { |line| line.start_with?('docker exec', 'docker cp') && line.match?(/-review-(web|db)\b/) }, label
        assert_equal STOCK, @runtime.stored_settings[NAME], label
        assert_equal unproven('failure'), report(run[:run_id], 'failure'), label
        assert_equal 'unproven', run.dig(:results, 'merge', 'site_settings_preservation'), label
        assert_nil run.dig(:results, 'merge', 'site_settings_changed'), label
        assert_public_projection_clean(run[:run_id])
      end
    end
  end

  def test_settings_recovery_runs_no_helper_in_unowned_containers
    unowned_identities.each do |label, identity|
      with_settings do
        before_command(CONSTRUCTOR) do
          @runtime.stored_settings[NAME] = STOCK.dup
          raise Aborted
        end
        assert_raises(Aborted) { run_merge }
        @hooks.clear
        @runtime.container_identity = identity
        from = issued.size
        recovered = @service.recover(run_id: last_run_id)
        assert_equal 'interrupted', recovered[:status], label
        refute_empty positions(OWNERSHIP, from: from), label
        assert_equal [], settings_commands(from), label
        assert_equal STOCK, @runtime.stored_settings[NAME], label
        assert_equal unproven('recovery'), report(last_run_id, 'recovery'), label
        assert_equal 'unproven', recovered.dig(:results, 'merge', 'site_settings_preservation'), label
      end
    end
  end

  # -- a snapshot that is no longer the bound one --------------------------------------------

  def snapshot_tampering
    rewrite = lambda do |run_id, bytes, rebind: true|
      path = private_path(run_id, 'merge-site-settings.json')
      File.chmod(0600, path)
      File.binwrite(path, bytes)
      @service.store.update { |state| state['runs'][run_id]['merge_site_settings']['sha256'] = Digest::SHA256.hexdigest(bytes) } if rebind
    end
    edit = ->(run_id) { JSON.parse(File.read(private_path(run_id, 'merge-site-settings.json'))) }
    rebind = ->(run_id, value) { @service.store.update { |state| state['runs'][run_id]['merge_site_settings'] = value } }
    {
      'bytes changed' => ->(id) { rewrite.call(id, File.binread(private_path(id, 'merge-site-settings.json')).sub(PRIVATE, PRIVATE.downcase), rebind: false) },
      'a value replaced by the stock one' => ->(id) { rewrite.call(id, JSON.generate(edit.call(id).tap { |s| s['settings'][NAME] = STOCK.dup }) + "\n", rebind: false) },
      'removed' => ->(id) { FileUtils.rm_f(private_path(id, 'merge-site-settings.json')) },
      'a link to the same bytes' => lambda do |id|
        path = private_path(id, 'merge-site-settings.json')
        FileUtils.mv(path, path + '.moved')
        File.symlink(path + '.moved', path)
      end,
      'a directory' => ->(id) { FileUtils.rm_f(private_path(id, 'merge-site-settings.json')); FileUtils.mkdir_p(private_path(id, 'merge-site-settings.json')) },
      'another digest' => ->(id) { rebind.call(id, binding_for(id).merge('sha256' => 'e' * 64)) },
      'an upper-case digest' => ->(id) { rebind.call(id, binding_for(id).merge('sha256' => binding_for(id)['sha256'].upcase)) },
      'no digest' => ->(id) { rebind.call(id, binding_for(id).except('sha256')) },
      'a binding that is not a record' => ->(id) { rebind.call(id, true) },
      # File and binding agree, but the content is not a snapshot the host could have written.
      'not JSON' => ->(id) { rewrite.call(id, 'not json') },
      'not an object' => ->(id) { rewrite.call(id, "[]\n") },
      'another version' => ->(id) { rewrite.call(id, JSON.generate(edit.call(id).merge('version' => 2)) + "\n") },
      'no settings' => ->(id) { rewrite.call(id, JSON.generate(edit.call(id).except('settings')) + "\n") },
      'a row that is not a pair' => ->(id) { rewrite.call(id, JSON.generate(edit.call(id).tap { |s| s['settings']['title'] = 'x' }) + "\n") },
      'no effective value' => ->(id) { rewrite.call(id, JSON.generate(edit.call(id).except('authorized_extensions_effective')) + "\n") },
      'too large' => ->(id) { rewrite.call(id, JSON.generate(edit.call(id).merge('pad' => 'x' * SETTINGS::MERGE_SITE_SETTINGS_BYTES)) + "\n") }
    }
  end

  # Changed while the merger ran: nothing later is compared against it, and it is never
  # installed or used to "restore".
  def test_settings_tampered_snapshot_refuses_check_and_restore
    snapshot_tampering.each do |label, tamper|
      with_settings do
        before_command(CONSTRUCTOR) do
          @runtime.stored_settings[NAME] = STOCK.dup
          tamper.call(last_run_id)
        end
        run = run_merge
        constructor = position(CONSTRUCTOR)
        if label == 'a binding that is not a record'
          # The run record itself was rewritten: the run still stops here, as an internal failure.
          assert_equal ['failed', 'merge'], [run[:status], run.dig(:failure, 'stage')], label
          assert_includes [CODE, 'STANDARD_INTERNAL'], run.dig(:failure, 'code'), label
        else
          assert_settings_failure(run, 'merge', label)
        end
        assert_equal 'pending', run.dig(:stages, 'finalize'), label
        refute_equal 'verified', report(run[:run_id], 'after-merge')&.fetch('state'), label
        assert_equal [], positions(INSTALL, from: constructor), label
        assert_equal [], helper_calls('restore'), label
        assert_equal [], positions(FINALIZE), label
        assert_equal STOCK, @runtime.stored_settings[NAME], label
        assert_equal unproven('failure'), report(run[:run_id], 'failure'), label
        assert_equal 'unproven', run.dig(:results, 'merge', 'site_settings_preservation'), label
        assert_public_projection_clean(run[:run_id])
      end
    end
  end

  # Changed at any later boundary: that boundary refuses, whatever the database holds.
  def test_settings_tampered_snapshot_refuses_every_later_boundary
    tamper = snapshot_tampering.fetch('a value replaced by the stock one')
    relabelled = lambda do |run_id|
      # A consistent rewrite of file and binding to the stock value, with the database changed to match.
      snapshot = snapshot_for(run_id).tap { |s| s['settings'][NAME] = STOCK.dup }
      bytes = JSON.generate(snapshot.merge('authorized_extensions_effective' => STOCK.first)) + "\n"
      File.chmod(0600, private_path(run_id, 'merge-site-settings.json'))
      File.binwrite(private_path(run_id, 'merge-site-settings.json'), bytes)
      @service.store.update { |state| state['runs'][run_id]['merge_site_settings']['sha256'] = Digest::SHA256.hexdigest(bytes) }
    end
    boundary_cases.drop(1).each do |phase, stage, (pattern, options)|
      with_settings do
        before_command(pattern, **options) { tamper.call(last_run_id) }
        run = run_merge
        assert_settings_failure(run, stage, phase)
        refute_equal 'verified', report(run[:run_id], phase)&.fetch('state'), phase
        assert_equal [], helper_calls('restore'), phase
        assert_equal unproven('failure'), report(run[:run_id], 'failure'), phase
        assert_nil run.dig(:artifacts, 'backup'), phase unless phase == 'completion'
      end
    end
    # The verify stage still holds the state recorded before the merge: a snapshot rewritten
    # (with its binding) to agree with a changed database doesn't get a backup made.
    with_settings do
      before_command(CONSTRUCTOR) do
        @runtime.stored_settings[NAME] = STOCK.dup
        relabelled.call(last_run_id)
      end
      run = run_merge
      assert_equal 'failed', run[:status]
      assert_equal 'verify', run.dig(:failure, 'stage')
      assert_equal [], positions(%r{script/discourse backup })
      assert_nil run.dig(:artifacts, 'backup')
    end
  end

  # -- what leaves the private directory ------------------------------------------------------

  def test_settings_values_never_reach_projections_logs_or_command_lines
    with_settings do
      run = run_merge(settings: @merge_settings)
      assert_equal 'completed', run[:status], run[:failure].inspect
      run_id = run[:run_id]
      assert_public_projection_clean(run_id)
      assert_values_stay_private(run_id)
      refute_includes JSON.generate(run), PRIVATE
      refute_includes JSON.generate(@service.merge_evidence(run_id)), PRIVATE
      # The whole record holds a digest and a phase, never the snapshot.
      record = @service.store.load.fetch('runs').fetch(run_id)
      refute_includes JSON.generate(record), PRIVATE
      assert_equal %w[execution sha256 version], record.fetch('merge_site_settings').keys.sort
      assert_equal({ 'site_settings_preservation' => 'verified', 'site_settings_changed' => 0 }, record.dig('results', 'merge').slice('site_settings_preservation', 'site_settings_changed'))
      # Outside the private snapshot, only the state helper's own evidence and log hold values (as before).
      holding = Dir.glob(File.join(@service.store.run_dir(run_id), '**', '*')).select { |path| File.file?(path) && File.binread(path).force_encoding('UTF-8').include?(PRIVATE) }
      names = holding.map { |path| path.delete_prefix(@service.store.run_dir(run_id) + '/') }
      assert_includes names, 'private/merge-site-settings.json'
      assert_equal [], names - %w[private/merge-site-settings.json evidence/merge-before.json logs/merge-state.log]
      # The helper's and the query's answers are never written to a log of their own.
      assert_equal [], Dir.glob(@service.store.run_dir(run_id, 'logs', '*')).map { |path| File.basename(path) }.grep(/setting/)
    end
  end
end

# A prepared merge runs the same merge stage on an environment a Prepare run built earlier.
class StandardMergeSiteSettingsPreparedTest < StandardMergePreparationTest
  include MergeSiteSettingsHostChecks

  def self.runnable_methods
    public_instance_methods.grep(/^test_prepared_settings_/).map(&:to_s)
  end

  def with_prepared_settings(settings = SITE)
    with_prepare do
      prepare_settings(settings)
      yield
    end
  end

  # A Prepare completed by code that knew nothing of this contract stays usable as it is: its
  # plan, digest and generation are not rewritten, and the merge that consumes it is protected.
  def test_prepared_settings_existing_completed_prepare_is_merged_without_being_rewritten
    with_prepared_settings do
      prep = prepared
      prepared_id = prep[:run_id]
      generation = prep.dig(:merge_environment, 'generation')
      assert_match(/\A[0-9a-f]{64}\z/, generation)
      # Preparing constructs no merger, so it captures and binds nothing.
      assert_equal [], settings_commands(0)
      assert_equal 2, positions(HELPER_INSTALL).size
      assert_nil binding_for(prepared_id)
      plan_before = JSON.generate(@service.store.load.dig('plans', prep[:plan_id]))
      record_before = JSON.generate(record(prepared_id).slice('generation', 'seals', 'sealed_at', 'base_inspection_database_oid'))
      environment_before = JSON.generate(record(prepared_id))
      refute_includes plan_before, 'site_settings_preservation'
      # As an older checkout left it: other code, and a helper set without the settings helper.
      FileUtils.rm_f(@service.store.run_dir(prepared_id, 'work', 'helpers', 'merge_site_settings.rb'))
      File.write(File.join(@code_root, 'lib', 'identity.rb'), '# the code that prepared this is not the code that merges it')
      refute_equal @service.store.load.dig('plans', prep[:plan_id], 'body', 'code_identity'), @service.send(:code_identity)
      assert_equal 'ready', environment(prepared_id)['phase']
      assert_equal generation, environment(prepared_id)['generation']

      from = issued.size
      plan = prepared_plan(prep)
      assert_equal SETTINGS::MERGE_SITE_SETTINGS_POLICY, plan.dig(:merge, 'site_settings_preservation')
      assert_equal({ 'run_id' => prepared_id, 'generation' => generation }, plan[:prepared_from])
      # Proposing and approving against it rewrote nothing of it, and ran nothing in its stack.
      approved = approve(plan)
      assert_equal plan_before, JSON.generate(@service.store.load.dig('plans', prep[:plan_id]))
      assert_equal environment_before, JSON.generate(record(prepared_id))
      assert_equal [], docker_commands(from).grep(/ (exec|cp) /)
      assert_equal 'ready', environment(prepared_id)['phase']
      run = @service.run_plan(plan_id: approved)
      assert_equal 'completed', run[:status], failure_detail(run)

      # Captured on the activated environment, with this run's helpers, before the constructor.
      capture = helper_calls('capture', from: from)
      assert_equal 1, capture.size
      helper = position(%r{\Adocker cp \S+/#{run[:run_id]}/work/helpers/merge_site_settings\.rb \S+:/tmp/merge_site_settings\.rb\z}, from: from)
      constructor = position(CONSTRUCTOR, from: from)
      assert_operator helper, :<, capture.first
      assert_operator capture.first, :<, constructor
      assert_equal 5, positions(QUERY, from: from).size
      assert_equal SITE, snapshot_for(run[:run_id])['settings']
      PHASES.each { |phase| assert_equal expected_report(phase, 'verified'), report(run[:run_id], phase), phase }
      assert_equal 'verified', run.dig(:results, 'merge', 'site_settings_preservation')
      assert_equal 'finished', binding_for(run[:run_id])['execution']

      # The preparation is consumed, not rewritten: same plan and digest, same generation.
      assert_equal plan_before, JSON.generate(@service.store.load.dig('plans', prep[:plan_id]))
      assert_equal record_before, JSON.generate(record(prepared_id).slice('generation', 'seals', 'sealed_at', 'base_inspection_database_oid'))
      assert_equal generation, record(prepared_id)['generation']
      assert_equal generation, run.dig(:merge_environment, 'generation')
      assert_equal generation, run.dig(:artifacts, 'backup') && @service.store.load.dig('runs', run[:run_id], 'artifacts', 'backup', 'merge_generation')
      assert_equal 'result', environment(prepared_id)['phase']
      assert_nil binding_for(prepared_id)
      assert_equal [], Dir.glob(private_path(prepared_id, 'merge-site-settings*'))
      assert_public_projection_clean(run[:run_id])
      assert_public_projection_clean(prepared_id)
      assert_values_stay_private(run[:run_id])
    end
  end

  # An approval of a prepared merge given before this contract existed is refused while the
  # environment is still untouched: not claimed, not activated, and ready for a plan proposed now.
  def test_prepared_settings_approval_without_the_policy_does_not_consume_the_environment
    WEAKENINGS.each do |label, weaken|
      with_prepared_settings do
        prep = prepared
        generation = prep.dig(:merge_environment, 'generation')
        approved = approve(prepared_plan(prep))
        historical_plan(approved, weaken)
        environment_before = JSON.generate(record(prep[:run_id]))
        preparation_before = JSON.generate(@service.store.load.dig('plans', prep[:plan_id]))
        runs = @service.store.load.fetch('runs').keys
        from = issued.size
        @inspection.clear

        assert_equal 'stale', @service.show_plan(approved)[:status], label
        standard_error('STANDARD_STALE_PLAN') { @service.run_plan(plan_id: approved) }
        # No run, so nothing claimed the generation; nothing was fenced, renamed or dropped.
        assert_equal runs, @service.store.load.fetch('runs').keys, label
        assert_equal 'approved', @service.store.load.dig('plans', approved, 'status'), label
        assert_equal environment_before, JSON.generate(record(prep[:run_id])), label
        assert_equal 'ready', environment(prep[:run_id])['phase'], label
        assert_nil record(prep[:run_id])['consumed_by'], label
        assert_equal generation, record(prep[:run_id])['generation'], label
        assert_equal preparation_before, JSON.generate(@service.store.load.dig('plans', prep[:plan_id])), label
        assert_equal 'prepared', instance_state, label
        assert_equal SEALED, @runtime.databases, label
        assert_equal [], @inspection, label
        assert_equal [], docker_commands(from), label
        assert_equal SITE, @runtime.stored_settings, label

        # The same generation serves a plan this code proposes.
        run = @service.run_plan(plan_id: approve(prepared_plan(prep)))
        assert_equal 'completed', run[:status], failure_detail(run)
        assert_equal generation, run.dig(:merge_environment, 'generation'), label
        assert_equal 'verified', run.dig(:results, 'merge', 'site_settings_preservation'), label
      end
    end
  end

  # Restored or not, a prepared merge that failed on settings leaves its generation dirty:
  # the cleanup's answer never makes it ready again.
  def test_prepared_settings_failure_never_returns_the_generation_to_ready
    [[-> { @runtime.stored_settings[NAME] = STOCK.dup }, 'restored'], [-> { @runtime.stored_settings[EXTRA] = ['on', 5] }, 'unproven']].each do |change, cleanup|
      with_prepared_settings do
        prep = prepared
        generation = prep.dig(:merge_environment, 'generation')
        plan = prepared_plan(prep)
        before_command(CONSTRUCTOR, &change)
        run = @service.run_plan(plan_id: approve(plan))
        assert_settings_failure(run, 'merge')
        assert_equal cleanup, report(run[:run_id], 'failure')['state']
        assert_equal cleanup, run.dig(:results, 'merge', 'site_settings_preservation')
        assert_nil run.dig(:artifacts, 'backup')
        assert_equal 'dirty', run.dig(:merge_environment, 'phase')
        assert_equal 'dirty', environment(prep[:run_id])['phase']
        assert_equal generation, record(prep[:run_id])['generation']
        assert_equal 'dirty', instance_state
        refute(@inspection.any? { |call| call[:phase] == 'result' })
        standard_error('STANDARD_MERGE_ENVIRONMENT_STALE') { prepared_plan(prep) }
        assert_nil binding_for(prep[:run_id])
        assert_public_projection_clean(run[:run_id])
      end
    end
  end

  # The settings helper only ever runs in the stack of the run that bound the snapshot.
  def test_prepared_settings_interrupted_merge_is_recovered_as_unproven
    with_prepared_settings do
      prep = prepared
      plan = prepared_plan(prep)
      before_command(CONSTRUCTOR) do
        @runtime.stored_settings[NAME] = STOCK.dup
        raise Aborted
      end
      assert_raises(Aborted) { @service.run_plan(plan_id: approve(plan)) }
      run_id = last_run_id
      @hooks.clear
      from = issued.size
      recovered = @service.recover(run_id: run_id)
      assert_equal 'interrupted', recovered[:status]
      restore = helper_calls('restore', from: from)
      assert_equal 1, restore.size
      assert_match UNCERTAIN, issued[restore.first]
      # Read, named and left: the interrupted merger may still be running in that stack.
      assert_equal expected_report('recovery', 'unproven', failed: [NAME], uncertain: true), report(run_id, 'recovery')
      assert_equal SITE.merge(NAME => STOCK), @runtime.stored_settings
      assert_equal 'dirty', environment(prep[:run_id])['phase']
      assert_equal prep.dig(:merge_environment, 'generation'), record(prep[:run_id])['generation']
      standard_error('STANDARD_MERGE_ENVIRONMENT_STALE') { prepared_plan(prep) }
      # Recovering the preparation's own run afterwards has no snapshot and runs no helper.
      assert_nil binding_for(prep[:run_id])
      assert_equal [], Dir.glob(private_path(prep[:run_id], 'merge-site-settings*'))
    end
  end
end
