# frozen_string_literal: true
require_relative 'standard_merge_run_test'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# Scripted PostgreSQL catalogue for a prepared merge environment: which databases exist,
# whether they accept connections and a content fingerprint that follows renames and copies.
class PrepareScriptedRuntime < MergeScriptedRuntime
  attr_accessor :fail_sql, :sessions_left
  attr_writer :inspection_oid

  def inspection_oid = instance_variable_defined?(:@inspection_oid) ? @inspection_oid : '2001'

  def self.seal(tag)
    "#{tag * 32}|#{'b' * 32}:1|1,1,1,1,1,1,1|1,1,1,1"
  end

  def databases = (@databases ||= { 'discourse' => true })
  def content = (@content ||= { 'discourse' => self.class.seal('a'), 'merge_source' => self.class.seal('c') })
  def sql = (@sql ||= [])

  # A removed stack takes its PostgreSQL volume with it.
  def new_volume!
    @databases = @content = nil
  end

  def run(cmd, **options)
    if cmd[0, 2] == %w[docker exec] && cmd.include?('psql') && cmd.include?('-Atc') && (result = prepare_sql(cmd, cmd.last))
      commands << cmd.join(' ')
      sql << cmd.last
      return result
    end
    super
  end

  def prepare_sql(cmd, text)
    return review_fail('scripted failure') if fail_sql && text.include?(fail_sql)

    database = cmd[cmd.index('-d') + 1]
    case text
    when /silo_seal/ then databases[database] ? review_ok(content.fetch(database) + "\n") : review_fail('database is not accepting connections')
    when /pg_terminate_backend/ then review_ok("0\n")
    when /COUNT\(\*\) FROM pg_stat_activity/ then review_ok("#{sessions_left || 0}\n")
    when /pg_database_size/ then review_ok("1000,2000\n")
    when /\ASELECT oid::text FROM pg_database WHERE datname = 'discourse'\z/ then review_ok("#{inspection_oid}\n")
    when /FROM pg_database WHERE/
      # PostgreSQL boolean concatenation uses true/false, unlike a standalone
      # boolean column's t/f output. Do not let the fake hide this SQL contract.
      canonical = text.include?("CASE WHEN datallowconn THEN 't' ELSE 'f' END")
      review_ok(databases.sort.map { |name, open| "#{name}:#{canonical ? (open ? 't' : 'f') : open.to_s}\n" }.join)
    when /\ACREATE DATABASE merge_source OWNER/
      databases['merge_source'] = true
      review_ok
    when /\AALTER DATABASE (\w+) RENAME TO (\w+)\z/
      databases[$2] = databases.delete($1)
      content[$2] = content.delete($1)
      review_ok
    when /\ACREATE DATABASE (\w+) TEMPLATE (\w+) OWNER discourse\z/
      return review_fail('source database is being accessed') unless databases.key?($2)

      databases[$1] = true
      content[$1] = content.fetch($2)
      review_ok
    when /\AALTER DATABASE (\w+) ALLOW_CONNECTIONS (true|false)\z/
      databases[$1] = $2 == 'true'
      review_ok
    when /\ADROP DATABASE (\w+)\z/
      databases.delete($1)
      content.delete($1)
      review_ok
    end
  end
end

class StandardMergePreparationTest < StandardMergeRunTest
  PREPARATION = SiloMigrate::Services::StandardMergePreparation
  SEALED = { 'discourse' => true, 'merge_source' => false, 'silo_clean_base' => false, 'silo_inspect_source' => true }.freeze
  ACTIVE = { 'discourse' => true, 'merge_source' => true }.freeze

  def self.runnable_methods
    public_instance_methods.grep(/^test_prepare/).map(&:to_s)
  end

  def with_prepare(ahead: false)
    with_merge(ahead: ahead) do
      runtime = PrepareScriptedRuntime.new
      runtime.service = @service
      @runtime = runtime
      @service.instance_variable_set(:@runtime, runtime)
      stub_inspection
      yield
    end
  end

  # The inspection module is another owner's: only the seam (when, for which run and phase)
  # is under test here. Its summary carries an invented secret to prove nothing projects it.
  def stub_inspection
    calls = @inspection = []
    failing = @inspection_failure = {}
    service = @service
    service.define_singleton_method(:merge_inspection_open) do |run_id, phase:, **facts|
      backup = !store.load.dig('runs', run_id, 'artifacts', 'backup').nil?
      admin = File.exist?(store.run_dir(run_id, 'private', 'admin-password'))
      calls << { op: 'open', run_id: run_id, phase: phase, facts: facts, backup: backup, admin: admin, at: @runtime.commands.size }
      raise SiloMigrate::StandardWorkflowError, failing[phase] if failing[phase]

      { 'version' => 1, 'run_id' => run_id, 'phase' => phase, 'generation' => facts[:generation], 'state' => 'open',
        'endpoints' => phase == 'base' ? %w[site source] : %w[site], 'granted_tables' => 3, 'unreviewed_tables' => 1, 'api_key' => 'invented-private-api-key' }
    end
    service.define_singleton_method(:merge_inspection_close) do |run_id|
      calls << { op: 'close', run_id: run_id, at: @runtime.commands.size }
      raise SiloMigrate::StandardWorkflowError, failing['close'] if failing['close']

      { 'version' => 1, 'run_id' => run_id, 'state' => 'closed', 'endpoints' => [] }
    end
  end

  def prepare_plan(**opts)
    @service.propose_merge_preparation_plan(source: @merge_source, base_site: @base, **opts)
  end

  def run_prepare(plan = prepare_plan)
    @instance = plan.dig(:instances, 'review', 'name')
    @runtime.ownership = @instance
    @runtime.live_result = %w[db redis web proxy].map { |_role| "true #{@instance}" }.join("\n") + "\n"
    @service.run_plan(plan_id: approve(plan))
  end

  def prepared
    run = run_prepare
    assert_equal 'completed', run[:status], run[:failure].inspect + failure_detail(run)
    run
  end

  def failure_detail(run)
    Dir.glob(@service.store.run_dir(run[:run_id], 'private', 'failure.json')).map { |path| File.read(path) }.join
  end

  def prepared_plan(prep, intent: 'stock', **opts)
    @service.propose_merge_plan(prepared_from: prep[:run_id], generation: prep.dig(:merge_environment, 'generation'), intent: intent, **opts)
  end

  def environment(run_id)
    @service.show_run(run_id)[:merge_environment]
  end

  def record(run_id)
    @service.store.load.dig('runs', run_id, 'merge_environment')
  end

  def instance_state
    @service.store.load.dig('instances', @instance, 'state')
  end

  def index_of(pattern, from: 0)
    merge_lines.each_with_index { |line, index| return index if index >= from && line.match?(pattern) }
    nil
  end

  def use_layer
    sha = 'c' * 40
    source = "class InventedMerger < BulkImport::DiscourseMerger; def self.silo_merge_preflight! = true; def self.silo_merge_postflight! = true; end\n"
    @runtime.layer_entries = "100644 blob #{sha}\tmergers/synthetic/merger.rb\0"
    @runtime.layer_blobs = { sha => source, 'mergers/synthetic/merger.rb' => source }
  end

  # -- the production quiesce script against real processes (no scripted runtime) ----------

  # Only the two container facts a test host lacks are supplied: the service account and runit.
  QUIESCE_PRELUDE = <<~'SH'
    id() { if [ "$*" = "-u discourse" ]; then [ -n "$SILO_TEST_SERVICE_UID" ] || return 1; echo "$SILO_TEST_SERVICE_UID"; else command id "$@"; fi; }
    sv() {
      echo "sv $*" >> "$SILO_TEST_SV_LOG"
      if [ "$1" = -w ]; then shift 2; fi
      case "$1" in
        stop) [ -z "$SILO_TEST_SV_STOP_FAILS" ] || { echo "timeout: run: $2"; return 1; }; echo "ok: down: $2: 1s, normally up" ;;
        status) echo "${SILO_TEST_SV_STATUS:-down}: $2: 1s, normally up" ;;
      esac
    }
    if [ -n "$SILO_TEST_PS_FAILS" ]; then ps() { return 1; }; fi
  SH

  def quiesce(dir, uid: Process.uid.to_s, path: ENV.fetch('PATH'), wrapped: false, ps_fails: false, grace: nil, stop_fails: false, status: nil)
    script = QUIESCE_PRELUDE + PREPARATION::MERGE_QUIESCE_SCRIPT
    # Wrapped: a parent shell carries the whole script on its command line as well.
    argv = wrapped ? ['/bin/sh', '-c', '/bin/sh -c "$0"; exit $?', script] : ['/bin/sh', '-c', script]
    env = { 'SILO_TEST_SERVICE_UID' => uid, 'SILO_TEST_SV_LOG' => File.join(dir, 'sv.log'), 'PATH' => path, 'SILO_TEST_PS_FAILS' => ps_fails ? '1' : '',
            'SILO_QUIESCE_GRACE' => grace.to_s, 'SILO_TEST_SV_STOP_FAILS' => stop_fails ? '1' : '', 'SILO_TEST_SV_STATUS' => status.to_s }
    Open3.capture2e(env, *argv)
  end

  def decoy(*argv, title: nil)
    pid = Process.spawn(*argv, out: File::NULL, err: File::NULL)
    @decoys << pid
    200.times do
      line = File.read("/proc/#{pid}/cmdline").tr("\0", ' ') rescue ''
      break if title ? line.start_with?(title) : !line.empty?

      sleep 0.05
    end
    pid
  end

  # A Ruby process that takes the title Sidekiq (or the pinned image's demon) gives itself.
  def titled(title, ignore_term: false)
    trap = ignore_term ? 'Signal.trap("TERM", "IGNORE"); ' : ''
    decoy(RbConfig.ruby, '-e', "#{trap}Process.setproctitle(#{title.dump}); sleep 300", title: title)
  end

  def running?(pid)
    Process.waitpid(pid, Process::WNOHANG).nil?
  rescue Errno::ECHILD
    false
  end

  def diagnostic(out)
    out.lines.map(&:strip).grep(PREPARATION::MERGE_QUIESCE_DIAGNOSTIC).last.to_s
  end

  def quiesce_host?
    File.executable?('/bin/sh') && File.directory?('/proc/self') && system('ps -eo pid=,ppid=,uid=,stat=,args= >/dev/null 2>&1')
  end

  def with_decoys
    skip 'needs /bin/sh, /proc and procps ps' unless quiesce_host?
    @decoys = []
    Dir.mktmpdir('silo-quiesce') { |dir| yield dir }
  ensure
    # Only this test's own children are ever cleaned up here.
    Array(@decoys).each do |pid|
      Process.kill('KILL', pid) rescue nil
      Process.waitpid(pid) rescue nil
    end
  end

  def test_prepare_quiesce_script_stops_real_sidekiq_and_never_its_own_shell
    script = PREPARATION::MERGE_QUIESCE_SCRIPT
    # The regression's premise: the script names the services, so its own shell (and any parent
    # or child carrying it) looks like a worker to a command-line search.
    assert_match(%r{/etc/service/sidekiq }, script)
    refute_match(/pgrep|pkill|killall|KILL/, script)
    with_decoys do |dir|
      bin = File.join(dir, 'bin')
      Dir.mkdir(bin)
      File.write(File.join(bin, 'sidekiq'), "sleep 300\n")
      File.write(File.join(dir, 'diagnostic.rb'), "sleep 300\n")
      # Real launch forms: ruby running a sidekiq program, Sidekiq's own title, the demon's title.
      program = decoy(RbConfig.ruby, File.join(bin, 'sidekiq'), '-q', 'critical,8')
      sidekiq = titled('sidekiq 7.3.9 discourse [0 of 5 busy]')
      demon = titled('discourse sidekiq')
      # Bystanders that merely carry the word as an argument, a title fragment or a request path.
      bystanders = [
        decoy(RbConfig.ruby, File.join(dir, 'diagnostic.rb'), '--label', 'sidekiq'),
        decoy('/bin/sh', '-c', 'while :; do sleep 1; done', 'my-sidekiq-notes', 'sidekiq'),
        titled('pitchfork (gen:0) worker[0] - requests: 1, processing: /sidekiq'),
        titled('ruby /invented/tool sidekiq')
      ]

      # Another account's processes are not this stack's service, whatever they are called.
      out, status = quiesce(dir, uid: (Process.uid + 1).to_s)
      assert_equal [0, 'SILO_QUIESCED'], [status.exitstatus, out.lines.last.to_s.strip], out
      assert_equal 'SILO_QUIESCE reason=quiesced workers=0 zombies=0 stopped=0 signalled=0 waited=0s grace=60s', diagnostic(out)
      assert [program, sidekiq, demon, *bystanders].all? { |pid| running?(pid) }

      # Same account as the workers, script on the shell's and its parent's command line: the
      # workers go, the shell survives to report, and nothing else is signalled.
      out, status = quiesce(dir, wrapped: true)
      refute status.signaled?, out
      assert_equal [0, 'SILO_QUIESCED'], [status.exitstatus, out.lines.last.to_s.strip], out
      assert_match(/\ASILO_QUIESCE reason=quiesced workers=0 zombies=0 stopped=0 signalled=3 waited=[1-9]\d*s grace=60s\z/, diagnostic(out))
      [program, sidekiq, demon].each { |pid| refute running?(pid) }
      assert bystanders.all? { |pid| running?(pid) }
      calls = File.readlines(File.join(dir, 'sv.log'), chomp: true)
      assert_equal ['sv -w 30 stop unicorn', 'sv status unicorn'], calls.last(2)

      # Already down, nothing left to stop: an immediate pass, again without touching bystanders.
      out, status = quiesce(dir)
      assert_equal [0, 'SILO_QUIESCED'], [status.exitstatus, out.lines.last.to_s.strip], out
      assert_includes diagnostic(out), 'signalled=0 waited=0s'
      assert bystanders.all? { |pid| running?(pid) }
      # No process argument ever reaches the output.
      refute_match(/diagnostic|processing|notes|invented/, out)
    end
  end

  def test_prepare_quiesce_script_bounded_drain_and_fail_closed
    with_decoys do |dir|
      # A worker that ignores TERM: bounded wait, repeated TERM, a fixed reason and counts; it is
      # never KILLed and the script never reports quiesced.
      stubborn = titled('sidekiq 7.3.9 discourse [1 of 5 busy] stopping', ignore_term: true)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, status = quiesce(dir, grace: 2)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_equal 2, status.exitstatus, out
      refute_includes out, 'SILO_QUIESCED'
      assert_equal 'SILO_QUIESCE reason=workers_remain workers=1 zombies=0 stopped=0 signalled=1 waited=2s grace=2s', diagnostic(out)
      assert_operator elapsed, :<, 30
      assert running?(stubborn)
      # The grace can only be shortened by the environment, never extended or disabled.
      head = PREPARATION::MERGE_QUIESCE_SCRIPT.lines.take_while { |line| !line.include?("count=0;") }.join
      assert_equal "grace=#{PREPARATION::MERGE_QUIESCE_GRACE}\n", head.lines[1]
      { '' => '60', '0' => '60', '600' => '60', '61' => '60', 'x' => '60', '-1' => '60', '5' => '5' }.each do |given, effective|
        out, = Open3.capture2e({ 'SILO_QUIESCE_GRACE' => given }, '/bin/sh', '-c', head + 'echo "$grace"')
        assert_equal "#{effective}\n", out, given
      end
      Process.kill('KILL', stubborn)
      Process.waitpid(stubborn)

      # A failed stop or an app server still up refuses, with its own exit code and reason.
      out, status = quiesce(dir, stop_fails: true)
      assert_equal [1, 'reason=stop_failed'], [status.exitstatus, diagnostic(out).split[1]], out
      out, status = quiesce(dir, status: 'run')
      assert_equal [3, 'reason=app_server_not_down'], [status.exitstatus, diagnostic(out).split[1]], out

      # Fail closed: no verified service account, no ps, or an unreadable process table.
      empty = File.join(dir, 'empty')
      Dir.mkdir(empty)
      [[{ uid: '' }, 'no_service_user'], [{ uid: '0' }, 'no_service_user'], [{ uid: 'discourse' }, 'no_service_user'],
       [{ path: empty }, 'no_ps'], [{ ps_fails: true }, 'process_table_unreadable']].each do |options, reason|
        out, status = quiesce(dir, **options)
        assert_equal 4, status.exitstatus, options.inspect + out
        refute_includes out, 'SILO_QUIESCED'
        assert_equal "reason=#{reason}", diagnostic(out).split[1], options.inspect + out
      end
    end
  end

  # The failure keeps its public code; only the script's fixed reason/count line reaches the
  # private failure detail, never other output.
  def test_prepare_quiesce_failure_detail_is_reason_and_counts_only
    with_prepare do
      @runtime.quiesce_result = SiloMigrate::Runtime::CommandResult.new(
        success?: false, status: 2, stderr: '',
        stdout: "ok: down: unicorn: 1s, normally up\nruby /invented/private.rb --customer secret\nSILO_QUIESCE reason=workers_remain workers=1 zombies=0 stopped=0 signalled=6 waited=60s grace=60s\n"
      )
      run = run_prepare
      assert_equal 'STANDARD_STACK_FAILED', run.dig(:failure, 'code')
      detail = JSON.parse(failure_detail(run)).fetch('detail')
      assert_equal 'STANDARD_STACK_FAILED: quiesce: reason=workers_remain workers=1 zombies=0 stopped=0 signalled=6 waited=60s grace=60s', detail
      refute_includes run.inspect, 'secret'
    end
    with_prepare do
      @runtime.quiesce_result = SiloMigrate::Runtime::CommandResult.new(success?: false, status: 2, stderr: '',
        stdout: "SILO_QUIESCE reason=invented_secret workers=1 zombies=0 stopped=0 signalled=1 waited=1s grace=60s\n")
      run = run_prepare
      assert_equal 'STANDARD_STACK_FAILED: quiesce', JSON.parse(failure_detail(run)).fetch('detail')
    end
    with_prepare do
      @runtime.quiesce_result = SiloMigrate::Runtime::CommandResult.new(success?: false, status: 2, stderr: '', stdout: "SILO_QUIESCE reason=workers_remain path=/invented/secret\n")
      run = run_prepare
      assert_equal 'STANDARD_STACK_FAILED: quiesce', JSON.parse(failure_detail(run)).fetch('detail')
    end
  end

  def test_prepare_plan_needs_no_converter_layer_or_settings
    with_prepare do
      # A dirty converter checkout blocks the one-shot merge, never a preparation.
      @runtime.converter_dirty = true
      standard_error('STANDARD_CONVERTER_DIRTY') { merge_plan }
      plan = prepare_plan
      assert_equal 'standard_merge_prepare', plan[:operation]
      assert_equal 'proposed', plan[:status]
      assert_nil plan[:converter_revision]
      assert_nil plan.dig(:merge, 'layer')
      assert_equal %w[base_site source], plan[:roles].keys.sort
      assert_equal 2, plan.dig(:capacity, 'inspection_copies')
      assert_equal ['environment'], plan[:outputs].keys
      assert plan[:not_included].any? { |text| text.include?('does not copy') && text.include?('never implied carried') }
      assert plan[:not_included].any? { |text| text.include?('merge itself') }
      refute_match(/private-site|customer-secret|#{Regexp.escape(@root)}/, JSON.generate(plan))
      body = @service.store.load.fetch('plans').fetch(plan[:plan_id])
      assert_equal PREPARATION::PREPARE_STAGES, @service.send(:stages_for, body)
      assert_equal %w[preflight site_up base_restore source_load compatibility checkpoint inspection], PREPARATION::PREPARE_STAGES
      refute body.fetch('body').key?('converter_revision')
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.propose_merge_preparation_plan(source: @merge_source, base_site: @merge_source) }
      standard_error('STANDARD_INPUTS_INCOMPLETE') { @service.propose_merge_preparation_plan(source: @ids['source'], base_site: @base) }
      standard_error('STANDARD_REFERENCE_INVALID') { @service.propose_merge_preparation_plan(source: 'missing', base_site: @base) }
      assert_equal 'supported_local_prepare_inspect_then_one_use_merge', @service.status[:capabilities]['prepared_discourse_merge']
    end
  end

  def test_prepare_binds_shm_headroom_and_merge_keeps_the_approved_limits
    with_prepare do
      @service.define_singleton_method(:host_capacity) { [8, 128 * 1024] }
      original = @service.method(:review_limits)
      # Tiny invented archives exercise the large tier without creating a huge fixture.
      @service.define_singleton_method(:review_limits) { |input_bytes: 0| original.call(input_bytes: input_bytes + 20 * 1024**3) }
      plan = prepare_plan
      assert_equal 2048, plan.dig(:limits, 'db', 'maintenance_work_mem_mib')
      assert_equal 4096, plan.dig(:limits, 'db', 'shm_mib')
      run = run_prepare(plan)
      assert_equal 'completed', run[:status], run[:failure].inspect + failure_detail(run)
      db = @runtime.calls.find { |cmd| cmd[0, 2] == %w[docker run] && cmd.include?("#{@instance}-db") }
      assert_equal '4096m', db[db.index('--shm-size') + 1]
      @service.define_singleton_method(:review_limits) { |**_options| raise 'prepared merge must not recalculate limits' }
      merge = prepared_plan(run)
      assert_equal run[:run_id], merge.dig(:prepared_from, 'run_id')
      assert_equal plan[:limits], merge[:limits]
    end
  end

  def test_prepare_database_inventory_checks_the_fresh_stack_before_restore
    with_prepare do
      run = prepared
      initial = index_of(/CASE WHEN datallowconn/)
      assert_operator initial, :<, index_of(%r{script/discourse restore})
      assert @runtime.sql.grep(/SELECT datname \|\|/).all? { |sql| sql.include?("CASE WHEN datallowconn THEN 't' ELSE 'f' END") }
      assert_equal 'completed', run[:status]
    end
  end

  def test_prepare_initial_database_probe_command_failure_is_stack_failure
    with_prepare do
      @runtime.fail_sql = 'CASE WHEN datallowconn'
      run = run_prepare
      assert_equal 'failed', run.dig(:stages, 'site_up')
      assert_equal 'pending', run.dig(:stages, 'base_restore')
      assert_equal 'STANDARD_STACK_FAILED', run.dig(:failure, 'code')
      assert_includes failure_detail(run), 'initial-databases'
      refute index_of(%r{script/discourse restore})
    end
  end

  def test_prepare_unexpected_initial_databases_refuse_before_restore
    [{'discourse' => false}, {'discourse' => true, 'silo_clean_base' => true},
     {'discourse' => true, 'merge_source' => true}].each do |databases|
      with_prepare do
        @runtime.databases.replace(databases)
        run = run_prepare
        assert_equal 'failed', run[:status]
        assert_equal 'failed', run.dig(:stages, 'site_up')
        assert_equal 'pending', run.dig(:stages, 'base_restore')
        assert_equal 'STANDARD_MERGE_ENVIRONMENT_DIRTY', run.dig(:failure, 'code')
        assert_includes failure_detail(run), 'unexpected initial databases'
        refute index_of(%r{script/discourse restore})
      end
    end
  end

  def test_prepare_run_reaches_ready_without_constructing_a_merger
    with_prepare do
      run = prepared
      assert run[:stages].values.all? { |status| status == 'passed' }
      assert_equal PREPARATION::PREPARE_STAGES, run[:stages].keys
      # Readiness: no merger process, no marker edit, no backup of the source taken again.
      refute index_of(%r{ruby /tmp/merge_run\.rb})
      refute merge_lines.any? { |line| line.match?(/schema_migrations/i) && line.match?(/DELETE|INSERT|UPDATE/i) }
      assert_equal 'passed', run.dig(:results, 'merge', 'compatibility', 'status')
      assert_equal 3000, run.dig(:results, 'merge', 'inspection_copy_bytes')
      assert_equal({ 'state' => 'open', 'endpoints' => 2, 'granted_tables' => 3, 'unreviewed_tables' => 1 }, run.dig(:results, 'merge', 'inspection'))
      summary = run[:merge_environment]
      assert_equal %w[generation phase preparation_run_id], summary.keys.sort
      assert_equal run[:run_id], summary['preparation_run_id']
      assert_equal 'ready', summary['phase']
      assert_match(/\A[0-9a-f]{64}\z/, summary['generation'])
      assert_equal summary, @service.status[:runs].find { |entry| entry[:run_id] == run[:run_id] }[:merge_environment]
      # The prepared databases are sealed; only the copies accept connections.
      assert_equal SEALED, @runtime.databases
      assert_equal @runtime.content['silo_clean_base'], @runtime.content['discourse']
      assert_equal @runtime.content['merge_source'], @runtime.content['silo_inspect_source']
      assert_equal 'prepared', instance_state
      # Unicorn and Sidekiq are quiesced before anything is sealed or copied; the app starts on
      # the copy and only then is inspection opened, once, for the preparation run.
      quiesce = merge_lines.each_index.select { |index| merge_lines[index].include?('SILO_QUIESCED') }
      assert_equal 3, quiesce.size
      assert merge_lines[quiesce.last].include?('sidekiq')
      seal = index_of(/RENAME TO silo_clean_base/)
      start = index_of(/sv start unicorn/, from: seal)
      assert_operator quiesce.last, :<, seal
      assert_operator index_of(/ALLOW_CONNECTIONS false/, from: seal), :<, start
      assert_equal [{ op: 'open', run_id: run[:run_id], phase: 'base', backup: false, admin: false }], @inspection.map { |call| call.slice(:op, :run_id, :phase, :backup, :admin) }
      assert_operator @inspection.first[:at], :>, start
      assert_equal({ generation: summary['generation'], preparation_run_id: run[:run_id], source_database: 'silo_inspect_source' }, @inspection.first[:facts])
      # Projections carry no access material and no database or path detail.
      shown = JSON.generate([run, @service.status, @service.show_plan(run[:plan_id], detail: true)])
      refute_match(/invented-private-api-key|silo_inspect_source|silo_clean_base|merge-access|private-source|secret\.png|#{Regexp.escape(@root)}/, shown)
      # Private host seam: locators only.
      access = @service.merge_access(run[:run_id], side: 'source')
      assert_equal 'silo_inspect_source', access[:database]
      assert_equal 'discourse', @service.merge_access(run[:run_id], side: 'base')[:database]
      assert_equal @service.store.run_dir(run[:run_id], 'private', 'merge-access.json'), access[:manifest]
      assert_equal %i[database generation instance manifest phase preparation_run_id run_id side version], access.keys.sort
      standard_error('STANDARD_TRANSITION_INVALID') { @service.merge_access(run[:run_id], side: 'result') }
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.merge_access(run[:run_id], side: 'clean') }
      # Uploads stay private and whole for the later merge.
      assert File.directory?(@service.store.run_dir(run[:run_id], 'private', 'merge-source'))
      assert_equal 1, @service.merge_evidence(run[:run_id]).dig('totals', 'source_upload_files')
    end
  end

  def test_prepare_shared_plugin_table_is_unhandled_not_carried
    with_prepare do
      base = (MergeScriptedRuntime::MERGE_TABLES + %w[schema_migrations]).map { |table| [table, table == 'schema_migrations' ? 'version' : 'id', 'bigint'] }
      both = base + [%w[plugin_table id bigint], %w[plugin_table customer_note text], %w[backup_metadata name text]]
      @runtime.target_state = { 'columns' => both + [%w[plugin_table target_extra text]] }
      @runtime.source_state = { 'columns' => both + [%w[source_only_plugin id bigint], %w[users legacy_flag boolean]] }
      plan = prepare_plan
      run = run_prepare(plan)
      assert_equal 'completed', run[:status], failure_detail(run)
      compatibility = run.dig(:results, 'merge', 'compatibility')
      assert_equal 'passed', compatibility['status']
      # Present on both sides is not "carried": the pinned merger never names it.
      assert_equal 2, compatibility['unhandled_source_tables']
      assert_equal 1, compatibility['unhandled_shared_tables']
      assert_equal 1, compatibility['source_only_tables']
      assert_equal 1, compatibility['source_only_columns']
      assert_equal 'merger_named_tables_only', compatibility['carried_scope']
      assert_equal 7, compatibility['merger_tables']
      assert_equal 11, compatibility['source_tables']
      assert_equal 1, run.dig(:results, 'merge', 'target_only_columns')
      report = JSON.parse(File.read(@service.store.run_dir(run[:run_id], 'evidence', 'merge-compatibility.json')))
      assert_equal %w[plugin_table source_only_plugin], report['unhandled_source_tables']
      assert_equal %w[source_only_plugin], report['source_only_tables']
      assert_equal [%w[users legacy_flag]], report['source_only_columns']
      assert_equal [%w[plugin_table target_extra]], report['target_only_columns']
      refute_includes report['unhandled_source_tables'], 'backup_metadata'
      # Names are customer-shaped: counts leave the private directory, names don't.
      refute_match(/plugin_table|source_only_plugin|legacy_flag|target_extra|customer_note/, JSON.generate([run, @service.status]))
      # The consuming merge re-checks on the activated databases and reports the same scope.
      merged = @service.run_plan(plan_id: approve(prepared_plan(run)))
      assert_equal 'completed', merged[:status], failure_detail(merged)
      assert_equal 1, merged.dig(:results, 'merge', 'compatibility', 'unhandled_shared_tables')
      assert @service.show_plan(merged[:plan_id])[:not_included].any? { |text| text.include?('never implied carried') }
    end
  end

  def test_prepare_compatibility_matrix_fails_closed
    with_prepare do
      columns = (MergeScriptedRuntime::MERGE_TABLES + %w[schema_migrations]).map { |table| [table, 'id', 'bigint'] }
      state = lambda do |**changes|
        { 'pending' => false, 'migrations' => ['20261104011110'], 'columns' => columns,
          'merger' => { 'available' => true, 'tables' => MergeScriptedRuntime::MERGE_TABLES } }.merge(changes.transform_keys(&:to_s))
      end
      checks = ->(target, source) { @service.send(:merge_compatibility, target, source, ['20261104011110']).fetch('failures').map { |failure| failure['check'] }.sort }
      assert_equal [], checks.call(state.call, state.call)
      assert_equal %w[source-pending], checks.call(state.call, state.call(pending: true))
      assert_equal %w[target-pending], checks.call(state.call(pending: nil), state.call)
      # A schema newer than the pinned code, whatever the file was called.
      assert_equal %w[schema-version-differs source-newer-than-runtime], checks.call(state.call, state.call(migrations: %w[20261104011110 20270101000000]))
      assert_equal %w[source-newer-than-runtime target-newer-than-runtime], checks.call(state.call(migrations: %w[20261104011110 20270101000000]), state.call(migrations: %w[20261104011110 20270101000000]))
      assert_equal %w[schema-version-differs source-missing-runtime-migrations], checks.call(state.call, state.call(migrations: %w[20250101000000]))
      # An older unknown migration (a plugin this runtime lacks) is recorded, not refused.
      older = @service.send(:merge_compatibility, state.call, state.call(migrations: %w[20250101000000 20261104011110]), ['20261104011110'])
      assert_equal [], older['failures']
      assert_equal %w[20250101000000], older['source_unknown_migrations']
      # An inventory the trusted helper didn't produce is never assumed.
      assert_equal %w[migration-inventory], checks.call(state.call, state.call(migrations: nil))
      assert_equal %w[migration-inventory], checks.call(state.call(migrations: ['not-a-version']), state.call)
      assert_equal %w[schema-inventory], checks.call(state.call(columns: 'users'), state.call)
      assert_equal %w[merger-tables-unknown], checks.call(state.call(merger: { 'available' => false, 'tables' => [] }), state.call)
      unknown = @service.send(:merge_compatibility, state.call(merger: nil), state.call, ['20261104011110'])
      assert_equal 'unknown', unknown['carried_scope']
      assert_equal %w[source-missing-columns], checks.call(state.call(columns: columns + [%w[users locale text]]), state.call)
      assert_equal %w[column-types-differ], checks.call(state.call, state.call(columns: columns.map { |table, column, _type| [table, column, 'integer'] }))
      assert_equal %w[source-missing-tables], checks.call(state.call, state.call(columns: columns.reject { |table, _column| table == 'tags' }))
      assert_equal %w[target-missing-tables], checks.call(state.call(merger: { 'available' => true, 'tables' => %w[users invented_model_table] }), state.call(columns: columns + [%w[invented_model_table id bigint]]))
    end
  end

  def test_prepare_binds_inspection_clone_identity_before_minting
    with_prepare do
      run = prepared
      assert_equal '2001', record(run[:run_id]).fetch('base_inspection_database_oid')
      mint = @inspection.find { |call| call[:op] == 'open' && call[:phase] == 'base' }
      assert mint
      query = index_of(/SELECT oid::text FROM pg_database WHERE datname = 'discourse'/)
      assert query
      assert_operator query, :<, mint.fetch(:at)
      refute_includes JSON.generate(run[:merge_environment]), 'base_inspection_database_oid'
    end
  end

  def test_prepare_unknown_clone_identity_never_opens_access
    ['', '0', 'not-an-oid'].each do |oid|
      with_prepare do
        @runtime.inspection_oid = oid
        run = run_prepare
        assert_equal 'failed', run[:status], failure_detail(run)
        assert_equal 'failed', run.dig(:stages, 'checkpoint')
        assert_equal 'dirty', environment(run[:run_id])['phase']
        refute @inspection.any? { |call| call[:op] == 'open' }
      end
    end
  end

  def test_prepare_incompatible_source_stops_before_checkpoint
    with_prepare do
      @runtime.source_state = { 'migrations' => %w[20261104011110 20270101000000] }
      run = run_prepare
      assert_equal 'STANDARD_MERGE_INCOMPATIBLE', run.dig(:failure, 'code')
      assert_includes run.dig(:failure, 'recovery'), 'no migration marker was edited'
      assert_equal 'failed', run.dig(:stages, 'compatibility')
      assert_equal 'pending', run.dig(:stages, 'checkpoint')
      assert_equal 'refused', run.dig(:results, 'merge', 'compatibility', 'status')
      assert_equal 'dirty', run.dig(:merge_environment, 'phase')
      assert_nil run.dig(:merge_environment, 'generation')
      assert_equal ACTIVE, @runtime.databases
      refute index_of(/TEMPLATE|RENAME TO/)
      refute index_of(%r{ruby /tmp/merge_run\.rb})
      refute merge_lines.any? { |line| line.match?(/schema_migrations/i) && line.match?(/DELETE|INSERT|UPDATE/i) }
      assert_equal [], @inspection
      refute_includes JSON.generate(run), '20270101000000'
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.propose_merge_plan(prepared_from: run[:run_id], generation: nil, intent: 'stock') }
      standard_error('STANDARD_MERGE_ENVIRONMENT_STALE') { @service.propose_merge_plan(prepared_from: run[:run_id], generation: 'a' * 64, intent: 'stock') }
    end
  end

  def test_prepare_merge_consumes_exactly_one_generation
    with_prepare do
      prep = prepared
      generation = prep.dig(:merge_environment, 'generation')
      standard_error('STANDARD_MERGE_ENVIRONMENT_STALE') { @service.propose_merge_plan(prepared_from: prep[:run_id], generation: 'f' * 64, intent: 'stock') }
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.propose_merge_plan(prepared_from: prep[:run_id], generation: generation) }
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.propose_merge_plan(prepared_from: prep[:run_id], generation: generation, intent: 'automatic') }
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.propose_merge_plan(prepared_from: prep[:run_id], generation: generation, intent: 'stock', port: 18099) }
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.propose_merge_plan(prepared_from: prep[:run_id], generation: generation, intent: 'stock', source: @base) }
      standard_error('STANDARD_REFERENCE_INVALID') { @service.propose_merge_plan(prepared_from: 'run-' + '0' * 32, generation: generation, intent: 'stock') }
      # Explicit stock: no converter or layer is consulted, however dirty the checkout is.
      @runtime.converter_dirty = true
      # Stock reads no settings: a mapping it would silently ignore is refused, not bound.
      standard_error('STANDARD_MERGE_INTENT_MISMATCH') { @service.propose_merge_plan(prepared_from: prep[:run_id], generation: generation, intent: 'stock', settings: @merge_settings) }
      plan = @service.propose_merge_plan(prepared_from: prep[:run_id], generation: generation, intent: 'stock', source: @merge_source, base_site: @base)
      assert_equal false, plan.dig(:merge, 'settings')
      assert_equal 'standard_merge', plan[:operation]
      assert_equal({ 'run_id' => prep[:run_id], 'generation' => generation }, plan[:prepared_from])
      assert_equal 'stock', plan[:intent]
      assert_equal({ 'present' => false }, plan.dig(:merge, 'layer'))
      assert_nil plan[:converter_revision]
      assert_equal @instance, plan.dig(:instances, 'review', 'name')
      assert_equal @service.show_plan(prep[:plan_id])[:discourse_profile], plan[:discourse_profile]
      assert_equal PREPARATION::PREPARED_MERGE_STAGES, @service.send(:stages_for, @service.store.load.fetch('plans').fetch(plan[:plan_id]))
      refute_includes PREPARATION::PREPARED_MERGE_STAGES, 'source_load'
      second = prepared_plan(prep)
      before = merge_lines.size
      run = @service.run_plan(plan_id: approve(plan))
      assert_equal 'completed', run[:status], run[:failure].inspect + failure_detail(run)
      assert run[:stages].values.all? { |status| status == 'passed' }
      assert_equal({ 'preparation_run_id' => prep[:run_id], 'generation' => generation, 'phase' => 'result' }, run[:merge_environment])
      assert_equal 'result', environment(prep[:run_id])['phase']
      assert_equal run[:run_id], record(prep[:run_id])['consumed_by']
      assert_equal ACTIVE, @runtime.databases
      assert_equal PrepareScriptedRuntime.seal('a'), @runtime.content['discourse']
      # Fence first, then drop the copies, restore the clean names, flush Redis; only then a merger.
      close = @inspection.find { |call| call[:op] == 'close' }
      assert_equal prep[:run_id], close[:run_id]
      assert_operator close[:at], :>=, before
      fence = index_of(/ALTER DATABASE discourse ALLOW_CONNECTIONS false/, from: before)
      assert_operator close[:at], :<=, fence
      assert_operator index_of(/SILO_QUIESCED/, from: before), :<, fence
      drop = index_of(/DROP DATABASE silo_inspect_source/, from: before)
      rename = index_of(/ALTER DATABASE silo_clean_base RENAME TO discourse/, from: before)
      flush = index_of(/redis-cli FLUSHALL/, from: before)
      merger = index_of(%r{ruby /tmp/merge_run\.rb}, from: before)
      assert_equal [fence, drop, rename, flush, merger], [fence, drop, rename, flush, merger].sort
      assert_operator index_of(/pg_terminate_backend/, from: fence), :<, drop
      # Stock: no layer, no required policy hooks.
      refute_match(/SILO_MERGE_REQUIRE_CHECKS|SILO_MERGE_LAYER|SILO_MERGE_SETTINGS/, merge_lines[merger])
      # The source was loaded once, by the preparation: no restore, reload or re-extraction now.
      refute merge_lines.drop(before).any? { |line| line.match?(%r{script/discourse restore|CREATE DATABASE merge_source|silo-merge\.sql\.gz|db:migrate}) }
      refute File.exist?(@service.store.run_dir(run[:run_id], 'private', 'merge-source'))
      # Result inspection only after the clean backup, for the merge run.
      opened = @inspection.select { |call| call[:op] == 'open' }
      assert_equal %w[base result], opened.map { |call| call[:phase] }
      assert_equal run[:run_id], opened.last[:run_id]
      assert_equal true, opened.last[:backup]
      assert_equal({ generation: generation, preparation_run_id: prep[:run_id] }, opened.last[:facts])
      assert_equal 'open', run.dig(:results, 'merge', 'result_inspection')
      assert_equal 1, run.dig(:results, 'merge', 'archive_upload_files')
      assert_equal 'setup', instance_state
      assert_equal 'discourse', @service.merge_access(run[:run_id], side: 'result')[:database]
      standard_error('STANDARD_TRANSITION_INVALID') { @service.merge_access(prep[:run_id], side: 'base') }
      refute_match(/invented-private-api-key|silo_clean_base|merge-access/, JSON.generate([run, @service.status]))
      # One generation, one merge: the other plan is stale, a new one is refused.
      assert_equal 'stale', @service.show_plan(second[:plan_id])[:status]
      @service.approve_plan(plan_id: second[:plan_id], sha256: second[:digest], reviewer: 'Invented engineer') rescue nil
      error = assert_raises(SiloMigrate::StandardWorkflowError) { @service.claim(plan_id: second[:plan_id]) }
      assert_includes %w[STANDARD_STALE_PLAN STANDARD_NOT_APPROVED], error.code
      standard_error('STANDARD_MERGE_ENVIRONMENT_STALE') { prepared_plan(prep) }
      # Ownership: the environment is reset through the run that took it, and only by it.
      standard_error('STANDARD_TRANSITION_INVALID') { @service.reset_run(run_id: prep[:run_id], yes: true) }
      assert_equal 'setup', instance_state
      @inspection.clear
      reset = @service.reset_run(run_id: run[:run_id], yes: true)
      assert_equal [@instance], reset[:removed]
      assert_equal [prep[:run_id], run[:run_id]], @inspection.map { |call| call[:run_id] }
      assert @inspection.all? { |call| call[:op] == 'close' }
      assert_equal 'removed', instance_state
      assert_equal 'reset', environment(prep[:run_id])['phase']
      assert_equal 'reset', environment(run[:run_id])['phase']
      refute File.exist?(@service.store.run_dir(prep[:run_id], 'private', 'merge-source'))
      assert_equal 'reset', @service.reset_run(run_id: prep[:run_id], yes: true)[:status]
    end
  end

  def test_prepare_custom_intent_binds_layer_and_required_checks
    with_prepare do
      prep = prepared
      error = standard_error('STANDARD_MERGE_INTENT_MISMATCH') { prepared_plan(prep, intent: 'custom') }
      assert_equal 'STANDARD_MERGE_INTENT_MISMATCH', error.code
      use_layer
      # A layer that disappears after approval is a changed plan, not a silent stock merge.
      plan = prepared_plan(prep, intent: 'custom')
      @runtime.layer_entries = ''
      failed = @service.run_plan(plan_id: approve(plan))
      assert_equal 'STANDARD_MERGE_LAYER_INVALID', failed.dig(:failure, 'code')
      assert_equal 'failed', failed.dig(:stages, 'preflight')
      assert_equal 'released', failed.dig(:merge_environment, 'phase')
      assert_equal 'ready', environment(prep[:run_id])['phase']
      assert_equal SEALED, @runtime.databases
      # Nothing was consumed: the same generation serves the next exact plan.
      use_layer
      plan = prepared_plan(prep, intent: 'custom', settings: @merge_settings)
      assert_equal 'custom', plan[:intent]
      assert_equal true, plan.dig(:merge, 'layer', 'present')
      assert_equal true, plan.dig(:merge, 'settings')
      assert_equal 'a' * 40, plan[:converter_revision]
      before = merge_lines.size
      run = @service.run_plan(plan_id: approve(plan))
      assert_equal 'completed', run[:status], run[:failure].inspect + failure_detail(run)
      # The command line is shell-escaped; compare the plain form.
      merger = merge_lines[index_of(%r{ruby /tmp/merge_run\.rb}, from: before)].delete('\\')
      assert_includes merger, 'SILO_MERGE_REQUIRE_CHECKS=1'
      assert_includes merger, 'SILO_MERGE_LAYER=/shared/merge/layer/merger.rb'
      assert_includes merger, 'SILO_MERGE_SETTINGS=/shared/merge/settings.yml'
      # The gate sees the committed layer's models before any merger exists.
      scan = merge_lines.each_index.find { |index| index >= before && merge_lines[index].delete('\\').match?(%r{SILO_MERGE_SCAN_LAYER=/shared/silo-merge-layer-scan .*merge_state\.rb}) }
      assert scan
      assert_operator scan, :<, index_of(%r{ruby /tmp/merge_run\.rb}, from: before)
    end
  end

  def test_prepare_merge_requires_one_terminal_done_line
    ["SILO_MERGE: start layer=no\n", "SILO_MERGE: done\nSILO_MERGE: done\n", "SILO_MERGE: done\nlate output\n", "  SILO_MERGE: done\n", ''].each do |output|
      with_prepare do
        prep = prepared
        @runtime.merger_result = review_ok_output(output)
        run = @service.run_plan(plan_id: approve(prepared_plan(prep)))
        assert_equal 'STANDARD_MERGE_FAILED', run.dig(:failure, 'code'), output.inspect
        assert_equal 'failed', run.dig(:stages, 'merge')
        assert_equal 'pending', run.dig(:stages, 'backup')
        assert_nil run.dig(:artifacts, 'backup')
        assert_equal 'dirty', run.dig(:merge_environment, 'phase')
        assert_equal 'dirty', environment(prep[:run_id])['phase']
        assert_equal 'dirty', instance_state
        refute @inspection.any? { |call| call[:phase] == 'result' }
      end
    end
    with_prepare do
      prep = prepared
      @runtime.merger_result = review_ok_output("SILO_MERGE: start layer=no\r\nSILO_MERGE: done\r\n\n")
      run = @service.run_plan(plan_id: approve(prepared_plan(prep)))
      assert_equal 'completed', run[:status], failure_detail(run)
    end
  end

  def review_ok_output(stdout)
    SiloMigrate::Runtime::CommandResult.new(success?: true, stdout: stdout, stderr: '', status: 0)
  end

  def test_prepare_environment_goes_stale_on_runtime_or_input_change
    with_prepare do
      prep = prepared
      plan = prepared_plan(prep)
      original = @service.store.load.dig('config', 'discourse_profile_sha256')
      @service.store.update { |state| state['config']['discourse_profile_sha256'] = '0' * 64 }
      assert_equal 'stale', environment(prep[:run_id])['phase']
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_MERGE_ENVIRONMENT_STALE') { prepared_plan(prep) }
      standard_error('STANDARD_TRANSITION_INVALID') { @service.merge_access(prep[:run_id], side: 'base') }
      @service.store.update { |state| state['config']['discourse_profile_sha256'] = original }
      assert_equal 'ready', environment(prep[:run_id])['phase']
      assert_equal 'proposed', @service.show_plan(plan[:plan_id])[:status]
      # The source input changes after preparation: the loaded copy is no longer that input.
      input = @service.store.named_state.fetch('inputs').fetch(@merge_source)
      path = File.join(@root, input.fetch('path').unpack1('m0'))
      File.chmod(0600, path)
      File.write(path, 'changed')
      assert_equal 'stale', environment(prep[:run_id])['phase']
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_MERGE_ENVIRONMENT_STALE') { prepared_plan(prep) }
      # Nothing was touched: the stale environment still stands until its own run is reset.
      assert_equal SEALED, @runtime.databases
      assert_equal 'prepared', instance_state
    end
  end

  def test_prepare_reset_ends_the_generation
    with_prepare do
      prep = prepared
      plan_id = approve(prepared_plan(prep))
      @inspection.clear
      reset = @service.reset_run(run_id: prep[:run_id], yes: true)
      assert_equal [@instance], reset[:removed]
      assert_equal [{ op: 'close', run_id: prep[:run_id] }], @inspection.map { |call| call.slice(:op, :run_id) }
      assert_equal 'reset', environment(prep[:run_id])['phase']
      assert_equal 'removed', instance_state
      refute File.exist?(@service.store.run_dir(prep[:run_id], 'private', 'merge-source'))
      assert_equal 'stale', @service.show_plan(plan_id)[:status]
      standard_error('STANDARD_STALE_PLAN') { @service.claim(plan_id: plan_id) }
      standard_error('STANDARD_MERGE_ENVIRONMENT_STALE') { prepared_plan(prep) }
      standard_error('STANDARD_TRANSITION_INVALID') { @service.merge_access(prep[:run_id], side: 'source') }
      # A second preparation is its own generation.
      @runtime.new_volume!
      again = prepared
      refute_equal prep.dig(:merge_environment, 'generation'), again.dig(:merge_environment, 'generation')
      standard_error('STANDARD_MERGE_ENVIRONMENT_STALE') { @service.propose_merge_plan(prepared_from: again[:run_id], generation: prep.dig(:merge_environment, 'generation'), intent: 'stock') }
    end
  end

  def test_prepare_merge_failing_before_activation_releases_the_environment
    with_prepare do
      prep = prepared
      plan = prepared_plan(prep)
      service = @service
      service.define_singleton_method(:prepared_merge_preflight) { |*_args| raise SiloMigrate::StandardWorkflowError, 'STANDARD_CAPACITY' }
      @inspection.clear
      before = merge_lines.size
      run = service.run_plan(plan_id: approve(plan))
      assert_equal 'STANDARD_CAPACITY', run.dig(:failure, 'code')
      # Nothing was fenced or dropped, so nothing of the preparation is lost or dirtied.
      assert_equal 'released', run.dig(:merge_environment, 'phase')
      assert_equal 'ready', environment(prep[:run_id])['phase']
      assert_nil record(prep[:run_id])['consumed_by']
      assert_equal 'prepared', instance_state
      assert_equal SEALED, @runtime.databases
      assert_equal [], @inspection
      refute merge_lines.drop(before).any? { |line| line.match?(/DROP DATABASE|ALLOW_CONNECTIONS|RENAME TO/) }
      # Resetting the failed merge run removes nothing of the environment it never took.
      reset = service.reset_run(run_id: run[:run_id], yes: true)
      assert_equal [], reset[:removed]
      assert_equal 'ready', environment(prep[:run_id])['phase']
      assert_equal 'prepared', instance_state
      # The same generation can still be merged, once.
      service.singleton_class.send(:remove_method, :prepared_merge_preflight)
      merged = service.run_plan(plan_id: approve(prepared_plan(prep)))
      assert_equal 'completed', merged[:status], failure_detail(merged)
      assert_equal 'result', environment(prep[:run_id])['phase']
      assert_equal 'released', environment(run[:run_id])['phase']
    end
  end

  def test_prepare_checkpoint_failure_is_owned_and_dirty
    with_prepare do
      @runtime.fail_sql = 'TEMPLATE merge_source'
      run = run_prepare
      assert_equal 'STANDARD_MERGE_ENVIRONMENT_DIRTY', run.dig(:failure, 'code')
      assert_equal 'failed', run.dig(:stages, 'checkpoint')
      assert_equal 'pending', run.dig(:stages, 'inspection')
      assert_equal 'dirty', run.dig(:merge_environment, 'phase')
      assert_nil run.dig(:merge_environment, 'generation')
      # Ownership was durable before the first fallible action.
      assert_equal @instance, record(run[:run_id])['instance']
      assert_equal 'dirty', instance_state
      assert_equal [], @inspection
      standard_error('STANDARD_DIRTY_INSTANCE') { @service.claim(plan_id: approve(prepare_plan)) }
      @runtime.fail_sql = nil
      assert_equal [@instance], @service.reset_run(run_id: run[:run_id], yes: true)[:removed]
      assert_equal 'reset', environment(run[:run_id])['phase']
    end
    with_prepare do
      @runtime.sessions_left = 2
      run = run_prepare
      assert_equal 'STANDARD_MERGE_ENVIRONMENT_DIRTY', run.dig(:failure, 'code')
      assert_equal ACTIVE, @runtime.databases
      refute index_of(/TEMPLATE|RENAME TO/)
    end
    with_prepare do
      @runtime.quiesce_result = review_ok_output("ok: down: unicorn: 0s\n")
      run = run_prepare
      assert_equal 'STANDARD_STACK_FAILED', run.dig(:failure, 'code')
      assert_equal 'failed', run.dig(:stages, 'site_up')
    end
  end

  def test_prepare_activation_refuses_unfenced_or_changed_environment
    with_prepare do
      prep = prepared
      plan = prepared_plan(prep)
      # Inspection access that can't be proven closed: nothing is dropped, no merger runs.
      @inspection_failure['close'] = 'STANDARD_MERGE_INSPECTION_FENCE_FAILED'
      before = merge_lines.size
      run = @service.run_plan(plan_id: approve(plan))
      assert_equal 'STANDARD_MERGE_INSPECTION_FENCE_FAILED', run.dig(:failure, 'code')
      assert_equal 'failed', run.dig(:stages, 'activate')
      assert_equal SEALED, @runtime.databases
      refute merge_lines.drop(before).any? { |line| line.match?(%r{DROP DATABASE|ruby /tmp/merge_run\.rb}) }
      assert_equal 'dirty', environment(prep[:run_id])['phase']
      assert_equal 'dirty', run.dig(:merge_environment, 'phase')
      assert_equal 'dirty', instance_state
      standard_error('STANDARD_MERGE_ENVIRONMENT_STALE') { prepared_plan(prep) }
      # The stack's teardown ends the access even when the fence itself keeps failing first.
      @inspection_failure.delete('close')
      assert_equal [@instance], @service.reset_run(run_id: run[:run_id], yes: true)[:removed]
      assert_equal 'reset', environment(prep[:run_id])['phase']
    end
    with_prepare do
      prep = prepared
      # The sealed Base is not what was sealed: the merge must not start from it.
      @runtime.content['silo_clean_base'] = PrepareScriptedRuntime.seal('d')
      run = @service.run_plan(plan_id: approve(prepared_plan(prep)))
      assert_equal 'STANDARD_MERGE_ENVIRONMENT_DIRTY', run.dig(:failure, 'code')
      assert_equal 'failed', run.dig(:stages, 'activate')
      refute index_of(%r{ruby /tmp/merge_run\.rb})
      assert_equal 'dirty', environment(prep[:run_id])['phase']
    end
    with_prepare do
      prep = prepared
      # A stack that isn't running the recorded containers is not the prepared environment.
      @runtime.live_result = ''
      run = @service.run_plan(plan_id: approve(prepared_plan(prep)))
      assert_equal 'STANDARD_MERGE_ENVIRONMENT_DIRTY', run.dig(:failure, 'code')
      assert_equal SEALED, @runtime.databases
      refute @inspection.any? { |call| call[:op] == 'close' }
    end
    with_prepare do
      prep = prepared
      # Inspection may change its own copies freely; the sealed databases are what is merged.
      @runtime.content['discourse'] = PrepareScriptedRuntime.seal('e')
      @runtime.content['silo_inspect_source'] = PrepareScriptedRuntime.seal('f')
      run = @service.run_plan(plan_id: approve(prepared_plan(prep)))
      assert_equal 'completed', run[:status], failure_detail(run)
      assert_equal PrepareScriptedRuntime.seal('a'), @runtime.content['discourse']
    end
  end

  def test_prepare_inspection_failures
    with_prepare do
      @inspection_failure['base'] = 'STANDARD_MERGE_INSPECTION_UNAVAILABLE'
      run = run_prepare
      assert_equal 'STANDARD_MERGE_INSPECTION_UNAVAILABLE', run.dig(:failure, 'code')
      assert_equal 'failed', run.dig(:stages, 'inspection')
      assert_equal 'dirty', run.dig(:merge_environment, 'phase')
      standard_error('STANDARD_MERGE_ENVIRONMENT_STALE') { prepared_plan(run) }
    end
    with_prepare do
      prep = prepared
      # After a recorded backup, missing result inspection is reported, not a failed merge.
      @inspection_failure['result'] = 'STANDARD_MERGE_INSPECTION_UNSUPPORTED'
      run = @service.run_plan(plan_id: approve(prepared_plan(prep)))
      assert_equal 'completed', run[:status], failure_detail(run)
      assert_equal 'unavailable', run.dig(:results, 'merge', 'result_inspection')
      assert run.dig(:artifacts, 'backup')
      assert_equal 'result', run.dig(:merge_environment, 'phase')
    end
  end

  def test_prepare_recover_marks_an_interrupted_environment_dirty
    with_prepare do
      plan = prepare_plan
      claim = @service.claim(plan_id: approve(plan))
      assert_equal({ 'preparation_run_id' => claim[:run_id], 'generation' => nil, 'phase' => 'preparing' }, environment(claim[:run_id]))
      recovered = @service.recover(run_id: claim[:run_id])
      assert_equal 'dirty', recovered.dig(:merge_environment, 'phase')
      assert_equal 'dirty', environment(claim[:run_id])['phase']
    end
  end
end
