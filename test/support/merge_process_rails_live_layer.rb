# frozen_string_literal: true

# Invented-data hooks only. No constructors/start overrides: real stock start runs.
require "yaml"
class InventedProcessMerge < BulkImport::DiscourseMerger
  def self.settings
    @settings ||= YAML.safe_load(File.read(ENV.fetch("SILO_MERGE_SETTINGS")))
  end

  def self.silo_merge_preflight!
    SiteSetting.authorized_extensions
    SiteSetting.client_settings_json
    2.times { ActiveRecord::Base.connection.select_rows("SELECT name, value, data_type FROM site_settings ORDER BY name") }
    @refused_policy = settings.fetch("semantic_ok") == true ? 0 : 1
    @refused_policy.zero?
  end

  def self.silo_merge_postflight!
    snapshot = JSON.parse(File.read("/shared/merge/site-settings.json"))
    value = snapshot.fetch("authorized_extensions_effective")
    SiteSetting.authorized_extensions == value &&
      SiteSetting.client_settings_hash[:authorized_extensions].to_s == value &&
      JSON.parse(SiteSetting.client_settings_json).fetch("authorized_extensions").to_s == value &&
      ActiveRecord::Base.connection.query_cache_enabled &&
      Post.where(raw: settings.fetch("raw")).exists? &&
      UploadReference.where(upload_id: Upload.find_by!(sha1: settings.fetch("sha1")).id).exists?
  end

  def self.silo_merge_asset_ids
    [settings.fetch("upload_id")]
  end

  def self.silo_merge_audit(phase)
    result = { "selected_uploads" => 1 }
    result["refused_policy"] = @refused_policy if phase == "preflight"
    result
  end
end
