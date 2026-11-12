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
            (root / '.silo-migrate').chmod(0o700)
            (root / 'inputs').mkdir(mode=0o700)
            (root / '.silo-migrate/named/state.json').write_text(json.dumps({'inputs': {}, 'datasets': {}}))
            return json.dumps({'version': 1, 'status': 'initialized'})
        root = self.base / ws
        if argv[:3] == ['named', 'source', 'add']:
            return json.dumps({'version': 1, 'source_id': 'source-' + 'a' * 32, 'status': 'registered'})
        if argv[:3] == ['named', 'dataset', 'add']:
            state = json.loads((root / '.silo-migrate/named/state.json').read_text())
            dataset_id = 'dataset-' + ('b' * 32 if not state['datasets'] else '%032x' % (len(state['datasets']) + 1))
            state['datasets'][dataset_id] = {'id': dataset_id}
            (root / '.silo-migrate/named/state.json').write_text(json.dumps(state))
            return json.dumps({'version': 1, 'dataset_id': dataset_id, 'status': 'registered'})
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


FAKE_TERM_LLM = """#!/usr/bin/env python3
import os, sys
if sys.argv[1:] == ['--version']:
    print(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'term-version')).read().strip())
    sys.exit(0)
top = os.path.dirname(os.environ['XDG_CONFIG_HOME'])  # term-llm gets only HOME, PATH, LANG and this
with open(os.path.join(top, 'term-calls'), 'a') as out:
    out.write(' '.join(sys.argv[1:]) + '\\n')
if os.path.exists(os.path.join(top, 'term-fails')) or sys.argv[1:3] != ['config', 'set']:
    sys.exit(1)
name = sys.argv[3].split('.')[2]
path = os.path.join(os.environ['XDG_CONFIG_HOME'], 'term-llm', 'config.yaml')
os.makedirs(os.path.dirname(path), exist_ok=True)
text = open(path).read() if os.path.exists(path) else 'providers: {}\\n'
if 'mcp:' not in text:
    text += 'mcp:\\n  servers:\\n'
text += '    ' + name + ':\\n      agents:\\n        - ' + sys.argv[4] + '\\n'
open(path, 'w').write(text)
"""


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
        self.auto_label = True
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
        # term-llm's `config set`, faked: it records the call and appends the rule the way term-llm
        # writes it. Never the term-llm on PATH.
        self.term = top / 'fake-term-llm'
        self.term.write_text(FAKE_TERM_LLM)
        self.term.chmod(0o700)
        (top / 'term-version').write_text('term-llm version 0.9.99 (commit: x)')
        self.d._enforcing.clear()
        self.term_calls = top / 'term-calls'
        term = mock.patch.object(self.d, 'term_llm_command', return_value=str(self.term))
        term.start()
        self.addCleanup(term.stop)

    def rules(self):
        path = self.config_home / 'term-llm/config.yaml'
        return self.d.mcp_rules_of(path.read_text()) if path.exists() else {}

    def term_calls_made(self):
        return self.term_calls.read_text().splitlines() if self.term_calls.exists() else []

    def content_id(self, ref):
        profile = json.loads((ROOT / 'runtime/profiles/discourse-2026.11.0-latest-3158c750.json').read_text())
        return next(image['content_id'] for image in profile['images'].values() if image['ref'] == ref)

    def op(self, op, **request):
        if op == 'take' and self.auto_label:
            self.mark_labelled(request.get('path'))
        result = self.d.main(['data', 'arc'], self.values, self.base, ROOT, self.host, io.StringIO(json.dumps(dict(op=op, **request))), self.control)
        self.assertLessEqual(len(json.dumps(result, ensure_ascii=False).encode()), 46 * 1024)
        return result

    def mark_labelled(self, path):
        """Most tests are about moving files, not labels: treat the file as already labelled."""
        file = self.intake / path if isinstance(path, str) else None
        if file is None or file.is_symlink() or not file.is_file() or '..' in path or not (self.base / 'arc/.silo-migrate/data/workspace.json').is_file():
            return
        dataset = json.loads((self.base / 'arc/.silo-migrate/data/workspace.json').read_text())['dataset_id']
        store = self.base / 'arc/.silo-migrate/named/deliveries.json'
        document = json.loads(store.read_text()) if store.exists() else {'version': 1, 'deliveries': {}}
        record = document['deliveries'].setdefault(dataset, {'dataset_id': dataset, 'kind': 'development', 'version': 1, 'labelled_at': 'x', 'labelled_by': 'T', 'files': []})
        info = file.stat()
        record['files'].append({'path': path, 'bytes': info.st_size, 'mtime_ns': str(info.st_mtime_ns), 'ctime_ns': str(info.st_ctime_ns), 'ino': str(info.st_ino)})
        store.write_text(json.dumps(document))

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
            return fd, os.stat_result(fields, {'st_mtime_ns': info.st_mtime_ns, 'st_ctime_ns': info.st_ctime_ns})
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
        self.assertEqual({'command', 'args'}, set(entry))  # the limit is config.yaml's rule, not a key here
        self.assertEqual(['dbhub', 'arc'], entry['args'])
        self.assertTrue(entry['command'].endswith('/bin/silo-migrate-control'))
        self.assertEqual(0o600, stat.S_IMODE((self.config_home / 'term-llm/mcp.json').stat().st_mode))
        self.assertEqual(['migration-data'], self.rules()['db-arc'])
        self.assertEqual(['config set mcp.servers.db-arc.agents migration-data'], self.term_calls_made())  # once: then it's there
        # An entry written by an earlier release (with `agents` in mcp.json) is rewritten once.
        config['servers']['db-arc']['agents'] = ['migration-data']
        (self.config_home / 'term-llm/mcp.json').write_text(json.dumps(config))
        self.docker.image_present = False
        self.docker.calls.clear()
        repaired = self.op('db_status')['queries']
        self.assertEqual('added', repaired['registration'])
        self.assertNotIn('agents', self.mcp()['servers']['db-arc'])
        self.assertEqual([], self.docker.argvs('pull'))  # status never pulls
        self.assertIn('data_db_up', repaired['image'])
        audit = [json.loads(line) for line in (self.base / 'arc/.silo-migrate/data/audit.jsonl').read_text().splitlines()]
        self.assertEqual(2, sum(1 for entry in audit if entry['op'] == 'mcp_register'))
        # A rule someone took out of config.yaml is put back by status.
        (self.config_home / 'term-llm/config.yaml').write_text('providers: {}\n')
        self.assertEqual('registered', self.op('db_status')['queries']['registration'])
        self.assertEqual(['migration-data'], self.rules()['db-arc'])
        # Someone else's server with that name is left alone.
        config = self.mcp()
        config['servers']['db-arc'] = {'command': 'npx', 'args': ['my-db']}
        (self.config_home / 'term-llm/mcp.json').write_text(json.dumps(config))
        self.assertIn("isn't silo-migrate's", self.op('db_status')['queries']['registration'])
        self.assertEqual(['my-db'], self.mcp()['servers']['db-arc']['args'])
        self.op('db_reset', confirm=True)
        self.assertEqual(['my-db'], self.mcp()['servers']['db-arc']['args'])
        self.assertEqual(['migration-data'], self.rules()['db-arc'])  # the rule outlives the server
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

    def test_a_database_is_never_listed_without_its_rule(self):
        self.create()
        (self.config_home / 'term-llm').mkdir(parents=True)
        (self.term_calls.parent / 'term-fails').touch()
        queries = self.op('db_up', engine='mariadb')['queries']
        self.assertIn("couldn't be limited to migration-data", queries['registration'])
        self.assertNotIn('db-arc', (self.mcp() if (self.config_home / 'term-llm/mcp.json').exists() else {'servers': {}})['servers'])
        (self.term_calls.parent / 'term-fails').unlink()
        self.assertEqual('added', self.op('db_status')['queries']['registration'])
        self.assertEqual(['migration-data'], self.rules()['db-arc'])

    def test_a_rule_that_goes_while_the_server_is_added_takes_it_back_out(self):
        self.create()
        (self.config_home / 'term-llm').mkdir(parents=True)
        real = self.d.mcp_rule_present
        answers = iter([True, False])  # there when checked, gone once mcp.json was written
        with mock.patch.object(self.d, 'mcp_rule_present', side_effect=lambda name: next(answers, real(name))):
            queries = self.op('db_up', engine='mariadb')['queries']
        self.assertIn('its rule left', queries['registration'])
        self.assertNotIn('db-arc', self.mcp()['servers'])

    def test_a_term_llm_that_doesnt_enforce_rules_is_never_asked_to_write_one(self):
        # 0.9.93 (a rollback) would write the rule as a plain value, which 0.9.99 refuses to read.
        (self.term.parent / 'term-version').write_text('term-llm version 0.9.93 (commit: x)')
        self.create()
        (self.config_home / 'term-llm').mkdir(parents=True)
        self.assertEqual('added', self.op('db_up', engine='mariadb')['queries']['registration'])  # as before rules existed
        self.assertIn('db-arc', self.mcp()['servers'])
        self.assertEqual([], self.term_calls_made())
        self.assertEqual({}, self.rules())
        out = io.StringIO()
        with mock.patch('sys.stdout', out), self.assertRaisesRegex(self.d.Refusal, "doesn't enforce MCP rules"):
            self.d.mcp_rules_main(['mcp-rules'], self.values, self.base, ROOT)
        self.assertEqual({'version': 1, 'project_servers': 1, 'enforced': False}, json.loads(out.getvalue()))
        self.assertIn('db-arc', self.mcp()['servers'])  # nothing taken out
        self.assertEqual([], self.term_calls_made())

    def test_a_version_that_cant_be_read_still_requires_the_rule(self):
        (self.term.parent / 'term-version').write_text('garbled')
        self.assertTrue(self.d.term_llm_enforces(str(self.term)))
        self.assertNotIn(str(self.term), self.d._enforcing)  # not remembered
        self.create()
        (self.config_home / 'term-llm').mkdir(parents=True)
        (self.term_calls.parent / 'term-fails').touch()
        self.assertIn("couldn't be limited", self.op('db_up', engine='mariadb')['queries']['registration'])
        self.assertNotIn('db-arc', (self.mcp() if (self.config_home / 'term-llm/mcp.json').exists() else {'servers': {}})['servers'])

    def test_mcp_rules_limits_every_project_database_and_names_none(self):
        (self.config_home / 'term-llm').mkdir(parents=True)
        servers = {'db-arc': {'command': 'c', 'args': ['dbhub', 'arc']}, 'db-other': {'command': 'c', 'args': ['dbhub', 'other']},
                   'db-mine': {'command': 'npx', 'args': ['x']}, 'playwright': {'command': 'npx', 'args': []}}
        (self.config_home / 'term-llm/mcp.json').write_text(json.dumps({'servers': servers}))
        (self.config_home / 'term-llm/config.yaml').write_text('providers: {}\nmcp:\n  servers:\n    db-arc:\n      agents:\n        - migration-data\n')
        out = io.StringIO()
        with mock.patch('sys.stdout', out):
            self.assertEqual(0, self.d.mcp_rules_main(['mcp-rules'], self.values, self.base, ROOT))
        self.assertEqual({'version': 1, 'project_servers': 2, 'limited_to_migration_data': 2, 'taken_out': 0}, json.loads(out.getvalue()))
        self.assertEqual({'db-arc': ['migration-data'], 'db-other': ['migration-data']}, self.rules())
        self.assertEqual(['config set mcp.servers.db-other.agents migration-data'], self.term_calls_made())  # only the missing one
        self.assertNotIn('arc', out.getvalue())
        # One that can't be limited comes out of mcp.json: never open to every agent.
        (self.config_home / 'term-llm/config.yaml').write_text('providers: {}\nmcp:\n  servers:\n    db-arc:\n      agents:\n        - migration-data\n')
        (self.term_calls.parent / 'term-fails').touch()
        out = io.StringIO()
        with mock.patch('sys.stdout', out), self.assertRaisesRegex(self.d.Refusal, 'not every project database'):
            self.d.mcp_rules_main(['mcp-rules'], self.values, self.base, ROOT)
        self.assertEqual({'version': 1, 'project_servers': 2, 'limited_to_migration_data': 1, 'taken_out': 1}, json.loads(out.getvalue()))
        self.assertEqual({'db-arc', 'db-mine', 'playwright'}, set(self.mcp()['servers']))

    def test_reads_the_rules_term_llm_writes_and_refuses_what_it_cant_read(self):
        text = ('providers:\n  x:\n    api_key: $(op read "op://a/b")\nmcp:\n  servers:\n    db-arc:\n      agents:\n        - migration-data\n'
                '    "db-q":\n      agents: [migration-data, other]  # two\n    db-none:\n      agents: []\n    plain:\n      foo: bar\nagents:\n  use_builtin: false\n')
        self.assertEqual({'db-arc': ['migration-data'], 'db-q': ['migration-data', 'other'], 'db-none': []}, self.d.mcp_rules_of(text))
        self.assertEqual({}, self.d.mcp_rules_of('providers: {}\n'))
        self.assertEqual({}, self.d.mcp_rules_of('mcp:\n  servers: {}\n'))
        for bad in ('mcp:\n  servers:\n    db-x:\n      agents:\n        - a\n       - b\n', 'mcp:\n  servers: [1\n', 'mcp:\n  servers: {}\nmcp:\n  x: 1\n'):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.d.mcp_rules_of(bad)

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
        dataset = json.loads((self.base / 'arc/.silo-migrate/data/workspace.json').read_text())['dataset_id']
        state['plans'] = {plan['plan_id']: {'body': {'operation': 'standard_' + plan['kind'], 'dataset_id': plan.get('dataset_id', dataset)}} for plan in (plans or [])}
        for run in runs or []:
            state['plans'].setdefault(run['plan_id'], {'body': {'operation': 'standard_' + run['kind'], 'dataset_id': run.get('dataset_id', dataset)}})
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
        (self.base / 'arc/.silo-migrate/data/db/state.json').write_text(json.dumps({'engine': 'mariadb', 'loads': [{'at': 'x', 'dataset_id': json.loads((self.base / 'arc/.silo-migrate/data/workspace.json').read_text())['dataset_id']}]}))

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

    def test_guide_for_a_new_project_with_files_sends_the_engineer_to_create_the_workspace_on_the_page(self):
        self.drop('dump.sql', DUMP)
        guide = self.op('guide')
        self.assertEqual('workspace', guide['stage'])
        self.assertNext('engineer', 'On the Files tab, create the workspace', guide)
        self.assertEqual('Project page', guide['next']['where'])

    def test_the_files_view_says_whether_workspace_setup_is_done_and_the_guide_follows(self):
        self.auto_label = False
        self.drop('dump.sql', DUMP)
        self.assertEqual({'complete': False, 'platform': None}, self.op('deliveries')['setup'])
        self.assertEqual([], self.control.calls)  # looking creates nothing
        self.create()
        self.assertEqual({'complete': True, 'platform': 'mybb'}, self.op('deliveries')['setup'])
        self.assertNext('engineer', "say what they're for")
        # A setup that stopped at the clone: the platform is known, the rest is still to do.
        standard = self.base / 'arc/.silo-migrate/named/standard/state.json'
        kept = standard.read_text()
        standard.unlink()
        self.assertEqual({'complete': False, 'platform': 'mybb'}, self.op('deliveries')['setup'])
        self.assertNext('engineer', 'Finish creating the workspace on the Files tab')
        standard.write_text(kept)
        self.assertEqual({'complete': True, 'platform': 'mybb'}, self.op('deliveries')['setup'])

    def test_guide_walks_the_whole_flow(self):
        self.create()
        self.drop('dump.sql', DUMP)
        self.assertNext('engineer', 'Project page')
        self.label('development')
        self.assertNext('agent', 'data_take')
        self.op('take', path='dump.sql', type='mysql-dump')
        self.assertNext('agent', 'data_db_load')
        (self.base / 'arc/.silo-migrate/data/db').mkdir(exist_ok=True)
        (self.base / 'arc/.silo-migrate/data/db/state.json').write_text(json.dumps({'engine': 'mariadb', 'loads': [{'at': 'x', 'dataset_id': json.loads((self.base / 'arc/.silo-migrate/data/workspace.json').read_text())['dataset_id']}]}))
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
        self.assertNext('engineer', 'accept it or say what needs changing', guide)
        self.assertEqual('site', guide['stage'])
        self.assertEqual('current', guide['stages'][-1]['state'])
        self.assertTrue(any('holds customer data' in line for line in guide['also']))
        self.guide_state(findings=released, pushes=pushes, runs=[convert, review])
        self.assertNext('engineer', 'its site is gone: accept it on its pass')

    def site_state(self, review_passed=True, kind='development'):
        """Plans and runs stored the way the workbench stores them: a passed convert and a review import."""
        self.guide_ready()
        dataset = next(iter(json.loads((self.base / 'arc/.silo-migrate/named/state.json').read_text())['datasets']))
        self.deliveries({dataset: {'dataset_id': dataset, 'kind': kind, 'version': 2, 'sequence': 1, 'labelled_at': '2026-01-01T00:00:00Z', 'files': []}})
        convert_run, review_run = 'run-' + '1' * 32, 'run-' + '2' * 32
        binding = lambda *ids: [{'id': i, 'sha256': i[-1] * 64, 'bytes': 1, 'type': 'x'} for i in ids]
        delivery = {'dataset_id': dataset, 'kind': kind, 'version': 2}
        convert_body = {'operation': 'standard_convert', 'delivery': delivery, 'converter_revision': 'c' * 40,
                        'converter': {'repo': 'https://github.com/x/y.git', 'branch': 'migration/arc/x'}, 'source_charset': 'utf8mb4',
                        'roles': {'source': 'input-' + 'a' * 32, 'settings': 'input-' + 'b' * 32, 'reconciliation': 'input-' + 'd' * 32},
                        'input_binding': binding('input-' + 'a' * 32, 'input-' + 'b' * 32, 'input-' + 'd' * 32)}
        review_body = {'operation': 'standard_review', 'delivery': delivery, 'from_run': {'run_id': convert_run},
                       'roles': {'reconciliation': 'input-' + 'e' * 32}, 'input_binding': binding('input-' + 'e' * 32),
                       'discourse_profile': 'discourse-2026.11.0-latest-3158c750', 'runtime_lock_sha256': 'f' * 64}
        results = lambda matched: {'reconciliation_checks': 6, 'reconciliation_matched': matched}
        standard = self.base / 'arc/.silo-migrate/named/standard'
        state = json.loads((standard / 'state.json').read_text())
        state['config'] = dict(state.get('config') or {}, converter_revision='c' * 40, discourse_profile='discourse-2026.11.0-latest-3158c750')
        state['plans'] = {'plan-' + '1' * 32: {'digest': '1' * 64, 'body': convert_body}, 'plan-' + '2' * 32: {'digest': '2' * 64, 'body': review_body}}
        state['runs'] = {convert_run: {'id': convert_run, 'plan_id': 'plan-' + '1' * 32, 'status': 'completed', 'results': results(6)},
                         review_run: {'id': review_run, 'plan_id': 'plan-' + '2' * 32, 'status': 'completed', 'results': results(6 if review_passed else 5)}}
        (standard / 'state.json').write_text(json.dumps(state))
        self.control.status = {'version': 1, 'instances': [], 'plans': [],
                               'runs': [{'run_id': run_id, 'plan_id': run['plan_id'], 'status': 'completed', 'started_at': '2026-01-0%dT00:00:00Z' % (4 + i),
                                         'results': run['results']} for i, (run_id, run) in enumerate(state['runs'].items())]}
        return review_run

    def deliveries(self, records):
        (self.base / 'arc/.silo-migrate/named/deliveries.json').write_text(json.dumps({'version': 1, 'deliveries': records}))

    def test_site_review_accepts_exactly_the_process_shown_and_the_guide_follows(self):
        run_id = self.site_state()
        shown = self.op('site_process', run_id=run_id)
        self.assertTrue(shown['can_accept'])
        process = shown['process']
        self.assertEqual(('c' * 40, 'migration/arc/x', 2), (process['converter']['revision'], process['converter']['branch'], process['delivery']['version']))
        self.assertEqual({'id': 'input-' + 'b' * 32, 'sha256': 'b' * 64}, process['settings'])
        self.assertEqual({'convert': {'checks': 6, 'matched': 6}, 'import': {'checks': 6, 'matched': 6}}, process['results'])
        accept = dict(run_id=run_id, verdict='accepted', basis='customer', by='Alex (web UI)', note='approved on the call')
        with self.assertRaisesRegex(self.d.Refusal, 'STANDARD_APPROVAL_MISMATCH'):
            self.op('site_review', process_digest='0' * 64, **accept)
        with self.assertRaisesRegex(self.d.Refusal, 'basis'):
            self.op('site_review', process_digest=shown['process_digest'], **dict(accept, basis='me'))
        # Not something an agent can do, even with the right arguments.
        with self.assertRaisesRegex(self.d.Refusal, 'STANDARD_DATA_OPERATION_REFUSED'):
            self.op('site_review', process_digest=shown['process_digest'], via='chat', **accept)
        self.assertFalse(self.d.site_reviews_file(self.d.Workspace(self.base, 'arc', ROOT, None, {}, None)).exists())
        done = self.op('site_review', process_digest=shown['process_digest'], **accept)
        self.assertEqual(('accepted', 'customer', 'Alex (web UI)'), (done['review']['verdict'], done['review']['basis'], done['review']['by']))
        guide = self.op('guide')
        self.assertEqual('done', guide['stages'][-1]['state'])
        self.assertEqual('nobody', guide['next']['who'])
        self.assertIn('accepted: the customer approved it', guide['next']['action'])
        self.assertEqual({'run_id': run_id, 'data': 'Development v2', 'converter': 'c' * 40, 'by': 'Alex (web UI)', 'note': 'approved on the call'},
                         {key: value for key, value in guide['site_acceptance']['accepted'].items() if key not in ('at', 'id')})
        self.assertEqual([], guide['site_acceptance']['changed_since_acceptance'])
        # The converter moves on: the guide says so, the acceptance stands.
        standard = self.base / 'arc/.silo-migrate/named/standard/state.json'
        state = json.loads(standard.read_text())
        state['config']['converter_revision'] = '9' * 40
        standard.write_text(json.dumps(state))
        self.assertEqual(['converter ccccccc → 9999999'], self.op('guide')['site_acceptance']['changed_since_acceptance'])
        # Withdrawn: nothing is accepted, and the site is back to deciding.
        with self.assertRaisesRegex(self.d.Refusal, 'review_id'):
            self.op('site_review', verdict='withdrawn', review_id='review-nope', by='Alex (web UI)')
        self.op('site_review', verdict='withdrawn', review_id=done['review']['id'], by='Alex (web UI)')
        guide = self.op('guide')
        self.assertIsNone(guide['site_acceptance']['accepted'])
        self.assertEqual('engineer', guide['next']['who'])
        with self.assertRaisesRegex(self.d.Refusal, 'review_id'):  # once
            self.op('site_review', verdict='withdrawn', review_id=done['review']['id'], by='Alex (web UI)')
        reviews = json.loads((self.base / 'arc/.silo-migrate/named/site-reviews.json').read_text())['reviews']
        self.assertEqual(['accepted', 'withdrawn'], [entry['verdict'] for entry in reviews])  # append-only
        audit = (self.base / 'arc/.silo-migrate/data/audit.jsonl').read_text()
        self.assertNotIn('approved on the call', audit)  # the note's text is logged by hash only

    def test_site_review_own_check_and_needs_changes(self):
        run_id = self.site_state()
        digest = self.op('site_process', run_id=run_id)['process_digest']
        self.op('site_review', run_id=run_id, verdict='accepted', basis='engineer', by='Alex (web UI)', process_digest=digest)
        guide = self.op('guide')
        self.assertIsNone(guide['site_acceptance']['accepted'])  # launch repeats only the customer's
        self.assertEqual(run_id, guide['site_acceptance']['own_check']['run_id'])
        self.assertNext('engineer', 'checked the site of review run %s yourself' % run_id, guide)
        self.assertEqual('current', guide['stages'][-1]['state'])
        with self.assertRaisesRegex(self.d.Refusal, 'note'):
            self.op('site_review', run_id=run_id, verdict='needs_changes', by='Alex (web UI)')
        self.op('site_review', run_id=run_id, verdict='needs_changes', by='Alex (web UI)', note='quoted replies show raw markup')
        guide = self.op('guide')
        self.assertNext('agent', 'needs changes: "quoted replies show raw markup"', guide)
        for bad in ('x' * 2001, 'a\x00b', '   '):
            with self.subTest(bad=bad[:5]), self.assertRaisesRegex(self.d.Refusal, 'note'):
                self.op('site_review', run_id=run_id, verdict='needs_changes', by='Alex (web UI)', note=bad)

    def accept(self, run_id, basis='customer', note=None):
        digest = self.op('site_process', run_id=run_id)['process_digest']
        return self.op('site_review', run_id=run_id, verdict='accepted', basis=basis, by='A (web UI)', process_digest=digest, **({'note': note} if note else {}))['review']

    def second_review_run(self):
        """A second passed import of the same convert run (pass 1, imported twice)."""
        standard = self.base / 'arc/.silo-migrate/named/standard/state.json'
        state = json.loads(standard.read_text())
        state['plans']['plan-' + '3' * 32] = dict(state['plans']['plan-' + '2' * 32], digest='3' * 64)
        state['runs']['run-' + '3' * 32] = dict(state['runs']['run-' + '2' * 32], id='run-' + '3' * 32, plan_id='plan-' + '3' * 32)
        standard.write_text(json.dumps(state))
        return 'run-' + '3' * 32

    def test_withdrawing_the_newest_acceptance_leaves_none_not_an_older_one(self):
        first = self.site_state()
        older = self.accept(first)
        second = self.second_review_run()
        newer = self.accept(second)
        self.assertEqual(second, self.op('guide')['site_acceptance']['accepted']['run_id'])
        self.op('site_review', verdict='withdrawn', review_id=newer['id'], by='A (web UI)')
        self.assertIsNone(self.op('guide')['site_acceptance']['accepted'])  # the older acceptance doesn't come back
        # The older pass's acceptance was replaced, so it doesn't stand: it can be withdrawn, or take a
        # new verdict, without anything coming back.
        self.op('site_review', verdict='withdrawn', review_id=older['id'], by='A (web UI)')
        self.op('site_review', run_id=first, verdict='needs_changes', by='A (web UI)', note='a later look found an issue')
        self.assertIsNone(self.op('guide')['site_acceptance']['accepted'])

    def test_a_replaced_acceptance_takes_a_new_verdict(self):
        first = self.site_state()
        self.accept(first)
        second = self.second_review_run()
        self.accept(second)
        # First's acceptance no longer stands (second's does): a new verdict on it is allowed.
        self.op('site_review', run_id=first, verdict='needs_changes', by='A (web UI)', note='a later look found an issue')
        self.assertEqual(second, self.op('guide')['site_acceptance']['accepted']['run_id'])
        with self.assertRaisesRegex(self.d.Refusal, 'STANDARD_SITE_ACCEPTED'):
            self.op('site_review', run_id=second, verdict='needs_changes', by='A (web UI)', note='n')

    def test_a_standing_acceptance_takes_no_other_verdict_until_withdrawn(self):
        run_id = self.site_state()
        done = self.accept(run_id)
        for verdict in ({'verdict': 'needs_changes', 'note': 'n'}, {'verdict': 'accepted', 'basis': 'engineer', 'process_digest': self.op('site_process', run_id=run_id)['process_digest']}):
            with self.subTest(verdict['verdict']), self.assertRaisesRegex(self.d.Refusal, 'STANDARD_SITE_ACCEPTED'):
                self.op('site_review', run_id=run_id, by='A (web UI)', **verdict)
        self.op('site_review', verdict='withdrawn', review_id=done['id'], by='A (web UI)')
        changed = self.op('site_review', run_id=run_id, verdict='needs_changes', by='A (web UI)', note='customer found missing avatars')['review']
        guide = self.op('guide')
        self.assertIsNone(guide['site_acceptance']['accepted'])
        self.assertEqual('agent', guide['next']['who'])
        self.assertNotEqual('done', guide['stages'][-1]['state'])  # the stage and the next step agree
        self.assertIn('never quote it to converter-developer', guide['next']['action'])
        with self.assertRaisesRegex(self.d.Refusal, 'review_id'):  # only an acceptance can be withdrawn
            self.op('site_review', verdict='withdrawn', review_id=changed['id'], by='A (web UI)')
        with self.assertRaisesRegex(self.d.Refusal, 'note'):
            self.op('site_review', run_id=run_id, verdict='needs_changes', by='A (web UI)', note='abc‮def')

    def test_the_page_and_the_guide_read_the_record_alike(self):
        spec = importlib.util.spec_from_file_location('project_board', ROOT / 'integrations/term-llm/widgets/project/board.py')
        board = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(board)
        a = lambda i, run, basis='customer': {'id': 'review-%d' % i, 'verdict': 'accepted', 'basis': basis, 'run_id': run}
        n = lambda i, run: {'id': 'review-%d' % i, 'verdict': 'needs_changes', 'run_id': run, 'note': 'x'}
        w = lambda i, of, run: {'id': 'review-%d' % i, 'verdict': 'withdrawn', 'of': of, 'run_id': run}
        sequences = [[], [a(1, 'r1')], [a(1, 'r1'), w(2, 'review-1', 'r1')], [a(1, 'r1'), a(2, 'r2')], [a(1, 'r1', 'engineer'), n(2, 'r1')], [n(1, 'r1'), a(2, 'r1')],
                     [a(1, 'r1'), a(2, 'r2'), w(3, 'review-2', 'r2')], [a(1, 'r1'), w(2, 'review-1', 'r1'), n(3, 'r1'), a(4, 'r2', 'engineer')]]
        for reviews in sequences:
            with self.subTest(reviews=[entry['id'] for entry in reviews]):
                ours = {run: (entry['verdict'], entry.get('basis')) for run, entry in self.d.site_verdicts(reviews).items()}
                page = {run: (entry['verdict'], entry.get('basis')) for run, entry in board.site_verdicts(reviews).items()}
                self.assertEqual(ours, page)
                current = self.d.current_acceptance(reviews)
                standing = [run for run, entry in board.site_verdicts(reviews).items() if entry['verdict'] == 'accepted' and entry['basis'] == 'customer' and not entry['replaced']]
                self.assertEqual([current['run_id']] if current else [], standing)

    def test_an_unreadable_record_is_said_not_read_as_nothing_accepted(self):
        run_id = self.site_state()
        self.accept(run_id)
        record = self.base / 'arc/.silo-migrate/named/site-reviews.json'
        record.rename(record.with_name('elsewhere.json'))
        record.symlink_to(record.with_name('elsewhere.json'))
        guide = self.op('guide')
        self.assertIsNone(guide['site_acceptance']['accepted'])
        self.assertTrue(any("site reviews couldn't be read (STANDARD_PATH_INVALID)" in line for line in guide['also']), guide['also'])

    def test_only_a_passing_development_site_can_be_accepted(self):
        for case, kwargs in (('a check differs', {'review_passed': False}), ('launch data', {'kind': 'launch'})):
            with self.subTest(case):
                self.setUp()
                run_id = self.site_state(**kwargs)
                shown = self.op('site_process', run_id=run_id)
                self.assertFalse(shown['can_accept'])
                with self.assertRaisesRegex(self.d.Refusal, 'STANDARD_SITE_NOT_PASSED'):
                    self.op('site_review', run_id=run_id, verdict='accepted', basis='customer', by='A (web UI)', process_digest=shown['process_digest'])
                # Saying it needs changes is always possible on a finished import.
                self.op('site_review', run_id=run_id, verdict='needs_changes', by='A (web UI)', note='check the counts')
        with self.assertRaisesRegex(self.d.Refusal, 'STANDARD_SITE_NOT_REVIEW'):
            self.op('site_process', run_id='run-' + '1' * 32)  # a convert run has no site

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
        guide = self.op('guide')
        self.assertTrue(any('out of date' in line for line in guide['also']))
        self.assertTrue(any('1 new file' in item['what'] for item in guide['waiting_on_engineer']))

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
        self.assertIsNone(guide['data']['development'])
        self.assertIn('no data is labelled yet', guide['data']['note'])
        self.assertIsNone(guide['site_acceptance']['accepted'])
        self.assertIn('nothing accepted yet', guide['site_acceptance']['note'])
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
        self.refused('STANDARD_NOT_INITIALIZED', 'decide', topic='a', decision='b', basis='default')
        self.create()
        self.refused('STANDARD_ARGUMENTS_INVALID: topic', 'decide', topic=' ', decision='b', basis='default')
        self.refused('STANDARD_ARGUMENTS_INVALID: topic', 'decide', topic='a\nb', decision='b', basis='default')
        self.refused('STANDARD_ARGUMENTS_INVALID: topic', 'decide', topic='a' * 121, decision='b', basis='default')
        self.refused('STANDARD_ARGUMENTS_INVALID: decision', 'decide', topic='a', decision='', basis='default')
        self.refused('STANDARD_ARGUMENTS_INVALID: decision', 'decide', topic='a', decision='b' * 2001, basis='default')
        for basis in (None, 'engineer', 'ruling'):
            self.refused('STANDARD_ARGUMENTS_INVALID: basis', 'decide', topic='a', decision='b', basis=basis)
        first = self.op('decide', topic='Empty posts', decision='Keep posts with attachments', basis='default')
        self.assertRegex(first['id'], r'decision-[0-9a-f]{16}\Z')
        self.op('decide', topic='Empty posts', decision='Drop them all', basis='engineer_ruling')
        path = self.base / 'arc/.silo-migrate/data/decisions.jsonl'
        self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
        with open(path, 'a') as out:
            out.write('not json\n')
        result = self.op('decisions')
        self.assertEqual(['Drop them all', 'Keep posts with attachments'], [entry['decision'] for entry in result['decisions']])
        self.assertEqual(2, result['total'])
        self.assertEqual(['engineer_ruling', 'default'], [entry['basis'] for entry in result['decisions']])
        self.assertEqual(2, self.op('guide')['decisions_recorded'])
        # Entries from before `basis` existed say so; nothing presents them as rulings.
        with open(path, 'a') as out:
            out.write(json.dumps({'id': 'decision-old', 'at': 'x', 'topic': 'Old', 'decision': 'Backfilled'}) + '\n')
        self.assertEqual('not_recorded', self.op('decisions')['decisions'][0]['basis'])
        audit = (self.base / 'arc/.silo-migrate/data/audit.jsonl').read_text()
        self.assertNotIn('Drop them all', audit)
        self.assertIn('decision_sha256', audit)
        self.assertIn('topic_sha256', audit)
        self.assertNotIn('Empty posts', audit)
        self.assertNotIn('"op": "decisions"', audit)
        path.unlink()
        path.symlink_to(self.base / 'elsewhere.jsonl')
        self.refused('STANDARD_PATH_INVALID', 'decisions')

    # -- deliveries: which data is for what ---------------------------------------------------

    def listing(self):
        return self.op('deliveries')['unlabelled_files']

    def label(self, kind, **extra):
        return self.op('delivery_label', kind=kind, by='Reviewer', files=self.listing(), **extra)

    def input_datasets(self):
        return [record['dataset_id'] for record in json.loads((self.base / 'arc/.silo-migrate/named/state.json').read_text())['inputs'].values()]

    def base_backup(self, stamp='20261110123456'):
        name = 'sandbox-v2026-10-0-' + stamp + '.sql.gz'
        (self.intake / name).write_bytes(gzip.compress(b'-- PostgreSQL database dump\nCREATE TABLE users(id int);'))
        return name

    def test_base_label_does_not_change_accepted_data_or_launch_gate(self):
        run_id = self.site_state()
        self.accept(run_id)
        before = self.op('site_process', run_id=run_id)
        self.base_backup()
        self.label('base_site')
        after = self.op('site_process', run_id=run_id)
        self.assertEqual(before['process_digest'], after['process_digest'])
        self.assertTrue(after['can_accept'])
        guide = self.op('guide')
        self.assertEqual(run_id, guide['site_acceptance']['accepted']['run_id'])
        self.assertEqual([], guide['site_acceptance']['changed_since_acceptance'])
        self.assertEqual('Development v2', guide['data']['development'])

    def test_base_label_auto_takes_and_does_not_change_data_identity(self):
        self.auto_label = False
        self.create()
        self.drop('data.sql', DUMP)
        data = self.label('development')
        source = self.op('take', path='data.sql', type='mysql-dump')['input_id']
        meta = (self.base / 'arc/.silo-migrate/data/workspace.json').read_bytes()
        name = self.base_backup()
        base = self.label('base_site')
        self.assertEqual('Base site v1', base['delivery'])
        self.assertTrue(base['checks']['gzip'])
        self.assertTrue(base['checks']['sql_only_name'])
        self.assertNotIn('sql_only', base['checks'])
        self.assertEqual('2026.10.0', base['checks']['discourse_version'])
        input_id = base['input']['input_id']
        self.assertFalse((self.intake / name).exists())
        self.assertFalse((self.base / 'arc/inputs' / name).stat().st_mode & 0o222)
        self.assertEqual(meta, (self.base / 'arc/.silo-migrate/data/workspace.json').read_bytes())
        status = self.op('status')
        record = next(r for r in status['inputs'] if r['input_id'] == input_id)
        self.assertEqual(('base_site', 'Base site v1'), (record['type'], record['delivery']))
        ws = self.d.Workspace(self.base, 'arc', ROOT, self.host, self.values, self.control)
        dataset, mounts = self.d.job_delivery(ws, {})
        self.assertEqual(data['dataset_id'], dataset)
        self.assertFalse(any(name in str(path) for path, _ in mounts))
        self.assertEqual('Base site v1', self.op('guide')['data']['base_site'])
        self.assertEqual('Development v1', self.op('guide')['data']['development'])
        self.assertEqual('Base site v1', self.op('peek', area='inputs', path=name)['delivery'])
        self.assertEqual('base_site', next(r for r in self.op('list', area='inputs')['entries'] if r['name'] == name)['input_type'])
        for role in ('source', 'settings', 'reconciliation'):
            args = dict(source=source, settings=source)
            args[role] = input_id
            self.refused('STANDARD_BASE_SITE_ROLE', 'plan_propose', **args)
        self.refused('STANDARD_BASE_SITE_ROLE', 'db_load', path='inputs/' + name)
        self.refused('STANDARD_BASE_SITE_TYPE', 'register', path='analysis/result.sql', type='base_site')
        for area in ('list', 'peek'):
            self.refused('STANDARD_ARGUMENTS_INVALID', area, area='outbox', path='backup.sql.gz')

    def test_base_label_does_not_switch_legacy_data_jobs_or_outputs_into_labelled_mode(self):
        self.create()
        self.drop('old.sql', DUMP)
        self.op('take', path='old.sql', type='sql')
        (self.base / 'arc/.silo-migrate/named/deliveries.json').unlink()
        self.base_backup()
        self.label('base_site')
        ws = self.d.Workspace(self.base, 'arc', ROOT, self.host, self.values, self.control)
        with self.assertRaisesRegex(self.d.Refusal, 'NO_ACTIVE_SOURCE'):
            self.d.job_delivery(ws, {})
        # An initialized role registry never guesses an active source from old inputs.
        self.op('delivery_label', kind='development', by='Reviewer', dataset_id=ws.meta()['dataset_id'])
        dataset, mounts = self.d.job_delivery(ws, {})
        self.assertEqual(ws.meta()['dataset_id'], dataset)
        self.assertEqual(['/in/old.sql'], [target for _, target in mounts])
        self.op('extract', path='inputs/old.sql', into='legacy-extract')
        argv = ' '.join(self.docker.calls[-1][0])
        self.assertNotIn('sandbox-v', argv)
        # A completed pre-label job's derived output still belongs to the data metadata,
        # never to the newly labelled Base site.
        job = next((self.base / 'arc/.silo-migrate/data/jobs').glob('*.json'))
        doc = json.loads(job.read_text()); doc['status'] = 'completed'; job.write_text(json.dumps(doc))
        out = self.base / 'arc/work/legacy-extract/result.json'
        out.write_text('{}')
        registered = self.op('register', path='legacy-extract/result.json', type='json')
        item = next(item for item in self.op('status')['inputs'] if item['input_id'] == registered['input_id'])
        self.assertEqual(ws.meta()['dataset_id'], item['dataset_id'])
        self.assertNotEqual('base_site', item['type'])

    def test_base_versions_replace_only_base_and_preserve_data_versions(self):
        self.auto_label = False
        self.create()
        self.drop('data.sql', DUMP)
        dev = self.label('development')
        self.op('take', path='data.sql', type='sql')
        self.base_backup()
        base1 = self.label('base_site')
        self.base_backup('20261111123456')
        base2 = self.label('base_site')
        self.assertEqual('Base site v2', base2['delivery'])
        records = json.loads((self.base / 'arc/.silo-migrate/named/deliveries.json').read_text())['deliveries']
        self.assertEqual(base2['dataset_id'], records[base1['dataset_id']]['replaced_by'])
        self.assertNotIn('replaced_by', records[dev['dataset_id']])
        self.drop('next.sql', DUMP + '-- different')
        self.assertEqual('Development v2', self.label('development')['delivery'])
        self.assertNotIn('replaced_by', json.loads((self.base / 'arc/.silo-migrate/named/deliveries.json').read_text())['deliveries'][base2['dataset_id']])

    def test_base_label_auto_takes_in_cli_workspace_without_data_metadata(self):
        self.auto_label = False
        self.create()
        (self.base / 'arc/.silo-migrate/data/workspace.json').unlink()
        name = self.base_backup()
        labelled = self.label('base_site')
        self.assertEqual('base_site', labelled['input']['type'])
        self.assertFalse((self.intake / name).exists())
        item = next(item for item in self.op('status')['inputs'] if item['input_id'] == labelled['input']['input_id'])
        self.assertEqual(labelled['dataset_id'], item['dataset_id'])
        self.assertIn((['named', 'source', 'add', 'arc', '--platform', 'discourse'], None), self.control.calls)

    def test_base_label_validates_before_writing_and_can_wait_for_workspace_setup(self):
        self.auto_label = False
        self.drop('sandbox.tar.gz', 'not gzip')
        self.refused('STANDARD_BASE_SITE_INVALID', 'delivery_label', kind='base_site', by='Engineer', files=self.listing())
        self.assertEqual([], self.control.calls)
        (self.intake / 'sandbox.tar.gz').unlink()
        name = self.base_backup()
        labelled = self.label('base_site')
        self.assertNotIn('input', labelled)
        self.assertTrue((self.intake / name).exists())
        self.assertIn('create the workspace', self.op('guide')['next']['action'])
        self.create()
        self.refused('STANDARD_BASE_SITE_TYPE', 'take', path=name, type='sql')
        input_id = self.op('take', path=name, type='base_site')['input_id']
        self.assertEqual(labelled['dataset_id'], next(r['dataset_id'] for r in self.op('status')['inputs'] if r['input_id'] == input_id))
        self.drop('data.sql', DUMP)
        self.label('development')
        self.refused('STANDARD_BASE_SITE_TYPE', 'take', path='data.sql', type='base_site')

    def test_base_label_rejects_bad_magic_multiple_files_and_symlinks(self):
        self.auto_label = False
        self.create()
        name = self.base_backup()
        (self.intake / name).write_bytes(b'not gzip')
        self.refused('STANDARD_BASE_SITE_INVALID', 'delivery_label', kind='base_site', by='Engineer', files=self.listing())
        self.assertFalse((self.base / 'arc/.silo-migrate/named/deliveries.json').exists())
        (self.intake / name).unlink()
        name = self.base_backup()
        self.base_backup('20261111123456')
        self.refused('STANDARD_BASE_SITE_INVALID', 'delivery_label', kind='base_site', by='Engineer', files=self.listing())
        self.refused('STANDARD_DATA_OPERATION_REFUSED', 'delivery_label', via='chat', kind='base_site', by='Engineer', files=self.listing())
        (self.intake / name).unlink()
        (self.intake / name).symlink_to(self.intake / 'sandbox-v2026-10-0-20261111123456.sql.gz')
        self.assertEqual(1, len(self.listing()))

    def test_base_guide_adds_release_only_for_base_projects_and_tracks_newest_pass(self):
        facts = {'drop_files': 0, 'inputs': 2, 'initialized': True, 'db_loaded': True, 'base_site': 'Base site v1'}
        convert = {'kind': 'convert', 'run_id': 'run-convert', 'status': 'completed', 'checks': 6, 'matched': 6, 'started_at': '1'}
        review = dict(convert, kind='review', run_id='run-review', started_at='2')
        records = {'runs': [convert, review], 'findings': [], 'pushes': []}
        site = dict(self.d.NO_SITE, checked={'run_id': 'run-review'})
        current, stages = self.d.guide_stages(facts, records, site)
        self.assertEqual('release', current)
        self.assertEqual(['Import on Base site v1', 'Check site', 'Release backup'], [stage['label'] for stage in stages[-3:]])
        review['release'] = {'released_by': 'Engineer'}
        self.assertEqual('accepted', self.d.guide_stages(facts, records, site)[0])
        records['runs'].append(dict(review, run_id='run-new', started_at='3', release=None))
        site['checked'] = {'run_id': 'run-new'}
        self.assertEqual('release', self.d.guide_stages(facts, records, site)[0])
        facts.pop('base_site')
        self.assertEqual(list(self.d.GUIDE_STAGES), [(stage['id'], stage['label']) for stage in self.d.guide_stages(facts, records, site)[1]])

    def test_evidence_adds_backup_identity_and_release_without_extra_customer_counts(self):
        self.create()
        run_id = 'run-' + 'a' * 32
        path = self.base / 'arc/.silo-migrate/named/standard/state.json'
        state = json.loads(path.read_text())
        backup = {'filename': 'invented-v20261110123456.sql.gz', 'sha256': 'a' * 64, 'bytes': 42, 'label': 'sql-only', 'path': '/private/not-exposed'}
        release = {'released_at': '2026-11-10T12:00:00Z', 'released_by': 'Engineer', 'sha256': 'a' * 64, 'filename': backup['filename'],
                   'outbox': '/invented/arc/outbox/', 'manifest': 'invented.manifest.json', 'acknowledged_differences': True}
        state['runs'] = {run_id: {'artifacts': {'backup': backup}, 'release': release, 'results': {'base_site': True, 'base_site_newer_migrations': ['20261109000000'], 'prior_import_id_rows': 7, 'customer_table_count': 999}}}
        path.write_text(json.dumps(state))
        result = self.op('run_evidence', run_id=run_id)['evidence']
        self.assertEqual({k: v for k, v in backup.items() if k != 'path'}, result['backup'])
        self.assertEqual(release, result['release'])
        self.assertEqual({'base_site_newer_migrations': ['20261109000000'], 'prior_import_id_rows': 7}, result['base_site'])
        self.assertNotIn('999', json.dumps(result))

    def test_review_base_default_explicit_fresh_and_missing_input(self):
        self.auto_label = False
        self.create()
        self.base_backup()
        labelled = self.label('base_site')
        input_id = labelled['input']['input_id']
        original = self.control
        calls = []
        def control(argv, input=None, timeout=120):
            if argv[:3] == ['standard', 'plan', 'propose']:
                calls.append(argv)
                base = {'input_id': input_id, 'delivery': {'kind': 'base_site', 'version': 1},
                        'schema_version': 100, 'site_schema_version': 90, 'ahead': True}
                return json.dumps({'base_site': base if '--base-site' in argv else None})
            return original(argv, input=input, timeout=timeout)
        self.control = control
        run = 'run-' + 'a' * 32
        result = self.op('plan_propose', from_run=run)
        self.assertEqual(['--base-site', input_id], calls[-1][-2:])
        self.assertIn('on Base site v1', result['next'])
        self.assertIn('Normal for hosted sandboxes', result['next'])
        result = self.op('plan_propose', from_run=run, fresh_site=True)
        self.assertNotIn('--base-site', calls[-1])
        self.assertIn('on a fresh site', result['next'])
        self.op('plan_propose', from_run=run, base_site=input_id)
        self.assertEqual(['--base-site', input_id], calls[-1][-2:])
        self.refused('STANDARD_ARGUMENTS_INVALID', 'plan_propose', from_run=run, base_site=input_id, fresh_site=False)
        self.refused('STANDARD_BASE_SITE_INVALID', 'plan_propose', from_run=run, base_site='input-' + 'f' * 32)
        self.refused('STANDARD_BASE_SITE_ROLE', 'plan_propose', from_run=run, reconciliation=input_id)
        state = self.base / 'arc/.silo-migrate/named/state.json'
        doc = json.loads(state.read_text()); doc['inputs'] = {}; state.write_text(json.dumps(doc))
        self.refused('STANDARD_BASE_SITE_NOT_TAKEN', 'plan_propose', from_run=run)

    def test_review_runtime_preparation_is_pending_not_a_plan_or_started_import(self):
        self.create()
        original = self.control
        def control(argv, input=None, timeout=120):
            if argv[:3] == ['standard', 'plan', 'propose']:
                return json.dumps({'status': 'runtime_preparing'})
            return original(argv, input=input, timeout=timeout)
        self.control = control
        result = self.op('plan_propose', from_run='run-' + 'a' * 32)
        self.assertEqual('runtime_preparing', result['status'])
        self.assertNotIn('plan_id', result)
        self.assertIn('No customer data', result['next'])
        self.assertIn('Poll this same proposal', result['next'])

    # -- merge projects (source platform discourse) ----------------------------------------

    SOURCE_BACKUP = 'invented-source-v2026-11-0-latest-20261104011110.tar.gz'

    def merge_project(self):
        """A discourse project with the source site's backup and the Base site taken."""
        self.auto_label = False
        self.op('create', platform='discourse')
        (self.intake / self.SOURCE_BACKUP).write_bytes(gzip.compress(b'invented archive bytes'))
        self.label('development')
        source = self.op('take', path=self.SOURCE_BACKUP, type='discourse-backup')['input_id']
        self.base_backup()
        return source, self.label('base_site')['input']['input_id']

    def merge_control(self, calls, base, layer=None):
        original = self.control

        def control(argv, input=None, timeout=120):
            if argv[:3] == ['standard', 'plan', 'propose']:
                calls.append((argv, timeout))
                return json.dumps({'version': 1, 'plan_id': 'plan-' + 'e' * 32, 'digest': 'f' * 64, 'status': 'proposed', 'operation': 'standard_merge',
                                   'roles': {'source': argv[argv.index('--source') + 1], 'base_site': base}, 'converter_revision': 'a' * 40,
                                   'base_site': {'input_id': base, 'delivery': {'kind': 'base_site', 'version': 1}, 'schema_version': 100, 'site_schema_version': 100, 'ahead': False},
                                   'merge': {'layer': layer or {'present': False}, 'settings': '--settings' in argv, 'options': {}},
                                   'instances': {'review': {'name': 'private', 'hostname': 'private', 'port': 4200}}, 'private': 'not passed on'})
            if argv == ['standard', 'converter', 'refresh', 'arc', '--if-changed']:
                calls.append((argv, timeout))
                return json.dumps({'version': 1, 'commit': 'a' * 40, 'branch': 'migration/arc/merge-layer', 'dirty': False})
            return original(argv, input=input, timeout=timeout)
        self.control = control

    def test_a_merge_source_is_a_full_discourse_backup_in_a_discourse_project(self):
        self.create()  # a converter project
        (self.intake / self.SOURCE_BACKUP).write_bytes(gzip.compress(b'invented full backup'))
        self.refused('STANDARD_MERGE_SOURCE_INVALID', 'take', path=self.SOURCE_BACKUP, type='discourse-backup')
        self.assertTrue((self.intake / self.SOURCE_BACKUP).exists())
        self.refused('STANDARD_MERGE_NOT_DISCOURSE', 'merge_propose')

    def test_a_merge_source_keeps_its_backup_name(self):
        self.op('create', platform='discourse')
        for name in ('backup.tar.gz', 'site-v2026-11-0-latest-20261104011110.sql.gz'):
            (self.intake / name).write_bytes(b'x')
            self.refused('STANDARD_MERGE_SOURCE_INVALID', 'take', path=name, type='discourse-backup')
        (self.intake / self.SOURCE_BACKUP).write_bytes(gzip.compress(b'invented full backup'))
        self.refused('STANDARD_MERGE_SOURCE_INVALID', 'take', path=self.SOURCE_BACKUP, type='discourse-backup', name='renamed.tar.gz')
        self.assertTrue(self.op('take', path=self.SOURCE_BACKUP, type='discourse-backup')['input_id'].startswith('input-'))

    def test_merge_propose_uses_the_registered_source_and_base_site(self):
        source, base = self.merge_project()
        calls = []
        self.merge_control(calls, base)
        result = self.op('merge_propose')
        propose = ['standard', 'plan', 'propose', 'arc', '--operation', 'merge', '--source', source, '--base-site', base]
        self.assertEqual([['standard', 'converter', 'refresh', 'arc', '--if-changed'], propose], [argv for argv, _ in calls])
        self.assertLessEqual(sum(timeout for _, timeout in calls), 285)
        self.assertEqual(('plan-' + 'e' * 32, 'standard_merge', 'migration/arc/merge-layer', {'review': {'port': 4200}}),
                         (result['plan_id'], result['operation'], result['converter_branch'], result['instances']))
        self.assertNotIn('private', json.dumps(result))
        self.assertIn("Discourse's own merger with no project merge layer", result['next'])
        self.assertIn('Runs tab', result['next'])
        # Options and a settings input are passed on; a layer is named with its commit.
        settings = self.settings_input()
        calls.clear()
        self.merge_control(calls, base, layer={'present': True, 'path': 'mergers/arc/merger.rb', 'revision': 'c' * 40})
        result = self.op('merge_propose', source=source, base_site=base, settings=settings, ignore_global_pins=True,
                         separate_same_named_groups=True)
        self.assertEqual(propose + ['--settings', settings, '--ignore-global-pins', '--separate-same-named-groups'], calls[-1][0])
        self.assertIn('mergers/arc/merger.rb at ' + 'c' * 12, result['next'])
        self.assertTrue(result['merge']['settings'])

    def settings_input(self):
        """Register a merge-settings input the way migration-data would (a derived file)."""
        state = self.base / 'arc/.silo-migrate/named/state.json'
        doc = json.loads(state.read_text())
        input_id = 'input-' + '9' * 32
        doc['inputs'][input_id] = {'id': input_id, 'type': 'merge-settings', 'dataset_id': 'dataset-' + 'b' * 32}
        state.write_text(json.dumps(doc))
        return input_id

    def test_merge_propose_refuses_what_is_not_a_source_base_site_or_settings(self):
        source, base = self.merge_project()
        calls = []
        self.merge_control(calls, base)
        for code, request in (('STANDARD_MERGE_SOURCE_INVALID', {'source': base}), ('STANDARD_MERGE_SOURCE_INVALID', {'source': 'input-1 --x'}),
                              ('STANDARD_BASE_SITE_INVALID', {'base_site': source}), ('STANDARD_MERGE_SETTINGS_INVALID', {'settings': source}),
                              ('STANDARD_MERGE_SETTINGS_INVALID', {'settings': '--base-site'}), ('STANDARD_ARGUMENTS_INVALID', {'separate_same_named_groups': 'no'}),
                              ('STANDARD_ARGUMENTS_INVALID', {'ignore_global_pins': 1})):
            with self.subTest(request=request):
                self.refused(code, 'merge_propose', **request)
        self.assertEqual([], calls)

    def test_merge_propose_says_what_is_missing(self):
        self.auto_label = False
        self.op('create', platform='discourse')
        self.refused('STANDARD_MERGE_SOURCE_NOT_TAKEN', 'merge_propose')
        (self.intake / self.SOURCE_BACKUP).write_bytes(gzip.compress(b'invented full backup'))
        self.label('development')
        self.op('take', path=self.SOURCE_BACKUP, type='discourse-backup')
        self.refused('STANDARD_MERGE_BASE_SITE_MISSING', 'merge_propose')

    def test_guide_walks_a_merge_project(self):
        self.auto_label = False
        self.op('create', platform='discourse')
        self.assertNext('engineer', 'full backup (with uploads')
        (self.intake / self.SOURCE_BACKUP).write_bytes(gzip.compress(b'invented full backup'))
        self.label('development')
        guide = self.op('guide')
        self.assertNext('agent', 'type=discourse-backup', guide)
        self.assertEqual(['files', 'workspace', 'source', 'base', 'merge', 'release'], [stage['id'] for stage in guide['stages']])
        self.op('take', path=self.SOURCE_BACKUP, type='discourse-backup')
        guide = self.op('guide')
        self.assertEqual('base', guide['stage'])
        self.assertNext('engineer', 'label it Base site', guide)
        self.base_backup()
        self.label('base_site')
        guide = self.op('guide')
        self.assertEqual('merge', guide['stage'])
        self.assertNext('agent', 'data_merge_propose', guide)
        self.assertIn('merge layer', guide['next']['action'])
        run = {'run_id': 'run-' + '5' * 32, 'plan_id': 'plan-' + '5' * 32, 'kind': 'merge', 'stage': 'merge'}
        for state, who, text in ((dict(run, status='failed', failure={'code': 'STANDARD_MERGE_FAILED'}), 'agent', 'STANDARD_MERGE_FAILED'),
                                 (dict(run, status='abandoned'), 'engineer', 'Recover it'),
                                 (dict(run, status='completed'), 'engineer', 'release its backup')):
            with self.subTest(status=state['status']):
                self.guide_state(runs=[state])
                self.assertNext(who, text)
        self.guide_state(runs=[dict(run, status='completed')], sites=[{'role': 'review', 'run_id': run['run_id'], 'state': 'running'}])
        guide = self.op('guide')
        self.assertEqual(['files', 'workspace', 'source', 'base', 'merge'], self.stages(guide))
        self.assertNotIn(self.SOURCE_BACKUP, json.dumps(guide))

    def test_files_must_be_labelled_before_they_can_be_taken(self):
        self.auto_label = False
        self.create()
        self.drop('dump.sql', DUMP)
        self.refused('STANDARD_DELIVERY_UNLABELLED', 'take', path='dump.sql', type='mysql-dump')
        self.assertTrue((self.intake / 'dump.sql').is_file())
        self.assertEqual('Development v1', self.label('development')['delivery'])
        self.assertEqual('ok', 'ok' if self.op('take', path='dump.sql', type='mysql-dump')['input_id'] else '')
        self.assertFalse((self.intake / 'dump.sql').exists())

    def test_a_file_changed_after_labelling_is_no_longer_labelled(self):
        self.auto_label = False
        self.create()
        self.drop('dump.sql', DUMP)
        self.label('development')
        self.drop('dump.sql', DUMP + '-- edited\n')
        self.refused('STANDARD_DELIVERY_UNLABELLED', 'take', path='dump.sql', type='mysql-dump')
        self.assertEqual(['dump.sql'], [item['path'] for item in self.listing()])

    def test_each_delivery_is_its_own_dataset_with_its_own_version(self):
        self.auto_label = False
        self.create()
        self.drop('one.sql', DUMP)
        first = self.label('development')
        self.assertEqual('dataset-' + 'b' * 32, first['dataset_id'])  # the empty first dataset is used
        self.op('take', path='one.sql', type='mysql-dump')
        self.drop('two.sql', DUMP + '-- two\n')
        second = self.label('development')
        self.assertEqual('Development v2', second['delivery'])
        self.assertNotEqual(first['dataset_id'], second['dataset_id'])
        self.op('take', path='two.sql', type='mysql-dump')
        self.assertEqual([first['dataset_id'], second['dataset_id']], self.input_datasets())
        data = self.op('guide')['data']
        self.assertEqual(('Development v2', None), (data['development'], data['launch']))
        self.assertEqual({'Development v2': 'current', 'Development v1': 'replaced'}, {item['label']: item['state'] for item in data['deliveries']})

    def test_labelling_is_never_available_to_a_chat(self):
        self.create()
        self.drop('dump.sql', DUMP)
        for op, request in (('delivery_label', {'kind': 'development', 'by': 'x', 'files': []}), ('deliveries', {})):
            self.refused('STANDARD_DATA_OPERATION_REFUSED', op, via='chat', **request)
        self.assertFalse((self.base / 'arc/.silo-migrate/named/deliveries.json').exists())

    def test_launch_needs_a_typed_confirmation_and_a_second_must_say_it_replaces_the_first(self):
        self.auto_label = False
        self.create()
        self.drop('final.sql', DUMP)
        self.refused('STANDARD_DELIVERY_CONFIRM_LAUNCH', 'delivery_label', kind='launch', by='R', files=self.listing())
        self.refused('STANDARD_DELIVERY_CONFIRM_LAUNCH', 'delivery_label', kind='launch', by='R', files=self.listing(), confirm='yes')
        self.assertEqual('Launch', self.label('launch', confirm='LAUNCH')['delivery'])
        self.drop('final2.sql', DUMP + '-- newer\n')
        self.refused('STANDARD_DELIVERY_LAUNCH_EXISTS', 'delivery_label', kind='launch', by='R', confirm='LAUNCH', files=self.listing())
        self.assertEqual('launch', self.label('launch', confirm='LAUNCH', replaces_launch=True)['kind'])

    def test_a_label_is_refused_if_the_files_changed_since_the_page_loaded(self):
        self.create()
        self.drop('dump.sql', DUMP)
        seen = self.listing()
        self.drop('dump.sql', DUMP + '-- more\n')
        self.refused('STANDARD_DELIVERY_FILES_CHANGED', 'delivery_label', kind='development', by='R', files=seen)
        self.refused('STANDARD_DELIVERY_FILES_CHANGED', 'delivery_label', kind='development', by='R', files=[{'path': 'other.sql', 'bytes': 1, 'mtime_ns': 1}])
        self.refused('STANDARD_ARGUMENTS_INVALID: files', 'delivery_label', kind='development', by='R', files=[])
        self.refused('STANDARD_ARGUMENTS_INVALID: kind', 'delivery_label', kind='rehearsal', by='R', files=self.listing())
        self.refused('STANDARD_ARGUMENTS_INVALID: by', 'delivery_label', kind='development', by=' ', files=self.listing())

    def test_data_taken_before_labels_existed_is_labelled_once_and_first(self):
        self.create()
        self.drop('old.sql', DUMP)
        self.op('take', path='old.sql', type='mysql-dump')
        (self.base / 'arc/.silo-migrate/named/deliveries.json').unlink()  # as on a project from before labels
        dataset = self.input_datasets()[0]
        self.assertEqual([dataset], self.op('deliveries')['unlabelled_data'])
        self.assertNext('engineer', 'already in this project')
        self.drop('new.sql', DUMP + '-- new\n')
        self.refused('STANDARD_DELIVERY_LABEL_EXISTING_FIRST', 'delivery_label', kind='development', by='R', files=self.listing())
        self.refused('STANDARD_ARGUMENTS_INVALID: dataset_id', 'delivery_label', kind='launch', by='R', confirm='LAUNCH', dataset_id=dataset)
        self.refused('STANDARD_ARGUMENTS_INVALID: dataset_id', 'delivery_label', kind='development', by='R', dataset_id='dataset-' + 'f' * 32)
        self.assertEqual('Development v1', self.op('delivery_label', kind='development', by='R', dataset_id=dataset)['delivery'])
        self.assertEqual([], self.op('deliveries')['unlabelled_data'])
        self.refused('STANDARD_ARGUMENTS_INVALID: dataset_id', 'delivery_label', kind='development', by='R', dataset_id=dataset)  # a label never changes
        self.assertEqual('Development v2', self.label('development')['delivery'])

    def test_launch_data_identical_to_a_development_delivery_is_stopped(self):
        self.auto_label = False
        self.create()
        self.drop('dev.sql', DUMP)
        self.label('development')
        self.op('take', path='dev.sql', type='mysql-dump')
        self.drop('final.sql', DUMP)
        self.label('launch', confirm='LAUNCH')
        self.refused('STANDARD_DELIVERY_SAME_AS_DEVELOPMENT', 'take', path='final.sql', type='mysql-dump')
        self.assertTrue((self.intake / 'final.sql').is_file())

    def test_launch_data_of_the_same_size_but_different_content_is_taken(self):
        self.auto_label = False
        self.create()
        self.drop('dev.sql', DUMP)
        self.label('development')
        self.op('take', path='dev.sql', type='mysql-dump')
        self.drop('final.sql', DUMP.replace('Distrib', 'distrib'))
        self.label('launch', confirm='LAUNCH')
        self.assertTrue(self.op('take', path='final.sql', type='mysql-dump')['input_id'])

    def test_the_guide_names_deliveries_but_never_their_files_and_the_page_view_does(self):
        self.auto_label = False
        self.create()
        self.drop('customer-name-export.sql', DUMP)
        self.assertIn('customer-name', json.dumps(self.op('deliveries')))
        self.assertNotIn('customer-name', json.dumps(self.op('guide')))
        self.label('development')
        printed = json.dumps(self.op('guide'))
        self.assertNotIn('customer-name', printed)
        self.assertIn('Development v1', printed)

    def two_deliveries(self):
        """Development v1 and Launch, each with one file taken. Returns their dataset IDs."""
        self.auto_label = False
        self.create()
        self.drop('dev.sql', DUMP)
        dev = self.label('development')['dataset_id']
        self.op('take', path='dev.sql', type='mysql-dump')
        self.drop('final.sql', DUMP + '-- final\n')
        launch = self.label('launch', confirm='LAUNCH')['dataset_id']
        self.op('take', path='final.sql', type='mysql-dump')
        return dev, launch

    def finish(self, started):
        name = [argv for argv in self.docker.argvs('run') if any(started['job_id'][4:] in arg for arg in argv)][-1]
        self.docker.state[name[name.index('--name') + 1]] = {'Running': False, 'Status': 'exited', 'ExitCode': 0}
        self.op('job', job_id=started['job_id'])

    def test_a_script_reads_one_delivery_and_its_output_belongs_to_it(self):
        dev, launch = self.two_deliveries()
        ws = self.d.Workspace(self.base, 'arc', ROOT, self.host, self.values, self.control)
        self.assertEqual(dev, self.d.job_delivery(ws, {})[0])  # explicit active Development is the default
        self.refused('STANDARD_ARGUMENTS_INVALID: delivery', 'script', code='puts 1', into='x', delivery='dataset-' + 'f' * 32)
        started = self.op('script', code='puts 1', into='fromdev', delivery=dev)
        argv = ' '.join(self.docker.argvs('run')[-1])
        self.assertIn('dst=/in/dev.sql,readonly', argv)
        self.assertNotIn('final.sql', argv)
        self.assertNotIn('dst=/in,', argv)
        (self.base / 'arc/work/fromdev/out.sql').write_text('x')
        self.finish(started)
        result = self.op('register', path='fromdev/out.sql', type='derived-sql')
        datasets = {record['id']: record['dataset_id'] for record in json.loads((self.base / 'arc/.silo-migrate/named/state.json').read_text())['inputs'].values()}
        self.assertEqual(dev, datasets[result['input_id']])
        # Its derived files are part of that delivery from now on, and only of that one.
        self.op('script', code='puts 2', into='again', delivery=dev)
        self.assertIn('dst=/in/derived/fromdev-out.sql,readonly', ' '.join(self.docker.argvs('run')[-1]))

    def test_the_output_of_a_job_from_before_labels_cant_be_registered(self):
        self.create()
        started = self.op('script', code='puts 1', into='old')  # no labels yet: reads everything, as before
        self.assertIn('dst=/in,readonly', ' '.join(self.docker.argvs('run')[-1]))
        (self.base / 'arc/work/old/out.sql').write_text('x')
        self.finish(started)
        self.drop('dev.sql', DUMP)
        self.op('take', path='dev.sql', type='mysql-dump')  # labels now exist
        self.refused('STANDARD_DELIVERY_UNLABELLED', 'register', path='old/out.sql', type='derived-sql')

    def test_extract_reads_only_its_archives_delivery(self):
        dev, _launch = self.two_deliveries()
        self.op('extract', path='inputs/dev.sql', into='unpacked')
        argv = ' '.join(self.docker.argvs('run')[-1])
        self.assertIn('dst=/in/dev.sql,readonly', argv)
        self.assertNotIn('final.sql', argv)

    def test_db_load_records_which_delivery_is_in_the_database(self):
        dev, _launch = self.two_deliveries()
        state = self.base / 'arc/.silo-migrate/data/db/state.json'
        self.op('db_up', engine='mariadb')
        self.op('db_load', path='inputs/dev.sql')
        self.assertEqual(dev, json.loads(state.read_text())['loads'][-1]['dataset_id'])

    def test_a_replaced_file_with_the_same_size_and_time_is_not_labelled(self):
        self.auto_label = False
        self.create()
        self.drop('dump.sql', DUMP)
        self.label('development')
        original = (self.intake / 'dump.sql').stat()
        (self.intake / 'new.tmp').write_text(DUMP.replace('Distrib', 'distrib'))
        os.utime(self.intake / 'new.tmp', ns=(original.st_atime_ns, original.st_mtime_ns))
        os.replace(self.intake / 'new.tmp', self.intake / 'dump.sql')
        self.refused('STANDARD_DELIVERY_UNLABELLED', 'take', path='dump.sql', type='mysql-dump')

    def test_a_taken_file_cant_be_claimed_again_and_a_replaced_launch_holds_nothing(self):
        self.auto_label = False
        self.create()
        self.drop('final.sql', DUMP)
        first = self.label('launch', confirm='LAUNCH')
        self.drop('other.sql', DUMP + '-- other\n')
        self.label('launch', confirm='LAUNCH', replaces_launch=True)
        self.refused('STANDARD_DELIVERY_UNLABELLED', 'take', path='final.sql', type='mysql-dump')  # its label went with the old launch
        self.op('take', path='other.sql', type='mysql-dump')
        records = json.loads((self.base / 'arc/.silo-migrate/named/deliveries.json').read_text())['deliveries']
        self.assertTrue(records[first['dataset_id']]['replaced_by'])
        self.assertTrue(all(entry.get('taken') for record in records.values() if not record.get('replaced_by') for entry in record['files']))

    def test_an_interrupted_take_cant_carry_an_unlabelled_file_in(self):
        self.auto_label = False
        self.create()
        self.drop('dump.sql', DUMP)
        dataset = self.label('development')['dataset_id']
        pending = self.d.pending_for(self.d.Workspace(self.base, 'arc', ROOT, self.host, self.values, self.control), 'inputs/dump.sql')
        pending.write_text(json.dumps({'dev': 1, 'ino': 1, 'provenance': {'event': 'take', 'dataset_id': dataset}}))
        self.drop('other.sql', DUMP + '-- other\n')
        self.refused('STANDARD_DELIVERY_UNLABELLED', 'take', path='other.sql', type='mysql-dump', name='dump.sql')
        self.assertTrue((self.intake / 'other.sql').exists())

    def test_development_data_identical_to_launch_is_stopped_too_and_the_guide_asks_to_remove_it(self):
        self.auto_label = False
        self.create()
        self.drop('final.sql', DUMP)
        self.label('launch', confirm='LAUNCH')
        self.op('take', path='final.sql', type='mysql-dump')
        self.drop('dev.sql', DUMP)
        self.label('development')
        self.refused('STANDARD_DELIVERY_SAME_AS_LAUNCH', 'take', path='dev.sql', type='mysql-dump')
        self.refused('STANDARD_DELIVERY_SAME_AS_LAUNCH', 'take', path='dev.sql', type='mysql-dump')  # remembered
        guide = self.op('guide')
        self.assertNext('engineer', "can't be taken", guide)
        self.assertEqual(1, self.op('deliveries')['counts']['refused'])
        self.assertNotIn('dev.sql', json.dumps(guide))

    def test_files_not_handed_over_or_with_odd_names_cant_be_labelled(self):
        self.create()
        name = os.fsdecode(b'odd-\xff.sql')
        (self.intake / name).write_bytes(DUMP.encode())
        view = self.op('deliveries')
        self.assertEqual([], view['unlabelled_files'])
        self.assertEqual(1, len(view['not_ready_files']))
        self.assertIn('\ufffd', view['not_ready_files'][0]['path'])
        self.assertNext('engineer', 'silo intake arc')

    def test_marking_a_finding_done_is_for_the_engineer_and_released_findings_only(self):
        self.create()
        state_file = self.base / 'arc/.silo-migrate/named/standard/state.json'
        state = json.loads(state_file.read_text())
        released, proposed = 'finding-' + 'a' * 32, 'finding-' + 'b' * 32
        state['findings'] = {released: {'status': 'released'}, proposed: {'status': 'proposed'}}
        state_file.write_text(json.dumps(state))
        self.refused('STANDARD_DATA_OPERATION_REFUSED', 'finding_done', finding_id=released, by='R', via='chat')
        self.refused('STANDARD_ARGUMENTS_INVALID: finding_id', 'finding_done', finding_id=proposed, by='R')
        self.refused('STANDARD_ARGUMENTS_INVALID: finding_id', 'finding_done', finding_id='x', by='R')
        self.assertTrue(self.op('finding_done', finding_id=released, by='Reviewer')['done'])
        marks = json.loads((self.base / 'arc/.silo-migrate/named/finding-progress.json').read_text())['done']
        self.assertEqual('Reviewer', marks[released]['by'])
        state['findings'][released]['status'] = 'superseded'  # corrected since: its mark can still be taken back
        state_file.write_text(json.dumps(state))
        self.assertFalse(self.op('finding_done', finding_id=released, by='Reviewer', undo=True)['done'])
        self.refused('STANDARD_ARGUMENTS_INVALID: finding_id', 'finding_done', finding_id=released, by='Reviewer')

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
        self.assertIn('Runs tab', result['next'])
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
