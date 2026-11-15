# frozen_string_literal: true

# Invented policy only. Inherits the pinned stock constructor and start unchanged.
# Unlike the guest-composition layer this does not require a test-driver query
# cache or any guest-only orchestration. Host-installed merge_run invokes it.
require "yaml"
class InventedConnectedMerge < BulkImport::DiscourseMerger
  def self.settings
    @settings ||= YAML.safe_load(File.read(ENV.fetch("SILO_MERGE_SETTINGS")))
  end

  def self.silo_merge_preflight!
    @refused_policy = settings.fetch("semantic_ok") == true ? 0 : 1
    @refused_policy.zero?
  end

  def self.silo_merge_postflight!
    snapshot = JSON.parse(File.read("/shared/merge/site-settings.json"))
    value = snapshot.fetch("authorized_extensions_effective")
    upload = Upload.find_by!(sha1: settings.fetch("sha1"))
    SiteSetting.authorized_extensions == value &&
      Post.where(raw: settings.fetch("raw")).exists? &&
      UploadReference.where(upload_id: upload.id).exists?
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
