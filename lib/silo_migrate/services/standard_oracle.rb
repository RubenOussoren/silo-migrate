# frozen_string_literal: true

require "nokogiri"

module SiloMigrate
  module Services
    # Independent comparison of site facts against the baseline and the dataset's
    # expected content. Pure data-in, failures-out: nothing here reads or trusts
    # importer status. Exit code 0 from an importer is not acceptance.
    module StandardOracle
      BASELINE_USERS = %w[id username email admin moderator trust_level active created_at].freeze
      BASELINE_TOPICS = %w[id title slug category user created_at].freeze
      BASELINE_POSTS = %w[id topic_id post_number user raw created_at reply_to_post_number].freeze
      BASELINE_UPLOADS = %w[id original_filename extension sha1 filesize url short_path user_id local_path_present file_sha256 post_references].freeze

      module_function

      # Allows only explicit derived-value differences: everything durable about a
      # baseline-origin record must survive unchanged.
      def baseline_failures(baseline, site, base_url_map: nil)
        failures = []
        compare_records(failures, "user", baseline["users"], site["users"], "username", BASELINE_USERS)
        compare_records(failures, "topic", baseline["topics"], site["topics"], "id", BASELINE_TOPICS)
        compare_records(failures, "post", baseline["posts"], site["posts"], "id", BASELINE_POSTS)
        compare_records(failures, "upload", baseline["uploads"], site["uploads"], "sha1", BASELINE_UPLOADS)
        baseline.fetch("categories").each do |category|
          found = site.fetch("categories").find { |candidate| candidate["slug"] == category["slug"] }
          failures << "baseline-category-missing:#{category['slug']}" unless found
          failures << "baseline-category-changed:#{category['slug']}" if found && %w[id name parent_category_id user].any? { |field| found[field] != category[field] }
        end
        baseline.fetch("groups").each do |group|
          found = site.fetch("groups").find { |candidate| candidate["name"] == group["name"] }
          failures << "baseline-group-missing:#{group['name']}" unless found
          failures << "baseline-group-members-changed:#{group['name']}" if found && found["users"] != group["users"]
        end
        baseline.fetch("settings").each do |name, value|
          failures << "baseline-setting-changed:#{name}" unless site.fetch("settings")[name] == value
        end
        baseline.fetch("posts").each do |post|
          current = site.fetch("posts").find { |candidate| candidate["id"] == post["id"] }
          next unless current

          failures << "baseline-post-cooked-changed:#{post['id']}" unless normalize(current["cooked"], base_url_map) == normalize(post["cooked"], base_url_map)
        end
        failures
      end

      # `expected` is the dataset's registered expected file (synthetic). Matches by
      # source import ID in both directions, so an extra or moved record fails as well
      # as a missing one. Text is the whole post's visible text, not a substring.
      def imported_failures(expected, site, attachment_sha256s:, baseline: nil)
        failures = []
        imported = ->(records) { records.select { |record| record["import_id"] } }
        users = imported.call(site.fetch("users"))
        categories = imported.call(site.fetch("categories"))
        topics = imported.call(site.fetch("topics"))
        posts = imported.call(site.fetch("posts"))
        usernames = expected.fetch("users").to_h { |user| [user["user_id"].to_s, user["username"]] }

        compare_ids(failures, "user", expected.fetch("users").map { |user| user["user_id"] }, users)
        compare_ids(failures, "category", expected.fetch("categories").map { |category| category["category_id"] }, categories)
        compare_ids(failures, "topic", expected.fetch("topics").map { |topic| topic["topic_id"] }, topics)
        compare_ids(failures, "post", expected.fetch("posts").map { |post| post["post_id"] }, posts)

        expected.fetch("users").each do |user|
          found = users.find { |candidate| candidate["import_id"] == user["user_id"].to_s }
          next unless found

          failures << "imported-user-username-mismatch:#{user['user_id']}" unless found["username"] == user["username"]
          failures << "imported-user-email-mismatch:#{user['user_id']}" unless found["email"] == user["email"]
        end
        expected.fetch("categories").each do |category|
          found = categories.find { |candidate| candidate["import_id"] == category["category_id"].to_s }
          next unless found

          failures << "imported-category-slug-mismatch:#{category['category_id']}" unless found["slug"] == category["slug"]
          parent = category["parent_category_id"]&.to_s
          failures << "imported-category-parent-mismatch:#{category['category_id']}" unless found["parent_import_id"] == parent
        end
        expected.fetch("topics").each do |topic|
          found = topics.find { |candidate| candidate["import_id"] == topic["topic_id"].to_s }
          next unless found

          failures << "imported-topic-title-mismatch:#{topic['topic_id']}" unless found["title"] == topic["topic_subject"]
          failures << "imported-topic-category-mismatch:#{topic['topic_id']}" unless found["category_import_id"] == topic["category_id"].to_s
          failures << "imported-topic-user-mismatch:#{topic['topic_id']}" unless found["user"] == usernames[topic["user_id"].to_s]
          failures << "imported-topic-created-mismatch:#{topic['topic_id']}" unless found["created_at"] == topic["created_at"]
        end
        expected.fetch("posts").each do |post|
          found = posts.find { |candidate| candidate["import_id"] == post["post_id"].to_s }
          next unless found

          failures << "imported-post-topic-mismatch:#{post['post_id']}" unless found["topic_import_id"] == post["topic_id"].to_s
          failures << "imported-post-number-mismatch:#{post['post_id']}" unless found["post_number"] == post["post_number"]
          failures << "imported-post-user-mismatch:#{post['post_id']}" unless found["user"] == usernames[post["user_id"].to_s]
          failures << "imported-post-created-mismatch:#{post['post_id']}" unless found["created_at"] == post["created_at"]
          text = visible_text(post["raw"])
          failures << "imported-post-text-mismatch:#{post['post_id']}" unless !text.empty? && text == post_visible_text(found["cooked"])
        end

        if baseline
          { "topics" => "topics", "posts" => "posts", "users" => "users" }.each do |kind, key|
            total = baseline.fetch(key).size + expected.fetch("counts").fetch(kind)
            failures << "site-#{kind}-total-mismatch:#{site.fetch(key).size}!=#{total}" unless site.fetch(key).size == total
          end
        end

        attachment_sha256s.each do |sha|
          upload = site.fetch("uploads").find { |candidate| candidate["file_sha256"] == sha }
          if upload.nil?
            failures << "attachment-missing:#{sha[0, 12]}"
          else
            failures << "attachment-file-absent:#{sha[0, 12]}" unless upload["local_path_present"]
            failures << "attachment-unreferenced:#{sha[0, 12]}" if upload["post_references"].empty?
          end
        end
        if (attachment = expected["attachment"])
          owner = posts.find { |candidate| candidate["import_id"] == attachment["post_id"].to_s }
          upload = site.fetch("uploads").find { |candidate| candidate["original_filename"] == attachment["file_name"] && candidate["filesize"] == attachment["bytes"] }
          if upload.nil?
            failures << "attachment-record-missing:#{attachment['attachment_id']}"
          elsif owner.nil? || !upload["post_references"].include?(owner["id"])
            failures << "attachment-wrong-post:#{attachment['attachment_id']}"
          end
        end
        failures
      end

      def compare_ids(failures, label, expected_ids, records)
        expected_ids = expected_ids.map(&:to_s).sort
        actual = records.map { |record| record["import_id"].to_s }.sort
        (expected_ids - actual).each { |id| failures << "imported-#{label}-missing:#{id}" }
        (actual - expected_ids).each { |id| failures << "imported-#{label}-unexpected:#{id}" }
      end

      def runtime_failures(site, lock)
        failures = []
        app = lock.fetch("app")
        failures << "runtime-version-mismatch" unless site.dig("versions", "discourse") == app.fetch("version")
        failures << "runtime-revision-mismatch" unless site.dig("versions", "git") == app.fetch("revision")
        failures << "runtime-ruby-mismatch" unless site.dig("versions", "ruby") == app.fetch("ruby")
        runtime = site.fetch("runtime")
        failures << "runtime-store-not-local" unless runtime["store_local"] == true && runtime["s3"] == false
        failures << "runtime-email-not-disabled" unless runtime["disable_emails"] == "yes"
        (app.fetch("required_extensions") - runtime.fetch("extensions")).each { |name| failures << "runtime-extension-missing:#{name}" }
        failures << "runtime-postgres-mismatch" unless runtime["pg_version"].to_s.start_with?("#{app.fetch('postgres_major')}.")
        failures << "runtime-redis-mismatch" unless runtime["redis_version"].to_s.start_with?("#{app.fetch('redis_major')}.")
        failures << "runtime-restore-left-enabled" if runtime["allow_restore"]
        failures
      end

      # Restored site must match the pre-backup site across the facts the fingerprint
      # collects, modulo the deliberate hostname change.
      def restored_failures(source_site, restored_site, base_url_map:)
        failures = []
        compare_records(failures, "restored-user", source_site["users"], restored_site["users"], "username", BASELINE_USERS)
        compare_records(failures, "restored-topic", source_site["topics"], restored_site["topics"], "id", BASELINE_TOPICS + %w[posts_count])
        compare_records(failures, "restored-post", source_site["posts"], restored_site["posts"], "id", BASELINE_POSTS)
        compare_records(failures, "restored-upload", source_site["uploads"], restored_site["uploads"], "sha1", BASELINE_UPLOADS)
        source_site.fetch("posts").each do |post|
          current = restored_site.fetch("posts").find { |candidate| candidate["id"] == post["id"] }
          next unless current

          failures << "restored-post-cooked-changed:#{post['id']}" unless normalize(current["cooked"], base_url_map) == normalize(post["cooked"], base_url_map)
        end
        %w[groups categories settings custom_fields].each do |key|
          failures << "restored-#{key}-changed" unless restored_site[key] == source_site[key]
        end
        failures
      end

      def collision_failures(baseline, intermediate)
        failures = []
        taken_usernames = baseline.fetch("users").map { |user| user["username"].to_s.downcase }
        taken_emails = baseline.fetch("users").map { |user| user["email"].to_s.downcase }
        taken_categories = baseline.fetch("categories").flat_map { |category| [category["name"].to_s.downcase, category["slug"].to_s.downcase] }
        intermediate.fetch("users").each do |user|
          failures << "collision-username:#{user['username']}" if taken_usernames.include?(user["username"].to_s.downcase)
          failures << "collision-email:#{user['email']}" if taken_emails.include?(user["email"].to_s.downcase)
        end
        intermediate.fetch("categories").each do |category|
          next unless [category["name"], category["slug"]].compact.any? { |value| taken_categories.include?(value.to_s.downcase) }

          failures << "collision-category:#{category['slug'] || category['name']}"
        end
        failures
      end

      def visible_text(html)
        Nokogiri::HTML.fragment(html.to_s).text.gsub(/[[:space:]]+/, " ").strip
      end

      # A post's own words, without the attachment link and size the importer adds.
      # The attachment is asserted separately against the post that should own it.
      def post_visible_text(cooked)
        fragment = Nokogiri::HTML.fragment(cooked.to_s)
        fragment.css("a.attachment").each(&:remove)
        fragment.text.gsub(/\(\s*\d+(?:\.\d+)?\s*(?:Bytes|KB|MB)\s*\)/, "").gsub(/[[:space:]]+/, " ").strip
      end

      def normalize(text, base_url_map)
        return text.to_s unless base_url_map

        base_url_map.reduce(text.to_s) { |memo, (from, to)| memo.gsub(from, to) }
      end

      def compare_records(failures, label, expected, actual, key, fields)
        expected.each do |record|
          found = actual.find { |candidate| candidate[key] == record[key] }
          if found.nil?
            failures << "#{label}-missing:#{record[key]}"
            next
          end
          changed = fields.reject { |field| found[field] == record[field] }
          failures << "#{label}-changed:#{record[key]}:#{changed.join(',')}" unless changed.empty?
        end
      end
    end
  end
end
