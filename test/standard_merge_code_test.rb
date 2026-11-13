# frozen_string_literal: true
require_relative 'standard_merge_preparation_test'

# The standalone local merger store (no remote), its binding into prepared custom merges, the
# compatibility of a completed Prepare recorded in the earlier (ce4bf9f) format, and the
# inspection fence after a failed or interrupted run. Invented values only.
class StandardMergeCodeTest < StandardMergePreparationTest
  def self.runnable_methods
    public_instance_methods.grep(/^test_merger/).map(&:to_s)
  end

  def fresh_store
    FileUtils.rm_rf(merger_dir)
    @service.merger_init
  end

  def merger_error(code, &block)
    error = assert_raises(SiloMigrate::StandardWorkflowError, &block)
    assert_equal code, error.code
    error
  end

  def merger_commands
    @runtime.commands.map { |command| Array(command).join(' ') }.select { |line| line.include?("-C #{merger_dir}") }
  end

  # -- store, status and manifest ----------------------------------------------------------

  def test_merger_init_status_and_manifest
    with_prepare do
      status = @service.merger_status
      assert_equal({ version: 1, path: File.join(@service.store.workspace_root, 'merger'), initialized: false, commit: nil, branch: nil, dirty: nil,
                     layer: nil, layer_error: nil }, status)
      refute File.exist?(merger_dir)
      status = @service.merger_init
      assert_equal true, status[:initialized]
      assert_nil status[:commit]
      assert_equal 'STANDARD_MERGE_INTENT_MISMATCH', status[:layer_error]
      assert_equal '', git('remote')
      assert_empty Dir.glob(File.join(merger_dir, '.git', 'hooks', '*'))
      commit = use_layer
      status = @service.merger_status
      assert_equal [commit, 'main', false], status.values_at(:commit, :branch, :dirty)
      layer = status[:layer]
      assert_equal({ 'present' => true, 'store' => 'merger', 'path' => 'merger.rb', 'revision' => commit, 'files' => 2 }, layer.slice('present', 'store', 'path', 'revision', 'files'))
      assert_match(/\A[0-9a-f]{64}\z/, layer['sha256'])
      # Every service Git call is hardened: no hooks, protocols, replace objects or outside config.
      line = merger_commands.last
      %w[GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 core.hooksPath=/dev/null protocol.allow=never --no-replace-objects].each do |flag|
        assert_includes line, flag
      end
      # Tests and README are reviewed, never executed: they don't change the executable manifest.
      commit_merger('README.md' => "Changed notes.\n", 'test/merger_test.rb' => "# changed invented test\n", 'test/run.sh' => "#!/bin/sh\n")
      assert_equal layer['sha256'], @service.merger_status[:layer]['sha256']
      commit_merger('helpers/routes.rb' => "module InventedRoutes; ROUTE = 1; end\n")
      refute_equal layer['sha256'], @service.merger_status[:layer]['sha256']
      File.write(File.join(merger_dir, 'merger.rb'), "# uncommitted\n")
      assert_equal true, @service.merger_status[:dirty]
      # Idempotent: an existing store is gated and reported, never re-created.
      assert_equal true, @service.merger_init[:dirty]
      # A non-empty directory that is not a store is not adopted.
      FileUtils.rm_rf(merger_dir)
      FileUtils.mkdir_p(merger_dir)
      File.write(File.join(merger_dir, 'notes.txt'), "invented\n")
      merger_error('STANDARD_MERGER_CONFIG') { @service.merger_init }
    end
  end

  def test_merger_init_serializes_and_git_ignores_inherited_overrides
    with_prepare do
      blocked = ->(**_options, &_block) { raise SiloMigrate::StandardWorkflowError, 'STANDARD_BUSY' }
      @service.store.stub(:with_op_lock, blocked) do
        merger_error('STANDARD_BUSY') { @service.merger_init }
      end
      refute File.exist?(merger_dir)
      @service.merger_init
      commit = use_layer
      expected = @service.merger_status[:layer]
      overrides = { 'GIT_NAMESPACE' => 'not-the-project', 'GIT_SHALLOW_FILE' => '/nonexistent/invented-shallow',
                    'GIT_CONFIG_COUNT' => '1', 'GIT_CONFIG_KEY_0' => 'core.bare', 'GIT_CONFIG_VALUE_0' => 'true' }
      saved = overrides.to_h { |key, _| [key, ENV[key]] }
      begin
        overrides.each { |key, value| ENV[key] = value }
        assert_equal commit, @service.merger_status[:commit]
        assert_equal expected, @service.merger_status[:layer]
        line = merger_commands.last
        overrides.each_key { |key| assert_includes line, "-u #{key}" }
      ensure
        saved.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
      end
    end
  end

  def test_merger_one_shot_cannot_silently_ignore_the_local_store
    with_prepare do
      @service.merger_init
      use_layer
      before = @service.store.load
      merger_error('STANDARD_MERGE_PREPARATION_REQUIRED') do
        @service.propose_merge_plan(source: @merge_source, base_site: @base)
      end
      assert_equal before, @service.store.load
    end
  end

  def test_merger_init_ignores_inherited_hash_format
    with_prepare do
      saved = ENV['GIT_DEFAULT_HASH']
      begin
        ENV['GIT_DEFAULT_HASH'] = 'sha256'
        assert @service.merger_init[:initialized]
        assert_equal "0", git('config', '--get', 'core.repositoryformatversion').strip
        refute File.read(File.join(merger_dir, '.git', 'config')).include?('[extensions]')
      ensure
        saved ? ENV['GIT_DEFAULT_HASH'] = saved : ENV.delete('GIT_DEFAULT_HASH')
      end
    end
  end

  def test_merger_refuses_unsafe_store
    cases = {
      'remote' => -> { git('remote', 'add', 'origin', 'https://example.invalid/merger.git') },
      'include' => -> { git('config', 'include.path', '/tmp/invented.config') },
      'url rewrite' => -> { git('config', 'url.https://example.invalid/.insteadOf', 'https://') },
      'filter' => -> { git('config', 'filter.x.clean', 'touch /tmp/pwned') },
      'hooks path' => -> { git('config', 'core.hooksPath', '/tmp/hooks') },
      'fsmonitor' => -> { git('config', 'core.fsmonitor', '/tmp/monitor') },
      'alias' => -> { git('config', 'alias.st', '!touch /tmp/pwned') },
      'credential helper' => -> { git('config', 'credential.helper', '!touch /tmp/pwned') },
      'format version' => -> { git('config', 'core.repositoryformatversion', '1') },
      'alternates' => -> { File.write(File.join(merger_dir, '.git/objects/info/alternates'), "/tmp/elsewhere\n") },
      'grafts' => -> { FileUtils.mkdir_p(File.join(merger_dir, '.git/info')); File.write(File.join(merger_dir, '.git/info/grafts'), '') },
      'shallow' => -> { File.write(File.join(merger_dir, '.git/shallow'), '') },
      'gitmodules' => -> { File.write(File.join(merger_dir, '.gitmodules'), '') },
      'group-writable config' => -> { File.chmod(0o664, File.join(merger_dir, '.git/config')) },
      'group-writable store' => -> { File.chmod(0o775, merger_dir) },
      'symlinked objects' => lambda {
        objects = File.join(merger_dir, '.git/objects')
        FileUtils.mv(objects, File.join(@root, 'moved-objects'))
        File.symlink(File.join(@root, 'moved-objects'), objects)
      },
      'gitdir file' => lambda {
        FileUtils.mv(File.join(merger_dir, '.git'), File.join(@root, 'elsewhere.git'))
        File.write(File.join(merger_dir, '.git'), "gitdir: #{File.join(@root, 'elsewhere.git')}\n")
      },
      'symlinked store' => lambda {
        FileUtils.mv(merger_dir, File.join(@root, 'elsewhere-store'))
        File.symlink(File.join(@root, 'elsewhere-store'), merger_dir)
      }
    }
    with_prepare do
      cases.each do |name, change|
        fresh_store
        use_layer
        change.call
        before = merger_commands.size
        error = assert_raises(SiloMigrate::StandardWorkflowError, name) { @service.merger_status }
        assert_equal 'STANDARD_MERGER_CONFIG', error.code, name
        # Config is listed before any other Git command on the store could act on it.
        merger_commands.drop(before).each { |line| assert_match(/config --list|rev-parse --git-dir/, line, name) }
        FileUtils.rm_rf(merger_dir)
        FileUtils.rm_rf(Dir.glob(File.join(@root, '{moved-objects,elsewhere.git,elsewhere-store}')))
      end
    end
  end

  def test_merger_layer_limits
    layer = "class InventedMerger < BulkImport::DiscourseMerger; end\n"
    bad = {
      'missing entry' => { 'helpers/routes.rb' => "module A; end\n" },
      'unknown top level' => { 'merger.rb' => layer, 'lib/extra.rb' => "module A; end\n" },
      'second root ruby file' => { 'merger.rb' => layer, 'other.rb' => "module A; end\n" },
      'non-ruby helper' => { 'merger.rb' => layer, 'helpers/data.yml' => "a: 1\n" },
      'hidden helper' => { 'merger.rb' => layer, 'helpers/.hidden.rb' => "module A; end\n" },
      'too many files' => { 'merger.rb' => layer }.merge((1..32).to_h { |n| ["helpers/h#{n}.rb", "module H#{n}; end\n"] }),
      'too many bytes' => { 'merger.rb' => layer, 'helpers/big.rb' => '#' * (512 * 1024) }
    }
    with_prepare do
      bad.each do |name, files|
        fresh_store
        commit_merger(files)
        status = @service.merger_status
        assert_nil status[:layer], name
        assert_equal 'STANDARD_MERGE_LAYER_INVALID', status[:layer_error], name
      end
      # A link anywhere (even among tests) and an executable layer file are refused.
      fresh_store
      commit_merger('merger.rb' => layer)
      FileUtils.mkdir_p(File.join(merger_dir, 'test'))
      File.symlink('/etc/passwd', File.join(merger_dir, 'test', 'link.rb'))
      commit_merger({})
      merger_error('STANDARD_MERGER_CONFIG') { @service.merger_status }
      # A link removed from the index but still in the committed tree is refused by the layer.
      git('rm', '-q', '--cached', 'test/link.rb')
      FileUtils.rm_f(File.join(merger_dir, 'test', 'link.rb'))
      assert_equal 'STANDARD_MERGE_LAYER_INVALID', @service.merger_status[:layer_error]
      fresh_store
      commit_merger('merger.rb' => layer)
      File.chmod(0o755, File.join(merger_dir, 'merger.rb'))
      commit_merger({})
      assert_equal 'STANDARD_MERGE_LAYER_INVALID', @service.merger_status[:layer_error]
      # A gitlink in the index is refused by the gate itself.
      fresh_store
      commit = commit_merger('merger.rb' => layer)
      git('update-index', '--add', '--cacheinfo', "160000,#{commit},helpers/sub")
      merger_error('STANDARD_MERGER_CONFIG') { @service.merger_status }
      # At the limits, nested helpers and executable test scripts are accepted.
      fresh_store
      commit_merger({ 'merger.rb' => layer, 'helpers/a/b.rb' => "module B; end\n", 'test/run.sh' => "#!/bin/sh\n" }
                    .merge((1..30).to_h { |n| ["helpers/h#{n}.rb", "module H#{n}; end\n"] }))
      File.chmod(0o755, File.join(merger_dir, 'test/run.sh'))
      commit_merger({})
      assert_equal 32, @service.merger_status[:layer]['files']
    end
  end

  # -- plan binding, retention, extraction and tamper --------------------------------------

  def test_merger_plan_binds_commit_retains_it_and_extracts_committed_bytes
    with_prepare do
      prep = prepared
      first = use_layer
      File.write(File.join(merger_dir, 'helpers/untracked.rb'), "module Untracked; end\n")
      merger_error('STANDARD_MERGER_DIRTY') { prepared_plan(prep, intent: 'custom') }
      FileUtils.rm_f(File.join(merger_dir, 'helpers/untracked.rb'))
      plan = prepared_plan(prep, intent: 'custom')
      assert_equal first, plan.dig(:merge, 'layer', 'revision')
      assert_equal first, git('rev-parse', "refs/silo/merge-plans/#{plan[:plan_id]}").strip
      # Later local work, even history rewritten and pruned, doesn't touch the approved commit.
      commit_merger('merger.rb' => "# a later, unreviewed edit\n" + LAYER_SOURCE)
      git('checkout', '-q', '--orphan', 'rewrite')
      git('commit', '-q', '-m', 'rewritten')
      git('branch', '-q', '-D', 'main')
      git('reflog', 'expire', '--expire=now', '--all')
      git('gc', '-q', '--prune=now')
      assert_equal "commit\n", git('cat-file', '-t', first)
      assert_equal 'proposed', @service.show_plan(plan[:plan_id])[:status]
      File.write(File.join(merger_dir, 'merger.rb'), "# working tree is never executed\n")
      run = @service.run_plan(plan_id: approve(plan))
      assert_equal 'completed', run[:status], failure_detail(run)
      assert_equal LAYER_SOURCE, File.read(@service.store.run_dir(run[:run_id], 'private', 'merge', 'layer', 'merger.rb'))
      refute File.exist?(@service.store.run_dir(run[:run_id], 'private', 'merge', 'layer', 'README.md'))
      refute_match(/#{Regexp.escape(@root)}/, JSON.generate(plan))
    end
  end

  def test_merger_tampered_objects_or_plan_refuse
    with_prepare do
      prep = prepared
      commit = use_layer
      plan = prepared_plan(prep, intent: 'custom')
      approved = approve(plan)
      # A loose object rewritten in place (same name, other bytes) is not the committed file.
      blob = git('rev-parse', "#{commit}:merger.rb").strip
      object = File.join(merger_dir, '.git', 'objects', blob[0, 2], blob[2..])
      File.chmod(0o644, object)
      File.binwrite(object, Zlib::Deflate.deflate("blob 5\0evil\n"))
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      merger_error('STANDARD_STALE_PLAN') { @service.run_plan(plan_id: approved) }
      assert_equal 'ready', environment(prep[:run_id])['phase']
      assert_equal SEALED, @runtime.databases
    end
    with_prepare do
      prep = prepared
      use_layer
      plan = prepared_plan(prep, intent: 'custom')
      approved = approve(plan)
      # A stored plan edited to another commit or manifest no longer matches its approval.
      @service.store.update { |state| state['plans'][plan[:plan_id]]['body']['merge']['layer']['sha256'] = '0' * 64 }
      error = assert_raises(SiloMigrate::StandardWorkflowError) { @service.run_plan(plan_id: approved) }
      refute_equal 'completed', error.code
      assert_equal 'ready', environment(prep[:run_id])['phase']
    end
  end

  # -- a completed Prepare in the earlier (ce4bf9f) format --------------------------------

  # The pre-standalone prepared custom format: a converter-held layer plus converter binding.
  def invent_legacy_custom_plan(prep)
    stock = prepared_plan(prep)
    config = @service.store.load.fetch('config')
    layer = @service.send(:merge_layer!, config.fetch('converter_worktree'), config.fetch('converter_revision'), 'synthetic').first
    @service.store.update do |state|
      plan = state['plans'][stock[:plan_id]]
      body = plan['body']
      body.merge!('intent' => 'custom', 'converter' => config['converter'], 'converter_binding' => config['converter_binding'],
                  'converter_revision' => config['converter_revision'])
      body['merge']['layer'] = layer
      plan['digest'] = Digest::SHA256.hexdigest(@service.send(:canonical_json, body))
    end
    @service.show_plan(stock[:plan_id])
  end

  def test_merger_compatibility_with_an_earlier_completed_prepare
    with_prepare do
      prep = prepared
      state = @service.store.load
      prepare_run = JSON.generate(state['runs'][prep[:run_id]])
      prepare_plan_record = JSON.generate(state['plans'][prep[:plan_id]])
      generation = prep.dig(:merge_environment, 'generation')
      # The earlier format: no layer, store or converter facts in the preparation at all.
      body = state['plans'][prep[:plan_id]]['body']
      refute body['merge'].key?('layer')
      refute body.key?('converter_revision')
      use_converter_layer
      legacy = invent_legacy_custom_plan(prep)
      use_layer
      standalone = prepared_plan(prep, intent: 'custom', settings: @merge_settings)
      stock = prepared_plan(prep)
      [legacy, standalone, stock].each { |plan| assert_equal 'proposed', @service.show_plan(plan[:plan_id])[:status] }
      assert_equal 'ready', environment(prep[:run_id])['phase']
      # An approved Merge whose Silo code identity changed cannot run; the Prepare stays ready.
      approved = approve(stock)
      identity = File.join(@code_root, 'lib', 'identity.rb')
      original = File.read(identity)
      File.write(identity, "# changed synthetic code identity\n")
      [legacy, standalone, stock].each { |plan| assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status] }
      merger_error('STANDARD_STALE_PLAN') { @service.run_plan(plan_id: approved) }
      assert_equal 'ready', environment(prep[:run_id])['phase']
      File.write(identity, original)
      # The converter binding governs the legacy plan only, never the standalone one.
      binding = @service.store.load.dig('config', 'converter_binding')
      @service.store.update { |current| current['config']['converter_binding'] = 'f' * 32 }
      assert_equal 'stale', @service.show_plan(legacy[:plan_id])[:status]
      assert_equal 'proposed', @service.show_plan(standalone[:plan_id])[:status]
      assert_equal 'approved', @service.show_plan(stock[:plan_id])[:status]
      @service.store.update { |current| current['config']['converter_binding'] = binding }
      # Settings tampering still fails closed for the standalone plan.
      input = @service.store.named_state.fetch('inputs').fetch(@merge_settings)
      path = File.join(@root, input.fetch('path').unpack1('m0'))
      saved = File.binread(path)
      File.chmod(0o600, path)
      File.write(path, "category_routes: { changed: 1 }\n")
      assert_equal 'stale', @service.show_plan(standalone[:plan_id])[:status]
      File.binwrite(path, saved)
      # Nothing about the completed Prepare was rewritten by any of this.
      state = @service.store.load
      assert_equal prepare_run, JSON.generate(state['runs'][prep[:run_id]])
      assert_equal prepare_plan_record, JSON.generate(state['plans'][prep[:plan_id]])
      # The older converter-held custom plan still runs its converter-held bytes.
      run = @service.run_plan(plan_id: approve(legacy))
      assert_equal 'completed', run[:status], failure_detail(run)
      assert_equal LAYER_SOURCE, File.read(@service.store.run_dir(run[:run_id], 'private', 'merge', 'layer', 'merger.rb'))
      refute File.exist?(@service.store.run_dir(run[:run_id], 'private', 'merge', 'layer', 'helpers'))
      assert_equal generation, record(prep[:run_id])['generation']
      assert_equal prepare_plan_record, JSON.generate(@service.store.load['plans'][prep[:plan_id]])
    end
  end

  # -- inspection fence after failure or interruption --------------------------------------

  def test_merger_failure_after_inspection_opened_fences_it
    [nil, 'STANDARD_MERGE_INSPECTION_FENCE_FAILED'].each do |close_failure|
      with_prepare do
        # Access opens, then recording it fails: the run fails and its access is closed again.
        @service.define_singleton_method(:merge_inspection_counts) { |_summary| raise 'invented state failure' }
        @inspection_failure['close'] = close_failure if close_failure
        run = run_prepare
        assert_equal 'STANDARD_INTERNAL', run.dig(:failure, 'code')
        assert_equal 'failed', run.dig(:stages, 'inspection')
        assert_equal 'dirty', environment(run[:run_id])['phase']
        assert_match(/\A[0-9a-f]{64}\z/, record(run[:run_id])['generation'])
        calls = @inspection.map { |call| call.slice(:op, :run_id, :phase).compact }
        assert_equal [{ op: 'open', run_id: run[:run_id], phase: 'base' }, { op: 'close', run_id: run[:run_id] }], calls
        # An unproven fence is reported, never a changed failure; reset retries it.
        assert_equal close_failure ? 'unproven' : 'closed', run.dig(:results, 'merge', 'inspection_fence')
        standard_error('STANDARD_MERGE_ENVIRONMENT_STALE') { prepared_plan(run) }
        @inspection_failure.delete('close')
        generation = record(run[:run_id])['generation']
        assert_equal [@instance], @service.reset_run(run_id: run[:run_id], yes: true)[:removed]
        assert_equal generation, record(run[:run_id])['generation']
      end
    end
  end

  def test_merger_recover_fences_interrupted_access
    with_prepare do
      plan = prepare_plan
      claim = @service.claim(plan_id: approve(plan))
      @service.store.update do |state|
        state['runs'][claim[:run_id]]['merge_environment'].merge!('phase' => 'inspection', 'generation' => 'e' * 64)
      end
      @service.merge_inspection_open(claim[:run_id], phase: 'base', generation: 'e' * 64)
      recovered = @service.recover(run_id: claim[:run_id])
      assert_equal 'interrupted', recovered[:status]
      assert_equal 'dirty', environment(claim[:run_id])['phase']
      assert_equal 'e' * 64, record(claim[:run_id])['generation']
      assert_equal({ op: 'close', run_id: claim[:run_id] }, @inspection.last.slice(:op, :run_id))
    end
    with_prepare do
      # A merge interrupted after it took the environment: the preparation's access goes too.
      prep = prepared
      claim = @service.claim(plan_id: approve(prepared_plan(prep)))
      @service.store.update { |state| state['runs'][prep[:run_id]]['merge_environment']['phase'] = 'merging' }
      @inspection.clear
      # The first close failing still leaves the second attempted.
      service = @service
      calls = @inspection
      service.define_singleton_method(:merge_inspection_close) do |run_id|
        calls << { op: 'close', run_id: run_id }
        raise SiloMigrate::StandardWorkflowError, 'STANDARD_MERGE_INSPECTION_FENCE_FAILED' if calls.size == 1
      end
      @service.recover(run_id: claim[:run_id])
      assert_equal 'unproven', @service.show_run(claim[:run_id]).dig(:results, 'merge', 'inspection_fence')
      assert_equal 'dirty', environment(prep[:run_id])['phase']
      assert_equal prep.dig(:merge_environment, 'generation'), record(prep[:run_id])['generation']
      assert_equal [prep[:run_id], claim[:run_id]].sort, @inspection.map { |call| call[:run_id] }.sort
      assert @inspection.all? { |call| call[:op] == 'close' }
    end
  end
end
