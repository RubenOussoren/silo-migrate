# frozen_string_literal: true

require_relative "test_helper"

class ConverterSummaryServiceTest < SiloMigrateTest
  def test_reads_intermediate_log_entries_and_redacts_details
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme", password: "supersecret")
      project_path = project.project_path("acme")
      db_path = File.join(project_path, "output", "intermediate.db")
      create_intermediate_db(db_path)
      insert_log_entry(
        db_path,
        type: "error",
        message: "Failed for jane.customer@example.com from 192.168.1.9 in #{project_path}",
        exception: "NoMethodError: undefined method `strip' for nil",
        details: {
          id: 42,
          email: "jane.customer@example.com",
          bio: "real customer text " * 10,
          created_at: nil
        }.to_json
      )

      result = SiloMigrate::Runtime::CommandResult.new(
        success?: false,
        stdout: "connecting with supersecret\n",
        stderr: "Runtime Error at https://example.com/path for jane.customer@example.com\n",
        status: 1
      )
      artifacts = SiloMigrate::Services::ConverterSummaryService.new(env: env).generate(
        "acme",
        command: ["bundle", "exec", "ruby", "converter.rb"],
        result: result,
        timestamp: Time.utc(2026, 6, 1, 12, 0, 0)
      )

      summary = JSON.parse(File.read(artifacts.fetch(:summary_path)))
      entry = summary.dig("sources", "intermediate_db", "entries").first
      assert_equal 1, summary.dig("sources", "intermediate_db", "log_entry_count")
      assert_equal({ "error" => 1 }, summary.dig("sources", "intermediate_db", "counts_by_type"))
      assert_equal "[REDACTED_DETAILS]", entry.fetch("details")
      assert_equal %w[bio created_at email id], entry.dig("details_shape", "keys")
      assert_equal "email", entry.dig("details_shape", "value_types", "email")
      assert_equal "text", entry.dig("details_shape", "value_types", "bio")
      assert_equal "[EMAIL]", entry.dig("details_shape", "value_categories", "email")
      assert_match(/\A\[TEXT length=\d+\]\z/, entry.dig("details_shape", "value_categories", "bio"))
      assert_equal ["created_at"], entry.dig("details_shape", "null_fields")

      summary_text = JSON.generate(summary)
      refute_includes summary_text, "jane.customer@example.com"
      refute_includes summary_text, project_path
      refute_includes summary_text, "real customer text"
      assert_includes summary_text, "[EMAIL]"
      assert_includes summary_text, "[IP]"
      assert_includes summary_text, "[PROJECT_PATH]"

      log_text = File.read(artifacts.fetch(:log_path))
      assert_includes log_text, "[SECRET]"
      assert_includes log_text, "[URL]"
      assert_includes log_text, "[EMAIL]"
      refute_includes log_text, "supersecret"
      assert File.exist?(File.join(project_path, "findings", "redacted-logs", "latest.log"))
      assert File.exist?(File.join(project_path, "findings", "redacted-logs", "latest.summary.json"))
    end
  end

  def test_creates_process_only_summary_when_intermediate_db_is_absent
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")

      artifacts = SiloMigrate::Services::ConverterSummaryService.new(env: env).generate(
        "acme",
        command: ["ruby", "converter.rb"],
        result: SiloMigrate::Runtime::CommandResult.new(success?: true, stdout: "ok\n", stderr: "", status: 0)
      )

      summary = JSON.parse(File.read(artifacts.fetch(:summary_path)))
      assert_equal false, summary.dig("sources", "intermediate_db", "available")
      assert_equal 0, summary.dig("sources", "intermediate_db", "log_entry_count")
      assert_empty summary.dig("sources", "intermediate_db", "entries")
      assert_equal 1, summary.dig("sources", "process_output", "stdout_lines")
    end
  end

  def test_warns_when_intermediate_db_wal_is_fresh
    with_tmp_base do |_dir, env|
      project = SiloMigrate::Services::ProjectService.new(runtime: SiloMigrate::Runtime::Fake.new, env: env, output: StringIO.new)
      project.init("acme")
      db_path = File.join(project.project_path("acme"), "output", "intermediate.db")
      create_intermediate_db(db_path)
      insert_log_entry(db_path, type: "info", message: "ok", exception: nil, details: nil)
      write("#{db_path}-wal", "")

      artifacts = SiloMigrate::Services::ConverterSummaryService.new(env: env).generate(
        "acme",
        command: ["ruby", "converter.rb"],
        result: SiloMigrate::Runtime::CommandResult.new(success?: true, stdout: "", stderr: "", status: 0)
      )

      summary = JSON.parse(File.read(artifacts.fetch(:summary_path)))
      warnings = summary.dig("sources", "intermediate_db", "warnings")
      refute_nil warnings
      assert_match(/may still be running/, warnings.first)
      assert_equal 1, summary.dig("sources", "intermediate_db", "log_entry_count")
    end
  end

  private

  def create_intermediate_db(path)
    FileUtils.mkdir_p(File.dirname(path))
    db = SQLite3::Database.new(path)
    db.execute(<<~SQL)
      CREATE TABLE log_entries (
        created_at DATETIME NOT NULL,
        type TEXT NOT NULL,
        message TEXT NOT NULL,
        exception TEXT,
        details TEXT
      )
    SQL
  ensure
    db&.close
  end

  def insert_log_entry(path, type:, message:, exception:, details:)
    db = SQLite3::Database.new(path)
    db.execute(
      "INSERT INTO log_entries (created_at, type, message, exception, details) VALUES (?, ?, ?, ?, ?)",
      ["2026-06-01 12:00:00", type, message, exception, details]
    )
  ensure
    db&.close
  end
end
