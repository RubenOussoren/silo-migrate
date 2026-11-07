"""migration-data host operations (bin/data_tools.py). Run: python3 -I -B test/data_tools_test.py.

Docker and the control callbacks are faked and recorded; files, paths, moves, checksums,
provenance and audit records are real.
"""
import base64
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tarfile
import tempfile
import types
import unittest
import zipfile
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
MARKER = 'CUSTOMER-CANARY-51c2e9'
DUMP = ('-- MySQL dump 10.13  Distrib 5.7.44\n--\n/*!40101 SET NAMES utf8mb4 */;\n'
        'CREATE TABLE `mybb_users` (\n  `uid` int NOT NULL\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;\n'
        "INSERT INTO `mybb_users` VALUES (1,'" + MARKER + "');\n"
        'CREATE TABLE `mybb_posts` (\n  `pid` int NOT NULL\n);\n-- Dump completed on 2026-11-01\n')


def load():
    spec = importlib.util.spec_from_file_location('data_tools', ROOT / 'bin/data_tools.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeControl:
    """named/standard/converter callbacks that change state the way the real ones do."""

    def __init__(self, base):
        self.base = base
        self.calls = []

    def __call__(self, argv, input=None, timeout=120):
        self.calls.append((argv, input))
        ws = argv[3] if argv[1] in ('source', 'dataset', 'input', 'finding', 'analyst') else argv[2]
        if argv[:2] == ['named', 'init']:
            ws = argv[2]
            root = self.base / ws
            (root / '.silo-migrate/named').mkdir(parents=True)
            (root / 'inputs').mkdir(mode=0o700)
            (root / '.silo-migrate/named/state.json').write_text(json.dumps({'inputs': {}}))
            return json.dumps({'version': 1, 'status': 'initialized'})
        root = self.base / ws
        if argv[:3] == ['named', 'source', 'add']:
            return json.dumps({'version': 1, 'source_id': 'source-' + 'a' * 32, 'status': 'registered'})
        if argv[:3] == ['named', 'dataset', 'add']:
            return json.dumps({'version': 1, 'dataset_id': 'dataset-' + 'b' * 32, 'status': 'registered'})
        if argv[:3] == ['named', 'input', 'add']:
            opts = dict(zip(argv[4::2], argv[5::2]))
            path = root / opts['--path']
            assert hashlib.sha256(path.read_bytes()).hexdigest() == opts['--sha256'], 'registered checksum must match the bytes'
            state = json.loads((root / '.silo-migrate/named/state.json').read_text())
            input_id = 'input-%032x' % (len(state['inputs']) + 1)
            state['inputs'][input_id] = {'id': input_id, 'path': base64.b64encode(opts['--path'].encode()).decode(), 'sha256': opts['--sha256'],
                                         'bytes': int(opts['--bytes']), 'type': opts['--type'], 'dataset_id': opts['--dataset']}
            (root / '.silo-migrate/named/state.json').write_text(json.dumps(state))
            return json.dumps({'version': 1, 'input_id': input_id, 'status': 'registered'})
        if argv[:2] == ['converter', 'clone']:
            (root / 'converter/converters/phpbb').mkdir(parents=True)
            (root / 'converter/.git').mkdir()
            (root / 'converter/.git/config').write_text('[core]\n')
            (root / 'converter/AI-AGENTS.md').write_text('# AI Coding Agent Guide\n')
            return json.dumps({'version': 1, 'status': 'cloned'})
        if argv[:2] == ['standard', 'init']:
            profile = (ROOT / 'runtime/profiles/discourse-2026.11.0-latest-3158c750.json').read_bytes()
            (root / '.silo-migrate/named/standard').mkdir(parents=True)
            (root / '.silo-migrate/named/standard/state.json').write_text(json.dumps({'config': {
                'discourse_profile': 'discourse-2026.11.0-latest-3158c750', 'discourse_profile_sha256': hashlib.sha256(profile).hexdigest()}}))
            return json.dumps({'version': 1, 'status': 'initialized'})
        if argv[:3] == ['standard', 'finding', 'propose']:
            return json.dumps({'version': 1, 'finding_id': 'finding-' + 'c' * 32, 'status': 'proposed'})
        if argv[:3] == ['standard', 'analyst', 'evidence']:
            return json.dumps({'version': 1, 'run_id': argv[4], 'status': 'failed'})
        raise AssertionError(argv)


class FakeDocker:
    def __init__(self):
        self.calls = []
        self.state = {}  # container -> State dict
        self.ready = True

    def __call__(self, argv, timeout=120, input=None):
        self.calls.append((argv, input))
        out, code = b'', 0
        if argv[0] == 'run':
            name = argv[argv.index('--name') + 1]
            self.state[name] = {'Running': True, 'Status': 'running', 'ExitCode': 0}
            out = b'cid\n'
        elif argv[0] == 'inspect':
            name = argv[-1]
            if name not in self.state:
                code = 1
            elif '{{json .State}}' in argv:
                out = json.dumps(self.state[name]).encode()
            elif '{{.State.Running}}' in argv:
                out = b'true' if self.state[name]['Running'] else b'false'
            else:
                out = self.state[name]['Status'].encode()
        elif argv[0] == 'logs':
            out = b'converted 3 records\n'
        elif argv[0] == 'network' and argv[1] == 'inspect':
            code = 1
        elif argv[0] == 'exec':
            if any(arg in ('mariadb-admin', 'pg_isready') for arg in argv):
                code = 0 if self.ready else 1
            elif input and b'information_schema.tables' in input:
                out = b'source\t2\t1\n'
        elif argv[0] == 'rm':
            self.state.pop(argv[-1], None)
        return subprocess.CompletedProcess(argv, code, out, b'')

    def argvs(self, verb):
        return [argv for argv, _ in self.calls if argv[0] == verb]


class DataToolsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        top = Path(self.temp.name)
        self.base = top / 'workspaces'
        self.base.mkdir()
        self.intake = top / 'intake/arc'
        self.intake.mkdir(parents=True, mode=0o700)
        self.d = load()
        self.control = FakeControl(self.base)
        self.docker = FakeDocker()
        patcher = mock.patch.object(self.d, 'docker', side_effect=self.docker)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.host = types.SimpleNamespace(inspect=lambda ref: {'Id': 'sha256:' + '1' * 64, 'ref': ref},
                                          identity=lambda document: self.content_id(document['ref']))
        self.values = {'SILO_CONTROL_GEMS': str(top / 'gems')}
        (top / 'gems').mkdir()

    def content_id(self, ref):
        profile = json.loads((ROOT / 'runtime/profiles/discourse-2026.11.0-latest-3158c750.json').read_text())
        return next(image['content_id'] for image in profile['images'].values() if image['ref'] == ref)

    def op(self, op, **request):
        result = self.d.main(['data', 'arc'], self.values, self.base, ROOT, self.host, io.StringIO(json.dumps(dict(op=op, **request))), self.control)
        self.assertLessEqual(len(json.dumps(result, ensure_ascii=False).encode()), 46 * 1024)
        return result

    def refused(self, expected_code, op, **request):
        with self.assertRaises(self.d.Refusal) as caught:
            self.op(op, **request)
        self.assertTrue(str(caught.exception).startswith(expected_code), str(caught.exception))

    def create(self):
        return self.op('create', platform='mybb')

    def all_docker_argv(self):
        return [' '.join(map(str, argv)) for argv, _ in self.docker.calls]

    # -- confinement -------------------------------------------------------------------

    def test_paths_never_leave_their_area(self):
        outside = Path(self.temp.name) / 'outside'
        outside.mkdir()
        (outside / 'secret.txt').write_text(MARKER)
        (self.intake / 'link.sql').symlink_to(outside / 'secret.txt')
        (self.intake / 'linkdir').symlink_to(outside)
        (self.intake / 'real.sql').write_text(DUMP)
        for path in ('../outside/secret.txt', '/etc/hostname', 'link.sql', 'linkdir/secret.txt', 'a/../real.sql', 'x\n'):
            with self.subTest(path=path):
                with self.assertRaises(self.d.Refusal):
                    self.op('peek', area='intake', path=path, mode='head')
        listing = self.op('list', area='intake')
        kinds = {entry['name']: entry for entry in listing['entries']}
        self.assertEqual('symlink', kinds['link.sql']['type'])
        self.assertNotIn(MARKER, json.dumps(listing))
        self.refused('STANDARD_ARGUMENTS_INVALID', 'list', area='workspaces')
        self.refused('STANDARD_NOT_INITIALIZED', 'list', area='inputs')

    def test_intake_root_must_be_a_real_folder(self):
        self.intake.rmdir()
        self.intake.symlink_to(Path(self.temp.name))
        self.refused('STANDARD_PATH_INVALID', 'list', area='intake')

    def test_converter_area_hides_git(self):
        self.create()
        names = [entry['name'] for entry in self.op('list', area='converter')['entries']]
        self.assertIn('AI-AGENTS.md', names)
        self.assertNotIn('.git', names)
        self.refused('STANDARD_PATH_INVALID', 'peek', area='converter', path='.git/config', mode='head')
        self.assertIn('Guide', self.op('peek', area='converter', path='AI-AGENTS.md', mode='head')['text'])

    # -- reading ------------------------------------------------------------------------

    def test_peek_head_tail_search_and_archive(self):
        (self.intake / 'forum.sql.gz').write_bytes(gzip.compress(DUMP.encode()))
        (self.intake / 'forum.sql').write_text(DUMP)
        head = self.op('peek', area='intake', path='forum.sql.gz', mode='head', bytes=64)
        self.assertEqual(('gzip', 'mysql-dump', True), (head['kind'], head['inner'], head['decompressed']))
        self.assertTrue(head['text'].startswith('-- MySQL dump'))
        self.assertIn('Dump completed', self.op('peek', area='intake', path='forum.sql', mode='tail', bytes=40)['text'])
        found = self.op('peek', area='intake', path='forum.sql.gz', mode='search', pattern='CREATE TABLE')
        self.assertEqual([4, 8], [match['line'] for match in found['matches']])
        self.assertTrue(found['complete'])
        regex = self.op('peek', area='intake', path='forum.sql', mode='search', pattern=r'CHARSET=(\w+)', regex=True)
        self.assertEqual(1, len(regex['matches']))
        self.refused('STANDARD_ARGUMENTS_INVALID', 'peek', area='intake', path='forum.sql', mode='head', bytes=10 ** 6)
        archive = Path(self.temp.name) / 'a.zip'
        with zipfile.ZipFile(archive, 'w') as zf:
            zf.writestr('uploads/a.png', b'x' * 5)
            zf.writestr('dump.sql', DUMP)
        os.replace(archive, self.intake / 'export.zip')
        listing = self.op('peek', area='intake', path='export.zip', mode='archive')
        self.assertEqual(('zip', 2), (listing['archive'], listing['total']))
        tar_path = self.intake / 'backup.tar.gz'
        with tarfile.open(tar_path, 'w:gz') as tf:
            data = gzip.compress(b'-- PostgreSQL database dump\n')
            info = tarfile.TarInfo('dump.sql.gz')
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        self.assertEqual(['dump.sql.gz'], [e['name'] for e in self.op('peek', area='intake', path='backup.tar.gz', mode='archive')['entries']])

    # -- create, take, register ------------------------------------------------------

    def test_create_runs_each_step_once(self):
        first = self.create()
        self.assertEqual(['workspace', 'source', 'dataset', 'converter', 'standard'], first['created'])
        clone = next(argv for argv, _ in self.control.calls if argv[:2] == ['converter', 'clone'])
        self.assertEqual(['--repo', 'https://github.com/discourse-org/discourse-converters.git', '--branch', 'main'], clone[3:])
        calls = len(self.control.calls)
        self.assertEqual([], self.create()['created'])
        self.assertEqual(calls, len(self.control.calls))
        self.refused('STANDARD_PLATFORM_MISMATCH', 'create', platform='phpbb')
        self.refused('STANDARD_ARGUMENTS_INVALID', 'create', platform='MyBB; rm')
        self.refused('STANDARD_ARGUMENTS_INVALID', 'create', platform='mybb', converter_branch='--upload-pack=x')

    def test_take_moves_bytes_unchanged_read_only_and_records_provenance(self):
        self.refused('STANDARD_NOT_INITIALIZED', 'take', path='forum.sql', type='mysql-dump')
        self.create()
        (self.intake / 'Forum Export (1).sql').write_text(DUMP)
        digest = hashlib.sha256(DUMP.encode()).hexdigest()
        result = self.op('take', path='Forum Export (1).sql', type='mysql-dump')
        self.assertEqual(('inputs/Forum_Export_1_.sql', digest, 'moved'), (result['path'], result['sha256'], result['how']))
        target = self.base / 'arc' / result['path']
        self.assertEqual(DUMP, target.read_text())
        self.assertEqual(0o400, stat.S_IMODE(target.stat().st_mode))
        self.assertFalse((self.intake / 'Forum Export (1).sql').exists())
        add = next(argv for argv, _ in self.control.calls if argv[:3] == ['named', 'input', 'add'])
        self.assertIn('--type', add)
        provenance = [json.loads(line) for line in (self.base / 'arc/.silo-migrate/data/provenance.jsonl').read_text().splitlines()]
        self.assertEqual(('take', 'intake/Forum Export (1).sql', digest), (provenance[0]['event'], provenance[0]['from'], provenance[0]['sha256']))
        audit = (self.base / 'arc/.silo-migrate/data/audit.jsonl').read_text()
        self.assertIn('"op": "take"', audit)
        self.assertEqual(0o600, stat.S_IMODE((self.base / 'arc/.silo-migrate/data/audit.jsonl').stat().st_mode))
        (self.intake / 'again.sql').write_text('x')
        self.refused('STANDARD_INPUT_EXISTS', 'take', path='again.sql', type='mysql-dump', name='Forum_Export_1_.sql')
        self.assertTrue((self.intake / 'again.sql').exists())
        os.link(self.intake / 'again.sql', Path(self.temp.name) / 'hardlink')
        self.refused('STANDARD_PATH_INVALID', 'take', path='again.sql', type='mysql-dump')
        self.refused('STANDARD_ARGUMENTS_INVALID', 'take', path='again.sql', type='Mysql Dump')
        self.refused('STANDARD_ARGUMENTS_INVALID', 'take', path='again.sql', type='x', name='../escape')
        failed = [json.loads(line) for line in (self.base / 'arc/.silo-migrate/data/audit.jsonl').read_text().splitlines()][-1]
        self.assertEqual('STANDARD_ARGUMENTS_INVALID', failed['result'])

    def test_register_moves_work_output_with_its_job(self):
        self.create()
        started = self.op('script', code='File.write("/out/users.sql", "x")', into='xml')
        self.refused('STANDARD_BUSY', 'register', path='xml/users.sql', type='derived-sql')
        (self.base / 'arc/work/xml/users.sql').write_text('INSERT INTO users VALUES (1);\n')
        self.docker.state[next(iter(self.docker.state))] = {'Running': False, 'Status': 'exited', 'ExitCode': 0}
        self.assertEqual('succeeded', self.op('job', job_id=started['job_id'])['status'])
        result = self.op('register', path='xml/users.sql', type='derived-sql')
        self.assertEqual('inputs/derived/xml-users.sql', result['path'])
        self.assertEqual(started['job_id'], result['produced_by'])
        record = json.loads((self.base / 'arc/.silo-migrate/data/provenance.jsonl').read_text().splitlines()[-1])
        self.assertEqual(started['script_sha256'], record['job']['script_sha256'])
        self.refused('STANDARD_ARGUMENTS_INVALID', 'register', path='users.sql', type='derived-sql')

    # -- sandbox -------------------------------------------------------------------------

    def test_script_runs_in_a_closed_sandbox_and_is_polled(self):
        self.create()
        code = 'puts "hello"  # ' + MARKER
        started = self.op('script', code=code, into='convert')
        (argv,) = self.docker.argvs('run')
        joined = ' '.join(argv)
        for expected in ('--network none', '--read-only', '--cap-drop ALL', 'no-new-privileges', '--pids-limit 256', '--memory 4g',
                         'dst=/in,readonly', 'dst=/silo,readonly', 'dst=/gems,readonly', 'dst=/job/script.rb,readonly', '--entrypoint timeout'):
            self.assertIn(expected, joined)
        self.assertIn('type=bind,src=%s,dst=/out' % (self.base / 'arc/work/convert'), joined)
        self.assertNotIn('dst=/out,readonly', joined)
        self.assertEqual('sha256:' + '1' * 64, argv[argv.index('timeout') + 1])
        self.assertEqual(['-s', 'KILL', '1800', 'ruby', '/job/script.rb'], argv[argv.index('timeout') + 2:])
        self.assertNotIn(MARKER, joined)
        script = self.base / 'arc/.silo-migrate/data/scripts' / (hashlib.sha256(code.encode()).hexdigest() + '.rb')
        self.assertEqual(code, script.read_text())
        self.assertNotIn(MARKER, (self.base / 'arc/.silo-migrate/data/audit.jsonl').read_text())
        self.refused('STANDARD_BUSY', 'script', code='puts 2', into='other')
        running = self.op('job', job_id=started['job_id'])
        self.assertEqual('running', running['status'])
        self.docker.state[argv[argv.index('--name') + 1]] = {'Running': False, 'Status': 'exited', 'ExitCode': 137, 'OOMKilled': False}
        done = self.op('job', job_id=started['job_id'])
        self.assertEqual(('timed_out', 137), (done['status'], done['exit_code']))
        self.assertIn('converted 3 records', done['log_tail'])
        self.assertIn(['rm', '-f', argv[argv.index('--name') + 1]], self.docker.argvs('rm'))
        (self.base / 'arc/work/convert/out.txt').write_text('x')
        self.refused('STANDARD_OUTPUT_EXISTS', 'script', code='puts 2', into='convert')
        self.refused('STANDARD_ARGUMENTS_INVALID', 'script', code='puts 2', into='../x')
        self.refused('STANDARD_ARGUMENTS_INVALID', 'script', code='puts 2', into='y', timeout_minutes=10 ** 4)
        self.refused('STANDARD_ARGUMENTS_INVALID', 'script', code='x' * (300 * 1024), into='y')
        self.refused('STANDARD_ARGUMENTS_INVALID', 'job', job_id='../jobs')

    def test_extract_runs_the_shipped_extractor_in_the_sandbox(self):
        self.create()
        (self.intake / 'export.zip').write_bytes(b'PK\x05\x06' + b'\x00' * 18)
        self.op('take', path='export.zip', type='archive')
        self.op('extract', path='inputs/export.zip', into='unpacked')
        (argv,) = self.docker.argvs('run')
        self.assertEqual(['python3', '-I', '/silo/bin/data_extract.py', '/in/export.zip', '/out'], argv[-5:])
        self.assertIn('--network', argv)
        self.refused('STANDARD_ARGUMENTS_INVALID', 'extract', path='work/x.zip', into='again')

    # -- source database ---------------------------------------------------------------

    def test_db_up_uses_an_internal_network_and_keeps_passwords_out_of_argv(self):
        self.create()
        self.refused('STANDARD_ARGUMENTS_INVALID', 'db_up', engine='mysql')
        result = self.op('db_up', engine='mariadb')
        self.assertTrue(result['ready'])
        self.assertEqual('silo_ro', result['read_only_user'])
        secret = self.base / 'arc/.silo-migrate/data/db/secret.env'
        self.assertEqual(0o600, stat.S_IMODE(secret.stat().st_mode))
        passwords = [line.split('=', 1)[1] for line in secret.read_text().splitlines() if 'PASSWORD' in line]
        self.assertEqual(2, len(passwords))
        self.assertIn(['network', 'create', '--internal', '--label', 'silo.workspace=arc', 'silo-src-arc'], self.docker.argvs('network'))
        (run,) = self.docker.argvs('run')
        self.assertNotIn('-p', run)
        self.assertNotIn('--publish', run)
        self.assertEqual('silo-src-arc', run[run.index('--network') + 1])
        self.assertIn('--env-file', run)
        self.assertEqual('sha256:' + '1' * 64, run[run.index('--innodb-buffer-pool-size=1G') - 1])
        for joined in self.all_docker_argv():
            for password in passwords:
                self.assertNotIn(password, joined)
        ro = [inp for argv, inp in self.docker.calls if inp and b'CREATE USER' in inp]
        self.assertTrue(ro and b'GRANT SELECT, SHOW VIEW' in ro[0])
        self.refused('STANDARD_DB_ENGINE_MISMATCH', 'db_up', engine='postgres')
        self.assertEqual([['source', 2]], [[s['schema'], s['tables']] for s in self.op('db_status')['schemas']])

    def test_db_load_streams_a_registered_input_from_a_read_only_loader(self):
        self.create()
        (self.intake / 'forum.sql.gz').write_bytes(gzip.compress(DUMP.encode()))
        self.op('take', path='forum.sql.gz', type='mysql-dump')
        self.refused('STANDARD_DB_NOT_UP', 'db_load', path='inputs/forum.sql.gz')
        self.op('db_up', engine='mariadb')
        self.refused('STANDARD_ARGUMENTS_INVALID', 'db_load', path='inputs/forum.sql.gz', charset='utf16')
        self.refused('STANDARD_ARGUMENTS_INVALID', 'db_load', path='intake/forum.sql.gz')
        started = self.op('db_load', path='inputs/forum.sql.gz')
        self.assertEqual({'kind': 'gzip', 'inner': 'mysql-dump'}, started['source_kind'])
        loader = self.docker.argvs('run')[-1]
        joined = ' '.join(loader)
        self.assertEqual('silo-src-arc', loader[loader.index('--network') + 1])
        for expected in ('--read-only', '--cap-drop ALL', 'dst=/in/dump,readonly', '--env-file'):
            self.assertIn(expected, joined)
        self.assertIn('gzip -dc /in/dump | MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -h source-db', loader[-1])
        self.assertIn('GRANT SELECT, SHOW VIEW', loader[-1])
        passwords = [line.split('=', 1)[1] for line in (self.base / 'arc/.silo-migrate/data/db/secret.env').read_text().splitlines() if 'PASSWORD' in line]
        self.assertFalse(any(password in joined for password in passwords))
        self.assertEqual(started['job_id'], self.op('db_status')['loads'][0]['job_id'])
        self.refused('STANDARD_CONFIRMATION_REQUIRED', 'db_reset')
        self.refused('STANDARD_BUSY', 'db_reset', confirm=True)

    def test_postgres_custom_dump_uses_pg_restore_and_grants_read_only(self):
        self.create()
        (self.intake / 'site.dump').write_bytes(b'PGDMP' + b'\x00' * 100)
        self.op('take', path='site.dump', type='postgres-dump')
        self.op('db_up', engine='postgres')
        (run,) = [argv for argv in self.docker.argvs('run')]
        self.assertEqual(['postgres', '-c', 'fsync=off'], run[run.index('postgres'):run.index('postgres') + 3])
        self.op('db_load', path='inputs/site.dump', stop_on_error=False)
        script = self.docker.argvs('run')[-1][-1]
        self.assertIn('pg_restore --no-owner --no-privileges', script)
        self.assertNotIn('--exit-on-error', script)
        self.assertIn('GRANT SELECT ON ALL TABLES IN SCHEMA', script)

    def test_db_reset_removes_only_the_database(self):
        self.create()
        (self.intake / 'forum.sql').write_text(DUMP)
        self.op('take', path='forum.sql', type='mysql-dump')
        self.op('db_up', engine='mariadb')
        self.op('db_reset', confirm=True)
        self.assertIn(['volume', 'rm', '-f', 'silo-src-arc-data'], self.docker.argvs('volume'))
        self.assertFalse((self.base / 'arc/.silo-migrate/data/db/secret.env').exists())
        self.assertTrue((self.base / 'arc/inputs/forum.sql').is_file())
        self.assertIsNone(self.op('db_status')['source_db'])

    # -- findings and output ---------------------------------------------------------

    def test_findings_and_evidence_go_through_the_standard_interface(self):
        self.create()
        self.op('propose_finding', text='users: uid int; example user_1')
        self.op('propose_finding', text='cause', run_id='run-' + 'd' * 32)
        self.op('run_evidence', run_id='run-' + 'd' * 32)
        calls = [(argv, inp) for argv, inp in self.control.calls if argv[0] == 'standard' and argv[1] != 'init']
        self.assertEqual((['standard', 'finding', 'propose', 'arc', '--kind', 'schema', '--file', '-'], 'users: uid int; example user_1'), calls[0])
        self.assertEqual(['standard', 'finding', 'propose', 'arc', '--run', 'run-' + 'd' * 32, '--file', '-'], calls[1][0])
        self.refused('STANDARD_ARGUMENTS_INVALID', 'propose_finding', text='x', run_id='run-1')
        self.refused('STANDARD_ARGUMENTS_INVALID', 'propose_finding', text=' ')
        audit = (self.base / 'arc/.silo-migrate/data/audit.jsonl').read_text()
        self.assertNotIn('example user_1', audit)
        self.assertIn('text_sha256', audit)

    def test_corrupt_files_give_fixed_errors(self):
        (self.intake / 'broken.gz').write_bytes(b'\x1f\x8b\x08\x00' + b'\xff' * 64)
        (self.intake / 'broken.zip').write_bytes(b'PK\x03\x04' + b'\x00' * 30 + b'PK\x05\x06' + b'\xff' * 18)
        for path, mode in (('broken.gz', 'head'), ('broken.gz', 'search'), ('broken.zip', 'archive')):
            with self.subTest(path=path, mode=mode):
                try:
                    result = self.op('peek', area='intake', path=path, mode=mode, pattern='x')
                except self.d.Refusal as refusal:
                    self.assertRegex(str(refusal), r'^STANDARD_[A-Z_]+$')
                else:
                    self.assertIn(result.get('error', 'STANDARD_READ_FAILED'), ('STANDARD_READ_FAILED',))

    def test_unknown_operations_and_output_limit(self):
        with self.assertRaises(self.d.Refusal):
            self.d.main(['data', 'arc'], {}, self.base, ROOT, self.host, io.StringIO('{"op": "shell"}'), self.control)
        with self.assertRaises(self.d.Refusal):
            self.d.main(['data', '../arc'], {}, self.base, ROOT, self.host, io.StringIO('{"op": "status"}'), self.control)
        fitted = self.d.fit({'version': 1, 'log_tail': 'y' * 40000 + 'END', 'text': 'x' * 40000, 'entries': [{'n': 'z' * 100}] * 2000})
        self.assertLessEqual(len(json.dumps(fitted, ensure_ascii=False).encode()), 46 * 1024)
        self.assertTrue(fitted['log_tail'].endswith('END'))

    def test_status_overview(self):
        status = self.op('status')
        self.assertFalse(status['initialized'])
        (self.intake / 'forum.sql').write_text(DUMP)
        self.create()
        self.op('take', path='forum.sql', type='mysql-dump')
        status = self.op('status')
        self.assertEqual((0, 'mybb', 1), (status['drop_folder_files'], status['platform'], len(status['inputs'])))
        self.assertEqual('inputs/forum.sql', status['inputs'][0]['path'])


class ExtractorTest(unittest.TestCase):
    """bin/data_extract.py, run for real on crafted archives."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.out = self.root / 'out'
        self.out.mkdir()

    def run_extract(self, archive):
        result = subprocess.run(['python3', '-I', '-B', str(ROOT / 'bin/data_extract.py'), str(archive), str(self.out)], capture_output=True, text=True, timeout=30)
        return result.returncode, json.loads(result.stdout)

    def test_unsafe_entries_are_skipped(self):
        archive = self.root / 'evil.tar'
        with tarfile.open(archive, 'w') as tf:
            for name, data in (('ok/a.txt', b'a'), ('../escape.txt', b'x'), ('/abs.txt', b'x')):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
            link = tarfile.TarInfo('ok/link')
            link.type = tarfile.SYMTYPE
            link.linkname = '/etc/passwd'
            tf.addfile(link)
        code, summary = self.run_extract(archive)
        self.assertEqual((0, 1, 3), (code, summary['files'], summary['skipped']))
        self.assertEqual(b'a', (self.out / 'ok/a.txt').read_bytes())
        self.assertFalse((self.root / 'escape.txt').exists())
        self.assertFalse((self.out / 'ok/link').exists())

    def test_zip_and_single_compressed_file(self):
        archive = self.root / 'export.zip'
        with zipfile.ZipFile(archive, 'w') as zf:
            zf.writestr('uploads/1/a.png', b'png')
            zf.writestr('../../x', b'no')
        code, summary = self.run_extract(archive)
        self.assertEqual((0, 1, 1, 'zip'), (code, summary['files'], summary['skipped'], summary['archive']))
        gz = self.root / 'dump.sql.gz'
        gz.write_bytes(gzip.compress(b'-- MySQL dump\n'))
        code, summary = self.run_extract(gz)
        self.assertEqual(b'-- MySQL dump\n', (self.out / 'dump.sql').read_bytes())
        code, summary = self.run_extract(gz)  # never overwrites
        self.assertEqual((1, 'failed'), (code, summary['status']))


if __name__ == '__main__':
    unittest.main()
