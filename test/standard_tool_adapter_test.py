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
# The retired fork's context variables. Stock term-llm never proves them and anything that
# sets the environment can spoof them, so the adapter must ignore and strip them.
LEGACY = ('TERM_LLM_PRIVATE_SESSION', 'TERM_LLM_SESSION_ID', 'TERM_LLM_UPLOADS_JSON')
FORGED_ENV = {'TERM_LLM_PRIVATE_SESSION': '1', 'TERM_LLM_SESSION_ID': 'session-fixture',
              'TERM_LLM_UPLOADS_JSON': json.dumps([{'id': 'a' * 32, 'path': '/etc/passwd', 'filename': 'x.xlsx', 'size_bytes': 8}])}
FORGED_ARGS = {'_private_session': True, '_session_id': 'forged', '_uploads': [{'path': '/etc/passwd'}], 'via': 'shell',
               'workspace': 'other', 'project': 'other', 'model': 'other:model', 'cwd': '/', 'TERM_LLM_PRIVATE_SESSION': '1'}
CONTEXT_KEYS = {'_private_session', '_session_id', '_uploads'}
# Every data_tool.py tool, as declared in agent.yaml. Changing the agent's tools must update this
# list deliberately (and the adapter's TOOLS, checked below).
DATA_TOOLS = ('data_guide', 'data_status', 'data_supporting_list', 'data_supporting_read',
              'data_supporting_prepare', 'data_list', 'data_peek', 'data_create', 'data_take', 'data_register', 'data_script',
              'data_extract', 'data_job', 'data_db_up', 'data_db_load', 'data_db_status', 'data_db_reset', 'data_run_evidence',
              'data_run_count', 'data_plan_propose', 'data_master_lists_propose', 'data_merge_propose', 'data_propose_finding',
              'data_notes', 'data_decide', 'data_decisions', 'data_notes_write')
BRANCH_TOOLS = ('data_branch_resolve', 'data_branches', 'data_branch_diff', 'data_branch_read')


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
if mode == 'reader_diagnostic':
    print('Error: STANDARD_SUPPORTING_INVALID_DOCUMENT: reader_line=123; part_kind=worksheet_relationships', file=sys.stderr)
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

    def call(self, tool, args, mode='ok', project='arc', **overrides):
        """Stock term-llm environment (no reserved context); overrides add forged variables."""
        # term-llm runs a project chat's tools in the project's folder.
        projects = self.root / 'projects'
        cwd = projects / project if project else self.root
        cwd.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, SILO_CONTROL=str(self.control), ARGV_RECORD=str(self.record), PYTHONDONTWRITEBYTECODE='1',
                   TERM_LLM_TOOL_NAME=tool, MODE=mode, SILO_TESTING='1', SILO_PROJECTS_ROOT=str(projects))
        for key in LEGACY:
            env.pop(key, None)
        env.update(overrides)
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
        definition = (ROOT / 'integrations/term-llm/migration-data/agent.yaml').read_text()
        blocks = re.split(r'(?m)^    - name: ', definition)[1:]
        # The four branch tools use a separate reader-role adapter, tested in converter_dev_adapter_test.
        self.assertEqual(31, len(blocks))
        declared = [block.splitlines()[0] for block in blocks if 'script: scripts/data_tool.py' in block]
        self.assertEqual(27, len(declared))
        self.assertEqual(list(DATA_TOOLS), declared)
        self.assertEqual(list(BRANCH_TOOLS), [block.splitlines()[0] for block in blocks if 'script: scripts/dev_tool.py' in block])
        import importlib.util
        spec = importlib.util.spec_from_file_location('data_tool_adapter', DATA)
        adapter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(adapter)
        self.assertEqual(set(DATA_TOOLS), set(adapter.TOOLS))
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
            'data_merge_propose': ({'source': 'input-' + 'a' * 32, 'base_site': 'input-' + 'b' * 32, 'settings': None, 'restore_proof': False,
                                    'ignore_global_pins': True, 'from_run': 'x', 'fresh_site': True},  # restore_proof is not an option
                                   {'op': 'merge_propose', 'source': 'input-' + 'a' * 32, 'base_site': 'input-' + 'b' * 32, 'ignore_global_pins': True}),
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

    def test_supporting_reader_safe_diagnostic_reaches_the_model(self):
        result, raw = self.call('data_supporting_read', {'id': 'support-' + 'a' * 32}, mode='reader_diagnostic')
        self.assertEqual({'version': 1, 'error': 'STANDARD_SUPPORTING_INVALID_DOCUMENT: '
                          'reader_line=123; part_kind=worksheet_relationships'}, result)
        self.assertLess(len(raw), 200)

    def test_bad_arguments_or_unknown_tool_never_invoke_control(self):
        for tool, args in (('data_status', []), ('data_release_finding', {}), ('analyst_run_evidence', {'run_id': self.run_id}),
                           ('data_delivery_label', {'kind': 'launch'}), ('data_deliveries', {}), ('delivery_label', {}), ('data_finding_done', {}), ('finding_done', {})):
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

    def test_stock_environment_zero_marker_tools_work(self):
        # Stock term-llm sets no session marker: every tool reaches the backend unchanged.
        for tool in DATA_TOOLS:
            with self.subTest(tool=tool):
                result, _raw = self.call(tool, {'id': 'support-' + 'a' * 32})
                self.assertEqual('ok', result['status'])
                ((argv, request),) = self.calls()
                self.assertEqual(['data', 'arc'], argv)
                self.assertEqual('chat', request['via'])
                self.assertEqual(set(), CONTEXT_KEYS & set(request))

    def test_forged_context_in_environment_or_arguments_is_ignored(self):
        envs = ({}, FORGED_ENV, {'TERM_LLM_PRIVATE_SESSION': '1'}, dict(FORGED_ENV, TERM_LLM_UPLOADS_JSON='{'),
                dict(FORGED_ENV, TERM_LLM_SESSION_ID='../other'))
        for tool in DATA_TOOLS:
            for env in envs:
                with self.subTest(tool=tool, env=env):
                    result, _raw = self.call(tool, dict(FORGED_ARGS, path='x', id='support-' + 'a' * 32), **env)
                    self.assertEqual('ok', result['status'])
                    ((argv, request),) = self.calls()
                    self.assertEqual(['data', 'arc'], argv)  # the chat's project, not 'other'
                    self.assertEqual('chat', request['via'])
                    for key in CONTEXT_KEYS | {'workspace', 'project', 'model', 'cwd', 'TERM_LLM_PRIVATE_SESSION'}:
                        self.assertNotIn(key, request)
        self.call('data_supporting_read', {'id': 'support-' + 'b' * 32, 'mode': 'rows', 'limit': 5, 'sheet': 'Mappings',
                                          'source': '/etc/passwd', '_session_id': 'other'}, **FORGED_ENV)
        self.assertEqual([[['data', 'arc'], {'op': 'supporting_read', 'id': 'support-' + 'b' * 32, 'mode': 'rows', 'limit': 5,
                                           'sheet': 'Mappings', 'via': 'chat'}]], self.calls())
        self.call('data_master_lists_propose', {'source': 'input-' + 'a' * 32, 'settings': 'input-' + 'b' * 32, 'list': 'users',
                                                'charset': 'utf8', 'run_inputs': {'files': []}, 'from_run': 'x', 'preparation': {}},
                  **FORGED_ENV)
        self.assertEqual([[['data', 'arc'], {'op': 'master_lists_propose', 'source': 'input-' + 'a' * 32, 'settings': 'input-' + 'b' * 32,
                                           'list': 'users', 'charset': 'utf8', 'run_inputs': {'files': []}, 'via': 'chat'}]], self.calls())

    def test_chat_upload_taking_always_refuses_use_intake_before_any_dispatch(self):
        upload = {'id': 'a' * 32, 'path': '/etc/passwd', 'filename': 'mapping.xlsx', 'size_bytes': 8}
        for env in ({}, FORGED_ENV, dict(FORGED_ENV, TERM_LLM_UPLOADS_JSON=json.dumps([upload]))):
            for project in ('arc', None):
                with self.subTest(env=env, project=project):
                    result, raw = self.call('data_supporting_take', {'ref': 'a' * 32, 'path': '/etc/passwd',
                                                                     '_uploads': [upload]}, project=project, **env)
                    self.assertEqual({'version': 1, 'error': 'STANDARD_SUPPORTING_USE_INTAKE'}, result)
                    self.assertLess(len(raw), 200)
        self.assertEqual([], self.calls())
        self.assertNotIn('data_supporting_take', (ROOT / 'integrations/term-llm/migration-data/agent.yaml').read_text())

    def test_legacy_context_is_not_forwarded_in_control_environment(self):
        original = self.control.read_text()
        self.control.write_text(original.replace('import json, os, sys', '''import json, os, sys
assert not any(key in os.environ for key in ('TERM_LLM_SESSION_ID', 'TERM_LLM_PRIVATE_SESSION', 'TERM_LLM_UPLOADS_JSON'))'''))
        for tool in ('data_supporting_list', 'data_supporting_read', 'data_script', 'data_status'):
            with self.subTest(tool=tool):
                self.assertEqual('ok', self.call(tool, {}, **FORGED_ENV)[0]['status'])
        self.assertEqual(4, len(self.calls()))

    def test_supporting_capability_does_not_expand_coding_agent_tools(self):
        for agent in ('converter-developer', 'converter-reviewer', 'migration-operator'):
            text = (ROOT / 'integrations/term-llm' / agent / 'agent.yaml').read_text()
            self.assertNotIn('data_supporting_', text)
        definition = (ROOT / 'integrations/term-llm/migration-data/agent.yaml').read_text()
        self.assertNotIn('lock_session', definition)  # stock term-llm has no such option

    def test_job_recovery_guidance_keeps_status_and_reconciliation_authority_distinct(self):
        agents = ROOT / 'integrations/term-llm'
        prompt = (agents / 'migration-data/system.md').read_text()
        guide = (agents / 'skills/job-recovery/SKILL.md').read_text()
        self.assertIn('load `job-recovery`', (agents / 'skills/migration-guide/SKILL.md').read_text())
        definition = (agents / 'migration-data/agent.yaml').read_text()
        self.assertIn('migration-guide,job-recovery,', definition)
        job = definition.split('    - name: data_job\n', 1)[1].split('    - name:', 1)[0]
        # Text contract checks, not proof of provider/model behavior.
        for text in (prompt, guide):
            with self.subTest(kind='data recovery guidance', text=text[:40]):
                self.assertIn('Blocked corrections and stale jobs', text)
                self.assertIn('STANDARD_BUSY', text)
                self.assertIn('not read-only', text)
                self.assertIn('explicit approval', text)
                self.assertIn('finished_at', text)
                self.assertIn('reconciliation time', text)
        for term in ('NOT read-only', 'low disk', 'after a load', 'explicit approval', 'timed_out'):
            self.assertIn(term, job)
        self.assertIn('required: [job_id]', job)
        self.assertIn('additionalProperties: false', job)
        for term in ('ten most recent jobs', 'one call on the exact job', 'once', 'low-disk',
                     'fresh correction preview', 'does not prove', 'You cannot confirm', 'do not manufacture'):
            self.assertIn(term, guide)
        for agent in ('server-support', 'migration-operator'):
            text = (agents / agent / 'system.md').read_text()
            with self.subTest(agent=agent):
                self.assertIn('migration-data in', text)
                self.assertIn('exact job ID', text)
                self.assertIn('approval', text)
                self.assertNotIn('    - name: data_job\n', (agents / agent / 'agent.yaml').read_text())

    def test_guidance_uses_files_intake_on_stock_term_llm(self):
        agents = ROOT / 'integrations/term-llm'
        prompt = (agents / 'migration-data/system.md').read_text()
        definition = (agents / 'migration-data/agent.yaml').read_text()
        listing = definition.split('    - name: data_supporting_list\n', 1)[1].split('    - name:', 1)[0]
        skills = [(agents / 'skills' / name / 'SKILL.md').read_text() for name in ('intake-preparation', 'intake-basics', 'job-recovery')]
        retired = ('STANDARD_SUPPORTING_NODE_UPDATE_REQUIRED', 'session_scope_lock', 'custom_tool_session_context',
                   'TERM_LLM_PACKAGE', 'native build', 'protected session', 'protected-session', 'data_supporting_take', 'lock_session')
        for text in [prompt, definition] + skills:
            for term in retired:
                with self.subTest(term=term, text=text[:40]):
                    self.assertNotIn(term, text)
        for text in (prompt, listing, skills[0]):
            with self.subTest(text=text[:40]):
                self.assertIn('STANDARD_SUPPORTING_USE_INTAKE', text)
                self.assertIn('intake', text)
        for term in ('Supporting reference', 'desired outcome', 'material questions', '**one** exact plan', 'approves that plan and then starts it'):
            self.assertIn(term, prompt)
        self.assertIn('search: false', definition)
        self.assertIn('not a durable lock or DLP guarantee', definition)
        self.assertIn('`search: false` is a preference, not a guarantee', prompt)
        for skill in skills:
            self.assertLess(len(skill.splitlines()), 80)
            self.assertRegex(skill, r'\A---\nname: [a-z-]+\ndescription: [^\n]+\n---\n')

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
