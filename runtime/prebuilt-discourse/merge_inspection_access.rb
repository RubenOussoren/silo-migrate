# frozen_string_literal: true
# Local merge-inspection identity on a disposable inspection clone (or on the result site,
# only after its clean backup was recorded by the host). Run by the host through
# `rails runner`; prints exactly one SILO_JSON line with non-secret identifiers only.
#
# create: a dedicated, labelled admin account plus ONE single-user API key in server-enforced
#   read_only scope mode (exactly one global:read scope = GET only). The key is written to a
#   private file inside this container (0600, new 0700 directory) and is never printed, logged
#   or passed through argv; the host copies it out with `docker cp` and removes the directory.
# revoke: revokes the recorded keys, removes the account's sessions and demotes/deactivates it.
#
# Fails closed with a fixed reason (no exception text) when the runtime lacks the read-only
# scope feature, the identity already exists or the result does not verify.
require "json"
require "securerandom"

def refuse!(reason)
  abort "MERGE_INSPECTION_REFUSED: #{reason}"
end

action = ENV["SILO_INSPECTION_ACTION"]
username = ENV["SILO_INSPECTION_USERNAME"].to_s
refuse!("username") unless username.match?(/\Asilo_inspect_[0-9a-f]{8}\z/)
DESCRIPTION = "SiloMigrate merge inspection (local, read-only)"

# Database binding, before ANY read-for-decision or mutation: this process must be connected to
# exactly the database the host bound (name AND pg_database OID). The Base inspection clone and
# the sealed pristine Base carry the same name at different times; only the OID tells them apart.
expected_db = ENV["SILO_INSPECTION_DATABASE"].to_s
expected_oid = ENV["SILO_INSPECTION_DATABASE_OID"].to_s
refuse!("database binding") unless expected_db.match?(/\A[a-z_][a-z0-9_]{0,62}\z/) && expected_oid.match?(/\A[1-9][0-9]{0,9}\z/)
connection = ActiveRecord::Base.connection
current_db = connection.select_value("SELECT current_database()").to_s
current_oid = connection.select_value("SELECT oid::text FROM pg_database WHERE datname = current_database()").to_s
refuse!("database binding") unless current_db == expected_db && current_oid == expected_oid

case action
when "create"
  key_dir = ENV["SILO_INSPECTION_KEY_DIR"].to_s
  refuse!("key path") unless key_dir.match?(%r{\A/tmp/silo-inspection-[0-9a-f]{16}\z})
  # Feature detection on the actual runtime: read-only scope mode with one GET-only global scope.
  supported = ApiKey.respond_to?(:scope_modes) && ApiKey.scope_modes.key?("read_only") &&
              ApiKeyScope.respond_to?(:default_mappings) &&
              ApiKeyScope.default_mappings.dig(:global, :read, :methods) == [:get]
  refuse!("read-only scope unsupported") unless supported
  email = "#{username.tr('_', '-')}@example.invalid"
  refuse!("identity exists") if User.exists?(username_lower: username) || UserEmail.exists?(email: email)

  user = nil
  api_key = nil
  User.transaction do
    user = User.new(username: username, name: DESCRIPTION, email: email,
                    password: SecureRandom.hex(32), active: true, approved: true, trust_level: 4, admin: true)
    user.required_fields_version = UserRequiredFieldsVersion.current if defined?(UserRequiredFieldsVersion)
    user.skip_email_validation = true
    user.skip_username_watched_words_validation = true if user.respond_to?(:skip_username_watched_words_validation=)
    user.save!(validate: false)
    user.email_tokens.update_all(confirmed: true)
    user.activate

    api_key = ApiKey.new(description: DESCRIPTION, user: user,
                         created_by: Discourse.system_user, scope_mode: "read_only")
    api_key.api_key_scopes = [ApiKeyScope.new(resource: "global", action: "read")]
    api_key.save!
    scopes = api_key.reload.api_key_scopes.map { |scope| [scope.resource, scope.action] }
    unless api_key.read_only? && scopes == [%w[global read]] && api_key.user_id == user.id && api_key.revoked_at.nil? &&
           ApiKey.where(user_id: user.id).count == 1
      raise ActiveRecord::Rollback
    end

    Dir.mkdir(key_dir, 0o700)
    File.open(File.join(key_dir, "key"), File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
      file.write(api_key.key)
    end
  end
  refuse!("key not created") unless api_key&.persisted? && File.file?(File.join(key_dir, "key"))

  puts "SILO_JSON:" + JSON.generate(
    "database" => current_db, "database_oid" => current_oid,
    "user_id" => user.id, "username" => user.username, "api_key_id" => api_key.id,
    "scope_mode" => api_key.scope_mode, "scopes" => ["global:read"]
  )
when "revoke"
  ids = ENV["SILO_INSPECTION_KEY_IDS"].to_s.split(",")
  refuse!("key ids") unless ids.size.between?(1, 4) && ids.all? { |id| id.match?(/\A[0-9]{1,18}\z/) }
  ids = ids.map(&:to_i)
  acknowledged = ENV["SILO_INSPECTION_MINT_ACKNOWLEDGED"] == "1"
  user = User.find_by(username_lower: username)
  never_minted = false
  if user.nil?
    # A recorded (acknowledged) key whose identity vanished can't be proven revoked.
    refuse!("identity missing") if acknowledged
    # Identity and key are created in one transaction: with no identity, an unacknowledged mint
    # left nothing only if no active tool-described key without a live owner exists here.
    orphans = ApiKey.where(description: DESCRIPTION, revoked_at: nil)
                    .where("user_id IS NULL OR user_id NOT IN (SELECT id FROM users)").count
    refuse!("unowned inspection keys") unless orphans.zero?
    never_minted = true
  end
  ApiKey.transaction do
    keys = ApiKey.where(id: ids)
    # Only keys bound to the tool-created identity; never a restored production key. Without the
    # identity, ownership of any existing key with a supplied ID can't be proven: touch nothing.
    refuse!("key ownership") if user.nil? ? keys.exists? : keys.any? { |key| key.user_id != user.id }
    keys.where(revoked_at: nil).update_all(revoked_at: Time.zone.now)
    if user
      ApiKey.where(user_id: user.id, revoked_at: nil).update_all(revoked_at: Time.zone.now)
      UserAuthToken.where(user_id: user.id).delete_all
      user.update_columns(admin: false, moderator: false, active: false)
    end
  end
  remaining = ApiKey.where(id: ids, revoked_at: nil).count + (user ? ApiKey.where(user_id: user.id, revoked_at: nil).count : 0)
  refuse!("keys still active") unless remaining.zero?
  puts "SILO_JSON:" + JSON.generate("database" => current_db, "database_oid" => current_oid, "revoked" => ids.size,
                                    "active_remaining" => 0, "identity_present" => !user.nil?, "never_minted" => never_minted)
else
  refuse!("action")
end
