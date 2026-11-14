# frozen_string_literal: true

# Shared lifecycle primitives. Engines are registered by shipped code, never by a
# project document. A capability describes an implemented interface, not permission
# to access a database or execute a run.
require "digest"
require "json"
require_relative "../../runtime/shared/merge_contract"

module SiloMigrate
  module MergeProcess
    VERSION = 1
    class Refused < StandardError; end

    class Registry
      def initialize
        @engines = {}
      end

      def register(id, adapter)
        unless id.is_a?(String) && id.match?(/\A[a-z][a-z0-9-]{0,63}\z/) && !@engines.key?(id) &&
               %i[describe validate verify_output].all? { |method| adapter.respond_to?(method) }
          raise Refused, "engine_registration_invalid"
        end
        @engines[id] = adapter
        self
      end

      def fetch(id)
        @engines.fetch(id) { raise Refused, "engine_unsupported" }
      end
    end

    # No project-supplied exposure flags are consumed here. The caller retains the
    # result in trusted evidence; an existing, reviewed projection handles release.
    class Evidence
      MAX_COUNT = 999_999_999_999
      PHASES = %w[validation preflight transfer postflight output].freeze
      attr_reader :document

      def initialize(engine:)
        raise Refused, "engine_invalid" unless engine.is_a?(String) && engine.match?(/\A[a-z][a-z0-9-]{0,63}\z/)
        @document = { "version" => VERSION, "engine" => engine, "phases" => {} }
      end

      def record(phase, counts:, complete:)
        raise Refused, "evidence_phase_invalid" unless PHASES.include?(phase) && [true, false].include?(complete)
        unless counts.is_a?(Hash) && counts.size <= 64 && counts.all? do |name, value|
          name.is_a?(String) && name.match?(/\A[a-z][a-z0-9_]{0,63}\z/) && value.is_a?(Integer) && value.between?(0, MAX_COUNT)
        end
          raise Refused, "evidence_counts_invalid"
        end
        @document["phases"][phase] = { "complete" => complete, "counts" => counts.dup }
        self
      end
    end

    def self.registry
      Registry.new.register(MergeAdapters::PreparedDiscourseAdapter::ID, MergeAdapters::PreparedDiscourseAdapter.new)
    end

    # Used by shipped adapters and test-only adapters alike. This small coordinator
    # deliberately owns no engine SQL, schema, settings or asset-layout knowledge.
    class Gate
      def initialize(registry)
        @registry = registry
      end

      def validate(engine:, context:)
        adapter = @registry.fetch(engine)
        result = adapter.validate(context)
        unless result.is_a?(Hash) && result["valid"] == true && result["binding"].is_a?(Hash)
          raise Refused, "validation_refused"
        end
        result
      end

      def verify_output(engine:, context:, manifest:)
        result = @registry.fetch(engine).verify_output(context, manifest)
        raise Refused, "output_unproven" unless result == true
        true
      end
    end
  end
end

require_relative "merge_adapters/prepared_discourse"
