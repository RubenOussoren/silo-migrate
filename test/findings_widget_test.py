"""Findings widget tests: a real server on a Unix socket, a synthetic findings store, a fake control.

Run: python3 -I -B test/findings_widget_test.py
"""
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
WIDGET = ROOT / 'integrations/term-llm/widgets/findings'
MARKER = 'CUSTOMER-CANARY-findings'


def load():
    spec = importlib.util.spec_from_file_location('findings_widget', WIDGET / 'server.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost', timeout=20)
        self.path_ = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path_)


def fid(n):
    return 'finding-%032x' % n


class FindingsWidgetTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        top = Path(self.temp.name)
        self.base = top / 'workspaces'
        self.record = top / 'calls.jsonl'
        self.control = top / 'fake-control'
        self.control.write_text('''#!/usr/bin/env python3
import json, os, sys
data = sys.stdin.buffer.read() if '--file' in sys.argv else b''
with open(os.environ['FINDINGS_RECORD'], 'a') as out:
    out.write(json.dumps([sys.argv[1:], data.decode()]) + '\\n')
if os.environ.get('FINDINGS_MODE') == 'busy':
    print('Error: STANDARD_BUSY', file=sys.stderr); sys.exit(1)
action = sys.argv[3]
status = {'release': 'released', 'amend': 'released', 'reject': 'rejected', 'withdraw': 'withdrawn'}[action]
print(json.dumps({'version': 1, 'finding_id': 'finding-' + 'f' * 32 if action == 'amend' else sys.argv[5], 'status': status}))
''')
        self.control.chmod(0o700)
        os.environ.update(FINDINGS_RECORD=str(self.record))
        self.addCleanup(os.environ.pop, 'FINDINGS_RECORD', None)
        self.w = load()
        # arc: 60 proposed + a released chain; acme: one proposed
        findings = {fid(n): {'id': fid(n), 'kind': 'schema', 'status': 'proposed', 'proposed_at': '2026-11-07T00:%02d:00Z' % (n % 60), 'release': None}
                    for n in range(1, 61)}
        findings[fid(100)] = {'id': fid(100), 'kind': 'schema', 'status': 'superseded', 'proposed_at': '2026-11-06T10:00:00Z', 'superseded_by': fid(101),
                              'superseded_at': '2026-11-06T12:00:00Z', 'release': {'sha256': 'a' * 64, 'reviewer': 'Ruben (web UI)', 'released_at': '2026-11-06T11:00:00Z'}}
        findings[fid(101)] = {'id': fid(101), 'kind': 'schema', 'status': 'released', 'proposed_at': '2026-11-06T12:00:00Z', 'supersedes': fid(100),
                              'release': {'sha256': 'b' * 64, 'reviewer': 'Ruben (web UI)', 'released_at': '2026-11-06T12:00:00Z'}}
        self.write_ws('arc', findings)
        self.write_ws('acme', {fid(500): {'id': fid(500), 'kind': 'finding', 'run_id': 'run-' + '1' * 32, 'status': 'proposed', 'proposed_at': '2026-11-07T01:00:00Z'}})
        self.text('arc', fid(7), 'private/proposal.txt', 'SCHEMA FINDING arc seven\nusers: uid int; example user_1\n')
        self.text('arc', fid(100), 'released/summary.txt', 'first version\n')
        self.text('arc', fid(101), 'released/summary.txt', 'second version: -2 are drafts\n')
        self.text('acme', fid(500), 'private/proposal.txt', MARKER + ' cause\n')
        (self.base / 'notes').mkdir()  # not a workspace
        self.socket = str(top / 'w.sock')
        self.server = self.w.Server(self.socket, self.w.Handler)
        self.server.store, self.server.control = self.w.Store(self.base), str(self.control)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def write_ws(self, name, findings):
        standard = self.base / name / '.silo-migrate/named/standard'
        standard.mkdir(parents=True)
        (standard / 'state.json').write_text(json.dumps({'findings': findings, 'runs': {}}))

    def text(self, ws, finding, relative, text):
        path = self.base / ws / '.silo-migrate/named/standard/findings' / finding / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def request(self, method, path, body=None, headers=None):
        connection = UnixConnection(self.socket)
        data = json.dumps(body).encode() if body is not None else None
        sent = {'Content-Type': 'application/json', 'X-Silo-Findings': '1'} if method == 'POST' else {}
        sent.update(headers or {})
        connection.request(method, path, body=data, headers=sent)
        response = connection.getresponse()
        raw = response.read()
        connection.close()
        return response.status, raw, response

    def get(self, path):
        status, raw, _ = self.request('GET', path)
        return status, json.loads(raw)

    def calls(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []

    def test_summary_counts_pending_without_any_text(self):
        status, data = self.get('/api/summary')
        self.assertEqual(200, status)
        self.assertEqual(61, data['pending'])
        self.assertEqual([{'workspace': 'acme', 'pending': 1}, {'workspace': 'arc', 'pending': 60}], data['workspaces'])
        self.assertEqual(8, len(data['latest']))
        self.assertEqual(fid(500), data['latest'][0]['id'])  # newest first
        self.assertNotIn(MARKER, json.dumps(data))
        self.assertNotIn('title', data['latest'][0])

    def test_many_findings_are_paged_filtered_and_searchable(self):
        status, page = self.get('/api/findings?status=proposed&workspace=arc')
        self.assertEqual((200, 60, 3, 25), (status, page['total'], page['pages'], len(page['items'])))
        self.assertEqual(['acme', 'arc'], page['workspaces'])
        last = self.get('/api/findings?status=proposed&workspace=arc&page=2')[1]
        self.assertEqual(10, len(last['items']))
        history = self.get('/api/findings?status=history')[1]
        self.assertEqual([fid(101), fid(100)], [item['id'] for item in history['items']])
        self.assertEqual('second version: -2 are drafts', history['items'][0]['title'])
        found = self.get('/api/findings?status=all&q=arc%20seven')[1]
        self.assertEqual([fid(7)], [item['id'] for item in found['items']])
        self.assertEqual(400, self.get('/api/findings?status=bogus')[0])
        self.assertEqual(400, self.get('/api/findings?page=x')[0])

    def test_detail_shows_texts_and_the_version_chain(self):
        status, record = self.get('/api/finding?workspace=arc&id=' + fid(101))
        self.assertEqual(200, status)
        self.assertEqual('second version: -2 are drafts\n', record['released'])
        self.assertIsNone(record['proposal'])
        self.assertEqual([fid(100), fid(101)], [v['id'] for v in record['versions']])
        self.assertEqual([fid(100), fid(101)], [v['id'] for v in self.get('/api/finding?workspace=arc&id=' + fid(100))[1]['versions']])
        for bad in ('workspace=../x&id=' + fid(1), 'workspace=arc&id=finding-1', 'workspace=arc&id=' + fid(999), 'workspace=nope&id=' + fid(1)):
            with self.subTest(query=bad):
                self.assertIn(self.get('/api/finding?' + bad)[0], (400, 404))

    def test_release_sends_the_exact_text_and_its_digest(self):
        text = 'Edited: -2 = drafts, not migrated.\nExample: user_1 ☃\n'
        status, raw, _ = self.request('POST', '/api/release', {'workspace': 'arc', 'id': fid(7), 'text': text})
        self.assertEqual(200, status, raw)
        (argv, stdin), = self.calls()
        digest = hashlib.sha256(text.encode('utf-8')).hexdigest()
        self.assertEqual(['standard', 'finding', 'release', 'arc', fid(7), '--file', '-', '--sha256', digest, '--reviewer'], argv[:10])
        self.assertTrue(argv[10].endswith('(web UI)'))
        self.assertEqual(text, stdin)

    def test_amend_reject_withdraw_and_refusals(self):
        self.assertEqual('finding-' + 'f' * 32, json.loads(self.request('POST', '/api/amend', {'workspace': 'arc', 'id': fid(101), 'text': 'v3'})[1])['finding_id'])
        self.request('POST', '/api/reject', {'workspace': 'arc', 'id': fid(8)})
        self.request('POST', '/api/withdraw', {'workspace': 'arc', 'id': fid(101)})
        self.assertEqual(['amend', 'reject', 'withdraw'], [argv[2] for argv, _ in self.calls()])
        self.assertEqual(['--reviewer'], self.calls()[1][0][5:6])
        self.record.unlink()
        refusals = [
            ({'workspace': 'arc', 'id': fid(7), 'text': 'x'}, {'X-Silo-Findings': ''}, 403),             # no page header
            ({'workspace': 'arc', 'id': fid(7), 'text': 'x'}, {'Content-Type': 'text/plain'}, 403),     # not JSON
            ({'workspace': 'arc', 'id': fid(7), 'text': '  '}, {}, 400),                                 # empty text
            ({'workspace': 'arc', 'id': fid(7), 'text': 'a\x00b'}, {}, 400),
            ({'workspace': '../arc', 'id': fid(7), 'text': 'x'}, {}, 400),
            ({'workspace': 'arc', 'id': 'finding-x', 'text': 'x'}, {}, 400),
            ({'workspace': 'arc', 'id': fid(7), 'text': 'x' * (256 * 1024 + 1)}, {}, 400),
            ({'workspace': 'arc', 'id': fid(7), 'text': '\u2603' * (90 * 1024)}, {}, 400),             # 270 KiB once UTF-8 encoded
        ]
        for body, headers, expected in refusals:
            with self.subTest(body=str(body)[:60], headers=headers):
                self.assertEqual(expected, self.request('POST', '/api/release', body, headers)[0])
        self.assertEqual(400, self.request('POST', '/api/delete', {'workspace': 'arc', 'id': fid(7)})[0])
        # A body announced beyond any possible finding is refused before reading it.
        raw = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        raw.connect(self.socket)
        raw.sendall(b'POST /api/release HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nX-Silo-Findings: 1\r\nContent-Length: 99999999\r\n\r\n')
        self.assertTrue(raw.recv(4096).startswith(b'HTTP/1.0 413'))
        raw.close()
        self.assertEqual([], self.calls())
        os.environ['FINDINGS_MODE'] = 'busy'
        self.addCleanup(os.environ.pop, 'FINDINGS_MODE', None)
        status, raw, _ = self.request('POST', '/api/reject', {'workspace': 'arc', 'id': fid(9)})
        self.assertEqual((409, 'STANDARD_BUSY'), (status, json.loads(raw)['error']))

    def test_links_and_odd_files_are_refused_not_followed(self):
        outside = Path(self.temp.name) / 'outside'
        outside.mkdir()
        (outside / 'secret.txt').write_text(MARKER)
        target = self.base / 'arc/.silo-migrate/named/standard/findings' / fid(9) / 'private'
        target.mkdir(parents=True)
        (target / 'proposal.txt').symlink_to(outside / 'secret.txt')
        status, raw, _ = self.request('GET', '/api/finding?workspace=arc&id=' + fid(9))
        self.assertEqual(200, status)
        self.assertIsNone(json.loads(raw)['proposal'])
        self.assertNotIn(MARKER, raw.decode())
        # A linked folder on the way is refused too.
        (target / 'proposal.txt').unlink()
        target.rmdir()
        (outside / 'proposal.txt').write_text(MARKER)
        target.symlink_to(outside)
        status, raw, _ = self.request('GET', '/api/finding?workspace=arc&id=' + fid(9))
        self.assertNotIn(MARKER, raw.decode())
        (self.base / 'linked').symlink_to(self.base / 'acme')
        self.assertNotIn('linked', self.get('/api/summary')[1]['workspaces'])
        self.assertEqual(404, self.get('/api/finding?workspace=linked&id=' + fid(500))[0])

    def test_page_assets_and_headers(self):
        status, raw, response = self.request('GET', '/')
        self.assertEqual(200, status)
        self.assertIn(b'app.js', raw)
        self.assertIn("script-src 'self'", response.getheader('Content-Security-Policy'))
        self.assertEqual('no-store', response.getheader('Cache-Control'))
        for asset in ('/app.js', '/app.css'):
            self.assertEqual(200, self.request('GET', asset)[0])
        self.assertEqual(404, self.request('GET', '/server.py')[0])
        self.assertEqual(404, self.request('GET', '/../widget.yaml')[0])
        # The page inserts server text as text, never as HTML.
        script = (WIDGET / 'app.js').read_text()
        self.assertNotIn('innerHTML', script)
        self.assertNotIn('innerHTML', (ROOT / 'integrations/term-llm/extensions/silo-findings/main.js').read_text())

    def test_reviewer_is_the_commit_identity(self):
        home = Path(self.temp.name) / 'home'
        (home / '.config/silo-migrate').mkdir(parents=True)
        (home / '.config/silo-migrate/git-identity').write_text('name=Ruben Example\nemail=r@example.invalid\n')
        import pwd as pwd_module
        real = pwd_module.getpwuid(os.getuid())
        fake = pwd_module.struct_passwd((real.pw_name, 'x', real.pw_uid, real.pw_gid, '', str(home), '/bin/bash'))
        from unittest import mock
        with mock.patch.object(self.w.pwd, 'getpwuid', return_value=fake):
            self.assertEqual('Ruben Example (web UI)', self.w.reviewer_name())
        (home / '.config/silo-migrate/git-identity').write_text('name=\x1b[31mevil\n')
        with mock.patch.object(self.w.pwd, 'getpwuid', return_value=fake):
            self.assertEqual('engineer (web UI)', self.w.reviewer_name())

    def test_refuses_to_start_in_a_socket_folder_that_isnt_private(self):
        from unittest import mock
        shared = Path(self.temp.name) / 'shared'
        shared.mkdir(mode=0o755)
        shared.chmod(0o755)
        env = {'SILO_TESTING': '1', 'SILO_FINDINGS_CONTROL': str(self.control), 'SILO_FINDINGS_BASE': str(self.base)}
        with mock.patch.dict(os.environ, env), self.assertRaisesRegex(SystemExit, 'mode 0700'):
            self.w.main(['server.py', str(shared / 'findings.sock')])
        self.assertFalse((shared / 'findings.sock').exists())
        with self.assertRaises(SystemExit):
            self.w.main(['server.py', 'relative.sock'])

    def test_manifest_uses_a_socket_and_the_extension_only_reads(self):
        manifest = (WIDGET / 'widget.yaml').read_text()
        self.assertIn('"$SOCKET"', manifest)
        self.assertNotIn('$PORT', manifest)
        extension = (ROOT / 'integrations/term-llm/extensions/silo-findings/main.js').read_text()
        self.assertIn('api/summary', extension)
        self.assertNotIn("method: 'POST'", extension)


if __name__ == '__main__':
    unittest.main()
