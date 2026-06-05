# frozen_string_literal: true

require_relative "test_helper"

class XMLToSQLTest < SiloMigrateTest
  XML = <<~XML
    <?xml version="1.0"?>
    <mysqldump>
      <database name="forum">
        <table_structure name="users">
          <field Field="id" Type="int" Null="NO" Key="PRI" Extra="auto_increment" />
          <field Field="name" Type="varchar(255)" Null="YES" />
        </table_structure>
        <table_data name="users">
          <row><field name="id">1</field><field name="name">Tom & Jerry</field></row>
          <row><field name="id">2</field><field name="name"><![CDATA[A & B]]></field></row>
        </table_data>
        <table_structure name="logs">
          <field Field="id" Type="int" Null="NO" Key="PRI" />
        </table_structure>
        <table_data name="logs"><row><field name="id">1</field></row></table_data>
      </database>
    </mysqldump>
  XML

  def test_converts_xml_with_malformed_ampersands_and_batching
    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), XML)
      output = File.join(dir, "dump.sql")
      stats = SiloMigrate::XMLToSQLConverter.new(batch_size: 1, exclude_tables: ["logs"], verbose: false).convert(Pathname(input), Pathname(output))

      sql = File.read(output)
      assert_equal 1, stats[:tables_processed]
      assert_equal 2, stats[:rows_processed]
      assert_includes sql, "CREATE TABLE `users`"
      assert_includes sql, "'Tom & Jerry'"
      assert_includes sql, "'A & B'"
      refute_includes sql, "CREATE TABLE `logs`"
    end
  end

  def test_gzip_input_output_schema_only_and_file_filters
    Dir.mktmpdir do |dir|
      gzip_write(File.join(dir, "users.xml.gz"), XML)
      gzip_write(File.join(dir, "logs.xml.gz"), XML)
      output = File.join(dir, "out.sql.gz")
      stats = SiloMigrate::XMLToSQLConverter.new(include_files: ["users"], schema_only: true, verbose: false).convert(Pathname(dir), Pathname(output))
      sql = Zlib::GzipReader.open(output, &:read)

      assert_equal 1, stats[:files_processed]
      assert_includes sql, "CREATE TABLE `users`"
      refute_includes sql, "INSERT INTO"
    end
  end
end
