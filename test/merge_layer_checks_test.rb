# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class MergeLayerChecksTest < SiloMigrateTest
  SCRIPT = File.expand_path('../runtime/prebuilt-discourse/merge_run.rb', __dir__)
  HARNESS = <<~RUBY
    module PG
      def self.connect(*args, **kwargs); end
    end
    module BulkImport
      class DiscourseMerger
        def initialize
          puts 'EVENT:constructor'
        end
        def start
          puts 'EVENT:copy'
        end
      end
    end
    module Kernel
      alias silo_original_require require
      def require(path)
        return true if path == 'pg' || path == '/var/www/discourse/script/bulk_import/discourse_merger.rb'
        silo_original_require(path)
      end
    end
  RUBY

  def invoke(layer: nil, required: true)
    Dir.mktmpdir('merge-policy-') do |dir|
      harness = File.join(dir, 'harness.rb')
      File.write(harness, HARNESS)
      env = { 'DB_NAME' => 'merge_source', 'SILO_MERGE_REQUIRE_CHECKS' => required ? '1' : nil, 'SILO_MERGE_LAYER' => nil }
      if layer
        entry = File.join(dir, 'layer.rb')
        File.write(entry, layer)
        env['SILO_MERGE_LAYER'] = entry
      end
      Open3.capture3(env, RbConfig.ruby, '-r', harness, SCRIPT)
    end
  end

  def test_required_checks_run_before_constructor_and_after_copy
    out, err, status = invoke(layer: <<~RUBY)
      class InventedLayer < BulkImport::DiscourseMerger
        def self.silo_merge_preflight!
          puts 'EVENT:preflight'
          true
        end
        def self.silo_merge_postflight!
          puts 'EVENT:postflight'
          true
        end
      end
    RUBY
    assert status.success?, err
    assert_empty err
    assert_equal %w[EVENT:preflight EVENT:constructor EVENT:copy EVENT:postflight], out.lines.map(&:strip).grep(/^EVENT:/)
    assert_includes out, 'SILO_MERGE: done'
  end

  def test_missing_checks_fail_before_constructor
    [nil, "class InventedLayer < BulkImport::DiscourseMerger; end\n"].each do |layer|
      out, err, status = invoke(layer: layer)
      assert_equal 3, status.exitstatus
      refute_includes out, 'EVENT:constructor'
      refute_includes out, 'EVENT:copy'
      assert_includes err, 'layer must define'
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
      out, err, status = invoke(layer: layer)
      assert_equal 3, status.exitstatus
      refute_includes out, 'SILO_MERGE: done'
      refute_includes out + err, 'PRIVATE-POLICY-VALUE'
      assert_includes err, 'layer policy check failed (RuntimeError)'
      assert_equal failed == :silo_merge_postflight!, out.include?('EVENT:copy')
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
      out, err, status = invoke(layer: layer)
      assert_equal 3, status.exitstatus
      assert_includes err, 'layer policy check failed (SystemExit)'
      refute_includes out, 'SILO_MERGE: done'
      assert_equal failed == :silo_merge_postflight!, out.include?('EVENT:constructor')
    end
  end

  def test_instance_methods_do_not_satisfy_the_class_contract
    out, err, status = invoke(layer: <<~RUBY)
      class InventedLayer < BulkImport::DiscourseMerger
        def silo_merge_preflight!; true; end
        def silo_merge_postflight!; true; end
      end
    RUBY
    assert_equal 3, status.exitstatus
    assert_includes err, 'layer must define'
    refute_includes out, 'EVENT:constructor'
  end

  def test_only_explicit_true_passes
    out, err, status = invoke(layer: <<~RUBY)
      class InventedLayer < BulkImport::DiscourseMerger
        def self.silo_merge_preflight!; nil; end
        def self.silo_merge_postflight!; true; end
      end
    RUBY
    assert_equal 3, status.exitstatus
    refute_includes out, 'EVENT:constructor'
    assert_includes err, 'layer policy check failed'
  end

  def test_legacy_stock_and_layer_keep_prior_behavior
    [nil, "class InventedLayer < BulkImport::DiscourseMerger; end\n"].each do |layer|
      out, err, status = invoke(layer: layer, required: false)
      assert status.success?, err
      assert_empty err
      assert_includes out, 'EVENT:copy'
      assert_includes out, 'SILO_MERGE: done'
    end
  end
end
