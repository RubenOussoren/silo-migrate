# frozen_string_literal: true

require_relative "test_helper"
require "silo_migrate/services/standard_oracle"

class StandardOracleMarkupTest < SiloMigrateTest
  Oracle = SiloMigrate::Services::StandardOracle

  def setup
    @expected = {
      "users" => [], "categories" => [], "topics" => [],
      "posts" => [{ "post_id" => 7, "topic_id" => 2, "post_number" => 1, "raw" => "<p>Tom &amp; Jerry <strong>loud</strong> — 50% invented.</p>" }],
      "counts" => { "users" => 0, "categories" => 0, "topics" => 0, "posts" => 1, "attachments" => 0 }
    }
    @site = {
      "users" => [], "categories" => [], "topics" => [], "uploads" => [],
      "posts" => [{
        "import_id" => "7", "topic_import_id" => "2", "post_number" => 1,
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

  def test_different_sentence_with_import_id_is_text_mismatch
    @expected["posts"][0]["raw"] = "<p>Completely different invented sentence.</p>"
    assert_equal ["imported-post-text-mismatch:7"], imported_failures
  end

  def test_entire_visible_text_absent_from_destination_is_missing
    @site["posts"][0] = { "raw" => "Unrelated body.", "cooked" => "<p>Unrelated body.</p>" }
    assert_equal ["imported-post-missing:7"], imported_failures
  end

  def test_empty_source_post_still_fails
    ["", "<p> </p>"].each do |raw|
      @expected["posts"][0]["raw"] = raw
      assert_equal ["imported-post-text-mismatch:7"], imported_failures
    end
  end

  def test_matching_prefix_does_not_hide_missing_tail
    @site["posts"][0] = { "import_id" => "7", "topic_import_id" => "2", "post_number" => 1, "raw" => "Tom & Jerry **loud**", "cooked" => "<p>Tom &amp; Jerry <strong>loud</strong></p>" }
    assert_equal ["imported-post-text-mismatch:7"], imported_failures
  end

  def test_raw_match_does_not_hide_missing_rendered_content
    @site["posts"][0]["cooked"] = "<p>Unrelated body.</p>"
    assert_equal ["imported-post-text-mismatch:7"], imported_failures
  end

  def test_matching_text_without_import_id_is_still_missing
    @site['posts'][0].delete('import_id')
    assert_equal ['imported-post-missing:7'], imported_failures
  end

  def test_attachment_link_and_importer_size_are_removed_but_not_post_words
    @site['posts'][0]['cooked'] += '<a class="attachment" href="/uploads/file.txt">file.txt</a> (1.5 KB)'
    assert_empty imported_failures
    @site['posts'][0]['cooked'] += '<p>Unwanted appended words.</p>'
    assert_equal ['imported-post-text-mismatch:7'], imported_failures
  end
  def test_block_boundaries_normalize_equally_on_both_sides
    @expected['posts'][0]['raw'] = '<p>a</p><p>b</p>'
    @site['posts'][0]['cooked'] = '<p>a</p><p>b</p>'
    assert_empty imported_failures
    @site['posts'][0]['cooked'] = '<div>a<br>b</div>'
    assert_empty imported_failures
    assert_equal 'a b', Oracle.visible_text(@expected['posts'][0]['raw'])
    assert_equal 'a b', Oracle.post_visible_text(@site['posts'][0]['cooked'])
  end

  def test_curly_quotes_normalize_to_authored_plain_quotes
    @expected['posts'][0]['raw'] = %q(<p>"Quoted" and 'single' isn't different.</p>)
    @site['posts'][0]['cooked'] = '<p>“Quoted” and ‘single’ isn’t different.</p>'
    assert_empty imported_failures
    @site['posts'][0]['cooked'] = '<p>“Changed” and ‘single’ isn’t different.</p>'
    assert_equal ['imported-post-text-mismatch:7'], imported_failures
  end

  def test_authored_sizes_are_preserved_and_only_size_directly_after_attachment_is_removed
    @expected['posts'][0]['raw'] = '<p>Authored (5 KB) remains.</p>'
    @site['posts'][0]['cooked'] = '<p>Authored (5 KB) remains. <a class="attachment">file.txt</a> (1 Byte)</p>'
    assert_empty imported_failures
    assert_equal 'Authored (5 KB) remains.', Oracle.post_visible_text(@site['posts'][0]['cooked'])
    @site['posts'][0]['cooked'] = '<p>Authored remains. <a class="attachment">file.txt</a> (1 Byte)</p>'
    assert_equal ['imported-post-text-mismatch:7'], imported_failures
    assert_equal 'Words later (5 KB)', Oracle.post_visible_text('<p>Words <a class="attachment">file</a> later (5 KB)</p>')
  end

end
