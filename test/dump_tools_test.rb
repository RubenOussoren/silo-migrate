# frozen_string_literal: true

require_relative "test_helper"

class DumpToolsTest < SiloMigrateTest
  def test_detects_plain_sql_gzip_tar_and_invalid_files
    Dir.mktmpdir do |dir|
      sql = write(File.join(dir, "dump.sql"), "-- MySQL dump\nCREATE TABLE users (id int);\n")
      gz = gzip_write(File.join(dir, "dump.sql.gz"), "-- MySQL dump\n")
      invalid = write(File.join(dir, "invalid.bin"), "\x00\x01\x02".b, mode: "wb")
      tar = File.join(dir, "archive.tar")
      system("tar", "-cf", tar, "-C", dir, "dump.sql")

      assert_equal "sql", SiloMigrate::DumpTools.detect_file_format(sql)[:format]
      assert_equal "gzip", SiloMigrate::DumpTools.detect_file_format(gz)[:format]
      tar_info = SiloMigrate::DumpTools.detect_file_format(tar)
      assert_equal "tar", tar_info[:format]
      assert_equal true, tar_info[:is_valid]
      assert_equal "unknown", SiloMigrate::DumpTools.detect_file_format(invalid)[:format]
    end
  end

  def test_extract_sql_from_tar
    Dir.mktmpdir do |dir|
      sql = write(File.join(dir, "dump.sql"), "CREATE TABLE users (id int);\n")
      tar = File.join(dir, "archive.tar")
      out = File.join(dir, "out")
      system("tar", "-cf", tar, "-C", dir, File.basename(sql))

      extracted = SiloMigrate::DumpTools.extract_sql_from_tar(tar, out)
      assert_equal "dump.sql", File.basename(extracted)
      assert_includes File.read(extracted), "CREATE TABLE"
    end
  end

  def test_verify_gzip_accepts_valid_files
    Dir.mktmpdir do |dir|
      gz = gzip_write(File.join(dir, "dump.sql.gz"), "INSERT INTO t VALUES (1);\n" * 1000)
      assert SiloMigrate::DumpTools.verify_gzip(gz)[:valid]
      assert SiloMigrate::DumpTools.verify_gzip(gz, full: true)[:valid]
    end
  end

  def test_verify_gzip_detects_truncated_files_in_full_mode
    Dir.mktmpdir do |dir|
      gz = gzip_write(File.join(dir, "dump.sql.gz"), "INSERT INTO t VALUES (1);\n" * 5000)
      File.truncate(gz, File.size(gz) / 2)
      result = SiloMigrate::DumpTools.verify_gzip(gz, full: true)
      refute result[:valid]
      refute_empty result[:message]
    end
  end

  def test_verify_gzip_rejects_non_gzip_content
    Dir.mktmpdir do |dir|
      fake = write(File.join(dir, "dump.sql.gz"), "not gzip at all")
      result = SiloMigrate::DumpTools.verify_gzip(fake)
      refute result[:valid]
      assert_includes result[:message], "magic"
    end
  end
end
