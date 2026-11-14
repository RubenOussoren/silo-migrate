# frozen_string_literal: true

# A merge run's entry point: Discourse's own merger (script/bulk_import/discourse_merger.rb,
# loaded unedited), optionally with one project merge layer on top.
#
# A layer is a Ruby file from the project's converter checkout. It defines exactly one
# subclass of BulkImport::DiscourseMerger and changes behaviour by overriding its methods
# (and calling super). Customer values don't belong in the layer: it reads them from the
# YAML file named by SILO_MERGE_SETTINGS, which only the run supplies.
#
# The stock script connects to PostgreSQL as "postgres" on localhost. Here the database is
# another container and the site's role is "discourse", so exactly those two connections
# (the site's database and the source copy) use the site's own database settings instead.
# Rails' connections are untouched.
require "pg"

module SiloMergeConnection
  def connect(*args, **kwargs, &block)
    options = args.first.is_a?(Hash) ? args.first.dup : kwargs.dup
    names = [ENV.fetch("DB_NAME"), ENV.fetch("DISCOURSE_DB_NAME", "discourse")]
    return super unless options[:user] == "postgres" && names.include?(options[:dbname])

    options.merge!(
      host: ENV.fetch("DISCOURSE_DB_HOST"),
      port: Integer(ENV.fetch("DISCOURSE_DB_PORT", "5432")),
      user: "discourse",
      password: ENV.fetch("DISCOURSE_DB_PASSWORD"),
    )
    super(**options, &block)
  end
end
PG.singleton_class.prepend(SiloMergeConnection)

# Site settings: the host captured every stored setting before any merge code loaded and
# names the snapshot's SHA-256. Without that snapshot the run refuses: it never runs unprotected.
# The only write allowed is the stock constructor's temporary authorized_extensions, kept
# while copying and put back (row, value, type, or absence) before the postflight check.
SILO_MERGE_RUNNER = true
require_relative "merge_site_settings"

refuse = lambda do |tag|
  warn "SILO_MERGE: settings #{tag}"
  exit 4
end

snapshot = begin
  SiloMergeSiteSettings.load_snapshot
rescue SiloMergeSiteSettings::Refused => e
  refuse.call(e.tag)
end

finished = false
reported = false
report = nil
begin
  # Loading the stock file doesn't start it: it only runs itself when it is the program.
  require "/var/www/discourse/script/bulk_import/discourse_merger.rb"

  guard = lambda do |tag, window: false|
    report = window ? SiloMergeSiteSettings.verify_stock_window(snapshot) : SiloMergeSiteSettings.verify(snapshot)
    refuse.call(tag) unless report["state"] == "clean"
  end
  guard.call("changed-before-layer")

  merger = BulkImport::DiscourseMerger
  if (layer = ENV["SILO_MERGE_LAYER"])
    begin
      require layer
    rescue ScriptError, StandardError => e
      # The class only: a message can quote values.
      warn "SILO_MERGE: layer failed to load (#{e.class})"
      exit 3
    end
    layers = BulkImport::DiscourseMerger.subclasses
    unless layers.size == 1
      warn "SILO_MERGE: layer must define exactly one subclass of BulkImport::DiscourseMerger (found #{layers.size})"
      exit 3
    end
    merger = layers.first
  end
  guard.call("changed-by-layer-load")

  # Prepared custom merges must validate destination policy before the stock constructor
  # writes settings, and validate the resulting ACLs before the host finalizes/backs up.
  # These hooks are reviewed project code, not proof by themselves that a policy is correct.
  required_checks = ENV["SILO_MERGE_REQUIRE_CHECKS"] == "1"
  checks = %i[silo_merge_preflight! silo_merge_postflight!]
  if required_checks && (!layer || checks.any? { |hook| !merger.respond_to?(hook) })
    warn "SILO_MERGE: layer must define preflight and postflight policy checks"
    exit 3
  end

  run_check = lambda do |hook|
    next unless required_checks

    begin
      result = merger.public_send(hook)
      raise "check refused" unless result == true
    rescue Exception => e # includes a layer's SystemExit; a hook cannot signal success by exiting
      # Never surface an exception message: it may contain a customer name/value.
      warn "SILO_MERGE: layer policy check failed (#{e.class})"
      exit 3
    end
  end

  run_check.call(:silo_merge_preflight!)
  guard.call("changed-by-preflight")
  puts "SILO_MERGE: start layer=#{layer ? 'yes' : 'no'}"
  instance = merger.new
  # Only the stock assignment may differ now, and it stays while uploads are copied.
  guard.call("changed-by-constructor", window: true)
  instance.start
  guard.call("changed-during-copy", window: true)
  report = SiloMergeSiteSettings.restore(snapshot)
  refuse.call("restore-unproven") unless report["state"] == "restored"
  run_check.call(:silo_merge_postflight!)
  guard.call("changed-by-postflight")
  finished = true
rescue StandardError, ScriptError => e
  # The stock merger's (or a layer's) message can quote setting or customer values: classes
  # only, the cause chain included, so the host still tells a schema mismatch
  # (PG::UndefinedColumn, often wrapped in ActiveRecord::StatementInvalid) apart. Exits and
  # signals aren't caught here; the ensure below handles every path the same way.
  causes = []
  cause = e.cause
  while cause && causes.size < 4 && !causes.include?(cause.class)
    causes << cause.class
    cause = cause.cause
  end
  warn "SILO_MERGE: merger failed (#{[e.class, *causes].join(' caused by ')})"
  exit 1
ensure
  # Every way out (a layer's exit, an exception, a signal Ruby raises) puts back the stock
  # assignment only; any other changed setting is reported, never repaired. A hard kill skips
  # this: the host then restores from the same snapshot.
  unless finished
    report = begin
      SiloMergeSiteSettings.restore(snapshot)
    rescue Exception # a second signal must not lose the report
      SiloMergeSiteSettings.unproven_report
    end
  end
  # Exactly one report line, on the real standard output whatever a layer did to $stdout.
  unless reported
    reported = true
    STDOUT.write("SILO_SETTINGS_REPORT:" + JSON.generate(report || SiloMergeSiteSettings.unproven_report) + "\n")
    STDOUT.flush
  end
  unless finished
    warn "SILO_MERGE: settings restore-unproven" unless report && report["state"] == "restored"
    pending = $!
    # Leaving early is never success, whatever status a layer chose.
    if pending.nil? || (pending.is_a?(SystemExit) && pending.success?)
      warn "SILO_MERGE: settings early-exit"
      exit 4
    end
  end
end
STDOUT.write("SILO_MERGE: done\n")
STDOUT.flush
