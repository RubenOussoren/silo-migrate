"""Object-only local rebase boundary tests. No network or customer fixtures.

Run: python3 -I -B test/converter_rebase_test.py
"""
import importlib.util
import json
import os
from pathlib import Path
import runpy
import subprocess
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


def git(path, *args):
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
               GIT_AUTHOR_NAME='Invented Author', GIT_AUTHOR_EMAIL='author@example.invalid',
               GIT_COMMITTER_NAME='Invented Committer', GIT_COMMITTER_EMAIL='committer@example.invalid')
    return subprocess.run(['git', '-C', str(path), *args], env=env, check=True,
                          capture_output=True, text=True).stdout.strip()


class RebaseTest(unittest.TestCase):
    def setUp(self):
        previous = os.umask(0o022)
        self.addCleanup(os.umask, previous)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.dev, self.helper = load('converter_dev'), load('converter_rebase')
        self.host = types.SimpleNamespace(**runpy.run_path(str(ROOT / 'bin/silo-migrate-control')))
        self.workspace = 'invented-forum'
        self.root = self.base / 'workspaces' / self.workspace
        self.standard = self.root / '.silo-migrate/named/standard'
        self.standard.mkdir(parents=True)
        (self.standard.parent / 'state.json').write_text('{}')
        self.seed = self.base / 'seed'
        self.seed.mkdir()
        git(self.seed, 'init', '-q', '-b', 'main')
        self.write(self.seed, 'code.rb', 'base\n')
        self.write(self.seed, 'other.rb', 'other base\n')
        self.write(self.seed, '.gitignore', '*.sqlite\nprivate/\n')
        git(self.seed, 'add', '.')
        git(self.seed, 'commit', '-qm', 'Invented base')
        self.origin = self.base / 'origin.git'
        git(self.base, 'clone', '-q', '--bare', str(self.seed), str(self.origin))
        self.path = self.root / 'converter'
        git(self.root, 'clone', '-q', str(self.origin), str(self.path))
        git(self.path, 'config', 'user.name', 'Invented Engineer')
        git(self.path, 'config', 'user.email', 'engineer@example.invalid')
        self.state = {'config': {'converter_worktree': str(self.path)}, 'runs': {}}
        self.save_state()
        self.checkout = self.dev.Checkout(self.base / 'workspaces', self.workspace, self.host)
        self.branch = self.checkout.migration_prefix() + 'invented-change'
        git(self.path, 'checkout', '-qb', self.branch)
        self.checkout.save_manifest({'files': {}, 'branches': [self.branch]})
        patch = mock.patch.object(self.dev, 'fetchable', return_value=True)
        patch.start()
        self.addCleanup(patch.stop)
        # All credentials calls short-circuit on local origins, with no token reads.
        self.assertIsNone(self.host.github_credentials(self.path, str(self.origin)))

    def save_state(self):
        (self.standard / 'state.json').write_text(json.dumps(self.state))

    @staticmethod
    def write(root, name, text):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def commit(self, name='code.rb', text='local change\n'):
        self.write(self.path, name, text)
        git(self.path, 'add', name)
        git(self.path, 'commit', '-qm', 'Invented local change')
        return git(self.path, 'rev-parse', 'HEAD')

    def advance_main(self, name='other.rb', text='upstream change\n'):
        self.write(self.seed, name, text)
        git(self.seed, 'add', '-f', name)
        git(self.seed, 'commit', '-qm', 'Invented main change')
        git(self.seed, 'push', '-q', str(self.origin), 'main')
        return git(self.seed, 'rev-parse', 'HEAD')

    def rebase(self):
        with self.dev.DevLock(self.checkout, wait=0):
            return self.helper.rebase_main(self.checkout, self.dev, self.base / 'home')

    def snapshot(self):
        return (git(self.path, 'rev-parse', 'HEAD'),
                (self.path / '.git/index').read_bytes(),
                (self.path / 'code.rb').read_bytes(), (self.path / 'other.rb').read_bytes())

    def refused(self, code):
        with self.assertRaises(self.dev.Refusal) as raised:
            self.rebase()
        self.assertEqual(code, str(raised.exception))

    def test_published_divergence_and_pinned_lease(self):
        before = self.commit()
        git(self.path, 'push', '-q', 'origin', self.branch)
        main = self.advance_main()
        result = self.rebase()
        self.assertEqual('rebased', result['status'])
        self.assertNotEqual(before, result['head'])
        self.assertTrue(result['rewrite_required'])
        self.assertEqual(main, git(self.path, 'rev-parse', 'HEAD^'))
        self.assertEqual(before, git(self.path, 'rev-parse', result['backup_ref']))
        self.assertEqual('Invented Author <author@example.invalid>', git(self.path, 'show', '-s', '--format=%an <%ae>'))
        self.assertEqual('Invented Engineer <engineer@example.invalid>', git(self.path, 'show', '-s', '--format=%cn <%ce>'))
        meta = self.helper.rewrite_metadata(self.checkout, self.dev)
        self.assertEqual('force-with-lease', meta['mode'])
        self.assertEqual(before, meta['expected_remote_head'])
        self.assertEqual(main, meta['main_head'])
        self.assertEqual(before, git(self.origin, 'rev-parse', 'refs/heads/' + self.branch))
        self.assertEqual('', git(self.path, 'status', '--porcelain'))
        record = self.helper._record(self.checkout)
        self.assertEqual(0o600, self.helper._record_path(self.checkout).stat().st_mode & 0o777)
        self.assertEqual(result['head'], record['after_head'])

    def test_unpublished_and_already_ancestor_need_normal_push(self):
        self.commit()
        self.advance_main()
        self.assertFalse(self.rebase()['rewrite_required'])
        self.assertIsNone(self.helper.rewrite_metadata(self.checkout, self.dev))
        git(self.path, 'push', '-q', 'origin', self.branch)
        git(self.path, 'fetch', '-q', 'origin')
        self.assertIsNone(self.helper.rewrite_metadata(self.checkout, self.dev))
        self.commit('code.rb', 'another local change\n')
        self.assertIsNone(self.helper.rewrite_metadata(self.checkout, self.dev))

    def test_repeated_rebase_keeps_original_pinned_lease(self):
        before = self.commit()
        git(self.path, 'push', '-q', 'origin', self.branch)
        self.advance_main()
        first = self.rebase()
        self.commit('addition.rb', 'local continuation\n')
        self.advance_main('other.rb', 'second upstream\n')
        second = self.rebase()
        self.assertNotEqual(first['head'], second['head'])
        self.assertEqual(before, self.helper.rewrite_metadata(self.checkout, self.dev)['expected_remote_head'])
        self.assertEqual('local continuation\n', (self.path / 'addition.rb').read_text())
        # A teammate appends to the ORIGINAL published branch, unseen by this agent.
        git(self.seed, 'fetch', '-q', str(self.origin), self.branch)
        git(self.seed, 'checkout', '-q', '--detach', 'FETCH_HEAD')
        self.write(self.seed, 'teammate.rb', 'teammate change\n')
        git(self.seed, 'add', 'teammate.rb')
        git(self.seed, 'commit', '-qm', 'Invented teammate')
        git(self.seed, 'push', '-q', str(self.origin), 'HEAD:refs/heads/' + self.branch)
        snapshot = self.snapshot()
        self.refused('STANDARD_REBASE_REMOTE_DIVERGED')
        self.assertEqual(snapshot, self.snapshot())
        with self.assertRaisesRegex(self.dev.Refusal, '^STANDARD_REBASE_REMOTE_DIVERGED$'):
            self.helper.rewrite_metadata(self.checkout, self.dev)

    def test_dirty_files_index_and_agent_new_require_checkpoint(self):
        self.commit()
        self.advance_main()
        for kind in ('tracked', 'staged', 'agent-new', 'assume', 'skip'):
            with self.subTest(kind=kind):
                git(self.path, 'reset', '--hard', 'HEAD')
                git(self.path, 'update-index', '--no-assume-unchanged', '--no-skip-worktree', 'code.rb')
                self.checkout.save_manifest({'files': {}, 'branches': [self.branch]})
                if kind == 'agent-new':
                    self.write(self.path, 'agent.rb', 'checkpoint me\n')
                    self.checkout.record_write('agent.rb', b'checkpoint me\n')
                else:
                    if kind in ('assume', 'skip'):
                        git(self.path, 'update-index', '--assume-unchanged' if kind == 'assume' else '--skip-worktree', 'code.rb')
                    self.write(self.path, 'code.rb', 'uncommitted canary\n')
                    if kind == 'staged':
                        git(self.path, 'add', 'code.rb')
                snapshot = self.snapshot()
                self.refused('STANDARD_REBASE_CHECKPOINT_REQUIRED')
                self.assertEqual(snapshot, self.snapshot())
                git(self.path, 'update-index', '--no-assume-unchanged', '--no-skip-worktree', 'code.rb')

    def test_private_untracked_and_ignored_files_are_untouched_and_invisible(self):
        self.commit()
        self.advance_main()
        names = ['private/synthetic.sqlite', 'unknown-hidden.csv', '.private-canary', 'ignored.sqlite']
        for name in names:
            self.write(self.path, name, 'PRIVATE INVENTED CANARY\n')
        (self.path / 'unrelated-link').symlink_to(self.base / 'absent')
        before = {name: (self.path / name).read_bytes() for name in names}
        result = self.rebase()
        self.assertEqual('rebased', result['status'])
        for name in names:
            self.assertEqual(before[name], (self.path / name).read_bytes())
            self.assertNotIn(name, json.dumps(result))
        self.assertNotIn('PRIVATE INVENTED CANARY', json.dumps(result))
        self.assertTrue((self.path / 'unrelated-link').is_symlink())

    def test_new_path_and_symlink_parent_collisions(self):
        self.commit()
        self.advance_main('incoming/new.rb', 'main new code\n')
        private = self.write(self.path, 'incoming/new.rb', 'PRIVATE INVENTED CANARY\n')
        snapshot = self.snapshot()
        self.refused('STANDARD_REBASE_COLLISION')
        self.assertEqual(snapshot, self.snapshot())
        self.assertEqual('PRIVATE INVENTED CANARY\n', private.read_text())
        private.unlink()
        private.parent.rmdir()
        outside = self.base / 'outside'
        outside.mkdir()
        (self.path / 'incoming').symlink_to(outside, target_is_directory=True)
        self.refused('STANDARD_REBASE_COLLISION')
        self.assertEqual([], list(outside.iterdir()))
        self.assertEqual(snapshot, self.snapshot())

    def test_conflict_never_changes_live_head_index_or_worktree(self):
        self.commit()
        self.advance_main('code.rb', 'conflicting upstream\n')
        snapshot = self.snapshot()
        result = self.rebase()
        self.assertEqual('conflict', result['status'])
        self.assertEqual(['code.rb'], result['paths'])
        self.assertIn('unchanged', result['note'])
        self.assertEqual(snapshot, self.snapshot())
        self.assertFalse((self.path / '.git/rebase-merge').exists())
        self.assertFalse((self.path / '.git/rebase-apply').exists())

    def test_active_run_and_parallel_locks_refuse(self):
        self.state['runs'] = {'invented-run': {'status': 'running'}}
        self.save_state()
        self.refused('STANDARD_BUSY')
        self.state['runs'] = {}
        self.save_state()
        with self.dev.Locked(self.checkout):
            self.refused('STANDARD_BUSY')
        with self.dev.DevLock(self.checkout, wait=0):
            self.refused('STANDARD_BUSY')

    def test_hooks_and_global_config_disabled(self):
        self.commit()
        self.advance_main()
        marker = self.base / 'hook-ran'
        for name in ('pre-rebase', 'post-checkout', 'post-rewrite', 'reference-transaction'):
            hook = self.write(self.path, '.git/hooks/' + name, '#!/bin/sh\ntouch ' + str(marker) + '\nexit 1\n')
            hook.chmod(0o755)
        hostile = self.write(self.base, 'hostile-config', '[core]\n hooksPath = ' + str(self.path / '.git/hooks') + '\n[rebase]\n autoStash = true\n')
        with mock.patch.dict(os.environ, {'GIT_CONFIG_GLOBAL': str(hostile)}):
            self.assertEqual('rebased', self.rebase()['status'])
        self.assertFalse(marker.exists())
        git(self.path, 'config', 'core.hooksPath', str(self.path / '.git/hooks'))
        with self.assertRaises(ValueError) as raised:
            self.dev.Checkout(self.base / 'workspaces', self.workspace, self.host)
        self.assertTrue(str(raised.exception).startswith('STANDARD_CONVERTER_CONFIG'))

    def test_scratch_timeout_preserves_live_state(self):
        self.commit()
        self.advance_main()
        original = subprocess.run
        def bounded(argv, **kwargs):
            if 'rebase' in argv:
                self.assertEqual(90, kwargs['timeout'])
                raise subprocess.TimeoutExpired(argv, 90)
            return original(argv, **kwargs)
        snapshot = self.snapshot()
        with mock.patch.object(self.helper.subprocess, 'run', side_effect=bounded):
            self.refused('STANDARD_REBASE_TIMEOUT')
        self.assertEqual(snapshot, self.snapshot())

    def test_install_failure_rolls_back_tracked_files_and_head(self):
        self.commit()
        self.advance_main()
        snapshot = self.snapshot()
        with mock.patch.object(self.dev, 'write_record', side_effect=OSError('invented failure')):
            self.refused('STANDARD_REBASE_FAILED')
        self.assertEqual(snapshot, self.snapshot())
        self.assertFalse((self.path / '.git/index.lock').exists())

    def test_manifest_write_failure_rolls_back_live_install(self):
        self.commit()
        self.advance_main()
        snapshot = self.snapshot()
        with mock.patch.object(self.checkout, 'save_manifest', side_effect=OSError('invented failure')):
            self.refused('STANDARD_REBASE_FAILED')
        self.assertEqual(snapshot, self.snapshot())
        self.assertFalse((self.path / '.git/index.lock').exists())
        self.assertIsNone(self.helper._record(self.checkout))

    def test_untrusted_and_nonmigration_branches_refuse(self):
        self.commit()
        self.checkout.save_manifest({'files': {}, 'branches': []})
        self.refused('STANDARD_DEV_BRANCH_UNTRUSTED')
        git(self.path, 'checkout', '-q', 'main')
        self.refused('STANDARD_DEV_NOT_MIGRATION_BRANCH')

    def test_ignored_incoming_collision_and_deleted_index_entry(self):
        self.commit()
        self.advance_main('incoming.sqlite', 'invented committed data\n')
        self.write(self.path, 'incoming.sqlite', 'PRIVATE INVENTED CANARY\n')
        snapshot = self.snapshot()
        self.refused('STANDARD_REBASE_COLLISION')
        self.assertEqual(snapshot, self.snapshot())
        self.assertEqual('PRIVATE INVENTED CANARY\n', (self.path / 'incoming.sqlite').read_text())
        (self.path / 'incoming.sqlite').unlink()
        git(self.path, 'rm', '--cached', 'other.rb')
        snapshot = self.snapshot()
        self.refused('STANDARD_REBASE_CHECKPOINT_REQUIRED')
        self.assertEqual(snapshot, self.snapshot())

    def test_fresh_fetch_is_not_throttled_and_has_fixed_budget(self):
        self.commit()
        self.advance_main()
        self.dev.fetch_origin(self.checkout)
        main = self.advance_main('other.rb', 'newer main after recent fetch\n')
        original = subprocess.run
        calls = []
        def bounded(argv, **kwargs):
            if 'fetch' in argv and 'origin' in argv:
                calls.append(argv)
                self.assertEqual(40, kwargs['timeout'])
            return original(argv, **kwargs)
        with mock.patch.object(self.helper.subprocess, 'run', side_effect=bounded):
            self.assertEqual(main, self.rebase()['main_head'])
        self.assertEqual(1, len(calls))

    def test_fetch_timeout_and_unapproved_origin_never_change_live_state(self):
        self.commit()
        self.advance_main()
        snapshot = self.snapshot()
        with mock.patch.object(self.dev, 'fetchable', return_value=False):
            self.refused('STANDARD_REBASE_ORIGIN_REFUSED')
        original = subprocess.run
        def bounded(argv, **kwargs):
            if 'fetch' in argv and 'origin' in argv:
                raise subprocess.TimeoutExpired(argv, 40)
            return original(argv, **kwargs)
        with mock.patch.object(self.helper.subprocess, 'run', side_effect=bounded):
            self.refused('STANDARD_REBASE_TIMEOUT')
        self.assertEqual(snapshot, self.snapshot())

    def test_remote_trusted_branch_without_manifest_is_accepted(self):
        self.commit()
        git(self.path, 'push', '-q', 'origin', self.branch)
        self.checkout.save_manifest({'files': {}, 'branches': []})
        self.advance_main()
        self.assertEqual('rebased', self.rebase()['status'])

    def test_first_rebase_refuses_unmerged_teammate_branch_commits(self):
        before = self.commit()
        git(self.path, 'push', '-q', 'origin', self.branch)
        git(self.seed, 'fetch', '-q', str(self.origin), self.branch)
        git(self.seed, 'checkout', '-q', '--detach', 'FETCH_HEAD')
        self.write(self.seed, 'teammate.rb', 'invented teammate\n')
        git(self.seed, 'add', 'teammate.rb')
        git(self.seed, 'commit', '-qm', 'Invented teammate')
        git(self.seed, 'push', '-q', str(self.origin), 'HEAD:refs/heads/' + self.branch)
        snapshot = self.snapshot()
        self.refused('STANDARD_REBASE_REMOTE_DIVERGED')
        self.assertEqual(before, git(self.path, 'rev-parse', 'HEAD'))
        self.assertEqual(snapshot, self.snapshot())

    def test_preexisting_git_operation_states_refused_before_fetch(self):
        self.commit()
        self.advance_main()
        for name in ('rebase-merge', 'rebase-apply', 'CHERRY_PICK_HEAD', 'REVERT_HEAD',
                     'MERGE_HEAD', 'BISECT_LOG', 'BISECT_START', 'sequencer'):
            with self.subTest(name=name):
                path = self.path / '.git' / name
                path.write_text('invented existing operation\n')
                snapshot = self.snapshot()
                with mock.patch.object(self.helper, '_fetch') as fetch:
                    self.refused('STANDARD_REBASE_IN_PROGRESS')
                    fetch.assert_not_called()
                self.assertEqual(snapshot, self.snapshot())
                path.unlink()

    def test_identity_home_fallback_and_missing_identity_refusal(self):
        self.commit()
        self.advance_main()
        git(self.path, 'config', '--unset', 'user.name')
        git(self.path, 'config', '--unset', 'user.email')
        self.refused('STANDARD_DEV_IDENTITY_MISSING')
        identity = self.write(self.base / 'home', '.config/silo-migrate/git-identity',
                              'name=Invented Home Engineer\nemail=home-engineer@example.invalid\n')
        identity.chmod(0o600)
        self.assertEqual('rebased', self.rebase()['status'])
        self.assertEqual('Invented Home Engineer <home-engineer@example.invalid>',
                         git(self.path, 'show', '-s', '--format=%cn <%ce>'))

    def seed_tracked_links(self):
        canary = self.write(self.base, 'outside/private-canary', 'PRIVATE INVENTED CANARY\n')
        targets = {'tracked-link': str(canary), 'dangling-link': '../invented-absent',
                   'outside-directory-link': str(canary.parent)}
        for name, target in targets.items():
            (self.seed / name).symlink_to(target)
        git(self.seed, 'add', '.')
        git(self.seed, 'commit', '-qm', 'Invented base links')
        git(self.seed, 'push', '-q', str(self.origin), 'main')
        git(self.path, 'fetch', '-q', 'origin')
        git(self.path, 'merge', '-q', '--ff-only', 'origin/main')
        return canary, targets

    def test_unchanged_tracked_links_preserved_without_opening_targets(self):
        canary, targets = self.seed_tracked_links()
        self.commit()
        self.advance_main()
        before = {name: (self.path / name).lstat() for name in targets}
        original_open = os.open
        def no_private_open(path, *args, **kwargs):
            self.assertNotEqual(os.fsencode(canary), os.fsencode(path))
            self.assertNotEqual(os.fsencode(self.path / 'tracked-link'), os.fsencode(path))
            return original_open(path, *args, **kwargs)
        with mock.patch.object(self.helper.os, 'open', side_effect=no_private_open):
            result = self.rebase()
        self.assertEqual('rebased', result['status'])
        for name, target in targets.items():
            self.assertTrue((self.path / name).is_symlink())
            self.assertEqual(target, os.readlink(self.path / name))
            after = (self.path / name).lstat()
            self.assertEqual((before[name].st_ino, before[name].st_mode, before[name].st_mtime_ns),
                             (after.st_ino, after.st_mode, after.st_mtime_ns))
        self.assertEqual('PRIVATE INVENTED CANARY\n', canary.read_text())
        self.assertNotIn(str(canary), json.dumps(result))
        self.assertNotIn('PRIVATE INVENTED CANARY', json.dumps(result))
        self.host.converter_config_safe(self.path)

    def test_dirty_tracked_link_requires_checkpoint_without_following_target(self):
        canary, targets = self.seed_tracked_links()
        self.commit()
        self.advance_main()
        link = self.path / 'tracked-link'
        for flag in (None, '--assume-unchanged', '--skip-worktree'):
            with self.subTest(flag=flag):
                if flag:
                    git(self.path, 'update-index', flag, 'tracked-link')
                link.unlink()
                link.symlink_to('../invented-modified-target')
                snapshot = self.snapshot()
                self.refused('STANDARD_REBASE_CHECKPOINT_REQUIRED')
                self.assertEqual(snapshot, self.snapshot())
                self.assertEqual('../invented-modified-target', os.readlink(link))
                git(self.path, 'update-index', '--no-assume-unchanged', '--no-skip-worktree', 'tracked-link')
                link.unlink()
                link.symlink_to(targets['tracked-link'])
        link.unlink()
        link.write_text(targets['tracked-link'])
        self.refused('STANDARD_REBASE_CHECKPOINT_REQUIRED')
        self.assertEqual('PRIVATE INVENTED CANARY\n', canary.read_text())

    def test_incoming_symlink_add_remove_target_and_mode_changes_refused(self):
        canary, targets = self.seed_tracked_links()
        self.commit()
        snapshot = self.snapshot()
        for change in ('target', 'remove', 'mode', 'addition'):
            with self.subTest(change=change):
                link = self.seed / 'tracked-link'
                if os.path.lexists(link):
                    link.unlink()
                if change == 'target':
                    link.symlink_to('../invented-other-target')
                elif change == 'mode':
                    link.write_text('invented regular replacement\n')
                elif change == 'addition':
                    link.symlink_to(targets['tracked-link'])
                    (self.seed / 'incoming-link').symlink_to(str(canary))
                git(self.seed, 'add', '-A')
                git(self.seed, 'commit', '-qm', 'Invented incoming link ' + change)
                git(self.seed, 'push', '-q', str(self.origin), 'main')
                self.refused('STANDARD_REBASE_UNSUPPORTED_TREE')
                self.assertEqual(snapshot, self.snapshot())
                self.assertEqual(targets['tracked-link'], os.readlink(self.path / 'tracked-link'))
                self.assertFalse(os.path.lexists(self.path / 'incoming-link'))
                self.assertEqual('PRIVATE INVENTED CANARY\n', canary.read_text())

    def test_incoming_gitmodules_path_components_refused(self):
        self.commit()
        snapshot = self.snapshot()
        for name in ('.gitmodules', 'nested/.gitmodules/entry'):
            with self.subTest(name=name):
                if name != '.gitmodules':
                    git(self.seed, 'rm', '.gitmodules')
                self.advance_main(name, 'invented protected path\n')
                self.refused('STANDARD_REBASE_UNSUPPORTED_TREE')
                self.assertEqual(snapshot, self.snapshot())
                self.assertFalse(os.path.lexists(self.path / name))

    def test_gitfile_or_symlink_git_directory_refused_before_mutation(self):
        self.commit()
        before = self.snapshot()
        dotgit = self.path / '.git'
        saved_git = self.path / '.saved-invented-git'
        dotgit.rename(saved_git)
        for kind in ('gitfile', 'symlink'):
            with self.subTest(kind=kind):
                if kind == 'gitfile':
                    dotgit.write_text('gitdir: .saved-invented-git\n')
                else:
                    dotgit.symlink_to(saved_git, target_is_directory=True)
                # It is a valid Gitfile/link, but this helper explicitly refuses it.
                self.assertEqual(before[0], git(self.path, 'rev-parse', 'HEAD'))
                marker = dotgit.read_bytes() if kind == 'gitfile' else os.readlink(dotgit)
                with mock.patch.object(self.helper, '_fetch') as fetch:
                    self.refused('STANDARD_CONVERTER_CONFIG')
                    fetch.assert_not_called()
                self.assertEqual(before[1], (saved_git / 'index').read_bytes())
                self.assertEqual(before[2], (self.path / 'code.rb').read_bytes())
                self.assertEqual(marker, dotgit.read_bytes() if kind == 'gitfile' else os.readlink(dotgit))
                dotgit.unlink()
        saved_git.rename(dotgit)
        self.assertEqual(before, self.snapshot())

    def test_index_read_failure_is_under_lock_and_cleans_lock(self):
        self.commit()
        self.advance_main()
        snapshot = self.snapshot()
        original = Path.read_bytes
        def unreadable_index(path):
            if path == self.path / '.git/index':
                self.assertTrue((self.path / '.git/index.lock').is_file())
                raise OSError('invented unreadable index')
            return original(path)
        with mock.patch.object(Path, 'read_bytes', unreadable_index):
            self.refused('STANDARD_REBASE_FAILED')
        self.assertFalse((self.path / '.git/index.lock').exists())
        self.assertEqual(snapshot, self.snapshot())

    def test_record_cannot_authorize_non_descendant_or_unpinned_remote(self):
        before = self.commit()
        git(self.path, 'push', '-q', 'origin', self.branch)
        self.advance_main()
        result = self.rebase()
        record_path = self.helper._record_path(self.checkout)
        record = json.loads(record_path.read_text())
        record['expected_remote_head'] = '0' * 40
        self.dev.write_record(record_path, record)
        with self.assertRaisesRegex(self.dev.Refusal, '^STANDARD_REBASE_REMOTE_DIVERGED$'):
            self.helper.rewrite_metadata(self.checkout, self.dev)
        record['expected_remote_head'] = before
        self.dev.write_record(record_path, record)
        git(self.path, 'reset', '--hard', result['main_head'])
        with self.assertRaisesRegex(self.dev.Refusal, '^STANDARD_REBASE_REMOTE_DIVERGED$'):
            self.helper.rewrite_metadata(self.checkout, self.dev)

    def test_branch_cas_failure_rolls_back_before_ref_change(self):
        self.commit()
        self.advance_main()
        snapshot = self.snapshot()
        original = self.checkout.git
        def fail_cas(*args, **kwargs):
            if args[:2] == ('update-ref', 'refs/heads/' + self.branch):
                self.dev.refuse('STANDARD_OPERATION_FAILED')
            return original(*args, **kwargs)
        with mock.patch.object(self.checkout, 'git', side_effect=fail_cas):
            self.refused('STANDARD_OPERATION_FAILED')
        self.assertEqual(snapshot, self.snapshot())
        self.assertFalse((self.path / '.git/index.lock').exists())

    def test_shallow_source_boundary_survives_object_only_scratch_transfer(self):
        self.advance_main('history.rb', 'older committed history\n')
        self.path.rename(self.root / 'full-checkout')
        git(self.root, 'clone', '-q', '--depth', '1', '--branch', 'main', 'file://' + str(self.origin), str(self.path))
        git(self.path, 'remote', 'set-url', 'origin', str(self.origin))  # approved local fixture transport
        git(self.path, 'config', 'user.name', 'Invented Engineer')
        git(self.path, 'config', 'user.email', 'engineer@example.invalid')
        git(self.path, 'checkout', '-qb', self.branch)
        self.checkout = self.dev.Checkout(self.base / 'workspaces', self.workspace, self.host)
        self.checkout.save_manifest({'files': {}, 'branches': [self.branch]})
        self.assertEqual('true', git(self.path, 'rev-parse', '--is-shallow-repository'))
        boundary = (self.path / '.git/shallow').read_bytes()
        self.commit()
        main = self.advance_main()
        result = self.rebase()
        self.assertEqual('rebased', result['status'])
        self.assertEqual(main, result['main_head'])
        self.assertEqual('local change\n', (self.path / 'code.rb').read_text())
        self.assertEqual('upstream change\n', (self.path / 'other.rb').read_text())
        self.assertEqual(boundary, (self.path / '.git/shallow').read_bytes())
        self.assertEqual('true', git(self.path, 'rev-parse', '--is-shallow-repository'))

    def test_local_merge_commit_refused(self):
        self.commit()
        git(self.path, 'checkout', '-qb', 'invented-side', 'HEAD^')
        self.commit('side.rb', 'invented side\n')
        git(self.path, 'checkout', '-q', self.branch)
        git(self.path, 'merge', '--no-ff', '-qm', 'Invented merge', 'invented-side')
        self.refused('STANDARD_REBASE_MERGES_UNSUPPORTED')


if __name__ == '__main__':
    unittest.main()
