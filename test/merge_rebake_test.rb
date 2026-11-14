# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/merge_settings_runner'

# merge_rebake.rb as finalize runs it (rails runner), in a child Ruby against the fake Rails
# harness plus the stand-ins below for Post and Jobs.
class MergeRebakeTest < SiloMigrateTest
  include MergeSettingsRunner

  REBAKE = File.join(RUNTIME, 'merge_rebake.rb')
  # The host's own completion pattern (stage_finalize).
  MARKER = /\ASILO_MERGE_REBAKE: posts=[0-9]+\z/
  AUTH = SITE.merge('authorized_extensions' => ['pdf|PRIVATE-EXT', 8])
  SECRET = 'PRIVATE-POST-BODY'

  # Post and Jobs as merge_rebake.rb may use them. Anything else it could reach for ends the
  # process with a status no rescue can hide: 96 for running jobs inline or changing image
  # locking, 97 for a site-setting write (the settings harness does the same for its own).
  # Posts come from TEST_POSTS_FILE (JSON, [{id, raw, cooked, baked_version, deleted}]); the final
  # table goes to TEST_POSTS_OUT and every call, in order, to TEST_EVENTS_OUT.
  # Knobs (ENV, a post id unless noted): TEST_REBAKE_FAIL=plain|wrapped at TEST_REBAKE_FAIL_ID,
  # TEST_REBAKE_UNMARKED_ID (rebake leaves no marker), TEST_REBAKE_EXIT_ID (exit 0),
  # TEST_REBAKE_SETTING_ID with TEST_REBAKE_SETTING=other|authorized (a setting changes behind
  # the helper's back), TEST_COUNT_EXTRA (number added to Post.count), TEST_JOBS_INLINE=1,
  # TEST_CORE_NOISE=1 (core prints while cooking), TEST_SETTINGS_UNREADABLE=1 (the settings
  # table can't be read at all) and TEST_REBAKE_UNREADABLE_ID (it can't from that post on).
  POST_HARNESS = <<~'RUBY'
    require "json"

    $silo_posts = JSON.parse(File.read(ENV.fetch("TEST_POSTS_FILE")))
    $silo_events = []
    at_exit do
      File.write(ENV["TEST_POSTS_OUT"], JSON.generate($silo_posts)) if ENV["TEST_POSTS_OUT"]
      File.write(ENV["TEST_EVENTS_OUT"], $silo_events.join("\n")) if ENV["TEST_EVENTS_OUT"]
    end

    $silo_unreadable = ENV["TEST_SETTINGS_UNREADABLE"] == "1"
    ActiveRecord::Base::FakeConnection.prepend(Module.new do
      def select_rows(sql)
        raise ActiveRecord::StatementInvalid, "PRIVATE-QUERY-VALUE" if $silo_unreadable

        super
      end
    end)

    module Jobs
      def self.run_immediately? = ENV["TEST_JOBS_INLINE"] == "1"
      def self.run_immediately! = exit!(96)
      def self.with_immediate_jobs = exit!(96)

      # Queued only: nothing here ever runs a job.
      def self.enqueue(name, opts = {})
        $silo_events << "enqueue #{name} queue=#{opts[:queue]}"
      end
    end

    class OptimizedImage
      def self.lock_per_machine=(_value)
        exit!(96)
      end
    end

    class SiteSetting
      def self.method_missing(name, *args)
        exit!(97) if name.to_s.end_with?("=")
        super
      end

      def self.respond_to_missing?(name, include_private = false) = name.to_s.end_with?("=") || super
    end

    class Post
      BAKED_VERSION = 2

      # The default scope: deleted posts are invisible to every call below.
      def self.visible = $silo_posts.reject { |row| row["deleted"] }

      def self.count
        $silo_events << "count"
        visible.size + Integer(ENV.fetch("TEST_COUNT_EXTRA", "0"))
      end

      def self.update_all(changes)
        raise "unexpected update" unless changes == { baked_version: nil } || changes == "baked_version = NULL"

        $silo_events << "reset"
        visible.each { |row| row["baked_version"] = nil }
        visible.size
      end

      def self.find_each(batch_size:)
        $silo_events << "find_each batch_size=#{batch_size}"
        visible.sort_by { |row| row["id"] }.each_slice(batch_size) do |rows|
          $silo_events << "batch size=#{rows.size}"
          rows.each { |row| yield new(row) }
        end
      end

      Stale = Struct.new(:rows) do
        def exists? = rows.any?
        def count = rows.size
      end

      def self.where(sql, version)
        raise "unexpected query" unless sql.match?(/\bbaked_version IS NULL\b/i) && sql.match?(/\bbaked_version <> \?/) && version == BAKED_VERSION

        $silo_events << "stale-check"
        Stale.new(visible.select { |row| row["baked_version"] != version })
      end

      def initialize(row)
        @row = row
      end

      def rebake!(**opts)
        id = @row["id"].to_s
        $silo_events << "rebake id=#{id} opts=#{opts.inspect}"
        puts "core cooking #{id}" if ENV["TEST_CORE_NOISE"] == "1"
        $silo_unreadable = true if ENV["TEST_REBAKE_UNREADABLE_ID"] == id
        fail_here = ENV["TEST_REBAKE_FAIL_ID"] == id
        raise ArgumentError, "PRIVATE-POST-BODY #{@row["raw"]} post #{id}" if fail_here && ENV["TEST_REBAKE_FAIL"] == "plain"
        if fail_here && ENV["TEST_REBAKE_FAIL"] == "wrapped"
          begin
            raise PG::UndefinedColumn, "PRIVATE-POST-BODY #{@row["raw"]}"
          rescue PG::UndefinedColumn
            raise ActiveRecord::StatementInvalid, "PRIVATE-POST-BODY #{@row["raw"]}"
          end
        end
        exit 0 if ENV["TEST_REBAKE_EXIT_ID"] == id
        if ENV["TEST_REBAKE_SETTING_ID"] == id
          # Like SQL through another connection: the helper is told nothing.
          if ENV["TEST_REBAKE_SETTING"] == "authorized"
            SiteSetting.write_raw("authorized_extensions", "jpg|jpeg|png|gif", 8)
          else
            SiteSetting.write_raw("title", "PRIVATE-CHANGED", 1)
          end
        end

        old = @row["cooked"]
        @row["cooked"] = "<p>#{@row["raw"]}</p>"
        @row["baked_version"] = BAKED_VERSION unless ENV["TEST_REBAKE_UNMARKED_ID"] == id
        Jobs.enqueue(:process_post, post_id: @row["id"], queue: opts[:priority].to_s)
        @row["cooked"] != old
      end
    end
  RUBY

  Run = Struct.new(:out, :err, :status, :db, :posts, :events, keyword_init: true)

  def post(id, cooked: 'old', baked_version: 1, deleted: false)
    { 'id' => id, 'raw' => "#{SECRET} #{id}", 'cooked' => cooked, 'baked_version' => baked_version, 'deleted' => deleted }
  end

  # Three posts: one stale, one already at the current marker, one whose cooked HTML won't change.
  def three_posts
    [post(1), post(2, baked_version: 2), post(3, cooked: "<p>#{SECRET} 3</p>", baked_version: nil)]
  end

  # Runs the helper. The snapshot is captured from `captured` (the site as the host saw it);
  # `db` is the site the helper finds. Site-setting writes are forbidden throughout.
  def rebake(posts: three_posts, db: AUTH, captured: db, env: {})
    Dir.mktmpdir('merge-rebake-') do |dir|
      path, digest, = capture_snapshot(captured, dir)
      harness = File.join(dir, 'post_harness.rb')
      File.write(harness, POST_HARNESS)
      files = %w[db posts events].to_h { |name| [name, File.join(dir, "#{name}.out")] }
      File.write(File.join(dir, 'posts.json'), JSON.generate(posts))
      base = { 'TEST_DB_JSON' => JSON.generate(db), 'TEST_DB_OUT' => files['db'], 'TEST_POSTS_FILE' => File.join(dir, 'posts.json'),
               'TEST_POSTS_OUT' => files['posts'], 'TEST_EVENTS_OUT' => files['events'], 'TEST_SNAPSHOT_FILE' => path,
               'SILO_MERGE_SITE_SETTINGS_SHA256' => digest, 'SILO_MERGE_SITE_SETTINGS_ACTION' => nil,
               'TEST_FORBID_WRITES' => '1' }
      out, err, status = Open3.capture3(base.merge(env), RbConfig.ruby, '-r', HARNESS, '-r', harness, REBAKE)
      read = ->(name) { File.exist?(files[name]) ? File.read(files[name]) : nil }
      Run.new(out: out, err: err, status: status, db: read['db']&.then { |text| JSON.parse(text) },
              posts: read['posts']&.then { |text| JSON.parse(text) }, events: read['events'].to_s.lines.map(&:chomp))
    end
  end

  def rebaked_ids(run)
    run.events.grep(/\Arebake /).map { |event| event[/id=(\d+)/, 1].to_i }
  end

  def assert_done(run, count)
    assert run.status.success?, run.err
    assert_equal "SILO_MERGE_REBAKE: posts=#{count}", run.out.lines.last.chomp
    assert_equal 1, run.out.lines.map(&:chomp).grep(MARKER).size
    assert_empty run.err
  end

  # No completion line, nothing private, and the stored settings exactly as they were found.
  def assert_refused(run, status, err, db: AUTH)
    assert_equal status, run.status.exitstatus
    assert_equal err, run.err
    refute_match(/posts=/, run.out + run.err)
    assert_no_private_values(run)
    assert_equal JSON.parse(JSON.generate(db)), run.db
  end

  def test_no_posts_is_a_completed_rebake
    run = rebake(posts: [])
    assert_done(run, 0)
    assert_equal "SILO_MERGE_REBAKE: posts=0\n", run.out
    assert_equal ['count', 'reset', 'find_each batch_size=1000', 'stale-check'], run.events
  end

  def test_every_post_is_rebaked_with_the_stock_arguments_and_jobs_stay_queued
    run = rebake
    assert_done(run, 3)
    assert_equal "SILO_MERGE_REBAKE: posts=3\n", run.out
    assert_equal ['count', 'reset', 'find_each batch_size=1000', 'batch size=3',
                  'rebake id=1 opts={priority: :ultra_low}', 'enqueue process_post queue=ultra_low',
                  'rebake id=2 opts={priority: :ultra_low}', 'enqueue process_post queue=ultra_low',
                  'rebake id=3 opts={priority: :ultra_low}', 'enqueue process_post queue=ultra_low',
                  'stale-check'], run.events.map { |event| event.sub(':priority=>', 'priority: ') }
    # A current marker beforehand doesn't excuse a post, and unchanged HTML (false) still counts.
    assert_equal [2, 2, 2], run.posts.map { |row| row['baked_version'] }
    assert_equal ["<p>#{SECRET} 1</p>", "<p>#{SECRET} 2</p>", "<p>#{SECRET} 3</p>"], run.posts.map { |row| row['cooked'] }
    assert_equal JSON.parse(JSON.generate(AUTH)), run.db
    assert_no_private_values(run)
  end

  def test_all_posts_are_read_in_batches_and_deleted_posts_are_out_of_scope
    posts = (1..2500).map { |id| post(id) } + [post(9000, baked_version: nil, deleted: true)]
    run = rebake(posts: posts)
    assert_done(run, 2500)
    assert_equal ['batch size=1000', 'batch size=1000', 'batch size=500'], run.events.grep(/\Abatch /)
    assert_equal (1..2500).to_a, rebaked_ids(run)
    assert_equal 2500, run.events.count('enqueue process_post queue=ultra_low')
    assert_operator run.events.index('reset'), :<, run.events.index { |event| event.start_with?('rebake ') }
    deleted = run.posts.last
    assert_equal ['old', nil], [deleted['cooked'], deleted['baked_version']]
  end

  def test_core_output_cannot_displace_the_completion_line
    run = rebake(env: { 'TEST_CORE_NOISE' => '1' })
    assert_done(run, 3)
    assert_equal ['core cooking 1', 'core cooking 2', 'core cooking 3', 'SILO_MERGE_REBAKE: posts=3'], run.out.lines.map(&:chomp)
  end

  def test_first_exception_stops_the_run_and_only_its_class_is_shown
    run = rebake(env: { 'TEST_REBAKE_FAIL' => 'plain', 'TEST_REBAKE_FAIL_ID' => '2' })
    assert_refused(run, 1, "SILO_MERGE_REBAKE: failed (ArgumentError)\n")
    assert_empty run.out
    assert_equal [1, 2], rebaked_ids(run)
    refute_includes run.events, 'stale-check'

    wrapped = rebake(env: { 'TEST_REBAKE_FAIL' => 'wrapped', 'TEST_REBAKE_FAIL_ID' => '1' })
    assert_refused(wrapped, 1, "SILO_MERGE_REBAKE: failed (ActiveRecord::StatementInvalid caused by PG::UndefinedColumn)\n")
    assert_equal [1], rebaked_ids(wrapped)
  end

  def test_a_post_left_without_the_current_marker_is_a_failure
    run = rebake(env: { 'TEST_REBAKE_UNMARKED_ID' => '2' })
    assert_refused(run, 1, "SILO_MERGE_REBAKE: failed (SiloMergeRebake::StalePosts)\n")
    assert_equal [1, 2, 3], rebaked_ids(run)
  end

  def test_a_different_number_of_posts_than_counted_is_a_failure
    [1, -1].each do |extra|
      run = rebake(env: { 'TEST_COUNT_EXTRA' => extra.to_s })
      assert_refused(run, 1, "SILO_MERGE_REBAKE: failed (SiloMergeRebake::CountMismatch)\n")
    end
  end

  def test_inline_jobs_are_refused_before_any_post_is_touched
    posts = three_posts
    run = rebake(posts: posts, env: { 'TEST_JOBS_INLINE' => '1' })
    assert_refused(run, 1, "SILO_MERGE_REBAKE: failed (SiloMergeRebake::InlineJobs)\n")
    assert_empty run.events
    assert_equal posts, run.posts
  end

  def test_an_early_successful_exit_is_not_completion
    run = rebake(env: { 'TEST_REBAKE_EXIT_ID' => '2' })
    assert_refused(run, 1, "SILO_MERGE_REBAKE: failed (early-exit)\n")
    assert_equal [1, 2], rebaked_ids(run)
  end

  def test_settings_that_differ_beforehand_refuse_the_rebake_and_are_not_repaired
    posts = three_posts
    { 'another setting' => AUTH.merge('title' => ['PRIVATE-CHANGED', 1]),
      'the stock assignment still in place' => AUTH.merge('authorized_extensions' => ['jpg|jpeg|png|gif', 8]),
      'an override where there was none' => nil }.each do |label, db|
      captured = db ? AUTH : SITE
      db ||= SITE.merge('authorized_extensions' => ['jpg|jpeg|png|gif', 8])
      run = rebake(posts: posts, db: db, captured: captured)
      assert_refused(run, 4, "SILO_MERGE_REBAKE: settings changed-before-rebake\n", db: db)
      assert_empty run.out, label
      assert_empty run.events, label
      assert_equal posts, run.posts, label
    end
  end

  def test_settings_changed_during_the_rebake_are_reported_and_not_repaired
    { 'other' => AUTH.merge('title' => ['PRIVATE-CHANGED', 1]),
      'authorized' => AUTH.merge('authorized_extensions' => ['jpg|jpeg|png|gif', 8]) }.each do |kind, after|
      run = rebake(env: { 'TEST_REBAKE_SETTING_ID' => '2', 'TEST_REBAKE_SETTING' => kind })
      assert_refused(run, 4, "SILO_MERGE_REBAKE: settings changed-by-rebake\n", db: after)
      assert_empty run.out
      assert_equal [1, 2, 3], rebaked_ids(run)
    end
  end

  def test_a_failure_does_not_hide_a_changed_setting_or_the_other_way_round
    run = rebake(env: { 'TEST_REBAKE_SETTING_ID' => '1', 'TEST_REBAKE_SETTING' => 'other',
                        'TEST_REBAKE_FAIL' => 'plain', 'TEST_REBAKE_FAIL_ID' => '2' })
    assert_refused(run, 4, "SILO_MERGE_REBAKE: failed (ArgumentError)\nSILO_MERGE_REBAKE: settings changed-by-rebake\n",
                   db: AUTH.merge('title' => ['PRIVATE-CHANGED', 1]))
    assert_equal [1, 2], rebaked_ids(run)
  end

  # Unreadable settings are never called clean, and never called changed either.
  def test_settings_that_cannot_be_read_are_unproven
    posts = three_posts
    before = rebake(posts: posts, env: { 'TEST_SETTINGS_UNREADABLE' => '1' })
    assert_refused(before, 4, "SILO_MERGE_REBAKE: settings unproven-before-rebake\n")
    assert_empty before.events
    assert_equal posts, before.posts

    after = rebake(env: { 'TEST_REBAKE_UNREADABLE_ID' => '3' })
    assert_refused(after, 4, "SILO_MERGE_REBAKE: settings unproven-after-rebake\n")
    assert_equal [1, 2, 3], rebaked_ids(after)

    failed = rebake(env: { 'TEST_REBAKE_UNREADABLE_ID' => '1', 'TEST_REBAKE_FAIL' => 'plain', 'TEST_REBAKE_FAIL_ID' => '2' })
    assert_refused(failed, 1, "SILO_MERGE_REBAKE: failed (ArgumentError)\n")
  end

  def test_without_the_bound_snapshot_nothing_runs
    posts = three_posts
    { 'snapshot-digest-missing' => { 'SILO_MERGE_SITE_SETTINGS_SHA256' => nil },
      'snapshot-digest-mismatch' => { 'SILO_MERGE_SITE_SETTINGS_SHA256' => 'a' * 64 },
      'snapshot-missing' => { 'TEST_SNAPSHOT_FILE' => '/nonexistent/site-settings.json' } }.each do |tag, env|
      run = rebake(posts: posts, env: env)
      assert_refused(run, 4, "SILO_MERGE_REBAKE: settings #{tag}\n")
      assert_empty run.events
      assert_equal posts, run.posts
    end
  end

  # The settings helper's own standalone mode must not take over when its action is set.
  def test_the_settings_helper_is_loaded_as_a_library_only
    run = rebake(env: { 'SILO_MERGE_SITE_SETTINGS_ACTION' => 'capture' })
    assert_done(run, 3)
    refute_includes run.out, 'SILO_SETTINGS_SNAPSHOT'
  end

  def test_the_helper_names_no_setting_write_inline_jobs_or_stock_task
    code = File.read(REBAKE).lines.reject { |line| line.lstrip.start_with?('#') }.join
    refute_match(/(?<![A-Za-z])SiteSetting\b/, code)
    refute_match(/run_immediately!|with_immediate_jobs|lock_per_machine|Rake|posts:rebake|prepend|alias|define_method/, code)
    assert_equal 1, code.scan('rebake!').size
    assert_includes code, 'post.rebake!(priority: :ultra_low)'
  end
end
