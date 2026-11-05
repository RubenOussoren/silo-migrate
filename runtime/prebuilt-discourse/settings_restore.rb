# frozen_string_literal: true
# uploads_importer.rb writes its working settings to the destination site.
# Put back the baseline values so a migration preserves the site's own policy.
settings = JSON.parse(ENV.fetch("SILO_SETTINGS_JSON"))
settings.each { |name, value| SiteSetting.set(name, value) }
SiteSetting.refresh!
mismatched = settings.reject { |name, value| SiteSetting.public_send(name).to_s == value.to_s }
abort "SETTINGS_RESTORE_MISMATCH #{mismatched.keys.join(',')}" unless mismatched.empty?
puts "SILO_JSON:" + JSON.generate("restored" => settings.keys.sort)
