# frozen_string_literal: true

require "fileutils"
require "find"
require "json"
require "yaml"

module SiloMigrate
  module Services
    class AIWorkspaceService
      ARTIFACT_VERSION = 1
      DEFAULT_SAFE_DIR_NAME = "safe-ai-workspaces"
      SKIPPED_BASENAMES = %w[
        .bundle
        .env
        .git
        config.env
        converter-settings
      ].freeze
      SKIPPED_PATTERNS = [
        /\Asettings.*\.ya?ml\z/,
        /credentials/i,
        /secret/i
      ].freeze

      def initialize(env: ENV, output: $stdout)
        @env = env
        @output = output
      end

      def prepare(customer, output_dir: nil)
        Project.load_config(customer, @env)
        project_path = File.expand_path(Project.project_path(customer, @env))
        workspace_path = File.expand_path(output_dir || default_workspace_path(customer))
        validate_workspace_path!(workspace_path, project_path)

        FileUtils.rm_rf(workspace_path)
        FileUtils.mkdir_p(workspace_path)

        copied = []
        copied.concat(copy_dir(project_path, workspace_path, "discourse-converters", required: true))
        copied.concat(copy_dir(project_path, workspace_path, "schema", required: true))
        copied.concat(copy_dir(project_path, workspace_path, File.join("findings", "redacted-logs"), required: true))
        copied.concat(copy_safe_findings(project_path, workspace_path))
        copied.concat(copy_dir(project_path, workspace_path, "synthetic-fixtures", required: true))
        copied.concat(write_agent_files(customer, workspace_path))
        copied << write_normal_dev_silo_config(customer, workspace_path)

        @output.puts "[OK] Safe AI workspace prepared: #{workspace_path}"
        @output.puts "[OK] Files/directories written: #{copied.length}"
        { workspace_path: workspace_path, copied: copied }
      end

      alias refresh prepare

      private

      def default_workspace_path(customer)
        base = @env["SILO_MIGRATE_SAFE_AI_BASE_PATH"]
        base ||= File.join(File.dirname(Project.base_path(@env)), DEFAULT_SAFE_DIR_NAME)
        File.join(base, customer)
      end

      def validate_workspace_path!(workspace_path, project_path)
        raise UsageError, "Safe AI workspace path cannot be the raw customer project path." if workspace_path == project_path
        if workspace_path.start_with?("#{project_path}/")
          raise UsageError, "Safe AI workspace must be outside the raw customer project: #{workspace_path}"
        end

        raise UsageError, "Refusing to prepare a safe AI workspace at filesystem root." if workspace_path == "/"
      end

      def copy_dir(project_path, workspace_path, relative, required:)
        source = File.join(project_path, relative)
        unless Dir.exist?(source)
          @output.puts "[WARN] No #{relative}/ artifacts found." if required
          return []
        end

        destination = File.join(workspace_path, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        copy_tree(source, destination)
        [destination]
      end

      def copy_tree(source, destination)
        FileUtils.mkdir_p(destination)
        Find.find(source) do |path|
          next if path == source

          relative = path.delete_prefix("#{source}/")

          if skip_entry?(path)
            Find.prune if File.directory?(path)
            next
          end

          target = File.join(destination, relative)
          if File.directory?(path)
            FileUtils.mkdir_p(target)
          elsif File.file?(path)
            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.cp(path, target)
          end
        end
      end

      def skip_entry?(path)
        return true if File.symlink?(path)

        basename = File.basename(path)
        SKIPPED_BASENAMES.include?(basename) || SKIPPED_PATTERNS.any? { |pattern| basename.match?(pattern) }
      end

      def copy_safe_findings(project_path, workspace_path)
        findings_dir = File.join(project_path, "findings")
        unless Dir.exist?(findings_dir)
          @output.puts "[WARN] No findings/ artifacts found."
          return []
        end

        destination_dir = File.join(workspace_path, "findings")
        FileUtils.mkdir_p(destination_dir)
        copied = []
        skipped = []
        Dir[File.join(findings_dir, "finding-*.yml")].sort.each do |path|
          finding = read_finding(path)
          if VisibilityPolicy.normalize(finding["dev_visibility"]) == VisibilityPolicy::SAFE
            destination = File.join(destination_dir, File.basename(path))
            FileUtils.cp(path, destination)
            copied << destination
          else
            skipped << File.basename(path)
          end
        rescue UsageError => e
          skipped << "#{File.basename(path)} (#{e.message})"
        end
        @output.puts "[WARN] No safe findings copied." if copied.empty?
        @output.puts "[WARN] Skipped non-safe findings: #{skipped.join(', ')}" unless skipped.empty?
        copied
      end

      def read_finding(path)
        finding = YAML.safe_load(File.read(path), permitted_classes: [Time, Symbol], aliases: false)
        raise UsageError, "Malformed finding #{File.basename(path)}: expected a mapping." unless finding.is_a?(Hash)

        finding
      rescue Psych::Exception => e
        raise UsageError, "Malformed finding #{File.basename(path)}: #{e.message}"
      end

      def write_agent_files(customer, workspace_path)
        files = []
        agents = agent_instructions(customer)
        claude = claude_instructions(customer)
        allowed = allowed_commands(customer)

        files << write_file(File.join(workspace_path, "AGENTS.md"), agents)
        files << write_file(File.join(workspace_path, "CLAUDE.md"), claude)
        files << write_file(File.join(workspace_path, "allowed-commands.json"), JSON.pretty_generate(allowed) + "\n")
        files
      end

      def write_normal_dev_silo_config(customer, workspace_path)
        config = {
          "artifact_version" => ARTIFACT_VERSION,
          "kind" => "normal-dev-ai",
          "customer" => customer,
          "dev_visibility" => VisibilityPolicy::SAFE,
          "mounts" => [
            {
              "source" => workspace_path,
              "target" => "/workspace/#{customer}-safe-ai",
              "access" => "read_write",
              "classification" => "safe"
            }
          ],
          "denied_mounts" => [
            "raw customer project",
            "dumps/",
            "trusted/",
            "output/intermediate.db"
          ],
          "agents" => {
            "codex" => { "mode" => "normal" },
            "claude" => { "mode" => "normal" }
          }
        }
        write_file(File.join(workspace_path, ".silo", "normal-dev-ai.yml"), config.to_yaml)
      end

      def write_file(path, content)
        Project.atomic_write(path, content)
        path
      end

      def agent_instructions(customer)
        <<~MARKDOWN
          # Normal Dev AI Workspace

          This workspace is generated for converter development for `#{customer}`.

          Allowed paths:
          - `discourse-converters/`
          - `schema/`
          - `findings/redacted-logs/`
          - `findings/finding-*.yml` with `dev_visibility: safe`
          - `synthetic-fixtures/`

          Forbidden paths and data:
          - Raw customer project directories.
          - `dumps/`, `trusted/`, `output/intermediate.db`, database credentials, raw logs, and raw row values.
          - Names, emails, IP addresses, private messages, post bodies, secrets, or customer-specific text.
          - `restricted` or `trusted_only` findings unless a trusted reviewer writes a safe derivative.

          Allowed command loop:
          - Edit converter code and tests in `discourse-converters/`.
          - Ask a human operator to run `silo-migrate run-converter #{customer} TYPE --redacted-logs`.
          - Ask for `silo-migrate findings generate #{customer}` and `silo-migrate fixtures generate #{customer}` after redacted logs are available.
          - Ask for `silo-migrate ai refresh #{customer}` before using newly generated safe artifacts.

          Escalate when schema, redacted logs, safe findings, and synthetic fixtures are not enough. Do not request direct raw-data access from this workspace.
        MARKDOWN
      end

      def claude_instructions(customer)
        <<~MARKDOWN
          # Claude Normal Dev Instructions

          Work only from the safe workspace for `#{customer}`. Treat all raw customer data, credentials, dumps, trusted artifacts, and intermediate databases as forbidden.

          Use schema bundles, redacted logs, safe findings, and synthetic fixtures to update converter code. For converter verification, request controlled `silo-migrate` commands from the human operator and consume only refreshed safe artifacts.
        MARKDOWN
      end

      def allowed_commands(customer)
        {
          "artifact_version" => ARTIFACT_VERSION,
          "customer" => customer,
          "commands" => [
            {
              "command" => "silo-migrate run-converter #{customer} TYPE --redacted-logs",
              "requires_human_operator" => true,
              "reason" => "Runs converter through the controlled migration runtime and emits redacted artifacts."
            },
            {
              "command" => "silo-migrate findings generate #{customer}",
              "requires_human_operator" => true,
              "reason" => "Generates durable findings from redacted summaries."
            },
            {
              "command" => "silo-migrate fixtures generate #{customer}",
              "requires_human_operator" => true,
              "reason" => "Generates shape-only fixtures from safe findings."
            },
            {
              "command" => "silo-migrate ai refresh #{customer}",
              "requires_human_operator" => true,
              "reason" => "Regenerates this safe workspace from allowlisted artifacts."
            }
          ],
          "denied" => [
            "direct access to raw customer project paths",
            "database shell access",
            "reading dumps/",
            "reading trusted/",
            "reading output/intermediate.db"
          ]
        }
      end
    end
  end
end
