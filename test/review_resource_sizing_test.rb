# frozen_string_literal: true
require_relative 'test_helper'
require 'json'
require 'silo_migrate/services/standard_workflow_service'

# Host/input-aware review sizing and the stack's plan-bound DB settings and Sidekiq
# switch. Invented host capacities and scripted commands only; no Docker or host reads.
class ReviewResourceSizingTest < Minitest::Test
  PROFILE = Dir[File.expand_path('../runtime/profiles/*.json', __dir__)].min
  GIB = 1024**3

  class Sizer
    include SiloMigrate::Services::StandardReviewRun
    attr_reader :lock
    public :review_limits, :review_capacity!, :review_restore_timeout

    def initialize(lock, cpus, memory_mib)
      @lock = lock
      @capacity = [cpus, memory_mib]
    end

    def host_capacity
      @capacity
    end

    def measured_usage
      [0.0, 0]
    end
  end

  class Recorder
    attr_reader :calls

    def initialize
      @calls = []
    end

    def run(cmd, **_options)
      @calls << cmd
      ok = lambda { |out = ''| SiloMigrate::Runtime::CommandResult.new(success?: true, stdout: out, stderr: '', status: 0) }
      if cmd[1..].include?('inspect')
        SiloMigrate::Runtime::CommandResult.new(success?: false, stdout: '', stderr: 'Error: No such object', status: 1)
      elsif cmd[0, 2] == %w[docker run]
        ok.call("#{Digest::SHA256.hexdigest(cmd.join(' '))}\n")
      elsif cmd.include?('curl')
        ok.call('200')
      else
        ok.call
      end
    end

    def role(name)
      @calls.find { |cmd| cmd[0, 2] == %w[docker run] && cmd.include?("silomig-test-#{name}") }
    end
  end

  def lock
    @lock ||= JSON.parse(File.read(PROFILE))
  end

  def sizer(cpus, gib)
    Sizer.new(lock, cpus, gib * 1024)
  end

  def legacy(cpus, gib)
    sizer(cpus, gib).review_limits
  end

  def test_small_input_and_default_keep_legacy_sizing
    [[4, 128], [8, 128], [2, 8], [1, 2]].each do |cpus, gib|
      assert_equal legacy(cpus, gib), sizer(cpus, gib).review_limits(input_bytes: GIB - 1)
      assert_equal legacy(cpus, gib), sizer(cpus, gib).review_limits(input_bytes: 0)
    end
    limits = legacy(8, 128)
    assert_equal({ 'cpus' => 2.0, 'memory_mib' => 4096, 'pids' => 128 }, limits['db'])
    assert_equal({ 'cpus' => 2.0, 'memory_mib' => 6144, 'pids' => 512 }, limits['web'])
  end

  def test_large_input_on_128_gib_hosts_with_4_or_8_cpus
    four = sizer(4, 128).review_limits(input_bytes: 2 * GIB)
    assert_equal({ 'cpus' => 2.0, 'memory_mib' => 16_384, 'pids' => 128, 'restore_timeout_seconds' => 7200,
                   'shared_buffers_mib' => 4096, 'maintenance_work_mem_mib' => 1024, 'shm_mib' => 2048 }, four['db'])
    assert_equal({ 'cpus' => 2.0, 'memory_mib' => 8192, 'pids' => 512 }, four['web'])
    eight = sizer(8, 128).review_limits(input_bytes: 2 * GIB)
    assert_equal 4.0, eight.dig('db', 'cpus')
    assert_equal 2.0, eight.dig('web', 'cpus')
    # Larger archives grow the database, up to 32 GiB.
    huge = sizer(8, 128).review_limits(input_bytes: 20 * GIB)
    assert_equal 32_768, huge.dig('db', 'memory_mib')
    assert_equal 8192, huge.dig('db', 'shared_buffers_mib')
    assert_equal 2048, huge.dig('db', 'maintenance_work_mem_mib')
    assert_equal 4096, huge.dig('db', 'shm_mib')
    [four, eight, huge].each do |limits|
      # Headroom: no quota is the whole 4-CPU host's worth for the DB, memory fits the admission share.
      assert_operator limits.values.sum { |limit| limit['memory_mib'] }, :<=, 128 * 1024 / 2
      assert_equal lock.dig('limits', 'stack', 'redis').slice('cpus', 'memory_mib', 'pids'), limits['redis']
      sizer(4, 128).review_capacity!(limits, running: false)
    end
    assert_operator four.dig('db', 'cpus'), :<, 4
  end

  def test_large_plan_shm_leaves_parallel_index_build_headroom
    # Invented compressed sizes, including a non-round size between the tiers.
    # A maintenance-sized shm mount leaves little room for DSM metadata/other segments.
    [32, 64, 128, 256].each do |gib|
      [4, 8].each do |cpus|
        [GIB, 2 * GIB, 5 * GIB + 1_234_567, 20 * GIB].each do |bytes|
          db = sizer(cpus, gib).review_limits(input_bytes: bytes).fetch('db')
          assert_equal 2 * db.fetch('maintenance_work_mem_mib'), db.fetch('shm_mib')
          assert_operator db.fetch('shm_mib') - db.fetch('maintenance_work_mem_mib'), :>=, 512
          assert_operator db.fetch('shm_mib'), :<=, db.fetch('memory_mib') / 8
          assert_operator db.fetch('shm_mib'), :<=, 4096
          args = create(limits: sizer(cpus, gib).review_limits(input_bytes: bytes)).role('db')
          assert_equal "#{db.fetch('shm_mib')}m", args[args.index('--shm-size') + 1]
        end
      end
    end
  end

  def test_large_input_on_small_hosts_keeps_small_sizing_but_longer_restore
    [[2, 128], [8, 16], [1, 2]].each do |cpus, gib|
      limits = sizer(cpus, gib).review_limits(input_bytes: 5 * GIB)
      expected = legacy(cpus, gib)
      expected['db'] = expected['db'].merge('restore_timeout_seconds' => 7200)
      assert_equal expected, limits
    end
    # A 32 GiB host is large enough, but its quarter-host cap bounds the DB.
    limits = sizer(4, 32).review_limits(input_bytes: 5 * GIB)
    assert_equal 8192, limits.dig('db', 'memory_mib')
    assert_equal 6144, limits.dig('web', 'memory_mib') # never below the small sizing
    sizer(4, 32).review_capacity!(limits, running: false)
  end

  def test_profile_minima_are_preserved
    lock.dig('limits', 'stack', 'db')['memory_mib'] = 40_000
    lock.dig('limits', 'stack', 'db')['cpus'] = 3.0
    limits = sizer(4, 128).review_limits(input_bytes: 2 * GIB)
    assert_equal 40_000, limits.dig('db', 'memory_mib')
    assert_equal 3.0, limits.dig('db', 'cpus')
    assert_equal 8192, limits.dig('db', 'shared_buffers_mib')
  end

  def test_insufficient_capacity_still_refused
    limits = sizer(8, 128).review_limits(input_bytes: 20 * GIB)
    error = assert_raises(SiloMigrate::StandardWorkflowError) { sizer(2, 32).review_capacity!(limits, running: false) }
    assert_equal 'STANDARD_CAPACITY', error.code
  end

  def test_restore_timeout_defaults_for_old_plans
    service = sizer(4, 128)
    assert_equal 1200, service.review_restore_timeout(legacy(4, 128))
    assert_equal 1200, service.review_restore_timeout(nil)
    assert_equal 7200, service.review_restore_timeout(service.review_limits(input_bytes: 2 * GIB))
    assert_equal 1200, service.review_restore_timeout('db' => { 'restore_timeout_seconds' => 99_999 })
    assert_equal 1200, service.review_restore_timeout('db' => { 'restore_timeout_seconds' => '7200' })
  end

  def create(limits: nil, extra_env: {}, runtime: Recorder.new)
    selected = JSON.parse(JSON.generate(lock))
    selected.fetch('images').each_value { |image| image['id'] = image.fetch('content_id') }
    selected.fetch('limits')['stack'] = limits if limits
    stack = SiloMigrate::Services::PrebuiltStack.new(runtime: runtime, lock: selected, name: 'silomig-test', sleeper: ->(_s) {})
    stack.create!(hostname: '127.0.0.1', port: 18_080, env_file: '/dev/null', extra_env: extra_env)
    runtime
  end

  def test_stack_defaults_are_unchanged
    runtime = create
    db = runtime.role('db')
    assert_includes db, 'DB_SHARED_BUFFERS=128MB'
    assert_includes db, 'DB_WORK_MEM=8MB'
    assert_equal '128m', db[db.index('--shm-size') + 1]
    assert_equal lock.dig('images', 'db', 'content_id'), db.last # image's own command
    web = runtime.role('web')
    assert_equal ['UNICORN_SIDEKIQS=1'], web.grep(/UNICORN_SIDEKIQS/)
    assert_includes web, 'UNICORN_WORKERS=1'
  end

  def test_stack_forwards_plan_bound_db_settings
    limits = Sizer.new(lock, 8, 128 * 1024).review_limits(input_bytes: 20 * GIB)
    runtime = create(limits: limits)
    db = runtime.role('db')
    assert_equal '32768m', db[db.index('--memory') + 1]
    assert_equal '4.0', db[db.index('--cpus') + 1]
    assert_includes db, 'DB_SHARED_BUFFERS=8192MB'
    assert_equal '4096m', db[db.index('--shm-size') + 1]
    assert_includes db, 'DB_WORK_MEM=8MB' # work_mem stays conservative
    assert_equal [lock.dig('images', 'db', 'content_id'), 'postgres', '-c', 'maintenance_work_mem=2048MB'], db.last(4)
    refute db.any? { |arg| arg.match?(/wal|fsync|synchronous/i) }
    web = runtime.role('web')
    assert_equal '8192m', web[web.index('--memory') + 1]
  end

  def test_stack_honors_previously_bound_equal_memory_plan
    limits = sizer(8, 128).review_limits(input_bytes: 2 * GIB)
    limits['db']['shm_mib'] = 1024 # saved before headroom was added; never rewrite it
    db = create(limits: limits).role('db')
    assert_equal '1024m', db[db.index('--shm-size') + 1]
    assert_equal %w[postgres -c maintenance_work_mem=1024MB], db.last(3)
  end

  def test_stack_refuses_unbounded_db_settings
    [{ 'shared_buffers_mib' => 99_999 }, { 'shared_buffers_mib' => '8GB' }, { 'shared_buffers_mib' => 1024 },
     { 'maintenance_work_mem_mib' => '1GB; DROP' }, { 'maintenance_work_mem_mib' => 4096 },
     { 'shm_mib' => 4096 }, { 'shm_mib' => '1g' }, { 'shm_mib' => 512 }].each do |extra|
      limits = JSON.parse(JSON.generate(lock.dig('limits', 'stack')))
      limits['db'].merge!(extra)
      error = assert_raises(SiloMigrate::StandardWorkflowError) { create(limits: limits) }
      assert_equal 'STANDARD_STACK_FAILED', error.code
    end
  end

  def test_stack_shm_cap_and_memory_share_still_refuse_before_creation
    limits = sizer(8, 256).review_limits(input_bytes: 20 * GIB)
    # Enough DB memory for the share; test the absolute cap independently.
    limits['db']['memory_mib'] = 128 * 1024
    positive = create(limits: limits).role('db')
    assert_equal '4096m', positive[positive.index('--shm-size') + 1]
    [4097, 8192].each do |shm|
      limits['db']['shm_mib'] = shm
      runtime = Recorder.new
      error = assert_raises(SiloMigrate::StandardWorkflowError) { create(limits: limits, runtime: runtime) }
      assert_equal 'STANDARD_STACK_FAILED', error.code
      assert_includes error.message, 'db settings'
      assert_empty runtime.calls
    end
    limits = sizer(8, 128).review_limits(input_bytes: 2 * GIB)
    limits['db']['shm_mib'] = 4096 # within absolute cap, above this DB's one-eighth share
    runtime = Recorder.new
    error = assert_raises(SiloMigrate::StandardWorkflowError) { create(limits: limits, runtime: runtime) }
    assert_equal 'STANDARD_STACK_FAILED', error.code
    assert_includes error.message, 'db settings'
    assert_empty runtime.calls
  end

  def test_stack_sidekiqs_switch_is_validated
    web = create(extra_env: { 'UNICORN_SIDEKIQS' => '0', 'DISCOURSE_LOGIN_REQUIRED' => 'true' }).role('web')
    assert_equal ['UNICORN_SIDEKIQS=0'], web.grep(/UNICORN_SIDEKIQS/)
    assert_includes web, 'DISCOURSE_LOGIN_REQUIRED=true'
    assert_equal ['UNICORN_SIDEKIQS=1'], create(extra_env: { 'UNICORN_SIDEKIQS' => '1' }).role('web').grep(/UNICORN_SIDEKIQS/)
    ['2', '-1', '0; sh', '', 'yes'].each do |value|
      error = assert_raises(SiloMigrate::StandardWorkflowError) { create(extra_env: { 'UNICORN_SIDEKIQS' => value }) }
      assert_equal 'STANDARD_STACK_FAILED', error.code
    end
    [{ 'lower' => 'x' }, { 'A=B' => 'x' }, { 'DISCOURSE_X' => "a\nB=c" }].each do |env|
      error = assert_raises(SiloMigrate::StandardWorkflowError) { create(extra_env: env) }
      assert_equal 'STANDARD_STACK_FAILED', error.code
    end
    # Refused before any Docker resource is created.
    runtime = Recorder.new
    stack = SiloMigrate::Services::PrebuiltStack.new(runtime: runtime, lock: lock, name: 'silomig-test', sleeper: ->(_s) {})
    assert_raises(SiloMigrate::StandardWorkflowError) do
      stack.create!(hostname: '127.0.0.1', port: 18_080, env_file: '/dev/null', extra_env: { 'UNICORN_SIDEKIQS' => '2' })
    end
    assert_empty runtime.calls
  end
end
