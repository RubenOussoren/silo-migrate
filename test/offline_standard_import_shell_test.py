"""Offline shell-contract tests; no Ruby, Docker, Discourse or source data run.

Only the bounded log shell text is exercised, substituting temporary paths and
shell builtins for the importer. This is not a Ruby service/test-suite substitute.
"""
import pathlib
import re
import shlex
import subprocess
import tempfile
import unittest


class StandardImportShellTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="silo-shell ;literal-")
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.log = self.root / "import.log"
        source = (
            pathlib.Path(__file__).resolve().parents[1]
            / "lib/silo_migrate/services/discourse_service.rb"
        ).read_text()
        match = re.search(r"command\[-1\] = <<~SH\n(.*?)\n        SH", source, re.S)
        self.assertIsNotNone(match, "bounded import shell contract not found")
        self.script = match[1]
        limit_source = (
            pathlib.Path(__file__).resolve().parents[1]
            / "lib/silo_migrate/services/discourse_archive.rb"
        ).read_text()
        limit = re.search(r"STANDARD_IMPORT_LOG_LIMIT = ([\d_]+)", limit_source)
        self.assertIsNotNone(limit)
        self.limit = int(limit[1].replace("_", ""))
        self.script = self.script.replace(
            "cd /var/www/discourse || exit 1",
            f"cd {shlex.quote(str(self.root))} || exit 1",
        ).replace(
            "log=/shared/silo-migrate-standard-import.log",
            f"log={shlex.quote(str(self.log))}",
        ).replace("#{STANDARD_IMPORT_LOG_LIMIT}", str(self.limit))

    def run_fake(self, invocation):
        script = self.script.replace("#{invocation}", invocation)
        self.assertNotIn("#{", script)
        return subprocess.run(
            ["sh", "-c", script], capture_output=True, timeout=5, check=False
        )

    def test_shell_syntax_without_execution(self):
        script = self.script.replace("#{invocation}", ":")
        result = subprocess.run(
            ["sh", "-n"], input=script.encode(), capture_output=True,
            timeout=5, check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(self.log.exists())

    def test_success_keeps_exact_single_use_report(self):
        report = "Done! (0 minutes)\n"
        result = self.run_fake(f"printf %s {shlex.quote(report)}")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(report.encode(), result.stdout)
        self.assertEqual(report.encode(), self.log.read_bytes())

    def test_importer_failure_retains_log_and_nonzero_status(self):
        result = self.run_fake("(printf 'synthetic failure\\n' >&2; exit 7)")
        self.assertEqual(7, result.returncode)
        self.assertEqual(b"synthetic failure\n", result.stdout)
        self.assertEqual(result.stdout, self.log.read_bytes())

    def test_oversize_report_is_retained_but_not_captured(self):
        payload = "x" * (self.limit + 1)
        result = self.run_fake(f"printf %s {shlex.quote(payload)}")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertEqual(self.limit + 1, self.log.stat().st_size)

    def test_existing_report_refuses_repeat_without_overwrite(self):
        self.log.write_bytes(b"prior attempt")
        result = self.run_fake("printf overwritten")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertEqual(b"prior attempt", self.log.read_bytes())

    def test_symlink_report_refuses_execution_without_touching_target(self):
        target = self.root / "preserved.txt"
        target.write_bytes(b"preserved synthetic artifact")
        self.log.symlink_to(target)
        result = self.run_fake("printf overwritten")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertEqual(b"preserved synthetic artifact", target.read_bytes())


if __name__ == "__main__":
    unittest.main()
