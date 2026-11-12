"""`silo` node command tests (no real services). Run: python3 -I -B test/silo_cli_test.py."""
import importlib.machinery
import importlib.util
import io
import json
import types
import os
from pathlib import Path
import pwd
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load():
    loader = importlib.machinery.SourceFileLoader('silo_cli', str(ROOT / 'bin/silo'))
    spec = importlib.util.spec_from_loader('silo_cli', loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class SiloTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.s = load()
        self.prefix = self.root / 'srv'
        release = self.prefix / 'releases' / ('a' * 40)
        for agent in ('converter-developer', 'migration-analyst'):
            (release / 'integrations/term-llm' / agent).mkdir(parents=True)
            (release / 'integrations/term-llm' / agent / 'agent.yaml').write_text('name: x\n')
        (release / 'integrations/term-llm/converter-developer/agent.yaml').chmod(0o444)
        (release / 'integrations/term-llm/migration-analyst/agent.yaml').chmod(0o444)
        (self.prefix / 'current').symlink_to(release)
        (self.prefix / 'state').mkdir()
        self.home = self.root / 'home'
        (self.home / '.config/term-llm').mkdir(parents=True)
        (self.home / '.config/term-llm/config.yaml').write_text(
            'providers:\n  cdck_frontier:\n    api_key: $(/usr/local/bin/op-cache read "op://Everybody/Snorlax LLM/credential" --account discourse.1password.com)\n  claude-bin:\n    model: opus\n')
        (self.home / '.config/term-llm/chatgpt_oauth.json').write_text('{}')
        me = pwd.getpwuid(os.getuid())
        self.entry = pwd.struct_passwd((me.pw_name, 'x', me.pw_uid, me.pw_gid, '', str(self.home), '/bin/bash'))
        self.s.PREFIX = self.prefix
        self.s.METAL_CONFIG = self.root / 'metal.conf'
        self.s.INSTALLER = self.root / 'installer'

    # -- running as the service account -------------------------------------------

    def test_account_steps_run_as_the_account_with_its_environment(self):
        argv = self.s.as_account(['term-llm', 'agents'], self.entry)
        self.assertEqual('env', argv[0])
        self.assertIn('XDG_RUNTIME_DIR=/run/user/' + str(self.entry.pw_uid), argv)
        self.assertEqual(['term-llm', 'agents'], argv[-2:])
        other = pwd.struct_passwd(('silomig', 'x', 99999, 99999, '', '/home/silomig', '/bin/bash'))
        with mock.patch.object(self.s.os, 'geteuid', return_value=0):
            argv = self.s.as_account(['term-llm', 'agents'], other)
        self.assertEqual(['sudo', '-u', 'silomig', '--', 'env', '-i'], argv[:6])
        self.assertIn('HOME=/home/silomig', argv)
        self.assertIn('DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/99999/bus', argv)
        with self.assertRaisesRegex(self.s.Stop, 'root'):
            self.s.as_account(['x'], other)

    # -- doctor ---------------------------------------------------------------------

    def fake_runner(self, responses):
        def runner(argv, timeout=60, input=None):
            text = ' '.join(argv)
            for needle, (code, out) in responses.items():
                if needle in text:
                    return subprocess.CompletedProcess(argv, code, out, '')
            return subprocess.CompletedProcess(argv, 1, '', '')
        return runner

    def statuses(self, responses, which='/usr/local/bin/claude'):
        with mock.patch.object(self.s.shutil, 'which', return_value=which):
            return {c['name']: c for c in self.s.doctor_checks(self.entry, runner=self.fake_runner(responses))}

    def healthy(self):
        listing = 'Available agents (2):\n\n  [user] /x/\n    converter-developer - a\n    migration-analyst - b\n'
        return {'service status': (0, 'ActiveState=active\n'), ' agents': (0, listing), 'sh op://Everybody/Snorlax LLM/credential --account discourse.1password.com': (0, 'secret'),
                'auth status --json': (0, json.dumps({'loggedIn': True})), 'docker info': (0, '29.9.3\n'),
                'capabilities --json': (0, json.dumps({'private_upload_context': 1, 'session_scope_lock': 1, 'custom_tool_session_context': 1}))}

    def test_doctor_all_good(self):
        token = self.home / '.config/silo-migrate/github/token-discourse-org'
        token.parent.mkdir(parents=True)
        token.write_text('t')
        token.chmod(0o600)
        (self.home / '.config/silo-migrate/git-identity').write_text('name=a\nemail=b@c\n')
        checks = self.statuses(self.healthy())
        for name in ('web service', 'agents', 'ChatGPT sign-in', 'Frontier (op-cache)', 'Claude (claude-bin)', 'GitHub token', 'commit identity', 'Docker', 'release read-only'):
            self.assertEqual('OK', checks[name]['status'], (name, checks[name]))
        self.assertNotIn('secret', json.dumps(checks))

    def test_doctor_checks_actual_private_attachment_capabilities(self):
        checks = self.statuses(self.healthy())
        self.assertEqual('OK', checks['private chat attachments']['status'])
        for code, payload in ((1, ''), (0, '{}'), (0, '[]'), (0, 'invalid'),
                              (0, '{"private_upload_context":1}')):
            with self.subTest(payload=payload):
                responses = dict(self.healthy(), **{'capabilities --json': (code, payload)})
                check = self.statuses(responses)['private chat attachments']
                self.assertEqual('WARN', check['status'])
                self.assertIn('TERM_LLM_PACKAGE', check['fix'])
                self.assertIn('normal intake', check['detail'])

    def test_doctor_generic_private_scope_is_separate_from_deferred_chat_uploads(self):
        generic = {'session_scope_lock': 1, 'custom_tool_session_context': 1}
        checks = self.statuses(dict(self.healthy(), **{'capabilities --json': (0, json.dumps(generic))}))
        self.assertEqual('OK', checks['private data conversations']['status'])
        self.assertEqual('WARN', checks['private chat attachments']['status'])
        self.assertIn('do not install the old', checks['private chat attachments']['fix'])
        config = self.home / '.config/term-llm/mcp.json'
        config.write_text(json.dumps({'servers': {'db-private-canary': {
            'command': '/srv/silo-migrate/bin/silo-migrate-control', 'args': ['dbhub', 'private-canary']}}}))
        before = config.read_bytes()
        checks = self.statuses(dict(self.healthy(), **{'capabilities --json': (0, '{"session_scope_lock":1}')}))
        self.assertEqual('FAIL', checks['private data conversations']['status'])
        self.assertEqual('FAIL', checks['DBHub']['status'])
        self.assertIn('1 project database servers', checks['DBHub']['detail'])
        self.assertNotIn('private-canary', json.dumps(checks))
        self.assertEqual(before, config.read_bytes())

    def test_doctor_checks_dbhub_servers_are_limited_without_naming_projects(self):
        self.assertEqual('OK', self.statuses(self.healthy())['DBHub']['status'])
        config = self.home / '.config/term-llm/mcp.json'
        rules = self.home / '.config/term-llm/config.yaml'
        base = rules.read_text()
        entry = {'command': '/srv/silo-migrate/bin/silo-migrate-control', 'args': ['dbhub', 'acme-forum']}
        config.write_text(json.dumps({'servers': {'db-acme-forum': entry, 'db-other': {'command': 'x'}, 'mine': {'command': 'y'}}}))
        responses = dict(self.healthy(), **{' version': (0, 'term-llm version 0.9.99 (commit: x)\n')})
        check = self.statuses(responses)['DBHub']
        self.assertEqual(('WARN', '1 of 1 project servers not limited to migration-data'), (check['status'], check['detail']))
        self.assertIn('silo update', check['fix'])
        # The old mcp.json key isn't a rule: term-llm reads only config.yaml's.
        config.write_text(json.dumps({'servers': {'db-acme-forum': dict(entry, agents=['migration-data'])}}))
        self.assertEqual('WARN', self.statuses(responses)['DBHub']['status'])
        rules.write_text(base + 'mcp:\n  servers:\n    db-acme-forum:\n      agents:\n        - migration-data\n')
        check = self.statuses(responses)['DBHub']
        self.assertEqual(('OK', '1 project servers, only migration-data can use them'), (check['status'], check['detail']))
        # Older term-llm: the rule is there but not enforced.
        old = dict(responses, **{' version': (0, 'term-llm version 0.9.93 (commit: x)\n')})
        check = self.statuses(old)['DBHub']
        self.assertEqual('WARN', check['status'])
        self.assertIn("0.9.93 doesn't enforce", check['detail'])
        self.assertEqual('silo update', check['fix'])
        # Agents from a search path can't be named by the rule: migration-data couldn't use its database.
        searched = dict(responses, **{' agents': (0, self.healthy()[' agents'][1].replace('[user] /x/', '[search-path] /srv/x'))})
        checks = self.statuses(searched)
        self.assertEqual(('FAIL', 'WARN'), (checks['agents']['status'], checks['DBHub']['status']))
        self.assertIn('not from ~/.config/term-llm/agents', checks['agents']['detail'])
        self.assertIn('silo update', checks['agents']['fix'])
        self.assertIn("can't use them", checks['DBHub']['detail'])
        self.assertNotIn('acme', json.dumps(self.statuses(responses)))
        rules.write_text(base + 'mcp:\n  servers: [broken\n')
        self.assertIn("can't be read", self.statuses(responses)['DBHub']['detail'])
        config.write_text('{broken')
        self.assertEqual('WARN', self.statuses(responses)['DBHub']['status'])

    def test_doctor_reports_each_problem_with_its_fix(self):
        responses = self.healthy()
        responses['service status'] = (0, 'ActiveState=failed\n')
        responses[' agents'] = (0, 'Available agents (3):\n\n  [builtin]\n    developer - d\n')
        del responses['sh op://Everybody/Snorlax LLM/credential --account discourse.1password.com']
        responses['auth status --json'] = (0, json.dumps({'loggedIn': False}))
        token = self.home / '.config/silo-migrate/github/token-discourse-org'
        token.parent.mkdir(parents=True)
        token.write_text('t')
        token.chmod(0o644)
        (self.prefix / 'current/integrations/term-llm/migration-analyst/agent.yaml').chmod(0o644)
        checks = self.statuses(responses)
        expected = {'web service': ('FAIL', 'silo restart'), 'agents': ('FAIL', 'agents.use_builtin'), 'Frontier (op-cache)': ('FAIL', 'silo prime'),
                    'Claude (claude-bin)': ('FAIL', 'silo claude-login'), 'GitHub token': ('FAIL', 'chmod 600'), 'commit identity': ('WARN', 'git-identity'),
                    'release read-only': ('WARN', 'silo update')}
        for name, (status, fix) in expected.items():
            self.assertEqual(status, checks[name]['status'], name)
            self.assertIn(fix, checks[name]['fix'], name)
        self.assertEqual('FAIL', self.statuses(self.healthy(), which=None)['Claude (claude-bin)']['status'])

    def test_root_checks(self):
        self.s.METAL_CONFIG.write_text('SILO_REPO=/srv/silo-transfer/silo-migrate.git\nCONVERTER_REPO=https://github.com/x/y.git\n')
        responses = self.healthy()
        responses['rev-parse HEAD'] = (0, 'b' * 40 + '\n')
        with mock.patch.object(self.s.os, 'geteuid', return_value=0), mock.patch.object(self.s, 'as_account', side_effect=lambda argv, entry=None: argv):
            checks = self.statuses(responses)
        self.assertEqual(('WARN', 'silo use-github'), (checks['update source']['status'], checks['update source']['fix']))
        self.assertEqual(('WARN', 'silo update'), (checks['installer checkout']['status'], checks['installer checkout']['fix']))
        self.assertEqual('WARN', checks['silo command']['status'])

    def test_op_cache_settings_ttl_and_display(self):
        self.assertEqual((False, '/tmp/op-cache.sock', 86400), self.s.op_cache_settings(self.entry))
        config = self.home / '.config/op-cache/config.yaml'
        config.parent.mkdir(parents=True)
        config.write_text('socket_path: /run/user/1001/op-cache.sock\nop_path: /usr/bin/op\nttl_seconds: 2592000\n')
        self.assertEqual((True, '/run/user/1001/op-cache.sock', 2592000), self.s.op_cache_settings(self.entry))
        self.assertEqual('30 days', self.s.duration(2592000))
        self.assertEqual('24 hours', self.s.duration(86400))
        checks = self.statuses(self.healthy())
        self.assertEqual('OK', checks['op-cache config']['status'])
        self.assertIn('30 days', checks['op-cache config']['detail'])
        config.write_text('socket_path: /tmp/op-cache.sock\n')
        self.assertEqual('WARN', self.statuses(self.healthy())['op-cache config']['status'])
        self.assertEqual('term-llm service restart web',
                         self.s.shown(['sudo', '-u', 'silomig', '--', 'env', '-i', 'HOME=/h', 'PATH=/p', 'term-llm', 'service', 'restart', 'web']))
        self.assertEqual('git -C /opt/x pull', self.s.shown(['git', '-C', '/opt/x', 'pull']))

    def test_parsers(self):
        self.assertEqual((2, ['a', 'b'], False), self.s.listed_agents('Available agents (2):\n\n  [user] /x/\n    b - y\n    a - x\n'))
        self.assertEqual({'OP_SESSION_discourse': 'abc'}, self.s.op_session('export OP_SESSION_discourse="abc"\n# This command is meant to be used with your shell\'s eval function.\n'))
        self.assertEqual({}, self.s.op_session('error'))

    # -- use-github / update --------------------------------------------------------------

    def test_use_github_rewrites_only_the_repository_lines(self):
        self.s.METAL_CONFIG.write_text('SILO_ACCOUNT=silomig\nSILO_REPO=/srv/silo-transfer/silo-migrate.git\nSILO_BRANCH=mvp/metal-installer\n')
        self.s.METAL_CONFIG.chmod(0o640)
        calls = []
        with mock.patch.object(self.s, 'need_root'), mock.patch.object(self.s, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')), \
                mock.patch.object(self.s, 'stream', side_effect=lambda argv: calls.append(argv) or 0):
            (self.s.INSTALLER / '.git').mkdir(parents=True)
            self.assertEqual(0, self.s.use_github())
        # CONVERTER_REPO is left alone: metal plan resolves it without a token.
        self.assertEqual('SILO_ACCOUNT=silomig\nSILO_REPO=https://github.com/RubenOussoren/silo-migrate.git\nSILO_BRANCH=mvp/metal-installer\n',
                         self.s.METAL_CONFIG.read_text())
        self.assertEqual(0o640, stat.S_IMODE(self.s.METAL_CONFIG.stat().st_mode))
        self.assertEqual(1, len(list(self.root.glob('metal.conf.bak-*'))))
        self.assertEqual(['git', '-C', str(self.s.INSTALLER), 'remote', 'set-url', 'origin', 'https://github.com/RubenOussoren/silo-migrate.git'], calls[0])
        self.assertEqual([], list(self.root.glob('.metal-*')) + list(self.root.glob('.backup-*')))

    def test_config_rewrite_refuses_symlinks_and_loose_directories(self):
        real = self.root / 'real.conf'
        real.write_text('SILO_REPO=/x\n')
        self.s.METAL_CONFIG.symlink_to(real)
        with self.assertRaisesRegex(self.s.Stop, 'symlink'):
            self.s.set_conf_values(self.s.METAL_CONFIG, {'SILO_REPO': 'https://github.com/a/b.git'})
        self.s.METAL_CONFIG.unlink()
        self.s.METAL_CONFIG.write_text('SILO_REPO=/x\n')
        with mock.patch.object(self.s, 'is_root', return_value=True), self.assertRaisesRegex(self.s.Stop, 'root-owned'):
            self.s.set_conf_values(self.s.METAL_CONFIG, {'SILO_REPO': 'https://github.com/a/b.git'})
        self.assertEqual('SILO_REPO=/x\n', self.s.METAL_CONFIG.read_text())

    def test_use_github_changes_nothing_when_github_is_unreachable(self):
        self.s.METAL_CONFIG.write_text('SILO_REPO=/x\n')
        with mock.patch.object(self.s, 'need_root'), mock.patch.object(self.s, 'run', return_value=subprocess.CompletedProcess([], 128, '', '')):
            with self.assertRaisesRegex(self.s.Stop, 'nothing changed'):
                self.s.use_github()
        self.assertEqual('SILO_REPO=/x\n', self.s.METAL_CONFIG.read_text())

    def test_update_needs_root_and_uses_the_installed_branch(self):
        with self.assertRaisesRegex(self.s.Stop, 'root'):
            self.s.update(self.entry)
        (self.prefix / 'state/install-manifest.json').write_text(json.dumps({'branch': 'mvp/metal-installer'}))
        calls = []
        on_branch = mock.patch.object(self.s, 'run', return_value=subprocess.CompletedProcess([], 0, 'mvp/metal-installer\n', ''))
        with mock.patch.object(self.s.os, 'geteuid', return_value=0), mock.patch.object(self.s, 'stream', side_effect=lambda argv: calls.append(argv) or 0), \
                mock.patch.object(self.s, 'doctor', return_value=0), mock.patch.object(self.s.time, 'sleep'), on_branch:
            self.assertEqual(0, self.s.update(self.entry))
        self.assertEqual(['git', '-C', str(self.s.INSTALLER), 'pull', '--ff-only'], calls[0])
        self.assertEqual([str(self.s.INSTALLER / 'script/metal'), 'update', '--config', str(self.s.METAL_CONFIG), '--branch', 'mvp/metal-installer'], calls[1])
        self.assertIn('restart', calls[2])
        with mock.patch.object(self.s.os, 'geteuid', return_value=0), mock.patch.object(self.s, 'stream', return_value=1), on_branch:
            with self.assertRaisesRegex(self.s.Stop, 'not main'):
                self.s.update(self.entry, 'main')
            with self.assertRaisesRegex(self.s.Stop, 'stopped'):
                self.s.update(self.entry, 'mvp/metal-installer')

    # -- intake ------------------------------------------------------------------------------

    def test_intake_prepares_a_private_drop_folder(self):
        self.s.intake(self.entry, 'mybb-acme')
        folder = self.prefix / 'intake/mybb-acme'
        self.assertEqual(0o700, stat.S_IMODE(folder.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(folder.parent.stat().st_mode))
        (folder / 'dump.sql').write_text('-- MySQL dump\n')
        (folder / 'attachments').mkdir()
        (folder / 'attachments/a.png').write_bytes(b'x' * 10)
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'secret').write_text('x')
        (folder / 'escape').symlink_to(outside)
        chowned = []
        real_chown = os.chown
        real_fstat = os.fstat
        as_root = lambda fd: os.stat_result((stat.S_IFDIR | 0o700, 0, 0, 1, 99999, 99999, 0, 0, 0, 0))  # the account's folder
        with mock.patch.object(self.s, 'is_root', return_value=True), mock.patch.object(self.s.os, 'fchown'), mock.patch.object(self.s.os, 'fstat', side_effect=as_root), \
                mock.patch.object(self.s.os, 'chown', side_effect=lambda *a, **k: chowned.append((a, k))):
            self.s.intake(pwd.struct_passwd(('silomig', 'x', 99999, 99999, '', '/x', '/bin/bash')), 'mybb-acme')
        names = sorted(a[0] for a, k in chowned)
        self.assertEqual(['a.png', 'attachments', 'dump.sql', 'escape'], names)  # the link itself, never its target
        self.assertTrue(all(k.get('follow_symlinks') is False and 'dir_fd' in k for a, k in chowned))
        stranger = lambda fd: os.stat_result((stat.S_IFDIR | 0o700, 0, 0, 1, 0, 0, 0, 0, 0, 0))  # pre-existing root folder
        with mock.patch.object(self.s.os, 'fstat', side_effect=stranger), self.assertRaisesRegex(self.s.Stop, 'unexpected owner'):
            self.s.intake(pwd.struct_passwd(('silomig', 'x', 99999, 99999, '', '/x', '/bin/bash')), 'mybb-acme')
        os.rename(folder, self.root / 'moved')
        (self.prefix / 'intake/mybb-acme').symlink_to(outside)
        with self.assertRaisesRegex(self.s.Stop, 'symlink|plain directory'):
            self.s.intake(self.entry, 'mybb-acme')
        for name in ('../x', 'a/b', '', '-x'):
            with self.subTest(name=name), self.assertRaises(self.s.Stop):
                self.s.intake(self.entry, name)

    def test_intake_second_run_says_the_files_now_belong_to_the_account(self):
        import contextlib, io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.s.intake(self.entry, 'arc')
        self.assertIn('scp FILES', out.getvalue())
        (self.prefix / 'intake/arc/dump.sql').write_text('-- MySQL dump\n')
        out = io.StringIO()
        as_account = lambda fd: os.stat_result((stat.S_IFDIR | 0o700, 0, 0, 1, 99999, 99999, 0, 0, 0, 0))
        with contextlib.redirect_stdout(out), mock.patch.object(self.s, 'is_root', return_value=True), mock.patch.object(self.s.os, 'fchown'), \
                mock.patch.object(self.s.os, 'chown'), mock.patch.object(self.s.os, 'fstat', side_effect=as_account):
            self.s.intake(pwd.struct_passwd(('silomig', 'x', 99999, 99999, '', '/x', '/bin/bash')), 'arc')
        text = out.getvalue()
        self.assertIn('1 file(s)', text)
        self.assertIn('now belong to silomig', text)
        self.assertIn('Files tab: create the workspace', text)  # the page first, then the chat
        self.assertLess(text.index('Files tab'), text.index('migration-data'))
        self.assertNotIn('scp FILES', text)

    def test_doctor_checks_the_skills_link(self):
        skills = self.prefix / 'current/integrations/term-llm/skills/intake-basics'
        os.chmod(self.prefix / 'current/integrations/term-llm', 0o755)
        skills.mkdir(parents=True)
        (skills / 'SKILL.md').write_text('---\nname: intake-basics\ndescription: x\n---\n')
        check = self.statuses(self.healthy())['skills']
        self.assertEqual('WARN', check['status'])
        self.assertIn('ln -s ' + str(self.prefix / 'current/integrations/term-llm/skills'), check['fix'])
        (self.home / '.config/term-llm/skills').symlink_to(self.prefix / 'current/integrations/term-llm/skills')
        check = self.statuses(self.healthy())['skills']
        self.assertEqual(('OK', '1 linked from the release'), (check['status'], check['detail']))

    def test_intake_creates_the_web_ui_project_without_showing_the_token(self):
        spec = self.home / '.config/term-llm/services/web/service.json'
        spec.parent.mkdir(parents=True)
        token = 'tok_' + 'x' * 40
        real_run = self.s.run
        def fake_run(argv, timeout=60, input=None):
            if argv[-3:] == ['service', 'token', 'web']:
                return subprocess.CompletedProcess(argv, 0, token + '\n', '')
            return real_run(argv, timeout=timeout, input=input)
        sent = []
        class Reply(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self, *a): return False
        def fake_urlopen(request, timeout=0):
            sent.append(request)
            if len(sent) > 1:  # what term-llm 0.9.93 answers for a folder that is already a project
                raise urllib.error.HTTPError(request.full_url, 409, 'Conflict', {}, io.BytesIO(b'{"error":{"code":"project_duplicate"}}'))
            return Reply(json.dumps({'project': {'id': 'prj_1'}}).encode())
        import urllib.error
        import urllib.request
        handlers = []
        def fake_build_opener(*given):
            handlers.extend(given)
            return types.SimpleNamespace(open=fake_urlopen)
        with mock.patch.object(self.s, 'run', side_effect=fake_run), mock.patch('urllib.request.build_opener', side_effect=fake_build_opener), \
                mock.patch('sys.stdout', new_callable=io.StringIO) as out:
            # Projects not on yet: the folder is made, no request is sent.
            spec.write_text(json.dumps({'url': 'http://localhost:18800/ui/', 'args': ['--no-projects']}))
            self.assertIn('silo update turns them on', self.s.web_project(self.entry, 'mybb-acme'))
            self.assertEqual([], sent)
            spec.write_text(json.dumps({'url': 'http://localhost:18800/ui/', 'args': ['--host', '127.0.0.1', '--projects']}))
            self.s.intake(self.entry, 'mybb-acme')
            self.assertIn('(already there)', self.s.web_project(self.entry, 'mybb-acme'))
        folder = self.home / 'projects/mybb-acme'
        self.assertTrue(folder.is_dir())
        self.assertEqual(0o700, stat.S_IMODE(folder.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(folder.parent.stat().st_mode))
        request = sent[0]
        self.assertEqual('http://127.0.0.1:18800/ui/v1/projects', request.full_url)
        self.assertEqual({'name': 'mybb-acme', 'path': str(folder)}, json.loads(request.data))
        self.assertEqual('Bearer ' + token, request.get_header('Authorization'))
        self.assertIn('web UI project: mybb-acme (created)', out.getvalue())
        # No proxy from root's environment and no redirects carrying the token.
        proxy = next(h for h in handlers if isinstance(h, urllib.request.ProxyHandler))
        self.assertEqual({}, proxy.proxies)
        redirect = next(h for h in handlers if isinstance(h, urllib.request.HTTPRedirectHandler))
        self.assertIsNone(redirect.redirect_request(None, None, 302, 'Found', {}, 'http://elsewhere.example/'))
        self.assertNotIn(token, out.getvalue())
        # Any other refusal says so, with its status.
        def refusing(request, timeout=0):
            raise urllib.error.HTTPError(request.full_url, 401, 'Unauthorized', {}, io.BytesIO(b'{"error":{"code":"unauthorized"}}'))
        with mock.patch.object(self.s, 'run', side_effect=fake_run), \
                mock.patch('urllib.request.build_opener', return_value=types.SimpleNamespace(open=refusing)):
            self.assertIn('refused it: HTTP 401, unauthorized', self.s.web_project(self.entry, 'mybb-acme'))
        # A URL that isn't local is never sent the token.
        spec.write_text(json.dumps({'url': 'https://example.test/ui/', 'args': ['--projects']}))
        with mock.patch.object(self.s, 'run', side_effect=fake_run), mock.patch('urllib.request.build_opener', side_effect=fake_build_opener):
            self.s.web_project(self.entry, 'mybb-acme')
        self.assertEqual(2, len(sent))

    def test_doctor_warns_when_frontier_has_no_context_window(self):
        config = self.home / '.config/term-llm/config.yaml'
        self.assertEqual('WARN', self.statuses(self.healthy())['Frontier context']['status'])
        text = config.read_text()
        config.write_text('providers:\n  cdck_frontier:\n    model: CDCK/MoM\n    context_window: 256000  # tokens\n  other:\n    context_window: 5\n')
        check = self.statuses(self.healthy())['Frontier context']
        self.assertEqual(('OK', 'context_window 256000'), (check['status'], check['detail']))
        # Another provider's value doesn't count, and neither does a zero.
        for body in ('providers:\n  cdck_frontier:\n    model: CDCK/MoM\n  other:\n    context_window: 5\n',
                     'providers:\n  cdck_frontier:\n    context_window: 0\n'):
            config.write_text(body)
            self.assertEqual('WARN', self.statuses(self.healthy())['Frontier context']['status'])
        config.write_text(text)

    def test_set_contact_is_root_only_one_line_and_read_back_by_doctor(self):
        import contextlib
        self.assertEqual('WARN', self.statuses(self.healthy())['support contact']['status'])
        with self.assertRaisesRegex(self.s.Stop, 'needs root'):
            self.s.set_contact('Ruben')
        (self.prefix / 'etc').mkdir()
        with mock.patch.object(self.s, 'is_root', return_value=True), contextlib.redirect_stdout(io.StringIO()):
            for bad in ('', 'two\nlines', 'x' * 81):
                with self.assertRaises(self.s.Stop):
                    self.s.set_contact(bad)
            self.assertEqual(0, self.s.set_contact('  Ruben '))
        target = self.prefix / 'etc/support-contact'
        self.assertEqual('Ruben\n', target.read_text())
        self.assertEqual(0o644, stat.S_IMODE(target.stat().st_mode))
        check = self.statuses(self.healthy())['support contact']
        self.assertEqual(('OK', 'Ruben'), (check['status'], check['detail']))

    def test_doctor_shows_whether_web_projects_are_on(self):
        spec = self.home / '.config/term-llm/services/web/service.json'
        spec.parent.mkdir(parents=True)
        spec.write_text(json.dumps({'args': ['--no-projects']}))
        self.assertEqual(('WARN', 'silo update'), (self.statuses(self.healthy())['web projects']['status'], self.statuses(self.healthy())['web projects']['fix']))
        spec.write_text(json.dumps({'args': ['--projects']}))
        self.assertEqual('OK', self.statuses(self.healthy())['web projects']['status'])

    def test_doctor_shows_whether_the_findings_widget_is_on(self):
        spec = self.home / '.config/term-llm/services/web/service.json'
        spec.parent.mkdir(parents=True, exist_ok=True)
        ui = str(self.prefix / 'current/integrations/term-llm')
        spec.write_text(json.dumps({'args': ['--projects', '--disable-extensions', '--disable-widgets']}))
        self.assertEqual(('WARN', 'silo update'), (self.statuses(self.healthy())['project page']['status'], self.statuses(self.healthy())['project page']['fix']))
        spec.write_text(json.dumps({'args': ['--projects', '--widgets-dir', ui + '/widgets', '--extensions-dir', ui + '/extensions', '--extensions', 'silo-findings']}))
        statuses = self.statuses(self.healthy())
        self.assertEqual('OK', statuses['project page']['status'])
        self.assertEqual(('WARN', 'silo update'), (statuses['theme']['status'], statuses['theme']['fix']))
        spec.write_text(json.dumps({'args': ['--projects', '--widgets-dir', ui + '/widgets', '--extensions-dir', ui + '/extensions', '--extensions', 'varnish,silo-theme,silo-findings']}))
        self.assertEqual('WARN', self.statuses(self.healthy())['theme']['status'])  # saved args name it, but the release has no Varnish
        varnish = Path(ui) / 'extensions/varnish'
        varnish.mkdir(parents=True)
        (varnish / 'extension.yaml').write_text('title: V\n')
        statuses = self.statuses(self.healthy())
        self.assertEqual('OK', statuses['project page']['status'])
        self.assertEqual('OK', statuses['theme']['status'])

    def test_doctor_checks_the_widget_socket_folder_is_private(self):
        runtime, tmpfiles = self.root / 'widgets-run', self.root / 'tmpfiles.conf'
        with mock.patch.object(self.s, 'WIDGET_RUNTIME', runtime), mock.patch.object(self.s, 'WIDGET_TMPFILES', tmpfiles):
            self.assertEqual(('WARN', 'silo update'), (self.statuses(self.healthy())['widget folder']['status'], self.statuses(self.healthy())['widget folder']['fix']))
            tmpfiles.write_text('d x')
            self.assertEqual('OK', self.statuses(self.healthy())['widget folder']['status'])
            runtime.mkdir(mode=0o700)
            self.assertEqual('OK', self.statuses(self.healthy())['widget folder']['status'])
            runtime.chmod(0o755)
            self.assertEqual('FAIL', self.statuses(self.healthy())['widget folder']['status'])
            runtime.chmod(0o700)
            real_lstat = os.lstat
            def someone_elses(path, *args, **kwargs):
                info = real_lstat(path, *args, **kwargs)
                if Path(path) != runtime:
                    return info
                fields = list(info)
                fields[4] = os.getuid() + 4242  # st_uid: another account created it first
                return os.stat_result(fields)
            with mock.patch.object(self.s.os, 'lstat', side_effect=someone_elses):
                checks = self.statuses(self.healthy())
            self.assertEqual('FAIL', checks['widget folder']['status'])
            self.assertIn('remove it', checks['widget folder']['fix'])

    def test_status_gets_a_short_read_cpu_budget_without_changing_executor_limits(self):
        import runpy
        control = runpy.run_path(str(ROOT / 'bin/silo-migrate-control'))
        values = {'SILO_MIGRATE_BASE_PATH': str(self.root / 'workspaces'), 'SILO_CONTROL_GEMS': str(self.root / 'gems')}
        real_stat = Path.stat
        def fake_stat(path, *args, **kwargs):
            return types.SimpleNamespace(st_gid=99) if str(path) == '/var/run/docker.sock' else real_stat(path, *args, **kwargs)
        cases = [(['standard', 'status', 'synthetic'], '1'),
                 (['standard', 'plan', 'show', 'synthetic', 'plan-' + 'a' * 32], '1'),
                 (['standard', 'run', 'show', 'synthetic', 'run-' + 'a' * 32], '1'),
                 (['standard', 'run', 'execute', 'synthetic', 'run-' + 'a' * 32], '0.25'),
                 (['standard', 'plan', 'approve', 'synthetic', 'plan-' + 'b' * 32], '0.25'),
                 (['standard', 'agent', 'status', 'synthetic'], '0.25')]
        with mock.patch.dict(control['main'].__globals__, {'settings': lambda: (values, False)}), \
                mock.patch.object(Path, 'stat', fake_stat), mock.patch('os.execvp') as execute:
            for args, budget in cases:
                control['main'](args)
                command = execute.call_args.args[1]
                self.assertEqual(budget, command[command.index('--cpus') + 1])
                self.assertEqual('512m', command[command.index('--memory') + 1])
                self.assertIn('--read-only', command)
                self.assertIn('no-new-privileges', command)
                self.assertEqual('ALL', command[command.index('--cap-drop') + 1])

    def test_control_refuses_root_except_image_identity(self):
        import runpy
        config = self.root / 'control.env'
        config.write_text('SILO_MIGRATE_BASE_PATH=/x\nSILO_CONTROL_GEMS=/x\nSILO_CONTROL_SITE_CACHE=/x\n')
        control = types.SimpleNamespace(**runpy.run_path(str(Path(__file__).resolve().parents[1] / 'bin/silo-migrate-control')))
        with mock.patch.dict(os.environ, {'SILO_CONTROL_CONFIG': str(config)}), mock.patch('os.geteuid', return_value=0):
            with self.assertRaisesRegex(ValueError, 'STANDARD_RUN_AS_ACCOUNT'):
                control.main(['standard', 'finding', 'review', 'arc', 'finding-' + 'a' * 32])
            with mock.patch.dict(control.main.__globals__, {'inspect': lambda ref: {'x': 1}, 'identity': lambda doc: 'sha256:' + '0' * 64}), \
                    mock.patch('sys.stdout', new_callable=io.StringIO):
                self.assertEqual(0, control.main(['image-identity', 'ruby@sha256:' + 'a' * 64]))

    def test_claude_link_goes_in_the_service_path_not_roots(self):
        target = self.home / '.local/bin/claude'
        target.parent.mkdir(parents=True)
        target.write_text('#!/bin/sh\n')
        (self.prefix / 'bin').mkdir()
        calls = []
        with mock.patch.object(self.s.subprocess, 'call', side_effect=lambda argv: calls.append(argv) or 0):
            self.s.claude_login(self.entry, [])
        self.assertIn(['ln', '-sfn', str(target), str(self.prefix / 'bin/claude')], [c[-4:] for c in calls])
        self.assertIn(['auth', 'login', '--claudeai'], [c[-3:] for c in calls])
        self.assertFalse(any('/usr/local/bin' in ' '.join(c[-4:]) for c in calls))

    def remove_calls(self, replies, typed=None, tty=True):
        """Run `silo remove-project` with silo-migrate-control's answers faked; (status, output, argvs)."""
        calls = []

        def fake(argv, timeout=60, input=None):
            calls.append(argv)
            code, payload = replies.pop(0)
            return subprocess.CompletedProcess(argv, code, json.dumps(payload) + '\n' if code == 0 else '', payload if code else '')
        out = io.StringIO()
        stdin = mock.Mock(isatty=lambda: tty)
        with mock.patch.object(self.s, 'run', side_effect=fake), mock.patch('sys.stdout', out), mock.patch('sys.stdin', stdin), \
                mock.patch('builtins.input', side_effect=[typed] if typed is not None else EOFError), mock.patch.dict(os.environ, {'SUDO_USER': 'ruben'}):
            try:
                status = self.s.remove_project(self.entry, self.args)
            except self.s.Stop as stop:
                status = 'stop: ' + str(stop)
        return status, out.getvalue(), [argv[argv.index(str(self.prefix / 'bin/silo-migrate-control')) + 1:] for argv in calls]

    def test_remove_project_lists_projects_and_checks_its_arguments(self):
        self.args = []
        status, out, argvs = self.remove_calls([(0, {'projects': ['arc', 'demo']})])
        self.assertEqual((0, [['remove-project', '--list']]), (status, argvs))
        self.assertIn('projects on this server: arc, demo', out)
        for args in (['../x'], ['arc', '--force'], ['arc', '--keep-received', 'x']):
            self.args = args
            self.assertIn('usage: silo remove-project', self.remove_calls([])[0])

    PLAN = {'exists': True, 'mode': 'start_over', 'blocked': [],
            'removed': [{'text': 'Work: 2 plans, 1 run, 0 findings, labels, notes and decisions', 'bytes': 2_100_000_000},
                        {'text': 'Converter checkout on this server, with 1 commit that aren\'t on GitHub', 'bytes': 38_000_000, 'warn': True}],
            'kept': [{'text': 'Received files: export.sql.gz, back in the drop folder to label again', 'bytes': 790_000_000}]}

    def test_remove_project_shows_the_plan_and_needs_the_typed_name(self):
        self.args = ['arc', '--keep-received']
        status, out, argvs = self.remove_calls([(0, self.PLAN)], typed='arcc')
        self.assertEqual(1, status)
        self.assertEqual([['remove-project', 'arc', '--plan', '--keep-received']], argvs)  # never --confirm
        self.assertIn('Start arc over', out)
        self.assertIn('  ! Converter checkout on this server, with 1 commit', out)
        self.assertIn('Received files: export.sql.gz, back in the drop folder to label again   790 MB', out)
        self.assertIn('Cancelled. Nothing was changed.', out)
        self.assertIn('run this in a terminal', self.remove_calls([(0, self.PLAN)], tty=False)[0])

    def test_remove_project_refuses_while_busy(self):
        self.args = ['arc']
        plan = dict(self.PLAN, mode='remove', blocked=[{'code': 'STANDARD_BUSY_RUN', 'text': 'A run is still running. Wait for it to finish.'}])
        status, out, argvs = self.remove_calls([(0, plan)])
        self.assertEqual(2, status)
        self.assertIn('Not now:\n  A run is still running', out)
        self.assertEqual(1, len(argvs))

    def test_remove_project_confirmed(self):
        self.args = ['arc', '--keep-received']
        done = {'status': 'done', 'removed': {'docker_objects': 9, 'chats': 5, 'attachments': 2}, 'returned': [{'name': 'export.sql.gz', 'to': 'export.sql.gz', 'bytes': 790_000_000}],
                'notes': [], 'next': 'Next: on the Project page, Files tab, label the returned files.'}
        status, out, argvs = self.remove_calls([(0, self.PLAN), (0, done)], typed='arc')
        self.assertEqual(0, status)
        self.assertEqual(['remove-project', 'arc', '--confirm', 'arc', '--keep-received', '--by', 'ruben'], argvs[1])
        self.assertIn('chats removed: 5 (attachments: 2)', out)
        self.assertIn('back in the drop folder: export.sql.gz   790 MB', out)
        status, out, argvs = self.remove_calls([(0, self.PLAN), (1, 'Error: STANDARD_BUSY_CHAT: a chat in this project is still answering\n')], typed='arc')
        self.assertEqual('stop: STANDARD_BUSY_CHAT: a chat in this project is still answering', status)

    def test_remove_project_with_nothing_there(self):
        self.args = ['ghost']
        status, out, _ = self.remove_calls([(0, {'exists': False, 'blocked': [], 'removed': [], 'kept': []})])
        self.assertEqual(0, status)
        self.assertIn('There is nothing of ghost on this server.', out)

    def test_cli_entry_points(self):
        result = subprocess.run(['python3', '-I', '-B', str(ROOT / 'bin/silo'), 'nonsense'], capture_output=True, text=True)
        self.assertEqual(2, result.returncode)
        self.assertIn('unknown command', result.stderr)
        self.assertIn('silo doctor', subprocess.run(['python3', '-I', '-B', str(ROOT / 'bin/silo'), '--help'], capture_output=True, text=True).stdout)


if __name__ == '__main__':
    unittest.main()
