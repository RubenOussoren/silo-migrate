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
        self.status = {'version': 1, 'plans': [], 'runs': [], 'instances': []}
        self.status_refusal = None

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
        if argv[:3] == ['standard', 'analyst', 'count']:
            return json.dumps({'version': 1, 'run_id': argv[4], 'side': argv[6], 'count': 7, 'error': None})
        if argv[:2] == ['standard', 'status']:
            if self.status_refusal:
                raise self.status_refusal
            return json.dumps(self.status)
        if argv[:3] == ['standard', 'plan', 'show']:
            return json.dumps({'version': 1, 'plan_id': argv[4], 'run_id': None if argv[4].endswith('0') else 'run-' + 'e' * 32})
        raise AssertionError(argv)


class FakeDocker:
    def __init__(self):
        self.calls = []
        self.state = {}  # container -> State dict
        self.networks = {}  # name -> create argv
        self.volumes = set()
        self.ready = True
        self.hostile_role = b''
        self.logs = b'converted 3 records\n'
        self.keep_volume = False
        self.image_present = True
        self.dbhub_containers = b''

    def __call__(self, argv, timeout=120, input=None):
        self.calls.append((argv, input))
        out, code, err = b'', 0, b''
        if argv[0] == 'run':
            name = argv[argv.index('--name') + 1]
            self.state[name] = {'Running': True, 'Status': 'running', 'ExitCode': 0}
            for arg in argv:
                if arg.startswith('type=volume,src='):
                    self.volumes.add(arg.split('src=')[1].split(',')[0])
            out = b'cid\n'
        elif argv[0] == 'network' and argv[1] == 'create':
            self.networks[argv[-1]] = argv
        elif argv[0] == 'network' and argv[1] == 'inspect':
            create = self.networks.get(argv[-1])
            if create is None:
                code, err = 1, b'Error response from daemon: network x not found'
            else:
                options = {'com.docker.network.bridge.inhibit_ipv4': 'true'} if 'com.docker.network.bridge.inhibit_ipv4=true' in create else {}
                out = json.dumps({'Internal': '--internal' in create, 'Options': options}).encode()
        elif argv[0] == 'network' and argv[1] == 'rm':
            self.networks.pop(argv[-1], None)
        elif argv[0] == 'volume' and argv[1] == 'inspect':
            code = 0 if argv[-1] in self.volumes else 1
        elif argv[0] == 'volume' and argv[1] == 'rm':
            if not self.keep_volume:
                self.volumes.discard(argv[-1])
        elif argv[0] == 'inspect':
            name = argv[-1]
            # Like Docker: without --type, a network of the same name matches too.
            if '--type' not in argv and name in self.networks:
                out = b'[{}]'
            elif name not in self.state:
                code, err = 1, b'Error: No such object: ' + name.encode()
            elif len(argv) == 2:
                out = b'[{}]'
            elif '{{json .State}}' in argv:
                out = json.dumps(self.state[name]).encode()
            elif '{{.State.Running}}' in argv:
                out = b'true' if self.state[name]['Running'] else b'false'
            else:
                out = self.state[name]['Status'].encode()
        elif argv[0] == 'logs':
            out = self.logs
        elif argv[0] == 'exec':
            if any(arg in ('mariadb-admin', 'pg_isready') for arg in argv):
                code = 0 if self.ready else 1
            elif input and b'information_schema.tables' in input:
                out = b'source\t2\t1\n'
            elif input and input.startswith(b"SELECT 'role'"):
                # As a hostile dump could leave them: an extra host entry and an injected role name.
                out = b"role\tsafe_role\nhost\t172.%\ninformation_schema\nmysql\nsource\nforum_db\n%\n" + self.hostile_role
        elif argv[0] == 'rm':
            self.state.pop(argv[-1], None)
        elif argv[0] == 'image' and argv[1] == 'inspect':
            code = 0 if self.image_present else 1
        elif argv[0] == 'pull':
            self.image_present = True
        elif argv[0] == 'ps':
            out = self.dbhub_containers
        return subprocess.CompletedProcess(argv, code, out, err)

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
        # /tmp may be a small tmpfs; the reserve itself is tested separately.
        disk = mock.patch.object(self.d, 'low_disk', return_value=False)
        disk.start()
        self.addCleanup(disk.stop)
        self.host = types.SimpleNamespace(inspect=lambda ref: {'Id': 'sha256:' + '1' * 64, 'ref': ref},
                                          identity=lambda document: self.content_id(document['ref']))
        self.values = {'SILO_CONTROL_GEMS': str(top / 'gems')}
        (top / 'gems').mkdir()
        self.config_home = top / 'config'
        environ = mock.patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.config_home)})
        environ.start()
        self.addCleanup(environ.stop)

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
        self.assertEqual('STANDARD_ARGUMENTS_INVALID: name', failed['result'])

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
        ro = self.base / 'arc/.silo-migrate/data/db/ro.env'
        self.assertEqual((0o600, 0o600), (stat.S_IMODE(secret.stat().st_mode), stat.S_IMODE(ro.stat().st_mode)))
        self.assertNotIn('SILO_RO_PASSWORD', secret.read_text())  # containers never get the read-only password
        passwords = self.passwords()
        self.assertEqual(2, len(passwords))  # MariaDB root + the read-only user
        self.assertIn(['network', 'create', '--internal', '-o', 'com.docker.network.bridge.inhibit_ipv4=true', '--label', 'silo.workspace=arc', 'silo-src-arc'],
                      self.docker.argvs('network'))
        (run,) = self.docker.argvs('run')
        self.assertNotIn('-p', run)
        self.assertNotIn('--publish', run)
        self.assertEqual('silo-src-arc', run[run.index('--network') + 1])
        self.assertIn('--env-file', run)
        self.assertEqual('sha256:' + '1' * 64, run[run.index('--innodb-buffer-pool-size=1G') - 1])
        for joined in self.all_docker_argv():
            for password in passwords:
                self.assertNotIn(password, joined)
        hardening = b''.join(inp for argv, inp in self.docker.calls if inp)
        for statement in (b'CREATE USER IF NOT EXISTS', b'REVOKE ALL PRIVILEGES, GRANT OPTION', b'SET DEFAULT ROLE NONE', b'GRANT SELECT, SHOW VIEW ON `source`',
                          b"DROP USER IF EXISTS 'silo_ro'@'172.%'", b"REVOKE `safe_role` FROM"):
            self.assertIn(statement, hardening)
        self.assertNotIn(b'`mysql`', hardening)
        self.assertNotIn(b'`%`', hardening)  # a database named % would be a wildcard grant
        self.assertIn(b'GRANT SELECT, SHOW VIEW ON `forum\\_db`.*', hardening)
        self.assertIn(b'REVOKE ALL PRIVILEGES, GRANT OPTION FROM PUBLIC', hardening)
        # A role that can't be named safely is never spliced in, and the check fails.
        self.docker.hostile_role = b"role\tx`; GRANT ALL ON *.* TO silo_ro@'%'; --\n"
        self.docker.calls.clear()
        self.assertFalse(self.d.harden_ro_user(self.d.Workspace(self.base, 'arc', ROOT, self.host, self.values, self.control), 'mariadb'))
        self.assertNotIn(b'GRANT ALL', b''.join(inp for _argv, inp in self.docker.calls if inp))
        self.refused('STANDARD_DB_ENGINE_MISMATCH', 'db_up', engine='postgres')
        self.assertEqual([['source', 2]], [[s['schema'], s['tables']] for s in self.op('db_status')['schemas']])

    def passwords(self):
        values = []
        for name in ('secret.env', 'ro.env'):
            path = self.base / 'arc/.silo-migrate/data/db' / name
            values += [line.split('=', 1)[1] for line in path.read_text().splitlines() if 'PASSWORD=' in line]
        return values

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
        self.assertIn('gzip -dc /in/dump | MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -h source-db -uroot --sandbox', loader[-1])
        self.assertTrue(loader[-1].endswith('source > /dev/null; code=$?; echo LOAD_DONE; exit $code'), loader[-1])  # a failed load fails the job
        self.assertFalse(any(password in joined for password in self.passwords()))
        self.assertEqual(started['job_id'], self.op('db_status')['loads'][0]['job_id'])
        self.refused('STANDARD_CONFIRMATION_REQUIRED', 'db_reset')
        self.refused('STANDARD_BUSY', 'db_reset', confirm=True)
        # A dump that runs `env` would print the root password: it never reaches the agent.
        root = self.passwords()[0]
        self.docker.logs = ('ERROR 1064 near ' + root + '\n').encode()
        self.docker.state[loader[loader.index('--name') + 1]] = {'Running': False, 'Status': 'exited', 'ExitCode': 1}
        self.docker.calls.clear()
        done = self.op('job', job_id=started['job_id'])
        self.assertEqual(('failed', 1), (done['status'], done['exit_code']))
        self.assertNotIn(root, json.dumps(done))
        self.assertIn('[redacted]', done['log_tail'])
        self.assertNotIn(root.encode(), (self.base / 'arc/.silo-migrate/data/jobs' / (started['job_id'] + '.log')).read_bytes())
        self.assertTrue(done['read_only_user_checked'])  # re-asserted after the dump ran as root
        self.assertTrue(any(inp and b'REVOKE ALL PRIVILEGES' in inp for _argv, inp in self.docker.calls))

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
        hardening = b''.join(inp for argv, inp in self.docker.calls if inp)
        for statement in (b'NOSUPERUSER', b'default_transaction_read_only = on', b'GRANT SELECT ON ALL TABLES IN SCHEMA', b'REVOKE %I FROM silo_ro',
                          b'IN DATABASE source RESET ALL', b'REVOKE CREATE, TEMPORARY ON DATABASE source FROM PUBLIC',
                          b'REVOKE ALL ON ALL ROUTINES IN SCHEMA %I FROM PUBLIC'):
            self.assertIn(statement, hardening)

    def test_plain_postgres_dump_runs_with_backslash_commands_restricted(self):
        self.create()
        (self.intake / 'dump.sql.gz').write_bytes(gzip.compress(b'--\n-- PostgreSQL database dump\n--\n\\! env\nSELECT 1;\n'))
        self.op('take', path='dump.sql.gz', type='postgres-dump')
        self.op('db_up', engine='postgres')
        self.op('db_load', path='inputs/dump.sql.gz')
        script = self.docker.argvs('run')[-1][-1]
        # bash then sees: printf "%s\n" "\\restrict KEY" (one backslash after quoting) and the
        # sed pattern ^\\(un)?restrict (a literal backslash), as run for real in the smoke test.
        self.assertRegex(script, r'printf "%s\\n" "\\\\restrict [0-9a-f]{32}"; gzip -dc /in/dump \| ')
        self.assertIn(r'sed -E "/^\\\\(un)?restrict /d"; } | ', script)
        self.assertIn('ON_ERROR_STOP=1 > /dev/null; code=$?; echo LOAD_DONE; exit $code', script)

    def test_unsupported_dumps_and_unregistered_inputs_are_refused(self):
        self.create()
        (self.intake / 'forum.sql').write_text(DUMP)
        self.op('take', path='forum.sql', type='mysql-dump')
        self.op('db_up', engine='postgres')
        self.refused('STANDARD_DUMP_KIND_UNSUPPORTED', 'db_load', path='inputs/forum.sql')  # MySQL dump into PostgreSQL
        (self.base / 'arc/inputs/stray.sql').write_text(DUMP)
        self.refused('STANDARD_INPUT_NOT_REGISTERED', 'db_load', path='inputs/stray.sql')
        self.refused('STANDARD_INPUT_NOT_REGISTERED', 'extract', path='inputs/stray.sql', into='x')

    def test_db_network_without_a_host_address_is_required(self):
        self.create()
        self.docker.networks['silo-src-arc'] = ['network', 'create', '--internal', 'silo-src-arc']  # an older, plain internal network
        self.refused('STANDARD_DB_NETWORK_UNSAFE', 'db_up', engine='mariadb')

    def test_db_state_missing_or_reset_incomplete_keeps_passwords(self):
        self.create()
        self.op('db_up', engine='mariadb')
        before = self.passwords()
        self.docker.keep_volume = True
        self.refused('STANDARD_DB_RESET_INCOMPLETE', 'db_reset', confirm=True)
        self.assertEqual(before, self.passwords())
        (self.base / 'arc/.silo-migrate/data/db/state.json').unlink()
        self.refused('STANDARD_DB_STATE_MISSING', 'db_up', engine='mariadb')

    def test_jobs_are_lost_only_when_docker_says_so_and_low_disk_stops_them(self):
        self.create()
        started = self.op('script', code='puts 1', into='a')
        name = self.docker.argvs('run')[-1][self.docker.argvs('run')[-1].index('--name') + 1]
        real = self.docker.__call__
        flaky = lambda argv, timeout=120, input=None: subprocess.CompletedProcess(argv, 1, b'', b'Cannot connect to the Docker daemon') if argv[0] == 'inspect' else real(argv, timeout, input)
        with mock.patch.object(self.d, 'docker', side_effect=flaky):
            self.assertEqual('running', self.op('job', job_id=started['job_id'])['status'])
        with mock.patch.object(self.d, 'low_disk', return_value=True):
            self.op('job', job_id=started['job_id'])
            self.assertIn(['kill', name], self.docker.argvs('kill'))
            self.refused('STANDARD_BUSY', 'script', code='puts 2', into='b')
        self.docker.state[name] = {'Running': False, 'Status': 'exited', 'ExitCode': 137}
        self.assertEqual('stopped_low_disk', self.op('job', job_id=started['job_id'])['status'])
        with mock.patch.object(self.d, 'low_disk', return_value=True):
            self.refused('STANDARD_DISK_LOW', 'script', code='puts 2', into='b')
        self.docker.state.clear()
        second = self.op('script', code='puts 3', into='c')
        self.docker.state.clear()  # the container vanished
        self.assertEqual('lost', self.op('job', job_id=second['job_id'])['status'])

    def test_take_refuses_files_not_yet_handed_to_the_account_and_resumes_after_interruption(self):
        self.create()
        (self.intake / 'big.sql').write_text(DUMP)
        real_register = self.d.register
        with mock.patch.object(self.d, 'register', side_effect=self.d.Refusal('STANDARD_OPERATION_TIMEOUT')):
            self.refused('STANDARD_OPERATION_TIMEOUT', 'take', path='big.sql', type='mysql-dump')
        self.assertFalse((self.intake / 'big.sql').exists())
        self.assertEqual(0o400, stat.S_IMODE((self.base / 'arc/inputs/big.sql').stat().st_mode))
        resumed = self.op('take', path='big.sql', type='mysql-dump')
        self.assertEqual(('resumed', 'inputs/big.sql'), (resumed['how'], resumed['path']))
        self.assertEqual([], list((self.base / 'arc/.silo-migrate/data/pending').iterdir()))
        (self.intake / 'root-owned.sql').write_text(DUMP)
        real_open = self.d.open_regular
        def as_root(root, parts):
            fd, info = real_open(root, parts)
            fields = list(info)
            fields[4] = 0
            return fd, os.stat_result(fields)
        with mock.patch.object(self.d, 'open_regular', side_effect=as_root):
            self.refused('STANDARD_PATH_INVALID', 'take', path='root-owned.sql', type='mysql-dump')
        self.assertTrue((self.intake / 'root-owned.sql').exists())
        (self.intake / 'huge.sql').write_text(DUMP)
        with mock.patch.object(self.d, 'MAX_TOOL_INPUT', 10):
            # Too big for a chat tool's 300 s; the same request from a shell (no "via") works.
            self.refused('STANDARD_INPUT_TOO_LARGE_FOR_TOOL', 'take', path='huge.sql', type='mysql-dump', via='chat')
            self.assertEqual('inputs/huge.sql', self.op('take', path='huge.sql', type='mysql-dump')['path'])

    def test_retry_adopts_a_registration_that_finished_after_the_tool_was_killed(self):
        self.create()
        (self.intake / 'slow.sql').write_text(DUMP)
        real_register = self.d.register
        def finishes_in_background(*args):
            real_register(*args)  # the control process completes on its own...
            raise self.d.Refusal('STANDARD_OPERATION_TIMEOUT')  # ...after the tool gave up
        with mock.patch.object(self.d, 'register', side_effect=finishes_in_background):
            self.refused('STANDARD_OPERATION_TIMEOUT', 'take', path='slow.sql', type='mysql-dump')
        adds = len([argv for argv, _ in self.control.calls if argv[:3] == ['named', 'input', 'add']])
        retry = self.op('take', path='slow.sql', type='mysql-dump')
        self.assertEqual(('resumed', 'input-%032x' % 1), (retry['how'], retry['input_id']))
        self.assertEqual(adds, len([argv for argv, _ in self.control.calls if argv[:3] == ['named', 'input', 'add']]))
        provenance = [json.loads(line) for line in (self.base / 'arc/.silo-migrate/data/provenance.jsonl').read_text().splitlines()]
        self.assertEqual(['input-%032x' % 1], [record['input_id'] for record in provenance])

    def test_search_keeps_memory_bounded_on_one_huge_line(self):
        line = b'INSERT INTO t VALUES ' + b'(1,"x"),' * (600 * 1024) + b'(2,"NEEDLE");\nnext line\n'
        (self.intake / 'one-line.sql.gz').write_bytes(gzip.compress(line))
        reads = []
        real_reader = self.d.reader
        def spy(fd, decompress=True):
            stream, kind = real_reader(fd, decompress)
            original = stream.readline
            def readline(size=-1):
                self.assertGreater(size, 0)  # never an unbounded line read
                data = original(size)
                reads.append(len(data))
                return data
            stream.readline = readline
            return stream, kind
        with mock.patch.object(self.d, 'reader', side_effect=spy):
            found = self.op('peek', area='intake', path='one-line.sql.gz', mode='search', pattern='NEEDLE')
        self.assertEqual(1, len(found['matches']))
        self.assertEqual(1, found['matches'][0]['line'])
        self.assertLessEqual(max(reads), 1024 * 1024)
        boundary = self.op('peek', area='intake', path='one-line.sql.gz', mode='search', pattern='next line')
        self.assertEqual(2, boundary['matches'][0]['line'])
        # Two matches close together across a piece boundary: the second isn't lost.
        piece = 1024 * 1024
        data = b'a' * (piece - 3) + b'XYZ' + b'XYZ' + b'b' * 10 + b'\n'
        (self.intake / 'pair.txt').write_bytes(data)
        both = self.op('peek', area='intake', path='pair.txt', mode='search', pattern='XYZ')
        self.assertEqual([piece - 3, piece], [match['offset'] for match in both['matches']])

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

    # -- DBHub ---------------------------------------------------------------------------

    def mcp(self):
        return json.loads((self.config_home / 'term-llm/mcp.json').read_text())

    def test_db_up_registers_the_projects_dbhub_server_for_migration_data_only(self):
        self.create()
        (self.config_home / 'term-llm').mkdir(parents=True)
        mine = {'command': 'npx', 'args': ['other'], 'extra_field': 1}
        (self.config_home / 'term-llm/mcp.json').write_text(json.dumps({'servers': {'mine': mine}, 'top_extra': True}))
        self.docker.image_present = False
        self.assertIsNone(self.op('db_status')['source_db'])
        self.assertNotIn('db-arc', self.mcp()['servers'])  # nothing before the database exists
        queries = self.op('db_up', engine='mariadb')['queries']
        self.assertEqual(('db-arc', 'added', 'ready'), (queries['mcp_server'], queries['registration'], queries['image']))
        self.assertEqual('registered', self.op('db_status')['queries']['registration'])  # unchanged: nothing written
        self.assertIn(['pull', '--quiet', self.d.DBHUB_IMAGE], self.docker.argvs('pull'))
        config = self.mcp()
        self.assertEqual(mine, config['servers']['mine'])
        self.assertTrue(config['top_extra'])
        entry = config['servers']['db-arc']
        self.assertEqual(['migration-data'], entry['agents'])
        self.assertEqual(['dbhub', 'arc'], entry['args'])
        self.assertTrue(entry['command'].endswith('/bin/silo-migrate-control'))
        self.assertEqual(0o600, stat.S_IMODE((self.config_home / 'term-llm/mcp.json').stat().st_mode))
        # term-llm 0.9.93 drops `agents` when its web UI rewrites mcp.json: status puts it back.
        del config['servers']['db-arc']['agents']
        (self.config_home / 'term-llm/mcp.json').write_text(json.dumps(config))
        self.docker.image_present = False
        self.docker.calls.clear()
        repaired = self.op('db_status')['queries']
        self.assertEqual('added', repaired['registration'])
        self.assertEqual(['migration-data'], self.mcp()['servers']['db-arc']['agents'])
        self.assertEqual([], self.docker.argvs('pull'))  # status never pulls
        self.assertIn('data_db_up', repaired['image'])
        audit = [json.loads(line) for line in (self.base / 'arc/.silo-migrate/data/audit.jsonl').read_text().splitlines()]
        self.assertEqual(2, sum(1 for entry in audit if entry['op'] == 'mcp_register'))
        # Someone else's server with that name is left alone.
        config = self.mcp()
        config['servers']['db-arc'] = {'command': 'npx', 'args': ['my-db']}
        (self.config_home / 'term-llm/mcp.json').write_text(json.dumps(config))
        self.assertIn("isn't silo-migrate's", self.op('db_status')['queries']['registration'])
        self.assertEqual(['my-db'], self.mcp()['servers']['db-arc']['args'])
        self.op('db_reset', confirm=True)
        self.assertEqual(['my-db'], self.mcp()['servers']['db-arc']['args'])
        self.op('db_up', engine='mariadb')
        del config['servers']['db-arc']
        (self.config_home / 'term-llm/mcp.json').write_text(json.dumps(config))
        # Never written through a link or into a file it can't parse.
        (self.config_home / 'term-llm/mcp.json').write_text('{not json')
        self.assertIn('not changed', self.op('db_status')['queries']['registration'])
        self.assertEqual('{not json', (self.config_home / 'term-llm/mcp.json').read_text())

    def test_dbhub_runs_on_the_project_network_as_the_read_only_user(self):
        self.create()
        with mock.patch.object(self.d.os, 'execvpe') as execvpe, self.assertRaises(self.d.Refusal) as before:
            self.d.dbhub_main(['dbhub', 'arc'], self.values, self.base, ROOT, self.host)
        self.assertTrue(str(before.exception).startswith('STANDARD_DB_STATE_MISSING'))
        execvpe.assert_not_called()
        self.op('db_up', engine='postgres')
        with mock.patch.object(self.d.os, 'execvpe') as execvpe:
            self.d.dbhub_main(['dbhub', 'arc'], self.values, self.base, ROOT, self.host)
        file, argv, env = execvpe.call_args[0]
        password = self.d.ro_password(self.d.Workspace(self.base, 'arc', ROOT, self.host, self.values, self.control))
        self.assertEqual(password, env['DB_PASSWORD'])
        self.assertNotIn(password, ' '.join(argv))
        for flag in ('--rm', '-i', '--pull=never', '--read-only', '--log-driver', '-e'):
            self.assertIn(flag, argv)
        self.assertEqual('silo-src-arc', argv[argv.index('--network') + 1])
        self.assertEqual('ALL', argv[argv.index('--cap-drop') + 1])
        self.assertEqual('none', argv[argv.index('--log-driver') + 1])
        self.assertNotIn('-p', argv)
        self.assertEqual(['DB_PASSWORD'], [argv[i + 1] for i, a in enumerate(argv) if a == '-e' and argv[i + 1].startswith('DB_')])
        self.assertEqual(self.d.DBHUB_IMAGE, argv[argv.index('--transport') - 1])
        toml = (self.base / 'arc/.silo-migrate/data/db/dbhub.toml')
        text = toml.read_text()
        self.assertNotIn(password, text)
        self.assertIn('postgres://silo_ro:${DB_PASSWORD}@source-db:5432/source', text)
        self.assertIn('readonly = true', text)
        self.assertIn('max_rows = 50', text)
        self.assertEqual(0o600, stat.S_IMODE(toml.stat().st_mode))
        # A network that could reach the host is refused.
        self.docker.networks['silo-src-arc'] = ['network', 'create', '--internal', 'silo-src-arc']
        with mock.patch.object(self.d.os, 'execvpe') as execvpe, self.assertRaises(self.d.Refusal):
            self.d.dbhub_main(['dbhub', 'arc'], self.values, self.base, ROOT, self.host)
        execvpe.assert_not_called()
        for bad in (['dbhub'], ['dbhub', '../x'], ['dbhub', 'arc', 'extra']):
            with self.subTest(args=bad), self.assertRaises(self.d.Refusal):
                self.d.dbhub_main(bad, self.values, self.base, ROOT, self.host)

    def test_db_reset_stops_dbhub_and_removes_its_entry(self):
        self.create()
        self.op('db_up', engine='mariadb')
        self.docker.dbhub_containers = b'abc123\ndef456\n'
        self.op('db_reset', confirm=True)
        self.assertNotIn('db-arc', self.mcp()['servers'])
        removed = [argv[-1] for argv in self.docker.argvs('rm')]
        self.assertEqual(['abc123', 'def456'], removed[:2])
        self.assertEqual(2, len(self.docker.argvs('ps')))  # swept again before the network is removed
        self.assertIn(['ps', '-aq', '--filter', 'label=silo.role=dbhub', '--filter', 'label=silo.workspace=arc'], self.docker.argvs('ps'))

    # -- project notes ---------------------------------------------------------------------

    # -- the guide: every state is invented ----------------------------------------------------

    def guide_state(self, findings=None, plans=None, runs=None, sites=None, pushes=None):
        """Write the workbench's state the way it's stored, and what `standard status` reports."""
        standard = self.base / 'arc/.silo-migrate/named/standard'
        state = json.loads((standard / 'state.json').read_text())
        state['findings'] = {key: dict(value) for key, value in (findings or {}).items()}
        state['plans'] = {plan['plan_id']: {'body': {'operation': 'standard_' + plan['kind']}} for plan in (plans or [])}
        for run in runs or []:
            state['plans'].setdefault(run['plan_id'], {'body': {'operation': 'standard_' + run['kind']}})
        (standard / 'state.json').write_text(json.dumps(state))
        folder = standard / 'converter-pushes'
        folder.mkdir(exist_ok=True)
        for push in pushes or []:
            (folder / (push['digest'] + '.json')).write_text(json.dumps(dict(push, proposal={'branch': push.get('branch', 'migration/arc/x')})))
        self.control.status = {'version': 1, 'instances': sites or [],
                               'plans': [{'plan_id': plan['plan_id'], 'status': plan['status'], 'run_id': plan.get('run_id'), 'created_at': plan.get('created_at', '2026-01-01T00:00:00Z')}
                                         for plan in plans or []],
                               'runs': [{'run_id': run['run_id'], 'plan_id': run['plan_id'], 'status': run['status'], 'stage': run.get('stage'),
                                         'started_at': run.get('started_at', '2026-01-02T00:00:00Z'), 'finished_at': None, 'failure': run.get('failure'),
                                         'results': {'reconciliation_checks': run.get('checks', 0), 'reconciliation_matched': run.get('matched', 0),
                                                     'reconciliation_differs': run.get('differ', 0), 'reconciliation_errors': run.get('errors', 0)}}
                                        for run in runs or []]}

    def drop(self, name, text):
        (self.intake / name).write_text(text)

    def guide_ready(self):
        """A workspace with files taken and the source database loaded."""
        self.create()
        self.drop('dump.sql', DUMP)
        self.op('take', path='dump.sql', type='mysql-dump')
        (self.base / 'arc/.silo-migrate/data/db').mkdir(exist_ok=True)
        (self.base / 'arc/.silo-migrate/data/db/state.json').write_text(json.dumps({'engine': 'mariadb', 'loads': [{'at': 'x'}]}))

    def assertNext(self, who, text, guide=None):
        step = (guide or self.op('guide'))['next']
        self.assertEqual(who, step['who'], step)
        self.assertIn(text, step['action'])

    def stages(self, guide):
        return [stage['id'] for stage in guide['stages'] if stage['state'] == 'done']

    def test_guide_for_a_new_project_with_no_files_asks_the_engineer_to_copy_them(self):
        guide = self.op('guide')
        self.assertEqual('arc', guide['project'])
        self.assertEqual('files', guide['stage'])
        self.assertNext('engineer', 'silo intake arc', guide)
        self.assertIn(str(self.base.parent / 'intake/arc'), guide['next']['action'])
        self.assertEqual([], self.control.calls)  # nothing exists yet, so nothing is asked of the workbench

    def test_guide_for_a_new_project_with_files_tells_the_agent_to_create_the_workspace(self):
        self.drop('dump.sql', DUMP)
        guide = self.op('guide')
        self.assertEqual('workspace', guide['stage'])
        self.assertNext('agent', 'data_create', guide)

    def test_guide_walks_the_whole_flow(self):
        self.create()
        self.drop('dump.sql', DUMP)
        self.assertNext('agent', 'data_take')
        self.op('take', path='dump.sql', type='mysql-dump')
        self.assertNext('agent', 'data_db_load')
        (self.base / 'arc/.silo-migrate/data/db').mkdir(exist_ok=True)
        (self.base / 'arc/.silo-migrate/data/db/state.json').write_text(json.dumps({'engine': 'mariadb', 'loads': [{'at': 'x'}]}))
        self.assertNext('agent', 'data_propose_finding')
        finding = 'finding-' + '1' * 32
        self.guide_state(findings={finding: {'status': 'proposed', 'proposed_at': '2026-01-01T00:00:00Z'}})
        self.assertNext('engineer', 'Review finding ' + finding)
        released = {finding: {'status': 'released', 'release': {'released_at': '2026-01-02T00:00:00Z'}}}
        self.guide_state(findings=released)
        self.assertNext('engineer', 'converter-developer chat')
        self.guide_state(findings=released, pushes=[{'digest': 'a' * 64, 'status': 'proposed', 'proposed_at': '2026-01-03T00:00:00Z'}])
        self.assertNext('engineer', 'converter push')
        pushes = [{'digest': 'a' * 64, 'status': 'pushed', 'proposed_at': '2026-01-03T00:00:00Z', 'pushed_at': '2026-01-03T01:00:00Z'}]
        self.guide_state(findings=released, pushes=pushes)
        self.assertNext('agent', 'propose a convert run')
        convert = {'run_id': 'run-' + '1' * 32, 'plan_id': 'plan-' + '1' * 32, 'kind': 'convert', 'status': 'completed', 'checks': 6, 'matched': 6, 'started_at': '2026-01-04T00:00:00Z'}
        self.guide_state(findings=released, pushes=pushes, runs=[convert])
        guide = self.op('guide')
        self.assertNext('agent', 'from_run=' + convert['run_id'], guide)
        self.assertEqual('review', guide['stage'])
        self.assertEqual(['files', 'workspace', 'source_db', 'finding', 'converter', 'convert'], self.stages(guide))
        review = {'run_id': 'run-' + '2' * 32, 'plan_id': 'plan-' + '2' * 32, 'kind': 'review', 'status': 'completed', 'checks': 6, 'matched': 6, 'started_at': '2026-01-05T00:00:00Z'}
        site = {'run_id': review['run_id'], 'role': 'review', 'state': 'ready', 'live': True, 'port': 18080}
        self.guide_state(findings=released, pushes=pushes, runs=[convert, review], sites=[site])
        guide = self.op('guide')
        self.assertNext('engineer', 'SSH tunnel', guide)
        self.assertEqual('site', guide['stage'])
        self.assertEqual('not_recorded', guide['stages'][-1]['state'])
        self.assertTrue(any('holds customer data' in line for line in guide['also']))
        self.guide_state(findings=released, pushes=pushes, runs=[convert, review])
        self.assertNext('nobody', 'next pass')

    def test_guide_puts_a_running_run_first_then_what_waits_on_the_engineer(self):
        self.guide_ready()
        plan = {'plan_id': 'plan-' + '3' * 32, 'kind': 'convert', 'status': 'proposed', 'created_at': '2026-01-03T00:00:00Z'}
        running = {'run_id': 'run-' + '4' * 32, 'plan_id': 'plan-' + '4' * 32, 'kind': 'convert', 'status': 'running', 'stage': 'convert'}
        self.guide_state(plans=[plan], runs=[running])
        guide = self.op('guide')
        self.assertNext('nobody', 'Nothing is needed', guide)
        self.assertEqual(1, len(guide['waiting_on_engineer']))
        self.guide_state(plans=[plan])
        self.assertNext('engineer', 'Approve or discard convert plan')
        self.guide_state(plans=[dict(plan, status='approved')])
        self.assertNext('engineer', 'Start approved convert plan')

    def test_guide_does_not_let_a_leftover_plan_hide_the_next_step(self):
        self.guide_ready()
        convert = {'run_id': 'run-' + '9' * 32, 'plan_id': 'plan-' + '9' * 32, 'kind': 'convert', 'status': 'completed', 'checks': 6, 'matched': 6, 'started_at': '2026-01-04T00:00:00Z'}
        leftover = {'plan_id': 'plan-' + 'a' * 32, 'kind': 'convert', 'status': 'proposed', 'created_at': '2026-01-03T00:00:00Z'}
        self.guide_state(plans=[leftover], runs=[convert])
        guide = self.op('guide')
        self.assertEqual([], guide['waiting_on_engineer'])
        self.assertNext('agent', 'from_run=' + convert['run_id'], guide)
        self.assertTrue(any('never run' in line and leftover['plan_id'] in line for line in guide['also']))
        # A plan proposed after the last run is the real next step.
        self.guide_state(plans=[dict(leftover, created_at='2026-01-05T00:00:00Z')], runs=[convert])
        self.assertNext('engineer', 'Approve or discard convert plan')

    def test_guide_explains_runs_that_did_not_pass(self):
        self.guide_ready()
        base = {'run_id': 'run-' + '5' * 32, 'plan_id': 'plan-' + '5' * 32, 'kind': 'convert', 'stage': 'import'}
        for run, who, text in ((dict(base, status='failed', failure={'code': 'STANDARD_IMPORT_FAILED'}), 'agent', 'STANDARD_IMPORT_FAILED'),
                               (dict(base, status='abandoned'), 'engineer', 'Recover it'),
                               (dict(base, status='not_started'), 'engineer', 'Recover it'),
                               (dict(base, status='completed', checks=6, matched=5, differ=1), 'agent', '5 of 6'),
                               (dict(base, status='completed', checks=0), 'agent', 'no count checks')):
            with self.subTest(status=run['status'], checks=run.get('checks')):
                self.guide_state(runs=[run])
                guide = self.op('guide')
                self.assertNext(who, text, guide)
                self.assertNotIn('convert', self.stages(guide))

    def test_guide_asks_for_a_new_convert_run_after_a_newer_push_and_a_new_review_after_a_newer_convert(self):
        self.guide_ready()
        convert = {'run_id': 'run-' + '6' * 32, 'plan_id': 'plan-' + '6' * 32, 'kind': 'convert', 'status': 'completed', 'checks': 6, 'matched': 6, 'started_at': '2026-01-04T00:00:00Z'}
        review = {'run_id': 'run-' + '7' * 32, 'plan_id': 'plan-' + '7' * 32, 'kind': 'review', 'status': 'completed', 'checks': 6, 'matched': 6, 'started_at': '2026-01-03T00:00:00Z'}
        self.guide_state(runs=[review, convert])
        guide = self.op('guide')
        self.assertNext('agent', 'from_run=' + convert['run_id'], guide)
        self.assertNotIn('review', self.stages(guide))
        pushes = [{'digest': 'b' * 64, 'status': 'pushed', 'proposed_at': '2026-01-05T00:00:00Z', 'pushed_at': '2026-01-05T01:00:00Z'}]
        self.guide_state(runs=[convert], pushes=pushes)
        self.assertNext('agent', 'propose a convert run')

    def test_guide_lets_a_convert_run_settle_a_finding_that_needed_no_change(self):
        self.guide_ready()
        finding = 'finding-' + '2' * 32
        released = {finding: {'status': 'released', 'release': {'released_at': '2026-01-03T00:00:00Z'}}}
        pushes = [{'digest': 'a' * 64, 'status': 'pushed', 'proposed_at': '2026-01-01T00:00:00Z', 'pushed_at': '2026-01-02T00:00:00Z'}]
        self.guide_state(findings=released, pushes=pushes)
        self.assertNext('engineer', 'converter-developer chat')
        convert = {'run_id': 'run-' + 'c' * 32, 'plan_id': 'plan-' + 'c' * 32, 'kind': 'convert', 'status': 'completed', 'checks': 6, 'matched': 6, 'started_at': '2026-01-04T00:00:00Z'}
        self.guide_state(findings=released, pushes=pushes, runs=[convert])
        self.assertNext('agent', 'from_run=' + convert['run_id'])

    def test_guide_notices_a_finding_released_after_the_last_run_with_no_pushes(self):
        self.guide_ready()
        finding = 'finding-' + '3' * 32
        convert = {'run_id': 'run-' + 'd' * 32, 'plan_id': 'plan-' + 'd' * 32, 'kind': 'convert', 'status': 'completed', 'checks': 6, 'matched': 6, 'started_at': '2026-01-04T00:00:00Z'}
        self.guide_state(findings={finding: {'status': 'released', 'release': {'released_at': '2026-01-05T00:00:00Z'}}}, runs=[convert])
        self.assertNext('engineer', finding)

    def test_guide_survives_a_run_with_no_start_time(self):
        self.guide_ready()
        self.guide_state(runs=[{'run_id': 'run-' + 'e' * 32, 'plan_id': 'plan-' + 'e' * 32, 'kind': 'convert', 'status': 'completed', 'checks': 6, 'matched': 6, 'started_at': None}])
        self.assertNext('agent', 'from_run=')

    def test_guide_keeps_only_the_code_when_the_workbench_refuses(self):
        self.guide_ready()
        self.guide_state()
        self.control.status_refusal = self.d.Refusal('STANDARD_OPERATION_FAILED: some detail')
        action = self.op('guide')['next']['action']
        self.assertIn('STANDARD_OPERATION_FAILED', action)
        self.assertNotIn('some detail', action)

    def test_drop_folder_and_contact_come_from_the_install_prefix_not_the_workspaces_folder(self):
        top = Path(self.temp.name) / 'layout'
        release = top / 'srv/releases' / ('a' * 40)
        release.mkdir(parents=True)
        (top / 'srv/etc').mkdir()
        (top / 'srv/etc/support-contact').write_text('Ruben\n')
        workspaces = top / 'elsewhere/workspaces'
        workspaces.mkdir(parents=True)
        ws = self.d.Workspace(workspaces, 'arc', release, self.host, self.values, self.control)
        self.assertEqual(top / 'srv/intake/arc', ws.intake)
        self.assertEqual('Ruben', self.d.support_contact(ws))

    def test_guide_treats_an_older_push_proposal_as_superseded(self):
        self.guide_ready()
        self.guide_state(pushes=[{'digest': 'a' * 64, 'status': 'proposed', 'proposed_at': '2026-01-01T00:00:00Z'},
                                 {'digest': 'b' * 64, 'status': 'proposed', 'proposed_at': '2026-01-02T00:00:00Z'}])
        waiting = self.op('guide')['waiting_on_engineer']
        self.assertEqual(['Review converter push ' + 'b' * 64 + ' and push it.'], [item['what'] for item in waiting])

    def test_guide_flags_a_stale_plan_and_files_left_in_the_drop_folder(self):
        self.guide_ready()
        self.drop('more.sql', DUMP)
        self.guide_state(plans=[{'plan_id': 'plan-' + '8' * 32, 'kind': 'convert', 'status': 'stale'}])
        also = self.op('guide')['also']
        self.assertTrue(any('out of date' in line for line in also))
        self.assertTrue(any('drop folder' in line for line in also))

    def test_guide_says_when_it_could_not_read_the_workbench(self):
        self.guide_ready()
        self.guide_state()
        self.control.status_refusal = self.d.Refusal('STANDARD_OPERATION_FAILED')
        guide = self.op('guide')
        self.assertNext('agent', "couldn't be read", guide)
        self.assertIn('STANDARD_OPERATION_FAILED', guide['next']['action'])

    def test_guide_holds_no_file_names_or_customer_values(self):
        self.create()
        self.drop('customer-name-export.sql', DUMP)
        self.op('take', path='customer-name-export.sql', type='mysql-dump')
        printed = json.dumps(self.op('guide'))
        self.assertNotIn('customer-name', printed)
        self.assertNotIn(MARKER, printed)

    def test_guide_always_says_what_it_does_not_track_and_who_to_ask(self):
        guide = self.op('guide')
        self.assertIn('not tracked yet', guide['data_purpose'])
        self.assertIn('not recorded yet', guide['site_acceptance'])
        self.assertEqual('your node admin', guide['support_contact'])
        contact = self.base.parent / 'etc/support-contact'
        contact.parent.mkdir(exist_ok=True)
        contact.write_text('Ruben\n')
        self.assertEqual('Ruben', self.op('guide')['support_contact'])
        contact.write_text('two\nlines\n')
        self.assertEqual('your node admin', self.op('guide')['support_contact'])
        contact.unlink()
        contact.symlink_to(self.base / 'elsewhere')
        self.assertEqual('your node admin', self.op('guide')['support_contact'])

    # -- decisions ---------------------------------------------------------------------------

    def test_decisions_are_append_only_newest_first_and_survive_a_bad_line(self):
        self.assertEqual({'decisions': [], 'total': 0}, {k: v for k, v in self.op('decisions').items() if k != 'version'})
        self.refused('STANDARD_NOT_INITIALIZED', 'decide', topic='a', decision='b')
        self.create()
        self.refused('STANDARD_ARGUMENTS_INVALID: topic', 'decide', topic=' ', decision='b')
        self.refused('STANDARD_ARGUMENTS_INVALID: topic', 'decide', topic='a\nb', decision='b')
        self.refused('STANDARD_ARGUMENTS_INVALID: topic', 'decide', topic='a' * 121, decision='b')
        self.refused('STANDARD_ARGUMENTS_INVALID: decision', 'decide', topic='a', decision='')
        self.refused('STANDARD_ARGUMENTS_INVALID: decision', 'decide', topic='a', decision='b' * 2001)
        first = self.op('decide', topic='Empty posts', decision='Keep posts with attachments')
        self.assertRegex(first['id'], r'decision-[0-9a-f]{16}\Z')
        self.op('decide', topic='Empty posts', decision='Drop them all')
        path = self.base / 'arc/.silo-migrate/data/decisions.jsonl'
        self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
        with open(path, 'a') as out:
            out.write('not json\n')
        result = self.op('decisions')
        self.assertEqual(['Drop them all', 'Keep posts with attachments'], [entry['decision'] for entry in result['decisions']])
        self.assertEqual(2, result['total'])
        self.assertEqual(2, self.op('guide')['decisions_recorded'])
        audit = (self.base / 'arc/.silo-migrate/data/audit.jsonl').read_text()
        self.assertNotIn('Drop them all', audit)
        self.assertIn('decision_sha256', audit)
        self.assertIn('topic_sha256', audit)
        self.assertNotIn('Empty posts', audit)
        self.assertNotIn('"op": "decisions"', audit)
        path.unlink()
        path.symlink_to(self.base / 'elsewhere.jsonl')
        self.refused('STANDARD_PATH_INVALID', 'decisions')

    def test_refusals_name_the_bad_field(self):
        self.create()
        self.refused('STANDARD_ARGUMENTS_INVALID: timeout_minutes', 'script', language='ruby', code='puts 1', into='x', timeout_minutes='soon')
        self.refused('STANDARD_ARGUMENTS_INVALID: area', 'list', area='nope')

    def test_notes_are_the_projects_memory_with_previous_versions_kept(self):
        self.assertIn("doesn't exist yet", self.op('notes')['note'])
        self.create()
        self.assertEqual('', self.op('notes')['notes'])
        self.refused('STANDARD_ARGUMENTS_INVALID', 'notes_write', text='  ')
        self.refused('STANDARD_NOTES_TOO_LARGE', 'notes_write', text='a\n' * 14000)  # escaped, it wouldn't fit a read
        for version in range(1, 24):
            self.op('notes_write', text=f'# arc\nversion {version}')
        notes = self.op('notes')
        self.assertEqual('# arc\nversion 23\n', notes['notes'])
        path = self.base / 'arc/.silo-migrate/data/notes.md'
        self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
        history = sorted((self.base / 'arc/.silo-migrate/data/notes-history').glob('*.md'))
        self.assertEqual(20, len(history))
        self.assertEqual('# arc\nversion 22\n', history[-1].read_text())
        audit = (self.base / 'arc/.silo-migrate/data/audit.jsonl').read_text()
        self.assertNotIn('version 23', audit)  # logged by hash only
        self.assertIn('text_sha256', audit)
        self.assertNotIn('"op": "notes"', audit)
        # Never through a link.
        path.unlink()
        path.symlink_to(self.base / 'elsewhere.md')
        self.refused('STANDARD_PATH_INVALID', 'notes')
        self.refused('STANDARD_PATH_INVALID', 'notes_write', text='x')

    # -- findings and output ---------------------------------------------------------

    def test_run_tools_accept_the_plan_id_and_count_one_query(self):
        self.create()
        evidence = self.op('run_evidence', run_id='plan-' + 'a' * 32)
        self.assertEqual('run-' + 'e' * 32, evidence['run_id'])
        self.refused('STANDARD_RUN_NOT_FOUND', 'run_evidence', run_id='plan-' + '0' * 32)
        counted = self.op('run_count', run_id='run-' + 'd' * 32, side='destination', sql='SELECT COUNT(*) FROM posts')
        self.assertEqual(7, counted['count'])
        argv, sent = [(argv, sent) for argv, sent in self.control.calls if argv[:3] == ['standard', 'analyst', 'count']][-1]
        self.assertEqual(['standard', 'analyst', 'count', 'arc', 'run-' + 'd' * 32, '--side', 'destination', '--sql-file', '-'], argv)
        self.assertEqual('SELECT COUNT(*) FROM posts', sent)  # stdin, never argv
        audit = (self.base / 'arc/.silo-migrate/data/audit.jsonl').read_text()
        self.assertNotIn('FROM posts', audit)
        self.assertIn('sql_sha256', audit)
        self.op('run_count', run_id='plan-' + 'a' * 32, side='intermediate', sql='SELECT COUNT(*) FROM posts')
        for bad in ({'side': 'source', 'sql': 'SELECT 1'}, {'side': 'intermediate', 'sql': ''}, {'side': 'intermediate', 'sql': 'x' * 5000},
                    {'side': 'intermediate', 'sql': 5}, {'run_id': 'run-1', 'side': 'intermediate', 'sql': 'SELECT 1'}):
            self.refused('STANDARD_ARGUMENTS_INVALID', 'run_count', **dict({'run_id': 'run-' + 'd' * 32}, **bad))

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

    def test_plan_propose_passes_input_ids_and_prepares_dependencies_once(self):
        self.create()
        source, settings, checks = ('input-%032x' % n for n in (1, 2, 3))
        calls, answers = [], ['deps-missing', 'plan']
        plan = {'version': 1, 'plan_id': 'plan-' + 'e' * 32, 'digest': 'f' * 64, 'status': 'proposed', 'operation': 'standard_convert',
                'platform': 'mybb', 'roles': {'source': source}, 'inputs': [], 'source_charset': 'latin1', 'converter_revision': 'a' * 40,
                'converter_deps': 'd' * 64, 'mutations': ['load'], 'not_included': ['import into Discourse'], 'private': 'not passed on'}
        original = self.control

        def control(argv, input=None, timeout=120):
            if argv[:3] == ['standard', 'plan', 'propose']:
                calls.append((argv, timeout))
                if answers.pop(0) == 'deps-missing':
                    self.d.refuse('STANDARD_CONVERTER_DEPS_MISSING: run dev_test once on this commit')
                return json.dumps(plan)
            if argv == ['standard', 'converter', 'refresh', 'arc', '--if-changed']:
                calls.append((argv, timeout))
                return json.dumps({'version': 1, 'commit': 'a' * 40, 'branch': 'migration/arc/mybb-converter', 'dirty': False})
            if argv[:2] == ['converter', 'deps']:
                calls.append((argv, timeout))
                return json.dumps({'version': 1, 'dependencies': {'status': 'prepared', 'gems_added': ['markbridge-0.5.0']}})
            return original(argv, input=input, timeout=timeout)
        self.control = control
        result = self.op('plan_propose', source=source, settings=settings, reconciliation=checks, charset='latin1')
        propose = ['standard', 'plan', 'propose', 'arc', '--operation', 'convert', '--charset', 'latin1', '--source', source,
                   '--settings', settings, '--reconciliation', checks]
        self.assertEqual([['standard', 'converter', 'refresh', 'arc', '--if-changed'], propose, ['converter', 'deps', 'arc', '--budget', '150'], propose],
                         [c for c, _ in calls])
        self.assertLessEqual(sum(timeout for _, timeout in calls), 285)
        self.assertEqual('plan-' + 'e' * 32, result['plan_id'])
        self.assertEqual({'status': 'prepared', 'gems_added': ['markbridge-0.5.0']}, result['dependencies_prepared'])
        self.assertNotIn('private', result)
        self.assertIn('Runs widget', result['next'])
        self.assertEqual('migration/arc/mybb-converter', result['converter_branch'])
        calls.clear()
        answers.append('plan')
        self.op('plan_propose', source=source, settings=settings)
        self.assertEqual([['standard', 'converter', 'refresh', 'arc', '--if-changed'], ['standard', 'plan', 'propose', 'arc', '--operation', 'convert', '--charset', 'utf8mb4',
                                                                       '--source', source, '--settings', settings]], [c for c, _ in calls])
        for bad in ({'source': 'input-1', 'settings': settings}, {'source': source, 'settings': source + ' --x'},
                    {'source': source, 'settings': settings, 'charset': 'koi8r'}, {'source': source}):
            with self.subTest(bad=bad):
                self.refused('STANDARD_ARGUMENTS_INVALID', 'plan_propose', **bad)

    def test_review_plan_propose_skips_converter_and_selects_summary(self):
        self.create()
        run_id, checks = 'run-' + 'a' * 32, 'input-' + 'b' * 32
        calls = []
        plan = {'plan_id': 'plan-' + 'c' * 32, 'digest': 'd' * 64, 'status': 'proposed',
                'operation': 'standard_review', 'from_run': {'run_id': run_id, 'intermediate_sha256': 'e' * 64, 'intermediate_bytes': 42},
                'roles': {'reconciliation': checks}, 'inputs': [], 'instances': {'review': {'port': 18081}},
                'limits': {'web': {'cpus': 2, 'memory_mib': 4096, 'pids': 512}},
                'mutations': ['import'], 'not_included': ['uploads'], 'private': 'never returned'}

        def control(argv, input=None, timeout=120):
            calls.append(argv)
            return json.dumps(plan)
        self.control = control
        result = self.op('plan_propose', from_run=run_id, reconciliation=checks)
        argv = ['standard', 'plan', 'propose', 'arc', '--operation', 'review', '--from-run', run_id]
        self.assertEqual([argv + ['--reconciliation', checks]], calls)
        for key in ('from_run', 'instances', 'limits', 'roles', 'inputs', 'digest', 'plan_id', 'mutations', 'not_included'):
            self.assertEqual(plan[key], result[key])
        self.assertNotIn('private', result)
        calls.clear()
        self.op('plan_propose', from_run=run_id)
        self.assertEqual([argv], calls)
        calls.clear()
        for bad in ({'from_run': 'run-1'}, {'from_run': run_id + ' --yes'}, {'from_run': None},
                    {'from_run': run_id, 'source': checks}, {'from_run': run_id, 'settings': checks},
                    {'from_run': run_id, 'charset': 'utf8mb4'}, {'from_run': run_id, 'reconciliation': 'input-1'}):
            with self.subTest(bad=bad):
                self.refused('STANDARD_ARGUMENTS_INVALID', 'plan_propose', **bad)
        self.assertEqual([], calls)

    def test_control_refusals_keep_a_short_detail(self):
        runner = self.d.control_runner('/bin/sh')
        with mock.patch.object(self.d.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '',
                               'Error: STANDARD_RECONCILIATION_INVALID: check 3: source_sql. The reconciliation input is invalid.\n')):
            with self.assertRaisesRegex(self.d.Refusal, r'\ASTANDARD_RECONCILIATION_INVALID: check 3: source_sql\Z'):
                runner(['standard'])
        with mock.patch.object(self.d.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'Error: STANDARD_STALE_PLAN\n')):
            with self.assertRaisesRegex(self.d.Refusal, r'\ASTANDARD_STALE_PLAN\Z'):
                runner(['standard'])
        # A long or multi-line detail is cut, never passed on whole.
        with mock.patch.object(self.d.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'Error: STANDARD_SETTINGS_INVALID: ' + 'x' * 500 + '\nsecond line\n')):
            with self.assertRaises(self.d.Refusal) as caught:
                runner(['standard'])
            self.assertEqual('STANDARD_SETTINGS_INVALID', str(caught.exception))

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
        self.reserve = 0

    def run_extract(self, archive):
        env = dict(os.environ, SILO_DATA_RESERVE_BYTES=str(self.reserve))
        result = subprocess.run(['python3', '-I', '-B', str(ROOT / 'bin/data_extract.py'), str(archive), str(self.out)], capture_output=True, text=True, timeout=30, env=env)
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

    def test_extraction_stops_at_the_disk_reserve(self):
        archive = self.root / 'big.zip'
        with zipfile.ZipFile(archive, 'w') as zf:
            zf.writestr('a.bin', b'x' * 10)
        self.reserve = 10 ** 18
        code, summary = self.run_extract(archive)
        self.assertEqual((1, 'failed'), (code, summary['status']))
        self.assertIn('reserve', summary['error'])

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
