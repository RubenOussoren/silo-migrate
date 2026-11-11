# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/silo_migrate/discourse_version"

class DiscourseVersionTest < Minitest::Test
  CASES = JSON.parse(File.read(File.join(__dir__, "fixtures/discourse-versions.json")))

  def test_versions
    CASES.fetch("versions").each do |entry|
      parsed = SiloMigrate::DiscourseVersion.parse(entry["value"])
      if entry["canonical"].nil?
        assert_nil parsed, entry.inspect
      else
        assert_equal entry["canonical"], parsed.fetch(:canonical), entry.inspect
        assert_equal entry["track"], parsed.fetch(:track), entry.inspect
        assert_equal entry["canonical"].split(/-latest|\.beta|\.rc/).first, parsed.fetch(:release)
      end
    end
  end

  def test_huge_decimal_is_refused_without_integer_conversion
    assert_nil SiloMigrate::DiscourseVersion.parse("3.4." + "9" * 5000)
    assert_nil SiloMigrate::DiscourseVersion.parse("3.4.0-beta" + "9" * 5000)
  end

  def test_backups
    CASES.fetch("backups").each do |entry|
      parsed = SiloMigrate::DiscourseVersion.backup(entry["name"], extension: entry["extension"])
      if entry["invalid"]
        assert_nil parsed, entry.inspect
      else
        assert_equal({ "discourse_version" => entry["canonical"], "schema_version" => entry["schema"] }, parsed, entry.inspect)
      end
    end
  end

  def test_comparison
    CASES.fetch("comparisons").each do |left, right, expected|
      a, b = [left, right].map { |value| SiloMigrate::DiscourseVersion.parse(value).fetch(:version) }
      assert_equal expected, a <=> b, "#{left} vs #{right}"
    end
  end
end
