# frozen_string_literal: true

require "digest"
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
      PRIVATE_ARTIFACT_VERSION = 2
      class OperationError < UsageError; end
      PRIVATE_ERROR_CODES = %w[
        TRUSTED_WORKSPACE_INVALID TRUSTED_INSPECT_INPUT_INVALID TRUSTED_INSPECT_COMMAND_FAILED
        TRUSTED_SESSION_INPUT_INVALID TRUSTED_SESSION_PLATFORM_UNSUPPORTED
        TRUSTED_SESSION_SNAPSHOT_FAILED TRUSTED_SESSION_LAUNCH_FAILED
      ].freeze
      FINDING_ID_PATTERN = /\Afinding-[a-zA-Z0-9_-]{1,128}\z/
      FINDING_ROOTS = ["findings", "trusted/findings"].freeze

      def initialize(runtime: Runtime::Docker.new, env: ENV, output: $stdout)
        @runtime = runtime
        @env = env
        @output = output
      end

      def inspect(customer, phase: "initial", reason: nil, command: [], as_finding: false, message: nil, timestamp: Time.now.utc)
        private_operation("INSPECT") do
          unless %w[initial final].include?(phase) && [true, false].include?(as_finding) &&
                 private_reason?(reason) && command.is_a?(Array) && !command.empty? &&
                 command.first.is_a?(String) && !command.first.empty? &&
                 command.all? { |arg| arg.is_a?(String) && !arg.b.include?("\0") } &&
                 (message.nil? || message.is_a?(String))
            raise OperationError, "TRUSTED_INSPECT_INPUT_INVALID"
          end
          project_path = private_project_path(customer)
          actor = byte_envelope(default_reviewer)
          id = SecureRandom.hex(16)
          confined_review_path(project_path, "trusted/inspections/inspection-#{id}.json", create_parents: true)
          confined_review_path(project_path, "trusted/audit/trusted-inspect-#{id}.json", create_parents: true)
          confined_review_path(project_path, "trusted/findings/finding-inspect-#{id}.yml", create_parents: true) if as_finding
          intent_path = write_private_json(project_path, "trusted/audit/trusted-inspect-request-#{id}.json", {
            "artifact_version" => PRIVATE_ARTIFACT_VERSION, "generated_at" => timestamp.utc.iso8601,
            "event" => "trusted_inspect", "actor" => actor,
            "details" => { "phase" => phase, "reason" => byte_envelope(reason),
              "command" => command.map { |arg| byte_envelope(arg) }, "status" => "requested",
              "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY }
          })
          result = @runtime.run(command, capture: true, binary: true, timeout: nil)
          fields = private_result(result)
          inspection_path = write_private_json(project_path, "trusted/inspections/inspection-#{id}.json", {
            "artifact_version" => PRIVATE_ARTIFACT_VERSION,
            "generated_at" => timestamp.utc.iso8601,
            "customer" => customer, "phase" => phase,
            "reason" => byte_envelope(reason), "command" => command.map { |arg| byte_envelope(arg) },
            "message" => message.nil? ? nil : byte_envelope(message),
            "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY, "contains_raw_rows" => true
          }.merge(fields))
          finding_path = write_inspection_finding(project_path, inspection_path, phase, id, timestamp) if as_finding
          audit_path = write_private_json(project_path, "trusted/audit/trusted-inspect-#{id}.json", {
            "artifact_version" => PRIVATE_ARTIFACT_VERSION, "generated_at" => timestamp.utc.iso8601,
            "event" => "trusted_inspect", "actor" => actor,
            "details" => {
              "phase" => phase, "reason" => byte_envelope(reason),
              "command" => command.map { |arg| byte_envelope(arg) },
              "success" => fields.fetch("success"), "exit_status" => fields.fetch("exit_status"),
              "artifact" => source_label(inspection_path, project_path),
              "finding" => finding_path ? source_label(finding_path, project_path) : nil,
              "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY, "redaction_review" => "not_reviewed"
            }
          })
          raise OperationError, "TRUSTED_INSPECT_COMMAND_FAILED" unless fields.fetch("success")

          @output.puts "[OK] Trusted inspection artifact: inspection-#{id}"
          @output.puts "[OK] Trusted finding stub: finding-inspect-#{id}" if finding_path
          @output.puts "[OK] Trusted inspection audit: trusted-inspect-#{id}"
          { inspection_path: inspection_path, finding_path: finding_path, audit_path: audit_path, intent_path: intent_path }
        end
      end

      def review(customer, finding_path, decision: "safe", reviewer: default_reviewer, notes: nil, released_message: nil, timestamp: Time.now.utc)
        review_finding(customer, finding_path, decision: decision, reviewer: reviewer, notes: notes, timestamp: timestamp, redact: false, released_message: released_message)
      end

      def redact(customer, finding_path, reviewer: default_reviewer, notes: nil, released_message: nil, timestamp: Time.now.utc)
        review_finding(customer, finding_path, decision: "safe", reviewer: reviewer, notes: notes, timestamp: timestamp, redact: true, released_message: released_message)
      end

      def session(customer, provider: "bedrock", runtime: "silo", reason: nil, session_id: nil, timestamp: Time.now.utc)
        private_operation("SESSION") do
          unless provider.is_a?(String) && provider.b.strip.downcase == "bedrock" &&
                 runtime.is_a?(String) && runtime.b.strip.downcase == "silo" && private_reason?(reason)
            raise OperationError, "TRUSTED_SESSION_INPUT_INVALID"
          end
          raise OperationError, "TRUSTED_SESSION_PLATFORM_UNSUPPORTED" unless linux_host?

          project_path = private_project_path(customer)
          actor = byte_envelope(default_reviewer)
          id = SecureRandom.hex(16)
          session_id = normalize_session_id(session_id, id)
          config_path = write_trusted_silo_config(customer, project_path, session_id, timestamp, id)
          audit_path = write_private_json(project_path, "trusted/audit/trusted-session-#{id}.json", {
            "artifact_version" => PRIVATE_ARTIFACT_VERSION, "generated_at" => timestamp.utc.iso8601,
            "event" => "trusted_session", "actor" => actor,
            "details" => {
              "provider" => "bedrock", "runtime" => "silo", "reason" => byte_envelope(reason),
              "session_id" => session_id, "config" => source_label(config_path, project_path),
              "snapshot" => "before_agent_launch", "status" => "requested",
              "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY
            }
          })
          confined_review_path(project_path, "trusted/session-results/session-#{id}-snapshot.json", create_parents: true)
          snapshot = @runtime.run(["silo", "snapshot", "create", "--config", config_path, "--message", "trusted-data-ai #{id}"], capture: true, binary: true, timeout: nil)
          snapshot_path = write_private_result(project_path, id, "snapshot", snapshot, timestamp)
          raise OperationError, "TRUSTED_SESSION_SNAPSHOT_FAILED" unless snapshot.success?

          # Attached execution bypasses the privacy boundary through inherited
          # stdout/stderr. Legacy session launch is now captured, never streamed.
          launch = @runtime.run(["silo", "agent", "claude", "--config", config_path], capture: true, binary: true, timeout: nil)
          launch_path = write_private_result(project_path, id, "launch", launch, timestamp)
          raise OperationError, "TRUSTED_SESSION_LAUNCH_FAILED" unless launch.success?

          @output.puts "[OK] Trusted session artifacts written: session-#{id}"
          { config_path: config_path, audit_path: audit_path, session_id: session_id,
            snapshot_path: snapshot_path, launch_path: launch_path }
        end
      end

      private

      def private_operation(kind)
        yield
      rescue OperationError => error
        code = PRIVATE_ERROR_CODES.include?(error.message) ? error.message : "TRUSTED_#{kind}_FAILED"
        raise OperationError, code, cause: nil
      rescue StandardError, ScriptError
        raise OperationError, "TRUSTED_#{kind}_FAILED", cause: nil
      end

      def private_reason?(reason)
        reason.is_a?(String) && !reason.b.strip.empty?
      end

      def byte_envelope(value)
        raise TypeError unless value.is_a?(String)

        bytes = value.b
        { "encoding" => "base64", "original_encoding" => value.encoding.name,
          "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes),
          "data" => [bytes].pack("m0") }
      end

      def private_result(result)
        success = result.success?
        status = result.status
        raise TypeError unless [true, false, nil].include?(success) && (status.nil? || status.is_a?(Integer))

        { "success" => success == true, "exit_status" => status,
          "stdout" => result.stdout.nil? ? nil : byte_envelope(result.stdout),
          "stderr" => result.stderr.nil? ? nil : byte_envelope(result.stderr) }
      end

      def private_project_path(customer)
        unless customer.is_a?(String) && CUSTOMER_NAME_PATTERN.match?(customer)
          raise OperationError, "TRUSTED_WORKSPACE_INVALID"
        end
        path = Project.project_path(customer, @env)
        raise OperationError, "TRUSTED_WORKSPACE_INVALID" if File.symlink?(path)

        root = File.realpath(path)
        # Existence/identity anchor only: arbitrary inspection does not require
        # loading private database credentials or validating database settings.
        confined_review_path(root, "config.env")
        root
      rescue StandardError
        raise OperationError, "TRUSTED_WORKSPACE_INVALID", cause: nil
      end

      def write_private_json(project_path, relative, value)
        path = confined_review_path(project_path, relative, create_parents: true)
        write_review_artifact(path, JSON.pretty_generate(value) + "\n", kind: :audit)
        path
      end

      def write_private_result(project_path, id, stage, result, timestamp)
        write_private_json(project_path, "trusted/session-results/session-#{id}-#{stage}.json", {
          "artifact_version" => PRIVATE_ARTIFACT_VERSION, "generated_at" => timestamp.utc.iso8601,
          "operation_id" => id, "stage" => stage, "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY,
          "contains_raw_rows" => true
        }.merge(private_result(result)))
      end

      def write_inspection_finding(project_path, inspection_path, phase, id, timestamp)
        path = confined_review_path(project_path, "trusted/findings/finding-inspect-#{id}.yml", create_parents: true)
        finding = {
          "artifact_version" => ARTIFACT_VERSION, "id" => "finding-inspect-#{id}",
          "generated_at" => timestamp.utc.iso8601, "source" => source_label(inspection_path, project_path),
          "failure" => "trusted_inspection", "severity" => "warning", "phase" => phase,
          "message" => "Review the private byte-preserving inspection record.",
          "exception_class" => nil, "observed_shape" => nil,
          "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY, "contains_raw_rows" => false,
          "recommended_next_step" => "Produce a separately reviewed derivative; exact-byte snapshot approval is still required before publication."
        }
        write_review_artifact(path, finding.to_yaml, kind: :audit)
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

      def write_trusted_silo_config(customer, project_path, session_id, timestamp, id)
        path = confined_review_path(project_path, "trusted/silo/trusted-data-ai-#{id}.yml", create_parents: true)
        config = {
          "artifact_version" => ARTIFACT_VERSION, "kind" => "trusted-data-ai",
          "customer" => customer, "generated_at" => timestamp.utc.iso8601,
          "provider" => "bedrock", "runtime" => "silo",
          "reason" => "Operator justification is recorded in the private audit.",
          "session_id" => session_id, "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY,
          "agent" => { "name" => "claude", "mode" => "bedrock" },
          "snapshots" => { "before_agent_launch" => true },
          "audit" => { "directory" => File.join(project_path, "trusted", "audit") },
          "mounts" => [{ "source" => project_path, "target" => "/workspace/#{customer}",
            "access" => "read_write", "classification" => "raw_customer_project",
            "dev_visibility" => VisibilityPolicy::TRUSTED_ONLY }],
          "safe_handoff" => ["trusted redact", "release prepare", "engineer reviews exact snapshot", "release approve", "release publish"]
        }
        write_review_artifact(path, config.to_yaml, kind: :audit)
        path
      end

      def normalize_session_id(session_id, id)
        return "session-#{id}" if session_id.nil? || session_id == ""
        unless session_id.is_a?(String) && session_id.valid_encoding? &&
               session_id.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/)
          raise OperationError, "TRUSTED_SESSION_INPUT_INVALID"
        end

        session_id
      end

      def linux_host?
        return true if @env["SILO_MIGRATE_FORCE_LINUX"] == "1"
        return false if @env["SILO_MIGRATE_FORCE_NON_LINUX"] == "1"

        RbConfig::CONFIG.fetch("host_os").include?("linux")
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
