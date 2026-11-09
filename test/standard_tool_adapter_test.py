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

    def call(self, tool, args, status='approved', project='synthetic', **overrides):
        env = dict(self.env, TERM_LLM_TOOL_NAME=tool, PLAN_STATUS=status, SILO_TESTING='1', SILO_PROJECTS_ROOT=str(self.root / 'projects'),
                   OBSERVED_STATUSES=json.dumps([status]))
        env.update(overrides)
        cwd = self.root / 'projects' / project if project else self.root
        cwd.mkdir(parents=True, exist_ok=True)
        result = subprocess.run([sys.executable, '-I', '-B', str(SCRIPT)],
                                input=json.dumps(args), capture_output=True, text=True,
                                env=env, timeout=10, cwd=cwd)
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
        self.assertEqual('approved', self.call('migration_status', {})['status'])
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
                self.assertEqual('approved', self.call(tool, args)['status'])
                self.assertEqual([['standard', 'agent'] + argv], self.calls())

    def test_injection_and_invalid_shapes_rejected_before_any_invocation(self):
        tools = {
            'dataset_id': ('migration_plan_propose', {}),
            'plan_id': ('migration_plan_show', {}),
            'run_id': ('migration_run_show', {}),
            'finding_id': ('migration_finding_show', {}),
            'baseline': ('migration_plan_propose', {'dataset_id': self.ids['dataset_id']}),
        }
        for field, (tool, extra) in tools.items():
            valid = 'seed' if field == 'baseline' else self.ids[field]
            invalid = [valid + ' extra', valid + ';echo INJECTED', '--help', '-x', '../private', '', None, 123,
                       valid + '\n', valid + '\x00']
            invalid += ['wrong-' + 'a' * 32, valid.upper(), valid + 'a']
            if field == 'baseline':
                invalid.append('baseline-' + 'a' * 32)
            for value in invalid:
                with self.subTest(field=field, value=value):
                    self.reset_calls()
                    args = dict(extra)
                    args[field] = value
                    if field == 'baseline' and value is None:
                        # Optional absent/null baseline means the default, not an injection.
                        continue
                    self.assertEqual('STANDARD_ARGUMENTS_INVALID', self.call(tool, args)['error'])
                    self.assertEqual([], self.calls())

    def test_unknown_tool_never_invokes_control(self):
        self.assertEqual('STANDARD_TOOL_UNKNOWN', self.call('migration_approve', {})['error'])
        self.assertEqual([], self.calls())

    def test_the_chats_project_decides_the_workspace(self):
        self.assertEqual('approved', self.call('migration_status', {}, project='synthetic')['status'])
        self.assertEqual([['standard', 'agent', 'status', 'synthetic']], self.calls())
        self.reset_calls()
        self.call('migration_status', {'workspace': 'acme'}, project='synthetic')  # a stray name changes nothing
        self.assertEqual([['standard', 'agent', 'status', 'synthetic']], self.calls())
        self.reset_calls()
        for project in (None, '.hidden'):
            with self.subTest(project=project):
                self.assertEqual('STANDARD_CHAT_NOT_IN_PROJECT', self.call('migration_status', {}, project=project)['error'])
        self.assertEqual('STANDARD_ARGUMENTS_INVALID', self.call('migration_status', [])['error'])
        self.assertEqual([], self.calls())

    def test_no_tool_can_start_a_run(self):
        self.assertEqual('STANDARD_TOOL_UNKNOWN', self.call('migration_run_request', {'plan_id': self.ids['plan_id']})['error'])
        self.assertEqual([], self.calls())
        self.assertNotIn('migration_run_request', (ROOT / 'integrations/term-llm/migration-operator/agent.yaml').read_text())
        source = SCRIPT.read_text()
        self.assertNotIn('run-claim', source)
        self.assertNotIn('run-execute', source)


DATA = ROOT / 'integrations/term-llm/migration-data/scripts/data_tool.py'


class DataToolAdapterTest(unittest.TestCase):
    """migration-data's adapter: every tool is one `data WS` request with only its own keys."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.record = self.root / 'argv.jsonl'
        self.control = self.root / 'fake-control'
        self.control.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['ARGV_RECORD'], 'a') as out:
    out.write(json.dumps([sys.argv[1:], json.loads(sys.stdin.read())]) + '\\n')
mode = os.environ.get('MODE', 'ok')
if mode == 'refuse':
    print('Error: STANDARD_PATH_INVALID', file=sys.stderr)
    sys.exit(1)
if mode == 'detail':
    print('Error: STANDARD_ARGUMENTS_INVALID: timeout_minutes\\nnot this line', file=sys.stderr)
    sys.exit(1)
if mode == 'large':
    print(json.dumps({'version': 1, 'text': 'x' * (49 * 1024)}))
elif mode == 'garbage':
    print('{"version": 1, "text": "cut')
else:
    print(json.dumps({'version': 1, 'status': 'ok'}))
''')
        self.control.chmod(0o700)
        self.run_id = 'run-' + 'a' * 32

    def call(self, tool, args, mode='ok', project='arc'):
        # term-llm runs a project chat's tools in the project's folder.
        projects = self.root / 'projects'
        cwd = projects / project if project else self.root
        cwd.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, SILO_CONTROL=str(self.control), ARGV_RECORD=str(self.record), PYTHONDONTWRITEBYTECODE='1',
                   TERM_LLM_TOOL_NAME=tool, MODE=mode, SILO_TESTING='1', SILO_PROJECTS_ROOT=str(projects))
        result = subprocess.run([sys.executable, '-I', '-B', str(DATA)], input=json.dumps(args), capture_output=True,
                                text=True, env=env, timeout=10, cwd=cwd)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('', result.stderr)
        return json.loads(result.stdout), result.stdout

    def calls(self):
        calls = [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []
        if self.record.exists():
            self.record.unlink()
        return calls

    def test_every_declared_tool_maps_to_one_data_request(self):
        import re
        declared = re.findall(r'(?m)^    - name: ([a-z_]+)$', (ROOT / 'integrations/term-llm/migration-data/agent.yaml').read_text())
        self.assertEqual(22, len(declared))
        for tool in declared:
            with self.subTest(tool=tool):
                self.call(tool, {'path': 'x', 'unexpected': 'dropped'})
                (argv, request), = self.calls()
                self.assertEqual(['data', 'arc'], argv)
                self.assertNotIn('unexpected', request)
                self.assertNotIn('workspace', request)
                self.assertEqual('chat', request['via'])

    def test_requests_carry_only_allowed_keys(self):
        cases = {
            'data_peek': ({'area': 'intake', 'path': 'dump.sql', 'mode': 'search', 'pattern': 'CREATE TABLE', 'op': 'db_reset'},
                          {'op': 'peek', 'area': 'intake', 'path': 'dump.sql', 'mode': 'search', 'pattern': 'CREATE TABLE'}),
            'data_take': ({'path': 'dump.sql', 'type': 'mysql-dump', 'confirm': True}, {'op': 'take', 'path': 'dump.sql', 'type': 'mysql-dump'}),
            'data_script': ({'code': 'puts 1', 'into': 'xml', 'language': 'ruby'}, {'op': 'script', 'code': 'puts 1', 'into': 'xml', 'language': 'ruby'}),
            'data_db_up': ({'engine': 'postgres'}, {'op': 'db_up', 'engine': 'postgres'}),
            'data_guide': ({'confirm': True}, {'op': 'guide'}),
            'data_decide': ({'topic': 'Empty posts', 'decision': 'Drop them', 'basis': 'default', 'at': 'x'}, {'op': 'decide', 'topic': 'Empty posts', 'decision': 'Drop them', 'basis': 'default'}),
            'data_decisions': ({}, {'op': 'decisions'}),
            'data_notes_write': ({'text': '# arc', 'path': 'x'}, {'op': 'notes_write', 'text': '# arc'}),
            'data_propose_finding': ({'text': 'schema', 'run_id': None}, {'op': 'propose_finding', 'text': 'schema'}),
            'data_run_evidence': ({'run_id': self.run_id}, {'op': 'run_evidence', 'run_id': self.run_id}),
            'data_run_count': ({'run_id': self.run_id, 'side': 'destination', 'sql': 'SELECT COUNT(*) FROM posts', 'confirm': True},
                               {'op': 'run_count', 'run_id': self.run_id, 'side': 'destination', 'sql': 'SELECT COUNT(*) FROM posts'}),
            'data_plan_propose': ({'source': 'input-' + 'a' * 32, 'settings': 'input-' + 'b' * 32, 'reconciliation': None, 'plan_id': 'x'},
                                  {'op': 'plan_propose', 'source': 'input-' + 'a' * 32, 'settings': 'input-' + 'b' * 32}),
        }
        for tool, (args, request) in cases.items():
            with self.subTest(tool=tool):
                self.call(tool, dict(args, via='shell'))
                self.assertEqual([[['data', 'arc'], dict(request, via='chat')]], self.calls())

    def test_oversize_truncated_or_refused_output_becomes_a_fixed_error(self):
        for mode, code in (('large', 'STANDARD_OUTPUT_TOO_LARGE'), ('garbage', 'STANDARD_OPERATION_FAILED'), ('refuse', 'STANDARD_PATH_INVALID')):
            with self.subTest(mode=mode):
                result, raw = self.call('data_status', {}, mode=mode)
                self.assertEqual({'version': 1, 'error': code}, result)
                self.assertLess(len(raw), 200)

    def test_a_refusal_keeps_its_detail_on_this_side_only(self):
        result, _raw = self.call('data_script', {}, mode='detail')
        self.assertEqual({'version': 1, 'error': 'STANDARD_ARGUMENTS_INVALID: timeout_minutes'}, result)

    def test_bad_arguments_or_unknown_tool_never_invoke_control(self):
        for tool, args in (('data_status', []), ('data_release_finding', {}), ('analyst_run_evidence', {'run_id': self.run_id}),
                           ('data_delivery_label', {'kind': 'launch'}), ('data_deliveries', {}), ('delivery_label', {})):
            with self.subTest(tool=tool, args=args):
                result, _raw = self.call(tool, args)
                self.assertIn(result['error'], ('STANDARD_ARGUMENTS_INVALID', 'STANDARD_TOOL_UNKNOWN'))
        self.assertEqual([], self.calls())

    def test_the_chats_project_decides_the_workspace(self):
        self.assertEqual('ok', self.call('data_status', {})[0]['status'])
        self.assertEqual([['data', 'arc']], [argv for argv, _request in self.calls()])
        self.call('data_status', {'workspace': 'acme'})  # a stray name changes nothing
        self.assertEqual([['data', 'arc']], [argv for argv, _request in self.calls()])
        for project in (None, '.hidden'):
            with self.subTest(project=project):
                result, _raw = self.call('data_peek', {'path': 'x'}, project=project)
                self.assertEqual({'version': 1, 'error': 'STANDARD_CHAT_NOT_IN_PROJECT'}, result)
        # A subfolder of the project still counts as the project; a link out of it doesn't fool it.
        (self.root / 'projects/arc/sub').mkdir(parents=True)
        self.assertEqual('ok', self.call('data_status', {}, project='arc/sub')[0]['status'])
        (self.root / 'elsewhere').mkdir()
        (self.root / 'projects/arc-link').symlink_to(self.root / 'elsewhere')
        self.assertEqual('STANDARD_CHAT_NOT_IN_PROJECT', self.call('data_status', {}, project='arc-link')[0]['error'])
        self.assertEqual(1, len(self.calls()))

    def test_a_new_projects_first_chat_creates_the_workspace_it_is_in(self):
        self.call('data_create', {'platform': 'mybb'}, project='new-forum')
        self.assertEqual([[['data', 'new-forum'], {'op': 'create', 'platform': 'mybb', 'via': 'chat'}]], self.calls())
        self.call('data_guide', {}, project='new-forum')
        self.assertEqual([['data', 'new-forum']], [argv for argv, _request in self.calls()])

    def test_no_agent_declares_a_workspace_argument(self):
        import re
        for agent in ('migration-data', 'converter-developer', 'converter-reviewer', 'migration-operator'):
            with self.subTest(agent=agent):
                text = (ROOT / 'integrations/term-llm' / agent / 'agent.yaml').read_text()
                self.assertEqual([], re.findall(r'(?m)^\s+workspace: \{|required: \[[^\]]*workspace', text))


if __name__ == '__main__':
    program = unittest.main(exit=False)
    result = program.result
    print(f'{result.testsRun} runs, {StandardToolAdapterTest.assertions} assertions, '
          f'{len(result.failures)} failures, {len(result.errors)} errors, {len(result.skipped)} skips')
    sys.exit(not result.wasSuccessful())
