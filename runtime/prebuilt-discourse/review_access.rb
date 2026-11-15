# frozen_string_literal: true
# Local access only, AFTER the host has durably recorded the portable backup.
abort "REVIEW_ACCESS_REFUSED: backup not recorded" unless ENV["SILO_BACKUP_RECORDED"] == "true"
abort "REVIEW_ACCESS_REFUSED: identity exists" if User.exists?(username_lower: "silo_review_admin") || UserEmail.exists?(email: "review-admin@example.invalid")
User.transaction do
  user = User.new(username: "silo_review_admin", name: "SiloMigrate review admin", email: "review-admin@example.invalid",
                  password: ENV.fetch("SILO_ADMIN_PASSWORD"), active: true, approved: true, trust_level: 4, admin: true,
                  required_fields_version: UserRequiredFieldsVersion.current)
  user.skip_email_validation = true
  user.skip_username_watched_words_validation = true
  # This is a local access identity, not the first real site administrator.
  # Core's after_save callback would clear has_login_hint/global_notice and
  # mutate the destination settings after its portable backup was recorded.
  # Suppress only that callback on THIS instance; retain the final exact check.
  user.define_singleton_method(:clear_global_notice_if_needed) { nil }
  # Mark this local account current so required fields do not redirect it after login.
  # This fixed, engineer-only identity must not be rejected by the sandbox's username,
  # email, password or required custom-field policies. Database constraints still apply.
  user.save!(validate: false)
  user.email_tokens.update_all(confirmed: true)
  # Already saved active/approved and its signup token is confirmed. #activate
  # would load a NEW User via EmailToken.confirm and run the notice callback
  # on that different instance. Refresh groups without a second activation.
  user.set_automatic_groups
  puts "SILO_JSON:" + JSON.generate(
    "admin_username" => user.username, "disable_emails" => SiteSetting.disable_emails.to_s,
    "login_required" => SiteSetting.login_required, "allow_restore" => SiteSetting.allow_restore,
    "base_url" => Discourse.base_url
  )
end
