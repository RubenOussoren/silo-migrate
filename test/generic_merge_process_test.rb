# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/silo_migrate/merge_process"
require_relative "../runtime/shared/merge_contract"
require_relative "../runtime/shared/merge_assets"

class GenericMergeProcessTest < SiloMigrateTest
  # Deliberately not a supported migration engine: it has record keys and asset
  # blobs, no categories, uploads table, site settings or Discourse backup layout.
  class ToyRecords
    def describe = { "engine" => "toy-records-v1", "version" => 1 }
    def validate(context)
      { "valid" => true, "binding" => SiloMergeContract.validate_settings!(context.fetch(:contract), context.fetch(:settings)) }
    end
    def verify_output(context, manifest)
      manifest.fetch("entries").all? do |entry|
        key = "blobs/#{entry.fetch('destination')}"
        entry["disposition"] == "exclude" ? !context.fetch(:members).key?(key) : context.fetch(:members)[key] == entry.fetch("digest").fetch("value")
      end
    end
  end

  def contract(engine)
    SiloMergeContract.load(JSON.generate({
      "version" => 1, "engine" => engine,
      "settings_schema" => { "type" => "object", "additionalProperties" => false,
        "required" => ["asset_mode"], "properties" => { "asset_mode" => { "type" => "string", "enum" => ["selected"] } } },
      "asset_policy_key" => "asset_mode", "asset_policies" => { "selected" => "carried" },
      "audit_aggregates" => { "preflight" => ["records_selected"], "postflight" => ["records_verified"] }
    }))
  end

  def test_same_gates_transfer_and_evidence_support_unrelated_adapter
    registry = SiloMigrate::MergeProcess.registry.register("toy-records-v1", ToyRecords.new)
    gate = SiloMigrate::MergeProcess::Gate.new(registry)
    %w[discourse-merger-v1 toy-records-v1].each do |engine|
      schema = contract(engine)
      checked = gate.validate(engine: engine, context: { contract: schema, settings: { "asset_mode" => "selected" } })
      assert_equal "carried", checked.fetch("binding").fetch("physical_policy")
      Dir.mktmpdir do |dir|
        source, target = %w[source destination].map { |name| File.join(dir, name) }
        [source, target].each { |path| Dir.mkdir(path, 0o700) }
        File.write(File.join(source, "kept.bin"), "invented carried record")
        File.write(File.join(source, "omitted.bin"), "invented excluded record")
        entries = %w[kept.bin omitted.bin].map.with_index do |name, index|
          bytes = File.binread(File.join(source, name))
          { "key" => "record-#{index}", "source" => name, "destination" => name,
            "digest" => { "algorithm" => "sha256", "value" => Digest::SHA256.hexdigest(bytes) }, "bytes" => bytes.bytesize,
            "disposition" => index.zero? ? "copy" : "exclude", "required" => index.zero? }
        end
        manifest = { "version" => 1, "policy" => "carried", "entries" => entries }
        counts = SiloMergeAssets.transfer!(manifest, source_root: source, destination_root: target)
        assert_equal({ copied: 1, reused: 0, skipped_by_policy: 1 }, counts)
        refute File.exist?(File.join(target, "omitted.bin"))
        prefix = engine == "toy-records-v1" ? "blobs/" : "uploads/default/"
        members = { "#{prefix}kept.bin" => entries.first.fetch("digest").fetch("value") }
        context = engine == "toy-records-v1" ? { members: members } : { upload_sha256: members,
          baseline_assets: { "version" => 1, "files" => [], "derived_files" => 0 } }
        assert gate.verify_output(engine: engine, context: context, manifest: manifest)
        members["#{prefix}omitted.bin"] = entries.last.fetch("digest").fetch("value")
        assert_raises(SiloMigrate::MergeProcess::Refused) { gate.verify_output(engine: engine, context: context, manifest: manifest) }
        evidence = SiloMigrate::MergeProcess::Evidence.new(engine: engine).record("transfer", counts: counts.transform_keys(&:to_s), complete: true)
        assert_equal true, evidence.document.dig("phases", "transfer", "complete")
      end
    end
  end

  def test_engine_output_gate_preserves_unrelated_baseline_originals
    gate = SiloMigrate::MergeProcess::Gate.new(SiloMigrate::MergeProcess.registry)
    baseline = { "version" => 1, "files" => [{ "path" => "original/baseline.bin", "sha256" => Digest::SHA256.hexdigest("baseline"), "bytes" => 8 }], "derived_files" => 2 }
    manifest = { "version" => 1, "policy" => "carried", "entries" => [] }
    members = { "uploads/default/original/baseline.bin" => Digest::SHA256.hexdigest("baseline") }
    context = { upload_sha256: members, baseline_assets: baseline }
    assert gate.verify_output(engine: "discourse-merger-v1", context: context, manifest: manifest)
    members.clear
    assert_raises(SiloMigrate::MergeProcess::Refused) { gate.verify_output(engine: "discourse-merger-v1", context: context, manifest: manifest) }
  end

  def test_unknown_engine_and_invalid_registration_are_not_project_capabilities
    registry = SiloMigrate::MergeProcess.registry
    assert_raises(SiloMigrate::MergeProcess::Refused) { registry.fetch("unimplemented-v1") }
    assert_raises(SiloMigrate::MergeProcess::Refused) { registry.register("fake-v1", Object.new) }
    assert_raises(SiloMigrate::MergeProcess::Refused) { registry.register("discourse-merger-v1", ToyRecords.new) }
  end

  def test_evidence_counts_have_no_arbitrary_values_or_release_flags
    evidence = SiloMigrate::MergeProcess::Evidence.new(engine: "toy-records-v1")
    assert_raises(SiloMigrate::MergeProcess::Refused) { evidence.record("transfer", counts: { "customer_name" => "private" }, complete: false) }
    assert_raises(SiloMigrate::MergeProcess::Refused) { evidence.record("transfer", counts: { "copied" => -1 }, complete: false) }
    assert_raises(SiloMigrate::MergeProcess::Refused) { evidence.record("unknown", counts: {}, complete: false) }
    refute evidence.document.key?("visibility")
  end
end
