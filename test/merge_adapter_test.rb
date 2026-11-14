# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require "pathname"
require_relative "../runtime/shared/merge_assets"
require_relative "../runtime/prebuilt-discourse/merge_adapter"

# Load the exact full public script normally; its temporary base is test-only.
# There is no eval and no runtime adapter exception for fixtures/project paths.
PINNED_FIXTURE = File.expand_path("support/pinned_discourse_merger.rb", __dir__)
METHOD_FIXTURE = File.expand_path("support/stock_copy_uploads_fixture.rb", __dir__)
FIXTURE_ROOT = Dir.mktmpdir("pinned-stock-fixture-")
FIXTURE = File.join(FIXTURE_ROOT, "discourse_merger.rb")
FileUtils.cp(PINNED_FIXTURE, FIXTURE)
File.write(File.join(FIXTURE_ROOT, "base.rb"), "module BulkImport; class Base; end; end\n")
require FIXTURE
Minitest.after_run { FileUtils.remove_entry(FIXTURE_ROOT) }

module BulkImport
  class DiscourseMerger
    attr_reader :inserted, :sequences

    def initialize(root, rows)
      self.class.constructions += 1
      @uploads_path, @source_rows = root, rows.map(&:dup)
      @uploads, @sequences, @inserted = {}, {}, []
      @raw_connection = self
    end

    class << self
      attr_accessor :constructions
    end

    def copy_data(*)
      yield
    end

    def source_raw_connection
      self
    end

    def exec(*)
      @source_rows
    end

    def put_copy_data(values)
      @inserted << Upload.columns.map(&:name).zip(values).to_h
    end

    def user_id_from_imported_id(id)
      { 10 => 110 }[id]
    end

  end
end

class Upload
  class << self
    attr_accessor :rows

    def columns
      %w[id sha1 url filesize user_id original_sha1 secure].map { |name| Struct.new(:name).new(name) }
    end

    def unscoped
      self
    end

    def maximum(*)
      rows.map { |row| row["id"] }.max
    end

    def where
      self
    end

    def not(*)
      self
    end

    def pluck(*keys)
      rows.map { |row| keys.map { |key| row[key.to_s] } }
    end

    def sequence_name
      "uploads_id_seq"
    end
  end
end

module Rails
  class << self
    attr_accessor :public_path
  end
end

class MergeAdapterTest < Minitest::Test
  Adapter = SiloDiscourseMergeAdapter

  def setup
    @stock_path = Adapter::STOCK_PATH
    Adapter.send(:remove_const, :STOCK_PATH)
    Adapter.const_set(:STOCK_PATH, FIXTURE)
    @workspace = Dir.mktmpdir("invented-adapter-")
    @source = File.join(@workspace, "source")
    @destination = File.join(@workspace, "public", "uploads", "default")
    FileUtils.mkdir_p([@source, @destination])
    Rails.public_path = Pathname.new(File.join(@workspace, "public"))
    Upload.rows = []
    @klass = Class.new(BulkImport::DiscourseMerger)
    @klass.constructions = 0
  end

  def teardown
    FileUtils.remove_entry(@workspace)
    Adapter.send(:remove_const, :STOCK_PATH)
    Adapter.const_set(:STOCK_PATH, @stock_path)
  end

  def row(id, path = "original/#{id}.png", body: "image #{id}", user: 10, identity: nil, original_sha1: nil, secure: false)
    { "id" => id, "sha1" => identity || Digest::SHA1.hexdigest(body), "url" => "/uploads/source/#{path}",
      "filesize" => body.bytesize, "user_id" => user, "original_sha1" => original_sha1, "secure" => secure }
  end

  def write(root, path, body)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.binwrite(File.join(root, path), body)
  end

  def source_row(id, **options)
    result = row(id, **options)
    write(@source, result["url"].sub("/uploads/source/", ""), options.fetch(:body, "image #{id}"))
    result
  end

  def prepare(rows, ids = rows.map { |r| r["id"] }, **options)
    Adapter.prepare!(@klass, source_rows: rows, destination_rows: Upload.rows, approved_ids: ids,
                     policy: "carried", source_root: @source, destination_root: @destination,
                     **options)
  end

  def run_stock(instance)
    capture_io { instance.copy_uploads }
    Upload.rows + instance.inserted
  end

  def refusal(tag = nil, &block)
    error = assert_raises(Adapter::Error, &block)
    assert_equal tag, error.tag if tag
    assert_equal error.tag, error.message
    assert_nil error.cause
    error
  end

  def test_shipped_method_is_exact_fixture_with_only_copy_line_changed
    stock = File.binread(METHOD_FIXTURE)
    assert_equal Adapter::FILE_SHA256, Digest::SHA256.file(PINNED_FIXTURE).hexdigest
    assert_equal Adapter::METHOD_SHA256, Digest::SHA256.hexdigest(stock)
    file, line = Adapter::DeferredUploads.instance_method(:copy_uploads).source_location
    lines = File.readlines(file)
    shipped = lines[(line - 1), stock.lines.size].join
    assert_equal stock.sub(Adapter::COPY_LINE, "    @silo_uploads_deferred = (@silo_uploads_deferred || 0) + 1"), shipped
    cached = File.expand_path("../../../.runtime-cache/generic-merge-20261114/discourse_merger-2769139d.rb", __dir__)
    if File.file?(cached)
      assert_equal Adapter::FILE_SHA256, Digest::SHA256.file(cached).hexdigest
      source = File.binread(cached)
      assert_equal stock, source[source.index("  def copy_uploads\n")...source.index("  def copy_upload_references\n")]
    end
  end

  def test_deferred_copy_happens_after_map_and_only_on_chosen_subclass
    rows = [source_row(1)]
    global_copy = FileUtils.method(:cp_r)
    global_method = BulkImport::DiscourseMerger.instance_method(:copy_uploads)
    context = prepare(rows)
    assert_empty Dir.children(@destination)
    instance = @klass.new(@source, rows)
    refusal("copy_not_deferred") { context.transfer!(instance, destination_rows: []) }
    actual = run_stock(instance)
    assert_empty Dir.children(@destination)
    assert_equal 2, instance.upload_id_from_imported_id(1)
    result = context.transfer!(instance, destination_rows: actual)
    assert_equal "image 1", File.binread(File.join(@destination, "original/1.png"))
    assert_equal({ copied: 1, reused: 0, skipped_by_policy: 0, upload_rows_inserted: 1, upload_rows_skipped: 0 }, result[:aggregates])
    assert_equal global_copy, FileUtils.method(:cp_r)
    assert_equal global_method, BulkImport::DiscourseMerger.instance_method(:copy_uploads)
    assert_equal global_method, Class.new(BulkImport::DiscourseMerger).instance_method(:copy_uploads)
  end

  def test_stock_row_map_owner_url_and_sequence_equivalence
    rows = [source_row(1), source_row(2, user: 999), source_row(3, user: 0), row(4), row(5)]
    Upload.rows = [row(50, body: "image 4")]
    write(@destination, "original/50.png", "image 4")
    context = prepare(rows, [1, 3, 4])
    adapted = @klass.new(@source, rows)
    adapted_rows = run_stock(adapted)
    original_class = Class.new(BulkImport::DiscourseMerger)
    original_class.constructions = 0
    original = original_class.new(@source, rows)
    run_stock(original)
    assert_equal original.inserted, adapted.inserted
    assert_equal original.instance_variable_get(:@uploads), adapted.instance_variable_get(:@uploads)
    assert_equal original.sequences, adapted.sequences
    assert_equal [110, 0, 110], adapted.inserted.map { |r| r["user_id"] }
    assert_equal ["/uploads/default/original/1.png", "/uploads/default/original/3.png", "/uploads/source/original/5.png"], adapted.inserted.map { |r| r["url"] }
    result = context.transfer!(adapted, destination_rows: adapted_rows)
    assert_equal 3, result[:aggregates][:upload_rows_inserted]
    assert_equal "reuse", result[:manifest]["entries"].find { |entry| entry["key"] == "upload:4" }["disposition"]
  end

  def test_known_stock_s3_prefix_is_normalized_without_changing_row_logic
    source = source_row(1).merge("url" => "//bucket.amazonaws.com/site/uploads/source/original/1.png")
    context = prepare([source])
    instance = @klass.new(@source, [source])
    actual = run_stock(instance)
    assert_equal "/uploads/default/original/1.png", instance.inserted.first["url"]
    result = context.transfer!(instance, destination_rows: actual)
    assert_equal "original/1.png", result[:manifest]["entries"].first["source"]
    assert_equal 1, result[:aggregates][:copied]
  end

  def test_carried_pm_exclusions_do_not_change_row_import_or_copy_excluded_files
    rows = [source_row(1), source_row(2)]
    context = prepare(rows, [1])
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    assert_equal 2, instance.inserted.size
    result = context.transfer!(instance, destination_rows: actual)
    assert File.file?(File.join(@destination, "original/1.png"))
    refute File.exist?(File.join(@destination, "original/2.png"))
    assert_equal [true, false], result[:manifest]["entries"].map { |e| e["required"] }
    assert_equal 1, result[:aggregates][:skipped_by_policy]
  end

  def test_missing_required_source_refuses_before_construction
    refusal("missing_required_asset") { prepare([row(1)]) }
    assert_equal 0, @klass.constructions
    assert_empty Dir.children(@destination)
  end

  def test_missing_source_requires_actual_verified_destination_upload_not_just_file
    write(@destination, "original/1.png", "image 1")
    refusal("missing_required_asset") { prepare([row(1)]) }
  end

  def test_missing_source_can_reuse_verified_dedup_destination_path
    Upload.rows = [row(8, body: "image 1")]
    write(@destination, "original/8.png", "image 1")
    rows = [row(1)]
    context = prepare(rows)
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    assert_empty instance.inserted
    assert_equal "original/8.png", result[:manifest]["entries"].first["destination"]
    assert_equal 1, result[:aggregates][:reused]
    assert_equal 0, result[:aggregates][:upload_rows_inserted]
  end

  def test_corrupt_destination_reuse_and_corrupt_source_both_refuse
    Upload.rows = [row(8, body: "image 1")]
    write(@destination, "original/8.png", "wrong")
    refusal("asset_validation_failed") { prepare([row(1)]) }
    write(@destination, "original/8.png", "image 1")
    write(@source, "original/1.png", "wrong")
    refusal("asset_validation_failed") { prepare([row(1)]) }
  end

  def test_mapping_to_skipped_user_without_destination_row_is_not_evidence
    rows = [source_row(1, user: 999)]
    context = prepare(rows)
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    assert_equal 2, instance.upload_id_from_imported_id(1)
    refusal("missing_mapping") { context.transfer!(instance, destination_rows: actual) }
    assert_empty Dir.children(@destination)
  end

  def test_mapping_metadata_and_missing_map_refuse
    rows = [source_row(1)]
    context = prepare(rows)
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    wrong = actual.map { |r| r.merge("sha1" => "0" * 40) }
    refusal("missing_mapping") { context.transfer!(instance, destination_rows: wrong) }
    instance.instance_variable_set(:@uploads, {})
    refusal("missing_mapping") { context.transfer!(instance, destination_rows: actual) }
  end

  def test_selected_backup_entries_use_verified_target_sha256
    rows = [source_row(1), row(2)]
    Upload.rows = [row(8, body: "image 2")]
    write(@destination, "original/8.png", "image 2")
    context = prepare(rows)
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    entries = result[:manifest]["entries"]
    assert_equal %w[copy reuse], entries.map { |entry| entry["disposition"] }
    entries.each do |entry|
      assert_equal({ "algorithm" => "sha256", "value" => Digest::SHA256.file(File.join(@destination, entry["destination"])).hexdigest }, entry["digest"])
    end
    assert SiloMergeAssets.verify!(result[:manifest], destination_root: @destination)
  end

  def test_excluded_path_preserves_different_baseline_bytes_with_separate_full_baseline_evidence
    rows = [source_row(1), source_row(2)]
    write(@destination, "original/2.png", "original baseline")
    context = prepare(rows, [1])
    assert_equal "original baseline", File.binread(File.join(@destination, "original/2.png"))
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    excluded = result[:manifest]["entries"].find { |entry| entry["disposition"] == "exclude" }
    baseline = result[:manifest]["entries"].find { |entry| entry["key"].start_with?("baseline:") }
    assert_equal({ "algorithm" => "sha256", "value" => Digest::SHA256.hexdigest("image 2") }, excluded["digest"])
    assert_equal "original/2.png", baseline["source"]
    assert_equal excluded["destination"], baseline["destination"]
    assert_equal "reuse", baseline["disposition"]
    assert baseline["required"]
    assert_equal({ "algorithm" => "sha256", "value" => Digest::SHA256.hexdigest("original baseline") }, baseline["digest"])
    assert_equal "original baseline".bytesize, baseline["bytes"]
    assert_equal "original baseline", File.binread(File.join(@destination, "original/2.png"))
    assert_equal 1, result[:aggregates][:copied]
    assert_equal 1, result[:aggregates][:reused]
    assert_equal 0, result[:aggregates][:skipped_by_policy]
    assert SiloMergeAssets.verify!(result[:manifest], destination_root: @destination)
  end

  def test_changed_or_removed_baseline_refuses_before_any_physical_copy
    [:changed, :removed].each do |change|
      @klass = Class.new(BulkImport::DiscourseMerger)
      @klass.constructions = 0
      rows = [source_row(1), source_row(2)]
      write(@destination, "original/2.png", "original baseline")
      context = prepare(rows, [1])
      instance = @klass.new(@source, rows)
      actual = run_stock(instance)
      path = File.join(@destination, "original/2.png")
      change == :changed ? File.binwrite(path, "tampered baseline") : File.unlink(path)
      refusal("asset_validation_failed") { context.transfer!(instance, destination_rows: actual) }
      refute File.exist?(File.join(@destination, "original/1.png"))
    end
  end

  def test_excluded_baseline_and_selected_dedup_target_can_share_identical_bytes
    rows = [source_row(1), source_row(2)]
    Upload.rows = [row(8, "original/2.png", body: "image 1")]
    write(@destination, "original/2.png", "image 1")
    context = prepare(rows, [1])
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    selected = result[:manifest]["entries"].reject { |entry| entry["disposition"] == "exclude" }
    assert_equal 2, selected.size
    assert_equal 1, selected.map { |entry| entry["destination"] }.uniq.size
    assert_equal 1, selected.map { |entry| entry["digest"] }.uniq.size
    assert_equal "image 1", File.binread(File.join(@destination, "original/2.png"))
    assert_equal 0, result[:aggregates][:copied]
    assert_equal 1, result[:aggregates][:reused]
    assert_equal 1, result[:aggregates][:skipped_by_policy]
    assert SiloMergeAssets.verify!(result[:manifest], destination_root: @destination)
  end

  def test_conflicting_selected_and_excluded_baseline_bytes_refuse_before_constructor
    required = source_row(1)
    excluded = row(2, "original/1.png")
    write(@destination, "original/1.png", "different baseline bytes")
    refusal("asset_validation_failed") { prepare([required, excluded], [1]) }
    assert_equal 0, @klass.constructions
    assert_equal "different baseline bytes", File.binread(File.join(@destination, "original/1.png"))
  end

  def test_preflight_manifest_digest_binds_excluded_baseline_content
    rows = [source_row(1), source_row(2)]
    write(@destination, "original/2.png", "baseline before")
    first = prepare(rows, [1])
    @klass = Class.new(BulkImport::DiscourseMerger)
    write(@destination, "original/2.png", "baseline after")
    second = prepare(rows, [1])
    assert_equal first.selection_digest, second.selection_digest
    refute_equal first.preflight_manifest_digest, second.preflight_manifest_digest
  end

  def test_all_policy_includes_orphan_and_optimized_files_after_map
    rows = [source_row(1)]
    write(@source, "optimized/orphan.png", "optimized")
    write(@source, "original/orphan.png", "orphan")
    context = prepare(rows, policy: "all")
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    assert_empty Dir.children(@destination)
    result = context.transfer!(instance, destination_rows: actual)
    assert_equal 3, result[:aggregates][:copied]
    assert_equal %w[optimized/orphan.png original/1.png original/orphan.png], result[:manifest]["entries"].map { |e| e["destination"] }.sort
  end

  def test_all_preserves_original_source_file_even_when_row_deduplicates_elsewhere
    rows = [source_row(1)]
    Upload.rows = [row(8, body: "image 1")]
    write(@destination, "original/8.png", "image 1")
    context = prepare(rows, policy: "all")
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    assert_equal 1, result[:aggregates][:copied]
    assert_equal 1, result[:aggregates][:reused]
    assert_equal "image 1", File.binread(File.join(@destination, "original/1.png"))
  end

  def test_missing_target_symlink_components_and_source_root_symlinks_refuse
    Upload.rows = [row(8, body: "image 1")]
    write(@destination, "original/8.png", "image 1")
    File.symlink(File.join(@workspace, "missing"), File.join(@source, "original"))
    refusal("unsafe_source_tree") { prepare([row(1)]) }
    File.unlink(File.join(@source, "original"))
    root_link = File.join(@workspace, "root-link")
    File.symlink(@source, root_link)
    refusal("asset_validation_failed") { prepare([], [], source_root: root_link) }
  end

  def test_all_policy_rejects_symlink_even_unselected
    File.symlink("/not-an-asset", File.join(@source, "link"))
    refusal("unsafe_source_tree") { prepare([], [], policy: "all") }
  end

  def test_unsafe_urls_metadata_and_duplicate_ids_refuse
    ["/uploads/../bad", "/uploads/%2e%2e/bad", "/uploads/source/../bad", "/uploads/source/%2e%2e/bad", "https://elsewhere/file", "/uploads/source//bad"].each do |url|
      refusal("unsafe_url") { prepare([row(1).merge("url" => url)]) }
    end
    refusal("invalid_ids") { prepare([], [0]) }
    refusal("invalid_ids") { prepare([], [1, 1]) }
    refusal("invalid_ids") { prepare([], Array.new(100_001, 1)) }
    refusal("invalid_rows") { prepare([row(1), row(1)]) }
    refusal("invalid_rows") { prepare([row(1).merge("sha1" => nil)]) }
    refusal("invalid_rows") { prepare([row(1).merge("filesize" => -1)]) }
    refusal("missing_source_row") { prepare([], [1]) }
    assert_equal 0, @klass.constructions
  end

  def test_unknown_stock_and_all_layer_hook_overrides_refuse_before_construction
    %i[copy_uploads upload_id_from_imported_id fix_user_upload].each do |hook|
      @klass = Class.new(BulkImport::DiscourseMerger)
      @klass.constructions = 0
      @klass.define_method(hook) {}
      refusal("unsupported_stock") { prepare([]) }
      assert_equal 0, @klass.constructions
    end
    @klass = Class.new(BulkImport::DiscourseMerger)
    @klass.constructions = 0
    unknown = File.join(@workspace, "unknown.rb")
    original = File.binread(FIXTURE)
    begin
      File.binwrite(FIXTURE, original + "# changed\n")
      refusal("unsupported_stock") { prepare([]) }
    ensure
      File.binwrite(FIXTURE, original)
    end
    assert_raises(ArgumentError) { prepare([], stock_path: unknown) }
    assert_equal 0, @klass.constructions
  end

  def test_public_media_modes_are_readable_under_private_umask
    rows = [source_row(1)]
    context = prepare(rows)
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    previous = File.umask(0o077)
    begin
      context.transfer!(instance, destination_rows: actual)
    ensure
      File.umask(previous)
    end
    assert_equal 0o644, File.stat(File.join(@destination, "original/1.png")).mode & 0o777
    assert_equal 0o755, File.stat(File.join(@destination, "original")).mode & 0o777
    assert_equal Process.uid, File.stat(File.join(@destination, "original/1.png")).uid
  end

  def test_all_copies_optional_skipped_owner_files_and_tolerates_missing_optional_files
    rows = [source_row(1), source_row(2, user: 999), row(3, user: 999), row(4)]
    context = prepare(rows, [1], policy: "all")
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    result = context.transfer!(instance, destination_rows: actual)
    optional = result[:manifest]["entries"].find { |entry| entry["key"] == "upload:2" }
    assert_equal "copy", optional["disposition"]
    refute optional["required"]
    assert_equal "original/2.png", optional["destination"]
    assert_equal "image 2", File.binread(File.join(@destination, "original/2.png"))
    refute result[:manifest]["entries"].any? { |entry| ["original/3.png", "original/4.png"].include?(entry["destination"]) }
    assert_equal 2, result[:aggregates][:upload_rows_skipped]
    assert_equal 2, result[:aggregates][:copied]
    assert_equal 0, result[:aggregates][:skipped_by_policy]
    assert_equal [2], context.approved_destination_ids(instance)
    assert_equal [5], context.excluded_inserted_ids(instance)
  end

  def test_required_skipped_owner_mapping_remains_fatal_in_all
    rows = [source_row(1, user: 999)]
    context = prepare(rows, policy: "all")
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    refusal("missing_mapping") { context.transfer!(instance, destination_rows: actual) }
    assert_empty Dir.children(@destination)
  end

  def test_carried_inventory_excludes_all_source_only_orphans_and_preserves_baseline_orphans
    rows = [source_row(1)]
    write(@source, "original/orphan.png", "source orphan")
    write(@source, "original/another.png", "another orphan")
    write(@destination, "original/orphan.png", "baseline orphan")
    context = prepare(rows)
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    exclusions = result[:manifest]["entries"].select { |entry| entry["disposition"] == "exclude" }
    assert_equal %w[original/another.png original/orphan.png], exclusions.map { |entry| entry["destination"] }.sort
    assert_equal 1, result[:aggregates][:skipped_by_policy]
    assert_equal 1, result[:aggregates][:reused]
    refute File.exist?(File.join(@destination, "original/another.png"))
    baseline = result[:manifest]["entries"].find { |entry| entry["key"].start_with?("baseline:") }
    assert_equal Digest::SHA256.hexdigest("baseline orphan"), baseline["digest"]["value"]
    assert_equal "baseline orphan", File.binread(File.join(@destination, "original/orphan.png"))
  end

  def test_unclassified_optimized_files_fail_closed_before_constructor_in_carried
    rows = [source_row(1)]
    write(@source, "optimized/1X/derivative.png", "derived bytes")
    refusal("optimized_classification_unproven") { prepare(rows) }
    assert_equal 0, @klass.constructions
    assert_empty Dir.children(@destination)
  end

  def test_nonpositive_source_ids_are_explicitly_unsupported_before_constructor
    [0, -1].each do |id|
      refusal("unsupported_source_id") { prepare([row(id)], []) }
    end
    assert_equal 0, @klass.constructions
  end

  def test_postflight_id_accessors_require_mapping_verification_and_do_not_include_baseline_dedup
    rows = [source_row(1), source_row(2), source_row(3, user: 999), row(4)]
    Upload.rows = [row(20, body: "image 4")]
    write(@destination, "original/20.png", "image 4")
    context = prepare(rows, [1, 4])
    instance = @klass.new(@source, rows)
    refusal("mapping_not_verified") { context.approved_destination_ids(instance) }
    refusal("mapping_not_verified") { context.excluded_inserted_ids(instance) }
    actual = run_stock(instance)
    assert context.verify_mapping!(instance, destination_rows: actual)
    assert_empty Dir.glob(File.join(@destination, "original/1.png"))
    assert_equal [23], context.dangling_destination_ids(instance)
    assert_equal [20, 21], context.approved_destination_ids(instance)
    assert_equal [22], context.excluded_inserted_ids(instance)
    ids = context.approved_destination_ids(instance)
    ids.clear
    assert_equal [20, 21], context.approved_destination_ids(instance)
    refusal("mapping_not_verified") { context.approved_destination_ids(Object.new) }
  end

  def test_full_method_only_file_is_not_a_supported_runtime_and_hook_location_pins_are_enforced
    original = File.binread(FIXTURE)
    begin
      File.binwrite(FIXTURE, File.binread(METHOD_FIXTURE))
      refusal("unsupported_stock") { prepare([]) }
    ensure
      File.binwrite(FIXTURE, original)
    end
    %i[upload_id_from_imported_id fix_user_upload].each do |hook|
      stock = BulkImport::DiscourseMerger.instance_method(hook)
      begin
        BulkImport::DiscourseMerger.define_method(hook) {}
        refusal("unsupported_stock") { prepare([]) }
      ensure
        BulkImport::DiscourseMerger.define_method(hook, stock)
      end
    end
    assert_equal 0, @klass.constructions
  end

  def test_secure_source_identity_is_not_treated_as_content_digest
    rows = [source_row(1, identity: "a" * 40, original_sha1: Digest::SHA1.hexdigest("image 1"), secure: true)]
    context = prepare(rows)
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    assert_equal "a" * 40, instance.inserted.first["sha1"]
    assert_equal Digest::SHA256.hexdigest("image 1"), result[:manifest]["entries"].first["digest"]["value"]
    assert_equal "image 1", File.binread(File.join(@destination, "original/1.png"))
  end

  def test_secure_destination_reuse_validates_original_sha1_and_source_actual_bytes
    identity = "b" * 40
    real = Digest::SHA1.hexdigest("image 1")
    rows = [source_row(1, identity: identity, original_sha1: real, secure: true)]
    Upload.rows = [row(8, body: "image 1", identity: identity, original_sha1: real, secure: true)]
    write(@destination, "original/8.png", "image 1")
    context = prepare(rows)
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    assert_empty instance.inserted
    assert_equal 8, instance.upload_id_from_imported_id(1)
    assert_equal Digest::SHA256.hexdigest("image 1"), result[:manifest]["entries"].first["digest"]["value"]
    assert_equal 1, result[:aggregates][:reused]
  end

  def test_missing_secure_source_can_reuse_verified_original_sha1_bytes
    identity = "c" * 40
    real = Digest::SHA1.hexdigest("image 1")
    rows = [row(1, identity: identity, original_sha1: real, secure: true)]
    Upload.rows = [row(8, body: "image 1", identity: identity, original_sha1: real, secure: true)]
    write(@destination, "original/8.png", "image 1")
    context = prepare(rows)
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    assert_equal 1, result[:aggregates][:reused]
    assert_equal Digest::SHA256.hexdigest("image 1"), result[:manifest]["entries"].first["digest"]["value"]
  end

  def test_unverifiable_fake_identities_refuse_explicitly_before_constructor
    rows = [source_row(1, identity: "d" * 40)]
    refusal("unsupported_content_identity") { prepare(rows) }
    File.unlink(File.join(@source, "original/1.png"))
    Upload.rows = [row(8, body: "image 1", identity: "d" * 40, secure: true)]
    write(@destination, "original/8.png", "image 1")
    refusal("unsupported_content_identity") { prepare([row(1, identity: "d" * 40, secure: true)]) }
    assert_equal 0, @klass.constructions
  end

  def test_secure_original_digest_mismatches_and_dedup_byte_mismatches_refuse
    real = Digest::SHA1.hexdigest("image 1")
    rows = [source_row(1, identity: "e" * 40, original_sha1: real, secure: true)]
    Upload.rows = [row(8, body: "image 1", identity: "e" * 40, original_sha1: "0" * 40, secure: true)]
    write(@destination, "original/8.png", "image 1")
    refusal("asset_validation_failed") { prepare(rows) }
    Upload.rows = [row(8, body: "image 9", identity: "e" * 40, original_sha1: Digest::SHA1.hexdigest("image 9"), secure: true)]
    write(@destination, "original/8.png", "image 9")
    refusal("asset_validation_failed") { prepare(rows) }
    Upload.rows = []
    refusal("asset_validation_failed") { prepare([rows.first.merge("original_sha1" => "0" * 40)]) }
    assert_equal 0, @klass.constructions
  end

  def test_file_counts_ignore_missing_optional_rows_and_deduplicate_shared_paths
    shared = source_row(2, body: "shared")
    duplicate = row(3, "original/2.png", body: "shared")
    rows = [source_row(1), shared, duplicate, row(4), row(5)]
    write(@source, "original/orphan.png", "orphan")
    # A destination-only path is not a skipped source file or source obligation.
    write(@destination, "original/4.png", "destination only")
    context = prepare(rows, [1])
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    assert_equal 5, instance.inserted.size
    assert_equal 1, result[:aggregates][:copied]
    assert_equal 2, result[:aggregates][:skipped_by_policy]
    exclusions = result[:manifest]["entries"].select { |entry| entry["disposition"] == "exclude" }
    assert_equal %w[original/2.png original/orphan.png], exclusions.map { |entry| entry["destination"] }.uniq.sort
    refute result[:manifest]["entries"].any? { |entry| ["original/4.png", "original/5.png"].include?(entry["destination"]) }
    assert_equal "destination only", File.binread(File.join(@destination, "original/4.png"))
    assert_equal 0, result[:aggregates][:reused]
  end

  def test_all_counts_only_existing_files_with_duplicate_rows_and_missing_optional_paths
    shared = source_row(1, body: "shared")
    duplicate = row(2, "original/1.png", body: "shared", user: 999)
    rows = [shared, duplicate, row(3), row(4, user: 999)]
    context = prepare(rows, [], policy: "all")
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    assert_equal 1, result[:aggregates][:copied]
    assert_equal 0, result[:aggregates][:reused]
    assert_equal 0, result[:aggregates][:skipped_by_policy]
    assert_equal 2, result[:aggregates][:upload_rows_skipped]
    assert_equal ["original/1.png"], result[:manifest]["entries"].map { |entry| entry["destination"] }.uniq
  end

  def test_excluded_file_evidence_uses_actual_inventory_not_fake_row_identity_or_size
    excluded = source_row(2, identity: "f" * 40).merge("filesize" => 99)
    rows = [source_row(1), excluded]
    context = prepare(rows, [1])
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    entry = result[:manifest]["entries"].find { |item| item["disposition"] == "exclude" }
    assert_equal "image 2".bytesize, entry["bytes"]
    assert_equal({ "algorithm" => "sha256", "value" => Digest::SHA256.hexdigest("image 2") }, entry["digest"])
    assert_equal 1, result[:aggregates][:skipped_by_policy]
    refute File.exist?(File.join(@destination, "original/2.png"))
  end

  def test_partial_shared_transfer_counts_are_preserved_without_private_error_text
    rows = [source_row(1)]
    context = prepare(rows)
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    partial = { copied: 1, reused: 2, skipped_by_policy: 3, private_path: "/private/file" }
    failure = lambda do |*args, **options|
      assert_equal 0o644, options[:file_mode]
      assert_equal 0o755, options[:directory_mode]
      raise SiloMergeAssets::Error.new("private_io_reason", counts: partial)
    end
    SiloMergeAssets.stub(:transfer!, failure) do
      error = refusal("asset_validation_failed") { context.transfer!(instance, destination_rows: actual) }
      assert_equal({ copied: 1, reused: 2, skipped_by_policy: 3 }, error.counts)
      assert error.counts.frozen?
      refute_includes error.message, "private_io_reason"
      refute_includes error.message, "/private/file"
    end
    assert_equal [2], context.approved_destination_ids(instance)
  end

  def test_failed_post_copy_verification_keeps_actual_completed_counts_without_revoking_mapping_proof
    rows = [source_row(1)]
    context = prepare(rows)
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    original_transfer = SiloMergeAssets.method(:transfer!)
    original_verify = SiloMergeAssets.method(:verify!)
    completed = false
    transfer = lambda do |*args, **options|
      counts = original_transfer.call(*args, **options)
      completed = true
      counts
    end
    verify = lambda do |*args, **options|
      raise SiloMergeAssets::Error.new("private_verification_failure") if completed
      original_verify.call(*args, **options)
    end
    SiloMergeAssets.stub(:transfer!, transfer) do
      SiloMergeAssets.stub(:verify!, verify) do
        error = refusal("asset_validation_failed") { context.transfer!(instance, destination_rows: actual) }
        assert_equal({ copied: 1, reused: 0, skipped_by_policy: 0 }, error.counts)
        assert_equal "image 1", File.binread(File.join(@destination, "original/1.png"))
      end
    end
    assert_equal [2], context.approved_destination_ids(instance)
  end

  def test_partial_counts_accept_only_fixed_nonnegative_integer_fields
    assert_nil Adapter::Error.new("refused", counts: { copied: -1, reused: 0, skipped_by_policy: 0 }).counts
    assert_nil Adapter::Error.new("refused", counts: { copied: "1", reused: 0, skipped_by_policy: 0 }).counts
    assert_nil Adapter::Error.new("refused", counts: { copied: 1 }).counts
    assert_nil Adapter::Error.new("refused").counts
  end

  def test_unknown_missing_source_fake_identity_without_secure_flag_is_explicitly_unsupported
    Upload.rows = [row(8, body: "image 1", identity: "f" * 40)]
    write(@destination, "original/8.png", "image 1")
    refusal("unsupported_content_identity") { prepare([row(1, identity: "f" * 40)]) }
    assert_equal 0, @klass.constructions
  end

  def test_mapping_verification_is_metadata_only_and_exposes_optional_dangling_ids_before_copy
    rows = [source_row(1), source_row(2), source_row(3, user: 999)]
    context = prepare(rows, [1])
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    assert_empty Dir.children(@destination)
    # The metadata phase must still work when neither filesystem is available.
    FileUtils.remove_entry(@source)
    FileUtils.remove_entry(@destination)
    assert context.verify_mapping!(instance, destination_rows: actual)
    assert_equal [2], context.approved_destination_ids(instance)
    assert_equal [3], context.excluded_inserted_ids(instance)
    assert_equal [4], context.dangling_destination_ids(instance)
    assert_equal [3, 4], (context.excluded_inserted_ids(instance) + context.dangling_destination_ids(instance)).sort
    dangling = context.dangling_destination_ids(instance)
    dangling.clear
    assert_equal [4], context.dangling_destination_ids(instance)
    refute File.exist?(@destination)
  end

  def test_invalid_raw_mapping_keys_values_and_required_targets_refuse_without_destination_mutation
    rows = [source_row(1)]
    context = prepare(rows)
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    [{ "1" => 2 }, { 1 => "2" }, { 1 => nil }, { 1 => -1 }, { 0 => 2 }, { 99 => 2 }, {}, []].each do |mapping|
      instance.instance_variable_set(:@uploads, mapping)
      refusal("missing_mapping") { context.verify_mapping!(instance, destination_rows: actual) }
      refusal("mapping_not_verified") { context.approved_destination_ids(instance) }
      assert_empty Dir.children(@destination)
    end
    instance.instance_variable_set(:@uploads, { 1 => 99 })
    refusal("missing_mapping") { context.verify_mapping!(instance, destination_rows: actual) }
    assert_empty Dir.children(@destination)
    instance.instance_variable_set(:@uploads, { 1 => 2 })
    wrong_identity = actual.map { |row| row.merge("sha1" => "0" * 40) }
    refusal("missing_mapping") { context.verify_mapping!(instance, destination_rows: wrong_identity) }
    assert_empty Dir.children(@destination)
  end

  def test_mapping_accessors_are_invalidated_by_map_mutation_and_failed_reverification
    rows = [source_row(1), source_row(2, user: 999)]
    context = prepare(rows, [1])
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    context.verify_mapping!(instance, destination_rows: actual)
    assert_equal [3], context.dangling_destination_ids(instance)
    instance.instance_variable_get(:@uploads)[2] = 99
    refusal("mapping_not_verified") { context.dangling_destination_ids(instance) }
    context.verify_mapping!(instance, destination_rows: actual)
    assert_equal [99], context.dangling_destination_ids(instance)
    refusal("missing_mapping") { context.verify_mapping!(instance, destination_rows: []) }
    refusal("mapping_not_verified") { context.approved_destination_ids(instance) }
    refusal("mapping_not_verified") { context.dangling_destination_ids(nil) }
    assert_empty Dir.children(@destination)
  end

  def test_missing_destination_root_preflight_is_read_only_and_transfer_creates_public_directories
    rows = [source_row(1)]
    FileUtils.remove_entry(File.join(@workspace, "public"))
    context = prepare(rows)
    refute File.exist?(@destination)
    instance = @klass.new(@source, rows)
    actual = run_stock(instance)
    refute File.exist?(@destination)
    context.verify_mapping!(instance, destination_rows: actual)
    refute File.exist?(@destination)
    result = context.transfer!(instance, destination_rows: actual)
    assert_equal 1, result[:aggregates][:copied]
    assert_equal "image 1", File.binread(File.join(@destination, "original/1.png"))
    assert_equal 0o755, File.stat(@destination).mode & 0o777
    assert_equal 0o644, File.stat(File.join(@destination, "original/1.png")).mode & 0o777
  end

  def test_empty_sql_only_destination_does_not_require_or_create_upload_directories
    FileUtils.remove_entry(File.join(@workspace, "public"))
    context = prepare([])
    instance = @klass.new(@source, [])
    actual = run_stock(instance)
    assert context.verify_mapping!(instance, destination_rows: actual)
    assert_empty context.dangling_destination_ids(instance)
    result = context.transfer!(instance, destination_rows: actual)
    assert_empty result[:manifest]["entries"]
    assert_equal 0, result[:aggregates][:copied]
    assert_equal 0, result[:aggregates][:reused]
    refute File.exist?(@destination)
  end

  def test_missing_destination_option_does_not_allow_symlinked_ancestor
    rows = [source_row(1)]
    FileUtils.remove_entry(File.join(@workspace, "public"))
    actual_root = File.join(@workspace, "actual-public")
    Dir.mkdir(actual_root)
    File.symlink(actual_root, File.join(@workspace, "public"))
    refusal("asset_validation_failed") { prepare(rows) }
    assert_equal 0, @klass.constructions
    assert_empty Dir.children(actual_root)
  end

  def test_complete_baseline_original_changes_bind_preflight_receipt_but_not_source_selection
    rows = [source_row(1)]
    write(@destination, "original/unrelated.png", "baseline before")
    first = prepare(rows)
    assert_equal 0, @klass.constructions
    assert first.baseline_inventory.frozen?
    assert first.baseline_inventory.fetch("files").frozen?
    assert_equal 1, first.baseline_inventory.fetch("files").size
    @klass = Class.new(BulkImport::DiscourseMerger)
    @klass.constructions = 0
    write(@destination, "original/unrelated.png", "baseline after")
    second = prepare(rows)
    assert_equal 0, @klass.constructions
    assert_equal first.selection_digest, second.selection_digest
    refute_equal first.preflight_manifest_digest, second.preflight_manifest_digest
    assert_equal SiloDiscourseBaselineAssets.capture(@destination), second.baseline_inventory
    assert_raises(FrozenError) { first.baseline_inventory["version"] = 99 }
    first.baseline_inventory.fetch("files").each do |file|
      assert file.frozen?
      assert file.fetch("path").frozen?
      assert file.fetch("sha256").frozen?
      assert_raises(FrozenError) { file["bytes"] = 0 }
    end
  end

  def test_complete_baseline_inventory_refuses_unrelated_symlink_before_constructor
    rows = [source_row(1)]
    File.symlink("/not-an-asset", File.join(@destination, "unrelated-link"))
    refusal("baseline_validation_failed") { prepare(rows) }
    assert_equal 0, @klass.constructions
    refute File.exist?(File.join(@destination, "original/1.png"))
  end

  def test_baseline_optimized_files_are_counted_without_original_byte_obligations
    rows = [source_row(1)]
    write(@destination, "original/baseline.png", "baseline original")
    write(@destination, "optimized/1X/cache.png", "regenerable cache")
    context = prepare(rows)
    inventory = context.baseline_inventory
    assert_equal 1, inventory.fetch("derived_files")
    assert_equal ["original/baseline.png"], inventory.fetch("files").map { |file| file.fetch("path") }
    assert_equal SiloDiscourseBaselineAssets.capture(@destination), inventory
    assert_equal 0, @klass.constructions
    instance = @klass.new(@source, rows)
    result = context.transfer!(instance, destination_rows: run_stock(instance))
    refute result[:manifest]["entries"].any? { |entry| entry["destination"] == "original/baseline.png" || entry["destination"].start_with?("optimized/") }
    assert_equal 1, result[:aggregates][:copied]
    expected = Digest::SHA256.hexdigest(JSON.generate([result[:manifest], SiloDiscourseBaselineAssets.digest(inventory)]))
    assert_equal expected, context.preflight_manifest_digest
  end

  def test_receipt_digests_are_stable_under_row_and_approval_order_and_bind_metadata
    rows = [source_row(1), source_row(2)]
    first = prepare(rows)
    @klass = Class.new(BulkImport::DiscourseMerger)
    second = prepare(rows.reverse, [2, 1])
    assert_match(/\A[0-9a-f]{64}\z/, first.selection_digest)
    assert_equal first.selection_digest, second.selection_digest
    assert_equal first.preflight_manifest_digest, second.preflight_manifest_digest
    @klass = Class.new(BulkImport::DiscourseMerger)
    third = prepare(rows, [1])
    refute_equal first.selection_digest, third.selection_digest
    refute_equal first.preflight_manifest_digest, third.preflight_manifest_digest
  end
end
