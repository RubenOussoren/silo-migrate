"""Synthetic standalone backend tests. Run python3 -I -B test/supporting_files_test.py."""
import base64
import contextlib
import hashlib
import importlib.util
import json
import os
import select
import signal
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'bin' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


backend = load('supporting_files')
helpers = load('data_tools')


class Workspace:
    def __init__(self, root):
        self.root = root
        self.name = 'synthetic'
        self.chat = False
        self.intake = root.parent / 'intake'
        self.intake.mkdir(mode=0o700)
        self.values = {}
        self.repo = ROOT
        self.root.mkdir(mode=0o700)
        self.data_dir()
        (self.root / '.silo-migrate').chmod(0o700)

    def data_dir(self, *parts):
        path = self.root / '.silo-migrate' / 'data'
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        for part in parts:
            path = path / part
            if path.is_symlink():
                raise helpers.Refusal('STANDARD_PATH_INVALID')
            path.mkdir(mode=0o700, exist_ok=True)
        return path

    def lock(self):
        return contextlib.nullcontext()

    def require(self, standard=True):
        assert standard is False

    def area_path(self, area):
        return self.intake if area == 'intake' else self.root / area

    def open_area(self, area):
        return helpers.open_root(self.area_path(area))

    def image(self, key):
        assert key == 'control'
        return 'sha256:' + 'a' * 64


class FakeDocker:
    def __init__(self):
        self.calls = []
        self.stdout = b'{"status":"ok","rows":[[{"type":"formula","value":"=1+1"}]]}'
        self.returncode = 0
        self.timeout = False
        self.cleanup_bad = False

    def __call__(self, argv, timeout=120):
        self.calls.append((argv, timeout))
        if argv[0] == 'run':
            if self.timeout:
                raise subprocess.TimeoutExpired('docker', timeout)
            return types.SimpleNamespace(returncode=self.returncode, stdout=self.stdout, stderr=b'/secret/path: private')
        return types.SimpleNamespace(returncode=0, stdout=b'container' if argv[0] == 'ps' and self.cleanup_bad else b'', stderr=b'')


class SupportingFilesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.ws = Workspace(self.base / 'project')
        self.uploads = self.base / 'uploads'
        self.uploads.mkdir(mode=0o700)
        patch = mock.patch.dict(os.environ, {'SILO_TESTING': '1', 'SILO_SUPPORT_UPLOADS_ROOT': str(self.uploads)})
        patch.start()
        self.addCleanup(patch.stop)
        self.docker = FakeDocker()
        self.api = types.SimpleNamespace(open_root=helpers.open_root, open_regular=helpers.open_regular,
                                         sandbox_argv=helpers.sandbox_argv, docker=self.docker, refuse=helpers.refuse)
        self.context = {'_private_session': True, '_session_id': 'chat-1', '_uploads': []}
        self.add_upload()
        self.sentinels = {}
        for relative in ('inputs/input.sql', 'converter/source.rb', '.silo-migrate/named/state.json',
                         '.silo-migrate/data/deliveries.json', 'settings.yml'):
            path = self.ws.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'unchanged')
            self.sentinels[path] = (path.read_bytes(), path.stat().st_mode)

    def add_upload(self, filename='reference.csv', data=b'name,value\na,=1+1\n', ref=None):
        ref = ref or ('%032x' % (len(self.context['_uploads']) + 1))
        path = self.uploads / ref
        path.write_bytes(data)
        path.chmod(0o600)
        item = dict(id=ref, path=str(path), filename=filename, media_type='text/plain', size_bytes=len(data))
        self.context['_uploads'].append(item)
        return item

    def call(self, op='supporting_list', **kwargs):
        return backend.handle(self.ws, dict(self.context, op=op, **kwargs), self.api)

    def take(self, **kwargs):
        return self.call('supporting_take', ref=self.context['_uploads'][0]['id'], **kwargs)['file']

    def refusal(self, code, op='supporting_list', **kwargs):
        with self.assertRaisesRegex(helpers.Refusal, '^STANDARD_SUPPORTING_' + code + '$'):
            self.call(op, **kwargs)

    def test_import_permissions_checksum_provenance_and_named_state_unchanged(self):
        item = self.take()
        self.assertRegex(item['id'], r'^support-[0-9a-f]{32}$')
        root = self.ws.data_dir() / 'supporting'
        for path in (root, root / 'index', root / 'files'):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
        path = root / 'files' / item['id']
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o400)
        self.assertEqual(item['sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
        meta = root / 'index' / (item['id'] + '.json')
        self.assertEqual(stat.S_IMODE(meta.stat().st_mode), 0o600)
        record = json.loads(meta.read_bytes())
        self.assertEqual(record['session_id'], 'chat-1')
        self.assertEqual(record['provenance'], 'private-session-upload')
        for path, original in self.sentinels.items():
            self.assertEqual((path.read_bytes(), path.stat().st_mode), original)
        self.assertEqual(self.docker.calls, [])

    def test_private_session_and_safe_session_required(self):
        for value in (False, None, 1, 'true'):
            with self.subTest(value=value):
                self.refusal('PRIVATE_SESSION_REQUIRED', _private_session=value)
        for session in ('../chat', '', '/tmp', 'x\n', 'a' * 129):
            self.refusal('PRIVATE_SESSION_REQUIRED', _session_id=session)

    def test_ref_public_key_and_legacy_alias_invalid(self):
        ref = self.context['_uploads'][0]['id']
        self.refusal('REF_INVALID', 'supporting_take', refid=ref)
        self.refusal('REF_INVALID', 'supporting_take', ref='../invalid', refid=ref)
        item = self.call('supporting_take', ref=ref)['file']
        metadata = self.ws.data_dir() / 'supporting/index' / (item['id'] + '.json')
        self.assertEqual(json.loads(metadata.read_bytes())['refid'], ref)
        self.assertEqual(stat.S_IMODE(metadata.stat().st_mode), 0o600)

    def test_tsv_maps_to_fixed_csv_reader(self):
        self.context['_uploads'] = []
        self.add_upload('Canonical Original Name.TSV', b'name\tvalue\na\t1\n')
        item = self.take()
        self.assertEqual(item['filename'], 'Canonical Original Name.TSV')
        self.call('supporting_read', id=item['id'], mode='rows')
        argv = self.docker.calls[0][0]
        self.assertEqual(argv[argv.index('--format') + 1], 'csv')
        self.assertIn('/silo/bin/supporting_reader.py', argv)

    def test_fixed_parser_error_mapping_and_invalid_codes(self):
        item = self.take()
        for returncode in (0, 1):
            self.docker.returncode = returncode
            for code in sorted(backend.PARSER_ERRORS):
                self.docker.stdout = json.dumps({'status': 'error', 'error': code,
                                                'untrusted_detail': '/secret/path'}).encode()
                self.refusal(code.removeprefix('STANDARD_SUPPORTING_'), 'supporting_read', id=item['id'])
        for code in ('STANDARD_SUPPORTING_UNKNOWN', 'STANDARD_SUPPORTING_IO\n',
                     'STANDARD_SUPPORTING_' + 'X' * 80, 'STANDARD_SUPPORTING_/secret',
                     'STANDARD_SUPPORTING_io', None, [], {'error': 'STANDARD_SUPPORTING_IO'}):
            self.docker.stdout = json.dumps({'status': 'error', 'error': code}).encode()
            self.refusal('PARSER_FAILED', 'supporting_read', id=item['id'])
        self.docker.stdout = json.dumps({'status': 'error', 'error': 'STANDARD_SUPPORTING_IO',
                                        'detail': 'x' * backend.MAX_OUTPUT}).encode()
        self.refusal('OUTPUT_LIMIT', 'supporting_read', id=item['id'])
        self.assertEqual(len(self.docker.calls) % 3, 0)

    def test_unknown_reference_and_id_injection(self):
        self.refusal('REF_NOT_AVAILABLE', 'supporting_take', ref='f' * 32)
        self.refusal('REF_INVALID', 'supporting_take', ref='../etc/passwd')
        self.refusal('ID_INVALID', 'supporting_read', id='../etc/passwd')
        self.refusal('NOT_FOUND', 'supporting_read', id='support-' + 'f' * 32)

    def test_shared_project_and_current_chat_refs(self):
        first = self.take()
        self.assertEqual(self.take(), first)
        self.context['_session_id'] = 'chat-2'
        self.context['_uploads'] = []
        result = self.call()
        self.assertEqual(result['files'], [first])
        self.assertEqual(result['available_refs'], [])
        self.refusal('REF_NOT_AVAILABLE', 'supporting_take', ref='0' * 31 + '1')
        self.assertEqual(self.call('supporting_read', id=first['id'])['status'], 'ok')
        self.add_upload()
        self.assertNotEqual(self.take()['id'], first['id'])

    def test_list_does_not_expose_paths_or_session(self):
        self.take()
        result = json.dumps(self.call())
        self.assertNotIn(str(self.base), result)
        self.assertNotIn('chat-1', result)
        self.assertIn('reference.csv', result)

    def test_source_must_be_exact_direct_path(self):
        item = self.context['_uploads'][0]
        for path in (str(self.uploads / '..' / 'uploads' / item['id']),
                     str(self.uploads / 'nested' / item['id']), '/etc/passwd', 'relative'):
            with self.subTest(path=path):
                self.refusal('PATH_INVALID', 'supporting_take', ref=item['id'],
                             _uploads=[dict(item, path=path)])

    def test_source_symlink_and_symlink_parent_refused(self):
        item = self.context['_uploads'][0]
        path = Path(item['path'])
        original = self.uploads / 'original'
        path.rename(original)
        path.symlink_to(original)
        with self.assertRaises(helpers.Refusal):
            self.take()
        alias = self.base / 'alias'
        alias.symlink_to(self.uploads, target_is_directory=True)
        with mock.patch.dict(os.environ, {'SILO_SUPPORT_UPLOADS_ROOT': str(alias)}):
            with self.assertRaises(helpers.Refusal):
                self.call('supporting_take', ref=item['id'], _uploads=[dict(item, path=str(alias / item['id']))])

    def test_source_nonregular_hardlink_groupwrite_and_wrongowner(self):
        path = Path(self.context['_uploads'][0]['path'])
        path.chmod(0o620)
        self.refusal('FILE_INVALID', 'supporting_take', ref=self.context['_uploads'][0]['id'])
        path.chmod(0o600)
        os.link(path, self.uploads / 'hardlink')
        self.refusal('FILE_INVALID', 'supporting_take', ref=self.context['_uploads'][0]['id'])
        (self.uploads / 'hardlink').unlink()
        real = self.api.open_regular
        def wrongowner(*args):
            fd, info = real(*args)
            fields = list(info)
            fields[4] = os.getuid() + 1
            return fd, os.stat_result(fields)
        self.api.open_regular = wrongowner
        self.refusal('FILE_INVALID', 'supporting_take', ref=self.context['_uploads'][0]['id'])
        self.api.open_regular = real
        path.unlink()
        os.mkfifo(path, 0o600)
        with self.assertRaises(helpers.Refusal):
            self.take()

    def test_filename_controls_and_separators(self):
        item = self.context['_uploads'][0]
        for name in ('../secret', 'x/y', 'x\\y', 'x\n', 'x\x7f', '', '.', '..', 'x' * 129):
            self.refusal('UPLOADS_INVALID', _uploads=[dict(item, filename=name)])

    def test_upload_caps(self):
        item = self.context['_uploads'][0]
        self.refusal('UPLOADS_INVALID', _uploads=[item] * 33)
        self.refusal('UPLOADS_INVALID', _uploads=[dict(item, size_bytes=backend.MAX_FILE + 1)])
        self.refusal('UPLOADS_INVALID', _uploads=[dict(item, arbitrary='x' * backend.MAX_RECORD)])
        self.refusal('UPLOADS_INVALID', _uploads=[item, item])

    def test_store_symlink_refused(self):
        (self.ws.data_dir() / 'supporting').symlink_to(self.uploads, target_is_directory=True)
        with self.assertRaises(helpers.Refusal):
            self.take()

    def test_checksum_and_permissions_verified_before_read(self):
        item = self.take()
        path = self.ws.data_dir() / 'supporting/files' / item['id']
        path.chmod(0o600)
        self.refusal('FILE_INVALID', 'supporting_read', id=item['id'])
        path.write_bytes(b'changed')
        path.chmod(0o400)
        self.refusal('CHECKSUM_MISMATCH', 'supporting_read', id=item['id'])
        self.assertEqual(self.docker.calls, [])

    def test_mutation_during_copy_refused(self):
        real = backend.os.read
        path = Path(self.context['_uploads'][0]['path'])
        def mutate(fd, size):
            data = real(fd, size)
            if data and os.fstat(fd).st_ino == path.stat().st_ino:
                path.write_bytes(b'altered')
            return data
        with mock.patch.object(backend.os, 'read', side_effect=mutate):
            self.refusal('FILE_CHANGED', 'supporting_take', ref=self.context['_uploads'][0]['id'])
        self.assertEqual(list((self.ws.data_dir() / 'supporting/files').iterdir()), [])

    def test_sandbox_fixed_reader_argv_and_no_named_inputs(self):
        item = self.take()
        result = self.call('supporting_read', id=item['id'], mode='rows', sheet='--evil', limit=100, columns=50)
        self.assertEqual(result['rows'][0][0]['type'], 'formula')
        argv, timeout = self.docker.calls[0]
        self.assertEqual(argv[:2], ['run', '--rm'])
        self.assertNotIn('-d', argv)
        self.assertLessEqual(timeout, 45)
        self.assertEqual(argv[argv.index('--network') + 1], 'none')
        self.assertIn('--read-only', argv)
        self.assertIn('--cpus', argv)
        self.assertIn('--memory', argv)
        self.assertIn('--pids-limit', argv)
        self.assertIn('/silo/bin/supporting_reader.py', argv)
        self.assertIn('--sheet=--evil', argv)
        self.assertIn('python3', argv)
        self.assertIn('-I', argv)
        mounts = [arg for arg in argv if arg.startswith('type=bind,')]
        self.assertEqual(len(mounts), 3)
        self.assertFalse(any('/inputs' in arg or 'delivery' in arg for arg in mounts))
        self.assertTrue(any('dst=/reference/input,readonly' in arg for arg in mounts))
        self.assertNotIn(str(self.uploads), repr(argv))
        name = argv[argv.index('--name') + 1]
        self.assertRegex(name, r'^silo-support-[0-9a-f]{32}$')
        self.assertEqual(self.docker.calls[1][0], ['rm', '-f', name])
        self.assertEqual(self.docker.calls[2][0], ['ps', '-aq', '--filter', 'name=^/' + name + '$'])
        self.assertFalse(list(self.ws.data_dir().glob('support-read-*')))

    def test_reader_limits(self):
        item = self.take()
        for args in ({'limit': 101}, {'columns': 51}, {'limit': True}, {'offset': -1},
                     {'sheet': 'x\n'}, {'mode': 'execute'}, {'columns': 0}):
            self.refusal('ARGUMENTS_INVALID', 'supporting_read', id=item['id'], **args)
        self.assertEqual(self.docker.calls, [])

    def test_failed_parser_cleanup_and_output_refusals(self):
        item = self.take()
        self.docker.returncode = 1
        self.refusal('PARSER_FAILED', 'supporting_read', id=item['id'])
        self.assertEqual(len(self.docker.calls), 3)
        self.docker.returncode = 0
        for output, code in ((b'x' * (backend.MAX_OUTPUT + 1), 'OUTPUT_LIMIT'),
                             (b'/secret/path', 'PARSER_FAILED'), (b'[]', 'PARSER_FAILED'),
                             (b'{"status":"error","error":"private"}', 'PARSER_FAILED')):
            self.docker.stdout = output
            self.refusal(code, 'supporting_read', id=item['id'])

    def test_cleanup_absence_must_be_confirmed(self):
        item = self.take()
        self.docker.cleanup_bad = True
        self.refusal('CLEANUP_FAILED', 'supporting_read', id=item['id'])
        self.docker.timeout = True
        self.refusal('CLEANUP_FAILED', 'supporting_read', id=item['id'])

    def test_timeout_is_sanitized_and_cleaned(self):
        item = self.take()
        self.docker.timeout = True
        self.refusal('PARSER_FAILED', 'supporting_read', id=item['id'])
        self.assertEqual([argv[0] for argv, timeout in self.docker.calls], ['run', 'rm', 'ps'])

    def test_text_head_and_unsupported_binary(self):
        self.context['_uploads'] = []
        self.add_upload('reference.md', b'a' * 20000)
        item = self.take()
        result = self.call('supporting_read', id=item['id'], mode='text')
        self.assertEqual(len(result['text']), 16384)
        self.assertTrue(result['truncated'])
        self.context['_uploads'] = []
        self.add_upload('file.bin', b'\xff\x00', ref='f' * 32)
        item = self.take()
        self.refusal('UNSUPPORTED', 'supporting_read', id=item['id'], mode='text')
        self.assertEqual(self.docker.calls, [])

    def test_registered_count_and_total_limits(self):
        self.take()
        with mock.patch.object(backend, 'MAX_TOTAL', 1):
            self.refusal('LIMIT')
        root = self.ws.data_dir() / 'supporting/index'
        for number in range(101):
            (root / ('junk-%s' % number)).write_text('{}')
        self.refusal('LIMIT')

    def test_metadata_cap_and_corruption(self):
        self.take()
        path = next((self.ws.data_dir() / 'supporting/index').iterdir())
        path.write_bytes(b'x' * (backend.MAX_RECORD + 1))
        self.refusal('INDEX_INVALID')
        path.write_text('{}')
        self.refusal('INDEX_INVALID')

    def test_text_limits_utf8_and_binary_refusal(self):
        self.context['_uploads'] = []
        self.add_upload('note.txt', b'\xff')
        item = self.take()
        self.refusal('UNSUPPORTED', 'supporting_read', id=item['id'])
        self.context['_uploads'] = []
        self.add_upload('note.txt', b'valid', ref='e' * 32)
        item = self.take()
        self.refusal('ARGUMENTS_INVALID', 'supporting_read', id=item['id'], limit=101)
        self.refusal('ARGUMENTS_INVALID', 'supporting_read', id=item['id'], columns=51)

    def test_source_actual_size_and_root_permissions(self):
        item = self.context['_uploads'][0]
        self.refusal('FILE_CHANGED', 'supporting_take', ref=item['id'],
                     _uploads=[dict(item, size_bytes=0)])
        with Path(item['path']).open('wb') as stream:
            stream.truncate(backend.MAX_FILE + 1)
        self.refusal('FILE_INVALID', 'supporting_take', ref=item['id'])
        self.uploads.chmod(0o770)
        self.refusal('PATH_INVALID', 'supporting_take', ref=item['id'])

    def test_bounded_list_and_import_quota(self):
        item = self.take()
        root = self.ws.data_dir() / 'supporting/index'
        original = json.loads((root / (item['id'] + '.json')).read_bytes())
        for number in range(99):
            record = dict(original, id='support-%032x' % number, filename='é' * 64,
                          refid='%032x' % (number + 10))
            path = root / (record['id'] + '.json')
            path.write_text(json.dumps(record))
            path.chmod(0o600)
        result = self.call()
        self.assertTrue(result['has_more'])
        self.assertLessEqual(len(backend.encoded(result)), backend.MAX_OUTPUT)
        self.add_upload(ref='f' * 32)
        self.refusal('LIMIT', 'supporting_take', ref='f' * 32)

    def test_snapshot_is_checksum_verified_and_only_mount_is_selected_copy(self):
        item = self.take()
        original = self.ws.data_dir() / 'supporting/files' / item['id']
        real_sandbox = self.api.sandbox_argv
        def sandbox(ws, name, out, mounts, command, inputs=None):
            snapshot = mounts[0][0]
            self.assertNotEqual(snapshot, original)
            self.assertEqual(hashlib.sha256(snapshot.read_bytes()).hexdigest(), item['sha256'])
            self.assertEqual(stat.S_IMODE(snapshot.stat().st_mode), 0o400)
            original.chmod(0o600)
            original.write_bytes(b'changed after snapshot')
            original.chmod(0o400)
            self.assertEqual(hashlib.sha256(snapshot.read_bytes()).hexdigest(), item['sha256'])
            return real_sandbox(ws, name, out, mounts, command, inputs=inputs)
        self.api.sandbox_argv = sandbox
        self.ws.values['SILO_CONTROL_GEMS'] = str(self.uploads)
        self.call('supporting_read', id=item['id'])
        self.assertFalse(any('/gems' in arg for arg in self.docker.calls[0][0]))
        self.refusal('CHECKSUM_MISMATCH', 'supporting_read', id=item['id'])

    def test_test_override_requires_testing_flag(self):
        with mock.patch.dict(os.environ, {'SILO_TESTING': '0', 'XDG_DATA_HOME': str(self.base / 'xdg')}):
            self.assertEqual(backend.upload_root(), self.base / 'xdg/term-llm/uploads')
        with mock.patch.dict(os.environ, {}, clear=True):
            import pwd
            self.assertEqual(backend.upload_root(), Path(pwd.getpwuid(os.getuid()).pw_dir) / '.local/share/term-llm/uploads')


class EngineerReferenceTest(SupportingFilesTest):
    # Inherit the native-session regressions with the same fixture workspace.
    def reference(self, area='intake', path='notes/reference.txt', data=b'invented reference', origin='file-123'):
        source = self.ws.area_path(area) / path
        source.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        source.write_bytes(data)
        for directory in (source.parent, self.ws.area_path(area)):
            directory.chmod(0o700)
        source.chmod(0o600 if area == 'intake' else 0o400)
        request = dict(area=area, path=path, origin_id=origin, by='Engineer Example')
        if area == 'intake':
            request['identity'] = backend.source_identity(source.stat(), path)
        else:
            request['sha256'] = hashlib.sha256(data).hexdigest()
            state = {'inputs': {'input-' + 'a' * 32: {
                'path': base64.b64encode(('inputs/' + path).encode()).decode(),
                'sha256': request['sha256'], 'bytes': len(data), 'dataset_id': 'dataset-invented'}}}
            state_path = self.ws.root / '.silo-migrate/named/state.json'
            state_path.parent.chmod(0o700)
            state_path.parent.parent.chmod(0o700)
            state_path.write_text(json.dumps(state))
            state_path.chmod(0o600)
        return source, request

    def admit(self, request):
        with self.ws.lock():
            return backend.admit_reference(self.ws, request, self.api)

    def denied(self, request, code=None):
        with self.assertRaises(helpers.Refusal) as caught:
            self.admit(request)
        if code:
            self.assertEqual(str(caught.exception), code)
        return str(caught.exception)

    def assert_empty(self):
        for child in ('files', 'index'):
            root = self.ws.data_dir() / 'supporting' / child
            self.assertFalse(root.exists() and list(root.iterdir()))

    def test_engineer_intake_private_copy_and_native_visibility(self):
        source, request = self.reference()
        before = (source.read_bytes(), backend.stamp(source.stat()))
        result = self.admit(request)
        self.assertFalse(result['already_registered'])
        item = result['file']
        blob = self.ws.data_dir() / 'supporting/files' / item['id']
        self.assertEqual(blob.read_bytes(), before[0])
        self.assertEqual(stat.S_IMODE(blob.stat().st_mode), 0o400)
        self.assertEqual((source.read_bytes(), backend.stamp(source.stat())), before)
        record = json.loads((self.ws.data_dir() / 'supporting/index' / (item['id'] + '.json')).read_bytes())
        self.assertEqual(record['provenance'], 'engineer-file-reference')
        self.assertEqual(record['origin_id'], request['origin_id'])
        self.assertEqual(record['actor'], request['by'])
        self.assertEqual(record['source']['identity'], request['identity'])
        self.assertNotIn('session_id', record)
        chat = self.take()
        self.assertEqual({f['id'] for f in self.call()['files']}, {item['id'], chat['id']})
        self.assertEqual(self.call('supporting_read', id=item['id'])['text'], before[0].decode())
        for path, original in self.sentinels.items():
            self.assertEqual((path.read_bytes(), path.stat().st_mode), original)

    def test_registered_original_preserved_and_provenance(self):
        source, request = self.reference(area='inputs', path='original/é reference.txt')
        before = {p: (p.read_bytes(), backend.stamp(p.stat())) for p in
                  (source, self.ws.root / '.silo-migrate/named/state.json', self.ws.data_dir() / 'deliveries.json')}
        result = self.admit(request)
        self.assertEqual(self.admit(request), dict(result, already_registered=True))
        record = json.loads((self.ws.data_dir() / 'supporting/index' / (result['file']['id'] + '.json')).read_bytes())
        self.assertEqual(record['source']['registered'], {'input_id': 'input-' + 'a' * 32, 'sha256': request['sha256']})
        for path, value in before.items():
            self.assertEqual((path.read_bytes(), backend.stamp(path.stat())), value)

    def test_engineer_gate_cannot_be_spoofed_by_session_fields(self):
        _, request = self.reference()
        self.ws.chat = True
        self.denied(dict(request, **self.context), 'STANDARD_DATA_OPERATION_REFUSED')
        self.assert_empty()
        self.ws.chat = False
        # An engineer reference is not an alternative admission token to native tools.
        with self.assertRaisesRegex(helpers.Refusal, '^STANDARD_SUPPORTING_PRIVATE_SESSION_REQUIRED$'):
            backend.handle(self.ws, dict(request, op='supporting_list'), self.api)
        self.refusal('PRIVATE_SESSION_REQUIRED', _private_session=False, **request)
        self.refusal('OPERATION_INVALID', 'admit_reference', **request)

    def test_reference_paths_and_arguments(self):
        _, request = self.reference()
        for path in ('/etc/passwd', '../notes/reference.txt', 'notes/../reference.txt',
                     'notes//reference.txt', './notes/reference.txt', 'notes/reference.txt/',
                     'notes/secret\\file', 'notes/evil\x00.txt'):
            with self.subTest(path=path):
                self.denied(dict(request, path=path), 'STANDARD_SUPPORTING_ARGUMENTS_INVALID')
        for key, value in (('area', 'work'), ('area', 'host'), ('origin_id', '../x'),
                           ('origin_id', 'x' * 129), ('by', ''), ('by', 'actor\n')):
            self.denied(dict(request, **{key: value}), 'STANDARD_SUPPORTING_ARGUMENTS_INVALID')
        self.assert_empty()

    def test_reference_requires_exact_identity(self):
        _, request = self.reference()
        self.denied(dict(request, identity=None), 'STANDARD_SUPPORTING_IDENTITY_INVALID')
        for key in ('bytes', 'mtime_ns', 'ctime_ns', 'ino', 'path'):
            value = request['identity'][key]
            changed = value + 1 if type(value) is int else value + '1'
            self.denied(dict(request, identity=dict(request['identity'], **{key: changed})),
                        'STANDARD_SUPPORTING_FILE_CHANGED' if key != 'path' else 'STANDARD_SUPPORTING_IDENTITY_INVALID')
        self.assert_empty()

    def test_inputs_require_registered_exact_decoded_path_and_sha(self):
        source, request = self.reference(area='inputs')
        state_path = self.ws.root / '.silo-migrate/named/state.json'
        original = json.loads(state_path.read_bytes())
        record = original['inputs']['input-' + 'a' * 32]
        for path in ('inputs/notes/other.txt', 'inputs/notes/../notes/reference.txt',
                     'notes/reference.txt', str(source), 'inputs//notes/reference.txt'):
            record['path'] = base64.b64encode(path.encode()).decode()
            state_path.write_text(json.dumps(original))
            self.denied(request, 'STANDARD_SUPPORTING_INPUT_NOT_REGISTERED')
        record['path'] = base64.b64encode(('inputs/' + request['path']).encode()).decode()
        state_path.write_text(json.dumps(original))
        self.denied(dict(request, sha256='0' * 64), 'STANDARD_SUPPORTING_CHECKSUM_MISMATCH')
        source.chmod(0o600)
        source.write_bytes(b'wrong actual content')
        source.chmod(0o400)
        self.denied(request, 'STANDARD_SUPPORTING_CHECKSUM_MISMATCH')
        self.assert_empty()

    def test_symlink_hardlink_and_untrusted_directories(self):
        source, request = self.reference()
        source.unlink()
        source.symlink_to(self.uploads / self.context['_uploads'][0]['id'])
        self.denied(request)
        source.unlink()
        os.link(self.uploads / self.context['_uploads'][0]['id'], source)
        self.denied(request, 'STANDARD_SUPPORTING_FILE_INVALID')
        source.unlink()
        source, request = self.reference()
        source.parent.chmod(0o770)
        self.denied(request, 'STANDARD_SUPPORTING_PATH_INVALID')
        source.parent.chmod(0o700)
        source.parent.rename(source.parent.with_name('moved'))
        source.parent.symlink_to(source.parent.with_name('moved'), target_is_directory=True)
        self.denied(request)
        self.assert_empty()

    def test_area_root_and_ancestor_symlinks_and_owner(self):
        source, request = self.reference()
        root = self.ws.intake
        root.rename(root.with_name('other-intake'))
        root.symlink_to(root.with_name('other-intake'), target_is_directory=True)
        self.denied(request)
        root.unlink()
        root.with_name('other-intake').rename(root)
        root.chmod(0o770)
        self.denied(request, 'STANDARD_SUPPORTING_PATH_INVALID')
        root.chmod(0o700)
        real = self.api.open_regular
        def wrong_owner(*args):
            fd, info = real(*args)
            values = {key: getattr(info, key) for key in dir(info) if key.startswith('st_')}
            values['st_uid'] = os.getuid() + 1
            return fd, types.SimpleNamespace(**values)
        with mock.patch.object(self.api, 'open_regular', side_effect=wrong_owner):
            self.denied(request, 'STANDARD_SUPPORTING_FILE_INVALID')
        self.assert_empty()

    def test_reference_retry_and_conflicting_identity_or_hash(self):
        source, request = self.reference()
        result = self.admit(request)
        self.assertEqual(self.admit(request), dict(result, already_registered=True))
        with mock.patch.object(backend, 'MAX_TOTAL', result['file']['size_bytes']):
            self.assertTrue(self.admit(request)['already_registered'])
        with mock.patch.object(backend, 'hash_checked', return_value='0' * 64):
            self.denied(request, 'STANDARD_SUPPORTING_REFERENCE_CONFLICT')
        source.write_bytes(b'changed reference')
        request['identity'] = backend.source_identity(source.stat(), request['path'])
        self.denied(request, 'STANDARD_SUPPORTING_REFERENCE_CONFLICT')
        _, other = self.reference(path='other.txt', origin=request['origin_id'])
        self.denied(other, 'STANDARD_SUPPORTING_REFERENCE_CONFLICT')
        self.assertEqual(len(list((self.ws.data_dir() / 'supporting/files').iterdir())), 1)

    def test_reference_quota_and_size(self):
        source, request = self.reference()
        with mock.patch.object(backend, 'MAX_TOTAL', 1):
            self.denied(request, 'STANDARD_SUPPORTING_LIMIT')
        with source.open('wb') as stream:
            stream.truncate(backend.MAX_FILE + 1)
        self.denied(request, 'STANDARD_SUPPORTING_FILE_INVALID')
        self.assert_empty()

    def test_mutation_and_path_swap_during_copy_cleaned_up(self):
        source, request = self.reference()
        original = backend.copy_checked
        def replaced(*args, **kwargs):
            result = original(*args, **kwargs)
            source.rename(source.with_name('old.txt'))
            source.write_bytes(b'substitute')
            source.chmod(0o600)
            return result
        with mock.patch.object(backend, 'copy_checked', side_effect=replaced):
            self.denied(request, 'STANDARD_SUPPORTING_FILE_CHANGED')
        self.assert_empty()
        source, request = self.reference()
        real_read = os.read
        def changed(fd, size):
            data = real_read(fd, size)
            if size == 1024 * 1024 and data:
                source.write_bytes(b'racing mutation')
            return data
        with mock.patch.object(backend.os, 'read', side_effect=changed):
            self.denied(request, 'STANDARD_SUPPORTING_FILE_CHANGED')
        self.assert_empty()

    def test_reference_registry_count_limit(self):
        item = self.take()
        root = self.ws.data_dir() / 'supporting/index'
        original = json.loads((root / (item['id'] + '.json')).read_bytes())
        for number in range(99):
            record = dict(original, id='support-%032x' % number, refid='%032x' % (number + 10))
            path = root / (record['id'] + '.json')
            path.write_text(json.dumps(record))
            path.chmod(0o600)
        _, request = self.reference()
        self.denied(request, 'STANDARD_SUPPORTING_LIMIT')
        self.assertEqual(len(list((self.ws.data_dir() / 'supporting/files').iterdir())), 1)

    def test_registered_state_symlink_and_hardlink_refused(self):
        _, request = self.reference(area='inputs')
        state = self.ws.root / '.silo-migrate/named/state.json'
        saved = state.with_name('original.json')
        state.rename(saved)
        state.symlink_to(saved)
        self.denied(request)
        state.unlink()
        os.link(saved, state)
        self.denied(request, 'STANDARD_SUPPORTING_FILE_INVALID')
        self.assert_empty()

    def test_reference_ancestor_and_root_swap(self):
        _, request = self.reference()
        self.base.chmod(0o770)
        self.denied(request, 'STANDARD_SUPPORTING_PATH_INVALID')
        self.base.chmod(0o700)
        def wrong_root(area):
            return helpers.open_root(self.uploads)
        with mock.patch.object(self.ws, 'open_area', side_effect=wrong_root):
            self.denied(request, 'STANDARD_SUPPORTING_FILE_CHANGED')
        self.assert_empty()

    def test_reference_publish_failure_removes_unindexed_blob(self):
        _, request = self.reference()
        real_open = os.open
        def fail_metadata(path, flags, *args, **kwargs):
            if isinstance(path, str) and path.startswith('support-') and path.endswith('.json'):
                raise OSError('invented metadata failure, never exposed')
            return real_open(path, flags, *args, **kwargs)
        with mock.patch.object(backend.os, 'open', side_effect=fail_metadata):
            self.denied(request, 'STANDARD_SUPPORTING_IO')
        self.assert_empty()

    def test_duplicate_origins_and_cross_branch_metadata_rejected(self):
        _, request = self.reference()
        result = self.admit(request)
        root = self.ws.data_dir() / 'supporting/index'
        path = root / (result['file']['id'] + '.json')
        original = json.loads(path.read_bytes())
        duplicate = dict(original, id='support-' + '0' * 32)
        other = root / (duplicate['id'] + '.json')
        other.write_text(json.dumps(duplicate))
        other.chmod(0o600)
        self.refusal('INDEX_INVALID')
        other.unlink()
        chat = self.take()
        chat_path = root / (chat['id'] + '.json')
        chat_record = json.loads(chat_path.read_bytes())
        chat_path.write_text(json.dumps(dict(chat_record, origin_id='file-invented')))
        self.refusal('INDEX_INVALID')

    def engineer_inventory(self):
        with self.ws.lock():
            return backend.engineer_list(self.ws, self.api)

    def test_engineer_inventory_public_all_provenances_and_archives(self):
        chat = self.take()
        _, request = self.reference()
        reference = self.admit(request)['file']
        # Inventory must not suppress archived rows or depend on the activity callback.
        self.api.reference_active = mock.Mock(side_effect=RuntimeError('not consulted'))
        rows = self.engineer_inventory()
        self.assertEqual({row['id'] for row in rows}, {chat['id'], reference['id']})
        for row in rows:
            self.assertEqual(set(row), {'id', 'filename', 'size_bytes', 'sha256'})
        self.api.reference_active.assert_not_called()
        for path, original in self.sentinels.items():
            self.assertEqual((path.read_bytes(), path.stat().st_mode), original)

    def test_engineer_inventory_empty_benign_init_and_gate_order(self):
        root = self.ws.data_dir() / 'supporting'
        self.assertFalse(root.exists())
        self.ws.chat = True
        with mock.patch.object(self.ws, 'require') as require:
            with self.assertRaisesRegex(helpers.Refusal, '^STANDARD_DATA_OPERATION_REFUSED$'):
                self.engineer_inventory()
            require.assert_not_called()
        self.assertFalse(root.exists())
        self.ws.chat = False
        with mock.patch.object(self.ws, 'require', side_effect=helpers.Refusal('STANDARD_NOT_INITIALIZED')) as require:
            with self.assertRaisesRegex(helpers.Refusal, '^STANDARD_NOT_INITIALIZED$'):
                self.engineer_inventory()
            require.assert_called_once_with(standard=False)
        self.assertFalse(root.exists())
        self.assertEqual(self.engineer_inventory(), [])
        for directory in (root, root / 'index', root / 'files'):
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)

    def test_engineer_inventory_uses_strict_store_and_index(self):
        item = self.take()
        path = self.ws.data_dir() / 'supporting/index' / (item['id'] + '.json')
        path.write_text('{}')
        with self.assertRaisesRegex(helpers.Refusal, '^STANDARD_SUPPORTING_INDEX_INVALID$'):
            self.engineer_inventory()
        path.unlink()
        path.symlink_to(self.uploads / self.context['_uploads'][0]['id'])
        with self.assertRaises(helpers.Refusal):
            self.engineer_inventory()
        path.unlink()
        root = self.ws.data_dir() / 'supporting'
        root.chmod(0o770)
        with self.assertRaisesRegex(helpers.Refusal, '^STANDARD_SUPPORTING_PATH_INVALID$'):
            self.engineer_inventory()

    def test_archived_reference_list_read_and_take_preserve_custody(self):
        chat = self.take()
        _, request = self.reference()
        reference = self.admit(request)['file']
        root = self.ws.data_dir() / 'supporting'
        originals = {path: (path.read_bytes(), backend.stamp(path.stat()))
                     for directory in (root / 'files', root / 'index') for path in directory.iterdir()}
        roles = {chat['id']: False, reference['id']: False}
        self.api.reference_active = lambda identity: roles.get(identity, True)
        self.assertEqual(self.call()['files'], [])
        self.refusal('INACTIVE', 'supporting_read', id=chat['id'])
        self.refusal('INACTIVE', 'supporting_read', id=reference['id'])
        self.refusal('INACTIVE', 'supporting_take', ref=self.context['_uploads'][0]['id'])
        for path, original in originals.items():
            self.assertEqual((path.read_bytes(), backend.stamp(path.stat())), original)
        self.assertEqual(len(self.engineer_inventory()), 2)
        # A trusted engineer's role change, not a chat retry, can make a row active.
        roles[reference['id']] = True
        self.assertEqual(self.call()['files'], [reference])
        self.assertEqual(self.call('supporting_read', id=reference['id'])['text'], 'invented reference')
        self.refusal('INACTIVE', 'supporting_take', ref=self.context['_uploads'][0]['id'])
        self.assertEqual(self.docker.calls, [])

    def test_inactive_read_refused_before_blob_open(self):
        item = self.take()
        (self.ws.data_dir() / 'supporting/files' / item['id']).unlink()
        self.api.reference_active = lambda identity: False
        self.refusal('INACTIVE', 'supporting_read', id=item['id'])

    def test_unknown_chat_references_default_active_via_role_authority(self):
        first = self.take()
        self.add_upload('second.txt', b'new chat reference', ref='f' * 32)
        self.api.reference_active = lambda identity: {first['id']: False}.get(identity, True)
        second = self.call('supporting_take', ref='f' * 32)['file']
        self.assertEqual(self.call()['files'], [second])
        self.assertEqual(self.call('supporting_read', id=second['id'])['text'], 'new chat reference')
        self.assertTrue(self.call('supporting_take', ref='f' * 32)['already_registered'])
        self.assertEqual(len(self.engineer_inventory()), 2)

    def test_activity_callback_is_internal_and_cannot_bypass_native_gate(self):
        item = self.take()
        self.api.reference_active = mock.Mock(return_value=False)
        # Model-supplied flags cannot override internal authority in either direction.
        for flags in ({'reference_active': True}, {'active': True}, {'_reference_active': True}):
            self.assertEqual(self.call(**flags)['files'], [])
            self.refusal('INACTIVE', 'supporting_read', id=item['id'], **flags)
            self.refusal('INACTIVE', 'supporting_take', ref=self.context['_uploads'][0]['id'], **flags)
        self.api.reference_active.reset_mock()
        self.refusal('PRIVATE_SESSION_REQUIRED', _private_session=False, reference_active=True)
        self.api.reference_active.assert_not_called()
        del self.api.reference_active
        self.assertEqual(self.call(reference_active=False, active=False)['files'], [item])

    def test_activity_callback_errors_and_nonboolean_results_fail_closed(self):
        item = self.take()
        for callback in (True, 'active', lambda identity: 1, lambda identity: 'true', lambda identity: None,
                         mock.Mock(side_effect=RuntimeError('/invented/private/path')),
                         mock.Mock(side_effect=helpers.Refusal('STANDARD_PRIVATE_DETAIL'))):
            with self.subTest(callback=callback):
                self.api.reference_active = callback
                self.refusal('REFERENCE_STATE_INVALID')
                self.refusal('REFERENCE_STATE_INVALID', 'supporting_read', id=item['id'])
                self.refusal('REFERENCE_STATE_INVALID', 'supporting_take', ref=self.context['_uploads'][0]['id'])
        self.api.reference_active = None
        self.assertEqual(self.call()['files'], [item])

    def asset_reference(self, origin='file-' + 'a' * 32):
        root = self.ws.data_dir() / 'file-role-assets'
        root.mkdir(mode=0o700, exist_ok=True)
        source = root / origin
        source.write_bytes(b'invented immutable XLSX fixture')
        source.chmod(0o400)
        request = dict(origin_id=origin, filename='original reference.xlsx',
                       sha256=hashlib.sha256(source.read_bytes()).hexdigest(), by='Engineer Example')
        return source, request

    def admit_asset(self, request):
        with self.ws.lock():
            return backend.admit_asset_reference(self.ws, request, self.api)

    def asset_denied(self, request, code=None):
        with self.assertRaises(helpers.Refusal) as caught:
            self.admit_asset(request)
        if code:
            self.assertEqual(str(caught.exception), code)

    def test_asset_reference_private_copy_retry_and_preservation(self):
        source, request = self.asset_reference()
        before = (source.read_bytes(), backend.stamp(source.stat()))
        result = self.admit_asset(request)
        self.assertFalse(result['already_registered'])
        self.assertEqual(self.admit_asset(request), dict(result, already_registered=True))
        item = result['file']
        blob = self.ws.data_dir() / 'supporting/files' / item['id']
        self.assertEqual(blob.read_bytes(), before[0])
        self.assertEqual(stat.S_IMODE(blob.stat().st_mode), 0o400)
        self.assertEqual((source.read_bytes(), backend.stamp(source.stat())), before)
        self.assertEqual(self.engineer_inventory(), [item])
        self.assertEqual(self.call()['files'], [item])
        record = json.loads((self.ws.data_dir() / 'supporting/index' / (item['id'] + '.json')).read_bytes())
        self.assertEqual(record['provenance'], 'engineer-asset-reference')
        self.assertEqual(record['source']['blob'], 'file-role-assets/' + request['origin_id'])
        self.assertEqual(record['source']['identity']['ino'], str(source.stat().st_ino))
        self.assertNotIn('session_id', record)
        for path, original in self.sentinels.items():
            self.assertEqual((path.read_bytes(), path.stat().st_mode), original)
        self.api.reference_active = lambda identity: False
        self.assertEqual(self.call()['files'], [])
        self.refusal('INACTIVE', 'supporting_read', id=item['id'])

    def test_asset_gate_fixed_root_and_request_validation(self):
        source, request = self.asset_reference()
        self.ws.chat = True
        self.asset_denied(dict(request, **self.context), 'STANDARD_DATA_OPERATION_REFUSED')
        self.ws.chat = False
        for change in ({'path': str(source)}, {'area': 'intake'}, {'origin_id': '../' + source.name},
                       {'origin_id': 'file-123'}, {'filename': '../original.xlsx'}, {'by': ''}):
            self.asset_denied(dict(request, **change), 'STANDARD_SUPPORTING_ARGUMENTS_INVALID')
        source.unlink()
        # Even a valid same-ID intake file cannot substitute for the immutable asset.
        (self.ws.intake / request['origin_id']).write_bytes(b'invented immutable XLSX fixture')
        self.asset_denied(request)
        self.assert_empty()

    def test_asset_symlinks_hardlinks_and_modes_refused(self):
        source, request = self.asset_reference()
        saved = source.with_name('saved')
        source.rename(saved)
        source.symlink_to(saved)
        self.asset_denied(request)
        source.unlink()
        os.link(saved, source)
        self.asset_denied(request, 'STANDARD_SUPPORTING_FILE_INVALID')
        source.unlink()
        saved.rename(source)
        source.chmod(0o600)
        self.asset_denied(request, 'STANDARD_SUPPORTING_FILE_INVALID')
        source.chmod(0o400)
        source.parent.chmod(0o750)
        self.asset_denied(request, 'STANDARD_SUPPORTING_PATH_INVALID')
        source.parent.chmod(0o700)
        parent = source.parent
        parent.rename(parent.with_name('asset-saved'))
        parent.symlink_to(parent.with_name('asset-saved'), target_is_directory=True)
        self.asset_denied(request)
        self.assert_empty()

    def test_asset_checksum_quota_and_race_cleanup(self):
        source, request = self.asset_reference()
        self.asset_denied(dict(request, sha256='0' * 64), 'STANDARD_SUPPORTING_CHECKSUM_MISMATCH')
        self.assert_empty()
        with mock.patch.object(backend, 'MAX_TOTAL', 1):
            self.asset_denied(request, 'STANDARD_SUPPORTING_LIMIT')
        original = backend.copy_checked
        def replaced(*args, **kwargs):
            result = original(*args, **kwargs)
            source.rename(source.with_name('old-asset'))
            source.write_bytes(b'replaced')
            source.chmod(0o400)
            return result
        with mock.patch.object(backend, 'copy_checked', side_effect=replaced):
            self.asset_denied(request, 'STANDARD_SUPPORTING_FILE_CHANGED')
        self.assert_empty()

    def test_asset_retry_conflicts_and_cross_kind_origin(self):
        source, request = self.asset_reference()
        self.admit_asset(request)
        self.asset_denied(dict(request, filename='renamed.xlsx'), 'STANDARD_SUPPORTING_REFERENCE_CONFLICT')
        self.asset_denied(dict(request, sha256='0' * 64), 'STANDARD_SUPPORTING_REFERENCE_CONFLICT')
        _, intake_request = self.reference(origin=request['origin_id'])
        self.denied(intake_request, 'STANDARD_SUPPORTING_REFERENCE_CONFLICT')
        _, other = self.asset_reference(origin='file-' + 'b' * 32)
        _, intake_request = self.reference(path='second.txt', origin=other['origin_id'])
        self.admit(intake_request)
        self.asset_denied(other, 'STANDARD_SUPPORTING_REFERENCE_CONFLICT')
        source.chmod(0o600)
        source.write_bytes(b'changed custody')
        source.chmod(0o400)
        self.asset_denied(request, 'STANDARD_SUPPORTING_REFERENCE_CONFLICT')

    def test_asset_strict_provenance_and_duplicate_origins(self):
        _, request = self.asset_reference()
        result = self.admit_asset(request)
        path = self.ws.data_dir() / 'supporting/index' / (result['file']['id'] + '.json')
        original = json.loads(path.read_bytes())
        for changed in (dict(original, session_id='fake'), dict(original, origin_id='file-123'),
                        dict(original, source=dict(original['source'], blob='/host/path')),
                        dict(original, source=dict(original['source'], device=1)),
                        dict(original, source=dict(original['source'], area='inputs'))):
            path.write_text(json.dumps(changed))
            self.refusal('INDEX_INVALID')
        path.write_text(json.dumps(original))
        duplicate = dict(original, id='support-' + '0' * 32)
        duplicate_path = path.parent / (duplicate['id'] + '.json')
        duplicate_path.write_text(json.dumps(duplicate))
        duplicate_path.chmod(0o600)
        self.refusal('INDEX_INVALID')
        duplicate_path.unlink()
        self.assertEqual(len(self.call()['files']), 1)

    def crash_take(self, mode, ref):
        # Real subprocess death bypasses Python finally/exception cleanup. Only
        # this fixture's synthetic paths and the module under test are accessed.
        script = r"""
import contextlib, importlib.util, json, os, signal, sys, types
from pathlib import Path
repo, project, mode, request = sys.argv[1:]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
module = load('crash_support', Path(repo) / 'bin/supporting_files.py')
helpers = load('crash_helpers', Path(repo) / 'bin/data_tools.py')
root = Path(project) / '.silo-migrate/data'
ws = types.SimpleNamespace(data_dir=lambda: root, require=lambda standard: None,
                           lock=lambda: helpers.Locked(root / 'lock'), chat=False)
api = types.SimpleNamespace(open_regular=helpers.open_regular, refuse=helpers.refuse)
if mode == 'preindex':
    module.publish = lambda *args: os._exit(71)
else:
    real_fdopen = module.os.fdopen
    class Stream:
        def __init__(self, inner): self.inner = inner
        def __getattr__(self, name): return getattr(self.inner, name)
        def __enter__(self): self.inner.__enter__(); return self
        def __exit__(self, *args): return self.inner.__exit__(*args)
        def write(self, data):
            metadata = data.startswith(b'{"id":"support-')
            if mode == 'partialblob' and not metadata:
                self.inner.write(data[:5]); self.inner.flush(); os._exit(72)
            if mode == 'metadata' and metadata:
                self.inner.write(data[:7]); self.inner.flush()
                print('READY', flush=True)
                while True: signal.pause()
            return self.inner.write(data)
    module.os.fdopen = lambda *args, **kwargs: Stream(real_fdopen(*args, **kwargs))
module.handle(ws, json.loads(request), api)
raise AssertionError('crash hook not reached')
"""
        request = dict(self.context, op='supporting_take', ref=ref)
        args = [sys.executable, '-I', '-B', '-c', script, str(ROOT), str(self.ws.root), mode, json.dumps(request)]
        if mode != 'metadata':
            result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
            self.assertEqual(result.returncode, 71 if mode == 'preindex' else 72, result.stderr.decode())
            return
        child = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            ready, _, _ = select.select([child.stdout], [], [], 15)
            self.assertTrue(ready, 'child did not reach the staged metadata write')
            self.assertEqual(child.stdout.readline(), b'READY\n')
            child.kill()
            _, errors = child.communicate(timeout=15)
            self.assertEqual(child.returncode, -signal.SIGKILL, errors.decode())
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate(timeout=15)
            child.stdout.close()
            child.stderr.close()

    def test_abrupt_death_preserves_prior_registry_and_charges_orphans(self):
        self.context['_uploads'] = []
        self.add_upload('prior.txt', b'prior registered reference')
        prior = self.take()
        for number, mode in enumerate(('partialblob', 'preindex', 'metadata'), 10):
            with self.subTest(mode=mode):
                upload = self.add_upload('interrupted.txt', b'invented interrupted source', ref='%032x' % number)
                source = Path(upload['path'])
                before = (source.read_bytes(), backend.stamp(source.stat()))
                previous = self.call()['files']
                self.crash_take(mode, upload['id'])
                root = self.ws.data_dir() / 'supporting'
                # No stage filename or partial JSON can enter the index namespace.
                self.assertTrue(all(json.loads(p.read_bytes()) for p in (root / 'index').iterdir()))
                self.assertEqual(self.call('supporting_read', id=prior['id'])['text'], 'prior registered reference')
                self.assertEqual(self.call()['files'], previous)
                stored = sum(p.stat().st_size for folder in ('files', 'pending') for p in (root / folder).iterdir())
                with mock.patch.object(backend, 'MAX_TOTAL', stored + upload['size_bytes'] - 1):
                    self.refusal('LIMIT', 'supporting_take', ref=upload['id'])
                    self.assertEqual(self.call('supporting_read', id=prior['id'])['text'], 'prior registered reference')
                orphan_paths = {p: p.read_bytes() for folder in ('files', 'pending') for p in (root / folder).iterdir()}
                result = self.call('supporting_take', ref=upload['id'])
                self.assertFalse(result['already_registered'])
                self.assertTrue(self.call('supporting_take', ref=upload['id'])['already_registered'])
                for path, data in orphan_paths.items():
                    self.assertEqual(path.read_bytes(), data)
                self.assertEqual((source.read_bytes(), backend.stamp(source.stat())), before)
        pending = self.ws.data_dir() / 'supporting/pending'
        self.assertEqual(len(list(pending.iterdir())), 1)
        self.assertEqual(next(pending.iterdir()).read_bytes(), b'{"id":"')

    def test_orphan_count_and_pending_bytes_are_admission_only(self):
        item = self.take()
        root = self.ws.data_dir() / 'supporting'
        for number in range(100):
            path = root / 'files' / ('support-%032x' % number)
            path.write_bytes(b'')
            path.chmod(0o600)
        upload = self.add_upload(ref='e' * 32)
        self.refusal('LIMIT', 'supporting_take', ref=upload['id'])
        self.assertEqual(self.call()['files'], [item])
        # A metadata-only interrupted stage also consumes a count slot and bytes.
        for number in range(100):
            (root / 'files' / ('support-%032x' % number)).unlink()
        pending = root / 'pending' / ('support-' + 'f' * 32 + '.json')
        pending.write_bytes(b'partial metadata')
        pending.chmod(0o600)
        with mock.patch.object(backend, 'MAX_TOTAL', item['size_bytes'] + upload['size_bytes']):
            self.refusal('LIMIT', 'supporting_take', ref=upload['id'])
            self.assertEqual(self.call()['files'], [item])

    def test_interrupted_storage_validation_does_not_poison_reads(self):
        item = self.take()
        upload = self.add_upload(ref='e' * 32)
        root = self.ws.data_dir() / 'supporting'
        stage = root / 'pending' / ('support-' + 'f' * 32 + '.json')
        for mode in (0o400, 0o666):
            stage.write_bytes(b'partial')
            stage.chmod(mode)
            self.refusal('STORAGE_INVALID' if mode == 0o400 else 'FILE_INVALID', 'supporting_take', ref=upload['id'])
            self.assertEqual(self.call()['files'], [item])
            stage.chmod(0o600)
        stage.unlink()
        stage.symlink_to(self.uploads / upload['id'])
        with self.assertRaises(helpers.Refusal):
            self.call('supporting_take', ref=upload['id'])
        self.assertEqual(self.call()['files'], [item])
        stage.unlink()
        stage.write_bytes(b'partial')
        stage.chmod(0o600)
        os.link(stage, stage.with_name('other-link'))
        with self.assertRaises(helpers.Refusal):
            self.call('supporting_take', ref=upload['id'])
        self.assertEqual(self.call()['files'], [item])

    def test_native_resize_before_copy_fstat_is_refused_and_cleaned(self):
        upload = self.context['_uploads'][0]
        source = Path(upload['path'])
        original = backend.copy_checked
        def grew(*args, **kwargs):
            source.write_bytes(b'x' * (upload['size_bytes'] + 100))
            return original(*args, **kwargs)
        with mock.patch.object(backend, 'MAX_TOTAL', upload['size_bytes'] + 50), \
                mock.patch.object(backend, 'copy_checked', side_effect=grew):
            self.refusal('FILE_CHANGED', 'supporting_take', ref=upload['id'])
        self.assert_empty()
        self.assertEqual(self.call()['files'], [])

    def test_actual_postcopy_capacity_checked_for_all_admissions(self):
        prior = self.take()
        upload = self.add_upload('new.txt', b'new native fixture', ref='e' * 32)
        _, reference = self.reference()
        _, asset = self.asset_reference()
        root = self.ws.data_dir() / 'supporting'
        orphan = root / 'files' / ('support-' + 'f' * 32)
        original = backend.copy_checked
        def extra_storage(*args, **kwargs):
            result = original(*args, **kwargs)
            orphan.write_bytes(b'x' * 4096)
            orphan.chmod(0o600)
            return result
        operations = (lambda: self.call('supporting_take', ref=upload['id']),
                      lambda: self.admit(reference), lambda: self.admit_asset(asset))
        for operation in operations:
            with mock.patch.object(backend, 'MAX_TOTAL', 4096), \
                    mock.patch.object(backend, 'copy_checked', side_effect=extra_storage):
                with self.assertRaisesRegex(helpers.Refusal, '^STANDARD_SUPPORTING_LIMIT$'):
                    operation()
                self.assertEqual(self.call()['files'], [prior])
            self.assertEqual(len(list((root / 'files').iterdir())), 2)
            orphan.unlink()  # Test-owned injected data only; implementation retains it.

    def test_metadata_publication_fsync_order_and_postcommit_failure(self):
        original = os.fsync
        seen = []
        root = self.ws.data_dir() / 'supporting'
        def sync(fd):
            info = os.fstat(fd)
            if stat.S_ISDIR(info.st_mode):
                for name in ('files', 'index'):
                    folder = root / name
                    if folder.exists() and folder.stat().st_ino == info.st_ino:
                        seen.append(name)
                        if name == 'index':
                            raise OSError('invented post-rename durability failure')
            return original(fd)
        with mock.patch.object(backend.os, 'fsync', side_effect=sync):
            self.refusal('IO', 'supporting_take', ref=self.context['_uploads'][0]['id'])
        self.assertLess(seen.index('files'), seen.index('index'))
        # The rename has committed: failure must not delete the blob or record.
        self.assertEqual(len(self.call()['files']), 1)
        self.assertTrue(self.call('supporting_take', ref=self.context['_uploads'][0]['id'])['already_registered'])
        self.assertEqual(len(list((root / 'files').iterdir())), 1)
        self.assertEqual(list((root / 'pending').iterdir()), [])

    def test_internal_origin_lookup_distinguishes_prepared_engineer_copies(self):
        chat = self.take()
        _, request = self.reference()
        engineer = self.admit(request)['file']
        _, asset_request = self.asset_reference()
        asset = self.admit_asset(asset_request)['file']
        self.ws.chat = True
        def lookup(identity):
            with self.ws.lock():
                return backend.reference_origin(self.ws, identity, self.api)
        self.assertEqual(lookup(chat['id']), {'provenance': 'private-session-upload', 'origin_id': None})
        self.assertEqual(lookup(engineer['id']), {'provenance': 'engineer-file-reference', 'origin_id': request['origin_id']})
        self.assertEqual(lookup(asset['id']), {'provenance': 'engineer-asset-reference', 'origin_id': asset_request['origin_id']})
        self.assertIsNone(lookup('support-' + 'f' * 32))
        # The internal accessor lets the role authority fail closed for an
        # unlinked prepared engineer copy while unknown native uploads stay active.
        linked_references = {asset['id']}
        def authority(identity):
            origin = backend.reference_origin(self.ws, identity, self.api)
            return origin['provenance'] == 'private-session-upload' or identity in linked_references
        self.api.reference_active = authority
        self.assertEqual({row['id'] for row in self.call()['files']}, {chat['id'], asset['id']})
        self.refusal('INACTIVE', 'supporting_read', id=engineer['id'])
        with self.assertRaisesRegex(helpers.Refusal, '^STANDARD_SUPPORTING_ID_INVALID$'):
            lookup('../state.json')
        self.refusal('OPERATION_INVALID', 'reference_origin', id=chat['id'])
        self.assertTrue(all(set(row) == {'id', 'filename', 'size_bytes', 'sha256'} for row in self.call()['files']))
        path = self.ws.data_dir() / 'supporting/index' / (engineer['id'] + '.json')
        path.write_text('{}')
        with self.assertRaisesRegex(helpers.Refusal, '^STANDARD_SUPPORTING_INDEX_INVALID$'):
            lookup(chat['id'])

    def test_strict_provenance_union(self):
        _, request = self.reference()
        result = self.admit(request)
        self.take()
        path = self.ws.data_dir() / 'supporting/index' / (result['file']['id'] + '.json')
        original = json.loads(path.read_bytes())
        for changed in (dict(original, session_id='fake', refid='1' * 32),
                        dict(original, provenance='unknown'), dict(original, actor=''),
                        dict(original, source=dict(original['source'], registered={'input_id': 'fake'})),
                        dict(original, source=dict(original['source'], area='work'))):
            path.write_text(json.dumps(changed))
            self.refusal('INDEX_INVALID')
        path.write_text(json.dumps(original))
        chat_path = next(p for p in path.parent.iterdir() if p != path)
        chat_record = json.loads(chat_path.read_bytes())
        self.assertEqual(chat_record['provenance'], 'private-session-upload')
        for key in ('session_id', 'refid', 'provenance'):
            changed = dict(chat_record)
            del changed[key]
            chat_path.write_text(json.dumps(changed))
            self.refusal('INDEX_INVALID')
        chat_path.write_text(json.dumps(chat_record))
        self.assertEqual(len(self.call()['files']), 2)


if __name__ == '__main__':
    unittest.main()
