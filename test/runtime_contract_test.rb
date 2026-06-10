# frozen_string_literal: true

require_relative "test_helper"

class RuntimeContractTest < SiloMigrateTest
  def test_docker_fake_and_silo_expose_phase_1_runtime_methods
    [SiloMigrate::Runtime::Docker.new, SiloMigrate::Runtime::Fake.new, SiloMigrate::Runtime::Silo.new].each do |runtime|
      assert SiloMigrate::Runtime::Contract.assert_implemented!(runtime)
    end
  end

  def test_docker_fake_and_silo_expose_phase_2_runtime_methods
    [SiloMigrate::Runtime::Docker.new, SiloMigrate::Runtime::Fake.new, SiloMigrate::Runtime::Silo.new].each do |runtime|
      assert SiloMigrate::Runtime::Contract.assert_phase_2_implemented!(runtime)
    end
  end

  def test_silo_runtime_fails_with_phase_boundary_message
    error = assert_raises(NotImplementedError) do
      SiloMigrate::Runtime::Silo.new.schema_metadata_commands("acme_initial_mariadb", "mariadb", "forum", "password")
    end

    assert_includes error.message, "Phase 4"
    assert_includes error.message, "Docker runtime"
  end

  def test_fake_runtime_records_phase_1_operations
    runtime = SiloMigrate::Runtime::Fake.new

    runtime.compose("acme", ["ps"], capture: true)
    runtime.container_running?("acme_initial_mariadb")
    runtime.wait_for_container_healthy("acme_initial_mariadb", timeout: 5)
    runtime.exec_import_command("acme_initial_mariadb", "mariadb", "forum", "password", max_packet: "512M", disable_keys: true)
    runtime.schema_dump_command("acme_initial_mariadb", "mariadb", "forum", "password")
    runtime.schema_metadata_commands("acme_initial_mariadb", "mariadb", "forum", "password")
    runtime.run(["true"], capture: true, timeout: 1)
    runtime.run_with_stdin(["cat"]) { |stdin| stdin.write("hello") }

    assert_equal [
      :compose,
      :container_running?,
      :wait_for_container_healthy,
      :exec_import_command,
      :schema_dump_command,
      :schema_metadata_commands,
      :run,
      :run_with_stdin
    ], runtime.operations.map(&:first)
  end

  def test_mysql_fast_import_command_does_not_force_whole_dump_transaction
    command = SiloMigrate::Runtime::Docker.new.exec_import_command(
      "acme_initial_mariadb",
      "mariadb",
      "forum",
      "password",
      max_packet: "512M",
      disable_keys: true
    )

    init_command = command.find { |arg| arg.start_with?("--init-command=") }
    assert_includes command, "--max-allowed-packet=512M"
    assert_includes init_command, "FOREIGN_KEY_CHECKS=0"
    assert_includes init_command, "UNIQUE_CHECKS=0"
    assert_includes init_command, "max_allowed_packet=1000000000"
    refute_includes init_command, "AUTOCOMMIT=0"
  end
end
