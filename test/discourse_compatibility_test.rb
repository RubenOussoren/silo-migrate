# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/discourse_runtime"

class DiscourseCompatibilityTest < SiloMigrateTest
  def with_service(standard: false)
    with_tmp_base do |dir, env|
      runtime = DiscourseFakeRuntime.new
      project = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new)
      root = project.init("acme")
      launcher = write(File.join(dir, "launcher", "launcher"), "#!/bin/sh\n")
      File.chmod(0o755, launcher)
      service = SiloMigrate::Services::DiscourseService.new(runtime: runtime, env: env, output: StringIO.new)
      service.setup("acme", docker_path: File.dirname(launcher), standard_local: standard.to_s)
      source = write(File.join(root, "output", "intermediate.db"), "sqlite")
      runtime.processing_path = File.join(root, "output", "uploads.sqlite3")
      store = SiloMigrate::WorkflowStore.new("acme", env: env, runtime: runtime)
      yield service, runtime, root, store, source, env
    end
  end

  def commands(runtime)
    runtime.commands.select { |entry| entry[0] == :run }.map { |entry| entry[1].join(" ") }
  end

  def test_standard_fixture_profile_is_opt_in_and_pins_app_not_launcher_or_image
    with_service(standard: true) do |service, _runtime, root, _store, _source, env|
      config = SiloMigrate::Project.load_config("acme", env)
      container = YAML.load_file(File.join(config.fetch("DISCOURSE_DOCKER_PATH"), "containers", "acme-import.yml"))
      assert_equal "1", container.dig("env", "UNICORN_WORKERS")
      assert_equal "128MB", container.dig("params", "db_shared_buffers")
      assert_equal SiloMigrate::Services::DiscourseService::STANDARD_DISCOURSE_REVISION, container.dig("params", "version")
      refute container.fetch("hooks").key?("after_code")
      uploader = YAML.load_file(File.join(root, "shared", "bulk_import_scripts", "uploads_importer.yml"))
      assert_equal 1.0, uploader["thread_count_factor"]
      assert_equal [], uploader["path_replacements"]
      %w[fix_missing delete_missing_uploads delete_surplus_uploads create_optimized_images].each { |key| assert_equal false, uploader[key] }
      refute uploader.key?("thread_factor")
      refute uploader.key?("optimized_images")
      assert_equal "txt", uploader.dig("site_settings", "authorized_extensions")
      assert_equal 1024, uploader.dig("site_settings", "max_attachment_size_kb")
      assert_equal false, uploader.dig("site_settings", "enable_s3_uploads")
    end
  end

  def test_uploads_role_default_is_not_silently_redirected_and_cannot_repeat
    with_service do |service, runtime, _root, store|
      service.run_uploads("acme")
      assert commands(runtime).any? { |text| text.include?("acme-uploads") && text.include?("uploads_importer.rb") }
      assert_equal "processed", store.read.dig("discourse", "uploads", "state")
      assert_raises(SiloMigrate::UsageError) { service.run_uploads("acme") }
      assert_raises(SiloMigrate::UsageError) { service.run_uploads("acme", role: "both") }
    end
  end

  def test_failed_same_destination_upload_is_dirty_and_no_repeat
    with_service do |service, runtime, _root, store|
      runtime.fail_on = "uploads_importer.rb"
      assert_raises(SiloMigrate::UsageError) { service.run_uploads("acme", role: "import") }
      assert_equal "dirty", store.read.dig("discourse", "state")
      assert_equal "dirty", store.read.dig("discourse", "uploads", "state")
      count = commands(runtime).count { |text| text.include?("uploads_importer.rb") || text.include?("generic_bulk.rb") }
      assert_raises(SiloMigrate::UsageError) { service.run_uploads("acme", role: "import") }
      assert_raises(SiloMigrate::UsageError) { service.import("acme", no_uploads_db: true) }
      assert_equal count, commands(runtime).count { |text| text.include?("uploads_importer.rb") || text.include?("generic_bulk.rb") }
    end
  end

  def test_changed_intermediate_or_processing_db_blocks_import
    with_service do |service, runtime, _root, _store, source|
      service.run_uploads("acme", role: "import")
      File.write(source, "different snapshot")
      error = assert_raises(SiloMigrate::UsageError) { service.import("acme") }
      assert_includes error.message, "lineage"
      refute commands(runtime).any? { |text| text.include?("generic_bulk.rb") }
    end
  end

  def test_failed_standard_import_is_dirty_and_does_not_repeat
    with_service do |service, runtime, _root, store|
      runtime.fail_on = "generic_bulk.rb"
      assert_raises(SiloMigrate::UsageError) { service.import("acme", no_uploads_db: true) }
      assert_equal "dirty", store.read.dig("discourse", "state")
      runtime.fail_on = nil
      assert_raises(SiloMigrate::UsageError) { service.import("acme", no_uploads_db: true) }
    end
  end

  def test_skips_invalid_and_uncheckpointed_processing_databases_are_refused
    with_service do |service, runtime|
      File.write(runtime.processing_path, "not sqlite")
      assert_raises(SiloMigrate::UsageError) { service.import("acme") }
      File.delete(runtime.processing_path)
      DiscourseFakeRuntime.processing_db(runtime.processing_path, skipped: true)
      assert_raises(SiloMigrate::UsageError) { service.import("acme") }
      File.delete(runtime.processing_path)
      DiscourseFakeRuntime.processing_db(runtime.processing_path)
      File.write("#{runtime.processing_path}-wal", "unclosed")
      assert_raises(SiloMigrate::UsageError) { service.import("acme") }
      refute commands(runtime).any? { |text| text.include?("generic_bulk.rb") }
    end
  end

  def test_standard_local_refuses_unrelated_processing_database
    with_service(standard: true) do |service, runtime|
      DiscourseFakeRuntime.processing_db(runtime.processing_path)
      error = assert_raises(SiloMigrate::UsageError) { service.import("acme") }
      assert_includes error.message, "same destination"
    end
  end

  def test_scoped_restore_preserves_original_false_and_true_permissions
    [false, true].each do |prior|
      with_service do |service, runtime, root, store|
        runtime.restore_allowed = prior
        runtime.restore_changes_permission = !prior
        backup = write(File.join(root, "baseline.tar.gz"), "baseline backup")
        service.restore_import("acme", backup: backup)
        assert_equal prior, runtime.restore_allowed
        assert_equal "restored", store.read.dig("discourse", "state")
        assert_equal Digest::SHA256.hexdigest("baseline backup"), store.read.dig("discourse", "baseline", "sha256")
        if prior
          refute commands(runtime).any? { |text| text.include?("disable_restore") }
        else
          assert commands(runtime).any? { |text| text.include?("disable_restore") }
        end
        assert_raises(SiloMigrate::UsageError) { service.restore_import("acme", backup: backup) }
      end
    end
  end

  def test_restore_failure_and_enable_failure_both_clean_up_and_leave_dirty
    ["script/discourse restore ", "script/discourse enable_restore"].each do |failure|
      with_service do |service, runtime, root, store|
        runtime.fail_on = failure
        backup = write(File.join(root, "baseline.tar.gz"), "baseline")
        assert_raises(SiloMigrate::UsageError) { service.restore_import("acme", backup: backup) }
        refute runtime.restore_allowed
        assert_equal "dirty", store.read.dig("discourse", "state")
        assert commands(runtime).any? { |text| text.include?("disable_restore") }
      end
    end
  end

  def test_restore_cleanup_failure_is_not_success
    with_service do |service, runtime, root, store|
      runtime.fail_on = "disable_restore"
      backup = write(File.join(root, "baseline.tar.gz"), "baseline")
      assert_raises(SiloMigrate::UsageError) { service.restore_import("acme", backup: backup) }
      assert_equal "dirty", store.read.dig("discourse", "state")
      refute File.exist?(File.join(root, "output", "discourse-import-restored.txt"))
    end
  end

  def test_backup_rejects_missing_and_unsafe_output_identities_before_runtime
    with_service do |service, runtime|
      [nil, "../escape.tar.gz", "x;touch-x.tar.gz", "x.sql.gz", "-option.tar.gz"].each do |filename|
        assert_raises(SiloMigrate::UsageError) { service.backup_import("acme", filename: filename) }
      end
      refute commands(runtime).any? { |text| text.include?("script/discourse backup") }
    end
  end

  def test_backup_failure_consumes_identity_and_does_not_select_stale_output
    with_service do |service, runtime, root|
      preserved = write(File.join(root, "output", "discourse-backups", "old.tar.gz"), "old backup")
      runtime.fail_on = "script/discourse backup "
      assert_raises(SiloMigrate::UsageError) { service.backup_import("acme", filename: "final.tar.gz") }
      runtime.fail_on = nil
      assert_raises(SiloMigrate::UsageError) { service.backup_import("acme", filename: "final.tar.gz") }
      assert_equal "old backup", File.read(preserved)
      assert_equal "dirty", JSON.parse(File.read(File.join(root, "output", "discourse-backups", "final", "manifest.json")))["state"]
    end
  end

  def test_backup_fails_on_missing_ambiguous_or_unexpected_remote_output
    ["", "final-v1.tar.gz\nfinal-v2.tar.gz\n", "other-v1.tar.gz\n", "../../final-v1.tar.gz\n"].each do |listing|
      with_service do |service, runtime|
        runtime.listed_files = listing
        assert_raises(SiloMigrate::UsageError) { service.backup_import("acme", filename: "final.tar.gz") }
        refute runtime.commands.any? { |entry| entry[0] == :run && entry[1][0, 2] == ["docker", "cp"] }
      end
    end
  end

  def test_backup_copy_success_without_actual_regular_file_is_failure
    with_service do |service, runtime|
      runtime.omit_copy = true
      assert_raises(SiloMigrate::UsageError) { service.backup_import("acme", filename: "final.tar.gz") }
    end
  end

  def test_backup_requires_db_local_uploads_and_exact_required_members
    [{ "dump.sql.gz" => "not gzip" }, { "uploads/default/a.txt" => "upload" },
     { "dump.sql.gz" => "not gzip", "uploads/default/a.txt" => "upload" }].each do |members|
      with_service do |service, runtime|
        runtime.archive_members = members
        assert_raises(SiloMigrate::UsageError) { service.backup_import("acme", filename: "final.tar.gz") }
      end
    end
    with_service do |service, _runtime|
      assert_raises(SiloMigrate::UsageError) { service.backup_import("acme", filename: "final.tar.gz", required_uploads: ["uploads/default/missing.txt"]) }
    end
  end

  def test_backup_refuses_archive_traversal_and_unsafe_required_member
    with_service do |service, runtime|
      runtime.archive_members["../escape"] = "unsafe"
      assert_raises(SiloMigrate::UsageError) { service.backup_import("acme", filename: "final.tar.gz") }
      assert_raises(SiloMigrate::UsageError) { service.backup_import("acme", filename: "other.tar.gz", required_uploads: ["uploads/../escape"]) }
    end
  end

  def test_backup_refuses_symlink_output_directory
    with_service do |service, _runtime, root|
      File.symlink(File.join(root, "shared"), File.join(root, "output", "discourse-backups"))
      assert_raises(SiloMigrate::UsageError) { service.backup_import("acme", filename: "final.tar.gz") }
    end
  end

  def test_shell_paths_are_quoted_and_mode_variables_unset_only_in_command
    with_service do |service, runtime, _root, _store, _source, env|
      config = SiloMigrate::Project.load_config("acme", env)
      config["DISCOURSE_IMPORT_GUEST_ROOT"] = "/migrations/a b;literal"
      config["DELTA_IMPORT"] = "0"
      config["MERGE_IMPORT"] = "1"
      SiloMigrate::Project.save_config("acme", config, env)
      service.import("acme", no_uploads_db: true)
      text = runtime.commands.reverse.find { |entry| entry[0] == :run && entry[1].last.include?("generic_bulk.rb") }[1].last
      argv = Shellwords.split(text.delete_prefix("cd /var/www/discourse && exec "))
      assert_equal "/migrations/a b;literal/output/intermediate.db", argv.last
      assert_includes argv, "-u"
      assert_includes argv, "DELTA_IMPORT"
      assert_equal "0", SiloMigrate::Project.load_config("acme", env)["DELTA_IMPORT"]
      assert_equal "1", SiloMigrate::Project.load_config("acme", env)["MERGE_IMPORT"]
    end
  end
  def local_source(source, root, filename: "fixture.txt", relative_path: "", url: nil)
    File.delete(source)
    db = SQLite3::Database.new(source)
    db.execute("CREATE TABLE uploads (filename TEXT, relative_path TEXT, url TEXT, data BLOB)")
    db.execute("INSERT INTO uploads VALUES (?, ?, ?, NULL)", [filename, relative_path, url])
    db.close
    write(File.join(root, "uploads", "fixture.txt"), "synthetic attachment")
  end

  def test_standard_same_destination_preserves_baseline_lineage_and_checks_reports
    with_service(standard: true) do |service, runtime, root, store, source|
      backup = write(File.join(root, "baseline.tar.gz"), "synthetic baseline")
      service.restore_import("acme", backup: backup)
      local_source(source, root)
      service.run_uploads("acme", role: "import")
      assert_equal "restored", store.read.dig("discourse", "state")
      service.import("acme")
      assert_equal "imported", store.read.dig("discourse", "state")
      assert_equal Digest::SHA256.hexdigest("synthetic baseline"), store.read.dig("discourse", "baseline", "sha256")
      assert commands(runtime).any? { |text| text.include?("Etc.nprocessors") && text.include?("LocalStore") }
      assert commands(runtime).any? { |text| text.include?("wc -c") && text.include?("65536") }
    end
  end

  def test_standard_import_does_not_accept_exit_zero_with_issues_or_missing_completion
    ["", "Import issues (details in /tmp/issues):\n  missing upload: 1\nDone! (0 minutes)\n", "ERROR: failed\nDone! (0 minutes)\n", "x" * 65_537].each do |report|
      with_service(standard: true) do |service, runtime, _root, store|
        runtime.import_report = report
        assert_raises(SiloMigrate::UsageError) { service.import("acme", no_uploads_db: true) }
        assert_equal "dirty", store.read.dig("discourse", "state")
      end
    end
  end

  def test_standard_local_refuses_url_traversal_and_symlink_inputs_without_runtime
    [{ url: "https://example.invalid/a.txt" }, { relative_path: "../" }, { filename: "/tmp/a.txt" }].each do |options|
      with_service(standard: true) do |service, runtime, root, _store, source|
        local_source(source, root, **options)
        assert_raises(SiloMigrate::UsageError) { service.run_uploads("acme", role: "import") }
        refute commands(runtime).any? { |text| text.include?("uploads_importer.rb") }
      end
    end
    with_service(standard: true) do |service, runtime, root, _store, source|
      local_source(source, root)
      File.rename(File.join(root, "uploads", "fixture.txt"), File.join(root, "uploads", "real.txt"))
      File.symlink("real.txt", File.join(root, "uploads", "fixture.txt"))
      assert_raises(SiloMigrate::UsageError) { service.run_uploads("acme", role: "import") }
      refute commands(runtime).any? { |text| text.include?("uploads_importer.rb") }
    end
  end

  def test_prepare_deps_never_installs_on_missing_frozen_dependencies
    with_service do |service, runtime|
      runtime.fail_on = "bundle check"
      assert_raises(SiloMigrate::UsageError) { service.prepare_deps("acme", role: "import") }
      refute commands(runtime).any? { |text| text.include?("bundle install") || text.include?("bundle update") }
    end
  end

  def test_processing_database_tampering_blocks_import_even_if_still_valid_sqlite
    with_service do |service, runtime|
      service.run_uploads("acme", role: "import")
      db = SQLite3::Database.new(runtime.processing_path)
      db.execute("UPDATE uploads SET markdown = 'changed'")
      db.close
      error = assert_raises(SiloMigrate::UsageError) { service.import("acme") }
      assert_includes error.message, "lineage"
      refute commands(runtime).any? { |text| text.include?("generic_bulk.rb") }
    end
  end

  def test_standard_runtime_pin_mismatch_stays_dirty_without_upload_execution
    with_service(standard: true) do |service, runtime, root, store, source|
      local_source(source, root)
      runtime.fail_on = "rev-parse HEAD"
      assert_raises(SiloMigrate::UsageError) { service.run_uploads("acme", role: "import") }
      assert_equal "dirty", store.read.dig("discourse", "state")
      refute commands(runtime).any? { |text| text.include?("uploads_importer.rb") }
    end
  end

  def test_standard_mutable_sqlite_inputs_must_not_be_hardlinks
    with_service(standard: true) do |service, runtime, root, _store, source|
      local_source(source, root)
      File.link(source, File.join(root, "preserved-input.sqlite3"))
      error = assert_raises(SiloMigrate::UsageError) { service.run_uploads("acme", role: "import") }
      assert_includes error.message, "hardlink"
      refute commands(runtime).any? { |text| text.include?("uploads_importer.rb") }
    end
  end

end
