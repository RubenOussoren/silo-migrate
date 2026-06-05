# frozen_string_literal: true

module SiloMigrate
  module Runtime
    module Contract
      PHASE_1_METHODS = %i[
        compose
        run
        run_with_stdin
        container_running?
        wait_for_container_healthy
        exec_import_command
        schema_dump_command
      ].freeze
      PHASE_2_METHODS = (PHASE_1_METHODS + %i[
        schema_metadata_commands
      ]).freeze

      module_function

      def assert_implemented!(runtime, methods: PHASE_1_METHODS, phase: "Phase 1")
        missing = methods.reject { |method| runtime.respond_to?(method) }
        return true if missing.empty?

        raise UsageError, "Runtime #{runtime.class} is missing #{phase} methods: #{missing.join(', ')}"
      end

      def assert_phase_2_implemented!(runtime)
        assert_implemented!(runtime, methods: PHASE_2_METHODS, phase: "Phase 2")
      end
    end
  end
end
