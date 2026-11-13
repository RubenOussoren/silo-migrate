"""Prepared merge environment on the Project page (board.py, server.py). Invented data only.
Run: python3 -I -B test/merge_preparation_board_test.py."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
WIDGET = ROOT / 'integrations/term-llm/widgets/project'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PREP_PLAN, MERGE_PLAN, DIRECT_PLAN = 'plan-' + 'a' * 32, 'plan-' + 'b' * 32, 'plan-' + 'c' * 32
PREP_RUN, MERGE_RUN, DIRECT_RUN = 'run-' + 'a' * 32, 'run-' + 'b' * 32, 'run-' + 'c' * 32
GEN, OTHER_GEN = '1' * 64, '2' * 64
DELIVERY = {'dataset_id': 'dataset-1', 'kind': 'development', 'version': 2}
BASE = {'delivery': {'kind': 'base_site', 'version': 3}, 'discourse_version': '2026.9.0'}
# What a host record could hold beside the safe facts: none of it may reach the page.
LEAK = {'profile_path': '/srv/private/invented-forum/mcp/profile.json', 'api_key': 'invented-secret-key', 'host': 'http://127.0.0.1:40123',
        'backup': 'invented-forum-2026-11-01.tar.gz', 'credentials_file': '/srv/private/k'}


def env(phase='ready', generation=GEN, run_id=PREP_RUN, endpoints=True):
    value = {'preparation_run_id': run_id, 'generation': generation, 'phase': phase, **LEAK}
    if endpoints:
        value['endpoints'] = [{'kind': 'dbhub', 'name': 'silo-arc-source', 'ready': True, **LEAK},
                              {'kind': 'discourse_mcp', 'name': 'silo-arc-base', 'ready': False, 'url': 'http://127.0.0.1:4000/'},
                              {'kind': 'shell', 'name': 'anything', 'ready': True},
                              {'kind': 'dbhub', 'name': '/srv/private/path', 'ready': True}]
    return value


def prep_body():
    return {'operation': 'standard_merge_prepare', 'roles': {'source': 'input-1', 'base_site': 'input-2'}, 'delivery': DELIVERY, 'base_site': BASE}


def merge_body(prepared=True, intent='custom', shape='string'):
    body = {'operation': 'standard_merge', 'roles': {'source': 'input-1', 'base_site': 'input-2', 'settings': 'input-3'}, 'delivery': DELIVERY,
            'base_site': BASE, 'merge': {'options': {'ignore_global_pins': True}, 'layer': {'present': False}}}
    if prepared:
        if shape == 'string':
            body.update(prepared_from=PREP_RUN, generation=GEN)
        else:
            body['prepared_from'] = {'run_id': PREP_RUN, 'generation': GEN}
        if intent:
            body['intent'] = intent
    return body


class BoardTest(unittest.TestCase):
    def setUp(self):
        self.board = load('merge_prep_board', WIDGET / 'board.py')

    def build(self, plans, runs, bodies):
        return self.board.build_passes(plans, runs, bodies, {}, [], {})

    def test_sanitizers_keep_only_fixed_safe_facts(self):
        shown = self.board.merge_environment(env())
        self.assertEqual({'preparation_run_id': PREP_RUN, 'generation': GEN, 'phase': 'ready',
                          'endpoints': [{'kind': 'dbhub', 'name': 'silo-arc-source', 'ready': True},
                                        {'kind': 'discourse_mcp', 'name': 'silo-arc-base', 'ready': False},
                                        {'kind': 'dbhub', 'name': None, 'ready': True}]}, shown)
        for word in ('invented-secret', '/srv/', 'tar.gz', '127.0.0.1', 'shell'):
            self.assertNotIn(word, json.dumps(shown))
        self.assertIsNone(self.board.merge_environment({'phase': '../Ready', 'generation': 'x', 'preparation_run_id': 'run-1'}))
        self.assertIsNone(self.board.merge_environment('ready'))
        self.assertEqual({'run_id': PREP_RUN, 'generation': GEN}, self.board.prepared_from({'run_id': PREP_RUN, 'generation': GEN, **LEAK}))
        self.assertEqual({'run_id': PREP_RUN, 'generation': 4}, self.board.prepared_from(PREP_RUN, 4))
        for bad in ({'run_id': PREP_RUN}, {'run_id': 'run-x', 'generation': GEN}, {'run_id': PREP_RUN, 'generation': True},
                    {'run_id': PREP_RUN, 'generation': 'G' * 64}, None, 7):
            self.assertIsNone(self.board.prepared_from(bad))

    def test_preparation_is_a_distinct_environment_not_a_pass_and_has_no_output(self):
        plans = [{'plan_id': PREP_PLAN, 'status': 'consumed', 'created_at': '2026-11-01T00:00:00Z'}]
        runs = [{'run_id': PREP_RUN, 'plan_id': PREP_PLAN, 'status': 'completed', 'started_at': '2026-11-01T01:00:00Z',
                 'artifacts': {'backup': {'bytes': 9}}, 'release': {'outbox': '/x'}, 'results': {'merge_environment': env(), 'review_url': 'http://127.0.0.1:4000/'}}]
        result = self.build(plans, runs, {PREP_PLAN: prep_body()})
        self.assertEqual([], result['passes'])
        self.assertIsNone(result['banner'])
        [item] = result['environments']
        self.assertEqual(('merge_prepare', 'Prepare merge environment'), (item['kind'], item['name']))
        self.assertEqual(('Ready: inspect, then propose the merge', 'now'), item['status'])
        self.assertTrue(item['live'])
        self.assertEqual((None, None, 'none', {}), (item['step']['backup'], item['step']['release'], item['step']['backup_state'], item['step']['results']))
        self.assertEqual('Base site v3', item['base_site'])
        self.assertEqual('Development v2', item['delivery'])
        for word in ('invented-secret', '/srv/', 'tar.gz', '127.0.0.1'):
            self.assertNotIn(word, json.dumps(result))

    def test_environment_status_follows_the_hosts_phase(self):
        def status(run_status=None, plan_status='proposed', phase=None, used=()):
            step = {'run_status': run_status, 'plan_status': plan_status}
            return self.board.environment_status(step, {'phase': phase} if phase else None, list(used))
        self.assertEqual('Waiting for your approval', status()[0])
        self.assertEqual('Out of date: propose it again', status(plan_status='stale')[0])
        self.assertEqual('Running', status('running')[0])
        self.assertEqual('Preparation needs a look', status('failed')[0])
        self.assertEqual('Ready: inspect, then propose the merge', status('completed', phase='inspection')[0])
        self.assertEqual('Ready: inspect, then propose the merge', status('completed', phase='ready', used=[2])[0])  # a refused merge left it clean
        self.assertEqual('In use by a merge', status('completed', phase='merging')[0])
        self.assertEqual('Used by a merge', status('completed', phase='consumed')[0])
        self.assertEqual('Used by a merge', status('completed', used=[2])[0])
        self.assertEqual('Not clean: prepare it again', status('completed', phase='dirty')[0])
        self.assertEqual('Reset', status('completed', phase='reset')[0])
        self.assertEqual('Prepared: state unknown', status('completed')[0])

    def test_another_runs_environment_is_never_shown_as_this_one(self):
        plans = [{'plan_id': PREP_PLAN, 'status': 'consumed', 'created_at': '2026-11-01T00:00:00Z'}]
        runs = [{'run_id': PREP_RUN, 'plan_id': PREP_PLAN, 'status': 'completed', 'merge_environment': env(run_id=MERGE_RUN)}]
        [item] = self.build(plans, runs, {PREP_PLAN: prep_body()})['environments']
        self.assertIsNone(item['environment'])
        self.assertFalse(item['live'])

    def test_a_prepared_merge_pass_names_its_binding_and_the_environment_names_the_pass(self):
        plans = [{'plan_id': PREP_PLAN, 'status': 'consumed', 'created_at': '2026-11-01T00:00:00Z'},
                 {'plan_id': MERGE_PLAN, 'status': 'consumed', 'created_at': '2026-11-02T00:00:00Z'},
                 {'plan_id': DIRECT_PLAN, 'status': 'consumed', 'created_at': '2026-10-01T00:00:00Z'}]
        runs = [{'run_id': PREP_RUN, 'plan_id': PREP_PLAN, 'status': 'completed', 'merge_environment': env('consumed')},
                {'run_id': MERGE_RUN, 'plan_id': MERGE_PLAN, 'status': 'completed', 'started_at': '2026-11-02T01:00:00Z'},
                {'run_id': DIRECT_RUN, 'plan_id': DIRECT_PLAN, 'status': 'completed', 'started_at': '2026-10-01T01:00:00Z'}]
        result = self.build(plans, runs, {PREP_PLAN: prep_body(), MERGE_PLAN: merge_body(shape='dict'), DIRECT_PLAN: merge_body(prepared=False)})
        prepared, direct = result['passes']
        self.assertEqual((2, {'run_id': PREP_RUN, 'generation': GEN}), (prepared['number'], prepared['prepared_from']))
        self.assertEqual((1, None), (direct['number'], direct['prepared_from']))  # the legacy direct merge is unchanged
        self.assertEqual(('Merged', 'ok'), prepared['status'])
        [item] = result['environments']
        self.assertEqual(([2], 'Used by a merge'), (item['used_by'], item['status'][0]))

    def test_a_proposed_prepared_merge_is_listed_and_blocks_the_shortcut_banner(self):
        plans = [{'plan_id': PREP_PLAN, 'status': 'consumed', 'created_at': '2026-11-01T00:00:00Z'},
                 {'plan_id': MERGE_PLAN, 'status': 'proposed', 'created_at': '2026-11-02T00:00:00Z'}]
        runs = [{'run_id': PREP_RUN, 'plan_id': PREP_PLAN, 'status': 'completed', 'merge_environment': env()}]
        result = self.build(plans, runs, {PREP_PLAN: prep_body(), MERGE_PLAN: merge_body()})
        self.assertEqual([1], result['environments'][0]['proposed_merges'])
        self.assertEqual('Waiting for your approval', result['passes'][0]['status'][0])

    def test_a_live_environment_suppresses_the_unbound_rerun_banner(self):
        plans = [{'plan_id': DIRECT_PLAN, 'status': 'consumed', 'created_at': '2026-10-01T00:00:00Z'},
                 {'plan_id': PREP_PLAN, 'status': 'consumed', 'created_at': '2026-11-01T00:00:00Z'}]
        runs = [{'run_id': DIRECT_RUN, 'plan_id': DIRECT_PLAN, 'status': 'completed', 'started_at': '2026-10-01T01:00:00Z'},
                {'run_id': PREP_RUN, 'plan_id': PREP_PLAN, 'status': 'completed', 'started_at': '2026-11-01T01:00:00Z', 'merge_environment': env()}]
        pushes = [{'digest': 'd1', 'status': 'pushed', 'pushed_at': '2026-11-03T00:00:00Z', 'proposal': {'head': 'f' * 40, 'title': 'Layer'}}]
        bodies = {DIRECT_PLAN: merge_body(prepared=False), PREP_PLAN: prep_body()}
        self.assertIsNone(self.board.build_passes(plans, runs, bodies, {}, pushes, {})['banner'])
        runs[1]['merge_environment'] = env('reset')
        self.assertEqual('converter', self.board.build_passes(plans, runs, bodies, {}, pushes, {})['banner']['kind'])  # as before


class ServerTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.top = Path(temp.name)
        self.base = self.top / 'workspaces'
        self.standard = self.base / 'arc/.silo-migrate/named/standard'
        self.standard.mkdir(parents=True)
        self.record = self.top / 'calls.jsonl'
        self.control = self.top / 'control'
        self.control.write_text('''#!/usr/bin/env python3
import json, os, sys
request = json.loads(sys.stdin.read()) if sys.argv[1] == 'data' else None
with open(os.environ['CALLS'], 'a') as out:
    out.write(json.dumps([sys.argv[1:], request]) + '\\n')
print(json.dumps({'status': 'proposed', 'plan_id': 'plan-' + 'f' * 32}))
''')
        self.control.chmod(0o700)
        os.environ['CALLS'] = str(self.record)
        self.addCleanup(os.environ.pop, 'CALLS', None)
        self.m = load('merge_prep_server', WIDGET / 'server.py')

    def state(self, environment, merge=None, prep_status='completed'):
        state = {'plans': {PREP_PLAN: {'body': prep_body(), 'created_at': '1'}, MERGE_PLAN: {'body': merge or merge_body(), 'created_at': '2'},
                           DIRECT_PLAN: {'body': merge_body(prepared=False), 'created_at': '0'}},
                 'runs': {PREP_RUN: {'plan_id': PREP_PLAN, 'status': prep_status, 'merge_environment': environment},
                          MERGE_RUN: {'plan_id': MERGE_PLAN, 'status': 'failed'},
                          DIRECT_RUN: {'plan_id': DIRECT_PLAN, 'status': 'completed'}}}
        (self.standard / 'state.json').write_text(json.dumps(state))

    def requests(self):
        return [json.loads(line)[1] for line in self.record.read_text().splitlines()] if self.record.exists() else []

    def again(self, run_id):
        return self.m.propose_again(self.base, str(self.control), {'workspace': 'arc', 'run_id': run_id})

    def test_run_again_for_a_preparation_reproposes_merge_prepare_only(self):
        self.state(env())
        self.again(PREP_RUN)
        self.assertEqual([{'op': 'merge_prepare', 'source': 'input-1'}], self.requests())

    def test_a_prepared_merge_continues_only_in_the_same_ready_generation(self):
        for phase in ('ready', 'inspection'):
            self.state(env(phase))
            self.again(MERGE_RUN)
        self.assertEqual({'op': 'merge_propose', 'source': 'input-1', 'ignore_global_pins': True, 'settings': 'input-3',
                          'prepared_from': PREP_RUN, 'generation': GEN, 'intent': 'custom'}, self.requests()[0])
        self.assertEqual(self.requests()[0], self.requests()[1])

    def test_a_stale_environment_refuses_instead_of_switching_to_a_fresh_merge(self):
        cases = [(env('consumed'), None, 'completed'), (env('dirty'), None, 'completed'), (env('reset'), None, 'completed'),
                 (env(generation=OTHER_GEN), None, 'completed'), (env(run_id=DIRECT_RUN), None, 'completed'),
                 (env(), None, 'failed'), (None, None, 'completed')]
        for environment, merge, status in cases:
            self.state(environment, merge, status)
            with self.assertRaises(self.m.Refused) as refused:
                self.again(MERGE_RUN)
            self.assertTrue(refused.exception.code.startswith('STANDARD_MERGE_ENVIRONMENT_STALE'), refused.exception.code)
            self.assertEqual(409, refused.exception.status)
        self.state(env(), merge_body(intent=None))
        with self.assertRaises(self.m.Refused) as refused:
            self.again(MERGE_RUN)  # never guesses stock or custom
        self.assertTrue(refused.exception.code.startswith('STANDARD_MERGE_ENVIRONMENT_INVALID'))
        broken = merge_body()
        broken['generation'] = 'not-a-generation'
        self.state(env(), broken)
        with self.assertRaises(self.m.Refused) as refused:
            self.again(MERGE_RUN)
        self.assertEqual('STANDARD_MERGE_ENVIRONMENT_INVALID', refused.exception.code)
        self.assertEqual([], self.requests())

    def test_the_legacy_direct_merge_rerun_is_unchanged(self):
        self.state(env())
        self.again(DIRECT_RUN)
        self.assertEqual([{'op': 'merge_propose', 'source': 'input-1', 'ignore_global_pins': True, 'settings': 'input-3'}], self.requests())

    def test_plan_detail_hides_backup_names_and_raw_environment_fields(self):
        self.state(env())
        shown = {'operation': 'standard_merge_prepare', 'plan_id': PREP_PLAN, 'roles': {'source': 'input-1', 'base_site': 'input-2'},
                 'input_paths': {'input-1': 'inputs/invented-forum-2026-11-01.tar.gz', 'input-2': 'inputs/invented-target.sql.gz'},
                 'merge_environment': env(), 'inspection': LEAK, 'connectors': [LEAK]}
        with mock.patch.object(self.m.runs, 'plan_detail', return_value=shown), mock.patch.object(self.m.intake, 'plan_view', return_value=None):
            result = self.m.plan_detail(self.m.runs.Store(self.base), str(self.control), 'arc', PREP_PLAN)
        self.assertEqual({}, result['input_paths'])
        self.assertEqual('ready', result['merge_environment']['phase'])
        self.assertNotIn('inspection', result)
        self.assertNotIn('connectors', result)
        for word in ('invented-', '/srv/', '127.0.0.1'):
            self.assertNotIn(word, json.dumps(result))
        shown = {'operation': 'standard_merge', 'plan_id': MERGE_PLAN, 'roles': {}, 'prepared_from': PREP_RUN, 'generation': GEN, 'intent': 'stock'}
        with mock.patch.object(self.m.runs, 'plan_detail', return_value=shown), mock.patch.object(self.m.intake, 'plan_view', return_value=None):
            result = self.m.plan_detail(self.m.runs.Store(self.base), str(self.control), 'arc', MERGE_PLAN)
        self.assertEqual({'run_id': PREP_RUN, 'generation': GEN}, result['prepared_from'])
        self.assertEqual('stock', result['intent'])

    def test_a_prepare_run_offers_no_backup_release_review_url_or_password(self):
        self.state(env())
        shown = {'operation': 'standard_merge_prepare', 'run_id': PREP_RUN, 'plan_id': PREP_PLAN, 'status': 'completed',
                 'artifacts': {'backup': {'bytes': 1}}, 'release': {'outbox': '/x'}, 'mcp': LEAK,
                 'results': {'review_url': 'http://127.0.0.1:4000/', 'merge_environment': env(), 'connectors': [LEAK], 'review_runtime': {'actual_version': '2026.9.0'}}}
        with mock.patch.object(self.m.runs, 'run_detail', return_value=shown):
            result = self.m.run_detail(self.m.runs.Store(self.base), str(self.control), 'arc', PREP_RUN)
        self.assertIsNone(result['release'])
        self.assertEqual({}, result['artifacts'])
        self.assertEqual({'review_runtime': {'actual_version': '2026.9.0'}}, result['results'])
        self.assertEqual(GEN, result['merge_environment']['generation'])
        for word in ('invented-secret', '/srv/', '127.0.0.1', 'tar.gz'):
            self.assertNotIn(word, json.dumps(result))
        with mock.patch.object(self.m.runs, 'decide') as decide, self.assertRaises(self.m.Refused) as refused:
            self.m.no_prepared_sign_in(self.m.runs.Store(self.base), {'workspace': 'arc', 'run_id': PREP_RUN})
        self.assertEqual('STANDARD_PREPARED_ENVIRONMENT_NO_SIGN_IN', refused.exception.code)
        decide.assert_not_called()
        self.m.no_prepared_sign_in(self.m.runs.Store(self.base), {'workspace': 'arc', 'run_id': DIRECT_RUN})  # merged sites keep theirs

    def test_board_reads_the_recorded_environment_when_status_leaves_it_out(self):
        self.state(env())
        view = {'plans': [{'plan_id': PREP_PLAN, 'status': 'consumed', 'created_at': '2026-11-01T00:00:00Z'}],
                'runs': [{'run_id': PREP_RUN, 'plan_id': PREP_PLAN, 'status': 'completed'}], 'converter': {}}
        with mock.patch.object(self.m.runs, 'overview', return_value=view):
            result = self.m.passes_of(self.base, str(self.control), 'arc')
        self.assertEqual('ready', result['environments'][0]['environment']['phase'])
        self.assertNotIn('/srv/', json.dumps(result))


class PageSourceTest(unittest.TestCase):
    def test_prepare_is_worded_as_its_own_operation_with_no_release_or_password(self):
        source = (WIDGET / 'runs.js').read_text()
        self.assertIn("'standard_merge_prepare'", source)
        self.assertIn("'Prepare merge environment'", source)
        self.assertIn('if (data.operation === PREPARE) return prepareRun(data);', source)
        prepare_run = source[source.index('function prepareRun('):source.index('function run(data)')]
        for word in ('admin-password', 'releaseButton', 'backupRows', 'review_url', "act('release'"):
            self.assertNotIn(word, prepare_run)
        self.assertIn('no migration has run', source)
        self.assertIn('The backups are not restored anew', source)
        self.assertIn('it never switches to a fresh restore', source)
        endpoints = source[source.index('const endpointRows'):source.index('const live =')]
        for word in ('profile', 'url', 'path', 'host', 'key'):
            self.assertNotIn(word, endpoints.lower())  # only the fixed kind, name and readiness
        for word in ('innerHTML', 'https://'):
            self.assertNotIn(word, source)


if __name__ == '__main__':
    unittest.main()
