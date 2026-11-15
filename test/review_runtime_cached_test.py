"""Conservative pinned-cache admission; no image, process or network effects."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def control_module():
    loader = importlib.machinery.SourceFileLoader('cached_control', str(ROOT / 'bin/silo-migrate-control'))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    result = importlib.util.module_from_spec(spec)
    loader.exec_module(result)
    return result


class CachedRuntimeAdmissionTest(unittest.TestCase):
    def setUp(self):
        self.control = control_module()
        self.schema = '20261101000000'
        self.metadata = dict(version='2026.11.0-latest', revision='a' * 40, ruby='3.3.0', bundler='2.6.9',
                             gemfile_lock_sha256='b' * 64, core_migrations=[self.schema], postgres_major='15')
        self.baseline = {'qualification': {'status': 'qualified'}, 'images': {'web': {'ref': 'pinned-cache', 'content_id': 'sha256:' + 'c' * 64}},
                         'app': dict(self.metadata, postgres_major='18')}
        self.document = {'Id': 'sha256:' + 'd' * 64}
        self.runtime = types.SimpleNamespace(inspect=mock.Mock(return_value=self.document),
            identity=mock.Mock(return_value='sha256:' + 'c' * 64), probe=mock.Mock(return_value=self.metadata),
            sandbox=mock.Mock(return_value=json.dumps([self.schema])))
        self.loader = types.SimpleNamespace(exec_module=mock.Mock())
        patcher = mock.patch.object(importlib.util, 'spec_from_file_location', return_value=types.SimpleNamespace(loader=self.loader))
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = mock.patch.object(importlib.util, 'module_from_spec', return_value=self.runtime)
        patcher.start()
        self.addCleanup(patcher.stop)

    def admit(self, **kw):
        args = dict(repo=ROOT, baseline=self.baseline, name='pinned-profile', version=self.metadata['version'],
                    schema=self.schema, required_migrations=[self.schema])
        args.update(kw)
        return self.control.cached_review_runtime(**args)

    def test_admits_actual_cached_identity_metadata_migrations_and_frozen_bundle_only(self):
        result = self.admit()
        self.assertEqual({'status': 'ready', 'name': 'pinned-profile', 'comparison': {
            'core_comparison_complete': True, 'missing_known_core_migrations': 0}}, result)
        self.runtime.inspect.assert_called_once_with('pinned-cache')
        self.runtime.probe.assert_called_once_with(self.document['Id'])
        argv = self.runtime.sandbox.call_args.args[0]
        for required in ('--pull=never', '--network=none', '--read-only', '--env=BUNDLE_FROZEN=true', '--env=BUNDLE_WITH=generic_import'):
            self.assertIn(required, argv)
        self.assertEqual([self.document['Id'], 'check'], argv[-2:])
        self.assertNotIn('--mount', argv)

    def test_mismatched_content_never_probes_or_checks_bundle(self):
        self.runtime.identity.return_value = 'sha256:' + 'e' * 64
        with self.assertRaisesRegex(ValueError, '^STANDARD_RUNTIME_MISMATCH$'):
            self.admit()
        self.runtime.probe.assert_not_called()
        self.runtime.sandbox.assert_not_called()

    def test_absent_cached_image_has_no_acquisition_fallback(self):
        self.runtime.inspect.side_effect = ValueError('STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED')
        with self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED$'):
            self.admit()
        self.runtime.probe.assert_not_called()
        self.runtime.sandbox.assert_not_called()

    def test_version_revision_lock_or_plugin_migration_mismatch_never_becomes_ready(self):
        for key, replacement in [('version', '2026.10.0-latest'), ('revision', 'e' * 40),
                                 ('gemfile_lock_sha256', 'e' * 64), ('ruby', '3.3.1'), ('bundler', '2.6.8')]:
            with self.subTest(key=key):
                altered = dict(self.metadata, **{key: replacement})
                self.runtime.probe.return_value = altered
                with self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_UNRESOLVED$'):
                    self.admit()
        self.runtime.sandbox.assert_not_called()

    def test_unqualified_missing_unsorted_duplicate_or_malformed_inventory_refuses_before_probe(self):
        cases = [dict(version=None), dict(required_migrations=None), dict(required_migrations=[]),
                 dict(required_migrations=[{}]), dict(required_migrations=[self.schema, self.schema]),
                 dict(required_migrations=[self.schema, '20260101000000']), dict(schema='20261201000000'),
                 dict(baseline=dict(self.baseline, qualification={'status': 'unqualified'}))]
        for kw in cases:
            with self.subTest(kw=kw), self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_UNRESOLVED$'):
                self.admit(**kw)
        self.runtime.inspect.assert_not_called()

    def test_postgres_requirement_cannot_be_lowered(self):
        self.runtime.probe.return_value = dict(self.metadata, postgres_major='19')
        with self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_POSTGRES_INCOMPATIBLE$'):
            self.admit()
        self.runtime.sandbox.assert_not_called()

    def test_history_must_be_actual_public_core_inventory_not_a_filtered_backup(self):
        # Historical IDs may be absent from current filenames but present in the
        # canonical public schema. Their actual shipped history is still required.
        self.runtime.probe.return_value = dict(self.metadata, core_migrations=['20261001000000'])
        self.assertEqual('ready', self.admit()['status'])
        first = self.runtime.sandbox.call_args_list[0].args[0]
        self.assertEqual([self.document['Id'], '-e', self.control.CACHED_CORE_HISTORY_PROBE], first[-3:])
        self.assertIn('--network=none', first)
        self.assertNotIn('--mount', first)
        for history in ([], ['20260901000000'], [self.schema, self.schema], [False], {'private': self.schema}):
            self.runtime.sandbox.reset_mock()
            self.runtime.sandbox.return_value = json.dumps(history)
            with self.subTest(history=history), self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_UNRESOLVED$'):
                self.admit()
            self.assertEqual(1, self.runtime.sandbox.call_count)  # never reaches bundle

    def test_failed_bundle_check_does_not_admit(self):
        self.runtime.sandbox.side_effect = [json.dumps([self.schema]), ValueError('STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED')]
        with self.assertRaisesRegex(ValueError, '^STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED$'):
            self.admit()
        self.assertEqual(2, self.runtime.sandbox.call_count)


class CachedRuntimeFlagTest(unittest.TestCase):
    def setUp(self):
        self.control = control_module()
        self.flag = '--cached-review-runtime'
        self.args = ['standard', 'plan', 'propose', 'invented', '--operation', 'merge-prepare',
                     '--source', 'input-' + 'a' * 32, '--base-site', 'input-' + 'b' * 32]

    def test_explicit_prefix_only_and_default_unchanged(self):
        self.assertEqual((self.args, False), self.control.cached_runtime_options(self.args))
        self.assertEqual((self.args, True), self.control.cached_runtime_options([self.flag, *self.args]))
        for args in ([*self.args, self.flag], [self.flag, self.flag, *self.args],
                     [self.flag, 'standard', 'status', 'invented'],
                     [self.flag, 'standard', 'workflow', 'validate', 'invented'],
                     [self.flag, *self.args, '--prepared-from', 'run-' + 'c' * 32]):
            with self.subTest(args=args), self.assertRaisesRegex(ValueError, '^STANDARD_ARGUMENTS_INVALID$'):
                self.control.cached_runtime_options(args)

    def test_unconfigured_invocation_cannot_silently_ignore_the_operator_flag(self):
        with mock.patch.object(self.control, 'settings', return_value=({}, False)), \
                self.assertRaisesRegex(ValueError, '^STANDARD_CONTROL_CONFIG_INVALID$'):
            self.control.main([self.flag, *self.args])


if __name__ == '__main__':
    unittest.main()
