# frozen_string_literal: true
require "minitest/autorun"
require "open3"
require "rbconfig"
require "securerandom"
require "json"

# Load each actual helper in an isolated Ruby process. The fake model reproduces
# pinned core's first-admin after_save callback; no database/service is involved.
class ReviewAccessPreservationTest < Minitest::Test
  HARNESS = <<~'RUBY'
    require "json"
    require "fileutils"
    class SiteSetting
      class << self
        attr_accessor :has_login_hint, :global_notice
        def disable_emails = "yes"
        def login_required = true
        def allow_restore = false
      end
      self.has_login_hint = true
      self.global_notice = "Invented original notice"
    end
    class User
      attr_accessor :skip_email_validation, :skip_username_watched_words_validation, :required_fields_version
      attr_reader :id
      def self.exists?(*) = false
      def self.transaction = yield
      def initialize(**attributes)
        @attributes = attributes
        @id = 1
      end
      def save!(**) = clear_global_notice_if_needed
      def email_tokens = self
      def update_all(*) = true
      # Pinned #activate calls EmailToken.confirm, which saves a DIFFERENT User.
      def activate = self.class.new(admin: true, active: true).save!
      def set_automatic_groups = true
      def username = @attributes.fetch(:username)
      protected
      def clear_global_notice_if_needed
        return if id < 0
        if @attributes[:admin] && @attributes[:active] && SiteSetting.has_login_hint
          SiteSetting.has_login_hint = false
          SiteSetting.global_notice = ""
        end
      end
    end
    class UserEmail
      def self.exists?(*) = false
    end
    module UserRequiredFieldsVersion
      def self.current = 1
    end
    module Discourse
      def self.base_url = "http://127.0.0.1:18080"
      def self.system_user = Struct.new(:id).new(-1)
    end
    module ActiveRecord
      class Rollback < StandardError; end
      class Base
        def self.connection = self
        def self.select_value(sql) = sql.start_with?("SELECT current_database()") ? "discourse" : "123"
      end
    end
    ApiKeyScope = Struct.new(:resource, :action, keyword_init: true) do
      def self.default_mappings = { global: { read: { methods: [:get] } } }
    end
    class ApiKey
      attr_accessor :api_key_scopes
      def self.scope_modes = { "read_only" => 2 }
      def self.where(*) = Struct.new(:count).new(1)
      def initialize(**) = nil
      def save! = true
      def reload = self
      def read_only? = true
      def user_id = 1
      def id = 2
      def scope_mode = "read_only"
      def revoked_at = nil
      def persisted? = true
      def key = "invented-unit-key-not-a-credential"
    end
    begin
      load ARGV.fetch(0)
      preserved = SiteSetting.has_login_hint == true && SiteSetting.global_notice == "Invented original notice"
      # The exception must be per-instance: ordinary model callbacks stay active.
      User.new(admin: true, active: true).save!
      ordinary = SiteSetting.has_login_hint == false && SiteSetting.global_notice == ""
      puts "PRESERVATION_JSON:" + JSON.generate(preserved: preserved, ordinary_callback_active: ordinary)
    rescue Exception => error
      allowed = %w[NameError NoMethodError ArgumentError TypeError RuntimeError SystemExit]
      klass = allowed.include?(error.class.name) ? error.class.name : "other"
      frames = Array(error.backtrace_locations).first(4).map do |location|
        base = File.basename(location.path)
        [(%w[review_access.rb merge_inspection_access.rb -e].include?(base) ? base : "other"), location.lineno]
      end
      STDERR.puts "UNIT_FAILURE:" + JSON.generate(error_class: klass, public_locations: frames)
      exit 1
    ensure
      path = ENV.fetch("SILO_INSPECTION_KEY_DIR")
      FileUtils.remove_entry(path) if File.directory?(path)
    end
  RUBY

  def test_local_review_and_inspection_identities_preserve_settings_without_global_callback_changes
    %w[review_access.rb merge_inspection_access.rb].each do |name|
      helper = File.expand_path("../runtime/prebuilt-discourse/#{name}", __dir__)
      environment = { "SILO_BACKUP_RECORDED" => "true", "SILO_ADMIN_PASSWORD" => "invented-unit-password",
        "SILO_SITE_PORT" => "18080", "SILO_INSPECTION_ACTION" => "create",
        "SILO_INSPECTION_USERNAME" => "silo_inspect_abcdef12", "SILO_INSPECTION_DATABASE" => "discourse",
        "SILO_INSPECTION_DATABASE_OID" => "123", "SILO_INSPECTION_KEY_DIR" => "/tmp/silo-inspection-#{SecureRandom.hex(8)}" }
      out, err, status = Open3.capture3(environment, RbConfig.ruby, "-e", HARNESS, helper)
      safe = err.lines.grep(/\AUNIT_FAILURE:/).join
      assert status.success?, "#{name} failed its invented isolated harness: #{safe}"
      line = out.lines.grep(/\APRESERVATION_JSON:/)
      assert_equal 1, line.size
      assert_equal({ "preserved" => true, "ordinary_callback_active" => true }, JSON.parse(line.first.delete_prefix("PRESERVATION_JSON:")))
      assert_equal "", err
      refute File.exist?(environment.fetch("SILO_INSPECTION_KEY_DIR"))
    end
  end
end
