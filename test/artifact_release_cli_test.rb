# frozen_string_literal: true

require_relative "test_helper"

class ArtifactReleaseCLITest < SiloMigrateTest
  def test_engineer_cli_snapshot_approval_publication_and_revocation
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      root = SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new).init("acme")
      FileUtils.mkdir_p(File.join(root, "discourse-converters"))
      source = write(File.join(root, "schema", "private-source-name.txt"), "Reviewed synthetic contents\n")
      out = StringIO.new
      err = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: err)
      assert_equal 0, cli.run(["release", "prepare", "acme", "schema/private-source-name.txt", "--class", "schema"])
      prepared = JSON.parse(out.string.lines.last)
      snapshot = File.join(root, ".silo-migrate", "releases", "snapshots", "#{prepared.fetch('id')}.bin")
      assert_equal File.binread(source), File.binread(snapshot)
      assert_equal Digest::SHA256.file(snapshot).hexdigest, prepared.fetch("sha256")
      approval = ["release", "approve", "acme", prepared.fetch("id"), "--sha256", prepared.fetch("sha256"), "--bytes", prepared.fetch("bytes").to_s, "--reviewer", "private-reviewer"]
      assert_equal 1, cli.run(approval)
      assert_includes err.string, "RELEASE_APPROVAL_REQUIRED"
      assert_equal 0, cli.run(approval + ["--reviewed", "--notes", "private-notes"])
      File.binwrite(source, "new private source contents")
      assert_equal 0, cli.run(["release", "publish", "acme", prepared.fetch("id")])
      published = JSON.parse(out.string.lines.last)
      entry = published.fetch("artifacts").fetch(0)
      view = File.join(root, "discourse-converters", "safe-artifacts")
      assert_equal File.binread(snapshot), File.binread(File.join(view, entry.fetch("file")))
      %w[private-source-name private-reviewer private-notes].each { |sentinel| refute_includes out.string, sentinel }
      assert_equal 0, cli.run(["release", "status", "acme", prepared.fetch("id")])
      assert_equal "approved", JSON.parse(out.string.lines.last).fetch("state")
      assert_equal 0, cli.run(["release", "revoke", "acme", prepared.fetch("id")])
      refute File.exist?(view)
      assert_equal 1, cli.run(["release", "publish", "acme", prepared.fetch("id")])
      assert_includes err.string, "RELEASE_NOT_APPROVED"
      assert_equal 1, cli.run(approval + ["--reviewed"])
      assert_includes err.string, "RELEASE_APPROVAL_REQUIRED"
    end
  end

  def test_release_parser_and_source_errors_are_fixed_and_do_not_echo_private_values
    with_tmp_base do |_dir, env|
      runtime = SiloMigrate::Runtime::Fake.new
      SiloMigrate::Services::ProjectService.new(runtime: runtime, env: env, output: StringIO.new).init("acme")
      out = StringIO.new
      err = StringIO.new
      cli = SiloMigrate::CLI.new(runtime: runtime, env: env, output: out, error: err)
      [
        ["release", "prepare", "acme", "../private-sentinel", "--class", "schema"],
        ["release", "prepare", "acme", "schema/private-sentinel", "--nots=private-sentinel"],
        ["release", "approve", "acme", "private-sentinel", "--bytes", "private-sentinel"],
        ["release", "private-sentinel", "acme"],
        ["release", "status", "acme", "private-sentinel"],
        ["ai", "private-sentinel", "acme"]
      ].each do |args|
        assert_equal 1, cli.run(args)
      end
      refute_includes err.string, "private-sentinel"
      assert_empty out.string
    end
  end

  def test_release_help_describes_exact_content_attestation
    out = StringIO.new
    cli = SiloMigrate::CLI.new(runtime: SiloMigrate::Runtime::Fake.new, output: out, error: StringIO.new)
    assert_equal 0, cli.run(["release", "--help"])
    %w[prepare approve publish revoke status --reviewed --sha256 --bytes].each { |word| assert_includes out.string, word }
  end
end
