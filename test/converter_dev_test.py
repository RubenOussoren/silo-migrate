"""Converter development boundary tests with real Git. Run: python3 -I -B test/converter_dev_test.py."""
import hashlib
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
        git(seed, 'add', '-A')
        git(seed, 'commit', '-q', '-m', 'Seed')
        git(base, 'clone', '-q', '--bare', str(seed), str(self.origin))
        self.checkout = self.root / 'converter'
        git(self.root, 'clone', '-q', str(self.origin), str(self.checkout))
        self.state = {'config': {'converter_worktree': str(self.checkout), 'discourse_profile': 'profile-a', 'discourse_profile_sha256': ''}, 'runs': {}}
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
        self.assertEqual({'.github', 'lib', 'test', '.gitignore', 'README.md'}, names)
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

    def test_test_runner_exports_only_visible_files_into_a_sealed_container(self):
        seen = {}

        def fake_docker(argv, timeout):
            mount = next(a for a in argv if a.startswith('type=bind,src='))
            export = Path(mount.split('src=', 1)[1].split(',', 1)[0])
            seen['files'] = sorted(str(p.relative_to(export)) for p in export.rglob('*') if p.is_file())
            seen['text'] = ''.join(p.read_text(errors='replace') for p in export.rglob('*') if p.is_file())
            seen['argv'] = argv
            return 0, b'Run options\n3 runs, 5 assertions, 0 failures, 0 errors, 0 skips\n', b''

        self.call('write', path='lib/new.rb', content='# new\n')
        with mock.patch.object(self.dev, 'converter_image', return_value='sha256:' + 'b' * 64), mock.patch.object(self.dev, 'docker', side_effect=fake_docker):
            result = self.call('test', role='reviewer')
        self.assertEqual('3 runs, 5 assertions, 0 failures, 0 errors, 0 skips', result['summary'])
        self.assertEqual(['.github/workflows/ci.yml', '.gitignore', 'README.md', 'lib/importer.rb', 'lib/new.rb', 'test/importer_test.rb'], seen['files'])
        self.assertNotIn(MARKER, seen['text'])
        argv = seen['argv']
        for flag in (['--network', 'none'], ['--read-only'], ['--cap-drop', 'ALL'], ['--security-opt', 'no-new-privileges'], ['--pull=never']):
            self.assertTrue(any(argv[i:i + len(flag)] == flag for i in range(len(argv))), flag)
        self.assertEqual(1, sum(1 for a in argv if a.startswith('type=bind')))
        self.assertNotIn(str(self.root), ' '.join(argv))
        self.assertEqual(['sha256:' + 'b' * 64, 'exec', 'rake', 'test'], argv[argv.index('sha256:' + 'b' * 64):][:1] + argv[-3:])
        self.assertEqual('STANDARD_ARGUMENTS_INVALID', self.call('test', file='lib/importer.rb')['error'])
        with mock.patch.object(self.dev, 'converter_image', return_value='sha256:' + 'b' * 64), mock.patch.object(self.dev, 'docker', side_effect=fake_docker):
            self.assertIsNone(self.call('test', file='')['file'])
        self.assertEqual(['exec', 'rake', 'test'], seen['argv'][-3:])

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
