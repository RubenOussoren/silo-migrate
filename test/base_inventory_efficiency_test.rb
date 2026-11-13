# frozen_string_literal: true
require_relative "test_helper"

class BaseInventoryEfficiencyTest < Minitest::Test
  CHUNK = 64 * 1024
  HEADER = "COPY public.schema_migrations (version) FROM stdin;\n"
  VERSIONS = %w[20261104011110 20261109000000].freeze
  BLOCK = "#{HEADER}#{VERSIONS.reverse.join("\n")}\n#{VERSIONS.first}\n\\.\n"

  def scan(sql, suffix: "", corrupt: nil)
    Dir.mktmpdir("invented-inventory-test") do |dir|
      path = File.join(dir, "invented.sql.gz")
      Zlib::GzipWriter.open(path) { |gzip| gzip.write(sql) }
      if corrupt
        bytes = File.binread(path)
        bytes = corrupt.call(bytes)
        File.binwrite(path, bytes)
      end
      File.open(path, "ab") { |file| file.write(suffix) }
      Object.new.extend(SiloMigrate::Services::StandardReviewRun).send(:base_site_dump_migrations!, path)
    end
  end

  def invalid(sql, **options)
    error = assert_raises(SiloMigrate::StandardWorkflowError) { scan(sql, **options) }
    assert_equal "STANDARD_BASE_SITE_INVALID", error.code
  end

  def test_many_short_rows_before_and_after_copy
    rows = "42\tinvented row\n" * 20_000
    assert_equal VERSIONS, scan(rows + BLOCK + rows)
  end

  def test_every_header_split_including_marker_and_pending_whitespace
    [HEADER, " \t#{HEADER.rstrip}\r\n"].each do |header|
      (1...header.bytesize).each do |split|
        prefix = "x" * (CHUNK - split - 1) + "\n"
        assert_equal VERSIONS, scan(prefix + header + VERSIONS.join("\n") + "\n\\.\n"), "split #{split}"
      end
    end
  end

  def test_copy_header_without_public_qualifier_and_stripped_values
    assert_equal VERSIONS, scan("\tCOPY schema_migrations (version) FROM stdin; \r\n  #{VERSIONS.first}\t\r\n\t#{VERSIONS.last} \n \\. \r\n")
  end

  def test_version_and_terminator_split_across_reader_boundaries
    ["#{VERSIONS.first}\n", "\\.\n"].each do |line|
      (1...line.bytesize).each do |split|
        content = HEADER + "#{VERSIONS.first}\n"
        # Extra ignored lines position the COPY block so its target line splits.
        prefix = "x" * (CHUNK - split - content.bytesize - 1) + "\n"
        ending = line == "\\.\n" ? line : line + "\\.\n"
        assert_equal [VERSIONS.first], scan(prefix + content + ending)
      end
    end
  end

  def test_oversized_rows_and_bounded_tails_recover_at_newline
    [0, 1, 1023, 1024, 1025, CHUNK - 1, CHUNK, CHUNK + 1].each do |tail|
      # First chunk has a newline, followed by a tail potentially over the bound.
      prefix = "x" * (CHUNK - 1026) + "\n" + "y" * (1025 + tail)
      assert_equal VERSIONS, scan(prefix + "\n" + BLOCK), "tail #{tail}"
    end
    assert_equal VERSIONS, scan("x" * (4 * CHUNK + 17) + "\n" + BLOCK)
    # No newline: a header-looking suffix is still part of the oversized line.
    invalid("x" * (4 * CHUNK) + BLOCK)
  end

  def test_header_line_limit_includes_newline_and_leading_whitespace
    padding = 1024 - HEADER.bytesize
    assert_equal VERSIONS, scan(" " * padding + BLOCK)
    invalid(" " * (padding + 1) + BLOCK)
    # A skipped pending prefix must not disappear when the marker arrives.
    invalid("x" * (CHUNK - 500) + "\n" + " " * 1024 + BLOCK)
  end

  def test_marker_lookalikes_never_start_a_block
    decoys = ["schema_migrations\n", "COPY public.schema_migrations (other) FROM stdin;\n",
              "prefix #{HEADER}", HEADER.downcase, "x" * 2048 + HEADER]
    decoys.each do |decoy|
      assert_equal VERSIONS, scan(decoy + BLOCK)
      invalid(decoy)
    end
    # Retained line prefix spanning chunks must disqualify an apparent header.
    invalid("x" * (CHUNK - 10) + "\nnot-copy " + BLOCK)
  end

  def test_duplicate_blocks_and_malformed_rows_are_rejected
    invalid(BLOCK + BLOCK)
    invalid(BLOCK + "x" * (3 * CHUNK) + "\n" + BLOCK)
    ["", "not-a-version\n", "123\n", "1" * 15 + "\n", "x" * 1025 + "\n", HEADER].each do |rows|
      invalid(HEADER + rows + "\\.\n")
    end
    # Whitespace may be stripped, but an oversized version line is not accepted.
    invalid(HEADER + " " * 1024 + VERSIONS.first + "\n\\.\n")
  end

  def test_unterminated_lines_and_blocks_keep_original_eof_rules
    invalid(HEADER + VERSIONS.first + "\n\\.")
    invalid(HEADER + VERSIONS.first)
    invalid(HEADER)
    invalid(HEADER.rstrip)
    assert_equal VERSIONS, scan(BLOCK + "x" * (2 * CHUNK))
    # Like the original, an incomplete second header is not a parsed line.
    assert_equal VERSIONS, scan(BLOCK + HEADER.rstrip)
  end

  def test_unique_version_cap_and_duplicate_versions
    rows = (0...100_000).map { |i| format("%014d\n", i) }.join
    result = scan(HEADER + rows + "00000000000000\n\\.\n")
    assert_equal 100_000, result.size
    assert_equal "00000000000000", result.first
    assert_equal "00000000099999", result.last
    invalid(HEADER + rows + "00000000100000\n\\.\n")
  end

  def test_full_gzip_drain_checks_crc_size_and_truncation_after_valid_block
    sql = BLOCK + "invented trailing rows\n" * 20_000
    [8, 4].each do |offset|
      invalid(sql, corrupt: ->(bytes) { bytes.setbyte(bytes.bytesize - offset, bytes.getbyte(bytes.bytesize - offset) ^ 1); bytes })
    end
    [1, 8, 32].each { |count| invalid(sql, corrupt: ->(bytes) { bytes.byteslice(0, bytes.bytesize - count) }) }
    assert_equal VERSIONS, scan(sql)
  end

  def test_trailing_bytes_and_second_gzip_member_are_rejected
    invalid(BLOCK, suffix: "unused trailing bytes")
    io = StringIO.new
    gzip = Zlib::GzipWriter.new(io)
    gzip.write("invented second member\n")
    gzip.close
    invalid(BLOCK, suffix: io.string)
  end
end
