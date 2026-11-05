# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/discourse_runtime"

class DiscourseServiceTest < SiloMigrateTest
  def build_service(env, runtime: DiscourseFakeRuntime.new)
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

  def test_failed_setup_persists_no_discourse_config
    with_tmp_base do |dir, env|
      project, service, = build_service(env)
      project.init("acme")
      docker_path = fake_discourse_docker(dir)
      write(File.join(docker_path, "containers"), "not a directory")

      assert_raises(StandardError) { service.setup("acme", docker_path: docker_path) }

      config = SiloMigrate::Project.load_config("acme", env)
      assert_empty config.keys.select { |key| key.start_with?("DISCOURSE_") }
    end
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
      assert_equal "pg_catalog.english", uploads_yml.dig("params", "db_default_text_search_config")
      assert_equal "32GB", uploads_yml.dig("params", "db_shared_buffers")
      assert_equal "250", uploads_yml.dig("params", "db_max_connections")
      assert_equal "en_US.UTF-8", uploads_yml.dig("env", "LC_ALL")
      assert_equal "en_US.UTF-8", uploads_yml.dig("env", "LANG")
      assert_equal "en_US.UTF-8", uploads_yml.dig("env", "LANGUAGE")
      assert_equal "4", uploads_yml.dig("env", "UNICORN_WORKERS")
      assert_equal "0", uploads_yml.dig("env", "UNICORN_SIDEKIQS")
      assert_equal false, uploads_yml.dig("env", "DISCOURSE_USE_HTTPS")
      assert_equal "200", uploads_yml.dig("env", "DISCOURSE_DB_POOL")
      assert_equal "sudo -E -u postgres psql -d template1 -c \"ALTER SYSTEM SET enable_memoize = off;\"",
                   uploads_yml.dig("hooks", "after_postgres", 0, "exec", "cmd")
      assert_equal "$home/plugins", uploads_yml.dig("hooks", "after_code", 0, "exec", "cd")
      assert_equal [
        "git clone https://github.com/discourse/docker_manager.git",
        "git clone https://github.com/discourse/discourse-signatures.git"
      ], uploads_yml.dig("hooks", "after_code", 0, "exec", "cmd")
      assert_equal [{ "exec" => "echo \"Beginning of custom commands\"" }, { "exec" => "echo \"End of custom commands\"" }],
                   uploads_yml.fetch("run")

      guests = uploads_yml.fetch("volumes").map { |entry| entry.fetch("volume").fetch("guest") }
      assert_includes guests, "/migrations/acme/uploads"
      assert_includes guests, "/migrations/acme/output"
      assert_includes guests, "/migrations/acme/shared"
      assert_equal uploads_yml.reject { |key, _| %w[expose volumes].include?(key) },
                   import_yml.reject { |key, _| %w[expose volumes].include?(key) }

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
      project, service, runtime, out = build_service(env)
      project.init("acme")
      service.setup("acme", docker_path: fake_discourse_docker(dir))
      backup = write(File.join(dir, "backup.tar.gz"), "backup")

      service.restore_import("acme", backup: backup)

      docker_cp = runtime.commands.find { |command| command[0] == :run && command[1][0, 2] == ["docker", "cp"] }
      restore = runtime.commands.find { |command| command[0] == :run && command[1].join(" ").include?("script/discourse restore backup.tar.gz") }
      assert_includes docker_cp[1].last, "acme-import:"
      assert_equal "acme-import", restore[1][2]
      refute runtime.commands.any? { |command| command[0] == :run && command[1].include?("acme-uploads") && command[1].join(" ").include?("restore") }
      assert_includes out.string, "[INFO] Copying Discourse backup into acme-import..."
      assert_includes out.string, "[INFO] Running: docker cp"
      assert_includes out.string, "[INFO] Restoring Discourse backup in acme-import..."
      assert runtime.commands.any? { |entry| entry[0] == :run && entry[1].join(" ").include?("script/discourse enable_restore") }
      refute runtime.restore_allowed
    end
  end

  def test_builds_frozen_dependency_same_instance_standard_import_and_exact_backup_commands
    with_tmp_base do |dir, env|
      project, service, runtime, out = build_service(env)
      project.init("acme")
      service.setup("acme", docker_path: fake_discourse_docker(dir))
      root = project.project_path("acme")
      write(File.join(root, "output", "intermediate.db"), "sqlite")
      runtime.processing_path = File.join(root, "output", "uploads.sqlite3")

      service.prepare_deps("acme", role: "both")
      service.run_uploads("acme", role: "import")
      service.import("acme")
      archive = service.backup_import("acme", filename: "final-01.tar.gz", required_uploads: ["uploads/default/original/sandbox.txt", "uploads/default/original/source.txt"])

      commands = runtime.commands.select { |entry| entry[0] == :run }.map { |entry| entry[1] }
      assert_equal 2, commands.count { |cmd| cmd.last.include?("bundle check") }
      refute commands.any? { |cmd| cmd.last.include?("bundle install") }
      upload = commands.find { |cmd| cmd.last.include?("uploads_importer.rb") }
      assert_equal "acme-import", upload[2]
      importer = commands.find { |cmd| cmd.last.include?("generic_bulk.rb") }
      assert_includes importer.last, "env -u IMPORT -u DELTA_IMPORT -u MERGE_IMPORT"
      assert_includes importer.last, "BUNDLE_WITH\\=generic_import"
      assert_includes importer.last, "generic_bulk.rb /migrations/acme/output/intermediate.db /migrations/acme/output/uploads.sqlite3"
      assert_includes File.basename(archive), "final-01-v"
      manifest = JSON.parse(File.read(File.join(File.dirname(archive), "manifest.json")))
      assert_equal "archive-validated", manifest.fetch("state")
      assert_equal Digest::SHA256.file(archive).hexdigest, manifest.dig("archive", "sha256")
      assert_equal Digest::SHA256.hexdigest("sandbox"), manifest.dig("members", "upload_sha256", "uploads/default/original/sandbox.txt")
      assert_includes out.string, "not restore-proven"
      refute commands.any? { |cmd| cmd.join(" ").include?("ls -1t") }
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

  def test_final_import_requires_processing_database_unless_explicitly_omitted
    with_tmp_base do |dir, env|
      project, service, runtime, out = build_service(env)
      project.init("acme")
      service.setup("acme", docker_path: fake_discourse_docker(dir))
      write(File.join(project.project_path("acme"), "output", "intermediate.db"), "sqlite")
      error = assert_raises(SiloMigrate::UsageError) { service.import("acme") }
      assert_includes error.message, "Upload processing database is required"
      refute runtime.commands.any? { |entry| entry[0] == :run && entry[1].join(" ").include?("generic_bulk.rb") }
      service.import("acme", no_uploads_db: true)
      import_command = runtime.commands.reverse.find { |entry| entry[0] == :run && entry[1].join(" ").include?("generic_bulk.rb") }
      refute_includes import_command[1].join(" "), "/migrations/acme/output/uploads.sqlite3"
      assert_includes out.string, "Explicitly skipping"
    end
  end

  def test_rebuild_start_stop_use_launcher_for_selected_roles
    with_tmp_base do |dir, env|
      project, service, runtime, out = build_service(env)
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
      assert_includes out.string, "[INFO] Rebuilding Discourse uploads container acme-uploads..."
      assert_includes out.string, "[INFO] Running: ./launcher rebuild acme-uploads"
      assert_includes out.string, "[INFO] Starting Discourse import container acme-import..."
      assert_includes out.string, "[INFO] Running: ./launcher start acme-import"
      assert_includes out.string, "[INFO] Stopping Discourse uploads container acme-uploads..."
      assert_includes out.string, "[INFO] Running: ./launcher stop acme-import"
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
