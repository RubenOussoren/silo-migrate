# frozen_string_literal: true
# Runs inside `rails runner` on a fresh review site, before real data is imported.
# Locks the site down (no email, login required, no restore) and creates the one admin
# account the engineer signs in with. Prints fixed facts only, never the password.
abort "REVIEW_SETUP_REFUSED: site already set up" if User.exists?(username: "silo_review_admin")
abort "REVIEW_SETUP_REFUSED: site has content" if Post.where("user_id > 0").exists? || UserCustomField.where(name: "import_id").exists?

SiteSetting.disable_emails = "yes"
SiteSetting.login_required = true
SiteSetting.allow_restore = false
SiteSetting.wizard_enabled = false
SiteSetting.title = "SiloMigrate review"
SiteSetting.site_description = "Local review import. Contains customer data: do not share."
SiteSetting.contact_email = "review-admin@example.invalid"
SiteSetting.notification_email = "noreply@example.invalid"
SiteSetting.download_remote_images_to_local = false
SiteSetting.enable_s3_uploads = false
# Set before the import, so imported content never needs remapping. A review site is
# never backed up, so the port can't travel to a hosted restore.
SiteSetting.port = ENV.fetch("SILO_SITE_PORT")
Discourse.clear_urls!

user = User.new(username: "silo_review_admin", name: "SiloMigrate review admin", email: "review-admin@example.invalid",
                password: ENV.fetch("SILO_ADMIN_PASSWORD"), active: true, approved: true, trust_level: 4, admin: true)
user.skip_email_validation = true
user.save!
user.email_tokens.update_all(confirmed: true)
user.activate

puts "SILO_JSON:" + JSON.generate(
  "admin_username" => user.username, "disable_emails" => SiteSetting.disable_emails.to_s,
  "login_required" => SiteSetting.login_required, "allow_restore" => SiteSetting.allow_restore,
  "base_url" => Discourse.base_url
)
