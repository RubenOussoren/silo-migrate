# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require_relative "../runtime/prebuilt-discourse/merge_baseline_assets"

class MergeBaselineAssetsTest < Minitest::Test
  Assets = SiloDiscourseBaselineAssets

  def setup
    @workspace = Dir.mktmpdir("invented-baseline-")
    @root = File.join(@workspace, "uploads", "default")
  end

  def teardown
    FileUtils.remove_entry(@workspace)
  end

  def write(path, bytes = "invented original")
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.binwrite(target, bytes)
    target
  end

  def entry(path = "original/file", bytes = "invented original")
    { "path" => path, "sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize }
  end

  def inventory(*files, derived: 0)
    { "version" => 1, "files" => files, "derived_files" => derived }
  end

  def assert_refused(tag = nil)
    error = assert_raises(Assets::Error) { yield }
    assert_equal tag, error.tag if tag
    assert_match(/\Abaseline_[a-z_]+\z/, error.tag)
    assert_equal error.tag, error.message
    assert_nil error.cause
    refute_includes error.message, @workspace
    error
  end

  def with_limit(name, value)
    original = Assets.const_get(name)
    Assets.send(:remove_const, name)
    Assets.const_set(name, value)
    yield
  ensure
    Assets.send(:remove_const, name)
    Assets.const_set(name, original)
  end

  def test_every_original_is_captured_and_only_optimized_subtree_is_counted
    paths = ["original/1/a.bin", "emoji/custom/toy.png", "root.txt", "other/optimized/keep", "optimized-other/keep", ".hidden"]
    paths.each { |path| write(path, path) }
    write("optimized/1/derivative", "regenerable")
    write("optimized/unknown-extension.xyz", "still engine-declared cache")
    actual = Assets.capture(@root)
    assert_equal inventory(*paths.sort.map { |path| entry(path, path) }, derived: 2), actual
    assert Assets.validate!(actual)
    assert_equal %w[derived_files files version], actual.keys.sort
  end

  def test_root_file_named_optimized_is_an_original
    write("optimized")
    assert_equal inventory(entry("optimized")), Assets.capture(@root)
  end

  def test_derivatives_are_counted_not_claimed_as_verified_bytes
    original = write("original/keep")
    derivative = write("optimized/cache", "first cache")
    before = Assets.capture(@root)
    File.binwrite(derivative, "different regenerable bytes")
    assert_equal before, Assets.capture(@root)
    File.binwrite(original, "changed original")
    refute_equal Assets.digest(before), Assets.digest(Assets.capture(@root))
    File.unlink(original)
    refute_equal Assets.digest(before), Assets.digest(Assets.capture(@root))
  end

  def test_missing_root_has_no_directory_or_file_side_effects
    before = Dir.children(@workspace)
    assert_equal inventory, Assets.capture(@root)
    assert_equal before, Dir.children(@workspace)
    refute File.exist?(File.dirname(@root))
    FileUtils.mkdir_p(File.dirname(@root))
    assert_equal inventory, Assets.capture(@root)
    refute File.exist?(@root)
  end

  def test_missing_root_does_not_allow_symlink_or_non_directory_ancestor
    outside = File.join(@workspace, "outside")
    Dir.mkdir(outside)
    File.symlink(outside, File.dirname(@root))
    assert_refused("baseline_unsafe_path") { Assets.capture(@root) }
    File.unlink(File.dirname(@root))
    File.write(File.dirname(@root), "not a directory")
    assert_refused("baseline_unsafe_path") { Assets.capture(@root) }
  end

  def test_symlink_root_and_all_links_including_cache_are_rejected
    write("keep")
    real = "#{@root}-real"
    File.rename(@root, real)
    File.symlink(real, @root)
    assert_refused("baseline_unsafe_path") { Assets.capture(@root) }
    File.unlink(@root)
    File.rename(real, @root)
    %w[original/link optimized/link root-link].each do |path|
      target = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(target))
      [File.join(@workspace, "absent"), @workspace, File.join(@root, "keep")].each do |destination|
        File.symlink(destination, target)
        assert_refused("baseline_unsafe_path") { Assets.capture(@root) }
        File.unlink(target)
      end
    end
  end

  def test_nonregular_nodes_are_rejected_even_in_cache_without_blocking
    %w[original/pipe optimized/pipe].each do |path|
      target = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(target))
      File.mkfifo(target)
      assert_refused("baseline_unsafe_path") { Assets.capture(@root) }
      File.unlink(target)
    end
  end

  def test_unsafe_root_and_relative_paths_are_rejected
    [nil, "relative", "/", "#{@root}/", "#{@root}/../escape", "#{@root}//child", "#{@root}/./child", "#{@root}/bad\\path", "#{@root}/bad\npath"].each do |root|
      assert_refused("baseline_unsafe_path") { Assets.capture(root) }
    end
    ["", "/escape", "../escape", "a/../b", "./a", "a/./b", "a//b", "a/", "a\\b", "bad\0name", "bad\nname", "bad\u0085name", "\xff".b, "a" * (Assets::MAX_PATH_BYTES + 1)].each do |path|
      assert_refused("baseline_unsafe_path") { Assets.validate!(inventory(entry(path))) }
    end
  end

  def test_actual_unsafe_filenames_are_rejected_including_optimized
    ["bad\\name", "optimized/bad\nname"].each do |path|
      target = write(path)
      assert_refused("baseline_unsafe_path") { Assets.capture(@root) }
      File.unlink(target)
    end
  end

  def test_deterministic_capture_and_canonical_digest_ignore_key_and_file_order
    write("z", "last")
    write("a", "first")
    write("emoji/é.png", "unicode")
    first = Assets.capture(@root)
    assert_equal first, Assets.capture(@root)
    reordered = { "derived_files" => 0, "files" => first["files"].reverse.map { |file| file.to_a.reverse.to_h }, "version" => 1 }
    canonical = inventory(*first["files"])
    assert_equal Digest::SHA256.hexdigest(JSON.generate(canonical)), Assets.digest(first)
    assert_equal Assets.digest(first), Assets.digest(reordered)
    assert_equal first, canonical
    assert_match(/\A[0-9a-f]{64}\z/, Assets.digest(first))
    assert_equal first["files"].map { |file| file["path"] }.sort, first["files"].map { |file| file["path"] }
  end

  def test_strict_keys_versions_types_digests_and_counts
    invalid = [nil, [], inventory.merge("unknown" => 1), inventory.reject { |key, _| key == "derived_files" },
               inventory.merge(version: 1), inventory.merge("version" => 1.0), inventory.merge("version" => 2),
               inventory.merge("files" => {}), inventory(derived: -1), inventory(derived: 1.0), inventory(derived: "0"),
               inventory(entry.merge("unknown" => true)), inventory(entry.reject { |key, _| key == "bytes" }),
               inventory(entry.merge("bytes" => -1)), inventory(entry.merge("bytes" => 0.0)),
               inventory(entry.merge("bytes" => "1")), inventory(entry.merge("sha256" => "A" * 64)),
               inventory(entry.merge("sha256" => "a" * 63)), inventory(entry.merge("sha256" => "g" * 64)),
               inventory(entry("optimized/cache"))]
    invalid.each do |value|
      assert_refused("baseline_invalid") { Assets.validate!(value) }
      assert_refused("baseline_invalid") { Assets.digest(value) }
    end
  end

  def test_duplicate_and_file_directory_collision_rejected
    assert_refused("baseline_duplicate") { Assets.validate!(inventory(entry, entry)) }
    assert_refused("baseline_collision") { Assets.validate!(inventory(entry("a/b/c"), entry("a"))) }
  end

  def test_limits_are_declared_and_checked_before_entry_processing
    assert_equal 100_000, Assets::MAX_FILES
    assert_equal 64 * 1024 * 1024, Assets::MAX_JSON
    # The nil entries must never be processed: count is checked first.
    assert_refused("baseline_limit") { Assets.validate!(inventory(*Array.new(Assets::MAX_FILES + 1))) }
    assert_refused("baseline_limit") { Assets.validate!(inventory(derived: Assets::MAX_FILES + 1)) }
    assert_refused("baseline_limit") { Assets.validate!(inventory(entry, derived: Assets::MAX_FILES)) }
    assert Assets.validate!(inventory(derived: Assets::MAX_FILES))
  end

  def test_capture_counts_originals_and_derivatives_against_same_cap
    write("original/a")
    write("optimized/b")
    with_limit(:MAX_FILES, 2) { assert_equal 1, Assets.capture(@root)["derived_files"] }
    write("optimized/c")
    with_limit(:MAX_FILES, 2) { assert_refused("baseline_limit") { Assets.capture(@root) } }
  end

  def test_empty_directories_cannot_grow_traversal_without_bound
    FileUtils.mkdir_p(File.join(@root, "a/b/c"))
    with_limit(:MAX_FILES, 2) { assert_refused("baseline_limit") { Assets.capture(@root) } }
  end

  def test_json_size_limit_on_capture_validation_and_digest
    write("original/a")
    value = Assets.capture(@root)
    exact = JSON.generate(value).bytesize
    with_limit(:MAX_JSON, exact) { assert_equal value, Assets.capture(@root) }
    with_limit(:MAX_JSON, exact - 1) do
      assert_refused("baseline_limit") { Assets.capture(@root) }
      assert_refused("baseline_limit") { Assets.validate!(value) }
      assert_refused("baseline_limit") { Assets.digest(value) }
    end
  end

  def test_files_are_hashed_in_bounded_chunks_and_byte_counts_are_exact
    content = ("\0binary\xff".b * (Assets::CHUNK_BYTES / 4)) + "tail"
    target = write("original/large", content)
    write("empty", "")
    requests = []
    real_open = File.method(:open)
    opener = lambda do |path, *args, &block|
      real_open.call(path, *args) do |file|
        if File.basename(path) == File.basename(target)
          read = file.method(:read)
          file.define_singleton_method(:read) { |count| requests << count; read.call(count) }
        end
        block.call(file)
      end
    end
    # Directory opens return their handles rather than using a block.
    opener = open_interceptor(real_open, &opener)
    actual = File.stub(:open, opener) { Assets.capture(@root) }
    assert_equal inventory(entry("empty", ""), entry("original/large", content)), actual
    assert_operator requests.size, :>, 2
    assert requests.all? { |size| size == Assets::CHUNK_BYTES }
  end

  def open_interceptor(real_open, &intercept)
    lambda do |path, *args, &block|
      block ? intercept.call(path, *args, &block) : real_open.call(path, *args)
    end
  end

  def test_mutation_during_hash_rejects_size_and_same_size_byte_changes
    [:truncate, :grow, :same_size, :replace].each do |mutation|
      target = write("original/mutate", "a" * (Assets::CHUNK_BYTES + 17))
      before = File.stat(target)
      real_open = File.method(:open)
      changed = false
      opener = open_interceptor(real_open) do |path, *args, &block|
        real_open.call(path, *args) do |file|
          if File.basename(path) == "mutate"
            read = file.method(:read)
            file.define_singleton_method(:read) do |count|
              result = read.call(count)
              unless changed
                changed = true
                # Ensure even coarse filesystem ctime clocks advance; restore
                # mtime below so that same-size changes must be caught by ctime.
                sleep 0.02
                case mutation
                when :truncate then File.truncate(target, 1)
                when :grow then File.binwrite(target, "b" * (before.size + 1))
                when :same_size
                  File.binwrite(target, "b" * before.size)
                  File.utime(before.atime, before.mtime, target)
                when :replace
                  File.unlink(target)
                  File.binwrite(target, "a" * before.size)
                  File.utime(before.atime, before.mtime, target)
                end
              end
              result
            end
          end
          block.call(file)
        end
      end
      File.stub(:open, opener) { assert_refused("baseline_changed") { Assets.capture(@root) } }
      assert changed
    end
  end

  def test_symlink_swap_after_lstat_never_reads_link_target
    target = write("original/swap")
    outside = File.join(@workspace, "outside-private")
    File.binwrite(outside, "never read")
    real_open = File.method(:open)
    swapped = false
    opener = lambda do |path, *args, &block|
      if File.basename(path) == "swap" && !swapped
        swapped = true
        File.unlink(target)
        File.symlink(outside, target)
      end
      real_open.call(path, *args, &block)
    end
    File.stub(:open, opener) { assert_refused("baseline_io_failed") { Assets.capture(@root) } }
    assert swapped
  end

  def test_directory_swap_uses_pinned_directory_and_fails_identity_check
    write("original/keep")
    outside = File.join(@workspace, "outside")
    Dir.mkdir(outside)
    File.binwrite(File.join(outside, "private"), "never read")
    original_frame = Assets.method(:frame)
    swapped = false
    framer = lambda do |anchor, relative|
      if relative == "original" && !swapped
        swapped = true
        File.rename(File.join(@root, "original"), File.join(@root, "old-original"))
        File.symlink(outside, File.join(@root, "original"))
      end
      original_frame.call(anchor, relative)
    end
    Assets.stub(:frame, framer) { assert_refused("baseline_changed") { Assets.capture(@root) } }
    assert swapped
  end
end
