"""Intake-first plan/reference projections of the Project page. Invented data only.
Run: python3 -I -B test/intake_plan_widget_test.py."""
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

ROOT = Path(__file__).resolve().parents[1]
WIDGET = ROOT / 'integrations/term-llm/widgets/project'
WS = 'atlas'
PLAN = 'plan-' + 'a' * 32
LEGACY = 'plan-' + 'b' * 32
OLD = 'plan-' + 'c' * 32
RUN = 'run-' + 'd' * 32
REF = 'file-' + '1' * 32
OTHER_REF = 'file-' + '2' * 32
MAP = 'input-' + '3' * 32
SETTINGS = 'input-' + '4' * 32
TEXT = b'source_category,target_category\nOld Help,Support\n'
YAML = b'category_routes:\n  - from: Old Help\n    to: Support\n'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def load():
    spec = importlib.util.spec_from_file_location('project_widget_intake', WIDGET / 'server.py')
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


def preparation(**changes):
    """As lib/silo_migrate/services/standard_run_inputs.rb binds it into a plan body."""
    value = {
        'version': 1, 'analyst': {'label': 'migration-data', 'text': 'Merge the invented Atlas forum into the Base site.'},
        'references': [{'file_id': REF, 'sha256': 'e' * 64}],
        'outcomes': [{'id': 'o1', 'requirement': 'Move Old Help into Support', 'disposition': 'prepared_input', 'input': 'categories.csv'},
                     {'id': 'o2', 'requirement': 'Merge matching-email users', 'disposition': 'stock'},
                     {'id': 'o3', 'requirement': 'Badge styling', 'disposition': 'excluded', 'exclusion': 'x1'}],
        'questions': [{'id': 'q1', 'text': 'Use the existing Support category?', 'status': 'resolved', 'resolution': 'Use existing Support'}],
        'exclusions': [{'id': 'x1', 'text': 'Badge styling', 'reason': 'Manual follow-up after launch'}],
        'code_readiness': {'kind': 'converter', 'present': True, 'required': False, 'platform': 'invented', 'path': 'converters/invented/converter.rb', 'revision': 'a1b2c3d4e5f6a7b8'},
    }
    value.update(changes)
    return value


class IntakePlanTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        top = Path(self.temp.name)
        self.base = top / 'workspaces'
        root = self.base / WS
        self.standard = root / '.silo-migrate/named/standard'
        self.standard.mkdir(parents=True)
        (root / 'inputs').mkdir()
        (root / 'inputs/map.csv').write_bytes(TEXT)
        (root / 'inputs/settings.yml').write_bytes(YAML)
        (root / '.silo-migrate/named/state.json').write_text(json.dumps({'inputs': {
            MAP: {'path': base64.b64encode(b'inputs/map.csv').decode(), 'sha256': sha(TEXT)},
            SETTINGS: {'path': base64.b64encode(b'inputs/settings.yml').decode(), 'sha256': sha(YAML)}}}))
        self.bindings = [{'id': MAP, 'sha256': sha(TEXT), 'bytes': len(TEXT), 'type': 'mapping'},
                         {'id': SETTINGS, 'sha256': sha(YAML), 'bytes': len(YAML), 'type': 'settings'}]
        self.manifest = {'version': 1, 'consumer': {'platform': 'invented', 'setting': 'mappings.directory'}, 'source_sha256': 'f' * 64,
                         'mount': '/run-inputs', 'writable': True,
                         'files': [{'name': 'categories.csv', 'input_id': MAP, 'sha256': sha(TEXT), 'bytes': len(TEXT),
                                    'lineage': {'references': [{'file_id': REF, 'sha256': 'e' * 64}], 'preparation': {'job': 'job-5555'}}}],
                         'absent_defaults': ['groups.csv'], 'generated': ['trust_level_mapping.yml']}
        self.calls = top / 'calls.jsonl'
        self.control = top / 'control'
        self.control.write_text('''#!/usr/bin/env python3
import json, os, sys
send = sys.stdin.read() if not sys.stdin.isatty() else ''
with open(os.environ['CALLS'], 'a') as out:
    out.write(json.dumps([sys.argv[1:], json.loads(send) if send else None]) + '\\n')
if sys.argv[1] == 'data':
    print(json.dumps({'initialized': True, 'roles': {'references': [
        {'id': '%s', 'path': 'invented-plan.xlsx', 'sha256': 'e' * 64, 'role': 'reference'},
        {'id': '%s', 'path': 'unused.txt', 'sha256': 'f' * 64, 'role': 'reference'}]}}))
elif sys.argv[1:4] == ['standard', 'plan', 'show']:
    print(json.dumps({'plan_id': sys.argv[5], 'status': 'proposed', 'digest': '0' * 64, 'operation': 'standard_convert'}))
else:
    print(json.dumps({'status': 'ok', 'run_id': '%s'}))
''' % (REF, OTHER_REF, RUN))
        self.control.chmod(0o700)
        os.environ['CALLS'] = str(self.calls)
        self.addCleanup(os.environ.pop, 'CALLS', None)
        self.m = load()
        self.intake = self.m.intake
        self.store = self.m.runs.Store(self.base)

    def write_state(self, plans, runs=None):
        (self.standard / 'state.json').write_text(json.dumps({'plans': plans, 'runs': runs or {}}))

    def body(self, **changes):
        value = {'operation': 'standard_convert', 'input_binding': self.bindings, 'roles': {'settings': SETTINGS},
                 'preparation': preparation(), 'run_inputs': self.manifest}
        value.update(changes)
        return {key: item for key, item in value.items() if item is not None}

    def view(self, **changes):
        return self.intake.plan_view(self.store, WS, self.body(**changes))

    def codes(self, view):
        return [blocker['code'] for blocker in view['blockers']]

    # -- plan projection ---------------------------------------------------------------

    def test_legacy_plan_has_no_projection_and_no_ready_claim(self):
        self.assertIsNone(self.intake.plan_view(self.store, WS, {'operation': 'standard_convert', 'input_binding': self.bindings}))

    def test_ready_plan_previews_exact_bytes_with_lineage(self):
        view = self.view()
        self.assertTrue(view['ready'], view['blockers'])
        [entry] = view['inputs']
        self.assertEqual(entry['state'], 'verified')
        self.assertEqual(entry['preview']['text'], TEXT.decode())
        self.assertEqual(entry['lineage']['references'], [{'file_id': REF, 'sha256': 'e' * 64}])
        self.assertEqual(view['run_inputs']['absent_defaults'], ['groups.csv'])
        self.assertEqual(view['preparation']['analyst']['label'], 'migration-data')

    def test_merge_prepared_settings_are_verified_by_role_not_name(self):
        prep = preparation(outcomes=[{'id': 'o1', 'requirement': 'Route categories', 'disposition': 'prepared_input', 'input': 'settings'}],
                           code_readiness={'kind': 'merge_layer', 'present': False, 'required': False})
        view = self.view(run_inputs=None, operation='standard_merge', preparation=prep)
        self.assertTrue(view['ready'], view['blockers'])
        [entry] = view['inputs']
        self.assertIsNone(entry['name'])
        self.assertEqual(entry['origin'], 'prepared settings')
        self.assertEqual(entry['preview']['text'], YAML.decode())

    def test_question_without_resolution_blocks(self):
        for question in ({'id': 'q2', 'text': 'Retire Sandbox how?'}, {'id': 'q2', 'text': 'Retire Sandbox how?', 'status': 'open'}):
            view = self.view(preparation=preparation(questions=[question]))
            self.assertFalse(view['ready'])
            self.assertEqual(self.codes(view), ['QUESTION_UNRESOLVED'])
        narrowed = preparation(questions=[{'id': 'q2', 'text': 'Retire Sandbox how?', 'status': 'excluded', 'resolution': 'Deferred', 'exclusion': 'x1'}])
        self.assertTrue(self.view(preparation=narrowed)['ready'])

    def test_missing_code_blocks(self):
        code = [{'id': 'o4', 'requirement': 'Route categories', 'disposition': 'code'}]
        missing = preparation(outcomes=code, code_readiness={'kind': 'merge_layer', 'present': False, 'required': True})
        self.assertIn('CODE_MISSING', self.codes(self.view(preparation=missing)))
        self.assertIn('CODE_MISSING', self.codes(self.view(preparation=preparation(outcomes=code, code_readiness=None))))
        pinned = preparation(outcomes=code, code_readiness={'kind': 'merge_layer', 'present': True, 'required': True, 'revision': 'a1b2c3d4e5'})
        self.assertTrue(self.view(preparation=pinned)['ready'])

    def test_prepared_outcome_must_name_a_bound_file(self):
        prep = preparation(outcomes=[{'id': 'o1', 'requirement': 'x', 'disposition': 'prepared_input', 'input': 'users.csv'}])
        self.assertIn('INPUT_NOT_BOUND', self.codes(self.view(preparation=prep)))
        settings = preparation(outcomes=[{'id': 'o1', 'requirement': 'x', 'disposition': 'setting'}])
        self.assertIn('INPUT_NOT_BOUND', self.codes(self.view(preparation=settings, roles={})))

    def test_changed_missing_unbound_and_linked_inputs_fail_closed(self):
        (self.base / WS / 'inputs/map.csv').write_bytes(TEXT + b'Extra,Row\n')
        self.assertIn('INPUT_CHANGED', self.codes(self.view()))
        (self.base / WS / 'inputs/map.csv').unlink()
        self.assertIn('INPUT_MISSING', self.codes(self.view()))
        (self.base / WS / 'inputs/map.csv').symlink_to(self.base / WS / 'inputs/settings.yml')
        view = self.view()
        self.assertFalse(view['ready'])
        self.assertIsNone(view['inputs'][0].get('preview'))
        unbound = self.view(input_binding=[self.bindings[1]])
        self.assertIn('INPUT_NOT_BOUND', self.codes(unbound))

    def test_malformed_fields_block(self):
        for bad in ({'version': 2}, 'text', preparation(analyst=None), preparation(outcomes=[{'id': 'o1', 'requirement': 'x', 'disposition': 'magic'}]),
                    preparation(outcomes=[{'id': 'o1', 'requirement': 'x', 'disposition': 'excluded', 'exclusion': 'nope'}]),
                    preparation(references=[{'file_id': REF, 'input_id': MAP, 'sha256': 'e' * 64}])):
            self.assertIn('PREPARATION_UNREADABLE', self.codes(self.view(preparation=bad)))
        for name in ('../escape.csv', '/abs.csv', 'a//b.csv', 'a\\b.csv', '.hidden'):
            manifest = dict(self.manifest, files=[dict(self.manifest['files'][0], name=name)])
            self.assertIn('RUN_INPUTS_UNREADABLE', self.codes(self.view(run_inputs=manifest)))
        both = dict(self.manifest, absent_defaults=['Categories.csv'])
        self.assertIn('RUN_INPUTS_UNREADABLE', self.codes(self.view(run_inputs=both)))
        no_files = dict(self.manifest)
        del no_files['files']
        for bad in (no_files, dict(self.manifest, files=None), dict(self.manifest, files='none')):
            self.assertIn('RUN_INPUTS_UNREADABLE', self.codes(self.view(run_inputs=bad)))

    # -- derived "Used by" -------------------------------------------------------------

    def test_reference_usage_is_derived_from_plans_and_runs(self):
        self.write_state({PLAN: {'status': 'proposed', 'body': self.body()}})
        usage = self.intake.reference_usage(self.store, WS)
        self.assertEqual(self.intake.reference_status(usage.get(REF), 'e' * 64), 'cited_by_plan')
        self.assertEqual(self.intake.reference_status(usage.get(OTHER_REF), 'f' * 64), 'reference_only')
        # Different bytes under the same ID are not this reference's use.
        self.assertEqual(self.intake.reference_status(usage.get(REF), '9' * 64), 'reference_only')
        self.write_state({PLAN: {'status': 'consumed', 'body': self.body()}}, {RUN: {'plan_id': PLAN, 'status': 'completed'}})
        self.assertEqual(self.intake.reference_status(self.intake.reference_usage(self.store, WS).get(REF), 'e' * 64), 'used_by_completed_run')
        self.write_state({OLD: {'status': 'stale', 'body': self.body()}})
        self.assertEqual(self.intake.reference_status(self.intake.reference_usage(self.store, WS).get(REF), 'e' * 64), 'cited_earlier')
        self.write_state({PLAN: {'status': 'consumed', 'body': self.body()}}, {RUN: {'plan_id': PLAN, 'status': 'failed'}})
        self.assertEqual(self.intake.reference_status(self.intake.reference_usage(self.store, WS).get(REF), 'e' * 64), 'run_not_completed')

    def test_running_and_failed_runs_are_named_truthfully(self):
        status = lambda: self.intake.reference_status(self.intake.reference_usage(self.store, WS).get(REF), 'e' * 64)
        for run_status, expected in (('running', 'in_use'), ('claimed', 'in_use'), ('failed', 'run_not_completed'),
                                     ('interrupted', 'run_not_completed'), ('abandoned', 'run_not_completed')):
            self.write_state({PLAN: {'status': 'consumed', 'body': self.body()}}, {RUN: {'plan_id': PLAN, 'status': run_status}})
            self.assertEqual(status(), expected, run_status)
        # A plan waiting for review outranks an earlier failed run; a completed run outranks all.
        self.write_state({PLAN: {'status': 'consumed', 'body': self.body()}, OLD: {'status': 'proposed', 'body': self.body()}},
                         {RUN: {'plan_id': PLAN, 'status': 'failed'}})
        self.assertEqual(status(), 'cited_by_plan')
        self.write_state({PLAN: {'status': 'discarded', 'body': self.body()}})
        self.assertEqual(status(), 'cited_earlier')

    def test_large_inputs_are_not_blocked_or_claimed_verified(self):
        self.intake.MAX_VERIFY = 8
        self.addCleanup(setattr, self.intake, 'MAX_VERIFY', 2 * 1024 * 1024 * 1024)
        view = self.view()
        self.assertTrue(view['ready'], view['blockers'])
        self.assertEqual(view['inputs'][0]['state'], 'not_verified_here')
        self.assertIsNone(view['inputs'][0].get('preview'))

    def test_bounded_preview_keeps_whole_utf8_characters(self):
        data = ('é' * (self.intake.MAX_PREVIEW // 2) + 'tail').encode()  # odd boundary inside a 2-byte sequence
        data = b'x' + data
        (self.base / WS / 'inputs/map.csv').write_bytes(data)
        manifest = dict(self.manifest, files=[dict(self.manifest['files'][0], sha256=sha(data), bytes=len(data))])
        view = self.view(run_inputs=manifest, input_binding=[dict(self.bindings[0], sha256=sha(data), bytes=len(data)), self.bindings[1]])
        preview = view['inputs'][0]['preview']
        self.assertTrue(preview['truncated'])
        self.assertLessEqual(len(preview['text'].encode()), self.intake.MAX_PREVIEW)
        self.assertTrue(preview['text'].startswith('xé'))

    def test_unreadable_plans_mark_usage_unknown_not_unused(self):
        files = {'roles': {'references': [{'id': REF, 'sha256': 'e' * 64}]}}

        class Broken:
            def plans(self, workspace):
                raise OSError('unreadable')
        result = self.intake.annotate_references(Broken(), WS, files)
        self.assertEqual(result['roles']['references'][0]['usage_status'], 'unknown')
        self.assertIsNone(result['roles']['references'][0]['used_by'])

    # -- HTTP: files, plan detail, guarded decisions -----------------------------------

    def serve(self):
        path = str(Path(self.temp.name) / 'w.sock')
        server = self.m.Server(path, self.m.Handler)
        server.control, server.base = str(self.control), self.base
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return path

    def call(self, path, method='GET', body=None):
        conn = Conn(self.sock)
        headers = {'X-Silo-Project': '1', 'Content-Type': 'application/json'} if body is not None else {}
        conn.request(method, path, json.dumps(body) if body is not None else None, headers)
        response = conn.getresponse()
        data = json.loads(response.read() or b'{}')
        conn.close()
        return response.status, data

    def control_calls(self):
        return [json.loads(line)[0] for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def data_requests(self):
        return [json.loads(line)[1] for line in self.calls.read_text().splitlines() if json.loads(line)[1]] if self.calls.exists() else []

    def test_http_files_plan_and_guarded_decisions(self):
        blocked = self.body(preparation=preparation(questions=[{'id': 'q9', 'text': 'Retire Sandbox how?'}]))
        self.write_state({PLAN: {'status': 'proposed', 'body': blocked}, LEGACY: {'status': 'approved', 'body': {'operation': 'standard_convert'}}})
        self.sock = self.serve()
        status, files = self.call('/api/files?workspace=' + WS)
        self.assertEqual(status, 200)
        refs = {ref['id']: ref for ref in files['roles']['references']}
        self.assertEqual(refs[REF]['usage_status'], 'cited_by_plan')
        self.assertEqual(refs[REF]['used_by']['plans'][0]['plan_id'], PLAN)
        self.assertEqual(refs[OTHER_REF]['usage_status'], 'reference_only')
        status, plan = self.call('/api/runs/plan?workspace=%s&id=%s' % (WS, PLAN))
        self.assertEqual(status, 200)
        self.assertFalse(plan['intake']['ready'])
        status, legacy = self.call('/api/runs/plan?workspace=%s&id=%s' % (WS, LEGACY))
        self.assertIsNone(legacy['intake'])
        before = len(self.control_calls())
        for action in ('approve', 'start'):
            status, refused = self.call('/api/runs/' + action, 'POST', {'workspace': WS, 'plan_id': PLAN, 'digest': '0' * 64})
            self.assertEqual((status, refused['error']), (409, 'STANDARD_PLAN_NOT_READY'))
        self.assertEqual(len(self.control_calls()), before, 'a blocked plan never reaches the control command')
        status, _ = self.call('/api/runs/start', 'POST', {'workspace': WS, 'plan_id': LEGACY})
        self.assertEqual(status, 200)
        self.assertEqual(self.control_calls()[-1], ['start-run', WS, LEGACY])
        # Answering produces a new ready plan; its approval reaches the existing exact-digest command.
        self.write_state({PLAN: {'status': 'proposed', 'body': self.body()}})
        status, _ = self.call('/api/runs/approve', 'POST', {'workspace': WS, 'plan_id': PLAN, 'digest': '0' * 64})
        self.assertEqual(status, 200)
        self.assertEqual(self.control_calls()[-1][:4], ['standard', 'plan', 'approve', WS])

    # -- Run again: a NEW proposal that keeps the bound inputs and recorded choices ---------

    def again(self, body, operation='standard_convert'):
        roles = {'source': 'input-' + '7' * 32, 'settings': SETTINGS}
        self.write_state({PLAN: {'status': 'consumed', 'digest': '9' * 64, 'body': dict(body, operation=operation, roles=roles, source_charset='utf8mb4')}},
                         {RUN: {'plan_id': PLAN, 'status': 'completed'}})
        self.calls.unlink(missing_ok=True)
        return self.m.propose_again(self.base, str(self.control), {'workspace': WS, 'run_id': RUN})

    def test_run_again_carries_manifest_and_choices_without_computed_fields(self):
        self.again(self.body())
        request = self.data_requests()[-1]
        self.assertEqual(request['op'], 'plan_propose')
        self.assertEqual(request['source'], 'input-' + '7' * 32)
        self.assertEqual(request['run_inputs'], {
            'version': 1, 'consumer': {'platform': 'invented', 'setting': 'mappings.directory'}, 'source_sha256': 'f' * 64,
            'files': [{'name': 'categories.csv', 'input_id': MAP, 'sha256': sha(TEXT), 'bytes': len(TEXT),
                       # Bound lineage is repeated so the adapter can require the records still say exactly this.
                       'lineage': {'references': [{'file_id': REF, 'sha256': 'e' * 64}], 'preparation': {'job': 'job-5555'}}}],
            'absent_defaults': ['groups.csv'], 'generated': ['trust_level_mapping.yml']})
        prep = request['preparation']
        self.assertEqual(prep['analyst'], {'text': 'Merge the invented Atlas forum into the Base site.'})
        self.assertNotIn('code_readiness', prep)
        self.assertEqual(prep['references'], [{'file_id': REF}])
        self.assertEqual([item['id'] for item in prep['outcomes']], ['o1', 'o2', 'o3'])
        self.assertEqual(prep['questions'], [{'id': 'q1', 'text': 'Use the existing Support category?', 'status': 'resolved', 'resolution': 'Use existing Support'}])
        self.assertEqual(prep['exclusions'], [{'id': 'x1', 'text': 'Badge styling', 'reason': 'Manual follow-up after launch'}])
        text = json.dumps(request)
        for leaked in ('digest', 'plan_id', 'run_id', 'approved', 'label', 'mount', 'writable', 'verified', 'code_readiness'):
            self.assertNotIn('"%s"' % leaked, text)
        self.assertFalse(any(argv[:3] == ['standard', 'plan', 'approve'] or argv[0] == 'start-run' for argv in self.control_calls()))

    def test_run_again_keeps_explicit_reuse_and_exact_reference_hashes(self):
        reuse = {'dataset_id': 'dataset-' + '6' * 32, 'source_sha256': 'b' * 64}
        lineage = {'references': [{'file_id': REF, 'sha256': 'e' * 64, 'verified': 'registry_digest'}],
                   'preparation': {'job': 'job-5555', 'tool': 'data_supporting_prepare', 'preparation_sha256': 'c' * 64}}
        manifest = dict(self.manifest, files=[dict(self.manifest['files'][0], reuse=reuse, lineage=lineage)])
        prep = preparation(references=[{'file_id': REF, 'sha256': 'e' * 64, 'verified': 'custody_bytes'}])
        self.again(self.body(run_inputs=manifest, preparation=prep))
        request = self.data_requests()[-1]
        [bound] = request['run_inputs']['files']
        self.assertEqual(bound['reuse'], reuse, 'the exact earlier source version is carried, not dropped')
        self.assertEqual(bound['lineage'], {'references': [{'file_id': REF, 'sha256': 'e' * 64}],
                                            'preparation': {'job': 'job-5555', 'tool': 'data_supporting_prepare', 'preparation_sha256': 'c' * 64}})
        self.assertEqual(request['run_inputs']['source_sha256'], 'f' * 64)
        self.assertEqual(request['preparation']['references'], [{'file_id': REF}])
        self.assertNotIn('verified', json.dumps(request))
        # The cited reference's hash was checked against the registry before proposing.
        self.assertEqual([r['op'] for r in self.data_requests()], ['deliveries', 'plan_propose'])

    def test_reuse_and_verification_shapes_fail_closed(self):
        bad_reuse = [{'dataset_id': 'dataset-' + '6' * 32}, {'dataset_id': 'x', 'source_sha256': 'b' * 64},
                     {'dataset_id': 'dataset-' + '6' * 32, 'source_sha256': 'b' * 64, 'extra': 1}]
        for reuse in bad_reuse:
            manifest = dict(self.manifest, files=[dict(self.manifest['files'][0], reuse=reuse)])
            self.assertIn('RUN_INPUTS_UNREADABLE', self.codes(self.view(run_inputs=manifest)))
            with self.assertRaises(self.m.Refused) as refused:
                self.again(self.body(run_inputs=manifest))
            self.assertTrue(refused.exception.code.startswith('STANDARD_RUN_INPUTS_INVALID'))
        self.assertIn('PREPARATION_UNREADABLE', self.codes(self.view(preparation=preparation(references=[{'file_id': REF, 'sha256': 'e' * 64, 'verified': 'trusted'}]))))
        lineage = {'preparation': {'job': 'job-5555', 'preparation_sha256': 'nothex'}}
        manifest = dict(self.manifest, files=[dict(self.manifest['files'][0], lineage=lineage)])
        self.assertIn('RUN_INPUTS_UNREADABLE', self.codes(self.view(run_inputs=manifest)))
        view = self.view(run_inputs=dict(self.manifest, files=[dict(self.manifest['files'][0], reuse={'dataset_id': 'dataset-' + '6' * 32, 'source_sha256': 'b' * 64})]))
        self.assertTrue(view['ready'])
        self.assertEqual(view['inputs'][0]['reuse']['dataset_id'], 'dataset-' + '6' * 32)

    def empty_manifest(self):
        # Khoros with no reviewed maps: a fresh empty directory, the converter's own defaults.
        return dict(self.manifest, files=[], absent_defaults=['categories.csv', 'groups.csv'])

    def test_empty_manifest_binds_defaults_without_placeholder_files(self):
        prep = preparation(outcomes=[{'id': 'o1', 'requirement': 'Keep Khoros defaults', 'disposition': 'stock'}])
        view = self.view(run_inputs=self.empty_manifest(), preparation=prep)
        self.assertTrue(view['ready'], view['blockers'])
        self.assertEqual(view['inputs'], [])
        self.assertEqual(view['run_inputs']['files'], [])
        self.assertEqual(view['run_inputs']['consumer']['setting'], 'mappings.directory')
        self.assertEqual(view['run_inputs']['absent_defaults'], ['categories.csv', 'groups.csv'])
        self.assertEqual(view['run_inputs']['generated'], ['trust_level_mapping.yml'])
        # A prepared-file outcome cannot point into an empty manifest.
        self.assertIn('INPUT_NOT_BOUND', self.codes(self.view(run_inputs=self.empty_manifest())))

    def test_run_again_keeps_empty_manifest_exactly(self):
        prep = preparation(outcomes=[{'id': 'o1', 'requirement': 'Keep Khoros defaults', 'disposition': 'stock'}])
        self.again(self.body(run_inputs=self.empty_manifest(), preparation=prep))
        self.assertEqual(self.data_requests()[-1]['run_inputs'], {
            'version': 1, 'consumer': {'platform': 'invented', 'setting': 'mappings.directory'}, 'source_sha256': 'f' * 64,
            'files': [], 'absent_defaults': ['categories.csv', 'groups.csv'], 'generated': ['trust_level_mapping.yml']})

    def test_run_again_merge_keeps_reference_lineage(self):
        prep = preparation(outcomes=[{'id': 'o1', 'requirement': 'Route categories', 'disposition': 'prepared_input', 'input': 'settings'}],
                           code_readiness={'kind': 'merge_layer', 'present': False, 'required': False})
        self.again({'preparation': prep, 'merge': {'options': {'ignore_global_pins': True}}}, operation='standard_merge')
        request = self.data_requests()[-1]
        self.assertEqual(request['op'], 'merge_propose')
        self.assertEqual(request['settings'], SETTINGS)
        self.assertTrue(request['ignore_global_pins'])
        self.assertEqual(request['preparation']['references'], [{'file_id': REF}])
        self.assertEqual(request['preparation']['outcomes'][0]['input'], 'settings')

    def test_run_again_without_documents_is_unchanged(self):
        self.again({})
        self.assertEqual(self.data_requests(), [{'op': 'plan_propose', 'source': 'input-' + '7' * 32, 'settings': SETTINGS, 'charset': 'utf8mb4'}])
        self.again({'merge': {'options': {}}}, operation='standard_merge')
        self.assertEqual(self.data_requests(), [{'op': 'merge_propose', 'source': 'input-' + '7' * 32, 'settings': SETTINGS}])

    def test_run_again_refuses_rather_than_dropping(self):
        cases = [
            ({'run_inputs': dict(self.manifest, reuse={'from_run': RUN})}, 'STANDARD_RUN_INPUTS_INVALID'),
            ({'run_inputs': dict(self.manifest, files=[dict(self.manifest['files'][0], reuse=True)])}, 'STANDARD_RUN_INPUTS_INVALID'),
            ({'run_inputs': dict(self.manifest, consumer='mappings')}, 'STANDARD_RUN_INPUTS_INVALID'),
            ({'preparation': dict(preparation(), extra=1)}, 'STANDARD_PREPARATION_INVALID'),
            ({'preparation': preparation(questions=[{'id': 'q2', 'text': 'Open?'}])}, 'STANDARD_PREPARATION_UNRESOLVED'),
            ({'preparation': preparation(references=[{'file_id': REF, 'sha256': '9' * 64}])}, 'STANDARD_PREPARATION_INVALID'),
            ({'preparation': preparation(references=[{'file_id': 'file-' + '8' * 32, 'sha256': 'e' * 64}])}, 'STANDARD_PREPARATION_INVALID'),
        ]
        for body, code in cases:
            with self.assertRaises(self.m.Refused) as refused:
                self.again(body)
            self.assertTrue(refused.exception.code.startswith(code), (body, refused.exception.code))
            self.assertFalse(any(request.get('op') in ('plan_propose', 'merge_propose') for request in self.data_requests()), body)

    # -- Preparation jobs are not passes ------------------------------------------------

    def test_master_list_export_is_a_preparation_not_a_pass(self):
        board = self.m.board
        plans = [{'plan_id': PLAN, 'status': 'proposed', 'created_at': '2026-11-12T10:00:00Z'},
                 {'plan_id': LEGACY, 'status': 'consumed', 'created_at': '2026-11-11T10:00:00Z'}]
        bodies = {PLAN: {'operation': 'standard_master_lists', 'master_lists': {'list': 'all'}, 'delivery': {'kind': 'development', 'version': 1}},
                  LEGACY: {'operation': 'standard_convert', 'delivery': {'kind': 'development', 'version': 1}}}
        runs = [{'run_id': RUN, 'plan_id': LEGACY, 'status': 'completed', 'results': {'reconciliation_checks': 1, 'reconciliation_matched': 1}}]
        result = board.build_passes(plans, runs, bodies, {}, [], {})
        self.assertEqual([group['key'] for group in result['passes']], [LEGACY])
        self.assertEqual(result['passes'][0]['status'][0], 'Converted: import next')
        [job] = result['preparations']
        self.assertEqual((job['name'], job['plan_id'], job['plan_status'], job['list'], job['delivery']), ('Master-list export', PLAN, 'proposed', 'all', 'Development v1'))

    def test_static_intake_module_is_served(self):
        self.sock = self.serve()
        conn = Conn(self.sock)
        conn.request('GET', '/intake.js')
        response = conn.getresponse()
        body = response.read()
        conn.close()
        self.assertEqual(response.status, 200)
        self.assertIn(b'export function planSections', body)
        self.assertNotIn(b'insertComposerText', body)


if __name__ == '__main__':
    unittest.main()
