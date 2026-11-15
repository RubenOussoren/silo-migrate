"""Saved validation wire boundary; no Docker, customer data or runtime execution.
Run: python3 -I -B test/data_validation_adapter_test.py
"""
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / 'integrations/term-llm/migration-data/scripts/data_tool.py'
ATTEMPT = 'a' * 32
CODE = 'STANDARD_MERGE_VALIDATION_FAILED'
CANARY = '/private/CUSTOMER-secret-settings'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def projection():
    diagnostic = {'reason': 'policy_conflict', 'stage': 'guest_validation',
                  'deadline_reached': False, 'command_outcome': 'failed'}
    return {'version': 1, 'attempt_id': ATTEMPT,
            'evidence': {'receipt': 'saved', 'journal': 'saved'},
            'status': 'refused', 'reason': 'policy_conflict',
            'work': dict(diagnostic, status='refused'), 'producer_outcome': 'completed',
            'cleanup': dict(diagnostic, status='confirmed'),
            'last_recorded_stage': 'cleanup_absence',
            'events': [{'stage': 'guest_validation', 'phase': 'finish',
                        'elapsed_ms': 123, 'outcome': 'failed'}],
            'key_path_segments': 2, 'next_action': 'inspect_private_evidence_and_correct_cause'}


def envelope():
    return {'version': 1, 'error': CODE, 'validation': projection()}


class ValidationAdapterTest(unittest.TestCase):
    def setUp(self):
        self.data = load('validation_data', ROOT / 'bin/data_tools.py')
        self.adapter = load('validation_adapter', ADAPTER)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        root = self.base / 'fixture'
        named = root / '.silo-migrate/named'
        (named / 'standard').mkdir(parents=True)
        (named / 'state.json').write_text('{"inputs":{}}')
        (named / 'standard/state.json').write_text('{}')
        (root / '.silo-migrate/data').mkdir()
        (root / '.silo-migrate/data/workspace.json').write_text('{"platform":"discourse"}')
        self.control = self.data.control_runner('fixed-control')
        self.ws = self.data.Workspace(self.base, 'fixture', ROOT, None, {}, self.control)

    def invoke(self, request):
        return self.data.main(['data', 'fixture'], {}, self.base, ROOT, None,
                              io.StringIO(json.dumps(request)), self.control)

    def completed(self, value, code=0, stderr=''):
        return subprocess.CompletedProcess([], code, json.dumps(value), stderr)

    def snapshot(self):
        return {str(p.relative_to(self.base)): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}

    def test_status_dispatch_latest_and_exact_no_writes(self):
        before = self.snapshot()
        for selector in (None, 'latest', ATTEMPT):
            request = {'op': 'workflow_validation_status', 'via': 'chat'}
            if selector is not None:
                request['attempt'] = selector
            with mock.patch.object(self.data.subprocess, 'run', return_value=self.completed(projection())) as run:
                self.assertEqual(projection(), self.invoke(request))
            self.assertEqual(['fixed-control', 'standard', 'workflow', 'validation-status', 'fixture',
                              '--attempt', selector or 'latest'], run.call_args.args[0])
            self.assertEqual(subprocess.DEVNULL, run.call_args.kwargs['stdin'])
        self.assertEqual(before, self.snapshot())

    def test_invalid_status_requests_never_call_control(self):
        for extra in ({'attempt': '../x'}, {'attempt': 'A' * 32}, {'attempt': False},
                      {'workspace': 'other'}, {'apply': True}, {'settings': CANARY},
                      {'attempt': 'latest', 'recovery': 'apply'}):
            with self.subTest(extra=extra), mock.patch.object(self.data.subprocess, 'run') as run:
                with self.assertRaises(self.data.Refusal):
                    self.invoke({'op': 'workflow_validation_status', **extra})
                run.assert_not_called()
        self.assertFalse(any('recovery' in name for name in self.data.OPS))

    def test_projection_rejects_unknown_malformed_and_private_values(self):
        for target, key, bad in [('root', 'path', CANARY), ('root', 'status', CANARY),
                                 ('root', 'version', True), ('root', 'attempt_id', CANARY),
                                 ('root', 'key_path_segments', 33), ('root', 'key_path_segments', True),
                                 ('work', 'reason', CANARY), ('work', 'stage', CANARY),
                                 ('cleanup', 'deadline_reached', 0), ('cleanup', 'counts', {'secret': 1}),
                                 ('event', 'elapsed_ms', 86400001), ('event', 'elapsed_ms', True),
                                 ('event', 'outcome', CANARY), ('event', 'path', CANARY),
                                 ('root', 'next_action', 'apply_recovery')]:
            value = projection()
            obj = value if target == 'root' else value['events'][0] if target == 'event' else value[target]
            obj[key] = bad
            with self.subTest(target=target, key=key), self.assertRaises(self.data.Refusal):
                self.data.validation_json(json.dumps(value))
        for raw in ('null', '[]', '{', '{"version":1,"version":1}', 'x' * 50000):
            with self.assertRaises(self.data.Refusal):
                self.data.validation_json(raw)
        value = projection()
        value['events'] *= 129
        with self.assertRaises(self.data.Refusal):
            self.data.validation_projection(value)
        value = projection()
        value['attempt_id'] = 'b' * 32
        with mock.patch.object(self.data.subprocess, 'run', return_value=self.completed(value)):
            with self.assertRaises(self.data.Refusal):
                self.invoke({'op': 'workflow_validation_status', 'attempt': ATTEMPT})

    def test_host_error_classes_and_fixed_boundaries_survive_without_message_or_private_class(self):
        value = projection()
        value['work'].update(stage='private_staging', error_class='Errno::EACCES')
        self.assertEqual(value, self.data.validation_json(json.dumps(value)))
        for bad in (CANARY, 'CustomerSpecificError', None, [], True):
            value['work']['error_class'] = bad
            with self.subTest(bad=bad), self.assertRaises(self.data.Refusal):
                self.data.validation_json(json.dumps(value))
        value['work']['error_class'] = 'Errno::EACCES'
        value['work']['message'] = CANARY
        with self.assertRaises(self.data.Refusal):
            self.data.validation_json(json.dumps(value))

    def test_fixed_guest_diagnostic_survives_but_raw_messages_private_classes_and_paths_do_not(self):
        diagnostic = {'version': 1, 'stage': 'rails_boot', 'error_class': 'PG::InsufficientPrivilege',
                      'component': 'stock_runtime', 'line': 42}
        value = projection()
        value['guest_diagnostic'] = diagnostic
        self.assertEqual(value, self.data.validation_json(json.dumps(value)))
        failure = {'version': 1, 'error': CODE, 'validation': value}
        result, _ = self.wrapper_call('data_merge_propose', {}, self.completed(failure, 1, 'Error: ' + CODE))
        self.assertEqual(failure, result)
        for bad in (dict(diagnostic, message=CANARY), dict(diagnostic, error_class=CANARY),
                    dict(diagnostic, component=CANARY), dict(diagnostic, stage=CANARY),
                    dict(diagnostic, line=True), dict(diagnostic, line=1000001),
                    dict(diagnostic, component='custom_layer'), dict(diagnostic, component='unknown')):
            value['guest_diagnostic'] = bad
            with self.assertRaises(self.data.Refusal):
                self.data.validation_json(json.dumps(value))

    def test_legacy_unknown_and_missing_are_not_success(self):
        for action in ('reconcile_legacy_attempt', 'reconcile_unknown_producer', 'no_saved_attempt'):
            value = projection()
            value.update(status='unknown', producer_outcome='unknown', next_action=action)
            value['work'].update(status='unknown', command_outcome='unknown')
            value['cleanup']['status'] = 'unconfirmed'
            if action == 'no_saved_attempt':
                value['attempt_id'] = None
                value['evidence'] = {'receipt': 'missing', 'journal': 'missing'}
            self.assertEqual(value, self.data.validation_json(json.dumps(value)))

    def proposal_request(self):
        return {'op': 'merge_propose', 'via': 'chat', 'prepared_from': 'run-' + 'b' * 32,
                'generation': 'c' * 64, 'intent': 'custom'}

    def test_actual_control_runner_and_merge_propose_preserve_failure(self):
        failure = envelope()
        result = self.completed(failure, 1, 'Error: ' + CODE + '\n')
        with mock.patch.object(self.data.subprocess, 'run', return_value=result) as run:
            actual = self.invoke(self.proposal_request())
        self.assertEqual(failure, actual)
        self.assertEqual(1, run.call_count)
        argv = run.call_args.args[0]
        self.assertEqual(['fixed-control', 'standard', 'plan', 'propose', 'fixture'], argv[:5])
        self.assertIn('--intent', argv)
        self.assertNotIn('validate', argv)
        self.assertNotIn('recovery', argv)
        # Failure does not become a successful audit entry.
        audit = self.ws.data / 'audit.jsonl'
        self.assertEqual(CODE, json.loads(audit.read_text().splitlines()[-1])['result'])

    def test_bridge_refuses_private_or_malformed_failure_stdout(self):
        values = [dict(envelope(), path=CANARY), {'version': 1, 'error': CODE, 'validation': CANARY},
                  {'version': 1, 'error': CODE}, {'version': 1, 'error': CANARY}, None]
        bad = envelope()
        bad['validation']['work']['counts'] = {CANARY: 99}
        values.append(bad)
        for value in values:
            with self.subTest(value=value), mock.patch.object(self.data.subprocess, 'run', return_value=self.completed(value, 1, 'Error: ' + CODE)):
                with self.assertRaises(self.data.Refusal) as caught:
                    self.invoke(self.proposal_request())
                self.assertEqual(CODE, str(caught.exception))
                self.assertNotIn(CANARY, str(caught.exception))
        # Even a well-formed envelope cannot be used on another command.
        with mock.patch.object(self.data.subprocess, 'run', return_value=self.completed(envelope(), 1, 'Error: ' + CODE)):
            with self.assertRaises(self.data.Refusal) as caught:
                self.control(['standard', 'workflow', 'validate', 'fixture'])
            self.assertNotIsInstance(caught.exception, self.data.ValidationFailure)

    def wrapper_call(self, tool, args, result):
        with mock.patch.dict(os.environ, {'TERM_LLM_TOOL_NAME': tool}), \
                mock.patch.object(self.adapter.sys, 'stdin', io.StringIO(json.dumps(args))), \
                mock.patch.object(self.adapter, 'chat_project', return_value='fixture'), \
                mock.patch.object(self.adapter.subprocess, 'run', return_value=result) as run, \
                mock.patch.object(self.adapter.sys, 'stdout', new_callable=io.StringIO) as output:
            self.assertEqual(0, self.adapter.main())
            value = json.loads(output.getvalue())
        return value, run

    def test_tool_schema_and_wrapper_dispatch(self):
        definition = (ADAPTER.parents[1] / 'agent.yaml').read_text()
        block = re.search(r'    - name: data_workflow_validation_status\n(.*?)(?=    - name:)', definition, re.S).group(1)
        self.assertIn('additionalProperties: false', block)
        self.assertIn('^(latest|[0-9a-f]{32})$', block)
        self.assertNotIn('required:', block)
        for args in ({}, {'attempt': 'latest'}, {'attempt': ATTEMPT}):
            value, run = self.wrapper_call('data_workflow_validation_status', args, self.completed(projection()))
            self.assertEqual(projection(), value)
            self.assertEqual(['data', 'fixture'], run.call_args.args[0][-2:])
            self.assertEqual({'op': 'workflow_validation_status', **args, 'via': 'chat'},
                             json.loads(run.call_args.kwargs['input']))
        for args in ({'attempt': '../x'}, {'apply': True}, {'workspace': 'other'}, {'attempt': None}):
            value, run = self.wrapper_call('data_workflow_validation_status', args, self.completed(projection()))
            self.assertEqual('STANDARD_ARGUMENTS_INVALID', value['error'])
            run.assert_not_called()
        for agent in ('converter-developer', 'converter-reviewer'):
            self.assertNotIn('data_workflow_validation_status', (ROOT / 'integrations/term-llm' / agent / 'agent.yaml').read_text())
        self.assertFalse(any('recovery' in name for name in self.adapter.TOOLS))

    def test_real_wrapper_to_data_to_control_subprocess_chain(self):
        # Only the service CLI is a synthetic executable. The adapter main,
        # Workspace/control_runner, operation, parsers and JSON transport are real.
        shim = self.base / 'control'
        shim.write_text("#!/usr/bin/env python3\n" + f"""
import importlib.machinery, importlib.util, io, json, pathlib, sys
spec = importlib.util.spec_from_file_location('data', {str(ROOT / 'bin/data_tools.py')!r})
data = importlib.util.module_from_spec(spec)
spec.loader.exec_module(data)
base = pathlib.Path({str(self.base)!r})
args = sys.argv[1:]
with (base / 'calls').open('a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:1] == ['data']:
    loader = importlib.machinery.SourceFileLoader('control', {str(ROOT / 'bin/silo-migrate-control')!r})
    control_spec = importlib.util.spec_from_loader(loader.name, loader)
    control = importlib.util.module_from_spec(control_spec)
    sys.modules[loader.name] = control
    loader.exec_module(control)
    control.data_tools = lambda: data
    sys.exit(control.host_data(args, {{}}, base, pathlib.Path(__file__)))
elif args[:3] == ['standard', 'workflow', 'validation-status']:
    print({json.dumps(projection())!r})
elif args[:3] == ['standard', 'plan', 'propose']:
    print({json.dumps(envelope())!r})
    print('Error: {CODE}', file=sys.stderr)
    sys.exit(1)
else:
    sys.exit(90)
""")
        shim.chmod(0o700)
        # The fixture workspace is also the fixed chat project.
        env = dict(os.environ, SILO_CONTROL=str(shim), SILO_TESTING='1',
                   SILO_PROJECTS_ROOT=str(self.base), PYTHONDONTWRITEBYTECODE='1')
        for tool, args, expected in (
                ('data_workflow_validation_status', {}, projection()),
                ('data_merge_propose', {key: value for key, value in self.proposal_request().items()
                                        if key not in ('op', 'via')}, envelope())):
            env['TERM_LLM_TOOL_NAME'] = tool
            result = subprocess.run([sys.executable, '-I', '-B', str(ADAPTER)],
                                    input=json.dumps(args), text=True, capture_output=True,
                                    env=env, cwd=self.ws.root, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual('', result.stderr)
            self.assertEqual(expected, json.loads(result.stdout))
        calls = [json.loads(line) for line in (self.base / 'calls').read_text().splitlines()]
        self.assertEqual(4, len(calls))
        self.assertEqual(['standard', 'workflow', 'validation-status', 'fixture', '--attempt', 'latest'], calls[1])
        self.assertEqual(['standard', 'plan', 'propose', 'fixture'], calls[3][:4])
        # CLI/Project-page callers retain failure exit semantics even though the
        # trusted custom-tool wrapper intentionally normalizes JSON errors to 0.
        direct = subprocess.run([sys.executable, '-I', '-B', str(shim), 'data', 'fixture'],
            input=json.dumps(self.proposal_request()), text=True, capture_output=True, env=env, timeout=10)
        self.assertEqual(1, direct.returncode)
        self.assertEqual('Error: ' + CODE + '\n', direct.stderr)
        self.assertEqual(envelope(), json.loads(direct.stdout))

    def test_failure_details_never_forward_raw_stderr(self):
        stderr = 'Error: ' + CODE + ': ' + CANARY + '\n'
        with mock.patch.object(self.data.subprocess, 'run', return_value=self.completed(envelope(), 1, stderr)):
            with self.assertRaises(self.data.Refusal) as caught:
                self.invoke(self.proposal_request())
            self.assertEqual(CODE, str(caught.exception))
        result = subprocess.CompletedProcess([], 1, b'', stderr.encode())
        value, _ = self.wrapper_call('data_merge_propose', {}, result)
        self.assertEqual({'version': 1, 'error': CODE}, value)
        before = self.snapshot()
        for op in ('workflow_validation_recovery', 'merge_recovery', 'recovery_apply'):
            with mock.patch.object(self.data.subprocess, 'run') as run:
                with self.assertRaises(self.data.Refusal):
                    self.invoke({'op': op, 'attempt': ATTEMPT, 'apply': True})
                run.assert_not_called()
        self.assertEqual(before, self.snapshot())

    def test_stage_a_v1_missing_event_fields_fails_closed_during_update(self):
        # Stage A used version 1 too, but lacked these integrated fields. Never
        # relax the schema or forward an old projection during a mixed update.
        legacy = projection()
        legacy.pop('last_recorded_stage')
        legacy.pop('events')
        failure = {'version': 1, 'error': CODE, 'validation': legacy}
        with self.assertRaises(self.data.Refusal):
            self.data.validation_json(json.dumps(legacy))
        with mock.patch.object(self.data.subprocess, 'run', return_value=self.completed(failure, 1, 'Error: ' + CODE)):
            with self.assertRaises(self.data.Refusal) as caught:
                self.invoke(self.proposal_request())
            self.assertEqual(CODE, str(caught.exception))
            self.assertNotIsInstance(caught.exception, self.data.ValidationFailure)
        # Neither bridge nor wrapper exposes a partially understood projection.
        for returncode in (0, 1):
            value, _ = self.wrapper_call('data_merge_propose', {}, self.completed(failure, returncode, 'Error: ' + CODE))
            self.assertEqual({'version': 1, 'error': CODE}, value)
            self.assertNotIn('validation', value)
        value, _ = self.wrapper_call('data_workflow_validation_status', {}, self.completed(legacy))
        self.assertEqual({'version': 1, 'error': 'STANDARD_OPERATION_FAILED'}, value)
        self.assertNotIn(ATTEMPT, json.dumps(value))

    def test_wrapper_revalidates_failure_envelope(self):
        for code in (0, 1):
            value, _ = self.wrapper_call('data_merge_propose', {}, self.completed(envelope(), code, 'Error: ' + CODE))
            self.assertEqual(envelope(), value)
        bad = envelope()
        bad['validation']['private'] = CANARY
        value, _ = self.wrapper_call('data_merge_propose', {}, self.completed(bad))
        self.assertEqual({'version': 1, 'error': CODE}, value)
        bad = projection()
        bad['counts'] = {CANARY: 100}
        value, _ = self.wrapper_call('data_workflow_validation_status', {}, self.completed(bad))
        self.assertEqual({'version': 1, 'error': 'STANDARD_OPERATION_FAILED'}, value)


if __name__ == '__main__':
    unittest.main()
