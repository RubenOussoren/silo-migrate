"""Project page backend. Run: python3 -I -B test/project_widget_test.py."""
import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
WIDGET = ROOT / 'integrations/term-llm/widgets/project'


def load():
    spec = importlib.util.spec_from_file_location('project_widget', WIDGET / 'server.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Conn(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('local')
        self.unix = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.unix)


class ProjectWidgetTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        top = Path(self.temp.name)
        self.base = top / 'workspaces'
        (self.base / 'arc').mkdir(parents=True)
        (top / 'intake/new-forum').mkdir(parents=True)
        (top / 'intake/.hidden').mkdir()
        (self.base / 'link').symlink_to(self.base / 'arc')
        self.record = top / 'calls.jsonl'
        self.control = top / 'control'
        self.control.write_text('''#!/usr/bin/env python3
import json, os, sys
request = json.loads(sys.stdin.read())
with open(os.environ['CALLS'], 'a') as out:
    out.write(json.dumps([sys.argv[1:], request]) + '\\n')
if os.environ.get('REFUSE'):
    print('Error: ' + os.environ['REFUSE'], file=sys.stderr)
    sys.exit(1)
print(json.dumps({'version': 1, 'unlabelled_files': [{'path': 'a.sql'}] if sys.argv[2] == 'new-forum' else [], 'unlabelled_data': [], 'delivery': 'Development v1'}))
''')
        self.control.chmod(0o700)
        os.environ['CALLS'] = str(self.record)
        self.addCleanup(os.environ.pop, 'CALLS', None)
        self.m = load()
        self.socket = str(top / 'w.sock')
        self.server = self.m.Server(self.socket, self.m.Handler)
        self.server.control, self.server.base = str(self.control), self.base
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self, method, path, body=None, headers=None):
        conn = Conn(self.socket)
        payload = json.dumps(body) if body is not None else None
        conn.request(method, path, payload, headers or {})
        response = conn.getresponse()
        data = response.read()
        conn.close()
        return response.status, data, response

    def post(self, body, headers=None):
        return self.request('POST', '/api/label', body, {'X-Silo-Project': '1', 'Content-Type': 'application/json'} if headers is None else headers)

    def calls(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []

    def test_lists_workspaces_and_new_projects_but_nothing_else(self):
        status, data, _ = self.request('GET', '/api/projects')
        self.assertEqual(200, status)
        self.assertEqual(['arc', 'new-forum'], json.loads(data)['projects'])

    def test_a_label_passes_only_known_fields_and_the_servers_reviewer_name(self):
        status, _data, _ = self.post({'workspace': 'arc', 'kind': 'development', 'by': 'Someone Else', 'op': 'db_reset', 'via': 'x',
                                      'files': [{'path': 'a.sql', 'bytes': 1, 'mtime_ns': '2', 'ctime_ns': '3', 'ino': '4', 'extra': 'x'}]})
        self.assertEqual(200, status)
        (argv, request), = self.calls()
        self.assertEqual(['data', 'arc'], argv)
        self.assertEqual({'op': 'delivery_label', 'kind': 'development', 'by': self.m.runs.reviewer_name(), 'files': [{'path': 'a.sql', 'bytes': 1, 'mtime_ns': '2', 'ctime_ns': '3', 'ino': '4'}]}, request)

    def test_launch_flags_pass_only_in_their_exact_form(self):
        self.post({'workspace': 'arc', 'kind': 'launch', 'files': [{'path': 'a'}], 'confirm': 'yes', 'replaces_launch': 'true'})
        self.assertNotIn('confirm', self.calls()[0][1])
        self.assertNotIn('replaces_launch', self.calls()[0][1])
        self.post({'workspace': 'arc', 'kind': 'launch', 'files': [{'path': 'a'}], 'confirm': 'LAUNCH', 'replaces_launch': True})
        self.assertEqual('LAUNCH', self.calls()[1][1]['confirm'])
        self.assertIs(True, self.calls()[1][1]['replaces_launch'])

    def test_a_post_needs_the_pages_header_and_valid_shapes(self):
        self.assertEqual(403, self.post({'workspace': 'arc', 'kind': 'development', 'files': [{}]}, {'Content-Type': 'application/json'})[0])
        for body in ({'workspace': '../x', 'kind': 'development', 'files': [{}]}, {'workspace': 'arc', 'kind': 'development', 'files': []},
                     {'workspace': 'arc', 'kind': 'development', 'files': 'x'}, {'workspace': 'arc', 'kind': 'development', 'dataset_id': 'x'}):
            with self.subTest(body=body):
                self.assertEqual(400, self.post(body)[0])
        self.assertEqual([], self.calls())

    def test_only_the_label_action_exists(self):
        conn = self.request('POST', '/api/release', {'workspace': 'arc'}, {'X-Silo-Project': '1', 'Content-Type': 'application/json'})
        self.assertEqual(400, conn[0])

    def test_summary_counts_projects_with_files_to_label(self):
        self.assertEqual({'waiting': 1, 'latest': [{'workspace': 'new-forum', 'files': 1}]}, json.loads(self.request('GET', '/api/summary')[1]))

    def test_a_refusal_keeps_its_code(self):
        os.environ['REFUSE'] = 'STANDARD_DELIVERY_FILES_CHANGED: the files changed'
        self.addCleanup(os.environ.pop, 'REFUSE', None)
        status, data, _ = self.post({'workspace': 'arc', 'kind': 'development', 'files': [{'path': 'a'}]})
        self.assertEqual(409, status)
        self.assertIn('STANDARD_DELIVERY_FILES_CHANGED', json.loads(data)['error'])

    def test_serves_the_page_and_varnish_fonts_with_a_strict_policy(self):
        status, _data, response = self.request('GET', '/')
        self.assertEqual(200, status)
        policy = response.getheader('Content-Security-Policy')
        self.assertIn("default-src 'none'", policy)
        self.assertIn("font-src 'self'", policy)
        status, data, response = self.request('GET', '/fonts/Geist-Variable.woff2')
        self.assertEqual((200, 'font/woff2'), (status, response.getheader('Content-Type')))
        self.assertEqual(data, (ROOT / 'integrations/term-llm/extensions/varnish/fonts/Geist-Variable.woff2').read_bytes())
        self.assertEqual(404, self.request('GET', '/fonts/../server.py')[0])

    def test_the_page_builds_with_dom_calls_only(self):
        source = (WIDGET / 'app.js').read_text()
        for word in ('innerHTML', 'insertAdjacentHTML', 'document.write', 'http://', 'https://', 'eval('):
            self.assertNotIn(word, source)
        self.assertNotIn('//', (WIDGET / 'tokens.css').read_text().replace('/*', ''))


if __name__ == '__main__':
    unittest.main()
