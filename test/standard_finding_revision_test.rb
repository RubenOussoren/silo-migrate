# frozen_string_literal: true
require_relative 'standard_workflow_test'
require 'silo_migrate/services/standard_findings_service'
require 'silo_migrate/standard_cli'

# Proposal revisions: migration-data may replace the text of a finding that is still proposed;
# a release or a rejection names the revision the engineer read. Invented text only.
class StandardFindingRevisionTest < SiloMigrateTest
  include StandardTestWorkspace
  Findings = SiloMigrate::Services::StandardFindingsService
  MARKER = 'PRIVATE-MARKER-revision-5d1c'

  def findings
    Findings.new('synthetic', env: @env)
  end

  def sha(text)
    Digest::SHA256.hexdigest(text)
  end

  def record(id)
    @service.store.load.fetch('findings').fetch(id)
  end

  def private_file(id, name)
    @service.store.finding_dir(id, 'private', name)
  end

  def state_bytes
    File.binread(File.join(@service.store.root, 'state.json'))
  end

  def finding_files(id)
    Dir.glob('**/*', base: @service.store.finding_dir(id)).sort
  end

  # Refused: the given error, and neither the state nor the finding's files changed.
  def refused(code, id)
    before = [state_bytes, finding_files(id)]
    standard_error(code) { yield }
    assert_equal before, [state_bytes, finding_files(id)], "#{code} must change nothing"
  end

  def release(id, text, proposal)
    findings.release(finding_id: id, released_text: text, sha256: sha(text), reviewer: 'engineer', expected_proposal_sha256: proposal)
  end

  def test_revise_replaces_the_proposal_and_keeps_every_revision
    with_standard do
      run_id = claim
      proposed = findings.propose(run_id: run_id, text: "#{MARKER} first")
      id = proposed[:finding_id]
      assert_equal({ version: 1, finding_id: id, status: 'proposed', proposal_revision: 1, proposal_sha256: sha("#{MARKER} first") }, proposed)
      assert_equal({ version: 1, finding_id: id, status: 'proposed', proposal: "#{MARKER} first", proposal_revision: 1, proposal_sha256: proposed[:proposal_sha256] }, findings.proposal(id))

      second = "#{MARKER} second ☃\n"
      revised = findings.revise(finding_id: id, text: second, expected_proposal_sha256: proposed[:proposal_sha256])
      assert_equal({ version: 1, finding_id: id, status: 'proposed', proposal_revision: 2, proposal_sha256: sha(second), bytes: second.bytesize }, revised)
      refute_includes JSON.generate(revised), MARKER
      third = "#{MARKER} third"
      assert_equal 3, findings.revise(finding_id: id, text: third, expected_proposal_sha256: revised[:proposal_sha256])[:proposal_revision]

      # The finding is the same finding; only its proposal moved on.
      stored = record(id)
      assert_equal [id, 'finding', run_id, 'proposed', nil], stored.values_at('id', 'kind', 'run_id', 'status', 'release')
      assert_equal [3, sha(third)], stored.values_at('proposal_revision', 'proposal_sha256')
      assert_equal [[1, sha("#{MARKER} first"), "#{MARKER} first".bytesize], [2, sha(second), second.bytesize], [3, sha(third), third.bytesize]],
        stored['proposal_revisions'].map { |entry| entry.values_at('revision', 'sha256', 'bytes') }
      assert_equal [stored['proposed_at'], stored['proposal_revised_at']], stored['proposal_revisions'].values_at(0, 2).map { |entry| entry['at'] }
      # Every revision is still on disk, byte for byte, private.
      assert_equal %w[private private/proposal-2.txt private/proposal-3.txt private/proposal.txt], finding_files(id)
      assert_equal ["#{MARKER} first".b, second.b, third.b], %w[proposal.txt proposal-2.txt proposal-3.txt].map { |name| File.binread(private_file(id, name)) }
      %w[proposal.txt proposal-2.txt proposal-3.txt].each { |name| assert_equal 0o600, File.stat(private_file(id, name)).mode & 0o777 }
      assert_equal [third, 3, sha(third)], findings.proposal(id).values_at(:proposal, :proposal_revision, :proposal_sha256)
      assert_equal third, findings.review_text(id)
      # A revision releases nothing.
      assert_empty findings.released_list[:findings]
      standard_error('STANDARD_NOT_RELEASED') { findings.released_show(id) }
    end
  end

  def test_revise_needs_the_current_digest_of_a_finding_in_this_workspace
    with_standard do
      first = findings.propose(run_id: nil, text: 'schema one', kind: 'schema')
      id = first[:finding_id]
      current = first[:proposal_sha256]
      refused('STANDARD_PROPOSAL_CHANGED', id) { findings.revise(finding_id: id, text: 'schema two', expected_proposal_sha256: sha('something else')) }
      [nil, '', current.upcase, current[0, 63], "#{current}\n", 7].each do |bad|
        refused('STANDARD_ARGUMENT_INVALID', id) { findings.revise(finding_id: id, text: 'schema two', expected_proposal_sha256: bad) }
      end
      assert_raises(ArgumentError) { findings.revise(finding_id: id, text: 'schema two') }
      refused('STANDARD_REVISION_UNCHANGED', id) { findings.revise(finding_id: id, text: 'schema one', expected_proposal_sha256: current) }
      ['finding-' + '0' * 32, '../' + id, 'run-' + 'a' * 32].each do |unknown|
        refused('STANDARD_REFERENCE_INVALID', id) { findings.revise(finding_id: unknown, text: 'schema two', expected_proposal_sha256: current) }
        standard_error('STANDARD_REFERENCE_INVALID') { findings.proposal(unknown) }
      end
      # Another workspace's service has no such finding, whatever digest is offered.
      @named.init('elsewhere')
      SiloMigrate::StandardStore.new('elsewhere', env: @env).init!({})
      elsewhere = Findings.new('elsewhere', env: @env)
      refused('STANDARD_REFERENCE_INVALID', id) { elsewhere.revise(finding_id: id, text: 'schema two', expected_proposal_sha256: current) }
      standard_error('STANDARD_REFERENCE_INVALID') { elsewhere.proposal(id) }
      assert_equal %w[private private/proposal.txt], finding_files(id)

      # The second of two revisions made from the same reading is refused.
      revised = findings.revise(finding_id: id, text: 'schema two', expected_proposal_sha256: current)
      refused('STANDARD_PROPOSAL_CHANGED', id) { findings.revise(finding_id: id, text: 'schema three', expected_proposal_sha256: current) }
      assert_equal ['schema two', 2], findings.proposal(id).values_at(:proposal, :proposal_revision)
      assert_equal revised[:proposal_sha256], findings.proposal(id)[:proposal_sha256]
    end
  end

  def test_revised_text_is_bounded_utf8_and_revisions_are_bounded
    with_standard do
      first = findings.propose(run_id: nil, text: 'schema', kind: 'schema')
      id = first[:finding_id]
      current = first[:proposal_sha256]
      ['', nil, 42, 'x' * (Findings::MAX_BYTES + 1), "caf\xE9".b, "caf\xE9".dup.force_encoding(Encoding::UTF_8), "\xFF\xFE".b].each do |bad|
        refused('STANDARD_ARGUMENT_INVALID', id) { findings.revise(finding_id: id, text: bad, expected_proposal_sha256: current) }
      end
      # stdin arrives tagged binary: valid UTF-8 bytes are accepted and stored as they came.
      binary = "café ☃".b
      current = findings.revise(finding_id: id, text: binary, expected_proposal_sha256: current)[:proposal_sha256]
      assert_equal binary, File.binread(private_file(id, 'proposal-2.txt'))
      assert_equal ["café ☃", Encoding::UTF_8], [findings.proposal(id)[:proposal], findings.proposal(id)[:proposal].encoding]
      largest = 'y' * Findings::MAX_BYTES
      current = findings.revise(finding_id: id, text: largest, expected_proposal_sha256: current)[:proposal_sha256]
      assert_equal Findings::MAX_BYTES, findings.proposal(id)[:proposal].bytesize

      (4..Findings::MAX_REVISIONS).each do |number|
        revised = findings.revise(finding_id: id, text: "revision #{number}", expected_proposal_sha256: current)
        assert_equal number, revised[:proposal_revision]
        current = revised[:proposal_sha256]
      end
      refused('STANDARD_REVISION_LIMIT', id) { findings.revise(finding_id: id, text: 'one too many', expected_proposal_sha256: current) }
      assert_equal Findings::MAX_REVISIONS, record(id)['proposal_revisions'].size
      # The last revision can still be decided.
      assert_equal 'released', release(id, 'safe summary', current)[:status]
    end
  end

  # The same bound wherever text enters: a proposal, and the text an engineer releases or amends.
  def test_proposed_and_released_text_is_utf8_whatever_its_string_is_tagged
    with_standard do
      listed = -> { @service.store.load.fetch('findings').keys }
      none = listed.call
      ["caf\xE9".b, "caf\xE9".dup.force_encoding(Encoding::UTF_8), "#{MARKER}\xFF\xFE".b, '', 'x' * (Findings::MAX_BYTES + 1)].each do |bad|
        standard_error('STANDARD_ARGUMENT_INVALID') { findings.propose(run_id: nil, text: bad, kind: 'schema') }
      end
      assert_equal none, listed.call, 'nothing is proposed'
      assert_empty Dir.glob(File.join(@service.store.root, 'findings', '*')), 'and nothing is written'

      # stdin arrives tagged binary: valid UTF-8 bytes are still a proposal, stored as they came.
      binary = "café ☃".b
      proposed = findings.propose(run_id: nil, text: binary, kind: 'schema')
      id = proposed[:finding_id]
      assert_equal [sha(binary), binary], [proposed[:proposal_sha256], File.binread(private_file(id, 'proposal.txt'))]

      invalid = "safe \xFF\xFE".b
      refused('STANDARD_APPROVAL_MISMATCH', id) { release(id, invalid, proposed[:proposal_sha256]) }
      assert_equal 'released', release(id, "released café".b, proposed[:proposal_sha256])[:status]
      assert_equal 'released café', findings.released_show(id)[:summary]
      refused('STANDARD_APPROVAL_MISMATCH', id) { findings.amend(finding_id: id, released_text: invalid, sha256: sha(invalid), reviewer: 'engineer') }
      amended = findings.amend(finding_id: id, released_text: "amended café".b, sha256: sha("amended café".b), reviewer: 'engineer')[:finding_id]
      assert_equal 'amended café', findings.released_show(amended)[:summary]
    end
  end

  def test_a_proposal_from_before_revisions_is_revision_one
    with_standard do
      # Exactly what propose wrote before revisions existed: no revision number, no history.
      id = 'finding-' + 'a' * 32
      other = 'finding-' + 'b' * 32
      old = "#{MARKER} proposed before revisions\n"
      [id, other].each do |finding|
        @service.store.write_private(private_file(finding, 'proposal.txt'), old)
        @service.store.update do |state|
          state['findings'][finding] = { 'id' => finding, 'run_id' => nil, 'kind' => 'schema', 'status' => 'proposed', 'proposed_at' => '2026-11-01T10:00:00Z',
                                         'proposal_sha256' => sha(old), 'release' => nil }
        end
      end
      before = state_bytes
      assert_equal({ version: 1, finding_id: id, status: 'proposed', proposal: old, proposal_revision: 1, proposal_sha256: sha(old) }, findings.proposal(id))
      assert_equal before, state_bytes, 'reading migrates nothing'
      # It is released and rejected like any proposal, by its digest, as it is.
      refused('STANDARD_PROPOSAL_CHANGED', other) { release(other, 'safe', sha('not it')) }
      assert_equal 'released', release(other, 'safe', sha(old))[:status]
      refute record(other).key?('proposal_revisions')

      revised = findings.revise(finding_id: id, text: 'revised', expected_proposal_sha256: sha(old))
      assert_equal 2, revised[:proposal_revision]
      assert_equal old.b, File.binread(private_file(id, 'proposal.txt')), 'revision 1 keeps its bytes'
      assert_equal [[1, sha(old), old.bytesize, '2026-11-01T10:00:00Z'], [2, sha('revised'), 7, record(id)['proposal_revised_at']]],
        record(id)['proposal_revisions'].map { |entry| entry.values_at('revision', 'sha256', 'bytes', 'at') }
      assert_equal '2026-11-01T10:00:00Z', record(id)['proposed_at']
      assert_equal 'rejected', findings.reject(finding_id: id, reviewer: 'engineer', expected_proposal_sha256: revised[:proposal_sha256])[:status]
    end
  end

  def test_release_and_reject_name_the_proposal_the_engineer_read
    with_standard do
      first = findings.propose(run_id: claim, text: "#{MARKER} cause v1")
      id = first[:finding_id]
      viewed = first[:proposal_sha256]
      summary = "Reviewed summary.\n"
      # No digest, no decision: there is no fallback for an older caller.
      assert_raises(ArgumentError) { findings.release(finding_id: id, released_text: summary, sha256: sha(summary), reviewer: 'engineer') }
      assert_raises(ArgumentError) { findings.reject(finding_id: id, reviewer: 'engineer') }
      [nil, '', 'abc', viewed.upcase, viewed + '0'].each do |bad|
        refused('STANDARD_ARGUMENT_INVALID', id) { release(id, summary, bad) }
        refused('STANDARD_ARGUMENT_INVALID', id) { findings.reject(finding_id: id, reviewer: 'engineer', expected_proposal_sha256: bad) }
      end
      # The two digests answer different questions and are not interchangeable.
      refused('STANDARD_PROPOSAL_CHANGED', id) { release(id, summary, sha(summary)) }
      refused('STANDARD_APPROVAL_MISMATCH', id) do
        findings.release(finding_id: id, released_text: summary, sha256: viewed, reviewer: 'engineer', expected_proposal_sha256: viewed)
      end

      # migration-data revises while the engineer's page still shows revision 1.
      current = findings.revise(finding_id: id, text: "#{MARKER} cause v2", expected_proposal_sha256: viewed)[:proposal_sha256]
      refused('STANDARD_PROPOSAL_CHANGED', id) { release(id, summary, viewed) }
      refused('STANDARD_PROPOSAL_CHANGED', id) { findings.reject(finding_id: id, reviewer: 'engineer', expected_proposal_sha256: viewed) }
      assert_equal 'proposed', record(id)['status']
      assert_empty findings.released_list[:findings]
      refute File.exist?(@service.store.finding_dir(id, 'released'))

      released = release(id, summary, current)
      assert_equal({ version: 1, finding_id: id, status: 'released', sha256: sha(summary) }, released)
      assert_equal summary, findings.released_show(id)[:summary]
      assert_equal [2, current], record(id).values_at('proposal_revision', 'proposal_sha256'), 'the record keeps which revision was decided'

      rejected = findings.propose(run_id: nil, text: 'other', kind: 'schema')
      assert_equal 'rejected', findings.reject(finding_id: rejected[:finding_id], reviewer: 'engineer', expected_proposal_sha256: rejected[:proposal_sha256])[:status]
    end
  end

  def test_a_decided_finding_is_not_revised_or_decided_again
    with_standard do
      released = findings.propose(run_id: nil, text: 'schema a', kind: 'schema')
      rejected = findings.propose(run_id: nil, text: 'schema b', kind: 'schema')
      release(released[:finding_id], 'safe a', released[:proposal_sha256])
      findings.reject(finding_id: rejected[:finding_id], reviewer: 'engineer', expected_proposal_sha256: rejected[:proposal_sha256])
      amended = findings.amend(finding_id: released[:finding_id], released_text: 'safe a2', sha256: sha('safe a2'), reviewer: 'engineer')[:finding_id]
      withdrawn = findings.propose(run_id: nil, text: 'schema c', kind: 'schema')
      release(withdrawn[:finding_id], 'safe c', withdrawn[:proposal_sha256])
      findings.withdraw(finding_id: withdrawn[:finding_id], reviewer: 'engineer')

      # superseded, rejected, withdrawn: the right digest changes nothing once decided.
      [released, rejected, withdrawn].each do |decided|
        id, digest = decided.values_at(:finding_id, :proposal_sha256)
        refused('STANDARD_TRANSITION_INVALID', id) { findings.revise(finding_id: id, text: "#{MARKER} late", expected_proposal_sha256: digest) }
        refused('STANDARD_TRANSITION_INVALID', id) { release(id, 'again', digest) }
        refused('STANDARD_TRANSITION_INVALID', id) { findings.reject(finding_id: id, reviewer: 'engineer', expected_proposal_sha256: digest) }
        # The analyst can still read what it proposed and see that it was decided.
        assert_equal [record(id)['status'], 1], findings.proposal(id).values_at(:status, :proposal_revision)
      end
      # An amendment is the engineer's text: it has no proposal to read or revise.
      assert_equal 'released', record(amended)['status']
      standard_error('STANDARD_REFERENCE_INVALID') { findings.proposal(amended) }
      refused('STANDARD_TRANSITION_INVALID', amended) { findings.revise(finding_id: amended, text: 'x', expected_proposal_sha256: sha('safe a2')) }
      # Amend and withdraw stay the engineer's, on released findings only, with no proposal digest.
      pending = findings.propose(run_id: nil, text: 'schema d', kind: 'schema')[:finding_id]
      standard_error('STANDARD_TRANSITION_INVALID') { findings.amend(finding_id: pending, released_text: 'x', sha256: sha('x'), reviewer: 'engineer') }
      standard_error('STANDARD_TRANSITION_INVALID') { findings.withdraw(finding_id: pending, reviewer: 'engineer') }
      assert_equal 'withdrawn', findings.withdraw(finding_id: amended, reviewer: 'engineer')[:status]
    end
  end

  def test_proposal_bytes_on_disk_must_be_the_recorded_revision
    with_standard do
      first = findings.propose(run_id: nil, text: 'schema v1', kind: 'schema')
      id = first[:finding_id]
      current = findings.revise(finding_id: id, text: 'schema v2', expected_proposal_sha256: first[:proposal_sha256])[:proposal_sha256]
      tampered = lambda do
        standard_error('STANDARD_PROPOSAL_TAMPERED') { findings.proposal(id) }
        refused('STANDARD_PROPOSAL_TAMPERED', id) { findings.revise(finding_id: id, text: 'schema v3', expected_proposal_sha256: current) }
        refused('STANDARD_PROPOSAL_TAMPERED', id) { release(id, 'safe', current) }
        refused('STANDARD_PROPOSAL_TAMPERED', id) { findings.reject(finding_id: id, reviewer: 'engineer', expected_proposal_sha256: current) }
      end
      # Changed bytes.
      @service.store.write_private(private_file(id, 'proposal-2.txt'), "#{MARKER} swapped")
      tampered.call
      # The digest of the swapped bytes is not the recorded proposal either.
      refused('STANDARD_PROPOSAL_CHANGED', id) { release(id, 'safe', sha("#{MARKER} swapped")) }
      # Missing, then a link to the right bytes elsewhere.
      File.delete(private_file(id, 'proposal-2.txt'))
      tampered.call
      outside = write(File.join(@root, 'outside.txt'), 'schema v2')
      File.symlink(outside, private_file(id, 'proposal-2.txt'))
      tampered.call
      File.delete(private_file(id, 'proposal-2.txt'))
      @service.store.write_private(private_file(id, 'proposal-2.txt'), 'schema v2')
      assert_equal 'schema v2', findings.proposal(id)[:proposal]

      # A record pointed back at an older revision's file does not pass for the current one.
      @service.store.update { |state| state['findings'][id]['proposal_revision'] = 1 }
      tampered.call
      # Nor does a revision number without its history, or one out of range.
      @service.store.update { |state| state['findings'][id].merge!('proposal_revision' => 2, 'proposal_revisions' => nil) }
      refused('STANDARD_PROPOSAL_TAMPERED', id) { findings.revise(finding_id: id, text: 'schema v3', expected_proposal_sha256: current) }
      [0, 'two', Findings::MAX_REVISIONS + 1].each do |number|
        @service.store.update { |state| state['findings'][id]['proposal_revision'] = number }
        tampered.call
      end
      assert_empty findings.released_list[:findings]
    end
  end

  def test_an_unfinished_revision_file_is_not_a_revision
    with_standard do
      first = findings.propose(run_id: nil, text: 'schema v1', kind: 'schema')
      id = first[:finding_id]
      # A revision file written just before a state write that failed: nothing refers to it.
      @service.store.write_private(private_file(id, 'proposal-2.txt'), "#{MARKER} never recorded")
      assert_equal ['schema v1', 1], findings.proposal(id).values_at(:proposal, :proposal_revision)
      revised = findings.revise(finding_id: id, text: 'schema v2', expected_proposal_sha256: first[:proposal_sha256])
      assert_equal 'schema v2', File.binread(private_file(id, 'proposal-2.txt'))
      assert_equal ['schema v2', 2, revised[:proposal_sha256]], findings.proposal(id).values_at(:proposal, :proposal_revision, :proposal_sha256)
    end
  end

  def test_concurrent_revisions_and_decisions_have_one_winner
    with_standard do
      # Each caller read the same proposal; the store lock lets exactly one act on it.
      outcome = lambda do |&action|
        action.call
        :done
      rescue SiloMigrate::StandardWorkflowError => error
        error.code
      end
      first = findings.propose(run_id: nil, text: 'schema v1', kind: 'schema')
      id = first[:finding_id]
      results = Array.new(6) do |index|
        Thread.new { outcome.call { findings.revise(finding_id: id, text: "schema from #{index}", expected_proposal_sha256: first[:proposal_sha256]) } }
      end.map(&:value)
      assert_equal [1, 5], [results.count(:done), results.count('STANDARD_PROPOSAL_CHANGED')], results.inspect
      assert_equal [2, 2], [record(id)['proposal_revision'], record(id)['proposal_revisions'].size]
      assert_equal record(id)['proposal_sha256'], sha(findings.proposal(id)[:proposal])

      8.times do |round|
        proposed = findings.propose(run_id: nil, text: "schema round #{round}", kind: 'schema')
        finding, digest = proposed.values_at(:finding_id, :proposal_sha256)
        actions = [
          -> { findings.revise(finding_id: finding, text: "#{MARKER} revised #{round}", expected_proposal_sha256: digest) },
          -> { release(finding, "safe #{round}", digest) },
          -> { findings.reject(finding_id: finding, reviewer: 'engineer', expected_proposal_sha256: digest) }
        ].rotate(round)
        results = actions.map { |action| Thread.new { outcome.call(&action) } }.map(&:value)
        assert_equal 1, results.count(:done), results.inspect
        assert_empty results - [:done, 'STANDARD_PROPOSAL_CHANGED', 'STANDARD_TRANSITION_INVALID'], results.inspect
        stored = record(finding)
        case stored['status']
        when 'released'
          # Released on the revision that was read: the revision that lost left no trace.
          assert_equal [1, digest], stored.values_at('proposal_revision', 'proposal_sha256')
          assert_equal "safe #{round}", findings.released_show(finding)[:summary]
        when 'rejected' then assert_equal [1, digest], stored.values_at('proposal_revision', 'proposal_sha256')
        else
          assert_equal ['proposed', 2], stored.values_at('status', 'proposal_revision')
          refute File.exist?(@service.store.finding_dir(finding, 'released'))
        end
      end
    end
  end

  def test_private_revisions_never_reach_coding_views_errors_or_output
    with_standard do
      cli = lambda do |*args|
        out = StringIO.new
        err = StringIO.new
        command = SiloMigrate::StandardCLI.new(env: @env, runtime: @runtime, code_root: @code_root, output: out, error: err)
        [command.stub(:service, new_standard) { command.run(args) }, out.string, err.string]
      end
      first = findings.propose(run_id: claim, text: "#{MARKER} v1")
      id = first[:finding_id]
      current = findings.revise(finding_id: id, text: "#{MARKER} v2", expected_proposal_sha256: first[:proposal_sha256])[:proposal_sha256]
      pending = findings.propose(run_id: nil, text: "#{MARKER} schema", kind: 'schema')
      findings.revise(finding_id: pending[:finding_id], text: "#{MARKER} schema v2", expected_proposal_sha256: pending[:proposal_sha256])

      # Every refusal is a bare code: no text, digest or path.
      errors = [
        standard_error('STANDARD_PROPOSAL_CHANGED') { findings.revise(finding_id: id, text: "#{MARKER} v3", expected_proposal_sha256: first[:proposal_sha256]) },
        standard_error('STANDARD_PROPOSAL_CHANGED') { release(id, 'safe', first[:proposal_sha256]) },
        standard_error('STANDARD_REVISION_UNCHANGED') { findings.revise(finding_id: id, text: "#{MARKER} v2", expected_proposal_sha256: current) },
        standard_error('STANDARD_ARGUMENT_INVALID') { findings.revise(finding_id: id, text: "#{MARKER}\xFF".b, expected_proposal_sha256: current) }
      ]
      errors.each { |error| assert_equal error.code, error.message }

      release(id, 'Reviewed: invented example user_1.', current)
      coding = [findings.released_list, findings.released_show(id)]
      %w[findings finding-show].each do |command|
        code, out, err = cli.call('agent', *[command, 'synthetic', (id if command == 'finding-show')].compact)
        assert_equal [0, ''], [code, err]
        coding << out
      end
      # The coding surface has no route to a proposal, a revision or a revise.
      [%w[proposal], %w[finding-proposal], %w[revise], %w[finding-revise], %w[finding proposal]].each do |route|
        code, out, err = cli.call('agent', *route, 'synthetic', pending[:finding_id])
        assert_equal [1, ''], [code, out]
        coding << err
      end
      code, out, err = cli.call('agent', 'finding-show', 'synthetic', pending[:finding_id])
      assert_equal [1, '', "Error: STANDARD_NOT_RELEASED\n"], [code, out, err]
      text = coding.map { |value| value.is_a?(String) ? value : JSON.generate(value) }.join("\n")
      [MARKER, 'proposal', first[:proposal_sha256], current, pending[:proposal_sha256], record(pending[:finding_id])['proposal_sha256']].each do |private_text|
        refute_includes text, private_text
      end
      assert_equal [id], findings.released_list[:findings].map { |entry| entry[:finding_id] }
    end
  end
end
