"""Opt-in: the merger tools' sealed container for real, on invented files only.

    SILO_MERGER_DEV_LIVE=1 python3 -I -B test/merger_dev_live_test.py

Nothing is mocked or patched on the path under test: the image is the one the repository's own
qualified runtime profile pins (resolved by converter_dev.converter_image_document through the
real `docker image inspect` and identity check), run by converter_dev.run_in_sandbox with
--pull=never and --network none. It must already be loaded locally: nothing is pulled, built or
installed, and there is no converter checkout, Gemfile or dependency step. The only stand-in is
the service's `standard merger init WS`, replaced by the same `git init` it runs (the Ruby action
has its own tests); the dependency and emoji steps are replaced by assertions that they never run.
"""
import base64
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
MARKER = 'CUSTOMER-CANARY-live-41c9'
CLEAN_ENV = dict({k: v for k, v in os.environ.items() if not k.startswith('GIT_')}, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')

# Deliberately not formatted: dev_merger_format must change it.
MERGER = '''require "yaml"
require_relative "helpers/policy/category_map"
class InventedMerger < BulkImport::DiscourseMerger
  def initialize
    super
    @map = InventedCategoryMap.new( YAML.safe_load_file(ENV.fetch("SILO_MERGE_SETTINGS")) )
  end
  def category_exists(row)
    @map.destination(row["slug"]) || super
  end
end
'''
HELPER = '''class InventedCategoryMap
  def initialize(settings)
    @routes = settings.fetch("category_map")
  end

  def destination(slug)
    @routes[slug]
  end
end
'''
LAYER_TEST = '''require "minitest/autorun"
require "socket"
require "tempfile"
require "yaml"

module BulkImport
  class DiscourseMerger
    def initialize
    end

    def category_exists(_row)
      nil
    end
  end
end
require_relative "../merger"

class InventedMergerTest < Minitest::Test
  def test_routes_an_invented_category_from_invented_settings
    Tempfile.create(%w[settings .yml]) do |file|
      file.write({ "category_map" => { "invented-source" => 7 } }.to_yaml)
      file.flush
      ENV["SILO_MERGE_SETTINGS"] = file.path
      merger = InventedMerger.new
      assert_equal 7, merger.category_exists({ "slug" => "invented-source" })
      assert_nil merger.category_exists({ "slug" => "elsewhere" })
    end
  end

  def test_the_container_is_sealed_and_holds_only_the_visible_merger_files
    assert_nil defined?(Bundler)
    assert_empty ENV.keys & %w[BUNDLE_PATH BUNDLE_GEMFILE BUNDLE_APP_CONFIG BUNDLE_FROZEN RUBYOPT]
    refute File.exist?("Gemfile")
    assert_equal %w[README.md helpers merger.rb test], Dir.children("/app").sort
    assert_equal %w[test/fixtures/settings.yml test/merger_test.rb],
                 Dir["test/**/*"].select { |path| File.file?(path) }.sort
    refute File.exist?("/deps")
    assert_equal %w[lo], Socket.getifaddrs.map(&:name).uniq
    assert_raises(SystemCallError, SocketError) do
      TCPSocket.new("192.0.2.1", 80, connect_timeout: 2)
    end
    root = File.readlines("/proc/mounts").map(&:split).find { |mount| mount[1] == "/" }
    assert_includes root[3].split(","), "ro"
    assert_operator Process.uid, :>, 0
  end
end
'''
FAILING_TEST = '''require "minitest/autorun"

class InventedFailureTest < Minitest::Test
  def test_reports_a_failure
    assert_equal 1, 2
  end
end
'''


def load(name, relative):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / relative))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    loader.exec_module(module)
    return module


@unittest.skipUnless(os.environ.get('SILO_MERGER_DEV_LIVE') == '1', 'opt-in cached-image merger sandbox (no pull, no network, invented files)')
class MergerDevLiveTest(unittest.TestCase):
    def setUp(self):
        old = os.umask(0o022)
        self.addCleanup(os.umask, old)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        top = Path(self.temp.name).resolve()
        self.merger = load('merger_dev_live', 'bin/merger_dev.py')
        self.dev = self.merger.dev
        self.host = load('merger_dev_live_control', 'bin/silo-migrate-control')  # the real inspect() and identity()
        self.addCleanup(sys.modules.pop, 'merger_dev_live_control', None)
        self.addCleanup(sys.modules.pop, 'merger_dev_live', None)
        profiles = sorted((ROOT / 'runtime/profiles').glob('*.json'))
        self.assertEqual(1, len(profiles), 'expected the one qualified runtime profile')
        raw = profiles[0].read_bytes()
        self.profile = json.loads(raw)
        self.base, self.home, self.ws = top / 'workspaces', top / 'home', 'example-forum'
        self.root = self.base / self.ws
        standard = self.root / '.silo-migrate/named/standard'
        standard.mkdir(parents=True)
        (self.root / '.silo-migrate/named/state.json').write_text(json.dumps(
            {'sources': {'a': {'platform': base64.b64encode(b'discourse').decode()}}}))
        # The workspace's pinned profile is all that names the image: no converter keys, no converter checkout.
        (standard / 'state.json').write_text(json.dumps({'config': {
            'discourse_profile': profiles[0].stem, 'discourse_profile_sha256': hashlib.sha256(raw).hexdigest()}, 'runs': {}, 'plans': {}}))
        identity = self.home / '.config/silo-migrate/git-identity'
        identity.parent.mkdir(parents=True)
        identity.write_text('name=Invented Engineer\nemail=engineer@example.invalid\n')
        os.chmod(identity, 0o600)
        self.store = self.root / 'merger'
        (self.root / 'inputs').mkdir()
        (self.root / 'inputs/source.sql').write_text(MARKER)
        self.outputs, self.runs = [], []

    def tearDown(self):
        for output in self.outputs:
            self.assertNotIn(MARKER, output)

    def service_init(self, workspace):
        path = self.base / workspace / 'merger'
        path.mkdir(mode=0o700)
        subprocess.run(['git', 'init', '--quiet', '--template=', '--initial-branch=main', str(path)], check=True, env=CLEAN_ENV)

    def call(self, op, role='developer', **request):
        try:
            result = self.merger.main(['merger', 'dev', self.ws, '--role', role], {}, self.base, ROOT, self.host,
                                      io.StringIO(json.dumps(dict(op=op, **request))), init=self.service_init, home=str(self.home))
        except ValueError as refusal:
            result = {'error': str(refusal)}
        self.outputs.append(json.dumps(result))
        return result

    def mounts(self, argv):
        return [argv[i + 1] for i, arg in enumerate(argv) if arg == '--mount']

    def test_python_commit_and_ruby_plan_reader_agree_on_the_same_manifest(self):
        gems = ROOT.parents[1] / '.runtime-cache/gems'
        image = 'ruby:3.3-bookworm'
        if not gems.is_dir() or subprocess.run(['docker', 'image', 'inspect', image], capture_output=True).returncode:
            self.skipTest('cached Ruby control gems and ruby:3.3-bookworm required; never downloaded')
        self.assertNotIn('error', self.call('init'))
        for path, content in {'merger.rb': MERGER, 'helpers/policy/category_map.rb': HELPER,
                              'test/merger_test.rb': LAYER_TEST, 'README.md': 'Invented notes'}.items():
            self.assertNotIn('error', self.call('write', path=path, content=content))
        committed = self.call('commit', message='Add invented policy layer')
        self.assertNotIn('error', committed)
        python_layer = self.call('status')['layer']
        script = ('require "json"; require "silo_migrate"; '
                  'env = {"SILO_MIGRATE_BASE_PATH" => "/fixtures/workspaces", '
                  '"SILO_MIGRATE_USER_CONFIG" => "/tmp/user-config.env", '
                  '"SILO_MIGRATE_IGNORE_LEGACY_DEFAULT" => "1"}; '
                  'service = SiloMigrate::Services::StandardWorkflowService.new("example-forum", env: env); '
                  'puts JSON.generate(service.merger_status[:layer])')
        result = subprocess.run(['docker', 'run', '--rm', '--pull=never', '--network', 'none', '--read-only',
            '--user', f'{os.getuid()}:{os.getgid()}', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
            '--tmpfs', '/tmp:rw,exec', '--mount', f'type=bind,src={ROOT},dst=/code,readonly',
            '--mount', f'type=bind,src={Path(self.temp.name)},dst=/fixtures,readonly',
            '--mount', f'type=bind,src={gems},dst=/gems,readonly', '-e', 'HOME=/tmp',
            '-e', 'GEM_HOME=/gems/ruby/3.3.0', '-e', 'GEM_PATH=/gems/ruby/3.3.0:/gems:/usr/local/bundle',
            '-w', '/code', '--entrypoint', 'ruby', image, '-Ilib', '-e', script],
            capture_output=True, timeout=60)
        self.assertEqual(0, result.returncode, result.stderr.decode('utf-8', 'replace'))
        self.assertEqual(python_layer, json.loads(result.stdout))

    def test_minitest_and_the_formatter_run_exported_files_in_the_pinned_image_with_nothing_else(self):
        real_docker = self.dev.docker

        def recorded(argv, timeout):
            self.runs.append(list(argv))
            return real_docker(argv, timeout)

        self.assertFalse((self.root / 'converter').exists())
        with mock.patch.object(self.dev, 'docker', side_effect=recorded), \
                mock.patch.object(self.dev, 'prepare_dependencies', side_effect=AssertionError('dependency step')), \
                mock.patch.object(self.dev, 'fetch_emoji', side_effect=AssertionError('network')), \
                mock.patch.object(self.dev, 'site_settings_cache', side_effect=AssertionError('converter cache')):
            self.assertNotIn('error', self.call('init'))
            for path, content in {'merger.rb': MERGER, 'helpers/policy/category_map.rb': HELPER, 'test/merger_test.rb': LAYER_TEST,
                                  'test/fixtures/settings.yml': 'category_map:\n  invented-source: 7\n', 'README.md': 'Invented notes\n'}.items():
                self.assertNotIn('error', self.call('write', path=path, content=content), path)
            # Hand-made files the tools never wrote stay on the host: not exported, not run.
            (self.store / 'test/customer_export.yml').write_text(MARKER)
            (self.store / 'test/by_hand_test.rb').write_text('raise %r\n' % MARKER)

            passed = self.call('test')
            self.assertEqual((0, False, '2 runs, 15 assertions, 0 failures, 0 errors, 0 skips', 5),
                             tuple(passed.get(k) for k in ('exit_code', 'timed_out', 'summary', 'files_exported')), passed)

            # A failing test is reported as one, for one named file.
            self.assertNotIn('error', self.call('write', path='test/failing_test.rb', content=FAILING_TEST))
            failed = self.call('test', role='reviewer', file='test/failing_test.rb')
            self.assertEqual((1, '1 runs, 1 assertions, 1 failures, 0 errors, 0 skips'), (failed.get('exit_code'), failed.get('summary')), failed)
            self.assertIn('InventedFailureTest#test_reports_a_failure', failed['stdout_tail'])
            self.assertNotIn('error', self.call('delete', path='test/failing_test.rb'))

            # The image's own syntax_tree, with no Bundler: it rewrites merger.rb and only through the recorded path.
            formatted = self.call('format')
            self.assertEqual(['merger.rb'], formatted.get('formatted'), formatted)
            text = (self.store / 'merger.rb').read_text()
            self.assertNotEqual(MERGER, text)
            self.assertIn('InventedCategoryMap.new(YAML.safe_load_file(ENV.fetch("SILO_MERGE_SETTINGS")))', text)
            self.assertEqual(([], 3), (lambda again: (again.get('formatted'), again.get('unchanged')))(self.call('format')))
            # A file that is not Ruby is a reported failure that changes nothing.
            self.assertNotIn('error', self.call('write', path='helpers/broken.rb', content='class Broken\n  def (\n'))
            broken = self.call('format', path='helpers/broken.rb')
            self.assertEqual(([], False), (broken.get('formatted'), broken.get('timed_out')), broken)
            self.assertNotIn(broken.get('exit_code'), (0, None, 126, 127))
            self.assertEqual('class Broken\n  def (\n', (self.store / 'helpers/broken.rb').read_text())
            self.assertNotIn('error', self.call('delete', path='helpers/broken.rb'))

            commit = self.call('commit', message='Add the invented merge layer')
            self.assertNotIn('error', commit)
            self.assertEqual((2, None), (commit['layer']['files'], commit['layer_error']))
            reviewed = self.call('test', role='reviewer')
            self.assertEqual((0, '2 runs, 15 assertions, 0 failures, 0 errors, 0 skips'), (reviewed.get('exit_code'), reviewed.get('summary')), reviewed)

        # Every container: the pinned image by content id, never pulled, no network, only the export mounted.
        pinned = self.profile['images']['converter']
        document = self.host.inspect(pinned['ref'])
        self.assertEqual(pinned['content_id'], self.host.identity(document))
        self.assertEqual(6, len(self.runs))
        for argv in self.runs:
            self.assertEqual(['docker', 'run', '--rm'], argv[:3])
            for flags in (['--pull=never'], ['--network', 'none'], ['--read-only'], ['--cap-drop', 'ALL'], ['--security-opt', 'no-new-privileges']):
                self.assertTrue(any(argv[i:i + len(flags)] == flags for i in range(len(argv))), flags)
            mounts = self.mounts(argv)
            self.assertEqual(1, len(mounts), mounts)
            self.assertRegex(mounts[0], r'\Atype=bind,src=[^,]*silo-devtest-[^,]*,dst=/app\Z')
            self.assertIn(document['Id'], argv)
            self.assertFalse([arg for arg in argv if 'converter' in arg and arg != document['Id']], argv)
        # Nothing was left behind or fetched: no exports, no dependency cache, no converter, no remote.
        self.assertFalse((self.root / 'converter').exists())
        self.assertEqual(['.silo-migrate', 'inputs', 'merger'], sorted(p.name for p in self.root.iterdir()))
        self.assertEqual('', subprocess.run(['git', '-C', str(self.store), 'remote'], check=True, capture_output=True, text=True, env=CLEAN_ENV).stdout)


if __name__ == '__main__':
    unittest.main()
