"""Bounded INVENTED-DATA Rails prepared-custom process acceptance (cached Docker only).

  SILO_MERGE_PROCESS_RAILS_LIVE=1 python3 -I -B test/merge_process_rails_live_test.py

Actual pinned Rails3158 overlay, PostgreSQL and dedicated validation Redis; production
merge_validation_config.rb, merge_validate.rb, merge_run.rb, stock merger start,
physical adapter, settings preservation, reference verifier and engine backup verifier.
The production StandardMergeValidation provisioning SQL, journal shape and template
custody checks are called through a socket-free, exact-owned-PG stdio fixture
transport in the cached Ruby control image. Journal persistence is fixture-only.
This fixture explicitly removes inherited boot upload metadata through core before
seeding an original-only supported subset: two source uploads with real SHA1s and
one destination baseline. It proves neither synthetic upload identity support nor
optimized-source support. This is guest composition, NOT the full host service pipeline: host locks,
registry, custody journals, validation receipts/preclaim gate, orchestration, rebake,
release and restore of a released backup are not covered. No customer/server/deploy
access, ports, binds, pulls or builds. Missing cached prerequisites FAIL if opted in.
All helper bytes go through docker cp; credentials stay in private 0600 files/stdin.
Raw process output stays private and is never included in test failures. Exact labelled
resource cleanup runs in finally, with the shared fixture's 900-second test budget.
"""
import hashlib
import io
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import struct
import subprocess
import tarfile
import time
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('process_settings_fixture', ROOT / 'test/merge_site_settings_live_test.py')
settings = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(settings)
GATE = os.environ.get('SILO_MERGE_PROCESS_RAILS_LIVE') == '1'


def png(color):
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 1, 1, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(b'\0' + bytes(color))) + chunk(b'IEND', b''))


class ProcessFixture(settings.SettingsFixture):
    def __init__(self):
        super().__init__()
        self.name = 'silo-mpr-live-' + self.token

    def assert_isolation(self):
        super().assert_isolation()
        volumes = {name for kind, name in self.resources if kind == 'volume'}
        for kind, name in self.resources:
            if kind == 'container':
                doc = self.owned(kind, name)
                assert all(m['Name'] in volumes for m in doc['Mounts'] if m['Type'] == 'volume'), 'untracked volume detected'

    def stage(self, name, data, guest=None):
        path = self.private / name
        path.write_bytes(data if isinstance(data, bytes) else data.encode())
        path.chmod(0o600)
        self.copy(path, guest or '/tmp/' + name)
        self.docker('exec', self.web, 'chmod', '0600', guest or '/tmp/' + name)

    def guest_json(self, guest):
        path = self.private / ('read-' + secrets.token_hex(4))
        self.docker('cp', self.web + ':' + guest, str(path))
        path.chmod(0o600)
        return json.loads(path.read_bytes())

    def drive(self, action, *env):
        started = time.monotonic()
        result = self.docker('exec', '-e', 'LIVE_ACTION=' + action,
            *[item for value in env for item in ('-e', value)], self.web,
            'su', 'discourse', '-c', 'cd /var/www/discourse && exec env BUNDLE_WITH=generic_import '
            'RAILS_ENV=production bundle exec ruby /tmp/merge_process_rails_live_driver.rb',
            check=False, timeout=180)
        self.timings.append((action, round(time.monotonic() - started, 1)))
        # Emit only the driver's fixed codes/classes/source-line projections.
        for line in result.stdout.decode(errors='replace').splitlines():
            if re.fullmatch(r'LIVE:[A-Za-z0-9_:=.,\[\]" /-]+', line):
                print(line, flush=True)
        return result

    def host(self, spec):
        path = self.private / 'host.json'
        path.write_text(json.dumps(spec))
        path.chmod(0o600)
        profile = json.loads(settings.shared.PROFILE.read_text())
        image = json.loads(self.docker('image', 'inspect', profile['images']['control']['ref']).stdout)[0]['Id']
        role = 'control-' + secrets.token_hex(4)
        control = self.container(role, image, '-i', '--entrypoint', 'ruby',
            command=('/src/test/support/merge_process_rails_live_host.rb', '/private/spec.json'), start=False)
        # Copy a scoped tree through docker cp: no host socket, executable bind,
        # cached gems or customer/workspace mounts. Ruby asks this Python fixture
        # for SQL over a private stdio bridge bound to its exact owned PG ID.
        tree = self.private / ('control-tree-' + secrets.token_hex(4))
        tree.mkdir(mode=0o700)
        (tree / 'src/test/support').mkdir(parents=True, exist_ok=True)
        import shutil
        shutil.copyfile(ROOT / 'test/support/merge_process_rails_live_host.rb', tree / 'src/test/support/merge_process_rails_live_host.rb')
        (tree / 'private').mkdir(mode=0o700)
        shutil.copyfile(path, tree / 'private/spec.json')
        (tree / 'private/spec.json').chmod(0o600)
        self.docker('cp', str(tree) + '/.', control + ':/')
        if 'archive' in spec:
            self.docker('cp', spec['archive_host'], control + ':' + spec['archive'])
        # docker cp cannot rename an existing directory atomically; this fixed
        # bootstrap only arranges the copied library tree, never runs a shell.
        # A separate exact-ID exec is not possible until start, so copy paths
        # directly to /src after the parent directory now exists.
        self.docker('cp', str(ROOT / 'lib'), control + ':/src/lib')
        self.docker('cp', str(ROOT / 'runtime'), control + ':/src/runtime')
        process = subprocess.Popen(['docker', 'start', '-ai', control], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        ok = False
        try:
            while selector.select(timeout=max(0, min(120, self.deadline - time.monotonic()))):
                line = process.stdout.readline()
                if not line:
                    break
                self.outputs.append(line)
                if line.startswith(b'{'):
                    try:
                        request = json.loads(line)
                    except (json.JSONDecodeError, UnicodeError):
                        raise AssertionError('private SQL bridge protocol invalid (output suppressed)') from None
                    try:
                        out = self.sql(request['sql'], request['database'])
                        response = {'ok': True, 'out': out + '\n'}
                    except AssertionError:
                        response = {'ok': False, 'out': ''}
                    process.stdin.write((json.dumps(response) + '\n').encode())
                    process.stdin.flush()
                elif line == b'LIVE:host_ok\n':
                    ok = True
                elif line.startswith((b'LIVE:host_error_class=', b'LIVE:host_source_lines=')):
                    print(line.decode().strip(), flush=True)
            process.wait(timeout=10)
        finally:
            selector.close()
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
            process.stdin.close()
            process.stdout.close()
        assert process.returncode == 0 and ok, 'fixture production provision/output adapter refused (raw output suppressed)'

    def fingerprints(self):
        result = {}
        for db in ('discourse', 'merge_source', 'silo_clean_base'):
            if db != 'discourse':
                self.sql('ALTER DATABASE ' + db + ' ALLOW_CONNECTIONS true')
            tables = self.sql("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename", db).splitlines()
            queries = ["SELECT '" + table + "', md5(COALESCE(string_agg(to_jsonb(t)::text, '' ORDER BY to_jsonb(t)::text), '')) FROM public.\"" + table + '\" t' for table in tables]
            try:
                result[db] = dict(line.split('|', 1) for line in self.sql(' UNION ALL '.join(queries), db).splitlines())
            finally:
                if db != 'discourse':
                    self.sql('ALTER DATABASE ' + db + ' ALLOW_CONNECTIONS false')
        return result


@unittest.skipUnless(GATE, 'opt in with SILO_MERGE_PROCESS_RAILS_LIVE=1 (invented data only)')
class RailsProcessAcceptance(unittest.TestCase):
    def test_complete_guest_composition(self):
        missing = settings.prerequisites()
        self.assertFalse(bool(missing), 'missing cached local prerequisite(s); no pulls/builds allowed: ' + ', '.join(missing))
        f = ProcessFixture()
        try:
            self.accept(f)
        finally:
            f.close()
            print('LIVE:cleanup_confirmed', flush=True)

    def accept(self, f):
        f.setup(site=True)
        f.quiesce()
        # All fixtures and production helpers copied, not bound from the workspace.
        for path in sorted((ROOT / 'runtime/prebuilt-discourse').glob('merge*.rb')):
            f.copy(path, '/tmp/' + path.name)
        for path in sorted((ROOT / 'runtime/shared').glob('merge*.rb')):
            f.copy(path, '/tmp/' + path.name)
        for path in sorted((ROOT / 'test/support').glob('merge_process_rails_live*.rb')):
            if path.name.endswith('_host.rb'):
                continue
            f.copy(path, '/tmp/' + path.name)
        f.docker('exec', f.web, 'mkdir', '-p', '/shared/merge', '/shared/merge-process', '/shared/source-uploads')
        f.docker('exec', f.web, 'chown', '-R', 'discourse:discourse', '/shared/merge', '/shared/merge-process', '/shared/source-uploads')
        for name, color in [('carried', (255, 0, 0)), ('excluded', (0, 255, 0)), ('baseline', (0, 0, 255))]:
            f.stage('live-' + name + '.png', png(color))
        f.sql('CREATE DATABASE merge_source TEMPLATE discourse OWNER discourse')
        self.assertTrue(f.drive('seed', 'LIVE_KIND=destination').returncode == 0, 'destination core API seed failed')
        f.sql('CREATE DATABASE silo_clean_base TEMPLATE discourse OWNER postgres')
        source_config = f.private / 'source.conf'
        f.docker('cp', f.web + ':/var/www/discourse/config/discourse.conf', str(source_config))
        source_config.chmod(0o600)
        config_bytes = source_config.read_text()
        config_bytes = re.sub(r'^\s*db_name\s*=.*$', '', config_bytes, flags=re.M) + "\ndb_name = 'merge_source'\n"
        f.stage('live-source.conf', config_bytes)
        self.assertTrue(f.drive('seed', 'LIVE_KIND=source', 'SILO_MERGE_CONFIG=/tmp/live-source.conf').returncode == 0, 'source core API seed failed')
        source = f.guest_json('/tmp/live-seed-source.json')
        metadata_counts = f.sql("SELECT count(*) || ',' || count(*) FILTER (WHERE sha1 IS NULL) || ',' || count(*) FILTER (WHERE sha1 ~ '^[0-9a-f]{40}$') FROM uploads", 'merge_source')
        print('LIVE:source_upload_total_null_valid=' + metadata_counts, flush=True)
        baseline = f.guest_json('/tmp/live-seed-destination.json')['baseline']
        # Separate physical roots: source's two core-generated files are removed from
        # destination inventory and moved to the validation/runtime source root.
        for name in ('carried', 'excluded'):
            relative = source[name]['url'].split('/uploads/default/', 1)[1]
            parent = str(Path(relative).parent)
            f.docker('exec', f.web, 'mkdir', '-p', '/shared/source-uploads/' + parent)
            f.docker('exec', f.web, 'mv', '/shared/uploads/default/' + relative, '/shared/source-uploads/' + relative)
        f.docker('exec', f.web, 'chown', '-R', 'discourse:discourse', '/shared/source-uploads')
        # Verify actual cached file pin, not application commit == file revision.
        stock = f.docker('exec', f.web, 'sha256sum', '/var/www/discourse/script/bulk_import/discourse_merger.rb').stdout.split()[0]
        pin = re.search(r'FILE_SHA256 = "([0-9a-f]+)"', (ROOT / 'runtime/prebuilt-discourse/merge_adapter.rb').read_text()).group(1)
        self.assertTrue(stock.decode() == pin, 'cached stock merger does not match production adapter file pin')
        print('LIVE:stock_file_pin_matches=true', flush=True)
        contract = {'version': 1, 'engine': 'discourse-merger-v1', 'settings_schema': {
            'type': 'object', 'additionalProperties': False,
            'required': ['asset_mode', 'semantic_ok', 'upload_id', 'sha1', 'raw'],
            'properties': {'asset_mode': {'type': 'string', 'enum': ['selected']},
                'semantic_ok': {'type': 'boolean'}, 'upload_id': {'type': 'integer', 'minimum': 1},
                'sha1': {'type': 'string'}, 'raw': {'type': 'string'}}},
            'asset_policy_key': 'asset_mode', 'asset_policies': {'selected': 'carried'},
            'audit_aggregates': {'preflight': ['selected_uploads'], 'postflight': ['selected_uploads']}}
        spec = {'asset_mode': 'selected', 'semantic_ok': True, 'upload_id': source['carried']['id'],
                'sha1': source['carried']['sha1'], 'raw': source['raw']}
        f.stage('live-contract.json', json.dumps(contract))
        f.stage('live-settings.yml', json.dumps(spec))  # JSON is safe YAML, no aliases
        ident = secrets.token_hex(16)
        journal = {'id': ident, 'source': 'silo_val_s_' + ident, 'base': 'silo_val_b_' + ident,
                   'role': 'silo_val_r_' + ident, 'templates': {}}
        password = secrets.token_hex(32)
        before = f.fingerprints()
        # Actual shipped provision method; only journal/custody and SQL transport
        # are fixture adapters. No production receipt/preclaim gate is implied.
        f.host({'action': 'provision', 'db': f.db, 'journal': journal, 'password': password})
        redis_image = json.loads((settings.shared.PROFILE).read_text())['images']['redis']['ref']
        redis_id = json.loads(f.docker('image', 'inspect', redis_image).stdout)[0]['Id']
        validation_redis_volume = f.create('volume', 'validation-redis')
        f.container('validation-redis', redis_id, '-v', validation_redis_volume + ':/data')
        context = dict(journal, password=password, host='db', port=5432, redis_isolated=True,
            redis_host='validation-redis', redis_port=6379, original_config_path='/var/www/discourse/config/discourse.conf',
            validation_config_path='/tmp/discourse-validation.conf', contract_path='/tmp/live-contract.json',
            settings_path='/tmp/live-settings.yml', layer_path='/tmp/merge_process_rails_live_layer.rb', checks=[])
        f.stage('live-context.json', json.dumps(context))
        validation_env = ['SILO_MERGE_VALIDATION_CONTEXT=/tmp/live-context.json',
            'SILO_MERGE_SETTINGS=/tmp/live-settings.yml']

        def validate(label):
            path = '/tmp/live-result-' + label + '.json'
            run = f.drive('validate', *validation_env, 'SILO_MERGE_VALIDATION_RESULT=' + path)
            answer = f.guest_json(path)
            print('LIVE:validation_' + label + '=' + answer['status'] + ':' + answer['reason'], flush=True)
            return run, answer

        # Semantic refusal and corrupt physical bytes must not change a single
        # stored template/working row; boot caches and settings are real Rails.
        spec['semantic_ok'] = False
        f.stage('live-settings.yml', json.dumps(spec))
        run, answer = validate('semantic')
        self.assertTrue(run.returncode != 0 and answer['status'] == 'refused' and answer['reason'] == 'preflight_refused',
                        'semantic refusal not proven; production validation failed earlier')
        after = f.fingerprints()
        for db in before:
            changed = sorted(table for table in before[db] if before[db][table] != after[db].get(table))
            if changed:
                print('LIVE:changed_tables=' + db + ':' + ','.join(changed), flush=True)
        self.assertTrue(before == after, 'semantic refusal changed template/working rows')
        spec['semantic_ok'] = True
        f.stage('live-settings.yml', json.dumps(spec))
        carried_path = '/shared/source-uploads/' + source['carried']['url'].split('/uploads/default/', 1)[1]
        f.stage('live-corrupt.png', b'not a valid carried image', carried_path)
        run, answer = validate('physical')
        self.assertTrue(run.returncode != 0 and answer['status'] == 'refused' and answer['reason'] == 'assets_unproven', 'bad physical asset refusal not proven')
        self.assertTrue(before == f.fingerprints(), 'physical refusal changed template/working rows')
        f.stage('live-carried.png', png((255, 0, 0)), carried_path)
        run, answer = validate('positive')
        self.assertTrue(run.returncode == 0 and answer['status'] == 'passed', 'positive production Rails validation refused')
        self.assertTrue(answer['approved_ids'] == [source['carried']['id']], 'validation selection differs')
        self.assertTrue(before == f.fingerprints(), 'positive validation changed template/working rows')
        print('LIVE:validation_templates_working_unchanged=true', flush=True)
        rows = f.rows()
        self.assertTrue(f.drive('capture').returncode == 0, 'production settings capture failed')
        snapshot = f.private / 'snapshot.json'
        f.docker('cp', f.web + ':/shared/merge/site-settings.json', str(snapshot))
        snapshot.chmod(0o600)
        run_env = {'SILO_MERGE_CONTRACT': '/tmp/live-contract.json', 'SILO_MERGE_SETTINGS': '/tmp/live-settings.yml',
            'SILO_MERGE_LAYER': '/tmp/merge_process_rails_live_layer.rb', 'DB_NAME': 'merge_source',
            'UPLOADS_PATH': '/shared/source-uploads', 'SOURCE_BASE_URL': 'https://invented-source.invalid',
            'SILO_MERGE_SITE_SETTINGS_SHA256': hashlib.sha256(snapshot.read_bytes()).hexdigest(),
            'SILO_MERGE_SELECTION_SHA256': answer['selection_sha256'],
            'SILO_MERGE_ASSET_PREFLIGHT_SHA256': answer['asset_preflight_sha256'],
            'SILO_MERGE_OWNER_PREFLIGHT_SHA256': answer['owner_preflight_sha256']}
        execution_before = f.fingerprints()
        bad_env = dict(run_env, SILO_MERGE_SELECTION_SHA256='0' * 64)
        f.stage('live-run-env.json', json.dumps(bad_env))
        f.sql('ALTER DATABASE merge_source ALLOW_CONNECTIONS true')
        refused = f.drive('run')
        refusal_log = f.docker('exec', f.web, 'cat', '/tmp/live-output').stdout
        self.assertTrue(refused.returncode != 0 and b'SILO_MERGE: start' not in refusal_log and b'SILO_MERGE: done' not in refusal_log, 'changed selection digest reached stock construction')
        self.assertTrue(execution_before == f.fingerprints(), 'selection digest refusal changed database rows')
        print('LIVE:execution_digest_refusal_before_stock_writes=true', flush=True)
        f.stage('live-run-env.json', json.dumps(run_env))
        f.sql('ALTER DATABASE merge_source ALLOW_CONNECTIONS true')
        run = f.drive('run')
        log = f.docker('exec', f.web, 'cat', '/tmp/live-output').stdout
        # Only explicitly projected safe runtime protocol fields are emitted.
        reports = [json.loads(line.split(b':', 1)[1]) for line in log.splitlines() if line.startswith(b'SILO_MERGE_PROCESS:')]
        if run.returncode:
            for line in log.splitlines():
                if re.fullmatch(rb'SILO_MERGE: (?:merger failed \([A-Za-z0-9_: ]+\)|settings [a-z-]+)', line):
                    print(line.decode(), flush=True)
        self.assertTrue(run.returncode == 0 and b'SILO_MERGE: done' in log, 'production merge_run failed (raw output suppressed)')
        self.assertTrue([r['phase'] for r in reports] == ['preflight', 'transfer', 'postflight'] and reports[-1]['complete'], 'complete process evidence missing')
        self.assertTrue(reports[-1]['audit_aggregates'] == {'preflight': {'selected_uploads': 1}, 'postflight': {'selected_uploads': 1}}, 'audit count evidence differs')
        transfer = reports[-1]['transfer']
        self.assertTrue(transfer['files_copied'] == 1 and transfer['files_skipped_by_policy'] == 1, 'selective physical transfer counts differ')
        self.assertTrue({k: v[:2] for k, v in rows.items()} == {k: v[:2] for k, v in f.rows().items()}, 'T2 stored setting equality failed')
        self.assertTrue(f.sql("SELECT count(*) FROM posts WHERE raw LIKE 'Invented carried image%'", 'discourse') == '1', 'carried post missing')
        for name, present in [('carried', True), ('excluded', False)]:
            relative = source[name]['url'].split('/uploads/default/', 1)[1]
            exists = f.docker('exec', f.web, 'test', '-f', '/shared/uploads/default/' + relative, check=False).returncode == 0
            self.assertTrue(exists == present, 'selected/excluded physical asset presence differs')
        print('LIVE:stock_start_selective_assets_t2_references=true', flush=True)
        # Real Discourse backup archive, not a fabricated manifest-only tar.
        self.assertTrue(f.drive('backup').returncode == 0, 'real Discourse backup failed')
        archives = f.docker('exec', f.web, 'find', '/shared/backups', '-type', 'f', '-name', '*.tar.gz').stdout.decode().splitlines()
        self.assertTrue(len(archives) == 1, 'expected exactly one real backup archive')
        archive = f.private / 'backup.tar.gz'
        f.docker('cp', f.web + ':' + archives[0], str(archive), timeout=120)
        archive.chmod(0o600)
        members = {}
        with tarfile.open(archive, 'r:gz') as tar:
            for member in tar:
                if member.isfile() and member.name.startswith('uploads/'):
                    stream = tar.extractfile(member)
                    digest = hashlib.sha256()
                    for chunk in iter(lambda: stream.read(65536), b''):
                        digest.update(chunk)
                    members[member.name] = digest.hexdigest()
        manifest = f.guest_json('/shared/merge-process/asset-manifest.json')
        inventory = f.guest_json('/shared/merge-process/baseline-assets.json')
        required = sorted(set(['uploads/default/' + entry['destination'] for entry in manifest['entries']
                               if entry['disposition'] != 'exclude'] +
                              ['uploads/default/' + entry['path'] for entry in inventory['files']]))
        carried_member = 'uploads/default/' + source['carried']['url'].split('/uploads/default/', 1)[1]
        excluded_member = 'uploads/default/' + source['excluded']['url'].split('/uploads/default/', 1)[1]
        self.assertTrue(members.get(carried_member) == hashlib.sha256(png((255, 0, 0))).hexdigest(), 'carried archive SHA differs')
        self.assertTrue(excluded_member not in members, 'excluded member present in archive')
        f.host({'action': 'verify', 'archive': '/private/backup.tar.gz', 'archive_host': str(archive),
                'required': required, 'manifest': manifest, 'baseline': inventory})
        baseline_member = 'uploads/default/' + baseline['url'].split('/uploads/default/', 1)[1]
        self.assertTrue(members.get(baseline_member) == hashlib.sha256(png((0, 0, 255))).hexdigest(), 'baseline original missing or changed in backup')
        for kind, refusal in [('corrupt_crc', 'SiloMigrate::UsageError'), ('missing_carried', 'SiloMigrate::UsageError'),
                              ('tampered_carried', 'SiloMigrate::MergeProcess::Refused'),
                              ('excluded_member', 'SiloMigrate::MergeProcess::Refused')]:
            bad = f.private / (kind + '.tar.gz')
            if kind == 'corrupt_crc':
                contents = bytearray(archive.read_bytes())
                contents[-8] ^= 0x01
                bad.write_bytes(contents)
            else:
                with tarfile.open(archive, 'r:gz') as original, tarfile.open(bad, 'w:gz', format=tarfile.USTAR_FORMAT) as changed:
                    for member in original:
                        if kind == 'missing_carried' and member.name == carried_member:
                            continue
                        stream = original.extractfile(member) if member.isfile() else None
                        if kind == 'tampered_carried' and member.name == carried_member:
                            data = b'corrupt invented carried bytes'
                            member.size = len(data)
                            stream = io.BytesIO(data)
                        changed.addfile(member, stream)
                    if kind == 'excluded_member':
                        data = png((0, 255, 0))
                        member = tarfile.TarInfo(excluded_member)
                        member.size = len(data)
                        changed.addfile(member, io.BytesIO(data))
            bad.chmod(0o600)
            f.host({'action': 'verify', 'archive': '/private/backup.tar.gz', 'archive_host': str(bad),
                    'required': required, 'manifest': manifest, 'baseline': inventory, 'expected_refusal': refusal})
            print('LIVE:archive_' + kind + '_refused=true', flush=True)
        print('LIVE:real_backup_engine_member_verification=true', flush=True)
        f.assert_isolation()
        print('LIVE:timings=' + json.dumps(f.timings), flush=True)


if __name__ == '__main__':
    unittest.main()
