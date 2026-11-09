# frozen_string_literal: true
require_relative 'standard_workflow_test'
require 'sqlite3'
require 'zlib'
require 'timeout'
require 'silo_migrate/services/standard_findings_service'
require 'silo_migrate/standard_cli'

# Scripted Docker/Git for convert-only runs on (invented) real-shaped data. No subprocess,
# Docker socket or network: commands are recorded and answered.
class ConvertScriptedRuntime < StandardScriptedRuntime
  GEMFILE = "source \"https://rubygems.org\"\n"
  LOCKFILE = "GEM\n  remote: https://rubygems.org/\n"
  DOCUMENT = {
    'Id' => 'placeholder', 'Architecture' => 'amd64', 'Os' => 'linux', 'RootFS' => { 'Layers' => ['sha256:' + '1' * 64] },
    'Config' => { 'Env' => ['PATH=/usr/local/bundle/bin:/usr/bin:/bin', 'RUBY_VERSION=3.3.13', 'GEM_HOME=/usr/local/bundle',
                            'BUNDLE_PATH=/opt/bundle', 'BUNDLE_FROZEN=true'], 'User' => '1001:1001', 'WorkingDir' => '/app' }
  }.freeze
  attr_accessor :service, :platform_missing, :convert_failure, :source_counts, :log_lines, :source_empty, :table_check_fails, :log_fifo
  attr_reader :calls, :stdins

  def initialize
    super
    self.images_match = true
    self.inspect_document = Marshal.load(Marshal.dump(DOCUMENT))
    self.source_counts = { 'src_users' => "3\n", 'src_posts' => "5\n" }
    @calls = []
    @stdins = []
  end

  def ok(stdout = '', success: true, stderr: '')
    SiloMigrate::Runtime::CommandResult.new(success?: success, stdout: stdout, stderr: stderr, status: success ? 0 : 1)
  end

  def run_dir(*parts)
    service.store.run_dir(service.store.load.fetch('runs').values.last.fetch('id'), *parts)
  end

  def run(cmd, **options)
    @calls << cmd
    @stdins << options[:stdin_data] if options[:stdin_data]
    if cmd.include?('cat-file')
      return ok(success: !platform_missing)
    elsif cmd.include?('show') && cmd.last.end_with?(':Gemfile')
      return ok(GEMFILE)
    elsif cmd.include?('show') && cmd.last.end_with?(':Gemfile.lock')
      return ok(LOCKFILE)
    elsif cmd[0, 2] == %w[git archive] || (cmd.include?('archive') && cmd.include?('--format=tar'))
      archive = cmd[cmd.index('-o') + 1]
      File.binwrite(archive, '')
      return ok
    elsif cmd.first == 'tar'
      return ok
    elsif cmd[0, 3] == %w[docker run -d]
      return ok(cmd.include?('mariadbd') ? "source-db-id\n" : "converter-id\n")
    elsif cmd[0, 2] == %w[docker exec] && cmd.last.to_s.include?('SELECT 1')
      return ok("1\n")
    elsif cmd[0, 2] == %w[docker exec] && cmd.last.to_s.include?("information_schema.tables WHERE table_schema = 'source'")
      return ok('', success: false, stderr: 'ERROR 2002') if table_check_fails

      return ok(source_empty ? "0\n" : "4\n")
    elsif cmd[0, 2] == %w[docker exec] && cmd.include?('--defaults-extra-file=/run-fixture/count.cnf')
      sql = options[:stdin_data].to_s
      key = source_counts.keys.find { |table| sql.include?(table) }
      return key ? ok(source_counts[key]) : ok('', success: false, stderr: 'ERROR 1146: no such table')
    elsif cmd[0, 2] == %w[docker exec] && cmd.include?('./convert') || cmd.any? { |arg| arg.to_s.include?('./convert') }
      output = run_dir('work', 'converter-output')
      if log_fifo
        File.mkfifo(File.join(output, 'convert.log'))
      else
        File.write(File.join(output, 'convert.log'), (log_lines || ['converting', '== Run Summary ==', 'Errors : 0 (conversion) + 0 (setup)']).join("\n") + "\n")
      end
      return ok('', success: false, stderr: 'converter failed') if convert_failure

      db = SQLite3::Database.new(File.join(output, 'intermediate.sqlite'))
      db.execute('PRAGMA journal_mode=WAL')
      db.execute('CREATE TABLE users (id INTEGER)')
      3.times { |n| db.execute('INSERT INTO users VALUES (?)', [n]) }
      db.execute('CREATE TABLE posts (id INTEGER)')
      4.times { |n| db.execute('INSERT INTO posts VALUES (?)', [n]) }
      db.close
      return ok
    elsif cmd[0, 3] == %w[docker image inspect]
      document = Marshal.load(Marshal.dump(inspect_document))
      document['Id'] = 'sha256:' + Digest::SHA256.hexdigest(cmd.last)
      return ok(JSON.generate([document]))
    end
    super
  end
end

class StandardConvertRunTest < SiloMigrateTest
  include StandardTestWorkspace

  SETTINGS = <<~YAML
    database:
      host: "${SILO_DB_HOST}"
      port: ${SILO_DB_PORT}
      username: "${SILO_DB_USER}"
      password: "${SILO_DB_PASSWORD}"
      database: "${SILO_DB_NAME}"
      table_prefix: "src_"
    import:
      site_url: "https://forum.example.invalid"
  YAML

  SPEC = JSON.generate('version' => 1, 'checks' => [
    { 'name' => 'users', 'source_sql' => 'SELECT COUNT(*) FROM src_users', 'intermediate_sql' => 'SELECT COUNT(*) FROM users' },
    { 'name' => 'posts', 'source_sql' => 'SELECT COUNT(*) FROM src_posts WHERE visible = 1', 'intermediate_sql' => 'SELECT COUNT(*) FROM posts', 'expect' => 'equal',
      'note' => 'drafts excluded by decision' },
    { 'name' => 'polls', 'source_sql' => 'SELECT COUNT(*) FROM src_polls', 'intermediate_sql' => 'SELECT COUNT(*) FROM polls', 'expect' => 'report' }
  ])

  def with_convert(dump: "CREATE TABLE src_users (id int);\n", settings: SETTINGS, spec: SPEC, deps: true)
    with_tmp_base do |dir, env|
      @dir = dir
      @env = env
      @named = SiloMigrate::Services::NamedWorkspaceService.new(env: env)
      @named.init('synthetic')
      @root = File.join(env.fetch('SILO_MIGRATE_BASE_PATH'), 'synthetic')
      source = @named.add_source('synthetic', platform: 'mybb')[:source_id]
      @dataset = @named.add_dataset('synthetic', source_id: source)[:dataset_id]
      label_delivery('development')
      @ids = {}
      @ids['source'] = add_input('dump.sql', dump, 'mysql-dump')
      @ids['settings'] = add_input('derived/settings.yml', settings, 'converter-settings')
      @ids['reconciliation'] = add_input('derived/checks.json', spec, 'reconciliation') if spec
      @code_root = File.join(dir, 'code')
      FileUtils.mkdir_p(File.join(@code_root, 'runtime'))
      FileUtils.cp_r(File.expand_path('../runtime/prebuilt-discourse', __dir__), File.join(@code_root, 'runtime'))
      FileUtils.cp_r(File.expand_path('../runtime/profiles', __dir__), File.join(@code_root, 'runtime'))
      profile_path = File.join(@code_root, 'runtime/profiles', SiloMigrate::RuntimeProfiles::DEFAULT + '.json')
      profile = JSON.parse(File.read(profile_path))
      digest = SiloMigrate::ImageIdentity.content_id(ConvertScriptedRuntime::DOCUMENT)
      profile.fetch('images').each_value { |image| image['content_id'] = digest }
      File.write(profile_path, JSON.pretty_generate(profile))
      write(File.join(@code_root, 'lib', 'identity.rb'), '# synthetic code identity')
      @runtime = ConvertScriptedRuntime.new
      @service = new_standard
      @service.define_singleton_method(:host_capacity) { [8, 64 * 1024] }
      @runtime.service = @service
      site = write(File.join(dir, 'site-settings.yml'), "title: Synthetic\n")
      converter = File.join(dir, 'converter')
      FileUtils.mkdir_p(File.join(converter, '.git'))
      File.write(File.join(converter, '.git', 'config'), '')
      @service.init(converter_worktree: converter, site_settings: site)
      prepare_deps if deps
      yield
    end
  end

  def label_delivery(kind)
    File.write(File.join(@root, '.silo-migrate', 'named', 'deliveries.json'),
               JSON.generate('version' => 1, 'deliveries' => { @dataset => { 'dataset_id' => @dataset, 'kind' => kind, 'version' => 1 } }))
  end

  def add_input(name, bytes, type)
    relative = "inputs/#{name}"
    write(File.join(@root, relative), bytes, mode: 'wb')
    File.chmod(0o400, File.join(@root, relative))
    @named.add_input('synthetic', dataset_id: @dataset, path: relative, sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize, type: type)[:input_id]
  end

  def converter_image_id
    'sha256:' + Digest::SHA256.hexdigest(@service.lock.dig('images', 'converter', 'ref'))
  end

  def deps_key
    @service.send(:converter_deps_binding, File.join(@dir, 'converter'), 'a' * 40, converter_image_id)
  end

  def deps_path
    File.join(@dir, 'state', 'converter-deps', deps_key.fetch('key'))
  end

  def prepare_deps
    binding = deps_key
    FileUtils.mkdir_p(File.join(deps_path, 'gems'))
    FileUtils.mkdir_p(File.join(deps_path, 'emoji_cache'))
    File.write(File.join(deps_path, 'ready.json'), JSON.generate(binding.slice('image', 'gemfile_sha256', 'lockfile_sha256').merge('recipe' => 1)))
  end

  def test_a_plan_binds_the_delivery_and_needs_one
    with_convert do
      plan = propose_convert
      assert_equal({ 'dataset_id' => @dataset, 'kind' => 'development', 'version' => 1 }, plan[:delivery])
      FileUtils.rm_f(File.join(@root, '.silo-migrate', 'named', 'deliveries.json'))
      standard_error('STANDARD_DELIVERY_UNLABELLED') { propose_convert }
      File.write(File.join(@root, '.silo-migrate', 'named', 'deliveries.json'), 'not json')
      standard_error('STANDARD_DELIVERY_UNLABELLED') { propose_convert }
      label_delivery('rehearsal')
      standard_error('STANDARD_DELIVERY_UNLABELLED') { propose_convert }
    end
  end

  def test_launch_data_can_be_labelled_but_cannot_run_yet
    with_convert do
      label_delivery('launch')
      standard_error('STANDARD_LAUNCH_NOT_READY') { propose_convert }
    end
  end

  def propose_convert(**overrides)
    @service.propose_convert_plan(source: @ids['source'], settings: @ids['settings'], reconciliation: @ids['reconciliation'], **overrides)
  end

  def approve_convert(plan = propose_convert)
    @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'synthetic engineer')
    plan
  end

  def run_convert
    plan = approve_convert
    @service.run_plan(plan_id: plan[:plan_id])
  end

  def docker_calls(prefix)
    @runtime.calls.select { |cmd| cmd[0, prefix.size] == prefix }
  end

  def test_deps_key_matches_converter_dev_py
    with_convert do
      key = @service.send(:converter_deps_binding, File.join(@dir, 'converter'), 'a' * 40, 'sha256:' + 'a' * 64)
      # bin/converter_dev.py, same image and files (computed with that code).
      assert_equal '8e44bd449cff0fae4836798644f00b3bc885c4e6bde1b743084faf3fb1948fec', key['key']
    end
  end

  def test_propose_binds_platform_roles_inputs_and_dependencies
    with_convert do
      plan = propose_convert(charset: 'latin1')
      assert_equal 'standard_convert', plan[:operation]
      assert_equal 'mybb', plan[:platform]
      assert_equal 'latin1', plan[:source_charset]
      assert_equal deps_key['key'], plan[:converter_deps]
      assert_equal 'report', plan[:reconciliation_policy]
      assert_equal @ids.values.sort, plan[:inputs].map { |input| input['id'] }.sort
      assert_equal({ 'source' => @ids['source'], 'settings' => @ids['settings'], 'reconciliation' => @ids['reconciliation'] }, plan[:roles])
      assert_equal({}, plan[:instances])
      assert_nil plan[:baseline]
      body = @service.store.load.fetch('plans').fetch(plan[:plan_id]).fetch('body')
      assert_equal %w[converter source_db], body.fetch('image_content_ids').keys.sort
      approve_convert(plan)
      run_id = @service.claim(plan_id: plan[:plan_id]).fetch(:run_id)
      assert_equal %w[preflight convert reconcile], @service.store.load.dig('runs', run_id, 'stages').keys
    end
  end

  def test_propose_refusals
    with_convert do
      standard_error('STANDARD_ARGUMENT_INVALID') { propose_convert(charset: 'koi8r') }
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.propose_convert_plan(source: @ids['source'], settings: @ids['source']) }
      standard_error('STANDARD_REFERENCE_INVALID') { @service.propose_convert_plan(source: 'input-missing', settings: @ids['settings']) }
      standard_error('STANDARD_INPUTS_INCOMPLETE') { @service.propose_convert_plan(source: @ids['settings'], settings: @ids['source']) }
      @runtime.platform_missing = true
      standard_error('STANDARD_CONVERTER_PLATFORM_MISSING') { propose_convert }
      @runtime.platform_missing = false
      FileUtils.rm_f(File.join(deps_path, 'ready.json'))
      standard_error('STANDARD_CONVERTER_DEPS_MISSING') { propose_convert }
    end
  end

  def test_settings_must_use_placeholders
    { SETTINGS.sub('"${SILO_DB_PASSWORD}"', '"secret"') => 'missing ${SILO_DB_PASSWORD}',
      SETTINGS + "  other: ${SILO_SECRET}\n" => 'unknown placeholder SILO_SECRET',
      "database: [${SILO_DB_PASSWORD}\n" => 'not YAML', "- ${SILO_DB_PASSWORD}\n" => 'not a YAML mapping' }.each do |settings, detail|
      with_convert(settings: settings) do
        error = standard_error('STANDARD_SETTINGS_INVALID') { propose_convert }
        assert_includes error.message, detail
      end
    end
  end

  def test_reconciliation_spec_is_validated
    bad = lambda do |check|
      JSON.generate('version' => 1, 'checks' => [{ 'name' => 'users', 'source_sql' => 'SELECT COUNT(*) FROM src_users', 'intermediate_sql' => 'SELECT COUNT(*) FROM users' }.merge(check)])
    end
    [bad.call('source_sql' => 'SELECT COUNT(*) FROM src_users; DROP TABLE src_users'), bad.call('source_sql' => 'DELETE FROM src_users'),
     bad.call('source_sql' => 'SELECT COUNT(*) FROM src_users -- x'), bad.call('source_sql' => 'SELECT COUNT(*) INTO OUTFILE "/tmp/x" FROM src_users'),
     bad.call('intermediate_sql' => "SELECT COUNT(*) FROM users WHERE 1 /* x */"), bad.call('intermediate_sql' => 'ATTACH DATABASE "/etc/x" AS x'),
     bad.call('intermediate_sql' => 'SELECT load_extension("x")'), bad.call('name' => 'Users!'), bad.call('expect' => 'close'), bad.call('extra' => 1),
     JSON.generate('version' => 2, 'checks' => []), JSON.generate('version' => 1, 'checks' => []), '{', '[]'].each do |spec|
      with_convert(spec: spec) do
        standard_error('STANDARD_RECONCILIATION_INVALID') { propose_convert }
      end
    end
  end

  def test_convert_run_loads_converts_reconciles_and_cleans_up
    with_convert do
      result = run_convert
      assert_equal 'completed', result[:status], result.inspect
      assert_equal({ 'preflight' => 'passed', 'convert' => 'passed', 'reconcile' => 'passed' }, result[:stages])
      run_id = result[:run_id]

      db_run = docker_calls(%w[docker run -d]).find { |cmd| cmd.include?('mariadbd') }
      assert_equal 'none', db_run[db_run.index('--network') + 1]
      assert_includes db_run, "type=bind,src=#{@service.store.run_dir(run_id, 'private', 'source-db')},dst=/var/lib/mysql"
      refute(db_run.any? { |arg| arg.start_with?('-p') || arg == '--publish' })
      assert_includes db_run, '--innodb-buffer-pool-size=4096M'
      assert_equal '8192m', db_run[db_run.index('--memory') + 1]

      load = @runtime.calls.find { |cmd| cmd.last.to_s.include?('/run-fixture/dump |') }
      assert_includes load.last, 'cat /run-fixture/dump | mariadb --defaults-extra-file=/run-fixture/root.cnf --sandbox --default-character-set=utf8mb4 source'

      converter_run = docker_calls(%w[docker run -d]).find { |cmd| cmd.include?('exec sleep infinity') }
      assert_equal 'container:source-db-id', converter_run[converter_run.index('--network') + 1]
      assert_includes converter_run, "type=bind,src=#{File.join(deps_path, 'gems')},dst=/deps,readonly"
      assert_includes converter_run, "type=bind,src=#{File.join(deps_path, 'emoji_cache')},dst=/app/tmp/emoji_cache,readonly"
      assert_includes converter_run, 'GEM_PATH=/deps:/opt/bundle/ruby/3.3.0:/usr/local/bundle'
      assert_includes converter_run, 'PATH=/deps/bin:/opt/bundle/ruby/3.3.0/bin:/usr/local/bundle/bin:/usr/bin:/bin'
      assert_includes converter_run, 'BUNDLE_APP_CONFIG=/tmp/bundle-config'
      convert = @runtime.calls.find { |cmd| cmd.any? { |arg| arg.to_s.include?('./convert') } }
      assert_equal %w[convert mybb], convert.last(2)
      assert_includes convert.join(' '), 'env -u BUNDLE_PATH bundle _2.6.3_ exec ruby ./convert --from="$1"'

      # Source counts come before the converter can touch the database.
      counted = @runtime.calls.index { |cmd| cmd.include?('--defaults-extra-file=/run-fixture/count.cnf') }
      assert_operator counted, :<, @runtime.calls.index(converter_run)
      @runtime.stdins.each { |sql| assert_match(/\ASET SESSION max_statement_time=1800;\nSELECT \(SELECT COUNT\(\*\) FROM src_[a-z]+[^;]*\);\n\z/, sql) }
      # Users are created after the load, so the dump can't change them.
      users = @runtime.calls.index { |cmd| cmd.last.to_s.include?('/run-fixture/users.sql') }
      assert_operator @runtime.calls.index(load), :<, users
      assert_operator users, :<, counted

      settings = File.read(@service.store.run_dir(run_id, 'private', 'converter', 'settings.yml'))
      refute_includes settings, '${SILO_'
      assert_includes settings, 'password: "[removed]"'
      assert_includes settings, 'port: 3306'
      assert_equal ['settings.yml'], Dir.children(@service.store.run_dir(run_id, 'private', 'converter'))
      assert_includes db_run, '--secure-file-priv=/var/lib/mysql-tmp'
      registered = File.read(File.join(@root, 'inputs/derived/settings.yml'))
      assert_includes registered, '${SILO_DB_PASSWORD}'

      %w[source-db source-db-tmp].each { |name| refute File.exist?(@service.store.run_dir(run_id, 'private', name)), name }
      refute File.exist?(@service.store.run_dir(run_id, 'work', 'inputs', 'dump.sql'))
      assert File.file?(@service.store.run_dir(run_id, 'artifacts', 'intermediate.sqlite'))
      assert_equal ['intermediate.sqlite'], Dir.children(@service.store.run_dir(run_id, 'artifacts'))
      assert File.file?(@service.store.run_dir(run_id, 'logs', 'conversion-output.log'))
      assert_includes File.read(@service.store.run_dir(run_id, 'evidence', 'conversion-summary.txt')), 'Errors : 0'
      assert(@runtime.calls.count { |cmd| cmd[0, 2] == %w[docker rm] } >= 2)

      rows = JSON.parse(File.read(@service.store.run_dir(run_id, 'evidence', 'reconciliation.json'))).fetch('checks')
      assert_equal [['users', 3, 3, 'matched'], ['posts', 5, 4, 'differs'], ['polls', nil, nil, 'error']],
                   rows.map { |row| row.values_at('name', 'source', 'intermediate', 'status') }
      assert_equal(-1, rows[1]['difference'])
      assert_equal 'drafts excluded by decision', rows[1]['note']

      public = @service.show_run(run_id)
      assert_equal({ 'input_count' => 3, 'input_bytes' => public.dig(:results, 'input_bytes'), 'conversion_summary' => 'present',
                     'reconciliation_checks' => 3, 'reconciliation_matched' => 1, 'reconciliation_differs' => 1, 'reconciliation_errors' => 1 }, public[:results])
      [JSON.generate(@service.status), JSON.generate(public)].each do |text|
        refute_match(/"reconciliation":/, text)
        refute_includes text, '1146'
        refute_includes text, 'src_users'
      end
      out = StringIO.new
      SiloMigrate::StandardCLI.new(env: @env, output: out, error: StringIO.new, runtime: @runtime, code_root: @code_root).run(['agent', 'run-show', 'synthetic', run_id])
      refute_match(/"reconciliation":|1146|src_users/, out.string)
      assert_includes out.string, '"reconciliation_differs":1'

      evidence = SiloMigrate::Services::StandardFindingsService.new('synthetic', env: @env).private_evidence(run_id)
      assert_equal 'may_propose', evidence[:finding]
      assert_equal 3, evidence.dig(:results, 'reconciliation').size
      assert_equal 'convert', SiloMigrate::Services::StandardFindingsService.log_stage('conversion-output')
      proposed = SiloMigrate::Services::StandardFindingsService.new('synthetic', env: @env).propose(run_id: run_id, text: 'posts differ by 1: invented explanation')
      assert_equal 'proposed', proposed[:status]
    end
  end

  def test_report_expectation_and_no_spec
    with_convert(spec: nil) do
      result = run_convert
      assert_equal 'completed', result[:status]
      assert_equal 0, result.dig(:results, 'reconciliation_checks')
      refute(@runtime.calls.any? { |cmd| cmd.include?('--defaults-extra-file=/run-fixture/count.cnf') })
    end
    spec = JSON.generate('version' => 1, 'checks' => [{ 'name' => 'users', 'source_sql' => 'SELECT COUNT(*) FROM src_users', 'intermediate_sql' => 'SELECT COUNT(*) FROM users', 'expect' => 'report' }])
    with_convert(spec: spec) do
      result = run_convert
      rows = JSON.parse(File.read(@service.store.run_dir(result[:run_id], 'evidence', 'reconciliation.json'))).fetch('checks')
      assert_equal 'reported', rows.first['status']
    end
  end

  def test_compressed_and_archive_dumps
    gz = StringIO.new
    writer = Zlib::GzipWriter.new(gz)
    writer.write("CREATE TABLE src_users (id int);\n")
    writer.close
    with_convert(dump: gz.string) do
      run_convert
      load = @runtime.calls.find { |cmd| cmd.last.to_s.include?('/run-fixture/dump |') }
      assert load.last.start_with?('set -o pipefail; gzip -dc /run-fixture/dump |')
    end
    with_convert(dump: "PK\x03\x04zipped".b) do
      # Refused at proposal: migration-data hears it before anyone approves anything.
      standard_error('STANDARD_DUMP_KIND_UNSUPPORTED') { propose_convert }
      refute(@runtime.calls.any? { |cmd| cmd[0, 3] == %w[docker run -d] })
    end
  end

  def test_converter_failure_fails_the_run_and_removes_everything
    with_convert do
      @runtime.convert_failure = true
      result = run_convert
      assert_equal 'failed', result[:status]
      assert_equal 'STANDARD_CONVERSION_FAILED', result.dig(:failure, 'code')
      run_id = result[:run_id]
      assert_equal %w[converter-id source-db-id], @runtime.calls.select { |cmd| cmd[0, 2] == %w[docker rm] }.map(&:last)
      refute File.exist?(@service.store.run_dir(run_id, 'private', 'source-db'))
      refute File.exist?(@service.store.run_dir(run_id, 'work', 'inputs', 'dump.sql'))
      assert_includes File.read(@service.store.run_dir(run_id, 'logs', 'convert.log')), 'converting'
    end
  end

  def test_dump_with_its_own_database_fails_clearly
    with_convert do
      @runtime.source_empty = true
      result = run_convert
      assert_equal 'STANDARD_SOURCE_EMPTY', result.dig(:failure, 'code')
      refute(@runtime.calls.any? { |cmd| cmd.include?('exec sleep infinity') })
      refute File.exist?(@service.store.run_dir(result[:run_id], 'private', 'source-db'))
    end
  end

  def test_failed_table_check_is_not_reported_as_an_empty_source
    with_convert do
      @runtime.table_check_fails = true
      assert_equal 'STANDARD_CONVERSION_FAILED', run_convert.dig(:failure, 'code')
    end
  end

  def test_a_fifo_in_place_of_the_converter_log_cannot_hang_the_run
    with_convert do
      @runtime.log_fifo = true
      result = Timeout.timeout(30) { run_convert }
      assert_equal 'completed', result[:status]
      assert_equal 'missing', result.dig(:results, 'conversion_summary')
    end
  end

  def test_convert_admission_counts_running_containers
    with_convert do
      plan = approve_convert
      @runtime.high_usage = true
      standard_error('STANDARD_CAPACITY') { @service.claim(plan_id: plan[:plan_id]) }
      @runtime.high_usage = false
      @service.define_singleton_method(:host_capacity) { [1, 64 * 1024] }
      standard_error('STANDARD_CAPACITY') { @service.claim(plan_id: plan[:plan_id]) }
      @service.define_singleton_method(:host_capacity) { [8, 20 * 1024] }
      standard_error('STANDARD_CAPACITY') { @service.claim(plan_id: plan[:plan_id]) }
      @service.define_singleton_method(:host_capacity) { [2, 22 * 1024] }
      assert @service.claim(plan_id: plan[:plan_id])[:run_id]
    end
  end

  def test_limits_are_sized_for_the_host_at_proposal
    with_convert do
      @service.define_singleton_method(:host_capacity) { [4, 11 * 1024] }
      plan_id = propose_convert[:plan_id]
      limits = @service.store.load.dig('plans', plan_id, 'body', 'limits')
      assert_equal({ 'cpus' => 2.0, 'memory_mib' => 2816, 'pids' => 512, 'buffer_pool' => '1408M' }, limits['db'])
      assert_equal 2816, limits.dig('converter', 'memory_mib')
      @service.define_singleton_method(:host_capacity) { [1, 2 * 1024] }
      standard_error('STANDARD_CAPACITY') { propose_convert }
    end
  end

  def test_disk_is_checked_before_the_dump_is_copied
    with_convert do
      plan = approve_convert
      @service.instance_variable_set(:@disk_free, -> { 8 * 1024**3 + 100 })
      result = @service.run_plan(plan_id: plan[:plan_id])
      assert_equal %w[STANDARD_CAPACITY preflight], result[:failure].values_at('code', 'stage')
      refute File.exist?(@service.store.run_dir(result[:run_id], 'work', 'inputs', 'dump.sql'))
    end
  end

  def test_reset_removes_what_a_killed_convert_run_left
    with_convert do
      plan = approve_convert
      run_id = @service.claim(plan_id: plan[:plan_id]).fetch(:run_id)
      private_dir = @service.store.run_dir(run_id, 'private')
      write(File.join(private_dir, 'source-db', 'ibdata1'), 'x')
      write(File.join(private_dir, 'converter', 'root.cnf'), 'password=secret')
      write(File.join(private_dir, 'converter', 'settings.yml'), "password: \"p#{'a' * 62}\"\n")
      write(@service.store.run_dir(run_id, 'work', 'inputs', 'dump.sql'), 'dump')
      write(@service.store.run_dir(run_id, 'work', 'inputs.json'), JSON.generate([{ 'id' => @ids['source'], 'role' => 'source', 'relative' => 'inputs/dump.sql' }]))
      @service.recover(run_id: run_id)
      @service.reset_run(run_id: run_id, yes: true)
      refute File.exist?(File.join(private_dir, 'source-db'))
      refute File.exist?(File.join(private_dir, 'converter', 'root.cnf'))
      refute File.exist?(@service.store.run_dir(run_id, 'work', 'inputs', 'dump.sql'))
      assert_equal "password: \"[removed]\"\n", File.read(File.join(private_dir, 'converter', 'settings.yml'))
    end
  end

  def test_intermediate_counts_read_at_most_two_rows_and_time_out
    with_convert do
      path = File.join(@dir, 'big.sqlite')
      db = SQLite3::Database.new(path)
      db.execute('PRAGMA journal_mode = WAL')
      db.execute('CREATE TABLE posts (id INTEGER, email TEXT)')
      db.transaction { 20_000.times { |n| db.execute('INSERT INTO posts VALUES (?, ?)', [n, n.even? ? "u#{n}@example.invalid" : nil]) } }
      db.close
      pids = []
      fork = Process.method(:fork)
      count = lambda do |sql, timeout: 60|
        Process.stub(:fork, ->(&block) { fork.call(&block).tap { |pid| pids << pid } }) do
          @service.send(:intermediate_count, path, sql, timeout: timeout)
        end
      end
      assert_equal [20_000, nil], count.call('SELECT COUNT(*) FROM posts')
      # Regression: sqlite3 2.8.1's statement_timeout interrupted any row-scanning query within ~2,000 VM steps.
      assert_equal [10_000, nil], count.call('SELECT COUNT(*) FROM posts WHERE email IS NOT NULL')
      assert_equal [10_000, nil], count.call('SELECT COUNT(DISTINCT p.id) FROM posts p JOIN posts q ON q.id = p.id WHERE p.email IS NULL')
      assert_equal [nil, 'not a single count'], count.call('SELECT id FROM posts')
      assert_equal [nil, 'not a single count'], count.call('SELECT 1, 2')
      assert_equal [nil, 'not a single count'], count.call('SELECT -1')
      assert_equal [nil, 'more than one statement'], count.call('SELECT 1; SELECT 2')
      assert_match(/\Aquery failed: no such table/, count.call('SELECT COUNT(*) FROM missing').last)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      value, error = count.call('WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT COUNT(*) FROM c', timeout: 1)
      assert_nil value
      assert_equal 'query failed: timed out after 1 s', error
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
      # A child that dies without an answer, or fails outside SQLite, is one check's error.
      # (If the child ran this process's at_exit handlers, minitest would run again in it.)
      @service.stub(:intermediate_count_in, ->(_db, _sql) { exit!(1) }) do
        assert_equal [nil, 'query failed: no result'], count.call('SELECT COUNT(*) FROM posts')
      end
      @service.stub(:intermediate_count_in, ->(_db, _sql) { raise 'boom' }) do
        assert_equal [nil, 'query failed: RuntimeError'], count.call('SELECT COUNT(*) FROM posts')
      end
      assert_equal 11, pids.size
      pids.each { |pid| assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) } } # all reaped
      refute File.exist?(path + '-shm')
      refute File.exist?(path + '-wal')
    end
  end

  def test_missing_dependencies_make_an_approved_plan_stale
    with_convert do
      plan = approve_convert
      FileUtils.rm_f(File.join(deps_path, 'ready.json'))
      error = standard_error('STANDARD_STALE_PLAN') { @service.claim(plan_id: plan[:plan_id]) }
      assert_includes error.message, 'converter_deps'
    end
  end

  def test_changed_registered_settings_make_the_plan_stale
    with_convert do
      plan = approve_convert
      path = File.join(@root, 'inputs/derived/settings.yml')
      File.chmod(0o600, path)
      File.write(path, SETTINGS + "# edited\n")
      standard_error('STANDARD_STALE_PLAN') { @service.claim(plan_id: plan[:plan_id]) }
    end
  end

  def test_discarded_plans_can_never_be_approved_or_run
    with_convert do
      plan = propose_convert
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.discard_plan(plan_id: plan[:plan_id], reviewer: '') }
      assert_equal 'discarded', @service.discard_plan(plan_id: plan[:plan_id], reviewer: 'Ruben (web UI)')[:status]
      assert_equal 'discarded', @service.show_plan(plan[:plan_id])[:status]
      standard_error('STANDARD_TRANSITION_INVALID') { @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'x') }
      standard_error('STANDARD_PLAN_CONSUMED') { @service.claim(plan_id: plan[:plan_id]) }
      standard_error('STANDARD_TRANSITION_INVALID') { @service.discard_plan(plan_id: plan[:plan_id], reviewer: 'x') }
      approved = approve_convert
      assert_equal 'discarded', @service.discard_plan(plan_id: approved[:plan_id], reviewer: 'x')[:status]
      standard_error('STANDARD_PLAN_CONSUMED') { @service.claim(plan_id: approved[:plan_id]) }
      out = StringIO.new
      cli = SiloMigrate::StandardCLI.new(env: @env, output: out, error: StringIO.new, runtime: @runtime, code_root: @code_root)
      third = propose_convert
      assert_equal 0, cli.run(['plan', 'discard', 'synthetic', third[:plan_id], '--reviewer', 'Ruben'])
      assert_equal 'discarded', JSON.parse(out.string)['status']
    end
  end

  def test_full_run_still_refuses_findings_once_completed
    with_convert do
      service = SiloMigrate::Services::StandardFindingsService.new('synthetic', env: @env)
      @service.store.update do |state|
        state['plans']['plan-x'] = { 'id' => 'plan-x', 'body' => { 'operation' => 'standard_full_snapshot' } }
        state['runs']['run-x'] = { 'id' => 'run-x', 'plan_id' => 'plan-x', 'status' => 'completed', 'stages' => {}, 'results' => {}, 'assertions' => {} }
      end
      standard_error('STANDARD_RUN_COMPLETED') { service.propose(run_id: 'run-x', text: 'nothing to diagnose') }
    end
  end

  def test_cli_proposes_convert_plans_and_explains_refusals
    with_convert do
      out = StringIO.new
      err = StringIO.new
      cli = SiloMigrate::StandardCLI.new(env: @env, output: out, error: err, runtime: @runtime, code_root: @code_root)
      assert_equal 0, cli.run(['plan', 'propose', 'synthetic', '--operation', 'convert', '--source', @ids['source'], '--settings', @ids['settings'],
                               '--reconciliation', @ids['reconciliation'], '--charset', 'utf8mb4'])
      assert_equal 'standard_convert', JSON.parse(out.string)['operation']
      assert_equal 1, cli.run(['plan', 'propose', 'synthetic', '--operation', 'convert', '--source', @ids['source']])
      assert_includes err.string, 'STANDARD_ARGUMENTS_INVALID'
      FileUtils.rm_f(File.join(deps_path, 'ready.json'))
      err.truncate(0)
      err.rewind
      assert_equal 1, cli.run(['plan', 'propose', 'synthetic', '--operation', 'convert', '--source', @ids['source'], '--settings', @ids['settings']])
      assert_includes err.string, 'Error: STANDARD_CONVERTER_DEPS_MISSING: run dev_test once on this commit'
    end
  end
end
