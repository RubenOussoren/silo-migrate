# frozen_string_literal: true
# Runs the generic bulk importer (and the import:ensure_consistency pass it runs itself)
# with Sidekiq and the scheduler paused. On a live site, background work (e.g.
# PeriodicalUpdates rebaking posts that have no baked_version) updates the same rows as
# the importer's bulk UPDATEs and deadlocks them (seen on arc's first review import).
#
# Discourse's own Sidekiq.pause! is a 60-second lease renewed by a thread, which can lapse
# while the importer holds the GVL in long SQLite steps. So the pause key is set without
# an expiry and deleted at the end. Sidekiq.paused? and MiniScheduler's skip_schedule read
# the same key. A killed import leaves its (failed, dirty) site paused until reset.
# Usage: ruby review_import.rb INTERMEDIATE_DB (from the Discourse root)
abort "REVIEW_IMPORT_REFUSED: usage" unless ARGV.size == 1

intermediate = ARGV.first
require File.join(Dir.pwd, "script/bulk_import/generic_bulk") # loads Rails; doesn't run (main-program guard)
require "sidekiq/api"

def busy
  { "jobs" => Sidekiq::Workers.new.size, "scheduled" => MiniScheduler::Manager.discover_running_scheduled_jobs.size }
end

def clock
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

Discourse.redis.set(SidekiqPauser::PAUSED_KEY, "silo-migrate review import")
begin
  # Work already started finishes first, as before a backup restore. Sidekiq publishes
  # its workers every 10 seconds (BEAT_PAUSE) and a queued scheduled job starts within
  # moments: idle twice, 11 seconds apart (a heartbeat inside each interval).
  deadline = clock + 600
  idle = 0
  while idle < 2
    sleep 11
    idle = busy.values.sum.zero? ? idle + 1 : 0
    abort "REVIEW_IMPORT_REFUSED: background jobs still running" if idle < 2 && clock > deadline
  end
  abort "REVIEW_IMPORT_REFUSED: Sidekiq not paused" unless Sidekiq.paused?

  puts "SILO_SIDEKIQ: paused=true running=0 (before import)"
  BulkImport::Generic.new(intermediate).start
  abort "REVIEW_IMPORT_REFUSED: Sidekiq pause lost during the import" unless Sidekiq.paused?

  puts "SILO_SIDEKIQ: paused=true (after import)"
ensure
  Discourse.redis.del(SidekiqPauser::PAUSED_KEY)
end
