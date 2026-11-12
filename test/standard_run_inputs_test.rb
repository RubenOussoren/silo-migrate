# frozen_string_literal: true
require_relative 'standard_convert_run_test'
require_relative 'standard_merge_run_test'

# Scripted converter that also answers the platform's committed settings template and can
# act on the mounted run-input directory the way a real converter might.
class RunInputsScriptedRuntime < ConvertScriptedRuntime
  PLATFORM_SETTINGS = <<~YAML
    database:
      host: ""
    mappings:
      directory: ""                             # blank = converter default
      reuse_base_import_ids: false
  YAML
  attr_accessor :platform_settings, :converter_effect, :exporter_missing, :export_files
  attr_reader :seen_inputs

  def run(cmd, **options)
    if cmd.include?('cat-file') && cmd.last.to_s.end_with?('scripts/export_master_lists.rb')
      @calls << cmd
      return ok(success: !exporter_missing)
    end
    if cmd.any? { |arg| arg.to_s.include?('export_master_lists.rb') } && cmd[0, 2] == %w[docker exec]
      @calls << cmd
      output = run_dir('work', 'converter-output')
      dir = run_dir('work', 'run-inputs')
      @seen_inputs = File.directory?(dir) ? Dir.glob('**/*', base: dir).sort.select { |rel| File.file?(File.join(dir, rel)) } : nil
      FileUtils.mkdir_p(File.join(output, 'master_lists'))
      (export_files || { 'master_category_data.csv' => "khoros_category_id,title\nc-1,Invented\n" }).each do |name, bytes|
        File.write(File.join(output, 'master_lists', name), bytes)
      end
      File.write(File.join(output, 'convert.log'), "exporting\n== Run Summary ==\nErrors : 0\n")
      return ok
    end
    if cmd.include?('show') && cmd.last.to_s.end_with?('/settings.yml')
      return platform_settings ? ok(platform_settings) : ok('', success: false, stderr: 'fatal: path does not exist')
    end
    if cmd.any? { |arg| arg.to_s.include?('./convert') }
      dir = run_dir('work', 'run-inputs')
      @seen_inputs = File.directory?(dir) ? Dir.glob('**/*', base: dir).sort.select { |rel| File.file?(File.join(dir, rel)) }.to_h { |rel| [rel, File.binread(File.join(dir, rel))] } : nil
      converter_effect&.call(dir)
    end
    super
  end
end

class StandardRunInputsTest < StandardConvertRunTest
  def self.runnable_methods
    public_instance_methods.grep(/^test_run_inputs/).map(&:to_s)
  end

  MAPPED_SETTINGS = StandardConvertRunTest::SETTINGS + "mappings:\n  directory: \"${SILO_RUN_INPUTS_DIR}\"\n"
  CATEGORY_CSV = "khoros_category_id,discourse_category_name\nc-1,Invented\n"
  HEADER_ONLY_CSV = "khoros_ranking_id,discourse_trust_level\n"

  def with_run_inputs(settings: MAPPED_SETTINGS, &block)
    with_convert(settings: settings) do
      runtime = RunInputsScriptedRuntime.new
      runtime.platform_settings = RunInputsScriptedRuntime::PLATFORM_SETTINGS
      runtime.service = @service
      @runtime = runtime
      @service.instance_variable_set(:@runtime, runtime)
      @maps = {
        'category_organization.csv' => add_input('maps/category_organization.csv', CATEGORY_CSV, 'run-input'),
        'user_ranking.csv' => add_input('maps/user_ranking.csv', HEADER_ONLY_CSV, 'run-input')
      }
      @reference = add_input('refs/wishes.xlsx', "PK invented workbook bytes\n", 'reference-copy')
      block.call
    end
  end

  def input_record(id)
    @service.store.named_state.fetch('inputs').fetch(id)
  end

  def manifest(**overrides)
    files = @maps.map do |name, id|
      record = input_record(id)
      { 'name' => name, 'input_id' => id, 'sha256' => record['sha256'], 'bytes' => record['bytes'],
        'lineage' => { 'references' => [{ 'input_id' => @reference, 'sha256' => input_record(@reference)['sha256'] }],
                       'preparation' => { 'job' => 'job-invented-1', 'tool' => 'migration-data.prepare', 'script_sha256' => 'c' * 64 } } }
    end
    { 'version' => 1, 'consumer' => { 'platform' => 'mybb', 'setting' => 'mappings.directory' },
      'source_sha256' => input_record(@ids['source'])['sha256'], 'files' => files,
      'absent_defaults' => ['tag_mapping.csv', 'trust_level_mapping.yml'], 'generated' => [] }.merge(overrides.transform_keys(&:to_s))
  end

  def preparation(**overrides)
    { 'version' => 1,
      'analyst' => { 'label' => 'Analyst summary (migration-data)', 'text' => 'Invented: wishes map categories; rankings left to defaults.' },
      'references' => [{ 'input_id' => @reference, 'sha256' => input_record(@reference)['sha256'] }],
      'outcomes' => [{ 'id' => 'o1', 'requirement' => 'Reorganize categories', 'disposition' => 'prepared_input', 'input' => 'category_organization.csv' },
                     { 'id' => 'o2', 'requirement' => 'Keep topic bodies', 'disposition' => 'stock' },
                     { 'id' => 'o3', 'requirement' => 'Badges', 'disposition' => 'excluded', 'exclusion' => 'x1' }],
      'questions' => [{ 'id' => 'q1', 'text' => 'Merge duplicate users?', 'status' => 'resolved', 'resolution' => 'Engineer: no.' }],
      'exclusions' => [{ 'id' => 'x1', 'text' => 'Badges are not migrated', 'reason' => 'customer choice' }] }.merge(overrides.transform_keys(&:to_s))
  end

  def run_with(plan)
    approve_convert(plan)
    @service.run_plan(plan_id: plan[:plan_id])
  end

  def test_run_inputs_absent_keeps_the_plan_body_unchanged
    with_convert do
      plan = propose_convert
      body = @service.store.load.fetch('plans').fetch(plan[:plan_id]).fetch('body')
      refute body.key?('run_inputs')
      refute body.key?('preparation')
      refute plan.key?(:run_inputs)
      refute plan.key?(:preparation)
      result = run_convert
      assert_equal 'completed', result[:status]
      converter_run = docker_calls(%w[docker run -d]).find { |cmd| cmd.include?('exec sleep infinity') }
      refute(converter_run.any? { |arg| arg.to_s.include?('/run-inputs') })
      refute File.exist?(@service.store.run_dir(result[:run_id], 'work', 'run-inputs'))
      refute File.exist?(@service.store.run_dir(result[:run_id], 'evidence', 'run-inputs.json'))
      refute result[:results].key?('run_inputs')
    end
  end

  def test_run_inputs_placeholder_only_with_a_manifest
    with_run_inputs do
      error = standard_error('STANDARD_SETTINGS_INVALID') { propose_convert }
      assert_includes error.message, 'SILO_RUN_INPUTS_DIR'
    end
    with_run_inputs(settings: StandardConvertRunTest::SETTINGS) do
      error = standard_error('STANDARD_SETTINGS_INVALID') { propose_convert(run_inputs: manifest) }
      assert_includes error.message, 'missing ${SILO_RUN_INPUTS_DIR}'
    end
    with_run_inputs(settings: StandardConvertRunTest::SETTINGS + "mappings:\n  directory: \"${SILO_RUN_INPUTS_DIR}/x\"\n") do
      error = standard_error('STANDARD_SETTINGS_INVALID') { propose_convert(run_inputs: manifest) }
      assert_includes error.message, 'mappings.directory must be'
    end
  end

  def test_run_inputs_bind_names_hashes_lineage_and_source
    with_run_inputs do
      plan = propose_convert(run_inputs: manifest)
      bound = plan[:run_inputs]
      assert_equal %w[category_organization.csv user_ranking.csv], bound['files'].map { |file| file['name'] }
      assert_equal '/run-inputs', bound['mount']
      assert_equal false, bound['writable']
      assert_equal input_record(@ids['source'])['sha256'], bound['source_sha256']
      assert_equal 'job-invented-1', bound['files'].first.dig('lineage', 'preparation', 'job')
      assert_equal (@ids.values + @maps.values).sort, plan[:inputs].map { |input| input['id'] }.sort
      assert(plan[:mutations].any? { |line| line.include?('read-only') && line.include?('mappings.directory') })
      # The run inputs are part of the one approved digest.
      without = propose_convert(run_inputs: manifest('absent_defaults' => []))
      refute_equal plan[:digest], without[:digest]
    end
  end

  def test_run_inputs_refusals
    with_run_inputs do
      cat = @maps['category_organization.csv']
      first = ->(changes) { manifest.tap { |doc| doc['files'][0].merge!(changes) } }
      {
        'version' => manifest('version' => 2),
        'consumer platform' => manifest('consumer' => { 'platform' => 'khoros', 'setting' => 'mappings.directory' }),
        'source_sha256' => manifest('source_sha256' => 'f' * 64),
        'sha256/bytes' => first.call('sha256' => 'e' * 64),
        'name' => first.call('name' => '../escape.csv'),
        'name ' => first.call('name' => 'a//b.csv'),
        'registered input' => first.call('input_id' => 'input-' + '0' * 32),
        'input type' => first.call('input_id' => @ids['reconciliation'], 'sha256' => input_record(@ids['reconciliation'])['sha256'], 'bytes' => input_record(@ids['reconciliation'])['bytes']),
        'duplicate' => manifest.tap { |doc| doc['files'][1]['name'] = 'Category_Organization.csv' },
        'overlap' => manifest('generated' => ['category_organization.csv']),
        'both a file and a directory' => manifest('generated' => ['category_organization.csv/x.yml']),
        'shape' => manifest('extra' => true),
        'reference' => first.call('lineage' => { 'references' => [{ 'input_id' => @reference, 'sha256' => 'd' * 64 }] }),
        'preparation job' => first.call('lineage' => { 'preparation' => { 'job' => 'job x; rm' } }),
        'only data files' => first.call('name' => 'post_import/override.rb'),
        'only data files ' => manifest('generated' => ['generated_step.rb']),
        'only data files  ' => manifest('absent_defaults' => ['Makefile'])
      }.each do |detail, doc|
        error = standard_error('STANDARD_RUN_INPUTS_INVALID') { propose_convert(run_inputs: doc) }
        assert_includes error.message, detail.strip, detail
      end
      error = standard_error('STANDARD_RUN_INPUTS_INVALID') { propose_convert(run_inputs: manifest('consumer' => { 'platform' => 'mybb', 'setting' => 'mappings.folder' })) }
      assert_includes error.message, "not in the converter's settings.yml"
      @runtime.platform_settings = nil
      error = standard_error('STANDARD_RUN_INPUTS_INVALID') { propose_convert(run_inputs: manifest) }
      assert_includes error.message, 'is not committed'
      assert cat
    end
  end

  def test_run_inputs_read_only_run_gets_a_fresh_real_copy_and_evidence
    with_run_inputs do
      result = run_with(propose_convert(run_inputs: manifest))
      assert_equal 'completed', result[:status], result.inspect
      run_id = result[:run_id]
      assert_equal({ 'category_organization.csv' => CATEGORY_CSV, 'user_ranking.csv' => HEADER_ONLY_CSV }, @runtime.seen_inputs)
      root = @service.store.run_dir(run_id, 'work', 'run-inputs')
      converter_run = docker_calls(%w[docker run -d]).find { |cmd| cmd.include?('exec sleep infinity') }
      assert_includes converter_run, "type=bind,src=#{root},dst=/run-inputs,readonly"
      settings = File.read(@service.store.run_dir(run_id, 'private', 'converter', 'settings.yml'))
      assert_includes settings, 'directory: "/run-inputs"'
      copy = File.join(root, 'category_organization.csv')
      original = File.join(@root, 'inputs/maps/category_organization.csv')
      refute_equal File.stat(original).ino, File.stat(copy).ino
      assert_equal 1, File.stat(copy).nlink
      assert_equal 0o400, File.stat(copy).mode & 0o777
      evidence = JSON.parse(File.read(@service.store.run_dir(run_id, 'evidence', 'run-inputs.json')))
      assert_equal %w[unchanged unchanged], evidence['declared'].map { |entry| entry['status'] }
      assert_equal %w[tag_mapping.csv trust_level_mapping.yml], evidence['absent_defaults_in_effect']
      assert_equal [], evidence['violations']
      assert_equal({ 'files' => 2, 'generated' => 0, 'absent_defaults_in_effect' => 2, 'violations' => 0 }, result[:results]['run_inputs'])
      # Non-role manifest files were copied by convert_preflight with the plan's bytes, beside the roles.
      manifest_copy = JSON.parse(File.read(@service.store.run_dir(run_id, 'work', 'inputs.json')))
      mapped = manifest_copy.select { |input| @maps.value?(input['id']) }
      assert_equal 2, mapped.size
      assert(mapped.all? { |input| input['role'].nil? && File.binread(@service.store.run_dir(run_id, 'work', input['relative'])).bytesize == input['bytes'] })
      # Engineer detail carries the private evidence; the default does not.
      detailed = @service.show_run(run_id, detail: true)
      assert_equal %w[category_organization.csv user_ranking.csv], detailed[:run_inputs_evidence]['declared'].map { |entry| entry['name'] }
      refute @service.show_run(run_id).key?(:run_inputs_evidence)
      # Custody untouched.
      assert_equal CATEGORY_CSV, File.binread(original)
    end
  end

  def test_run_inputs_declared_generated_default_is_captured_not_promoted
    with_run_inputs do
      @runtime.converter_effect = ->(dir) { File.write(File.join(dir, 'trust_level_mapping.yml'), "1: 0\n") }
      plan = propose_convert(run_inputs: manifest('generated' => ['trust_level_mapping.yml'], 'absent_defaults' => ['trust_level_mapping.yml']))
      assert_equal true, plan[:run_inputs]['writable']
      result = run_with(plan)
      assert_equal 'completed', result[:status], result.inspect
      run_id = result[:run_id]
      root = @service.store.run_dir(run_id, 'work', 'run-inputs')
      converter_run = docker_calls(%w[docker run -d]).find { |cmd| cmd.include?('exec sleep infinity') }
      assert_includes converter_run, "type=bind,src=#{root},dst=/run-inputs"
      captured = @service.store.run_dir(run_id, 'private', 'run-inputs-generated', 'trust_level_mapping.yml')
      assert_equal "1: 0\n", File.read(captured)
      assert_equal 1, result[:results].dig('run_inputs', 'generated')
      assert_equal 0, result[:results].dig('run_inputs', 'absent_defaults_in_effect')
      generated = @service.show_run(run_id, detail: true)[:run_inputs_evidence]['generated']
      assert_equal [{ 'name' => 'trust_level_mapping.yml', 'bytes' => 5, 'sha256' => Digest::SHA256.hexdigest("1: 0\n"), 'captured' => true }], generated
      assert(plan[:mutations].any? { |line| line.include?('kept privately as evidence and never reused') })
      refute(plan[:mutations].any? { |line| line.include?('trust_level_mapping') })
      # A second, independently approved run of the same manifest starts from the bound
      # bytes only, in its own new directory: the generated file is not an input.
      @runtime.converter_effect = nil
      second = run_with(propose_convert(run_inputs: manifest('generated' => ['trust_level_mapping.yml'])))
      assert_equal 'completed', second[:status], second.inspect
      refute_equal run_id, second[:run_id]
      refute @runtime.seen_inputs.key?('trust_level_mapping.yml')
      standard_error('STANDARD_PLAN_CONSUMED') { @service.claim(plan_id: plan[:plan_id]) }
    end
  end

  def test_run_inputs_explicit_empty_manifest_gets_a_fresh_writable_directory
    with_run_inputs do
      @runtime.converter_effect = ->(dir) { File.write(File.join(dir, 'trust_level_mapping.yml'), "1: 0\n") }
      empty = manifest('files' => [], 'absent_defaults' => ['tag_mapping.csv'], 'generated' => ['trust_level_mapping.yml'])
      first_plan = propose_convert(run_inputs: empty)
      assert_equal [], first_plan.dig(:run_inputs, 'files')
      assert_equal true, first_plan.dig(:run_inputs, 'writable')
      assert_equal @ids.values.sort, first_plan[:inputs].map { |input| input['id'] }.sort
      first = run_with(first_plan)
      assert_equal 'completed', first[:status], first.inspect
      assert_equal({}, @runtime.seen_inputs)
      second_plan = propose_convert(run_inputs: empty)
      refute_equal first_plan[:plan_id], second_plan[:plan_id]
      second = run_with(second_plan)
      assert_equal 'completed', second[:status], second.inspect
      # Fresh, empty directory again: the first run's generated default is not an input.
      assert_equal({}, @runtime.seen_inputs)
      [first, second].each do |result|
        assert_equal({ 'files' => 0, 'generated' => 1, 'absent_defaults_in_effect' => 1, 'violations' => 0 }, result[:results]['run_inputs'])
        assert_equal "1: 0\n", File.read(@service.store.run_dir(result[:run_id], 'private', 'run-inputs-generated', 'trust_level_mapping.yml'))
      end
      dirs = [first, second].map { |result| File.stat(@service.store.run_dir(result[:run_id], 'work', 'run-inputs')).ino }
      refute_equal dirs.first, dirs.last
      # An undeclared write still fails with an empty manifest.
      @runtime.converter_effect = ->(dir) { File.write(File.join(dir, 'user_overrides.yml'), "{}\n") }
      third = run_with(propose_convert(run_inputs: empty))
      assert_equal 'STANDARD_RUN_INPUTS_MUTATED', third.dig(:failure, 'code')
      # Without any manifest, no directory and no mount, as before.
      @runtime.converter_effect = nil
    end
  end

  def test_run_inputs_undeclared_changes_fail_the_run
    effects = {
      'modified' => ->(dir) { File.chmod(0o600, File.join(dir, 'user_ranking.csv')); File.write(File.join(dir, 'user_ranking.csv'), "x\n") },
      'removed' => ->(dir) { File.delete(File.join(dir, 'category_organization.csv')) },
      'undeclared file' => ->(dir) { File.write(File.join(dir, 'user_overrides.yml'), "{}\n") },
      'not a regular file' => ->(dir) { File.symlink('/etc/hostname', File.join(dir, 'trust_level_mapping.yml')) },
      'executable file' => ->(dir) { File.write(File.join(dir, 'trust_level_mapping.yml'), "1: 0\n"); File.chmod(0o700, File.join(dir, 'trust_level_mapping.yml')) },
      'undeclared file ' => ->(dir) { File.write(File.join(dir, 'step.rb'), "puts 1\n") },
      'undeclared directory' => ->(dir) { Dir.mkdir(File.join(dir, 'empty')) },
      'undeclared directory ' => ->(dir) { FileUtils.mkdir_p(File.join(dir, 'a/b/c/d/e')) },
      'too many entries' => ->(dir) { 1100.times { |n| File.write(File.join(dir, "x#{n}.csv"), '') } },
      'larger than' => ->(dir) { File.write(File.join(dir, 'trust_level_mapping.yml'), 'x' * (16 * 1024 * 1024 + 1)) },
      'modified ' => ->(dir) { File.chmod(0o600, File.join(dir, 'user_ranking.csv')); File.write(File.join(dir, 'user_ranking.csv'), 'x' * 50_000) }
    }
    effects.each do |detail, effect|
      with_run_inputs do
        @runtime.converter_effect = effect
        result = run_with(propose_convert(run_inputs: manifest('generated' => ['trust_level_mapping.yml'])))
        assert_equal 'failed', result[:status], detail
        assert_equal 'STANDARD_RUN_INPUTS_MUTATED', result.dig(:failure, 'code'), detail
        evidence = JSON.parse(File.read(@service.store.run_dir(result[:run_id], 'evidence', 'run-inputs.json')))
        assert(evidence['violations'].any? { |line| line.include?(detail.strip) }, "#{detail}: #{evidence['violations'].first(3)}")
        refute File.exist?(@service.store.run_dir(result[:run_id], 'artifacts', 'intermediate.sqlite')), detail
      end
    end
  end

  def test_run_inputs_selected_file_changed_after_approval_is_stale
    with_run_inputs do
      plan = approve_convert(propose_convert(run_inputs: manifest))
      path = File.join(@root, 'inputs/maps/user_ranking.csv')
      File.chmod(0o600, path)
      File.write(path, HEADER_ONLY_CSV + "r-1,2\n")
      assert_equal 'stale', @service.show_plan(plan[:plan_id])[:status]
      error = standard_error('STANDARD_STALE_PLAN') { @service.claim(plan_id: plan[:plan_id]) }
      assert_includes error.message, 'inputs'
    end
    with_run_inputs do
      plan = approve_convert(propose_convert(run_inputs: manifest))
      File.delete(File.join(@root, 'inputs/maps/category_organization.csv'))
      standard_error('STANDARD_STALE_PLAN') { @service.claim(plan_id: plan[:plan_id]) }
    end
  end

  def test_run_inputs_preparation_binds_review_metadata
    with_run_inputs do
      plan = propose_convert(run_inputs: manifest, preparation: preparation)
      prep = plan[:preparation]
      assert_equal 'Analyst summary (migration-data)', prep.dig('analyst', 'label')
      assert_equal({ 'kind' => 'converter', 'present' => true, 'platform' => 'mybb', 'path' => 'converters/mybb/converter.rb', 'revision' => 'a' * 40, 'required' => false,
                     'claim' => 'pinned_code_available', 'note' => SiloMigrate::Services::StandardRunInputs::CODE_CLAIM }, prep['code_readiness'])
      assert_includes prep['code_readiness']['note'], 'not proof'
      assert_equal 'custody_bytes', prep['references'].first['verified']
      # Agent projection: counts and readiness, not the analyst's text.
      summary = @service.show_plan(plan[:plan_id])[:preparation]
      refute_includes JSON.generate(summary), 'Invented: wishes'
      assert_equal({ 'prepared_input' => 1, 'stock' => 1, 'excluded' => 1 }, summary['outcomes'])
      assert_includes plan[:not_included], '2 excluded outcome(s)/exclusion(s) from the preparation review'
      manual = propose_convert(run_inputs: manifest, preparation: preparation('outcomes' => [{ 'id' => 'o1', 'requirement' => 'Rename staff', 'disposition' => 'manual' }]))
      assert_includes manual[:not_included], '1 manual follow-up outcome(s) from the preparation review: not performed by this run'
      without = propose_convert(run_inputs: manifest)
      assert_equal %w[import\ into\ Discourse uploads hosted\ restore DNS\ or\ cutover remote\ pushes], without[:not_included]
      assert_equal 'Invented: wishes map categories; rankings left to defaults.', @service.show_plan(plan[:plan_id], detail: true).dig(:preparation, 'analyst', 'text')
      code = propose_convert(run_inputs: manifest, preparation: preparation('outcomes' => [{ 'id' => 'o1', 'requirement' => 'Custom routing', 'disposition' => 'code' }]))
      assert_equal true, code.dig(:preparation, 'code_readiness', 'required')
    end
  end

  def test_run_inputs_preparation_refusals
    with_run_inputs do
      error = standard_error('STANDARD_PREPARATION_UNRESOLVED') do
        propose_convert(run_inputs: manifest, preparation: preparation('questions' => [{ 'id' => 'q1', 'text' => 'Merge duplicate users?' }]))
      end
      assert_includes error.message, 'question 1'
      standard_error('STANDARD_PREPARATION_UNRESOLVED') { propose_convert(run_inputs: manifest, preparation: preparation('questions' => [{ 'id' => 'q1', 'text' => 'x', 'status' => 'open', 'resolution' => 'later' }])) }
      {
        'prepared_input' => preparation('outcomes' => [{ 'id' => 'o1', 'requirement' => 'x', 'disposition' => 'prepared_input', 'input' => 'tag_mapping.csv' }]),
        'analyst' => preparation('analyst' => { 'text' => 'no label' }),
        'disposition' => preparation('outcomes' => [{ 'id' => 'o1', 'requirement' => 'x', 'disposition' => 'implemented' }]),
        'excluded outcome must name an exclusion' => preparation('outcomes' => [{ 'id' => 'o1', 'requirement' => 'x', 'disposition' => 'excluded', 'exclusion' => 'x9' }]),
        'excluded question must name an exclusion' => preparation('outcomes' => [], 'questions' => [{ 'id' => 'q1', 'text' => 'x', 'status' => 'excluded', 'resolution' => 'out' }]),
        'reference 1' => preparation('outcomes' => [], 'references' => [{ 'input_id' => @reference, 'sha256' => '0' * 64 }]),
        'id' => preparation('outcomes' => [{ 'id' => 'o1', 'requirement' => 'x', 'disposition' => 'stock' }, { 'id' => 'o1', 'requirement' => 'y', 'disposition' => 'stock' }]),
        'shape' => preparation('script' => 'rm -rf /')
      }.each do |detail, doc|
        error = standard_error('STANDARD_PREPARATION_INVALID') { propose_convert(run_inputs: manifest, preparation: doc) }
        assert_includes error.message, detail, detail
      end
    end
  end

  def test_run_inputs_changed_reference_makes_the_plan_stale
    with_run_inputs do
      plan = approve_convert(propose_convert(run_inputs: manifest, preparation: preparation('outcomes' => [])))
      path = File.join(@root, 'inputs/refs/wishes.xlsx')
      File.chmod(0o600, path)
      File.write(path, "PK edited workbook\n")
      error = standard_error('STANDARD_STALE_PLAN') { @service.claim(plan_id: plan[:plan_id]) }
      assert_includes error.message, 'preparation'
    end
  end

  def test_run_inputs_from_another_dataset_need_an_explicit_reuse
    with_run_inputs do
      other = @named.add_dataset('synthetic', source_id: @service.store.named_state.fetch('datasets').fetch(@dataset).fetch('source_id'))[:dataset_id]
      deliveries = File.join(@root, '.silo-migrate', 'named', 'deliveries.json')
      document = JSON.parse(File.read(deliveries))
      document['deliveries'][other] = { 'dataset_id' => other, 'kind' => 'development', 'version' => 2 }
      File.write(deliveries, JSON.generate(document))
      current = @dataset
      @dataset = other
      older_dump = add_input('older/dump.sql', "CREATE TABLE src_users (id int, old int);\n", 'mysql-dump')
      older_map = add_input('older/category_organization.csv', CATEGORY_CSV + "c-2,Older\n", 'run-input')
      @dataset = current
      @maps = { 'category_organization.csv' => older_map }
      error = standard_error('STANDARD_RUN_INPUTS_INVALID') { propose_convert(run_inputs: manifest) }
      assert_includes error.message, "not in the plan source's dataset; declare reuse explicitly"
      reuse = manifest.tap { |doc| doc['files'][0]['reuse'] = { 'dataset_id' => other, 'source_sha256' => input_record(older_dump)['sha256'] } }
      plan = propose_convert(run_inputs: reuse)
      assert_equal({ 'dataset_id' => other, 'source_sha256' => input_record(older_dump)['sha256'] }, plan.dig(:run_inputs, 'files', 0, 'reuse'))
      assert(plan[:mutations].any? { |line| line.include?('explicitly reused from another delivery') })
      assert_equal 1, @service.show_plan(plan[:plan_id])[:run_inputs]['reused']
      bad = manifest.tap { |doc| doc['files'][0]['reuse'] = { 'dataset_id' => other, 'source_sha256' => 'a' * 64 } }
      error = standard_error('STANDARD_RUN_INPUTS_INVALID') { propose_convert(run_inputs: bad) }
      assert_includes error.message, 'not a registered mysql-dump source input of that dataset'
      # The reused mapping file's own digest is not a source snapshot.
      itself = manifest.tap { |doc| doc['files'][0]['reuse'] = { 'dataset_id' => other, 'source_sha256' => input_record(older_map)['sha256'] } }
      error = standard_error('STANDARD_RUN_INPUTS_INVALID') { propose_convert(run_inputs: itself) }
      assert_includes error.message, 'not a registered mysql-dump source input of that dataset'
      # Nor is another non-source input of that dataset with a matching digest.
      @dataset = other
      settings_copy = add_input('older/settings.yml', "x: 1\n", 'converter-settings')
      @dataset = current
      as_settings = manifest.tap { |doc| doc['files'][0]['reuse'] = { 'dataset_id' => other, 'source_sha256' => input_record(settings_copy)['sha256'] } }
      standard_error('STANDARD_RUN_INPUTS_INVALID') { propose_convert(run_inputs: as_settings) }
      wrong = manifest.tap { |doc| doc['files'][0]['reuse'] = { 'dataset_id' => @dataset, 'source_sha256' => input_record(@ids['source'])['sha256'] } }
      error = standard_error('STANDARD_RUN_INPUTS_INVALID') { propose_convert(run_inputs: wrong) }
      assert_includes error.message, "reuse dataset_id differs from the input's dataset"
      document['deliveries'][other]['kind'] = 'base_site'
      File.write(deliveries, JSON.generate(document))
      error = standard_error('STANDARD_RUN_INPUTS_INVALID') { propose_convert(run_inputs: reuse) }
      assert_includes error.message, 'another delivery kind'
    end
  end

  def test_run_inputs_lineage_binds_the_preparation_spec_digest
    with_run_inputs do
      doc = manifest.tap { |item| item['files'].each { |file| file['lineage']['preparation']['preparation_sha256'] = 'e' * 64 } }
      plan = propose_convert(run_inputs: doc)
      assert_equal 'e' * 64, plan.dig(:run_inputs, 'files', 0, 'lineage', 'preparation', 'preparation_sha256')
      doc['files'][0]['lineage']['preparation']['preparation_sha256'] = 'E' * 64
      error = standard_error('STANDARD_RUN_INPUTS_INVALID') { propose_convert(run_inputs: doc) }
      assert_includes error.message, 'preparation_sha256'
    end
  end

  # file roles' "taken" is the input ID an intake file became (FileRoleStore validates it as
  # one); a taken reference is checked against those custody bytes, an untaken one by digest.
  def test_run_inputs_file_role_references
    with_run_inputs do
      ref_sha = input_record(@reference)['sha256']
      taken = 'file-' + 'a' * 32
      untaken = 'file-' + 'b' * 32
      data = File.join(@root, '.silo-migrate', 'data')
      FileUtils.mkdir_p(data, mode: 0o700)
      File.chmod(0o700, data)
      roles = File.join(data, 'file-roles.json')
      File.write(roles, JSON.generate('version' => 1, 'revision' => 1, 'active' => { 'development' => @dataset },
                                      'snapshots' => { @dataset => { 'revision' => 1, 'eligible' => true, 'kind' => 'development' } },
                                      'files' => { taken => { 'id' => taken, 'role' => 'reference', 'dataset_id' => @dataset, 'sha256' => ref_sha, 'taken' => @reference },
                                                   untaken => { 'id' => untaken, 'role' => 'reference', 'dataset_id' => nil, 'sha256' => 'c' * 64 } },
                                      'history' => []))
      File.chmod(0o600, roles)
      prep = preparation('references' => [{ 'file_id' => taken, 'sha256' => ref_sha }, { 'file_id' => untaken, 'sha256' => 'c' * 64 }])
      plan = propose_convert(run_inputs: manifest, preparation: prep)
      assert_equal %w[custody_bytes registry_digest], plan.dig(:preparation, 'references').map { |ref| ref['verified'] }
      error = standard_error('STANDARD_PREPARATION_INVALID') { propose_convert(run_inputs: manifest, preparation: preparation('references' => [{ 'file_id' => taken, 'sha256' => 'c' * 64 }])) }
      assert_includes error.message, 'reference 1'
    end
  end

  def test_run_inputs_cli_documents
    with_run_inputs do
      out = StringIO.new
      err = StringIO.new
      cli = SiloMigrate::StandardCLI.new(env: @env, output: out, error: err, runtime: @runtime, code_root: @code_root)
      manifest_path = write(File.join(@dir, 'docs', 'manifest.json'), JSON.generate(manifest))
      prep_path = write(File.join(@dir, 'docs', 'prep.json'), JSON.generate(preparation))
      assert_equal 0, cli.run(['plan', 'propose', 'synthetic', '--operation', 'convert', '--source', @ids['source'], '--settings', @ids['settings'],
                               '--run-inputs', manifest_path, '--preparation', prep_path]), err.string
      proposed = JSON.parse(out.string)
      assert_equal 2, proposed.dig('run_inputs', 'files').size
      assert_equal 'Invented: wishes map categories; rankings left to defaults.', proposed.dig('preparation', 'analyst', 'text')
      out.truncate(0)
      out.rewind
      assert_equal 0, cli.run(['plan', 'show', 'synthetic', proposed['plan_id']])
      clean = JSON.parse(out.string)
      refute_includes out.string, 'Invented: wishes'
      refute_includes out.string, 'category_organization'
      refute_includes out.string, 'job-invented-1'
      assert_equal 2, clean.dig('run_inputs', 'files')
      out.truncate(0)
      out.rewind
      assert_equal 0, cli.run(['plan', 'show', 'synthetic', proposed['plan_id'], '--detail'])
      assert JSON.parse(out.string).dig('preparation', 'analyst', 'text')
      assert_equal 1, cli.run(['plan', 'show', 'synthetic', proposed['plan_id'], '--other'])
      out.truncate(0)
      out.rewind
      assert_equal 0, cli.run(['agent', 'plan-show', 'synthetic', proposed['plan_id']])
      refute_includes out.string, 'Invented: wishes'
      bad = write(File.join(@dir, 'docs', 'bad.json'), '{')
      assert_equal 1, cli.run(['plan', 'propose', 'synthetic', '--operation', 'convert', '--source', @ids['source'], '--settings', @ids['settings'], '--run-inputs', bad])
      assert_includes err.string, 'Error: STANDARD_RUN_INPUTS_INVALID: not JSON'
      large = write(File.join(@dir, 'docs', 'large.json'), JSON.generate('pad' => 'x' * (64 * 1024)))
      assert_equal 1, cli.run(['plan', 'propose', 'synthetic', '--operation', 'convert', '--source', @ids['source'], '--settings', @ids['settings'], '--preparation', large])
      assert_includes err.string, 'STANDARD_PREPARATION_INVALID: larger than 64 KiB'
    end
  end
end

class StandardMasterListsTest < StandardRunInputsTest
  def self.runnable_methods
    public_instance_methods.grep(/^test_master_lists/).map(&:to_s)
  end

  def test_master_lists_plan_is_its_own_approved_operation
    with_run_inputs(settings: StandardConvertRunTest::SETTINGS) do
      plan = @service.propose_master_lists_plan(source: @ids['source'], settings: @ids['settings'], list: 'categories')
      assert_equal 'standard_master_lists', plan[:operation]
      assert_equal({ 'script' => 'converters/mybb/scripts/export_master_lists.rb', 'list' => 'categories' }, plan[:master_lists])
      assert(plan[:mutations].any? { |line| line.include?('staging') && line.include?('disposable copy') })
      assert_includes plan[:not_included], 'registering exports as run inputs'
      assert_nil plan[:reconciliation_policy]
      standard_error('STANDARD_NOT_APPROVED') { @service.claim(plan_id: plan[:plan_id]) }
      standard_error('STANDARD_ARGUMENT_INVALID') { @service.propose_master_lists_plan(source: @ids['source'], settings: @ids['settings'], list: 'all; rm') }
      @runtime.exporter_missing = true
      error = standard_error('STANDARD_CONVERTER_PLATFORM_MISSING') { @service.propose_master_lists_plan(source: @ids['source'], settings: @ids['settings']) }
      assert_includes error.message, 'master-list exporter'
    end
  end

  def test_master_lists_run_exports_into_private_artifacts_only
    with_run_inputs(settings: StandardConvertRunTest::SETTINGS) do
      registered = @service.store.named_state.fetch('inputs').keys
      plan = @service.propose_master_lists_plan(source: @ids['source'], settings: @ids['settings'], list: 'categories')
      approve_convert(plan)
      result = @service.run_plan(plan_id: plan[:plan_id])
      assert_equal 'completed', result[:status], result.inspect
      assert_equal({ 'preflight' => 'passed', 'export' => 'passed' }, result[:stages])
      export = @runtime.calls.find { |cmd| cmd.any? { |arg| arg.to_s.include?('export_master_lists.rb') } && cmd[0, 2] == %w[docker exec] }
      assert_equal ['export', 'mybb', 'categories'], export.last(3)
      refute(@runtime.calls.any? { |cmd| cmd.any? { |arg| arg.to_s.include?('./convert') } })
      artifact = @service.store.run_dir(result[:run_id], 'artifacts', 'master-lists', 'master_category_data.csv')
      assert_equal "khoros_category_id,title\nc-1,Invented\n", File.read(artifact)
      assert_equal 0o400, File.stat(artifact).mode & 0o777
      assert_equal({ 'files' => 1, 'bytes' => 38 }, result[:results]['master_lists'])
      refute result.dig(:artifacts, 'master_lists').key?('files')
      assert_equal ['master_category_data.csv'], @service.show_run(result[:run_id], detail: true)[:master_lists_files].map { |file| file['name'] }
      refute result[:artifacts].key?('intermediate')
      # The source copy and the disposable database are gone, as for convert runs.
      refute File.exist?(@service.store.run_dir(result[:run_id], 'private', 'source-db'))
      # Exports are never registered as inputs automatically.
      assert_equal registered, @service.store.named_state.fetch('inputs').keys
      standard_error('STANDARD_PLAN_CONSUMED') { @service.claim(plan_id: plan[:plan_id]) }
    end
  end

  def test_master_lists_unexpected_output_fails
    with_run_inputs(settings: StandardConvertRunTest::SETTINGS) do
      @runtime.export_files = { 'master_category_data.csv' => "a\n", 'evil.rb' => "puts 1\n" }
      plan = approve_convert(@service.propose_master_lists_plan(source: @ids['source'], settings: @ids['settings']))
      result = @service.run_plan(plan_id: plan[:plan_id])
      assert_equal 'failed', result[:status]
      assert_equal 'STANDARD_CONVERSION_FAILED', result.dig(:failure, 'code')
    end
  end

  def test_master_lists_cli
    with_run_inputs(settings: StandardConvertRunTest::SETTINGS) do
      out = StringIO.new
      err = StringIO.new
      cli = SiloMigrate::StandardCLI.new(env: @env, output: out, error: err, runtime: @runtime, code_root: @code_root)
      assert_equal 0, cli.run(['plan', 'propose', 'synthetic', '--operation', 'master-lists', '--source', @ids['source'], '--settings', @ids['settings'], '--list', 'tags']), err.string
      assert_equal 'tags', JSON.parse(out.string).dig('master_lists', 'list')
      assert_equal 1, cli.run(['plan', 'propose', 'synthetic', '--operation', 'master-lists', '--source', @ids['source'], '--settings', @ids['settings'], '--preparation', 'x.json'])
    end
  end
end

class StandardMergePreparationTest < StandardMergeRunTest
  def self.runnable_methods
    public_instance_methods.grep(/^test_merge_preparation/).map(&:to_s)
  end

  def merge_preparation(outcomes)
    { 'version' => 1, 'analyst' => { 'label' => 'Analyst summary', 'text' => 'Invented wishes for a merge.' },
      'outcomes' => outcomes, 'questions' => [{ 'id' => 'q1', 'text' => 'Same-named groups?', 'status' => 'scope_narrowed', 'resolution' => 'Keep separate.' }] }
  end

  def test_merge_preparation_code_readiness_comes_from_the_pinned_layer
    with_merge do
      plain = merge_plan(settings: @merge_settings)
      refute plain.key?(:preparation)
      stock = merge_plan(settings: @merge_settings, preparation: merge_preparation([{ 'id' => 'o1', 'requirement' => 'Route categories', 'disposition' => 'prepared_input', 'input' => 'settings' }]))
      assert_equal({ 'kind' => 'merge_layer', 'present' => false, 'required' => false, 'claim' => 'no_pinned_code',
                     'note' => SiloMigrate::Services::StandardRunInputs::CODE_CLAIM }, stock.dig(:preparation, 'code_readiness'))
      error = standard_error('STANDARD_PREPARATION_INVALID') { merge_plan(preparation: merge_preparation([{ 'id' => 'o1', 'requirement' => 'Custom routing', 'disposition' => 'code' }])) }
      assert_includes error.message, 'no pinned consumer code (merge_layer)'
      standard_error('STANDARD_PREPARATION_INVALID') { merge_plan(preparation: merge_preparation([{ 'id' => 'o1', 'requirement' => 'Routes', 'disposition' => 'setting' }])) }

      sha = 'b' * 40
      source = "class InventedMerger < BulkImport::DiscourseMerger; end\n"
      @runtime.layer_entries = "100644 blob #{sha}\tmergers/synthetic/merger.rb\0"
      @runtime.layer_blobs = { sha => source, 'mergers/synthetic/merger.rb' => source }
      layered = merge_plan(preparation: merge_preparation([{ 'id' => 'o1', 'requirement' => 'Custom routing', 'disposition' => 'code' }]))
      readiness = layered.dig(:preparation, 'code_readiness')
      assert_equal true, readiness['present']
      assert_equal true, readiness['required']
      assert_equal layered.dig(:merge, 'layer', 'sha256'), readiness['sha256']
      assert_equal 'mergers/synthetic/merger.rb', readiness['path']
      assert_equal 'pinned_code_available', readiness['claim']
    end
  end
end
