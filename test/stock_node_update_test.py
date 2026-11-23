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
        self.assertEqual('0.9.122', self.m.TERM_LLM_PINNED)
        self.assertEqual('01258e7461c6eeb08ce97be611f7abbb19dd10f3e76dce7439ba5728bb52dab0', self.m.PIN)
        for version in ('0.9.93', '0.9.99', '0.9.103'):
            conf = self.fixture.configured('TERM_LLM_VERSION=' + version + '\n')
            self.assertEqual('0.9.122', conf['TERM_LLM_VERSION'])
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

    def test_update_from_explicit_103_pin_and_roll_back_both_release_and_binary(self):
        self.m.C.update(self.fixture.configured('TERM_LLM_VERSION=0.9.103\n'))
        p = self.m.P
        for path in (p / 'releases', p / 'state/logs', p / 'state/tmp', p / 'etc', p / 'bin'):
            path.mkdir(parents=True)
        self.m.W.mkdir()
        (self.m.W / '.silo-standard-execution.lock').touch()
        old, new = 'a' * 40, 'b' * 40
        prior, release = p / 'releases' / old, p / 'releases' / new
        for location in (prior, release):
            agent = location / 'integrations/term-llm/migration-data'
            agent.mkdir(parents=True)
            (agent / 'agent.yaml').write_text('name: migration-data\nallowed_models: [cdck_frontier:CDCK/MoM]\n')
        (p / 'current').symlink_to(prior)
        self.m.record({'commit': old, 'term_llm_version': '0.9.103'}, 'apply')
        binary = p / 'term-llm/0.9.103/term-llm'
        binary.parent.mkdir(parents=True)
        binary.write_text('invented previous binary')
        (p / 'bin/term-llm').symlink_to(binary)
        config = p / 'etc/silo-control.env'
        config.write_text('SILO_MIGRATE_BASE_PATH=/invented\nSILO_PROTECTED_SESSIONS=1\n')
        archive, checksum = self.fixture.fake_term_release('0.9.122')
        real_run = self.m.run

        def run(argv, **kwargs):
            if argv[0] != 'curl':
                return real_run(argv, **kwargs)
            dest = Path(argv[-1])
            if dest.name == 'checksums.txt':
                dest.write_text(checksum + '  ' + archive.name + '\n')
            else:
                self.assertEqual(archive.name, dest.name)
                dest.write_bytes(archive.read_bytes())

        with patch.object(self.m, 'resolve', return_value=new), \
                patch.object(self.m, 'fetch_release', return_value=release), \
                patch.object(self.m, 'private_scope_ready', side_effect=AssertionError('experimental capability requested')), \
                patch.object(self.m, 'trust_agents', return_value=True), \
                patch.object(self.m, 'project_default_agent', return_value=True), \
                patch.object(self.m, 'mcp_rules') as rules, \
                patch.object(self.m, 'refresh_service') as refresh, \
                patch.object(self.m, 'PIN', checksum), patch.object(self.m, 'run', side_effect=run), \
                contextlib.redirect_stdout(io.StringIO()):
            self.m.account_update(False)
        rules.assert_called_once_with()
        refresh.assert_called_once_with(force=True)
        self.assertEqual(release, (p / 'current').resolve())
        self.assertEqual(prior, (p / 'previous').resolve())
        self.assertEqual(binary, (p / 'bin/term-llm.previous').resolve())
        upgraded = p / 'term-llm/0.9.122/term-llm'
        self.assertEqual(upgraded, (p / 'bin/term-llm').resolve())
        self.assertNotIn('SILO_PROTECTED_SESSIONS', config.read_text())
        manifest_path = p / 'state/install-manifest.json'
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(('0.9.122', new), (manifest['term_llm_version'], manifest['commit']))

        with patch.object(self.m, 'refresh_service') as refresh, contextlib.redirect_stdout(io.StringIO()):
            self.m.account_update(True, term=True)
        refresh.assert_not_called()  # The operator restarts the managed service after rollback.
        self.assertEqual(prior, (p / 'current').resolve())
        self.assertEqual(binary, (p / 'bin/term-llm').resolve())
        self.assertEqual(upgraded, (p / 'bin/term-llm.previous').resolve())
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(('0.9.103', old), (manifest['term_llm_version'], manifest['commit']))


if __name__ == '__main__':
    unittest.main()
