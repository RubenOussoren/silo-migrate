require "digest"
c = ActiveRecord::Base.connection

# Trusted read-only state for the merge compatibility gate. Besides the counters it reports the
# actual migration inventory, column types and the tables the pinned merger (and, when a
# directory is named, a committed layer) refers to. Constant names are resolved to their tables
# without running merger code: a superset is deliberate, the gate only ever gets stricter.
merger = Rails.root.join("script/bulk_import/discourse_merger.rb").to_s
layer = ENV["SILO_MERGE_SCAN_LAYER"].to_s
scanned = [merger]
scanned += Dir.glob(File.join(layer, "**", "*.rb")).sort.first(64) if layer.match?(%r{\A/shared/[A-Za-z0-9_-]+\z}) && File.directory?(layer)
merger_tables = nil
if File.file?(merger)
  names = scanned.flat_map { |path| File.read(path, 1024 * 1024).to_s.scan(/(?<![A-Za-z0-9_:])(?:[A-Z][A-Za-z0-9]*)(?:::[A-Z][A-Za-z0-9]*)*/) }.uniq.first(4000)
  merger_tables = names.filter_map do |name|
    klass = begin
      name.safe_constantize
    rescue StandardError, LoadError
      nil
    end
    next unless klass.is_a?(Class) && klass < ActiveRecord::Base && !klass.abstract_class?

    begin
      klass.table_name if klass.table_exists?
    rescue StandardError
      nil
    end
  end.uniq.sort
end

puts "SILO_JSON:" + JSON.generate(
  "database" => c.select_value("SELECT current_database()"),
  "pending" => ActiveRecord::Base.connection_pool.migration_context.needs_migration? ||
    (Dir.glob(Rails.root.join("db/post_migrate/[0-9]*_*.rb")).map { |path| File.basename(path).split("_").first } -
      c.select_values("SELECT version FROM schema_migrations")).any?,
  "base_url" => (c.data_source_exists?("backup_metadata") ? c.select_value("SELECT value FROM backup_metadata WHERE name = 'base_url'") : nil),
  "counts" => %w[users topics posts categories groups tags uploads].to_h { |table| [table, c.select_value("SELECT COUNT(*) FROM #{table}").to_i] },
  "migrations" => c.select_values("SELECT version FROM schema_migrations ORDER BY version"),
  "columns" => c.select_rows("SELECT table_name, column_name, CASE WHEN data_type IN ('ARRAY', 'USER-DEFINED') THEN data_type || ':' || udt_name ELSE data_type END FROM information_schema.columns WHERE table_schema = 'public' ORDER BY table_name, column_name"),
  "merger" => { "available" => !merger_tables.nil?, "layer_scanned" => scanned.size > 1, "tables" => merger_tables || [] },
  "settings" => c.select_rows("SELECT name, value, data_type FROM site_settings ORDER BY name").to_h { |name, value, type| [name, [value, type]] },
)
