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

# Loading the stock file doesn't start it: it only runs itself when it is the program.
require "/var/www/discourse/script/bulk_import/discourse_merger.rb"

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
puts "SILO_MERGE: start layer=#{layer ? 'yes' : 'no'}"
merger.new.start
run_check.call(:silo_merge_postflight!)
puts "SILO_MERGE: done"
