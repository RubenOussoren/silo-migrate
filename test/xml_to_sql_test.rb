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

  def test_preserves_post_body_xhtml_from_cdata_as_sql_value
    unicode = "\u{1F600}"
    body = <<~HTML.chomp
      <article class="message" data-post-id="42">
        <p>Don't normalize <strong>this</strong> XHTML & don't sanitize scripts.</p>
        <pre data-path="C:\\tmp\\post.rb">puts 'hello'
      puts "tab:\tand unicode: cafe emoji: #{unicode}"</pre>
        <script type="application/json">{"raw":"<keep>&value"}</script>
      </article>
    HTML
    raw_body = "[b]raw[/b]\n<not-html attr='still text'> & \\ backslash"
    xml = messages_xml(body: "<![CDATA[#{body}]]>", raw_body: "<![CDATA[#{raw_body}]]>")

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "messages.xml"), xml)
      output = File.join(dir, "messages.sql")
      SiloMigrate::XMLToSQLConverter.new(verbose: false).convert(Pathname(input), Pathname(output))

      sql = File.read(output)
      assert_includes sql, SiloMigrate::SQLXML.escape_sql_string(body)
      assert_includes sql, SiloMigrate::SQLXML.escape_sql_string(raw_body)
      assert_includes sql, "<script type=\"application/json\">"
      assert_includes sql, "<keep>&value"
      assert_includes sql, "tab:\\tand unicode: cafe emoji: #{unicode}"
    end
  end

  def test_preserves_escaped_post_body_xhtml_as_same_character_value
    body = "<p title=\"A & B\">Tom & Jerry's <em>escaped</em> XHTML</p>"
    raw_body = "<blockquote data-x=\"1\">raw & exact</blockquote>"
    xml = messages_xml(body: xml_escape(body), raw_body: xml_escape(raw_body))

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "messages.xml"), xml)
      output = File.join(dir, "messages.sql")
      SiloMigrate::XMLToSQLConverter.new(verbose: false).convert(Pathname(input), Pathname(output))

      sql = File.read(output)
      assert_includes sql, SiloMigrate::SQLXML.escape_sql_string(body)
      assert_includes sql, SiloMigrate::SQLXML.escape_sql_string(raw_body)
      refute_includes sql, "&lt;em&gt;"
      refute_includes sql, "&amp;amp;"
    end
  end

  def test_xml_entity_repair_does_not_rewrite_post_body_value
    body = "community links: /a?x=1&y=2 and escaped &amp; entity"
    xml = messages_xml(body: body, raw_body: "")

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "messages.xml"), xml)
      output = File.join(dir, "messages.sql")
      SiloMigrate::XMLToSQLConverter.new(verbose: false).convert(Pathname(input), Pathname(output))

      sql = File.read(output)
      assert_includes sql, SiloMigrate::SQLXML.escape_sql_string("community links: /a?x=1&y=2 and escaped & entity")
    end
  end

  def test_scrubs_invalid_xml_controls_inside_text_and_cdata_with_audit_report
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="messages">
            <field Field="id" Type="int" Null="NO" Key="PRI" />
            <field Field="subject" Type="text" Null="YES" />
            <field Field="body" Type="text" Null="YES" />
          </table_structure>
          <table_data name="messages">
            <row>
              <field name="id">1</field>
              <field name="subject">bad\x1Bsubject</field>
              <field name="body"><![CDATA[before\x0C<strong>keep</strong>after]]></field>
            </row>
          </table_data>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "messages.xml"), xml)
      output = File.join(dir, "messages.sql")
      stats = SiloMigrate::XMLToSQLConverter.new(verbose: false).convert(Pathname(input), Pathname(output))

      sql = File.read(output)
      assert_equal 2, stats[:invalid_xml_chars_removed]
      assert_includes sql, "'badsubject', 'before<strong>keep</strong>after'"

      summary_path = "#{output}.invalid-xml-chars.json"
      events_path = "#{output}.invalid-xml-chars.events.jsonl"
      assert File.exist?(summary_path)
      assert File.exist?(events_path)

      summary = JSON.parse(File.read(summary_path))
      assert_equal true, summary.fetch("success")
      assert_equal 2, summary.fetch("total_scrubbed")
      assert_equal 2, summary.fetch("per_file_totals").fetch(input)
      assert_equal 1, summary.fetch("per_codepoint_totals").fetch("U+001B")
      assert_equal 1, summary.fetch("per_codepoint_totals").fetch("U+000C")

      events = File.readlines(events_path).map { |line| JSON.parse(line) }
      assert_equal [xml.b.index("\x1B"), xml.b.index("\x0C")], events.map { |event| event.fetch("input_byte_offset") }
      assert_equal %w[U+001B U+000C], events.map { |event| event.fetch("codepoint") }
      assert_equal ["removed", "removed"], events.map { |event| event.fetch("action") }
      report_text = File.read(summary_path) + File.read(events_path)
      refute_includes report_text, "badsubject"
      refute_includes report_text, "<strong>keep</strong>"
      refute_includes report_text, "before"
      refute_includes report_text, "after"
    end
  end

  def test_invalid_xml_audit_offsets_stay_raw_after_skipping_excluded_table_body
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="user_log"><field Field="id" Type="int" Null="NO" Key="PRI" /></table_structure>
          <table_data name="user_log"><row><field name="id">skipped #{'x' * 512}</field></row></table_data>
          <table_structure name="messages"><field Field="body" Type="text" Null="YES" /></table_structure>
          <table_data name="messages"><row><field name="body">bad\x1Bbody</field></row></table_data>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "messages.xml"), xml)
      output = File.join(dir, "messages.sql")
      stats = SiloMigrate::XMLToSQLConverter.new(exclude_tables: ["user_log"], verbose: false).convert(Pathname(input), Pathname(output))

      assert_equal 1, stats[:invalid_xml_chars_removed]
      events = File.readlines("#{output}.invalid-xml-chars.events.jsonl").map { |line| JSON.parse(line) }
      assert_equal [xml.b.index("\x1B")], events.map { |event| event.fetch("input_byte_offset") }
    end
  end

  def test_no_scrub_invalid_xml_controls_fails_with_actionable_error
    xml = messages_xml(body: "<![CDATA[before\x1Bafter]]>", raw_body: "")

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "messages.xml"), xml)
      output = File.join(dir, "messages.sql")

      error = assert_raises(SiloMigrate::UsageError) do
        SiloMigrate::XMLToSQLConverter.new(verbose: false, scrub_invalid_xml_chars: false).convert(Pathname(input), Pathname(output))
      end

      assert_includes error.message, "Invalid XML control character U+001B"
      assert_includes error.message, "input byte offset #{xml.b.index("\x1B")}"
      assert_includes error.message, "--no-scrub-invalid-xml-chars"
      refute File.exist?(output)
    end
  end

  def test_valid_xml_controls_are_preserved_and_do_not_create_report
    body = "tab:\tline\ncr:&#13;"
    xml = messages_xml(body: body, raw_body: "")

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "messages.xml"), xml)
      output = File.join(dir, "messages.sql")
      stats = SiloMigrate::XMLToSQLConverter.new(verbose: false).convert(Pathname(input), Pathname(output))

      assert_equal 0, stats[:invalid_xml_chars_removed]
      assert_includes File.read(output), "'tab:\\tline\\ncr:\\r'"
      refute File.exist?("#{output}.invalid-xml-chars.json")
      refute File.exist?("#{output}.invalid-xml-chars.events.jsonl")
    end
  end

  def test_invalid_xml_report_is_marked_failed_when_conversion_fails_later
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_data name="messages">
            <row><field name="body">bad\x1Bbody</field></row>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "bad.xml"), xml)
      output = File.join(dir, "bad.sql")

      assert_raises(REXML::ParseException) do
        SiloMigrate::XMLToSQLConverter.new(verbose: false).convert(Pathname(input), Pathname(output))
      end

      summary = JSON.parse(File.read("#{output}.invalid-xml-chars.json"))
      assert_equal false, summary.fetch("success")
      assert_equal 1, summary.fetch("total_scrubbed")
      assert File.exist?("#{output}.invalid-xml-chars.events.jsonl")
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

  def test_excluded_table_body_is_skipped_before_later_included_table
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="user_log">
            <field Field="id" Type="int" Null="NO" Key="PRI" />
          </table_structure>
          <table_data name="user_log">
            <row><field name="id">1</field></row>
            <!-- #{"x" * 4096} -->
          </table_data>
          <table_structure name="messages">
            <field Field="id" Type="int" Null="NO" Key="PRI" />
          </table_structure>
          <table_data name="messages"><row><field name="id">9</field></row></table_data>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      output = File.join(dir, "dump.sql")
      snapshots = []

      stats = SiloMigrate::XMLToSQLConverter.new(exclude_tables: ["user_log"], verbose: false).convert(
        Pathname(input),
        Pathname(output),
        progress_callback: proc { |snapshot| snapshots << snapshot },
        progress_interval: 0
      )

      sql = File.read(output)
      assert_equal 1, stats[:tables_processed]
      assert_equal 1, stats[:tables_skipped]
      assert_operator stats[:excluded_table_data_bytes_skipped], :>, 4096
      refute_includes sql, "CREATE TABLE `user_log`"
      refute_includes sql, "INSERT INTO `user_log`"
      assert_includes sql, "CREATE TABLE `messages`"
      assert_includes sql, "INSERT INTO `messages`"
      assert snapshots.any? { |snapshot| snapshot[:current_xml_table] == "user_log" && snapshot[:current_xml_table_included] == false && snapshot[:rows_processed].zero? && snapshot[:tables_processed].zero? }
      assert snapshots.any? { |snapshot| snapshot[:current_xml_table] == "messages" && snapshot[:current_xml_table_included] == true && snapshot[:tables_processed] == 1 }
      assert snapshots.any? { |snapshot| snapshot[:excluded_table_data_bytes_skipped].to_i.positive? }
    end
  end

  def test_malformed_xml_inside_excluded_table_body_does_not_fail_conversion
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="user_log"><field Field="id" Type="int" Null="NO" Key="PRI" /></table_structure>
          <table_data name="user_log">
            <row><field name="id">1</field><field name="bad"><not_closed></field></row>
          </table_data>
          <table_structure name="messages"><field Field="id" Type="int" Null="NO" Key="PRI" /></table_structure>
          <table_data name="messages"><row><field name="id">2</field></row></table_data>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      output = File.join(dir, "dump.sql")

      stats = SiloMigrate::XMLToSQLConverter.new(exclude_tables: ["user_log"], verbose: false).convert(Pathname(input), Pathname(output))

      assert_equal 1, stats[:rows_processed]
      assert_includes File.read(output), "INSERT INTO `messages`"
    end
  end

  def test_invalid_xml_controls_inside_excluded_table_body_are_not_scrubbed_or_audited
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="user_log"><field Field="id" Type="int" Null="NO" Key="PRI" /></table_structure>
          <table_data name="user_log"><row><field name="id">bad\x1Bvalue</field></row></table_data>
          <table_structure name="messages"><field Field="id" Type="int" Null="NO" Key="PRI" /></table_structure>
          <table_data name="messages"><row><field name="id">2</field></row></table_data>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      output = File.join(dir, "dump.sql")

      stats = SiloMigrate::XMLToSQLConverter.new(exclude_tables: ["user_log"], verbose: false, scrub_invalid_xml_chars: false).convert(Pathname(input), Pathname(output))

      assert_equal 0, stats[:invalid_xml_chars_removed]
      refute File.exist?("#{output}.invalid-xml-chars.json")
      assert_includes File.read(output), "INSERT INTO `messages`"
    end
  end

  def test_excluded_table_skip_scanner_ignores_nested_end_text_until_real_close
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="user_log"><field Field="id" Type="int" Null="NO" Key="PRI" /></table_structure>
          <table_data name="user_log">
            <row data="</table_data>"><field name="id"><![CDATA[not the end </table_data>]]></field></row>
            <!-- not the end </table_data> -->
            <?target not the end </table_data> ?>
          </table_data>
          <table_structure name="messages"><field Field="id" Type="int" Null="NO" Key="PRI" /></table_structure>
          <table_data name="messages"><row><field name="id">2</field></row></table_data>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      output = File.join(dir, "dump.sql")

      stats = SiloMigrate::XMLToSQLConverter.new(exclude_tables: ["user_log"], verbose: false).convert(Pathname(input), Pathname(output))

      assert_operator stats[:excluded_table_data_bytes_skipped], :>, 100
      assert_includes File.read(output), "INSERT INTO `messages`"
    end
  end

  def test_missing_excluded_table_data_close_reports_table_and_file
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="user_log"><field Field="id" Type="int" Null="NO" Key="PRI" /></table_structure>
          <table_data name="user_log"><row><field name="id">1</field></row>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      output = File.join(dir, "dump.sql")

      error = assert_raises(SiloMigrate::UsageError) do
        SiloMigrate::XMLToSQLConverter.new(exclude_tables: ["user_log"], verbose: false).convert(Pathname(input), Pathname(output))
      end

      assert_includes error.message, "user_log"
      assert_includes error.message, input
      assert_includes error.message, "Missing closing </table_data>"
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

  def test_discovers_table_options_metadata
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="email_tracking2">
            <field Field="id" Type="int" Null="NO" Key="PRI" />
            <options Name="email_tracking2" Rows="12345" Data_length="67108864" Index_length="8388608" />
          </table_structure>
          <table_structure name="users">
            <field Field="id" Type="int" Null="NO" Key="PRI" />
          </table_structure>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      result = SiloMigrate::XMLTableDiscovery.new.discover(Pathname(input))

      assert_equal %w[email_tracking2 users], result.tables
      assert_equal({ rows: 12_345, data_length: 67_108_864, index_length: 8_388_608 }, result.table_metadata.fetch("email_tracking2"))
      assert_equal({ rows: 12_345, data_length: 67_108_864, index_length: 8_388_608 }, result.files.first.table_metadata.fetch("email_tracking2"))
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

  def test_table_discovery_accepts_single_and_double_quoted_name_attributes
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name='single_quote' />
          <table_data name="double_quote"><row /></table_data>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      result = SiloMigrate::XMLTableDiscovery.new.discover(Pathname(input))

      assert_equal %w[double_quote single_quote], result.tables
    end
  end

  def test_table_discovery_handles_tags_split_across_chunks
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="split_tag" />
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      result = SiloMigrate::XMLTableDiscovery.new(chunk_size: 7).discover(Pathname(input))

      assert_equal ["split_tag"], result.tables
    end
  end

  def test_table_discovery_uses_table_data_when_structure_is_absent
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_data name="rows_only"><row><field name="id">1</field></row></table_data>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      result = SiloMigrate::XMLTableDiscovery.new.discover(Pathname(input))

      assert_equal ["rows_only"], result.tables
    end
  end

  def test_table_discovery_can_stop_after_byte_limit
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="early" />
          #{"x" * 200}
          <table_structure name="late" />
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      result = SiloMigrate::XMLTableDiscovery.new(chunk_size: 32, max_bytes: 128).discover(Pathname(input))

      assert_equal ["early"], result.tables
      assert_equal 128, result.bytes_scanned
      assert_equal true, result.truncated
      assert_equal true, result.files.first.truncated
    end
  end

  def test_table_discovery_ignores_table_like_text_inside_cdata
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="users" />
          <table_data name="users">
            <row><field name="body"><![CDATA[<table_data name="not_a_table">]]></field></row>
          </table_data>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      result = SiloMigrate::XMLTableDiscovery.new(chunk_size: 11).discover(Pathname(input))

      assert_equal ["users"], result.tables
    end
  end

  def test_table_discovery_finds_tables_after_large_table_data_block
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="early" />
          <table_data name="early">
            <row><field name="body">#{"x" * 4096}</field></row>
          </table_data>
          <table_structure name="late" />
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      result = SiloMigrate::XMLTableDiscovery.new(chunk_size: 64).discover(Pathname(input))

      assert_equal %w[early late], result.tables
      assert_equal false, result.truncated
    end
  end

  def test_table_discovery_sorted_tables_use_total_size_descending
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          #{discovery_structure_xml("small", rows: 100, data_length: 10, index_length: 5)}
          #{discovery_structure_xml("big", rows: 10, data_length: 100, index_length: 10)}
          #{discovery_structure_xml("middle", rows: 1_000, data_length: 40, index_length: 10)}
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      result = SiloMigrate::XMLTableDiscovery.new.discover(Pathname(input))

      assert_equal %w[big middle small], result.sorted_tables
    end
  end

  def test_table_discovery_sorted_tables_use_rows_as_secondary_sort
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          #{discovery_structure_xml("same_size_low_rows", rows: 5, data_length: 100, index_length: 10)}
          #{discovery_structure_xml("same_size_high_rows", rows: 50, data_length: 90, index_length: 20)}
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      result = SiloMigrate::XMLTableDiscovery.new.discover(Pathname(input))

      assert_equal %w[same_size_high_rows same_size_low_rows], result.sorted_tables
    end
  end

  def test_table_discovery_sorted_tables_place_unsized_tables_after_sized_tables
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="z_unsized" />
          #{discovery_structure_xml("sized", rows: 1, data_length: 1, index_length: 0)}
          <table_structure name="a_unsized" />
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      result = SiloMigrate::XMLTableDiscovery.new.discover(Pathname(input))

      assert_equal %w[sized a_unsized z_unsized], result.sorted_tables
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
      assert snapshots.any? { |snapshot| snapshot[:event] == :rows && snapshot[:current_table] == "users" }
      assert snapshots.any? { |snapshot| snapshot[:event] == :table && snapshot[:tables_processed].positive? }
    end
  end

  def test_first_table_and_row_progress_ignore_throttle
    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), XML)
      output = File.join(dir, "dump.sql")
      snapshots = []

      SiloMigrate::XMLToSQLConverter.new(batch_size: 1000, verbose: false).convert(
        Pathname(input),
        Pathname(output),
        progress_callback: proc { |snapshot| snapshots << snapshot },
        progress_interval: 3600
      )

      assert_equal [:start, :file_start, :table, :rows, :complete], snapshots.map { |snapshot| snapshot[:event] } & [:start, :file_start, :table, :rows, :complete]
      assert snapshots.any? { |snapshot| snapshot[:event] == :table && snapshot[:tables_processed] == 1 }
      assert snapshots.any? { |snapshot| snapshot[:event] == :rows && snapshot[:rows_processed] == 1 }
    end
  end

  def test_warns_when_bytes_advance_without_tables_or_rows
    Dir.mktmpdir do |dir|
      body = "x" * 2048
      input = write(File.join(dir, "dump.xml"), "<?xml version=\"1.0\"?><mysqldump><!-- #{body} --></mysqldump>")
      output = File.join(dir, "dump.sql")
      snapshots = []

      stats = SiloMigrate::XMLToSQLConverter.new(verbose: false, zero_progress_warning_bytes: 128).convert(
        Pathname(input),
        Pathname(output),
        progress_callback: proc { |snapshot| snapshots << snapshot },
        progress_interval: 3600
      )

      warning = snapshots.find { |snapshot| snapshot[:event] == :warning }
      refute_nil warning
      assert_includes warning[:message], "without discovering any tables or rows"
      assert_includes warning[:message], "Check: input path, command path, file format, current checkout."
      assert_includes warning[:message], input
      assert_includes warning[:message], "bin/silo-migrate convert-xml"
      assert_equal [warning[:message]], stats[:warnings]
    end
  end

  def test_excluding_first_large_table_does_not_warn_as_zero_progress
    xml = <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="email_tracking2">
            <field Field="id" Type="int" Null="NO" Key="PRI" />
          </table_structure>
          <table_data name="email_tracking2">
            <row><field name="id">1</field></row>
            <!-- #{"x" * 2048} -->
          </table_data>
        </database>
      </mysqldump>
    XML

    Dir.mktmpdir do |dir|
      input = write(File.join(dir, "dump.xml"), xml)
      output = File.join(dir, "dump.sql")
      snapshots = []

      stats = SiloMigrate::XMLToSQLConverter.new(exclude_tables: ["email_tracking2"], verbose: false, zero_progress_warning_bytes: 128).convert(
        Pathname(input),
        Pathname(output),
        progress_callback: proc { |snapshot| snapshots << snapshot },
        progress_interval: 0
      )

      assert_equal 1, stats[:tables_observed]
      assert_equal 0, stats[:tables_processed]
      assert_empty stats[:warnings]
      refute snapshots.any? { |snapshot| snapshot[:event] == :warning }
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

  private

  def discovery_structure_xml(name, rows:, data_length:, index_length:)
    <<~XML
      <table_structure name="#{name}">
        <field Field="id" Type="int" Null="NO" Key="PRI" />
        <options Name="#{name}" Rows="#{rows}" Data_length="#{data_length}" Index_length="#{index_length}" />
      </table_structure>
    XML
  end

  def messages_xml(body:, raw_body:)
    <<~XML
      <?xml version="1.0"?>
      <mysqldump>
        <database name="forum">
          <table_structure name="messages">
            <field Field="id" Type="int" Null="NO" Key="PRI" />
            <field Field="subject" Type="varchar(255)" Null="YES" />
            <field Field="body" Type="text" Null="YES" />
            <field Field="raw_body" Type="text" Null="YES" />
          </table_structure>
          <table_data name="messages">
            <row>
              <field name="id">1</field>
              <field name="subject">Synthetic post</field>
              <field name="body">#{body}</field>
              <field name="raw_body">#{raw_body}</field>
            </row>
          </table_data>
        </database>
      </mysqldump>
    XML
  end

  def xml_escape(value)
    value.gsub("&", "&amp;")
         .gsub("<", "&lt;")
         .gsub(">", "&gt;")
         .gsub('"', "&quot;")
         .gsub("'", "&apos;")
  end
end
