# frozen_string_literal: true
require_relative "test_helper"
require_relative "../runtime/prebuilt-discourse/merge_asset_references"

class MergeAssetReferencesTest < SiloMigrateTest
  class Connection
    attr_reader :queries
    def initialize(counts = {})
      @counts, @queries = counts, []
    end
    def select_rows(sql)
      @queries << sql
      return [["posts", "image_upload_id"], ["upload_references", "upload_id"], ["plugin_records", "asset_upload_id"],
              ["categories", "uploaded_logo_id"], ["user_uploads", "upload_id"], ["optimized_images", "upload_id"],
              ["users", "username"]] if sql.include?("information_schema")
      [["plugin_records", "asset_upload_id"]]
    end
    def select_value(sql)
      @queries << sql
      @counts.find { |table, _| sql.include?("FROM \"#{table}\"") }&.last || 0
    end
    def quote_table_name(name) = %Q{"#{name}"}
    def quote_column_name(name) = %Q{"#{name}"}
  end

  def test_actual_carried_reference_to_excluded_upload_is_fatal
    %w[posts upload_references categories].each do |table|
      connection = Connection.new(table => 1)
      error = assert_raises(RuntimeError) { SiloDiscourseAssetReferences.verify!(connection, [101]) }
      assert_equal "excluded_upload_referenced", error.message
    end
  end

  def test_baseline_and_approved_ids_are_not_scanned_as_exclusions
    connection = Connection.new
    assert_equal({ content: 0, bookkeeping: 0, unknown: 0 }, SiloDiscourseAssetReferences.verify!(connection, [102, 103]))
    statements = connection.queries.grep(/SELECT COUNT/)
    assert_equal 6, statements.size
    assert statements.all? { |sql| sql.end_with?("IN (102,103)") }
    refute statements.any? { |sql| sql.include?("username") }
    empty = Connection.new("posts" => 99)
    assert_equal({ content: 0, bookkeeping: 0, unknown: 0 }, SiloDiscourseAssetReferences.verify!(empty, []))
    assert_empty empty.queries
  end

  def test_ownership_and_derived_rows_do_not_falsely_require_excluded_bytes
    connection = Connection.new("user_uploads" => 2, "optimized_images" => 1)
    assert_equal({ content: 0, bookkeeping: 3, unknown: 0 }, SiloDiscourseAssetReferences.verify!(connection, [101]))
    error = assert_raises(RuntimeError) { SiloDiscourseAssetReferences.verify!(Connection.new("plugin_records" => 1), [101]) }
    assert_equal "unclassified_upload_reference", error.message
  end

  def test_dangling_upload_map_values_are_subject_to_the_same_content_check
    error = assert_raises(RuntimeError) { SiloDiscourseAssetReferences.verify!(Connection.new("posts" => 1), [999]) }
    assert_equal "excluded_upload_referenced", error.message
  end

  def test_only_the_known_image_mountpoint_is_normalized
    Dir.mktmpdir do |dir|
      assert_equal File.join(dir, "uploads", "default"), SiloDiscourseAssetReferences.destination_root(dir)
      File.symlink("/shared/uploads", File.join(dir, "uploads"))
      assert_equal "/shared/uploads/default", SiloDiscourseAssetReferences.destination_root(dir)
      File.unlink(File.join(dir, "uploads"))
      File.symlink("/private-unrelated", File.join(dir, "uploads"))
      assert_raises(RuntimeError) { SiloDiscourseAssetReferences.destination_root(dir) }
    end
  end

  def test_ids_and_discovered_identifiers_cannot_inject_sql
    connection = Connection.new
    assert_raises(RuntimeError) { SiloDiscourseAssetReferences.verify!(connection, ["1); DROP TABLE posts;"]) }
    assert_empty connection.queries
    connection.define_singleton_method(:select_rows) { |_| [["unsafe;name", "upload_id"]] }
    assert_raises(RuntimeError) { SiloDiscourseAssetReferences.verify!(connection, [1]) }
  end
end
