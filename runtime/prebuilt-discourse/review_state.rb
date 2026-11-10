# frozen_string_literal: true
# Read-only facts: never emit customer settings, identities or content.
names = %w[login_required backup_location enable_s3_uploads force_https enable_local_logins enable_discourse_connect download_remote_images_to_local enforce_second_factor port disable_emails allow_restore]
puts "SILO_JSON:" + JSON.generate(
  "discourse_version" => Discourse::VERSION::STRING,
  "schema_version" => ActiveRecord::Base.connection.select_value("SELECT MAX(version) FROM schema_migrations"),
  "migration_versions" => ActiveRecord::Base.connection.select_values("SELECT version FROM schema_migrations ORDER BY version"),
  "prior_import_id_rows" => [UserCustomField, CategoryCustomField, TopicCustomField, PostCustomField].sum { |model| model.where(name: "import_id").count },
  "settings" => names.to_h { |name| [name, SiteSetting.public_send(name)] }
)
