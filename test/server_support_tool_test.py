"""server-support read-tool boundary tests. Run: python3 -I -B test/server_support_tool_test.py."""
import json
import os
from pathlib import Path
import pwd
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
        self.installed_agent = release / 'integrations/term-llm/server-support'
        shutil.copytree(AGENT, self.installed_agent)
        # A development copy: the test-only SILO_SUPPORT_HOME/PREFIX overrides apply.
        self.agent = base / 'checkout/integrations/term-llm/server-support'
        shutil.copytree(AGENT, self.agent)
        (self.prefix / 'current').symlink_to(release)
        (self.prefix / 'releases' / ('d' * 40)).mkdir()
        (self.prefix / 'releases' / ('d' * 40) / 'old.txt').write_text('old release')
        self.write(self.prefix / 'etc/silo-control.env', f'SILO_MIGRATE_BASE_PATH={self.outside_workspaces}\nSILO_CONTROL_GEMS=/x\n')
        self.write(self.prefix / 'state/install-manifest.json', '{"commit": "c"}\n')
        self.write(self.prefix / 'state/tmp/upload-part', 'CUSTOMER-ROW alice@example.test')
        self.write(self.prefix / 'workspaces/acme/inputs/source.sql', 'CUSTOMER-ROW')
        self.write(self.outside_workspaces / 'acme/inputs/source.sql', 'CUSTOMER-ROW')
        self.write(self.prefix / 'intake/acme/forum.sql', 'CUSTOMER-ROW')
        config = self.home / '.config/term-llm'
        self.write(config / 'config.yaml', '\n'.join([
            'default_provider: chatgpt',
            'providers:',
            '  cdck_frontier:',
            '    api_key: $(/usr/local/bin/op-cache read "op://Everybody/Snorlax LLM/credential")',
            '    max_tokens: 4096',
            '  other:',
            f'    api_key: {SECRET}',
            '    token: "abcdefgh12345678"',
            '    password: ""',
            '    url: https://user:hunter2hunter2@example.test/v1',
            f'    headers: {{Authorization: "Bearer {SECRET}"}}',
            '    Authorization: Bearer plainbearervalue123',
            '    client_secret: |',
            '      multilineblocksecret1',
            '      multilineblocksecret2',
            '    after_block: visible-after-block',
            '-----BEGIN OPENSSH PRIVATE KEY-----',
            'b3BlbnNzaC1rZXktdjEAAAAA',
            '-----END OPENSSH PRIVATE KEY-----',
            'export API_KEY=exportedsecretvalue',
            '{"name":"web","token":"minifiedjsonsecret","port":8080}',
            'tokens:',
            '- samelevellistsecret',
            'hub_url: https://hub.example.test/x?token=querysecret123&access_token=querysecret456',
            'Authorization: Bearer',
            '  continuedsecretvalue',
            "quoted_secret: 'single ''escaped'' quotesecrettail'",
            'list_after: visible-after-list',
            'after: visible', '']))
        self.write(config / 'services/web/service.json', json.dumps({'args': ['serve', '--hub-registration-token', 'splitflagsecret', '--port', '18800',
                                                                              '--token=inlineflagsecret', '--auth', 'bearer']}, indent=2))
        self.write(config / 'agents/server-support-local/agent.yaml', 'name: x\n')
        self.write(config / 'chatgpt_oauth.json', '{"access_token": "OAUTH-SECRET"}')
        self.write(config / 'services/web/credentials/TERM_LLM_SERVE_TOKEN', 'SERVE-SECRET')
        self.write(config / 'mcp.json', '{"servers": {}}')
        self.write(config / 'images/agent/upload.png', 'CUSTOMER-IMAGE')
        self.write(config / 'backups/old/config.yaml', 'old')
        (config / 'ws-link').symlink_to(self.prefix / 'workspaces/acme')
        (config / 'agents/tmp-link').symlink_to(self.prefix / 'state/tmp/upload-part')
        self.write(self.home / '.config/op-cache/config.yaml', 'ttl: 86400\n')
        self.write(self.home / '.config/op-cache/notes.txt', 'other')
        self.write(self.home / '.config/silo-migrate/hub.env', 'TERM_LLM_HUB_REGISTRATION_TOKEN=HUB-SECRET\n')

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def call(self, tool, args, agent=None, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('SILO_', 'TERM_LLM_'))}
        env.update(TERM_LLM_TOOL_NAME=tool, TERM_LLM_AGENT_DIR=str(agent or self.agent), SILO_SUPPORT_HOME=str(self.home),
                   SILO_SUPPORT_PREFIX=str(self.prefix), PYTHONDONTWRITEBYTECODE='1')
        env.update(extra)
        result = subprocess.run([sys.executable, '-I', '-B', str((agent or self.agent) / 'scripts/support_tool.py')], input=json.dumps(args),
                                capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('', result.stderr)
        self.assertLess(len(result.stdout.encode()), 48 * 1024)
        return json.loads(result.stdout), result.stdout

    def read(self, path, **extra):
        return self.call('support_read_file', dict(path=str(path), **extra))

    def test_config_is_readable_with_secret_values_redacted_and_references_kept(self):
        result, raw = self.read('~/.config/term-llm/config.yaml')
        text = result['text']
        for secret in (SECRET, 'abcdefgh12345678', 'hunter2hunter2', 'b3BlbnNzaC1rZXktdjEAAAAA', 'plainbearervalue123',
                       'multilineblocksecret', 'exportedsecretvalue', 'minifiedjsonsecret', 'samelevellistsecret', 'querysecret',
                       'continuedsecretvalue', 'quotesecrettail'):
            self.assertNotIn(secret, raw, secret)
        for kept in ('op-cache read "op://Everybody/Snorlax LLM/credential"', 'max_tokens: 4096', 'password: ""', 'after: visible',
                     'after_block: visible-after-block', '"port":8080', 'list_after: visible-after-list', 'https://hub.example.test/x?token='):
            self.assertIn(kept, text, kept)
        self.assertGreaterEqual(result['redactions'], 9)

    def test_service_spec_flags_are_redacted(self):
        result, raw = self.read('~/.config/term-llm/services/web/service.json')
        for secret in ('splitflagsecret', 'inlineflagsecret'):
            self.assertNotIn(secret, raw)
        self.assertIn('"18800"', result['text'])
        self.assertIn('"bearer"', result['text'])

    def test_credentials_are_refused(self):
        for path in ('~/.config/term-llm/chatgpt_oauth.json', '~/.config/term-llm/services/web/credentials/TERM_LLM_SERVE_TOKEN',
                     '~/.config/term-llm/services/web/credentials'):
            with self.subTest(path=path):
                result, raw = self.call('support_list_dir' if path.endswith('credentials') else 'support_read_file', {'path': path})
                self.assertEqual('SUPPORT_PATH_REFUSED_SECRET', result['error'])
                self.assertNotIn('SECRET', raw.replace('SUPPORT_PATH_REFUSED_SECRET', ''))

    def test_only_listed_term_llm_and_op_cache_files(self):
        for path in ('~/.config/term-llm/mcp.json', '~/.config/term-llm/images/agent/upload.png', '~/.config/term-llm/backups/old/config.yaml',
                     '~/.config/term-llm/images', '~/.config/op-cache/notes.txt'):
            with self.subTest(path=path):
                result, raw = self.call('support_list_dir' if '.' not in path.rsplit('/', 1)[1] else 'support_read_file', {'path': path})
                self.assertEqual('SUPPORT_PATH_NOT_ALLOWED', result['error'])
                self.assertNotIn('CUSTOMER-IMAGE', raw)
        self.assertIn('name: x', self.read('~/.config/term-llm/agents/server-support-local/agent.yaml')[0]['text'])

    def test_workspaces_and_service_temp_are_refused_even_through_links(self):
        for path in (self.prefix / 'workspaces/acme/inputs/source.sql', self.prefix / 'workspaces', self.outside_workspaces / 'acme/inputs/source.sql',
                     self.prefix / 'state/tmp/upload-part', self.home / '.config/term-llm/ws-link/inputs/source.sql',
                     self.home / '.config/term-llm/agents/tmp-link', str(self.prefix / 'state') + '/../workspaces/acme/inputs/source.sql',
                     self.prefix / 'intake/acme/forum.sql', self.prefix / 'intake', str(self.prefix / 'state') + '/../intake/acme/forum.sql'):
            with self.subTest(path=path):
                result, raw = self.read(path)
                self.assertEqual('SUPPORT_PATH_REFUSED_CUSTOMER_DATA', result['error'])
                self.assertNotIn('CUSTOMER-ROW', raw)
        self.assertEqual('SUPPORT_PATH_REFUSED_CUSTOMER_DATA', self.call('support_list_dir', {'path': str(self.prefix / 'workspaces')})[0]['error'])
        self.assertEqual('SUPPORT_PATH_REFUSED_CUSTOMER_DATA', self.call('support_list_dir', {'path': str(self.prefix / 'intake')})[0]['error'])

    def test_configured_workspaces_parsing_fails_closed(self):
        inside = self.prefix / 'state/ws'
        self.write(inside / 'acme/source.sql', 'CUSTOMER-ROW')
        for line in (f'SILO_MIGRATE_BASE_PATH="{inside}"', f"export SILO_MIGRATE_BASE_PATH='{inside}'", f'  SILO_MIGRATE_BASE_PATH = {inside}'):
            with self.subTest(line=line):
                self.write(self.prefix / 'etc/silo-control.env', line + '\n')
                self.assertEqual('SUPPORT_PATH_REFUSED_CUSTOMER_DATA', self.read(inside / 'acme/source.sql')[0]['error'])
        for text in ('SILO_CONTROL_GEMS=/x\n', 'SILO_MIGRATE_BASE_PATH=relative\n'):
            with self.subTest(text=text):
                self.write(self.prefix / 'etc/silo-control.env', text)
                self.assertEqual('SUPPORT_PATH_NOT_ALLOWED', self.read(self.prefix / 'state/install-manifest.json')[0]['error'])
        (self.prefix / 'etc/silo-control.env').unlink()
        self.assertEqual('SUPPORT_PATH_NOT_ALLOWED', self.read(self.prefix / 'state/install-manifest.json')[0]['error'])
        self.write(self.prefix / 'etc/silo-control.env', f'SILO_MIGRATE_BASE_PATH={self.outside_workspaces}\n')
        result = self.read(inside / 'acme/source.sql', )[0]
        self.assertEqual('CUSTOMER-ROW', result['text'], 'control setup')
        self.assertEqual('SUPPORT_PATH_REFUSED_CUSTOMER_DATA',
                         self.call('support_read_file', {'path': str(inside / 'acme/source.sql')}, SILO_MIGRATE_BASE_PATH=str(inside))[0]['error'])

    def test_control_env_exception_does_not_follow_a_symlink(self):
        (self.prefix / 'etc/silo-control.env').unlink()
        self.write(self.prefix / 'etc/real-control.env', f'SILO_MIGRATE_BASE_PATH={self.outside_workspaces}\n')
        (self.prefix / 'etc/silo-control.env').symlink_to(self.prefix / 'etc/real-control.env')
        self.assertEqual('SUPPORT_PATH_REFUSED_SECRET', self.read(self.prefix / 'etc/silo-control.env')[0]['error'])

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

    def test_installed_release_ignores_the_test_overrides(self):
        roots = self.call('support_allowed_paths', {}, agent=self.installed_agent, SILO_SUPPORT_PREFIX='/', SILO_SUPPORT_HOME='/')[0]
        account = pwd.getpwuid(os.getuid()).pw_dir
        self.assertIn(os.path.realpath(os.path.join(account, '.config/term-llm')), roots['allowed'])
        self.assertIn(os.path.realpath(self.prefix / 'current'), roots['allowed'])
        self.assertNotIn('/', roots['allowed'])

    def test_allowed_installation_files(self):
        self.assertIn('SILO_MIGRATE_BASE_PATH', self.read(self.prefix / 'etc/silo-control.env')[0]['text'])
        self.assertIn('commit', self.read(self.prefix / 'state/install-manifest.json')[0]['text'])
        self.assertIn('ttl', self.read('~/.config/op-cache/config.yaml')[0]['text'])
        agent = self.read(self.prefix / 'current/integrations/term-llm/server-support/agent.yaml')[0]
        self.assertIn('name: server-support', agent['text'])

    def test_listing_marks_refused_entries_and_stays_bounded(self):
        listing = {entry['name']: entry for entry in self.call('support_list_dir', {'path': '~/.config/term-llm'})[0]['entries']}
        self.assertEqual('SUPPORT_PATH_REFUSED_SECRET', listing['chatgpt_oauth.json']['refused'])
        self.assertEqual('SUPPORT_PATH_REFUSED_CUSTOMER_DATA', listing['ws-link']['refused'])
        self.assertEqual('SUPPORT_PATH_NOT_ALLOWED', listing['mcp.json']['refused'])
        self.assertNotIn('refused', listing['config.yaml'])
        state = {entry['name']: entry for entry in self.call('support_list_dir', {'path': str(self.prefix / 'state')})[0]['entries']}
        self.assertEqual('SUPPORT_PATH_REFUSED_CUSTOMER_DATA', state['tmp']['refused'])
        roots = self.call('support_allowed_paths', {})[0]
        self.assertIn(str(self.outside_workspaces), roots['refused'])
        many = self.prefix / 'state/many'
        many.mkdir()
        for n in range(800):
            (many / (f'{n:04d}-' + 'n' * 80)).write_text('')
        result = self.call('support_list_dir', {'path': str(many)})[0]
        self.assertTrue(result['truncated'])
        self.assertEqual(800, result['total'])

    def test_large_file_is_paged_and_special_files_are_not_read(self):
        big = self.write(self.prefix / 'state/logs/big.json', ''.join(f'line {n} "quoted" \\ value\n' for n in range(1, 20001)))
        first = self.read(big)[0]
        self.assertTrue(first['next_line'])
        second = self.read(big, start_line=first['next_line'])[0]
        self.assertTrue(second['text'].startswith(f"line {first['next_line']} "))
        long_line = self.write(self.prefix / 'state/logs/long.txt', '\x01' * 200_000 + '\nnext line\n')
        result = self.read(long_line)[0]
        self.assertEqual(2, result['lines'])
        self.assertIn('…[line truncated]', result['text'])
        self.assertTrue(result['text'].endswith('next line\n'))
        (self.prefix / 'state/logs/bin.dat').write_bytes(b'\x00\x01secret')
        self.assertEqual(True, self.read(self.prefix / 'state/logs/bin.dat')[0]['binary'])
        os.mkfifo(self.prefix / 'state/logs/pipe')
        self.assertEqual('SUPPORT_NOT_A_FILE', self.read(self.prefix / 'state/logs/pipe')[0]['error'])
        self.assertEqual('SUPPORT_ARGUMENTS_INVALID', self.read(big, start_line=0)[0]['error'])

    def test_unknown_tool_is_refused(self):
        self.assertEqual('SUPPORT_TOOL_UNKNOWN', self.call('support_write_file', {'path': '~/.config/term-llm/config.yaml'})[0]['error'])


if __name__ == '__main__':
    unittest.main()
