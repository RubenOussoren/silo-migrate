# frozen_string_literal: true

require "rubygems/package"
require "sqlite3"

# A command recorder that creates only synthetic host files. Never shells out.
class DiscourseFakeRuntime < SiloMigrate::Runtime::Fake
  attr_accessor :restore_allowed, :fail_on, :processing_path, :archive_members,
                :listed_files, :omit_copy, :restore_changes_permission, :import_report

  def initialize
    super
    @restore_allowed = false
    dump = StringIO.new
    gzip = Zlib::GzipWriter.new(dump)
    gzip.write("-- synthetic SQL dump\n")
    gzip.finish
    @archive_members = { "dump.sql.gz" => dump.string, "uploads/default/original/sandbox.txt" => "sandbox", "uploads/default/original/source.txt" => "source" }
    @restore_changes_permission = false
    @import_report = "Done! (0 minutes)\n"
  end

  def self.processing_db(path, skipped: false)
    FileUtils.mkdir_p(File.dirname(path))
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE uploads (id TEXT PRIMARY KEY, upload TEXT, markdown TEXT, skip_reason TEXT, skip_details TEXT)")
    db.execute("INSERT INTO uploads VALUES (?, ?, ?, ?, ?)", ["1", skipped ? nil : '{"id":1}', "upload://synthetic.txt", skipped ? "error" : nil, nil])
  ensure
    db&.close
  end

  def run(cmd, **options)
    result = super
    text = cmd.join(" ")
    return command_result(false) if @fail_on && text.include?(@fail_on)

    if cmd[-2, 2] == ["rev-parse", "HEAD"]
      return command_result(true, "#{SiloMigrate::Services::DiscourseService::STANDARD_DISCOURSE_REVISION}\n")
    elsif text.include?("SILO_ALLOW_RESTORE")
      return command_result(true, "SILO_ALLOW_RESTORE=#{@restore_allowed}\n")
    elsif text.include?("script/discourse enable_restore")
      @restore_allowed = true
    elsif text.include?("script/discourse disable_restore")
      @restore_allowed = false
    elsif text.include?("script/discourse restore ")
      @restore_allowed = @restore_changes_permission
    elsif text.include?("generic_bulk.rb")
      return command_result(true, @import_report)
    elsif text.include?("uploads_importer.rb") && @processing_path
      self.class.processing_db(@processing_path)
    elsif text.include?("script/discourse backup ")
      @backup_stem = text.split("silo-migrate-backup-").last.split("/").first
    elsif cmd[0, 4] == ["docker", "exec", "acme-import", "find"]
      return command_result(true, @listed_files || "#{@backup_stem}-v2026-11-0-123.tar.gz\n")
    elsif cmd[0, 2] == ["docker", "cp"] && cmd[2].start_with?("acme-import:/shared/") && !@omit_copy
      Zlib::GzipWriter.open(cmd[3]) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          @archive_members.each do |name, bytes|
            tar.add_file_simple(name, 0o600, bytes.bytesize) { |entry| entry.write(bytes) }
          end
        end
      end
    end
    result
  end

  def command_result(success, stdout = "")
    SiloMigrate::Runtime::CommandResult.new(success?: success, stdout: stdout, stderr: "", status: success ? 0 : 1)
  end
end
