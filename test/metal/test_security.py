"""Adversarial fixtures only: never talks to Docker or a real workspace."""
import contextlib
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import tarfile
import unittest
from unittest.mock import patch
import test_metal as fixtures
from test_metal import module, ROOT


class SecurityTests(unittest.TestCase):
    setUp = fixtures.InstallerTests.setUp
    plan_stubs = fixtures.InstallerTests.plan_stubs
    configured = fixtures.InstallerTests.configured

    def test_symlinked_prefix_pruning_deletes_only_unprotected_releases(self):
        for keep in (2, 3):
            with self.subTest(keep=keep):
                actual = self.root/str(keep)
                actual.mkdir()
                link = self.root/(str(keep) + '-link')
                link.symlink_to(actual, target_is_directory=True)
                config = self.configured('SILO_PREFIX=' + str(link/'prefix') + '\nKEEP_RELEASES=' + str(keep))
                self.assertEqual(str(actual/'prefix'), config['SILO_PREFIX'])
                self.m.C.update(config)
                self.m.P = Path(config['SILO_PREFIX'])
                P = self.m.P
                (P/'state/logs').mkdir(parents=True)
                (P/'releases').mkdir()
                self.m.W.mkdir(exist_ok=True)
                (self.m.W/'.silo-standard-execution.lock').touch()
                commits = [c*40 for c in 'abcde']
                for n, commit in enumerate(commits):
                    release = P/'releases'/commit
                    release.mkdir()
                    os.utime(release, (100+n, 100+n))
                (P/'current').symlink_to(P/'releases'/commits[0])
                self.m.record({'commit': commits[0]}, 'apply')
                with patch.object(self.m, 'resolve', return_value=commits[1]), patch.object(self.m, 'fetch_release', return_value=P/'releases'/commits[1]), contextlib.redirect_stdout(io.StringIO()):
                    self.m.account_update()
                self.assertEqual(keep, len(list((P/'releases').iterdir())))
                for name in ('current', 'previous'):
                    self.assertTrue((P/name).resolve().is_dir())
                self.assertEqual(commits[1], (P/'current').resolve().name)
                self.assertEqual(commits[0], (P/'previous').resolve().name)

    def test_authority_records_ancestors_and_refuses_writable_and_symlink(self):
        parent = self.root/'trusted'
        parent.mkdir(mode=0o750)
        states = self.m.directory_authority([parent/'missing'])
        self.assertEqual(oct(parent.stat().st_mode & 0o7777), states[str(parent)]['mode'])
        self.assertEqual(os.getuid(), states[str(parent)]['uid'])
        parent.chmod(0o770)
        with self.assertRaisesRegex(self.m.Refusal, 'METAL_PATH_AUTHORITY'):
            self.m.directory_authority([parent/'missing'])
        parent.chmod(0o750)
        link = self.root/'link'
        link.symlink_to(parent, target_is_directory=True)
        with self.assertRaisesRegex(self.m.Refusal, 'METAL_PATH_AUTHORITY'):
            self.m.secure_directory(link/'missing', os.getuid(), os.getgid())
        self.assertFalse((parent/'missing').exists())

    def test_secure_directory_never_repairs_existing_owner(self):
        parent = self.root/'directory'
        parent.mkdir()
        with self.assertRaisesRegex(self.m.Refusal, 'METAL_PATH_AUTHORITY'):
            self.m.secure_directory(parent, os.getuid()+1, os.getgid())
        self.assertEqual(os.getuid(), parent.stat().st_uid)

    def test_workspace_overlap_refused(self):
        for suffix in ('', '/releases', '/state', '/workspaces/child'):
            with self.assertRaisesRegex(self.m.Refusal, 'METAL_CONFIG_INVALID'):
                self.configured('SILO_PREFIX=/srv/silo\nSILO_WORKSPACES=/srv/silo' + suffix)
        with self.assertRaises(self.m.Refusal):
            self.configured('SILO_PREFIX=/srv/silo\nSILO_WORKSPACES=/srv')

    def test_installer_hash_rechecked_in_account_apply_before_any_work(self):
        with self.plan_stubs():
            saved = self.m.envelope(self.m.make_plan())
        saved['plan']['installer_sha256'] = '0'*64
        with patch.object(self.m, 'install_term') as install, self.assertRaisesRegex(self.m.Refusal, 'METAL_PLAN_STALE'):
            self.m.account_apply(saved)
        install.assert_not_called()

    def test_install_lock_refuses_second_operation(self):
        (self.m.P/'state').mkdir(parents=True)
        with self.m.install_lock():
            with self.assertRaisesRegex(self.m.Refusal, 'METAL_BUSY'):
                with self.m.install_lock():
                    self.fail('second operation admitted')

    def test_update_and_rollback_rederive_images_never_trust_prior_verified(self):
        release = self.root/'release'
        profiles = release/'runtime/profiles'
        profiles.mkdir(parents=True)
        identity = module('image_identity_security', 'image_identity.py')
        document = {'Id': 'sha256:'+'f'*64, 'Architecture': 'amd64', 'Os': 'linux', 'RootFS': {'Layers': []}, 'Config': {}}
        image = {'ref': 'test:bound', 'content_id': identity.content_id(document), 'source': 'package'}
        (profiles/'bound.json').write_text(json.dumps({'version': 1, 'images': {'control': image}}))
        bound = {'manifest': {'profile': {'name': 'bound'}}}
        with patch.object(self.m, 'output', return_value=json.dumps([document])):
            receipts, status = self.m.verify_release_images(release, bound)
        self.assertEqual('verified', status)
        self.assertEqual(image['content_id'], receipts[0]['content_id'])
        with patch.object(self.m, 'output', return_value=None), self.assertRaisesRegex(self.m.Refusal, 'METAL_UPDATE_IMAGES'):
            self.m.verify_release_images(release, bound)
        self.assertEqual(([], 'skipped-no-package'), self.m.verify_release_images(release, None))

    def test_package_snapshot_private_cleaned_and_original_not_used(self):
        source = self.root/'package'
        source.mkdir(mode=0o750)
        (source/'payload').write_text('original')
        self.m.C['ARTIFACT_PACKAGE'] = str(source)
        (self.m.P/'state/tmp').mkdir(parents=True)
        seen = []
        def extract(release, package, root):
            seen.append(root)
            self.assertEqual(0o700, root.parent.stat().st_mode & 0o777)
            self.assertEqual(os.getuid(), root.parent.stat().st_uid)
            (source/'payload').write_text('replaced')
            self.assertEqual('original', (root/'payload').read_text())
            raise self.m.Refusal('synthetic failure')
        with patch.object(self.m, 'extract_artifact_copy', side_effect=extract), self.assertRaises(self.m.Refusal):
            self.m.extract_artifacts(self.root, {'manifest': {}})
        self.assertFalse(seen[0].parent.exists())

    def test_stale_link_cleaned_without_removing_regular_files(self):
        parent = self.root/'links'
        parent.mkdir()
        (parent/'.metal-link-old').symlink_to('missing')
        (parent/'.metal-link-file').write_text('preserve')
        self.m.symlink('new', parent/'current')
        self.assertFalse((parent/'.metal-link-old').is_symlink())
        self.assertTrue((parent/'.metal-link-file').is_file())

    def test_shared_control_char_identity(self):
        identity = module('image_identity_controls', 'image_identity.py')
        fixture = ROOT/'test/fixtures/image-inspect-controls.json'
        want = fixture.with_suffix('.content_id').read_text().strip()
        document = json.loads(fixture.read_text())[0]
        wrapper = runpy.run_path(str(ROOT/'bin/silo-migrate-control'))
        self.assertEqual(want, identity.content_id(document))
        self.assertEqual(want, wrapper['identity'](document))

    def test_wrapper_control_identity_comes_from_sha_bound_workspace_profile(self):
        wrapper = runpy.run_path(str(ROOT/'bin/silo-migrate-control'))
        repo = self.root/'release'
        profiles = repo/'runtime/profiles'
        profiles.mkdir(parents=True)
        profile = profiles/'candidate.json'
        control = {'ref': 'candidate:control', 'content_id': 'sha256:'+'e'*64}
        profile.write_text(json.dumps({'images': {'control': control}}))
        base = self.root/'work'
        state = base/'synthetic/.silo-migrate/named/standard/state.json'
        state.parent.mkdir(parents=True)
        state.write_text(json.dumps({'config': {'discourse_profile': 'candidate', 'discourse_profile_sha256': self.m.sha(profile)}}))
        for args in (['standard', 'status', 'synthetic'], ['standard', 'run', 'execute', 'synthetic', 'run'], ['start-run', 'synthetic', 'plan']):
            self.assertEqual(control, wrapper['control_image'](repo, {}, base, args))
        profile.write_text(profile.read_text()+'\n')
        with self.assertRaisesRegex(ValueError, 'STANDARD_RUNTIME_MISMATCH'):
            wrapper['control_image'](repo, {}, base, ['standard', 'status', 'synthetic'])


class ArchiveTests(unittest.TestCase):
    setUp = fixtures.InstallerTests.setUp

    def archive(self, *, tags=None, count=1, wrong_diff=False, wrong_config=False, oci=False,
                gzip_layer=False, annotations=None, extra_blob=False, layer_media=None, truncate_gzip=False):
        layer = b'tiny synthetic layer'
        diff = 'sha256:' + hashlib.sha256(layer).hexdigest()
        stored = gzip.compress(layer, mtime=0) if gzip_layer else layer
        if truncate_gzip:
            stored = stored[:-6]
        config = {'architecture': 'amd64', 'os': 'linux', 'rootfs': {'type': 'layers', 'diff_ids': [diff]}, 'config': {'Env': ['LANG=C']}}
        identity = module('identity_archive', 'image_identity.py')
        image = {'ref': 'test/bound:1', 'content_id': identity.content_id({'Architecture': 'amd64', 'Os': 'linux', 'RootFS': {'Layers': [diff]}, 'Config': config['config']})}
        if wrong_diff:
            config['rootfs']['diff_ids'] = ['sha256:'+'0'*64]
        raw = json.dumps(config).encode()
        digest = hashlib.sha256(raw).hexdigest()
        entries = {digest+'.json': raw, 'layer.tar': stored}
        if oci:
            entries = {}
            def blob(raw, media):
                digest = hashlib.sha256(raw).hexdigest()
                entries['blobs/sha256/'+digest] = raw
                return {'mediaType': media, 'digest': 'sha256:'+digest, 'size': len(raw)}
            cfg = blob(raw, 'application/vnd.oci.image.config.v1+json')
            media = layer_media or ('application/vnd.oci.image.layer.v1.tar+gzip' if gzip_layer else 'application/vnd.oci.image.layer.v1.tar')
            lay = blob(stored, media)
            desc = blob(json.dumps({'schemaVersion': 2, 'mediaType': 'application/vnd.oci.image.manifest.v1+json', 'config': cfg, 'layers': [lay]}).encode(), 'application/vnd.oci.image.manifest.v1+json')
            if tags:
                desc['annotations'] = {'org.opencontainers.image.ref.name': tags[0]}
            if annotations:
                desc['annotations'] = annotations
            entries['index.json'] = json.dumps({'schemaVersion': 2, 'manifests': [desc]*count}).encode()
            # Real containerd-store saves carry both layouts over the same blobs.
            entries['manifest.json'] = json.dumps([{'Config': 'blobs/sha256/'+cfg['digest'][7:], 'Layers': ['blobs/sha256/'+lay['digest'][7:]],
                                                    'RepoTags': [] if tags is None else tags}]).encode()
            entries['oci-layout'] = b'{"imageLayoutVersion": "1.0.0"}'
            if extra_blob:
                blob(b'a second, unreferenced image could hide here', 'application/octet-stream')
        else:
            entries['manifest.json'] = json.dumps([{'Config': ('0'*64 if wrong_config else digest)+'.json', 'Layers': ['layer.tar'], 'RepoTags': [] if tags is None else tags}]*count).encode()
        path = self.root/'image.tar.gz'
        with tarfile.open(path, 'w:gz') as tar:
            for name, body in entries.items():
                member = tarfile.TarInfo(name)
                member.size = len(body)
                tar.addfile(member, io.BytesIO(body))
        return path, image, identity, 'sha256:'+digest

    def test_tiny_docker_and_oci_archives_are_bound_before_load(self):
        parser = module('archive_test', 'image_archive.py')
        for oci in (False, True):
            for tags in (None, ['test/bound:1']):
                path, image, identity, config_id = self.archive(oci=oci, tags=tags)
                self.assertEqual(config_id, parser.validate(path, image, identity))

    def test_multiple_foreign_tag_wrong_diff_and_wrong_config_refused(self):
        parser = module('archive_bad_test', 'image_archive.py')
        for oci in (False, True):
            for opts in ({'count': 2}, {'tags': ['foreign:tag']}, {'wrong_diff': True}):
                with self.subTest(oci=oci, opts=opts), self.assertRaises((ValueError, KeyError)):
                    path, image, identity, _ = self.archive(oci=oci, **opts)
                    parser.validate(path, image, identity)
        path, image, identity, _ = self.archive(wrong_config=True)
        with self.assertRaises(ValueError):
            parser.validate(path, image, identity)

    def test_containerd_save_shape_gzip_layers_and_normalized_names(self):
        # Shape observed in real `docker image save` output (containerd store):
        # gzip OCI layers, docker.io-normalized name and tag-only OCI ref name.
        parser = module('archive_real_shape_test', 'image_archive.py')
        for gzip_layer in (False, True):
            path, image, identity, config_id = self.archive(oci=True, gzip_layer=gzip_layer, tags=['test/bound:1'], annotations={
                'io.containerd.image.name': 'docker.io/test/bound:1', 'org.opencontainers.image.ref.name': '1'})
            self.assertEqual(config_id, parser.validate(path, image, identity))
        path, image, identity, config_id = self.archive(gzip_layer=True, tags=['test/bound:1'])
        self.assertEqual(config_id, parser.validate(path, image, identity))
        self.assertEqual({'ruby@sha256:' + 'a'*64, 'docker.io/library/ruby@sha256:' + 'a'*64}, parser.spellings('ruby@sha256:' + 'a'*64))
        self.assertIn('registry.example:5000/x/y:2', parser.spellings('registry.example:5000/x/y:2'))

    def test_foreign_names_extra_blobs_zstd_and_truncated_gzip_refused(self):
        parser = module('archive_real_bad_test', 'image_archive.py')
        cases = [dict(annotations={'io.containerd.image.name': 'docker.io/library/postgres:15'}),
                 dict(annotations={'io.containerd.image.name': 'docker.io/test/other:1'}),
                 dict(annotations={'org.opencontainers.image.ref.name': '2'}),
                 dict(extra_blob=True),
                 dict(gzip_layer=True, layer_media='application/vnd.oci.image.layer.v1.tar+zstd'),
                 dict(gzip_layer=True, layer_media='application/vnd.oci.image.layer.v1.tar'),
                 dict(gzip_layer=True, truncate_gzip=True)]
        for opts in cases:
            with self.subTest(opts=opts), self.assertRaises(ValueError):
                path, image, identity, _ = self.archive(oci=True, **opts)
                parser.validate(path, image, identity)

class ConverterGitTests(unittest.TestCase):
    setUp = fixtures.InstallerTests.setUp

    def test_update_status_and_local_git_never_run_hooks_or_fsmonitor(self):
        wrapper = runpy.run_path(str(ROOT/'bin/silo-migrate-control'))
        globals_ = wrapper['host_converter'].__globals__
        base = self.root/'workspaces'
        root = base/'synthetic'
        checkout = root/'converter'
        remote = self.root/'remote'
        remote.mkdir()
        def git(*args):
            return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null', *map(str, args)], stderr=subprocess.DEVNULL, env=dict(os.environ, GIT_CONFIG_NOSYSTEM='1')).decode().strip()
        git('init', '-b', 'main', remote)
        git('-C', remote, 'config', 'user.email', 'fixture@example.test')
        git('-C', remote, 'config', 'user.name', 'Fixture')
        (remote/'tracked').write_text('one')
        git('-C', remote, 'add', '.')
        git('-C', remote, 'commit', '-m', 'one')
        root.mkdir(parents=True)
        git('clone', remote, checkout)
        standard = root/'.silo-migrate/named/standard'
        standard.mkdir(parents=True)
        (standard.parent/'state.json').write_text('{}')
        (standard/'op.lock').touch()
        state = {'config': {'converter_worktree': str(checkout), 'converter': {'branch': 'main'}}, 'runs': {}}
        (standard/'state.json').write_text(json.dumps(state))
        marker = self.root/'executed'
        monitor = self.root/'monitor'
        monitor.write_text('#!/bin/sh\ntouch '+str(marker)+'\nprintf "\\0"\n')
        monitor.chmod(0o755)
        git('-C', checkout, 'config', 'core.fsmonitor', monitor)
        for hook in ('post-merge', 'post-checkout'):
            script = checkout/'.git/hooks'/hook
            script.write_text('#!/bin/sh\ntouch '+str(marker)+'\n')
            script.chmod(0o755)
        # The fixture can execute code when not hardened, proving it is live.
        subprocess.run(['git', '-C', str(checkout), 'status', '--porcelain'], capture_output=True)
        self.assertTrue(marker.exists())
        marker.unlink()
        self.assertEqual('', wrapper['capture'](wrapper['converter_git'](checkout)+['--no-optional-locks', 'status', '--porcelain']))
        (remote/'tracked').write_text('two')
        git('-C', remote, 'commit', '-am', 'two')
        with patch('subprocess.call', return_value=0):
            wrapper['host_converter'](['converter', 'update', 'synthetic'], {}, base, ROOT/'bin/silo-migrate-control')
        self.assertEqual('two', (checkout/'tracked').read_text())
        self.assertFalse(marker.exists())
        # A checkout via the same hardened argv also refuses the live hook.
        wrapper['capture'](wrapper['converter_git'](checkout)+['checkout', 'main'])
        self.assertFalse(marker.exists())
        for status in ('claimed', 'running'):
            state['runs'] = {'run': {'status': status}}
            (standard/'state.json').write_text(json.dumps(state))
            with patch.dict(globals_, capture=lambda args: self.fail('git ran while claimed/running')), self.assertRaisesRegex(ValueError, 'STANDARD_BUSY'):
                wrapper['host_converter'](['converter', 'update', 'synthetic'], {}, base, ROOT/'bin/silo-migrate-control')
        state['runs'] = {}
        (standard/'state.json').write_text(json.dumps(state))
        with open(standard/'op.lock') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(ValueError, 'STANDARD_BUSY'):
                wrapper['host_converter'](['converter', 'update', 'synthetic'], {}, base, ROOT/'bin/silo-migrate-control')

class LoadBoundaryTests(unittest.TestCase):
    setUp = fixtures.InstallerTests.setUp

    def prepare(self, *, bad_tags=False, digest_ref=False, unsafe_gems=False):
        path, image, identity, config_id = ArchiveTests.archive(self, tags=['foreign:tag'] if bad_tags else None)
        if digest_ref:
            image['ref'] = 'ruby@sha256:'+'c'*64
        root = self.root/'package'
        (root/'images').mkdir(parents=True)
        path.rename(root/'images/control.tar.gz')
        (root/'manifest.json').write_text('{}')
        (root/'SHA256SUMS').write_text('synthetic')
        (root/'site_settings.yml').write_text('title: synthetic')
        with tarfile.open(root/'gems.tar.gz', 'w:gz') as tar:
            member = tarfile.TarInfo('../escaped' if unsafe_gems else 'gem.rb')
            member.size = 1
            tar.addfile(member, io.BytesIO(b'x'))
        manifest = {'profile': {'name': 'bound'}, 'images': [{'role': 'control', 'file': 'images/control.tar.gz'}], 'gems': {'sha256': 'gems'}, 'site_settings': {'sha256': self.m.sha(root/'site_settings.yml')}}
        package = {'manifest': manifest, 'id': self.m.sha(root/'manifest.json'), 'sha256': self.m.sha(root/'SHA256SUMS')}
        for directory in ('state/tmp', 'control/gems', 'control/site-cache'):
            (self.m.P/directory).mkdir(parents=True)
        pack = module('package_boundary_test', 'package-artifacts')
        self.m.module_original = self.m.module
        def modules(name, filename):
            if filename == 'package-artifacts':
                return type('Package', (), {'Invalid': pack.Invalid, 'safe_name': staticmethod(pack.safe_name), 'verify': staticmethod(lambda *args: manifest), 'profile_read': staticmethod(lambda *args: {'images': {'control': image}})})
            return self.m.module_original(name, filename)
        loaded = []
        def output(argv, **kwargs):
            if argv[1:3] == ['image', 'inspect']:
                if argv[-1] == image['ref'] and not (loaded and not digest_ref):
                    return None
                if loaded:
                    return json.dumps([{'Id': config_id, 'Architecture': 'amd64', 'Os': 'linux', 'RootFS': {'Layers': ['sha256:'+hashlib.sha256(b'tiny synthetic layer').hexdigest()]}, 'Config': {'Env': ['LANG=C']}}])
                return None
            raise AssertionError(argv)
        def run(argv, **kwargs):
            loaded.append(argv)
            return subprocess.CompletedProcess(argv, 0, '', '')
        return root, package, modules, output, run, loaded, image, config_id

    def test_preload_parser_refuses_before_daemon_call(self):
        root, package, modules, output, run, calls, _, _ = self.prepare(bad_tags=True)
        with patch.object(self.m, 'module', side_effect=modules), patch.object(self.m, 'output', side_effect=output), patch.object(self.m, 'run', side_effect=run), self.assertRaisesRegex(self.m.Refusal, 'METAL_IMAGE_ARCHIVE'):
            self.m.extract_artifact_copy(self.root, package, root)
        self.assertEqual([], calls)

    def test_foreign_tag_change_refused_after_load(self):
        root, package, modules, output, run, calls, _, _ = self.prepare()
        with patch.object(self.m, 'module', side_effect=modules), patch.object(self.m, 'output', side_effect=output), patch.object(self.m, 'run', side_effect=run), patch.object(self.m, 'image_tags', side_effect=[{'foreign:tag': 'old'}, {'foreign:tag': 'new'}]), self.assertRaisesRegex(self.m.Refusal, 'METAL_IMAGE_TAG_CHANGED'):
            self.m.extract_artifact_copy(self.root, package, root)
        self.assertEqual(1, len(calls))

    def test_digest_load_uses_validated_id_and_records_honest_local_alias(self):
        root, package, modules, output, run, calls, image, config_id = self.prepare(digest_ref=True)
        with patch.object(self.m, 'module', side_effect=modules), patch.object(self.m, 'output', side_effect=output), patch.object(self.m, 'run', side_effect=run), patch.object(self.m, 'image_tags', return_value={}):
            receipts, verified, _ = self.m.extract_artifact_copy(self.root, package, root)
        alias = 'silo-migrate/loaded:'+image['content_id'][7:]
        self.assertIn(['docker', 'image', 'tag', config_id, alias], calls)
        self.assertEqual('verified', verified)
        self.assertEqual(image['ref'], receipts[0]['ref'])
        self.assertEqual(alias, receipts[0]['resolved_ref'])

    def test_gem_members_revalidated_at_extraction_even_after_verifier(self):
        root, package, modules, output, run, calls, _, _ = self.prepare(unsafe_gems=True)
        with patch.object(self.m, 'module', side_effect=modules), patch.object(self.m, 'output', side_effect=output), patch.object(self.m, 'run', side_effect=run), patch.object(self.m, 'image_tags', return_value={}), self.assertRaisesRegex(self.m.Refusal, 'METAL_ARTIFACT_INVALID'):
            self.m.extract_artifact_copy(self.root, package, root)
        self.assertFalse((self.m.P/'state/tmp/escaped').exists())
        self.assertEqual([], list((self.m.P/'state/tmp').iterdir()))

class RootPlanTests(unittest.TestCase):
    setUp = fixtures.InstallerTests.setUp
    plan_stubs = fixtures.InstallerTests.plan_stubs

    def test_docker_existing_key_or_repository_never_overwritten(self):
        with patch.object(self.m.shutil, 'which', return_value=None), patch.object(self.m.os.path, 'lexists', return_value=True), patch.object(self.m, 'run') as run, self.assertRaisesRegex(self.m.Refusal, 'METAL_DOCKER_REPO_CONFLICT'):
            self.m.apply_roots([{'action': 'docker'}])
        run.assert_not_called()

    def test_docker_wrong_key_fingerprint_refused_before_publishing_or_apt(self):
        (self.m.P/'state/tmp').mkdir(parents=True)
        calls = []
        def run(argv, **kwargs):
            calls.append(argv)
            self.assertEqual('curl', argv[0])
            Path(argv[-1]).write_text('synthetic key')
        with patch.object(self.m.shutil, 'which', return_value=None), patch.object(self.m.os.path, 'lexists', return_value=False), patch.object(self.m, 'run', side_effect=run), patch.object(self.m, 'output', return_value='pub:::::::::\nfpr:::::::::WRONG:\n'), self.assertRaisesRegex(self.m.Refusal, 'METAL_DOCKER_KEY'):
            self.m.apply_roots([{'action': 'docker'}])
        self.assertEqual(1, len(calls))
        self.assertEqual([], list((self.m.P/'state/tmp').iterdir()))

    def test_apply_holds_install_lock_across_root_and_account_actions(self):
        for directory in (self.m.P, self.m.P/'state', self.m.P/'state/tmp'):
            directory.mkdir(parents=True, exist_ok=True, mode=0o750)
        with self.plan_stubs():
            saved = self.m.envelope(self.m.make_plan())
            planfile = self.root/'plan.json'
            planfile.write_text(json.dumps(saved))
            events = []
            def locked(label):
                with open(self.m.P/'state/install.lock') as stream:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                events.append(label)
            def run(argv, **kwargs):
                self.assertIn('_account-apply', argv)
                locked('account')
                return subprocess.CompletedProcess(argv, 0, '', '')
            with patch.object(self.m, 'read_config', return_value=self.m.C), patch.object(self.m.os, 'geteuid', return_value=0), patch.object(self.m, 'apply_roots', side_effect=lambda actions: locked('root')), patch.object(self.m, 'run', side_effect=run), patch('sys.argv', ['metal', 'apply', '--plan', str(planfile)]), contextlib.redirect_stdout(io.StringIO()):
                self.m.main()
            self.assertEqual(['root', 'account'], events)
