"""Operator long validation dispatch; all Docker/process calls are intercepted."""
import ast
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load():
    loader = importlib.machinery.SourceFileLoader('operator_control_fixture', str(ROOT / 'bin/silo-migrate-control'))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class OperatorValidationTest(unittest.TestCase):
    def setUp(self):
        self.control = load()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.values = {'SILO_MIGRATE_BASE_PATH': str(self.root / 'workspaces'),
                       'SILO_CONTROL_GEMS': str(self.root / 'gems'),
                       'SILO_MERGE_VALIDATION_MODE': 'operator'}
        self.flag = self.control.LONG_MERGE_VALIDATION_FLAG
        self.proposal = ['standard', 'plan', 'propose', 'invented', '--operation', 'merge',
                         '--prepared-from', 'run-' + 'a'*32, '--generation', 'b'*64,
                         '--intent', 'custom', '--settings', 'input-' + 'c'*32]

    def launch(self, args):
        real_stat = Path.stat
        def socket_stat(path, *args, **kwargs):
            return types.SimpleNamespace(st_gid=99) if str(path) == '/var/run/docker.sock' else real_stat(path, *args, **kwargs)
        with mock.patch.object(self.control, 'settings', return_value=(self.values, False)), \
                mock.patch.object(Path, 'stat', socket_stat), \
                mock.patch.object(self.control.os, 'execvp') as execute:
            self.control.main(args)
        return execute.call_args.args[1]

    def test_installed_shim_loads_config_and_forwards_the_documented_long_command(self):
        doc = (ROOT / 'docs/merge-preparation.md').read_text()
        self.assertIn('CONTROL=/srv/silo-migrate/bin/silo-migrate-control', doc)
        self.assertNotIn('CONTROL=/srv/silo-migrate/current/bin/silo-migrate-control', doc)
        # Evaluate only the installer's literal shim-construction assignment,
        # never its installer or any host/container operation.
        source = (ROOT / 'script/metal').read_text().split(": <<'PYTHON'\n", 1)[1].rsplit('\nPYTHON', 1)[0]
        assignments = [node for node in ast.walk(ast.parse(source))
                       if isinstance(node, ast.Assign)
                       and any(isinstance(target, ast.Name) and target.id == 'shim' for target in node.targets)
                       and 'SILO_CONTROL_CONFIG' in ast.get_source_segment(source, node)]
        self.assertEqual(1, len(assignments))
        namespace = {'P': self.root, 'shlex': shlex}
        exec(compile(ast.Module(body=assignments, type_ignores=[]), '<installed shim fixture>', 'exec'), namespace)
        (self.root / 'etc').mkdir()
        config = self.root / 'etc/silo-control.env'
        config.write_text(''.join(key + '=' + self.values[key] + '\n'
                                 for key in ('SILO_MIGRATE_BASE_PATH', 'SILO_CONTROL_GEMS'))
                          + 'SILO_CONTROL_SITE_CACHE=' + str(self.root / 'site.yml') + '\n')
        target = self.root / 'current/bin/silo-migrate-control'
        target.parent.mkdir(parents=True)
        target.write_text('#!' + sys.executable + '\nimport json, os, sys\n'
                          'print(json.dumps({"config": os.environ.get("SILO_CONTROL_CONFIG"), "args": sys.argv[1:]}))\n')
        target.chmod(0o750)
        launcher = self.root / 'bin/silo-migrate-control'
        launcher.parent.mkdir()
        launcher.write_text(namespace['shim'])
        launcher.chmod(0o750)
        args = [self.flag, *self.proposal]
        result = subprocess.run([str(launcher), *args], capture_output=True, text=True, timeout=10,
                                env={'PATH': os.environ['PATH'], 'SILO_CONTROL_CONFIG': '/invented/wrong-config'})
        self.assertEqual(0, result.returncode, result.stderr)
        observed = json.loads(result.stdout)
        self.assertEqual({'config': str(config), 'args': args}, observed)
        # The installed shim forwards the read-only saved-attempt path too.
        read_args = ['standard', 'workflow', 'validation-status', 'invented', '--attempt', 'latest']
        read_result = subprocess.run([str(launcher), *read_args], capture_output=True, text=True, timeout=10,
                                     env={'PATH': os.environ['PATH']})
        self.assertEqual(0, read_result.returncode, read_result.stderr)
        self.assertEqual({'config': str(config), 'args': read_args}, json.loads(read_result.stdout))
        inspect_args = ['standard', 'workflow', 'validation-reconcile-inspect', 'invented', '--attempt', 'a' * 32]
        inspected = subprocess.run([str(launcher), *inspect_args], capture_output=True, text=True, timeout=10,
                                   env={'PATH': os.environ['PATH']})
        self.assertEqual(0, inspected.returncode, inspected.stderr)
        self.assertEqual({'config': str(config), 'args': inspect_args}, json.loads(inspected.stdout))
        with mock.patch.dict(os.environ, {'SILO_CONTROL_CONFIG': observed['config']}, clear=True):
            values, configured = self.control.settings()
        self.assertTrue(configured)
        self.assertEqual(self.values['SILO_CONTROL_GEMS'], values['SILO_CONTROL_GEMS'])

    def test_saved_status_uses_read_dispatch_without_long_mode_or_cleanup(self):
        args = ['standard', 'workflow', 'validation-status', 'invented', '--attempt', 'latest']
        command = self.launch(args)
        self.assertEqual(command[-len(args):], args)
        self.assertEqual('1', command[command.index('--cpus') + 1])
        self.assertIn('SILO_MERGE_VALIDATION_MODE=chat', command)
        self.assertIn('--read-only', command)
        with self.assertRaisesRegex(ValueError, '^STANDARD_ARGUMENTS_INVALID$'):
            self.control.merge_validation_options([self.flag, *args])

    def test_legacy_inspector_uses_read_dispatch_without_long_mode_or_cleanup(self):
        args = ['standard', 'workflow', 'validation-reconcile-inspect', 'invented', '--attempt', 'a' * 32]
        with mock.patch.object(self.control, 'host_merge_lifecycle_cleanup', wraps=self.control.host_merge_lifecycle_cleanup) as hook:
            command = self.launch(args)
        self.assertEqual(command[-len(args):], args)
        self.assertEqual('1', command[command.index('--cpus') + 1])
        self.assertIn('SILO_MERGE_VALIDATION_MODE=chat', command)
        self.assertIn('--read-only', command)
        hook.assert_called_once()
        # The real hook exits before loading state/data tools for a read command.
        with mock.patch.object(self.control, 'data_tools', side_effect=AssertionError('unexpected state access')):
            self.control.host_merge_lifecycle_cleanup(args, self.values, self.root, ROOT, self.control)
        with self.assertRaisesRegex(ValueError, '^STANDARD_ARGUMENTS_INVALID$'):
            self.control.merge_validation_options([self.flag, *args])

    def test_reset_preview_uses_read_dispatch_without_long_mode(self):
        args = ['standard', 'workflow', 'validation-reset-preview', 'invented', '--attempt', 'a' * 32]
        command = self.launch(args)
        self.assertEqual(command[-len(args):], args)
        self.assertEqual('1', command[command.index('--cpus') + 1])
        self.assertIn('SILO_MERGE_VALIDATION_MODE=chat', command)
        with self.assertRaisesRegex(ValueError, '^STANDARD_ARGUMENTS_INVALID$'):
            self.control.merge_validation_options([self.flag, *args])

    def test_reset_actions_refuse_detached_invocation_before_settings_or_runtime_access(self):
        with mock.patch.object(self.control, 'settings', side_effect=AssertionError('unexpected host access')):
            for action in ('validation-reset-preview', 'validation-reset-apply'):
                with self.assertRaisesRegex(ValueError, '^STANDARD_ARGUMENTS_INVALID$'):
                    self.control.main(['--detach', 'standard', 'workflow', action, 'invented', '--attempt', 'a' * 32])

    def test_only_explicit_operator_flag_changes_container_budget(self):
        for flag, mode in (([], 'chat'), ([self.flag], 'operator')):
            command = self.launch(flag + self.proposal)
            self.assertIn('SILO_MERGE_VALIDATION_MODE=' + mode, command)
            self.assertNotIn(self.flag, command)
            self.assertEqual(command[-len(self.proposal):], self.proposal)
            self.assertEqual('0.25', command[command.index('--cpus') + 1])
            self.assertEqual('512m', command[command.index('--memory') + 1])
            self.assertIn('--read-only', command)
            self.assertIn('no-new-privileges', command)

    def test_long_budget_rejects_chat_data_and_unrelated_or_misplaced_commands(self):
        bad = [[], ['data', 'invented'], ['--detach', *self.proposal],
               ['standard', 'status', 'invented'],
               ['standard', 'plan', 'approve', 'invented', 'plan-' + 'd'*32],
               ['standard', 'run', 'reset', 'invented', 'run-' + 'a'*32, '--yes'],
               [self.flag, *self.proposal], self.proposal + [self.flag]]
        for args in bad:
            with self.subTest(args=args), self.assertRaisesRegex(ValueError, '^STANDARD_ARGUMENTS_INVALID$'):
                self.control.merge_validation_options([self.flag, *args])
        with self.assertRaisesRegex(ValueError, '^STANDARD_ARGUMENTS_INVALID$'):
            self.control.merge_validation_options(self.proposal + [self.flag])

    def test_proposal_requires_prepared_custom_settings_and_single_options(self):
        for key in ('--operation', '--intent', '--prepared-from', '--generation', '--settings'):
            args = self.proposal.copy()
            index = args.index(key)
            del args[index:index+2]
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, '^STANDARD_ARGUMENTS_INVALID$'):
                self.control.merge_validation_options([self.flag, *args])
        for key, value in (('--operation', 'merge-prepare'), ('--intent', 'stock')):
            args = self.proposal.copy(); args[args.index(key)+1] = value
            with self.assertRaises(ValueError):
                self.control.merge_validation_options([self.flag, *args])
        with self.assertRaises(ValueError):
            self.control.merge_validation_options([self.flag, *self.proposal, '--operation', 'merge'])

    def test_supported_validation_and_start_commands(self):
        cases = [['standard', 'workflow', op, 'invented'] for op in ('validate', 'exists')]
        cases += [['standard', 'run', op, 'invented', 'plan-'+'d'*32] for op in ('claim', 'start')]
        for args in cases:
            self.assertEqual((args, True), self.control.merge_validation_options([self.flag, *args]))
        self.assertEqual((self.proposal, False), self.control.merge_validation_options(self.proposal))

    def test_background_start_keeps_long_budget_through_foreground_claim_only(self):
        claimed = {'status': 'claimed', 'run_id': 'run-' + 'e'*32}
        for long in (False, True):
            with self.subTest(long=long), \
                    mock.patch.object(self.control, 'settings', return_value=(self.values, False)), \
                    mock.patch.object(self.control, 'capture', return_value=json.dumps(claimed)) as capture, \
                    mock.patch.object(self.control.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0)) as detach, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                flag = [self.flag] if long else []
                self.assertEqual(0, self.control.main(flag + ['start-run', 'invented', 'plan-'+'d'*32]))
                expected = [str(ROOT / 'bin/silo-migrate-control'), *flag, 'standard', 'run', 'claim', 'invented', 'plan-'+'d'*32]
                options = {'passthrough': True, **({'timeout': 1980} if long else {})}
                capture.assert_called_once_with(expected, **options)
                args = detach.call_args.args[0]
                self.assertEqual(args[1:], ['--detach', 'standard', 'run', 'execute', 'invented', claimed['run_id']])
                self.assertNotIn(self.flag, args)
                self.assertEqual(claimed, json.loads(output.getvalue()))

    def test_failed_claim_never_launches_merge(self):
        with mock.patch.object(self.control, 'settings', return_value=(self.values, False)), \
                mock.patch.object(self.control, 'capture', side_effect=ValueError('STANDARD_MERGE_VALIDATION_STALE')), \
                mock.patch.object(self.control.subprocess, 'run') as execute, \
                self.assertRaisesRegex(ValueError, '^STANDARD_MERGE_VALIDATION_STALE$'):
            self.control.main([self.flag, 'start-run', 'invented', 'plan-'+'d'*32])
        execute.assert_not_called()

    def test_capture_has_a_longer_bound_only_when_requested(self):
        with mock.patch.object(self.control.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0, stdout='{}')) as run:
            self.control.capture(['invented'])
            self.assertEqual(600, run.call_args.kwargs['timeout'])
            self.control.capture(['invented'], timeout=1980)
            self.assertEqual(1980, run.call_args.kwargs['timeout'])
            self.assertEqual(self.control.subprocess.DEVNULL, run.call_args.kwargs['stdin'])


if __name__ == '__main__':
    unittest.main()
