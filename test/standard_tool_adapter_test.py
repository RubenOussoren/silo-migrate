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
elif 'run-show' in sys.argv:
    path = os.environ['ARGV_RECORD'] + '.polls'
    count = int(open(path).read()) if os.path.exists(path) else 0
    statuses = json.loads(os.environ['OBSERVED_STATUSES'])
    with open(path, 'w') as counter:
        counter.write(str(count + 1))
    print(json.dumps({'version': 1, 'run_id': 'run-' + 'b' * 32, 'status': statuses[min(count, len(statuses) - 1)]}))
else:
    print(json.dumps({'version': 1, 'status': os.environ.get('PLAN_STATUS', 'approved')}))
''')
        self.control.chmod(0o700)
        self.env = dict(os.environ, SILO_CONTROL=str(self.control), ARGV_RECORD=str(self.record),
                        PYTHONDONTWRITEBYTECODE='1', SILO_TOOL_START_WAIT='0.5', SILO_TOOL_START_POLL='0.001')
        self.ids = {name: name.removesuffix('_id') + '-' + 'a' * 32
                    for name in ('dataset_id', 'plan_id', 'run_id', 'finding_id')}

    def call(self, tool, args, status='approved', **overrides):
        env = dict(self.env, TERM_LLM_TOOL_NAME=tool, PLAN_STATUS=status,
                   OBSERVED_STATUSES=json.dumps(['running' if tool == 'migration_run_request' else status]))
        env.update(overrides)
        result = subprocess.run([sys.executable, '-I', '-B', str(SCRIPT)],
                                input=json.dumps(args), capture_output=True, text=True,
                                env=env, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('', result.stderr)
        return json.loads(result.stdout)

    def reset_calls(self):
        self.record.unlink(missing_ok=True)
        Path(str(self.record) + '.polls').unlink(missing_ok=True)

    def calls(self):
        if not self.record.exists():
            return []
        return [json.loads(line) for line in self.record.read_text().splitlines()]

    def test_installed_layout_finds_prefix_shim_without_environment(self):
        # The server layout: agent dir reached through ~/.config/term-llm/agents, no SILO_CONTROL.
        prefix = self.root / 'srv'
        release = prefix / 'releases' / ('c' * 40)
        agent = release / 'integrations/term-llm/migration-operator'
        agent.mkdir(parents=True)
        (prefix / 'current').symlink_to(release)
        (prefix / 'bin').mkdir()
        shim = prefix / 'bin/silo-migrate-control'
        shim.write_text(self.control.read_text())
        shim.chmod(0o700)
        agents = self.root / 'home/.config/term-llm/agents'
        agents.mkdir(parents=True)
        (agents / 'migration-operator').symlink_to(prefix / 'current/integrations/term-llm/migration-operator')
        env = {k: v for k, v in self.env.items() if k != 'SILO_CONTROL'}
        env['TERM_LLM_AGENT_DIR'] = str(agents / 'migration-operator')
        env.pop('PATH', None)
        self.env = env
        self.assertEqual('approved', self.call('migration_status', {'workspace': 'synthetic'})['status'])
        self.assertEqual([['standard', 'agent', 'status', 'synthetic']], self.calls())

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
                self.reset_calls()
                self.assertEqual('approved', self.call(tool, dict(workspace='synthetic', **args))['status'])
                self.assertEqual([['standard', 'agent'] + argv], self.calls())

    def test_run_request_prechecks_then_detaches_exact_argv(self):
        result = self.call('migration_run_request', {'workspace': 'synthetic', 'plan_id': self.ids['plan_id']})
        self.assertEqual({'version': 1, 'plan_id': self.ids['plan_id'], 'run_id': 'run-' + 'b' * 32, 'status': 'running'}, result)
        self.assertEqual([
            ['standard', 'agent', 'plan-show', 'synthetic', self.ids['plan_id']],
            ['standard', 'agent', 'run-claim', 'synthetic', self.ids['plan_id']],
            ['--detach', 'standard', 'agent', 'run-execute', 'synthetic', 'run-' + 'b' * 32],
            ['standard', 'agent', 'run-show', 'synthetic', 'run-' + 'b' * 32],
        ], self.calls())

    def test_polling_returns_observed_status_and_not_a_started_claim(self):
        for status in ('running', 'completed', 'failed', 'not_started', 'abandoned'):
            with self.subTest(status=status):
                self.reset_calls()
                result = self.call('migration_run_request', {'workspace': 'synthetic', 'plan_id': self.ids['plan_id']},
                                   OBSERVED_STATUSES=json.dumps(['claimed', status]))
                self.assertEqual({'version': 1, 'plan_id': self.ids['plan_id'], 'run_id': 'run-' + 'b' * 32, 'status': status}, result)
                self.assertEqual([
                    ['standard', 'agent', 'plan-show', 'synthetic', self.ids['plan_id']],
                    ['standard', 'agent', 'run-claim', 'synthetic', self.ids['plan_id']],
                    ['--detach', 'standard', 'agent', 'run-execute', 'synthetic', 'run-' + 'b' * 32],
                    ['standard', 'agent', 'run-show', 'synthetic', 'run-' + 'b' * 32],
                    ['standard', 'agent', 'run-show', 'synthetic', 'run-' + 'b' * 32],
                ], self.calls())

    def test_poll_deadline_reports_claimed_truthfully_if_execution_never_starts(self):
        result = self.call('migration_run_request', {'workspace': 'synthetic', 'plan_id': self.ids['plan_id']},
                           OBSERVED_STATUSES=json.dumps(['claimed']), SILO_TOOL_START_WAIT='0.1')
        self.assertEqual('claimed', result['status'])
        self.assertEqual('run-' + 'b' * 32, result['run_id'])
        calls = self.calls()
        self.assertEqual([
            ['standard', 'agent', 'plan-show', 'synthetic', self.ids['plan_id']],
            ['standard', 'agent', 'run-claim', 'synthetic', self.ids['plan_id']],
            ['--detach', 'standard', 'agent', 'run-execute', 'synthetic', 'run-' + 'b' * 32],
        ], calls[:3])
        self.assertEqual(True, len(calls) > 3)
        self.assertEqual([['standard', 'agent', 'run-show', 'synthetic', 'run-' + 'b' * 32]] * (len(calls) - 3), calls[3:])

    def test_claim_refusal_returns_fixed_code_without_detaching(self):
        for code in ('STANDARD_BUSY', 'STANDARD_CAPACITY', 'STANDARD_STALE_PLAN'):
            with self.subTest(code=code):
                self.reset_calls()
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
                self.reset_calls()
                result = self.call('migration_run_request', {'workspace': 'synthetic', 'plan_id': self.ids['plan_id']}, CLAIM_RUN_ID=value)
                self.assertEqual('STANDARD_OPERATION_FAILED', result['error'])
                self.assertEqual(2, len(self.calls()))
                self.assertEqual('run-claim', self.calls()[-1][2])

    def test_nonapproved_plan_never_invokes_run_request(self):
        for status in ('proposed', 'stale', 'consumed', 'rejected', 'running'):
            with self.subTest(status=status):
                self.reset_calls()
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
                    self.reset_calls()
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
