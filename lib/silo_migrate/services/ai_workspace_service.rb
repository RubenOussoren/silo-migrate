# frozen_string_literal: true

require "fileutils"
require "find"
require "json"
require "time"
require "yaml"

module SiloMigrate
  module Services
    # Prepares the Normal Dev AI surface: the engineer's (or AI's) working
    # directory is the project's real discourse-converters git clone, and this
    # service writes a locally git-ignored `safe-artifacts/` directory inside
    # it (schema bundles, redacted logs, safe findings, synthetic fixtures)
    # plus generated agent instruction files. Converter code is never copied
    # and never touched — `refresh` only ever rebuilds `safe-artifacts/`.
    class AIWorkspaceService
      ARTIFACT_VERSION = 2
      SAFE_ARTIFACTS_DIR = "safe-artifacts"
      GENERATED_MARKER = "silo-migrate:generated"
      EXCLUDE_BEGIN = "# >>> silo-migrate generated (do not commit) >>>"
      EXCLUDE_END = "# <<< silo-migrate generated <<<"
      EXCLUDED_PATHS = %w[
        /safe-artifacts/
        /AGENTS.md
        /CLAUDE.md
        /.claude/
        /.silo/
        /Dockerfile
      ].freeze
      FORBIDDEN_PARENT_PATHS = %w[
        ../dumps/
        ../output/
        ../config.env
        ../converter-settings/
        ../trusted/
        ../uploads/
        ../shared/
        ../docker-compose.yml
      ].freeze
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

      def prepare(customer)
        Project.load_config(customer, @env)
        project_path = File.expand_path(Project.project_path(customer, @env))
        clone_path = File.join(project_path, "discourse-converters")
        unless Dir.exist?(clone_path)
          raise UsageError, "Converter is not set up for #{customer}.\nRun 'silo-migrate setup-converter #{customer}' first."
        end

        if Dir.exist?(File.join(clone_path, ".git"))
          write_git_exclude_block(clone_path)
        else
          @output.puts "[WARN] discourse-converters is not a git clone; generated files cannot be locally git-ignored."
        end

        safe_artifacts = File.join(clone_path, SAFE_ARTIFACTS_DIR)
        reset_safe_artifacts!(safe_artifacts, clone_path)

        copied = []
        copied.concat(copy_dir(project_path, safe_artifacts, "schema", required: true))
        copied.concat(copy_dir(project_path, safe_artifacts, File.join("findings", "redacted-logs"), required: true))
        copied.concat(copy_safe_findings(project_path, safe_artifacts))
        copied.concat(copy_dir(project_path, safe_artifacts, "synthetic-fixtures", required: true))

        copied << write_file(File.join(safe_artifacts, ".gitignore"), "*\n")
        copied << write_file(File.join(safe_artifacts, "manifest.json"), JSON.pretty_generate(manifest(customer)) + "\n")
        copied << write_file(File.join(safe_artifacts, "allowed-commands.json"), JSON.pretty_generate(allowed_commands(customer)) + "\n")
        copied.concat(write_instruction_files(customer, clone_path, safe_artifacts))

        @output.puts "[OK] Safe artifacts prepared: #{safe_artifacts}"
        @output.puts "[OK] Work from #{clone_path} (real git clone; commit/push converter changes normally)"
        { safe_artifacts_path: safe_artifacts, clone_path: clone_path, copied: copied }
      end

      alias refresh prepare

      # Refreshes safe-artifacts only when a previous `ai prepare` ran for this
      # customer (manifest present). Never raises: artifact generation commands
      # must not fail because the refresh did.
      def refresh_if_prepared(customer)
        clone_path = File.join(Project.project_path(customer, @env), "discourse-converters")
        return false unless File.exist?(File.join(clone_path, SAFE_ARTIFACTS_DIR, "manifest.json"))

        prepare(customer)
        true
      rescue StandardError => e
        @output.puts "[WARN] Safe artifacts refresh skipped: #{e.message.lines.first.strip}"
        false
      end

      private

      # The only rm_rf in this service: hard-guarded so a mis-resolved path can
      # never delete converter code.
      def reset_safe_artifacts!(safe_artifacts, clone_path)
        expected = File.join(File.expand_path(clone_path), SAFE_ARTIFACTS_DIR)
        unless File.expand_path(safe_artifacts) == expected
          raise UsageError, "Refusing to delete unexpected safe-artifacts path: #{safe_artifacts}"
        end

        FileUtils.rm_rf(safe_artifacts)
        FileUtils.mkdir_p(safe_artifacts)
      end

      def write_git_exclude_block(clone_path)
        exclude_path = File.join(clone_path, ".git", "info", "exclude")
        existing = File.exist?(exclude_path) ? File.read(exclude_path) : ""
        stripped = strip_managed_block(existing)
        block = ([EXCLUDE_BEGIN] + EXCLUDED_PATHS + [EXCLUDE_END]).join("\n")
        content = stripped.empty? ? "#{block}\n" : "#{stripped.chomp}\n#{block}\n"
        Project.atomic_write(exclude_path, content)
      end

      # Removes every managed block (older runs or interrupted writes can leave
      # more than one) so the rewrite always converges to a single block.
      def strip_managed_block(content)
        loop do
          lines = content.lines
          begin_index = lines.index { |line| line.chomp == EXCLUDE_BEGIN }
          return content unless begin_index

          end_index = lines[begin_index..].index { |line| line.chomp == EXCLUDE_END }
          return content unless end_index

          content = (lines[0...begin_index] + lines[(begin_index + end_index + 1)..]).join
        end
      end

      def manifest(customer)
        {
          "artifact_version" => ARTIFACT_VERSION,
          "kind" => "safe-artifacts",
          "customer" => customer,
          "generated_at" => Time.now.utc.iso8601
        }
      end

      def copy_dir(project_path, safe_artifacts, relative, required:)
        source = File.join(project_path, relative)
        unless Dir.exist?(source)
          @output.puts "[WARN] No #{relative}/ artifacts found." if required
          return []
        end

        destination = File.join(safe_artifacts, relative)
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

      def copy_safe_findings(project_path, safe_artifacts)
        findings_dir = File.join(project_path, "findings")
        unless Dir.exist?(findings_dir)
          @output.puts "[WARN] No findings/ artifacts found."
          return []
        end

        destination_dir = File.join(safe_artifacts, "findings")
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

      def write_instruction_files(customer, clone_path, safe_artifacts)
        files = []
        files << write_generated_root_file(clone_path, safe_artifacts, "AGENTS.md", agent_instructions(customer))
        files << write_generated_root_file(clone_path, safe_artifacts, "CLAUDE.md", claude_instructions(customer))
        files << write_claude_settings(clone_path)
        files << write_normal_dev_silo_config(customer, clone_path)
        files.compact
      end

      # Root instruction files must never clobber files owned by the upstream
      # converter repo (or hand-written by the user): only overwrite when the
      # existing file carries our generated marker; otherwise fall back into
      # safe-artifacts/ and warn.
      def write_generated_root_file(clone_path, safe_artifacts, name, content)
        path = File.join(clone_path, name)
        if File.exist?(path) && !File.read(path).include?(GENERATED_MARKER)
          @output.puts "[WARN] #{name} already exists in discourse-converters (likely tracked upstream); writing #{SAFE_ARTIFACTS_DIR}/#{name} instead."
          @output.puts "       Point your agent at it and do not edit the upstream file."
          return write_file(File.join(safe_artifacts, name), content)
        end

        write_file(path, content)
      end

      def write_claude_settings(clone_path)
        path = File.join(clone_path, ".claude", "settings.json")
        if File.exist?(path) && !File.read(path).include?("_generated_by")
          @output.puts "[WARN] .claude/settings.json already exists and was not generated by silo-migrate; leaving it untouched."
          return nil
        end

        write_file(path, JSON.pretty_generate(claude_settings) + "\n")
      end

      def claude_settings
        {
          "_generated_by" => "silo-migrate",
          "permissions" => {
            "deny" => FORBIDDEN_PARENT_PATHS.map { |p| "Read(#{p}#{p.end_with?('/') ? '**' : ''})" } +
                      ["Read(../findings/**)", "Read(../schema/**)", "Edit(safe-artifacts/**)"]
          }
        }
      end

      def write_normal_dev_silo_config(customer, clone_path)
        config = {
          "artifact_version" => ARTIFACT_VERSION,
          "kind" => "normal-dev-ai",
          "customer" => customer,
          "dev_visibility" => VisibilityPolicy::SAFE,
          "mounts" => [
            {
              "source" => clone_path,
              "target" => "/workspace/#{customer}-converters",
              "access" => "read_write",
              "classification" => "converter_clone_with_safe_artifacts"
            }
          ],
          "denied_mounts" => [
            "raw customer project root",
            "dumps/",
            "trusted/",
            "output/",
            "converter-settings/",
            "config.env"
          ],
          "agents" => {
            "codex" => { "mode" => "normal" },
            "claude" => { "mode" => "normal" }
          }
        }
        content = "# #{GENERATED_MARKER} — regenerated by 'silo-migrate ai refresh #{customer}'\n#{config.to_yaml}"
        write_file(File.join(clone_path, ".silo", "normal-dev-ai.yml"), content)
      end

      def write_file(path, content)
        Project.atomic_write(path, content)
        path
      end

      def agent_instructions(customer)
        <<~MARKDOWN
          <!-- #{GENERATED_MARKER} — local instruction file for `#{customer}`. Locally git-ignored; never commit. Regenerated by `silo-migrate ai refresh #{customer}`. -->

          # Converter Development — #{customer}

          You are working in the project's real `discourse-converters` git clone.
          Edit converter code and tests here, run the test suite, and commit/push
          to the converter repository normally.

          ## Safe artifacts

          `#{SAFE_ARTIFACTS_DIR}/` is generated, read-only context:
          - `#{SAFE_ARTIFACTS_DIR}/schema/` — schema bundles (structure only, no rows)
          - `#{SAFE_ARTIFACTS_DIR}/findings/redacted-logs/latest.log` and `latest.summary.json`
          - `#{SAFE_ARTIFACTS_DIR}/findings/finding-*.yml` — findings with `dev_visibility: safe`
          - `#{SAFE_ARTIFACTS_DIR}/synthetic-fixtures/` — shape-only fixtures, no real values

          Never edit files under `#{SAFE_ARTIFACTS_DIR}/`; it is deleted and rebuilt by
          `silo-migrate ai refresh #{customer}`.

          ## Development loop

          1. Edit converter code and tests in this clone.
          2. Ask the human operator to run:
             `silo-migrate run-converter #{customer} TYPE --redacted-logs`
             (it executes this exact working tree inside the converter container).
          3. Safe artifacts refresh in place automatically after redacted-log,
             findings, and fixture generation. Re-read
             `#{SAFE_ARTIFACTS_DIR}/findings/redacted-logs/latest.summary.json` and iterate.
          4. Commit and push converter changes with normal git commands.

          ## Hard rules

          - Never read outside this directory. Specifically forbidden:
            #{FORBIDDEN_PARENT_PATHS.map { |p| "`#{p}`" }.join(', ')},
            and any other raw customer project path.
          - Never request database credentials, raw rows, raw logs, or
            `output/intermediate.db` contents.
          - Never commit or `git add -f` any of: `#{SAFE_ARTIFACTS_DIR}/`, `AGENTS.md`,
            `CLAUDE.md`, `.claude/`, `.silo/`, or a generated `Dockerfile`. They are
            locally ignored via `.git/info/exclude` and must stay out of the
            upstream repository.
          - `restricted` and `trusted_only` findings never appear here. If schema,
            redacted logs, safe findings, and fixtures are insufficient, ask the
            human operator to escalate through the trusted workflow
            (`trusted inspect` → review → `trusted redact` → `ai refresh`).
        MARKDOWN
      end

      def claude_instructions(customer)
        <<~MARKDOWN
          <!-- #{GENERATED_MARKER} — see AGENTS.md. Locally git-ignored; never commit. -->

          # Claude Instructions — #{customer}

          Read `AGENTS.md` in this directory and follow it exactly. Summary: edit
          converter code here and commit normally; treat `#{SAFE_ARTIFACTS_DIR}/` as
          read-only generated context; never read any `../` path (raw customer
          data, credentials, dumps, trusted artifacts); never commit the generated
          files listed in AGENTS.md.
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
              "reason" => "Runs this working tree through the controlled migration runtime, emits redacted artifacts, and auto-refreshes safe-artifacts/."
            },
            {
              "command" => "silo-migrate findings generate #{customer}",
              "requires_human_operator" => true,
              "reason" => "Generates durable findings from redacted summaries; auto-refreshes safe-artifacts/."
            },
            {
              "command" => "silo-migrate fixtures generate #{customer}",
              "requires_human_operator" => true,
              "reason" => "Generates shape-only fixtures from safe findings; auto-refreshes safe-artifacts/."
            },
            {
              "command" => "silo-migrate ai refresh #{customer}",
              "requires_human_operator" => true,
              "reason" => "Rebuilds safe-artifacts/ from allowlisted artifacts (never touches converter code)."
            }
          ],
          "denied" => [
            "reading ../ paths from the converter clone (raw customer project)",
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
