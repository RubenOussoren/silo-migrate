"""Opt-in cached PostgreSQL parallel-index /dev/shm regression; INVENTED DATA only.

    SILO_RESTORE_SHM_LIVE=1 python3 -I -B test/restore_shm_live_test.py

Requires Docker, the cached qualified PostgreSQL and Ruby images, about 2 GiB
available RAM and 2 GiB disposable disk. No pulls, ports, customer mounts or
existing instances. Uses the shared Fixture's labelled ownership/cleanup on the
current Docker endpoint; run only with operator approval for these resources.

This is a reduced-scale PostgreSQL mechanism test, not a customer restore or a
proof that 2x headroom suffices for arbitrary concurrent maintenance workloads.
Production db_settings is extracted, not reimplemented. The old equal-memory
setting is compared to proposed/fixed 2x headroom on the SAME volume/table.
Both cases reserve 8 MiB of /dev/shm to model competing occupancy. On the cached
PG 18.6 / pgvector 0.8.7 image, an otherwise idle equal-sized /dev/shm succeeded
with two workers: this test does NOT claim equal limits alone always fail. HNSW
is an invented repro workload, not evidence of any customer's index method.
"""
import concurrent.futures
import importlib.util
import json
import os
import secrets
from pathlib import Path
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('restore_shm_fixture', ROOT / 'test/merge_inspection_live_test.py')
shared = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(shared)


def db_settings(fixture, image):
    """Extract production settings with cached Ruby and a private source-only copy."""
    source = fixture.private / 'prebuilt_stack.rb'
    source.write_bytes((ROOT / 'lib/silo_migrate/services/prebuilt_stack.rb').read_bytes())
    source.chmod(0o644)  # Contains public source only; private parent remains 0700.
    fixture.allowed_binds[fixture.name + '-settings'] = {'/source/prebuilt_stack.rb': str(source)}
    helper = '''require "json"
require "prebuilt_stack"
stack = SiloMigrate::Services::PrebuiltStack.allocate
puts JSON.generate(JSON.parse(STDIN.read).map { |limit| stack.send(:db_settings, limit) })
'''
    container = fixture.container('settings', image, '-i', '--read-only',
        '--mount', 'type=bind,src=' + str(source) + ',dst=/source/prebuilt_stack.rb,readonly',
        '--entrypoint', 'ruby', command=('-I/source', '-e', helper), start=False)
    limits = [dict(memory_mib=2048, shared_buffers_mib=128,
                   maintenance_work_mem_mib=128, shm_mib=shm) for shm in (128, 256)]
    result = fixture.docker('start', '-ai', container, data=json.dumps(limits).encode())
    if fixture.owned('container', container)['State']['ExitCode']:
        raise AssertionError('production db_settings extraction failed (output suppressed)')
    return json.loads(result.stdout)


class ShmFixture(shared.Fixture):
    def start_db(self, role, image, settings):
        env, command, shm = settings
        self.db = self.container(role, image, '-v', self.pg_volume + ':/var/lib/postgresql',
                                 '--env-file', str(self.private / 'db.env'), *env,
                                 '--memory', '2048m', '--memory-swap', '2048m', '--cpus', '2',
                                 '--shm-size', shm, command=(*command,
                                     '-c', 'max_worker_processes=4',
                                     '-c', 'max_parallel_workers=2',
                                     '-c', 'max_parallel_maintenance_workers=2',
                                     '-c', 'min_parallel_table_scan_size=0',
                                     '-c', 'dynamic_shared_memory_type=posix'))
        self.wait(lambda: self.docker('exec', self.db, 'pg_isready', '-U', 'postgres',
                                      check=False).returncode == 0)
        self.assert_isolation()
        doc = self.owned('container', self.db)
        assert doc['HostConfig']['ShmSize'] == int(shm[:-1]) * 1024**2
        assert doc['HostConfig']['Memory'] == 2048 * 1024**2
        assert self.sql('SHOW maintenance_work_mem') == '128MB'
        assert self.sql('SHOW max_parallel_maintenance_workers') == '2'
        assert self.sql('SHOW dynamic_shared_memory_type') == 'posix'
        # A fresh idle 128 MiB /dev/shm can fit this pgvector version's single
        # parallel graph. Model bounded competing DSM occupancy explicitly and
        # identically in BOTH cases; do not claim equal limits alone always fail.
        self.docker('exec', self.db, 'dd', 'if=/dev/zero',
                    'of=/dev/shm/invented-competing-occupancy', 'bs=1M', 'count=8', 'status=none')
        assert self.docker('exec', self.db, 'stat', '-c', '%s',
                           '/dev/shm/invented-competing-occupancy').stdout.strip() == b'8388608'

    def index(self):
        statement = b'''\\set VERBOSITY verbose
SET application_name = 'silo_restore_shm_index';
CREATE INDEX invented_parallel_idx ON invented_rows USING hnsw (embedding vector_l2_ops);
'''
        workers = set()
        phases = set()
        # docker() supplies a bounded subprocess deadline and suppresses raw errors.
        # Poll a second backend: configured workers alone are NOT proof of execution.
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(self.docker, 'exec', '-i', self.db,
                'psql', '-X', '-qAt', '-U', 'postgres', '-d', 'postgres',
                '-v', 'ON_ERROR_STOP=1', data=statement, timeout=240, check=False)
            while not future.done():
                rows = self.sql("""SELECT w.pid FROM pg_stat_activity w
                    JOIN pg_stat_activity l ON w.leader_pid=l.pid
                    WHERE w.backend_type='parallel worker'
                      AND l.application_name='silo_restore_shm_index'""")
                workers.update(int(pid) for pid in rows.splitlines() if pid)
                phase = self.sql("""SELECT phase FROM pg_stat_progress_create_index p
                    JOIN pg_stat_activity a ON p.pid=a.pid
                    WHERE a.application_name='silo_restore_shm_index'""")
                if phase:
                    phases.add(phase)
                time.sleep(0.05)
            result = future.result()
        return result, sorted(workers), sorted(phases)


@unittest.skipUnless(os.environ.get('SILO_RESTORE_SHM_LIVE') == '1',
                     'opt-in cached-image invented parallel index test')
class RestoreShmLiveTest(unittest.TestCase):
    def test_equal_memory_enospc_with_competing_occupancy_then_double_headroom_same_data(self):
        f = ShmFixture()
        self.addCleanup(f.close)
        profile = json.loads(shared.PROFILE.read_text())
        image = json.loads(f.docker('image', 'inspect', profile['images']['db']['ref']).stdout)[0]['Id']
        ruby = json.loads(f.docker('image', 'inspect', profile['images']['control']['ref']).stdout)[0]['Id']
        f.network = f.create('network', 'int', '--internal')
        old, fixed = db_settings(f, ruby)
        self.assertEqual(old[:2], fixed[:2], 'only /dev/shm may change')
        f.pg_volume = f.create('volume', 'pg')
        # No password in argv, output or report. The shared fixture removes this
        # private directory after exact-owned container/volume/network cleanup.
        env = f.private / 'db.env'
        env.write_text('DB_PASSWORD=' + secrets.token_hex(32) + '\n')
        env.chmod(0o600)
        f.start_db('equal', image, old)
        vector_version = f.sql("SELECT default_version FROM pg_available_extensions WHERE name='vector'")
        self.assertTrue(vector_version, 'cached image lacks pgvector; no download is permitted')
        f.docker('exec', '-i', f.db, 'psql', '-X', '-qAt', '-U', 'postgres',
                 '-v', 'ON_ERROR_STOP=1', timeout=180, data=b'''
CREATE EXTENSION vector;
CREATE TABLE invented_rows AS
 SELECT n, ARRAY(SELECT sin(n::float8 * j) FROM generate_series(1, 32) j)::vector(32) AS embedding
 FROM generate_series(1, 120000) n;
ALTER TABLE invented_rows SET (parallel_workers=2);
ANALYZE invented_rows;
''')
        fingerprint_sql = 'SELECT count(*), sum(n), pg_relation_size(\'invented_rows\') FROM invented_rows'
        before = f.sql(fingerprint_sql)
        version = f.sql('SHOW server_version')
        failed, old_workers, old_phases = f.index()
        print(json.dumps(dict(stage='equal-memory observation', server_version=version,
                              vector_version=vector_version, returncode=failed.returncode,
                              observed_worker_count=len(old_workers), phases=old_phases), sort_keys=True))
        # Only this exact error qualifies; disk-full, OOM, timeouts or serial
        # failures must never masquerade as the parallel DSM regression.
        self.assertNotEqual(0, failed.returncode, 'equal-memory index unexpectedly succeeded; repro not established')
        self.assertIn(b'53100', failed.stderr, 'expected disk_full SQLSTATE (raw output suppressed)')
        self.assertIn(b'could not resize shared memory segment', failed.stderr)
        self.assertIn(b'No space left on device', failed.stderr)
        f.sql('DROP INDEX IF EXISTS invented_parallel_idx')
        self.assertFalse(f.owned('container', f.db)['State']['OOMKilled'])
        f.docker('stop', '--time', '30', f.db)
        # A cleanly stopped server, same named volume, no data regeneration.
        f.start_db('headroom', image, fixed)
        self.assertEqual(before, f.sql(fingerprint_sql))
        succeeded, fixed_workers, fixed_phases = f.index()
        self.assertEqual(0, succeeded.returncode, '2x-headroom index failed (raw output suppressed)')
        self.assertGreaterEqual(len(fixed_workers), 1, 'no actual parallel worker observed; cannot claim parallel success')
        self.assertEqual('t', f.sql("SELECT indisvalid FROM pg_index WHERE indexrelid='invented_parallel_idx'::regclass"))
        self.assertEqual(before, f.sql(fingerprint_sql))
        self.assertFalse(f.owned('container', f.db)['State']['OOMKilled'])
        f.assert_isolation()
        receipt = dict(result='equal-memory DSM ENOSPC; 2x-headroom parallel index succeeded',
                       server_version=version, vector_version=vector_version,
                       index_method='hnsw', rows=120000, vector_dimensions=32, maintenance_mib=128,
                       old_shm_mib=128, fixed_shm_mib=256, competing_shm_occupancy_mib=8,
                       container_memory_mib=2048,
                       old_observed_worker_count=len(old_workers), fixed_observed_worker_count=len(fixed_workers),
                       old_phases=old_phases, fixed_phases=fixed_phases,
                       same_table_and_volume=True, customer_data_used=False,
                       limitation='reduced scale, one index at a time; not a full restore or concurrency guarantee')
        resources = list(f.resources)
        private = f.private
        f.close()
        # Fixture.close rechecks exact ownership before each deletion. Confirm
        # exact names are absent too, without inspecting unrelated resources.
        for kind, name in resources:
            self.assertNotEqual(0, f.docker(kind, 'inspect', name, check=False).returncode)
        self.assertFalse(private.exists())
        f.resources.clear()
        receipt['cleanup'] = dict(containers=sum(kind == 'container' for kind, _ in resources),
                                  volumes=sum(kind == 'volume' for kind, _ in resources),
                                  internal_networks=sum(kind == 'network' for kind, _ in resources),
                                  exact_names_absent=True, private_directory_absent=True)
        print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    unittest.main()
