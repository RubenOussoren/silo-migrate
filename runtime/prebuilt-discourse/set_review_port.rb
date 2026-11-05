# frozen_string_literal: true
# Local review convenience, applied only AFTER the portable backup is taken: the
# hidden `port` setting travels in backups and would break a hosted restore.
before = Discourse.base_url
SiteSetting.port = ENV.fetch("SILO_SITE_PORT")
after = Discourse.base_url
DbHelper.remap(before, after) if before != after
Discourse.clear_urls!
puts "SILO_JSON:" + JSON.generate("base_url" => after)
