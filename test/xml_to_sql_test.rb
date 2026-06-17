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
      assert_includes sql, "-- XML dumps are generated in autocommit mode"
      assert_includes sql, "SET FOREIGN_KEY_CHECKS = 0"
      assert_includes sql, "SET UNIQUE_CHECKS = 0"
      refute_includes sql, "SET AUTOCOMMIT = 0"
      refute_match(/^\s*COMMIT;\s*$/i, sql)
      assert_match(/SET FOREIGN_KEY_CHECKS = 1;\nSET UNIQUE_CHECKS = 1;\n\z/, sql)
      refute_includes sql, "CREATE TABLE `logs`"
    end
  end

  def test_empty_values_in_nullable_unique_columns_become_null
    xml = <<~UNIQUE_XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="accounts">
            <field Field="id" Type="int" Null="NO" Key="PRI" Extra="auto_increment" />
            <field Field="uuid" Type="char(36)" Null="YES" Key="UNI" />
            <field Field="code" Type="varchar(10)" Null="NO" Key="UNI" />
            <field Field="bio" Type="varchar(255)" Null="YES" />
          </table_structure>
          <table_data name="accounts">
            <row><field name="id">1</field><field name="uuid"></field><field name="code"></field><field name="bio"></field></row>
            <row><field name="id">2</field><field name="uuid"></field><field name="code">x1</field><field name="bio">hi</field></row>
          </table_data>
        </database>
      </mysqldump>
    UNIQUE_XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      output = File.join(dir, "dump.sql")
      SiloMigrate::XMLToSQLConverter.new(verbose: false).convert(Pathname(input), Pathname(output))

      sql = File.read(output)
      assert_includes sql, "UNIQUE KEY `uk_uuid` (`uuid`)"
      # Nullable unique column: empty values must become NULL so the unique
      # index accepts repeated "absent" values. Non-unique nullable columns
      # (bio) and NOT NULL unique columns (code) keep the '' behavior.
      assert_includes sql, "(1, NULL, '', '')"
      assert_includes sql, "(2, NULL, 'x1', 'hi')"
    end
  end

  def test_include_tables_filters_structures_and_rows
    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), XML)
      output = File.join(dir, "dump.sql")
      stats = SiloMigrate::XMLToSQLConverter.new(include_tables: ["users"], verbose: false).convert(Pathname(input), Pathname(output))

      sql = File.read(output)
      assert_equal 1, stats[:tables_processed]
      assert_equal 2, stats[:rows_processed]
      assert_includes sql, "CREATE TABLE `users`"
      assert_includes sql, "INSERT INTO `users`"
      refute_includes sql, "CREATE TABLE `logs`"
      refute_includes sql, "INSERT INTO `logs`"
    end
  end

  def test_exclude_tables_filters_structures_and_rows
    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), XML)
      output = File.join(dir, "dump.sql")
      stats = SiloMigrate::XMLToSQLConverter.new(exclude_tables: ["logs"], verbose: false).convert(Pathname(input), Pathname(output))

      sql = File.read(output)
      assert_equal 1, stats[:tables_processed]
      assert_equal 2, stats[:rows_processed]
      assert_includes sql, "CREATE TABLE `users`"
      assert_includes sql, "INSERT INTO `users`"
      refute_includes sql, "CREATE TABLE `logs`"
      refute_includes sql, "INSERT INTO `logs`"
    end
  end

  def test_include_and_exclude_table_filters_apply_conservatively
    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), XML)
      output = File.join(dir, "dump.sql")
      stats = SiloMigrate::XMLToSQLConverter.new(include_tables: %w[users logs], exclude_tables: ["logs"], verbose: false).convert(Pathname(input), Pathname(output))

      sql = File.read(output)
      assert_equal 1, stats[:tables_processed]
      assert_equal 2, stats[:rows_processed]
      assert_includes sql, "CREATE TABLE `users`"
      refute_includes sql, "CREATE TABLE `logs`"
      refute_includes sql, "INSERT INTO `logs`"
    end
  end

  def test_discovers_tables_from_single_xml_file
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="users">
            <field Field="id" Type="int" Null="NO" Key="PRI" />
          </table_structure>
          <table_data name="logs"><row><field name="id">1</field></row></table_data>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      result = SiloMigrate::XMLTableDiscovery.new.discover(Pathname(input))

      assert_equal %w[logs users], result.tables
      assert_equal 1, result.files.length
      assert_equal 2, result.files.first.count
    end
  end

  def test_discovers_tables_from_gzip_xml
    Dir.mktmpdir do |dir|
      input = gzip_write(File.join(dir, "dump.xml.gz"), XML)
      result = SiloMigrate::XMLTableDiscovery.new.discover(Pathname(input))

      assert_equal %w[logs users], result.tables
      assert_equal 1, result.files.length
      assert_equal "dump.xml.gz", result.files.first.path.basename.to_s
    end
  end

  def test_table_discovery_applies_file_exclusions
    Dir.mktmpdir do |dir|
      write(File.join(dir, "users.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump><database name="forum"><table_structure name="users" /></database></mysqldump>
      XML
      write(File.join(dir, "logs.xml"), <<~XML)
        <?xml version="1.0"?>
        <mysqldump><database name="forum"><table_structure name="logs" /></database></mysqldump>
      XML

      result = SiloMigrate::XMLTableDiscovery.new(exclude_files: ["logs"]).discover(Pathname(dir))

      assert_equal ["users"], result.tables
      assert_equal 2, result.files_found
      assert_equal 1, result.files_skipped
      assert_equal ["users.xml"], result.files.map { |file| file.path.basename.to_s }
    end
  end

  def test_rejects_non_positive_batch_size
    error = assert_raises(SiloMigrate::UsageError) do
      SiloMigrate::XMLToSQLConverter.new(batch_size: 0, verbose: false)
    end

    assert_includes error.message, "XML batch size must be greater than 0"
  end

  def test_gzip_input_output_schema_only_and_file_filters
    Dir.mktmpdir do |dir|
      gzip_write(File.join(dir, "users.xml.gz"), XML)
      gzip_write(File.join(dir, "logs.xml.gz"), XML)
      output = File.join(dir, "out.sql.gz")
      snapshots = []
      stats = SiloMigrate::XMLToSQLConverter.new(include_files: ["users"], schema_only: true, verbose: false).convert(
        Pathname(dir),
        Pathname(output),
        progress_callback: proc { |snapshot| snapshots << snapshot },
        progress_interval: 0
      )
      sql = Zlib::GzipReader.open(output, &:read)

      assert_equal 1, stats[:files_processed]
      assert_includes sql, "CREATE TABLE `users`"
      refute_includes sql, "INSERT INTO"
      assert_equal :complete, snapshots.last[:event]
      assert snapshots.any? { |snapshot| snapshot[:current_file]&.fetch(:name) == "users.xml.gz" }
    end
  end

  def test_progress_callback_reports_files_bytes_rows_and_tables
    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), XML)
      output = File.join(dir, "dump.sql")
      snapshots = []

      SiloMigrate::XMLToSQLConverter.new(batch_size: 1, verbose: false).convert(
        Pathname(input),
        Pathname(output),
        progress_callback: proc { |snapshot| snapshots << snapshot },
        progress_interval: 0
      )

      assert_equal :start, snapshots.first[:event]
      assert_equal :complete, snapshots.last[:event]
      assert snapshots.any? { |snapshot| snapshot[:event] == :bytes && snapshot[:current_file][:bytes_read].positive? }
      assert snapshots.any? { |snapshot| snapshot[:event] == :rows && snapshot[:rows_processed].positive? }
      assert snapshots.any? { |snapshot| snapshot[:event] == :table && snapshot[:tables_processed].positive? }
    end
  end

  def test_exclude_files_accepts_base_names_and_full_file_names
    Dir.mktmpdir do |dir|
      write(File.join(dir, "users.xml"), XML)
      write(File.join(dir, "logs.xml"), XML.gsub("users", "members"))
      write(File.join(dir, "admins.xml"), XML.gsub("users", "admins"))
      output = File.join(dir, "dump.sql")
      snapshots = []

      stats = SiloMigrate::XMLToSQLConverter.new(exclude_files: ["users", "logs.xml"], verbose: false).convert(
        Pathname(dir),
        Pathname(output),
        progress_callback: proc { |snapshot| snapshots << snapshot },
        progress_interval: 0
      )

      sql = File.read(output)
      assert_equal 1, stats[:files_processed]
      assert_equal 2, stats[:files_skipped]
      assert_equal :start, snapshots.first[:event]
      assert_equal 1, snapshots.first[:file_count]
      assert snapshots.first[:total_input_bytes].positive?
      assert_includes sql, "CREATE TABLE `admins`"
      refute_includes sql, "CREATE TABLE `users`"
      refute_includes sql, "CREATE TABLE `members`"
    end
  end

  def test_conversion_does_not_slurp_xml_with_file_read
    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), XML)
      output = File.join(dir, "dump.sql")
      file_singleton = class << File; self; end
      verbose = $VERBOSE
      $VERBOSE = nil
      file_singleton.alias_method :read_without_xml_stream_test, :read
      file_singleton.define_method(:read) do |*|
        raise "XML conversion must stream input instead of using File.read"
      end
      $VERBOSE = verbose

      SiloMigrate::XMLToSQLConverter.new(verbose: false).convert(Pathname(input), Pathname(output))
    ensure
      if file_singleton&.method_defined?(:read_without_xml_stream_test)
        verbose = $VERBOSE
        $VERBOSE = nil
        file_singleton.alias_method :read, :read_without_xml_stream_test
        file_singleton.remove_method :read_without_xml_stream_test
        $VERBOSE = verbose
      end
    end
  end

  def test_streaming_sanitizer_preserves_multiline_cdata
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="messages">
            <field Field="id" Type="int" Null="NO" Key="PRI" />
            <field Field="body" Type="text" Null="YES" />
          </table_structure>
          <table_data name="messages">
            <row><field name="id">1</field><field name="body">intro & escaped &amp; <![CDATA[line 1 & raw
      line 2 <tag>]]> outro & tail</field></row>
          </table_data>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      output = File.join(dir, "dump.sql")
      SiloMigrate::XMLToSQLConverter.new(verbose: false).convert(Pathname(input), Pathname(output))

      sql = File.read(output)
      assert_includes sql, "'intro & escaped & line 1 & raw\\nline 2 <tag> outro & tail'"
    end
  end

  def test_atomic_conversion_renames_temp_output_after_success
    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), XML)
      output = File.join(dir, "dump.sql")

      SiloMigrate::XMLToSQLConverter.new(verbose: false).convert(Pathname(input), Pathname(output))

      assert File.exist?(output)
      refute File.exist?("#{output}.tmp")
      assert_includes File.read(output), "CREATE TABLE `users`"
    end
  end

  def test_atomic_conversion_preserves_existing_output_after_failure
    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "bad.xml"), "<mysqldump><database><table_data name=\"users\"><row>")
      output = File.join(dir, "dump.sql")
      write(output, "existing output\n")

      assert_raises(REXML::ParseException) do
        SiloMigrate::XMLToSQLConverter.new(verbose: false).convert(Pathname(input), Pathname(output))
      end

      assert_equal "existing output\n", File.read(output)
      refute File.exist?("#{output}.tmp")
    end
  end
end
