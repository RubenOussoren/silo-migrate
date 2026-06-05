# frozen_string_literal: true

module SiloMigrate
  module Runtime
    class Silo
      PHASE_1_MESSAGE = "Silo runtime is a Phase 4 backend and is not implemented in Phase 1. Use the Docker runtime for Phase 1 migration workflows."

      def compose(*)
        raise NotImplementedError, PHASE_1_MESSAGE
      end

      def run(*)
        raise NotImplementedError, PHASE_1_MESSAGE
      end

      def run_with_stdin(*)
        raise NotImplementedError, PHASE_1_MESSAGE
      end

      def container_running?(*)
        raise NotImplementedError, PHASE_1_MESSAGE
      end

      def wait_for_container_healthy(*)
        raise NotImplementedError, PHASE_1_MESSAGE
      end

      def exec_import_command(*)
        raise NotImplementedError, PHASE_1_MESSAGE
      end

      def schema_dump_command(*)
        raise NotImplementedError, PHASE_1_MESSAGE
      end

      def schema_metadata_commands(*)
        raise NotImplementedError, PHASE_1_MESSAGE
      end
    end
  end
end
