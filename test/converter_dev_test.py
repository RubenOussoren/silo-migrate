"""Converter development boundary tests with real Git. Run: python3 -I -B test/converter_dev_test.py."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
MARKER = 'CUSTOMER-CANARY-7d1f0a'
LOCKFILE = ('GEM\n  remote: https://rubygems.org/\n  specs:\n    markbridge (0.5.0)\n\nPLATFORMS\n  ruby\n  x86_64-linux\n\n'
            'DEPENDENCIES\n  markbridge (~> 0.5.0)\n\nBUNDLED WITH\n   2.6.3\n')
IMAGE_ID = 'sha256:' + 'b' * 64
IMAGE_DOCUMENT = {'Id': IMAGE_ID, 'Config': {'Env': ['PATH=/usr/local/bundle/bin:/usr/bin', 'RUBY_VERSION=3.3.13', 'GEM_HOME=/usr/local/bundle',
                                                     'BUNDLE_PATH=/opt/bundle', 'BUNDLE_FROZEN=true']}}


def load_dev():
    spec = importlib.util.spec_from_file_location('converter_dev', ROOT / 'bin/converter_dev.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(cwd, *args, env=None):
    full = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid', **(env or {}))
    return subprocess.run(['git', '-C', str(cwd), *args], check=True, capture_output=True, text=True, env=full).stdout.strip()


class ConverterDevTest(unittest.TestCase):
    def setUp(self):
        old = os.umask(0o022)  # the account's umask; the Git gate refuses group-writable .git
        self.addCleanup(os.umask, old)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.dev = load_dev()
        self.host = types.SimpleNamespace(**runpy.run_path(str(ROOT / 'bin/silo-migrate-control')))
        self.base = base / 'workspaces'
        self.home = base / 'home'
        self.ws = 'example-forum'
        self.root = self.base / self.ws
        standard = self.root / '.silo-migrate/named/standard'
        standard.mkdir(parents=True)
        (self.root / '.silo-migrate/named/state.json').write_text('{}')
        (standard / 'op.lock').write_text('')
        self.origin = base / 'origin.git'
        seed = base / 'seed'
        seed.mkdir()
        git(seed, 'init', '-q', '-b', 'main')
        self.write(seed / 'README.md', 'Converter\n')
        self.write(seed / 'lib/importer.rb', 'def import_user(row)\n  row[:login].downcase\nend\n')
        self.write(seed / 'test/importer_test.rb', 'require "minitest/autorun"\n')
        self.write(seed / '.gitignore', 'log/\n*.sqlite\ntmp/\n')
        self.write(seed / '.github/workflows/ci.yml', 'name: CI\n')
        self.write(seed / 'Gemfile', 'source "https://rubygems.org"\ngem "markbridge", "~> 0.5.0"\n')
        self.write(seed / 'Gemfile.lock', LOCKFILE)
        git(seed, 'add', '-A')
        git(seed, 'commit', '-q', '-m', 'Seed')
        git(base, 'clone', '-q', '--bare', str(seed), str(self.origin))
        self.checkout = self.root / 'converter'
        git(self.root, 'clone', '-q', str(self.origin), str(self.checkout))
        self.site_settings = self.write(base / 'site-cache/site_settings.yml', 'basic:\n  title: Synthetic\n')
        self.state = {'config': {'converter_worktree': str(self.checkout), 'discourse_profile': 'profile-a', 'discourse_profile_sha256': '',
                                 'site_settings': str(self.site_settings), 'site_settings_sha256': hashlib.sha256(self.site_settings.read_bytes()).hexdigest()}, 'runs': {}}
        (standard / 'state.json').write_text(json.dumps(self.state))
        # Customer-like material everywhere an agent must not reach.
        self.write(self.checkout / 'log/convert.log', MARKER + ' alice@example.test\n')
        self.write(self.checkout / 'customer.sqlite', MARKER)
        # Not covered by the converter's .gitignore (as the real repository doesn't cover log/).
        self.write(self.checkout / 'exports/customer-users.csv', MARKER + ',alice@example.test\n')
        self.write(self.root / 'inputs/source.sql', MARKER)
        self.write(standard / 'runs/run-1/logs/convert.log', MARKER)
        (self.checkout / 'inputs-link').symlink_to(self.root / 'inputs/source.sql')
        (self.checkout / 'lib/linked-dir').symlink_to(self.root / 'inputs')
        self.outputs = []

    def test_parallel_writes_all_stay_visible(self):
        # Seen on arc: the model sent six dev_write calls at once; unlocked manifest updates lost
        # entries (files became invisible) and a shared temporary name failed two writes.
        from concurrent.futures import ThreadPoolExecutor
        import random
        real_record = self.dev.Checkout.record_write

        def slow_record(checkout, relative, data):  # widen the race the way real Git calls do
            time.sleep(random.random() * 0.05)
            return real_record(checkout, relative, data)
        names = ['lib/parallel_%02d.rb' % n for n in range(12)]
        with mock.patch.object(self.dev.Checkout, 'record_write', slow_record):
            with ThreadPoolExecutor(max_workers=12) as pool:
                results = list(pool.map(lambda name: self.call('write', path=name, content='# %s\n' % name), names))
        self.assertEqual([], [r for r in results if 'error' in r])
        listed = self.call('status')
        visible = json.dumps(listed)
        for name in names:
            self.assertIn(name, visible)
        self.assertIn('# lib/parallel_03.rb', self.call('read', path='lib/parallel_03.rb')['text'])
        self.assertEqual([], [p.name for p in (self.root / '.silo-migrate/named/standard').iterdir() if p.name.startswith('.converter-dev-files')])

    def test_a_write_whose_record_fails_leaves_no_invisible_file(self):
        with mock.patch.object(self.dev.Checkout, 'record_write', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.dev.main(['converter', 'dev', self.ws, '--role', 'developer'], {}, self.base, ROOT, self.host,
                              io.StringIO(json.dumps({'op': 'write', 'path': 'lib/orphan.rb', 'content': 'x\n'})), home=str(self.home))
        self.assertFalse((self.checkout / 'lib/orphan.rb').exists())
        # Overwriting or editing a visible file: the old, still-vouched bytes come back.
        before = (self.checkout / 'lib/importer.rb').read_text()
        for request in ({'op': 'write', 'path': 'lib/importer.rb', 'content': 'replaced\n'},
                        {'op': 'edit', 'path': 'lib/importer.rb', 'old_text': 'downcase', 'new_text': 'upcase'}):
            with self.subTest(op=request['op']), mock.patch.object(self.dev.Checkout, 'record_write', side_effect=OSError('disk full')):
                with self.assertRaises(OSError):
                    self.dev.main(['converter', 'dev', self.ws, '--role', 'developer'], {}, self.base, ROOT, self.host,
                                  io.StringIO(json.dumps(request)), home=str(self.home))
            self.assertEqual(before, (self.checkout / 'lib/importer.rb').read_text())
            self.assertIn('downcase', self.call('read', path='lib/importer.rb')['text'])

    def test_branch_works_in_a_workspace_that_never_ran_anything(self):
        # migration-data creates workspaces fresh: no op.lock until something takes it.
        lock = self.root / '.silo-migrate/named/standard/op.lock'
        lock.unlink()
        result = self.call('branch', topic='fresh-workspace')
        self.assertEqual('migration/example-forum/fresh-workspace', result.get('branch'), result)
        self.assertTrue(lock.is_file())
        self.assertEqual(0o600, lock.stat().st_mode & 0o777)
        lock.unlink()
        lock.symlink_to(self.root / 'inputs/source.sql')  # never followed
        self.assertIn('error', self.call('branch', topic='through-a-link'))
        self.assertEqual(MARKER, (self.root / 'inputs/source.sql').read_text())

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def call(self, op, role='developer', **request):
        stdin = io.StringIO(json.dumps(dict(op=op, **request)))
        try:
            result = self.dev.main(['converter', 'dev', self.ws, '--role', role], {}, self.base, ROOT, self.host, stdin, home=str(self.home))
        except ValueError as refusal:  # converter_dev.Refusal and the wrapper's own refusals
            result = {'error': str(refusal)}
        self.outputs.append(json.dumps(result))
        return result

    def tearDown(self):
        for output in self.outputs:
            self.assertNotIn(MARKER, output)

    def set_identity(self):
        git(self.checkout, 'config', 'user.name', 'Ruben Oussoren')
        git(self.checkout, 'config', 'user.email', '24749583+RubenOussoren@users.noreply.github.com')

    # -- reading ---------------------------------------------------------------

    def test_listing_and_reading_show_only_git_visible_files(self):
        names = {entry['name'] for entry in self.call('list')['entries']}
        self.assertEqual({'.github', 'lib', 'test', '.gitignore', 'README.md', 'Gemfile', 'Gemfile.lock'}, names)
        self.assertEqual(['importer.rb'], [entry['name'] for entry in self.call('list', path='lib')['entries']])
        self.assertIn('downcase', self.call('read', path='lib/importer.rb')['text'])
        for path in ('log/convert.log', 'customer.sqlite', 'exports/customer-users.csv', 'exports', 'inputs-link', 'lib/linked-dir/source.sql', '../inputs/source.sql',
                     '/etc/passwd', '.git/config', 'log', 'tmp/x'):
            with self.subTest(path=path):
                self.assertIn(self.call('read', path=path)['error'],
                              ('STANDARD_DEV_PATH_NOT_VISIBLE', 'STANDARD_DEV_PATH_REFUSED', 'STANDARD_ARGUMENTS_INVALID'))
        self.assertEqual('STANDARD_DEV_PATH_NOT_VISIBLE', self.call('list', path='log')['error'])

    def test_search_never_reaches_ignored_or_linked_files(self):
        self.assertEqual([], self.call('search', pattern=MARKER)['matches'])
        self.assertEqual([], self.call('search', pattern='alice@', path='exports')['matches'])
        self.assertEqual('STANDARD_ARGUMENTS_INVALID', self.call('search', pattern='(', fixed=False)['error'])
        found = self.call('search', pattern='downcase')['matches']
        self.assertEqual([{'path': 'lib/importer.rb', 'line': 2, 'text': '  row[:login].downcase'}], found)
        self.assertEqual(['lib/importer.rb'], [m['path'] for m in self.call('search', pattern='down.ase', fixed=False, path='lib')['matches']])

    def test_untracked_visible_work_is_readable_and_in_status_and_diff(self):
        self.call('write', path='lib/new_helper.rb', content='# helper\n')
        self.assertIn('# helper', self.call('read', path='lib/new_helper.rb')['text'])
        self.assertIn('# helper', ''.join(m['text'] for m in self.call('search', pattern='helper')['matches']))
        status = self.call('status')
        self.assertEqual([{'status': '??', 'path': 'lib/new_helper.rb'}], status['changes'])
        self.assertEqual(3, status['other_changes_not_shown'])  # exports/, inputs-link, lib/linked-dir: counted, never named
        self.assertIn('+# helper', self.call('diff')['diff'])

    # -- writing ---------------------------------------------------------------

    def test_edit_write_delete_and_their_refusals(self):
        edited = self.call('edit', path='lib/importer.rb', old_text='row[:login].downcase', new_text='(row[:login] || "deleted-user-#{row[:id]}").downcase')
        self.assertEqual(1, edited['replacements'])
        self.assertIn('deleted-user', (self.checkout / 'lib/importer.rb').read_text())
        self.assertEqual('STANDARD_DEV_EDIT_NOT_FOUND', self.call('edit', path='lib/importer.rb', old_text='nope', new_text='x')['error'])
        self.write(self.checkout / 'lib/direct.rb', 'a\n')  # not created through the tools: invisible
        self.assertEqual('STANDARD_DEV_PATH_NOT_VISIBLE', self.call('edit', path='lib/direct.rb', old_text='a', new_text='b')['error'])
        self.call('write', path='lib/twice.rb', content='a\na\n')
        self.assertEqual('STANDARD_DEV_EDIT_AMBIGUOUS', self.call('edit', path='lib/twice.rb', old_text='a', new_text='b')['error'])
        refused = {'.gitignore': 'STANDARD_DEV_PATH_PROTECTED', 'lib/.gitignore': 'STANDARD_DEV_PATH_PROTECTED', '.gitattributes': 'STANDARD_DEV_PATH_PROTECTED',
                   '.gitmodules': 'STANDARD_DEV_PATH_PROTECTED', '.git/config': 'STANDARD_DEV_PATH_REFUSED', '.github/workflows/ci.yml': 'STANDARD_DEV_PATH_PROTECTED',
                   'log/new.rb': 'STANDARD_DEV_PATH_IGNORED', 'export.sqlite': 'STANDARD_DEV_PATH_IGNORED', 'inputs-link': 'STANDARD_DEV_PATH_REFUSED',
                   'lib/linked-dir/x.rb': 'STANDARD_DEV_PATH_REFUSED', '../inputs/x.rb': 'STANDARD_DEV_PATH_REFUSED',
                   'Gemfile': 'STANDARD_DEV_PATH_PROTECTED', 'Gemfile.lock': 'STANDARD_DEV_PATH_PROTECTED', '.bundle/config': 'STANDARD_DEV_PATH_PROTECTED'}
        for path, code in refused.items():
            with self.subTest(path=path):
                self.assertEqual(code, self.call('write', path=path, content='x\n')['error'])
        self.assertFalse((self.root / 'inputs/x.rb').exists())
        self.assertEqual('STANDARD_ARGUMENTS_INVALID', self.call('write', path='lib/big.rb', content='x' * (512 * 1024 + 1))['error'])
        self.assertTrue(self.call('delete', path='lib/twice.rb')['deleted'])
        self.assertEqual('STANDARD_DEV_PATH_NOT_VISIBLE', self.call('delete', path='log/convert.log')['error'])
        self.assertTrue((self.checkout / 'log/convert.log').exists())

    def test_reviewer_cannot_change_anything(self):
        for op, extra in (('write', {'path': 'x.rb', 'content': 'x'}), ('edit', {'path': 'README.md', 'old_text': 'C', 'new_text': 'D'}),
                          ('delete', {'path': 'README.md'}), ('branch', {'topic': 'x'}), ('commit', {'message': 'x'}),
                          ('push-propose', {'title': 'x'}), ('push', {}), ('nonsense', {})):
            with self.subTest(op=op):
                self.assertEqual('STANDARD_DEV_OPERATION_REFUSED', self.call(op, role='reviewer', **extra)['error'])
        self.assertIn('Converter', self.call('read', role='reviewer', path='README.md')['text'])

    # -- branch, commit, push ----------------------------------------------------

    def commit_fix(self):
        self.set_identity()
        self.assertEqual('migration/example-forum/null-login-users', self.call('branch', topic='null-login-users')['branch'])
        self.call('edit', path='lib/importer.rb', old_text='row[:login].downcase', new_text='row[:login].to_s.downcase')
        return self.call('commit', message='Handle Khoros users without a login\n\n## Why\nDeleted accounts have no login.\n')

    def test_converter_log_shows_branch_commits_and_what_reached_github(self):
        log = lambda: self.dev.main(['converter', 'log', self.ws], {}, self.base, ROOT, self.host, io.StringIO(''))
        before = log()
        self.assertEqual('main', before['branch'])
        self.assertEqual([True], [c['pushed'] for c in before['commits']])
        self.assertEqual((0, 0, []), (before['not_pushed'], before['ahead_of_main'], before['branches']))
        self.commit_fix()
        after = log()
        self.assertEqual('migration/example-forum/null-login-users', after['branch'])
        self.assertEqual([False, True], [c['pushed'] for c in after['commits']])
        self.assertEqual('Handle Khoros users without a login', after['commits'][0]['subject'])
        # The fixture leaves three untracked customer-like files in the checkout: counted, never named.
        self.assertEqual((1, 1, 3), (after['not_pushed'], after['ahead_of_main'], after['uncommitted']))
        self.assertEqual([('migration/example-forum/null-login-users', 1, False)], [(b['name'], b['not_pushed'], b['on_github']) for b in after['branches']])
        self.call('write', path='lib/work_in_progress.rb', content='# wip\n')
        self.assertEqual(4, log()['uncommitted'])
        self.assertNotIn('customer-users', json.dumps(log()))
        # Nothing an agent wrote outside the visible files shows up as text: only counts.
        self.assertNotIn(MARKER, json.dumps(log()))
        git(self.checkout, 'config', 'core.pager', 'sh -c id')
        with self.assertRaisesRegex(ValueError, 'STANDARD_CONVERTER_CONFIG'):
            log()

    def test_commit_as_engineer_with_trailer_never_stages_ignored_files(self):
        self.assertEqual('STANDARD_DEV_NOT_MIGRATION_BRANCH', self.call('commit', message='x')['error'])
        self.call('branch', topic='fix')
        self.call('write', path='lib/x.rb', content='x\n')
        self.assertEqual('STANDARD_DEV_IDENTITY_MISSING', self.call('commit', message='x')['error'])
        self.call('branch', topic='null-login-users')
        git(self.checkout, 'add', '-f', 'exports/customer-users.csv')  # an engineer staged a data file by hand
        result = self.commit_fix()
        self.assertEqual('Ruben Oussoren <24749583+RubenOussoren@users.noreply.github.com>', result['author'])
        message = git(self.checkout, 'log', '-1', '--format=%B')
        self.assertIn('## Why', message)
        self.assertTrue(message.rstrip().endswith('Assisted-by: converter-developer (term-llm agent)'))
        committed = git(self.checkout, 'show', '--name-only', '--format=', 'HEAD').split()
        self.assertEqual(['lib/importer.rb', 'lib/x.rb'], sorted(committed))
        tracked = git(self.checkout, 'ls-files')
        self.assertNotIn('log/convert.log', tracked)
        self.assertNotIn('customer.sqlite', tracked)
        self.assertNotIn('inputs-link', tracked.split())  # symlink to inputs is outside the checkout
        self.assertNotIn('exports/customer-users.csv', git(self.checkout, 'ls-tree', '-r', '--name-only', 'HEAD'))
        self.assertEqual({}, json.loads((self.root / '.silo-migrate/named/standard/converter-dev-files.json').read_text())['files'])
        self.assertEqual('STANDARD_DEV_NOTHING_TO_COMMIT', self.call('commit', message='again')['error'])

    def test_commit_identity_from_node_file(self):
        self.write(self.home / '.config/silo-migrate/git-identity', 'name=Ruben Oussoren\nemail=ruben@example.invalid\n')
        self.call('branch', topic='fix')
        self.call('write', path='lib/x.rb', content='x\n')
        self.assertEqual('Ruben Oussoren <ruben@example.invalid>', self.call('commit', message='Add x')['author'])

    def test_branch_and_commit_refuse_while_a_run_is_active(self):
        self.state['runs'] = {'run-1': {'status': 'running'}}
        (self.root / '.silo-migrate/named/standard/state.json').write_text(json.dumps(self.state))
        self.assertEqual('STANDARD_BUSY', self.call('branch', topic='fix')['error'])
        for topic in ('Bad', '-x', 'a..b', 'x.lock', 'a/b', ''):
            with self.subTest(topic=topic):
                self.assertEqual('STANDARD_ARGUMENTS_INVALID', self.call('branch', topic=topic)['error'])

    def github(self, record):
        target = {'url': str(self.origin), 'owner': 'discourse-org', 'repo': 'discourse-converters'}

        def api(method, path, token, payload=None):
            record.append((method, path, token, payload))
            return 201, {'number': 7, 'html_url': 'https://github.com/discourse-org/discourse-converters/pull/7', 'draft': True}
        return mock.patch.object(self.dev, 'github_target', return_value=target), mock.patch.object(self.dev, 'github_api', side_effect=api)

    def token(self, mode=0o600):
        path = self.write(self.home / '.config/silo-migrate/github/token-discourse-org', 'github_pat_' + 'A' * 40)
        path.chmod(mode)

    def test_push_waits_for_the_exact_digest_and_opens_a_draft_pr(self):
        self.commit_fix()
        calls = []
        target, api = self.github(calls)
        with target, api:
            proposed = self.call('push-propose', title='Handle Khoros users without a login', body='Fixes the released finding.')
            digest = proposed['digest']
            self.assertEqual('silo-migrate-control converter push example-forum --sha256 ' + digest, proposed['approve'])
            self.assertEqual(1, len(proposed['proposal']['commits']))
            self.assertIn('lib/importer.rb', proposed['proposal']['stat'])
            self.assertEqual('STANDARD_DEV_OPERATION_REFUSED', self.call('push', sha256=digest)['error'])
            self.assertEqual('', git(self.origin, 'branch', '--list', 'migration/*'))  # nothing pushed by the agent
            push = lambda d: self.dev.main(['converter', 'push', self.ws, '--sha256', d], {}, self.base, ROOT, self.host, io.StringIO(''), home=str(self.home))
            with self.assertRaisesRegex(self.dev.Refusal, 'STANDARD_PUSH_UNKNOWN'):
                push('0' * 64)
            with self.assertRaisesRegex(self.dev.Refusal, 'STANDARD_PUSH_TOKEN_MISSING'):
                push(digest)
            self.token(0o644)
            with self.assertRaisesRegex(self.dev.Refusal, 'STANDARD_PUSH_TOKEN_UNSAFE'):
                push(digest)
            self.token()
            result = push(digest)
            self.assertEqual('pushed', result['status'])
            self.assertEqual(7, result['pull_request']['number'])
            self.assertEqual(git(self.checkout, 'rev-parse', 'HEAD'), git(self.origin, 'rev-parse', 'refs/heads/migration/example-forum/null-login-users'))
            self.assertEqual(1, len(calls))
            method, path, token, payload = calls[0]
            self.assertEqual(('POST', '/repos/discourse-org/discourse-converters/pulls'), (method, path))
            self.assertTrue(payload['draft'])
            self.assertEqual(('main', 'migration/example-forum/null-login-users'), (payload['base'], payload['head']))
            self.assertIn(digest, payload['body'])
            self.assertEqual([], self.call('status')['unpushed_commits'])
            self.assertEqual(result, push(digest))  # idempotent: no second push or PR
            self.assertEqual(1, len(calls))
            shown = self.dev.main(['converter', 'push-show', self.ws], {}, self.base, ROOT, self.host, io.StringIO(''), home=str(self.home))
            self.assertEqual('pushed', shown['proposals'][0]['status'])

    def test_push_refuses_a_stale_proposal(self):
        self.commit_fix()
        self.token()
        calls = []
        target, api = self.github(calls)
        with target, api:
            digest = self.call('push-propose', title='Fix')['digest']
            self.call('write', path='lib/later.rb', content='x\n')
            self.call('commit', message='Later change')
            with self.assertRaisesRegex(self.dev.Refusal, 'STANDARD_PUSH_STALE'):
                self.dev.main(['converter', 'push', self.ws, '--sha256', digest], {}, self.base, ROOT, self.host, io.StringIO(''), home=str(self.home))
            self.assertEqual('', git(self.origin, 'branch', '--list', 'migration/*'))
            self.call('write', path='lib/dirty.rb', content='x\n')
            self.assertEqual('STANDARD_CONVERTER_DIRTY', self.call('push-propose', title='Fix')['error'])
        self.assertEqual([], calls)

    def test_push_requires_a_github_origin(self):
        self.commit_fix()
        self.assertEqual('STANDARD_PUSH_REMOTE', self.call('push-propose', title='Fix')['error'])
        self.assertEqual({'url': 'https://github.com/discourse-org/discourse-converters.git', 'owner': 'discourse-org', 'repo': 'discourse-converters'},
                         self.dev.github_target(types.SimpleNamespace(out=lambda *a: 'https://github.com/discourse-org/discourse-converters.git\n')))
        for url in ('https://user:pw@github.com/o/r.git', 'https://github.com.evil/o/r', 'git@github.com:o/r.git', 'https://github.com/o'):
            with self.subTest(url=url), self.assertRaisesRegex(self.dev.Refusal, 'STANDARD_PUSH_REMOTE'):
                self.dev.github_target(types.SimpleNamespace(out=lambda *a, u=url: u + '\n'))

    def test_credential_helper_keeps_the_token_out_of_argv(self):
        self.token()
        path, token = self.dev.token_for('Discourse-Org', str(self.home))
        options, env = self.dev.credential_config(path)
        self.assertNotIn(token, ' '.join(options))
        helper = options[-1].split('=', 1)[1][1:]
        ask = lambda request: subprocess.run(['sh', '-c', helper + ' get'], input=request, capture_output=True, text=True, env=dict(os.environ, **env)).stdout
        self.assertEqual('username=x-access-token\npassword=' + token + '\n', ask('protocol=https\nhost=github.com\npath=discourse-org/x.git\n\n'))
        for request in ('protocol=https\nhost=evil.example\n\n', 'protocol=http\nhost=github.com\n\n', 'host=github.com\n\n', ''):
            with self.subTest(request=request):
                self.assertEqual('', ask(request))

    # -- review findings: content binding, staged files, branches, output size ------------

    def test_staged_engineer_files_never_reach_diff_or_status(self):
        git(self.checkout, 'add', '-f', 'exports/customer-users.csv', 'log/convert.log')
        self.call('edit', path='README.md', old_text='Converter', new_text='Converter tools')
        for request in ({}, {'path': 'exports'}, {'path': 'log'}, {'scope': 'working'}):
            with self.subTest(request=request):
                result = self.call('diff', **request)
                self.assertNotIn('customer-users', result.get('stat', ''))
        self.assertEqual([{'status': 'M', 'path': 'README.md'}], self.call('status')['changes'])

    def test_content_changed_outside_the_tools_is_invisible(self):
        self.call('write', path='lib/created.rb', content='# mine\n')
        (self.checkout / 'lib/created.rb').write_text(MARKER + '\n')       # e.g. a run writing over it
        (self.checkout / 'README.md').write_text(MARKER + '\n')            # a tracked file rewritten
        for path in ('lib/created.rb', 'README.md'):
            with self.subTest(path=path):
                self.assertEqual('STANDARD_DEV_PATH_NOT_VISIBLE', self.call('read', path=path)['error'])
                self.assertEqual('STANDARD_DEV_PATH_NOT_VISIBLE', self.call('edit', path=path, old_text=MARKER, new_text='x')['error'])
        self.assertEqual([], self.call('search', pattern=MARKER)['matches'])
        self.assertEqual([], self.call('status')['changes'])
        self.assertNotIn('README', self.call('diff')['stat'])
        names = {entry['name'] for entry in self.call('list')['entries']}
        self.assertNotIn('README.md', names)
        self.set_identity()
        self.call('branch', topic='fix')
        self.assertEqual('STANDARD_DEV_NOTHING_TO_COMMIT', self.call('commit', message='x')['error'])
        # Nor can the agent overwrite content it can't see: the engineer cleans it up.
        self.assertEqual('STANDARD_DEV_PATH_NOT_VISIBLE', self.call('write', path='lib/created.rb', content='# mine again\n')['error'])
        self.assertEqual(MARKER + '\n', (self.checkout / 'lib/created.rb').read_text())

    def test_switching_to_an_untrusted_local_branch_is_refused(self):
        git(self.checkout, 'switch', '-q', '-c', 'migration/example-forum/evil')
        git(self.checkout, 'add', '-f', 'exports/customer-users.csv')
        git(self.checkout, 'commit', '-q', '-m', 'data')
        git(self.checkout, 'switch', '-q', 'main')
        self.assertEqual('STANDARD_DEV_BRANCH_UNTRUSTED', self.call('branch', topic='evil')['error'])
        self.assertEqual('main', git(self.checkout, 'branch', '--show-current'))
        self.call('branch', topic='mine')
        git(self.checkout, 'switch', '-q', 'main')
        self.assertEqual('migration/example-forum/mine', self.call('branch', topic='mine')['branch'])  # its own branch

    def test_non_ascii_output_fits(self):
        self.call('write', path='lib/accents.rb', content=''.join('# café crème brûlée ☃ ' + str(n) + '\n' for n in range(3000)))
        for op, extra in (('diff', {}), ('read', {'path': 'lib/accents.rb'})):
            with self.subTest(op=op):
                result = self.call(op, **extra)
                self.assertNotIn('error', result)
                self.assertLess(len(json.dumps(result, ensure_ascii=False).encode()), 47 * 1024)

    def test_docker_runner_keeps_bounded_tails_and_times_out(self):
        code, out, err = self.dev.docker([sys.executable, '-c', 'import sys; sys.stdout.write("x" * 5_000_000); sys.stderr.write("e" * 300_000); print("END")'], 60)
        self.assertEqual(0, code)
        self.assertLessEqual(len(out), self.dev.TAIL_BYTES)
        self.assertTrue(out.endswith(b'END\n'))
        self.assertLessEqual(len(err), self.dev.TAIL_BYTES)
        code, _, _ = self.dev.docker([sys.executable, '-c', 'import time; time.sleep(30)'], 1)
        self.assertIsNone(code)

    # -- tests in the sandbox ------------------------------------------------------

    @staticmethod
    def mounts(argv):
        """{dst: (src, readonly)} of every --mount."""
        found = {}
        for value in argv:
            if value.startswith('type=bind,'):
                fields = dict(part.partition('=')[::2] for part in value.split(','))
                found[fields['dst']] = (fields['src'], 'readonly' in value.split(','))
        return found

    def sandbox(self, seen, deps_code=0, test_output=b'Run options\n3 runs, 5 assertions, 0 failures, 0 errors, 0 skips\n'):
        """Patches standing in for Docker and the emoji download, recording what each container got."""
        def fake_docker(argv, timeout):
            mounts = self.mounts(argv)
            if 'install' in argv:
                seen.setdefault('deps', []).append(argv)
                lock = Path(mounts['/lock'][0])
                seen['lock_files'] = sorted(p.name for p in lock.iterdir())
                time.sleep(seen.get('deps_seconds', 0))
                if deps_code == 0:
                    self.write(Path(mounts['/deps'][0]) / 'specifications/markbridge-0.5.0.gemspec', '# spec\n')
                return deps_code, b'Fetching markbridge 0.5.0\n', b'' if deps_code == 0 else b'Could not reach rubygems.org\n'
            export = Path(mounts['/app'][0])
            placeholder = export / 'tmp/requires/discourse/config/site_settings.yml'
            seen['placeholder_empty'] = placeholder.is_file() and placeholder.stat().st_size == 0  # a mount point, filled by Docker
            seen['files'] = sorted(str(p.relative_to(export)) for p in export.rglob('*') if p.is_file() and p != placeholder)
            seen['text'] = ''.join(p.read_text(errors='replace') for p in export.rglob('*') if p.is_file())
            seen['argv'] = argv
            seen['emoji'] = sorted(str(p.relative_to(mounts['/app/tmp/emoji_cache'][0])) for p in Path(mounts['/app/tmp/emoji_cache'][0]).rglob('*.json'))
            return 0, test_output, b''

        def fake_emoji(destination, deadline):
            seen['emoji_fetches'] = seen.get('emoji_fetches', 0) + 1
            for name in self.dev.EMOJI_FILES:
                self.write(Path(destination) / self.dev.emoji_repo_key() / name, '[]')

        return [mock.patch.object(self.dev, 'converter_image_document', return_value=IMAGE_DOCUMENT),
                mock.patch.object(self.dev, 'docker', side_effect=fake_docker), mock.patch.object(self.dev, 'fetch_emoji', side_effect=fake_emoji)]

    def run_test(self, seen, role='developer', **kwargs):
        patches = self.sandbox(seen, **{k: kwargs.pop(k) for k in ('deps_code', 'test_output') if k in kwargs})
        for patch in patches:
            patch.start()
        try:
            return self.call('test', role=role, **kwargs)
        finally:
            for patch in patches:
                patch.stop()

    def test_test_runner_exports_only_visible_files_into_a_sealed_container(self):
        seen = {}
        self.call('write', path='lib/new.rb', content='# new\n')
        result = self.run_test(seen, role='reviewer')
        self.assertEqual('3 runs, 5 assertions, 0 failures, 0 errors, 0 skips', result['summary'])
        self.assertEqual(['.github/workflows/ci.yml', '.gitignore', 'Gemfile', 'Gemfile.lock', 'README.md', 'lib/importer.rb', 'lib/new.rb', 'test/importer_test.rb'], seen['files'])
        self.assertNotIn(MARKER, seen['text'])
        argv = seen['argv']
        for flag in (['--network', 'none'], ['--read-only'], ['--cap-drop', 'ALL'], ['--security-opt', 'no-new-privileges'], ['--pull=never']):
            self.assertTrue(any(argv[i:i + len(flag)] == flag for i in range(len(argv))), flag)
        mounts = self.mounts(argv)
        self.assertEqual({'/app', '/deps', '/app/tmp/emoji_cache', '/app/tmp/requires/discourse/config/site_settings.yml'}, set(mounts))
        self.assertEqual(4, sum(1 for a in argv if a.startswith('type=bind')))
        self.assertEqual((str(self.site_settings), True), mounts['/app/tmp/requires/discourse/config/site_settings.yml'])
        self.assertTrue(seen['placeholder_empty'])
        self.assertFalse(mounts['/app'][1])
        self.assertTrue(mounts['/deps'][1] and mounts['/app/tmp/emoji_cache'][1])
        self.assertNotIn(str(self.root), ' '.join(argv))
        self.assertIn('GEM_PATH=/deps:/opt/bundle/ruby/3.3.0:/usr/local/bundle', argv)
        self.assertIn('PATH=/deps/bin:/opt/bundle/ruby/3.3.0/bin:/usr/local/bundle/bin:/usr/bin', argv)
        self.assertIn('GEM_HOME=/deps', argv)
        for setting in self.dev.BUNDLE_ENV:
            self.assertIn(setting, argv)
        self.assertNotIn('emoji_warning', result['dependencies'])
        self.assertEqual([IMAGE_ID, '-u', 'BUNDLE_PATH', 'bundle', '_2.6.3_', 'exec', 'rake', 'test'], argv[argv.index(IMAGE_ID):])
        self.assertEqual('env', argv[argv.index('--entrypoint') + 1])
        self.assertEqual(['raw_githubusercontent_com_discourse_discourse-emojis_main_/dist/aliases.json',
                          'raw_githubusercontent_com_discourse_discourse-emojis_main_/dist/emojis.json',
                          'raw_githubusercontent_com_discourse_discourse-emojis_main_/dist/tonable_emojis.json'], seen['emoji'])
        self.assertEqual('STANDARD_ARGUMENTS_INVALID', self.call('test', file='lib/importer.rb')['error'])
        self.assertIsNone(self.run_test(seen, file='')['file'])
        self.assertEqual(['exec', 'rake', 'test'], seen['argv'][-3:])

    def test_site_settings_cache_must_be_the_bound_file(self):
        seen = {}
        self.site_settings.write_text('changed: true\n')
        self.assertEqual('STANDARD_RUNTIME_MISMATCH', self.run_test(seen)['error'])
        self.assertNotIn('argv', seen)

    def test_dependency_step_sees_only_the_lockfiles_and_is_built_once(self):
        seen = {}
        self.call('write', path='lib/new.rb', content='AGENT-CODE\n')  # agent code never reaches the networked step
        first = self.run_test(seen)
        self.assertEqual('prepared', first['dependencies']['status'])
        self.assertEqual(['markbridge-0.5.0'], first['dependencies']['gems_added'])
        self.assertEqual(1, len(seen['deps']))
        argv = seen['deps'][0]
        mounts = self.mounts(argv)
        self.assertEqual({'/lock', '/deps'}, set(mounts))
        self.assertTrue(mounts['/lock'][1])
        self.assertFalse(mounts['/deps'][1])
        self.assertEqual(['Gemfile', 'Gemfile.lock'], seen['lock_files'])
        for flag in (['--network', 'bridge'], ['--read-only'], ['--cap-drop', 'ALL'], ['--security-opt', 'no-new-privileges'], ['--pull=never']):
            self.assertTrue(any(argv[i:i + len(flag)] == flag for i in range(len(argv))), flag)
        self.assertNotIn(str(self.root), ' '.join(argv))
        self.assertEqual([IMAGE_ID, '-u', 'BUNDLE_PATH', 'bundle', '_2.6.3_', 'install', '--no-cache'], argv[argv.index(IMAGE_ID):])
        for setting in self.dev.BUNDLE_ENV:
            self.assertIn(setting, argv)
        cache = Path(self.temp.name) / 'state/converter-deps'
        ready = [p for p in cache.iterdir() if not p.name.startswith('.')]
        self.assertEqual(1, len(ready))
        self.assertEqual(['emoji_cache', 'gems', 'ready.json'], sorted(p.name for p in ready[0].iterdir()))
        self.assertFalse(list(cache.glob('.build-*')))
        record = json.loads((ready[0] / 'ready.json').read_text())
        self.assertEqual(hashlib.sha256(LOCKFILE.encode()).hexdigest(), record['lockfile_sha256'])
        # Second call (and the reviewer's): reused, nothing networked runs again.
        self.assertEqual('ready', self.run_test(seen, role='reviewer')['dependencies']['status'])
        self.assertEqual(1, len(seen['deps']))
        self.assertEqual(1, seen['emoji_fetches'])
        # A new upstream lockfile is a new key.
        seed = Path(self.temp.name) / 'seed'
        self.write(seed / 'Gemfile.lock', LOCKFILE.replace('0.5.0)\n\nPLATFORMS', '0.5.1)\n\nPLATFORMS'))
        git(seed, 'commit', '-qam', 'Bump')
        git(seed, 'push', '-q', str(self.origin), 'main')
        git(self.checkout, 'pull', '-q', '--ff-only')
        self.assertEqual('prepared', self.run_test(seen)['dependencies']['status'])
        self.assertEqual(2, len(seen['deps']))

    def test_failed_dependency_step_runs_no_tests_and_leaves_no_cache(self):
        seen = {}
        result = self.run_test(seen, deps_code=1)
        self.assertEqual('failed', result['dependencies']['status'])
        self.assertEqual('gems', result['dependencies']['step'])
        self.assertIsNone(result['exit_code'])
        self.assertNotIn('argv', seen)
        self.assertIn('engineer', result['note'])
        cache = Path(self.temp.name) / 'state/converter-deps'
        self.assertEqual([], [p.name for p in cache.iterdir() if not p.name.startswith('.lock-')])

    def test_emoji_failure_fails_the_step(self):
        seen = {}
        with mock.patch.object(self.dev, 'converter_image_document', return_value=IMAGE_DOCUMENT), \
                mock.patch.object(self.dev, 'docker', side_effect=lambda argv, timeout: (0, b'', b'')), \
                mock.patch.object(self.dev.urllib.request, 'urlopen', side_effect=OSError('no route')):
            result = self.call('test')
        self.assertEqual({'status': 'failed', 'step': 'emoji', 'error': 'OSError'}, result['dependencies'])
        self.assertNotIn('argv', seen)

    def test_prepared_with_little_time_left_asks_for_a_rerun(self):
        seen = {'deps_seconds': 0.6}  # the build uses time; a reused cache doesn't
        with mock.patch.object(self.dev, 'TEST_TIMEOUT', 60), mock.patch.object(self.dev, 'TEST_MIN_SECONDS', 59.7):
            result = self.run_test(seen)
            self.assertEqual('prepared', result['dependencies']['status'])
            self.assertIn('Run dev_test again', result['note'])
            self.assertNotIn('argv', seen)
            self.assertEqual('3 runs, 5 assertions, 0 failures, 0 errors, 0 skips', self.run_test(seen)['summary'])

    def deps_key(self):
        gemfile = (self.checkout / 'Gemfile').read_bytes()
        return hashlib.sha256(self.dev.canonical({'recipe': self.dev.DEPS_RECIPE, 'image': IMAGE_ID, 'gemfile': hashlib.sha256(gemfile).hexdigest(),
                                                  'lockfile': hashlib.sha256(LOCKFILE.encode()).hexdigest()}).encode()).hexdigest()

    def test_waiting_for_another_preparer_also_counts_against_the_test_time(self):
        import fcntl
        import threading
        seen = {}
        root = Path(self.temp.name) / 'state/converter-deps'
        root.mkdir(parents=True)
        key = self.deps_key()
        holder = os.open(root / ('.lock-' + key), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(holder, fcntl.LOCK_EX)

        def other_preparer():
            time.sleep(1.5)
            for name in ('gems', 'emoji_cache'):
                (root / key / name).mkdir(parents=True)
            (root / key / 'ready.json').write_text('{}')
            os.close(holder)
        thread = threading.Thread(target=other_preparer)
        thread.start()
        try:
            with mock.patch.object(self.dev, 'TEST_TIMEOUT', 91), mock.patch.object(self.dev, 'TEST_MIN_SECONDS', 90):
                result = self.run_test(seen)
        finally:
            thread.join()
        self.assertEqual('ready', result['dependencies']['status'])
        self.assertIn('Run dev_test again', result['note'])
        self.assertNotIn('deps', seen)
        self.assertNotIn('argv', seen)

    def test_a_key_folder_without_ready_record_is_rebuilt(self):
        seen = {}
        broken = Path(self.temp.name) / 'state/converter-deps' / self.deps_key()
        self.write(broken / 'gems/half-written', 'x')
        self.assertEqual('prepared', self.run_test(seen)['dependencies']['status'])
        self.assertFalse((broken / 'gems/half-written').exists())
        self.assertTrue((broken / 'ready.json').is_file())

    def test_a_visible_file_in_the_way_of_the_emoji_mount_is_refused_cleanly(self):
        seen = {}
        self.call('write', path='tmp', content='not a folder\n')
        self.assertEqual('STANDARD_OPERATION_FAILED', self.run_test(seen)['error'])
        self.assertNotIn('argv', seen)

    def test_changed_emoji_url_is_reported(self):
        seen = {}
        self.call('write', path='support/emojis/discourse_emoji_data.rb', content='BASE_URI = "' + self.dev.EMOJI_BASE + '"\n')
        self.assertNotIn('emoji_warning', self.run_test(seen)['dependencies'])
        self.call('edit', path='support/emojis/discourse_emoji_data.rb', old_text='/main/', new_text='/abc123/')
        result = self.run_test(seen)
        self.assertIn('emoji URL changed', result['dependencies']['emoji_warning'])
        self.assertEqual('3 runs, 5 assertions, 0 failures, 0 errors, 0 skips', result['summary'])

    def test_dependency_step_waits_for_another_preparer(self):
        import fcntl
        seen = {}
        with mock.patch.object(self.dev, 'converter_image_document', return_value=IMAGE_DOCUMENT):
            checkout = self.dev.Checkout(self.base, self.ws, self.host)
        gemfile = (self.checkout / 'Gemfile').read_bytes()
        key = hashlib.sha256(self.dev.canonical({'recipe': self.dev.DEPS_RECIPE, 'image': IMAGE_ID, 'gemfile': hashlib.sha256(gemfile).hexdigest(),
                                                 'lockfile': hashlib.sha256(LOCKFILE.encode()).hexdigest()}).encode()).hexdigest()
        root = self.dev.deps_root(checkout)
        holder = os.open(root / ('.lock-' + key), os.O_RDWR | os.O_CREAT, 0o600)
        self.addCleanup(os.close, holder)
        fcntl.flock(holder, fcntl.LOCK_EX)
        with mock.patch.object(self.dev, 'DEPS_TIMEOUT', 2):
            result = self.run_test(seen)
        self.assertEqual('busy', result['dependencies']['status'])
        self.assertNotIn('deps', seen)

    def test_dependency_files_must_be_the_committed_upstream_ones(self):
        seen = {}
        self.write(self.checkout / 'Gemfile', 'source "https://example.invalid"\n')  # a person editing it, not an agent
        self.assertEqual('STANDARD_DEV_DEPS_UNSUPPORTED', self.run_test(seen)['error'])
        self.assertNotIn('deps', seen)
        git(self.checkout, 'checkout', '--', 'Gemfile')
        for path in ('Gemfile', 'Gemfile.lock'):
            self.assertEqual('STANDARD_DEV_PATH_PROTECTED', self.call('write', path=path, content='gem "x"\n')['error'])
        # A Gemfile.lock the agent could have recorded (not at HEAD) is refused too.
        git(self.checkout, 'rm', '-q', '--cached', 'Gemfile.lock')
        git(self.checkout, 'commit', '-qm', 'Untrack lock')
        self.assertEqual('STANDARD_DEV_DEPS_UNSUPPORTED', self.run_test(seen)['error'])
        self.assertNotIn('deps', seen)

    def test_deps_command_prepares_the_cache_for_head(self):
        seen = {}
        patches = self.sandbox(seen)
        for patch in patches:
            patch.start()
        try:
            result = self.dev.main(['converter', 'deps', self.ws], {}, self.base, ROOT, self.host, io.StringIO(''), home=str(self.home))
            self.assertEqual('prepared', result['dependencies']['status'])
            self.assertEqual(git(self.checkout, 'rev-parse', 'HEAD'), result['head'])
            self.assertEqual('ready', self.dev.main(['converter', 'deps', self.ws, '--budget', '150'], {}, self.base, ROOT, self.host, io.StringIO(''))['dependencies']['status'])
            for bad in (['--budget', '29'], ['--budget', '181'], ['--budget', 'x'], ['--timeout', '150']):
                with self.assertRaisesRegex(self.dev.Refusal, 'STANDARD_ARGUMENTS_INVALID'):
                    self.dev.main(['converter', 'deps', self.ws, *bad], {}, self.base, ROOT, self.host, io.StringIO(''))
            self.assertEqual(1, len(seen['deps']))
        finally:
            for patch in patches:
                patch.stop()
        patches = self.sandbox(seen, deps_code=1)
        for path in (Path(self.temp.name) / 'state/converter-deps').iterdir():
            if path.is_dir():
                shutil.rmtree(path)  # a new key must be built, and that build fails
        for patch in patches:
            patch.start()
        try:
            with self.assertRaisesRegex(self.dev.Refusal, r'\ASTANDARD_CONVERTER_DEPS_FAILED: failed \(gems\)\Z'):
                self.dev.main(['converter', 'deps', self.ws], {}, self.base, ROOT, self.host, io.StringIO(''))
        finally:
            for patch in patches:
                patch.stop()

    def test_lockfile_sources_and_bundler_are_checked(self):
        check = self.dev.check_lockfile
        check(LOCKFILE.encode())
        for bad in (LOCKFILE.replace('https://rubygems.org/', 'https://gems.example.invalid/'),
                    'GIT\n  remote: https://github.com/example/gem.git\n  revision: abc\n  specs:\n    x (1)\n\n' + LOCKFILE,
                    'PATH\n  remote: ../local\n  specs:\n    y (1)\n\n' + LOCKFILE,
                    'PLUGIN SOURCE\n  remote: https://rubygems.org/\n\n' + LOCKFILE,
                    LOCKFILE.replace('GEM\n  remote: https://rubygems.org/\n', 'GEM\n  remote: https://rubygems.org/\n  remote: https://gems.example.invalid/\n'),
                    LOCKFILE.replace('2.6.3', '2.7.1'), LOCKFILE.replace('BUNDLED WITH\n   2.6.3\n', ''), b'\xff'):
            with self.subTest(bad=bad[:40]):
                with self.assertRaisesRegex(self.dev.Refusal, 'STANDARD_DEV_DEPS_UNSUPPORTED'):
                    check(bad if isinstance(bad, bytes) else bad.encode())

    def test_image_gem_env_comes_from_the_image(self):
        self.assertEqual([*self.dev.BUNDLE_ENV, 'GEM_HOME=/deps', 'GEM_PATH=/deps:/opt/bundle/ruby/3.3.0:/usr/local/bundle',
                          'PATH=/deps/bin:/opt/bundle/ruby/3.3.0/bin:/usr/local/bundle/bin:/usr/bin'], self.dev.image_gem_env(IMAGE_DOCUMENT, '/deps'))
        good = ['RUBY_VERSION=3.4.1', 'GEM_HOME=/x', 'BUNDLE_PATH=/opt/b', 'PATH=/usr/bin']
        self.assertIn('GEM_PATH=/deps:/opt/b/ruby/3.4.0:/x', self.dev.image_gem_env({'Config': {'Env': good}}, '/deps'))
        for env in ([], good[:2] + good[3:], good[:2] + ['BUNDLE_PATH=/opt/b:/evil', good[3]], ['RUBY_VERSION=x'] + good[1:],
                    good[:3] + ['PATH=/usr/bin:relative'], good[:3] + ['PATH=/usr/bin:/a b']):
            with self.subTest(env=env):
                with self.assertRaisesRegex(self.dev.Refusal, 'STANDARD_RUNTIME_MISMATCH'):
                    self.dev.image_gem_env({'Config': {'Env': env}}, '/deps')

    def test_emoji_fetch_validates_and_bounds(self):
        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        destination = Path(self.temp.name) / 'emoji'
        with mock.patch.object(self.dev.urllib.request, 'urlopen', side_effect=lambda request, timeout: Response(b'{"a": 1}')) as opened:
            self.dev.fetch_emoji(destination, time.monotonic() + 60)
        self.assertEqual([self.dev.EMOJI_BASE + name for name in self.dev.EMOJI_FILES], [call.args[0].full_url for call in opened.call_args_list])
        self.assertEqual(3, len(list(destination.rglob('*.json'))))
        with mock.patch.object(self.dev.urllib.request, 'urlopen', side_effect=lambda request, timeout: Response(b'<html>')):
            with self.assertRaises(ValueError):
                self.dev.fetch_emoji(destination, time.monotonic() + 60)
        with mock.patch.object(self.dev, 'EMOJI_MAX_BYTES', 4), mock.patch.object(self.dev.urllib.request, 'urlopen', side_effect=lambda request, timeout: Response(b'[1,2,3]')):
            with self.assertRaises(ValueError):
                self.dev.fetch_emoji(destination, time.monotonic() + 60)
        with self.assertRaises(TimeoutError):
            self.dev.fetch_emoji(destination, time.monotonic() + 1)

    def test_converter_image_is_verified_against_the_bound_profile(self):
        repo = Path(self.temp.name) / 'release'
        profile = {'images': {'converter': {'ref': 'converter:tag', 'content_id': 'sha256:' + 'c' * 64}}}
        raw = json.dumps(profile).encode()
        (repo / 'runtime/profiles').mkdir(parents=True)
        (repo / 'runtime/profiles/profile-a.json').write_bytes(raw)
        checkout = types.SimpleNamespace(config={'discourse_profile': 'profile-a', 'discourse_profile_sha256': hashlib.sha256(raw).hexdigest()},
                                         host=types.SimpleNamespace(inspect=lambda ref: {'Id': 'sha256:' + 'd' * 64}, identity=lambda doc: 'sha256:' + 'c' * 64))
        self.assertEqual('sha256:' + 'd' * 64, self.dev.converter_image(checkout, {}, repo))
        checkout.host.identity = lambda doc: 'sha256:' + 'e' * 64
        with self.assertRaisesRegex(self.dev.Refusal, 'STANDARD_RUNTIME_MISMATCH'):
            self.dev.converter_image(checkout, {}, repo)
        checkout.config['discourse_profile_sha256'] = '0' * 64
        with self.assertRaisesRegex(self.dev.Refusal, 'STANDARD_RUNTIME_MISMATCH'):
            self.dev.converter_image(checkout, {}, repo)

    def test_unsafe_checkout_config_is_refused_before_any_operation(self):
        git(self.checkout, 'config', 'core.pager', 'sh -c "cat /etc/passwd"')
        self.assertTrue(self.call('list')['error'].startswith('STANDARD_CONVERTER_CONFIG'))

    def test_output_stays_under_the_tool_limit(self):
        self.write(self.checkout / 'lib/big.rb', ''.join(f'line {n} "q" \\ x\n' for n in range(40000)))
        for n in range(300):
            self.write(self.checkout / f'lib/many/file_{n:03d}_{"x" * 60}.rb', 'downcase\n')
        for op, extra in (('read', {'path': 'lib/big.rb'}), ('list', {'path': 'lib/many'}), ('search', {'pattern': 'downcase'}), ('diff', {})):
            with self.subTest(op=op):
                self.assertLess(len(json.dumps(self.call(op, **extra)).encode()), 48 * 1024)


if __name__ == '__main__':
    unittest.main()
