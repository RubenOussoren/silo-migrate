# frozen_string_literal: true
require_relative 'test_helper'
require 'silo_migrate/services/standard_oracle'

class StandardOracleTest < SiloMigrateTest
  Oracle = SiloMigrate::Services::StandardOracle

  def setup
    @site = {
      'users' => [{ 'id' => 1, 'username' => 'alice', 'email' => 'alice@example.test', 'import_id' => '1' }],
      'topics' => [{ 'id' => 2, 'title' => 'Topic', 'posts_count' => 1, 'import_id' => '2', 'category_import_id' => '5', 'user' => 'alice', 'created_at' => '2026-01-01T00:00:00Z' }],
      'posts' => [{ 'id' => 3, 'raw' => 'Post body', 'cooked' => '<p>Post body <a class="attachment" href="http://old.test/body">file.txt</a> (12 Bytes)</p>', 'import_id' => '3', 'topic_import_id' => '2', 'user' => 'alice', 'post_number' => 1, 'created_at' => '2026-01-01T00:00:00Z' }],
      'uploads' => [{ 'id' => 4, 'sha1' => 'abc', 'file_sha256' => 'a' * 64, 'local_path_present' => true, 'post_references' => [3], 'original_filename' => 'file.txt', 'filesize' => 12 }],
      'categories' => [{ 'id' => 5, 'name' => 'General', 'slug' => 'general', 'import_id' => '5', 'parent_import_id' => nil }],
      'groups' => [{ 'name' => 'staff', 'users' => ['alice'] }], 'settings' => { 'title' => 'Forum' },
      'custom_fields' => %w[user topic post category].to_h { |kind| ["#{kind}_import_ids", [1]] },
      'versions' => { 'discourse' => '1', 'git' => 'revision', 'ruby' => '3' },
      'runtime' => { 'store_local' => true, 's3' => false, 'disable_emails' => 'yes', 'extensions' => ['vector'], 'pg_version' => '16.1', 'redis_version' => '7.1' }
    }
    @expected = { 'users' => [{ 'user_id' => 1, 'username' => 'alice', 'email' => 'alice@example.test' }],
      'categories' => [{ 'category_id' => 5, 'slug' => 'general', 'parent_category_id' => nil }],
      'topics' => [{ 'topic_id' => 2, 'topic_subject' => 'Topic', 'category_id' => 5, 'user_id' => 1, 'created_at' => '2026-01-01T00:00:00Z' }],
      'posts' => [{ 'post_id' => 3, 'raw' => 'Post body', 'topic_id' => 2, 'post_number' => 1, 'user_id' => 1, 'created_at' => '2026-01-01T00:00:00Z',
        'attachments' => [{ 'attachment_id' => 6, 'file_name' => 'file.txt', 'bytes' => 12 }] }],
      'counts' => %w[users topics posts categories attachments].to_h { |kind| [kind, 1] } }
    @lock = { 'app' => { 'version' => '1', 'revision' => 'revision', 'ruby' => '3', 'required_extensions' => ['vector'], 'postgres_major' => 16, 'redis_major' => 7 } }
  end

  def copy
    Marshal.load(Marshal.dump(@site))
  end

  def imported(site)
    Oracle.imported_failures(@expected, site, attachment_sha256s: ['a' * 64], baseline: { 'users' => [], 'topics' => [], 'posts' => [], 'categories' => [] })
  end

  def test_passing_cases
    assert_empty Oracle.baseline_failures(@site, copy)
    assert_empty imported(copy)
    assert_empty Oracle.runtime_failures(@site, @lock)
    assert_empty Oracle.restored_failures(@site, copy, base_url_map: {})
    assert_empty Oracle.collision_failures(@site, { 'users' => [], 'categories' => [] })
  end

  { 'users' => ['user', 'email'], 'topics' => ['topic', 'title'], 'posts' => ['post', 'raw'], 'uploads' => ['upload', 'filesize'], 'categories' => ['category', 'name'] }.each do |kind, (label, field)|
    define_method("test_baseline_#{label}_missing") do
      changed = copy
      changed[kind].clear
      assert Oracle.baseline_failures(@site, changed).any? { |failure| failure.start_with?("#{label == 'category' ? 'baseline-category' : label}-missing:") }
    end
    define_method("test_baseline_#{label}_changed") do
      changed = copy
      changed[kind][0][field] = 'different'
      assert Oracle.baseline_failures(@site, changed).any? { |failure| failure.start_with?("#{label == 'category' ? 'baseline-category' : label}-changed:") }
    end
  end

  def test_baseline_settings_groups_and_cooked_fail_independently
    [['settings', ->(s) { s['settings']['title'] = 'changed' }, 'baseline-setting-changed:title'],
     ['groups', ->(s) { s['groups'][0]['users'] = [] }, 'baseline-group-members-changed:staff'],
     ['cooked', ->(s) { s['posts'][0]['cooked'] = 'changed' }, 'baseline-post-cooked-changed:3']].each do |_name, mutate, failure|
      changed = copy
      mutate.call(changed)
      assert_includes Oracle.baseline_failures(@site, changed), failure
    end
    changed = copy
    changed['groups'].clear
    assert_includes Oracle.baseline_failures(@site, changed), 'baseline-group-missing:staff'
  end

  %w[users categories topics posts uploads].each do |kind|
    define_method("test_imported_#{kind}_missing") do
      changed = copy
      changed[kind].clear
      expected_label = { 'users' => 'imported-user-missing:1', 'categories' => 'imported-category-missing:5', 'topics' => 'imported-topic-missing:2', 'posts' => 'imported-post-missing:3', 'uploads' => "attachment-missing:#{'a' * 12}" }.fetch(kind)
      assert_includes imported(changed), expected_label
    end
  end

  def test_imported_email_attachment_and_mapping_failures
    changed = copy
    changed['users'][0]['email'] = 'other@example.test'
    assert_includes imported(changed), 'imported-user-email-mismatch:1'
    { 'users' => 'user', 'topics' => 'topic', 'posts' => 'post', 'categories' => 'category' }.each do |kind, singular|
      changed = copy
      changed[kind][0]['import_id'] = '999'
      failures = imported(changed)
      assert_includes failures, "imported-#{singular}-unexpected:999"
      assert_includes failures, "imported-#{singular}-missing:#{@site[kind][0]['import_id']}"
    end
    changed = copy
    changed['uploads'][0]['post_references'] = []
    assert_includes imported(changed), "attachment-unreferenced:#{'a' * 12}"
    changed = copy
    changed['uploads'][0]['local_path_present'] = false
    assert_includes imported(changed), "attachment-file-absent:#{'a' * 12}"
  end

  { 'discourse' => 'version', 'git' => 'revision', 'ruby' => 'ruby' }.each do |field, code|
    define_method("test_runtime_#{code}_mismatch") do
      changed = copy
      changed['versions'][field] = 'wrong'
      assert_includes Oracle.runtime_failures(changed, @lock), "runtime-#{code}-mismatch"
    end
  end

  { 'extensions' => [[], 'extension-missing:vector'], 'pg_version' => ['15.1', 'postgres-mismatch'], 'redis_version' => ['6.1', 'redis-mismatch'],
    'store_local' => [false, 'store-not-local'], 's3' => [true, 'store-not-local'], 'disable_emails' => ['no', 'email-not-disabled'], 'allow_restore' => [true, 'restore-left-enabled'] }.each do |field, (value, code)|
    define_method("test_runtime_#{field}_mismatch") do
      changed = copy
      changed['runtime'][field] = value
      assert_includes Oracle.runtime_failures(changed, @lock), "runtime-#{code}"
    end
  end

  def test_restore_hostname_mapping_and_durable_differences
    changed = copy
    changed['posts'][0]['cooked'].sub!('old.test', 'new.test')
    map = { 'http://old.test' => 'http://new.test' }
    assert_empty Oracle.restored_failures(@site, changed, base_url_map: map)
    assert_includes Oracle.restored_failures(@site, changed, base_url_map: {}), 'restored-post-cooked-changed:3'
    %w[users topics posts uploads groups categories settings custom_fields].each do |kind|
      changed = copy
      changed[kind] = kind == 'settings' || kind == 'custom_fields' ? {} : []
      refute_empty Oracle.restored_failures(@site, changed, base_url_map: map), kind
    end
  end

  { 'users' => { 'username' => 'username', 'email' => 'email' },
    'categories' => { 'slug' => 'slug', 'parent_import_id' => 'parent' },
    'topics' => { 'title' => 'title', 'category_import_id' => 'category', 'user' => 'user', 'created_at' => 'created' },
    'posts' => { 'topic_import_id' => 'topic', 'post_number' => 'number', 'user' => 'user', 'created_at' => 'created', 'cooked' => 'text' }
  }.each do |kind, fields|
    fields.each do |field, label|
      define_method("test_imported_#{kind}_#{label}_mismatch") do
        changed = copy
        changed[kind][0][field] = 'wrong'
        singular = { 'users' => 'user', 'categories' => 'category', 'topics' => 'topic', 'posts' => 'post' }.fetch(kind)
        assert_includes imported(changed), "imported-#{singular}-#{label}-mismatch:#{@site[kind][0]['import_id']}"
      end
    end
  end

  { 'users' => 'user', 'categories' => 'category', 'topics' => 'topic', 'posts' => 'post' }.each do |kind, label|
    define_method("test_extra_import_id_in_#{kind}_is_unexpected") do
      changed = copy
      changed[kind] << changed[kind][0].merge('id' => 999, 'import_id' => '999')
      assert_includes imported(changed), "imported-#{label}-unexpected:999"
      refute imported(changed).any? { |failure| failure.start_with?("imported-#{label}-missing:") }
    end
  end

  def test_swapped_attachment_fails_even_when_still_referenced
    changed = copy
    changed['uploads'][0]['post_references'] = [999]
    assert_includes imported(changed), 'attachment-wrong-post:6'
    refute_includes imported(changed), "attachment-unreferenced:#{'a' * 12}"
  end

  def test_attachment_record_identity_required
    changed = copy
    changed['uploads'][0]['original_filename'] = 'wrong.txt'
    assert_includes imported(changed), 'attachment-record-missing:6'
  end

  def test_full_text_equality_rejects_appended_and_truncated_text
    ['<p>Post body plus unwanted tail</p>', '<p>Post</p>'].each do |cooked|
      changed = copy
      changed['posts'][0]['cooked'] = cooked
      assert_includes imported(changed), 'imported-post-text-mismatch:3'
    end
  end

  %w[users topics posts categories].each do |kind|
    define_method("test_extra_#{kind}_without_import_id_fails_total") do
      changed = copy
      changed[kind] << { 'id' => 999 }
      assert_includes imported(changed), "site-#{kind}-total-mismatch:2!=1"
    end
  end

  { 'users' => 'user', 'categories' => 'category', 'topics' => 'topic', 'posts' => 'post' }.each do |kind, label|
    define_method("test_duplicate_import_ids_in_#{kind}_fail") do
      changed = copy
      changed[kind] << changed[kind][0].merge('id' => 999)
      assert_includes imported(changed), "imported-#{label}-duplicate:#{@site[kind][0]['import_id']}"
      assert_includes imported(changed), "site-#{kind}-total-mismatch:2!=1"
    end
  end

  def add_reply(expected_id, site_id, number, target_id, reply_number)
    @expected['posts'] << @expected['posts'][0].merge('post_id' => expected_id, 'post_number' => number, 'reply_to_post_id' => target_id, 'attachments' => [])
    @site['posts'] << @site['posts'][0].merge('id' => site_id, 'import_id' => expected_id.to_s, 'post_number' => number, 'reply_to_post_number' => reply_number)
    @expected['counts']['posts'] += 1
  end

  def test_reply_to_first_post_has_no_stored_target_but_later_targets_must_match
    add_reply(7, 70, 2, 3, nil)
    assert_empty imported(copy)
    changed = copy
    changed['posts'][1]['reply_to_post_number'] = 1
    assert_includes imported(changed), 'imported-post-reply-mismatch:7'
    add_reply(8, 80, 3, 7, 2)
    assert_empty imported(copy)
    [nil, 1, 3].each do |wrong|
      changed = copy
      changed['posts'][2]['reply_to_post_number'] = wrong
      assert_includes imported(changed), 'imported-post-reply-mismatch:8'
    end
  end

  def test_every_declared_attachment_is_checked_against_its_own_post
    add_reply(7, 70, 2, 3, nil)
    @expected['posts'][1]['attachments'] = [{ 'attachment_id' => 9, 'file_name' => 'second.txt', 'bytes' => 5 }]
    @expected['counts']['attachments'] = 2
    @site['uploads'] << @site['uploads'][0].merge('id' => 99, 'original_filename' => 'second.txt', 'filesize' => 5, 'file_sha256' => 'b' * 64, 'post_references' => [70])
    assert_empty imported(copy)
    changed = copy
    changed['uploads'][0]['post_references'] = [70]
    changed['uploads'][1]['post_references'] = [3]
    assert_includes imported(changed), 'attachment-wrong-post:6'
    assert_includes imported(changed), 'attachment-wrong-post:9'
    changed['uploads'].delete_at(1)
    assert_includes imported(changed), 'attachment-record-missing:9'
  end

  def test_incomplete_attachment_declarations_fail_even_with_legacy_attachment_field
    @expected['attachment'] = @expected['posts'][0]['attachments'][0].merge('post_id' => 3)
    @expected['posts'][0]['attachments'] = []
    assert_includes imported(copy), 'attachment-expectation-incomplete:0!=1'
    @expected['counts']['attachments'] = 0
    @expected['posts'][0]['attachments'] = [@expected['attachment']]
    assert_includes imported(copy), 'attachment-expectation-incomplete:1!=0'
  end

  def test_each_collision_kind_case_insensitive
    cases = [ [{ 'username' => 'ALICE', 'email' => 'new@example.test' }], [{ 'username' => 'new', 'email' => 'ALICE@EXAMPLE.TEST' }] ]
    %w[username email].zip(cases).each do |kind, users|
      assert Oracle.collision_failures(@site, { 'users' => users, 'categories' => [] }).any? { |f| f.start_with?("collision-#{kind}:") }
    end
    [{ 'name' => 'GENERAL', 'slug' => 'other' }, { 'name' => 'other', 'slug' => 'GENERAL' }].each do |category|
      assert Oracle.collision_failures(@site, { 'users' => [], 'categories' => [category] }).any? { |f| f.start_with?('collision-category:') }
    end
  end
end
