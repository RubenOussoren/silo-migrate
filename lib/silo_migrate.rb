# frozen_string_literal: true

require_relative "silo_migrate/version"
require_relative "silo_migrate/errors"
require_relative "silo_migrate/constants"
require_relative "silo_migrate/user_config"
require_relative "silo_migrate/project"
require_relative "silo_migrate/bounded_buffer"
require_relative "silo_migrate/compose_generator"
require_relative "silo_migrate/dump_tools"
require_relative "silo_migrate/sql_tools"
require_relative "silo_migrate/sql_text"
require_relative "silo_migrate/xml_to_sql"
require_relative "silo_migrate/json_to_sql"
require_relative "silo_migrate/visibility_policy"
require_relative "silo_migrate/runtime/contract"
require_relative "silo_migrate/runtime/docker"
require_relative "silo_migrate/runtime/fake"
require_relative "silo_migrate/runtime/silo"
require_relative "silo_migrate/services/converter_settings_service"
require_relative "silo_migrate/services/converter_summary_service"
require_relative "silo_migrate/services/converter_findings_service"
require_relative "silo_migrate/services/synthetic_fixture_service"
require_relative "silo_migrate/services/ai_workspace_service"
require_relative "silo_migrate/services/trusted_workflow_service"
require_relative "silo_migrate/services/doctor_service"
require_relative "silo_migrate/services/install_service"
require_relative "silo_migrate/services/discourse_service"
require_relative "silo_migrate/services/project_service"
require_relative "silo_migrate/services/import_service"
require_relative "silo_migrate/services/schema_service"
require_relative "silo_migrate/interactive"
require_relative "silo_migrate/cli"

module SiloMigrate
  ROOT = File.expand_path("..", __dir__)

  def self.root
    ROOT
  end
end
