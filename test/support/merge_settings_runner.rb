# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# Runs merge_run.rb / merge_site_settings.rb in a child Ruby against the fake Rails harness.
module MergeSettingsRunner
  RUNTIME = File.expand_path('../../runtime/prebuilt-discourse', __dir__)
  RUNNER = File.join(RUNTIME, 'merge_run.rb')
  HELPER = File.join(RUNTIME, 'merge_site_settings.rb')
  HARNESS = File.expand_path('merge_settings_harness.rb', __dir__)
  # Stored rows a site might have; values are private and must never be printed.
  SITE = {
    'title' => ['PRIVATE-TITLE ünïcødé ✓', 1],
    'site_description' => ["PRIVATE line one\nline 'two' | \"three\"", 1],
    'max_attachment_size_kb' => ['4096', 3],
    'empty_value' => ['', 1],
    'null_value' => [nil, 1]
  }.freeze

  Result = Struct.new(:out, :err, :status, :db, :report, keyword_init: true)

  def helper_child(script, db:, env: {}, dir:)
    out_path = File.join(dir, "db-#{rand(1 << 30)}.json")
    base = { 'TEST_DB_JSON' => JSON.generate(db), 'TEST_DB_OUT' => out_path, 'SILO_MERGE_SITE_SETTINGS_ACTION' => nil,
             'SILO_MERGE_SITE_SETTINGS_SHA256' => nil, 'TEST_SNAPSHOT_FILE' => nil, 'SILO_MERGE_LAYER' => nil,
             'SILO_MERGE_REQUIRE_CHECKS' => nil, 'DB_NAME' => 'merge_source' }
    out, err, status = Open3.capture3(base.merge(env), RbConfig.ruby, '-r', HARNESS, script)
    db_after = File.exist?(out_path) ? JSON.parse(File.read(out_path)) : nil
    reports = out.lines.grep(/\ASILO_SETTINGS_REPORT:/)
    report = reports.size == 1 ? JSON.parse(reports.first.sub('SILO_SETTINGS_REPORT:', '')) : nil
    Result.new(out: out, err: err, status: status, db: db_after, report: report)
  end

  # The host's step: capture through the helper, keep the bytes, name their digest.
  def capture_snapshot(db, dir)
    result = helper_child(HELPER, db: db, env: { 'SILO_MERGE_SITE_SETTINGS_ACTION' => 'capture' }, dir: dir)
    raise "capture failed: #{result.err}" unless result.status.success?

    line = result.out.lines.grep(/\ASILO_SETTINGS_SNAPSHOT:/)
    raise 'one snapshot line expected' unless line.size == 1

    json = line.first.chomp.sub('SILO_SETTINGS_SNAPSHOT:', '')
    path = File.join(dir, 'site-settings.json')
    File.binwrite(path, json)
    [path, Digest::SHA256.hexdigest(json), result.db]
  end

  def run_merge(db: SITE, layer: nil, required: true, env: {}, snapshot: :capture)
    Dir.mktmpdir('merge-settings-') do |dir|
      path, digest, = capture_snapshot(db, dir) if snapshot == :capture
      run_env = { 'TEST_SNAPSHOT_FILE' => path, 'SILO_MERGE_SITE_SETTINGS_SHA256' => digest,
                  'SILO_MERGE_REQUIRE_CHECKS' => required ? '1' : nil }
      run_env.merge!(snapshot) if snapshot.is_a?(Hash)
      if layer
        entry = File.join(dir, 'layer.rb')
        File.write(entry, layer)
        run_env['SILO_MERGE_LAYER'] = entry
      end
      helper_child(RUNNER, db: db, env: run_env.merge(env), dir: dir)
    end
  end

  def checked_layer(body = '')
    <<~RUBY
      class InventedLayer < BulkImport::DiscourseMerger
        def self.silo_merge_preflight!
          puts 'EVENT:preflight'
          true
        end
        def self.silo_merge_postflight!
          puts 'EVENT:postflight'
          puts "EVENT:postflight-sees=\#{SiteSetting.authorized_extensions}"
          true
        end
        #{body}
      end
    RUBY
  end

  def events(result)
    result.out.lines.map(&:strip).grep(/\AEVENT:/)
  end

  def stored(result)
    result.db
  end

  # Exactly the seeded rows: the same names, raw values (nil and empty apart) and types.
  def assert_untouched(result, db)
    assert_equal JSON.parse(JSON.generate(db)), result.db
  end

  def assert_no_private_values(result)
    text = result.out.lines.reject { |line| line.start_with?('EVENT:') }.join + result.err
    ['PRIVATE', 'ünïcødé', 'line one'].each { |value| refute_includes text, value }
  end
end
