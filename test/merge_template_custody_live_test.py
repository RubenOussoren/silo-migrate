"""Invented-only custody regression on the cached profile's PostgreSQL18 image.

  SILO_MERGE_CUSTODY_SIZE_LIVE=1 python3 -I -B test/merge_template_custody_live_test.py

Autovacuum can visit a closed template and change physical storage without changing
its logical rows. Exercise the production custody comparator with actual before/
after metadata, not an 8 KiB tolerance. This is NOT host lifecycle/approval/Start or
guest policy acceptance. No customer inputs, ports, external network, pulls/builds
or host data mounts; only source/gems are mounted read-only in the comparison
client. Exact invocation-labelled PG/client containers are reconciled in finally.
"""
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONTROL = 'sha256:32ca6f94a3ffe387eb1b9d34edc4be8e9308da1c80a3dce8b7b8310d84949240'
PROFILE = ROOT / 'runtime/profiles/discourse-2026.11.0-latest-3158c750.json'
LABEL = 'silo-migrate.custody-size-live'
RUBY = r'''
require "json"
require_relative "/src/lib/silo_migrate/named_workspace_store"
require_relative "/src/lib/silo_migrate/standard_store"
require_relative "/src/lib/silo_migrate/services/standard_merge_validation"
value = JSON.parse(STDIN.read)
host = Object.new.extend(SiloMigrate::Services::StandardMergeValidation)
before, after = value.values_at("before", "after")
raise "old_comparison_did_not_detect_drift" if before == after
raise "physical_drift_refused" unless host.send(:mv_same_template_custody?, after, before)
%w[oid owner].each do |key|
  changed = Marshal.load(Marshal.dump(after))
  changed.fetch("silo_clean_base")[key] += 1
  raise "identity_drift_accepted" if host.send(:mv_same_template_custody?, changed, before)
end
puts JSON.generate("physical_drift_accepted" => true, "identity_owner_changes_refused" => true)
'''


@unittest.skipUnless(os.environ.get('SILO_MERGE_CUSTODY_SIZE_LIVE') == '1',
                     'opt in with SILO_MERGE_CUSTODY_SIZE_LIVE=1 (cached local images only)')
class TemplateCustodyLiveTest(unittest.TestCase):
    def docker(self, *args, input=None, timeout=30, check=True):
        result = subprocess.run(['docker', '--host', 'unix:///var/run/docker.sock', *args],
                                input=input, capture_output=True, text=True, timeout=timeout)
        if check:
            self.assertEqual(result.returncode, 0, 'invented fixture Docker operation failed; raw output withheld')
        return result

    def sql(self, statement, database='postgres'):
        return self.docker('exec', '-i', self.pg, 'psql', '-X', '-qAt', '-h', '/tmp', '-U', 'postgres',
                           '-d', database, '-v', 'ON_ERROR_STOP=1', input=statement, timeout=20).stdout.strip()

    def snapshot(self):
        return json.loads(self.sql("SELECT json_object_agg(datname,json_build_object('oid',oid::bigint,'owner',datdba::bigint,'closed',NOT datallowconn,'sessions',(SELECT count(*) FROM pg_stat_activity a WHERE a.datid=d.oid),'bytes',pg_database_size(oid))) FROM pg_database d WHERE datname IN ('merge_source','silo_clean_base');"))

    def test_background_maintenance_size_drift_keeps_logical_rows_and_stable_custody(self):
        profile = json.loads(PROFILE.read_text())
        image = self.docker('image', 'inspect', '--format', '{{.Id}}', profile['images']['db']['ref']).stdout.strip()
        self.assertRegex(image, r'^sha256:[0-9a-f]{64}$')
        self.assertEqual(self.docker('image', 'inspect', '--format', '{{.Id}}', CONTROL).stdout.strip(), CONTROL)
        gems = ROOT.parents[1] / '.runtime-cache/gems'
        self.assertTrue(gems.is_dir(), 'existing frozen gem cache required; do not install')
        token = secrets.token_hex(16)
        name = 'silo-custody-live-' + token
        names = [name + '-pg', name + '-client']
        self.pg = None
        success = False
        try:
            # Put autovacuum=off in config, not -c: ALTER SYSTEM must later be
            # able to enable it without changing the templates or reconnecting.
            start = "/usr/lib/postgresql/18/bin/initdb -D /tmp/pgdata --no-locale -A trust >/tmp/init.log 2>&1 && printf '\\nautovacuum=off\\n' >> /tmp/pgdata/postgresql.conf && exec /usr/lib/postgresql/18/bin/postgres -D /tmp/pgdata -c listen_addresses='' -c unix_socket_directories=/tmp -c shared_buffers=64MB -c autovacuum_naptime=1s -c autovacuum_vacuum_threshold=1 -c autovacuum_vacuum_scale_factor=0 -c autovacuum_analyze_threshold=1 -c autovacuum_analyze_scale_factor=0 -c autovacuum_vacuum_cost_delay=0"
            self.pg = self.docker('create', '--pull=never', '--name', names[0], '--label', LABEL + '=' + token,
                '--network', 'none', '--read-only', '--user', 'postgres', '--cap-drop', 'ALL',
                '--security-opt', 'no-new-privileges', '--pids-limit', '128', '--memory', '768m', '--cpus', '2',
                '--tmpfs', '/tmp:rw,nosuid,nodev,size=512m,mode=1777',
                '--tmpfs', '/var/lib/postgresql:rw,nosuid,nodev,size=1m,mode=1777',
                '--entrypoint', '/bin/sh', image, '-c', start).stdout.strip()
            self.assertRegex(self.pg, r'^[0-9a-f]{64}$')
            pg = json.loads(self.docker('container', 'inspect', self.pg).stdout)[0]
            self.assertEqual(pg['HostConfig']['NetworkMode'], 'none')
            self.assertFalse(pg['HostConfig']['PortBindings'])
            self.assertFalse([m for m in pg['Mounts'] if m['Type'] in ('bind', 'volume')])
            self.docker('start', self.pg)
            deadline = time.monotonic() + 30
            while self.docker('exec', self.pg, 'pg_isready', '-h', '/tmp', '-U', 'postgres', check=False).returncode:
                self.assertLess(time.monotonic(), deadline, 'invented PostgreSQL readiness timeout')
                time.sleep(.2)
            self.assertTrue(self.sql('SHOW server_version;').startswith('18.'), 'fixture expects pinned PG18')
            self.sql('CREATE DATABASE merge_source;\nCREATE DATABASE silo_clean_base;\n')
            self.sql("CREATE TABLE invented_rows AS SELECT g AS id, repeat('invented',10) AS body FROM generate_series(1,10000) g; CREATE INDEX invented_rows_idx ON invented_rows(id);", 'silo_clean_base')
            checksum = "SELECT count(*)::text||':'||md5(string_agg(id::text||body,',' ORDER BY id)) FROM invented_rows;"
            logical = self.sql(checksum, 'silo_clean_base')
            self.sql('ALTER DATABASE merge_source ALLOW_CONNECTIONS false;\nALTER DATABASE silo_clean_base ALLOW_CONNECTIONS false;\n')
            before = self.snapshot()
            self.sql('CREATE DATABASE invented_source_copy TEMPLATE merge_source;\nCREATE DATABASE invented_base_copy TEMPLATE silo_clean_base;\n')
            self.sql('ALTER SYSTEM SET autovacuum=on; SELECT pg_reload_conf();')
            self.assertEqual(self.sql('SHOW autovacuum;'), 'on')
            deadline = time.monotonic() + 35
            while True:
                after = self.snapshot()
                if after['silo_clean_base']['bytes'] != before['silo_clean_base']['bytes'] and all(row['sessions'] == 0 for row in after.values()):
                    break
                self.assertLess(time.monotonic(), deadline, 'closed-template maintenance size drift not reproduced')
                time.sleep(.2)
            for key in before:
                for field in ('oid', 'owner', 'closed'):
                    self.assertEqual(before[key][field], after[key][field])
                self.assertTrue(after[key]['closed'])
                self.assertEqual(after[key]['sessions'], 0)
            normalize = lambda snapshot: {key: {field: row[field] for field in ('oid', 'owner', 'bytes')} for key, row in snapshot.items()}
            payload = json.dumps({'before': normalize(before), 'after': normalize(after)})
            compared = self.docker('run', '--rm', '--pull=never', '-i', '--name', names[1], '--label', LABEL + '=' + token,
                '--network', 'none', '--read-only', '--user', str(os.getuid()) + ':' + str(os.getgid()),
                '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--pids-limit', '64', '--memory', '256m',
                '--tmpfs', '/tmp:rw,nosuid,nodev,size=32m,mode=1777',
                '--mount', 'type=bind,src=' + str(ROOT) + ',dst=/src,readonly',
                '--mount', 'type=bind,src=' + str(gems) + ',dst=/gems,readonly',
                '-e', 'GEM_HOME=/gems', '-e', 'GEM_PATH=/gems:/gems/ruby/3.3.0', CONTROL,
                'ruby', '-e', RUBY, input=payload, timeout=30)
            result = json.loads(compared.stdout)
            self.assertEqual(result, {'physical_drift_accepted': True, 'identity_owner_changes_refused': True})
            self.sql('ALTER DATABASE silo_clean_base ALLOW_CONNECTIONS true;')
            self.assertEqual(self.sql(checksum, 'silo_clean_base'), logical)
            counts = self.sql("SELECT autovacuum_count::text||':'||autoanalyze_count::text FROM pg_stat_user_tables WHERE relname='invented_rows';", 'silo_clean_base')
            self.assertTrue(any(int(n) > 0 for n in counts.split(':')))
            success = True
            print('CUSTODY_LIVE:' + json.dumps({'old_size_equality_would_refuse': True, 'production_comparator_passed': True,
                'closed_idle_identity_owner_preserved': True, 'logical_rows_unchanged': True,
                'base_physical_delta': after['silo_clean_base']['bytes'] - before['silo_clean_base']['bytes']}))
        finally:
            for target in reversed(names):
                found = self.docker('container', 'inspect', '--format', '{{.Id}}|{{index .Config.Labels "' + LABEL + '"}}', target, check=False)
                if found.returncode == 0:
                    identity, owned = found.stdout.strip().split('|')
                    self.assertEqual(owned, token, 'refusing to remove foreign fixture')
                    if target == names[0] and self.pg:
                        self.assertEqual(identity, self.pg)
                    self.docker('rm', '-f', identity)
                self.assertEqual(self.docker('container', 'ls', '-a', '--filter', 'name=^/' + target + '$', '--format', '{{.ID}}').stdout.strip(), '')
            self.assertEqual(self.docker('container', 'ls', '-a', '--filter', 'label=' + LABEL + '=' + token, '--format', '{{.ID}}').stdout.strip(), '')
            print('CUSTODY_LIVE:exact_fixture_cleanup_confirmed=' + str(True).lower() + ',passed=' + str(success).lower())


if __name__ == '__main__':
    unittest.main()
