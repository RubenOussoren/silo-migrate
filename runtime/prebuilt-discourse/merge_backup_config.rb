# frozen_string_literal: true

# Loaded by the bundle-activated Ruby child for ONE merge backup invocation.
# Pinned script/discourse restores include_s3_uploads_in_backups in ensure even
# when --s3-uploads was not requested. That redundant setter can create a stored
# override where the original state had none. Keep the real native CLI/Creator,
# but prohibit changes to that setting and avoid rewriting an already-equal value.
module SiloMergeBackupConfig
  class Refused < StandardError
    def initialize = super("STANDARD_MERGE_BACKUP_SETTINGS_UNPROVEN")
  end

  module NoSettingWrites
    def include_s3_uploads_in_backups=(value)
      unless [true, false].include?(value) && value == include_s3_uploads_in_backups
        raise Refused.new, cause: nil
      end
      value
    end
  end

  def self.install!
    require "/var/www/discourse/config/environment"
    SiteSetting.singleton_class.prepend(NoSettingWrites)
  end
end

begin
  SiloMergeBackupConfig.install!
rescue Exception
  # A boot exception may contain private data; retain only a fixed failure.
  abort "STANDARD_MERGE_BACKUP_SETTINGS_UNPROVEN"
end
