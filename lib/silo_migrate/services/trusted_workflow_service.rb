# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "securerandom"
require "tempfile"
require "time"
require "yaml"

module SiloMigrate
  module Services
    class TrustedWorkflowService
      ARTIFACT_VERSION = 1
      FINDING_ID_PATTERN = /\Afinding-[a-zA-Z0-9_-]{1,128}\z/
      FINDING_ROOTS = ["findings", "trusted/findings"].freeze

      def initialize(runtime: Runtime::Docker.new, env: ENV, output: $stdout)
        @runtime = runtime
        @env = env
        @output = output
      end

      def inspect(customer, phase: "initial", reason:, command:, as_finding: false, message: nil, timestamp: Time.now.utc)
        Project.load_config(customer, @env)
        raise UsageError, "Trusted inspection requires --reason." if reason.to_s.strip.empty?

        command = Array(command).reject(&:empty?)
        raise UsageError, "Trusted inspection command must be passed after '--'." if command.empty?

        project_path = Project.project_path(customer, @env)
        stamp = timestamp.utc.strftime("%Y%m%d-%H%M%S")
        result = @runtime.run(command, capture: true, timeout: nil)
        inspection_path = File.join(project_path, "trusted", "inspections", "inspection-#{stamp}.json")
        inspection = {
          "artifact_version" => ARTIFACT_VERSION,
          "generated_at" => timestamp.utc.iso8601,
          "customer" => customer,
          "phase" => phase,
          "reason" => reason,
          "command" => command,
          "success" => result.success?,
          "exit_status" => result.status,
          "stdout" => result.stdout,
          "stderr" => result.stderr,
          "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY,
          "contains_raw_rows" => true
        }
        Project.atomic_write(inspection_path, JSON.pretty_generate(inspection) + "\n")

        finding_path = write_inspection_finding(customer, project_path, inspection_path, phase, reason, message, stamp, timestamp) if as_finding

        audit_path = write_audit(
          customer,
          "trusted_inspect",
          timestamp,
          "phase" => phase,
          "reason" => reason,
          "command" => command,
          "success" => result.success?,
          "exit_status" => result.status,
          "artifact" => source_label(inspection_path, project_path),
          "finding" => finding_path ? source_label(finding_path, project_path) : nil,
          "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY,
          "redaction_review" => "not_reviewed"
        )

        @output.puts "[OK] Trusted inspection artifact: #{inspection_path}"
        @output.puts "[OK] Trusted finding stub: #{finding_path}" if finding_path
        @output.puts "[OK] Trusted audit: #{audit_path}"
        { inspection_path: inspection_path, finding_path: finding_path, audit_path: audit_path, result: result }
      end

      def review(customer, finding_path, decision: "safe", reviewer: default_reviewer, notes: nil, released_message: nil, timestamp: Time.now.utc)
        review_finding(customer, finding_path, decision: decision, reviewer: reviewer, notes: notes, timestamp: timestamp, redact: false, released_message: released_message)
      end

      def redact(customer, finding_path, reviewer: default_reviewer, notes: nil, released_message: nil, timestamp: Time.now.utc)
        review_finding(customer, finding_path, decision: "safe", reviewer: reviewer, notes: notes, timestamp: timestamp, redact: true, released_message: released_message)
      end

      def session(customer, provider: "bedrock", runtime: "silo", reason:, session_id: nil, timestamp: Time.now.utc)
        Project.load_config(customer, @env)
        provider = provider.to_s.strip.downcase
        runtime = runtime.to_s.strip.downcase
        raise UsageError, "Trusted sessions currently support --provider bedrock only." unless provider == "bedrock"
        raise UsageError, "Trusted sessions currently support --runtime silo only." unless runtime == "silo"
        raise UsageError, "Trusted session requires --reason." if reason.to_s.strip.empty?
        raise UsageError, trusted_session_platform_error unless linux_host?

        project_path = Project.project_path(customer, @env)
        session_id = normalize_session_id(session_id, timestamp)
        config_path = write_trusted_silo_config(customer, project_path, provider, runtime, reason, session_id, timestamp)
        audit_path = write_audit(
          customer,
          "trusted_session",
          timestamp,
          "provider" => provider,
          "runtime" => runtime,
          "reason" => reason,
          "session_id" => session_id,
          "config" => source_label(config_path, project_path),
          "raw_mount_policy" => "trusted_data_ai_only",
          "snapshot" => "before_agent_launch",
          "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY
        )

        snapshot_result = @runtime.run(["silo", "snapshot", "create", "--config", config_path, "--message", "trusted-data-ai #{customer} #{session_id}"], capture: true, timeout: nil)
        raise UsageError, "Silo snapshot failed before trusted session launch." unless snapshot_result.success?

        launch_result = @runtime.run(["silo", "agent", "claude", "--config", config_path], capture: false, timeout: nil)
        raise UsageError, "Trusted Silo agent session failed to launch." unless launch_result.success?

        @output.puts "[OK] Trusted Data AI config: #{config_path}"
        @output.puts "[OK] Trusted audit: #{audit_path}"
        { config_path: config_path, audit_path: audit_path, session_id: session_id }
      end

      private

      # Writes a trusted_only finding stub that REFERENCES the inspection but
      # omits command output. Reasons/messages can still be sensitive and stay
      # private until the operator explicitly supplies release text.
      def write_inspection_finding(customer, project_path, inspection_path, phase, reason, message, stamp, timestamp)
        path = File.join(project_path, "trusted", "findings", "finding-inspect-#{stamp}.yml")
        finding = {
          "artifact_version" => ARTIFACT_VERSION,
          "id" => "finding-inspect-#{stamp}",
          "generated_at" => timestamp.utc.iso8601,
          "source" => source_label(inspection_path, project_path),
          "failure" => "trusted_inspection",
          "severity" => "warning",
          "phase" => phase,
          "message" => (message.to_s.strip.empty? ? reason : message),
          "exception_class" => nil,
          "observed_shape" => nil,
          "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY,
          "contains_raw_rows" => false,
          "recommended_next_step" => "Review the referenced inspection in the trusted zone, then run 'silo-migrate trusted redact #{customer} #{source_label(path, project_path)}' and supply explicitly reviewed release text in --released-message. Keep private review context in --notes."
        }
        Project.atomic_write(path, finding.to_yaml)
        path
      end

      def review_finding(customer, finding_path, decision:, reviewer:, notes:, timestamp:, redact:, released_message:)
        Project.validate_customer_name!(customer)
        project_path = Project.project_path(customer, @env)
        raise UsageError, "Invalid finding workspace." if File.symlink?(project_path)

        nominal_project_path = File.expand_path(project_path)
        project_path = File.realpath(project_path)
        config_path = File.join(project_path, "config.env")
        unless File.file?(config_path) && !File.symlink?(config_path)
          raise UsageError, "Invalid finding workspace."
        end
        # Do not load a caller-selected file before checking its workspace root.
        finding_path = confined_finding_path(project_path, finding_path, nominal_project_path: nominal_project_path)
        decision = normalize_decision(decision)
        actor = default_reviewer
        unless [actor, reviewer, notes].all? { |value| value.nil? || (value.is_a?(String) && value.valid_encoding? && !value.include?("\0")) }
          raise UsageError, "Invalid private review metadata."
        end
        reviewer = actor if reviewer.nil? || reviewer.strip.empty?
        if decision == "reject" && !released_message.nil?
          raise UsageError, "Reject decisions must not include --released-message."
        end
        finding = read_finding(finding_path)
        source_id = finding["id"]
        unless source_id.is_a?(String) && FINDING_ID_PATTERN.match?(source_id)
          raise UsageError, "Invalid finding identifier."
        end
        visibility = finding["dev_visibility"]
        unless [VisibilityPolicy::SAFE, VisibilityPolicy::RESTRICTED, VisibilityPolicy::TRUSTED_ONLY].include?(visibility)
          raise UsageError, "Invalid finding visibility."
        end
        raise UsageError, "trusted_only findings require 'trusted redact', not review approval." if !redact && visibility == VisibilityPolicy::TRUSTED_ONLY && decision == "safe"

        reviewed = safe_derivative(released_message, timestamp, redact: redact) if decision == "safe"
        reviewed_path = if reviewed
          confined_review_path(project_path, "findings/#{reviewed.fetch('id')}.yml", create_parents: true)
        end
        audit_path = confined_review_path(
          project_path,
          "trusted/audit/#{redact ? 'trusted_redact' : 'trusted_review'}-#{SecureRandom.hex(16)}.json",
          create_parents: true
        )
        audit = {
          "artifact_version" => ARTIFACT_VERSION,
          "generated_at" => timestamp.utc.iso8601,
          "customer" => customer,
          "event" => redact ? "trusted_redact" : "trusted_review",
          "actor" => actor,
          "details" => {
            "source_finding" => source_label(finding_path, project_path),
            "source_finding_id" => source_id,
            "reviewed_finding" => reviewed_path ? source_label(reviewed_path, project_path) : nil,
            "source_visibility" => visibility,
            "decision" => decision,
            "reviewer" => reviewer,
            "notes" => notes,
            "released_message" => reviewed && reviewed.fetch("message"),
            "redaction_review" => redact ? "redacted" : decision
          }.compact
        }
        # Persist the private review decision before publishing its derivative.
        write_review_artifact(audit_path, JSON.pretty_generate(audit) + "\n", kind: :audit)
        write_review_artifact(reviewed_path, reviewed.to_yaml, kind: :derivative) if reviewed
        begin
          @output.puts "[OK] Reviewed finding: #{source_label(reviewed_path, project_path)}" if reviewed
          @output.puts "[OK] Trusted review audit: #{source_label(audit_path, project_path)}"
        rescue SystemCallError, IOError
          raise UsageError, "Review artifacts were written, but status output failed. Inspect the workspace before retrying.", cause: nil
        end
        { reviewed_path: reviewed_path, audit_path: audit_path }
      rescue SystemCallError, IOError, ArgumentError, JSON::GeneratorError, EncodingError
        raise UsageError, "Trusted finding review could not access workspace artifacts.", cause: nil
      end

      def safe_derivative(released_message, timestamp, redact:)
        unless released_message.is_a?(String) && released_message.valid_encoding? &&
               !released_message.strip.empty? && released_message.bytesize <= 4096 &&
               !released_message.include?("\0") && !released_message.lstrip.start_with?("--")
          raise UsageError, "Safe approval requires --released-message with explicitly reviewed, validly encoded text (1-4096 bytes; no NUL or leading --)."
        end

        # Source fields (including metadata and nested shapes) stay private.
        # The operator's explicit release text is the only free text published.
        {
          "artifact_version" => ARTIFACT_VERSION,
          "id" => "finding-#{SecureRandom.hex(16)}-#{redact ? 'redacted' : 'reviewed'}",
          "generated_at" => timestamp.utc.iso8601,
          "source" => "trusted_review",
          "failure" => "reviewed_finding",
          "severity" => "warning",
          "message" => released_message,
          "exception_class" => nil,
          "observed_shape" => nil,
          "contains_raw_rows" => false,
          "dev_visibility" => VisibilityPolicy::SAFE,
          "recommended_next_step" => "Use only the explicitly reviewed release text.",
          "review" => {
            "reviewed_at" => timestamp.utc.iso8601,
            "redacted" => redact
          }
        }
      end

      def confined_finding_path(project_path, path, nominal_project_path: project_path)
        expanded = File.expand_path(path, project_path)
        nominal_prefix = nominal_project_path + File::SEPARATOR
        if expanded.start_with?(nominal_prefix)
          expanded = File.join(project_path, expanded.delete_prefix(nominal_prefix))
        end
        unless FINDING_ROOTS.any? { |root| expanded.start_with?(File.join(project_path, root) + File::SEPARATOR) }
          raise UsageError, "Finding must be inside this workspace's findings directories."
        end
        confined_review_path(project_path, expanded)
      end

      # Reject symlink components, not just symlink leaves. These checks assume
      # operator-owned directories; they are not a sandbox for concurrent writers.
      def confined_review_path(project_path, path, create_parents: false)
        expanded = File.expand_path(path, project_path)
        prefix = project_path + File::SEPARATOR
        raise UsageError, "Invalid finding artifact path." unless expanded.start_with?(prefix)

        parts = expanded.delete_prefix(prefix).split(File::SEPARATOR)
        current = project_path
        parts.each_with_index do |part, index|
          current = File.join(current, part)
          leaf = index == parts.length - 1
          if create_parents && !leaf && !File.exist?(current) && !File.symlink?(current)
            Dir.mkdir(current, 0o700)
          end
          stat = (File.lstat(current) if File.exist?(current) || File.symlink?(current))
          if stat && (stat.symlink? || (leaf ? !stat.file? || stat.nlink != 1 : !stat.directory?))
            raise UsageError, "Invalid finding artifact path."
          end
          raise UsageError, "Finding artifact not found." if !stat && (!leaf || !create_parents)
        end
        expanded
      end

      def write_review_artifact(path, content, kind:)
        # Keep incomplete bytes out of final artifact names. Linking the closed
        # staging file publishes atomically without replacing an existing entry.
        staged = Tempfile.create([".review-", ".tmp"], File.dirname(path))
        published = false
        begin
          staged.write(content)
          staged.flush
          staged.fsync
          staged.close
          File.link(staged.path, path)
          published = true
        ensure
          primary_error = $!
          begin
            staged.close unless staged.closed?
          rescue SystemCallError, IOError => close_error
            raise close_error unless primary_error
          ensure
            begin
              File.unlink(staged.path)
            rescue SystemCallError, IOError
              outcome = if kind == :audit
                published ? "Audit written; derivative not published" : "Audit not written; derivative not published"
              else
                published ? "Derivative published" : "Derivative not published"
              end
              raise UsageError, "#{outcome}; staging cleanup failed. Inspect the private workspace before retrying.", cause: nil
            end
          end
        end
      end

      def read_finding(path)
        File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          finding = YAML.safe_load(file.read, permitted_classes: [Time, Symbol], aliases: false)
          raise UsageError, "Malformed finding: expected a mapping." unless finding.is_a?(Hash)

          finding
        end
      rescue Psych::Exception, ArgumentError
        raise UsageError, "Malformed finding: invalid YAML.", cause: nil
      end

      def write_audit(customer, event, timestamp, details)
        project_path = Project.project_path(customer, @env)
        path = File.join(project_path, "trusted", "audit", "#{event}-#{timestamp.utc.strftime('%Y%m%d-%H%M%S')}.json")
        audit = {
          "artifact_version" => ARTIFACT_VERSION,
          "generated_at" => timestamp.utc.iso8601,
          "customer" => customer,
          "event" => event,
          "actor" => default_reviewer,
          "details" => details.compact
        }
        Project.atomic_write(path, JSON.pretty_generate(audit) + "\n")
        path
      end

      def write_trusted_silo_config(customer, project_path, provider, runtime, reason, session_id, timestamp)
        path = File.join(project_path, "trusted", "silo", "trusted-data-ai-#{session_id}.yml")
        config = {
          "artifact_version" => ARTIFACT_VERSION,
          "kind" => "trusted-data-ai",
          "customer" => customer,
          "generated_at" => timestamp.utc.iso8601,
          "provider" => provider,
          "runtime" => runtime,
          "reason" => reason,
          "session_id" => session_id,
          "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY,
          "agent" => {
            "name" => "claude",
            "mode" => "bedrock"
          },
          "snapshots" => {
            "before_agent_launch" => true
          },
          "audit" => {
            "directory" => File.join(project_path, "trusted", "audit")
          },
          "mounts" => [
            {
              "source" => project_path,
              "target" => "/workspace/#{customer}",
              "access" => "read_write",
              "classification" => "raw_customer_project",
              "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY
            }
          ],
          "safe_handoff" => [
            "trusted redact",
            "safe findings",
            "synthetic fixtures",
            "ai refresh"
          ]
        }
        Project.atomic_write(path, config.to_yaml)
        path
      end

      def normalize_session_id(session_id, timestamp)
        value = session_id.to_s.strip
        value = "session-#{timestamp.utc.strftime('%Y%m%d-%H%M%S')}" if value.empty?
        raise UsageError, "Invalid trusted session id: #{session_id}. Use letters, numbers, '.', '_' or '-'." unless value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/)

        value
      end

      def linux_host?
        return true if @env["SILO_MIGRATE_FORCE_LINUX"] == "1"
        return false if @env["SILO_MIGRATE_FORCE_NON_LINUX"] == "1"

        RbConfig::CONFIG.fetch("host_os").include?("linux")
      end

      def trusted_session_platform_error
        "trusted session requires a Linux/Silo host. On macOS, use Docker plus 'silo-migrate ai prepare' for Normal Dev AI, or run this command on a Linux/Silo host for Bedrock raw-data access."
      end

      def normalize_decision(decision)
        value = decision.to_s.strip.downcase
        raise UsageError, "Invalid review decision. Expected safe or reject." unless %w[safe reject].include?(value)

        value
      end

      def default_reviewer
        @env["SILO_MIGRATE_ACTOR"] || @env["USER"] || "unknown"
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
    end
  end
end
