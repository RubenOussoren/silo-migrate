"""`silo` node command tests (no real services). Run: python3 -I -B test/silo_cli_test.py."""
import importlib.machinery
import importlib.util
import json
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
        return {'service status': (0, 'ActiveState=active\n'), ' agents': (0, listing), 'op-cache read op://Everybody/Snorlax LLM/credential --account discourse.1password.com': (0, 'secret'),
                'auth status --json': (0, json.dumps({'loggedIn': True})), 'docker info': (0, '29.9.3\n')}

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

    def test_doctor_reports_each_problem_with_its_fix(self):
        responses = self.healthy()
        responses['service status'] = (0, 'ActiveState=failed\n')
        responses[' agents'] = (0, 'Available agents (3):\n\n  [builtin]\n    developer - d\n')
        del responses['op-cache read op://Everybody/Snorlax LLM/credential --account discourse.1password.com']
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

    def test_parsers(self):
        self.assertEqual((2, ['a', 'b'], False), self.s.listed_agents('Available agents (2):\n\n  [user] /x/\n    b - y\n    a - x\n'))
        self.assertEqual({'OP_SESSION_discourse': 'abc'}, self.s.op_session('export OP_SESSION_discourse="abc"\n# This command is meant to be used with your shell\'s eval function.\n'))
        self.assertEqual({}, self.s.op_session('error'))

    # -- use-github / update --------------------------------------------------------------

    def test_use_github_rewrites_only_the_repository_lines(self):
        self.s.METAL_CONFIG.write_text('SILO_ACCOUNT=silomig\nSILO_REPO=/srv/silo-transfer/silo-migrate.git\nSILO_BRANCH=mvp/metal-installer\n')
        self.s.METAL_CONFIG.chmod(0o640)
        calls = []
        with mock.patch.object(self.s.os, 'geteuid', return_value=0), mock.patch.object(self.s, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')), \
                mock.patch.object(self.s, 'stream', side_effect=lambda argv: calls.append(argv) or 0), mock.patch.object(self.s.os, 'chown'):
            (self.s.INSTALLER / '.git').mkdir(parents=True)
            self.assertEqual(0, self.s.use_github())
        self.assertEqual('SILO_ACCOUNT=silomig\nSILO_REPO=https://github.com/RubenOussoren/silo-migrate.git\nSILO_BRANCH=mvp/metal-installer\n'
                         'CONVERTER_REPO=https://github.com/discourse-org/discourse-converters.git\n', self.s.METAL_CONFIG.read_text())
        self.assertEqual(0o640, stat.S_IMODE(self.s.METAL_CONFIG.stat().st_mode))
        self.assertEqual(1, len(list(self.root.glob('metal.conf.bak-*'))))
        self.assertEqual(['git', '-C', str(self.s.INSTALLER), 'remote', 'set-url', 'origin', 'https://github.com/RubenOussoren/silo-migrate.git'], calls[0])

    def test_use_github_changes_nothing_when_github_is_unreachable(self):
        self.s.METAL_CONFIG.write_text('SILO_REPO=/x\n')
        with mock.patch.object(self.s.os, 'geteuid', return_value=0), mock.patch.object(self.s, 'run', return_value=subprocess.CompletedProcess([], 128, '', '')):
            with self.assertRaisesRegex(self.s.Stop, 'nothing changed'):
                self.s.use_github()
        self.assertEqual('SILO_REPO=/x\n', self.s.METAL_CONFIG.read_text())

    def test_update_needs_root_and_uses_the_installed_branch(self):
        with self.assertRaisesRegex(self.s.Stop, 'root'):
            self.s.update(self.entry)
        (self.prefix / 'state/install-manifest.json').write_text(json.dumps({'branch': 'mvp/metal-installer'}))
        calls = []
        with mock.patch.object(self.s.os, 'geteuid', return_value=0), mock.patch.object(self.s, 'stream', side_effect=lambda argv: calls.append(argv) or 0), \
                mock.patch.object(self.s, 'doctor', return_value=0), mock.patch.object(self.s.time, 'sleep'):
            self.assertEqual(0, self.s.update(self.entry))
        self.assertEqual(['git', '-C', str(self.s.INSTALLER), 'pull', '--ff-only'], calls[0])
        self.assertEqual([str(self.s.INSTALLER / 'script/metal'), 'update', '--config', str(self.s.METAL_CONFIG), '--branch', 'mvp/metal-installer'], calls[1])
        self.assertIn('restart', calls[2])
        with mock.patch.object(self.s.os, 'geteuid', return_value=0), mock.patch.object(self.s, 'stream', return_value=1):
            with self.assertRaisesRegex(self.s.Stop, 'stopped'):
                self.s.update(self.entry, 'main')

    # -- intake ------------------------------------------------------------------------------

    def test_intake_prepares_a_private_drop_folder(self):
        self.s.intake(self.entry, 'mybb-acme')
        folder = self.prefix / 'intake/mybb-acme'
        self.assertEqual(0o700, stat.S_IMODE(folder.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(folder.parent.stat().st_mode))
        (folder / 'dump.sql').write_text('-- MySQL dump\n')
        self.s.intake(self.entry, 'mybb-acme')
        for name in ('../x', 'a/b', '', '-x'):
            with self.subTest(name=name), self.assertRaises(self.s.Stop):
                self.s.intake(self.entry, name)

    def test_cli_entry_points(self):
        result = subprocess.run(['python3', '-I', '-B', str(ROOT / 'bin/silo'), 'nonsense'], capture_output=True, text=True)
        self.assertEqual(2, result.returncode)
        self.assertIn('unknown command', result.stderr)
        self.assertIn('silo doctor', subprocess.run(['python3', '-I', '-B', str(ROOT / 'bin/silo'), '--help'], capture_output=True, text=True).stdout)


if __name__ == '__main__':
    unittest.main()
