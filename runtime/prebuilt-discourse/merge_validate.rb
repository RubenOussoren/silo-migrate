# frozen_string_literal: true

require "json"
require "digest"
if File.file?(File.expand_path("../shared/merge_contract.rb", __dir__))
  require_relative "../shared/merge_contract"
  require_relative "../shared/merge_refusal"
else
  require_relative "merge_contract"
  require_relative "merge_refusal"
end

# Engine-specific class-only validator. All returned data is PRIVATE, including
# exact-check names/paths and source IDs. stdout is a smaller fixed-key projection.
module SiloMergeValidation
  PREFIX = "SILO_MERGE_VALIDATION:"
  MAX_ROWS = 100_000
  RESULT_KEYS = %w[version status reason key_path approved_ids selected_ids_sha256 audit checks asset_preflight_sha256 selection_sha256 owner_preflight_sha256].freeze
  class Refused < StandardError; end
  FINDING_CODES = %w[unknown_source_id destination_exists destination_missing destination_ambiguous policy_conflict permission_unproven selection_unproven schema_unsupported].freeze
  # A reviewed layer can identify the offending settings key without putting
  # customer values into exception messages or requiring free-form log parsing.
  class Finding < StandardError
    attr_reader :key_path, :reason
    def initialize(key_path, reason)
      key_path = key_path.map { |part| part.is_a?(String) ? part.encode(Encoding::UTF_8) : part } if key_path.is_a?(Array) && key_path.size <= 32
      unless FINDING_CODES.include?(reason) && key_path.is_a?(Array) && key_path.size <= 32 && key_path.all? do |part|
        (part.is_a?(String) && part.valid_encoding? && part.bytesize.between?(1, 256) && !part.match?(/[[:cntrl:]]/)) ||
          (part.is_a?(Integer) && part.between?(0, 999_999_999_999))
      end
        raise ArgumentError, "MERGE_FINDING_INVALID", cause: nil
      end
      @key_path = key_path.map { |part| part.is_a?(String) ? part.dup.freeze : part }.freeze
      @reason = reason.dup.freeze
      super("MERGE_VALIDATION_FINDING")
    rescue EncodingError
      raise ArgumentError, "MERGE_FINDING_INVALID", cause: nil
    end
  end
  module_function

  def refuse!(reason)
    raise Refused, reason
  end

  def request!(checks)
    refuse!("checks_invalid") unless checks.is_a?(Array) && checks.size <= 100
    checks.each do |check|
      refuse!("checks_invalid") unless check.is_a?(Hash) && %w[category group tag].include?(check["kind"])
      if check["kind"] == "category"
        refuse!("checks_invalid") unless check.keys.sort == %w[kind path] && check["path"].is_a?(Array) && check["path"].size.between?(1, 32)
        names = check["path"]
      else
        refuse!("checks_invalid") unless check.keys.sort == %w[kind name]
        names = [check["name"]]
      end
      refuse!("checks_invalid") unless names.all? { |name| name.is_a?(String) && name.valid_encoding? && name.bytesize.between?(1, 256) && !name.match?(/[[:cntrl:]]/) }
    end
    refuse!("checks_invalid") if JSON.generate(checks).bytesize > 64 * 1024
    checks
  end

  # Callback executes a parameterized SELECT and returns complete rows, or nil
  # when completeness/availability is unknown. Whole names use core's
  # case-insensitive creation-uniqueness semantics, never LIKE/prefix/suffix
  # matching. Categories require every component from a NULL parent root.
  def existence(checks, query: nil)
    request!(checks)
    checks.map do |check|
      state = "unproven"
      count = nil
      begin
        if query
          if check["kind"] == "category"
            parent = nil
            check.fetch("path").each do |name|
              rows = query.call("SELECT id FROM categories WHERE lower(name) = lower($1) AND parent_category_id IS NOT DISTINCT FROM $2 LIMIT 2", [name, parent])
              state, count = rows_state(rows)
              break unless state == "found"
              parent = Integer(rows.first.fetch("id"))
              refuse!("checks_invalid") unless parent.positive?
            end
          else
            table = check["kind"] == "group" ? "groups" : "tags"
            rows = query.call("SELECT id FROM #{table} WHERE lower(name) = lower($1) LIMIT 2", [check.fetch("name")])
            state, count = rows_state(rows)
          end
        end
      rescue StandardError
        state, count = "unproven", nil
      end
      { "status" => state, "count" => count }
    end
  end

  def rows_state(rows)
    return ["unproven", nil] unless rows.is_a?(Array) && rows.size <= 2 && rows.all? { |row| row.is_a?(Hash) && row.keys == ["id"] && row["id"].to_s.match?(/\A[1-9][0-9]*\z/) }
    return ["absent", 0] if rows.empty?
    return ["ambiguous", 2] if rows.size == 2
    ["found", 1]
  end

  # asset_preflight must run the Discourse adapter's pure prepare! and return its
  # preflight_manifest_digest. No transfer! call is reachable from validation.
  def run!(merger:, contract:, settings:, checks: [], query: nil, asset_preflight: nil)
    result = { "version" => 1, "status" => "refused", "reason" => "validation_unproven", "key_path" => [],
               "approved_ids" => [], "selected_ids_sha256" => Digest::SHA256.hexdigest("[]"), "audit" => {}, "checks" => [], "asset_preflight_sha256" => nil, "selection_sha256" => nil, "owner_preflight_sha256" => nil }
    old_policy = ENV["SILO_MERGE_UPLOAD_COPY_POLICY"]
    old_protocol = ENV["SILO_MERGE_ASSET_PROTOCOL"]
    audit_ready = false
    audit_snapshot = nil
    failure_error = nil
    begin
      refuse!("validation_unproven") unless contract["engine"] == "discourse-merger-v1"
      policy = SiloMergeContract.validate_settings!(contract, settings).fetch("physical_policy")
      ENV["SILO_MERGE_UPLOAD_COPY_POLICY"] = policy
      ENV["SILO_MERGE_ASSET_PROTOCOL"] = "1"
      request!(checks)
      hooks = %i[silo_merge_preflight! silo_merge_asset_ids silo_merge_audit]
      refuse!("hooks_missing") unless merger.is_a?(Class) && hooks.all? { |hook| merger.respond_to?(hook) }
      audit_ready = true
      refuse!("preflight_refused") unless merger.silo_merge_preflight! == true
      ids = merger.silo_merge_asset_ids
      refuse!("asset_selection_invalid") unless ids.is_a?(Array) && ids.size <= MAX_ROWS && ids.all? { |id| id.is_a?(Integer) && id.between?(1, 2**63 - 1) } && ids.uniq == ids
      ids = ids.sort
      result["approved_ids"] = ids
      result["selected_ids_sha256"] = Digest::SHA256.hexdigest(JSON.generate(ids))
      result["audit"] = SiloMergeContract.audit!(contract, "preflight", merger.silo_merge_audit("preflight"))
      audit_snapshot = result["audit"]
      result["checks"] = existence(checks, query: query)
      refuse!("checks_invalid") if result["checks"].any? { |answer| answer["status"] == "unproven" }
      # Existence answers are facts, not universally required-found policy.
      # The layer's mandatory preflight owns semantic acceptance.
      refuse!("assets_unproven") unless asset_preflight
      prepared = asset_preflight.call(merger, ids, policy)
      refuse!("assets_unproven") unless prepared.respond_to?(:preflight_manifest_digest) && prepared.respond_to?(:selection_digest) && prepared.respond_to?(:owner_preflight_digest)
      digest, selection = prepared.preflight_manifest_digest, prepared.selection_digest
      owner_digest = prepared.owner_preflight_digest
      refuse!("assets_unproven") unless [digest, selection, owner_digest].all? { |value| value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/) }
      result["asset_preflight_sha256"], result["selection_sha256"], result["owner_preflight_sha256"] = digest, selection, owner_digest
      result["status"], result["reason"] = "passed", "ok"
    rescue Finding => error
      failure_error = error
      result["reason"], result["key_path"] = error.reason, error.key_path
    rescue SiloMergeContract::Error => error
      failure_error = error
      result["reason"], result["key_path"] = "audit_invalid", error.key_path
    rescue Refused => error
      failure_error = error
      result["reason"] = error.message
    rescue Exception => error # A reviewed hook's SystemExit cannot skip a typed refusal.
      failure_error = error
      # Adapter refusals are known asset failures, not boot/protocol failures.
      # Never relay their message, tag or paths into the public projection.
      asset_error = defined?(SiloDiscourseMergeAdapter::Error) && error.is_a?(SiloDiscourseMergeAdapter::Error)
      result["reason"] = asset_error ? "assets_unproven" : "validation_unproven"
    ensure
      if audit_ready && result["status"] == "refused"
        begin
          # Inspect the same loaded class's declared counters after refusal. Never
          # invoke selection, construction or transfers, and never parse its logs.
          options = { contract: contract, merger: merger, phase: "preflight", context: "validation",
            reason: result.fetch("reason"), error: failure_error }
          options[:audit_value] = audit_snapshot unless audit_snapshot.nil?
          failure = SiloMergeRefusal.capture(**options)
          result["failure"] = failure
          result["audit"] = failure.fetch("counts")
        rescue Exception
          # Optional diagnostics must not replace the primary refusal, including
          # when the collector itself cannot produce a trustworthy envelope.
        end
      end
      old_policy.nil? ? ENV.delete("SILO_MERGE_UPLOAD_COPY_POLICY") : ENV["SILO_MERGE_UPLOAD_COPY_POLICY"] = old_policy
      old_protocol.nil? ? ENV.delete("SILO_MERGE_ASSET_PROTOCOL") : ENV["SILO_MERGE_ASSET_PROTOCOL"] = old_protocol
    end
    result
  end

  # PG uses text decoding by default. Convert only the trusted narrow integer
  # fields; never relax the adapter's typed input contract or coerce policy data.
  def upload_rows(rows)
    refuse!("assets_unproven") unless rows.is_a?(Array) && rows.size <= MAX_ROWS
    rows.map do |row|
      refuse!("assets_unproven") unless row.is_a?(Hash)
      row.merge("id" => Integer(row.fetch("id")), "filesize" => Integer(row.fetch("filesize")))
    end
  rescue KeyError, ArgumentError, TypeError
    refuse!("assets_unproven")
  end

  # Stock skips insertion for a positive source owner without a primary email.
  # A required upload with proven destination digest reuse is unaffected. This
  # is input feasibility, not construction or an invented user-mapping algorithm.
  def required_owners!(source, source_rows, destination_rows, ids)
    reused = destination_rows.to_h { |row| [row.fetch("sha1"), true] }
    required = ids.to_h { |id| [id, true] }
    pending = source_rows.select { |row| required[row.fetch("id")] && !reused[row.fetch("sha1")] }.map { |row| row.fetch("id") }
    pending.each_slice(1000) do |batch|
      slots = batch.each_index.map { |index| "$#{index + 1}" }.join(",")
      sql = "SELECT uploads.id FROM uploads WHERE uploads.id IN (#{slots}) AND uploads.user_id > 0 AND NOT EXISTS (SELECT 1 FROM users JOIN user_emails ON user_emails.user_id = users.id WHERE users.id = uploads.user_id AND user_emails.primary = TRUE AND user_emails.email IS NOT NULL AND user_emails.email <> '') LIMIT 1"
      refuse!("assets_unproven") unless source.exec_params(sql, batch).to_a.empty?
    end
    Digest::SHA256.hexdigest(JSON.generate(["required_owner_feasibility_v1", ids.sort, pending.sort]))
  end

  def source_upload_rows(source)
    rows = []
    cursor = nil
    loop do
      sql = "SELECT id, sha1, original_sha1, secure, url, filesize FROM uploads"
      batch = if cursor.nil?
        source.exec_params("#{sql} ORDER BY id LIMIT 1000", []).to_a
      else
        source.exec_params("#{sql} WHERE id > $1 ORDER BY id LIMIT 1000", [cursor]).to_a
      end
      break if batch.empty?
      rows.concat(upload_rows(batch))
      refuse!("assets_unproven") if rows.size > MAX_ROWS
      next_cursor = rows.last.fetch("id")
      refuse!("assets_unproven") if cursor && next_cursor <= cursor
      cursor = next_cursor
    end
    rows
  end

  def destination_upload_rows(connection, sha1s)
    rows = []
    sha1s.uniq.each_slice(1000) do |hashes|
      refuse!("assets_unproven") unless hashes.all? { |hash| hash.is_a?(String) && hash.match?(/\A[0-9a-f]{40}\z/) }
      slots = hashes.each_index.map { |index| "$#{index + 1}" }.join(",")
      batch = connection.exec_params("SELECT id, sha1, original_sha1, secure, url, filesize FROM uploads WHERE sha1 IN (#{slots}) LIMIT 100001", hashes).to_a
      rows.concat(upload_rows(batch))
      refuse!("assets_unproven") if rows.size > MAX_ROWS
    end
    rows
  end

  def private_json(path, limit: 256 * 1024)
    File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
      stat = file.stat
      refuse!("validation_unproven") unless stat.file? && [0, Process.uid].include?(stat.uid) && (stat.mode & 0o077).zero? && stat.size <= limit
      SiloMergeContract.parse(file.read(limit + 1), max_bytes: limit)
    end
  end

  # Public protocol never includes approved IDs or customer settings, paths or
  # exception messages. Parent copies the private result file out separately.
  def projection(result)
    result.slice("version", "status", "reason", "selected_ids_sha256", "asset_preflight_sha256", "selection_sha256").merge("key_path" => [])
  end

  def main!
    result = nil
    # Capture arbitrary layer/boot stdout AND stderr to a private sink; never relay
    # these streams. Do not rescue and print Rails/PG exceptions.
    output = STDOUT.dup
    sink = File.open(File::NULL, "w")
    STDOUT.reopen(sink)
    STDERR.reopen(sink)
    begin
      context = private_json(ENV.fetch("SILO_MERGE_VALIDATION_CONTEXT"))
      if context["mode"] == "checks"
        require "pg"
        connection = PG.connect(host: context.fetch("host"), port: context.fetch("port"), dbname: context.fetch("base"), user: context.fetch("role"), password: context.fetch("password"))
        answers = existence(context.fetch("checks"), query: ->(sql, values) { connection.exec_params(sql, values).to_a })
        proven = answers.none? { |answer| answer["status"] == "unproven" }
        result = { "version" => 1, "status" => proven ? "passed" : "refused", "reason" => proven ? "ok" : "checks_invalid", "key_path" => [],
                   "approved_ids" => [], "selected_ids_sha256" => Digest::SHA256.hexdigest("[]"), "selection_sha256" => nil, "audit" => {}, "checks" => answers, "asset_preflight_sha256" => nil, "owner_preflight_sha256" => nil }
      else
      refuse!("validation_unproven") unless ENV["SILO_MERGE_VALIDATION_CONFIG"]
      require "/var/www/discourse/config/environment"
      refuse!("validation_unproven") unless GlobalSetting.db_username == context.fetch("role") && GlobalSetting.db_name == context.fetch("base")
      contract = SiloMergeContract.load(File.binread(context.fetch("contract_path"), SiloMergeContract::MAX_BYTES + 1))
      settings_bytes = File.binread(context.fetch("settings_path"), 256 * 1024 + 1)
      refuse!("validation_unproven") if settings_bytes.bytesize > 256 * 1024
      require "yaml"
      settings = YAML.safe_load(settings_bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
      policy = SiloMergeContract.validate_settings!(contract, settings).fetch("physical_policy")
      ENV["SILO_MERGE_UPLOAD_COPY_POLICY"] = policy
      ENV["SILO_MERGE_ASSET_PROTOCOL"] = "1"
      Object.const_set(:SILO_MERGE_RUNNER, true) unless Object.const_defined?(:SILO_MERGE_RUNNER)
      require "/var/www/discourse/script/bulk_import/discourse_merger"
      require context.fetch("layer_path")
      layers = BulkImport::DiscourseMerger.subclasses
      refuse!("hooks_missing") unless layers.size == 1
      require_relative "merge_adapter"
      require_relative "merge_asset_references"
      require "pg"
      connection = PG.connect(host: context.fetch("host"), port: context.fetch("port"), dbname: context.fetch("base"), user: context.fetch("role"), password: context.fetch("password"))
      source = PG.connect(host: context.fetch("host"), port: context.fetch("port"), dbname: context.fetch("source"), user: context.fetch("role"), password: context.fetch("password"))
      query = ->(sql, parameters) { connection.exec_params(sql, parameters).to_a }
      preflight = lambda do |klass, ids, policy|
        source_rows = source_upload_rows(source)
        destination_rows = destination_upload_rows(connection, source_rows.map { |row| row.fetch("sha1") })
        owner_digest = required_owners!(source, source_rows, destination_rows, ids)
        prepared = SiloDiscourseMergeAdapter.prepare!(klass, source_rows: source_rows, destination_rows: destination_rows, approved_ids: ids, policy: policy,
                                            source_root: "/shared/source-uploads", destination_root: SiloDiscourseAssetReferences.destination_root(Rails.public_path))
        # Preserve the adapter digest exactly for the execution backstop while
        # retaining a separate private owner-feasibility shape attestation.
        Struct.new(:selection_digest, :preflight_manifest_digest, :owner_preflight_digest).new(
          prepared.selection_digest, prepared.preflight_manifest_digest, owner_digest)
      end
      result = run!(merger: layers.first, contract: contract, settings: settings, checks: context.fetch("checks", []), query: query, asset_preflight: preflight)
      end
    rescue Exception
      result = { "version" => 1, "status" => "refused", "reason" => "validation_unproven", "key_path" => [], "approved_ids" => [], "audit" => {}, "checks" => [],
                 "selected_ids_sha256" => Digest::SHA256.hexdigest("[]"), "asset_preflight_sha256" => nil, "selection_sha256" => nil, "owner_preflight_sha256" => nil }
    ensure
      begin
        # Always persist a typed refusal, including boot/load exceptions. The
        # host still refuses missing/unknown files or a child with unknown status.
        path = ENV.fetch("SILO_MERGE_VALIDATION_RESULT")
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |file| file.write(JSON.generate(result)); file.flush; file.fsync }
      rescue Exception
        result["status"], result["reason"] = "refused", "validation_unproven"
      end
      begin
        source&.close
        connection&.close
      rescue Exception
        result["status"], result["reason"] = "refused", "validation_unproven"
      end
      output.puts(PREFIX + JSON.generate(projection(result)))
      output.flush
      output.close
      sink.close
    end
    result["status"] == "passed" ? 0 : 4
  end
end

exit SiloMergeValidation.main! if $PROGRAM_NAME == __FILE__
