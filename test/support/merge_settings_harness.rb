# frozen_string_literal: true

# A stand-in for the parts of Rails, Discourse's SiteSetting and the stock merger that
# merge_run.rb and merge_site_settings.rb touch. Loaded with `ruby -r` in a child process.
#
# The site_settings table is in memory, seeded from TEST_DB_JSON ({name=>[value,type]}).
# Two caches behave like the real ones:
# - ActiveRecord's query cache is on (as it can be inside Rails): a repeated read returns the
#   earlier result until an ActiveRecord write clears it. A raw write (SiteSetting.write_raw,
#   like SQL through another connection) doesn't clear it; only `uncached` reads see it.
# - SiteSetting's effective authorized_extensions is only reloaded by refresh!.
# Knobs (ENV): TEST_SNAPSHOT_FILE (stands in for the fixed snapshot path), TEST_DB_OUT (final
# table written as JSON at exit), TEST_CONSTRUCTOR_FAIL=before|after,
# TEST_START_FAIL=1|schema|wrapped (the copy raises), TEST_STOCK_LOAD_FAIL=1,
# TEST_NORMALIZE=value|type (the public setter normalises the value or the data type after the
# copy), TEST_FAIL_RESTORE=1 (writes after the copy raise), TEST_FORBID_WRITES=1 (any provider
# write or refresh! ends the process with status 97: no rescue can hide it).
require "json"

$silo_copied = false
$silo_db = JSON.parse(ENV.fetch("TEST_DB_JSON", "{}"))

at_exit do
  File.write(ENV["TEST_DB_OUT"], JSON.generate($silo_db)) if ENV["TEST_DB_OUT"]
end

module PG
  def self.connect(*args, **kwargs); end

  class UndefinedColumn < StandardError; end
end

module ActiveRecord
  class StatementInvalid < StandardError; end

  class Base
    class FakeConnection
      SQL = "SELECT name, value, data_type FROM site_settings ORDER BY name"

      def initialize
        @cache = {}
        @uncached = 0
      end

      def uncached
        @uncached += 1
        yield
      ensure
        @uncached -= 1
      end

      def clear_query_cache
        @cache.clear
      end

      def select_rows(sql)
        raise "unexpected query" unless sql == SQL
        return @cache[sql].map(&:dup) if @uncached.zero? && @cache.key?(sql)

        rows = $silo_db.sort.map { |name, (value, type)| [name, value, type.to_s] }
        @cache[sql] = rows.map(&:dup) if @uncached.zero?
        rows
      end
    end

    def self.connection
      @connection ||= FakeConnection.new
    end

    def self.uncached(&block)
      connection.uncached(&block)
    end
  end
end

class SiteSetting
  DEFAULT = "jpg|jpeg|png|gif|heic|heif|webp|avif"

  class Provider
    def save(name, value, type)
      exit!(97) if ENV["TEST_FORBID_WRITES"] == "1"
      raise "PRIVATE-RESTORE-VALUE" if ENV["TEST_FAIL_RESTORE"] == "1" && $silo_copied

      ActiveRecord::Base.connection.clear_query_cache
      $silo_db[name.to_s] = [value, type]
      true
    end

    def destroy(name)
      exit!(97) if ENV["TEST_FORBID_WRITES"] == "1"
      raise "PRIVATE-RESTORE-VALUE" if ENV["TEST_FAIL_RESTORE"] == "1" && $silo_copied

      ActiveRecord::Base.connection.clear_query_cache
      $silo_db.delete(name.to_s)
    end
  end

  class TypeSupervisor
    def to_db_value(_name, value)
      [value, 8]
    end
  end

  class << self
    def provider = (@provider ||= Provider.new)
    def type_supervisor = TypeSupervisor.new

    def refresh!
      exit!(97) if ENV["TEST_FORBID_WRITES"] == "1"
      @current = nil
    end

    def authorized_extensions
      @current ||= $silo_db.dig("authorized_extensions", 0) || DEFAULT
    end

    def authorized_extensions=(value)
      add_override!(:authorized_extensions, value)
    end

    def add_override!(name, value)
      type = 8
      value = "#{value}|normalised" if ENV["TEST_NORMALIZE"] == "value" && $silo_copied
      type = 9 if ENV["TEST_NORMALIZE"] == "type" && $silo_copied
      provider.save(name.to_s, value, type)
      @current = value if name.to_s == "authorized_extensions"
    end

    def remove_override!(name)
      provider.destroy(name.to_s)
      @current = DEFAULT if name.to_s == "authorized_extensions"
    end

    # For layers in tests: another setting, written the way any code could.
    def write_other(name, value)
      provider.save(name, value, 1)
    end

    # Like SQL through another connection: no ActiveRecord cache is told.
    def write_raw(name, value, type)
      $silo_db[name.to_s] = [value, type]
    end
  end
end

module BulkImport
  class DiscourseMerger
    def initialize
      puts "EVENT:constructor"
      raise "PRIVATE-CONSTRUCTOR-VALUE #{$silo_db.dig("title", 0)}" if ENV["TEST_CONSTRUCTOR_FAIL"] == "before"

      SiteSetting.authorized_extensions = %w[jpg jpeg png gif].join("|")
      raise "PRIVATE-CONSTRUCTOR-VALUE #{$silo_db.dig("title", 0)}" if ENV["TEST_CONSTRUCTOR_FAIL"] == "after"
    end

    def start
      puts "EVENT:copy"
      puts "EVENT:copy-sees=#{SiteSetting.authorized_extensions}"
      $silo_copied = true
      raise PG::UndefinedColumn, "PRIVATE-START-VALUE #{$silo_db.dig("title", 0)}" if ENV["TEST_START_FAIL"] == "schema"
      if ENV["TEST_START_FAIL"] == "wrapped"
        begin
          raise PG::UndefinedColumn, "PRIVATE-START-VALUE #{$silo_db.dig("title", 0)}"
        rescue PG::UndefinedColumn
          raise ActiveRecord::StatementInvalid, "PRIVATE-START-VALUE #{$silo_db.dig("title", 0)}"
        end
      end
      raise ArgumentError, "PRIVATE-START-VALUE #{$silo_db.dig("title", 0)}" if ENV["TEST_START_FAIL"] == "1"
    end
  end
end

module Kernel
  alias silo_original_require require
  def require(path)
    if path == "/var/www/discourse/script/bulk_import/discourse_merger.rb" && ENV["TEST_STOCK_LOAD_FAIL"] == "1"
      raise LoadError, "PRIVATE-LOAD-VALUE"
    end
    return true if path == "pg" || path == "/var/www/discourse/script/bulk_import/discourse_merger.rb"

    silo_original_require(path)
  end
end

class File
  class << self
    alias silo_original_binread binread
    def binread(path, *rest)
      path = ENV.fetch("TEST_SNAPSHOT_FILE", "/nonexistent/snapshot") if path == "/shared/merge/site-settings.json"
      silo_original_binread(path, *rest)
    end
  end
end
