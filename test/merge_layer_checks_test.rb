# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/merge_settings_runner'

# merge_run.rb end to end against a stand-in Rails: layer contract, policy-check order, and the
# site-setting snapshot every run is bound to.
class MergeLayerChecksTest < SiloMigrateTest
  include MergeSettingsRunner

  AUTH_PRESENT = SITE.merge('authorized_extensions' => ['pdf|txt|PRIVATE-EXT', 8])

  def test_required_checks_run_before_constructor_and_after_copy
    result = run_merge(layer: checked_layer)
    assert result.status.success?, result.err
    assert_empty result.err
    assert_equal %w[EVENT:preflight EVENT:constructor EVENT:copy], events(result).first(3)
    assert_equal 'EVENT:postflight', events(result)[4]
    assert_equal 'SILO_MERGE: done', result.out.lines.last.chomp
    assert_equal 'clean', result.report['state']
  end

  def test_preflight_constructor_copy_and_postflight_share_process_subclass_and_snapshot
    layer = <<~'RUBY'
      class InventedLayer < BulkImport::DiscourseMerger
        def self.silo_merge_preflight!
          @hook_pid = Process.pid
          @hook_class = self
          @baseline = { invented_staff: 7, invented_admins: 11 }.freeze
          @baseline_id = @baseline.object_id
          true
        end

        def initialize
          super
          raise "preflight process or class lost" unless self.class.instance_variable_get(:@hook_pid) == Process.pid &&
                                                       self.class.instance_variable_get(:@hook_class).equal?(self.class)
          @observations = self.class.instance_variable_get(:@baseline)
          raise "preflight snapshot lost" unless @observations.object_id == self.class.instance_variable_get(:@baseline_id)
        end

        def start
          raise "copy process changed" unless self.class.instance_variable_get(:@hook_pid) == Process.pid
          raise "copy snapshot changed" unless @observations.equal?(self.class.instance_variable_get(:@baseline))
          super
          self.class.instance_variable_set(:@copy_finished, true)
        end

        def self.silo_merge_postflight!
          raise "postflight process or class lost" unless @hook_pid == Process.pid && @hook_class.equal?(self)
          raise "postflight snapshot changed" unless @baseline.object_id == @baseline_id &&
                                                    @baseline == { invented_staff: 7, invented_admins: 11 }
          raise "postflight preceded copying" unless @copy_finished
          puts "EVENT:shared-process-and-snapshot"
          true
        end
      end
    RUBY
    result = run_merge(layer: layer)
    assert result.status.success?, result.err
    assert_empty result.err
    assert_equal 1, events(result).count('EVENT:shared-process-and-snapshot')
    assert_operator events(result).index('EVENT:copy'), :<, events(result).index('EVENT:shared-process-and-snapshot')
    assert_equal 'SILO_MERGE: done', result.out.lines.last.chomp
    assert_untouched(result, SITE)
  end

  def test_stock_value_is_kept_while_copying_and_the_prior_state_is_back_before_postflight
    [SITE, AUTH_PRESENT].each do |db|
      result = run_merge(db: db, layer: checked_layer)
      assert result.status.success?, result.err
      assert_includes events(result), 'EVENT:copy-sees=jpg|jpeg|png|gif'
      prior = db.key?('authorized_extensions') ? 'pdf|txt|PRIVATE-EXT' : 'jpg|jpeg|png|gif|heic|heif|webp|avif'
      assert_includes events(result), "EVENT:postflight-sees=#{prior}"
      # Absence is absence again; a present override has its exact raw value and type back.
      assert_untouched(result, db)
      assert_equal({ 'version' => 1, 'state' => 'clean', 'restoration_failed' => [], 'unexpected_names' => [],
                     'remaining_differences' => 0, 'effective_matches' => true }, result.report)
      assert_no_private_values(result)
    end
  end

  def test_a_prior_row_already_holding_the_stock_value_is_never_rewritten
    db = SITE.merge('authorized_extensions' => ['jpg|jpeg|png|gif', 8])
    result = run_merge(db: db, layer: checked_layer)
    assert result.status.success?, result.err
    assert_untouched(result, db)
  end

  def test_missing_or_unbound_snapshot_refuses_before_rails_or_layer
    Dir.mktmpdir do |dir|
      good = File.join(dir, 'good.json')
      File.write(good, '{"version":1}')
      malformed = File.join(dir, 'bad.json')
      File.write(malformed, '{"version":1,"settings":[]}')
      cases = {
        'snapshot-digest-missing' => { 'TEST_SNAPSHOT_FILE' => good, 'SILO_MERGE_SITE_SETTINGS_SHA256' => nil },
        'snapshot-missing' => { 'TEST_SNAPSHOT_FILE' => File.join(dir, 'absent'), 'SILO_MERGE_SITE_SETTINGS_SHA256' => 'a' * 64 },
        'snapshot-digest-mismatch' => { 'TEST_SNAPSHOT_FILE' => good, 'SILO_MERGE_SITE_SETTINGS_SHA256' => 'a' * 64 },
        'snapshot-invalid' => { 'TEST_SNAPSHOT_FILE' => malformed,
                                'SILO_MERGE_SITE_SETTINGS_SHA256' => Digest::SHA256.file(malformed).hexdigest }
      }
      cases.each do |tag, env|
        [true, false].each do |required|
          result = run_merge(layer: checked_layer("puts 'EVENT:layer-loaded'"), required: required, snapshot: env)
          assert_equal 4, result.status.exitstatus, tag
          assert_equal "SILO_MERGE: settings #{tag}\n", result.err
          assert_empty events(result)
          refute_includes result.out, 'SILO_MERGE: done'
        end
      end
    end
  end

  def test_a_snapshot_that_no_longer_matches_the_site_refuses_before_the_layer_loads
    result = run_merge(layer: checked_layer, env: { 'TEST_DB_JSON' => JSON.generate(SITE.merge('title' => ['other', 1])) })
    assert_equal 4, result.status.exitstatus
    assert_includes result.err, 'SILO_MERGE: settings changed-before-layer'
    assert_empty events(result)
    assert_equal ['title'], result.report['unexpected_names']
    assert_no_private_values(result)
  end

  def test_settings_written_while_loading_the_layer_or_in_preflight_are_refused
    writes = {
      'changed-by-layer-load' => ["SiteSetting.authorized_extensions = 'jpg|jpeg|png|gif'", ''],
      'changed-by-preflight' => ['', "SiteSetting.authorized_extensions = 'jpg|jpeg|png|gif'"]
    }
    writes.each do |tag, (at_load, in_preflight)|
      layer = <<~RUBY
        #{at_load}
        class InventedLayer < BulkImport::DiscourseMerger
          def self.silo_merge_preflight!
            #{in_preflight}
            true
          end
          def self.silo_merge_postflight!; true; end
        end
      RUBY
      [SITE, AUTH_PRESENT].each do |db|
        result = run_merge(db: db, layer: layer)
        assert_equal 4, result.status.exitstatus
        assert_includes result.err, "SILO_MERGE: settings #{tag}"
        refute_includes result.out, 'EVENT:constructor'
        # Even the stock value is refused there; it is put back, nothing else is touched.
        assert_untouched(result, db)
        assert_equal 'restored', result.report['state']
      end
    end
  end

  def test_another_setting_changed_by_a_layer_is_refused_and_left_as_found
    hooks = {
      'changed-by-preflight' => ["def self.silo_merge_preflight!; SiteSetting.write_other('title', 'PRIVATE-NEW'); true; end", false],
      'changed-by-constructor' => ["def initialize; super; SiteSetting.write_other('brand_new', 'PRIVATE-NEW'); end", true],
      'changed-during-copy' => ["def start; super; SiteSetting.write_other('title', 'PRIVATE-NEW'); end", true],
      'changed-by-postflight' => ["def self.silo_merge_postflight!; SiteSetting.write_other('title', 'PRIVATE-NEW'); true; end", true]
    }
    hooks.each do |tag, (body, constructed)|
      layer = <<~RUBY
        class InventedLayer < BulkImport::DiscourseMerger
          def self.silo_merge_preflight!; true; end
          def self.silo_merge_postflight!; true; end
          #{body}
        end
      RUBY
      result = run_merge(db: AUTH_PRESENT, layer: layer)
      assert_equal 4, result.status.exitstatus, tag
      assert_includes result.err, "SILO_MERGE: settings #{tag}"
      assert_includes result.err, 'SILO_MERGE: settings restore-unproven'
      refute_includes result.out, 'SILO_MERGE: done'
      assert_equal constructed, result.out.include?('EVENT:constructor'), tag
      changed = tag == 'changed-by-constructor' ? 'brand_new' : 'title'
      assert_equal 'PRIVATE-NEW', result.db.dig(changed, 0), 'never repaired'
      # The allowed setting is back exactly; the report names the other one, never values.
      assert_equal ['pdf|txt|PRIVATE-EXT', 8], result.db['authorized_extensions']
      assert_equal({ 'version' => 1, 'state' => 'unproven', 'restoration_failed' => [], 'unexpected_names' => [changed],
                     'remaining_differences' => 1, 'effective_matches' => true }, result.report)
      assert_no_private_values(result)
    end
  end

  def test_a_constructor_value_other_than_the_stock_one_is_refused_and_restored
    layer = checked_layer("def initialize; super; SiteSetting.authorized_extensions = 'exe'; end")
    [SITE, AUTH_PRESENT].each do |db|
      result = run_merge(db: db, layer: layer)
      assert_equal 4, result.status.exitstatus
      assert_includes result.err, 'SILO_MERGE: settings changed-by-constructor'
      refute_includes result.out, 'EVENT:copy'
      assert_untouched(result, db)
      assert_equal 'restored', result.report['state']
    end
  end

  def test_constructor_failure_before_or_after_the_assignment_is_restored_and_not_done
    %w[before after].each do |point|
      [SITE, AUTH_PRESENT].each do |db|
        result = run_merge(db: db, layer: checked_layer, env: { 'TEST_CONSTRUCTOR_FAIL' => point })
        assert_equal 1, result.status.exitstatus
        assert_equal "SILO_MERGE: merger failed (RuntimeError)\n", result.err
        refute_includes result.out, 'EVENT:copy'
        refute_includes result.out, 'SILO_MERGE: done'
        assert_untouched(result, db)
        assert_equal 'restored', result.report['state']
        assert_no_private_values(result)
      end
    end
  end

  def test_a_failed_copy_prints_the_class_only_and_still_restores
    { '1' => 'ArgumentError', 'schema' => 'PG::UndefinedColumn',
      'wrapped' => 'ActiveRecord::StatementInvalid caused by PG::UndefinedColumn' }.each do |mode, klass|
      [SITE, AUTH_PRESENT].each do |db|
        result = run_merge(db: db, layer: checked_layer, env: { 'TEST_START_FAIL' => mode })
        assert_equal 1, result.status.exitstatus
        # The host's schema classifier still sees the class name.
        assert_equal "SILO_MERGE: merger failed (#{klass})\n", result.err
        refute_includes result.out, 'EVENT:postflight'
        refute_includes result.out, 'SILO_MERGE: done'
        assert_equal 'SILO_SETTINGS_REPORT:', result.out.lines.last[0, 21]
        assert_untouched(result, db)
        assert_equal 'restored', result.report['state']
        assert_no_private_values(result)
      end
    end
  end

  def test_a_failed_copy_whose_restore_also_fails_stays_private_and_unproven
    result = run_merge(db: AUTH_PRESENT, layer: checked_layer, env: { 'TEST_START_FAIL' => '1', 'TEST_FAIL_RESTORE' => '1' })
    assert_equal 1, result.status.exitstatus
    assert_equal "SILO_MERGE: merger failed (ArgumentError)\nSILO_MERGE: settings restore-unproven\n", result.err
    refute_includes result.out, 'SILO_MERGE: done'
    assert_equal 'unproven', result.report['state']
    assert_equal ['authorized_extensions'], result.report['restoration_failed']
    assert_no_private_values(result)
  end

  def test_a_stock_file_that_fails_to_load_is_a_private_failure
    result = run_merge(db: AUTH_PRESENT, layer: checked_layer, env: { 'TEST_STOCK_LOAD_FAIL' => '1' })
    assert_equal 1, result.status.exitstatus
    assert_equal "SILO_MERGE: merger failed (LoadError)\n", result.err
    assert_empty events(result)
    refute_includes result.out, 'SILO_MERGE: done'
    assert_equal 'restored', result.report['state']
    assert_untouched(result, AUTH_PRESENT)
    assert_no_private_values(result)
  end

  def test_restoring_puts_the_exact_raw_value_back_even_when_the_setter_normalises
    %w[value type].each do |normalised|
      result = run_merge(db: AUTH_PRESENT, layer: checked_layer, env: { 'TEST_NORMALIZE' => normalised })
      assert result.status.success?, result.err
      assert_untouched(result, AUTH_PRESENT)
    end
  end

  def test_the_stock_window_needs_the_exact_stock_value_and_type
    layer = checked_layer(<<~RUBY)
      def initialize
        super
        SiteSetting.provider.save('authorized_extensions', 'jpg|jpeg|png|gif', 9)
      end
    RUBY
    [SITE, AUTH_PRESENT].each do |db|
      result = run_merge(db: db, layer: layer)
      assert_equal 4, result.status.exitstatus
      assert_includes result.err, 'SILO_MERGE: settings changed-by-constructor'
      refute_includes result.out, 'EVENT:copy'
      assert_untouched(result, db)
      assert_equal 'restored', result.report['state']
    end
  end

  # The checks read the table, not ActiveRecord's query cache: here the cache is warm from the
  # earlier checks and a write through another connection never clears it.
  def test_writes_that_bypass_the_query_cache_are_still_seen
    { "SiteSetting.write_raw('title', 'PRIVATE-RAW', 1)" => ['title'],
      "SiteSetting.write_raw('authorized_extensions', 'exe', 8)" => [] }.each do |write, unexpected|
      result = run_merge(db: AUTH_PRESENT, layer: checked_layer("def start; super; #{write}; end"))
      assert_equal 4, result.status.exitstatus, write
      assert_includes result.err, 'SILO_MERGE: settings changed-during-copy'
      refute_includes result.out, 'EVENT:postflight'
      assert_equal unexpected, result.report['unexpected_names']
      assert_equal ['pdf|txt|PRIVATE-EXT', 8], result.db['authorized_extensions']
      assert_equal unexpected.empty?, result.report['state'] == 'restored'
      assert_no_private_values(result)
    end
  end

  def test_one_report_and_done_reach_real_stdout_even_when_a_layer_swaps_stdout
    result = run_merge(layer: checked_layer("def start; super; require %q[stringio]; $stdout = StringIO.new; end"))
    assert result.status.success?, result.err
    assert_equal 1, result.out.lines.count { |line| line.start_with?('SILO_SETTINGS_REPORT:') }
    assert_equal ['SILO_MERGE: done'], result.out.lines.map(&:chomp).last(1)
    assert result.out.lines[-2].start_with?('SILO_SETTINGS_REPORT:')
  end

  def test_a_failed_restore_never_claims_done
    [SITE, AUTH_PRESENT].each do |db|
      result = run_merge(db: db, layer: checked_layer, env: { 'TEST_FAIL_RESTORE' => '1' })
      assert_equal 4, result.status.exitstatus
      assert_includes result.err, 'SILO_MERGE: settings restore-unproven'
      refute_includes result.out, 'EVENT:postflight'
      refute_includes result.out, 'SILO_MERGE: done'
      assert_equal 'unproven', result.report['state']
      assert_equal ['authorized_extensions'], result.report['restoration_failed']
      assert_no_private_values(result)
    end
  end

  def test_leaving_early_with_status_zero_is_a_failure_and_still_restores
    result = run_merge(db: AUTH_PRESENT, layer: checked_layer('def start; super; exit 0; end'))
    assert_equal 4, result.status.exitstatus
    assert_includes result.err, 'SILO_MERGE: settings early-exit'
    refute_includes result.out, 'SILO_MERGE: done'
    assert_untouched(result, AUTH_PRESENT)
  end

  def test_missing_checks_fail_before_constructor
    [nil, "class InventedLayer < BulkImport::DiscourseMerger; end\n"].each do |layer|
      result = run_merge(layer: layer)
      assert_equal 3, result.status.exitstatus
      refute_includes result.out, 'EVENT:constructor'
      assert_includes result.err, 'layer must define'
      assert_untouched(result, SITE)
    end
  end

  def test_failed_preflight_and_postflight_never_claim_done_or_print_values
    [:silo_merge_preflight!, :silo_merge_postflight!].each do |failed|
      layer = <<~RUBY
        class InventedLayer < BulkImport::DiscourseMerger
          def self.silo_merge_preflight!; true; end
          def self.silo_merge_postflight!; true; end
          def self.#{failed}; raise 'PRIVATE-POLICY-VALUE'; end
        end
      RUBY
      result = run_merge(db: AUTH_PRESENT, layer: layer)
      assert_equal 3, result.status.exitstatus
      refute_includes result.out, 'SILO_MERGE: done'
      assert_includes result.err, 'layer policy check failed (RuntimeError)'
      assert_equal failed == :silo_merge_postflight!, result.out.include?('EVENT:copy')
      assert_untouched(result, AUTH_PRESENT)
      assert_no_private_values(result)
    end
  end

  def test_exit_zero_in_a_check_is_a_refusal_not_success
    [:silo_merge_preflight!, :silo_merge_postflight!].each do |failed|
      layer = <<~RUBY
        class InventedLayer < BulkImport::DiscourseMerger
          def self.silo_merge_preflight!; true; end
          def self.silo_merge_postflight!; true; end
          def self.#{failed}; exit 0; end
        end
      RUBY
      result = run_merge(layer: layer)
      assert_equal 3, result.status.exitstatus
      assert_includes result.err, 'layer policy check failed (SystemExit)'
      refute_includes result.out, 'SILO_MERGE: done'
      assert_equal failed == :silo_merge_postflight!, result.out.include?('EVENT:constructor')
    end
  end

  def test_instance_methods_do_not_satisfy_the_class_contract
    result = run_merge(layer: <<~RUBY)
      class InventedLayer < BulkImport::DiscourseMerger
        def silo_merge_preflight!; true; end
        def silo_merge_postflight!; true; end
      end
    RUBY
    assert_equal 3, result.status.exitstatus
    assert_includes result.err, 'layer must define'
    refute_includes result.out, 'EVENT:constructor'
  end

  def test_only_explicit_true_passes
    result = run_merge(layer: <<~RUBY)
      class InventedLayer < BulkImport::DiscourseMerger
        def self.silo_merge_preflight!; nil; end
        def self.silo_merge_postflight!; true; end
      end
    RUBY
    assert_equal 3, result.status.exitstatus
    refute_includes result.out, 'EVENT:constructor'
    assert_includes result.err, 'layer policy check failed'
  end

  def test_legacy_stock_and_layer_keep_prior_behavior_and_are_protected_too
    [nil, "class InventedLayer < BulkImport::DiscourseMerger; end\n"].each do |layer|
      [SITE, AUTH_PRESENT].each do |db|
        result = run_merge(db: db, layer: layer, required: false)
        assert result.status.success?, result.err
        assert_empty result.err
        assert_includes result.out, 'EVENT:copy'
        assert_equal 'SILO_MERGE: done', result.out.lines.last.chomp
        assert_untouched(result, db)
      end
    end
  end
end
