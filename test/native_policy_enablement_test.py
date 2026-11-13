"""Private-agent enablement requires real native protection, not an ignored YAML key.

All installer actions and binaries here are invented fixtures. No services or network.
"""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('native_policy_metal_fixtures', ROOT / 'test/metal/test_metal.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class NativePolicyEnablementTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.InstallerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.m = self.fixture.m
        # Historical opt-in native packaging, not the default stock release.
        self.m.C["TERM_LLM_PACKAGE"] = "/invented/reviewed-native-package"
        self.release = self.m.P / 'releases' / ('b' * 40)
        agent = self.release / 'integrations/term-llm/migration-data'
        agent.mkdir(parents=True)
        (agent / 'agent.yaml').write_text('name: migration-data\nlock_session: true\n')

    def test_requires_both_versioned_generic_capabilities(self):
        accepted = {'session_scope_lock': 1, 'custom_tool_session_context': 1}
        for value in (None, '', '{}', '[]', 'bad', json.dumps({'private_upload_context': 1, 'session_scope_lock': 1}),
                      json.dumps(dict(accepted, custom_tool_session_context=True)),
                      json.dumps(dict(accepted, session_scope_lock=0)), ' ' * 8193):
            with self.subTest(value=value), patch.object(self.m, 'output', return_value=value), self.assertRaisesRegex(self.m.Refusal, 'METAL_PRIVATE_SESSION_REQUIRED'):
                self.m.require_private_scope(self.release)
        with patch.object(self.m, 'output', return_value=json.dumps(accepted)) as output:
            self.m.require_private_scope(self.release, as_account=False)
        self.assertEqual(['capabilities', '--json'], output.call_args.args[0][-2:])
        self.assertFalse(output.call_args.kwargs['account'])

    def test_unlocked_release_does_not_require_new_capabilities(self):
        (self.release / 'integrations/term-llm/migration-data/agent.yaml').write_text('name: ordinary\nlock_session: false\n')
        with patch.object(self.m, 'output') as output:
            self.m.require_private_scope(self.release)
        output.assert_not_called()

    def test_update_refuses_before_switch_config_mcp_history_or_service(self):
        old = 'a' * 40
        prior = self.m.P / 'releases' / old
        prior.mkdir()
        (self.m.P / 'state/logs').mkdir(parents=True)
        (self.m.P / 'current').symlink_to(prior)
        self.m.record({'commit': old, 'term_llm_version': 'invented-old'}, 'apply')
        manifest = (self.m.P / 'state/install-manifest.json').read_bytes()
        history = (self.m.P / 'state/history.jsonl').read_bytes()
        self.m.W.mkdir(parents=True)
        (self.m.W / '.silo-standard-execution.lock').touch()
        with patch.object(self.m, 'resolve', return_value=self.release.name), \
                patch.object(self.m, 'fetch_release', return_value=self.release), \
                patch.object(self.m, 'output', return_value='{}'), \
                patch.object(self.m, 'switch') as switch, patch.object(self.m, 'mcp_rules') as mcp, \
                patch.object(self.m, 'refresh_service') as service, \
                patch.object(self.m, 'verify_release_images') as images, \
                self.assertRaisesRegex(self.m.Refusal, 'METAL_PRIVATE_SESSION_REQUIRED'):
            self.m.account_update(False)
        for action in (switch, mcp, service, images):
            action.assert_not_called()
        self.assertEqual(prior, (self.m.P / 'current').resolve())
        self.assertEqual(manifest, (self.m.P / 'state/install-manifest.json').read_bytes())
        self.assertEqual(history, (self.m.P / 'state/history.jsonl').read_bytes())

    def test_unchanged_native_refresh_refuses_before_private_agent_or_mcp_wiring(self):
        (self.m.P / 'current').symlink_to(self.release)
        with patch.object(self.m, 'output', return_value='{}'), \
                patch.object(self.m, 'trust_agents') as agents, patch.object(self.m, 'mcp_rules') as mcp, \
                patch.object(self.m, 'term_llm_current') as install, \
                self.assertRaisesRegex(self.m.Refusal, 'METAL_PRIVATE_SESSION_REQUIRED'):
            self.m.node_term_llm()
        for action in (agents, mcp, install):
            action.assert_not_called()

    def test_dbhub_flag_is_written_only_after_native_probe_and_removed_on_unlocked_rollback(self):
        path = self.m.P / 'etc/silo-control.env'
        path.parent.mkdir(parents=True)
        original = 'SILO_MIGRATE_BASE_PATH=/invented/workspaces\nSILO_CONTROL_GEMS=/invented/gems\n'
        path.write_text(original)
        with patch.object(self.m, 'output', return_value='{}'), self.assertRaisesRegex(self.m.Refusal, 'METAL_PRIVATE_SESSION_REQUIRED'):
            self.m.set_private_scope_flag(self.release)
        self.assertEqual(original, path.read_text())
        with patch.object(self.m, 'output', return_value='{"session_scope_lock":1,"custom_tool_session_context":1}'):
            self.assertTrue(self.m.set_private_scope_flag(self.release))
        self.assertEqual(original + 'SILO_PROTECTED_SESSIONS=1\n', path.read_text())
        unlocked = self.m.P / 'releases' / ('c' * 40)
        unlocked.mkdir()
        with patch.object(self.m, 'output') as output:
            self.assertTrue(self.m.set_private_scope_flag(unlocked))
        output.assert_not_called()
        self.assertEqual(original, path.read_text())

    def test_bad_native_selection_revokes_grant_and_restores_previous_binary(self):
        path = self.m.P / 'etc/silo-control.env'
        path.parent.mkdir(parents=True)
        path.write_text('SILO_MIGRATE_BASE_PATH=/invented\nSILO_PROTECTED_SESSIONS=1\n')
        old, new = [self.m.P / 'term-llm' / version / 'term-llm' for version in ('capable', 'incapable')]
        for binary in (old, new):
            binary.parent.mkdir(parents=True)
            binary.write_text('invented binary fixture')
        (self.m.P / 'bin').mkdir()
        current = self.m.P / 'bin/term-llm'
        current.symlink_to(old)
        (self.m.P / 'current').symlink_to(self.release)
        def swap():
            (self.m.P / 'bin/term-llm.previous').symlink_to(old)
            current.unlink()
            current.symlink_to(new)
            return True
        with patch.object(self.m, 'private_scope_ready', side_effect=lambda *a, **k: current.resolve() == old), \
                patch.object(self.m, 'trust_agents', return_value=True), \
                patch.object(self.m, 'term_llm_current', side_effect=swap), \
                patch.object(self.m, 'mcp_rules') as mcp, \
                self.assertRaisesRegex(self.m.Refusal, 'METAL_PRIVATE_SESSION_REQUIRED'):
            self.m.node_term_llm()
        mcp.assert_not_called()
        self.assertEqual(old, current.resolve())
        self.assertNotIn('SILO_PROTECTED_SESSIONS', path.read_text())

    def test_failed_reverification_revokes_a_preexisting_grant(self):
        path = self.m.P / 'etc/silo-control.env'
        path.parent.mkdir(parents=True)
        path.write_text('SILO_MIGRATE_BASE_PATH=/invented\nSILO_PROTECTED_SESSIONS=1\n')
        with patch.object(self.m, 'output', return_value='{}'), self.assertRaisesRegex(self.m.Refusal, 'METAL_PRIVATE_SESSION_REQUIRED'):
            self.m.set_private_scope_flag(self.release)
        self.assertEqual('SILO_MIGRATE_BASE_PATH=/invented\n', path.read_text())

    def test_dbhub_flag_does_not_follow_a_control_config_symlink(self):
        path = self.m.P / 'etc/silo-control.env'
        path.parent.mkdir(parents=True)
        sentinel = self.fixture.root / 'sentinel'
        sentinel.write_text('unchanged')
        path.symlink_to(sentinel)
        with patch.object(self.m, 'output', return_value='{"session_scope_lock":1,"custom_tool_session_context":1}'), \
                self.assertRaisesRegex(self.m.Refusal, 'METAL_CONTROL_CONFIG'):
            self.m.set_private_scope_flag(self.release)
        self.assertEqual('unchanged', sentinel.read_text())

    def test_rollback_capability_probe_checks_candidate_not_current_binary(self):
        candidate = self.m.P / 'term-llm/previous/term-llm'
        with patch.object(self.m, 'output', return_value='{}') as output, \
                self.assertRaisesRegex(self.m.Refusal, 'METAL_PRIVATE_SESSION_REQUIRED'):
            self.m.require_private_scope(self.release, binary=candidate)
        self.assertEqual(candidate, output.call_args.args[0][0])


if __name__ == '__main__':
    unittest.main()
