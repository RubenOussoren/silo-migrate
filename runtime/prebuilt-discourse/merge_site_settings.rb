# frozen_string_literal: true

# Site-setting preservation for a merge run.
#
# The stock merger's constructor assigns SiteSetting.authorized_extensions so it can copy
# uploads. That one temporary assignment is the only site-setting write a merge run may make;
# a layer and its checks make none. The host captures every stored setting before any merge
# code loads; the runner (merge_run.rb) and the host compare against that snapshot, and the
# prior authorized_extensions override (exact raw value and type, or its absence) is put back
# before the run can finish. No other setting is ever written here: a different setting is
# reported, never repaired.
#
# Snapshot, JSON (raw values: private captures only, never normal logs):
#   {"version":1, "settings":{name=>[raw_value_or_null, data_type]},   # every stored row
#    "authorized_extensions_effective":"..."}
# Report, JSON (names and counts, never values):
#   {"version":1, "state":"restored"|"unproven" (restore) / "clean"|"dirty" (verify, window),
#    "restoration_failed":[names], "unexpected_names":[names],
#    "remaining_differences":integer|null, "effective_matches":true|false|null}
#
# As a standalone script (rails runner) with SILO_MERGE_SITE_SETTINGS_ACTION:
#   capture -> one "SILO_SETTINGS_SNAPSHOT:<json>" line
#   restore / verify -> reads SNAPSHOT_PATH, checks SILO_MERGE_SITE_SETTINGS_SHA256, prints one
#   "SILO_SETTINGS_REPORT:<json>" line; exit 0 only when restored/clean. With
#   SILO_MERGE_SITE_SETTINGS_EXECUTION_UNCERTAIN=1, restore writes nothing and is "unproven".
# Errors are fixed tags ("SILO_SETTINGS_ERROR: <tag>"); messages are never printed.
require "digest"
require "json"

module SiloMergeSiteSettings
  VERSION = 1
  NAME = "authorized_extensions"
  STOCK_VALUE = "jpg|jpeg|png|gif"
  SNAPSHOT_PATH = "/shared/merge/site-settings.json"
  DIGEST_ENV = "SILO_MERGE_SITE_SETTINGS_SHA256"
  # Set by the host when it can't confirm the merge process has stopped: restore only reads.
  UNCERTAIN_ENV = "SILO_MERGE_SITE_SETTINGS_EXECUTION_UNCERTAIN"
  KEYS = %w[authorized_extensions_effective settings version].freeze
  ROWS_SQL = "SELECT name, value, data_type FROM site_settings ORDER BY name"

  # A refusal with a fixed tag; the tag is the only thing ever shown.
  class Refused < StandardError
    attr_reader :tag

    def initialize(tag)
      @tag = tag
      super(tag)
    end
  end

  module_function

  def capture
    { "version" => VERSION, "settings" => stored_rows, "authorized_extensions_effective" => effective }
  end

  # Reads the fixed snapshot file, bound to the expected SHA-256 (hex).
  def load_snapshot(path = SNAPSHOT_PATH, digest = ENV[DIGEST_ENV])
    raise Refused, "snapshot-digest-missing" unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)

    bytes = begin
      File.binread(path)
    rescue SystemCallError, IOError
      raise Refused, "snapshot-missing"
    end
    raise Refused, "snapshot-digest-mismatch" unless Digest::SHA256.hexdigest(bytes) == digest

    snapshot = begin
      JSON.parse(bytes.dup.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError, EncodingError
      raise Refused, "snapshot-invalid"
    end
    validate!(snapshot)
  end

  def validate!(snapshot)
    ok = snapshot.is_a?(Hash) && snapshot.keys.sort == KEYS && snapshot["version"] == VERSION &&
         snapshot["settings"].is_a?(Hash) && snapshot["authorized_extensions_effective"].is_a?(String) &&
         snapshot["settings"].all? do |name, entry|
           name.is_a?(String) && entry.is_a?(Array) && entry.size == 2 &&
             (entry[0].nil? || entry[0].is_a?(String)) && entry[1].is_a?(Integer)
         end
    raise Refused, "snapshot-invalid" unless ok

    snapshot
  end

  # The snapshot's own state, exactly: every stored row and the effective value.
  def verify(snapshot)
    validate!(snapshot)
    compare(snapshot, allow_stock: false, success: "clean", failure: "dirty")
  end

  # While copying: no stored setting except authorized_extensions may differ, and that one
  # only as the stock constructor's own assignment (exact value and type).
  def verify_stock_window(snapshot)
    validate!(snapshot)
    compare(snapshot, allow_stock: true, success: "clean", failure: "dirty")
  end

  # Puts back the prior authorized_extensions override (or its absence) and nothing else.
  #
  # allow_write: false is for when the merge process may still be running (the host couldn't
  # confirm it stopped): writing then could race it, so nothing is written, the actual
  # differences are reported and the state is "unproven" whatever they are. Such a site stays
  # dirty until an engineer has checked it; there is no automatic restoration for that case.
  def restore(snapshot, allow_write: true)
    validate!(snapshot)
    unless allow_write
      return compare(snapshot, allow_stock: false, success: "unproven", failure: "unproven")
    end

    failed = false
    begin
      restore_authorized!(snapshot) unless authorized_matches?(snapshot, stored_rows, effective)
    rescue StandardError, ScriptError
      failed = true
    end
    report = compare(snapshot, allow_stock: false, success: "restored", failure: "unproven")
    report["state"] = "unproven" if failed
    report["restoration_failed"] = [NAME] if failed
    report
  end

  # A report for when nothing could be read: claims nothing.
  def unproven_report
    { "version" => VERSION, "state" => "unproven", "restoration_failed" => [NAME], "unexpected_names" => [],
      "remaining_differences" => nil, "effective_matches" => nil }
  end

  # --- internals ---------------------------------------------------------------------------

  # Straight from the table: never ActiveRecord's query cache, never SiteSetting's own cache.
  def stored_rows
    ActiveRecord::Base.uncached do
      ActiveRecord::Base.connection.select_rows(ROWS_SQL).to_h { |name, value, type| [name.to_s, [value&.to_s, Integer(type)]] }
    end
  end

  def effective
    SiteSetting.authorized_extensions.to_s
  end

  def authorized_matches?(snapshot, rows, current_effective, allow_stock: false)
    return true if rows[NAME] == snapshot["settings"][NAME] && current_effective == snapshot["authorized_extensions_effective"]
    return false unless allow_stock && current_effective == STOCK_VALUE

    rows[NAME] == [STOCK_VALUE, Integer(SiteSetting.type_supervisor.to_db_value(NAME.to_sym, STOCK_VALUE).last)]
  end

  def compare(snapshot, allow_stock:, success:, failure:)
    current = stored_rows
    current_effective = effective
    expected = snapshot["settings"]
    unexpected = (expected.keys | current.keys).reject { |name| name == NAME || expected[name] == current[name] }.sort
    authorized_ok = authorized_matches?(snapshot, current, current_effective, allow_stock: allow_stock)
    clean = unexpected.empty? && authorized_ok
    { "version" => VERSION, "state" => clean ? success : failure,
      "restoration_failed" => authorized_ok ? [] : [NAME], "unexpected_names" => unexpected,
      "remaining_differences" => unexpected.size + (authorized_ok ? 0 : 1),
      "effective_matches" => current_effective == snapshot["authorized_extensions_effective"] ||
                             (allow_stock && current_effective == STOCK_VALUE) }
  rescue StandardError, ScriptError
    unproven_report.merge("state" => failure)
  end

  # Writes the authorized_extensions override only, through the provider the public setter
  # itself saves with (so the setter's normalisation can't change the raw value or type), then
  # reloads SiteSetting from the table. Raises unless a fresh read and the getter then match.
  def restore_authorized!(snapshot)
    want = snapshot["settings"][NAME]
    # The provider finds the row through ActiveRecord: a cached lookup could miss a change.
    ActiveRecord::Base.uncached do
      if want.nil?
        SiteSetting.remove_override!(NAME.to_sym)
      else
        SiteSetting.provider.save(NAME, want[0], want[1])
      end
    end
    SiteSetting.refresh!
    raise Refused, "restore-unproven" unless authorized_matches?(snapshot, stored_rows, effective)
  end

  def run_action(action)
    case action
    when "capture"
      puts "SILO_SETTINGS_SNAPSHOT:" + JSON.generate(capture)
      return 0
    when "restore", "verify"
      report = if action == "restore"
                 restore(load_snapshot, allow_write: ENV[UNCERTAIN_ENV] != "1")
               else
                 verify(load_snapshot)
               end
      puts "SILO_SETTINGS_REPORT:" + JSON.generate(report)
      return 0 if %w[restored clean].include?(report["state"])

      warn "SILO_SETTINGS_ERROR: #{action == 'restore' ? 'restore-unproven' : 'settings-changed'}"
    else
      warn "SILO_SETTINGS_ERROR: action-invalid"
    end
    4
  rescue Refused => e
    warn "SILO_SETTINGS_ERROR: #{e.tag}"
    4
  rescue StandardError, ScriptError => e
    warn "SILO_SETTINGS_ERROR: failed (#{e.class})"
    4
  end
end

# Standalone (rails runner); the merge runner loads this file as a library only.
if ENV["SILO_MERGE_SITE_SETTINGS_ACTION"] && !defined?(SILO_MERGE_RUNNER)
  exit SiloMergeSiteSettings.run_action(ENV["SILO_MERGE_SITE_SETTINGS_ACTION"])
end
