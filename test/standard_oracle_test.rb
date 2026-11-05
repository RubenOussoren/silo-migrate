# frozen_string_literal: true
require_relative 'test_helper'
require 'silo_migrate/services/standard_oracle'

class StandardOracleTest < SiloMigrateTest
  Oracle = SiloMigrate::Services::StandardOracle

  def setup
    @site = {
      'users' => [{ 'id' => 1, 'username' => 'alice', 'email' => 'alice@example.test' }],
      'topics' => [{ 'id' => 2, 'title' => 'Topic', 'posts_count' => 1 }],
      'posts' => [{ 'id' => 3, 'raw' => 'Post body', 'cooked' => '<p>Post body <a href="http://old.test/body">link</a></p>' }],
      'uploads' => [{ 'id' => 4, 'sha1' => 'abc', 'file_sha256' => 'a' * 64, 'local_path_present' => true, 'post_references' => [3] }],
      'categories' => [{ 'id' => 5, 'name' => 'General', 'slug' => 'general' }],
      'groups' => [{ 'name' => 'staff', 'users' => ['alice'] }], 'settings' => { 'title' => 'Forum' },
      'custom_fields' => %w[user topic post category].to_h { |kind| ["#{kind}_import_ids", [1]] },
      'versions' => { 'discourse' => '1', 'git' => 'revision', 'ruby' => '3' },
      'runtime' => { 'store_local' => true, 's3' => false, 'disable_emails' => 'yes', 'extensions' => ['vector'], 'pg_version' => '16.1', 'redis_version' => '7.1' }
    }
    @expected = { 'users' => [{ 'username' => 'alice', 'email' => 'alice@example.test' }], 'categories' => [{ 'slug' => 'general' }],
      'topics' => [{ 'topic_id' => 2, 'topic_subject' => 'Topic' }], 'posts' => [{ 'post_id' => 3, 'raw' => 'Post body' }],
      'counts' => %w[users topics posts categories].to_h { |kind| [kind, 1] } }
    @lock = { 'app' => { 'version' => '1', 'revision' => 'revision', 'ruby' => '3', 'required_extensions' => ['vector'], 'postgres_major' => 16, 'redis_major' => 7 } }
  end

  def copy
    Marshal.load(Marshal.dump(@site))
  end

  def imported(site)
    Oracle.imported_failures(@expected, site, attachment_sha256s: ['a' * 64])
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
      refute_empty imported(changed)
    end
  end

  def test_imported_email_attachment_and_mapping_failures
    changed = copy
    changed['users'][0]['email'] = 'other@example.test'
    assert_includes imported(changed), 'imported-user-email-mismatch:alice'
    %w[users topics posts categories].zip(%w[user topic post category]).each do |kind, field|
      changed = copy
      changed['custom_fields']["#{field}_import_ids"] = []
      assert_includes imported(changed), "import-mapping-count-mismatch:#{kind}:0!=1"
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
    'store_local' => [false, 'store-not-local'], 's3' => [true, 'store-not-local'], 'disable_emails' => ['no', 'email-not-disabled'] }.each do |field, (value, code)|
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
