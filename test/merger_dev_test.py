"""Standalone local merger repository: the coding agents' boundary, with real Git and no Docker,
network, converter checkout or customer data. Run: python3 -I -B test/merger_dev_test.py."""
import base64
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
MARKER = 'CUSTOMER-CANARY-7d1f0a'
IMAGE_ID = 'sha256:' + 'b' * 64
IMAGE_DOCUMENT = {'Id': IMAGE_ID, 'Config': {'Env': ['PATH=/usr/local/bundle/bin:/usr/bin', 'RUBY_VERSION=3.3.13', 'GEM_HOME=/usr/local/bundle',
                                                     'BUNDLE_PATH=/opt/bundle', 'BUNDLE_FROZEN=true', 'BUNDLE_GEMFILE=/app/Gemfile']}}
ENTRY = 'class InventedMerger < BulkImport::DiscourseMerger\n  def category_exists(row)\n    super\n  end\nend\n'
CLEAN_ENV = dict({k: v for k, v in os.environ.items() if not k.startswith('GIT_')}, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                 GIT_AUTHOR_NAME='Engineer', GIT_AUTHOR_EMAIL='engineer@example.invalid', GIT_COMMITTER_NAME='Engineer',
                 GIT_COMMITTER_EMAIL='engineer@example.invalid')


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'bin' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(cwd, *args):
    """Plain Git, as the engineer working in the repository directly."""
    return subprocess.run(['git', '-C', str(cwd), *args], check=True, capture_output=True, text=True, env=CLEAN_ENV).stdout.strip()


class MergerDevTest(unittest.TestCase):
    def setUp(self):
        old = os.umask(0o022)  # the account's umask; the gate refuses a group-writable .git
        self.addCleanup(os.umask, old)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        top = Path(self.temp.name).resolve()
        self.merger = load('merger_dev')
        self.dev = self.merger.dev
        self.host = types.SimpleNamespace(**runpy.run_path(str(ROOT / 'bin/silo-migrate-control')))
        self.base, self.home, self.ws = top / 'workspaces', top / 'home', 'example-forum'
        self.root = self.base / self.ws
        self.standard = self.root / '.silo-migrate/named/standard'
        self.standard.mkdir(parents=True)
        (self.root / '.silo-migrate/named/state.json').write_text(json.dumps(
            {'sources': {'a': {'platform': base64.b64encode(b'discourse').decode()}}}))
        # No converter checkout, no converter keys: the merger tools must not need either.
        self.state = {'config': {'discourse_profile': 'profile-a', 'discourse_profile_sha256': ''}, 'runs': {}, 'plans': {}}
        self.save_state()
        self.write(self.home / '.config/silo-migrate/git-identity', 'name=Invented Engineer\nemail=engineer@example.invalid\n')
        os.chmod(self.home / '.config/silo-migrate/git-identity', 0o600)
        self.store = self.root / 'merger'
        # Customer-like material everywhere an agent must not reach.
        self.write(self.root / 'inputs/source.sql', MARKER)
        self.write(self.standard / 'runs/run-1/logs/merge.log', MARKER)
        self.inits, self.outputs, self.values = [], [], {}

    def tearDown(self):
        for output in self.outputs:
            self.assertNotIn(MARKER, output)

    @staticmethod
    def write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def save_state(self):
        (self.standard / 'state.json').write_text(json.dumps(self.state))

    def service_init(self, workspace):
        """Stands in for `standard merger init WS` (StandardMergeCode#merger_init): no template, remote or commit."""
        self.inits.append(workspace)
        path = self.base / workspace / 'merger'
        path.mkdir(mode=0o700)
        subprocess.run(['git', 'init', '--quiet', '--template=', '--initial-branch=main', str(path)], check=True, env=CLEAN_ENV)

    def call(self, op, role='developer', **request):
        stdin = io.StringIO(json.dumps(dict(op=op, **request)))
        try:
            result = self.merger.main(['merger', 'dev', self.ws, '--role', role], self.values, self.base, ROOT, self.host, stdin,
                                      init=self.service_init, home=str(self.home))
        except ValueError as refusal:
            result = {'error': str(refusal)}
        self.outputs.append(json.dumps(result))
        return result

    def ready(self, **files):
        """An initialized repository with one tool-made commit."""
        self.assertNotIn('error', self.call('init'))
        for path, content in ({'merger.rb': ENTRY} | files).items():
            self.assertNotIn('error', self.call('write', path=path, content=content))
        commit = self.call('commit', message='Add the merge layer')
        self.assertNotIn('error', commit)
        return commit

    @staticmethod
    def bound(commit, files):
        """What StandardMergeCode#merger_layer! binds, computed independently."""
        manifest = sorted(hashlib.sha256(data.encode()).hexdigest() + ' ' + name + '\n' for name, data in files.items())
        return {'present': True, 'store': 'merger', 'path': 'merger.rb', 'revision': commit, 'files': len(files),
                'bytes': sum(len(data.encode()) for data in files.values()), 'sha256': hashlib.sha256(''.join(manifest).encode()).hexdigest()}

    # -- no repository yet ---------------------------------------------------------------

    def test_without_a_repository_only_the_guide_and_init_answer_and_nothing_else_is_looked_at(self):
        # A converter checkout with merge code beside it is never a fallback.
        self.write(self.root / 'converter/mergers/example-forum/merger.rb', MARKER)
        for role, ops in self.merger.ROLES.items():
            for op in sorted(ops - {'merge-guide', 'init'}):
                with self.subTest(role=role, op=op):
                    result = self.call(op, role=role, path='merger.rb', content='x', message='m', pattern='x', old_text='a', new_text='b')
                    self.assertTrue(result['error'].startswith('STANDARD_MERGER_MISSING'), result)
        self.assertFalse(self.store.exists())
        for role in ('developer', 'reviewer'):
            guide = self.call('merge-guide', role=role)
            self.assertEqual((str(self.store), False, None, None), tuple(guide['merger'][k] for k in ('path', 'initialized', 'head', 'layer')))
            self.assertIn('dev_merger_init', guide['merger']['note'])
            self.assertIn(str(self.store), guide['guide'])
            self.assertNotIn('{', guide['guide'])
            self.assertNotIn('converter/mergers', json.dumps(guide))
        self.assertFalse(self.store.exists())
        self.assertEqual('STANDARD_DEV_OPERATION_REFUSED', self.call('init', role='reviewer')['error'])
        self.assertEqual([], self.inits)

    def test_init_is_the_service_action_once_and_leaves_an_empty_local_repository(self):
        created = self.call('init')
        self.assertEqual((True, str(self.store), True, 'main', None, False, None, 'STANDARD_MERGE_INTENT_MISMATCH'),
                         tuple(created[k] for k in ('created', 'path', 'initialized', 'branch', 'head', 'dirty', 'layer', 'layer_error')))
        again = self.call('init')
        self.assertFalse(again['created'])
        self.assertEqual([self.ws], self.inits)
        self.assertEqual('', git(self.store, 'remote'))
        self.assertEqual([], self.call('list')['entries'])
        self.assertEqual('STANDARD_DEV_NOTHING_TO_COMMIT', self.call('commit', message='Nothing')['error'])
        # Without the service action there is no other way to create it.
        other = self.base / 'other-forum'
        (other / '.silo-migrate/named/standard').mkdir(parents=True)
        (other / '.silo-migrate/named/state.json').write_text('{}')
        (other / '.silo-migrate/named/standard/state.json').write_text('{}')
        with self.assertRaises(ValueError) as refused:
            self.merger.main(['merger', 'dev', 'other-forum', '--role', 'developer'], {}, self.base, ROOT, self.host, io.StringIO('{"op":"init"}'))
        self.assertEqual('STANDARD_OPERATION_FAILED', str(refused.exception))
        self.assertFalse((other / 'merger').exists())

    def test_an_init_that_leaves_an_unsafe_repository_is_refused_by_the_gate(self):
        original = self.service_init

        def unsafe(workspace):
            original(workspace)
            git(self.store, 'remote', 'add', 'origin', 'https://example.invalid/x.git')
        self.service_init = unsafe
        self.assertEqual('STANDARD_MERGER_CONFIG', self.call('init')['error'])
        # Nothing is readable or writable through a store the gate refuses, and init does not repair it.
        for op in ('status', 'list', 'write', 'commit', 'init'):
            self.assertEqual('STANDARD_MERGER_CONFIG', self.call(op, path='merger.rb', content=ENTRY, message='m')['error'], op)
        self.assertEqual([self.ws], self.inits)

    # -- write, commit, identity -----------------------------------------------------------

    def test_first_and_later_commits_are_local_and_report_exactly_what_a_plan_would_bind(self):
        helper = 'module InventedHelper\n  LIMIT = 3\nend\n'
        test = 'require "minitest/autorun"\n'
        first = self.ready(**{'helpers/policy/invented_helper.rb': helper, 'test/merger_test.rb': test, 'README.md': 'Notes\n',
                              'test/fixtures/settings.yml': 'invented_category: 1\n'})
        head = git(self.store, 'rev-parse', 'HEAD')
        self.assertEqual((head, 'main', False, None), (first['commit'], first['branch'], first['dirty'], first['layer_error']))
        # The executable layer is merger.rb + helpers only: tests, fixtures and notes are committed, never bound.
        self.assertEqual(self.bound(head, {'merger.rb': ENTRY, 'helpers/policy/invented_helper.rb': helper}), first['layer'])
        self.assertEqual('', git(self.store, 'rev-list', '--parents', '-n', '1', head).replace(head, '').strip())  # a root commit
        self.assertIn('Assisted-by: converter-developer', git(self.store, 'log', '-1', '--format=%B'))
        self.assertEqual('Invented Engineer <engineer@example.invalid>', git(self.store, 'log', '-1', '--format=%an <%ae>'))
        self.assertEqual('', git(self.store, 'status', '--porcelain', '--untracked-files=all'))
        self.assertEqual(sorted(['README.md', 'helpers/policy/invented_helper.rb', 'merger.rb', 'test/fixtures/settings.yml', 'test/merger_test.rb']),
                         sorted(git(self.store, 'ls-tree', '-r', '--name-only', 'HEAD').splitlines()))

        edited = self.call('edit', path='helpers/policy/invented_helper.rb', old_text='LIMIT = 3', new_text='LIMIT = 4')
        self.assertIn('+  LIMIT = 4', edited['diff'])
        status = self.call('status', role='reviewer')
        self.assertEqual((str(self.store), head, True, [{'status': 'M', 'path': 'helpers/policy/invented_helper.rb'}], 0),
                         tuple(status[k] for k in ('path', 'head', 'dirty', 'changes', 'other_changes_not_shown')))
        self.assertEqual(first['layer'], status['layer'])  # still the committed bytes, not the working tree
        self.assertEqual(['Add the merge layer'], [commit['subject'] for commit in status['commits']])
        self.assertIn('+  LIMIT = 4', self.call('diff', role='reviewer')['diff'])
        self.assertNotIn('error', self.call('delete', path='test/fixtures/settings.yml'))
        second = self.call('commit', message='Raise the invented limit')
        self.assertEqual(head, git(self.store, 'rev-parse', 'HEAD~1'))
        self.assertEqual(self.bound(second['commit'], {'merger.rb': ENTRY, 'helpers/policy/invented_helper.rb': helper.replace('3', '4')}), second['layer'])
        self.assertFalse(second['dirty'])
        # Committed identity is reviewable: the commit's own diff, and an older one by id.
        shown = self.call('diff', role='reviewer', scope='commit')
        self.assertEqual((second['commit'], head), (shown['commit'], shown['parent']))
        self.assertIn('+  LIMIT = 4', shown['diff'])
        self.assertIn('+class InventedMerger', self.call('diff', role='reviewer', scope='commit', commit=head, path='merger.rb')['diff'])
        self.assertEqual(ENTRY, self.call('read', role='reviewer', path='merger.rb')['text'])
        self.assertEqual(['merger.rb'], [m['path'] for m in self.call('search', role='reviewer', pattern='category_exists')['matches']])
        # Still nothing that names a remote or another branch.
        self.assertEqual('', git(self.store, 'remote'))
        self.assertEqual(['main'], git(self.store, 'for-each-ref', '--format=%(refname:short)').splitlines())
        self.assertNotIn('remote', git(self.store, 'config', '--local', '--list'))

    def test_commit_does_not_wait_for_a_run_but_refuses_a_detached_head(self):
        self.ready()
        self.state['runs'] = {'run-' + '1' * 32: {'status': 'running'}}
        self.save_state()
        self.assertNotIn('error', self.call('write', path='README.md', content='Invented notes\n'))
        self.assertNotIn('error', self.call('commit', message='Notes while a merge runs'))
        git(self.store, 'checkout', '-q', '--detach')
        self.assertNotIn('error', self.call('write', path='README.md', content='More\n'))
        self.assertEqual('STANDARD_MERGER_DETACHED', self.call('commit', message='Lost')['error'])

    def test_writes_stay_inside_the_fixed_layout(self):
        self.ready()
        for path in ('lib/x.rb', 'x.rb', 'Gemfile', 'Gemfile.lock', '.gitignore', '.gitattributes', '.gitmodules', '.streerc', '.rubocop.yml',
                     'helpers/x.txt', 'helpers', 'helpers/.hidden.rb', 'helpers/-x.rb', 'helpers/a b.rb', 'test/run.sh', 'test', 'test/x',
                     'test/.gitignore', 'README.txt', 'merger.rb/x.rb', '../x.rb', '/tmp/x.rb', '.git/config', 'helpers/../../x.rb',
                     'helpers/.git/x.rb', '.github/workflows/ci.yml', '~/x.rb'):
            with self.subTest(path=path):
                self.assertIn('error', self.call('write', path=path, content='x\n'))
        for path in ('helpers/a.rb', 'helpers/deep/er/b.rb', 'test/a_test.rb', 'test/fixtures/a.yml', 'test/fixtures/a.json', 'README.md'):
            with self.subTest(path=path):
                self.assertNotIn('error', self.call('write', path=path, content='x\n'))
        self.assertEqual('STANDARD_MERGER_PATH_REFUSED', self.call('write', path='lib/x.rb', content='x\n')['error'])
        self.assertFalse((self.store / 'lib').exists())
        self.assertFalse((self.root / 'x.rb').exists())

    # -- only clean tracked or tool-written bytes ----------------------------------------------

    def test_only_committed_or_tool_written_layout_files_are_ever_visible(self):
        self.ready(**{'test/merger_test.rb': 'require "minitest/autorun"\n'})
        # Dropped by hand or by a run: untracked, changed outside the tools, linked, or outside the layout.
        self.write(self.store / 'test/customer_export.yml', MARKER + ': alice@example.test\n')
        self.write(self.store / 'private/customers.csv', MARKER)
        self.write(self.store / 'merger.rb', ENTRY + '# ' + MARKER + '\n')
        (self.store / 'helpers').mkdir()
        (self.store / 'helpers/linked.rb').symlink_to(self.root / 'inputs/source.sql')
        (self.store / 'test/linked').symlink_to(self.root / 'inputs')
        self.assertEqual(['test'], [entry['name'] for entry in self.call('list')['entries']])
        for path in ('test/customer_export.yml', 'private/customers.csv', 'merger.rb', 'helpers/linked.rb', 'test/linked/source.sql',
                     '../inputs/source.sql', '.git/config'):
            with self.subTest(path=path):
                self.assertIn('error', self.call('read', path=path))
                self.assertIn('error', self.call('edit', path=path, old_text='C', new_text='D'))
                self.assertIn('error', self.call('delete', path=path))
        self.assertIn('error', self.call('write', path='merger.rb', content='x\n'))  # never over bytes it can't see
        self.assertEqual([], self.call('search', pattern='CANARY')['matches'])
        self.assertEqual('', self.call('diff')['diff'])
        status = self.call('status')
        self.assertEqual(([], True), (status['changes'], status['dirty']))
        self.assertGreaterEqual(status['other_changes_not_shown'], 3)
        self.assertEqual('STANDARD_DEV_NOTHING_TO_COMMIT', self.call('commit', message='Nothing of mine')['error'])
        self.assertTrue((self.store / 'test/customer_export.yml').exists())

    def test_a_commit_outside_the_layout_is_never_shown_and_never_a_layer(self):
        self.ready()
        self.write(self.store / 'private/customers.csv', MARKER)
        self.write(self.store / 'Gemfile', 'source "https://rubygems.org"\n# ' + MARKER + '\n')
        git(self.store, 'add', '-A')
        git(self.store, 'commit', '-q', '-m', 'By hand')
        status = self.call('status')
        self.assertEqual((None, 'STANDARD_MERGE_LAYER_INVALID', False), (status['layer'], status['layer_error'], status['dirty']))
        self.assertEqual(['merger.rb'], [entry['name'] for entry in self.call('list')['entries']])
        for path in ('private/customers.csv', 'Gemfile'):
            self.assertEqual('STANDARD_DEV_PATH_NOT_VISIBLE', self.call('read', path=path)['error'])
            self.assertEqual('STANDARD_DEV_PATH_NOT_VISIBLE', self.call('diff', scope='commit', path=path)['error'])
        self.assertEqual('', self.call('diff', scope='commit')['diff'])
        self.assertEqual([], self.call('search', pattern='CANARY')['matches'])

    def test_layer_rules_match_the_service(self):
        self.ready()
        head = git(self.store, 'rev-parse', 'HEAD')
        checkout = self.merger.MergerCheckout(self.base, self.ws, self.host)
        self.assertEqual((self.bound(head, {'merger.rb': ENTRY}), None), self.merger.layer(checkout, head))

        def committed(files, mode=None):
            for path, content in files.items():
                self.write(self.store / path, content)
                if mode:
                    os.chmod(self.store / path, mode)
            git(self.store, 'add', '-A')
            git(self.store, 'commit', '-q', '-m', 'By hand')
            checkout = self.merger.MergerCheckout(self.base, self.ws, self.host)
            result = self.merger.layer(checkout, git(self.store, 'rev-parse', 'HEAD'))
            git(self.store, 'reset', '-q', '--hard', head)
            return result
        invalid = (None, 'STANDARD_MERGE_LAYER_INVALID')
        self.assertEqual(invalid, committed({'helpers/notes.txt': 'x\n'}))            # executable files are Ruby only
        self.assertEqual(invalid, committed({'helpers/run.rb': 'x\n'}, mode=0o755))   # and not executable-bit files
        self.assertEqual(invalid, committed({'lib/x.rb': 'x\n'}))                     # unknown top-level entry
        self.assertEqual(invalid, committed({'helpers/a b.rb': 'x\n'}))
        self.assertEqual(invalid, committed({'helpers/big.rb': '#' * (512 * 1024)}))
        self.assertEqual(invalid, committed({'helpers/h%02d.rb' % n: 'x\n' for n in range(32)}))  # 33 with merger.rb
        self.assertIsNone(committed({'helpers/h%02d.rb' % n: 'x\n' for n in range(31)})[1])
        self.assertIsNone(committed({'test/run.sh': 'x\n', 'test/.gitignore': 'tmp\n', '.gitignore': 'tmp/\n'}, mode=0o755)[1])
        git(self.store, 'rm', '-q', 'merger.rb')
        git(self.store, 'commit', '-q', '-m', 'No entry')
        self.assertEqual('STANDARD_MERGE_LAYER_INVALID', self.call('status')['layer_error'])

    def test_a_plan_retained_commit_stays_diffable_and_others_are_refused(self):
        first = self.ready()['commit']
        self.call('write', path='README.md', content='Invented\n')
        second = self.call('commit', message='Notes')['commit']
        git(self.store, 'update-ref', 'refs/silo/merge-plans/plan-abc', second)
        git(self.store, 'reset', '-q', '--hard', first)
        self.assertIn('+Invented', self.call('diff', role='reviewer', scope='commit', commit=second)['diff'])
        git(self.store, 'update-ref', '-d', 'refs/silo/merge-plans/plan-abc')
        for commit in (second, 'f' * 40, 'HEAD~1', 'main', '--all', git(self.store, 'rev-parse', 'HEAD^{tree}')):
            with self.subTest(commit=commit):
                self.assertEqual('STANDARD_ARGUMENTS_INVALID', self.call('diff', scope='commit', commit=commit)['error'])
        self.assertEqual('STANDARD_ARGUMENTS_INVALID', self.call('diff', scope='unpushed')['error'])

    # -- the gate ---------------------------------------------------------------------------------

    def test_any_repository_that_could_redirect_or_run_something_is_refused_before_use(self):
        self.ready()
        config = self.store / '.git/config'
        original = config.read_text()
        hook = self.root / 'ran'
        cases = {
            'remote': lambda: git(self.store, 'remote', 'add', 'origin', 'https://example.invalid/x.git'),
            'hooks': lambda: git(self.store, 'config', 'core.hooksPath', str(self.root)),
            'ssh': lambda: git(self.store, 'config', 'core.sshCommand', 'touch ' + str(hook)),
            'fsmonitor': lambda: git(self.store, 'config', 'core.fsmonitor', 'touch ' + str(hook)),
            'include': lambda: config.write_text(original + '[include]\n\tpath = /dev/null\n'),
            'filter': lambda: git(self.store, 'config', 'filter.x.clean', 'touch ' + str(hook)),
            'alias': lambda: git(self.store, 'config', 'alias.status', '!touch ' + str(hook)),
            'url': lambda: git(self.store, 'config', 'url.https://example.invalid/.insteadOf', 'x:'),
            'worktree': lambda: git(self.store, 'config', 'core.worktree', str(self.root / 'inputs')),
            'bare': lambda: git(self.store, 'config', 'core.bare', 'true'),
            'alternates': lambda: self.write(self.store / '.git/objects/info/alternates', str(self.root) + '\n'),
            'grafts': lambda: self.write(self.store / '.git/info/grafts', ''),
            'commondir': lambda: self.write(self.store / '.git/commondir', '../../elsewhere\n'),
            'gitmodules': lambda: self.write(self.store / '.gitmodules', ''),
            'group-writable': lambda: os.chmod(self.store / '.git', 0o775),
            'group-writable config': lambda: os.chmod(config, 0o664),
        }
        for name, change in cases.items():
            with self.subTest(case=name):
                change()
                for role in ('developer', 'reviewer'):
                    for op in ('list', 'status', 'merge-guide', 'read', 'test'):
                        self.assertEqual('STANDARD_MERGER_CONFIG', self.call(op, role=role, path='merger.rb')['error'])
                self.assertEqual('STANDARD_MERGER_CONFIG', self.call('init')['error'])
                self.assertEqual('STANDARD_MERGER_CONFIG', self.call('commit', message='x')['error'])
                config.write_text(original)
                os.chmod(config, 0o644)
                os.chmod(self.store / '.git', 0o755)
                for extra in ('.git/objects/info/alternates', '.git/info/grafts', '.git/commondir', '.gitmodules'):
                    (self.store / extra).unlink(missing_ok=True)
                self.assertNotIn('error', self.call('status'))
        self.assertFalse(hook.exists())
        self.assertEqual([self.ws], self.inits)

    def test_a_link_or_a_gitfile_in_place_of_the_repository_is_refused(self):
        elsewhere = Path(self.temp.name) / 'elsewhere'
        elsewhere.mkdir()
        git(elsewhere, 'init', '-q', '-b', 'main')
        self.write(elsewhere / 'merger.rb', MARKER)
        git(elsewhere, 'add', '-A')
        git(elsewhere, 'commit', '-q', '-m', 'Elsewhere')
        self.store.symlink_to(elsewhere)
        for op in ('list', 'status', 'merge-guide', 'init'):
            self.assertEqual('STANDARD_MERGER_CONFIG', self.call(op)['error'])
        self.store.unlink()
        self.store.mkdir()
        (self.store / '.git').write_text('gitdir: ' + str(elsewhere / '.git') + '\n')
        for op in ('list', 'status', 'merge-guide', 'init'):
            self.assertEqual('STANDARD_MERGER_CONFIG', self.call(op)['error'])
        (self.store / '.git').unlink()
        (self.store / '.git').symlink_to(elsewhere / '.git')
        self.assertEqual('STANDARD_MERGER_CONFIG', self.call('read', path='merger.rb')['error'])
        self.assertEqual([], self.inits)

    def test_inherited_git_settings_never_reach_the_repository(self):
        self.ready()
        elsewhere = Path(self.temp.name) / 'elsewhere'
        elsewhere.mkdir()
        git(elsewhere, 'init', '-q', '-b', 'main')
        hostile = {'GIT_DIR': str(elsewhere / '.git'), 'GIT_WORK_TREE': str(self.root / 'inputs'), 'GIT_CONFIG_COUNT': '1',
                   'GIT_CONFIG_KEY_0': 'core.hooksPath', 'GIT_CONFIG_VALUE_0': str(self.root), 'GIT_INDEX_FILE': str(elsewhere / 'index')}
        with mock.patch.dict(os.environ, hostile):
            status = self.call('status')
            self.assertEqual(git(self.store, 'rev-parse', 'HEAD'), status['head'])
            self.call('write', path='README.md', content='Invented\n')
            self.assertEqual(status['head'], git(self.store, 'rev-parse', self.call('commit', message='Notes')['commit'] + '~1'))
        self.assertEqual('', git(elsewhere, 'for-each-ref'))

    # -- roles --------------------------------------------------------------------------------------

    def test_roles_are_bounded_and_nothing_reaches_a_remote_or_another_branch(self):
        self.assertEqual({'list', 'read', 'search', 'status', 'diff', 'test', 'merge-guide'}, self.merger.ROLES['reviewer'])
        self.assertEqual(self.merger.ROLES['reviewer'] | {'write', 'edit', 'delete', 'format', 'commit', 'init'}, self.merger.ROLES['developer'])
        self.assertEqual({'developer', 'reviewer'}, set(self.merger.ROLES))
        self.ready()
        for op in ('write', 'edit', 'delete', 'format', 'commit', 'init'):
            self.assertEqual('STANDARD_DEV_OPERATION_REFUSED', self.call(op, role='reviewer', path='merger.rb', content='x', message='m')['error'])
        for op in ('push', 'push-propose', 'push-show', 'fetch', 'pull', 'branch', 'branches', 'branch-diff', 'branch-read', 'branch-resolve',
                   'rebase-main', 'clone', 'remote', 'deps', 'log', None, 7):
            for role in ('developer', 'reviewer'):
                self.assertEqual('STANDARD_DEV_OPERATION_REFUSED', self.call(op, role=role)['error'])
        for args in (['merger', 'dev', self.ws, '--role', 'reader'], ['merger', 'dev', self.ws, '--role', 'engineer'], ['merger', 'push', self.ws],
                     ['merger', 'dev', self.ws], ['merger', 'dev', self.ws, '--role', 'developer', '--path', '/tmp'], ['merger', 'init', self.ws],
                     ['converter', 'dev', self.ws, '--role', 'developer']):
            with self.assertRaises(ValueError) as refused:
                self.merger.main(args, {}, self.base, ROOT, self.host, io.StringIO('{"op":"status"}'))
            self.assertEqual('STANDARD_ARGUMENTS_INVALID', str(refused.exception))
        for workspace in ('../example-forum', 'example-forum/merger', '', '.', 'unknown-forum'):
            with self.assertRaises(ValueError):
                self.merger.main(['merger', 'dev', workspace, '--role', 'reviewer'], {}, self.base, ROOT, self.host, io.StringIO('{"op":"status"}'))

    # -- the sealed test and format container -----------------------------------------------------------

    @staticmethod
    def mounts(argv):
        found = {}
        for value in argv:
            if value.startswith('type=bind,'):
                fields = dict(part.partition('=')[::2] for part in value.split(','))
                found[fields['dst']] = (fields['src'], 'readonly' in value.split(','))
        return found

    def container(self, seen, output=b'2 runs, 3 assertions, 0 failures, 0 errors, 0 skips\n', rewrite=None):
        def fake_docker(argv, timeout):
            export = Path(self.mounts(argv)['/app'][0])
            seen.setdefault('runs', []).append(argv)
            seen['files'] = sorted(str(p.relative_to(export)) for p in export.rglob('*') if p.is_file())
            seen['text'] = ''.join(p.read_text(errors='replace') for p in export.rglob('*') if p.is_file())
            for name, content in (rewrite or {}).items():
                (export / name).write_text(content)
            return 0, output, b''
        return mock.patch.object(self.dev, 'docker', side_effect=fake_docker)

    def test_tests_run_sealed_on_the_image_gems_with_no_dependency_step_or_converter(self):
        self.ready(**{'test/merger_test.rb': 'require "minitest/autorun"\n', 'test/policy/deep_test.rb': '# deep\n'})
        self.write(self.store / 'test/customer_export.yml', MARKER)
        self.write(self.store / 'test/by_hand_test.rb', MARKER)
        self.assertFalse((self.root / 'converter').exists())
        seen = {}
        with self.container(seen), mock.patch.object(self.dev, 'converter_image_document', return_value=IMAGE_DOCUMENT), \
                mock.patch.object(self.dev, 'prepare_dependencies', side_effect=AssertionError('dependency step')), \
                mock.patch.object(self.dev, 'fetch_emoji', side_effect=AssertionError('network')):
            for role in ('developer', 'reviewer'):
                result = self.call('test', role=role)
                self.assertEqual((0, False, '2 runs, 3 assertions, 0 failures, 0 errors, 0 skips', 3),
                                 tuple(result[k] for k in ('exit_code', 'timed_out', 'summary', 'files_exported')), result)
            one = self.call('test', file='test/policy/deep_test.rb')
            self.assertEqual('test/policy/deep_test.rb', one['file'])
            # Only a visible test/..._test.rb is ever named to Ruby; each other value is refused before any container.
            refusals = {'merger.rb': 'STANDARD_ARGUMENTS_INVALID', 'test/customer_export.yml': 'STANDARD_ARGUMENTS_INVALID',
                        'test/missing_test.rb': 'STANDARD_ARGUMENTS_INVALID', 'test/by_hand_test.rb': 'STANDARD_ARGUMENTS_INVALID',
                        '-e': 'STANDARD_ARGUMENTS_INVALID', 'test/-x_test.rb;id': 'STANDARD_ARGUMENTS_INVALID',
                        '/etc/passwd': 'STANDARD_ARGUMENTS_INVALID', 'test/policy': 'STANDARD_ARGUMENTS_INVALID',
                        'test/../merger.rb': 'STANDARD_DEV_PATH_REFUSED', 'test/../../inputs/source_test.rb': 'STANDARD_DEV_PATH_REFUSED',
                        'test/.git/x_test.rb': 'STANDARD_DEV_PATH_REFUSED'}
            for file, refusal in refusals.items():
                self.assertEqual(refusal, self.call('test', file=file).get('error'), file)
            self.assertEqual('STANDARD_ARGUMENTS_INVALID', self.call('test', suite='lint')['error'])
        self.assertEqual(3, len(seen['runs']))  # one container per call, none to install anything
        argv = seen['runs'][0]
        self.assertEqual(['merger.rb', 'test/merger_test.rb', 'test/policy/deep_test.rb'], seen['files'])
        self.assertNotIn(MARKER, seen['text'])
        for flag in (['--network', 'none'], ['--pull=never'], ['--read-only'], ['--cap-drop', 'ALL'], ['--security-opt', 'no-new-privileges']):
            self.assertTrue(any(argv[i:i + len(flag)] == flag for i in range(len(argv))), flag)
        self.assertEqual(['/app'], list(self.mounts(argv)))  # no gems overlay, emoji table, site settings or lockfile
        environment = [argv[i + 1] for i, value in enumerate(argv) if value == '-e']
        self.assertIn('GEM_PATH=/opt/bundle/ruby/3.3.0:/usr/local/bundle', environment)
        self.assertIn('PATH=/opt/bundle/ruby/3.3.0/bin:/usr/local/bundle/bin:/usr/bin', environment)
        self.assertFalse([item for item in environment if item.startswith(('BUNDLE_', 'GEM_HOME='))])
        tail = argv[argv.index(IMAGE_ID) + 1:]
        self.assertEqual(['-u', 'BUNDLE_PATH', '-u', 'BUNDLE_GEMFILE', '-u', 'BUNDLE_APP_CONFIG', '-u', 'BUNDLE_FROZEN',
                          'ruby', '-I', 'test', '-e', self.merger.TEST_RUNNER], tail)
        self.assertEqual(['--', 'test/policy/deep_test.rb'], seen['runs'][2][-2:])
        self.assertNotIn('bundle', tail)

    def test_the_image_comes_from_the_workspace_profile_alone(self):
        self.ready(**{'test/merger_test.rb': 'require "minitest/autorun"\n'})
        profiles = Path(self.temp.name) / 'profiles'
        raw = json.dumps({'images': {'converter': {'ref': 'invented/converter:1', 'content_id': 'sha256:' + 'c' * 64}}}).encode()
        self.write(profiles / 'profile-a.json', raw.decode())
        self.state['config']['discourse_profile_sha256'] = hashlib.sha256(raw).hexdigest()
        self.save_state()
        self.values = {'SILO_RUNTIME_PROFILES_DIR': str(profiles)}
        inspected = []
        self.host = types.SimpleNamespace(inspect=lambda ref: inspected.append(ref) or IMAGE_DOCUMENT, identity=lambda document: 'sha256:' + 'c' * 64)
        seen = {}
        with self.container(seen):
            self.assertEqual(0, self.call('test')['exit_code'])
            self.host.identity = lambda document: 'sha256:' + 'd' * 64
            self.assertEqual('STANDARD_RUNTIME_MISMATCH', self.call('test')['error'])
        self.assertEqual(['invented/converter:1'] * 2, inspected)
        self.assertEqual(IMAGE_ID, seen['runs'][0][seen['runs'][0].index('-u') - 1])
        self.assertEqual(1, len(seen['runs']))

    def test_format_rewrites_only_visible_layout_files_through_the_recorded_path(self):
        self.ready(**{'helpers/a.rb': 'x=1\n'})
        self.write(self.store / 'helpers/by_hand.rb', '# ' + MARKER + '\n')
        seen = {}
        with self.container(seen, rewrite={'helpers/a.rb': 'x = 1\n', 'helpers/by_hand.rb': 'changed\n', 'merger.rb': ENTRY}), \
                mock.patch.object(self.dev, 'converter_image_document', return_value=IMAGE_DOCUMENT):
            self.assertEqual('STANDARD_DEV_OPERATION_REFUSED', self.call('format', role='reviewer')['error'])
            result = self.call('format', path='helpers')
        self.assertEqual((['helpers/a.rb'], 0), (result['formatted'], result['unchanged']), result)
        argv = seen['runs'][0]
        self.assertEqual(['stree', 'write', '--print-width=100', 'helpers/a.rb'], argv[argv.index('BUNDLE_FROZEN') + 1:])
        self.assertEqual(['/app'], list(self.mounts(argv)))
        self.assertEqual('x = 1\n', (self.store / 'helpers/a.rb').read_text())
        self.assertIn(MARKER, (self.store / 'helpers/by_hand.rb').read_text())
        self.assertEqual('x = 1\n', self.call('read', path='helpers/a.rb')['text'])
        self.assertEqual(['helpers/a.rb'], self.call('commit', message='Format')['files'])

    def test_format_refuses_plainly_when_the_image_has_no_formatter_and_reports_a_syntax_error_as_one(self):
        self.ready(**{'helpers/a.rb': 'x=1\n'})
        self.call('write', path='helpers/a.rb', content='x  =  1\n')
        for code, stderr in ((127, b"env: 'stree': No such file or directory\n"), (126, b"env: 'stree': Permission denied\n")):
            def absent(argv, timeout, code=code, stderr=stderr):
                (Path(self.mounts(argv)['/app'][0]) / 'helpers/a.rb').write_text('never written back\n')
                return code, b'', stderr
            with mock.patch.object(self.dev, 'docker', side_effect=absent), \
                    mock.patch.object(self.dev, 'converter_image_document', return_value=IMAGE_DOCUMENT):
                refused = self.call('format', path='helpers')
            self.assertTrue(refused['error'].startswith('STANDARD_MERGER_FORMATTER_UNAVAILABLE:'), refused)
            self.assertNotIn('formatted', refused)
        # The formatter ran and rejected the file: a result that says so, never a success.
        with mock.patch.object(self.dev, 'docker', return_value=(1, b'', b'helpers/a.rb: syntax error\n')), \
                mock.patch.object(self.dev, 'converter_image_document', return_value=IMAGE_DOCUMENT):
            failed = self.call('format', path='helpers')
        self.assertEqual(([], 1, False), (failed['formatted'], failed['exit_code'], failed['timed_out']))
        self.assertIn('syntax error', failed['error_tail'])
        self.assertIn('Nothing was changed', failed['note'])
        self.assertEqual('x  =  1\n', (self.store / 'helpers/a.rb').read_text())

    # -- the guide ------------------------------------------------------------------------------------

    def prepared(self, run='a', runtime=None, **environment):
        run_id, plan_id = 'run-' + run * 32, 'plan-' + run * 32
        body = {'operation': 'standard_merge_prepare', 'app_revision': '9' * 40, 'roles': {'base_site': 'private-base-' + MARKER},
                'review_runtime': {'actual_version': '2026.7.5', 'app_revision': 'c' * 40, 'image_ref': 'private/' + MARKER} if runtime is None else runtime}
        self.state['plans'][plan_id] = {'status': 'completed', 'created_at': '2026-11-12T00:00:00Z', 'body': body}
        self.state['runs'][run_id] = {'plan_id': plan_id, 'status': 'completed', 'merge_environment': dict(
            {'phase': 'ready', 'consumed_by': None, 'preparation_run_id': run_id, 'generation': 'e' * 64}, **environment)}
        self.save_state()
        return run_id

    def test_guide_gives_the_actual_path_committed_identity_and_the_ready_prepare_revision(self):
        commit = self.ready()
        # An older merge plan and the workspace profile both name other revisions: neither may win.
        profiles = Path(self.temp.name) / 'profiles'
        raw = json.dumps({'images': {}, 'app': {'revision': 'a' * 40, 'version': '2026.11.0-latest'}}).encode()
        self.write(profiles / 'profile-a.json', raw.decode())
        self.state['config']['discourse_profile_sha256'] = hashlib.sha256(raw).hexdigest()
        self.state['plans']['plan-' + 'b' * 32] = {'status': 'proposed', 'created_at': '2026-11-13T00:00:00Z', 'body': {
            'operation': 'standard_merge', 'review_runtime': {'actual_version': '2026.6.1', 'app_revision': 'd' * 40}}}
        self.values = {'SILO_RUNTIME_PROFILES_DIR': str(profiles)}
        run_id = self.prepared()
        self.call('write', path='README.md', content='Invented\n')
        for role in ('developer', 'reviewer'):
            guide = self.call('merge-guide', role=role)
            self.assertTrue(guide['merge_project'])
            self.assertEqual((str(self.store), True, 'main', commit['commit'], True, commit['layer'], None, 'merger.rb', ['README.md']),
                             tuple(guide['merger'][k] for k in ('path', 'initialized', 'branch', 'head', 'dirty', 'layer', 'layer_error',
                                                                 'entry', 'uncommitted_changes')))
            self.assertTrue(guide['discourse_basis'].startswith('ready_merge_preparation;'))
            self.assertEqual({'run_id': run_id, 'generation': 'e' * 64}, guide['discourse_basis_preparation'])
            self.assertEqual({'version': '2026.7.5', 'revision': 'c' * 40,
                              'merger_source': 'https://raw.githubusercontent.com/discourse/discourse/' + 'c' * 40 + '/script/bulk_import/discourse_merger.rb',
                              'base_source': 'https://raw.githubusercontent.com/discourse/discourse/' + 'c' * 40 + '/script/bulk_import/base.rb'},
                             guide['discourse'])
            for text in (str(self.store), 'merger.rb', 'helpers/', 'dev_merger_test', 'silo_merge_preflight!', 'no remote'):
                self.assertIn(text, guide['guide'])
            for text in ('{', 'mergers/', 'converter sandbox', 'as for converter code'):
                self.assertNotIn(text, guide['guide'])
            # Only these facts are returned: nothing else from the Prepare's plan (its inputs, image or roles).
            self.assertEqual({'version', 'merge_project', 'merger', 'recent_runs', 'guide', 'discourse_basis',
                              'discourse_basis_preparation', 'discourse'}, set(guide))
            returned = json.dumps(guide)
            for leak in ('private-base', 'private/', 'image_ref', 'base_site', '9' * 40, 'd' * 40, 'a' * 40, '2026.6.1', '2026.11.0'):
                self.assertNotIn(leak, returned)

    def test_guide_never_falls_back_when_a_ready_prepare_cannot_be_read(self):
        self.ready()
        self.state['plans']['plan-' + 'b' * 32] = {'status': 'proposed', 'created_at': '2026-11-13T00:00:00Z', 'body': {
            'operation': 'standard_merge', 'review_runtime': {'actual_version': '2026.6.1', 'app_revision': 'd' * 40}}}
        self.save_state()
        self.assertTrue(self.call('merge-guide')['discourse_basis'].startswith('latest_merge_plan'))
        run_id = self.prepared(runtime={'actual_version': 'not a version', 'app_revision': 'main'})
        self.state['plans']['plan-' + 'a' * 32]['body']['app_revision'] = 'main'
        self.save_state()
        guide = self.call('merge-guide')
        self.assertTrue(guide['discourse_basis'].startswith('ready_merge_preparation_unreadable'))
        self.assertEqual({'run_id': run_id}, guide['discourse_basis_preparation'])
        self.assertNotIn('discourse', guide)
        self.prepared(run='a')
        self.prepared(run='f')
        guide = self.call('merge-guide')
        self.assertTrue(guide['discourse_basis'].startswith('ready_merge_preparation_ambiguous'))
        self.assertNotIn('discourse', guide)
        # Consumed, unfinished or foreign records are not a ready Prepare.
        del self.state['runs']['run-' + 'f' * 32]
        for change in ({'phase': 'consumed', 'consumed_by': 'run-' + '2' * 32}, {'phase': 'inspection'}, {'preparation_run_id': 'run-' + '3' * 32}):
            self.prepared(run='a', **change)
            self.assertTrue(self.call('merge-guide')['discourse_basis'].startswith('latest_merge_plan'), change)

    def test_contract_text_keeps_one_source(self):
        contract = self.merger.contract
        text = contract.STANDALONE_MERGE_GUIDE.format(path='/invented/merger', files=contract.MERGE_LAYER_MAX_FILES, kib=contract.MERGE_LAYER_MAX_BYTES // 1024)
        legacy = contract.MERGE_GUIDE.format(path='mergers/x/merger.rb', tests='test/mergers/x', files=32, kib=512)
        self.assertIn('at most 32 files, 512 KiB together', text)
        # Everything that is not about where the layer lives is the same contract, word for word.
        shared = [line for line in legacy.splitlines() if line in text.splitlines()]
        self.assertGreater(len(shared), 40)
        with self.assertRaises(ValueError):
            contract._swap(text, 'a passage that is not there', 'x')

    # -- control dispatch -------------------------------------------------------------------------------

    def test_control_routes_merger_dev_to_these_tools_and_init_to_the_service_action(self):
        loader = importlib.machinery.SourceFileLoader('merger_control_fixture', str(ROOT / 'bin/silo-migrate-control'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        control = importlib.util.module_from_spec(spec)
        sys.modules[loader.name] = control  # as when it runs as a program: it passes itself on as the host
        self.addCleanup(sys.modules.pop, loader.name, None)
        loader.exec_module(control)
        self.assertEqual(self.merger.ROLES, control.merger_dev().ROLES)
        args = ['merger', 'dev', self.ws, '--role', 'developer']
        with mock.patch.object(control, 'settings', return_value=({'SILO_MIGRATE_BASE_PATH': str(self.base)}, False)), \
                mock.patch.object(control, 'host_merger', return_value=0) as routed, \
                mock.patch.object(control.os, 'execvp', side_effect=AssertionError('control container')):
            self.assertEqual(0, control.main(args))
        self.assertEqual((args, self.base), (routed.call_args.args[0], routed.call_args.args[2]))
        captured, written = [], io.BytesIO()

        def capture(argv, extra_env=None, passthrough=False):
            captured.append((argv, passthrough))
            self.service_init(argv[-1])
            return ''
        with mock.patch.object(control, 'capture', side_effect=capture), mock.patch.object(control.sys, 'stdin', io.StringIO('{"op":"init"}')), \
                mock.patch.object(control.sys, 'stdout', types.SimpleNamespace(buffer=written)), \
                mock.patch.object(control.os.path, 'expanduser', return_value=str(self.home)):
            self.assertEqual(0, control.host_merger(args, {}, self.base, Path('/invented/silo-migrate-control')))
        self.assertEqual([(['/invented/silo-migrate-control', 'standard', 'merger', 'init', self.ws], True)], captured)
        result = json.loads(written.getvalue())
        self.assertEqual((1, True, str(self.store), 'main'), tuple(result[k] for k in ('version', 'created', 'path', 'branch')))


if __name__ == '__main__':
    unittest.main()
