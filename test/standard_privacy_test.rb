# frozen_string_literal: true
require_relative 'standard_workflow_test'
require 'silo_migrate/services/standard_findings_service'
require 'silo_migrate/standard_cli'

class StandardPrivacyTest < SiloMigrateTest
  include StandardTestWorkspace
  MARKER = 'PRIVATE-MARKER-984cf8a310'
  PASSWORD = 'private-password-b53dcf'

  def plant_private_material(run_id)
    %w[logs/private.log evidence/private.json private/failure.json private/admin-password].each do |relative|
      @service.store.write_private(@service.store.run_dir(run_id, relative), "#{MARKER}\n#{PASSWORD}\n#{@root}")
    end
    @service.store.update do |state|
      run = state['runs'].fetch(run_id)
      run['artifacts']['final'] = { 'filename' => 'final.tar.gz', 'path' => "#{@root}/#{MARKER}", 'sha256' => 'a' * 64, 'bytes' => 12 }
      run['results']['private'] = "#{MARKER} #{PASSWORD} #{@root}"
    end
  end

  def assert_private_free(value)
    text = value.is_a?(String) ? value : JSON.generate(value)
    [MARKER, PASSWORD, @root, @service.store.root].each { |private_text| refute_includes text, private_text }
  end

  def cli(*args)
    out = StringIO.new
    err = StringIO.new
    command = SiloMigrate::StandardCLI.new(env: @env, runtime: @runtime, code_root: @code_root, output: out, error: err)
    code = command.stub(:service, new_standard) { command.run(args) }
    [code, out.string, err.string]
  end

  def test_status_show_run_show_plan_do_not_expose_private_material
    with_standard do
      add_standard_input('binary', MARKER, name: MARKER)
      plan = approve
      run_id = claim(plan)
      plant_private_material(run_id)
      assert_private_free @service.status
      assert_private_free @service.show_run(run_id)
      assert_private_free @service.show_plan(plan[:plan_id])
    end
  end

  def test_all_agent_outputs_are_private_free
    with_standard do
      add_standard_input('binary', MARKER, name: MARKER)
      plan = approve
      run_id = claim(plan)
      plant_private_material(run_id)
      findings = SiloMigrate::Services::StandardFindingsService.new('synthetic', env: @env)
      finding_id = findings.propose(run_id: run_id, text: MARKER)[:finding_id]
      derivative = "Reviewed synthetic finding.\n"
      findings.release(finding_id: finding_id, released_text: derivative, sha256: Digest::SHA256.hexdigest(derivative), reviewer: 'engineer')
      # All supported agent commands, plus refusal of the removed run-request verb.
      [['status', 'synthetic'], ['plan-propose', 'synthetic', '--dataset', @dataset], ['plan-show', 'synthetic', plan[:plan_id]],
       ['run-request', 'synthetic', plan[:plan_id]], ['run-claim', 'synthetic', plan[:plan_id]], ['run-execute', 'synthetic', run_id], ['run-show', 'synthetic', run_id], ['findings', 'synthetic'], ['finding-show', 'synthetic', finding_id]].each do |args|
        code, out, err = cli('agent', *args)
        assert_equal(%w[run-request run-claim run-execute].include?(args.first) ? 1 : 0, code)
        assert_private_free out
        assert_private_free err
        assert_equal "Error: STANDARD_ARGUMENTS_INVALID\n", err if args.first == 'run-request'
        JSON.parse(out) unless out.empty?
      end
    end
  end

  def test_successful_agent_claim_and_execution_responses_are_private_free
    with_standard do
      add_standard_input('binary', MARKER, name: MARKER)
      plan = approve
      code, out, err = cli('agent', 'run-claim', 'synthetic', plan[:plan_id])
      assert_equal 0, code
      assert_empty err
      assert_private_free out
      claimed = JSON.parse(out)
      assert_equal 'claimed', claimed.fetch('status')
      plant_private_material(claimed.fetch('run_id'))
      code, out, err = cli('agent', 'run-execute', 'synthetic', claimed.fetch('run_id'))
      assert_equal 1, code
      assert_empty err
      assert_private_free out
      assert_equal 'failed', JSON.parse(out).fetch('status')
      assert_equal 'STANDARD_RUNTIME_MISMATCH', JSON.parse(out).fetch('failure').fetch('code')
    end
  end

  def test_unreleased_findings_are_hidden_and_release_is_exact_digest_gated
    with_standard do
      run_id = claim
      findings = SiloMigrate::Services::StandardFindingsService.new('synthetic', env: @env)
      id = findings.propose(run_id: run_id, text: "#{MARKER} #{PASSWORD} #{@root}")[:finding_id]
      assert_empty findings.released_list[:findings]
      standard_error('STANDARD_NOT_RELEASED') { findings.released_show(id) }
      code, out, err = cli('agent', 'finding-show', 'synthetic', id)
      assert_equal 1, code
      assert_empty out
      assert_includes err, 'STANDARD_NOT_RELEASED'
      released = "Reviewed derivative \u2603\n\n"
      reproduction = "Synthetic reproduction\n"
      standard_error('STANDARD_APPROVAL_MISMATCH') { findings.release(finding_id: id, released_text: released, sha256: '0' * 64, reviewer: 'engineer') }
      assert_empty findings.released_list[:findings]
      findings.release(finding_id: id, released_text: released, sha256: Digest::SHA256.hexdigest(released), reviewer: 'engineer',
        reproduction: reproduction, reproduction_sha256: Digest::SHA256.hexdigest(reproduction))
      assert_equal [id], findings.released_list[:findings].map { |entry| entry[:finding_id] }
      view = findings.released_show(id)
      assert_equal released.b, view[:summary].b
      assert_equal reproduction.b, view[:reproduction].b
      assert_private_free view
      code, out, err = cli('agent', 'finding-show', 'synthetic', id)
      assert_equal 0, code
      assert_empty err
      assert_equal released.b, JSON.parse(out).fetch('summary').b
      @service.store.write_private(@service.store.finding_dir(id, 'released', 'summary.txt'), 'tampered')
      standard_error('STANDARD_RELEASE_TAMPERED') { findings.released_show(id) }
    end
  end

  def test_schema_finding_has_no_run_and_is_released_like_any_finding
    with_standard do
      findings = SiloMigrate::Services::StandardFindingsService.new('synthetic', env: @env)
      standard_error('STANDARD_ARGUMENT_INVALID') { findings.propose(run_id: nil, text: 'x') }
      standard_error('STANDARD_ARGUMENT_INVALID') { findings.propose(run_id: claim, text: 'x', kind: 'schema') }
      id = findings.propose(run_id: nil, text: "#{MARKER} users(uid int)", kind: 'schema')[:finding_id]
      assert_empty findings.released_list[:findings]
      code, out, err = cli('finding', 'propose', 'synthetic', '--file', '/dev/null')
      assert_equal [1, ''], [code, out]
      assert_includes err, 'STANDARD_ARGUMENTS_INVALID'
      code, _out, err = cli('finding', 'propose', 'synthetic', '--kind', 'schema', '--run', 'run-' + 'a' * 32, '--file', '/dev/null')
      assert_equal 1, code
      assert_includes err, 'STANDARD_ARGUMENTS_INVALID'
      released = "users: uid int, username varchar(120); example user_1\n"
      findings.release(finding_id: id, released_text: released, sha256: Digest::SHA256.hexdigest(released), reviewer: 'engineer')
      listed = findings.released_list[:findings]
      assert_equal [[id, 'schema', nil]], listed.map { |entry| entry.values_at(:finding_id, :kind, :run_id) }
      code, out, _err = cli('agent', 'finding-show', 'synthetic', id)
      assert_equal 0, code
      assert_equal released, JSON.parse(out).fetch('summary')
      refute_includes out, MARKER
    end
  end

  def test_tampered_reproduction_refused
    with_standard do
      id = SiloMigrate::Services::StandardFindingsService.new('synthetic', env: @env).propose(run_id: claim, text: MARKER)[:finding_id]
      findings = SiloMigrate::Services::StandardFindingsService.new('synthetic', env: @env)
      findings.release(finding_id: id, released_text: 'safe', sha256: Digest::SHA256.hexdigest('safe'), reviewer: 'engineer',
        reproduction: 'repro', reproduction_sha256: Digest::SHA256.hexdigest('repro'))
      @service.store.write_private(@service.store.finding_dir(id, 'released', 'reproduction.txt'), MARKER)
      standard_error('STANDARD_RELEASE_TAMPERED') { findings.released_show(id) }
    end
  end

  def test_agent_grammar_rejects_privileged_commands_and_every_extra_argument
    with_standard do
      %w[approve reset release private-paths recover review run-request].each do |verb|
        code, out, err = cli('agent', verb, 'synthetic')
        assert_equal 1, code, verb
        assert_empty out
        assert_equal "Error: STANDARD_ARGUMENTS_INVALID\n", err
      end
      [['status', 'synthetic'], ['plan-propose', 'synthetic', '--dataset', @dataset], ['plan-show', 'synthetic', 'plan-' + 'a' * 32],
       ['run-request', 'synthetic', 'plan-' + 'a' * 32], ['run-claim', 'synthetic', 'plan-' + 'a' * 32], ['run-execute', 'synthetic', 'run-' + 'a' * 32], ['run-show', 'synthetic', 'run-' + 'a' * 32],
       ['findings', 'synthetic'], ['finding-show', 'synthetic', 'finding-' + 'a' * 32]].each do |args|
        code, out, err = cli('agent', *args, 'extra')
        assert_equal 1, code
        assert_empty out
        assert_equal "Error: STANDARD_ARGUMENTS_INVALID\n", err
      end
    end
  end
end
