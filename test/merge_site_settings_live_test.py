"""Opt-in, INVENTED-DATA-only test of merge site-setting preservation on real Rails/PostgreSQL.

    SILO_MERGE_SITE_SETTINGS_LIVE=1 python3 -I -B test/merge_site_settings_live_test.py

Runs runtime/prebuilt-discourse/merge_site_settings.rb, unmodified, against the actual
SiteSetting API, cache and site_settings table of a new invented site: as the standalone
`rails runner` actions (capture/restore/verify with the fixed guest snapshot and its SHA-256)
and as the library the merge runner loads. The temporary write is the cached revision's own
stock statement, read from its merger file and executed verbatim.

What "preserved" means here: authorized_extensions has its prior stored raw value and data
type (or no stored row when there was none) and its prior effective value, and every other
stored (raw value, data type) pair is as it was. Row ids and timestamps of
authorized_extensions are NOT part of that. Another changed setting is named and counted,
never repaired, and no report carries a value.

`rails runner` runs with the ActiveRecord query cache on. The library test warms that cache
with the helper's own reads, then changes stored rows on the raw connection (ActiveRecord is
not told, as with the merger's own PostgreSQL connections) and requires every check and the
restore to read the table again. A control query proves the cache really was serving the old
answer at that moment.

The rebake check runs runtime/prebuilt-discourse/merge_rebake.rb, unmodified and standalone
(freshly captured snapshot, its SHA-256), over invented posts made by core's own PostCreator.
Every post must end with the current baked_version and its freshly cooked HTML, whether the
HTML changed or not; no stored setting pair may change, with disable_system_edit_notifications
(which the stock posts:rebake task writes) both absent and stored; no notification or revision
may appear. As with the stock task, rebake's follow-up jobs are only QUEUED (ultra_low): this
test shows they were queued and not run in the helper's process, and neither runs nor waits
for them. A wrong digest, a setting changed beforehand and a post that cannot be saved must
each end without the completion line.

Requires Docker, the cached images named by runtime/profiles and roughly 4 GiB available
RAM. Never pulls or builds: a missing prerequisite FAILS when opted in (it never passes or
skips). Uses the shared Fixture's labelled ownership/cleanup: only uniquely labelled
resources on an internal network, no published ports, no source or customer mounts, one
900s budget. Unicorn/Sidekiq of the invented site are stopped (plain `sv stop`, not the
production quiesce script) so nothing else writes settings.

Proves the guest helper on the cached PUBLIC profile revision only. That is not a customer's
or a customer-ready revision. No merger runs and no upload is copied: this is not a host
workflow, a merge run or an end-to-end custom merge, and it says nothing about what the
temporary narrower list does to any upload. The posts are plain invented Markdown without
links on the cached image's own plugins: nothing here shows how a customer's plugins render.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
GATE = os.environ.get('SILO_MERGE_SITE_SETTINGS_LIVE') == '1'
SPEC = importlib.util.spec_from_file_location('merge_site_settings_fixture', ROOT / 'test/merge_inspection_live_test.py')
shared = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(shared)

HELPER = ROOT / 'runtime/prebuilt-discourse/merge_site_settings.rb'
HELPER_GUEST = '/tmp/merge_site_settings.rb'
REBAKE = ROOT / 'runtime/prebuilt-discourse/merge_rebake.rb'
REBAKE_GUEST = '/tmp/merge_rebake.rb'  # beside the settings helper it requires, as the host installs both
REBAKE_DONE = re.compile(r'SILO_MERGE_REBAKE: posts=([0-9]+)')  # the host's own completion pattern
SYSTEM_EDIT = 'disable_system_edit_notifications'
SNAPSHOT_GUEST = '/shared/merge/site-settings.json'
DRIVER_GUEST = '/tmp/silo_settings_driver.rb'
INPUT_GUEST = '/tmp/silo_settings_input.json'
NAME = 'authorized_extensions'
ROLES = ('db', 'web', 'redis')
ROWS_SQL = ("SELECT COALESCE(json_object_agg(name, json_build_array(value, data_type, id, created_at::text, "
            "updated_at::text)), '{}'::json) FROM site_settings")
# Every post, deleted ones too: {id: [md5(cooked), baked_version, deleted, updated_at, md5(raw), has a link/source]}.
POSTS_SQL = ("SELECT COALESCE(json_object_agg(id, json_build_array(md5(cooked), baked_version, deleted_at IS NOT NULL, "
             "updated_at::text, md5(raw), cooked ~ '(href|src)=')), '{}'::json) FROM posts")
COUNTS_SQL = ("SELECT json_build_object('notifications', (SELECT count(*) FROM notifications), "
              "'post_revisions', (SELECT count(*) FROM post_revisions))")
STATES = {'restore': {'restored', 'unproven'}, 'verify': {'clean', 'dirty'}}
SNAPSHOT_KEYS = {'version', 'settings', 'authorized_extensions_effective'}

# Test-only code for the invented site: baselines and the stock write through the real
# SiteSetting API. Failures print exception classes and driver line numbers, never messages.
DRIVER = r'''# frozen_string_literal: true
require "json"
require "stringio"

HELPER = "/tmp/merge_site_settings.rb"
STOCK_FILES = %w[discourse_merger.rb base.rb].map { |name| "/var/www/discourse/script/bulk_import/" + name }
NAME = :authorized_extensions
SYSTEM_EDIT = :disable_system_edit_notifications
OTHERS = %w[title site_description short_site_description].freeze
TABLE_SQL = "SELECT name, value, data_type::text FROM site_settings ORDER BY name"
$step = "boot"

def effective
  SiteSetting.authorized_extensions.to_s
end

class StockDrift < StandardError; end
class NotExercised < StandardError; end

# Straight from PostgreSQL on the raw connection: never an answer kept by the query cache,
# and a write ActiveRecord is not told about.
def raw(sql, params = [])
  ActiveRecord::Base.connection.raw_connection.exec_params(sql, params).values
end

# The stored authorized_extensions row: [raw value, data type], or nil when there is none.
def row
  found = raw("SELECT value, data_type::text FROM site_settings WHERE name = 'authorized_extensions'").first
  found && [found[0], Integer(found[1])]
end

def stored_title
  raw("SELECT value FROM site_settings WHERE name = 'title'").first&.first
end

# The same question twice: through ActiveRecord (the query cache may answer) and from the table.
def cache_stale?
  ActiveRecord::Base.connection.select_rows(TABLE_SQL) != raw(TABLE_SQL)
end

def baseline!(spec)
  case spec.fetch("kind")
  when "absent"
    SiteSetting.remove_override!(NAME)
  when "setter"
    SiteSetting.authorized_extensions = spec.fetch("value")
  when "raw"
    # A row the public setter would not write itself: stored value and type exactly as given.
    SiteSetting.provider.save(NAME.to_s, spec.fetch("value"), Integer(spec.fetch("data_type")))
    SiteSetting.refresh!
  else
    raise ArgumentError
  end
end

def others!(input)
  input.fetch("others", {}).each do |name, value|
    raise ArgumentError unless OTHERS.include?(name)

    SiteSetting.public_send("#{name}=", value)
  end
  input.fetch("reset", []).each do |name|
    raise ArgumentError unless OTHERS.include?(name)

    SiteSetting.remove_override!(name.to_sym)
  end
end

# The cached revision's own statement, executed verbatim: the merger and its base class
# must contain exactly this one site-setting write.
def stock!
  write = /SiteSetting\s*\.\s*(?:[a-z_]+\s*=(?![=~])|set\b|set_and_log\b|add_override!|remove_override!|provider\b)/
  writes = STOCK_FILES.flat_map { |path| File.readlines(path).map(&:strip).grep(write) }
  match = writes.size == 1 &&
          writes.first.match(/\ASiteSetting\.authorized_extensions = %w\[([a-z0-9 ]+)\]\.join\("\|"\)\z/)
  raise StockDrift unless match

  TOPLEVEL_BINDING.eval(writes.first)
  { "stock_writes" => writes.size, "stock_value" => match[1].split.join("|"), "stock_data_type" => row && row[1] }
end

def state
  { "row" => row, "effective" => effective }
end

# What this process would hand to browsers, from SiteSetting's per-process client caches
# (the hash and the JSON document): is authorized_extensions in both exactly this value?
def client_shows?(value)
  SiteSetting.client_settings_hash[NAME].to_s == value &&
    JSON.parse(SiteSetting.client_settings_json)[NAME.to_s].to_s == value
end

def library(input)
  raise ArgumentError if ENV["SILO_MERGE_SITE_SETTINGS_ACTION"] || defined?(SILO_MERGE_RUNNER)

  out = $stdout
  err = $stderr
  quiet = StringIO.new
  begin
    $stdout = $stderr = quiet
    require HELPER # no action named: must neither run one nor exit
  ensure
    $stdout = out
    $stderr = err
  end
  helper = SiloMergeSiteSettings
  cases = input.fetch("baselines").map do |spec|
    $step = "library-#{spec.fetch('kind')}"
    baseline!(spec)
    before = state
    snapshot = JSON.parse(JSON.generate(helper.capture))
    client_before = client_shows?(before["effective"]) # also fills both client caches
    stock!
    during = state
    client_during = client_shows?(during["effective"]) # and again, now with the stock value
    window = helper.verify_stock_window(snapshot)
    strict = helper.verify(snapshot)
    foreign = nil
    if spec["foreign"]
      SiteSetting.authorized_extensions = spec["foreign"]
      foreign = helper.verify_stock_window(snapshot)
    end
    restored = helper.restore(snapshot)
    # No refresh by this driver: the getter must already be current in the same process.
    after = state
    client_after = client_shows?(before["effective"])
    clean = helper.verify(snapshot)
    again = helper.restore(snapshot)
    again_row = row
    SiteSetting.refresh!
    { "kind" => spec.fetch("kind"), "before" => before, "during" => during, "after" => after,
      "again_row" => again_row, "refreshed_effective" => effective,
      "client_before" => client_before, "client_during" => client_during, "client_after" => client_after,
      "snapshot_entry" => snapshot["settings"]["authorized_extensions"],
      "snapshot_effective" => snapshot["authorized_extensions_effective"],
      "window" => window, "strict" => strict, "foreign" => foreign,
      "restored" => restored, "clean" => clean, "again" => again }
  end
  { "require_output_bytes" => quiet.string.bytesize, "stock_constant" => helper::STOCK_VALUE,
    "snapshot_path" => helper::SNAPSHOT_PATH, "digest_env" => helper::DIGEST_ENV, "cases" => cases,
    "fresh" => input.fetch("fresh").map { |spec| freshness(helper, spec, input) } }
end

# Stored changes ActiveRecord is not told about, each made only after the query cache has been
# warmed with the helper's own reads. Every check and the restore must read the table again.
def freshness(helper, spec, input)
  $step = "fresh-#{spec.fetch('kind')}-setup"
  connection = ActiveRecord::Base.connection
  title = input.fetch("title")
  outside = input.fetch("outside_title")
  SiteSetting.title = title
  stock_type = stock!.fetch("stock_data_type").to_s
  stock_value = effective
  baseline!(spec)
  before = state
  snapshot = JSON.parse(JSON.generate(helper.capture))
  out = { "kind" => spec.fetch("kind"), "before" => before }

  set_stock = lambda do
    if before["row"]
      raw("UPDATE site_settings SET value = $1, data_type = $2::int WHERE name = 'authorized_extensions'",
          [stock_value, stock_type])
    else
      raw("INSERT INTO site_settings (name, value, data_type, created_at, updated_at) " \
          "VALUES ('authorized_extensions', $1, $2::int, now(), now())", [stock_value, stock_type])
    end
  end
  put_back = lambda do
    if before["row"]
      raw("UPDATE site_settings SET value = $1, data_type = $2::int WHERE name = 'authorized_extensions'",
          [before["row"][0], before["row"][1].to_s])
    else
      raw("DELETE FROM site_settings WHERE name = 'authorized_extensions'")
    end
  end
  # The helper's own reads (and its row query through the cached path, when it names one),
  # then the control. Nothing here may already be stale.
  warm = lambda do |lookups: false|
    helper.capture
    helper.verify(snapshot)
    helper.verify_stock_window(snapshot)
    connection.select_rows(helper::ROWS_SQL) if helper.const_defined?(:ROWS_SQL)
    if lookups # the model lookups SiteSetting's own provider makes before it writes
      SiteSetting.find_by(name: NAME.to_s)
      SiteSetting.where(name: NAME.to_s).to_a
    end
    raise NotExercised if cache_stale?
  end

  connection.cache do
    out["query_cache"] = connection.query_cache_enabled == true

    # 1. Another setting changes; then it is put back.
    $step = "fresh-#{spec.fetch('kind')}-other"
    out["primed"] = helper.verify(snapshot)
    warm.call
    raw("UPDATE site_settings SET value = $1 WHERE name = 'title'", [outside])
    out["other_control_stale"] = cache_stale?
    out["other_seen"] = helper.verify(snapshot)
    out["other_window"] = helper.verify_stock_window(snapshot)
    out["other_restore"] = helper.restore(snapshot)
    out["other_kept"] = stored_title == outside
    warm_again = cache_stale? # still warm with the old answer, unless the helper wrote
    raw("UPDATE site_settings SET value = $1 WHERE name = 'title'", [title])
    out["other_recovered"] = helper.verify(snapshot)
    out["other_still_warm"] = warm_again

    # 2. The authorized_extensions row changes in the table; this process's getter is not told.
    $step = "fresh-#{spec.fetch('kind')}-row"
    warm.call
    set_stock.call
    out["row_control_stale"] = cache_stale?
    out["row_getter_untold"] = effective == before["effective"]
    out["row_seen"] = helper.verify(snapshot)
    out["row_restore"] = helper.restore(snapshot)
    out["row_after"] = state
    out["row_clean"] = helper.verify(snapshot)

    # 3. The stored row is the prior one again, but this process's getter still holds the stock value.
    $step = "fresh-#{spec.fetch('kind')}-getter"
    stock!
    warm.call
    put_back.call
    out["getter_control_stale"] = cache_stale?
    out["getter_stored_prior"] = row == before["row"]
    out["getter_untold"] = effective == stock_value
    out["getter_client_untold"] = client_shows?(stock_value) # client caches filled with the stock value
    out["getter_seen"] = helper.verify(snapshot)
    out["getter_restore"] = helper.restore(snapshot)
    out["getter_after"] = state
    out["getter_client_after"] = client_shows?(before["effective"])
    out["getter_clean"] = helper.verify(snapshot)

    # 4. As 2, with the provider's own model lookups warmed too. Restoring may be impossible
    # here; claiming "restored" or "clean" while the table differs never is.
    $step = "fresh-#{spec.fetch('kind')}-lookup"
    connection.clear_query_cache
    SiteSetting.refresh!
    warm.call(lookups: true)
    set_stock.call
    out["lookup_control_stale"] = cache_stale?
    out["lookup_restore"] = helper.restore(snapshot)
    out["lookup_after"] = state
    out["lookup_verify"] = helper.verify(snapshot)
  end
  $step = "fresh-#{spec.fetch('kind')}-reset"
  put_back.call
  connection.clear_query_cache
  SiteSetting.refresh!
  out["reset"] = state == before && stored_title == title
  out
end

# Invented posts for the rebake helper, and what only Rails can say about them afterwards.
# Posts are made by core's own creator; skip_jobs is its documented option, so making them
# queues nothing and notifies nobody.
def posts(input)
  require "sidekiq/api"
  $step = "posts-setting"
  case input["system_edit"]
  when "absent"
    SiteSetting.remove_override!(SYSTEM_EDIT)
  when "stored"
    # A stored row that is not the default: the stock task would write over it and back.
    SiteSetting.public_send("#{SYSTEM_EDIT}=", !SiteSetting.defaults[SYSTEM_EDIT])
  when nil
    nil
  else
    raise ArgumentError
  end
  SiteSetting.title = input["site_title"] if input["site_title"]
  ids = input.fetch("ids", [])
  if (spec = input["create"])
    $step = "posts-create"
    options = { skip_validations: true, skip_jobs: true }
    first = PostCreator.create!(Discourse.system_user, title: spec.fetch("title"), raw: spec.fetch("raws").first, **options)
    rest = spec.fetch("raws").drop(1).map do |text|
      PostCreator.create!(Discourse.system_user, topic_id: first.topic_id, raw: text, **options)
    end
    ids = [first, *rest].map(&:id)
  end
  $step = "posts-probe"
  sizes = {}
  queued = Hash.new(0)
  elsewhere = 0
  Sidekiq::Queue.all.each do |queue|
    sizes[queue.name] = queue.size
    queue.each do |job|
      next unless job.klass == "Jobs::ProcessPost"

      args = job.args.first
      id = args.is_a?(Hash) ? args["post_id"] : nil
      next unless ids.include?(id)

      queue.name == "ultra_low" ? queued[id] += 1 : elsewhere += 1
    end
  end
  found = Post.with_deleted.where(id: ids).to_a
  { "post_ids" => ids, "baked_version" => Post::BAKED_VERSION, "jobs_inline" => Jobs.run_immediately?,
    "sidekiq_processes" => Sidekiq::ProcessSet.new.size, "queue_sizes" => sizes,
    "process_post_ultra_low" => ids.to_h { |id| [id.to_s, queued[id]] }, "process_post_elsewhere" => elsewhere,
    # A cook by this separate process gives exactly the stored HTML.
    "fresh_cook" => found.to_h { |post| [post.id.to_s, post.cook(post.raw, topic_id: post.topic_id) == post.cooked] },
    "system_edit_default" => SiteSetting.defaults[SYSTEM_EDIT] == true,
    "system_edit_effective" => SiteSetting.public_send(SYSTEM_EDIT) == true }
end

begin
  input = JSON.parse(File.read(ENV.fetch("SILO_TEST_INPUT")))
  facts = { "boot_effective" => effective, "default" => SiteSetting.defaults[NAME].to_s,
            "revision" => Discourse.git_version.to_s, "version" => Discourse::VERSION::STRING,
            "rails" => Rails.version.to_s,
            # rails runner wraps the script in the executor: reads can come from the query cache.
            "query_cache" => ActiveRecord::Base.connection.query_cache_enabled == true }
  case input.fetch("mode")
  when "prepare"
    $step = "baseline"
    baseline!(input.fetch("authorized"))
    $step = "others"
    others!(input)
  when "stock"
    $step = "stock"
    facts.merge!(stock!)
    $step = "others"
    others!(input)
  when "library"
    facts.merge!(library(input))
  when "posts"
    facts.merge!(posts(input))
  when "probe"
    nil
  else
    raise ArgumentError
  end
  facts["effective"] = effective
  puts "SILO_TEST_JSON:" + JSON.generate(facts)
rescue StandardError, ScriptError => e
  lines = (e.backtrace || []).grep(/silo_settings_driver/).first(3).map { |line| line[/:(\d+):/, 1] }
  warn "SILO_TEST_ERROR:#{e.class.name.to_s.gsub(/[^A-Za-z0-9_:]/, '')},step=#{$step},lines=#{lines.join('.')}"
  exit 1
end
'''


def prerequisites():
    """Names what is missing. Runs only read-only checks: never pulls, builds or starts anything."""
    missing = []
    if not HELPER.is_file():
        missing.append('runtime helper runtime/prebuilt-discourse/merge_site_settings.rb')
    if not shared.PROFILE.is_file():
        return missing + ['runtime profile ' + shared.PROFILE.name]
    profile = json.loads(shared.PROFILE.read_text())

    def quiet(*args):
        try:
            return subprocess.run(['docker', *args], capture_output=True, timeout=30).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False
    if not quiet('version', '--format', '{{.Server.Version}}'):
        return missing + ['a reachable Docker daemon']
    absent = [role for role in ROLES if not quiet('image', 'inspect', '--format', '{{.Id}}', profile['images'][role]['ref'])]
    if absent:
        missing.append('cached profile image(s) for ' + ', '.join(absent) + ' (this test never pulls or builds)')
    try:
        available = int(re.search(r'^MemAvailable:\s+(\d+) kB', Path('/proc/meminfo').read_text(), re.M).group(1))
    except (OSError, AttributeError):
        available = 0
    if available < 4 * 1024 * 1024:
        missing.append('about 4 GiB available RAM')
    return missing


def shape(report):
    """A report as names and counts: (state, restoration_failed, unexpected_names, remaining_differences)."""
    return (report['state'], sorted(report['restoration_failed']), sorted(report['unexpected_names']),
            report['remaining_differences'])


class SettingsFixture(shared.Fixture):
    """The shared labelled fixture under its own name prefix, with the invented site quiesced."""
    def __init__(self):
        super().__init__()
        self.name = 'silo-mss-live-' + self.token
        self.timings = []

    def quiesce(self):
        self.docker('exec', self.web, 'sv', '-w', '90', 'stop', 'unicorn', timeout=120)
        self.wait(lambda: self.docker('exec', self.web, 'sv', 'status', 'unicorn', check=False).stdout.startswith(b'down:'))
        self.wait(lambda: self.sql("SELECT count(*) FROM pg_stat_activity WHERE datname='discourse'") == '0')

    def rows(self):
        """Every stored setting, read by PostgreSQL alone: {name: [value, type, id, created, updated]}."""
        return json.loads(self.sql(ROWS_SQL, 'discourse'))

    def posts(self):
        return {int(key): value for key, value in json.loads(self.sql(POSTS_SQL, 'discourse')).items()}

    def counts(self):
        return json.loads(self.sql(COUNTS_SQL, 'discourse'))

    def rails(self, label, path, env):
        started = time.monotonic()
        result = self.runner(path, env, check=False)
        self.timings.append((label, round(time.monotonic() - started, 1)))
        return result

    def install_snapshot(self, data):
        """As the host does: its own bytes at the fixed guest path, read-only, named by digest."""
        path = self.private / 'site-settings.json'
        path.write_bytes(data)
        path.chmod(0o600)
        self.docker('exec', self.web, 'mkdir', '-p', os.path.dirname(SNAPSHOT_GUEST))
        self.docker('cp', str(path), self.web + ':' + SNAPSHOT_GUEST)
        self.docker('exec', self.web, 'chown', 'root:root', SNAPSHOT_GUEST)
        self.docker('exec', self.web, 'chmod', '0444', SNAPSHOT_GUEST)
        digest = hashlib.sha256(data).hexdigest()
        guest = self.docker('exec', self.web, 'sha256sum', SNAPSHOT_GUEST).stdout.split()[0].decode()
        assert guest == digest, 'guest snapshot differs from the bytes installed'
        return digest


@unittest.skipUnless(GATE, 'opt-in: set SILO_MERGE_SITE_SETTINGS_LIVE=1; cached images, invented data only')
class MergeSiteSettingsLiveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        missing = prerequisites()
        if missing:
            # Opted in but unable to run: an explicit failure, never a pass or a skip.
            raise AssertionError('INSUFFICIENT PREREQUISITE, nothing was run: ' + '; '.join(missing))
        stock = re.search(r'^\s*STOCK_VALUE = "([a-z0-9|]+)"', HELPER.read_text(), re.M)
        if not stock:
            raise AssertionError('helper no longer names STOCK_VALUE: this test must be re-coordinated with it')
        cls.stock_value = stock.group(1)
        cls.helper_sha256 = hashlib.sha256(HELPER.read_bytes()).hexdigest()
        cls.rebake_sha256 = hashlib.sha256(REBAKE.read_bytes()).hexdigest() if REBAKE.is_file() else None
        cls.profile = json.loads(shared.PROFILE.read_text())
        cls.revision = cls.version = cls.rails = cls.query_cache = None
        cls.notes = {}
        cls.f = f = SettingsFixture()
        cls.addClassCleanup(cls.finish)  # also runs when the rest of this setup fails
        f.setup(site=True)
        f.quiesce()
        f.copy(HELPER, HELPER_GUEST)
        driver = f.private / 'driver.rb'
        driver.write_text(DRIVER)
        f.copy(driver, DRIVER_GUEST)
        f.assert_isolation()
        # A new site stores no authorized_extensions row: absence is its real default state.
        if NAME in f.rows():
            raise AssertionError('new invented site unexpectedly stores an authorized_extensions row')

    @classmethod
    def finish(cls):
        f = cls.f
        resources = list(f.resources)
        private = f.private
        f.close()  # exact-name, label-checked removal; raises when anything is unresolved
        for kind, name in resources:
            if f.docker(kind, 'inspect', name, check=False).returncode == 0:
                raise AssertionError('owned resource still present after cleanup: ' + kind)
        label = 'label=' + shared.LABEL + '=' + f.token
        for listing in (('ps', '-aq'), ('volume', 'ls', '-q'), ('network', 'ls', '-q')):
            if f.docker(*listing, '--filter', label).stdout.strip():
                raise AssertionError('labelled resource still listed after cleanup: ' + listing[0])
        if private.exists():
            raise AssertionError('private fixture directory still present')
        f.resources.clear()
        print(json.dumps(dict(
            receipt='merge site-settings live fixture', profile=shared.PROFILE.name,
            app_revision=cls.revision, app_version=cls.version, rails_version=cls.rails,
            rails_runner_query_cache_enabled=cls.query_cache,
            revision_scope='cached public profile revision only; NOT a customer or customer-ready revision',
            scope='guest helpers only: no merger run, no upload copied, not an end-to-end merge; rebake '
                  'follow-up jobs queued and not run; no customer plugin rendering',
            helper_sha256=cls.helper_sha256, rebake_helper_sha256=cls.rebake_sha256, customer_data_used=False, images_pulled_or_built=False,
            observed=cls.notes, fixture=f.name,
            rails_runs=len(f.timings), rails_seconds=round(sum(seconds for _, seconds in f.timings), 1),
            slowest_rails_run=max((seconds for _, seconds in f.timings), default=None),
            cleanup=dict(confirmed_absent=True, containers=sum(kind == 'container' for kind, _ in resources),
                         volumes=sum(kind == 'volume' for kind, _ in resources),
                         internal_networks=sum(kind == 'network' for kind, _ in resources),
                         private_directory_removed=True)), sort_keys=True))

    def setUp(self):
        self.helper_outputs = []

    def same(self, expected, actual, message):
        """Equality of stored or effective VALUES. A failure never prints them: the invented
        site's rows include keys it generated for itself."""
        self.assertTrue(expected == actual, message + ' (values suppressed)')

    def drive(self, **spec):
        f = self.f
        path = f.private / 'input.json'
        path.write_text(json.dumps(spec))
        path.chmod(0o600)
        f.copy(path, INPUT_GUEST)
        result = f.rails('driver-' + spec['mode'], DRIVER_GUEST, ['SILO_TEST_INPUT=' + INPUT_GUEST])
        errors = re.findall(rb'SILO_TEST_ERROR:([A-Za-z0-9_:,.=-]+)', result.stderr)
        self.assertEqual(0, result.returncode, 'invented-site driver failed: ' +
                         (errors[0].decode() if errors else 'output suppressed'))
        lines = [line for line in result.stdout.split(b'\n') if line.startswith(b'SILO_TEST_JSON:')]
        self.assertEqual(1, len(lines))
        facts = json.loads(lines[0][len(b'SILO_TEST_JSON:'):])
        # The revision actually exercised is the cached public profile's, and is recorded as such.
        self.assertEqual(self.profile['app']['revision'], facts['revision'], 'cached image is not the profile revision')
        cls = type(self)
        cls.revision, cls.version, cls.rails, cls.query_cache = (facts[key] for key in ('revision', 'version', 'rails', 'query_cache'))
        return facts

    def helper(self, action, digest=None):
        env = ['SILO_MERGE_SITE_SETTINGS_ACTION=' + action]
        if digest is not None:
            env.append('SILO_MERGE_SITE_SETTINGS_SHA256=' + digest)
        result = self.f.rails(action, HELPER_GUEST, env)
        self.helper_outputs.append((action, result))
        return result

    @staticmethod
    def tags(result):
        """The helper's fixed error tags only: never its raw output."""
        found = re.findall(rb'^SILO_SETTINGS_ERROR: ([a-z-]+(?: \([A-Za-z:]+\))?)$', result.stderr, re.M)
        return ' [' + ', '.join(sorted({tag.decode() for tag in found})) + ']'

    def capture(self):
        """The host's step: one snapshot line, kept as bytes, installed and named by digest."""
        stored = self.f.rows()
        result = self.helper('capture')
        self.assertEqual(0, result.returncode, 'capture failed' + self.tags(result))
        lines = [line for line in result.stdout.split(b'\n') if line.startswith(b'SILO_SETTINGS_SNAPSHOT:')]
        self.assertEqual(1, len(lines), 'exactly one snapshot line expected')
        body = lines[0][len(b'SILO_SETTINGS_SNAPSHOT:'):]
        snapshot = json.loads(body)
        keys = set(snapshot)
        self.assertEqual(set(), SNAPSHOT_KEYS - keys, 'snapshot lacks a required field')
        self.assertEqual(set(), keys - SNAPSHOT_KEYS,
                         'snapshot has a field this test does not know: re-coordinate the schema')
        type(self).notes['snapshot_fields_beyond_schema'] = sorted(keys - SNAPSHOT_KEYS)
        self.assertEqual(1, snapshot['version'])
        self.same({name: row[:2] for name, row in stored.items()}, snapshot['settings'],
                  'snapshot is not exactly the stored rows (raw value, data type)')
        self.assertTrue(all(type(entry[1]) is int for entry in snapshot['settings'].values()))
        self.assertIsInstance(snapshot['authorized_extensions_effective'], str)
        self.same(stored, self.f.rows(), 'capture wrote to site_settings')
        return snapshot, self.f.install_snapshot(body + b'\n')

    def report(self, result, kind, names):
        lines = [line for line in result.stdout.split(b'\n') if line.startswith(b'SILO_SETTINGS_REPORT:')]
        self.assertEqual(1, len(lines), 'exactly one report line expected' + self.tags(result))
        report = json.loads(lines[0][len(b'SILO_SETTINGS_REPORT:'):])
        self.check_report(report, kind, names)
        return report

    def check_report(self, report, kind, names):
        """Names and counts only: a value could hide in no field of this shape."""
        self.assertEqual(1, report['version'])
        self.assertIn(report['state'], STATES[kind])
        for key in ('restoration_failed', 'unexpected_names'):
            self.assertIsInstance(report[key], list)
            self.assertTrue(all(isinstance(name, str) and name in names for name in report[key]),
                            key + ' holds something that is not a setting name')
        count = report['remaining_differences']
        self.assertTrue(count is None or (type(count) is int and count >= 0))
        for key, value in report.items():
            if key not in ('state', 'restoration_failed', 'unexpected_names'):
                self.assertTrue(value is None or isinstance(value, (bool, int)), 'report field carries text: ' + key)

    def assert_no_values(self, *values):
        """No invented value in anything a helper action printed, the private snapshot line apart."""
        self.assertTrue(self.helper_outputs)
        for action, result in self.helper_outputs:
            printed = b'\n'.join(line for line in result.stdout.split(b'\n')
                                 if not (action == 'capture' and line.startswith(b'SILO_SETTINGS_SNAPSHOT:')))
            for value in values:
                self.assertTrue(value.encode() not in printed and value.encode() not in result.stderr,
                                'a setting value reached ' + action + ' output (output suppressed)')

    def others(self, rows):
        return {name: row for name, row in rows.items() if name != NAME}

    @staticmethod
    def facets(expected, actual):
        """Which parts of the stored authorized_extensions pair differ: part names only, never values."""
        if expected is None or actual is None:
            return ' (row: ' + ('as expected' if expected == actual else 'expected ' +
                                ('absent' if expected is None else 'present') + ', found ' +
                                ('absent' if actual is None else 'present')) + ')'
        parts = [part for part, a, b in zip(('value', 'data_type'), expected, actual) if a != b]
        return ' (row differs in: ' + (', '.join(parts) or 'nothing') + ')'

    def dirty_before_restore(self, digest, during):
        """The standalone verify, a new process, sees the stored stock write and writes nothing."""
        seen = self.helper('verify', digest=digest)
        report = self.report(seen, 'verify', set(during))
        self.assertEqual(4, seen.returncode, 'verify passed while the stock value was still stored')
        self.assertIn(b'SILO_SETTINGS_ERROR: settings-changed', seen.stderr)
        self.assertEqual(('dirty', [NAME], [], 1), shape(report))
        self.same(during, self.f.rows(), 'verify wrote to site_settings')

    def test_absent_override_baseline_restores_row_absence_and_default(self):
        f = self.f
        title = 'Invented private title ' + secrets.token_hex(8)
        prepared = self.drive(mode='prepare', authorized={'kind': 'absent'}, others={'title': title})
        default = prepared['default']
        self.same(default, prepared['effective'], 'no stored row, yet the effective value is not the default')
        self.assertNotEqual(default, self.stock_value)
        before = f.rows()
        self.assertNotIn(NAME, before)
        self.same(title, before['title'][0], 'invented title not stored')
        snapshot, digest = self.capture()
        self.assertNotIn(NAME, snapshot['settings'])
        self.same(default, snapshot['authorized_extensions_effective'], 'snapshot effective value is not the default')

        stock = self.drive(mode='stock')
        self.same(default, stock['boot_effective'], 'a new process did not see the default')
        self.assertEqual(1, stock['stock_writes'])
        self.assertEqual(self.stock_value, stock['stock_value'], 'helper STOCK_VALUE is not the cached stock statement')
        self.assertEqual(self.stock_value, stock['effective'])
        during = f.rows()
        self.assertEqual([self.stock_value, stock['stock_data_type']], during[NAME][:2])
        self.same(before, self.others(during), 'the stock write changed another stored setting')

        # A wrong digest refuses before anything is read or written.
        refused = self.helper('restore', digest='0' * 64)
        self.assertEqual(4, refused.returncode)
        self.assertIn(b'SILO_SETTINGS_ERROR: snapshot-digest-mismatch', refused.stderr)
        self.assertNotIn(b'SILO_SETTINGS_REPORT:', refused.stdout)
        self.same(during, f.rows(), 'a refused restore wrote to site_settings')
        self.dirty_before_restore(digest, during)

        restored = self.helper('restore', digest=digest)
        after = f.rows()
        found = self.facets(None, after.get(NAME))
        report = self.report(restored, 'restore', set(during))
        self.assertEqual(0, restored.returncode, 'restore did not succeed' + self.tags(restored) + found)
        self.assertEqual(('restored', [], [], 0), shape(report), found)
        self.assertNotIn(b'SILO_SETTINGS_ERROR', restored.stderr)
        self.assertNotIn(NAME, after, 'the temporary row was not removed')
        self.same(before, after, 'another stored setting changed (value, type, id or timestamps)')

        verified = self.helper('verify', digest=digest)
        report = self.report(verified, 'verify', set(during))
        self.assertEqual(0, verified.returncode, 'verify did not succeed' + self.tags(verified))
        self.assertEqual(('clean', [], [], 0), shape(report))
        self.same(before, f.rows(), 'verify wrote to site_settings')
        probe = self.drive(mode='probe')
        self.same(default, probe['boot_effective'], 'a new process did not see the restored default')
        self.assert_no_values(title, default, self.stock_value)

    def test_custom_baseline_restores_stored_pair_and_effective_value(self):
        f = self.f
        custom = 'pdf|inv' + secrets.token_hex(4) + '|png|zip'
        title = 'Invented private title ' + secrets.token_hex(8)
        prepared = self.drive(mode='prepare', authorized={'kind': 'setter', 'value': custom}, others={'title': title})
        self.same(custom, prepared['effective'], 'custom baseline not effective')
        self.assertNotIn(custom, (prepared['default'], self.stock_value))
        before = f.rows()
        self.same(custom, before[NAME][0], 'custom baseline not stored')
        snapshot, digest = self.capture()
        self.same(before[NAME][:2], snapshot['settings'][NAME], 'snapshot pair is not the stored pair')
        self.same(custom, snapshot['authorized_extensions_effective'], 'snapshot effective value is not the custom one')

        stock = self.drive(mode='stock')
        self.same(custom, stock['boot_effective'], 'a new process did not see the custom baseline')
        self.assertEqual(self.stock_value, stock['effective'])
        during = f.rows()
        self.assertEqual([self.stock_value, stock['stock_data_type']], during[NAME][:2])
        self.same(self.others(before), self.others(during), 'the stock write changed another stored setting')
        self.dirty_before_restore(digest, during)

        restored = self.helper('restore', digest=digest)
        after = f.rows()
        found = self.facets(before[NAME][:2], after[NAME][:2] if NAME in after else None)
        report = self.report(restored, 'restore', set(during))
        self.assertEqual(0, restored.returncode, 'restore did not succeed' + self.tags(restored) + found)
        self.assertEqual(('restored', [], [], 0), shape(report), found)
        self.assertIn(NAME, after, 'the stored override was removed instead of restored')
        self.same(before[NAME][:2], after[NAME][:2], 'stored raw value or data type not restored exactly' + found)
        self.same(self.others(before), self.others(after), 'another stored setting changed (value, type, id or timestamps)')

        verified = self.helper('verify', digest=digest)
        report = self.report(verified, 'verify', set(during))
        self.assertEqual(0, verified.returncode, 'verify did not succeed' + self.tags(verified))
        self.assertEqual(('clean', [], [], 0), shape(report))
        self.same(after, f.rows(), 'verify wrote to site_settings')
        probe = self.drive(mode='probe')
        self.same(custom, probe['boot_effective'], 'a new process did not see the restored custom value')
        self.assert_no_values(title, custom, self.stock_value)

    def test_other_changed_settings_are_named_and_never_repaired(self):
        f = self.f
        custom = 'txt|inv' + secrets.token_hex(4) + '|csv'
        values = {key: 'Invented private ' + key + ' ' + secrets.token_hex(8) for key in ('kept', 'changed', 'removed', 'added')}
        self.drive(mode='prepare', authorized={'kind': 'setter', 'value': custom}, reset=['short_site_description'],
                   others={'title': values['kept'], 'site_description': values['removed']})
        before = f.rows()
        self.assertNotIn('short_site_description', before)
        snapshot, digest = self.capture()
        # During the run: the stock write, then one changed, one removed and one added row.
        self.drive(mode='stock', others={'title': values['changed'], 'short_site_description': values['added']},
                   reset=['site_description'])
        during = f.rows()
        names = ['short_site_description', 'site_description', 'title']
        self.assertEqual(names, sorted(name for name in set(before) | set(during)
                                       if name != NAME and before.get(name) != during.get(name)))

        restored = self.helper('restore', digest=digest)
        after = f.rows()
        found = self.facets(before[NAME][:2], after[NAME][:2] if NAME in after else None)
        report = self.report(restored, 'restore', set(before) | set(during))
        self.assertEqual(4, restored.returncode, 'a restore that leaves other settings changed must fail')
        self.assertIn(b'SILO_SETTINGS_ERROR: restore-unproven', restored.stderr)
        self.assertEqual(('unproven', [], names, 3), shape(report), 'authorized_extensions itself was restorable' + found)
        self.assertIn(NAME, after)
        self.same(before[NAME][:2], after[NAME][:2], 'authorized_extensions pair was not put back' + found)
        self.same(self.others(during), self.others(after), 'a setting other than authorized_extensions was written')
        self.same(values['changed'], after['title'][0], 'the changed setting was repaired')
        self.same(values['added'], after['short_site_description'][0], 'the added setting was repaired')
        self.assertNotIn('site_description', after, 'the removed setting was put back')

        verified = self.helper('verify', digest=digest)
        report = self.report(verified, 'verify', set(before) | set(during))
        self.assertEqual(4, verified.returncode, 'verify must fail while other settings differ')
        self.assertIn(b'SILO_SETTINGS_ERROR: settings-changed', verified.stderr)
        self.assertEqual(('dirty', [], names, 3), shape(report))
        self.same(after, f.rows(), 'verify wrote to site_settings')
        self.assert_no_values(custom, self.stock_value, *values.values())

    def rebake(self, digest):
        result = self.f.rails('rebake', REBAKE_GUEST, ['SILO_MERGE_SITE_SETTINGS_SHA256=' + digest])
        self.rebake_outputs.append(result)
        return result

    @staticmethod
    def rebake_lines(result):
        """(completion counts when the completion line is the single, last stdout line; fixed stderr lines)."""
        lines = [line for line in result.stdout.decode(errors='replace').splitlines() if line]
        done = [REBAKE_DONE.fullmatch(line) for line in lines]
        counts = [int(match.group(1)) for match in done if match]
        told = re.findall(r'^SILO_MERGE_REBAKE: ((?:settings [a-z-]+(?: \([A-Za-z:]+\))?)|(?:failed \([A-Za-z0-9_: ]+\)))$',
                          result.stderr.decode(errors='replace'), re.M)
        return (counts if len(counts) == 1 and done[-1] else [] if not counts else None), told

    def refused_rebake(self, result, status, line, posts, rows, counts):
        """A run that must not claim completion: its fixed line only, and what it must have left alone."""
        done, told = self.rebake_lines(result)
        self.assertEqual(status, result.returncode, 'unexpected rebake exit status ' + str(told))
        self.assertEqual([], done, 'a rebake that did not complete printed the completion line')
        self.assertEqual(1, len(told), told)
        self.assertRegex(told[0], line)
        self.same(rows, self.f.rows(), 'a refused or failed rebake changed a stored setting')
        self.assertEqual(counts, self.f.counts(), 'a refused or failed rebake notified or revised')
        if posts is not None:
            self.same(posts, self.f.posts(), 'a rebake refused before it started changed a post')
        return told[0]

    def test_rebake_helper_rebakes_every_post_and_writes_no_setting(self):
        f = self.f
        self.assertTrue(REBAKE.is_file(), 'INSUFFICIENT PREREQUISITE: runtime/prebuilt-discourse/merge_rebake.rb is missing')
        self.rebake_outputs = []
        f.copy(REBAKE, REBAKE_GUEST)
        token = secrets.token_hex(8)
        raws = ['**Invented** %s post %s\n\n* one\n* `two`\n\n> quoted line' % (role, token)
                for role in ('changed', 'unchanged', 'current', 'deleted')]
        self.assertFalse(any('http' in raw or '//' in raw or 'www' in raw for raw in raws), 'invented posts must not link anywhere')
        stale = '<p>stale ' + secrets.token_hex(8) + '</p>'
        stale_md5 = hashlib.md5(stale.encode()).hexdigest()
        titles = ['Invented private title ' + secrets.token_hex(8) for _ in range(2)]
        refusal = 'invented refusal ' + secrets.token_hex(8)

        made = self.drive(mode='posts', system_edit='absent', site_title=titles[0],
                          create={'title': 'Invented rebake topic ' + token, 'raws': raws})
        ids = made['post_ids']
        changed, unchanged, current, deleted = ids
        current_version = made['baked_version']
        self.assertEqual(4, len(set(ids)))
        self.assertIs(made['jobs_inline'], False, 'this Rails environment runs jobs inline: queueing cannot be shown')
        self.assertEqual(0, made['sidekiq_processes'], 'a Sidekiq process is alive: queued-and-not-run cannot be shown')
        self.assertEqual(0, made['process_post_elsewhere'])
        self.assertEqual({str(key): 0 for key in ids}, made['process_post_ultra_low'], 'making the posts queued rebake jobs')
        created = f.posts()
        self.assertTrue(all(key in created for key in ids))
        self.assertTrue(all(made['fresh_cook'][str(key)] for key in ids), 'PostCreator stored HTML a new cook does not give')
        self.assertFalse(any(created[key][5] for key in ids), 'an invented post rendered a link or a source')
        type(self).notes['stock_task_would_store_' + SYSTEM_EDIT] = (
            'yes: posts.rake assigns it and assigns it back (cached revision source, not run here)')

        def stage():
            """Stale by SQL alone: wrong HTML with no marker, right HTML with an old marker, wrong HTML
            with the current marker, and a soft-deleted post (plain UPDATE: fixture-only, no destroyer)."""
            f.sql("UPDATE posts SET cooked = '%s', baked_version = NULL WHERE id = %d;"
                  "UPDATE posts SET baked_version = %d WHERE id = %d;"
                  "UPDATE posts SET cooked = '%s', baked_version = %d WHERE id = %d;"
                  "UPDATE posts SET cooked = '%s', baked_version = NULL, deleted_at = COALESCE(deleted_at, now()) WHERE id = %d;"
                  % (stale, changed, current_version - 1, unchanged, stale, current_version, current, stale, deleted),
                  'discourse')
            staged = f.posts()
            self.assertEqual([stale_md5, None], staged[changed][:2])
            self.assertEqual([created[unchanged][0], current_version - 1], staged[unchanged][:2])
            self.assertEqual([stale_md5, current_version], staged[current][:2])
            self.assertEqual([stale_md5, None, True], staged[deleted][:3])
            self.assertNotEqual(stale_md5, created[changed][0])
            return staged

        def completed(result, staged, rows, counts, probe_before, label):
            done, told = self.rebake_lines(result)
            self.assertEqual(0, result.returncode, 'rebake failed ' + str(told))
            self.assertEqual([], told)
            self.assertIsNotNone(done, 'more than one completion line')
            self.assertEqual(1, len(done), 'the completion line is not the single, last line of standard output')
            after = f.posts()
            live = {key: post for key, post in after.items() if not post[2]}
            self.assertEqual(set(staged), set(after))
            self.assertEqual(len(live), done[0], 'completion count is not the number of posts that are not deleted')
            self.assertGreaterEqual(done[0], 3)
            self.assertEqual([], sorted(key for key, post in live.items() if post[1] != current_version),
                             'posts left without the current baked_version')
            self.same(created[changed][0], after[changed][0], 'stale HTML was not replaced by the cooked post')
            self.same(created[unchanged][0], after[unchanged][0], 'HTML that was already right changed')
            self.same(created[current][0], after[current][0], 'a post already marked current kept its stale HTML')
            self.assertEqual([], [key for key, post in live.items() if post[0] == stale_md5])
            self.assertFalse(any(after[key][5] for key in ids), 'an invented post rendered a link or a source')
            # A rebake is not an edit: no post text or modification time moved, nothing was revised or notified.
            self.same({key: post[3:5] for key, post in staged.items()}, {key: post[3:5] for key, post in after.items()},
                      'rebake changed a post text or modification time')
            self.assertEqual(counts, f.counts(), 'rebake created a notification or a post revision')
            self.same(rows, f.rows(), 'rebake changed a stored setting (value, type, id or timestamps)')
            probe = self.drive(mode='posts', ids=ids)
            self.same(rows, f.rows(), 'the probe changed a stored setting')
            self.assertEqual(0, probe['sidekiq_processes'], 'a Sidekiq process is alive: queued-and-not-run cannot be shown')
            self.assertIs(probe['jobs_inline'], False)
            self.assertTrue(all(probe['fresh_cook'][str(key)] for key in (changed, unchanged, current)),
                            'stored HTML is not what a new cook gives')
            # Follow-up work is queued, once per rebaked post and at the stock task's priority, and still there.
            queued = {key: probe['process_post_ultra_low'][str(key)] - probe_before['process_post_ultra_low'][str(key)]
                      for key in ids}
            self.assertEqual({changed: 1, unchanged: 1, current: 1}, {key: queued[key] for key in (changed, unchanged, current)},
                             'not exactly one process_post job queued per rebaked post on ultra_low')
            self.assertEqual(0, probe['process_post_elsewhere'], 'a rebake job was queued at another priority')
            grown = probe['queue_sizes'].get('ultra_low', 0) - probe_before['queue_sizes'].get('ultra_low', 0)
            self.assertGreaterEqual(grown, done[0], 'fewer jobs queued than posts rebaked: some ran or were lost')
            type(self).notes['rebake_' + label] = dict(
                posts=done[0], ultra_low_jobs_queued_not_run=grown,
                deleted_post_left_alone=after[deleted][:2] == staged[deleted][:2] and queued[deleted] == 0)
            return probe

        # 1. No stored disable_system_edit_notifications row (a new site's real state).
        staged = stage()
        rows = f.rows()
        self.assertNotIn(SYSTEM_EDIT, rows)
        self.same(titles[0], rows['title'][0], 'invented title not stored')
        _, digest = self.capture()
        counts = f.counts()

        # No completion without proof, and nothing touched before the settings are proven.
        self.refused_rebake(self.rebake('0' * 64), 4, r'^settings snapshot-digest-mismatch$', staged, rows, counts)
        f.sql("UPDATE site_settings SET value = '%s' WHERE name = 'title'" % titles[1], 'discourse')
        try:
            dirty = f.rows()
            result = self.rebake(digest)
        finally:
            f.sql("UPDATE site_settings SET value = '%s' WHERE name = 'title'" % titles[0], 'discourse')
        self.refused_rebake(result, 4, r'^settings changed-before-rebake$', staged, rows, counts)
        self.same(titles[1], dirty['title'][0], 'scenario not established: title not changed')

        probe = completed(self.rebake(digest), staged, rows, counts, made, 'without_stored_' + SYSTEM_EDIT)
        self.assertNotIn(SYSTEM_EDIT, f.rows(), 'rebake stored a disable_system_edit_notifications row')

        # 2. A stored, non-default disable_system_edit_notifications row.
        stored = self.drive(mode='posts', ids=ids, system_edit='stored')
        self.assertNotEqual(stored['system_edit_default'], stored['system_edit_effective'])
        staged = stage()
        rows = f.rows()
        self.assertIn(SYSTEM_EDIT, rows)
        _, digest = self.capture()
        completed(self.rebake(digest), staged, rows, counts, stored, 'with_stored_' + SYSTEM_EDIT)
        self.assertEqual(stored['process_post_ultra_low'], probe['process_post_ultra_low'])

        # 3. One post cannot be saved. The stock task prints the error and carries on to exit 0;
        # this must stop, say so with class names only, and not claim completion.
        staged = stage()
        f.sql("CREATE FUNCTION silo_test_refuse() RETURNS trigger LANGUAGE plpgsql AS "
              "$$ BEGIN RAISE EXCEPTION '%s'; END $$;"
              "CREATE TRIGGER silo_test_refuse BEFORE UPDATE ON posts FOR EACH ROW "
              "WHEN (NEW.id = %d AND NEW.baked_version IS NOT NULL) EXECUTE FUNCTION silo_test_refuse()"
              % (refusal, unchanged), 'discourse')
        try:
            result = self.rebake(digest)
        finally:
            f.sql('DROP TRIGGER silo_test_refuse ON posts; DROP FUNCTION silo_test_refuse()', 'discourse')
        failure = self.refused_rebake(result, 1, r'^failed \(', None, rows, counts)
        type(self).notes['rebake_unsaveable_post'] = failure
        after = f.posts()
        self.assertIsNone(after[unchanged][1], 'the post that could not be saved is marked current')
        self.assertIsNone(after[current][1], 'the run carried on after a post failed')

        for result in self.rebake_outputs:
            for value in (token, stale, refusal, *titles):
                self.assertTrue(value.encode() not in result.stdout and value.encode() not in result.stderr,
                                'post text, a setting value or an error message reached rebake output (output suppressed)')

    def test_library_methods_read_fresh_state_and_keep_the_getter_current(self):
        f = self.f
        token = secrets.token_hex(4)
        baselines = [
            {'kind': 'absent'},
            {'kind': 'setter', 'value': 'pdf|lib' + token + '|png', 'foreign': 'doc|for' + token},
            # Not what the public setter stores: mixed case, a space, a trailing pipe, string type.
            {'kind': 'raw', 'value': 'PDF| Jpg|raw' + token + '|', 'data_type': 1},
        ]
        fresh = [{'kind': 'setter', 'value': 'odt|new' + token + '|gif'}, {'kind': 'absent'}]
        title, outside = ('Invented private title ' + secrets.token_hex(8) for _ in range(2))
        before = f.rows()
        facts = self.drive(mode='library', baselines=baselines, fresh=fresh, title=title, outside_title=outside)
        after = f.rows()
        type(self).notes['rails_runner_query_cache_enabled'] = facts['query_cache']
        self.assertEqual(0, facts['require_output_bytes'], 'requiring the helper as a library printed output')
        self.assertEqual(self.stock_value, facts['stock_constant'])
        self.assertEqual(SNAPSHOT_GUEST, facts['snapshot_path'])
        self.assertEqual('SILO_MERGE_SITE_SETTINGS_SHA256', facts['digest_env'])
        before.pop('title', None)
        self.same(title, after.pop('title')[0], 'the driver did not put its own title change back')
        self.same(self.others(before), self.others(after), 'another stored setting changed (value, type, id or timestamps)')
        self.assertNotIn(NAME, after)
        self.assertEqual([spec['kind'] for spec in baselines], [case['kind'] for case in facts['cases']])
        names = set(before) | set(after) | {NAME, 'title'}
        for spec, case in zip(baselines, facts['cases']):
            with self.subTest(baseline=spec['kind']):
                row, effective = case['before']['row'], case['before']['effective']
                if spec['kind'] == 'absent':
                    self.assertIsNone(row)
                    self.assertIsNone(case['snapshot_entry'])
                    self.same(facts['default'], effective, 'no stored row, yet the effective value is not the default')
                else:
                    self.same([spec['value'], spec.get('data_type', row[1])], row, 'baseline pair not stored as given')
                    self.same(row, case['snapshot_entry'], 'snapshot pair is not the stored pair')
                self.same(effective, case['snapshot_effective'], 'snapshot effective value is not the getter value')
                self.assertNotEqual(self.stock_value, effective)
                self.assertEqual(self.stock_value, case['during']['effective'])
                self.assertEqual(self.stock_value, case['during']['row'][0])
                for key, kind in (('window', 'verify'), ('strict', 'verify'), ('restored', 'restore'),
                                  ('clean', 'verify'), ('again', 'restore')):
                    self.check_report(case[key], kind, names)
                self.assertEqual(('clean', [], [], 0), shape(case['window']),
                                 'the stock write alone was not accepted while copying')
                self.assertEqual(('dirty', [NAME], [], 1), shape(case['strict']))
                if spec.get('foreign'):
                    self.check_report(case['foreign'], 'verify', names)
                    self.assertEqual(('dirty', [NAME]), shape(case['foreign'])[:2],
                                     'a value other than the stock one was accepted while copying')
                found = self.facets(row, case['after']['row'])
                found += ' (same-process getter: ' + ('current' if effective == case['after']['effective'] else 'differs') + ')'
                for key in ('restored', 'again'):
                    self.assertEqual(('restored', [], [], 0), shape(case[key]), key + found)
                self.assertEqual(('clean', [], [], 0), shape(case['clean']))
                self.same(row, case['after']['row'], 'stored pair (raw value, data type) or absence not restored' + found)
                self.same(row, case['again_row'], 'a second restore changed the stored pair')
                self.same(effective, case['after']['effective'], 'same-process getter stale after restore')
                self.same(effective, case['refreshed_effective'], 'cache and stored row disagree after restore')
                # SiteSetting's per-process client hash and JSON, filled before and during the stock write.
                self.assertIs(case['client_before'], True, 'scenario not established: client caches lacked the baseline')
                self.assertIs(case['client_during'], True, 'scenario not established: client caches lacked the stock value')
                self.assertIs(case['client_after'], True,
                              'client settings hash/JSON of the same process not at the baseline after restore')
        self.assertEqual([spec['kind'] for spec in fresh], [case['kind'] for case in facts['fresh']])
        for spec, case in zip(fresh, facts['fresh']):
            with self.subTest(warmed_query_cache=spec['kind']):
                self.fresh_reads(case, names)

    def fresh_reads(self, case, names):
        """One baseline of the driver's freshness(): stored changes ActiveRecord was not told about."""
        prior = case['before']
        unexercised = ': the query cache was not serving the old answer, so freshness was not exercised'
        self.assertIs(case['query_cache'], True, 'query cache was not on')
        reports = dict(primed='verify', other_seen='verify', other_window='verify', other_restore='restore',
                       other_recovered='verify', row_seen='verify', row_restore='restore', row_clean='verify',
                       getter_seen='verify', getter_restore='restore', getter_clean='verify',
                       lookup_restore='restore', lookup_verify='verify')
        for key, kind in reports.items():
            self.check_report(case[key], kind, names)
        self.assertEqual(('clean', [], [], 0), shape(case['primed']))

        # 1. Another setting, changed and then put back, with the old answer cached throughout.
        self.assertIs(case['other_control_stale'], True, 'other setting' + unexercised)
        self.assertEqual(('dirty', [], ['title'], 1), shape(case['other_seen']),
                         'verify repeated an earlier answer: a stored change made outside ActiveRecord was not seen')
        self.assertEqual(('dirty', [], ['title'], 1), shape(case['other_window']),
                         'the while-copying check did not see a stored change made outside ActiveRecord')
        self.assertEqual(('unproven', [], ['title'], 1), shape(case['other_restore']),
                         'restore did not report a stored change made outside ActiveRecord')
        self.assertIs(case['other_kept'], True, 'a setting other than authorized_extensions was repaired')
        self.assertEqual(('clean', [], [], 0), shape(case['other_recovered']),
                         'verify did not see the stored row put back')

        # 2. The stored authorized_extensions row changes; only the table knows.
        self.assertIs(case['row_control_stale'], True, 'authorized_extensions row' + unexercised)
        self.assertIs(case['row_getter_untold'], True, 'scenario not established: the getter already followed the table')
        self.assertEqual(('dirty', [NAME], [], 1), shape(case['row_seen']),
                         'verify trusted the cache or the getter: the changed stored row was not seen')
        found = self.facets(prior['row'], case['row_after']['row'])
        self.assertEqual(('restored', [], [], 0), shape(case['row_restore']), found)
        self.same(prior, case['row_after'], 'restore did not act on the stored row as it really was' + found)
        self.assertEqual(('clean', [], [], 0), shape(case['row_clean']))

        # 3. The stored row is right; the getter of this process is not.
        self.assertIs(case['getter_control_stale'], True, 'getter' + unexercised)
        self.assertIs(case['getter_stored_prior'], True, 'scenario not established: stored row not put back')
        self.assertIs(case['getter_untold'], True, 'scenario not established: the getter already followed the table')
        self.assertEqual(('dirty', [NAME], [], 1), shape(case['getter_seen']),
                         'verify passed while the effective value differed')
        found = self.facets(prior['row'], case['getter_after']['row'])
        self.assertEqual(('restored', [], [], 0), shape(case['getter_restore']), found)
        self.same(prior, case['getter_after'], 'restore left the same-process getter stale' + found)
        self.assertIs(case['getter_client_untold'], True, 'scenario not established: client caches lacked the stock value')
        self.assertIs(case['getter_client_after'], True,
                      'restore left the client settings hash/JSON of the same process at the stock value')
        self.assertEqual(('clean', [], [], 0), shape(case['getter_clean']))

        # 4. The provider's own lookups were cached too. Restoring may fail; a false claim may not.
        self.assertIs(case['lookup_control_stale'], True, 'provider lookup' + unexercised)
        really = prior == case['lookup_after']
        outcome = case['lookup_restore']['state']
        self.assertEqual(really, outcome == 'restored',
                         'restore reported "' + outcome + '" while the stored/effective state says otherwise')
        self.assertEqual(really, case['lookup_verify']['state'] == 'clean',
                         'verify disagreed with the stored/effective state')
        if not really:
            self.assertIn(NAME, case['lookup_restore']['restoration_failed'])
            self.assertIn(NAME, case['lookup_verify']['restoration_failed'])
        type(self).notes['restore_with_cached_provider_lookup_' + case['kind']] = outcome
        self.assertIs(case['reset'], True, 'the driver could not put the invented site back')
        type(self).notes['stale_cache_controls_' + case['kind']] = sum(
            case[key] is True for key in ('other_control_stale', 'row_control_stale', 'getter_control_stale',
                                          'lookup_control_stale'))
        type(self).notes['cache_still_warm_after_noop_restore_' + case['kind']] = case['other_still_warm']


if __name__ == '__main__':
    unittest.main()
