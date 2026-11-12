"""Offline native-package custody/installer tests; invented compiled ELF only."""
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
import struct
import stat
import pwd
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('private_node', str(ROOT / 'script/private-node'))
spec = importlib.util.spec_from_loader('private_node', loader)
node = importlib.util.module_from_spec(spec)
loader.exec_module(node)


class PrivateNodeTest(unittest.TestCase):
    def setUp(self):
        old_umask = os.umask(0o022)
        self.addCleanup(os.umask, old_umask)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'framework'
        (self.source / 'runtime').mkdir(parents=True)
        patch_dir = self.source / 'integrations/term-llm/patches'
        patch_dir.mkdir(parents=True)
        (patch_dir / 'conversation-scope.patch').write_bytes(b'invented-reviewed-patch\n')
        self.expected = {'version': '0.9.103', 'base_commit': 'a' * 40,
                         'patch_sha256': hashlib.sha256(b'invented-reviewed-patch\n').hexdigest()}
        (self.source / 'runtime/private-node-source.json').write_text(json.dumps(self.expected))
        self.binary = self.root / 'built-node'
        code = self.root / 'fixture.c'
        code.write_text(r'''#include <stdio.h>
#include <string.h>
#define SERVE_HELP_BYTES 10323
int main(int argc, char **argv) {
 if (argc > 1 && !strcmp(argv[1], "capabilities"))
  puts("{\"custom_tool_session_context\": 1, \"session_scope_lock\": 1}");
 else if (argc > 1 && !strcmp(argv[1], "--version")) puts("term-llm version v0.9.103");
 else if (argc > 1 && !strcmp(argv[1], "serve")) {
  const char *flags = "--host --port --auth --approval --agent --projects --widgets-dir --extensions-dir --extensions";
  fputs(flags, stdout);
  for (size_t i = strlen(flags); i < SERVE_HELP_BYTES; i++) putchar(' ');
 }
 else puts("--binary --no-start --dry-run --host --port --auth --approval --agent --projects --widgets-dir --extensions-dir --extensions");
 return 0;
}
''')
        subprocess.run(['cc', '-o', str(self.binary), str(code)], check=True, capture_output=True)
        self.binary.chmod(0o700)
        self.package = self.root / 'package'

    def build_package(self):
        return node.package(self.binary, self.package, self.expected)

    def test_generic_probe_refuses_legacy_or_boolean_capability_claims(self):
        execute = node.subprocess.run
        for capabilities in ({'private_upload_context': 1, 'session_scope_lock': 1},
                             {'custom_tool_session_context': True, 'session_scope_lock': 1}):
            def claim(argv, **kwargs):
                result = execute(argv, **kwargs)
                if argv[1:] == ['capabilities', '--json']:
                    result.stdout = json.dumps(capabilities).encode()
                return result
            with self.subTest(capabilities=capabilities), patch.object(node.subprocess, 'run', side_effect=claim):
                with self.assertRaises(node.Refusal):
                    self.build_package()
                self.assertFalse(self.package.exists())

    def test_real_sized_serve_help_packages_and_installs(self):
        result = subprocess.run([str(self.binary), 'serve', '--help'], check=True, capture_output=True)
        self.assertEqual(10323, len(result.stdout))
        manifest = self.build_package()
        dest = self.root / 'install/term-llm'
        self.assertEqual(manifest, node.install(self.package, dest, self.expected))

    def test_help_output_limit_boundary_and_oversize(self):
        code = self.root / 'fixture.c'
        original = code.read_text()
        for size in (32 * 1024, 32 * 1024 + 1):
            with self.subTest(size=size):
                code.write_text(original.replace('#define SERVE_HELP_BYTES 10323',
                                                 f'#define SERVE_HELP_BYTES {size}'))
                subprocess.run(['cc', '-o', str(self.binary), str(code)], check=True, capture_output=True)
                if size == 32 * 1024:
                    node.probe(self.binary.read_bytes())
                else:
                    with self.assertRaises(node.Refusal):
                        self.build_package()
                    self.assertFalse(self.package.exists())

    def test_capability_and_version_output_limits_remain_8k(self):
        execute = node.subprocess.run
        for args in (['capabilities', '--json'], ['--version']):
            def oversized(argv, **kwargs):
                result = execute(argv, **kwargs)
                if argv[1:] == args:
                    result.stdout += b' ' * (8193 - len(result.stdout))
                return result
            with self.subTest(args=args), patch.object(node.subprocess, 'run', side_effect=oversized):
                with self.assertRaises(node.Refusal):
                    self.build_package()
                self.assertFalse(self.package.exists())

    def test_service_help_output_limit_remains_bounded(self):
        execute = node.subprocess.run
        def oversized(argv, **kwargs):
            result = execute(argv, **kwargs)
            if argv[1:] == ['service', 'install', '--help']:
                result.stdout += b' ' * (32 * 1024 + 1 - len(result.stdout))
            return result
        with patch.object(node.subprocess, 'run', side_effect=oversized):
            with self.assertRaises(node.Refusal):
                self.build_package()
        self.assertFalse(self.package.exists())

    def test_source_patch_is_bound_to_release(self):
        self.assertEqual(self.expected, node.source(self.source))
        (self.source / 'integrations/term-llm/patches/conversation-scope.patch').write_bytes(b'different')
        with self.assertRaisesRegex(node.Refusal, 'METAL_PRIVATE_NODE_INVALID'):
            node.source(self.source)

    def test_package_roundtrip_and_install(self):
        manifest = self.build_package()
        self.assertEqual(manifest, node.verify(self.package, self.expected))
        dest = self.root / 'install/term-llm'
        self.assertEqual(manifest, node.install(self.package, dest, self.expected))
        self.assertEqual(self.binary.read_bytes(), dest.read_bytes())
        self.assertEqual(manifest, node.install(self.package, dest, self.expected))
        self.assertEqual(manifest['binary_sha256'] + '\n', (dest.parent / 'binary.sha256').read_text())
        self.assertEqual([], list(dest.parent.glob('.native-*')))

    def test_modified_package_binary_is_refused(self):
        self.build_package()
        (self.package / 'term-llm').write_bytes(b'not the packaged binary')
        with self.assertRaises(node.Refusal):
            node.verify(self.package, self.expected)

    def test_wrong_source_or_capability_receipt_is_refused(self):
        self.build_package()
        for key, value in [('base_commit', 'b' * 40), ('patch_sha256', 'b' * 64), ('platform', 'other'), ('capabilities', {})]:
            with self.subTest(key=key), self.assertRaises(node.Refusal):
                expected = dict(self.expected, **{key: value}) if key in self.expected else dict(self.expected)
                if key not in self.expected:
                    manifest = json.loads((self.package / 'manifest.json').read_text())
                    original = manifest.copy()
                    manifest[key] = value
                    (self.package / 'manifest.json').write_text(json.dumps(manifest))
                    try:
                        node.verify(self.package, expected)
                    finally:
                        (self.package / 'manifest.json').write_text(json.dumps(original))
                else:
                    node.verify(self.package, expected)

    def test_package_symlinks_and_writeable_bytes_are_refused(self):
        self.build_package()
        path = self.package / 'term-llm'
        original = path.read_bytes()
        path.unlink()
        path.symlink_to(self.binary)
        with self.assertRaises(node.Refusal):
            node.verify(self.package, self.expected)
        path.unlink()
        path.write_bytes(original)
        path.chmod(0o666)
        with self.assertRaises(node.Refusal):
            node.verify(self.package, self.expected)
        alias = self.root / 'package-alias'
        alias.symlink_to(self.package)
        with self.assertRaises(node.Refusal):
            node.verify(alias, self.expected)

    def test_existing_unknown_destination_is_preserved(self):
        self.build_package()
        dest = self.root / 'install/term-llm'
        dest.parent.mkdir()
        dest.write_bytes(b'preserve existing binary')
        with self.assertRaises(node.Refusal):
            node.install(self.package, dest, self.expected)
        self.assertEqual(b'preserve existing binary', dest.read_bytes())

    def test_capability_probe_failure_does_not_install(self):
        self.build_package()
        dest = self.root / 'install/term-llm'
        with patch.object(node, 'probe', side_effect=node.Refusal('METAL_PRIVATE_NODE_INVALID')):
            with self.assertRaises(node.Refusal):
                node.install(self.package, dest, self.expected)
        self.assertFalse(dest.exists())
        self.assertEqual([], list(dest.parent.iterdir()))

    def installer(self):
        test_spec = importlib.util.spec_from_file_location('metal_tests', ROOT / 'test/metal/test_metal.py')
        tests = importlib.util.module_from_spec(test_spec)
        test_spec.loader.exec_module(tests)
        metal = tests.engine()
        metal.ROOT = self.source
        metal.P = self.root / 'prefix'
        (metal.P / 'bin').mkdir(parents=True)
        old = metal.P / 'old-node'
        old.write_bytes(b'previous')
        (metal.P / 'bin/term-llm').symlink_to(old)
        metal.C = dict(metal.DEFAULTS, SILO_ACCOUNT=pwd.getpwuid(os.getuid()).pw_name,
                       TERM_LLM_PACKAGE=str(self.package),
                       SILO_PREFIX=str(metal.P), SILO_WORKSPACES=str(metal.P / "workspaces"))
        original_module = metal.module
        metal.module = lambda name, filename: node if filename == 'private-node' else original_module(name, filename)
        return metal, old

    def test_installer_supports_explicit_package_and_preserves_previous(self):
        self.build_package()
        metal, old = self.installer()
        metal.install_term()
        self.assertEqual(old, (metal.P / 'bin/term-llm.previous').resolve())
        self.assertEqual(metal.term_destination(), (metal.P / 'bin/term-llm').resolve())
        self.assertIn('-private-', metal.term_destination().parent.name)
        self.assertFalse((metal.P / 'term-llm/0.9.99/term-llm').exists())
        self.assertFalse(metal.term_llm_current())

    def test_selected_package_and_binary_are_revalidated_without_changes(self):
        self.build_package()
        metal, old = self.installer()
        metal.install_term()
        dest = metal.term_destination()
        manifest = self.package / 'manifest.json'
        receipt = dest.parent / 'private-node.json'
        active = metal.P / 'bin/term-llm'
        previous = metal.P / 'bin/term-llm.previous'
        changes = [(manifest, b'{}'), (self.package / 'term-llm', b'invalid'),
                   (dest, b'changed'), (receipt, b'{}'),
                   (dest.parent / 'binary.sha256', b'wrong')]
        for path, value in changes:
            original = path.read_bytes()
            with self.subTest(path=path):
                path.write_bytes(value)
                with patch.object(metal, 'run') as run, patch.object(metal, 'symlink') as link:
                    with self.assertRaisesRegex(metal.Refusal, 'METAL_PRIVATE_NODE_INVALID'):
                        metal.term_llm_current()
                    run.assert_not_called()
                    link.assert_not_called()
                self.assertEqual(dest, active.resolve())
                self.assertEqual(old, previous.resolve())
            path.write_bytes(original)
        manifest.unlink()
        with self.assertRaises(metal.Refusal):
            metal.term_llm_current()
        self.assertEqual(dest, active.resolve())

    def test_selected_unsafe_custody_and_permissions_preserve_selection(self):
        self.build_package()
        metal, old = self.installer()
        metal.install_term()
        dest = metal.term_destination()
        for path, mode in ((self.package, 0o777), (dest.parent, 0o777), (dest, 0o600)):
            original = path.stat().st_mode & 0o777
            with self.subTest(path=path):
                path.chmod(mode)
                with patch.object(metal, 'run') as run, patch.object(metal, 'symlink') as link:
                    with self.assertRaises(metal.Refusal):
                        metal.term_llm_current()
                    run.assert_not_called()
                    link.assert_not_called()
                self.assertEqual(dest, (metal.P / 'bin/term-llm').resolve())
                self.assertEqual(old, (metal.P / 'bin/term-llm.previous').resolve())
                self.assertEqual(mode, path.stat().st_mode & 0o777)
            path.chmod(original)

    def test_elf_negatives_never_execute(self):
        valid = self.binary.read_bytes()
        wrong_machine = bytearray(valid)
        struct.pack_into('<H', wrong_machine, 18, 183)
        wrong_segment = bytearray(valid)
        phoff = struct.unpack_from('<Q', valid, 32)[0]
        struct.pack_into('<Q', wrong_segment, phoff + 8, len(valid) + 4096)
        wrong_header = bytearray(valid)
        struct.pack_into('<Q', wrong_header, 32, len(valid))
        for data in (b'#!/usr/bin/python3\nprint("unsafe")', valid[:32], valid[:100],
                     b'bad' + valid[3:], valid[:4] + b'\x01' + valid[5:],
                     valid[:5] + b'\x02' + valid[6:], wrong_machine, wrong_segment, wrong_header):
            with self.subTest(head=data[:20]):
                self.binary.write_bytes(data)
                with patch.object(node.subprocess, 'run') as run:
                    with self.assertRaises(node.Refusal):
                        node.package(self.binary, self.package, self.expected)
                    run.assert_not_called()
                self.assertFalse(self.package.exists())

    def test_writable_and_foreign_ancestor_refused_without_chmod(self):
        self.build_package()
        for mode in (0o777, 0o775):
            self.package.chmod(mode)
            with self.assertRaises(node.Refusal):
                node.verify(self.package, self.expected)
            self.assertEqual(mode, self.package.stat().st_mode & 0o777)
        self.package.chmod(0o700)
        info = self.package.stat()
        foreign = type('Info', (), {'st_uid': 123456, 'st_mode': info.st_mode})()
        with self.assertRaises(node.Refusal):
            node.custody(foreign, True)
        root = type('Info', (), {'st_uid': 0, 'st_mode': stat.S_IFDIR | 0o755})()
        node.custody(root, True)
        sticky = type('Info', (), {'st_uid': 0, 'st_mode': stat.S_IFDIR | 0o1777})()
        node.custody(sticky, True)

    def test_descriptor_reads_survive_ancestor_replacement(self):
        self.build_package()
        held = self.root / 'held-package'
        read = node.read_at
        replaced = False
        def replace_after_open(fd, name, maximum):
            nonlocal replaced
            if not replaced:
                replaced = True
                self.package.rename(held)
                self.package.mkdir()
                (self.package / 'term-llm').write_bytes(b'attacker')
            return read(fd, name, maximum)
        with patch.object(node, 'read_at', side_effect=replace_after_open):
            self.assertEqual(self.binary.read_bytes(), node.verified_bytes(self.package, self.expected)[1])

    def test_probe_uses_sealed_bytes_even_if_source_path_changes(self):
        original = self.binary.read_bytes()
        execute = node.subprocess.run
        def replace_and_execute(argv, **kwargs):
            self.binary.write_bytes(b'#!/bin/sh\nexit 42\n')
            self.assertTrue(argv[0].startswith('/proc/self/fd/'))
            fd = kwargs['pass_fds'][0]
            self.assertEqual(original, os.pread(fd, len(original), 0))
            with self.assertRaises(OSError):
                os.write(fd, b'mutation')
            return execute(argv, **kwargs)
        with patch.object(node.subprocess, 'run', side_effect=replace_and_execute):
            node.package(self.binary, self.package, self.expected)
        self.assertEqual(original, (self.package / 'term-llm').read_bytes())

    def test_customer_roots_and_custom_config_are_refused(self):
        config = self.root / 'metal.conf'
        prefix = self.root / 'custom-prefix'
        workspaces = self.root / 'custom-workspaces'
        config.write_text(f'SILO_PREFIX={prefix}\nSILO_WORKSPACES={workspaces}\n')
        roots = node.configured_roots(config)
        for customer_root in roots:
            customer_root.mkdir(parents=True)
            binary = customer_root / 'node'
            binary.write_bytes(self.binary.read_bytes())
            binary.chmod(0o700)
            with self.assertRaises(node.Refusal):
                node.package(binary, self.package, self.expected, roots)
            with self.assertRaises(node.Refusal):
                node.package(self.binary, customer_root / 'pkg', self.expected, roots)
        self.build_package()
        for customer_root in roots:
            with self.assertRaises(node.Refusal):
                node.install(self.package, customer_root / 'term-llm', self.expected, roots)
        with patch.dict(os.environ, SILO_PREFIX=str(prefix), SILO_WORKSPACES=str(workspaces)):
            with self.assertRaises(node.Refusal):
                node.read_regular(workspaces / 'node', node.MAX_BINARY)

    def test_root_can_validate_only_the_explicit_service_custodian(self):
        service_uid = os.geteuid() + 10000
        owned = type('Info', (), {'st_uid': service_uid, 'st_mode': stat.S_IFDIR | 0o700})()
        with patch.object(node.os, 'geteuid', return_value=0):
            with self.assertRaises(node.Refusal):
                node.custody(owned, True)
            with node.custodian(service_uid):
                node.custody(owned, True)
            with self.assertRaises(node.Refusal):
                node.custody(owned, True)
        with patch.object(node.os, 'geteuid', return_value=service_uid + 1):
            with self.assertRaises(node.Refusal), node.custodian(service_uid):
                pass

    def test_root_to_service_custody_requires_readability(self):
        self.build_package()
        actual_open = node.os.open
        def unreadable(path, *args, **kwargs):
            if path == self.package.name:
                raise PermissionError('service cannot traverse root-private package')
            return actual_open(path, *args, **kwargs)
        with patch.object(node.os, 'open', side_effect=unreadable):
            with self.assertRaises(node.Refusal):
                node.verify(self.package, self.expected)
        self.assertEqual(0o700, self.package.stat().st_mode & 0o777)

    def test_same_patch_different_base_has_distinct_install_and_rollback(self):
        self.build_package()
        metal, old = self.installer()
        metal.install_term()
        first = metal.term_destination()
        alternate = dict(self.expected, base_commit='b' * 40)
        self.assertNotEqual(node.variant(self.expected), node.variant(alternate))
        self.assertEqual(node.variant(self.expected), node.variant(dict(reversed(list(self.expected.items())))))
        (self.source / 'runtime/private-node-source.json').write_text(json.dumps(alternate))
        second_package = self.root / 'package-second'
        node.package(self.binary, second_package, alternate)
        metal.C['TERM_LLM_PACKAGE'] = str(second_package)
        self.assertTrue(metal.term_llm_current())
        self.assertNotEqual(first, metal.term_destination())
        self.assertTrue(first.is_file())
        self.assertEqual(first, (metal.P / 'bin/term-llm.previous').resolve())

    def test_capability_version_cli_failures_do_not_select(self):
        self.build_package()
        metal, old = self.installer()
        execute = node.subprocess.run
        for bad_args, bad_output in ((['capabilities', '--json'], b'{}'),
                                     (['--version'], b'term-llm version 0.9.98'),
                                     (['service', 'install', '--help'], b'no flags'),
                                     (['serve', '--help'], b'no flags')):
            def bad_probe(argv, **kwargs):
                if argv[1:] == bad_args:
                    return subprocess.CompletedProcess(argv, 0, bad_output, b'')
                return execute(argv, **kwargs)
            with self.subTest(args=bad_args), patch.object(node.subprocess, 'run', side_effect=bad_probe):
                with self.assertRaises(metal.Refusal):
                    metal.install_term()
            self.assertEqual(old, (metal.P / 'bin/term-llm').resolve())
            self.assertFalse((metal.P / 'bin/term-llm.previous').exists())


if __name__ == '__main__':
    unittest.main()
