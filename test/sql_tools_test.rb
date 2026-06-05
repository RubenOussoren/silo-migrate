# frozen_string_literal: true

require_relative "test_helper"

class SQLToolsTest < SiloMigrateTest
  def test_dump_type_and_mysql8_collation_detection_and_fixing
    Dir.mktmpdir do |dir|
      path = write(File.join(dir, "dump.sql"), "-- MySQL dump 10.13\nCREATE TABLE t (name varchar(10)) COLLATE=utf8mb4_0900_ai_ci;\n")
      detection = SiloMigrate::SQLTools.detect_dump_type(path)
      assert_equal "mysql8", detection[:detected]
      assert_equal "mysql", detection[:recommended]

      collations = SiloMigrate::SQLTools.detect_mysql8_collations(path)
      assert_equal true, collations[:has_incompatible_collations]
      assert_equal "utf8mb4_unicode_ci", collations[:collations_found]["utf8mb4_0900_ai_ci"]
      assert_includes SiloMigrate::SQLTools.fix_mysql8_collations(File.read(path)), "utf8mb4_unicode_ci"
    end
  end

  def test_large_table_analysis
    Dir.mktmpdir do |dir|
      path = write(File.join(dir, "dump.sql"), <<~SQL)
        CREATE TABLE users (id int);
        INSERT INTO users VALUES (1),(2),(3);
        CREATE TABLE posts (id int);
        INSERT INTO posts VALUES (1);
      SQL
      analysis = SiloMigrate::SQLTools.analyze_sql_dump(path, sample_bytes: nil)
      assert_equal 2, analysis[:total_tables]
      assert_equal 3, analysis[:tables]["users"][:rows]
      assert analysis[:tables]["users"][:size] > analysis[:tables]["posts"][:size]
    end
  end

  def test_generated_column_detection_and_preprocessing
    Dir.mktmpdir do |dir|
      path = write(File.join(dir, "dump.sql"), <<~SQL)
        CREATE TABLE `items` (
          `id` int NOT NULL,
          `slug` varchar(20) GENERATED ALWAYS AS (lower(`id`)),
          `name` varchar(20)
        );
        INSERT INTO `items` (`id`,`slug`,`name`) VALUES (1,'one','One'),(2,'two','Two');
      SQL
      info = SiloMigrate::SQLTools.detect_generated_columns(path)
      assert_equal true, info[:has_generated_columns]
      assert_equal true, info[:has_problematic_inserts]
      assert_equal ["slug"], info[:tables]["items"][:columns]

      out = File.join(dir, "fixed.sql")
      result = SiloMigrate::SQLTools.preprocess_mysql_dump(path, out, info)
      assert_equal true, result[:success]
      fixed = File.read(out)
      assert_includes fixed, "(1, DEFAULT, 'One')"
      assert_includes fixed, "(2, DEFAULT, 'Two')"
    end
  end
end
