# frozen_string_literal: true
require "minitest/autorun"
require "open3"
require "rbconfig"
require "json"

class MergeBackupConfigTest < Minitest::Test
  HARNESS = <<~'RUBY'
    require "json"
    # Stub only the fixed environment require in this isolated unit process.
    module SiloMergeBackupConfig
      def self.require(path)
        raise "unexpected dependency" unless path == "/var/www/discourse/config/environment"
        @environment_loaded = true
      end
      def self.environment_loaded? = @environment_loaded
    end
    class SiteSetting
      class << self
        attr_accessor :stored, :writes
        def include_s3_uploads_in_backups
          stored.nil? ? false : stored.fetch(0)
        end
        def include_s3_uploads_in_backups=(value)
          self.writes << value
          self.stored = [value, 5]
        end
      end
    end
    load ARGV.fetch(0)
    outcomes = []
    [nil, [false, 5], [true, 5]].each do |state|
      SiteSetting.stored = state&.dup
      SiteSetting.writes = []
      original = SiteSetting.include_s3_uploads_in_backups
      # Exact native CLI ensure behavior, without its backup IO.
      begin
        backup_called = true
      ensure
        SiteSetting.include_s3_uploads_in_backups = original
      end
      preserved = SiteSetting.stored == state && SiteSetting.writes.empty?
      refused = begin
        SiteSetting.include_s3_uploads_in_backups = !original
        false
      rescue SiloMergeBackupConfig::Refused => error
        error.message == "STANDARD_MERGE_BACKUP_SETTINGS_UNPROVEN" && error.cause.nil?
      end
      outcomes << { preserved: preserved, actual_change_refused: refused,
                    no_writes: SiteSetting.writes.empty?, native_body_called: backup_called }
    end
    bad_types = [nil, 0, 1, "false", "PRIVATE_VALUE"].all? do |value|
      begin
        SiteSetting.include_s3_uploads_in_backups = value
        false
      rescue SiloMergeBackupConfig::Refused
        true
      end
    end
    puts JSON.generate(environment_loaded: SiloMergeBackupConfig.environment_loaded?,
                       outcomes: outcomes, invalid_types_refused: bad_types)
  RUBY

  def test_native_redundant_setter_keeps_exact_absence_value_and_type_without_repair_writes
    helper = File.expand_path("../runtime/prebuilt-discourse/merge_backup_config.rb", __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", HARNESS, helper)
    assert status.success?, "isolated backup guard harness failed (raw output suppressed)"
    assert_empty stderr
    value = JSON.parse(stdout)
    assert_equal true, value.fetch("environment_loaded")
    assert_equal true, value.fetch("invalid_types_refused")
    assert_equal 3, value.fetch("outcomes").size
    value.fetch("outcomes").each do |outcome|
      assert_equal({ "preserved" => true, "actual_change_refused" => true,
                     "no_writes" => true, "native_body_called" => true }, outcome)
    end
  end
end
