# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "time"
require "yaml"

module SiloMigrate
  module Services
    class TrustedWorkflowService
      ARTIFACT_VERSION = 1

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

      def review(customer, finding_path, decision: "safe", reviewer: default_reviewer, notes: nil, timestamp: Time.now.utc)
        review_finding(customer, finding_path, decision: decision, reviewer: reviewer, notes: notes, timestamp: timestamp, redact: false)
      end

      def redact(customer, finding_path, reviewer: default_reviewer, notes: nil, timestamp: Time.now.utc)
        review_finding(customer, finding_path, decision: "safe", reviewer: reviewer, notes: notes, timestamp: timestamp, redact: true)
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
      # embeds none of its raw content (the command itself can contain raw
      # values, e.g. WHERE email='...'), so the later safe derivative cannot
      # leak anything. The human edits/redacts via 'trusted redact'.
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
          "recommended_next_step" => "Review the referenced inspection in the trusted zone, then run 'silo-migrate trusted redact #{customer} #{source_label(path, project_path)}' and summarize the conclusion safely in --notes."
        }
        Project.atomic_write(path, finding.to_yaml)
        path
      end

      def review_finding(customer, finding_path, decision:, reviewer:, notes:, timestamp:, redact:)
        Project.load_config(customer, @env)
        raise UsageError, "Finding not found: #{finding_path}" unless File.exist?(finding_path)

        decision = normalize_decision(decision)
        reviewer = default_reviewer if reviewer.to_s.strip.empty?
        finding = read_finding(finding_path)
        visibility = VisibilityPolicy.normalize(finding["dev_visibility"])
        raise UsageError, "trusted_only findings require 'trusted redact', not review approval." if !redact && visibility == VisibilityPolicy::TRUSTED_ONLY && decision == "safe"

        project_path = Project.project_path(customer, @env)
        reviewed_path = nil
        if decision == "safe"
          reviewed = safe_derivative(finding, reviewer, notes, timestamp, redact: redact)
          reviewed_path = File.join(project_path, "findings", "#{reviewed.fetch('id')}.yml")
          Project.atomic_write(reviewed_path, reviewed.to_yaml)
          @output.puts "[OK] Safe reviewed finding: #{reviewed_path}"
        end

        audit_path = write_audit(
          customer,
          redact ? "trusted_redact" : "trusted_review",
          timestamp,
          "source_finding" => source_label(finding_path, project_path),
          "reviewed_finding" => reviewed_path ? source_label(reviewed_path, project_path) : nil,
          "source_visibility" => visibility,
          "decision" => decision,
          "reviewer" => reviewer,
          "notes" => notes.to_s,
          "redaction_review" => redact ? "redacted" : decision
        )
        @output.puts "[OK] Trusted audit: #{audit_path}"
        { reviewed_path: reviewed_path, audit_path: audit_path }
      end

      def safe_derivative(finding, reviewer, notes, timestamp, redact:)
        source_id = finding.fetch("id")
        derived = finding.dup
        # Raw payload keys never survive into a safe derivative, regardless of
        # how the source finding was authored.
        %w[command stdout stderr details].each { |key| derived.delete(key) }
        derived["id"] = "#{source_id}-#{redact ? 'redacted' : 'reviewed'}"
        derived["generated_at"] = timestamp.utc.iso8601
        derived["source_trusted_finding_id"] = source_id
        derived["dev_visibility"] = VisibilityPolicy::SAFE
        derived["review"] = {
          "reviewed_at" => timestamp.utc.iso8601,
          "reviewer" => reviewer,
          "notes" => notes.to_s,
          "redacted" => redact
        }
        if redact
          derived["message"] = "[REDACTED]"
          derived["exception_class"] = nil
          derived["recommended_next_step"] = "Use this redacted safe derivative with schema bundle context."
        end
        derived
      end

      def read_finding(path)
        finding = YAML.safe_load(File.read(path), permitted_classes: [Time, Symbol], aliases: false)
        raise UsageError, "Malformed finding #{File.basename(path)}: expected a mapping." unless finding.is_a?(Hash)

        finding
      rescue Psych::Exception => e
        raise UsageError, "Malformed finding #{File.basename(path)}: #{e.message}"
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
        raise UsageError, "Invalid review decision: #{decision}. Expected safe or reject." unless %w[safe reject].include?(value)

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
