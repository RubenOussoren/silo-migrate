# frozen_string_literal: true

# Private data-bearing state, consumed only by the run service.
require "digest"
c = ActiveRecord::Base.connection
puts "SILO_JSON:" + JSON.generate(
  "database" => c.select_value("SELECT current_database()"),
  "pending" => ActiveRecord::Base.connection_pool.migration_context.needs_migration? ||
    (Dir.glob(Rails.root.join("db/post_migrate/[0-9]*_*.rb")).map { |path| File.basename(path).split("_").first } -
      c.select_values("SELECT version FROM schema_migrations")).any?,
  "base_url" => (c.data_source_exists?("backup_metadata") ? c.select_value("SELECT value FROM backup_metadata WHERE name = 'base_url'") : nil),
  "counts" => %w[users topics posts categories groups tags uploads].to_h { |table| [table, c.select_value("SELECT COUNT(*) FROM #{table}").to_i] },
  "columns" => c.select_rows("SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public' ORDER BY table_name, column_name"),
  "settings" => c.select_rows("SELECT name, value, data_type FROM site_settings ORDER BY name").to_h { |name, value, type| [name, [value, type]] },
)
