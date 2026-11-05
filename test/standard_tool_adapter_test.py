"""Synthetic adapter boundary tests. Run: python3 -I -B test/standard_tool_adapter_test.py."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'integrations/term-llm/migration-operator/scripts/standard_tool.py'


class StandardToolAdapterTest(unittest.TestCase):
    assertions = 0

    def assertEqual(self, first, second, msg=None):
        type(self).assertions += 1
        return super().assertEqual(first, second, msg)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.record = self.root / 'argv.jsonl'
        self.control = self.root / 'fake-control'
        self.control.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['ARGV_RECORD'], 'a') as out:
    out.write(json.dumps(sys.argv[1:]) + '\\n')
if 'run-claim' in sys.argv:
    refusal = os.environ.get('CLAIM_REFUSAL')
    if refusal:
        print('Error: ' + refusal, file=sys.stderr)
        sys.exit(1)
    print(json.dumps({'version': 1, 'status': 'claimed', 'run_id': os.environ.get('CLAIM_RUN_ID', 'run-' + 'b' * 32)}))
elif 'run-execute' in sys.argv:
    sys.exit(int(os.environ.get('EXECUTE_EXIT', '0')))
else:
    print(json.dumps({'version': 1, 'status': os.environ.get('PLAN_STATUS', 'approved')}))
''')
        self.control.chmod(0o700)
        self.env = dict(os.environ, SILO_CONTROL=str(self.control), ARGV_RECORD=str(self.record),
                        PYTHONDONTWRITEBYTECODE='1')
        self.ids = {name: name.removesuffix('_id') + '-' + 'a' * 32
                    for name in ('dataset_id', 'plan_id', 'run_id', 'finding_id')}

    def call(self, tool, args, status='approved', **overrides):
        env = dict(self.env, TERM_LLM_TOOL_NAME=tool, PLAN_STATUS=status,
                   **overrides)
        result = subprocess.run([sys.executable, '-I', '-B', str(SCRIPT)],
                                input=json.dumps(args), capture_output=True, text=True,
                                env=env, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('', result.stderr)
        return json.loads(result.stdout)

    def calls(self):
        if not self.record.exists():
            return []
        return [json.loads(line) for line in self.record.read_text().splitlines()]

    def test_every_tool_exact_argv(self):
        cases = [
            ('migration_status', {}, ['status', 'synthetic']),
            ('migration_plan_propose', {'dataset_id': self.ids['dataset_id']},
             ['plan-propose', 'synthetic', '--dataset', self.ids['dataset_id']]),
            ('migration_plan_propose', {'dataset_id': self.ids['dataset_id'], 'baseline': 'seed'},
             ['plan-propose', 'synthetic', '--dataset', self.ids['dataset_id'], '--baseline', 'seed']),
            ('migration_plan_propose', {'dataset_id': self.ids['dataset_id'], 'baseline': 'baseline-' + 'b' * 16},
             ['plan-propose', 'synthetic', '--dataset', self.ids['dataset_id'], '--baseline', 'baseline-' + 'b' * 16]),
            ('migration_plan_show', {'plan_id': self.ids['plan_id']}, ['plan-show', 'synthetic', self.ids['plan_id']]),
            ('migration_run_show', {'run_id': self.ids['run_id']}, ['run-show', 'synthetic', self.ids['run_id']]),
            ('migration_findings', {}, ['findings', 'synthetic']),
            ('migration_finding_show', {'finding_id': self.ids['finding_id']}, ['finding-show', 'synthetic', self.ids['finding_id']]),
        ]
        for tool, args, argv in cases:
            with self.subTest(tool=tool, args=args):
                self.record.unlink(missing_ok=True)
                self.assertEqual('approved', self.call(tool, dict(workspace='synthetic', **args))['status'])
                self.assertEqual([['standard', 'agent'] + argv], self.calls())

    def test_run_request_prechecks_then_detaches_exact_argv(self):
        result = self.call('migration_run_request', {'workspace': 'synthetic', 'plan_id': self.ids['plan_id']})
        self.assertEqual({'version': 1, 'plan_id': self.ids['plan_id'], 'run_id': 'run-' + 'b' * 32, 'status': 'started'}, result)
        self.assertEqual([
            ['standard', 'agent', 'plan-show', 'synthetic', self.ids['plan_id']],
            ['standard', 'agent', 'run-claim', 'synthetic', self.ids['plan_id']],
            ['--detach', 'standard', 'agent', 'run-execute', 'synthetic', 'run-' + 'b' * 32],
        ], self.calls())

    def test_claim_refusal_returns_fixed_code_without_detaching(self):
        for code in ('STANDARD_BUSY', 'STANDARD_CAPACITY', 'STANDARD_STALE_PLAN'):
            with self.subTest(code=code):
                self.record.unlink(missing_ok=True)
                result = self.call('migration_run_request', {'workspace': 'synthetic', 'plan_id': self.ids['plan_id']}, CLAIM_REFUSAL=code)
                self.assertEqual(code, result['error'])
                self.assertEqual([
                    ['standard', 'agent', 'plan-show', 'synthetic', self.ids['plan_id']],
                    ['standard', 'agent', 'run-claim', 'synthetic', self.ids['plan_id']],
                ], self.calls())

    def test_detach_failure_reports_not_started_without_polling(self):
        result = self.call('migration_run_request', {'workspace': 'synthetic', 'plan_id': self.ids['plan_id']}, EXECUTE_EXIT='1')
        self.assertEqual('STANDARD_RUN_NOT_STARTED', result['error'])
        self.assertEqual(3, len(self.calls()))
        self.assertEqual(['--detach', 'standard', 'agent', 'run-execute', 'synthetic', 'run-' + 'b' * 32], self.calls()[-1])

    def test_malformed_claim_id_cannot_be_executed(self):
        for value in ('run-wrong', '--help', 'run-' + 'b' * 32 + ';echo bad'):
            with self.subTest(value=value):
                self.record.unlink(missing_ok=True)
                result = self.call('migration_run_request', {'workspace': 'synthetic', 'plan_id': self.ids['plan_id']}, CLAIM_RUN_ID=value)
                self.assertEqual('STANDARD_OPERATION_FAILED', result['error'])
                self.assertEqual(2, len(self.calls()))
                self.assertEqual('run-claim', self.calls()[-1][2])

    def test_nonapproved_plan_never_invokes_run_request(self):
        for status in ('proposed', 'stale', 'consumed', 'rejected', 'running'):
            with self.subTest(status=status):
                self.record.unlink(missing_ok=True)
                result = self.call('migration_run_request', {'workspace': 'synthetic', 'plan_id': self.ids['plan_id']}, status=status)
                self.assertEqual('STANDARD_NOT_APPROVED' if status == 'proposed' else 'STANDARD_PLAN_NOT_RUNNABLE', result['error'])
                self.assertEqual([['standard', 'agent', 'plan-show', 'synthetic', self.ids['plan_id']]], self.calls())

    def test_injection_and_invalid_shapes_rejected_before_any_invocation(self):
        tools = {
            'workspace': ('migration_status', {}),
            'dataset_id': ('migration_plan_propose', {}),
            'plan_id': ('migration_run_request', {}),
            'run_id': ('migration_run_show', {}),
            'finding_id': ('migration_finding_show', {}),
            'baseline': ('migration_plan_propose', {'dataset_id': self.ids['dataset_id']}),
        }
        for field, (tool, extra) in tools.items():
            valid = 'synthetic' if field == 'workspace' else ('seed' if field == 'baseline' else self.ids[field])
            invalid = [valid + ' extra', valid + ';echo INJECTED', '--help', '-x', '../private', '', None, 123,
                       valid + '\n', valid + '\x00']
            if field != 'workspace':
                invalid += ['wrong-' + 'a' * 32, valid.upper(), valid + 'a']
                if field == 'baseline':
                    invalid.append('baseline-' + 'a' * 32)
            for value in invalid:
                with self.subTest(field=field, value=value):
                    self.record.unlink(missing_ok=True)
                    args = dict(workspace='synthetic', **extra)
                    args[field] = value
                    if field == 'baseline' and value is None:
                        # Optional absent/null baseline means the default, not an injection.
                        continue
                    self.assertEqual('STANDARD_ARGUMENTS_INVALID', self.call(tool, args)['error'])
                    self.assertEqual([], self.calls())

    def test_unknown_tool_never_invokes_control(self):
        self.assertEqual('STANDARD_TOOL_UNKNOWN', self.call('migration_approve', {'workspace': 'synthetic'})['error'])
        self.assertEqual([], self.calls())


if __name__ == '__main__':
    program = unittest.main(exit=False)
    result = program.result
    print(f'{result.testsRun} runs, {StandardToolAdapterTest.assertions} assertions, '
          f'{len(result.failures)} failures, {len(result.errors)} errors, {len(result.skipped)} skips')
    sys.exit(not result.wasSuccessful())
