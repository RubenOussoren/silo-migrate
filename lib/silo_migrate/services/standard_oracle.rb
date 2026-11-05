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

      # `expected` is the dataset's registered expected file (synthetic).
      def imported_failures(expected, site, attachment_sha256s:, baseline: nil)
        failures = []
        baseline_ids = baseline ? baseline.fetch("users").map { |user| user["username"] } : []
        imported_users = site.fetch("users").reject { |user| baseline_ids.include?(user["username"]) }
        expected_names = expected.fetch("users").map { |user| user["username"] }.sort
        failures << "imported-users-mismatch" unless imported_users.map { |user| user["username"] }.sort == expected_names
        expected.fetch("users").each do |user|
          found = imported_users.find { |candidate| candidate["username"] == user["username"] }
          failures << "imported-user-email-mismatch:#{user['username']}" if found && found["email"] != user["email"]
        end
        expected.fetch("categories").each do |category|
          failures << "imported-category-missing:#{category['slug']}" unless site.fetch("categories").any? { |candidate| candidate["slug"] == category["slug"] }
        end
        titles = site.fetch("topics").map { |topic| topic["title"] }
        expected.fetch("topics").each do |topic|
          failures << "imported-topic-missing:#{topic['topic_id']}" unless titles.include?(topic["topic_subject"])
        end
        # Source bodies are HTML; destination raw bodies are Markdown. Compare
        # rendered text instead, retaining the entire expected body as evidence.
        texts = site.fetch("posts").map { |post| visible_text(post["cooked"]) }
        expected.fetch("posts").each do |post|
          fragment = visible_text(post["raw"])
          failures << "imported-post-missing:#{post['post_id']}" unless !fragment.empty? && texts.any? { |text| text.include?(fragment) }
        end
        counts = site.fetch("custom_fields")
        { "users" => "user_import_ids", "topics" => "topic_import_ids", "posts" => "post_import_ids", "categories" => "category_import_ids" }.each do |kind, field|
          expected_count = expected.fetch("counts").fetch(kind)
          actual = counts.fetch(field).size
          failures << "import-mapping-count-mismatch:#{kind}:#{actual}!=#{expected_count}" unless actual == expected_count
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
        failures
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
        failures
      end

      # Restored site must equal the pre-backup site modulo the deliberate hostname
      # change. Comparing everything durable, not just the fixture's own records.
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
