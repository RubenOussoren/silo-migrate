# frozen_string_literal: true

module SiloMigrate
  module Services
    # Explicit operator publication only. Visibility labels, schema extraction,
    # converter runs and finding/fixture generation never authorize release.
    class AIWorkspaceService
      def initialize(env: ENV, output: $stdout)
        @release_service = ArtifactReleaseService.new(env: env, output: output)
      end

      def prepare(customer)
        @release_service.publish(customer)
      end

      alias refresh prepare

      # Kept for existing producer callers; deliberately performs no IO or
      # automatic publication, even if a previous view/manifest exists.
      def refresh_if_prepared(_customer)
        false
      end
    end
  end
end
