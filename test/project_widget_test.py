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

    def test_runs_and_findings_decisions_go_to_their_own_unchanged_logic(self):
        calls = []
        self.m.runs.decide = lambda store, control, action, body: calls.append(('runs', action, body)) or {'status': 'ok'}
        self.m.findings.decide = lambda control, action, workspace, finding_id, text: calls.append(('findings', action, workspace, finding_id, text)) or {'status': 'ok'}
        headers = {'X-Silo-Project': '1', 'Content-Type': 'application/json'}
        for action in self.m.RUN_ACTIONS:
            self.assertEqual(200, self.request('POST', '/api/runs/' + action, {'workspace': 'arc', 'plan_id': 'p'}, headers)[0])
        for action in self.m.FINDING_ACTIONS:
            self.assertEqual(200, self.request('POST', '/api/findings/' + action, {'workspace': 'arc', 'id': 'f', 'text': 't'}, headers)[0])
        self.assertEqual(len(self.m.RUN_ACTIONS) + len(self.m.FINDING_ACTIONS), len(calls))
        self.assertEqual(('runs', 'approve', {'workspace': 'arc', 'plan_id': 'p'}), calls[0])
        self.assertEqual(('findings', 'release', 'arc', 'f', 't'), calls[len(self.m.RUN_ACTIONS)])
        for path in ('/api/runs/approve-all', '/api/findings/delete', '/api/runs/../label', '/api/other/approve'):
            self.assertEqual(400, self.request('POST', path, {'workspace': 'arc'}, headers)[0])
        self.assertEqual(403, self.request('POST', '/api/runs/approve', {'workspace': 'arc'}, {'Content-Type': 'application/json', 'X-Silo-Runs': '1'})[0])
        self.assertEqual(len(self.m.RUN_ACTIONS) + len(self.m.FINDING_ACTIONS), len(calls))

    def test_run_again_and_import_reuse_the_runs_own_inputs_and_only_propose(self):
        base = self.base / 'arc/.silo-migrate/named/standard'
        base.mkdir(parents=True)
        convert = {'operation': 'standard_convert', 'roles': {'source': 'input-1', 'settings': 'input-2', 'reconciliation': 'input-3'}, 'source_charset': 'latin1'}
        review = {'operation': 'standard_review', 'from_run': {'run_id': 'run-' + 'a' * 32}, 'roles': {'reconciliation': 'input-4'}}
        state = {'plans': {'plan-' + 'a' * 32: {'body': convert, 'created_at': '1'}, 'plan-' + 'b' * 32: {'body': review, 'created_at': '2'}},
                 'runs': {'run-' + 'a' * 32: {'plan_id': 'plan-' + 'a' * 32}, 'run-' + 'b' * 32: {'plan_id': 'plan-' + 'b' * 32}}}
        (base / 'state.json').write_text(json.dumps(state))
        headers = {'X-Silo-Project': '1', 'Content-Type': 'application/json'}
        self.assertEqual(200, self.request('POST', '/api/runs/again', {'workspace': 'arc', 'run_id': 'run-' + 'a' * 32}, headers)[0])
        self.assertEqual(200, self.request('POST', '/api/runs/again', {'workspace': 'arc', 'run_id': 'run-' + 'b' * 32}, headers)[0])
        self.assertEqual(200, self.request('POST', '/api/runs/import', {'workspace': 'arc', 'run_id': 'run-' + 'a' * 32}, headers)[0])
        self.assertEqual(400, self.request('POST', '/api/runs/import', {'workspace': 'arc', 'run_id': 'run-' + 'b' * 32}, headers)[0])  # only from a convert run
        self.assertEqual(400, self.request('POST', '/api/runs/again', {'workspace': 'arc', 'run_id': 'x'}, headers)[0])
        requests = [request for _argv, request in self.calls()]
        self.assertEqual({'op': 'plan_propose', 'source': 'input-1', 'settings': 'input-2', 'charset': 'latin1', 'reconciliation': 'input-3'}, requests[0])
        self.assertEqual({'op': 'plan_propose', 'from_run': 'run-' + 'a' * 32, 'reconciliation': 'input-4'}, requests[1])
        self.assertEqual({'op': 'plan_propose', 'from_run': 'run-' + 'a' * 32, 'reconciliation': 'input-4'}, requests[2])
        self.assertEqual(3, len(requests))

    def test_marking_done_sends_only_the_finding_and_the_servers_reviewer(self):
        headers = {'X-Silo-Project': '1', 'Content-Type': 'application/json'}
        self.assertEqual(200, self.request('POST', '/api/findings/done', {'workspace': 'arc', 'id': 'finding-' + 'a' * 32, 'by': 'Other', 'undo': 'yes'}, headers)[0])
        self.assertEqual({'op': 'finding_done', 'finding_id': 'finding-' + 'a' * 32, 'by': self.m.runs.reviewer_name()}, self.calls()[-1][1])
        self.assertEqual(400, self.request('POST', '/api/findings/done', {'workspace': 'arc', 'id': 'x'}, headers)[0])

    def test_findings_are_shown_one_project_at_a_time(self):
        for query in ('', 'workspace=', 'workspace=../x'):
            self.assertEqual(400, self.request('GET', '/api/findings/list?' + query)[0])
        status, data, _ = self.request('GET', '/api/findings/list?workspace=arc')
        self.assertEqual((200, 0), (status, json.loads(data)['total']))  # nothing proposed in this fixture

    def test_counts_never_fail_for_a_new_project(self):
        self.assertEqual({'findings': 0, 'runs': 0}, json.loads(self.request('GET', '/api/counts?workspace=new-forum')[1]))
        self.assertEqual(400, self.request('GET', '/api/counts?workspace=../x')[0])

    def test_the_page_builds_with_dom_calls_only(self):
        for name in ('app.js', 'ui.js', 'runs.js', 'findings.js'):
            source = (WIDGET / name).read_text()
            for word in ('innerHTML', 'insertAdjacentHTML', 'document.write', 'https://', 'eval('):
                self.assertNotIn(word, source, name)
        self.assertNotIn('http://', (WIDGET / 'app.js').read_text())
        self.assertNotIn('//', (WIDGET / 'tokens.css').read_text().replace('/*', ''))


if __name__ == '__main__':
    unittest.main()
