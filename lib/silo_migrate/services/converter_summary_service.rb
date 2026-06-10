# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

begin
  require "sqlite3"
rescue LoadError
  nil
end

module SiloMigrate
  module Services
    class ConverterSummaryService
      ARTIFACT_VERSION = 1
      DETAILS_REDACTED = "[REDACTED_DETAILS]"
      MAX_DETECTED_ERRORS = 50

      def initialize(env: ENV, output: $stdout)
        @env = env
        @output = output
      end

      def generate(customer, command:, result: nil, stdout: nil, stderr: nil, timestamp: Time.now.utc)
        Project.load_config(customer, @env)
        project_path = Project.project_path(customer, @env)
        artifact_dir = File.join(project_path, "findings", "redacted-logs")
        FileUtils.mkdir_p(artifact_dir)

        stamp = timestamp.utc.strftime("%Y%m%d-%H%M%S")
        base = "converter-run-#{stamp}"
        redactor = Redactor.new(project_path: project_path, config: Project.load_config(customer, @env))
        stdout = stdout.nil? && result ? result.stdout : stdout.to_s
        stderr = stderr.nil? && result ? result.stderr : stderr.to_s
        command = Array(command)

        log_content = redacted_process_log(
          customer: customer,
          command: command,
          result: result,
          stdout: stdout,
          stderr: stderr,
          generated_at: timestamp,
          redactor: redactor
        )

        log_path = File.join(artifact_dir, "#{base}.log")
        Project.atomic_write(log_path, log_content)
        Project.atomic_write(File.join(artifact_dir, "latest.log"), log_content)

        summary = build_summary(
          customer: customer,
          command: command,
          result: result,
          stdout: stdout,
          stderr: stderr,
          generated_at: timestamp,
          project_path: project_path,
          redactor: redactor
        )
        summary["redaction_counts"] = redactor.counts

        summary_content = JSON.pretty_generate(summary) + "\n"
        summary_path = File.join(artifact_dir, "#{base}.summary.json")
        Project.atomic_write(summary_path, summary_content)
        Project.atomic_write(File.join(artifact_dir, "latest.summary.json"), summary_content)

        AIWorkspaceService.new(env: @env, output: @output).refresh_if_prepared(customer)

        { log_path: log_path, summary_path: summary_path }
      end

      private

      def redacted_process_log(customer:, command:, result:, stdout:, stderr:, generated_at:, redactor:)
        lines = []
        lines << "generated_at=#{generated_at.utc.iso8601}"
        lines << "customer=#{customer}"
        lines << "command=#{command.join(' ')}"
        lines << "success=#{result ? result.success?.to_s : 'unknown'}"
        lines << "exit_status=#{result&.status || 'unknown'}"
        lines << ""
        lines << "== stdout =="
        lines << redactor.redact(stdout)
        lines << ""
        lines << "== stderr =="
        lines << redactor.redact(stderr)
        lines.join("\n")
      end

      def build_summary(customer:, command:, result:, stdout:, stderr:, generated_at:, project_path:, redactor:)
        {
          "artifact_version" => ARTIFACT_VERSION,
          "generated_at" => generated_at.utc.iso8601,
          "customer" => customer,
          "command" => command,
          "success" => result ? result.success? : nil,
          "exit_status" => result&.status,
          "sources" => {
            "process_output" => process_output_summary(stdout, stderr, redactor),
            "intermediate_db" => intermediate_db_summary(project_path, redactor)
          },
          "contains_raw_rows" => false,
          "dev_ai_visibility" => "safe",
          "redaction_counts" => {}
        }
      end

      def process_output_summary(stdout, stderr, redactor)
        {
          "stdout_lines" => stdout.to_s.lines.count,
          "stderr_lines" => stderr.to_s.lines.count,
          "detected_errors" => detected_errors(stdout, stderr, redactor)
        }
      end

      def detected_errors(stdout, stderr, redactor)
        entries = []
        { "stdout" => stdout, "stderr" => stderr }.each do |stream, text|
          text.to_s.lines.each_with_index do |line, index|
            next unless line.match?(/\b(error|exception|failed|failure|traceback|fatal)\b/i)

            entries << {
              "stream" => stream,
              "line" => index + 1,
              "text" => redactor.redact(line.strip)
            }
            return entries if entries.length >= MAX_DETECTED_ERRORS
          end
        end
        entries
      end

      def intermediate_db_summary(project_path, redactor)
        db_path = File.join(project_path, "output", "intermediate.db")
        summary = {
          "available" => File.exist?(db_path),
          "path" => redactor.redact(db_path),
          "log_entry_count" => 0,
          "counts_by_type" => {},
          "entries" => []
        }
        return summary unless File.exist?(db_path)

        raise UsageError, "sqlite3 gem is required to read #{db_path}" unless defined?(SQLite3::Database)

        wal_path = "#{db_path}-wal"
        if File.exist?(wal_path) && (Time.now - File.mtime(wal_path)) < 10
          summary["warnings"] = ["intermediate.db was written to in the last few seconds; the converter may still be running and this summary may be incomplete"]
        end

        db = SQLite3::Database.new(db_path, readonly: true)
        db.busy_timeout = 2000
        db.results_as_hash = true
        rows = db.execute("SELECT created_at, type, message, exception, details FROM log_entries ORDER BY created_at")
        summary["log_entry_count"] = rows.length
        summary["counts_by_type"] = rows.each_with_object(Hash.new(0)) { |row, counts| counts[row.fetch("type").to_s] += 1 }
        summary["entries"] = rows.map { |row| summarize_log_entry(row, redactor) }
        summary["counts_by_type"] = summary["counts_by_type"].sort.to_h
        summary
      rescue StandardError => e
        if defined?(SQLite3::BusyException) && e.is_a?(SQLite3::BusyException)
          summary.merge(
            "available" => false,
            "read_error" => "intermediate.db is locked (the converter may still be writing); retry after the converter finishes",
            "entries" => []
          )
        elsif defined?(SQLite3::SQLException) && e.is_a?(SQLite3::SQLException)
          summary.merge(
            "available" => false,
            "read_error" => redactor.redact(e.message),
            "entries" => []
          )
        else
          raise
        end
      ensure
        db&.close
      end

      def summarize_log_entry(row, redactor)
        details = row["details"]
        redactor.count("details") unless details.nil? || details.to_s.empty?
        {
          "created_at" => redactor.redact(row["created_at"].to_s),
          "type" => redactor.redact(row["type"].to_s),
          "message" => redactor.redact(row["message"].to_s),
          "exception" => row["exception"] ? redactor.redact(row["exception"].to_s) : nil,
          "details_shape" => details_shape(details),
          "details" => details.nil? || details.to_s.empty? ? nil : DETAILS_REDACTED
        }
      end

      def details_shape(details)
        return { "redacted" => true } if details.nil? || details.to_s.empty?

        parsed = JSON.parse(details)
        shape = shape_for(parsed)
        shape["redacted"] = true
        shape
      rescue JSON::ParserError
        {
          "value_type" => "text",
          "length" => details.to_s.length,
          "redacted" => true
        }
      ensure
        # This is intentionally counted at the artifact level rather than per
        # key, because full details payloads are omitted as a class of data.
      end

      def shape_for(value)
        case value
        when Hash
          {
            "keys" => value.keys.map(&:to_s).sort,
            "value_types" => value.keys.map(&:to_s).sort.to_h { |key| [key, value_type(value[key])] },
            "value_categories" => value.keys.map(&:to_s).sort.each_with_object({}) do |key, categories|
              categories[key] = value_category(value[key])
            end,
            "string_lengths" => value.keys.map(&:to_s).sort.each_with_object({}) do |key, lengths|
              lengths[key] = value[key].length if value[key].is_a?(String)
            end,
            "null_fields" => value.keys.map(&:to_s).sort.select { |key| value[key].nil? }
          }
        when Array
          {
            "value_type" => "array",
            "length" => value.length,
            "element_types" => value.map { |entry| value_type(entry) }.uniq.sort
          }
        else
          {
            "value_type" => value_type(value)
          }
        end
      end

      def value_category(value)
        case value_type(value)
        when "email" then "[EMAIL]"
        when "url" then "[URL]"
        when "ip" then "[IP]"
        when "text" then "[TEXT length=#{value.to_s.length}]"
        when "string" then "[STRING length=#{value.to_s.length}]"
        when "null" then "[NULL]"
        when "integer", "float", "boolean" then "[#{value_type(value).upcase}]"
        when "array" then "[ARRAY length=#{value.length}]"
        when "object" then "[OBJECT keys=#{value.keys.length}]"
        else "[#{value_type(value).upcase}]"
        end
      end

      def value_type(value)
        case value
        when NilClass then "null"
        when TrueClass, FalseClass then "boolean"
        when Integer then "integer"
        when Float then "float"
        when Array then "array"
        when Hash then "object"
        when String
          return "email" if value.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
          return "url" if value.match?(%r{\Ahttps?://}i)
          return "ip" if value.match?(/\A(?:\d{1,3}\.){3}\d{1,3}\z/)
          return "text" if value.length > 80 || value.include?("\n")

          "string"
        else
          value.class.name
        end
      end

      class Redactor
        SECRET_KEY_PATTERN = /(PASSWORD|SECRET|TOKEN|KEY|URI|URL|DSN|CONNECTION)/i

        attr_reader :counts

        def initialize(project_path:, config:)
          @project_path = project_path
          @config = config
          @counts = Hash.new(0)
        end

        def redact(text)
          value = text.to_s.dup
          value = redact_config_secrets(value)
          value = replace(value, Regexp.escape(@project_path), "[PROJECT_PATH]", :project_path)
          value = replace(value, %r{[a-z][a-z0-9+.-]*://[^\s"'<>]+}i, "[URL]", :url)
          value = replace(value, /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i, "[EMAIL]", :email)
          replace(value, /\b(?:\d{1,3}\.){3}\d{1,3}\b/, "[IP]", :ip)
        end

        def count(key, amount = 1)
          @counts[key.to_s] += amount
        end

        private

        def redact_config_secrets(value)
          @config.each do |key, secret|
            next unless key.match?(SECRET_KEY_PATTERN)
            next if secret.to_s.empty?

            value = replace(value, Regexp.escape(secret.to_s), "[SECRET]", :secret)
          end
          value
        end

        def replace(value, pattern, replacement, count_key)
          regex = pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)
          matches = value.scan(regex).length
          @counts[count_key.to_s] += matches if matches.positive?
          value.gsub(regex, replacement)
        end
      end
    end
  end
end
