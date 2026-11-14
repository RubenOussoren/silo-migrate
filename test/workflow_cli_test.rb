# frozen_string_literal: true
# This boundary test needs no database/runtime gems: its backend is deliberately stubbed.
require 'minitest/autorun'
require 'minitest/mock'
require 'stringio'
require_relative '../lib/silo_migrate/named_workspace_store'
require_relative '../lib/silo_migrate/standard_store'
require 'silo_migrate/standard_cli'

class WorkflowCLITest < Minitest::Test
  RUN = 'run-' + 'a' * 32
  GENERATION = 'b' * 64
  INPUT = 'input-' + 'c' * 32

  class Backend
    attr_reader :calls
    def initialize
      @calls = []
    end
    def merge_contract
      @calls << [:contract]
      { 'contract' => { 'version' => 1 } }
    end
    def validate_merge_settings(**args)
      @calls << [:validate, args]
      { 'status' => 'refused', 'reason' => 'invalid_type', 'key_path' => ['invented', 1] }
    end
    def merge_exact_existence(**args)
      @calls << [:exists, args]
      { 'results' => %w[found absent ambiguous unproven] }
    end
  end

  def invoke(args, input: '')
    out, err = StringIO.new, StringIO.new
    cli = SiloMigrate::StandardCLI.new(output: out, error: err)
    old_stdin = $stdin
    $stdin = StringIO.new(input)
    code = cli.stub(:service, @backend) { cli.run(args) }
    [code, out.string, err.string]
  ensure
    $stdin = old_stdin
  end

  def setup
    @backend = Backend.new
  end

  def binding_args
    ['--prepared-from', RUN, '--generation', GENERATION]
  end

  def test_exact_public_methods_and_private_receipts
    assert_equal 0, invoke(%w[workflow describe invented]).first
    code, out, err = invoke(%w[workflow validate invented] + binding_args + ['--settings', INPUT])
    assert_equal 0, code
    assert_empty err
    assert_equal ['invented', 1], JSON.parse(out)['key_path']
    assert_equal [:validate, { prepared_from: RUN, generation: GENERATION, settings: INPUT }], @backend.calls.last
    queries = [{ 'kind' => 'category', 'path' => ['Invented Root', 'Invented Child'] }, { 'kind' => 'group', 'name' => 'Invented' }]
    code, out, err = invoke(%w[workflow exists invented] + binding_args + %w[--queries-file -], input: JSON.generate(queries))
    assert_equal 0, code
    assert_empty err
    assert_equal %w[found absent ambiguous unproven], JSON.parse(out)['results']
    assert_equal [:exists, { prepared_from: RUN, generation: GENERATION, queries: queries }], @backend.calls.last
  end

  def test_invalid_or_unbounded_queries_never_reach_backend
    [[], [{}], [{ kind: 'category', name: 'Invented' }], [{ kind: 'tag', name: 'x' * 257 }],
     [{ kind: 'group', name: "x\n" }], [{ kind: 'tag', name: 'Invented', sql: 'SELECT 1' }],
     Array.new(101) { { kind: 'tag', name: 'Invented' } },
     Array.new(9) { { kind: 'category', path: Array.new(32, 'x' * 256) } }].each do |queries|
      code, out, err = invoke(%w[workflow exists invented] + binding_args + %w[--queries-file -], input: JSON.generate(queries))
      assert_equal 1, code
      assert_empty out
      assert_equal "Error: STANDARD_ARGUMENTS_INVALID\n", err
    end
    [ %w[workflow describe invented extra], %w[agent workflow describe invented],
      %w[workflow exists invented] + binding_args + %w[--queries-file /private/file],
      %w[workflow validate invented] + binding_args + %w[--settings /private/file],
      %w[workflow validate invented] + binding_args + ['--settings', INPUT, '--generation', GENERATION]
    ].each { |args| assert_equal 1, invoke(args).first }
    assert_empty @backend.calls
  end
end
