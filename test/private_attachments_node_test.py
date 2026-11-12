"""Opt-in native UI-upload -> Frontier tool -> private registry/real reader check.

Set PRIVATE_TERM_LLM_BINARY to the paired binary and SILO_SUPPORTING_LIVE=1.
Only isolated configuration, invented data and loopback fake providers are used.
"""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('PRIVATE_TERM_LLM_BINARY')


def workbook():
    spec = importlib.util.spec_from_file_location('supporting_live_fixture', ROOT / 'test/supporting_live_test.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.workbook()


@unittest.skipUnless(BINARY and os.environ.get('SILO_SUPPORTING_LIVE') == '1', 'opt-in paired native node and cached Docker test')
class PrivateAttachmentsNodeTest(unittest.TestCase):
    def test_ui_upload_reaches_only_own_private_project_tools(self):
        # Chat upload plumbing is deliberately outside the new generic-core scope.
        # Keep this compatibility check for the older attachment-capable binary.
        probe = subprocess.run([str(Path(BINARY).resolve()), 'capabilities', '--json'],
                               capture_output=True, timeout=10, check=True)
        if json.loads(probe.stdout).get('private_upload_context') != 1:
            self.skipTest('generic conversation protection build has no private chat-upload capability')
        self.check_reference_route(via_intake=False)

    def test_intake_reference_without_chat_upload_reaches_only_private_project(self):
        self.check_reference_route(via_intake=True)

    def test_intake_reference_prepares_converter_native_file_in_real_sandbox(self):
        self.check_reference_route(via_intake=True, prepare_reference=True)

    def check_reference_route(self, via_intake, prepare_reference=False):
        previous_umask = os.umask(0o077)
        self.addCleanup(os.umask, previous_umask)
        # Preparation uses the real job disk-reserve admission. Use a private
        # case under disk-backed /var/tmp (or an explicit test root), not a small
        # /tmp tmpfs or a group-writable source checkout; never relax the gates.
        scratch = os.environ.get('SILO_PRIVATE_TEST_TMPDIR', '/var/tmp') if prepare_reference else None
        with tempfile.TemporaryDirectory(prefix='private-attachments-node-', dir=scratch) as directory:
            home = Path(directory)
            project = home / 'projects/invented'
            project.mkdir(parents=True)
            data = home / 'data'
            named = home / 'workspaces/invented/.silo-migrate/named'
            (named / 'standard').mkdir(parents=True)
            named_state = named / 'state.json'
            named_document = {'inputs': {}, 'datasets': {}}
            if prepare_reference:
                # An invented, explicitly selected source is needed to associate
                # preparation outputs; it is never mounted into the prepare job.
                source_id, dataset_id, input_id = ['%s-%s' % (kind, char * 32)
                                                  for kind, char in [('source', '1'), ('dataset', '2'), ('input', '3')]]
                source = named.parent.parent / 'inputs/invented.sql'
                source.parent.mkdir(mode=0o700)
                source.write_bytes(b'CREATE TABLE invented (id int);\n')
                source.chmod(0o400)
                named_document['sources'] = {source_id: {'id': source_id, 'platform': base64.b64encode(b'mybb').decode()}}
                named_document['datasets'][dataset_id] = {'id': dataset_id, 'source_id': source_id}
                named_document['inputs'][input_id] = {'id': input_id, 'dataset_id': dataset_id, 'type': 'mysql-dump',
                    'path': base64.b64encode(b'inputs/invented.sql').decode(), 'bytes': source.stat().st_size,
                    'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}
                (named / 'deliveries.json').write_text(json.dumps({'version': 1, 'deliveries': {dataset_id: {
                    'dataset_id': dataset_id, 'kind': 'development', 'version': 1, 'sequence': 1, 'files': []}}}))
            named_state.write_text(json.dumps(named_document))
            profile = ROOT / 'runtime/profiles/discourse-2026.11.0-latest-3158c750.json'
            standard_state = named / 'standard/state.json'
            standard_state.write_text(json.dumps({'config': {'discourse_profile': profile.stem,
                                                            'discourse_profile_sha256': hashlib.sha256(profile.read_bytes()).hexdigest()}}))
            before = named_state.read_bytes(), standard_state.read_bytes()
            intake_bytes = workbook()
            if via_intake:
                # Real engineer reference classification; no chat-upload context.
                def load_local(name, relative):
                    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / relative))
                    spec = importlib.util.spec_from_loader(name, loader)
                    module = importlib.util.module_from_spec(spec)
                    loader.exec_module(module)
                    return module
                helpers = load_local('intake_node_helpers', 'bin/data_tools.py')
                host = load_local('intake_node_host', 'bin/silo-migrate-control')
                workspace = helpers.Workspace(home / 'workspaces', 'invented', ROOT, host, {}, None)
                (workspace.root / '.silo-migrate').chmod(0o700)
                workspace.intake.mkdir(parents=True, mode=0o700)
                original = workspace.intake / 'wishes.xlsx'
                original.write_bytes(intake_bytes)
                identity = helpers.supporting_module().source_identity(original.stat(), original.name)
                change = {'action': 'classify', 'role': 'reference', 'files': [identity]}
                preview = helpers.op_file_roles_preview(workspace, {'change': change, 'by': 'Invented Engineer'})
                helpers.op_file_roles_commit(workspace, {'change': preview['change'], 'digest': preview['digest'],
                                                         'by': 'Invented Engineer'})
            config = home / '.config/term-llm'
            config.mkdir(parents=True)
            (config / 'agents').symlink_to(ROOT / 'integrations/term-llm')
            control = home / 'test-control'
            control.write_text(f'''#!/usr/bin/env python3
import importlib.machinery, importlib.util, json, os, sys
from pathlib import Path
root = Path({str(ROOT)!r})
def load(name, rel):
    loader = importlib.machinery.SourceFileLoader(name, str(root/rel))
    spec = importlib.util.spec_from_loader(name, loader)
    m = importlib.util.module_from_spec(spec); loader.exec_module(m); return m
helpers, host = load('data_helpers', 'bin/data_tools.py'), load('control_helpers', 'bin/silo-migrate-control')
try:
    result = helpers.main(sys.argv[1:], {{}}, Path({str(home / 'workspaces')!r}), root, host, sys.stdin, None)
    print(json.dumps(result))
except helpers.Refusal as e:
    print('Error: ' + str(e), file=sys.stderr); sys.exit(1)
''')
            control.chmod(0o700)
            requests = []
            outputs = []
            prepared_jobs = []
            failures = []

            def tool_json(text):
                # Native custom scripts are projected as stdout + exit status.
                return json.JSONDecoder().raw_decode(text[text.index('{'):])[0]

            class FakeProvider(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass
                def do_GET(self):
                    self.reply({'object': 'list', 'data': [{'id': m} for m in ('CDCK/MoM', 'gpt-6.1-sol')]})
                def reply(self, value):
                    body = json.dumps(value).encode()
                    self.send_response(200)
                    self.send_header('content-type', 'application/json')
                    self.send_header('content-length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                def do_POST(self):
                    request = json.loads(self.rfile.read(int(self.headers['content-length'])))
                    requests.append(request)
                    try:
                        tools = [m for m in request.get('messages', []) if m.get('role') == 'tool']
                        count = len(tools)
                        if count == 0:
                            name, args = 'data_supporting_list', {}
                        elif count == 1:
                            previous = tool_json(tools[-1]['content'])
                            if via_intake:
                                assert previous['available_refs'] == [], 'intake test must have no chat uploads'
                                name, args = 'data_supporting_read', {'id': previous['files'][0]['id'], 'mode': 'rows', 'columns': 2, 'limit': 1}
                            else:
                                name, args = 'data_supporting_take', {'ref': previous['available_refs'][0]['id']}
                        elif count == 2 and not via_intake:
                            previous = tool_json(tools[-1]['content'])
                            name, args = 'data_supporting_read', {'id': previous['file']['id'], 'mode': 'rows', 'columns': 2, 'limit': 1}
                        elif count == 2 and prepare_reference:
                            outputs.append(tool_json(tools[-1]['content']))
                            admitted = tool_json(tools[0]['content'])
                            name, args = 'data_supporting_prepare', {
                                'id': admitted['files'][0]['id'], 'sheet': 'Mappings', 'header_row': 0,
                                'columns': [{'from': 'invented-reference-marker', 'to': 'khoros_source_id', 'required': True}],
                                'format': 'csv', 'name': 'tag_mapping.csv', 'into': 'prepared-reference'}
                        elif prepare_reference:
                            previous = tool_json(tools[-1]['content'])
                            if count == 3 or previous.get('status') == 'running':
                                name, args = 'data_job', {'job_id': previous.get('job_id') or previous['id']}
                            else:
                                assert previous['status'] == 'succeeded', previous
                                prepared_jobs.append(previous)
                                name = None
                        else:
                            outputs.append(tool_json(tools[-1]['content']))
                            name = None
                        call = {'id': 'support-' + str(count), 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(args)}} if name else None
                        message = {'role': 'assistant', 'content': None, 'tool_calls': [call]} if name else {'role': 'assistant', 'content': 'SUPPORTING_UPLOAD_OK'}
                    except Exception as error:
                        failures.append(type(error).__name__)
                        call = None
                        message = {'role': 'assistant', 'content': 'SUPPORTING_FIXTURE_FAILED'}
                    if request.get('stream'):
                        self.send_response(200); self.send_header('content-type', 'text/event-stream'); self.end_headers()
                        delta = {'tool_calls': [dict(call, index=0)]} if call else {'content': message['content']}
                        for value in ({'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
                                      {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'tool_calls' if call else 'stop'}]}):
                            self.wfile.write(('data: ' + json.dumps(value) + '\n\n').encode())
                        self.wfile.write(b'data: [DONE]\n\n')
                    else:
                        self.reply({'id': 'fixture', 'object': 'chat.completion', 'model': request['model'],
                                    'choices': [{'index': 0, 'message': message, 'finish_reason': 'tool_calls' if call else 'stop'}],
                                    'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}})

            provider = ThreadingHTTPServer(('127.0.0.1', 0), FakeProvider)
            thread = threading.Thread(target=provider.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(provider.server_close)
            self.addCleanup(thread.join, 5)
            self.addCleanup(provider.shutdown)
            provider_url = f'http://127.0.0.1:{provider.server_address[1]}/v1/chat/completions'
            (config / 'config.yaml').write_text(f'''provider_discovery: config
default_provider: cdck_frontier
providers:
  cdck_frontier:
    type: vllm
    url: {provider_url}
    model: CDCK/MoM
    api_key: invented-unused
  chatgpt:
    type: vllm
    url: {provider_url}
    model: gpt-6.1-sol
    api_key: invented-unused
agents:
  use_builtin: false
web:
  project_default_agent: migration-data
serve:
  auto_title: false
  extensions: []
''')
            env = {'PATH': os.defpath, 'HOME': str(home), 'XDG_CONFIG_HOME': str(home / '.config'),
                   'XDG_DATA_HOME': str(data), 'XDG_CACHE_HOME': str(home / 'cache'),
                   'SILO_TESTING': '1', 'SILO_PROJECTS_ROOT': str(home / 'projects'), 'SILO_CONTROL': str(control)}
            with socket.socket() as port_socket:
                port_socket.bind(('127.0.0.1', 0)); port = port_socket.getsockname()[1]
            origin = f'http://127.0.0.1:{port}'
            base = origin + '/ui'
            def api(path, body=None, **headers):
                raw = body if isinstance(body, bytes) else json.dumps(body).encode() if body is not None else None
                h = {'Origin': origin, 'X-Term-LLM-UI-Version': 'invented-test', **headers}
                if raw is not None:
                    h.setdefault('Content-Type', 'application/json')
                req = Request(base + path, data=raw, headers=h)
                try:
                    with urlopen(req, timeout=90) as response:
                        return response.status, json.load(response)
                except HTTPError as error:
                    return error.code, json.load(error)
            log = (home / 'node.log').open('wb')
            process = subprocess.Popen([str(Path(BINARY).resolve()), 'serve', 'web', '--host', '127.0.0.1', '--port', str(port),
                                        '--auth', 'none', '--projects', '--approval', 'auto'], cwd=project, env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if process.poll() is not None:
                        self.fail('isolated native node exited: ' + (home / 'node.log').read_text()[-3000:])
                    try:
                        code, _ = api('/v1/projects')
                        if code == 200:
                            break
                    except (URLError, OSError):
                        time.sleep(0.1)
                code, created = api('/v1/projects', {'name': 'invented', 'path': str(project)})
                self.assertIn(code, (200, 201, 409), created)
                project_id = created['existing_project_id'] if code == 409 else created['project']['id']
                code, created = api('/v1/sessions', {'agent': 'migration-data', 'project_id': project_id})
                self.assertEqual(201, code, created)
                session_id = created['session']['id']
                content = [{'type': 'input_text', 'text': 'Inspect this invented reference, using the supporting tools.'}]
                if not via_intake:
                    code, uploaded = api('/uploads', workbook(), **{'X-Term-LLM-Upload-Filename': quote('mapping.xlsx'),
                                                                   'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'})
                    self.assertEqual(201, code, uploaded)
                    content.append({'type': 'input_upload', 'upload_id': uploaded['upload_id']})
                code, response = api('/v1/responses', {'input': [{'type': 'message', 'role': 'user', 'content': content}], 'stream': False,
                    'client_message_id': 'fixture-upload-1'}, **{'X-Term-LLM-Session-ID': session_id})
                self.assertEqual(200, code, response)
                self.assertIn('SUPPORTING_UPLOAD_OK', json.dumps(response),
                              (failures, [m.get('content') for m in requests[-1].get('messages', []) if m.get('role') == 'tool']))
                self.assertEqual([], failures)
                offered = {tool.get('function', {}).get('name') for tool in requests[0].get('tools', [])}
                self.assertTrue(offered, 'the real shipped private-agent tool surface must be offered')
                self.assertFalse(offered & {'web_search', 'read_url', 'shell', 'read_file', 'write_file', 'edit_file', 'spawn_agent'},
                                 'private analysis received unrestricted public-egress or host-file tools')
                if prepare_reference:
                    self.assertGreaterEqual(len(requests), 5)
                    output = named.parent.parent / 'work/prepared-reference/tag_mapping.csv'
                    self.assertEqual(b'khoros_source_id\n', output.read_bytes())
                    self.assertEqual(1, len(prepared_jobs))
                    self.assertEqual(hashlib.sha256(intake_bytes).hexdigest(), prepared_jobs[0]['references'][0]['sha256'])
                    self.assertRegex(prepared_jobs[0]['preparation_sha256'], r'^[0-9a-f]{64}$')
                    self.assertEqual([], list((named.parent / 'data/jobs').glob('refs-*')))
                else:
                    self.assertEqual(3 if via_intake else 4, len(requests))
                self.assertEqual({'CDCK/MoM'}, {item['model'] for item in requests})
                self.assertIn('rows', outputs[0], outputs)
                self.assertEqual('invented-reference-marker', outputs[0]['rows'][0][0]['value'])
                self.assertEqual({'type': 'formula', 'formula': True, 'value': None}, outputs[0]['rows'][0][1])
                before_denial = len(requests)
                code, denied = api('/v1/responses', {'input': 'Do not disclose this transcript.', 'provider': 'chatgpt',
                                               'model': 'gpt-6.1-sol', 'stream': False, 'client_message_id': 'fixture-denied-2',
                                               'previous_response_id': response['id']}, **{'X-Term-LLM-Session-ID': session_id})
                if code >= 400:
                    self.assertRegex(json.dumps(denied), r'(?i)(not allowed|locked|model policy|disallow)')
                    self.assertEqual(before_denial, len(requests))
                else:
                    # Durable continuation pins its admitted runtime; some wire
                    # overrides are ignored rather than treated as model swaps.
                    self.assertEqual(200, code, denied)
                    self.assertEqual('CDCK/MoM', denied.get('model'))
                    self.assertEqual(before_denial + 1, len(requests))
                self.assertEqual({'CDCK/MoM'}, {item['model'] for item in requests},
                                 'locked history reached the forbidden fake provider')
                self.assertEqual(before, (named_state.read_bytes(), standard_state.read_bytes()))
                if via_intake:
                    self.assertEqual(intake_bytes, original.read_bytes())
                print(json.dumps({'result': 'native reference, own-project private read and forbidden-provider non-dispatch passed',
                                  'arrival': 'intake_without_chat_upload' if via_intake else 'chat_upload',
                                  'prepared_in_real_sandbox': prepare_reference,
                                  'fake_frontier_requests': len(requests), 'migration_state_unchanged': True}))
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
                log.close()


if __name__ == '__main__':
    unittest.main()
