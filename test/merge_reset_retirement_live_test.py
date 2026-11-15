"""Opt-in installed-launcher retirement acceptance using invented data only.

SILO_MERGE_RESET_LIVE=1 python3 -I -B test/merge_reset_retirement_live_test.py

The v1 unknown attempt seeded here is synthetic historical evidence, not a
normal successful production validation. No network access, image acquisition,
published ports, customer inputs, or external server is permitted.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'connected_live', ROOT / 'test/merge_connected_live_test.py')
connected = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(connected)
GATE = os.environ.get('SILO_MERGE_RESET_LIVE') == '1'


def tree_snapshot(root):
    result = {}
    for path in sorted(root.rglob('*')):
        rel = str(path.relative_to(root))
        st = path.lstat()
        if path.is_symlink():
            result[rel] = ('symlink', os.readlink(path), st.st_mode & 0o777)
        elif path.is_file():
            data = path.read_bytes()
            result[rel] = ('file', len(data), hashlib.sha256(data).hexdigest(), st.st_mode & 0o777)
        elif path.is_dir():
            result[rel] = ('dir', st.st_mode & 0o777)
    return result


def private_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(json.dumps(value, separators=(',', ':')) + '\n')
    path.chmod(0o600)


@unittest.skipUnless(GATE, 'opt in with SILO_MERGE_RESET_LIVE=1 (invented data only)')
class ResetRetirementAcceptance(unittest.TestCase):
    def seed_legacy_attempt(self, fixture, attempt, run_id, generation, settings_id):
        """Seed explicit historical-v1-shaped unknown evidence and actual scratch DBs."""
        state = fixture.state()
        dbs = [v['containers']['db'] for v in state['instances'].values()
               if v.get('containers', {}).get('db')]
        assert len(dbs) == 1, 'expected exactly one owned preparation database container'
        db_id = dbs[0].get('id') if isinstance(dbs[0], dict) else dbs[0]
        role = 'silo_val_r_' + attempt
        source_db, base_db = 'silo_val_s_' + attempt, 'silo_val_b_' + attempt
        query = ("SELECT datname, oid, datdba, datallowconn, "
                 "(SELECT count(*) FROM pg_stat_activity a WHERE a.datid=d.oid), pg_database_size(oid) "
                 "FROM pg_database d WHERE datname IN ('merge_source','silo_clean_base') ORDER BY datname;\n")
        result = fixture.docker('exec', '-i', db_id, 'psql', '-X', '-q', '-At',
                                '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres',
                                data=query.encode())
        rows = [line.split('|') for line in result.stdout.decode().splitlines() if line]
        assert len(rows) == 2 and [row[0] for row in rows] == ['merge_source', 'silo_clean_base'], 'template catalogue was not exact'
        templates = {}
        for name, oid, owner, allow, sessions, size in rows:
            assert allow == 'f' and sessions == '0', 'template not sealed and connection-free'
            templates[name] = {'oid': int(oid), 'owner': int(owner), 'bytes': int(size)}
        sql = (f"CREATE ROLE {role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;\n"
               f"CREATE DATABASE {source_db} TEMPLATE merge_source OWNER postgres;\n"
               f"CREATE DATABASE {base_db} TEMPLATE silo_clean_base OWNER postgres;\n")
        fixture.docker('exec', '-i', db_id, 'psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1',
                       '-U', 'postgres', '-d', 'postgres', data=sql.encode())
        owned_sql = (f"SELECT datname, oid, datdba, pg_get_userbyid(datdba) FROM pg_database WHERE datname IN ('{source_db}','{base_db}') ORDER BY datname;\n"
                     f"SELECT rolname, oid, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolbypassrls, rolreplication, rolcanlogin FROM pg_roles WHERE rolname='{role}';\n")
        rows = fixture.docker('exec', '-i', db_id, 'psql', '-X', '-q', '-At', '-v',
                              'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres',
                              data=owned_sql.encode()).stdout.decode().splitlines()
        assert len(rows) == 3, 'seeded legacy resources could not be independently identified'
        identity_rows = [line.split('|') for line in rows]
        identity_rows.sort(key=lambda row: [source_db, base_db, role].index(row[0]))
        assert all(r[3] == 'postgres' for r in identity_rows[:2]), 'scratch database owner differs'
        assert identity_rows[2][0] == role and identity_rows[2][2:] == ['f','f','f','f','f','f','t'], 'scratch role is not low privilege'
        journal = {
            'version': 1, 'id': attempt, 'prepared_from': run_id, 'generation': generation,
            'source': source_db, 'base': base_db, 'role': role, 'templates': templates,
            'status': 'owned_unknown', 'cleanup_confirmed': False,
            'owned_identities': identity_rows,
        }
        receipt = {
            'version': 1, 'receipt_id': attempt, 'status': 'refused', 'reason': 'STANDARD_MERGE_VALIDATION_UNPROVEN',
            'settings': settings_id, 'prepared_from': run_id, 'generation': generation,
            'templates': templates, 'cleanup_confirmed': False,
        }
        validations = fixture.standard / 'validations'
        private_json(validations / (attempt + '.resources.json'), journal)
        private_json(validations / (attempt + '.json'), receipt)
        return db_id, source_db, base_db, role

    def test_legacy_unknown_attempt_is_retired_and_fresh_claim_passes(self):
        missing = connected.connected_prerequisites()
        self.assertFalse(missing, 'missing cached prerequisites: ' + ', '.join(missing))
        f = connected.ConnectedFixture()
        try:
            source = f.seed_backups()
            f.install()
            # The installed launcher may clean owned connector registrations
            # after a successful apply. Isolate that host-side effect from the
            # developer's real Term-LLM configuration even in this disposable
            # fixture; only an empty private MCP registry is reachable.
            private_xdg = f.private / 'xdg'
            private_xdg.mkdir(mode=0o700)
            private_term_config = private_xdg / 'term-llm'
            private_term_config.mkdir(mode=0o700)
            private_json(private_term_config / 'mcp.json', {'servers': {}})
            f.environment['XDG_CONFIG_HOME'] = str(private_xdg)
            for kind, name in f.resources:
                if kind == 'container':
                    f.docker('stop', '--time', '20', f.owned(kind, name)['Id'])
            src, base, settings = f.register_inputs(source)

            f.phase = 'retirement_prepare'
            prep = f.invoke('--cached-review-runtime', 'standard', 'plan', 'propose',
                            'invented', '--operation', 'merge-prepare', '--source', src,
                            '--base-site', base)
            self.assertIsInstance(prep, dict)
            f.approve(prep)
            started = f.cli('run', 'start', 'invented', prep['plan_id'])
            self.assertEqual(started['status'], 'completed')
            old_run = started['run_id']
            state = f.state()
            old_env = state['runs'][old_run]['merge_environment']
            self.assertEqual(old_env['phase'], 'ready')
            old_generation = old_env['generation']
            old_instance_name = state['runs'][old_run]['instances']['review']
            old_instance = state['instances'][old_instance_name]
            old_containers = set(old_instance['containers'].values())
            old_networks = list(old_instance['networks'])
            old_volumes = list(old_instance['volumes'])

            attempt = secrets.token_hex(16)
            db_id, old_source_db, old_base_db, old_role = self.seed_legacy_attempt(
                f, attempt, old_run, old_generation, settings[True])
            receipt_path = f.standard / 'validations' / (attempt + '.json')
            journal_path = f.standard / 'validations' / (attempt + '.resources.json')
            receipt_before, journal_before = receipt_path.read_bytes(), journal_path.read_bytes()
            inputs_before = tree_snapshot(f.workspace / 'inputs')
            named_before = (f.workspace / '.silo-migrate/named/state.json').read_bytes()
            merger_root = f.workspace / 'merger'
            self.assertTrue(merger_root.is_dir(), 'registered invented merger worktree missing')
            merger_before = tree_snapshot(merger_root)
            self.assertTrue(merger_before, 'merger-tree preservation snapshot is empty')

            # The legacy unresolved attempt gates a custom proposal before any
            # attempt to clean its scratch SQL in place.
            f.phase = 'legacy_gate_refusal'
            args = ('plan', 'propose', 'invented', '--operation', 'merge',
                    '--prepared-from', old_run, '--generation', old_generation,
                    '--intent', 'custom')
            refused = f.cli(*args, '--settings', settings[True], expected=1)
            self.assertEqual(refused.get('error'), 'STANDARD_MERGE_VALIDATION_FAILED')
            self.assertEqual(receipt_path.read_bytes(), receipt_before)
            self.assertEqual(journal_path.read_bytes(), journal_before)

            f.phase = 'detached_old_runtime_producers'
            # Prove domain destruction works even while an old guest/SQL child
            # is active. Do not manufacture historical producer completion or
            # terminate these children independently to make reset pass.
            f.docker('exec', '-d', old_instance['containers']['web'], 'sleep', '1800')
            f.docker('exec', '-d', db_id, 'psql', '-X', '-q', '-U', 'postgres',
                     '-d', 'dbname=postgres application_name=silo_legacy_reset_live',
                     '-c', 'SELECT pg_sleep(1800);')
            deadline = time.monotonic() + 10
            while True:
                active = f.docker('exec', db_id, 'psql', '-X', '-q', '-At', '-U', 'postgres', '-d', 'postgres',
                                 '-c', "SELECT count(*) FROM pg_stat_activity WHERE application_name='silo_legacy_reset_live';")
                if active.stdout.strip() == b'1':
                    break
                self.assertLess(time.monotonic(), deadline, 'invented detached SQL producer did not start')
                time.sleep(0.05)

            f.phase = 'reset_preview'
            preview = f.cli('workflow', 'validation-reset-preview', 'invented', '--attempt', attempt)
            self.assertEqual(preview['attempt_id'], attempt)
            self.assertEqual(preview['status'], 'preview')
            self.assertEqual(preview['historical_producer'], 'unproven')
            digest = preview['intent_sha256']
            self.assertRegex(digest, r'^[0-9a-f]{64}$')
            self.assertEqual(preview['persistent_work']['registered_inputs'], 'verified')
            self.assertEqual(receipt_path.read_bytes(), receipt_before)
            self.assertEqual(journal_path.read_bytes(), journal_before)

            # Independently prove the seeded legacy scratch databases and role
            # exist before reset; the subsequent operation must remove their
            # whole containing preparation stack.
            present = f.docker('exec', db_id, 'psql', '-X', '-q', '-At', '-U', 'postgres',
                               '-d', 'postgres', '-c', f"SELECT count(*) FROM pg_database WHERE datname IN ('{old_source_db}','{old_base_db}') UNION ALL SELECT count(*) FROM pg_roles WHERE rolname='{old_role}';")
            self.assertEqual(present.stdout.split(), [b'2', b'1'])

            f.phase = 'reset_apply'
            retired = f.cli('workflow', 'validation-reset-apply', 'invented', '--attempt', attempt,
                            '--intent-sha256', digest, '--yes')
            self.assertEqual(retired['status'], 'reset_retired')
            self.assertEqual(retired['next_action'], 'prepare_new_environment')
            self.assertEqual(retired['intent_sha256'], digest)
            intent_path = f.standard / 'validations' / f'{attempt}.reset-{digest}.intent.json'
            retirement_path = f.standard / 'validations' / f'{attempt}.reset-retirement.json'
            self.assertTrue(intent_path.is_file() and retirement_path.is_file())
            self.assertEqual(receipt_path.read_bytes(), receipt_before)
            self.assertEqual(journal_path.read_bytes(), journal_before)
            retirement = json.loads(retirement_path.read_bytes())
            self.assertEqual(retirement['state'], 'reset_retired')
            self.assertEqual(retirement['historical_producer'], 'unproven')
            self.assertEqual(f.state()['runs'][old_run]['merge_environment']['phase'], 'reset')
            for kind, names in [('network', old_networks), ('volume', old_volumes)]:
                for name in names:
                    self.assertNotEqual(f.docker(kind, 'inspect', name, check=False).returncode, 0)
            current_ids = set(f.docker('ps', '-a', '--no-trunc', '--format', '{{.ID}}').stdout.decode().split())
            self.assertFalse(old_containers & current_ids)
            for role in ('db', 'redis', 'web', 'proxy'):
                self.assertNotEqual(f.docker('container', 'inspect', f'{old_instance_name}-{role}', check=False).returncode, 0)
            self.assertEqual(tree_snapshot(f.workspace / 'inputs'), inputs_before)
            self.assertEqual((f.workspace / '.silo-migrate/named/state.json').read_bytes(), named_before)
            self.assertEqual(tree_snapshot(merger_root), merger_before)

            again = f.cli('workflow', 'validation-reset-apply', 'invented', '--attempt', attempt,
                          '--intent-sha256', digest, '--yes')
            self.assertEqual(again, retired, 'repeat apply was not idempotent')
            self.assertEqual(receipt_path.read_bytes(), receipt_before)
            self.assertEqual(journal_path.read_bytes(), journal_before)

            # A new real Prepare and fresh custom proposal/approval/claim proves
            # retirement satisfies the gate without executing the final merge.
            f.phase = 'fresh_prepare'
            prep2 = f.invoke('--cached-review-runtime', 'standard', 'plan', 'propose',
                             'invented', '--operation', 'merge-prepare', '--source', src,
                             '--base-site', base)
            f.approve(prep2)
            started2 = f.cli('run', 'start', 'invented', prep2['plan_id'])
            self.assertEqual(started2['status'], 'completed')
            new_run = started2['run_id']
            new_generation = f.state()['runs'][new_run]['merge_environment']['generation']
            self.assertNotEqual(new_run, old_run)
            self.assertNotEqual(new_generation, old_generation)
            f.phase = 'fresh_custom_claim'
            plan = f.cli('plan', 'propose', 'invented', '--operation', 'merge',
                         '--prepared-from', new_run, '--generation', new_generation,
                         '--intent', 'custom', '--settings', settings[True])
            f.approve(plan)
            receipts_before = {p.name for p in (f.standard / 'validations').glob('*.json')
                               if not p.name.endswith('.resources.json')}
            claim = f.cli('run', 'claim', 'invented', plan['plan_id'])
            fresh = [p for p in (f.standard / 'validations').glob('*.json')
                     if not p.name.endswith('.resources.json') and p.name not in receipts_before]
            self.assertEqual(len(fresh), 1)
            fresh_receipt = json.loads(fresh[0].read_bytes())
            self.assertEqual(fresh_receipt['status'], 'passed')
            self.assertTrue(fresh_receipt['cleanup_confirmed'])
            self.assertNotEqual(claim['run_id'], new_run)
            self.assertEqual(receipt_path.read_bytes(), receipt_before)
            self.assertEqual(journal_path.read_bytes(), journal_before)
            # A newly proposed plan legitimately adds refs/silo/merge-plans/*.
            # Reset itself was checked against the ENTIRE Git tree above; after
            # normal proposal/claim, compare worktree bytes and unchanged HEAD,
            # not the absence of the new retention refs that must now exist.
            without_git = lambda snapshot: {name: value for name, value in snapshot.items()
                                             if name != '.git' and not name.startswith('.git/')}
            self.assertEqual(without_git(tree_snapshot(merger_root)), without_git(merger_before))
            self.assertEqual(f.cli('merger', 'status', 'invented')['commit'], preview['persistent_work']['merger_commit'])
            self.assertEqual(tree_snapshot(f.workspace / 'inputs'), inputs_before)
            print('CONNECTED_RESET:installed_reset_retirement_saved_work_fresh_prepare_custom_claim=true', flush=True)
        finally:
            phase = f.phase
            f.close()
            print('CONNECTED_RESET:owned_cleanup_confirmed=true last_phase=' + phase,
                  flush=True)


if __name__ == '__main__':
    unittest.main()
