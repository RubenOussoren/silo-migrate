# frozen_string_literal: true

require_relative "test_helper"

class DiscourseServiceTest < SiloMigrateTest
  def build_service(env, runtime: SiloMigrate::Runtime::Fake.new)
    out = StringIO.new
    project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
    service = SiloMigrate::Services::DiscourseService.new(runtime: runtime, env: env, output: out)
    [project, service, runtime, out]
  end

  def fake_discourse_docker(base)
    path = File.join(base, "discourse")
    FileUtils.mkdir_p(path)
    launcher = write(File.join(path, "launcher"), "#!/usr/bin/env bash\n")
    FileUtils.chmod(0o755, launcher)
    path
  end

  def test_setup_generates_two_container_yml_files_with_distinct_ports_and_mounts
    with_tmp_base do |dir, env|
      project, service, = build_service(env)
      project.init("acme")
      docker_path = fake_discourse_docker(dir)

      service.setup("acme", docker_path: docker_path, uploads_port: 18080, import_port: 18081, developer_emails: "dev@example.test")

      uploads_yml = YAML.load_file(File.join(docker_path, "containers", "acme-uploads.yml"))
      import_yml = YAML.load_file(File.join(docker_path, "containers", "acme-import.yml"))
      assert_equal ["127.0.0.1:18080:80"], uploads_yml.fetch("expose")
      assert_equal ["127.0.0.1:18081:80"], import_yml.fetch("expose")
      assert_includes uploads_yml.fetch("templates"), "templates/postgres.template.yml"
      assert_includes uploads_yml.fetch("templates"), "templates/redis.template.yml"
      assert_includes uploads_yml.fetch("templates"), "templates/web.template.yml"
      assert_includes uploads_yml.fetch("templates"), "templates/web.ratelimited.template.yml"
      assert_equal "dev@example.test", uploads_yml.dig("env", "DISCOURSE_DEVELOPER_EMAILS")

      guests = uploads_yml.fetch("volumes").map { |entry| entry.fetch("volume").fetch("guest") }
      assert_includes guests, "/migrations/acme/uploads"
      assert_includes guests, "/migrations/acme/output"
      assert_includes guests, "/migrations/acme/shared"

      config = SiloMigrate::Project.load_config("acme", env)
      assert_equal docker_path, config.fetch("DISCOURSE_DOCKER_PATH")
      assert_equal "acme-uploads", config.fetch("DISCOURSE_UPLOADS_CONTAINER")
      assert_equal "acme-import", config.fetch("DISCOURSE_IMPORT_CONTAINER")
      assert_equal "18080", config.fetch("DISCOURSE_UPLOADS_PORT")
      assert_equal "18081", config.fetch("DISCOURSE_IMPORT_PORT")
    end
  end

  def test_setup_generates_uploads_importer_yml
    with_tmp_base do |dir, env|
      project, service, = build_service(env)
      project.init("acme")

      service.setup("acme", docker_path: fake_discourse_docker(dir), import_guest_root: "/migrations/acme")

      path = File.join(project.project_path("acme"), "shared", "bulk_import_scripts", "uploads_importer.yml")
      config = YAML.load_file(path)
      assert_equal "/migrations/acme/output/intermediate.db", config.fetch("source_db_path")
      assert_equal "/migrations/acme/output/uploads.sqlite3", config.fetch("output_db_path")
      assert_equal ["/migrations/acme/uploads"], config.fetch("root_paths")
      assert_equal "/migrations/acme/shared/downloaded_files", config.fetch("download_cache_path")
      refute config.key?("access_key_id")
      refute config.key?("secret_access_key")
    end
  end

  def test_role_commands_never_restore_backup_on_uploads_container
    with_tmp_base do |dir, env|
      project, service, runtime, = build_service(env)
      project.init("acme")
      service.setup("acme", docker_path: fake_discourse_docker(dir))
      backup = write(File.join(dir, "backup.tar.gz"), "backup")

      service.restore_import("acme", backup: backup)

      docker_cp = runtime.commands.find { |command| command[0] == :run && command[1][0, 2] == ["docker", "cp"] }
      restore = runtime.commands.find { |command| command[0] == :run && command[1].include?("DISCOURSE_ENABLE_RESTORE=true bundle exec script/discourse restore backup.tar.gz") }
      assert_includes docker_cp[1].last, "acme-import:"
      assert_equal "acme-import", restore[1][2]
      refute runtime.commands.any? { |command| command[0] == :run && command[1].include?("acme-uploads") && command[1].join(" ").include?("restore") }
    end
  end

  def test_builds_dependency_upload_import_final_import_and_backup_commands
    with_tmp_base do |dir, env|
      project, service, runtime, = build_service(env)
      project.init("acme")
      service.setup("acme", docker_path: fake_discourse_docker(dir))
      write(File.join(project.project_path("acme"), "output", "intermediate.db"), "sqlite")
      write(File.join(project.project_path("acme"), "output", "uploads.sqlite3"), "uploads")

      service.prepare_deps("acme", role: "both")
      service.run_uploads("acme")
      service.import("acme")
      service.backup_import("acme")

      command_texts = runtime.commands.select { |entry| entry[0] == :run }.map { |entry| entry[1].join(" ") }
      assert command_texts.any? { |cmd| cmd.include?("acme-uploads su discourse -c bundle config set --local with generic_import && bundle install") }
      assert command_texts.any? { |cmd| cmd.include?("acme-import su discourse -c bundle config set --local with generic_import && bundle install") }
      assert command_texts.any? { |cmd| cmd.include?("uploads_importer.rb /migrations/acme/shared/bulk_import_scripts/uploads_importer.yml") }
      assert command_texts.any? { |cmd| cmd.include?("IMPORT=1 bundle exec ruby script/bulk_import/generic_bulk.rb /migrations/acme/output/intermediate.db /migrations/acme/output/uploads.sqlite3") }
      assert command_texts.any? { |cmd| cmd.include?("acme-import su discourse -c bundle exec script/discourse backup") }
    end
  end

  def test_refuses_upload_run_without_intermediate_db
    with_tmp_base do |dir, env|
      project, service, = build_service(env)
      project.init("acme")
      service.setup("acme", docker_path: fake_discourse_docker(dir))

      error = assert_raises(SiloMigrate::UsageError) { service.run_uploads("acme") }
      assert_includes error.message, "intermediate.db"
    end
  end

  def test_final_import_uses_intermediate_db_only_when_uploads_db_is_missing
    with_tmp_base do |dir, env|
      project, service, runtime, out = build_service(env)
      project.init("acme")
      service.setup("acme", docker_path: fake_discourse_docker(dir))
      write(File.join(project.project_path("acme"), "output", "intermediate.db"), "sqlite")

      service.import("acme")
      import_command = runtime.commands.reverse.find { |entry| entry[0] == :run && entry[1].join(" ").include?("generic_bulk.rb") }
      assert_includes import_command[1].join(" "), "/migrations/acme/output/intermediate.db"
      refute_includes import_command[1].join(" "), "/migrations/acme/output/uploads.sqlite3"
      assert_includes out.string, "uploads.sqlite3 not found"
    end
  end

  def test_rebuild_start_stop_use_launcher_for_selected_roles
    with_tmp_base do |dir, env|
      project, service, runtime, = build_service(env)
      project.init("acme")
      docker_path = fake_discourse_docker(dir)
      service.setup("acme", docker_path: docker_path)

      service.rebuild("acme", role: "uploads")
      service.start("acme", role: "import")
      service.stop("acme", role: "both")

      assert_includes runtime.commands, [:run, ["./launcher", "rebuild", "acme-uploads"], docker_path, false, nil, nil]
      assert_includes runtime.commands, [:run, ["./launcher", "start", "acme-import"], docker_path, false, 300, nil]
      assert_includes runtime.commands, [:run, ["./launcher", "stop", "acme-uploads"], docker_path, false, 300, nil]
      assert_includes runtime.commands, [:run, ["./launcher", "stop", "acme-import"], docker_path, false, 300, nil]
    end
  end

  def test_setup_fails_when_discourse_docker_path_is_missing
    with_tmp_base do |dir, env|
      project, service, = build_service(env)
      project.init("acme")

      error = assert_raises(SiloMigrate::UsageError) do
        service.setup("acme", docker_path: File.join(dir, "missing-discourse"))
      end
      assert_includes error.message, "Discourse Docker launcher is not installed"
      refute File.exist?(File.join(dir, "missing-discourse", "containers", "acme-uploads.yml"))
    end
  end

  def test_setup_fails_when_launcher_is_missing
    with_tmp_base do |dir, env|
      project, service, = build_service(env)
      project.init("acme")
      docker_path = File.join(dir, "discourse")
      FileUtils.mkdir_p(docker_path)

      error = assert_raises(SiloMigrate::UsageError) do
        service.setup("acme", docker_path: docker_path)
      end
      assert_includes error.message, "Discourse Docker launcher is not installed"
    end
  end

  def test_install_launcher_clones_discourse_docker_on_linux
    with_tmp_base do |dir, env|
      env = env.merge("SILO_MIGRATE_HOST_OS" => "linux")
      runtime = SiloMigrate::Runtime::Fake.new
      project, service, runtime, out = build_service(env, runtime: runtime)
      project.init("acme")
      docker_path = File.join(dir, "discourse")

      def runtime.run(cmd, **kwargs)
        result = super
        if cmd[0, 3] == ["git", "clone", "-b"] && cmd[4].include?("discourse_docker")
          target = cmd.last
          FileUtils.mkdir_p(target)
          File.write(File.join(target, "launcher"), "#!/usr/bin/env bash\n")
          FileUtils.chmod(0o755, File.join(target, "launcher"))
        end
        result
      end

      service.install_launcher(docker_path: docker_path)

      assert File.executable?(File.join(docker_path, "launcher"))
      assert_includes runtime.commands, [:run, ["git", "--version"], nil, true, 30, nil]
      assert_includes runtime.commands, [:run, ["docker", "version", "--format", "{{.Server.Version}}"], nil, true, 30, nil]
      assert runtime.commands.any? { |command| command[0] == :run && command[1][0, 3] == ["git", "clone", "-b"] }
      assert_includes out.string, "Discourse Docker launcher installed"
    end
  end

  def test_install_launcher_fails_on_non_linux
    with_tmp_base do |dir, env|
      env = env.merge("SILO_MIGRATE_HOST_OS" => "darwin")
      project, service, = build_service(env)
      project.init("acme")

      error = assert_raises(SiloMigrate::UsageError) do
        service.install_launcher(docker_path: File.join(dir, "discourse"))
      end
      assert_includes error.message, "Linux-only"
    end
  end
end
