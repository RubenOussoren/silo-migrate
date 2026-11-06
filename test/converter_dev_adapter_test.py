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
WRITE_TOOLS = {'dev_write', 'dev_edit', 'dev_delete', 'dev_branch', 'dev_commit', 'dev_push_propose'}


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

    def call(self, agent, tool, args):
        env = dict(os.environ, SILO_CONTROL=str(self.control), RECORD=str(self.record), TERM_LLM_TOOL_NAME=tool, PYTHONDONTWRITEBYTECODE='1')
        env.pop('TERM_LLM_AGENT_DIR', None)
        result = subprocess.run([sys.executable, '-I', '-B', str(AGENTS / agent / 'scripts/dev_tool.py')], input=json.dumps(args),
                                capture_output=True, text=True, env=env, timeout=20)
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
            'dev_branch': ({'topic': 'fix'}, {'op': 'branch', 'topic': 'fix'}),
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


if __name__ == '__main__':
    unittest.main()
