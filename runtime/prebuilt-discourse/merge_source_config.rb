# frozen_string_literal: true

# Loaded with RUBYOPT=-r for one process only: that process reads its Discourse config
# from SILO_MERGE_CONFIG (a copy of the site's config naming the source copy's database),
# so the source copy can be migrated to this Discourse version. The image writes
# discourse.conf when the container starts; DISCOURSE_* variables given to a later exec are
# ignored, and the running site's own config must stay as it is.
require "/var/www/discourse/app/models/global_setting"

module SiloMergeSourceConfig
  def configure!(**options)
    super(**options.merge(path: ENV.fetch("SILO_MERGE_CONFIG")))
  end
end
GlobalSetting.singleton_class.prepend(SiloMergeSourceConfig)
