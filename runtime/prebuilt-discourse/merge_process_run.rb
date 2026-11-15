# frozen_string_literal: true

# Engine-specific bridge to the shared contract and asset protocols. Neither a
# project layer nor a settings document can enable a different adapter or weaken
# required-media checks. Everything returned here is run-private evidence.
require "json"
require "digest"
require "yaml"
require "pg"
if File.file?(File.expand_path("../shared/merge_contract.rb", __dir__))
  require_relative "../shared/merge_contract"
  require_relative "../shared/merge_refusal"
else
  require_relative "merge_contract"
  require_relative "merge_refusal"
end
require_relative "merge_adapter"
require_relative "merge_asset_references"
require_relative "merge_validate"

module SiloMergeProcessRuntime
  MAX_UPLOADS = 100_000
  module_function

  def load_contract
    path = ENV["SILO_MERGE_CONTRACT"]
    return nil unless path
    contract = SiloMergeContract.load(File.binread(path, 128 * 1024 + 1))
    raise "engine_unsupported" unless contract["engine"] == "discourse-merger-v1"
    bytes = File.binread(ENV.fetch("SILO_MERGE_SETTINGS"), 256 * 1024 + 1)
    raise "settings_size" if bytes.bytesize > 256 * 1024
    settings = YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
    resolved = SiloMergeContract.validate_settings!(contract, settings)
    ENV["SILO_MERGE_UPLOAD_COPY_POLICY"] = resolved.fetch("physical_policy")
    ENV["SILO_MERGE_ASSET_PROTOCOL"] = "1"
    { contract: contract, policy: resolved.fetch("physical_policy") }
  end

  def rows(connection)
    # Fetch narrow metadata with keyset paging; never materialize posts or raw
    # content merely to construct an upload manifest.
    result = []
    after = nil
    loop do
      sql = "SELECT id, sha1, original_sha1, secure, url, filesize FROM uploads"
      batch = if after.nil?
        connection.exec_params("#{sql} ORDER BY id LIMIT 1000", []).to_a
      else
        connection.exec_params("#{sql} WHERE id > $1 ORDER BY id LIMIT 1000", [after]).to_a
      end
      break if batch.empty?
      raise "asset_row_limit" if result.size + batch.size > MAX_UPLOADS
      batch.each do |row|
        row["id"] = Integer(row.fetch("id"))
        row["filesize"] = Integer(row.fetch("filesize"))
      end
      result.concat(batch)
      after = Integer(batch.last.fetch("id"))
    end
    result
  end

  def destination_rows(ids: nil, sha1s: nil, seeded_sha1s: [])
    # Restrict destination reads to relevant IDs/digests. A large existing site
    # must not require a second in-memory copy of its entire uploads table.
    values = ids || sha1s
    raise "asset_filter_required" unless values.is_a?(Array) && values.size <= MAX_UPLOADS
    result = []
    values.uniq.each_slice(1000) do |batch|
      literals = if ids
        batch.map { |value| Integer(value).to_s }
      else
        batch.map do |value|
          raise "asset_digest_invalid" unless value.is_a?(String) && (value.match?(/\A[0-9a-f]{40}\z/) || seeded_sha1s.include?(value))
          ActiveRecord::Base.connection.quote(value)
        end
      end
      next if literals.empty?
      column = ids ? "id" : "sha1"
      rows = ActiveRecord::Base.connection.exec_query("SELECT id, sha1, original_sha1, secure, url, filesize FROM uploads WHERE #{column} IN (#{literals.join(',')}) ORDER BY id").to_a
      raise "asset_row_limit" if result.size + rows.size > MAX_UPLOADS
      result.concat(rows)
    end
    result.uniq { |row| Integer(row.fetch("id")) }
  end

  def prepare(merger, state)
    return nil unless state
    unless merger.respond_to?(:silo_merge_asset_ids) && merger.respond_to?(:silo_merge_audit)
      raise "process_hooks_required"
    end
    source = PG.connect(dbname: ENV.fetch("DB_NAME"), host: ENV.fetch("DISCOURSE_DB_HOST"),
                        port: Integer(ENV.fetch("DISCOURSE_DB_PORT", "5432")), user: "discourse",
                        password: ENV.fetch("DISCOURSE_DB_PASSWORD"))
    source_rows = rows(source)
    seeded = SiloDiscourseMergeAdapter::SeededReuse.new(source_rows)
    before = destination_rows(sha1s: source_rows.map { |row| row.fetch("sha1") }.compact, seeded_sha1s: seeded.sha1s)
    approved_ids = merger.silo_merge_asset_ids
    context = SiloDiscourseMergeAdapter.prepare!(merger, source_rows: source_rows, destination_rows: before,
      approved_ids: approved_ids, policy: state.fetch(:policy),
      source_root: ENV.fetch("UPLOADS_PATH"), destination_root: SiloDiscourseAssetReferences.destination_root(Rails.public_path))
    expected = ENV.fetch("SILO_MERGE_SELECTION_SHA256")
    manifest_expected = ENV.fetch("SILO_MERGE_ASSET_PREFLIGHT_SHA256")
    owner_expected = ENV.fetch("SILO_MERGE_OWNER_PREFLIGHT_SHA256")
    unless [expected, manifest_expected, owner_expected].all? { |value| value.match?(/\A[0-9a-f]{64}\z/) }
      raise "receipt_digest_missing"
    end
    raise "selection_changed" unless context.selection_digest == expected
    raise "asset_preflight_changed" unless context.preflight_manifest_digest == manifest_expected
    owner_digest = SiloMergeValidation.required_owners!(source, source_rows, before, approved_ids)
    raise "owner_preflight_changed" unless owner_digest == owner_expected
    baseline_path = "/shared/merge-process/baseline-assets.json"
    File.open(baseline_path, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o600) do |file|
      file.write(JSON.generate(context.baseline_inventory) + "\n")
    end
    state = { context: context, before_ids: before.map { |row| Integer(row.fetch("id")) }, approved_source_ids: approved_ids.dup,
      baseline_sha256: Digest::SHA256.file(baseline_path).hexdigest,
      policy: state.fetch(:policy), contract: state.fetch(:contract),
      audit: { "preflight" => SiloMergeContract.audit!(state.fetch(:contract), "preflight", merger.silo_merge_audit("preflight")) } }
    emit(state, phase: "preflight", complete: false)
    state
  ensure
    source&.close
  end

  def transfer(state, instance)
    return unless state
    mapped = instance.instance_variable_get(:@uploads)
    raise "asset_mapping_missing" unless mapped.is_a?(Hash) && mapped.size <= MAX_UPLOADS
    actual = destination_rows(ids: mapped.values.compact)
    state.fetch(:context).verify_mapping!(instance, destination_rows: actual)
    inserted = actual.map { |row| Integer(row.fetch("id")) } - state.fetch(:before_ids)
    excluded_inserted = state.fetch(:policy) == "carried" ? state.fetch(:context).excluded_inserted_ids(instance) : []
    dangling = state.fetch(:context).dangling_destination_ids(instance)
    reference_counts = SiloDiscourseAssetReferences.verify!(ActiveRecord::Base.connection, excluded_inserted + dangling)
    state[:bookkeeping_references] = reference_counts.fetch(:bookkeeping)
    reference_path = "/shared/merge-process/references.json"
    File.open(reference_path, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o600) do |file|
      file.write(JSON.generate({ "version" => 1, "excluded_inserted_ids" => excluded_inserted, "dangling_ids" => dangling }) + "\n")
    end
    state[:references_sha256] = Digest::SHA256.file(reference_path).hexdigest
    begin
      result = state.fetch(:context).transfer!(instance, destination_rows: actual)
    rescue SiloDiscourseMergeAdapter::Error => error
      if error.respond_to?(:counts) && error.counts
        partial = error.counts
        state[:transfer] = { "files_copied" => partial.fetch(:copied), "files_reused" => partial.fetch(:reused),
          "files_skipped_by_policy" => partial.fetch(:skipped_by_policy) }
        emit(state, phase: "transfer", complete: false)
      end
      raise
    end
    manifest = result.fetch(:manifest)
    # The path is fixed by the runner, not the layer or a schema. Host copies it
    # privately for policy-aware backup verification; it is never public output.
    path = "/shared/merge-process/asset-manifest.json"
    File.open(path, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o600) { |file| file.write(JSON.generate(manifest) + "\n") }
    raw_counts = result.fetch(:aggregates)
    state[:transfer] = { "files_copied" => raw_counts.fetch(:copied), "files_reused" => raw_counts.fetch(:reused),
      "files_skipped_by_policy" => raw_counts.fetch(:skipped_by_policy) }
    state[:manifest_sha256] = Digest::SHA256.file(path).hexdigest
    # Do not infer inserted rows from MAX(id): compare the actual baseline IDs.
    state[:inserted_ids] = actual.map { |row| Integer(row.fetch("id")) } - state.fetch(:before_ids)
    emit(state, phase: "transfer", complete: false)
  end

  def finish(state, merger)
    return unless state
    state.fetch(:audit)["postflight"] = SiloMergeContract.audit!(state.fetch(:contract), "postflight", merger.silo_merge_audit("postflight"))
    ids = state.fetch(:inserted_ids)
    unreferenced = 0
    ids.each_slice(1000) do |batch|
      # The IDs are validated integers from the destination, not settings/SQL.
      unreferenced += ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM uploads u WHERE u.id IN (#{batch.join(',')}) AND NOT EXISTS (SELECT 1 FROM upload_references r WHERE r.upload_id = u.id)").to_i
    end
    state[:row_counts] = { "upload_rows_inserted" => ids.size, "upload_rows_inserted_without_references" => unreferenced }
    emit(state, phase: "postflight", complete: true)
  end

  def emit(state, phase:, complete:)
    report = { "version" => 1, "engine" => "discourse-merger-v1", "phase" => phase, "complete" => complete,
      "physical_policy" => ENV.fetch("SILO_MERGE_UPLOAD_COPY_POLICY"), "audit_aggregates" => state.fetch(:audit) }
    report["transfer"] = state[:transfer] if state[:transfer]
    report["manifest_sha256"] = state[:manifest_sha256] if state[:manifest_sha256]
    report["baseline_sha256"] = state[:baseline_sha256] if state[:baseline_sha256]
    report["references_sha256"] = state[:references_sha256] if state[:references_sha256]
    report["bookkeeping_references"] = state[:bookkeeping_references] if state.key?(:bookkeeping_references)
    report.merge!(state[:row_counts]) if state[:row_counts]
    STDOUT.write("SILO_MERGE_PROCESS:" + JSON.generate(report) + "\n")
    STDOUT.flush
  end
end
