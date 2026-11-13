"""Opt-in tiny Discourse backup/restore + real runit quiescence; invented data only.

SILO_PREPARE_RELIABILITY_LIVE=1 python3 -I -B test/prepare_reliability_live_test.py
Uses only the cached qualified profile and uniquely owned disposable resources,
no downloads, published ports, customer mounts or existing instances. This tests
real restore/worker lifecycle composition, not full host Prepare -> Merge or speed
on a customer's large database.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('prepare_reliability_fixture', ROOT / 'test/merge_inspection_live_test.py')
shared = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(shared)


class LifecycleFixture(shared.Fixture):
    def discourse(self, *args, check=True):
        command = ('cd /var/www/discourse && exec env BUNDLE_WITH=generic_import RAILS_ENV=production '
                   'PGHOST=db PGUSER=discourse PGPORT=5432 PGDATABASE=discourse '
                   'PGPASSWORD="$DISCOURSE_DB_PASSWORD" bundle exec script/discourse ' + shlex.join(args))
        return self.docker('exec', self.web, 'su', 'discourse', '-c', command, timeout=240, check=check)

    def quiesce(self):
        if not hasattr(self, 'quiesce_script'):
            self.copy(ROOT / 'lib/silo_migrate/services/standard_merge_preparation.rb', '/tmp/silo-prepare-source.rb')
            # Ask the image's Ruby to evaluate the public constant, including interpolation.
            self.quiesce_script = self.docker('exec', self.web, 'ruby', '-r/tmp/silo-prepare-source.rb', '-e',
                'print SiloMigrate::Services::StandardMergePreparation::MERGE_QUIESCE_SCRIPT').stdout.decode()
        result = self.docker('exec', self.web, 'sh', '-c', self.quiesce_script, timeout=150)
        if not result.stdout.endswith(b'SILO_QUIESCED\n'):
            raise AssertionError('quiescence success marker absent; raw output suppressed')
        if not re.search(rb'SILO_QUIESCE reason=quiesced workers=0\b', result.stdout):
            raise AssertionError('unexpected worker state; raw output suppressed')


@unittest.skipUnless(os.environ.get('SILO_PREPARE_RELIABILITY_LIVE') == '1', 'opt-in cached-image invented restore/worker test')
class PrepareReliabilityLiveTest(unittest.TestCase):
    def test_real_restore_with_normal_workers_and_real_service_stop(self):
        fixture = LifecycleFixture()
        self.addCleanup(fixture.close)
        fixture.setup(site=True)
        env = fixture.owned('container', fixture.name + '-web')['Config']['Env']
        self.assertIn('UNICORN_SIDEKIQS=1', env)
        self.assertNotIn('UNICORN_SIDEKIQS=0', env)
        before = fixture.sql('SELECT count(*) FROM users', database='discourse')
        schema = fixture.sql('SELECT max(version) FROM schema_migrations', database='discourse')
        # The same native SQL-only backup route as Silo's Base-site backup stage.
        fixture.docker('exec', fixture.web, 'sh', '-c',
            'mkdir -m 700 /shared/silo-reliability-backup && chown discourse:discourse /shared/silo-reliability-backup')
        fixture.discourse('backup', '/shared/silo-reliability-backup/invented.sql.gz', '--sql-only')
        names = fixture.docker('exec', fixture.web, 'find', '/shared/silo-reliability-backup',
            '-mindepth', '1', '-maxdepth', '1', '-type', 'f', '-printf', '%f\n').stdout.decode().splitlines()
        self.assertEqual(1, len(names))
        self.assertRegex(names[0], r'^invented-v[A-Za-z0-9.-]+\.sql\.gz$')
        filename = names[0]
        fixture.docker('exec', fixture.web, 'sh', '-c',
            'mkdir -p /var/www/discourse/public/backups/default && cp /shared/silo-reliability-backup/'
            + shlex.quote(filename) + ' /var/www/discourse/public/backups/default/ && '
            'chown -R discourse:discourse /var/www/discourse/public/backups')
        # Early check: real sv/runit, not a stub, with the healthy app already booted.
        fixture.quiesce()
        try:
            fixture.discourse('enable_restore')
            restored = fixture.discourse('restore', filename, '--location', 'local')
            self.assertIn(b'[SUCCESS]', restored.stdout, 'restore success marker absent; raw output suppressed')
        finally:
            fixture.discourse('disable_restore')
        fixture.docker('exec', fixture.web, 'sv', 'up', 'unicorn')
        fixture.wait(lambda: fixture.docker('exec', fixture.web, 'curl', '-s', '-o', '/dev/null',
            '-w', '%{http_code}', 'http://127.0.0.1/srv/status', check=False).stdout == b'200', timeout=120)
        # The original failure point: app restarted by the real restore, then stopped again.
        fixture.quiesce()
        fixture.quiesce()  # already down remains valid
        self.assertEqual(before, fixture.sql('SELECT count(*) FROM users', database='discourse'))
        self.assertEqual(schema, fixture.sql('SELECT max(version) FROM schema_migrations', database='discourse'))
        fixture.assert_isolation()
        print(json.dumps({'result': 'tiny native SQL backup/restore and real runit quiescence passed',
                          'background_worker_setting': 1, 'already_down_accepted': True,
                          'customer_data_used': False, 'full_host_prepare_merge': False}))


if __name__ == '__main__':
    unittest.main()
