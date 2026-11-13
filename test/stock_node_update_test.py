"""Stock term-llm update regression: invented files and fake installers, no services/network."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('stock_metal_fixtures', ROOT / 'test/metal/test_metal.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class StockNodeUpdateTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.InstallerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.m = self.fixture.m

    def test_official_release_pin_and_legacy_configuration_need_no_package(self):
        self.assertEqual('0.9.103', self.m.TERM_LLM_PINNED)
        self.assertEqual('ad6120221d9c34975c0c6ce25f00d9d3b68d0b174c8bf0bcca20e6e04240d9ed', self.m.PIN)
        for version in ('0.9.93', '0.9.99', '0.9.103'):
            conf = self.fixture.configured('TERM_LLM_VERSION=' + version + '\n')
            self.assertEqual('0.9.103', conf['TERM_LLM_VERSION'])
            self.assertEqual('', conf['TERM_LLM_PACKAGE'])

    def test_shipped_agents_do_not_require_experimental_host_capabilities(self):
        self.assertFalse(self.m.private_scope_required(ROOT))
        self.assertNotIn('lock_session: true', (ROOT / 'integrations/term-llm/migration-data/agent.yaml').read_text())
        with patch.object(self.m, 'private_scope_ready', side_effect=AssertionError('stock release must not probe capabilities')):
            self.m.require_private_scope(ROOT)

    def test_stock_rollback_candidate_does_not_require_a_fork_for_old_yaml(self):
        release = self.m.P / 'releases' / ('c' * 40)
        agent = release / 'integrations/term-llm/migration-data'
        agent.mkdir(parents=True)
        (agent / 'agent.yaml').write_text('name: migration-data\nlock_session: true\n')
        self.assertEqual('', self.m.C['TERM_LLM_PACKAGE'])
        with patch.object(self.m, 'private_scope_ready', side_effect=AssertionError('stock rollback must not query fork capabilities')):
            self.m.require_private_scope(release, binary=self.m.P / 'term-llm/previous/term-llm')

    def test_normal_update_from_older_release_selects_stock_and_retains_mcp_rules(self):
        p = self.m.P
        for path in (p / 'releases', p / 'state/logs', p / 'etc', p / 'bin'):
            path.mkdir(parents=True)
        self.m.W.mkdir()
        (self.m.W / '.silo-standard-execution.lock').touch()
        old, new = 'a' * 40, 'b' * 40
        prior, release = p / 'releases' / old, p / 'releases' / new
        for location, definition in ((prior, 'name: migration-data\nlock_session: true\n'),
                                     (release, 'name: migration-data\nallowed_models: [cdck_frontier:CDCK/MoM]\n')):
            agent = location / 'integrations/term-llm/migration-data'
            agent.mkdir(parents=True)
            (agent / 'agent.yaml').write_text(definition)
        (p / 'current').symlink_to(prior)
        self.m.record({'commit': old, 'term_llm_version': '0.9.99'}, 'apply')
        binary = p / 'term-llm/0.9.103/term-llm'
        binary.parent.mkdir(parents=True)
        binary.write_text('invented stock binary')
        (p / 'bin/term-llm').symlink_to(binary)
        config = p / 'etc/silo-control.env'
        config.write_text('SILO_MIGRATE_BASE_PATH=/invented\nSILO_PROTECTED_SESSIONS=1\n')
        with patch.object(self.m, 'resolve', return_value=new), \
                patch.object(self.m, 'fetch_release', return_value=release), \
                patch.object(self.m, 'private_scope_ready', side_effect=AssertionError('experimental capability requested')), \
                patch.object(self.m, 'refresh_service', return_value=False), \
                self.fixture.node_steps(changed=True) as steps, contextlib.redirect_stdout(io.StringIO()):
            self.m.account_update(False)
        self.assertEqual(['trust_agents', 'term_llm_current', 'project_default_agent', 'mcp_rules'], steps)
        self.assertEqual(release, (p / 'current').resolve())
        self.assertNotIn('SILO_PROTECTED_SESSIONS', config.read_text())
        manifest = json.loads((p / 'state/install-manifest.json').read_text())
        self.assertEqual('0.9.103', manifest['term_llm_version'])
        self.assertEqual(new, manifest['commit'])
        self.assertEqual(prior, (p / 'previous').resolve())


if __name__ == '__main__':
    unittest.main()
