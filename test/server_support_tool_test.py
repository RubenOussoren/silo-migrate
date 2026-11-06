"""server-support read-tool boundary tests. Run: python3 -I -B test/server_support_tool_test.py."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
AGENT = ROOT / 'integrations/term-llm/server-support'
SECRET = 'sk-live-' + 'q' * 32


class ServerSupportToolTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.home = base / 'home'
        self.prefix = base / 'srv'
        self.outside_workspaces = base / 'data/workspaces'
        release = self.prefix / 'releases' / ('c' * 40)
        self.agent = release / 'integrations/term-llm/server-support'
        shutil.copytree(AGENT, self.agent)
        (self.prefix / 'current').symlink_to(release)
        (self.prefix / 'releases' / ('d' * 40)).mkdir()
        (self.prefix / 'releases' / ('d' * 40) / 'old.txt').write_text('old release')
        self.write(self.prefix / 'etc/silo-control.env', f'SILO_MIGRATE_BASE_PATH={self.outside_workspaces}\nSILO_CONTROL_GEMS=/x\n')
        self.write(self.prefix / 'state/install-manifest.json', '{"commit": "c"}\n')
        self.write(self.prefix / 'state/tmp/upload-part', 'CUSTOMER-ROW alice@example.test')
        self.write(self.prefix / 'workspaces/acme/inputs/source.sql', 'CUSTOMER-ROW')
        self.write(self.outside_workspaces / 'acme/inputs/source.sql', 'CUSTOMER-ROW')
        config = self.home / '.config/term-llm'
        self.write(config / 'config.yaml', '\n'.join([
            'default_provider: chatgpt',
            'providers:',
            '  cdck_frontier:',
            '    api_key: $(/usr/local/bin/op-cache read "op://Everybody/Snorlax LLM/credential")',
            '  other:',
            f'    api_key: {SECRET}',
            '    token: "abcdefgh12345678"',
            '    password: ""',
            '    url: https://user:hunter2hunter2@example.test/v1',
            f'    headers: {{Authorization: "Bearer {SECRET}"}}',
            '-----BEGIN OPENSSH PRIVATE KEY-----',
            'b3BlbnNzaC1rZXktdjEAAAAA',
            '-----END OPENSSH PRIVATE KEY-----',
            'after: visible', '']))
        self.write(config / 'chatgpt_oauth.json', '{"access_token": "OAUTH-SECRET"}')
        self.write(config / 'services/web/credentials/TERM_LLM_SERVE_TOKEN', 'SERVE-SECRET')
        self.write(config / 'services/web/service.json', '{"args": ["serve"]}')
        (config / 'ws-link').symlink_to(self.prefix / 'workspaces/acme')
        (config / 'tmp-link').symlink_to(self.prefix / 'state/tmp/upload-part')
        self.write(self.home / '.config/op-cache/config.yaml', 'ttl: 86400\n')
        self.write(self.home / '.config/silo-migrate/hub.env', 'TERM_LLM_HUB_REGISTRATION_TOKEN=HUB-SECRET\n')

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def call(self, tool, args):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('SILO_', 'TERM_LLM_'))}
        env.update(TERM_LLM_TOOL_NAME=tool, TERM_LLM_AGENT_DIR=str(self.agent), SILO_SUPPORT_HOME=str(self.home), PYTHONDONTWRITEBYTECODE='1')
        result = subprocess.run([sys.executable, '-I', '-B', str(self.agent / 'scripts/support_tool.py')], input=json.dumps(args),
                                capture_output=True, text=True, env=env, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('', result.stderr)
        self.assertLess(len(result.stdout.encode()), 48 * 1024)
        return json.loads(result.stdout), result.stdout

    def read(self, path, **extra):
        return self.call('support_read_file', dict(path=str(path), **extra))

    def test_config_is_readable_with_secret_values_redacted_and_references_kept(self):
        result, raw = self.read('~/.config/term-llm/config.yaml')
        text = result['text']
        for secret in (SECRET, 'abcdefgh12345678', 'hunter2hunter2', 'b3BlbnNzaC1rZXktdjEAAAAA'):
            self.assertNotIn(secret, raw)
        self.assertIn('op-cache read "op://Everybody/Snorlax LLM/credential"', text)
        self.assertIn('password: ""', text)
        self.assertIn('after: visible', text)
        self.assertGreaterEqual(result['redactions'], 5)

    def test_credentials_are_refused(self):
        for path in ('~/.config/term-llm/chatgpt_oauth.json', '~/.config/term-llm/services/web/credentials/TERM_LLM_SERVE_TOKEN',
                     '~/.config/term-llm/services/web/credentials'):
            with self.subTest(path=path):
                result, raw = self.call('support_list_dir' if path.endswith('credentials') else 'support_read_file', {'path': path})
                self.assertEqual('SUPPORT_PATH_REFUSED_SECRET', result['error'])
                self.assertNotIn('SECRET', raw.replace('SUPPORT_PATH_REFUSED_SECRET', ''))

    def test_workspaces_and_service_temp_are_refused_even_through_links(self):
        for path in (self.prefix / 'workspaces/acme/inputs/source.sql', self.prefix / 'workspaces', self.outside_workspaces / 'acme/inputs/source.sql',
                     self.prefix / 'state/tmp/upload-part', self.home / '.config/term-llm/ws-link/inputs/source.sql',
                     self.home / '.config/term-llm/tmp-link', str(self.prefix / 'state') + '/../workspaces/acme/inputs/source.sql'):
            with self.subTest(path=path):
                result, raw = self.read(path)
                self.assertIn(result['error'], ('SUPPORT_PATH_REFUSED_CUSTOMER_DATA', 'SUPPORT_PATH_NOT_ALLOWED'))
                self.assertNotIn('CUSTOMER-ROW', raw)
        self.assertEqual('SUPPORT_PATH_REFUSED_CUSTOMER_DATA', self.call('support_list_dir', {'path': str(self.prefix / 'workspaces')})[0]['error'])

    def test_paths_outside_the_allowed_roots_are_refused(self):
        for path in ('/etc/passwd', str(self.home / '.config/silo-migrate/hub.env'), str(self.prefix / 'releases' / ('d' * 40) / 'old.txt'),
                     str(self.prefix), str(self.home / '.config/term-llm/../silo-migrate/hub.env'), str(self.home)):
            with self.subTest(path=path):
                result, raw = self.read(path)
                self.assertEqual('SUPPORT_PATH_NOT_ALLOWED', result['error'])
                self.assertNotIn('HUB-SECRET', raw)
        for value in ('relative/config.yaml', '', None, 7, 'x\x00y'):
            with self.subTest(value=value):
                self.assertIn(self.read(value)[0]['error'], ('SUPPORT_PATH_NOT_ABSOLUTE', 'SUPPORT_ARGUMENTS_INVALID'))

    def test_allowed_installation_files(self):
        self.assertIn('SILO_MIGRATE_BASE_PATH', self.read(self.prefix / 'etc/silo-control.env')[0]['text'])
        self.assertIn('commit', self.read(self.prefix / 'state/install-manifest.json')[0]['text'])
        self.assertIn('ttl', self.read('~/.config/op-cache/config.yaml')[0]['text'])
        agent = self.read(self.prefix / 'current/integrations/term-llm/server-support/agent.yaml')[0]
        self.assertIn('name: server-support', agent['text'])

    def test_listing_marks_refused_entries(self):
        listing = {entry['name']: entry for entry in self.call('support_list_dir', {'path': '~/.config/term-llm'})[0]['entries']}
        self.assertEqual('SUPPORT_PATH_REFUSED_SECRET', listing['chatgpt_oauth.json']['refused'])
        self.assertEqual('SUPPORT_PATH_REFUSED_CUSTOMER_DATA', listing['ws-link']['refused'])
        self.assertNotIn('refused', listing['config.yaml'])
        state = {entry['name']: entry for entry in self.call('support_list_dir', {'path': str(self.prefix / 'state')})[0]['entries']}
        self.assertEqual('SUPPORT_PATH_REFUSED_CUSTOMER_DATA', state['tmp']['refused'])
        roots = self.call('support_allowed_paths', {})[0]
        self.assertIn(str(self.outside_workspaces), roots['refused'])
        self.assertIn(os.path.realpath(self.prefix / 'current'), roots['allowed'])

    def test_large_file_is_paged_and_special_files_are_not_read(self):
        big = self.write(self.prefix / 'state/logs/big.json', ''.join(f'line {n} "quoted" \\ value\n' for n in range(1, 20001)))
        first = self.read(big)[0]
        self.assertTrue(first['next_line'])
        second = self.read(big, start_line=first['next_line'])[0]
        self.assertTrue(second['text'].startswith(f"line {first['next_line']} "))
        (self.prefix / 'state/logs/bin.dat').write_bytes(b'\x00\x01secret')
        self.assertEqual(True, self.read(self.prefix / 'state/logs/bin.dat')[0]['binary'])
        os.mkfifo(self.prefix / 'state/logs/pipe')
        self.assertEqual('SUPPORT_NOT_A_FILE', self.read(self.prefix / 'state/logs/pipe')[0]['error'])
        self.assertEqual('SUPPORT_ARGUMENTS_INVALID', self.read(big, start_line=0)[0]['error'])

    def test_unknown_tool_is_refused(self):
        self.assertEqual('SUPPORT_TOOL_UNKNOWN', self.call('support_write_file', {'path': '~/.config/term-llm/config.yaml'})[0]['error'])


if __name__ == '__main__':
    unittest.main()
