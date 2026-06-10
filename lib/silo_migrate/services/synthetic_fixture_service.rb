# frozen_string_literal: true

require "fileutils"
require "json"
require "yaml"

module SiloMigrate
  module Services
    class SyntheticFixtureService
      ARTIFACT_VERSION = 1
      PLACEHOLDERS = {
        "email" => "synthetic@example.test",
        "text" => "Synthetic text preserving only field shape.",
        "string" => "synthetic-value",
        "integer" => 1,
        "float" => 1.0,
        "boolean" => true,
        "null" => nil,
        "array" => [],
        "object" => {}
      }.freeze

      def initialize(env: ENV, output: $stdout)
        @env = env
        @output = output
      end

      def generate(customer, from: nil)
        Project.load_config(customer, @env)
        project_path = Project.project_path(customer, @env)
        input = from || File.join(project_path, "findings", "latest-findings.json")
        raise_missing_findings!(customer, input) unless File.exist?(input)

        findings = read_findings(input, project_path)
        output_dir = File.join(project_path, "synthetic-fixtures")
        FileUtils.mkdir_p(output_dir)

        written = []
        findings.each do |path|
          finding = read_finding(path)
          unless VisibilityPolicy.fixture_allowed?(finding)
            @output.puts "[WARN] Skipping #{File.basename(path)}: dev_visibility=#{finding['dev_visibility']} requires trusted review or redaction."
            next
          end

          fixture = fixture_for(finding)
          unless fixture
            @output.puts "[WARN] Skipping #{File.basename(path)}: no usable observed_shape."
            next
          end

          output_path = File.join(output_dir, "#{finding.fetch('id')}.yml")
          Project.atomic_write(output_path, fixture.to_yaml)
          written << output_path
        rescue KeyError, Errno::ENOENT, Psych::Exception => e
          @output.puts "[WARN] Skipping #{File.basename(path)}: #{e.message}"
        end

        AIWorkspaceService.new(env: @env, output: @output).refresh_if_prepared(customer)

        { fixtures: written }
      end

      private

      def read_findings(input, project_path)
        if File.directory?(input)
          Dir[File.join(input, "finding-*.yml")].sort
        elsif File.extname(input) == ".json"
          read_index(input, project_path)
        else
          [input]
        end
      end

      def read_index(path, project_path)
        index = JSON.parse(File.read(path))
        base = File.dirname(path)
        Array(index.fetch("findings")).map do |entry|
          candidate = entry.fetch("path")
          File.absolute_path(candidate, base)
        end.select { |candidate| File.expand_path(candidate).start_with?(File.expand_path(project_path)) || File.exist?(candidate) }
      rescue JSON::ParserError => e
        raise UsageError, "Malformed finding index #{File.basename(path)}: #{e.message}"
      rescue KeyError
        raise UsageError, "Malformed finding index #{File.basename(path)}: expected a findings array."
      end

      def read_finding(path)
        finding = YAML.safe_load(
          File.read(path),
          permitted_classes: [Time, Symbol],
          aliases: false
        )
        raise KeyError, "expected a finding mapping" unless finding.is_a?(Hash)

        finding
      end

      def fixture_for(finding)
        shape = finding["observed_shape"]
        value = placeholder_for_shape(shape)
        return nil if value == :unsupported

        {
          "artifact_version" => ARTIFACT_VERSION,
          "id" => "synthetic-#{finding.fetch('id')}",
          "source_finding_id" => finding.fetch("id"),
          "dev_visibility" => "safe",
          "values" => value
        }
      end

      def placeholder_for_shape(shape)
        return :unsupported unless shape.is_a?(Hash)

        if shape["keys"].is_a?(Array) && shape["value_types"].is_a?(Hash)
          return shape["keys"].each_with_object({}) do |key, values|
            placeholder = placeholder_for_type(shape["value_types"][key.to_s])
            return :unsupported if placeholder == :unsupported

            values[key.to_s] = placeholder
          end
        end

        placeholder_for_type(shape["value_type"])
      end

      def placeholder_for_type(type)
        return :unsupported unless PLACEHOLDERS.key?(type.to_s)

        value = PLACEHOLDERS.fetch(type.to_s)
        duplicate_placeholder(value)
      end

      def duplicate_placeholder(value)
        case value
        when Array then []
        when Hash then {}
        else value
        end
      end

      def raise_missing_findings!(customer, path)
        raise UsageError,
              "Findings input not found: #{path}\nRun 'silo-migrate findings generate #{customer}' first, or pass --from FILE_OR_DIR."
      end
    end
  end
end
