# frozen_string_literal: true
require_relative "test_helper"
require "open3"
require "rbconfig"

class CachedCoreHistoryProbeTest < SiloMigrateTest
  FIRST = "20200101000000"
  LAST = "20261101000000"

  def probe(sql)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "structure.sql")
      File.binwrite(path, sql)
      source = File.binread(File.expand_path("../bin/silo-migrate-control", __dir__))
        .match(/CACHED_CORE_HISTORY_PROBE = r'''\n(.*?)\n'''/m).captures.first
      source = source.sub('"/var/www/discourse/db/structure.sql"', path.dump)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", source)
      [stdout, stderr, status.success?]
    end
  end

  def block(rows = [LAST, FIRST])
    %(INSERT INTO "schema_migrations" (version) VALUES\n) + rows.map { |id| "('#{id}')" }.join(",\n") + ";\n"
  end

  def test_actual_shipped_probe_reads_only_literal_unique_historical_core_ids
    stdout, _, passed = probe("-- unrelated public schema DDL\n" + block + "\n-- unrelated public metadata\n")
    assert passed
    assert_equal [FIRST, LAST], JSON.parse(stdout)
  end

  def test_missing_duplicate_or_nonliteral_blocks_refuse
    ["-- none", block + block, block([FIRST, FIRST]), block.sub("('#{LAST}')", "(current_setting('secret'))"),
     block.sub("('#{LAST}')", "('private-path')"), block.sub(";\n", ",\n"),
     block.sub("VALUES\n", "VALUES\nSELECT 'private';\n")].each do |sql|
      stdout, stderr, passed = probe(sql)
      refute passed
      assert_empty stdout
      refute_includes stderr, "private-path"
    end
  end

  def test_oversized_public_schema_and_excessive_inventory_refuse
    [" " * (16 * 1024 * 1024 + 1), block(Array.new(20_001) { |index| format("%014d", index) })].each do |sql|
      stdout, _, passed = probe(sql)
      refute passed
      assert_empty stdout
    end
  end
end
