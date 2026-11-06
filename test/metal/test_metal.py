"""Fast stdlib tests: no Docker writes, services, sudo or network. python3 -I -m unittest discover -s test/metal -v"""
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import shutil
import os
from pathlib import Path
import pwd
import subprocess
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRATCH = ROOT / "../../.runtime-cache/metal-review-fix-tmp"
SCRATCH.mkdir(parents=True, exist_ok=True, mode=0o700)
# A test runner's permissive umask must not make authority fixtures unsafe.
os.umask(0o022)
tempfile.tempdir = str(SCRATCH.resolve())


def module(name, filename):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT/"script"/filename))
    spec = importlib.util.spec_from_loader(name, loader)
    obj = importlib.util.module_from_spec(spec)
    loader.exec_module(obj)
    return obj


def engine():
    obj = types.ModuleType("metal_engine")
    obj.__dict__["__name__"] = "metal_engine"
    text = (ROOT/"script/metal").read_text().split("<<'PYTHON'\n", 1)[1].rsplit("\nPYTHON", 1)[0]
    with patch("sys.argv", ["-c", str(ROOT/"script/metal")]):
        exec(compile(text, "script/metal:engine", "exec"), obj.__dict__)
    return obj


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.m = engine()
        self.m.C = dict(self.m.DEFAULTS, SILO_ACCOUNT=pwd.getpwuid(os.getuid()).pw_name,
                        SILO_PREFIX=str(self.root/"prefix"), SILO_WORKSPACES=str(self.root/"workspaces"), TERM_LLM_SERVICE="skip")
        self.m.P, self.m.W = Path(self.m.C["SILO_PREFIX"]), Path(self.m.C["SILO_WORKSPACES"])
        self.home = self.root/"home"
        self.home.mkdir()
        self.m.home = lambda:self.home
        self.osfile = self.root/"os-release"
        self.osfile.write_text('ID=debian\nVERSION_ID="12"\n')
        self.env = patch.dict(os.environ, SILO_METAL_TESTING="1", SILO_METAL_TEST_OS_RELEASE=str(self.osfile), SILO_METAL_TEST_ARCH="amd64")
        self.env.start()
        self.addCleanup(self.env.stop)

    def configured(self, body):
        path = self.root/"config"
        path.write_text(body)
        return self.m.read_config(path)

    def plan_stubs(self):
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(self.m, "resolve", return_value="a"*40))
        stack.enter_context(patch.object(self.m, "missing_packages", return_value=[]))
        stack.enter_context(patch.object(self.m, "output", side_effect=lambda argv, **kw: "docker users" if argv[0] == "id" else "amd64"))
        stack.enter_context(patch.object(self.m.shutil, "which", return_value="/usr/bin/docker"))
        return stack

    def snapshot(self):
        return sorted((str(p.relative_to(self.root)), p.lstat().st_mode, p.stat().st_size if p.is_file() else 0,
                       p.lstat().st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "")
                      for p in self.root.rglob("*"))

    def test_os_and_arch(self):
        self.assertEqual([], self.m.os_check()["errors"])
        for ident, version in (("debian", "11"), ("ubuntu", "24.04"), ("debian", "13"), ("fedora", "42")):
            self.osfile.write_text(f'ID={ident}\nVERSION_ID="{version}"\n')
            self.assertTrue(self.m.os_check()["errors"])
            self.assertEqual(not (ident == "ubuntu" or (ident == "debian" and version == "13")), bool(self.m.os_check(True)["errors"]))
        self.osfile.write_text('ID=debian\nVERSION_ID="12"\n')
        with patch.dict(os.environ, SILO_METAL_TEST_ARCH="arm64"):
            self.assertIn("METAL_ARCH_UNSUPPORTED", self.m.os_check()["errors"][0])

    def test_test_overrides_require_explicit_test_mode(self):
        with patch.dict(os.environ, SILO_METAL_TESTING="0", SILO_METAL_TEST_ARCH="arm64"):
            self.assertEqual("amd64", self.m.test_override("ARCH", "amd64"))

    def test_strict_config(self):
        for text in ("UNKNOWN=x", "SILO_ACCOUNT=x\nSILO_ACCOUNT=y", "SILO_ACCOUNT=$(whoami)", "export SILO_ACCOUNT=x", "TERM_LLM_SERVICE=no", "SILO_REPO=https://secret@example.com/a", "SILO_PREFIX=/tmp/../etc", "TERM_LLM_VERSION=latest"):
            with self.subTest(text=text), self.assertRaises(self.m.Refusal):
                self.configured(text)
        self.assertEqual("/disk/ws", self.configured("SILO_WORKSPACES=/disk/ws")["SILO_WORKSPACES"])
        self.assertEqual("/disk/workspaces", self.configured("SILO_PREFIX=/disk\nSILO_WORKSPACES=$SILO_PREFIX/workspaces")["SILO_WORKSPACES"])

    def test_dry_plan_zero_writes_and_existing_docker_config_preserved(self):
        existing = self.home/".config/term-llm"
        existing.mkdir(parents=True)
        (existing/"config.yaml").write_text("private sentinel")
        before = self.snapshot()
        with self.plan_stubs():
            plan = self.m.make_plan()
            second = self.m.make_plan()
        self.assertEqual(before, self.snapshot())
        self.assertEqual(plan, second)
        self.assertNotIn("docker", [a["action"] for a in plan["needs_root"]])
        self.assertTrue(any("PRESERVED" in n for n in plan["notes"]))
        self.assertNotIn("private sentinel", json.dumps(plan))

    def test_preflight_no_sudo_no_writes_and_pressure_fields(self):
        before = self.snapshot()
        def probe(argv, **kwargs):
            self.assertFalse(kwargs.get("account"), "preflight must never sudo")
            self.assertFalse(kwargs.get("root"), "preflight must never sudo")
            return "amd64" if argv[0] == "dpkg" else None
        with patch.object(self.m, "output", side_effect=probe), patch.object(self.m, "installed", return_value=True), patch.object(self.m, "resolve", return_value="a"*40):
            result = self.m.preflight(False)
        self.assertEqual(before, self.snapshot())
        for key in ("available_ram_bytes", "physical_cores", "logical_cpus", "load_average", "swap", "tmp"):
            self.assertIn(key, result)

    def test_missing_git_bare_ref_resolution_is_read_only(self):
        bare = self.root/"repo.git"
        (bare/"refs/heads/mvp").mkdir(parents=True)
        (bare/"refs/heads/mvp/metal-installer").write_text("a"*40 + "\n")
        before = self.snapshot()
        with patch.object(self.m, "git", return_value=None), patch.object(self.m.shutil, "which", return_value=None):
            self.assertEqual("a"*40, self.m.resolve(str(bare), "mvp/metal-installer"))
        self.assertEqual(before, self.snapshot())

    def test_apply_sha_mismatch_refuses_before_commands(self):
        with self.plan_stubs():
            saved = self.m.envelope(self.m.make_plan())
            saved["sha256"] = "0"*64
            file = self.root/"plan.json"
            file.write_text(json.dumps(saved))
            with patch.object(self.m, "read_config", return_value=self.m.C), patch.object(self.m, "apply_roots") as roots, patch("sys.argv", ["metal", "apply", "--plan", str(file)]), self.assertRaisesRegex(self.m.Refusal, "METAL_PLAN_STALE"):
                self.m.main()
            roots.assert_not_called()

    def test_second_apply_is_noop_and_existing_user_config_preserved(self):
        P = self.m.P
        for path in [P, self.m.W] + [P/p for p in ("bin", "etc", "releases", "term-llm", "control", "control/gems", "control/site-cache", "state", "state/logs", "state/tmp", "state/runtime-profiles")]:
            path.mkdir(parents=True, exist_ok=True)
            path.chmod(0o750)
        release = P/"releases"/("a"*40)
        release.mkdir()
        configdir = self.home/".config/term-llm"
        configdir.mkdir(parents=True)
        (configdir/"config.yaml").write_text("# sentinel: never overwrite\n")
        binary = P/"term-llm/0.9.93/term-llm"
        binary.parent.mkdir()
        binary.write_text("stub")
        os.symlink(binary, P/"bin/term-llm")
        with self.plan_stubs():
            saved = self.m.envelope(self.m.make_plan())
            with patch.object(self.m, "install_term"), patch.object(self.m, "fetch_release", return_value=release), patch.object(self.m, "extract_artifacts", return_value=([], "skipped-no-package", "")):
                self.m.account_apply(saved)
            self.assertEqual("# sentinel: never overwrite\n", (configdir/"config.yaml").read_text())
            plan = self.m.make_plan()
            self.assertEqual([], plan["needs_root"])
            self.assertEqual([], plan["as_account"])
            file = self.root/"approved.json"
            file.write_text(json.dumps(self.m.envelope(plan)))
            before = self.snapshot()
            with patch.object(self.m, "read_config", return_value=self.m.C), patch("sys.argv", ["metal", "apply", "--plan", str(file)]), contextlib.redirect_stdout(io.StringIO()):
                self.m.main()
            self.assertEqual(before, self.snapshot())

    def test_term_download_both_checksums_required(self):
        (self.m.P/"term-llm").mkdir(parents=True)
        (self.m.P/"state/tmp").mkdir(parents=True)
        def download(argv, **kwargs):
            dest = Path(argv[-1])
            dest.write_bytes(b"untrusted tar" if dest.name.endswith("tar.gz") else ("0"*64 + "  term-llm_0.9.93_linux_amd64.tar.gz\n").encode())
        with patch.object(self.m, "run", side_effect=download), self.assertRaisesRegex(self.m.Refusal, "METAL_TERM_CHECKSUM"):
            self.m.install_term()
        self.assertFalse((self.m.P/"bin/term-llm").exists())
        # Pinned checksum alone is insufficient if publisher checksum differs.
        with patch.object(self.m, "run", side_effect=download), patch.object(self.m, "PIN", hashlib.sha256(b"untrusted tar").hexdigest()), self.assertRaisesRegex(self.m.Refusal, "METAL_TERM_CHECKSUM"):
            self.m.install_term()

    def test_update_and_rollback_refuse_held_lock(self):
        path = self.m.W/"ws/.silo-migrate/named/standard"
        path.mkdir(parents=True)
        import fcntl
        for lockpath in (self.m.W/".silo-standard-execution.lock", path/"op.lock"):
            if lockpath.name == "op.lock":
                (self.m.W/".silo-standard-execution.lock").touch()
            with open(lockpath, "w") as stream:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                for rollback in (True, False):
                    with self.assertRaisesRegex(self.m.Refusal, "METAL_BUSY"):
                        self.m.account_update(rollback)
            lockpath.unlink()

    def test_claimed_registry_refuses_even_without_locks(self):
        path = self.m.W/"ws/.silo-migrate/named/standard"
        path.mkdir(parents=True)
        (self.m.W/".silo-standard-execution.lock").touch()
        (path/"state.json").write_text(json.dumps({"runs": {"run-id": {"status": "claimed"}}}))
        for rollback in (True, False):
            with self.assertRaisesRegex(self.m.Refusal, "METAL_BUSY"):
                self.m.account_update(rollback)

    def test_update_rollback_leave_workspaces_and_backups_untouched(self):
        P = self.m.P
        for path in (P/"releases", P/"state/logs", self.m.W/"ws/backups"):
            path.mkdir(parents=True)
        (self.m.W/".silo-standard-execution.lock").touch()
        a, b = "a"*40, "b"*40
        for commit in (a, b):
            (P/"releases"/commit).mkdir()
        os.symlink(P/"releases"/a, P/"current")
        self.m.record({"commit": a, "term_llm_version": "0.9.93"}, "apply")
        backup = self.m.W/"ws/backups/retained.tar.gz"
        backup.write_bytes(b"do-not-touch")
        stat = backup.stat()
        with patch.object(self.m, "resolve", return_value=b), patch.object(self.m, "fetch_release", return_value=P/"releases"/b), contextlib.redirect_stdout(io.StringIO()):
            self.m.account_update(False)
            self.m.account_update(True)
        self.assertEqual(a, (P/"current").resolve().name)
        self.assertEqual(b"do-not-touch", backup.read_bytes())
        self.assertEqual(stat.st_mtime_ns, backup.stat().st_mtime_ns)
        self.assertEqual({backup, self.m.W/".silo-standard-execution.lock"}, {p for p in self.m.W.rglob("*") if p.is_file()})

    def test_subprocess_secrets_not_in_errors_or_logs(self):
        secret = "DO_NOT_PRINT_THIS_SECRET"
        result = subprocess.CompletedProcess(["stub"], 1, secret, secret)
        with patch.object(subprocess, "run", return_value=result), self.assertRaises(self.m.Refusal) as error:
            self.m.run(["stub"])
        self.assertNotIn(secret, str(error.exception))
        (self.m.P/"state/logs").mkdir(parents=True)
        self.m.record({"commit": "a"*40}, "apply")
        self.assertNotIn(secret, "".join(p.read_text() for p in (self.m.P/"state/logs").iterdir()))

    def test_verify_capacity_refusal_does_not_create_workspace(self):
        before = self.snapshot()
        with patch.object(self.m, "capacity_ready", return_value=False), self.assertRaisesRegex(self.m.Refusal, "METAL_VERIFY_CAPACITY"):
            self.m.verify()
        self.assertEqual(before, self.snapshot())

    def test_verify_structured_control_contract(self):
        calls = []
        def control(argv):
            calls.append(argv)
            if argv[:3] == ["standard", "fixture", "register"]:
                return {"dataset_id": "dataset-a"}
            if argv[:3] == ["standard", "plan", "propose"]:
                self.assertEqual("18080,18081", argv[-1])
                return {"plan_id": "plan-a", "digest": "a"*64}
            if argv[0] == "start-run":
                return {"run_id": "run-a"}
            if argv[:2] == ["standard", "status"]:
                return {"runs": [{"run_id": "run-a", "status": "completed", "artifacts": {"final": {"label": "restore-proven", "sha256": "b"*64}}}]}
            return {}
        with patch.object(self.m, "capacity_ready", return_value=True), patch.object(self.m, "control", side_effect=control), contextlib.redirect_stdout(io.StringIO()) as stream:
            self.m.verify()
        self.assertIn("METAL_VERIFY_OK", stream.getvalue())
        self.assertTrue(any(a[:3] == ["standard", "run", "reset"] for a in calls))


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.pack = module("artifact_package_test", "package-artifacts")
        self.identity = module("identity_test", "image_identity.py")
        self.inspect = [{"Architecture": "amd64", "Os": "linux", "RootFS": {"Layers": ["sha256:" + "a"*64]},
                         "Config": {"Cmd": None, "User": None}}]
        self.profile = {"version": 1, "recipe": "synthetic", "images": {
            "web": {"ref": "test/web:1", "content_id": self.identity.content_id(self.inspect), "source": "package"},
            "control": {"ref": "ruby@sha256:" + "b"*64, "content_id": self.identity.content_id(self.inspect), "source": "public-digest"}}}
        self.profilefile = self.root/"runtime.json"
        self.profilefile.write_text(json.dumps(self.profile))
        self.gems = self.root/"gems"
        self.gems.mkdir()
        (self.gems/"gem.rb").write_text("# synthetic")
        self.site = self.root/"site_settings.yml"
        self.site.write_text("title: synthetic\n")
        self.out = self.root/"package"
        self.bin = self.root/"bin"
        self.bin.mkdir()
        self.docker = self.bin/"docker"
        self.docker.write_text('#!/bin/sh\ncase "$2" in inspect) printf \'%s\' \' ' + json.dumps(self.inspect) + ' \' ;; save) printf synthetic-image ;; *) exit 1 ;; esac\n')
        self.docker.chmod(0o755)
        self.env = patch.dict(os.environ, PATH=str(self.bin)+":"+os.environ["PATH"])
        self.env.start()
        self.addCleanup(self.env.stop)

    def build(self, **kwargs):
        args = types.SimpleNamespace(profile=self.profilefile, gems=self.gems, site_settings=self.site, output=self.out, include_public=False, **kwargs)
        with contextlib.redirect_stdout(io.StringIO()):
            self.pack.package(args)

    def test_package_allowlist_and_verify_cli(self):
        self.build()
        manifest = self.pack.verify(self.out, self.profilefile)
        self.assertEqual(["web"], [i["role"] for i in manifest["images"]])
        self.assertFalse((self.out/"images/control.tar.gz").exists())
        result = subprocess.run([str(ROOT/"script/metal"), "artifacts", "verify", str(self.out)], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)

    def test_tampered_missing_extra_symlink_and_profile_refused(self):
        self.build()
        payload = self.out/"site_settings.yml"
        original = payload.read_bytes()
        payload.write_bytes(b"tampered")
        with self.assertRaises(self.pack.Invalid): self.pack.verify(self.out)
        payload.unlink()
        with self.assertRaises(self.pack.Invalid): self.pack.verify(self.out)
        payload.write_bytes(original)
        extra = self.out/"extra"
        extra.write_text("unlisted")
        with self.assertRaises(self.pack.Invalid): self.pack.verify(self.out)
        extra.unlink()
        extra.symlink_to(payload)
        with self.assertRaises(self.pack.Invalid): self.pack.verify(self.out)
        extra.unlink()
        self.profilefile.write_text("{}")
        with self.assertRaises(self.pack.Invalid): self.pack.verify(self.out, self.profilefile)

    def test_gem_secret_patterns_refused(self):
        for name in ("private.pem", "id.key", ".netrc", "credentials.yaml", "refresh_token"):
            path = self.gems/name
            path.write_text("synthetic")
            with self.assertRaises(self.pack.Invalid): self.build()
            self.assertFalse(self.out.exists())
            path.unlink()

    def test_ordinary_names_and_reviewed_public_certificate_allowed(self):
        (self.gems/"tokenizer.c").write_text("synthetic source")
        cert = self.gems/"gem-public_cert.pem"
        body = b"-----BEGIN CERTIFICATE-----\nsynthetic\n-----END CERTIFICATE-----\n"
        cert.write_bytes(body)
        with patch.dict(self.pack.KNOWN_PUBLIC, {"gem-public_cert.pem": hashlib.sha256(body).hexdigest()}, clear=True):
            self.build()
            self.pack.verify(self.out)
        cert.write_bytes(body + b"changed")
        shutil.rmtree(self.out)
        with patch.dict(self.pack.KNOWN_PUBLIC, {"gem-public_cert.pem": hashlib.sha256(body).hexdigest()}, clear=True):
            with self.assertRaises(self.pack.Invalid): self.build()

    def test_image_mismatch_refused(self):
        self.profile["images"]["web"]["content_id"] = "sha256:" + "0"*64
        self.profilefile.write_text(json.dumps(self.profile))
        with self.assertRaises(self.pack.Invalid): self.build()

    def test_gem_tar_is_reproducible_no_owner_xattrs(self):
        self.build()
        checksum = self.pack.sha(self.out/"gems.tar.gz")
        with tarfile.open(self.out/"gems.tar.gz") as tar:
            info = tar.getmembers()[0]
            self.assertEqual((0, 0, "", "", {}), (info.uid, info.gid, info.uname, info.gname, info.pax_headers))
        self.out = self.root/"package2"
        self.build()
        self.assertEqual(checksum, self.pack.sha(self.out/"gems.tar.gz"))

    def test_unicode_identity_uses_utf8_not_ascii_escapes(self):
        obj = {"Architecture": "amd64", "Os": "linux", "Config": {"Env": ["TITLE=café"]}, "RootFS": {"Layers": None}}
        expected = {"architecture": "amd64", "os": "linux", "diff_ids": [], "config": {"Cmd": [], "Entrypoint": [], "Env": ["TITLE=café"], "User": "", "WorkingDir": ""}}
        want = "sha256:" + hashlib.sha256(json.dumps(expected, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest()
        self.assertEqual(want, self.identity.content_id(obj))

    def test_identity_matches_ruby_fixture(self):
        fixture = ROOT/"test/fixtures/image-inspect-sample.json"
        expected = ROOT/"test/fixtures/image-inspect-sample.content_id"
        if not fixture.exists() or not expected.exists():
            self.skipTest("Ruby peer fixture not delivered yet")
        self.assertEqual(expected.read_text().strip(), self.identity.content_id(json.loads(fixture.read_text())))


if __name__ == "__main__":
    unittest.main()
