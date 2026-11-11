"""Native model-policy smoke tests; no real models, credentials, or customer data.

Opt in with TERM_LLM_BINARY=/path/to/term-llm python3 -I -B test/agent_model_policy_test.py.
Uses isolated HOME/config/cache/data and loopback-only fake providers with the shipped agents.
This tests term-llm admission, not Claude Code/account availability or backend model identity.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
MODEL = 'claude-opus-5-5'
ROUTE = 'claude-bin:' + MODEL


@unittest.skipUnless(os.environ.get('TERM_LLM_BINARY'), 'set TERM_LLM_BINARY for native policy smoke tests')
class AgentModelPolicyTest(unittest.TestCase):
    def setUp(self):
        self.binary = str(Path(os.environ['TERM_LLM_BINARY']).resolve())
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.project = self.home / 'project'
        self.project.mkdir()
        config_dir = self.home / '.config/term-llm'
        config_dir.mkdir(parents=True)
        (config_dir / 'agents').symlink_to(ROOT / 'integrations/term-llm', target_is_directory=True)
        self.config = config_dir / 'config.yaml'
        self.requests = []
        self.spawn_model = None
        self.model_unavailable = False
        test = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.reply({'object': 'list', 'data': [
                    {'id': model, 'object': 'model'} for model in ('gpt-6.1-sol', MODEL)
                ]})

            def reply(self, body, status=200):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header('content-type', 'application/json')
                self.send_header('content-length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['content-length'])))
                test.requests.append(request)
                if test.model_unavailable and request['model'] == MODEL:
                    self.reply({'error': {'message': 'invented-model-unavailable',
                                          'type': 'invalid_request_error', 'code': 'model_not_found'}}, status=400)
                    return
                tools = [message for message in request.get('messages', []) if message.get('role') == 'tool']
                spawn = request['model'] == 'gpt-6.1-sol' and not tools
                message = {'role': 'assistant', 'content': 'invented-policy-ok'}
                if spawn:
                    args = {'agent_name': 'converter-reviewer', 'prompt': 'Invented route smoke test. Say ok; no tools.', 'wait': 30}
                    if test.spawn_model is not None:
                        args['model'] = test.spawn_model
                    message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                        'id': 'policy-spawn', 'type': 'function',
                        'function': {'name': 'spawn_agent', 'arguments': json.dumps(args)}
                    }]}
                reason = 'tool_calls' if spawn else 'stop'
                if request.get('stream'):
                    self.send_response(200)
                    self.send_header('content-type', 'text/event-stream')
                    self.end_headers()
                    delta = dict(message)
                    if spawn:
                        delta['tool_calls'][0]['index'] = 0
                    for chunk in (
                        {'choices': [{'index': 0, 'delta': delta}]},
                        {'choices': [{'index': 0, 'delta': {}, 'finish_reason': reason}],
                         'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}}
                    ):
                        self.wfile.write(b'data: ' + json.dumps(dict(chunk, id='policy', object='chat.completion.chunk', model=request['model'])).encode() + b'\n\n')
                    self.wfile.write(b'data: [DONE]\n\n')
                else:
                    self.reply({'id': 'policy', 'object': 'chat.completion', 'model': request['model'],
                                'choices': [{'index': 0, 'message': message, 'finish_reason': reason}],
                                'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}})

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(thread.join, 5)
        self.addCleanup(self.server.shutdown)
        port = self.server.server_address[1]
        self.config.write_text(f'''provider_discovery: config
default_provider: chatgpt
providers:
  chatgpt:
    type: vllm
    url: http://127.0.0.1:{port}/v1/chat/completions
    model: gpt-6.1-sol
    api_key: invented-unused
  claude-bin:
    type: vllm
    url: http://127.0.0.1:{port}/v1/chat/completions
    model: {MODEL}
    api_key: invented-unused
agents:
  use_builtin: false
''')
        # Do not inherit credentials, provider environment overrides, or real config paths.
        self.env = {'PATH': os.defpath, 'HOME': str(self.home),
                    'XDG_CONFIG_HOME': str(self.home / '.config'),
                    'XDG_DATA_HOME': str(self.home / 'data'),
                    'XDG_CACHE_HOME': str(self.home / 'cache')}

    def ask(self, agent, route=None):
        args = [self.binary, 'ask', '--text', '--no-session', '--no-search', '--approval', 'yolo',
                '--max-turns', '5', '--agent', agent]
        if route:
            args.extend(['--provider', route])
        return subprocess.run(args + ['Invented route smoke test.'], cwd=self.project, env=self.env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=45)

    def test_direct_reviewer_default_and_explicit_approved_route(self):
        for route in (None, ROUTE):
            with self.subTest(route=route):
                self.requests.clear()
                result = self.ask('converter-reviewer', route)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn('invented-policy-ok', result.stdout)
                self.assertEqual([MODEL], [r['model'] for r in self.requests])

    def test_direct_reviewer_rejects_old_models_aliases_and_other_provider(self):
        for route in ('claude-bin:claude-opus-4-6', 'claude-bin:claude-opus-4-8',
                      'claude-bin:opus', 'chatgpt:gpt-6.1-sol'):
            with self.subTest(route=route):
                self.requests.clear()
                result = self.ask('converter-reviewer', route)
                self.assertNotEqual(0, result.returncode)
                self.assertIn('not allowed for agent', result.stderr)
                self.assertEqual([], self.requests, 'denied model reached the fake provider')

    def test_spawn_default_and_explicit_approved_route(self):
        for route in (None, ROUTE):
            with self.subTest(route=route):
                self.requests.clear()
                self.spawn_model = route
                result = self.ask('converter-developer')
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(['gpt-6.1-sol', MODEL, 'gpt-6.1-sol'], [r['model'] for r in self.requests])
                self.assertNotIn('not allowed for agent', json.dumps(self.requests[-1]))

    def test_spawn_mapping_overrides_stale_reviewer_model_preference(self):
        with self.config.open('a') as out:
            out.write('  preferences:\n    converter-reviewer:\n      model: opus\n')
        result = self.ask('converter-developer')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(['gpt-6.1-sol', MODEL, 'gpt-6.1-sol'], [r['model'] for r in self.requests])

    def test_scoped_preference_commands_restore_routing_and_keep_other_settings(self):
        with self.config.open('a') as out:
            out.write('  preferences:\n    converter-reviewer:\n      model: opus\n      max_turns: 17\n'
                      '      allowed_models: ["claude-bin:*"]\n'
                      '    converter-developer:\n      allowed_models: ["chatgpt:*", "claude-bin:*"]\n')
        commands = (
            ['converter-developer', 'provider=chatgpt', 'model=gpt-6.1-sol',
             'allowed_models=chatgpt:*,claude-bin:claude-opus-5-5'],
            ['converter-reviewer', 'provider=claude-bin', 'model=' + MODEL, 'allowed_models=' + ROUTE],
        )
        for args in commands:
            result = subprocess.run([self.binary, 'agents', 'set'] + args, cwd=self.project, env=self.env,
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
            self.assertEqual(0, result.returncode, result.stderr)
        result = subprocess.run([self.binary, 'agents', 'get', 'converter-reviewer'], cwd=self.project,
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('max_turns: 17', result.stdout)
        self.assertEqual([], self.requests, 'preference changes should not call a model')
        result = self.ask('converter-developer')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(['gpt-6.1-sol', MODEL, 'gpt-6.1-sol'], [r['model'] for r in self.requests])

    def test_unavailable_approved_model_does_not_select_a_fallback(self):
        self.model_unavailable = True
        result = self.ask('converter-developer')
        self.assertEqual(0, result.returncode, result.stderr)
        models = [r['model'] for r in self.requests]
        self.assertIn(MODEL, models)
        self.assertEqual({'gpt-6.1-sol', MODEL}, set(models))
        tool_messages = [m['content'] for m in self.requests[-1]['messages'] if m.get('role') == 'tool']
        self.assertIn('invented-model-unavailable', json.dumps(tool_messages))

    def test_one_stale_wildcard_preference_cannot_bypass_the_other_rule(self):
        original = self.config.read_text()
        for agent, allowed in (
            ('converter-developer', '["chatgpt:*", "claude-bin:*"]'),
            ('converter-reviewer', '["claude-bin:*"]'),
        ):
            with self.subTest(agent=agent):
                self.config.write_text(original + f'  preferences:\n    {agent}:\n      allowed_models: {allowed}\n')
                self.requests.clear()
                self.spawn_model = 'claude-bin:claude-opus-4-6'
                result = self.ask('converter-developer')
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(['gpt-6.1-sol', 'gpt-6.1-sol'], [r['model'] for r in self.requests])
                tool_messages = [m['content'] for m in self.requests[-1]['messages'] if m.get('role') == 'tool']
                self.assertIn('not allowed for agent', json.dumps(tool_messages))

    def test_spawn_rejects_old_models_aliases_and_other_provider(self):
        for route in ('claude-bin:claude-opus-4-6', 'claude-bin:claude-opus-4-8',
                      'claude-bin:opus', 'chatgpt:gpt-6.1-sol'):
            with self.subTest(route=route):
                self.requests.clear()
                self.spawn_model = route
                result = self.ask('converter-developer')
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(['gpt-6.1-sol', 'gpt-6.1-sol'], [r['model'] for r in self.requests],
                                 'denied child reached the fake provider')
                tool_messages = [m['content'] for m in self.requests[-1]['messages'] if m.get('role') == 'tool']
                self.assertTrue(tool_messages, 'no native spawn result observed')
                self.assertIn('not allowed for agent', json.dumps(tool_messages))


if __name__ == '__main__':
    unittest.main()
