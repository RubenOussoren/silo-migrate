"""Bounded on-demand preparation and host boundary regressions; no Docker/network."""
import base64
import gzip
import fcntl
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module

job = load('review_job_tested', ROOT / 'bin/review_runtime_job.py')
control = load('review_control_tested', ROOT / 'bin/silo-migrate-control')


class ReviewRuntimeJobTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        (self.repo / 'bin').mkdir(parents=True)
        (self.repo / 'runtime/prebuilt-discourse').mkdir(parents=True)
        (self.repo / 'bin/review_runtime.py').write_text('def prepare(**kw):\n import time\n assert time.monotonic() < kw["deadline"] <= time.monotonic()+1200\n assert len(kw["attempt"]) == 32\n return {"name":"review-fake", "sha256":"a"*64, "comparison":{"required":kw["required_migrations"]}}\n')
        (self.repo / 'bin/discourse_version.py').write_text('# fixed version grammar fixture\n')
        (self.repo / 'runtime/prebuilt-discourse/review-runtime.Dockerfile').write_text('FROM public@sha256:invented\n')
        self.cache = self.root / 'state/review-runtimes'
        self.private_dir = self.root / 'workspace/.silo-migrate/data/review-runtime-jobs'
        self.spawn = patch.object(job.subprocess, 'Popen').start()
        self.addCleanup(patch.stopall)
        self.kw = dict(repo=self.repo, cache=self.cache, private_dir=self.private_dir, baseline={'images':{}}, version='2026.7.5', schema='20260101000000')

    def record(self):
        return next(self.private_dir.glob('*.json'))

    def test_starts_one_fixed_worker_and_returns_pending_without_data(self):
        self.assertEqual({'status':'runtime_preparing'}, job.request(**self.kw))
        self.assertEqual({'status':'runtime_preparing'}, job.request(**self.kw))
        self.assertEqual(1, self.spawn.call_count)
        argv = self.spawn.call_args.args[0]
        self.assertEqual(['-I', '-B'], argv[1:3])
        self.assertEqual(str(Path(job.__file__).resolve()), argv[3])
        self.assertTrue(self.spawn.call_args.kwargs['start_new_session'])
        self.assertEqual(0o600, self.record().stat().st_mode & 0o777)
        self.assertEqual('2026.7.5', job.read(self.record())['inputs']['version'])
        self.assertNotIn('customer', self.record().read_text())

    def test_ready_request_binds_immutable_profile_hash(self):
        job.request(**self.kw)
        path = self.record()
        state = job.read(path)
        directory = job.directory(self.cache / 'profiles')
        raw = b'{"public":"runtime"}\n'
        (directory / 'review-fake.json').write_bytes(raw)
        result = {'name':'review-fake', 'sha256':hashlib.sha256(raw).hexdigest(), 'comparison':{'required':['20260101000000']}}
        job.write(path, dict(state, status='ready', created_at=time.time()-job.FRESH_SECONDS-10, finished_at=time.time(), result=result))
        self.assertEqual(dict(result, status='ready'), job.request(**self.kw))
        self.assertEqual(1, self.spawn.call_count)
        (directory / 'review-fake.json').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED'):
            job.request(**self.kw)

    def test_changed_base_schema_and_recipe_start_distinct_requests(self):
        job.request(**self.kw)
        job.request(**dict(self.kw, schema='20260202000000'))
        (self.repo / 'runtime/prebuilt-discourse/review-runtime.Dockerfile').write_text('changed recipe')
        job.request(**self.kw)
        self.assertEqual(3, self.spawn.call_count)
        self.assertEqual(3, len(list(self.private_dir.glob('*.json'))))

    def test_changed_version_grammar_invalidates_pending_job_before_import(self):
        job.request(**self.kw)
        old = self.record()
        self.assertEqual(3, len(job.read(old)['inputs']['recipes']))
        (self.repo / 'bin/discourse_version.py').write_text('# updated version grammar fixture\n')
        job.request(**self.kw)
        self.assertEqual(2, self.spawn.call_count)
        self.assertEqual(2, len(list(self.private_dir.glob('*.json'))))
        with patch.object(job, '__file__', str(self.repo / 'bin/review_runtime_job.py')), \
                patch.object(job.importlib.util, 'spec_from_file_location') as import_helper:
            with self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED$'):
                job.worker(old)
        import_helper.assert_not_called()
        self.assertEqual('preparing', job.read(old)['status'])

    def test_fixed_failures_and_expired_workers_do_not_claim_ready(self):
        job.request(**self.kw)
        path = self.record()
        state = job.read(path)
        job.write(path, dict(state, status='failed', error='private customer text'))
        with self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED$'):
            job.request(**self.kw)
        job.write(path, dict(state, created_at=time.time()-job.WORK_SECONDS-100))
        with self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_TIMEOUT$'):
            job.request(**self.kw)
        self.assertEqual(1, self.spawn.call_count)
        self.assertEqual('failed', job.read(path)['status'])
        with patch.object(job.time, 'time', return_value=time.time()+31):
            self.assertEqual({'status':'runtime_preparing'}, job.request(**self.kw))
        self.assertEqual(2, self.spawn.call_count)

    def test_stale_worker_cannot_overwrite_a_replacement_attempt(self):
        job.request(**self.kw)
        path = self.record()
        old = job.read(path)
        new = dict(old, attempt='f'*32)
        job.write(path, new)
        job.finish(path, old, status='ready', result={'name':'old', 'sha256':'a'*64})
        self.assertEqual(new, job.read(path))
        job.finish(path, new, status='ready', result={'name':'new', 'sha256':'b'*64})
        self.assertEqual('new', job.read(path)['result']['name'])

    def test_rejects_symlinked_cache_and_request(self):
        other = self.root / 'other'
        other.mkdir()
        self.cache.parent.mkdir(parents=True)
        self.cache.symlink_to(other, target_is_directory=True)
        with self.assertRaises(ValueError):
            job.request(**self.kw)
        self.cache.unlink()
        job.request(**self.kw)
        path = self.record()
        path.unlink()
        path.symlink_to(self.repo / 'bin/review_runtime.py')
        with self.assertRaises(OSError):
            job.request(**self.kw)

    def test_finish_lock_wait_has_bounded_cleanup_grace(self):
        job.request(**self.kw)
        target = self.record()
        state = job.read(target)
        with patch.object(job.fcntl, 'flock', side_effect=BlockingIOError), \
                patch.object(job.time, 'monotonic', side_effect=[0, 6]):
            with self.assertRaises(TimeoutError):
                job.finish(target, state, status='ready')
        self.assertEqual(state, job.read(target))

    def aged_pending(self, age=6):
        job.request(**self.kw)
        target = self.record()
        state = dict(job.read(target), created_at=time.time()-age)
        job.write(target, state)
        return target, state

    def test_crash_after_own_public_lease_requires_recovery_without_replay(self):
        target, state = self.aged_pending()
        marker = self.cache / '.inflight.json'
        job.write(marker, {'attempt':state['attempt'], 'status':'outcome_unknown'})
        raw = marker.read_bytes()
        with self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_RECOVERY_REQUIRED$'):
            job.request(**self.kw)
        self.assertEqual('failed', job.read(target)['status'])
        with patch.object(job.time, 'time', return_value=time.time()+60):
            with self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_RECOVERY_REQUIRED$'):
                job.request(**self.kw)
        self.assertEqual(raw, marker.read_bytes())
        self.assertEqual(1, self.spawn.call_count)

    def test_crash_before_effects_is_retryable_after_failure_cooldown(self):
        target, state = self.aged_pending()
        with self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_TIMEOUT$'):
            job.request(**self.kw)
        failed = job.read(target)
        self.assertEqual('failed', failed['status'])
        self.assertEqual('STANDARD_REVIEW_RUNTIME_TIMEOUT', failed['error'])
        with patch.object(job.time, 'time', return_value=time.time()+31):
            self.assertEqual({'status':'runtime_preparing'}, job.request(**self.kw))
        self.assertNotEqual(state['attempt'], job.read(target)['attempt'])
        self.assertEqual(2, self.spawn.call_count)

    def test_unrelated_public_lease_does_not_attribute_effects_to_crashed_job(self):
        target, state = self.aged_pending()
        marker = self.cache / '.inflight.json'
        job.write(marker, {'attempt':'f'*32, 'status':'preparing'})
        raw = marker.read_bytes()
        with self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_TIMEOUT$'):
            job.request(**self.kw)
        self.assertEqual('STANDARD_REVIEW_RUNTIME_TIMEOUT', job.read(target)['error'])
        self.assertEqual(raw, marker.read_bytes())
        self.assertEqual(1, self.spawn.call_count)

    def test_startup_grace_and_live_expiry_preserve_pending_record(self):
        target, state = self.aged_pending(age=4)
        self.assertEqual({'status':'runtime_preparing'}, job.request(**self.kw))
        self.assertEqual(state, job.read(target))
        live = job.lifetime_lock(target)
        self.addCleanup(os.close, live)
        fcntl.flock(live, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = dict(state, created_at=time.time()-10)
        job.write(target, state)
        self.assertEqual({'status':'runtime_preparing'}, job.request(**self.kw))
        state = dict(state, created_at=time.time()-job.WORK_SECONDS-100)
        job.write(target, state)
        marker = self.cache / '.inflight.json'
        job.write(marker, {'attempt':state['attempt'], 'status':'preparing'})
        raw = marker.read_bytes()
        with self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_TIMEOUT$'):
            job.request(**self.kw)
        self.assertEqual(state, job.read(target))
        self.assertEqual(raw, marker.read_bytes())
        self.assertEqual(1, self.spawn.call_count)

    def test_lifetime_lock_rejects_unsafe_files(self):
        job.request(**self.kw)
        live = self.record().with_suffix('.live')
        for mode in (0o644, 0o660):
            live.touch(mode=mode)
            with self.assertRaises(ValueError):
                job.lifetime_lock(self.record())
            live.unlink()
        live.symlink_to(self.record())
        with self.assertRaises(OSError):
            job.lifetime_lock(self.record())

    def test_worker_holds_lifetime_lock_through_finish_and_releases_on_exit(self):
        job.request(**self.kw)
        target = self.record()
        finish = job.finish
        def checked_finish(*args, **kwargs):
            live = job.lifetime_lock(target)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(live, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(live)
            return finish(*args, **kwargs)
        with patch.object(job, '__file__', str(self.repo / 'bin/review_runtime_job.py')), \
                patch.object(job, 'finish', side_effect=checked_finish):
            job.worker(target)
        live = job.lifetime_lock(target)
        try:
            fcntl.flock(live, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(live)
        self.assertEqual('ready', job.read(target)['status'])

    def test_read_descriptor_walk_rejects_raced_parent_symlink(self):
        job.request(**self.kw)
        target = self.record()
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / target.name).write_text('{"private":"never-read"}')
        original_open = os.open
        raced = False
        def race(path, flags, *args, **kwargs):
            nonlocal raced
            if path == 'review-runtime-jobs' and flags & os.O_DIRECTORY and not raced:
                raced = True
                self.private_dir.rename(self.private_dir.with_name('held'))
                self.private_dir.symlink_to(outside, target_is_directory=True)
            return original_open(path, flags, *args, **kwargs)
        with patch.object(job.os, 'open', side_effect=race):
            with self.assertRaises(OSError):
                job.read(target)
        self.assertTrue(raced)

    def test_missing_private_dir_never_falls_back_to_shared_jobs(self):
        kwargs = dict(self.kw)
        del kwargs['private_dir']
        with self.assertRaises(TypeError):
            job.request(**kwargs)
        self.assertFalse(self.cache.exists())
        self.spawn.assert_not_called()

    def test_private_directory_rejects_symlinks_permissions_and_wrong_scope(self):
        job.private_directory(self.private_dir)
        self.assertEqual(0o700, self.private_dir.stat().st_mode & 0o777)
        for mode in (0o755, 0o750, 0o770):
            self.private_dir.chmod(mode)
            with self.assertRaises(ValueError):
                job.request(**self.kw)
        self.private_dir.chmod(0o700)
        self.private_dir.rmdir()
        other = self.root / 'other'
        other.mkdir()
        self.private_dir.symlink_to(other, target_is_directory=True)
        with self.assertRaises(ValueError):
            job.request(**self.kw)
        with self.assertRaises(ValueError):
            job.request(**dict(self.kw, private_dir=self.cache / 'jobs'))
        with patch.object(job.os, 'getuid', return_value=os.getuid()+1):
            with self.assertRaises(ValueError):
                job.private_directory(other / '.silo-migrate/data/review-runtime-jobs')
        self.spawn.assert_not_called()

    def test_two_workspaces_share_only_public_profile_not_inventories_or_results(self):
        other = self.root / 'workspace-two/.silo-migrate/data/review-runtime-jobs'
        inventory = ['20260101000000', '20251231000000']
        first_kw = dict(self.kw, required_migrations=inventory)
        second_kw = dict(first_kw, private_dir=other)
        job.request(**first_kw)
        first = self.record()
        first_state = job.read(first)
        job.request(**second_kw)
        second = next(other.glob('*.json'))
        self.assertEqual(first.name, second.name)
        self.assertEqual(2, self.spawn.call_count)
        self.assertNotEqual(first, second)
        public = job.directory(self.cache / 'profiles') / 'review-fake.json'
        raw = b'{"images":{"web":"public-runtime"}}'
        public.write_bytes(raw)
        for path, workspace in ((first, 'one'), (second, 'two')):
            result = {'name':'review-fake', 'sha256':hashlib.sha256(raw).hexdigest(),
                      'comparison':{'required':inventory, 'workspace':workspace}}
            job.write(path, dict(job.read(path), status='ready', finished_at=time.time(), result=result))
        self.assertEqual('one', job.request(**first_kw)['comparison']['workspace'])
        self.assertEqual('two', job.request(**second_kw)['comparison']['workspace'])
        self.assertEqual(inventory, first_state['inputs']['required_migrations'])
        self.assertEqual(str(self.cache.absolute()), first_state['cache'])
        self.assertFalse((self.cache / 'jobs').exists())
        self.assertEqual([public], [p for p in self.cache.rglob('*') if p.is_file()])
        self.assertNotIn(inventory[0], public.read_text())
        argv = self.spawn.call_args.args[0]
        self.assertNotIn(inventory[0], ' '.join(argv))
        self.assertNotIn('required_migrations', ' '.join(argv))
        job.request(**dict(second_kw, required_migrations=['20260101000000']))
        self.assertEqual(3, self.spawn.call_count)
        self.assertEqual(1, len(list(self.private_dir.glob('*.json'))))

    def test_worker_rejects_shared_jobs_and_modified_recipe_before_import(self):
        job.request(**self.kw)
        with self.assertRaises(ValueError):
            job.worker(self.cache / 'jobs' / self.record().name)
        (self.repo / 'bin/review_runtime.py').write_text('raise AssertionError("must not import")')
        with patch.object(job, '__file__', str(self.repo / 'bin/review_runtime_job.py')):
            with self.assertRaises(ValueError):
                job.worker(self.record())

    def test_worker_timeout_is_fixed_and_does_not_replace_process_alarm(self):
        job.request(**self.kw)
        # Change the trusted fixture before request so its recipe hash matches.
        (self.repo / 'bin/review_runtime.py').write_text('def prepare(**kw):\n raise TimeoutError("private detail")\n')
        job.request(**self.kw)
        target = max(self.private_dir.glob('*.json'), key=lambda p:p.stat().st_mtime_ns)
        with patch.object(job, '__file__', str(self.repo / 'bin/review_runtime_job.py')), \
                patch('signal.alarm', side_effect=AssertionError('no outer alarm')), \
                patch('signal.signal', side_effect=AssertionError('no global signal handler')):
            job.worker(target)
        state = job.read(target)
        self.assertEqual('failed', state['status'])
        self.assertEqual('STANDARD_REVIEW_RUNTIME_TIMEOUT', state['error'])
        self.assertNotIn('private detail', target.read_text())

    def test_worker_uses_only_fixed_helper_and_preserves_fixed_error(self):
        job.request(**self.kw)
        with patch.object(job, '__file__', str(self.repo / 'bin/review_runtime_job.py')):
            job.worker(self.record())
        self.assertEqual('ready', job.read(self.record())['status'])
        self.assertEqual({'name':'review-fake', 'sha256':'a'*64, 'comparison':{'required':None}},
                         job.read(self.record())['result'])


class ReviewRuntimeHostTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        (self.repo / 'bin').mkdir(parents=True)
        profile_dir = self.repo / 'runtime/profiles'
        profile_dir.mkdir(parents=True)
        raw = b'{"images":{"web":{}},"app":{"version":"2026.11.0-latest"}}'
        (profile_dir / 'baseline.json').write_bytes(raw)
        self.base = self.root / 'workspaces'
        self.named = self.base / 'invented/.silo-migrate/named'
        (self.named / 'standard').mkdir(parents=True)
        (self.named / 'standard/state.json').write_text(json.dumps({'config':{
            'discourse_profile':'baseline', 'discourse_profile_sha256':hashlib.sha256(raw).hexdigest()}}))
        self.input = 'input-' + 'a'*32
        self.run = 'run-' + 'b'*32
        self.set_base('never-disclose-me-v2026-11-0-latest-1-20261109000000.sql.gz')
        (self.repo / 'bin/review_runtime_job.py').write_text('''import json\nfrom pathlib import Path\ndef request(**kw):\n p=Path(__file__).parent / "observed.json"\n p.write_text(json.dumps({"version":kw["version"],"schema":kw["schema"],"private_dir":str(kw["private_dir"])}))\n return {"status":"runtime_preparing"}\n''')

    def set_base(self, name):
        inputs = self.named.parents[1] / 'inputs'
        inputs.mkdir(exist_ok=True)
        schema = name.rsplit('-', 1)[-1].split('.')[0].removeprefix('v')
        with gzip.open(inputs / name, 'wb') as archive:
            archive.write(('private invented row outside the migration block\nCOPY public.schema_migrations (version) FROM stdin;\n'+schema+'\n\\.\n').encode())
        (self.named / 'state.json').write_text(json.dumps({'inputs':{self.input:{'type':'base_site','path':base64.b64encode(('inputs/'+name).encode()).decode()}}}))

    def args(self, base=True):
        return ['standard','plan','propose','invented','--operation','review','--from-run',self.run] + (['--base-site',self.input] if base else [])

    def test_preparation_receives_workspace_private_job_directory(self):
        values = {}
        self.assertEqual({'status':'runtime_preparing'}, control.prepare_review_runtime(self.args(),values,self.base,self.repo))
        observed = json.loads((self.repo / 'bin/observed.json').read_text())
        self.assertEqual({'version':'2026.11.0-latest.1','schema':'20261109000000',
                          'private_dir':str(self.named.parents[1] / '.silo-migrate/data/review-runtime-jobs')}, observed)
        self.assertNotIn('never-disclose', json.dumps(observed))
        self.assertEqual({}, values)

    def test_migration_scan_is_private_bounded_and_reused_for_unchanged_input(self):
        root = self.named.parents[1]
        encoded = json.loads((self.named / 'state.json').read_text())['inputs'][self.input]['path']
        self.assertEqual(['20261109000000'], control.review_base_migrations(root, encoded))
        with patch('gzip.GzipFile', side_effect=AssertionError('unchanged backup was rescanned')):
            self.assertEqual(['20261109000000'], control.review_base_migrations(root, encoded))
        cache = next((root / '.silo-migrate/data/review-runtime-inputs').glob('*.json'))
        self.assertNotIn('private invented row', cache.read_text())
        self.assertNotIn('never-disclose', cache.read_text())

    def test_migration_scan_rejects_untrusted_paths_and_invalid_blocks(self):
        root = self.named.parents[1]
        for path in ('../elsewhere', '/absolute/secret', 'work/derived.sql.gz'):
            with self.assertRaises(ValueError):
                control.review_base_migrations(root, base64.b64encode(path.encode()).decode())
        invalid = root / 'inputs/invalid.sql.gz'
        with gzip.open(invalid, 'wb') as stream:
            stream.write(b'COPY public.schema_migrations (version) FROM stdin;\nprivate-invalid-value\n\\.\n')
        with self.assertRaisesRegex(ValueError, '^STANDARD_BASE_SITE_INVALID$'):
            control.review_base_migrations(root, base64.b64encode(b'inputs/invalid.sql.gz').decode())

    def test_ready_comparison_forwards_only_bounded_workspace_facts(self):
        (self.repo / 'bin/review_runtime_job.py').write_text('''def request(**kw):\n return {"status":"ready","name":"review-public","sha256":"a"*64,"comparison":{"core_comparison_complete":True,"missing_known_core_migrations":2,"unknown_required_migrations_count":7,"private_raw":"never-forward"}}\n''')
        values = {}
        self.assertIsNone(control.prepare_review_runtime(self.args(), values, self.base, self.repo))
        self.assertEqual({'core_comparison_complete':True,'missing_known_core_migrations':2},
                         json.loads(values['SILO_REVIEW_RUNTIME_COMPARISON']))
        self.assertNotIn('never-forward', json.dumps(values))
        self.assertNotIn('unknown_required', json.dumps(values))

    def test_descriptor_walk_refuses_a_raced_parent_symlink(self):
        module = control.data_tools()
        original_open = os.open
        outside = self.root / 'outside'
        (outside / 'standard').mkdir(parents=True)
        (outside / 'standard/state.json').write_text('{"private":"never-read"}')
        raced = False
        def race(path, flags, *args, **kwargs):
            nonlocal raced
            if path == 'named' and flags & os.O_DIRECTORY and not raced:
                raced = True
                self.named.rename(self.named.with_name('held'))
                self.named.symlink_to(outside, target_is_directory=True)
            return original_open(path, flags, *args, **kwargs)
        with patch.object(control, 'data_tools', return_value=module), patch.object(os, 'open', side_effect=race):
            with self.assertRaisesRegex(ValueError, '^STANDARD_PATH_INVALID'):
                control.prepare_review_runtime(self.args(), {}, self.base, self.repo)
        self.assertTrue(raced)
        self.assertFalse((self.repo/'bin/observed.json').exists())

    def test_selection_scan_stops_after_migration_block(self):
        root = self.named.parents[1]
        encoded = json.loads((self.named/'state.json').read_text())['inputs'][self.input]['path']
        real_gzip = gzip.GzipFile
        class StopAtBlock:
            def __init__(self, **kwargs):
                self.stream = real_gzip(**kwargs)
                self.done = False
            def __enter__(self): return self
            def __exit__(self, *args): self.stream.close()
            def readline(self, size):
                if self.done: raise AssertionError('decompressed beyond the selected migration block')
                line = self.stream.readline(size)
                self.done = line.rstrip(b'\r\n') == b'\\.'
                return line
        with patch('gzip.GzipFile', StopAtBlock):
            self.assertEqual(['20261109000000'], control.review_base_migrations(root, encoded))

    def test_no_base_requests_latest_without_backup_metadata(self):
        control.prepare_review_runtime(self.args(False),{},self.base,self.repo)
        self.assertEqual({'version':None,'schema':None,
                          'private_dir':str(self.named.parents[1] / '.silo-migrate/data/review-runtime-jobs')},
                         json.loads((self.repo / 'bin/observed.json').read_text()))

    def test_relabelled_base_is_reread_every_time(self):
        control.prepare_review_runtime(self.args(),{},self.base,self.repo)
        self.set_base('different-private-name-v2026-7-5-20260701000000.sql.gz')
        control.prepare_review_runtime(self.args(),{},self.base,self.repo)
        self.assertEqual('2026.7.5', json.loads((self.repo / 'bin/observed.json').read_text())['version'])

    def test_invalid_arguments_and_missing_version_never_prepare(self):
        for args in (self.args()+['--image','evil'], self.args()+['--base-site',self.input],
                     self.args()[:-1]+['--bad'], self.args(False)[:-1]+['../../escape']):
            with self.assertRaises(ValueError):
                control.prepare_review_runtime(args,{},self.base,self.repo)
        self.set_base('invented-v20261109000000.sql.gz')
        with self.assertRaisesRegex(ValueError,'STANDARD_REVIEW_RUNTIME_UNRESOLVED'):
            control.prepare_review_runtime(self.args(),{},self.base,self.repo)
        self.assertFalse((self.repo / 'bin/observed.json').exists())

    def test_merge_prepare_resolves_runtime_from_its_exact_base(self):
        args = ['standard', 'plan', 'propose', 'invented', '--operation', 'merge-prepare',
                '--source', 'input-' + 'c' * 32, '--base-site', self.input]
        self.assertEqual({'status': 'runtime_preparing'}, control.prepare_review_runtime(args, {}, self.base, self.repo))
        observed = json.loads((self.repo / 'bin/observed.json').read_text())
        self.assertEqual(('2026.11.0-latest.1', '20261109000000'), (observed['version'], observed['schema']))
        for extra in (['--settings', self.input], ['--ignore-global-pins']):
            with self.subTest(extra=extra), self.assertRaisesRegex(ValueError, 'STANDARD_ARGUMENTS_INVALID'):
                control.prepare_review_runtime(args + extra, {}, self.base, self.repo)

    def test_prepared_merge_never_resolves_or_reads_another_runtime(self):
        args = ['standard', 'plan', 'propose', 'invented', '--operation', 'merge',
                '--prepared-from', self.run, '--generation', 'd' * 64, '--intent', 'custom',
                '--settings', self.input, '--preparation', '/private/invented.json']
        # Even a missing state/profile must not lead this host seam to choose a fresh runtime.
        (self.named / 'standard/state.json').unlink()
        self.assertIsNone(control.prepare_review_runtime(args, {}, self.base, self.repo))
        self.assertFalse((self.repo / 'bin/observed.json').exists())
        for extra in (['--port', '8080'], ['--allow-unqualified-runtime']):
            with self.subTest(extra=extra), self.assertRaisesRegex(ValueError, 'STANDARD_ARGUMENTS_INVALID'):
                control.prepare_review_runtime(args + extra, {}, self.base, self.repo)
        for key, bad in (('--generation', 'not-a-generation'), ('--prepared-from', '../other'), ('--intent', 'guess')):
            malformed = list(args)
            malformed[malformed.index(key) + 1] = bad
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'STANDARD_ARGUMENTS_INVALID'):
                control.prepare_review_runtime(malformed, {}, self.base, self.repo)

    def test_reads_start_and_reset_do_not_prepare(self):
        for args in (['standard','status','invented'], ['start-run','invented','plan-'+'a'*32], ['standard','run','reset','invented',self.run,'--yes']):
            self.assertIsNone(control.prepare_review_runtime(args,{},self.base,self.repo))
        self.assertFalse((self.repo / 'bin/observed.json').exists())


if __name__ == '__main__':
    unittest.main()
