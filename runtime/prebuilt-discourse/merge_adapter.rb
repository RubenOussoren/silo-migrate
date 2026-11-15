# frozen_string_literal: true

require "digest"
require "find"
require "json"
if File.file?(File.expand_path("../shared/merge_assets.rb", __dir__))
  require_relative "../shared/merge_assets"
else
  require_relative "merge_assets"
end

require_relative "merge_baseline_assets"

# Private, pinned Discourse compatibility seam. No extra SQL, global patches, or core
# edits. Call prepare! before constructing the chosen subclass, then transfer!
# after stock start has completed. Roots must remain under trusted custody.
module SiloDiscourseMergeAdapter
  MAX_ASSETS = 100_000
  STOCK_PATH = "/var/www/discourse/script/bulk_import/discourse_merger.rb"
  FILE_SHA256 = "5aa46422c5d9981103d014801506c71bff4f26f608f83a5a55db91dba0f8128b"
  METHOD_SHA256 = "453de716a7abfb1c8d7cc6613a8a37ba5260bbd39a71d777414222bd625f8687"
  COPY_LINE = '    FileUtils.cp_r(File.join(@uploads_path, "."), Rails.public_path.join("uploads/default").to_s)'

  class Error < StandardError
    attr_reader :tag, :counts

    def initialize(tag, counts: nil)
      @tag = tag
      fields = %i[copied reused skipped_by_policy]
      if counts.is_a?(Hash) && fields.all? { |field| counts[field].is_a?(Integer) && counts[field].between?(0, MAX_ASSETS) }
        @counts = fields.to_h { |field| [field, counts[field]] }.freeze
      end
      super(tag)
    end
  end

  # Core's db/fixtures/010_uploads.rb uses negative IDs and intentionally fake
  # digests for packaged /images files. These are NOT uploaded customer files.
  # Reuse is eligible only with exact image bytes/metadata AND the same existing
  # destination record. Keep them in stock SQL/mappings, never transfer or delete
  # them, and never generalize this to arbitrary negative IDs or invalid digests.
  class SeededReuse
    FILES = { -1 => "d-logo-sketch.png", -2 => "d-logo-sketch-small.png",
      -3 => "default-favicon.ico", -4 => "default-apple-touch-icon.png",
      -5 => "discourse-logo-sketch.png", -6 => "discourse-logo-sketch-small.png" }.freeze
    IMAGE_ROOT = "/var/www/discourse/public/images"
    MAX_FILE_BYTES = 4 * 1024 * 1024
    attr_reader :sha1s, :facts

    def initialize(rows)
      SiloDiscourseMergeAdapter.refuse!("invalid_rows") unless rows.is_a?(Array) && rows.size <= MAX_ASSETS
      @seeds = {}
      rows.each do |row|
        SiloDiscourseMergeAdapter.refuse!("invalid_rows") unless row.is_a?(Hash) && field(row, :id).is_a?(Integer)
        next if field(row, :id).positive?
        id = field(row, :id)
        SiloDiscourseMergeAdapter.refuse!("unsupported_source_id") if @seeds.key?(id)
        @seeds[id] = prove!(row, tag: "unsupported_source_id")
      end
      @sha1s = @seeds.values.map { |row| row.fetch(1) }.freeze
      @facts = @seeds.keys.sort.map { |id| @seeds.fetch(id) }.freeze
    end

    def physical_rows!(rows)
      SiloDiscourseMergeAdapter.refuse!("seeded_reuse_unproven") unless rows.is_a?(Array) && rows.size <= MAX_ASSETS
      seen = {}
      rows.each do |row|
        SiloDiscourseMergeAdapter.refuse!("seeded_reuse_unproven") unless row.is_a?(Hash) && field(row, :id).is_a?(Integer)
        next if field(row, :id).positive?
        id = field(row, :id)
        proof = prove!(row, tag: "seeded_reuse_unproven")
        SiloDiscourseMergeAdapter.refuse!("seeded_reuse_unproven") unless @seeds[id] == proof && !seen[id]
        seen[id] = true
      end
      # A duplicate digest on ANY other ID would make stock's reuse ambiguous.
      @seeds.each do |id, proof|
        matches = rows.select { |row| field(row, :sha1) == proof[1] }
        SiloDiscourseMergeAdapter.refuse!("seeded_reuse_unproven") unless seen[id] && matches.size == 1 && field(matches.first, :id) == id
      end
      rows.reject { |row| @seeds.key?(field(row, :id)) }
    end

    def physical_source(rows)
      rows.reject { |row| @seeds.key?(field(row, :id)) }
    end

    def mapping?(source, target)
      @seeds.key?(source) && source == target
    end

    def verify_mapping!(mapping)
      SiloDiscourseMergeAdapter.refuse!("seeded_reuse_unproven") unless @seeds.keys.all? { |id| mapping[id] == id }
    end

    def target_ids = @seeds.keys

    private

    def field(row, key)
      row.key?(key) ? row[key] : row[key.to_s]
    end

    def prove!(row, tag:)
      id = field(row, :id)
      filename = FILES[id]
      SiloDiscourseMergeAdapter.refuse!(tag) unless filename && field(row, :url) == "/images/#{filename}" && field(row, :original_sha1).nil? && [nil, false, "f"].include?(field(row, :secure))
      proof = File.open(File.join(IMAGE_ROOT, filename), File::RDONLY | File::NOFOLLOW) do |file|
        stat = file.stat
        SiloDiscourseMergeAdapter.refuse!(tag) unless stat.file? && stat.size.between?(1, MAX_FILE_BYTES)
        bytes = file.read(MAX_FILE_BYTES + 1)
        SiloDiscourseMergeAdapter.refuse!(tag) unless bytes.bytesize == stat.size
        [stat.size, "_#{Digest::SHA1.hexdigest(bytes)}"[0, 40]]
      end
      SiloDiscourseMergeAdapter.refuse!(tag) unless field(row, :filesize).is_a?(Integer) && field(row, :filesize) == proof[0] && field(row, :sha1).is_a?(String) && field(row, :sha1) == proof[1]
      [id, field(row, :sha1).dup.freeze, field(row, :url).dup.freeze, proof[0]].freeze
    rescue SystemCallError, IOError, TypeError, KeyError
      SiloDiscourseMergeAdapter.refuse!(tag)
    end
  end

  class << self
    def prepare!(merger_class, source_rows:, approved_ids:, policy:, source_root:, destination_root:,
                 destination_rows: [])
      guarded do
        supported!(merger_class)
        context = Context.new(merger_class, source_rows, approved_ids, policy, source_root,
                              destination_root, destination_rows)
        merger_class.prepend(DeferredUploads)
        context
      end
    end

    def refuse!(tag, counts: nil)
      raise Error.new(tag, counts: counts), cause: nil
    end

    def guarded
      yield
    rescue SiloDiscourseBaselineAssets::Error
      refuse!("baseline_validation_failed")
    rescue SiloMergeAssets::Error => error
      refuse!("asset_validation_failed", counts: error.counts)
    rescue SystemCallError, IOError, ArgumentError, TypeError
      refuse!("adapter_validation_failed")
    end

    private

    def supported!(klass)
      path = STOCK_PATH
      refuse!("unsupported_stock") unless klass.is_a?(Class)
      method = klass.instance_method(:copy_uploads)
      owner = method.owner
      refuse!("unsupported_stock") unless owner.name == "BulkImport::DiscourseMerger" && klass != owner
      file, line = method.source_location
      refuse!("unsupported_stock") unless file && File.realpath(file) == File.realpath(path)
      %i[upload_id_from_imported_id fix_user_upload].each do |hook|
        refuse!("unsupported_stock") unless klass.instance_method(hook).owner == owner
      end
      source = File.binread(path, 64 * 1024 + 1)
      digest = Digest::SHA256.hexdigest(source)
      refuse!("unsupported_stock") unless digest == FILE_SHA256
      start = source.index("  def copy_uploads\n")
      finish = source.index("  def copy_upload_references\n", start || 0)
      refuse!("unsupported_stock") unless start && finish && source.byteslice(0, start).count("\n") + 1 == line
      { upload_id_from_imported_id: 1293, fix_user_upload: 1411 }.each do |hook, expected_line|
        hook_file, hook_line = klass.instance_method(hook).source_location
        refuse!("unsupported_stock") unless hook_file && File.realpath(hook_file) == File.realpath(path) && hook_line == expected_line
      end
      method_source = source.byteslice(start, finish - start)
      refuse!("unsupported_stock") unless Digest::SHA256.hexdigest(method_source) == METHOD_SHA256
      true
    rescue NameError, SystemCallError, TypeError
      refuse!("unsupported_stock")
    end
  end

  # Pinned stock method with two explicit compatibility changes: defer physical
  # IO, and floor allocation at zero when the destination has only negative
  # packaged IDs. Preserve stock's existing empty/positive-ID behavior.
  module DeferredUploads
  def copy_uploads
    puts ""
    print "copying uploads..."

    @silo_uploads_deferred = (@silo_uploads_deferred || 0) + 1

    columns = Upload.columns.map(&:name)
    last_id = [Upload.unscoped.maximum(:id) || 1, 0].max
    sql = "COPY uploads (#{columns.map { |c| "\"#{c}\"" }.join(", ")}) FROM STDIN"
    existing_ids_by_sha1 = Upload.unscoped.where.not(sha1: nil).pluck(:sha1, :id).to_h

    @raw_connection.copy_data(sql, @encoder) do
      source_raw_connection
        .exec("SELECT #{columns.map { |c| "\"#{c}\"" }.join(", ")} FROM uploads")
        .each do |row|
          if existing_id = existing_ids_by_sha1[row["sha1"]]
            @uploads[row["id"].to_i] = existing_id
            next
          end

          # make sure to get a backup with uploads then convert them to local.
          # when the backup is restored to a site with s3 uploads, it will upload the items
          # to the bucket
          rel_filename = row["url"].gsub(%r{^/uploads/[^/]+/}, "")
          # assumes if coming from amazonaws.com that we want to remove everything
          # but the text after the last `/`, which should leave us the filename
          rel_filename = rel_filename.gsub(%r{^//[^/]+\.amazonaws\.com/\S+uploads/[^/]+/}, "")
          absolute_filename = File.join(@uploads_path, rel_filename)

          old_id = row["id"]
          if old_id && last_id
            row["id"] = (last_id += 1)
            @uploads[old_id.to_i] = row["id"]
          end

          old_user_id = row["user_id"].to_i
          if old_user_id >= 1
            row["user_id"] = user_id_from_imported_id(old_user_id)
            next if row["user_id"].nil?
          end

          row["url"] = "/uploads/default/#{rel_filename}" if File.exist?(absolute_filename)
          @raw_connection.put_copy_data(row.values)
        end
    end

    @sequences[Upload.sequence_name] = last_id + 1
  end

  end

  class Context
    attr_reader :selection_digest, :preflight_manifest_digest, :baseline_inventory

    def initialize(klass, rows, approved_ids, policy, source_root, destination_root, destination_rows)
      @klass, @source_root, @destination_root = klass, source_root, destination_root
      SiloDiscourseMergeAdapter.refuse!("invalid_policy") unless %w[carried all].include?(policy)
      @policy = policy.dup.freeze
      @source_root = File.expand_path(source_root)
      @destination_root = File.expand_path(destination_root)
      @seeded_reuse = SeededReuse.new(rows)
      @rows = normalize(@seeded_reuse.physical_source(rows), source: true)
      ids = checked_ids(approved_ids)
      @required = ids.to_h { |id| [id, true] }
      SiloDiscourseMergeAdapter.refuse!("missing_source_row") unless (ids - @rows.keys).empty?
      baseline = normalize(@seeded_reuse.physical_rows!(destination_rows))
      @before_ids = baseline.keys.to_h { |id| [id, true] }
      @baseline_by_sha1 = baseline.values.group_by { |row| row[:sha1] }
      refuse!("ambiguous_destination") if @baseline_by_sha1.values.any? { |matches| matches.size > 1 }
      SiloMergeAssets.preflight!(manifest([]), source_root: @source_root, destination_root: @destination_root, allow_missing_destination: true)
      # Separate private baseline evidence binds all engine-required destination
      # originals without expanding the source transfer manifest to that size.
      @baseline_inventory = freeze_inventory(SiloDiscourseBaselineAssets.capture(@destination_root))
      # Both policies bind the complete bounded source-file inventory. Carried
      # records exclusions too, rather than silently permitting source orphans.
      @source_files = inventory.to_h { |entry| [entry["source"], entry] }
      if @policy == "carried" && @required.any?
        approved_paths = @required.keys.to_h { |id| [@rows.fetch(id)[:path], true] }
        refuse!("optimized_classification_unproven") if @source_files.keys.any? { |path| path.start_with?("optimized/") && !approved_paths.key?(path) }
      end
      bind_source_content!
      selection = [@policy, @required.keys.sort, @rows.keys.sort.map { |id| @rows[id].values_at(:id, :sha1, :url, :bytes, :original_sha1, :secure) }]
      selection << ["pinned_stock_seeded_reuse_v1", @seeded_reuse.facts] unless @seeded_reuse.facts.empty?
      @selection_digest = Digest::SHA256.hexdigest(JSON.generate(selection)).freeze
      preflight = build_preflight
      @preflight_manifest_digest = Digest::SHA256.hexdigest(JSON.generate(
        [preflight, SiloDiscourseBaselineAssets.digest(@baseline_inventory)])).freeze
      SiloMergeAssets.preflight!(preflight, source_root: @source_root, destination_root: @destination_root, allow_missing_destination: true)
      @baseline_by_sha1 = nil
    end

    # Pure metadata verification: no root lookup, file checks, or copy. The
    # caller can now reject references to excluded/dangling IDs before asset IO.
    def verify_mapping!(instance, destination_rows:)
      @verified_instance = nil
      SiloDiscourseMergeAdapter.guarded do
        refuse!("copy_not_deferred") unless instance.is_a?(@klass) && instance.instance_variable_get(:@silo_uploads_deferred) == 1
        mapping = instance.instance_variable_get(:@uploads)
        refuse!("missing_mapping") unless mapping.is_a?(Hash) && mapping.size <= MAX_ASSETS
        valid_mapping = mapping.all? do |source_id, target_id|
          source_id.is_a?(Integer) && target_id.is_a?(Integer) &&
            ((@rows.key?(source_id) && target_id.positive?) || @seeded_reuse.mapping?(source_id, target_id))
        end
        refuse!("missing_mapping") unless valid_mapping
        @seeded_reuse.verify_mapping!(mapping)
        rows = normalize(@seeded_reuse.physical_rows!(destination_rows))
        @rows.each_value do |row|
          target = rows[mapping[row[:id]]]
          refuse!("missing_mapping") if @required.key?(row[:id]) && !target
          refuse!("missing_mapping") if target && target[:sha1] != row[:sha1]
        end
        @verified_approved_ids = @required.keys.map { |id| mapping.fetch(id) }.uniq.sort.freeze
        @verified_excluded_ids = (@rows.keys - @required.keys).filter_map { |id| mapping[id] if rows.key?(mapping[id]) && !@before_ids.key?(mapping[id]) }.uniq.sort.freeze
        @verified_dangling_ids = (mapping.values.uniq - rows.keys - @seeded_reuse.target_ids).sort.freeze
        @verified_mapping = mapping.dup.freeze
        @verified_rows = rows
        @verified_instance = instance
        true
      end
    end

    # Caller keeps this result private. Inserted counts are actual destination
    # IDs absent from the pre-constructor baseline, not map cardinality.
    def transfer!(instance, destination_rows:)
      SiloDiscourseMergeAdapter.guarded do
        verify_mapping!(instance, destination_rows: destination_rows)
        refuse!("source_root_mismatch") unless File.expand_path(instance.instance_variable_get(:@uploads_path).to_s) == File.expand_path(@source_root)
        rows, mapping = @verified_rows, @verified_mapping
        entries = @rows.values.filter_map do |row|
          required = @required.key?(row[:id])
          target = rows[mapping[row[:id]]]
          row_entry(row, target, required)
        end
        append_tree!(entries)
        # Always verify a present source too, even if destination reuse wins in
        # the generic primitive's destination-first algorithm.
        verify_sources!(entries)
        append_baselines!(entries)
        manifest = manifest(entries)
        aggregates = SiloMergeAssets.transfer!(manifest, source_root: @source_root, destination_root: @destination_root,
                                             file_mode: 0o644, directory_mode: 0o755, allow_missing_destination: true)
        aggregates = aggregates.merge(upload_rows_inserted: rows.keys.count { |id| !@before_ids.key?(id) },
                                      upload_rows_skipped: @rows.keys.count { |id| !rows.key?(mapping[id]) })
        begin
          result = { manifest: target_manifest!(manifest), aggregates: aggregates }
        rescue SiloMergeAssets::Error, Error
          # Transfer completed, but later verification did not. Preserve actual
          # completed IO counts without ever returning a success manifest.
          SiloDiscourseMergeAdapter.refuse!("asset_validation_failed", counts: aggregates)
        rescue SystemCallError, IOError
          SiloDiscourseMergeAdapter.refuse!("adapter_validation_failed", counts: aggregates)
        end
        result
      end
    end

    # IDs are exposed after metadata verification, not proof of copied bytes.
    # Excluded means business-excluded rows, independent of physical all mode.
    def approved_destination_ids(instance)
      verified_mapping!(instance)
      @verified_approved_ids.dup
    end

    def excluded_inserted_ids(instance)
      verified_mapping!(instance)
      @verified_excluded_ids.dup
    end

    def dangling_destination_ids(instance)
      verified_mapping!(instance)
      @verified_dangling_ids.dup
    end

    private

    def freeze_inventory(value)
      case value
      when Hash
        value.each { |key, item| freeze_inventory(key); freeze_inventory(item) }
      when Array
        value.each { |item| freeze_inventory(item) }
      end
      value.freeze
    end

    def verified_mapping!(instance)
      refuse!("mapping_not_verified") unless @verified_instance && @verified_instance.equal?(instance) && instance.instance_variable_get(:@uploads) == @verified_mapping
    end

    def refuse!(tag)
      SiloDiscourseMergeAdapter.refuse!(tag)
    end

    def checked_ids(ids)
      refuse!("invalid_ids") unless ids.is_a?(Array) && ids.size <= MAX_ASSETS
      refuse!("invalid_ids") unless ids.all? { |id| id.is_a?(Integer) && id.positive? } && ids.uniq.size == ids.size
      ids
    end

    def normalize(rows, source: false)
      refuse!("invalid_rows") unless rows.is_a?(Array) && rows.size <= MAX_ASSETS
      result = {}
      rows.each do |row|
        refuse!("invalid_rows") unless row.is_a?(Hash)
        value = ->(key) { row.key?(key) ? row[key] : row[key.to_s] }
        id, sha1 = value.call(:id), value.call(:sha1)
        refuse!("unsupported_source_id") if source && id.is_a?(Integer) && !id.positive?
        refuse!("invalid_rows") unless id.is_a?(Integer) && id.positive? && !result.key?(id)
        refuse!("invalid_rows") unless sha1.is_a?(String) && /\A[0-9a-f]{40}\z/.match?(sha1)
        original_sha1 = value.call(:original_sha1)
        refuse!("invalid_rows") unless original_sha1.nil? || (original_sha1.is_a?(String) && /\A[0-9a-f]{40}\z/.match?(original_sha1))
        secure = value.call(:secure)
        refuse!("invalid_rows") unless [nil, true, false, "t", "f"].include?(secure)
        item = { id: id, sha1: sha1.dup.freeze, path: url_path(value.call(:url)),
                 original_sha1: original_sha1&.dup&.freeze, secure: secure == true || secure == "t" }
        if source
          bytes = value.call(:filesize)
          refuse!("invalid_rows") unless bytes.is_a?(Integer) && bytes.between?(0, SiloMergeAssets::MAX_BYTES)
          item[:bytes] = bytes
          item[:url] = value.call(:url).dup.freeze
        end
        result[id] = item.freeze
      end
      result.sort.to_h
    end

    def url_path(url)
      refuse!("unsafe_url") unless url.is_a?(String) && url.valid_encoding? && url.bytesize <= 4096
      refuse!("unsafe_url") if url.match?(/[%?#\x00-\x20\x7f\\]/)
      refuse!("unsafe_url") if url.split("/").any? { |part| [".", ".."].include?(part) }
      path = if url.match?(%r{\A/uploads/[^/]+/})
        url.sub(%r{\A/uploads/[^/]+/}, "")
      elsif url.match?(%r{\A//[^/]+\.amazonaws\.com/\S+uploads/[^/]+/})
        url.sub(%r{\A//[^/]+\.amazonaws\.com/\S+uploads/[^/]+/}, "")
      end
      refuse!("unsafe_url") unless path && !path.match?(/[%?#\x00-\x20\x7f\\:]/) && path.split("/", -1).all? { |part| !["", ".", ".."].include?(part) }
      path.freeze
    end

    def entry(row, destination, disposition, required)
      { "key" => "upload:#{row[:id]}", "source" => row[:path], "destination" => destination,
        "digest" => { "algorithm" => "sha1", "value" => row[:original_sha1] || row[:sha1] }, "bytes" => row[:bytes],
        "disposition" => disposition, "required" => required }
    end

    def manifest(entries)
      { "version" => 1, "policy" => @policy, "entries" => entries }
    end

    def bind_source_content!
      @content_digests = {}
      @rows.each_value do |row|
        next unless @required.key?(row[:id]) || @policy == "all"
        file = @source_files[row[:path]]
        next unless file
        refuse!("asset_validation_failed") unless file["bytes"] == row[:bytes]
        path = regular_file(@source_root, row[:path])
        expected = row[:original_sha1] || row[:sha1]
        unless Digest::SHA1.file(path).hexdigest == expected
          refuse!(row[:original_sha1] ? "asset_validation_failed" : "unsupported_content_identity")
        end
        @content_digests[row[:id]] = file["digest"].dup.freeze
      end
    end

    def selected_entry(row, target, disposition, required)
      result = entry(row, target ? target[:path] : row[:path], disposition, required)
      if target && target[:original_sha1]
        # A destination's real-content metadata must also be truthful; sha1 is
        # only stock's dedup key and may deliberately identify different bytes.
        if @before_ids.key?(target[:id])
          metadata = result.merge("digest" => { "algorithm" => "sha1", "value" => target[:original_sha1] })
          SiloMergeAssets.verify!(manifest([metadata]), destination_root: @destination_root)
        else
          refuse!("asset_validation_failed") unless target[:original_sha1] == (row[:original_sha1] || row[:sha1])
        end
      end
      digest = @content_digests[row[:id]]
      unless digest
        real = row[:original_sha1] || target&.fetch(:original_sha1)
        refuse!("unsupported_content_identity") if !real && (row[:secure] || target&.fetch(:secure))
        if !real && target
          path = regular_file(@destination_root, target[:path])
          refuse!("unsupported_content_identity") if path && File.size(path) == row[:bytes] && Digest::SHA1.file(path).hexdigest != row[:sha1]
        end
        digest = { "algorithm" => "sha1", "value" => real || row[:sha1] }
      end
      result.merge("digest" => digest.dup)
    end

    def row_entry(row, target, required)
      if required
        selected_entry(row, target, target && @before_ids.key?(target[:id]) ? "reuse" : "copy", true)
      elsif @policy == "all"
        # Stock can allocate a map ID then skip an unmappable positive owner.
        # All still copies that file, but a nonexistent optional row is not proof
        # of a destination URL. Missing optional files create no IO obligation.
        if target && @before_ids.key?(target[:id])
          selected_entry(row, target, "reuse", false)
        elsif @source_files.key?(row[:path])
          selected_entry(row, target, "copy", false)
        end
      elsif @source_files.key?(row[:path])
        file = @source_files.fetch(row[:path])
        entry(row, row[:path], "exclude", false).merge("digest" => file["digest"].dup, "bytes" => file["bytes"])
      end
    end

    def build_preflight
      entries = @rows.values.filter_map do |row|
        required = @required.key?(row[:id])
        # Duplicate destination SHA1 matches are refused as ambiguous above.
        existing = @baseline_by_sha1[row[:sha1]]&.first
        row_entry(row, existing, required)
      end
      append_tree!(entries)
      verify_sources!(entries)
      # Resolve source-selected conflicts before constructor/merge writes. Only
      # excluded source-relative paths are inspected for baseline preservation.
      SiloMergeAssets.preflight!(manifest(entries), source_root: @source_root, destination_root: @destination_root, allow_missing_destination: true)
      @baselines = capture_baselines(entries)
      append_baselines!(entries)
      manifest(entries)
    end

    def capture_baselines(entries)
      entries.select { |entry| entry["disposition"] == "exclude" }.map { |entry| entry["destination"] }.uniq.sort.filter_map do |relative|
        next unless regular_file(@destination_root, relative)
        digest, bytes = target_sha256!(relative)
        { "key" => "baseline:#{Digest::SHA256.hexdigest(relative)}", "source" => relative, "destination" => relative,
          "digest" => { "algorithm" => "sha256", "value" => digest }, "bytes" => bytes,
          "disposition" => "reuse", "required" => true }
      end
    end

    def append_baselines!(entries)
      refuse!("asset_limit") if entries.size + @baselines.size > MAX_ASSETS
      by_path = @baselines.to_h { |entry| [entry["destination"], entry] }
      overlapping = entries.select { |entry| entry["disposition"] != "exclude" && by_path.key?(entry["destination"]) }
      # SHA1 and SHA256 identities cannot share a generic destination group.
      # First independently prove the row's original identity at the target,
      # then bind it to the original baseline SHA256; final preflight checks both.
      SiloMergeAssets.verify!(manifest(overlapping), destination_root: @destination_root) unless overlapping.empty?
      overlapping.each do |entry|
        next unless entry["digest"]["algorithm"] == "sha1"
        baseline = by_path.fetch(entry["destination"])
        entry["digest"] = baseline["digest"].dup
      end
      entries.concat(@baselines)
    end

    def target_manifest!(original)
      if original["entries"].all? { |entry| entry["disposition"] == "exclude" }
        # SQL-only destinations may legitimately have no upload root at all.
        # Transfer already checked every existing ancestor; there are no target
        # bytes to verify/hash and no reason to create a directory for evidence.
        SiloMergeAssets.validate!(original)
        return original
      end
      SiloMergeAssets.verify!(original, destination_root: @destination_root)
      verified = {}
      entries = original["entries"].map do |entry|
        next entry if entry["disposition"] == "exclude"
        digest, bytes = verified[entry["destination"]] ||= target_sha256!(entry["destination"])
        refuse!("asset_validation_failed") unless bytes == entry["bytes"]
        if entry["digest"]["algorithm"] == "sha256"
          refuse!("asset_validation_failed") unless digest == entry["digest"]["value"]
        end
        entry.merge("digest" => { "algorithm" => "sha256", "value" => digest })
      end
      result = manifest(entries)
      SiloMergeAssets.verify!(result, destination_root: @destination_root)
      result
    end

    def target_sha256!(relative)
      path = regular_file(@destination_root, relative)
      refuse!("asset_validation_failed") unless path
      File.open(path, "rb") do |input|
        refuse!("asset_validation_failed") unless input.stat.file?
        bytes = input.stat.size
        refuse!("asset_validation_failed") unless bytes.between?(0, SiloMergeAssets::MAX_BYTES)
        digest = Digest::SHA256.new
        total = 0
        while (chunk = input.read([SiloMergeAssets::CHUNK_BYTES, bytes - total + 1].min))
          total += chunk.bytesize
          refuse!("asset_validation_failed") if total > bytes
          digest.update(chunk)
        end
        refuse!("asset_validation_failed") unless total == bytes
        [digest.hexdigest, bytes]
      end
    end

    def verify_sources!(entries)
      present = entries.reject { |e| e["disposition"] == "exclude" }.select do |e|
        exists = source_exists?(e["source"])
        refuse!("missing_required_asset") if !exists && e["disposition"] != "reuse"
        exists
      end.map { |e| e.merge("destination" => e["source"], "disposition" => "reuse") }
      present.group_by { |entry| entry["digest"]["algorithm"] }.each_value do |group|
        SiloMergeAssets.verify!(manifest(group), destination_root: @source_root)
      end
    end

    def append_tree!(entries)
      # All means the entire stock source tree, including an original whose row
      # deduplicates onto a different existing destination URL.
      covered = entries.to_h { |entry| [entry["destination"], true] }
      @source_files.each_value do |entry|
        next if covered.key?(entry["destination"])
        entries << entry.merge("disposition" => @policy == "all" ? "copy" : "exclude")
      end
      refuse!("asset_limit") if entries.size > MAX_ASSETS
    end

    def source_exists?(relative)
      !!regular_file(@source_root, relative)
    end

    def regular_file(root, relative)
      current = root
      parts = relative.split("/")
      parts.each_with_index do |part, index|
        current = File.join(current, part)
        begin
          stat = File.lstat(current)
        rescue Errno::ENOENT
          return nil
        end
        refuse!("unsafe_source_tree") if stat.symlink?
        refuse!("unsafe_source_tree") unless index == parts.size - 1 ? stat.file? : stat.directory?
      end
      current
    end

    def inventory
      entries = []
      seen = 0
      Find.find(@source_root) do |path|
        stat = File.lstat(path)
        refuse!("unsafe_source_tree") if stat.symlink? || (!stat.file? && !stat.directory?)
        seen += 1
        refuse!("asset_limit") if seen > MAX_ASSETS * 2 + 1
        next unless stat.file?
        relative = path.delete_prefix(@source_root + "/")
        refuse!("asset_limit") if entries.size >= MAX_ASSETS
        entries << { "key" => "file:#{entries.size}", "source" => relative, "destination" => relative,
                     "digest" => { "algorithm" => "sha256", "value" => Digest::SHA256.file(path).hexdigest },
                     "bytes" => stat.size, "disposition" => "copy", "required" => false }
      end
      entries.sort_by { |entry| entry["source"] }.each_with_index { |entry, index| entry["key"] = "file:#{index}" }
    end
  end
end
