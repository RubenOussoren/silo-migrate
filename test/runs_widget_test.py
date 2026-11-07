"""Runs widget tests: a real server on a Unix socket, synthetic standard/named stores, a fake control.

Run: python3 -I -B test/runs_widget_test.py
"""
import base64
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
WIDGET = ROOT / 'integrations/term-llm/widgets/runs'
MARKER = 'CUSTOMER-CANARY-runs'


def load():
    spec = importlib.util.spec_from_file_location('runs_widget', WIDGET / 'server.py')
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


def pid(n):
    return 'plan-%032x' % n


def rid(n):
    return 'run-%032x' % n


SETTINGS = 'database:\n  password: "${SILO_DB_PASSWORD}"\n  table_prefix: "mybb_"\nimport:\n  site_url: "https://' + MARKER + '.example.invalid"\n'
CHECKS = json.dumps({'version': 1, 'checks': [{'name': 'users', 'source_sql': 'SELECT COUNT(*) FROM mybb_users', 'intermediate_sql': 'SELECT COUNT(*) FROM users'}]})


class RunsWidgetTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        top = Path(self.temp.name)
        self.base = top / 'workspaces'
        self.record = top / 'calls.jsonl'
        self.control = top / 'fake-control'
        self.control.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['RUNS_RECORD'], 'a') as out:
    out.write(json.dumps(args) + '\\n')
mode = os.environ.get('RUNS_MODE', '')
if mode == 'refuse':
    print('Error: STANDARD_RECONCILIATION_INVALID: check 3: source_sql. The reconciliation input is invalid.', file=sys.stderr); sys.exit(1)
if mode == 'garbage':
    print('Traceback (most recent call last): ' + os.environ['RUNS_MARKER'], file=sys.stderr); sys.exit(1)
if mode == 'slow':
    import subprocess, time
    # A grandchild that would finish the job later: it must be stopped with the call.
    subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(2); open(%r, "w").write("finished")' % os.environ['RUNS_LATE']])
    time.sleep(30)
if args[:2] == ['standard', 'status']:
    print(json.dumps({'version': 1, 'plans': [
        {'plan_id': 'plan-%032x' % 1, 'digest': 'a' * 64, 'status': 'proposed', 'created_at': '2026-11-07T10:00:00Z'},
        {'plan_id': 'plan-%032x' % 2, 'digest': 'b' * 64, 'status': 'stale', 'created_at': '2026-11-07T09:00:00Z'}],
        'runs': [{'run_id': 'run-%032x' % 1, 'status': 'completed', 'stages': {}, 'results': {'reconciliation_checks': 1}}]}))
elif args[:3] == ['standard', 'plan', 'show']:
    print(json.dumps({'version': 1, 'plan_id': args[4], 'digest': 'a' * 64, 'status': 'proposed', 'operation': 'standard_convert',
                      'roles': {'source': 'input-%032x' % 1, 'settings': 'input-%032x' % 2, 'reconciliation': 'input-%032x' % 3},
                      'inputs': [], 'converter': {'branch': 'migration/arc/mybb-converter'}}))
elif args[:3] == ['standard', 'run', 'show']:
    print(json.dumps({'version': 1, 'run_id': args[4], 'status': 'completed', 'stages': {'convert': 'passed'},
                      'results': {'reconciliation_checks': 1, 'reconciliation_matched': 0, 'reconciliation_differs': 1, 'reconciliation_errors': 0}}))
elif args[:2] == ['converter', 'log']:
    print(json.dumps({'version': 1, 'workspace': args[2], 'branch': 'migration/arc/mybb-core-conversion', 'head': '7' * 40, 'uncommitted': 2,
                      'not_pushed': 2, 'ahead_of_main': 2, 'commits': [{'sha': '7' * 40, 'subject': 'Add validated MyBB converter foundations', 'pushed': False}],
                      'branches': [{'name': 'migration/arc/mybb-converter', 'head': '7' * 40, 'not_pushed': 2, 'on_github': False}]}))
elif args[0] == 'start-run':
    print(json.dumps({'version': 1, 'plan_id': args[2], 'run_id': 'run-' + 'e' * 32, 'status': 'claimed'}))
    print('detached')
else:
    print(json.dumps({'version': 1, 'status': 'ok', 'args': args}))
''')
        self.control.chmod(0o700)
        os.environ.update(RUNS_RECORD=str(self.record), RUNS_MARKER=MARKER)
        self.addCleanup(os.environ.pop, 'RUNS_RECORD', None)
        self.addCleanup(os.environ.pop, 'RUNS_MODE', None)
        self.w = load()
        self.make_workspace()
        self.socket = str(top / 'w.sock')
        self.server = self.w.Server(self.socket, self.w.Handler)
        self.server.store, self.server.control = self.w.Store(self.base), str(self.control)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def make_workspace(self):
        root = self.base / 'arc'
        standard = root / '.silo-migrate/named/standard'
        standard.mkdir(parents=True)
        files = {'input-%032x' % 1: ('inputs/arc.sql.gz', b'\x1f\x8b dump ' + MARKER.encode(), 'mysql-dump'),
                 'input-%032x' % 2: ('inputs/derived/settings.yml', SETTINGS.encode(), 'converter-settings'),
                 'input-%032x' % 3: ('inputs/derived/checks.json', CHECKS.encode(), 'reconciliation')}
        inputs, binding = {}, []
        for input_id, (relative, data, kind) in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()
            inputs[input_id] = {'id': input_id, 'path': base64.b64encode(relative.encode()).decode(), 'sha256': digest, 'bytes': len(data), 'type': kind}
            binding.append({'id': input_id, 'sha256': digest, 'bytes': len(data), 'type': kind})
        (root / '.silo-migrate/named/state.json').write_text(json.dumps({'inputs': inputs}))
        body = {'operation': 'standard_convert', 'platform': 'mybb', 'input_binding': binding,
                'roles': {'source': 'input-%032x' % 1, 'settings': 'input-%032x' % 2, 'reconciliation': 'input-%032x' % 3},
                'limits': {'db': {'cpus': 2.0, 'memory_mib': 8192}, 'converter': {'cpus': 2.0, 'memory_mib': 8192}}}
        plans = {pid(1): {'id': pid(1), 'status': 'proposed', 'created_at': '2026-11-07T10:00:00Z', 'body': body},
                 pid(2): {'id': pid(2), 'status': 'approved', 'created_at': '2026-11-07T09:00:00Z', 'body': body},
                 pid(3): {'id': pid(3), 'status': 'consumed', 'created_at': '2026-11-06T09:00:00Z', 'body': body}}
        runs = {rid(1): {'id': rid(1), 'status': 'completed', 'started_at': '2026-11-06T09:01:00Z',
                         'results': {'reconciliation': [{'name': 'users', 'source': 1234, 'intermediate': 1233, 'status': 'differs'}]}},
                rid(2): {'id': rid(2), 'status': 'running', 'stage': 'convert', 'started_at': '2026-11-07T11:00:00Z', 'results': {}}}
        (standard / 'state.json').write_text(json.dumps({'plans': plans, 'runs': runs, 'findings': {}}))
        evidence = standard / 'runs' / rid(1) / 'evidence'
        evidence.mkdir(parents=True)
        (evidence / 'conversion-summary.txt').write_text('Errors : 0 (conversion) + 0 (setup)\n')
        pushes = standard / 'converter-pushes'
        pushes.mkdir()
        for digest, status, pull in (('c' * 64, 'proposed', None), ('d' * 64, 'pushed', {'number': 7, 'url': 'https://github.com/discourse-org/discourse-converters/pull/7'}),
                                     ('f' * 64, 'pushed', {'number': 8, 'url': 'javascript:alert(1)'})):
            record = {'digest': digest, 'status': status, 'proposed_at': '2026-11-07T08:00:00Z', 'pull_request': pull,
                      'proposal': {'title': 'Add MyBB users step', 'body': 'Why', 'branch': 'migration/arc/mybb-converter', 'base': 'main',
                                   'head': '1' * 40, 'repository': 'discourse-org/discourse-converters', 'commits': ['abc Add users'],
                                   'files': ['A\tconverters/mybb/steps/users.rb'], 'files_total': 1, 'stat': ' 1 file changed'}}
            (pushes / (digest + '.json')).write_text(json.dumps(record))
        (self.base / 'notes').mkdir()  # not a workspace

    def request(self, method, path, body=None, headers=None):
        connection = UnixConnection(self.socket)
        data = json.dumps(body).encode() if body is not None else None
        sent = {'Content-Type': 'application/json', 'X-Silo-Runs': '1'} if method == 'POST' else {}
        sent.update(headers or {})
        connection.request(method, path, body=data, headers=sent)
        response = connection.getresponse()
        raw = response.read()
        connection.close()
        return response.status, raw, response

    def get(self, path):
        status, raw, _ = self.request('GET', path)
        return status, json.loads(raw)

    def post(self, action, **body):
        status, raw, _ = self.request('POST', '/api/' + action, dict(workspace='arc', **body))
        return status, json.loads(raw)

    def calls(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []

    def test_summary_counts_from_disk_without_any_text_or_control_call(self):
        status, data = self.get('/api/summary')
        self.assertEqual(200, status)
        self.assertEqual(3, data['waiting'])  # proposed plan, approved plan, proposed push
        self.assertEqual(1, data['running'])
        self.assertEqual([{'workspace': 'arc', 'waiting': 3, 'running': 1}], data['workspaces'])
        self.assertEqual({('plan', 'proposed'), ('plan', 'approved'), ('push', 'proposed')}, {(i['kind'], i['status']) for i in data['latest']})
        for item in data['latest']:
            self.assertEqual({'kind', 'workspace', 'id', 'status', 'at'}, set(item))
        self.assertEqual([{'kind': 'run', 'workspace': 'arc', 'id': rid(2), 'status': 'running', 'stage': 'convert', 'at': '2026-11-07T11:00:00Z'}], data['active'])
        raw = json.dumps(data)
        self.assertNotIn(MARKER, raw)
        self.assertNotIn('Add MyBB users step', raw)
        self.assertNotIn('1234', raw)
        self.assertEqual([], self.calls())

    def test_overview_joins_control_status_with_disk(self):
        status, data = self.get('/api/overview?workspace=arc')
        self.assertEqual(200, status)
        self.assertEqual([['standard', 'status', 'arc'], ['converter', 'log', 'arc']], self.calls())
        self.assertEqual({'branch': 'migration/arc/mybb-core-conversion', 'head': '7' * 40, 'uncommitted': 2, 'not_pushed': 2, 'ahead_of_main': 2},
                         data['converter'])
        self.assertEqual(['proposed', 'stale'], [p['status'] for p in data['plans']])
        self.assertEqual(['standard_convert', 'standard_convert'], [p['operation'] for p in data['plans']])
        self.assertEqual('mybb', data['plans'][0]['platform'])
        self.assertEqual(['arc'], data['workspaces'])
        self.assertEqual({'c' * 64: None, 'd' * 64: 'https://github.com/discourse-org/discourse-converters/pull/7', 'f' * 64: None},
                         {p['digest']: (p['pull_request'] or {}).get('url') for p in data['pushes']})

    def test_plan_detail_shows_the_bound_settings_and_checks(self):
        status, data = self.get('/api/plan?workspace=arc&id=' + pid(1))
        self.assertEqual(200, status)
        self.assertEqual(SETTINGS, data['texts']['settings'])
        self.assertEqual(CHECKS, data['texts']['reconciliation'])
        self.assertEqual('inputs/derived/settings.yml', data['input_paths']['input-%032x' % 2])
        self.assertEqual(8192, data['limits']['db']['memory_mib'])
        self.assertNotIn('dump', json.dumps(data['texts']))  # the dump itself is never read
        # Changed since the plan: not shown as if it were what the plan binds.
        path = self.base / 'arc/inputs/derived/settings.yml'
        path.write_text(SETTINGS + '# edited\n')
        self.assertIsNone(self.get('/api/plan?workspace=arc&id=' + pid(1))[1]['texts']['settings'])

    def test_run_and_push_details(self):
        status, run = self.get('/api/run?workspace=arc&id=' + rid(1))
        self.assertEqual(200, status)
        self.assertEqual([{'name': 'users', 'source': 1234, 'intermediate': 1233, 'status': 'differs'}], run['reconciliation'])
        self.assertIn('Errors : 0', run['conversion_summary'])
        status, push = self.get('/api/push?workspace=arc&id=' + 'c' * 64)
        self.assertEqual(200, status)
        self.assertEqual(['A\tconverters/mybb/steps/users.rb'], push['files'])
        self.assertEqual('main', push['base'])
        self.assertIsNone(self.get('/api/push?workspace=arc&id=' + 'f' * 64)[1]['pull_request']['url'])
        self.assertEqual(404, self.get('/api/push?workspace=arc&id=' + 'e' * 64)[0])
        self.assertEqual(400, self.get('/api/run?workspace=arc&id=run-1')[0])

    def test_converter_view_is_read_only_and_survives_a_refusal(self):
        status, data = self.get('/api/converter?workspace=arc&id=arc')
        self.assertEqual(200, status)
        self.assertEqual('Add validated MyBB converter foundations', data['commits'][0]['subject'])
        self.assertEqual([['converter', 'log', 'arc']], self.calls())
        self.assertEqual(404, self.get('/api/converter?workspace=notes')[0])
        os.environ['RUNS_MODE'] = 'refuse'
        self.assertEqual(409, self.get('/api/converter?workspace=arc')[0])

    def test_actions_run_exact_control_commands(self):
        with mock.patch.object(self.w, 'reviewer_name', return_value='Ruben (web UI)'):
            self.assertEqual(200, self.post('approve', plan_id=pid(1), digest='a' * 64)[0])
            self.assertEqual(200, self.post('discard', plan_id=pid(2))[0])
        status, started = self.post('start', plan_id=pid(2))
        self.assertEqual((200, 'run-' + 'e' * 32), (status, started['run_id']))
        self.assertEqual(200, self.post('recover', run_id=rid(2))[0])
        self.assertEqual(200, self.post('reset', run_id=rid(1))[0])
        self.assertEqual(200, self.post('push', digest='c' * 64)[0])
        self.assertEqual([
            ['standard', 'plan', 'approve', 'arc', pid(1), '--sha256', 'a' * 64, '--reviewer', 'Ruben (web UI)'],
            ['standard', 'plan', 'discard', 'arc', pid(2), '--reviewer', 'Ruben (web UI)'],
            ['start-run', 'arc', pid(2)],
            ['standard', 'run', 'recover', 'arc', rid(2)],
            ['standard', 'run', 'reset', 'arc', rid(1), '--yes'],
            ['converter', 'push', 'arc', '--sha256', 'c' * 64]], self.calls())

    def test_bad_requests_never_reach_control(self):
        cases = [('approve', {'plan_id': pid(1)}), ('approve', {'plan_id': 'plan-1', 'digest': 'a' * 64}), ('approve', {'plan_id': pid(1), 'digest': 'a' * 63 + '--x'}),
                 ('start', {'plan_id': pid(1) + ' --yes'}), ('reset', {'run_id': '--yes'}), ('push', {'digest': 'C' * 64}), ('release', {'plan_id': pid(1)}),
                 ('start', {'plan_id': pid(1), 'workspace': '../arc'}), ('start', {'plan_id': pid(1), 'workspace': 'notes'})]
        for action, body in cases:
            with self.subTest(action=action, body=body):
                status, raw, _ = self.request('POST', '/api/' + action, dict({'workspace': 'arc'}, **body))
                self.assertIn(status, (400, 404))
        status, _, _ = self.request('POST', '/api/start', {'workspace': 'arc', 'plan_id': pid(1)}, headers={'X-Silo-Runs': '0'})
        self.assertEqual(403, status)
        status, _, _ = self.request('POST', '/api/start', {'workspace': 'arc', 'plan_id': pid(1), 'pad': 'x' * 5000})
        self.assertEqual(413, status)
        self.assertEqual([], self.calls())

    def test_control_refusals_pass_a_code_and_short_detail_never_raw_output(self):
        os.environ['RUNS_MODE'] = 'refuse'
        status, data = self.post('approve', plan_id=pid(1), digest='a' * 64)
        self.assertEqual((409, 'STANDARD_RECONCILIATION_INVALID: check 3: source_sql'), (status, data['error']))
        os.environ['RUNS_MODE'] = 'garbage'
        status, raw, _ = self.request('GET', '/api/overview?workspace=arc')
        self.assertEqual(409, status)
        self.assertNotIn(MARKER, raw.decode())

    def test_a_call_that_runs_out_of_time_stops_everything_it_started(self):
        late = Path(self.temp.name) / 'late'
        os.environ.update(RUNS_MODE='slow', RUNS_LATE=str(late))
        self.addCleanup(os.environ.pop, 'RUNS_LATE', None)
        with mock.patch.dict(self.w.TIMEOUTS, {'push': 1}):
            status, data = self.post('push', digest='c' * 64)
        self.assertEqual((504, 'STANDARD_OPERATION_TIMEOUT'), (status, data['error']))
        import time
        time.sleep(3)
        self.assertFalse(late.exists(), 'a process the timed-out call started kept running')
        self.assertIn('STANDARD_OPERATION_TIMEOUT', (WIDGET / 'app.js').read_text())

    def test_reviewer_name_refuses_control_and_format_characters(self):
        home = Path(self.temp.name) / 'home'
        (home / '.config/silo-migrate').mkdir(parents=True)
        import pwd as pwd_module
        real = pwd_module.getpwuid(os.getuid())
        fake = pwd_module.struct_passwd((real.pw_name, 'x', real.pw_uid, real.pw_gid, '', str(home), '/bin/bash'))
        for name, expected in (('Ruben Example', 'Ruben Example (web UI)'), ('Rub\u202eneb', 'engineer (web UI)'), ('x\x1b[31m', 'engineer (web UI)'),
                               ('Zoë Ølsen', 'Zoë Ølsen (web UI)'), ('', 'engineer (web UI)')):
            (home / '.config/silo-migrate/git-identity').write_text('name=' + name + '\n')
            with mock.patch.object(self.w.pwd, 'getpwuid', return_value=fake):
                self.assertEqual(expected, self.w.reviewer_name(), repr(name))

    def test_links_are_refused_not_followed(self):
        outside = Path(self.temp.name) / 'outside'
        outside.mkdir()
        (outside / 'secret.yml').write_text(MARKER)
        settings = self.base / 'arc/inputs/derived/settings.yml'
        settings.unlink()
        settings.symlink_to(outside / 'secret.yml')
        self.assertIsNone(self.get('/api/plan?workspace=arc&id=' + pid(1))[1]['texts']['settings'])
        evidence = self.base / 'arc/.silo-migrate/named/standard/runs' / rid(1) / 'evidence'
        (evidence / 'conversion-summary.txt').unlink()
        (evidence / 'conversion-summary.txt').symlink_to(outside / 'secret.yml')
        self.assertIsNone(self.get('/api/run?workspace=arc&id=' + rid(1))[1]['conversion_summary'])
        (self.base / 'linked').symlink_to(self.base / 'arc')
        self.assertEqual(['arc'], self.get('/api/workspaces')[1]['workspaces'])
        self.assertEqual(404, self.get('/api/overview?workspace=linked')[0])
        pushes = self.base / 'arc/.silo-migrate/named/standard/converter-pushes'
        (pushes / ('c' * 64 + '.json')).unlink()
        (pushes / ('c' * 64 + '.json')).symlink_to(outside / 'secret.yml')
        self.assertEqual(404, self.get('/api/push?workspace=arc&id=' + 'c' * 64)[0])

    def test_page_assets_headers_and_text_only_rendering(self):
        status, raw, response = self.request('GET', '/')
        self.assertEqual(200, status)
        self.assertIn(b'app.js', raw)
        self.assertIn("script-src 'self'", response.getheader('Content-Security-Policy'))
        self.assertEqual('no-store', response.getheader('Cache-Control'))
        for asset in ('/app.js', '/app.css'):
            self.assertEqual(200, self.request('GET', asset)[0])
        self.assertEqual(404, self.request('GET', '/server.py')[0])
        script = (WIDGET / 'app.js').read_text()
        self.assertNotIn('innerHTML', script)
        self.assertIn("'X-Silo-Runs': '1'", script)

    def test_refuses_to_start_in_a_socket_folder_that_isnt_private(self):
        shared = Path(self.temp.name) / 'shared'
        shared.mkdir(mode=0o755)
        shared.chmod(0o755)
        env = {'SILO_TESTING': '1', 'SILO_RUNS_CONTROL': str(self.control), 'SILO_RUNS_BASE': str(self.base)}
        with mock.patch.dict(os.environ, env), self.assertRaisesRegex(SystemExit, 'mode 0700'):
            self.w.main(['server.py', str(shared / 'runs.sock')])
        self.assertFalse((shared / 'runs.sock').exists())

    def test_manifest_uses_a_socket_and_the_extension_only_reads(self):
        manifest = (WIDGET / 'widget.yaml').read_text()
        self.assertIn('"$SOCKET"', manifest)
        self.assertNotIn('$PORT', manifest)
        extension = (ROOT / 'integrations/term-llm/extensions/silo-findings/main.js').read_text()
        self.assertIn("mount: 'runs'", extension)
        self.assertNotIn("method: 'POST'", extension)
        self.assertNotIn('innerHTML', extension)


if __name__ == '__main__':
    unittest.main()
