# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "yaml"

module SiloMigrate
  module Services
    class ConverterFindingsService
      ARTIFACT_VERSION = 1

      def initialize(env: ENV, output: $stdout)
        @env = env
        @output = output
      end

      def generate(customer, from: nil, timestamp: Time.now.utc)
        Project.load_config(customer, @env)
        project_path = Project.project_path(customer, @env)
        summary_path = from || File.join(project_path, "findings", "redacted-logs", "latest.summary.json")
        raise_missing_summary!(customer, summary_path) unless File.exist?(summary_path)

        summary = read_summary(summary_path)
        findings = build_findings(summary, source_label(summary_path, project_path), timestamp)
        raise UsageError, "No converter warnings or errors were found in #{safe_input_name(summary_path)}." if findings.empty?

        findings_dir = File.join(project_path, "findings")
        FileUtils.mkdir_p(findings_dir)
        written = findings.each_with_index.map do |finding, index|
          id = "#{timestamp.utc.strftime('%Y%m%d-%H%M%S')}-#{format('%03d', index + 1)}"
          artifact = finding.merge("id" => "finding-#{id}")
          path = File.join(findings_dir, "#{artifact.fetch('id')}.yml")
          Project.atomic_write(path, artifact.to_yaml)
          path
        end

        index = {
          "artifact_version" => ARTIFACT_VERSION,
          "generated_at" => timestamp.utc.iso8601,
          "source" => source_label(summary_path, project_path),
          "findings" => written.map do |path|
            {
              "id" => File.basename(path, ".yml"),
              "path" => File.basename(path)
            }
          end
        }
        index_path = File.join(findings_dir, "latest-findings.json")
        Project.atomic_write(index_path, JSON.pretty_generate(index) + "\n")

        AIWorkspaceService.new(env: @env, output: @output).refresh_if_prepared(customer)

        { findings: written, index_path: index_path }
      end

      private

      def read_summary(path)
        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        raise UsageError, "Malformed redacted summary #{safe_input_name(path)}: #{e.message}"
      end

      def raise_missing_summary!(customer, path)
        raise UsageError,
              "Redacted summary not found: #{path}\nRun 'silo-migrate run-converter #{customer} --redacted-logs' first, or pass --from FILE."
      end

      def build_findings(summary, source, timestamp)
        findings = []
        Array(summary.dig("sources", "intermediate_db", "entries")).each_with_index do |entry, index|
          type = entry["type"].to_s
          next unless %w[error warning].include?(type)

          findings << finding_from_intermediate_entry(summary, entry, index, source, timestamp)
        end

        Array(summary.dig("sources", "process_output", "detected_errors")).each_with_index do |entry, index|
          findings << finding_from_process_error(summary, entry, index, source, timestamp)
        end
        findings
      end

      def finding_from_intermediate_entry(summary, entry, index, source, timestamp)
        warning = entry["type"].to_s == "warning"
        {
          "artifact_version" => ARTIFACT_VERSION,
          "generated_at" => timestamp.utc.iso8601,
          "source" => source,
          "source_entry_index" => index,
          "failure" => warning ? "converter_log_warning" : "converter_log_error",
          "severity" => warning ? "warning" : "error",
          "message" => entry["message"].to_s,
          "exception_class" => exception_class(entry["exception"]),
          "observed_shape" => entry["details_shape"],
          "dev_visibility" => VisibilityPolicy.finding_visibility(summary, entry),
          "recommended_next_step" => warning ? "Review converter warning with schema bundle context." : "Reproduce with a shape-only fixture and update converter handling."
        }
      end

      def finding_from_process_error(summary, entry, index, source, timestamp)
        {
          "artifact_version" => ARTIFACT_VERSION,
          "generated_at" => timestamp.utc.iso8601,
          "source" => source,
          "source_entry_index" => index,
          "failure" => "converter_runtime_error",
          "severity" => "error",
          "message" => entry["text"].to_s,
          "exception_class" => nil,
          "observed_shape" => {
            "value_type" => "text",
            "stream" => entry["stream"].to_s,
            "line" => entry["line"],
            "redacted" => true
          },
          "dev_visibility" => VisibilityPolicy.finding_visibility(summary, entry),
          "recommended_next_step" => "Inspect the runtime error with redacted logs and reproduce from converter code paths."
        }
      end

      def exception_class(exception)
        value = exception.to_s.strip
        return nil if value.empty?

        value.split(":").first
      end

      def source_label(path, project_path)
        expanded = File.expand_path(path)
        project = File.expand_path(project_path)
        if expanded.start_with?("#{project}/")
          expanded.delete_prefix("#{project}/")
        else
          File.basename(path)
        end
      end

      def safe_input_name(path)
        File.basename(path)
      end
    end
  end
end
