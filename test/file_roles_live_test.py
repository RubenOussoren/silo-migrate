"""Opt-in real widget -> host roles -> private XLSX reader using invented fixtures.

No image pull, provider inference, import or server access. Set SILO_SUPPORTING_LIVE=1.
The protected-chat context is a fixture; native admission is tested separately.
"""
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@unittest.skipUnless(os.environ.get('SILO_SUPPORTING_LIVE') == '1', 'opt-in cached-image role correction integration')
class FileRolesLiveTest(unittest.TestCase):
    def test_widget_corrects_taken_workbook_restores_source_and_reads_private_copy(self):
        roles = load('roles_live_fixtures', ROOT / 'test/file_roles_test.py')
        fixtures = roles.FileRolesTest()
        fixtures.setUp()
        self.addCleanup(fixtures.doCleanups)
        workbook = load('roles_live_workbook', ROOT / 'test/supporting_live_test.py').workbook()
        write = fixtures.write
        fixtures.write = lambda name, body=b'invented data': write(name, workbook if name == 'mapping.xlsx' else body)
        original, mistaken, wrong, input_id = fixtures.legacy(taken=True)
        before_named = (fixtures.named / 'state.json').read_bytes()
        before_deliveries = (fixtures.named / 'deliveries.json').read_bytes()
        original_path = fixtures.root / 'inputs/mapping.xlsx'
        before_input = original_path.read_bytes(), original_path.stat().st_mode
        standard_path = fixtures.standard / 'state.json'
        standard = json.loads(standard_path.read_text())
        good_plan, bad_plan = 'plan-' + '1' * 32, 'plan-' + '2' * 32
        good_run = 'run-' + '3' * 32
        standard['plans'] = {good_plan: {'id': good_plan, 'status': 'consumed', 'body': {'dataset_id': original}},
                             bad_plan: {'id': bad_plan, 'status': 'approved', 'body': {'dataset_id': mistaken, 'roles': {'source': input_id}}}}
        standard['runs'] = {good_run: {'id': good_run, 'plan_id': good_plan, 'status': 'passed',
                                      'release': {'sha256': hashlib.sha256(b'invented released backup').hexdigest()}}}
        standard_path.write_text(json.dumps(standard))
        before_standard = standard_path.read_bytes()
        control = fixtures.root.parent.parent / 'roles-live-control'
        control.write_text(f'''#!/usr/bin/env python3
import importlib.machinery, importlib.util, io, json, sys
from pathlib import Path
root = Path({str(ROOT)!r})
def load(name, relative):
    loader = importlib.machinery.SourceFileLoader(name, str(root/relative))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec); loader.exec_module(module); return module
helpers, host = load('roles_live_helpers', 'bin/data_tools.py'), load('roles_live_host', 'bin/silo-migrate-control')
try:
    print(json.dumps(helpers.main(sys.argv[1:], {{}}, Path({str(fixtures.fixture.base)!r}), root, host, sys.stdin, None)))
except helpers.Refusal as error:
    print('Error: ' + str(error), file=sys.stderr); sys.exit(1)
''')
        control.chmod(0o700)
        widget = load('roles_live_widget', ROOT / 'integrations/term-llm/widgets/project/server.py')
        socket_path = str(control.parent / 'roles-widget.sock')
        server = widget.Server(socket_path, widget.Handler)
        server.control, server.base = str(control), fixtures.fixture.base
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        class Connection(http.client.HTTPConnection):
            def connect(self):
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(socket_path)

        def request(action, change=None, digest=None):
            connection = Connection('local', timeout=100)
            if action == 'view':
                connection.request('GET', '/api/files?workspace=arc')
            else:
                body = {'workspace': 'arc', 'change': change}
                if digest:
                    body['digest'] = digest
                connection.request('POST', '/api/files/' + action, json.dumps(body),
                                   {'Content-Type': 'application/json', 'X-Silo-Project': '1'})
            response = connection.getresponse()
            status, result = response.status, json.loads(response.read())
            connection.close()
            self.assertEqual(200, status, result)
            return result

        change = fixtures.correction(wrong, original)
        preview = request('preview', change)
        self.assertEqual([bad_plan], [entry['plan_id'] for entry in preview['impacts']['pending']])
        self.assertEqual([], preview['impacts']['completed'])
        self.assertEqual([], preview['impacts']['releases'])
        corrected = request('commit', preview['change'], preview['digest'])
        self.assertEqual(original, corrected['roles']['active']['development'])
        self.assertEqual(before_named, (fixtures.named / 'state.json').read_bytes())
        self.assertEqual(before_deliveries, (fixtures.named / 'deliveries.json').read_bytes())
        self.assertEqual(before_standard, standard_path.read_bytes())
        self.assertEqual(before_input, (original_path.read_bytes(), original_path.stat().st_mode))
        state = fixtures.state()
        self.assertIn(bad_plan, state['invalidated_plans'])
        self.assertNotIn(good_plan, state['invalidated_plans'])
        reference = request('view')['roles']['references'][0]
        self.assertEqual(hashlib.sha256(workbook).hexdigest(), reference['sha256'])

        # Real protected-reference backend and cached no-network Docker parser.
        # This context models the trusted adapter, not a native provider assertion.
        context = {'via': 'chat', '_private_session': True, '_session_id': 'invented-roles-chat', '_uploads': []}
        listed = widget.data(str(control), 'arc', dict(context, op='supporting_list'))
        self.assertIn(reference['support_id'], [item['id'] for item in listed['files']])
        parsed = widget.data(str(control), 'arc', dict(context, op='supporting_read', id=reference['support_id'], mode='rows', columns=2, limit=1))
        self.assertEqual('invented-reference-marker', parsed['rows'][0][0]['value'])
        self.assertEqual({'type': 'formula', 'formula': True, 'value': None}, parsed['rows'][0][1])
        self.assertEqual(before_standard, standard_path.read_bytes())
        self.assertEqual(before_input, (original_path.read_bytes(), original_path.stat().st_mode))


if __name__ == '__main__':
    unittest.main()
