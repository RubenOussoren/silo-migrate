"""Host lifecycle cleanup dispatch: no Docker, keys, term-llm calls or customer files."""
import contextlib
import importlib.machinery
import io
import json
import importlib.util
from pathlib import Path
import re
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load():
    loader = importlib.machinery.SourceFileLoader('merge_control_fixture', str(ROOT / 'bin/silo-migrate-control'))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class MergeControlDispatchTest(unittest.TestCase):
    def setUp(self):
        self.control = load()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        state_path = self.base / 'invented/.silo-migrate/named/standard/state.json'
        state_path.parent.mkdir(parents=True)
        state_path.write_text('{}')
        self.prepared, self.merged = 'run-' + 'a' * 32, 'run-' + 'b' * 32
        self.plan = 'plan-' + 'c' * 32
        self.state = {'plans': {self.plan: {'body': {'operation': 'standard_merge',
                       'prepared_from': {'run_id': self.prepared, 'generation': 'd' * 64}}}},
                      'runs': {self.merged: {'plan_id': self.plan, 'status': 'claimed',
                       'merge_environment': {'preparation_run_id': self.prepared, 'consumed_by': self.merged}}}}
        self.workspace = types.SimpleNamespace(name='invented')
        self.data = types.SimpleNamespace(WORKSPACE=re.compile(r'[A-Za-z0-9][A-Za-z0-9_-]{0,62}\Z'),
                                         RUN=re.compile(r'run-[0-9a-f]{32}\Z'),
                                         Workspace=lambda *args: self.workspace, standard_state=lambda ws: self.state)
        self.connector = types.SimpleNamespace(cleanup=mock.Mock())
        self.patch_data = mock.patch.object(self.control, 'data_tools', return_value=self.data)
        self.patch_connector = mock.patch.object(self.control, 'merge_inspection_module', return_value=self.connector)
        self.patch_data.start()
        self.patch_connector.start()
        self.addCleanup(self.patch_data.stop)
        self.addCleanup(self.patch_connector.stop)

    def invoke(self, args):
        self.control.host_merge_lifecycle_cleanup(args, {}, self.base, ROOT, object())

    def reset_result(self):
        return {'version': 1, 'attempt_id': 'e' * 32, 'prepared_from': self.prepared,
                'generation': 'f' * 64, 'intent_sha256': 'd' * 64, 'status': 'reset_retired',
                'actions': ['fence_inspection', 'remove_preparation_stack', 'verify_runtime_absence', 'retire_legacy_quarantine'],
                'persistent_work': {'merger_commit': 'a' * 40, 'registered_inputs': 'verified'},
                'historical_producer': 'unproven', 'next_action': 'prepare_new_environment'}

    def finish_reset(self, result):
        args = ['standard', 'workflow', 'validation-reset-apply', 'invented', '--attempt', 'e' * 32,
                '--intent-sha256', 'd' * 64, '--yes']
        self.state['plans'][self.plan]['body'] = {'operation': 'standard_merge_prepare'}
        self.state['runs'][self.prepared] = {'status': 'completed', 'plan_id': self.plan,
                'merge_environment': {'preparation_run_id': self.prepared, 'phase': 'reset'}}
        output = io.StringIO()
        with mock.patch.object(self.control, 'capture', return_value=json.dumps(result)) as capture, \
                contextlib.redirect_stdout(output):
            code = self.control.host_validation_reset_apply(['docker', 'run', 'fixture'], args, {}, self.base, ROOT, object())
        self.assertEqual(0, code)
        capture.assert_called_once_with(['docker', 'run', 'fixture'], passthrough=True, timeout=1800)
        return output.getvalue()

    def test_reset_connector_cleanup_occurs_only_after_valid_backend_retirement(self):
        result = self.reset_result()
        self.assertEqual(result, json.loads(self.finish_reset(result)))
        self.connector.cleanup.assert_called_once()
        self.assertEqual(self.prepared, self.connector.cleanup.call_args.kwargs['run_id'])

    def test_reset_unknown_backend_outcome_never_cleans_or_replays(self):
        with mock.patch.object(self.control, 'capture', side_effect=ValueError('STANDARD_OPERATION_FAILED')) as capture:
            with self.assertRaisesRegex(ValueError, '^STANDARD_OPERATION_FAILED$'):
                self.control.host_validation_reset_apply(['docker'], [], {}, self.base, ROOT, object())
        capture.assert_called_once()
        self.connector.cleanup.assert_not_called()

    def test_reset_malformed_or_private_backend_projection_is_not_forwarded(self):
        for field, value in [('prepared_from', '../private'), ('status', 'preview'), ('attempt_id', 'f' * 32),
                             ('historical_producer', 'completed'), ('unexpected', 'PRIVATE')]:
            result = self.reset_result()
            result[field] = value
            with self.assertRaisesRegex(ValueError, '^STANDARD_OPERATION_FAILED$'):
                self.finish_reset(result)
        self.connector.cleanup.assert_not_called()

    def test_completed_reset_with_failed_connector_cleanup_has_fixed_retryable_error(self):
        self.connector.cleanup.side_effect = ValueError('PRIVATE config error')
        with self.assertRaisesRegex(ValueError, '^STANDARD_MERGE_RESET_CONNECTORS_UNCONFIRMED$'):
            self.finish_reset(self.reset_result())
        self.connector.cleanup.side_effect = None
        self.assertEqual('reset_retired', json.loads(self.finish_reset(self.reset_result()))['status'])

    def test_ready_start_and_consumed_execute_preserve_inspection(self):
        for phase in ('ready', 'consumed'):
            self.state['runs'][self.prepared] = {'merge_environment': {'phase': phase}}
            self.invoke(['standard', 'run', 'start', 'invented', self.plan])
            self.invoke(['standard', 'run', 'execute', 'invented', self.merged])
        self.connector.cleanup.assert_not_called()

    def test_post_activation_execute_cleans_exact_owned_registrations(self):
        self.state['runs'][self.prepared] = {'merge_environment': {'phase': 'merging'}}
        self.invoke(['standard', 'run', 'execute', 'invented', self.merged])
        self.assertEqual([self.prepared, self.merged], [call.kwargs['run_id'] for call in self.connector.cleanup.call_args_list])

    def test_read_commands_never_load_state_or_cleanup(self):
        self.data.standard_state = mock.Mock(side_effect=AssertionError('read mutated'))
        for args in (['standard', 'status', 'invented'], ['standard', 'run', 'show', 'invented', self.merged],
                     ['standard', 'plan', 'show', 'invented', self.plan]):
            self.invoke(args)
        self.connector.cleanup.assert_not_called()

    def test_busy_reset_does_not_disrupt_an_active_environment(self):
        self.invoke(['standard', 'run', 'reset', 'invented', self.merged, '--yes'])
        self.connector.cleanup.assert_not_called()
        self.state['runs'][self.merged]['status'] = 'completed'
        self.invoke(['standard', 'run', 'reset', 'invented', self.merged, '--yes'])
        self.assertEqual(2, self.connector.cleanup.call_count)

    def test_legacy_run_does_not_touch_merge_connectors(self):
        self.state['plans'][self.plan]['body'].pop('prepared_from')
        self.state['runs'][self.merged].pop('merge_environment')
        self.invoke(['standard', 'run', 'execute', 'invented', self.merged])
        self.connector.cleanup.assert_not_called()

    def test_invalid_bound_run_is_not_used_for_cleanup(self):
        self.state['plans'][self.plan]['body']['prepared_from']['run_id'] = '../other-project'
        with self.assertRaisesRegex(ValueError, 'STANDARD_MERGE_INSPECTION_INVALID'):
            self.invoke(['standard', 'run', 'start', 'invented', self.plan])
        self.connector.cleanup.assert_not_called()


if __name__ == '__main__':
    unittest.main()
