# frozen_string_literal: true

# Engine-owned verification of final references. Column discovery is constrained
# to public core tables/actual foreign keys to uploads, never arbitrary project
# SQL. Non-FK legacy columns below are pinned to the supported merger schema.
require "json"
require "digest"

module SiloDiscourseAssetReferences
  LEGACY_COLUMNS = {
    "posts" => %w[image_upload_id], "topics" => %w[image_upload_id],
    "users" => %w[uploaded_avatar_id],
    "user_profiles" => %w[profile_background_upload_id card_background_upload_id],
    "user_avatars" => %w[custom_upload_id gravatar_upload_id],
    "categories" => %w[uploaded_logo_id uploaded_logo_dark_id uploaded_background_id uploaded_background_dark_id],
    "groups" => %w[flair_upload_id], "badges" => %w[image_upload_id],
    "custom_emojis" => %w[upload_id], "upload_references" => %w[upload_id]
  }.freeze

  BOOKKEEPING_COLUMNS = {
    "user_uploads" => %w[upload_id], "optimized_images" => %w[upload_id], "user_exports" => %w[upload_id]
  }.freeze
  EXTRA_CONTENT_COLUMNS = { "post_hotlinked_media" => %w[upload_id] }.freeze

  module_function

  # Resolve ONLY the pinned image's known mountpoint link. Relative asset links
  # and source links remain forbidden by the shared transfer primitive.
  def destination_root(public_path)
    root = File.join(public_path.to_s, "uploads")
    if File.symlink?(root)
      raise "asset_root_unproven" unless File.readlink(root) == "/shared/uploads"
      "/shared/uploads/default"
    else
      File.join(root, "default")
    end
  end

  def columns(connection)
    actual = connection.select_rows("SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public' ORDER BY table_name, column_name")
    available = actual.to_h { |table, _column| [table, true] }
    references = connection.select_rows(<<~SQL)
      SELECT t.relname, a.attname FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(c.conkey)
      WHERE c.contype = 'f' AND c.confrelid = 'public.uploads'::regclass AND n.nspname = 'public'
    SQL
    fixed = actual.select do |table, column|
      LEGACY_COLUMNS.fetch(table, []).include?(column) || column.match?(/(?:\Aupload_id\z|_upload_id\z)/)
    end
    (references + fixed).uniq.each do |table, column|
      raise "asset_reference_schema" unless available[table] && table.match?(/\A[a-z][a-z0-9_]*\z/) && column.match?(/\A[a-z][a-z0-9_]*\z/)
    end
    groups = { content: [], bookkeeping: [], unknown: [] }
    (references + fixed).uniq.each do |table, column|
      kind = if BOOKKEEPING_COLUMNS.fetch(table, []).include?(column)
        :bookkeeping
      elsif LEGACY_COLUMNS.fetch(table, []).include?(column) || EXTRA_CONTENT_COLUMNS.fetch(table, []).include?(column)
        :content
      else
        :unknown
      end
      groups.fetch(kind) << [table, column]
    end
    groups
  end

  def verify!(connection, excluded_ids)
    raise "asset_reference_ids" unless excluded_ids.is_a?(Array) && excluded_ids.size <= 100_000 && excluded_ids.all? { |id| id.is_a?(Integer) && id.positive? }
    counts = { content: 0, bookkeeping: 0, unknown: 0 }
    return counts if excluded_ids.empty?
    columns(connection).each do |kind, pairs|
      pairs.each do |table, column|
        excluded_ids.uniq.each_slice(1000) do |batch|
          count = connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)} WHERE #{connection.quote_column_name(column)} IN (#{batch.join(',')})").to_i
          counts[kind] += count
        end
      end
    end
    raise "excluded_upload_referenced" unless counts[:content].zero?
    raise "unclassified_upload_reference" unless counts[:unknown].zero?
    counts
  end
end

if ENV["SILO_MERGE_REFERENCE_CHECK"] == "1"
  begin
    path = "/shared/merge-process/references.json"
    bytes = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
      raise "references_unproven" unless file.stat.file? && file.stat.size <= 4 * 1024 * 1024
      file.read
    end
    expected = ENV.fetch("SILO_MERGE_REFERENCES_SHA256")
    raise "references_unproven" unless expected.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.hexdigest(bytes) == expected
    value = JSON.parse(bytes)
    raise "references_unproven" unless value.is_a?(Hash) && value.keys.sort == %w[dangling_ids excluded_inserted_ids version] && value["version"] == 1
    excluded = value.fetch("excluded_inserted_ids")
    dangling = value.fetch("dangling_ids")
    raise "references_unproven" unless excluded.is_a?(Array) && dangling.is_a?(Array)
    SiloDiscourseAssetReferences.verify!(ActiveRecord::Base.connection, excluded + dangling)
    puts "SILO_MERGE_REFERENCES: clean"
  rescue Exception
    warn "SILO_MERGE_REFERENCES: unproven"
    exit 4
  end
end
