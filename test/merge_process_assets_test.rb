# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../runtime/shared/merge_assets"

class MergeProcessAssetsTest < Minitest::Test
  def setup
    @workspace = Dir.mktmpdir("invented-assets-")
    @source = File.join(@workspace, "source")
    @destination = File.join(@workspace, "destination")
    Dir.mkdir(@source)
    Dir.mkdir(@destination)
  end

  def teardown
    FileUtils.remove_entry(@workspace)
  end

  def entry(key, path = key, body: "toy bytes", disposition: "copy", required: true, algorithm: "sha256")
    { "key" => key, "source" => path, "destination" => path,
      "digest" => { "algorithm" => algorithm, "value" => Digest.const_get(algorithm.upcase).hexdigest(body) },
      "bytes" => body.bytesize, "disposition" => disposition, "required" => required }
  end

  def manifest(*entries, policy: "carried")
    { "version" => 1, "policy" => policy, "entries" => entries }
  end

  def write(root, path, body = "toy bytes")
    target = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.binwrite(target, body)
    target
  end

  def transfer(data, **options)
    SiloMergeAssets.transfer!(data, source_root: @source, destination_root: @destination, **options)
  end

  def preflight(data, **options)
    SiloMergeAssets.preflight!(data, source_root: @source, destination_root: @destination, **options)
  end

  def assert_refusal(tag)
    error = assert_raises(SiloMergeAssets::Error) { yield }
    assert_equal tag, error.tag
    assert_equal tag, error.message
    assert_nil error.cause
    error
  end

  def test_generic_toy_record_adapter_and_thousands_file_selection
    # Deliberately unrelated record vocabulary; selection is adapter-owned.
    records = 2_100.times.map { |n| { serial: n, published: n.even?, blob: "shelf/#{n}.bin" } }
    entries = records.map do |record|
      write(@source, record[:blob], "artifact #{record[:serial]}")
      entry("record-#{record[:serial]}", record[:blob], body: "artifact #{record[:serial]}",
            disposition: record[:published] ? "copy" : "exclude", required: record[:published])
    end
    data = manifest(*entries)
    expected = { copied: 1_050, reused: 0, skipped_by_policy: 1_050 }
    assert_equal expected, preflight(data)
    assert_empty Dir.children(@destination)
    assert_equal expected, transfer(data)
    assert_equal 1_050, Dir.glob(File.join(@destination, "**", "*.bin")).size
    records.each do |record|
      assert_equal record[:published], File.exist?(File.join(@destination, record[:blob]))
    end
    assert_equal({ copied: 0, reused: 1_050, skipped_by_policy: 1_050 },
                 SiloMergeAssets.verify!(data, destination_root: @destination))
  end

  def test_deduplication_streaming_sha1_sha256_and_private_modes
    body = "abcd" * 40_000
    write(@source, "one", body)
    a = entry("one", "one", body: body, algorithm: "sha1")
    b = entry("two", "missing", body: body, algorithm: "sha1")
    a["destination"] = b["destination"] = "nested/shared"
    b["digest"]["value"] = b["digest"]["value"].upcase
    c = entry("empty", "empty", body: "")
    write(@source, "empty", "")
    data = manifest(a, b, c, policy: "all")
    assert_equal({ copied: 2, reused: 0, skipped_by_policy: 0 }, transfer(data))
    assert_equal body, File.binread(File.join(@destination, "nested/shared"))
    assert_equal 0o600, File.stat(File.join(@destination, "nested/shared")).mode & 0o777
    assert_equal({ copied: 0, reused: 2, skipped_by_policy: 0 }, transfer(data))
  end

  def test_new_permissions_default_private_and_allow_explicit_public_read
    [[:private, {}, 0o600, 0o700],
     [:public, { file_mode: 0o644, directory_mode: 0o755 }, 0o644, 0o755]].each do |name, options, file_mode, directory_mode|
      path = "#{name}/nested/one"
      write(@source, path)
      previous_umask = File.umask(0o077)
      begin
        transfer(manifest(entry(name.to_s, path)), **options)
      ensure
        File.umask(previous_umask)
      end
      assert_equal file_mode, File.stat(File.join(@destination, path)).mode & 0o777
      [name.to_s, "#{name}/nested"].each do |directory|
        assert_equal directory_mode, File.stat(File.join(@destination, directory)).mode & 0o777
      end
    end
  end

  def test_invalid_permissions_refuse_before_any_mutation
    write(@source, "nested/one")
    [{ file_mode: 0o666 }, { file_mode: 0o777 }, { file_mode: 0o640 },
     { file_mode: 0o4644 }, { file_mode: "0644" }, { file_mode: 0o644.to_f },
     { directory_mode: 0o777 }, { directory_mode: 0o775 },
     { directory_mode: 0o750 }, { directory_mode: nil }, { directory_mode: 0o755.to_f }].each do |options|
      error = assert_refusal("invalid_mode") { transfer(manifest(entry("one", "nested/one")), **options) }
      assert_nil error.counts
      assert_empty Dir.children(@destination)
    end
  end

  def test_existing_modes_are_never_changed_in_either_direction
    Dir.mkdir(File.join(@destination, "existing"), 0o700)
    write(@destination, "existing/reused")
    File.chmod(0o600, File.join(@destination, "existing/reused"))
    write(@source, "existing/new")
    transfer(manifest(entry("reused", "existing/reused", disposition: "reuse"), entry("new", "existing/new")),
             file_mode: 0o644, directory_mode: 0o755)
    assert_equal 0o700, File.stat(File.join(@destination, "existing")).mode & 0o777
    assert_equal 0o600, File.stat(File.join(@destination, "existing/reused")).mode & 0o777
    assert_equal 0o644, File.stat(File.join(@destination, "existing/new")).mode & 0o777
    File.chmod(0o755, File.join(@destination, "existing"))
    File.chmod(0o644, File.join(@destination, "existing/reused"))
    transfer(manifest(entry("reused", "existing/reused")))
    assert_equal 0o755, File.stat(File.join(@destination, "existing")).mode & 0o777
    assert_equal 0o644, File.stat(File.join(@destination, "existing/reused")).mode & 0o777
  end

  def test_public_mode_is_set_only_after_private_streaming_and_before_rename
    write(@source, "one")
    original_open = File.method(:open)
    inspect_stream = lambda do |path, *args, **options, &block|
      if path == File.join(@source, "one")
        Dir.glob(File.join(@destination, ".silo-asset-*.tmp")).each do |temporary|
          assert_equal 0o600, File.stat(temporary).mode & 0o777
        end
      end
      original_open.call(path, *args, **options, &block)
    end
    original_rename = File.method(:rename)
    inspect_rename = lambda do |from, to|
      assert_equal 0o644, File.stat(from).mode & 0o777
      original_rename.call(from, to)
    end
    File.stub(:open, inspect_stream) do
      File.stub(:rename, inspect_rename) do
        transfer(manifest(entry("one")), file_mode: 0o644, directory_mode: 0o755)
      end
    end
  end

  def test_missing_destination_preflight_is_read_only_then_transfer_creates_public_tree
    @destination = File.join(@workspace, "uncreated", "uploads", "default")
    write(@source, "nested/one")
    data = manifest(entry("one", "nested/one"))
    expected = { copied: 1, reused: 0, skipped_by_policy: 0 }
    assert_equal expected, preflight(data, allow_missing_destination: true)
    refute File.exist?(File.join(@workspace, "uncreated"))
    ancestor_mode = File.stat(@workspace).mode & 0o777
    previous_umask = File.umask(0o077)
    begin
      assert_equal expected, transfer(data, allow_missing_destination: true, file_mode: 0o644, directory_mode: 0o755)
    ensure
      File.umask(previous_umask)
    end
    %w[uncreated uncreated/uploads uncreated/uploads/default uncreated/uploads/default/nested].each do |path|
      assert_equal 0o755, File.stat(File.join(@workspace, path)).mode & 0o777
    end
    assert_equal ancestor_mode, File.stat(@workspace).mode & 0o777
    assert_equal 0o644, File.stat(File.join(@destination, "nested/one")).mode & 0o777
    assert_equal "toy bytes", File.binread(File.join(@destination, "nested/one"))
    assert_equal 1, SiloMergeAssets.verify!(data, destination_root: @destination)[:reused]
  end

  def test_missing_destination_uses_private_defaults_and_directory_io_failure_has_progress
    @destination = File.join(@workspace, "new-private", "root")
    write(@source, "one")
    transfer(manifest(entry("one")), allow_missing_destination: true)
    assert_equal 0o700, File.stat(File.join(@workspace, "new-private")).mode & 0o777
    assert_equal 0o700, File.stat(@destination).mode & 0o777
    assert_equal 0o600, File.stat(File.join(@destination, "one")).mode & 0o777
    @destination = File.join(@workspace, "io-failure", "root")
    original = Dir.method(:mkdir)
    replacement = lambda do |path, *args|
      raise Errno::EIO, "private root path" if path == @destination
      original.call(path, *args)
    end
    Dir.stub(:mkdir, replacement) do
      error = assert_refusal("asset_io_failed") { transfer(manifest(entry("one")), allow_missing_destination: true) }
      assert_equal({ copied: 0, reused: 0, skipped_by_policy: 0 }, error.counts)
    end
    assert Dir.exist?(File.join(@workspace, "io-failure"))
    refute File.exist?(@destination)
  end

  def test_missing_destination_required_source_or_reuse_refusal_leaves_entire_root_absent
    @destination = File.join(@workspace, "uncreated", "uploads", "default")
    write(@source, "good")
    [manifest(entry("good"), entry("missing")),
     manifest(entry("good"), entry("reuse", disposition: "reuse"))].each_with_index do |data, index|
      tag = index.zero? ? "missing_source" : "missing_destination"
      assert_refusal(tag) { preflight(data, allow_missing_destination: true) }
      error = assert_refusal(tag) { transfer(data, allow_missing_destination: true) }
      assert_nil error.counts
      refute File.exist?(File.join(@workspace, "uncreated"))
    end
  end

  def test_missing_destination_rejects_symlink_and_non_directory_ancestors
    File.symlink(@destination, File.join(@workspace, "linked"))
    write(@source, "one")
    @destination = File.join(@workspace, "linked", "uncreated")
    assert_refusal("unsafe_file") { preflight(manifest(entry("one")), allow_missing_destination: true) }
    assert_refusal("unsafe_file") { transfer(manifest(entry("one")), allow_missing_destination: true) }
    refute File.exist?(File.join(@workspace, "destination", "uncreated"))
    write(@workspace, "not-directory")
    @destination = File.join(@workspace, "not-directory", "uncreated")
    assert_refusal("unsafe_file") { preflight(manifest(entry("one")), allow_missing_destination: true) }
    @destination = File.join(@workspace, "missing", "..", "elsewhere")
    assert_refusal("unsafe_root") { preflight(manifest(entry("one")), allow_missing_destination: true) }
    refute File.exist?(File.join(@workspace, "missing"))
    refute File.exist?(File.join(@workspace, "elsewhere"))
  end

  def test_missing_destination_flag_is_strict_boolean_and_not_a_manifest_field
    @destination = File.join(@workspace, "uncreated", "root")
    write(@source, "one")
    [nil, 0, 1, "true", "false", [], {}].each do |flag|
      assert_refusal("invalid_option") { preflight(manifest(entry("one")), allow_missing_destination: flag) }
      error = assert_refusal("invalid_option") { transfer(manifest(entry("one")), allow_missing_destination: flag) }
      assert_nil error.counts
      refute File.exist?(File.join(@workspace, "uncreated"))
    end
    data = manifest(entry("one"))
    data["allow_missing_destination"] = true
    assert_refusal("invalid_manifest") { transfer(data, allow_missing_destination: true) }
    refute File.exist?(File.join(@workspace, "uncreated"))
  end

  def test_zero_selected_never_creates_missing_destination_and_verify_remains_strict
    @destination = File.join(@workspace, "uncreated", "root")
    [manifest, manifest(entry("excluded", disposition: "exclude", required: false))].each_with_index do |data, skipped|
      expected = { copied: 0, reused: 0, skipped_by_policy: skipped }
      assert_equal expected, preflight(data, allow_missing_destination: true)
      assert_equal expected, transfer(data, allow_missing_destination: true)
      refute File.exist?(File.join(@workspace, "uncreated"))
      assert_refusal("asset_io_failed") { SiloMergeAssets.verify!(data, destination_root: @destination) }
    end
  end

  def test_missing_destination_default_remains_strict_and_source_cannot_be_missing
    @destination = File.join(@workspace, "uncreated", "root")
    write(@source, "one")
    assert_refusal("asset_io_failed") { preflight(manifest(entry("one"))) }
    assert_refusal("asset_io_failed") { transfer(manifest(entry("one")), allow_missing_destination: false) }
    @source = File.join(@workspace, "missing-source")
    assert_refusal("asset_io_failed") { transfer(manifest, allow_missing_destination: true) }
    refute File.exist?(File.join(@workspace, "uncreated"))
    refute File.exist?(@source)
  end

  def test_existing_destination_resolves_required_copy_without_source
    write(@destination, "one")
    assert_equal 1, transfer(manifest(entry("one")))[:reused]
    data = manifest(entry("one", disposition: "reuse"))
    assert_equal 1, transfer(data)[:reused]
    File.binwrite(File.join(@destination, "one"), "bad bytes")
    assert_refusal("content_mismatch") { transfer(data) }
    assert_refusal("content_mismatch") { SiloMergeAssets.verify!(data, destination_root: @destination) }
  end

  def test_missing_required_and_reuse_refuse_before_mutation
    write(@source, "good")
    assert_refusal("missing_source") { transfer(manifest(entry("good"), entry("missing"))) }
    assert_empty Dir.children(@destination)
    write(@source, "one")
    assert_refusal("missing_destination") { preflight(manifest(entry("one", disposition: "reuse"))) }
    assert_empty Dir.children(@destination)
  end

  def test_whole_manifest_validation_happens_before_copy
    write(@source, "good")
    bad = entry("bad")
    bad["unexpected"] = "private marker"
    assert_refusal("invalid_manifest") { transfer(manifest(entry("good"), bad)) }
    assert_empty Dir.children(@destination)
  end

  def test_schema_is_exact_and_bounded
    mutations = [
      ->(m) { m["extra"] = true }, ->(m) { m["version"] = 2 },
      ->(m) { m["version"] = 1.0 }, ->(m) { m["policy"] = "default" },
      ->(m) { m["entries"] = nil }, ->(m) { m["entries"][0]["digest"]["extra"] = 1 },
      ->(m) { m["entries"][0]["digest"]["algorithm"] = "md5" },
      ->(m) { m["entries"][0]["digest"]["value"] = "z" * 64 },
      ->(m) { m["entries"][0]["bytes"] = -1 }, ->(m) { m["entries"][0]["bytes"] = 1.0 },
      ->(m) { m["entries"][0]["bytes"] = 2**63 }, ->(m) { m["entries"][0]["required"] = "true" },
      ->(m) { m["entries"][0]["key"] = "x" * 1_025 },
      ->(m) { m["entries"][0].delete("required") }
    ]
    mutations.each do |mutate|
      data = manifest(entry("one"))
      mutate.call(data)
      assert_refusal("invalid_manifest") { SiloMergeAssets.validate!(data) }
    end
    assert_refusal("duplicate_key") { SiloMergeAssets.validate!(manifest(entry("one"), entry("one"))) }
    assert_refusal("invalid_manifest") do
      SiloMergeAssets.validate!(manifest(*Array.new(100_001) { entry("x") }))
    end
    assert_refusal("required_excluded") { SiloMergeAssets.validate!(manifest(entry("x", disposition: "exclude"))) }
  end

  def test_unsafe_relative_paths_are_refused_even_when_excluded
    ["", ".", "..", "../escape", "/absolute", "a//b", "a/./b", "a/../b", "a/", "a\\b", "C:/x", "a\n", "a\0", "a\x7f", "x" * 4_097].each do |path|
      %w[source destination].each do |field|
        item = entry("one", disposition: "exclude", required: false)
        item[field] = path
        assert_refusal("unsafe_path") { preflight(manifest(item)) }
      end
    end
  end

  def test_symlink_roots_components_files_and_nonregular_paths
    outside = File.join(@workspace, "outside")
    Dir.mkdir(outside)
    write(outside, "one")
    File.symlink(outside, File.join(@source, "linked"))
    assert_refusal("unsafe_file") { preflight(manifest(entry("x", "linked/one"))) }
    File.symlink(File.join(outside, "one"), File.join(@source, "one"))
    assert_refusal("unsafe_file") { preflight(manifest(entry("one"))) }
    File.symlink(outside, File.join(@destination, "linked"))
    item = entry("one")
    item["destination"] = "linked/one"
    assert_refusal("unsafe_file") { preflight(manifest(item)) }
    File.symlink(File.join(outside, "absent"), File.join(@destination, "one"))
    assert_refusal("unsafe_file") { preflight(manifest(entry("one"))) }
    assert_refusal("unsafe_file") do
      SiloMergeAssets.preflight!(manifest, source_root: File.join(@source, "linked"), destination_root: @destination)
    end
    Dir.mkdir(File.join(@source, "directory"))
    assert_refusal("unsafe_file") { preflight(manifest(entry("directory"))) }
    File.mkfifo(File.join(@source, "fifo"))
    assert_refusal("unsafe_file") { preflight(manifest(entry("fifo"))) }
    assert_equal ["one"], Dir.children(outside)
  end

  def test_conflicts_and_existing_wrong_bytes_never_overwrite
    write(@source, "one")
    write(@destination, "one", "private existing")
    assert_refusal("content_mismatch") { transfer(manifest(entry("one"))) }
    assert_equal "private existing", File.binread(File.join(@destination, "one"))
    a = entry("a", "same")
    b = entry("b", "same", body: "different")
    assert_refusal("destination_conflict") { preflight(manifest(a, b)) }
    assert_refusal("destination_conflict") { preflight(manifest(entry("a", "node"), entry("b", "node/child"))) }
  end

  def test_excluded_paths_are_never_inspected_and_shared_exclusion_is_not_a_second_file
    File.symlink("/does-not-exist", File.join(@destination, "excluded"))
    data = manifest(entry("x", "excluded", disposition: "exclude", required: false))
    assert_equal({ copied: 0, reused: 0, skipped_by_policy: 1 }, transfer(data))
    assert_equal 1, SiloMergeAssets.verify!(data, destination_root: @destination)[:skipped_by_policy]
    write(@source, "selected")
    data = manifest(entry("a", "selected"), entry("b", "selected", disposition: "exclude", required: false))
    assert_equal({ copied: 1, reused: 0, skipped_by_policy: 0 }, transfer(data))
  end

  def test_invalid_encodings_and_root_failures_use_fixed_tags
    ["x\xff".dup.force_encoding(Encoding::UTF_8), "x".encode(Encoding::UTF_16LE)].each do |path|
      item = entry("x")
      item["source"] = path
      assert_refusal("unsafe_path") { preflight(manifest(item)) }
    end
    assert_refusal("unsafe_root") do
      SiloMergeAssets.preflight!(manifest, source_root: "private\0root", destination_root: @destination)
    end
    assert_refusal("asset_io_failed") do
      SiloMergeAssets.preflight!(manifest, source_root: File.join(@workspace, "missing-root"), destination_root: @destination)
    end
  end

  def test_wrong_source_bytes_refuse_all_destination_mutation
    write(@source, "good")
    write(@source, "bad", "wrong contents")
    data = manifest(entry("good"), entry("bad"))
    assert_refusal("content_mismatch") { preflight(data) }
    assert_refusal("content_mismatch") { transfer(data) }
    assert_empty Dir.children(@destination)
    assert_refusal("missing_destination") do
      SiloMergeAssets.verify!(manifest(entry("absent")), destination_root: @destination)
    end
  end

  def test_third_copy_failure_exposes_frozen_typed_progress_without_paths
    %w[one two three].each { |path| write(@source, path) }
    write(@destination, "reused")
    data = manifest(entry("reused", disposition: "reuse"), entry("one"), entry("two"), entry("three"),
                    entry("excluded", disposition: "exclude", required: false))
    original = File.method(:rename)
    attempts = 0
    replacement = lambda do |from, to|
      attempts += 1
      raise Errno::EIO, "private third path" if attempts == 3
      original.call(from, to)
    end
    error = nil
    File.stub(:rename, replacement) do
      error = assert_refusal("asset_io_failed") { transfer(data, file_mode: 0o644, directory_mode: 0o755) }
    end
    assert_equal({ copied: 2, reused: 1, skipped_by_policy: 1 }, error.counts)
    assert error.counts.frozen?
    assert error.counts.values.all? { |value| value.is_a?(Integer) && value >= 0 }
    assert_equal %w[one reused two], Dir.children(@destination).sort
  end

  def test_preflight_refusal_has_no_success_counts
    error = assert_refusal("missing_source") { transfer(manifest(entry("missing"))) }
    assert_nil error.counts
    assert_empty Dir.children(@destination)
  end

  def test_later_io_failure_propagates_dirty_and_cleans_temporary_file
    write(@source, "one")
    write(@source, "two")
    original = File.method(:rename)
    attempts = 0
    replacement = lambda do |from, to|
      attempts += 1
      raise Errno::EIO, "private path must not leak" if attempts == 2
      original.call(from, to)
    end
    File.stub(:rename, replacement) do
      assert_refusal("asset_io_failed") { transfer(manifest(entry("one"), entry("two"))) }
    end
    assert_equal ["one"], Dir.children(@destination)
    assert_equal "toy bytes", File.binread(File.join(@destination, "one"))
  end

  def test_copy_rechecks_bytes_and_cleans_temporary_on_content_change
    write(@source, "one")
    original = Tempfile.method(:new)
    replacement = lambda do |*args, **options|
      temporary = original.call(*args, **options)
      File.binwrite(File.join(@source, "one"), "corrupted")
      temporary
    end
    Tempfile.stub(:new, replacement) do
      error = assert_refusal("content_mismatch") { transfer(manifest(entry("one"))) }
      assert_equal({ copied: 0, reused: 0, skipped_by_policy: 0 }, error.counts)
    end
    assert_empty Dir.children(@destination)
  end
end
