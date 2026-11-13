"""Opt-in INVENTED-DATA-only production checkpoint/activation PostgreSQL protocol.

    SILO_CHECKPOINT_PROTOCOL_LIVE=1 python3 -I -B test/checkpoint_protocol_live_test.py

Cached images only, an operator-approved current Docker endpoint, no app entrypoint, published
ports, external network, existing resources, or customer mounts. Uses the shared
Fixture's ownership-checked cleanup, 900s run and independent 180s cleanup budgets.
Only PostgreSQL is real: web quiescence, Redis, control store, Rails inspection,
compatibility and disk admission are explicit seams, not end-to-end evidence.
Set SILO_CHECKPOINT_BASELINE=1 to reproduce the e9c0ef0 production boolean-cast
failure. That historical commit must be available locally; no fetch is attempted.
Normal mode requires the fixed actual method.
"""
import importlib.util
import json
import os
import subprocess
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
# -I intentionally excludes test/ from sys.path; load the shared fixture explicitly.
spec = importlib.util.spec_from_file_location('merge_inspection_live_fixture', ROOT / 'test/merge_inspection_live_test.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


@unittest.skipUnless(os.environ.get('SILO_CHECKPOINT_PROTOCOL_LIVE') == '1', 'opt-in invented-data PostgreSQL protocol')
class CheckpointProtocolLiveTest(unittest.TestCase):
    def test_actual_checkpoint_and_activation_protocol(self):
        f = shared.Fixture()
        closed = False

        def cleanup():
            nonlocal closed
            if not closed:
                f.close()
                closed = True

        self.addCleanup(cleanup)
        profile = json.loads(shared.PROFILE.read_text())
        image = json.loads(f.docker('image', 'inspect', profile['images']['web']['ref']).stdout)[0]['Id']
        f.setup()
        # The disposable DB image's normal initialization does not set postgres's
        # remote login password. Assign it through stdin; never argv or output.
        password = (f.private / 'db.env').read_text().splitlines()[0].split('=', 1)[1]
        f.sql("ALTER ROLE postgres PASSWORD '" + password + "'")
        env = f.private / 'helper.env'
        env.write_text('PGPASSWORD=' + password + '\n')
        env.chmod(0o600)
        helper = f.container('helper', image, '--env-file', str(env),
                             '--entrypoint', 'ruby', '--log-driver', 'none',
                             command=('-e', 'loop { sleep 60 }'))
        baseline = os.environ.get('SILO_CHECKPOINT_BASELINE') == '1'
        production = ROOT / 'lib/silo_migrate/services/standard_merge_preparation.rb'
        if baseline:
            # Concurrent parent fixes must not erase the original reproduction:
            # use the actual committed production module, not a handwritten query.
            original = subprocess.run(['git', 'show', 'e9c0ef0de486c1f12cbaacc1d636391039388314:lib/silo_migrate/services/standard_merge_preparation.rb'],
                                      cwd=ROOT, capture_output=True, check=True, timeout=10).stdout
            production = f.private / 'standard_merge_preparation.rb'
            production.write_bytes(original)
        # Private copies of public source only; no repository/customer bind mounts.
        for source, destination in (
            (production, '/tmp/standard_merge_preparation.rb'),
            (ROOT / 'test/checkpoint_protocol_live_driver.rb', '/tmp/checkpoint_protocol_live_driver.rb'),
        ):
            f.docker('cp', str(source), helper + ':' + destination)
        f.assert_isolation()
        result = f.docker('exec', '-e', 'SILO_CHECKPOINT_BASELINE=' + ('1' if baseline else '0'),
                          helper, 'ruby', '/tmp/checkpoint_protocol_live_driver.rb', timeout=720, check=False)
        self.assertEqual(0, result.returncode, 'production protocol driver failed; ' +
                         (result.stderr.decode().strip() if result.stderr.startswith(b'checkpoint protocol live failed (') and len(result.stderr) < 200 else 'live output suppressed'))
        facts = json.loads(result.stdout)
        self.assertEqual(['discourse:true', 'merge_source:true'], facts['raw'])
        if baseline:
            self.assertEqual('baseline', facts['mode'])
            self.assertEqual(facts['raw'], facts['actual'])
            self.assertIs(facts['checkpoint_refused'], True)
        else:
            self.assertEqual('fixed', facts['mode'])
            self.assertEqual(['discourse:t'], facts['fresh'])
            self.assertIs(facts['fresh_connections_accepted'], True)
            self.assertEqual(['discourse:t', 'merge_source:t'], facts['actual'])
            for key in ('checkpoint', 'activation', 'sealed_connections_refused', 'held_session_terminated', 'inspection_mutations_discarded'):
                self.assertIs(facts[key], True)
            self.assertEqual(2, facts['canaries'])
        # Ownership inspection necessarily reads Config.Env privately; only the
        # driver outputs are a protocol evidence boundary (never inspect dumps).
        self.assertFalse(password.encode() in result.stdout + result.stderr, 'credential appeared in driver output')
        # Fixture.close verifies each owned identity is absent, including after
        # failures; the registered callback is idempotent after explicit success.
        counts = {kind: sum(k == kind for k, _ in f.resources) for kind in ('container', 'volume', 'network')}
        cleanup()
        facts['cleanup'] = dict(counts, absence_confirmed=True)
        print('checkpoint-protocol evidence: ' + json.dumps(facts, sort_keys=True), flush=True)


if __name__ == '__main__':
    unittest.main()
