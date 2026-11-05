# frozen_string_literal: true
# Runs inside `rails runner` on a fresh, explicitly named synthetic site. Creates
# distinct sandbox-origin records that an import must preserve. Synthetic only.
abort "SEED_REFUSED: site already has sandbox content" if User.exists?(username: "sandbox_admin")
abort "SEED_REFUSED: site has non-system content" if Post.where("user_id > 0").exists? && ENV["SILO_SEED_ALLOW_EXISTING"] != "1"

SiteSetting.title = "SiloMigrate synthetic sandbox"
SiteSetting.site_description = "Disposable synthetic review site. Contains no customer data."
SiteSetting.contact_email = "synthetic-admin@example.invalid"
SiteSetting.notification_email = "noreply@example.invalid"
SiteSetting.wizard_enabled = false
SiteSetting.authorized_extensions = "txt"
SiteSetting.secure_uploads = false
SiteSetting.prevent_anons_from_downloading_files = false
SiteSetting.download_remote_images_to_local = false
SiteSetting.enable_s3_uploads = false
SiteSetting.disable_emails = "yes"
SiteSetting.login_required = false
SiteSetting.allow_restore = false

password = ENV.fetch("SILO_ADMIN_PASSWORD")
make_user = lambda do |username, email, admin:|
  user = User.new(username: username, name: username.tr("_", " ").capitalize, email: email,
                  password: password, active: true, approved: true, trust_level: admin ? 4 : 1,
                  admin: admin)
  user.skip_email_validation = true
  user.save!
  user.email_tokens.update_all(confirmed: true)
  user.activate
  user
end
admin = make_user.call("sandbox_admin", "sandbox_admin@example.invalid", admin: true)
member = make_user.call("sandbox_member", "sandbox_member@example.invalid", admin: false)

group = Group.create!(name: "sandbox_team", visibility_level: Group.visibility_levels[:public])
group.add(member)
group.add(admin)

category = Category.create!(name: "Sandbox Origin", slug: "sandbox-origin", user: admin,
                            description: "Synthetic records that existed before migration.",
                            color: "0088CC", text_color: "FFFFFF")

bytes = ENV.fetch("SILO_SANDBOX_ATTACHMENT_B64").unpack1("m0")
upload = Tempfile.create(["sandbox", ".txt"]) do |file|
  file.binmode
  file.write(bytes)
  file.flush
  file.rewind
  UploadCreator.new(file, "sandbox-attachment.txt", type: "composer").create_for(admin.id)
end
abort "SEED_FAILED: upload #{upload.errors.full_messages.join(', ')}" unless upload.persisted?

topic_post = PostCreator.create!(
  admin, title: "Sandbox welcome topic created before migration", category: category.id,
         raw: "Sandbox-origin first post. Attachment below.\n\n#{UploadMarkdown.new(upload).attachment_markdown}\n",
         skip_validations: true, skip_guardian: true
)
topic_post.link_post_uploads
reply = PostCreator.create!(member, topic_id: topic_post.topic_id, raw: "Sandbox-origin reply from the member account.",
                                    skip_validations: true, skip_guardian: true)

puts "SILO_JSON:" + JSON.generate(
  "admin_user_id" => admin.id, "member_user_id" => member.id, "group_id" => group.id,
  "category_id" => category.id, "topic_id" => topic_post.topic_id,
  "first_post_id" => topic_post.id, "reply_post_id" => reply.id,
  "upload_id" => upload.id, "upload_sha1" => upload.sha1, "upload_url" => upload.url,
  "short_path" => upload.short_path
)
