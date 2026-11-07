"""converter-developer / converter-reviewer adapter tests. Run: python3 -I -B test/converter_dev_adapter_test.py."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
AGENTS = ROOT / 'integrations/term-llm'
WRITE_TOOLS = {'dev_write', 'dev_edit', 'dev_delete', 'dev_branch', 'dev_commit', 'dev_push_propose', 'dev_format'}


class ConverterDevAdapterTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.record = root / 'calls.jsonl'
        self.control = root / 'fake-control'
        self.control.write_text('''#!/usr/bin/env python3
import json, os, sys
data = sys.stdin.read()
with open(os.environ['RECORD'], 'a') as out:
    out.write(json.dumps([sys.argv[1:], data]) + '\\n')
print(json.dumps({'version': 1, 'ok': True}))
''')
        self.control.chmod(0o700)

    def call(self, agent, tool, args, project='auto'):
        # As in real use, the reviewer runs in its workspace's web UI project unless a test says otherwise.
        if project == 'auto':
            workspace = args.get('workspace') if isinstance(args, dict) else None
            project = workspace if agent == 'converter-reviewer' and isinstance(workspace, str) and workspace.replace('-', '').isalnum() else None
        root = Path(self.temp.name) / 'projects'
        env = dict(os.environ, SILO_CONTROL=str(self.control), RECORD=str(self.record), TERM_LLM_TOOL_NAME=tool, PYTHONDONTWRITEBYTECODE='1',
                   SILO_TESTING='1', SILO_PROJECTS_ROOT=str(root))
        env.pop('TERM_LLM_AGENT_DIR', None)
        cwd = root / project if project else Path(self.temp.name)
        cwd.mkdir(parents=True, exist_ok=True)
        result = subprocess.run([sys.executable, '-I', '-B', str(AGENTS / agent / 'scripts/dev_tool.py')], input=json.dumps(args),
                                capture_output=True, text=True, env=env, timeout=20, cwd=cwd)
        self.assertEqual(0, result.returncode, result.stderr)
        return json.loads(result.stdout)

    def calls(self):
        if not self.record.exists():
            return []
        calls = [json.loads(line) for line in self.record.read_text().splitlines()]
        self.record.unlink()
        return calls

    def tools(self, agent):
        import re
        return re.findall(r'(?m)^    - name: ([a-z_]+)$', (AGENTS / agent / 'agent.yaml').read_text())

    def test_copies_are_identical(self):
        self.assertEqual((AGENTS / 'converter-developer/scripts/dev_tool.py').read_bytes(), (AGENTS / 'converter-reviewer/scripts/dev_tool.py').read_bytes())

    def test_developer_tools_map_to_role_and_op_with_only_allowed_keys(self):
        cases = {
            'dev_list': ({'path': 'lib'}, {'op': 'list', 'path': 'lib'}),
            'dev_read': ({'path': 'lib/a.rb', 'start_line': 3}, {'op': 'read', 'path': 'lib/a.rb', 'start_line': 3}),
            'dev_search': ({'pattern': 'x', 'fixed': False}, {'op': 'search', 'pattern': 'x', 'fixed': False}),
            'dev_status': ({}, {'op': 'status'}),
            'dev_diff': ({'scope': 'unpushed'}, {'op': 'diff', 'scope': 'unpushed'}),
            'dev_test': ({'suite': 'lint', 'file': 'lib/a.rb'}, {'op': 'test', 'suite': 'lint', 'file': 'lib/a.rb'}),
            'dev_push_show': ({}, {'op': 'push-show'}),
            'dev_write': ({'path': 'a.rb', 'content': 'x'}, {'op': 'write', 'path': 'a.rb', 'content': 'x'}),
            'dev_edit': ({'path': 'a.rb', 'old_text': 'a', 'new_text': 'b'}, {'op': 'edit', 'path': 'a.rb', 'old_text': 'a', 'new_text': 'b'}),
            'dev_delete': ({'path': 'a.rb'}, {'op': 'delete', 'path': 'a.rb'}),
            'dev_branch': ({'topic': 'fix', 'new_pr': True}, {'op': 'branch', 'topic': 'fix', 'new_pr': True}),
            'dev_format': ({'path': 'converters/mybb', 'content': 'dropped'}, {'op': 'format', 'path': 'converters/mybb'}),
            'dev_commit': ({'message': 'Fix'}, {'op': 'commit', 'message': 'Fix'}),
            'dev_push_propose': ({'title': 'T', 'body': 'B'}, {'op': 'push-propose', 'title': 'T', 'body': 'B'}),
        }
        self.assertEqual(set(cases) | {'dev_findings', 'dev_finding_show'}, set(self.tools('converter-developer')))
        for tool, (args, request) in cases.items():
            with self.subTest(tool=tool):
                self.assertEqual(True, self.call('converter-developer', tool, dict(workspace='example-forum', op='push', sha256='0' * 64, **args))['ok'])
                self.assertEqual([[['converter', 'dev', 'example-forum', '--role', 'developer'], json.dumps(request)]], self.calls())

    def test_reviewer_is_read_only_before_anything_runs(self):
        self.assertEqual(set(), WRITE_TOOLS & set(self.tools('converter-reviewer')))
        for tool in WRITE_TOOLS:
            with self.subTest(tool=tool):
                self.assertEqual('STANDARD_DEV_OPERATION_REFUSED', self.call('converter-reviewer', tool, {'workspace': 'example-forum', 'path': 'a', 'content': 'x'})['error'])
                self.assertEqual([], self.calls())
        self.call('converter-reviewer', 'dev_test', {'workspace': 'example-forum'})
        self.assertEqual([[['converter', 'dev', 'example-forum', '--role', 'reviewer'], json.dumps({'op': 'test'})]], self.calls())

    def test_findings_use_the_released_only_surface(self):
        self.call('converter-reviewer', 'dev_findings', {'workspace': 'example-forum'})
        self.call('converter-developer', 'dev_finding_show', {'workspace': 'example-forum', 'finding_id': 'finding-' + 'a' * 32})
        self.assertEqual([[['standard', 'agent', 'findings', 'example-forum'], ''],
                          [['standard', 'agent', 'finding-show', 'example-forum', 'finding-' + 'a' * 32], '']], self.calls())

    def test_no_push_approval_and_invalid_arguments_never_invoke_control(self):
        for agent in ('converter-developer', 'converter-reviewer'):
            for tool, args in (('dev_push', {'workspace': 'x', 'sha256': '0' * 64}), ('converter_push', {'workspace': 'x'}),
                               ('dev_list', {'workspace': '../x'}), ('dev_list', {'workspace': 'x;id'}), ('dev_list', {}),
                               ('dev_finding_show', {'workspace': 'x', 'finding_id': 'finding-x'})):
                with self.subTest(agent=agent, tool=tool, args=args):
                    self.assertIn(self.call(agent, tool, args)['error'], ('STANDARD_TOOL_UNKNOWN', 'STANDARD_ARGUMENTS_INVALID'))
        self.assertEqual([], self.calls())

    def test_in_a_web_ui_project_only_that_workspace(self):
        for agent in ('converter-developer', 'converter-reviewer'):
            with self.subTest(agent=agent):
                self.assertTrue(self.call(agent, 'dev_status', {'workspace': 'arc'}, project='arc')['ok'])
                self.assertEqual('STANDARD_WORKSPACE_NOT_THIS_PROJECT', self.call(agent, 'dev_status', {'workspace': 'arc'}, project='acme')['error'])
        # Outside a project: the developer works as before; the reviewer (often a sub-agent) refuses.
        self.assertTrue(self.call('converter-developer', 'dev_status', {'workspace': 'arc'}, project=None)['ok'])
        self.assertEqual('STANDARD_CHAT_NOT_IN_PROJECT', self.call('converter-reviewer', 'dev_status', {'workspace': 'arc'}, project=None)['error'])
        self.assertEqual(3, len(self.calls()))

    def test_only_the_developer_may_start_an_agent_and_only_the_reviewer(self):
        import re
        delegation = ('spawn_agent', 'wait_agent', 'continue_agent', 'list_agents', 'cancel_agent', 'queue_agent', 'initiate_handover', 'hub_delegate')
        for agent in ('converter-developer', 'converter-reviewer', 'migration-data', 'migration-operator', 'server-support'):
            text = (AGENTS / agent / 'agent.yaml').read_text()
            enabled = re.search(r'(?m)^  enabled: \[(.*)\]', text)
            tools = [name.strip() for name in enabled.group(1).split(',')] if enabled else []
            with self.subTest(agent=agent):
                if agent == 'converter-developer':
                    self.assertEqual(['spawn_agent', 'wait_agent'], [tool for tool in tools if tool in delegation])
                    spawn = re.search(r'(?ms)^spawn:\n((?:  .*\n)+)', text).group(1)
                    self.assertIn('allowed_agents: [converter-reviewer]', spawn)
                    self.assertIn('max_depth: 1', spawn)
                    # A spawned agent must pass its parent's model rule too: the developer lists
                    # claude-bin so the reviewer (claude-bin only) can run, and nothing more.
                    allowed = text.split('allowed_models:')[1].split('workspace:')[0]
                    self.assertEqual(['chatgpt:*', 'claude-bin:*'], re.findall(r'(?m)^  - "([^"]+)"', allowed))
                else:
                    self.assertEqual([], [tool for tool in tools if tool in delegation])
                    self.assertNotRegex(text, r'(?m)^spawn:')
        reviewer = (AGENTS / 'converter-reviewer/agent.yaml').read_text()
        self.assertRegex(reviewer, r'(?m)^provider: claude-bin$')
        self.assertEqual(['claude-bin:*'], re.findall(r'(?m)^  - "([^"]+)"', reviewer.split('allowed_models:')[1].split('workspace:')[0]))

if __name__ == '__main__':
    unittest.main()
