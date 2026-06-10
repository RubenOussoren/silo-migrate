# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
ENV["MT_NO_PLUGINS"] = "1"

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "zlib"
require "silo_migrate"

# Keep tests away from the developer's real ~/.config/silo-migrate.
ENV["SILO_MIGRATE_USER_CONFIG"] = File.join(Dir.mktmpdir("silo-migrate-test"), "user-config.env")

class SiloMigrateTest < Minitest::Test
  def with_tmp_base
    Dir.mktmpdir do |dir|
      env = {
        "SILO_MIGRATE_BASE_PATH" => File.join(dir, "customers"),
        "SILO_MIGRATE_USER_CONFIG" => File.join(dir, "user-config.env")
      }
      yield dir, env
    end
  end

  def write(path, content, mode: "w:utf-8")
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, mode) { |file| file.write(content) }
    path
  end

  def gzip_write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    Zlib::GzipWriter.open(path) { |gz| gz.write(content) }
    path
  end
end
