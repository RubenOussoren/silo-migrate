# frozen_string_literal: true

# Test-only Rails driver. Never print exception messages or arbitrary command output.
require "json"
require "digest"
require "stringio"
original = STDOUT.dup
sink = File.open("/tmp/live-output", "w", 0o600)
STDOUT.reopen(sink)
STDERR.reopen(sink)
begin
  case ENV.fetch("LIVE_ACTION")
  when "seed"
    require "/tmp/merge_source_config" if ENV["SILO_MERGE_CONFIG"]
    require "/var/www/discourse/config/environment"
    kind = ENV.fetch("LIVE_KIND")
    expected = kind == "source" ? "merge_source" : "discourse"
    raise "wrong_database" unless ActiveRecord::Base.connection.select_value("SELECT current_database()") == expected
    # Boot seeds built-in assets (including non-content placeholder digests).
    # This fixture's source/destination assets are exclusively the invented PNGs;
    # remove inherited upload references/rows through core before seeding them.
    UploadReference.delete_all
    Upload.find_each(&:destroy!)
    files = kind == "source" ? %w[carried excluded] : %w[baseline]
    uploads = files.to_h do |name|
      file = File.open("/tmp/live-#{name}.png", "rb")
      upload = UploadCreator.new(file, "invented-#{name}.png").create_for(Discourse.system_user.id)
      raise "seed_upload" unless upload.persisted? && upload.sha1 == Digest::SHA1.file(file.path).hexdigest
      [name, { "id" => upload.id, "sha1" => upload.sha1, "url" => upload.url }]
    ensure
      file&.close
    end
    if kind == "source"
      upload = Upload.find(uploads.fetch("carried").fetch("id"))
      text = "Invented carried image ![pixel](#{upload.short_url})"
      post = PostCreator.create!(Discourse.system_user, title: "Invented source acceptance topic", raw: text,
                                 skip_validations: true, skip_jobs: true)
      # Core's reference extractor, not a hand-inserted join.
      post.link_post_uploads
      raise "missing_reference" unless UploadReference.where(upload_id: upload.id, target: post).exists?
      uploads["raw"] = text
      raise "optimized_content" if post.cooked.include?("/optimized/")
      # The invented source contract has originals only. Core may create
      # optimized bookkeeping during cooking; remove those through core APIs.
      OptimizedImage.destroy_all
      raise "optimized_source" unless OptimizedImage.count.zero?
      raise "dangling_upload_reference" if UploadReference.where.not(upload_id: Upload.select(:id)).exists?
      [Post, Topic].each do |model|
        dangling = model.where.not(image_upload_id: nil).where.not(image_upload_id: Upload.select(:id)).exists?
        raise "dangling_image_reference" if dangling
      end
    else
      SiteSetting.authorized_extensions = "png|jpg|invented"
      SiteSetting.title = "Invented destination acceptance"
    end
    File.write("/tmp/live-seed-#{kind}.json", JSON.generate(uploads), mode: "w", perm: 0o600)
    original.puts "LIVE:seed_ok"
  when "capture"
    require "/var/www/discourse/config/environment"
    require "/tmp/merge_site_settings"
    bytes = JSON.generate(SiloMergeSiteSettings.capture)
    File.write("/shared/merge/site-settings.json", bytes, mode: "w", perm: 0o600)
    original.puts "LIVE:capture_ok"
  when "run"
    require "/var/www/discourse/config/environment"
    ENV.update(JSON.parse(File.read("/tmp/live-run-env.json")))
    ActiveRecord::Base.cache do
      raise "query_cache_disabled" unless ActiveRecord::Base.connection.query_cache_enabled
      load "/tmp/merge_run.rb"
    end
    original.puts "LIVE:run_ok"
  when "validate"
    # Trace only class and source line, never messages/config/arguments. Production
    # intentionally masks boot failures; this bounded fixture keeps a safe tail.
    failures = []
    trace = TracePoint.new(:raise) do |event|
      if event.raised_exception.class.name.start_with?("Silo")
        failures << [event.raised_exception.class.name, File.basename(event.path), event.lineno,
          event.raised_exception.backtrace_locations.first(5).map { |loc| [File.basename(loc.path), loc.lineno] }]
      end
      failures.shift while failures.size > 8
    end
    trace.enable
    require "/tmp/merge_validation_config"
    require "/tmp/merge_validate"
    status = SiloMergeValidation.main!
    trace.disable
    original.puts "LIVE:validation_exit=#{status}"
    original.puts "LIVE:raise_sites=" + JSON.generate(failures) unless status.zero?
    exit status
  when "backup"
    require "/var/www/discourse/config/environment"
    require "backup_restore/backuper"
    BackupRestore::Backuper.new(-1, publish_to_message_bus: false).run
    original.puts "LIVE:backup_ok"
  else
    raise ArgumentError
  end
rescue Exception => error
  unless error.is_a?(SystemExit)
    original.puts "LIVE:error_class=#{error.class.name}"
    original.puts "LIVE:source_lines=" + JSON.generate(error.backtrace_locations.first(5).map { |loc| [File.basename(loc.path), loc.lineno] })
  end
  exit(error.is_a?(SystemExit) ? error.status : 9)
ensure
  original.flush
end
