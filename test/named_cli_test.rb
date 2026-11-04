# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/silo_migrate/named_cli"

class NamedCLITest < SiloMigrateTest
  class FakeNamedService
    attr_reader :calls

    def initialize(env:)
      @env = env
      @calls = []
      self.class.calls ||= []
      self.class.last_instance = self
    end

    class << self
      attr_accessor :last_instance, :calls
    end

    %i[init add_source add_dataset add_input plan_validate_inputs execute show recover].each do |method|
      define_method(method) do |*args, **kwargs|
        @calls << [method, args, kwargs]
        self.class.calls << [method, args, kwargs]
        { version: 1, run_id: "run-#{'a' * 32}", status: "planned", input_count: 1, bytes: 7, attempt_id: "attempt-#{'b' * 32}", code: "NAMED_OK", private_path: "/secret" }
      end
    end
  end

  def with_cli
    service_class = SiloMigrate::Services.const_get(:NamedWorkspaceService, false) if SiloMigrate::Services.const_defined?(:NamedWorkspaceService, false)
    SiloMigrate::Services.send(:remove_const, :NamedWorkspaceService) if service_class
    SiloMigrate::Services.const_set(:NamedWorkspaceService, FakeNamedService)
    output = StringIO.new
    error = StringIO.new
    yield SiloMigrate::NamedCLI.new(env: {}, output: output, error: error), output, error
  ensure
    SiloMigrate::Services.send(:remove_const, :NamedWorkspaceService)
    SiloMigrate::Services.const_set(:NamedWorkspaceService, service_class) if service_class
  end

  def test_exact_command_dispatch_and_safe_json_projection
    with_cli do |cli, out, err|
      assert_equal 0, cli.run(%w[source add ws --platform postgres --label local])
      parsed = JSON.parse(out.string)
      assert_equal({ "version" => 1, "run_id" => "run-#{'a' * 32}", "status" => "planned", "attempt_id" => "attempt-#{'b' * 32}", "code" => "NAMED_OK", "input_count" => 1, "bytes" => 7 }, parsed)
      assert_empty err.string
    end
  end

  def test_all_supported_command_shapes_dispatch
    with_cli do |cli, _out, err|
      commands = [
        %w[init ws], %w[source add ws --platform x], %w[dataset add ws --source src],
        %w[input add ws --dataset ds --path inputs/a --sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --bytes 0 --type sql],
        %w[plan validate-inputs ws --dataset ds], %w[run execute ws run], %w[run show ws run], %w[run recover ws run]
      ]
      FakeNamedService.calls = []
      commands.each { |args| assert_equal 0, cli.run(args) }
      run_calls = FakeNamedService.calls.select { |method, _args, _kwargs| %i[execute show recover].include?(method) }
      assert_equal 3, run_calls.length
      run_calls.each { |_method, args, kwargs| assert_equal 1, args.length; assert_equal :run_id, kwargs.keys.fetch(0) }
      assert_empty err.string
    end
  end

  def test_rejects_bad_grammar_without_echoing_private_values
    with_cli do |cli, out, err|
      secret = "secret-private-value"
      [
        ["init", secret, "extra"], ["init", "ws", "--help"],
        ["source", "add", "ws", "--platformx", secret],
        ["source", "add", "ws", "--platform", "one", "--platform", "two"],
        ["dataset", "add", "ws", "--source"], ["input", "add", "ws", "--bytes", "-2"],
        ["run", "execute", "ws", "run", "extra"], ["--version"], ["source", "--help"]
      ].each { |args| assert_equal 1, cli.run(args) }
      assert_empty out.string
      refute_includes err.string, secret
      assert err.string.lines.all? { |line| line.match?(/\AError: NAMED_[A-Z_]+\n\z/) }
    end
  end

  def test_top_level_help_is_fixed_and_invalid_utf8_is_not_reflected
    with_cli do |cli, out, err|
      assert_equal 0, cli.run(["--help"])
      assert_includes out.string, "Usage: silo-migrate named COMMAND"
      assert_empty err.string
      out.truncate(0)
      out.rewind
      bad = "private\xFF".b.force_encoding("UTF-8")
      assert_equal 1, cli.run(["init", bad])
      refute_includes err.string.b, "private"
      assert_empty out.string
    end
  end

  def test_end_to_end_real_service_exposes_only_safe_run_descriptor
    with_tmp_base do |_dir, env|
      workspace = "synthetic"
      SiloMigrate::Services::NamedWorkspaceService.new(env: env).init(workspace)
      root = File.join(env.fetch("SILO_MIGRATE_BASE_PATH"), workspace)
      FileUtils.mkdir_p(File.join(root, "inputs"))
      input = File.join(root, "inputs", "fixture.sql")
      File.binwrite(input, "synthetic")
      output = StringIO.new
      error = StringIO.new
      cli = SiloMigrate::NamedCLI.new(env: env, output: output, error: error)
      source_line = cli.run(%w[source add synthetic --platform synthetic --label private-label])
      assert_equal 0, source_line
      source = JSON.parse(output.string.lines.last).fetch("source_id")
      output.puts # create distinct JSON lines for subsequent calls
      assert_equal 0, cli.run(["dataset", "add", workspace, "--source", source, "--label", "private-dataset"])
      dataset = JSON.parse(output.string.lines.last).fetch("dataset_id")
      digest = Digest::SHA256.file(input).hexdigest
      assert_equal 0, cli.run(["input", "add", workspace, "--dataset", dataset, "--path", "inputs/fixture.sql", "--sha256", digest, "--bytes", "9", "--type", "sql"])
      assert_equal 0, cli.run(["plan", "validate-inputs", workspace, "--dataset", dataset])
      planned = JSON.parse(output.string.lines.last)
      run_id = planned.fetch("run_id")
      assert_equal 0, cli.run(["run", "execute", workspace, run_id])
      completed = JSON.parse(output.string.lines.last)
      assert_equal "completed", completed.fetch("status")
      assert_match(/\Aattempt-[0-9a-f]{32}\z/, completed.fetch("attempt_id"))
      assert_equal "NAMED_OK", completed.fetch("code")
      assert_equal 1, completed.fetch("input_count")
      assert_equal 9, completed.fetch("bytes")
      refute_includes output.string, "private-label"
      refute_includes output.string, "fixture.sql"
      assert_empty error.string
    end
  end

  def test_failed_validation_returns_nonzero_with_safe_outcome_json
    with_tmp_base do |_dir, env|
      workspace = "synthetic"
      service = SiloMigrate::Services::NamedWorkspaceService.new(env: env)
      service.init(workspace)
      root = File.join(env.fetch("SILO_MIGRATE_BASE_PATH"), workspace)
      FileUtils.mkdir_p(File.join(root, "inputs"))
      input = File.join(root, "inputs", "fixture.sql")
      File.binwrite(input, "synthetic")
      source = service.add_source(workspace, platform: "synthetic").fetch(:source_id)
      dataset = service.add_dataset(workspace, source_id: source).fetch(:dataset_id)
      service.add_input(workspace, dataset_id: dataset, path: "inputs/fixture.sql", sha256: Digest::SHA256.file(input).hexdigest, bytes: 9, type: "sql")
      run = service.plan_validate_inputs(workspace, dataset_id: dataset).fetch(:run_id)
      File.binwrite(input, "changed")
      output = StringIO.new
      error = StringIO.new
      cli = SiloMigrate::NamedCLI.new(env: env, output: output, error: error)
      assert_equal 1, cli.run(["run", "execute", workspace, run])
      result = JSON.parse(output.string)
      assert_equal "failed", result.fetch("status")
      assert_equal "NAMED_VALIDATION_FAILED", result.fetch("code")
      assert_equal 0, result.fetch("input_count")
      refute_includes output.string, "fixture.sql"
      assert_empty error.string
      output.truncate(0)
      output.rewind
      assert_equal 0, cli.run(["run", "show", workspace, run])
      assert_equal "failed", JSON.parse(output.string).fetch("status")
    end
  end

  def test_output_write_failure_is_controlled
    with_cli do |cli, _out, _err|
      broken = Object.new
      broken.define_singleton_method(:write) { |_value| raise "private failure" }
      cli = SiloMigrate::NamedCLI.new(env: {}, output: broken, error: StringIO.new)
      assert_equal 1, cli.run(["--help"])
    end
  end
end
