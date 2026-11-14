# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/merge_settings_runner'

# merge_site_settings.rb as the host runs it (rails runner with an action): capture, verify and
# the host's fallback restore after a failed or killed merge.
class MergeSiteSettingsTest < SiloMigrateTest
  include MergeSettingsRunner

  AUTH = SITE.merge('authorized_extensions' => ['pdf|PRIVATE-EXT', 8])

  def action(name, db:, snapshot:, dir:, env: {})
    path, digest = snapshot
    helper_child(HELPER, db: db, dir: dir, env: { 'SILO_MERGE_SITE_SETTINGS_ACTION' => name, 'TEST_SNAPSHOT_FILE' => path,
                                                 'SILO_MERGE_SITE_SETTINGS_SHA256' => digest }.merge(env))
  end

  # The stored table as the merger's constructor leaves it, timestamps and all.
  def after_stock_assignment(db)
    db.merge('authorized_extensions' => ['jpg|jpeg|png|gif', 8])
  end

  def test_capture_lists_every_stored_row_and_the_effective_value_exactly
    Dir.mktmpdir do |dir|
      [SITE, AUTH].each do |db|
        path, = capture_snapshot(db, dir)
        snapshot = JSON.parse(File.binread(path))
        assert_equal %w[authorized_extensions_effective settings version], snapshot.keys.sort
        assert_equal 1, snapshot['version']
        assert_equal JSON.parse(JSON.generate(db.sort.to_h)), snapshot['settings']
        if db.key?('authorized_extensions')
          assert_equal 'pdf|PRIVATE-EXT', snapshot['authorized_extensions_effective']
        else
          assert_equal 'jpg|jpeg|png|gif|heic|heif|webp|avif', snapshot['authorized_extensions_effective']
        end
        assert_equal 1, File.binread(path).lines.size
      end
    end
  end

  def test_verify_is_clean_only_for_the_exact_state
    Dir.mktmpdir do |dir|
      snapshot = capture_snapshot(AUTH, dir)
      clean = action('verify', db: AUTH, snapshot: snapshot, dir: dir)
      assert clean.status.success?, clean.err
      assert_equal 'clean', clean.report['state']
      assert_empty clean.err

      { 'title' => SITE.merge('title' => ['x', 1]).merge('authorized_extensions' => AUTH['authorized_extensions']),
        'null_value' => AUTH.merge('null_value' => ['', 1]),
        'max_attachment_size_kb' => AUTH.merge('max_attachment_size_kb' => ['4096', 1]),
        'added' => AUTH.merge('added' => ['v', 1]),
        'empty_value' => AUTH.reject { |name, _| name == 'empty_value' } }.each do |name, db|
        dirty = action('verify', db: db, snapshot: snapshot, dir: dir)
        assert_equal 4, dirty.status.exitstatus
        assert_equal "SILO_SETTINGS_ERROR: settings-changed\n", dirty.err
        assert_equal({ 'version' => 1, 'state' => 'dirty', 'restoration_failed' => [], 'unexpected_names' => [name],
                       'remaining_differences' => 1, 'effective_matches' => true }, dirty.report)
        assert_no_private_values(dirty)
      end

      # The allowed setting, even at the stock value, is not clean outside the copy.
      stock = action('verify', db: after_stock_assignment(AUTH), snapshot: snapshot, dir: dir)
      assert_equal 'dirty', stock.report['state']
      assert_equal ['authorized_extensions'], stock.report['restoration_failed']
      assert_equal false, stock.report['effective_matches']
    end
  end

  def test_host_fallback_restore_puts_back_presence_or_absence_and_nothing_else
    Dir.mktmpdir do |dir|
      [SITE, AUTH].each do |db|
        snapshot = capture_snapshot(db, dir)
        result = action('restore', db: after_stock_assignment(db), snapshot: snapshot, dir: dir)
        assert result.status.success?, result.err
        assert_equal({ 'version' => 1, 'state' => 'restored', 'restoration_failed' => [], 'unexpected_names' => [],
                       'remaining_differences' => 0, 'effective_matches' => true }, result.report)
        assert_equal db.sort.to_h, stored(result).sort.to_h
        refute_includes result.out, 'PRIVATE'
      end
    end
  end

  def test_restore_never_repairs_another_setting
    Dir.mktmpdir do |dir|
      snapshot = capture_snapshot(AUTH, dir)
      db = after_stock_assignment(AUTH).merge('title' => ['PRIVATE-CHANGED', 1])
      result = action('restore', db: db, snapshot: snapshot, dir: dir)
      assert_equal 4, result.status.exitstatus
      assert_equal "SILO_SETTINGS_ERROR: restore-unproven\n", result.err
      assert_equal 'unproven', result.report['state']
      assert_equal ['title'], result.report['unexpected_names']
      assert_equal ['PRIVATE-CHANGED', 1], stored(result)['title']
      assert_equal AUTH['authorized_extensions'], stored(result)['authorized_extensions']
      assert_no_private_values(result)
    end
  end

  def test_restore_of_an_untouched_site_writes_nothing
    Dir.mktmpdir do |dir|
      snapshot = capture_snapshot(AUTH, dir)
      result = action('restore', db: AUTH, snapshot: snapshot, dir: dir, env: { 'TEST_FAIL_RESTORE' => '1' })
      assert result.status.success?, result.err
      assert_equal 'restored', result.report['state']
    end
  end

  # The host couldn't confirm the merge process stopped: restore reads and reports, never writes.
  def test_uncertain_execution_restore_only_reads_and_is_never_restored
    uncertain = { 'SILO_MERGE_SITE_SETTINGS_EXECUTION_UNCERTAIN' => '1', 'TEST_FORBID_WRITES' => '1' }
    Dir.mktmpdir do |dir|
      [SITE, AUTH].each do |db|
        snapshot = capture_snapshot(db, dir)
        cases = {
          after_stock_assignment(db) => { 'restoration_failed' => ['authorized_extensions'], 'unexpected_names' => [],
                                          'remaining_differences' => 1, 'effective_matches' => false },
          after_stock_assignment(db).merge('title' => ['PRIVATE-CHANGED', 1]) =>
            { 'restoration_failed' => ['authorized_extensions'], 'unexpected_names' => ['title'],
              'remaining_differences' => 2, 'effective_matches' => false },
          db => { 'restoration_failed' => [], 'unexpected_names' => [], 'remaining_differences' => 0, 'effective_matches' => true }
        }
        cases.each do |current, expected|
          result = action('restore', db: current, snapshot: snapshot, dir: dir, env: uncertain)
          assert_equal 4, result.status.exitstatus, result.err
          assert_equal "SILO_SETTINGS_ERROR: restore-unproven\n", result.err
          assert_equal({ 'version' => 1, 'state' => 'unproven' }.merge(expected), result.report)
          assert_untouched(result, current)
          assert_no_private_values(result)
        end
      end
      # Any other value is not the flag: the stock value is put back as usual.
      snapshot = capture_snapshot(AUTH, dir)
      result = action('restore', db: after_stock_assignment(AUTH), snapshot: snapshot, dir: dir,
                                 env: { 'SILO_MERGE_SITE_SETTINGS_EXECUTION_UNCERTAIN' => '0' })
      assert result.status.success?, result.err
      assert_untouched(result, AUTH)
    end
  end

  # In one process: a read warms ActiveRecord's query cache, then the table changes behind it.
  # The read-only restore still reports the table as it is.
  def test_read_only_restore_reads_the_table_not_a_warm_cache
    Dir.mktmpdir do |dir|
      path, digest = capture_snapshot(AUTH, dir)
      script = File.join(dir, 'warm.rb')
      File.write(script, <<~RUBY)
        SILO_MERGE_RUNNER = true
        require #{HELPER.dump}
        snapshot = SiloMergeSiteSettings.load_snapshot
        raise 'not clean' unless SiloMergeSiteSettings.verify(snapshot)['state'] == 'clean'
        SiteSetting.write_raw('authorized_extensions', 'jpg|jpeg|png|gif', 8)
        SiteSetting.write_raw('title', 'PRIVATE-RAW', 1)
        puts 'SILO_SETTINGS_REPORT:' + JSON.generate(SiloMergeSiteSettings.restore(snapshot, allow_write: false))
      RUBY
      result = helper_child(script, db: AUTH, dir: dir, env: { 'TEST_SNAPSHOT_FILE' => path, 'SILO_MERGE_SITE_SETTINGS_SHA256' => digest,
                                                               'TEST_FORBID_WRITES' => '1' })
      assert result.status.success?, result.err
      assert_equal({ 'version' => 1, 'state' => 'unproven', 'restoration_failed' => ['authorized_extensions'],
                     'unexpected_names' => ['title'], 'remaining_differences' => 2, 'effective_matches' => true }, result.report)
      assert_equal ['jpg|jpeg|png|gif', 8], result.db['authorized_extensions']
    end
  end

  def test_actions_refuse_with_fixed_tags_only
    Dir.mktmpdir do |dir|
      path, digest = capture_snapshot(AUTH, dir)
      tampered = File.join(dir, 'tampered.json')
      File.binwrite(tampered, File.binread(path).sub('pdf|PRIVATE-EXT', 'exe'))
      invalid = File.join(dir, 'invalid.json')
      File.binwrite(invalid, '{"version":1,"settings":{"a":["PRIVATE",1]}}')
      extra = File.join(dir, 'extra.json')
      File.binwrite(extra, File.binread(path).sub('{"version":1,', '{"version":1,"rows":{},'))
      broken = File.join(dir, 'broken.json')
      File.binwrite(broken, '{PRIVATE')
      cases = {
        'snapshot-digest-missing' => [path, nil],
        'snapshot-missing' => [File.join(dir, 'absent.json'), digest],
        'snapshot-digest-mismatch' => [tampered, digest],
        'snapshot-invalid' => [invalid, Digest::SHA256.file(invalid).hexdigest]
      }
      cases['snapshot-invalid '] = [broken, Digest::SHA256.file(broken).hexdigest]
      cases['snapshot-invalid  '] = [extra, Digest::SHA256.file(extra).hexdigest]
      cases.each do |tag, snapshot|
        %w[restore verify].each do |name|
          result = action(name, db: AUTH, snapshot: snapshot, dir: dir)
          assert_equal 4, result.status.exitstatus
          assert_equal "SILO_SETTINGS_ERROR: #{tag.strip}\n", result.err
          assert_empty result.out
          assert_equal AUTH.sort.to_h, stored(result).sort.to_h
        end
      end
      bad = action('repair', db: AUTH, snapshot: [path, digest], dir: dir)
      assert_equal 4, bad.status.exitstatus
      assert_equal "SILO_SETTINGS_ERROR: action-invalid\n", bad.err
    end
  end
end
