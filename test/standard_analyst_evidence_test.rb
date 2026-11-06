# frozen_string_literal: true
require_relative 'standard_workflow_test'
require 'silo_migrate/services/standard_findings_service'
require 'silo_migrate/standard_cli'
require 'tempfile'

# The trusted analyst's evidence view: structured state first, every log listed,
# bounded tails in priority order, and a serialized size that fits the tool limit.
class StandardAnalystEvidenceTest < SiloMigrateTest
  include StandardTestWorkspace
  Findings = SiloMigrate::Services::StandardFindingsService

  def findings
    Findings.new('synthetic', env: @env)
  end

  def write_log(run_id, name, text, mtime: nil)
    path = @service.store.run_dir(run_id, 'logs', "#{name}.log")
    @service.store.write_private(path, text)
    File.utime(mtime, mtime, path) if mtime
    path
  end

  # Content that expands under JSON encoding: quotes, backslashes, control
  # characters and multibyte text.
  def noisy(lines, tag)
    (1..lines).map { |n| "#{tag} line #{n} \"quoted\" back\\slash \t tab \u0001 ctl café ☃\n" }.join
  end

  def fail_at(run_id, stage, code: 'STANDARD_CONVERSION_FAILED', detail: 'conversion-db-bootstrap')
    @service.store.update do |state|
      run = state['runs'].fetch(run_id)
      run['status'] = 'failed'
      run['stage'] = stage
      run['stages'].fetch('preflight').merge!('status' => 'passed', 'started_at' => '2026-01-01T00:00:00Z', 'finished_at' => '2026-01-01T00:00:01Z')
      run['stages'].fetch(stage).merge!('status' => 'failed', 'started_at' => '2026-01-01T00:00:02Z', 'finished_at' => '2026-01-01T00:00:09Z')
      run['failure'] = { 'stage' => stage, 'code' => code, 'recovery' => 'synthetic recovery' }
      run['assertions']['site'] = { 'result' => 'failed', 'failed' => 2 }
      run['results']['input_count'] = 3
    end
    @service.store.write_private(@service.store.run_dir(run_id, 'private', 'failure.json'), JSON.generate('stage' => stage, 'code' => code, 'detail' => detail))
  end

  def test_structured_state_precedes_index_and_tails
    with_standard do
      run_id = claim
      fail_at(run_id, 'convert')
      write_log(run_id, 'convert', "exit=1\nconverter said no\n")
      evidence = findings.private_evidence(run_id)
      keys = evidence.keys
      %i[stages assertions results failure failure_detail].each { |key| assert_operator keys.index(key), :<, keys.index(:logs), key }
      assert_operator keys.index(:logs), :<, keys.index(:tails)
      assert_equal 'convert', evidence[:failed_stage]
      assert_equal 'failed', evidence[:stages]['convert']['status']
      assert_equal({ 'result' => 'failed', 'failed' => 2 }, evidence[:assertions]['site'])
      assert_equal 3, evidence[:results]['input_count']
      assert_equal 'conversion-db-bootstrap', evidence[:failure_detail]['detail']
      assert_equal 'may_propose', evidence[:finding]
      assert_equal "exit=1\nconverter said no\n", evidence[:tails]['logs/convert.log']
    end
  end

  def test_every_log_listed_with_size_and_failed_stage_logs_first_latest_first
    with_standard do
      run_id = claim
      fail_at(run_id, 'convert')
      base = Time.utc(2026, 1, 1, 0, 0, 5)
      write_log(run_id, 'backup-baseline', noisy(400, 'baseline'), mtime: base - 4)
      write_log(run_id, 'conversion-db-start', noisy(10, 'start'), mtime: base - 2)
      write_log(run_id, 'conversion-db-bootstrap', noisy(20, 'bootstrap'), mtime: base)
      write_log(run_id, 'mystery', noisy(5, 'mystery'), mtime: Time.utc(2026, 1, 1, 0, 0, 2))
      @service.store.write_private(@service.store.run_dir(run_id, 'evidence', 'site.failures.json'), JSON.generate(%w[a b]))
      evidence = findings.private_evidence(run_id)
      logs = evidence[:logs].to_h { |entry| [entry[:name], entry] }
      assert_equal %w[backup-baseline.log conversion-db-bootstrap.log conversion-db-start.log mystery.log], logs.keys
      logs.each { |name, entry| assert_equal File.size(@service.store.run_dir(run_id, 'logs', name)), entry[:bytes], name }
      assert_equal 'baseline', logs['backup-baseline.log'][:stage]
      assert_equal 'convert', logs['conversion-db-bootstrap.log'][:stage]
      assert_equal 'convert', logs['mystery.log'][:stage], 'unknown names fall back to the stage running at write time'
      assert_equal ['evidence/site.failures.json', 'logs/conversion-db-bootstrap.log', 'logs/conversion-db-start.log', 'logs/mystery.log'],
        evidence[:tails].keys.first(4)
      assert_equal [{ name: 'site.failures.json', bytes: 9, tail_bytes: 9 }], evidence[:evidence_files]
      fail_at(run_id, 'convert', detail: 'conversion-db-start')
      assert_equal 'logs/conversion-db-start.log', findings.private_evidence(run_id)[:tails].keys[1], 'the step named by the failure comes first'
    end
  end

  def test_document_fits_budget_with_large_escaped_logs_and_lists_omissions
    with_standard do
      run_id = claim
      fail_at(run_id, 'import', code: 'STANDARD_IMPORT_FAILED', detail: 'x' * 20_000)
      %w[import backup-baseline conversion-db-load convert uploads final-restore].each_with_index do |name, index|
        write_log(run_id, name, noisy(3000, name), mtime: Time.utc(2026, 1, 1, 0, 0, index))
      end
      [Findings::EVIDENCE_OUTPUT_BYTES, 12 * 1024, 6 * 1024].each do |budget|
        evidence = findings.private_evidence(run_id, budget: budget)
        assert_operator JSON.generate(evidence).bytesize, :<=, budget, budget
        assert_equal 6, evidence[:logs].size
        assert_equal 'logs/import.log', evidence[:tails].keys.first if budget >= 12 * 1024
        listed = evidence[:tails].keys + evidence[:omitted]
        assert_equal evidence[:logs].map { |entry| "logs/#{entry[:name]}" }.sort, listed.sort, budget
        evidence[:logs].each do |entry|
          tail = evidence[:tails]["logs/#{entry[:name]}"]
          assert_equal tail ? tail.bytesize : 0, entry[:tail_bytes]
          next unless tail

          assert_operator tail.bytesize, :<=, Findings::EVIDENCE_TAIL_BYTES
          assert_match(/\A#{Regexp.escape(entry[:name].delete_suffix('.log'))} line \d+ /, tail, 'tails start at a whole line')
          assert tail.end_with?("☃\n")
        end
        assert evidence[:failure_detail].key?('tail'), 'an oversized failure record is bounded'
      end
      refute_empty findings.private_evidence(run_id)[:omitted], 'six large logs cannot all fit'
    end
  end

  def test_cli_output_fits_the_adapter_limit
    with_standard do
      run_id = claim
      fail_at(run_id, 'convert')
      12.times { |index| write_log(run_id, "conversion-step-#{index}", noisy(2000, 'step')) }
      out = StringIO.new
      err = StringIO.new
      code = SiloMigrate::StandardCLI.new(env: @env, output: out, error: err).run(['analyst', 'evidence', 'synthetic', run_id])
      assert_equal 0, code, err.string
      assert_operator out.string.bytesize, :<=, Findings::EVIDENCE_OUTPUT_BYTES + 1
      assert_equal 12, JSON.parse(out.string).fetch('logs').size
    end
  end

  def test_completed_run_gets_no_finding
    with_standard do
      run_id = claim
      @service.store.update { |state| state['runs'].fetch(run_id)['status'] = 'completed' }
      assert_match(/\Anot_applicable/, findings.private_evidence(run_id)[:finding])
      standard_error('STANDARD_RUN_COMPLETED') { findings.propose(run_id: run_id, text: 'synthetic finding') }
      assert_empty @service.store.load['findings']
      out = StringIO.new
      err = StringIO.new
      input = Tempfile.create('finding') { |file| file.write('synthetic'); file.flush
        SiloMigrate::StandardCLI.new(env: @env, output: out, error: err).run(['finding', 'propose', 'synthetic', '--run', run_id, '--file', file.path]) }
      assert_equal 1, input
      assert_equal "Error: STANDARD_RUN_COMPLETED\n", err.string
    end
  end

  def test_symlinked_log_is_not_followed
    with_standard do
      run_id = claim
      outside = File.join(@root, 'outside-secret.txt')
      File.write(outside, 'OUTSIDE-SECRET')
      logs = @service.store.run_dir(run_id, 'logs')
      FileUtils.mkdir_p(logs)
      File.symlink(outside, File.join(logs, 'convert.log'))
      evidence = findings.private_evidence(run_id)
      refute_includes JSON.generate(evidence), 'OUTSIDE-SECRET'
    end
  end
end
