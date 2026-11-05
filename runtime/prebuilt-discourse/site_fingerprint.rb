# frozen_string_literal: true
# Read-only oracle input. Prints durable facts; comparison happens outside the
# site. Never mutates records and emits synthetic site facts only.
def upload_fact(upload)
  path = Discourse.store.path_for(upload)
  {
    "id" => upload.id, "original_filename" => upload.original_filename, "extension" => upload.extension,
    "sha1" => upload.sha1, "filesize" => upload.filesize, "url" => upload.url, "short_path" => upload.short_path,
    "user_id" => upload.user_id, "local_path_present" => !path.nil? && File.file?(path),
    "file_sha256" => path && File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil,
    "post_references" => UploadReference.where(upload_id: upload.id, target_type: "Post").pluck(:target_id).sort
  }
end

user_imports = UserCustomField.where(name: "import_id").pluck(:user_id, :value).to_h
category_imports = CategoryCustomField.where(name: "import_id").pluck(:category_id, :value).to_h
topic_imports = TopicCustomField.where(name: "import_id").pluck(:topic_id, :value).to_h
post_imports = PostCustomField.where(name: "import_id").pluck(:post_id, :value).to_h

facts = {
  "versions" => { "discourse" => Discourse::VERSION::STRING, "git" => Discourse.git_version, "ruby" => RUBY_VERSION,
                  "schema" => ActiveRecord::Base.connection.select_value("SELECT MAX(version) FROM schema_migrations") },
  "runtime" => {
    "store_local" => Discourse.store.is_a?(FileStore::LocalStore), "s3" => SiteSetting.enable_s3_uploads,
    "base_url" => Discourse.base_url, "disable_emails" => SiteSetting.disable_emails.to_s,
    "extensions" => ActiveRecord::Base.connection.select_values("SELECT extname FROM pg_extension").sort,
    "pg_version" => ActiveRecord::Base.connection.select_value("SHOW server_version"),
    "redis_version" => Discourse.redis.info["redis_version"],
    "allow_restore" => SiteSetting.allow_restore
  },
  "settings" => %w[title authorized_extensions max_attachment_size_kb max_image_size_kb max_image_megapixels clean_up_uploads secure_uploads s3_enable_access_control_tags prevent_anons_from_downloading_files download_remote_images_to_local].to_h { |n| [n, SiteSetting.public_send(n).to_s] },
  "users" => User.where("id > 0").order(:username).map { |u| { "id" => u.id, "username" => u.username, "email" => u.email, "admin" => u.admin, "moderator" => u.moderator, "trust_level" => u.trust_level, "active" => u.active, "created_at" => u.created_at.utc.iso8601, "import_id" => user_imports[u.id] } },
  "groups" => Group.where(automatic: false).order(:name).map { |g| { "name" => g.name, "users" => g.users.order(:username).pluck(:username) } },
  "categories" => Category.order(:slug).map { |c| { "id" => c.id, "name" => c.name, "slug" => c.slug, "parent_category_id" => c.parent_category_id, "user" => c.user&.username, "import_id" => category_imports[c.id], "parent_import_id" => category_imports[c.parent_category_id] } },
  "topics" => Topic.where(archetype: "regular").where("user_id > 0").order(:id).map { |t| { "id" => t.id, "title" => t.title, "slug" => t.slug, "category" => t.category&.slug, "user" => t.user&.username, "posts_count" => t.posts_count, "created_at" => t.created_at.utc.iso8601, "import_id" => topic_imports[t.id], "category_import_id" => category_imports[t.category_id] } },
  "posts" => Post.joins(:topic).where(topics: { archetype: "regular" }).where("posts.user_id > 0").order(:topic_id, :post_number).map { |p| { "id" => p.id, "topic_id" => p.topic_id, "post_number" => p.post_number, "user" => p.user&.username, "raw" => p.raw, "cooked_sha256" => Digest::SHA256.hexdigest(p.cooked.to_s), "cooked" => p.cooked, "created_at" => p.created_at.utc.iso8601, "reply_to_post_number" => p.reply_to_post_number, "import_id" => post_imports[p.id], "topic_import_id" => topic_imports[p.topic_id] } },
  "uploads" => Upload.where("id > 0").order(:sha1).map { |u| upload_fact(u) },
  "import_mappings" => (ActiveRecord::Base.connection.table_exists?("migration_mappings") ? ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM migration_mappings") : nil),
  "custom_fields" => {
    "user_import_ids" => UserCustomField.where(name: "import_id").order(:value).pluck(:value),
    "topic_import_ids" => TopicCustomField.where(name: "import_id").order(:value).pluck(:value),
    "post_import_ids" => PostCustomField.where(name: "import_id").order(:value).pluck(:value),
    "category_import_ids" => CategoryCustomField.where(name: "import_id").order(:value).pluck(:value)
  }
}
puts "SILO_JSON:" + JSON.generate(facts)
