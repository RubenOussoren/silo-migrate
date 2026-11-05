# frozen_string_literal: true

require_relative "test_helper"
require "silo_migrate/services/standard_oracle"

class StandardOracleMarkupTest < SiloMigrateTest
  Oracle = SiloMigrate::Services::StandardOracle

  def setup
    @expected = {
      "users" => [], "categories" => [], "topics" => [],
      "posts" => [{ "post_id" => 7, "raw" => "<p>Tom &amp; Jerry <strong>loud</strong> — 50% invented.</p>" }],
      "counts" => { "users" => 0, "categories" => 0, "topics" => 0, "posts" => 1 }
    }
    @site = {
      "users" => [], "categories" => [], "topics" => [], "uploads" => [],
      "posts" => [{
        "raw" => "Tom & Jerry **loud** — 50% invented.",
        "cooked" => "<p>Tom &amp; Jerry <strong>loud</strong> — 50% invented.</p>"
      }],
      "custom_fields" => {
        "user_import_ids" => [], "category_import_ids" => [],
        "topic_import_ids" => [], "post_import_ids" => [7]
      }
    }
  end

  def imported_failures
    Oracle.imported_failures(@expected, @site, attachment_sha256s: [])
  end

  def test_entities_and_inline_markup_match_rendered_destination
    assert_empty imported_failures
  end

  def test_different_sentence_from_finding_is_missing
    @expected["posts"][0]["raw"] = "<p>Completely different invented sentence.</p>"
    assert_equal ["imported-post-missing:7"], imported_failures
  end

  def test_entire_visible_text_absent_from_destination_is_missing
    @site["posts"][0] = { "raw" => "Unrelated body.", "cooked" => "<p>Unrelated body.</p>" }
    assert_equal ["imported-post-missing:7"], imported_failures
  end

  def test_empty_source_post_still_fails
    ["", "<p> </p>"].each do |raw|
      @expected["posts"][0]["raw"] = raw
      assert_equal ["imported-post-missing:7"], imported_failures
    end
  end

  def test_matching_prefix_does_not_hide_missing_tail
    @site["posts"][0] = { "raw" => "Tom & Jerry **loud**", "cooked" => "<p>Tom &amp; Jerry <strong>loud</strong></p>" }
    assert_equal ["imported-post-missing:7"], imported_failures
  end

  def test_raw_match_does_not_hide_missing_rendered_content
    @site["posts"][0]["cooked"] = "<p>Unrelated body.</p>"
    assert_equal ["imported-post-missing:7"], imported_failures
  end
end
