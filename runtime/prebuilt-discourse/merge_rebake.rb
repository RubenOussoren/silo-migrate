# frozen_string_literal: true

# Finalize's rebake of every post, without a site-setting write (rails runner).
#
# The stock posts:rebake task assigns SiteSetting.disable_system_edit_notifications before its
# loop and assigns it back afterwards, which stores an override row where there was none. A
# merge run may write no setting except the stock merger's own temporary one, so this does
# what that task's loop does, through the same model API, and leaves every setting alone:
#   Post.update_all(baked_version: nil), then post.rebake!(priority: :ultra_low) for each post.
# Post is used with its default scope throughout, as the task uses it: deleted posts are not
# counted, reset, rebaked or checked.
#
# rebake! cooks the post and stores cooked/baked_version before it returns; its follow-up jobs
# are queued exactly as the task queues them and are not run or waited for here. Its return
# value only says whether the cooked HTML changed: false is a rebaked post too.
#
# Unlike the task, the first exception ends the run (the task prints it and carries on), and
# completion is claimed only when: the stored settings matched the snapshot before and after,
# as many posts were rebaked as were counted before the loop, and no post is left without the
# current baked_version. A setting found changed is reported, never repaired.
#
# Needs SILO_MERGE_SITE_SETTINGS_SHA256 and the snapshot at its fixed path (merge_site_settings.rb).
# Prints nothing but one of these, never a post, an id, a setting value or an exception message:
#   stdout, last line, exit 0:  "SILO_MERGE_REBAKE: posts=<count>"
#   stderr, exit 4:             "SILO_MERGE_REBAKE: settings <tag>"
#   stderr, exit 1:             "SILO_MERGE_REBAKE: failed (<class>[ caused by <class>]...)"
#                               ("failed (early-exit)" when core or a plugin exits with success)
# Tags: the snapshot ones from merge_site_settings.rb, changed-before-rebake, changed-by-rebake,
# unproven-before-rebake, unproven-after-rebake (the settings couldn't be read). After a
# failure the settings are still compared, and a proven difference adds the settings line
# (exit 4); if they can't be read then, the failure line stands alone and claims nothing.
SILO_MERGE_RUNNER = true unless defined?(SILO_MERGE_RUNNER) # merge_site_settings.rb as a library only
require_relative "merge_site_settings"

module SiloMergeRebake
  BATCH = 1000
  STALE_SQL = "baked_version IS NULL OR baked_version <> ?"

  # Jobs are set to run inline in this process: rebaking would run the follow-up jobs here
  # instead of queueing them. That isn't the stock task's behaviour, so nothing is started.
  class InlineJobs < StandardError; end

  # The loop saw a different number of posts than were counted before it.
  class CountMismatch < StandardError; end

  # A post is still without the current baked_version after the loop.
  class StalePosts < StandardError; end

  module_function

  # "clean", "changed" or "unproven" (nothing could be read).
  def settings_state(snapshot)
    report = SiloMergeSiteSettings.verify(snapshot)
    return "clean" if report["state"] == "clean"

    report["remaining_differences"].nil? ? "unproven" : "changed"
  end

  # Returns the number of posts rebaked; raises on the first failure.
  def rebake_all
    raise InlineJobs if Jobs.run_immediately?

    total = Post.count
    # As the stock task does: afterwards a current marker can only come from this run.
    Post.update_all(baked_version: nil)
    rebaked = 0
    Post.find_each(batch_size: BATCH) do |post|
      post.rebake!(priority: :ultra_low)
      rebaked += 1
    end
    raise CountMismatch unless rebaked == total
    raise StalePosts if Post.where(STALE_SQL, Post::BAKED_VERSION).exists?

    rebaked
  end
end

refuse = lambda do |tag|
  warn "SILO_MERGE_REBAKE: settings #{tag}"
  exit 4
end

snapshot = begin
  SiloMergeSiteSettings.load_snapshot
rescue SiloMergeSiteSettings::Refused => e
  refuse.call(e.tag)
end

finished = false
begin
  state = SiloMergeRebake.settings_state(snapshot)
  refuse.call("#{state}-before-rebake") unless state == "clean"
  rebaked = SiloMergeRebake.rebake_all
  state = SiloMergeRebake.settings_state(snapshot)
  refuse.call(state == "changed" ? "changed-by-rebake" : "unproven-after-rebake") unless state == "clean"
  finished = true
rescue StandardError, ScriptError => e
  # Classes only, the cause chain included: a message can quote a post or a setting.
  causes = []
  cause = e.cause
  while cause && causes.size < 4 && !causes.include?(cause.class)
    causes << cause.class
    cause = cause.cause
  end
  warn "SILO_MERGE_REBAKE: failed (#{[e.class, *causes].join(' caused by ')})"
  changed = begin
    SiloMergeRebake.settings_state(snapshot) == "changed"
  rescue StandardError, ScriptError
    false
  end
  refuse.call("changed-by-rebake") if changed
  exit 1
ensure
  # Core or plugin code leaving early is never success, whatever status it chose. A failed
  # exit and a signal pass through as they are.
  pending = $!
  if !finished && (pending.nil? || (pending.is_a?(SystemExit) && pending.success?))
    warn "SILO_MERGE_REBAKE: failed (early-exit)"
    exit 1
  end
end
# On the real standard output, whatever core did to $stdout.
STDOUT.write("SILO_MERGE_REBAKE: posts=#{rebaked}\n")
STDOUT.flush
