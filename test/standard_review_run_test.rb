# frozen_string_literal: true
require_relative 'standard_convert_run_test'

# Scripted Docker for review runs: answers the prebuilt stack, its PostgreSQL and the
# importer on top of the convert fixture. No subprocess, Docker socket or network.
class ReviewScriptedRuntime < ConvertScriptedRuntime
  attr_accessor :import_output, :settings_rows, :destination_counts, :import_exit_failure, :role_failure

  def review_ok(stdout = '')
    SiloMigrate::Runtime::CommandResult.new(success?: true, stdout: stdout, stderr: '', status: 0)
  end

  def review_fail(stderr)
    SiloMigrate::Runtime::CommandResult.new(success?: false, stdout: '', stderr: stderr, status: 1)
  end

  def site_json(values)
    review_ok("noise\nSILO_JSON:#{JSON.generate(values)}\n")
  end

  def run(cmd, **options)
    line = cmd.join(' ')
    return super unless line.include?('-review')

    @calls << cmd
    @stdins << options[:stdin_data] if options[:stdin_data]
    app = service.lock.fetch('app')
    if cmd[0, 2] == %w[docker run]
      review_ok(Digest::SHA256.hexdigest(line) + "\n")
    elsif %w[network volume container].include?(cmd[1]) && cmd[2] == 'inspect' && !cmd.include?('--format')
      review_fail('Error: No such object')
    elsif cmd[1, 2] == %w[network create] || cmd[1, 2] == %w[volume create] || cmd[1, 2] == %w[network connect] || cmd[1] == 'cp'
      review_ok
    elsif line.include?('pg_isready')
      review_ok
    elsif line.include?('curl')
      review_ok('200')
    elsif line.include?('ruby -e')
      review_ok("#{app['ruby']}\n#{app['bundler']}\n#{app['gemfile_lock_sha256']}  Gemfile.lock\n{\"#{app['revision']}\":1}\n")
    elsif line.include?('site_fingerprint.rb')
      site_json('versions' => { 'discourse' => app['version'], 'git' => app['revision'], 'ruby' => app['ruby'] },
                'runtime' => { 'store_local' => true, 's3' => false, 'disable_emails' => 'yes', 'extensions' => app['required_extensions'],
                               'pg_version' => "#{app['postgres_major']}.1", 'redis_version' => "#{app['redis_major']}.0.1", 'allow_restore' => false })
    elsif line.include?('review_setup.rb')
      port = cmd.find { |arg| arg.start_with?('SILO_SITE_PORT=') }.to_s.split('=', 2).last
      site_json('admin_username' => 'silo_review_admin', 'disable_emails' => 'yes', 'login_required' => true, 'allow_restore' => false,
                'base_url' => "http://127.0.0.1:#{port}")
    elsif line.include?('generic_bulk.rb')
      import_exit_failure ? review_fail('importer crashed') : review_ok(import_output || "Starting...\nImporting users...\nDone! (1 minutes)\nNow run the 'import:ensure_consistency' rake task.\n")
    elsif line.include?('import:ensure_consistency') || line.include?('bundle check') || line.include?('mkdir -p /shared/import') || cmd.include?('chown')
      review_ok
    elsif cmd.include?('printenv')
      review_ok("yes\n")
    elsif line.include?('FROM site_settings')
      review_ok(settings_rows || "allow_restore=f\nlogin_required=t\n")
    elsif cmd.include?('postgres') && cmd.include?('psql')
      role_failure ? review_fail('ERROR:  permission denied') : review_ok
    elsif cmd.include?('silo_count') && cmd.include?('psql')
      script = options[:stdin_data].to_s
      key = (destination_counts || {}).keys.find { |text| script.include?(text) }
      key ? review_ok("#{destination_counts[key]}\n") : review_fail(%(ERROR:  42P01\n))
    elsif cmd.include?('{{json .Config.Labels}}') || cmd.include?('{{json .Labels}}') || line.include?('{{.State.Running}}') || cmd.include?('rm') || cmd[1, 2] == %w[network rm] || cmd[1, 2] == %w[volume rm]
      super_run(cmd, **options)
    else
      review_ok
    end
  end

  def super_run(cmd, **options)
    StandardScriptedRuntime.instance_method(:run).bind_call(self, cmd, **options)
  end
end

class StandardReviewRunTest < StandardConvertRunTest
  REVIEW_SPEC = JSON.generate('version' => 1, 'checks' => [
    { 'name' => 'users', 'source_sql' => 'SELECT COUNT(*) FROM src_users', 'intermediate_sql' => 'SELECT COUNT(*) FROM users',
      'destination_sql' => "SELECT COUNT(*) FROM user_custom_fields WHERE name = 'import_id'" },
    { 'name' => 'posts', 'source_sql' => 'SELECT COUNT(*) FROM src_posts WHERE visible = 1', 'intermediate_sql' => 'SELECT COUNT(*) FROM posts', 'expect' => 'equal',
      'destination_sql' => "SELECT COUNT(*) FROM post_custom_fields WHERE name = 'import_id'", 'note' => 'drafts excluded by decision' },
    { 'name' => 'renamed', 'source_sql' => 'SELECT COUNT(*) FROM src_users WHERE 1 = 1', 'intermediate_sql' => 'SELECT COUNT(*) FROM users' }
  ])

  # Runs every StandardConvertRunTest test only once (in that class).
  def self.runnable_methods
    super.select { |name| name.start_with?('test_review') }
  end

  def with_review(&block)
    with_convert do
      runtime = ReviewScriptedRuntime.new
      runtime.service = @service
      runtime.ownership = nil
      @runtime = runtime
      @service.instance_variable_set(:@runtime, runtime)
      @http_calls = []
      @http_answers = { '/srv/status' => { status: 200, body: 'ok' }, '/latest.json' => { status: 403, body: '{"errors":["login required"]}' } }
      @service.instance_variable_set(:@http, lambda do |url, _limit|
        @http_calls << url
        @http_answers.fetch(URI(url).path)
      end)
      @convert = run_convert
      assert_equal 'completed', @convert[:status], @convert.inspect
      block.call
    end
  end

  def instance_name(plan)
    plan.dig(:instances, 'review', 'name')
  end

  def propose_review(**options)
    @service.propose_review_plan(from_run: @convert[:run_id], **options)
  end

  def run_review(plan = propose_review)
    @runtime.ownership = instance_name(plan)
    @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'synthetic engineer')
    @service.run_plan(plan_id: plan[:plan_id])
  end

  def artifact
    @service.store.run_dir(@convert[:run_id], 'artifacts', 'intermediate.sqlite')
  end

  def private_rows(run_id)
    JSON.parse(File.read(@service.store.run_dir(run_id, 'evidence', 'reconciliation.json'))).fetch('checks').to_h { |row| [row['name'], row] }
  end

  def test_review_plan_binds_the_completed_convert_run
    with_review do
      plan = propose_review
      assert_equal 'standard_review', plan[:operation]
      assert_equal 'mybb', plan[:platform]
      recorded = @service.store.load.dig('runs', @convert[:run_id], 'artifacts', 'intermediate')
      assert_equal({ 'run_id' => @convert[:run_id], 'plan_id' => @convert[:plan_id], 'converter_revision' => 'a' * 40,
                     'intermediate_sha256' => recorded['sha256'], 'intermediate_bytes' => recorded['bytes'] }, plan[:from_run])
      assert_equal({ 'reconciliation' => @ids['reconciliation'] }, plan[:roles])
      assert_equal 18_080, plan.dig(:instances, 'review', 'port')
      assert_equal '127.0.0.1', plan.dig(:instances, 'review', 'hostname')
      base = @service.lock.dig('limits', 'stack')
      %w[web db redis proxy].each do |role|
        assert_operator plan.dig(:limits, role, 'memory_mib'), :>=, base.dig(role, 'memory_mib')
        assert_operator plan.dig(:limits, role, 'cpus'), :>=, base.dig(role, 'cpus')
      end
      assert_equal 6144, plan.dig(:limits, 'web', 'memory_mib') # 64 GiB host: capped
      assert_includes plan[:not_included], 'uploads and avatars'
      # Running sites don't block a proposal, only the start (they can be reset first).
      @runtime.high_usage = true
      @service.define_singleton_method(:measured_usage) { [1.0, 60 * 1024] }
      second = propose_review
      @service.approve_plan(plan_id: second[:plan_id], sha256: second[:digest], reviewer: 'synthetic engineer')
      standard_error('STANDARD_CAPACITY') { @service.claim(plan_id: second[:plan_id]) }
      @service.singleton_class.send(:remove_method, :measured_usage)
      @runtime.high_usage = false
      # A later proposal doesn't reuse a port reserved by an earlier one.
      assert_equal 18_082, propose_review.dig(:instances, 'review', 'port')
      @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'synthetic engineer')
      run_id = @service.claim(plan_id: plan[:plan_id]).fetch(:run_id)
      assert_equal %w[preflight site_up site_setup import verify review_url], @service.store.load.dig('runs', run_id, 'stages').keys
    end
  end

  def test_review_plan_refusals
    with_review do
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.propose_review_plan(from_run: 'run-x') }
      standard_error('STANDARD_REVIEW_SOURCE_INVALID') { @service.propose_review_plan(from_run: "run-#{'0' * 32}") }
      standard_error('STANDARD_REFERENCE_INVALID') { propose_review(reconciliation: 'input-missing') }
      standard_error('STANDARD_INPUTS_INCOMPLETE') { propose_review(reconciliation: @ids['settings']) }
      standard_error('STANDARD_ARGUMENT_INVALID') { propose_review(port: 80) }
      bad = add_input('derived/bad-checks.json', JSON.generate('version' => 1, 'checks' => [
        { 'name' => 'users', 'source_sql' => 'SELECT COUNT(*) FROM src_users', 'intermediate_sql' => 'SELECT COUNT(*) FROM users',
          'destination_sql' => "SELECT COUNT(*) FROM users WHERE pg_read_file('/etc/passwd') <> ''" }
      ]), 'reconciliation')
      standard_error('STANDARD_RECONCILIATION_INVALID') { propose_review(reconciliation: bad) }
      ["SELECT COUNT(*) FROM users WHERE U&\"!0070g_sleep\" UESCAPE '!'(1) IS NULL", 'SELECT COUNT(*) FROM users; SELECT 1',
       "SELECT set_config('x', 'y', false)", 'SELECT COUNT(*) FROM users FOR UPDATE', 'COPY users TO STDOUT'].each do |sql|
        refute @service.send(:count_sql?, sql, destination: true), sql
      end
      assert @service.send(:count_sql?, "SELECT COUNT(*) FROM user_emails e WHERE e.\"primary\" AND e.email ~ '^[0-9a-f]{32}@email[.]invalid$'", destination: true)
      File.chmod(0o600, artifact)
      File.open(artifact, 'ab') { |file| file.write('x') }
      standard_error('STANDARD_REVIEW_SOURCE_INVALID') { propose_review }
    end
  end

  def test_review_source_must_be_a_completed_convert_run
    with_review do
      @runtime.convert_failure = true
      failed = run_convert
      assert_equal 'failed', failed[:status]
      standard_error('STANDARD_REVIEW_SOURCE_INVALID') { @service.propose_review_plan(from_run: failed[:run_id]) }
    end
  end

  def test_review_plan_goes_stale_when_the_artifact_changes
    with_review do
      plan = propose_review
      File.chmod(0o600, artifact)
      bytes = File.binread(artifact)
      File.binwrite(artifact, bytes.reverse) # same size, different content and mtime
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      error = standard_error('STANDARD_STALE_PLAN') { @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'synthetic engineer') }
      assert_includes error.message, 'from_run'
    end
  end

  def test_review_run_imports_counts_three_columns_and_keeps_numbers_private
    with_review do
      checks = add_input('derived/review-checks.json', REVIEW_SPEC, 'reconciliation')
      @runtime.destination_counts = { 'user_custom_fields' => 3, 'post_custom_fields' => 4 }
      plan = propose_review(reconciliation: checks)
      result = run_review(plan)
      assert_equal 'completed', result[:status], result.inspect
      assert_equal %w[passed] * 6, result[:stages].values
      run_id = result[:run_id]

      rows = private_rows(run_id)
      assert_equal({ 'source' => 3, 'intermediate' => 3, 'destination' => 3, 'difference' => 0, 'destination_difference' => 0, 'status' => 'matched' },
                   rows['users'].slice('source', 'intermediate', 'destination', 'difference', 'destination_difference', 'status'))
      assert_equal({ 'source' => 5, 'intermediate' => 4, 'destination' => 4, 'status' => 'differs' }, rows['posts'].slice('source', 'intermediate', 'destination', 'status'))
      assert_equal 'error', rows['renamed']['status']
      assert_includes rows['renamed']['error'], 'not measured by the convert run'

      public = @service.show_run(run_id)
      assert_equal({ 'reconciliation_checks' => 3, 'reconciliation_matched' => 1, 'reconciliation_differs' => 1, 'reconciliation_errors' => 1,
                     'review_url' => 'http://127.0.0.1:18080', 'import_issues' => 0 }, public[:results])
      refute_match(/user_custom_fields|"destination"/, JSON.generate(@service.status))

      # The importer runs once, without an uploads database, then the consistency pass.
      imports = @runtime.calls.select { |cmd| cmd.join(' ').include?('generic_bulk.rb') }
      assert_equal 1, imports.size
      assert imports.first.last.end_with?('generic_bulk.rb /shared/import/intermediate.sqlite')
      assert @runtime.calls.any? { |cmd| cmd.join(' ').include?('import:ensure_consistency') }
      # Destination counts: SELECT-only role created first, each count read-only and timed.
      role = @runtime.calls.index { |cmd| cmd.include?('postgres') && cmd.include?('psql') }
      counts = @runtime.calls.each_index.select { |index| @runtime.calls[index].include?('silo_count') }
      assert_equal 2, counts.size
      assert_operator role, :<, counts.first
      role_sql = @runtime.stdins.find { |text| text.include?('CREATE ROLE silo_count') }
      assert_includes role_sql, 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO silo_count'
      assert_includes role_sql, 'default_transaction_read_only = on'
      assert_includes role_sql, "EXECUTE format('REVOKE ALL ON %I FROM silo_count', target)"
      count_sql = @runtime.stdins.find { |text| text.include?('user_custom_fields') }
      assert_match(/\ABEGIN TRANSACTION READ ONLY;\nSET LOCAL statement_timeout = '1800s';\nSELECT \(SELECT COUNT\(\*\) FROM user_custom_fields WHERE name = 'import_id'\);\nROLLBACK;\n\z/, count_sql)

      # Site sized by the plan, published on loopback, set up before the import.
      web = @runtime.calls.find { |cmd| cmd[0, 2] == %w[docker run] && cmd.include?("#{instance_name(plan)}-web") }
      assert_equal plan.dig(:limits, 'web', 'memory_mib').to_s + 'm', web[web.index('--memory') + 1]
      proxy = @runtime.calls.find { |cmd| cmd[0, 2] == %w[docker run] && cmd.include?("#{instance_name(plan)}-proxy") }
      assert_includes proxy, '127.0.0.1:18080:8080'
      setup = @runtime.calls.index { |cmd| cmd.join(' ').include?('review_setup.rb') }
      assert_operator setup, :<, @runtime.calls.index(imports.first)
      refute @runtime.calls.any? { |cmd| cmd.join(' ').include?('runner /tmp/set_review_port.rb') } # no remap of imported content
      assert_equal %w[http://127.0.0.1:18080/srv/status http://127.0.0.1:18080/latest.json], @http_calls
      assert_equal 'review', @service.store.load.dig('instances', instance_name(plan), 'state')

      # The admin's sign-in: engineer path only; the setup secrets file is gone.
      sign_in = @service.admin_password(run_id)
      assert_equal 'silo_review_admin', sign_in[:username]
      assert_equal File.read(@service.store.run_dir(run_id, 'private', 'admin-password')), sign_in[:password]
      assert_equal 'http://127.0.0.1:18080', sign_in[:review_url]
      refute File.exist?(@service.store.run_dir(run_id, 'private', 'review-setup.env'))
      refute_includes JSON.generate(@service.status), sign_in[:password]
      refute_includes JSON.generate(public), sign_in[:password]
      standard_error('STANDARD_TRANSITION_INVALID') { @service.admin_password(@convert[:run_id]) }

      # Reset removes the site and the sign-in.
      @service.reset_run(run_id: run_id, yes: true)
      assert_equal 'removed', @service.store.load.dig('instances', instance_name(plan), 'state')
      refute File.exist?(@service.store.run_dir(run_id, 'private', 'admin-password'))
      refute File.exist?(@service.store.run_dir(run_id, 'private', 'review-setup.env'))
      standard_error('STANDARD_TRANSITION_INVALID') { @service.admin_password(run_id) }
    end
  end

  def test_review_import_issues_are_counted_not_fatal
    with_review do
      @runtime.import_output = "Starting...\n\nImport issues (details in /tmp/generic_bulk_import_issues_20261108_101500.log):\n" \
                               "  post skipped (raw contains null bytes): 2\n  invalid email update skipped: 1\nDone! (3 minutes)\n"
      result = run_review
      assert_equal 'completed', result[:status], result.inspect
      assert_equal 3, result[:results]['import_issues']
      counts = @service.store.load.dig('runs', result[:run_id], 'results', 'import_issue_counts')
      assert_equal({ 'post skipped (raw contains null bytes)' => 2, 'invalid email update skipped' => 1 }, counts)
      refute public_keys(result).include?('import_issue_counts')
      assert @runtime.calls.any? { |cmd| cmd[1] == 'cp' && cmd[2].to_s.end_with?(':/tmp/generic_bulk_import_issues_20261108_101500.log') }
    end
  end

  def public_keys(result)
    result[:results].keys
  end

  def test_review_import_without_completion_or_with_unsafe_settings_fails
    with_review do
      @runtime.import_output = "Starting...\nImporting users...\n"
      result = run_review
      assert_equal 'failed', result[:status]
      assert_equal({ 'stage' => 'import', 'code' => 'STANDARD_IMPORT_FAILED' }, result[:failure].slice('stage', 'code'))
      assert_equal 'dirty', @service.store.load.dig('instances', instance_name(@service.show_plan(result[:plan_id])), 'state')
      @service.reset_run(run_id: result[:run_id], yes: true)

      @runtime.import_output = nil
      @runtime.settings_rows = "disable_emails=no\nlogin_required=t\n"
      result = run_review
      assert_equal({ 'stage' => 'verify', 'code' => 'STANDARD_VERIFY_FAILED' }, result[:failure].slice('stage', 'code'))
      @service.reset_run(run_id: result[:run_id], yes: true)

      @runtime.settings_rows = nil
      @http_answers['/latest.json'] = { status: 200, body: '{"topic_list":{"topics":[]}}' }
      result = run_review
      assert_equal({ 'stage' => 'review_url', 'code' => 'STANDARD_VERIFY_FAILED' }, result[:failure].slice('stage', 'code'))
    end
  end

  def test_review_destination_errors_are_per_check
    with_review do
      checks = add_input('derived/review-checks.json', REVIEW_SPEC, 'reconciliation')
      @runtime.destination_counts = { 'user_custom_fields' => 3 }
      result = run_review(propose_review(reconciliation: checks))
      assert_equal 'completed', result[:status]
      rows = private_rows(result[:run_id])
      assert_equal 'matched', rows['users']['status']
      assert_equal 'error', rows['posts']['status']
      assert_equal 'destination: query failed: SQLSTATE 42P01', rows['posts']['error']
    end
  end

  def test_review_import_report_parsing
    with_review do
      parse = ->(text) { @service.send(:review_import_report, text) }
      assert_nil parse.call("Importing...\n")
      assert_equal({ issues: 0, counts: {}, log: nil }, parse.call("Done! (12 minutes)\n"))
      odd = parse.call("Import issues (details in /etc/passwd):\n  x: 1\nDone! (0 minutes)\n")
      assert_nil odd[:log]
      assert_equal 1, odd[:issues]
      unparsed = parse.call("Import issues (details in /tmp/generic_bulk_import_issues_20261108_101500.log):\nsomething else\nDone! (0 minutes)\n")
      assert_equal({ 'unparsed' => 1 }, unparsed[:counts])
    end
  end

  def test_review_cli_parses_the_review_form
    with_review do
      out = StringIO.new
      err = StringIO.new
      cli = SiloMigrate::StandardCLI.new(env: @env, output: out, error: err, runtime: @runtime, code_root: @code_root)
      status = cli.run(['plan', 'propose', 'synthetic', '--operation', 'review', '--from-run', @convert[:run_id], '--port', 'eighty'])
      refute_equal 0, status
      assert_includes err.string, 'STANDARD_ARGUMENTS_INVALID'
    end
  end
end
