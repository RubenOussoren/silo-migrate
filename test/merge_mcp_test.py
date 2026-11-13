"""Prepared-merge inspection connectors (bin/merge_mcp.py). Run: python3 -I -B test/merge_mcp_test.py.

Docker, term-llm and the connector install are faked; files, modes, locks, manifests and
mcp.json edits are real. Invented identifiers only.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
RUN = "run-" + "a" * 32
PREP = "run-" + "b" * 32
GEN = "c" * 64
WEB, DB = "1" * 64, "2" * 64
INSTANCE = "silomig-0123abcd-review"
KEY = "f" * 64
NODE_REF = json.loads((ROOT / "integrations/discourse-mcp/runtime.json").read_text())["node_image"]
NODE_DIGEST = NODE_REF.split("@", 1)[1]
MIRROR_REF = "mirror.gcr.io/library/node@" + NODE_DIGEST
PASSWORD = "e" * 48


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeDocker:
    def __init__(self):
        self.calls = []
        self.web_networks = {INSTANCE + "-int": {}}
        self.internal = True
        self.running = True
        self.image_present = True
        self.launchers = []  # (role, id, run, generation, side)
        # Pinned Node image: inspectable refs -> (image ID, RepoDigests); pullable refs -> refs they add.
        self.node_refs = {NODE_REF: ("sha256:" + "9" * 64, ["node@" + NODE_DIGEST])}
        self.pullable = {}
        self.pulls = []
        self.ps_fails = False

    def __call__(self, argv, timeout=120, input=None):
        self.calls.append(argv)
        ok = lambda out: subprocess.CompletedProcess(argv, 0, out.encode(), b"")
        if argv[:2] == ["container", "inspect"]:
            role = {WEB: "web", DB: "db"}.get(argv[-1])
            if not role:
                return subprocess.CompletedProcess(argv, 1, b"", b"No such container")
            networks = self.web_networks if role == "web" else {INSTANCE + "-int": {}}
            return ok(json.dumps({"Id": argv[-1], "Name": "/" + INSTANCE + "-" + role, "State": {"Running": self.running},
                                  "Config": {"Labels": {"silo-migrate.managed": "true", "silo-migrate.instance": INSTANCE}},
                                  "NetworkSettings": {"Networks": networks}}))
        if argv[:2] == ["network", "inspect"]:
            return ok(json.dumps({"Name": argv[-1], "Internal": self.internal,
                                  "Labels": {"silo-migrate.managed": "true", "silo-migrate.instance": INSTANCE}}))
        if argv[:2] == ["image", "inspect"] and "RepoDigests" in argv[3]:
            found = self.node_refs.get(argv[-1]) if self.image_present else None
            return ok(found[0] + " " + json.dumps(found[1])) if found else subprocess.CompletedProcess(argv, 1, b"", b"No such image")
        if argv[:2] == ["pull", "--quiet"]:
            self.pulls.append(argv[2])
            if argv[2] in self.pullable:
                self.image_present = True
                self.node_refs.update(self.pullable[argv[2]])
                return ok("")
            return subprocess.CompletedProcess(argv, 1, b"", b"429 Too Many Requests")
        if argv[:2] == ["image", "inspect"]:
            return ok("sha256:" + "9" * 64) if self.image_present else subprocess.CompletedProcess(argv, 1, b"", b"")
        if argv[:2] == ["ps", "-a"]:
            if self.ps_fails:
                return subprocess.CompletedProcess(argv, 1, b"", b"")
            role = next(f.split("=", 2)[2] for f in argv if f.startswith("label=silo.role="))
            run = next((f.split("=", 2)[2] for f in argv if f.startswith("label=silo.merge-run=")), None)
            rows = [" ".join(row[1:]) for row in self.launchers if row[0] == role and (run is None or row[2] == run)]
            return ok("".join(row + "\n" for row in rows))
        if argv[:2] == ["rm", "-f"]:
            self.launchers = [row for row in self.launchers if row[1] != argv[2]]
            return ok(argv[2])
        return subprocess.CompletedProcess(argv, 1, b"", b"")


class MergeMcpTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        top = Path(self.tmp.name)
        self.base = top / "workspaces"
        self.config_home = top / "config"
        env = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.config_home), "XDG_DATA_HOME": str(top / "data")})
        env.start()
        self.addCleanup(env.stop)
        self.d = load("data_tools", ROOT / "bin/data_tools.py")
        self.m = load("merge_mcp", ROOT / "bin/merge_mcp.py")
        self.docker = FakeDocker()
        # As the parent passes it: a namespace of data_tools globals, not sys.modules.
        self.api = types.SimpleNamespace(**{k: v for k, v in vars(self.d).items() if not k.startswith("__")})
        self.api.docker = self.docker
        self.api.term_llm_command = lambda prefix: "/bin/true"
        self.api.term_llm_enforces = lambda term: True
        self.api.dbhub_image = lambda pull_seconds=0: self.docker.image_present
        (self.config_home / "term-llm").mkdir(parents=True)
        rules = "".join(f"    merge-{side}-arc:\n      agents: [migration-data]\n" for side in ("base", "result", "source"))
        (self.config_home / "term-llm/config.yaml").write_text("mcp:\n  servers:\n" + rules)
        root = self.base / "arc"
        (root / ".silo-migrate/named/standard").mkdir(parents=True)
        (root / ".silo-migrate/named/state.json").write_text("{}")
        (root / ".silo-migrate/named/standard/state.json").write_text("{}")
        self.private = root / ".silo-migrate/named/standard/runs" / RUN / "private"
        (self.private / "merge-inspection").mkdir(parents=True, mode=0o700)
        self.private.chmod(0o700)
        (self.private / "merge-access.lock").touch(mode=0o600)
        self.write_secret("base.key", KEY)
        self.write_secret("source.env", f"SILO_MI_ROLE=silo_mi_0a1b2c3d\nSILO_MI_PASSWORD={PASSWORD}\n")
        self.manifest = {
            "version": 1, "run_id": RUN, "preparation_run_id": RUN, "generation": GEN, "phase": "base", "state": "open",
            "owner": {"workspace": "arc", "instance": INSTANCE}, "containers": {"web": WEB, "db": DB},
            "network": INSTANCE + "-int", "port": 41000,
            "endpoints": {
                "base": {"state": "open", "kind": "discourse-mcp", "site": "http://web", "username": "silo_inspect_0a1b2c3d",
                         "user_id": 7, "api_key_id": 9, "scope_mode": "read_only", "scopes": ["global:read"],
                         "credential": "base.key", "credential_sha256": hashlib.sha256(KEY.encode()).hexdigest()},
                "source": {"state": "open", "kind": "dbhub", "database": "merge_source_inspect", "role": "silo_mi_0a1b2c3d",
                           "credential": "source.env",
                           "credential_sha256": hashlib.sha256(f"SILO_MI_ROLE=silo_mi_0a1b2c3d\nSILO_MI_PASSWORD={PASSWORD}\n".encode()).hexdigest(),
                           "policy": {"version": "merge-source-read-v1", "granted_tables": 3, "unreviewed_tables": 1}}}}
        self.save()
        self.state_path = root / ".silo-migrate/named/standard/state.json"
        self.state = {"runs": {RUN: {"status": "completed", "merge_environment": {
            "preparation_run_id": RUN, "generation": GEN, "phase": "ready", "instance": "instance-fixture"}}},
            "instances": {"instance-fixture": {"name": INSTANCE, "state": "prepared"}}, "plans": {}}
        self.save_state()

    def save_state(self):
        self.state_path.write_text(json.dumps(self.state))
        self.state_path.chmod(0o600)

    def write_secret(self, name, content):
        path = self.private / "merge-inspection" / name
        path.write_text(content)
        path.chmod(0o600)

    def save(self, manifest=None):
        path = self.private / "merge-access.json"
        path.write_text(json.dumps(manifest or self.manifest))
        path.chmod(0o600)

    def ws(self):
        def control(argv, **kwargs):
            self.assertEqual(["standard", "run", "show", "arc", RUN], argv)
            run = self.state["runs"][RUN]
            if "merge_environment" in run:
                environment = run["merge_environment"]
            else:
                environment = self.state["runs"][PREP]["merge_environment"]
            return json.dumps({"status": run["status"], "merge_environment": environment})
        return self.d.Workspace(self.base, "arc", ROOT, None, {}, control)

    def info(self, **request):
        return self.m.inspection_info(self.ws(), {"run_id": RUN, "generation": GEN, "side": "base", **request}, self.api)

    def refused(self, code, call):
        with self.assertRaises(self.d.Refusal) as caught:
            call()
        self.assertTrue(str(caught.exception).startswith(code), str(caught.exception))

    def mcp(self):
        return json.loads((self.config_home / "term-llm/mcp.json").read_text())

    # -- registration --------------------------------------------------------------------

    def test_inspection_info_registers_one_generation_bound_server_and_returns_safe_fields(self):
        (self.config_home / "term-llm/mcp.json").write_text(json.dumps({"servers": {"mine": {"command": "x", "args": ["y"]}}}))
        with mock.patch.object(self.m, "connector_ready", return_value=("/x", "sha256:" + "9" * 64, "e.js")):
            result = self.info()
        self.assertEqual({"run_id", "generation", "side", "mcp_server", "registration", "ready", "next", "access_model", "category_budget"}, set(result))
        self.assertEqual(("merge-base-arc", "added", True), (result["mcp_server"], result["registration"], result["ready"]))
        text = json.dumps(result)
        for secret in (KEY, PASSWORD, str(self.base), "silo_inspect_", "41000", "merge_source_inspect"):
            self.assertNotIn(secret, text)
        servers = self.mcp()["servers"]
        self.assertEqual({"command": "x", "args": ["y"]}, servers["mine"])
        entry = servers["merge-base-arc"]
        self.assertEqual({"command", "args"}, set(entry))
        self.assertEqual(["merge-mcp", "arc", RUN, GEN, "base"], entry["args"])
        self.assertTrue(entry["command"].endswith("/bin/silo-migrate-control"))
        self.assertNotIn(KEY, (self.config_home / "term-llm/mcp.json").read_text())
        self.assertEqual(0o600, stat.S_IMODE((self.config_home / "term-llm/mcp.json").stat().st_mode))
        source = self.info(side="source")
        self.assertEqual("merge-source-arc", source["mcp_server"])
        self.assertEqual(["merge-dbhub", "arc", RUN, GEN, "source"], self.mcp()["servers"]["merge-source-arc"]["args"])
        self.assertIn("merge-base-arc", self.mcp()["servers"])  # both sides of the open base phase stay

    def test_open_manifest_refuses_failed_dirty_consumed_reset_or_wrong_generation(self):
        import copy
        original = copy.deepcopy(self.state)
        for change in ("failed", "running", "dirty", "reset", "consumed", "generation", "owner", "removed"):
            with self.subTest(change=change):
                self.state = copy.deepcopy(original)
                run = self.state["runs"][RUN]
                env = run["merge_environment"]
                if change in ("failed", "running"):
                    run["status"] = change
                elif change in ("dirty", "reset", "consumed"):
                    env["phase"] = change
                elif change == "generation":
                    env["generation"] = "0" * 64
                elif change == "owner":
                    env["preparation_run_id"] = PREP
                else:
                    self.state["instances"]["instance-fixture"]["state"] = "removed"
                self.save_state()
                self.refused("STANDARD_MERGE_INSPECTION_STALE", self.info)
                self.assertFalse(self.m._still_open(self.ws(), RUN, GEN, "base", self.api))
                with mock.patch("subprocess.run") as created:
                    self.refused("STANDARD_MERGE_INSPECTION_STALE", lambda: self.launch("source", "merge-dbhub"))
                    created.assert_not_called()
        self.assertFalse((self.config_home / "term-llm/mcp.json").exists())

    def test_malformed_manifest_and_state_fail_with_fixed_codes(self):
        import copy
        for endpoints in ([], "not-an-object", None):
            manifest = copy.deepcopy(self.manifest)
            manifest["endpoints"] = endpoints
            self.save(manifest)
            self.refused("STANDARD_MERGE_INSPECTION_INVALID", self.info)
        self.save()
        for policy in ([], "not-an-object", None):
            manifest = copy.deepcopy(self.manifest)
            manifest["endpoints"]["source"]["policy"] = policy
            self.save(manifest)
            self.refused("STANDARD_MERGE_INSPECTION_INVALID", lambda: self.info(side="source"))
        self.save()
        original = copy.deepcopy(self.state)
        for value in (None, [], "not-an-object"):
            self.state = copy.deepcopy(original)
            self.state["runs"][RUN]["merge_environment"] = value
            self.save_state()
            self.refused("STANDARD_MERGE_INSPECTION_STALE", self.info)
        self.state_path.write_text("[" * 20000 + "]" * 20000)
        self.refused("STANDARD_MERGE_INSPECTION_STALE", self.info)
        self.state = original
        self.save_state()

    def test_result_requires_matching_completed_consumer_and_recorded_backup(self):
        import copy
        self.state["runs"][PREP] = self.state["runs"].pop(RUN)
        env = self.state["runs"][PREP]["merge_environment"]
        env.update(preparation_run_id=PREP, phase="result", consumed_by=RUN)
        self.state["runs"][RUN] = {"status": "completed", "plan_id": "plan-fixture", "artifacts": {"backup": {
            "merge_generation": GEN, "preparation_run_id": PREP}}}
        self.state["plans"] = {"plan-fixture": {"body": {"prepared_from": {"run_id": PREP, "generation": GEN}}}}
        self.manifest.update(preparation_run_id=PREP, phase="result")
        self.manifest["endpoints"] = {"result": dict(self.manifest["endpoints"]["base"], credential="result.key")}
        self.write_secret("result.key", KEY)
        self.save()
        self.save_state()
        self.assertEqual("result", self.info(side="result")["side"])
        self.state["runs"][RUN]["artifacts"]["backup"]["merge_generation"] = "0" * 64
        self.save_state()
        self.refused("STANDARD_MERGE_INSPECTION_STALE", lambda: self.info(side="result"))

    def test_missing_connector_or_image_is_a_clear_not_ready_not_a_download(self):
        with mock.patch.object(self.m, "connector_ready", return_value=None):
            result = self.info()
        self.assertFalse(result["ready"])
        self.assertIn("silo update", result["next"])
        self.docker.image_present = False
        self.assertFalse(self.info(side="source")["ready"])
        self.assertFalse(any(call[:1] == ["pull"] for call in self.docker.calls))

    def test_rules_unenforced_or_missing_registers_nothing(self):
        self.api.term_llm_enforces = lambda term: False
        self.refused("STANDARD_MERGE_MCP_RULES_UNENFORCED", self.info)
        self.api.term_llm_enforces = lambda term: True
        (self.config_home / "term-llm/config.yaml").write_text("providers: {}\n")
        self.api.mcp_rule = lambda name, term: False
        self.refused("STANDARD_MERGE_MCP_RULE_MISSING", self.info)
        self.assertFalse((self.config_home / "term-llm/mcp.json").exists())

    def test_foreign_server_name_is_left_alone_and_deregister_removes_only_ours(self):
        (self.config_home / "term-llm/mcp.json").write_text(json.dumps({"servers": {"merge-base-arc": {"command": "npx", "args": ["x"]}}}))
        self.refused("STANDARD_MERGE_MCP_NAME_TAKEN", self.info)
        self.assertEqual(["x"], self.mcp()["servers"]["merge-base-arc"]["args"])
        (self.config_home / "term-llm/mcp.json").write_text(json.dumps({"servers": {"db-arc": {"command": "c", "args": ["dbhub", "arc"]}}}))
        self.info()
        self.assertEqual(1, self.m.deregister(self.ws(), self.api))
        self.assertEqual({"db-arc"}, set(self.mcp()["servers"]))  # generic DBHub untouched

    # -- manifest/generation/path validation ------------------------------------------------

    def test_bad_requests_stale_generations_and_fenced_manifests_are_refused(self):
        for bad in ({"run_id": "../x"}, {"generation": "short"}, {"side": "destination"}):
            with self.subTest(request=bad):
                self.refused("STANDARD_ARGUMENTS_INVALID", lambda: self.info(**bad))
        self.refused("STANDARD_MERGE_INSPECTION_STALE", lambda: self.info(generation="d" * 64))
        self.refused("STANDARD_MERGE_INSPECTION_STALE", lambda: self.info(side="result"))
        for state in ("opening", "fencing", "closed"):
            with self.subTest(state=state):
                self.save({**self.manifest, "state": state})
                self.refused("STANDARD_MERGE_INSPECTION_STALE", self.info)
        self.save({**self.manifest, "owner": {"workspace": "other", "instance": INSTANCE}})
        self.refused("STANDARD_MERGE_INSPECTION_INVALID", self.info)
        self.save({**self.manifest, "version": 2})
        self.refused("STANDARD_MERGE_INSPECTION_INVALID", self.info)
        endpoint = dict(self.manifest["endpoints"]["base"], scope_mode="global")
        self.save({**self.manifest, "endpoints": {"base": endpoint}})
        self.refused("STANDARD_MERGE_INSPECTION_INVALID", self.info)
        (self.private / "merge-access.json").write_text("{not json")
        self.refused("STANDARD_MERGE_INSPECTION_INVALID", self.info)
        self.assertFalse((self.config_home / "term-llm/mcp.json").exists())

    def test_symlinks_and_non_private_modes_are_refused(self):
        (self.private / "merge-access.json").chmod(0o644)
        self.refused("STANDARD_MERGE_INSPECTION_INVALID", self.info)
        self.save()
        self.private.chmod(0o750)
        self.refused("STANDARD_MERGE_INSPECTION_INVALID", self.info)
        self.private.chmod(0o700)
        real = self.private / "elsewhere.json"
        (self.private / "merge-access.json").rename(real)
        (self.private / "merge-access.json").symlink_to(real)
        self.refused("STANDARD_MERGE_INSPECTION_INVALID", self.info)
        runs = self.private.parent.parent
        moved = runs.parent / "runs-real"
        runs.rename(moved)
        runs.symlink_to(moved)
        self.refused("STANDARD_MERGE_INSPECTION_INVALID", self.info)

    def test_environment_must_be_the_recorded_internal_only_stack(self):
        with mock.patch.object(self.m, "connector_ready", return_value=None):
            self.docker.internal = False
            self.refused("STANDARD_MERGE_INSPECTION_UNAVAILABLE", self.info)
            self.docker.internal = True
            self.docker.web_networks = {INSTANCE + "-int": {}, INSTANCE + "-pub": {}}
            self.refused("STANDARD_MERGE_INSPECTION_UNAVAILABLE", self.info)
            self.docker.web_networks = {INSTANCE + "-int": {}}
            self.docker.running = False
            self.refused("STANDARD_MERGE_INSPECTION_UNAVAILABLE", self.info)
            self.docker.running = True
            self.save({**self.manifest, "containers": {"web": "3" * 64, "db": DB}})
            self.refused("STANDARD_MERGE_INSPECTION_UNAVAILABLE", self.info)

    def test_a_held_fence_lock_blocks_validation(self):
        import fcntl
        fd = os.open(self.private / "merge-access.lock", os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            with mock.patch.object(self.m, "LOCK_WAIT", 0.2):
                self.refused("STANDARD_BUSY", self.info)
        finally:
            os.close(fd)

    # -- launchers ---------------------------------------------------------------------------

    def launch(self, side, verb):
        created = []

        def run(argv, env=None, **kwargs):
            created.append((argv, env))
            return subprocess.CompletedProcess(argv, 0, ("4" * 64 + "\n").encode(), b"")
        with mock.patch("subprocess.run", side_effect=run), mock.patch.object(self.m.os, "execvpe") as execvpe, \
                mock.patch.object(self.m, "connector_ready", return_value=(Path("/opt/prepared/install"), "sha256:" + "9" * 64, "node_modules/@discourse/mcp/dist/index.js")):
            self.m.main([verb, "arc", RUN, GEN, side], {}, self.base, ROOT, None, self.api)
        return created, execvpe.call_args[0]

    def test_mcp_launcher_uses_a_private_tethered_read_only_profile_and_no_secret_in_argv(self):
        created, (file, argv, env) = self.launch("base", "merge-mcp")
        self.assertEqual(1, len(created))
        create, create_env = created[0]
        self.assertEqual(["docker", "start", "-a", "-i", "4" * 64], argv)
        joined = " ".join(create + argv)
        self.assertNotIn(KEY, joined)
        self.assertNotIn(KEY, json.dumps(env))
        self.assertNotIn(KEY, json.dumps(create_env))
        self.assertEqual(INSTANCE + "-int", create[create.index("--network") + 1])
        for flag in ("--rm", "-i", "--pull=never", "--read-only", "--cap-drop", "--log-driver"):
            self.assertIn(flag, create)
        self.assertNotIn("-p", create)
        self.assertIn("silo.merge-run=" + RUN, create)
        self.assertIn("silo.merge-generation=" + GEN, create)
        self.assertIn("silo.role=merge-mcp", create)
        self.assertEqual("node", create[create.index("--entrypoint") + 1])
        profile_path = self.private / "merge-inspection/base.profile.json"
        self.assertEqual(0o600, stat.S_IMODE(profile_path.stat().st_mode))
        profile = json.loads(profile_path.read_text())
        self.assertEqual("http://web", profile["site"])
        self.assertEqual([{"site": "http://web", "api_key": KEY, "api_username": "silo_inspect_0a1b2c3d"}], profile["auth_pairs"])
        self.assertEqual((False, True, "discourse_api_only", False, "silent"),
                         (profile["allow_writes"], profile["read_only"], profile["tools_mode"], profile["show_emails"], profile["log_level"]))
        self.assertEqual(["search", "topics", "users", "groups", "administration"], profile["toolsets"])
        self.assertNotIn("categories", profile["toolsets"])  # not a 0.3.1 toolset
        self.assertLessEqual(profile["max_read_length"], 20000)
        mounts = [create[i + 1] for i, a in enumerate(create) if a == "--mount"]
        self.assertTrue(all(mount.endswith(",readonly") for mount in mounts))

    def test_dbhub_password_is_only_in_the_private_read_only_config_never_env_or_argv(self):
        created, (file, argv, env) = self.launch("source", "merge-dbhub")
        create, create_env = created[0]
        # Nothing that docker inspect (Config.Env) or a process listing could show.
        self.assertNotIn(PASSWORD, json.dumps(create_env) + json.dumps(env) + " ".join(create + argv))
        self.assertNotIn("DB_PASSWORD", " ".join(create))
        self.assertEqual(["HOME=/tmp"], [create[i + 1] for i, a in enumerate(create) if a == "-e"])
        self.assertEqual(self.d.DBHUB_IMAGE, create[create.index("--transport") - 1])
        path = self.private / "merge-inspection/source.dbhub.toml"
        self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
        toml = path.read_text()
        self.assertIn("postgres://silo_mi_0a1b2c3d:" + PASSWORD + "@db:5432/merge_source_inspect", toml)
        self.assertIn("readonly = true", toml)
        mounts = [create[i + 1] for i, a in enumerate(create) if a == "--mount"]
        self.assertEqual(["type=bind,src=%s,dst=/config/dbhub.toml,readonly" % path], mounts)
        self.assertIn("silo.role=merge-dbhub", create)

    def test_every_launch_rechecks_the_per_agent_rule_and_never_repairs_it(self):
        main = lambda side, verb: self.m.main([verb, "arc", RUN, GEN, side], {}, self.base, ROOT, None, self.api)
        rules = self.config_home / "term-llm/config.yaml"
        config = rules.read_text()
        cases = {
            "rule gone": ("mcp:\n  servers:\n    merge-source-arc:\n      agents: [migration-data]\n", None, "STANDARD_MERGE_MCP_RULE_MISSING"),
            "other agent": (config.replace("merge-base-arc:\n      agents: [migration-data]", "merge-base-arc:\n      agents: [converter-developer]"),
                            None, "STANDARD_MERGE_MCP_RULE_MISSING"),
            "rules unenforced": (config, lambda term: False, "STANDARD_MERGE_MCP_RULES_UNENFORCED"),
        }
        for label, (text, enforces, code) in cases.items():
            with self.subTest(label):
                rules.write_text(text)
                self.api.term_llm_enforces = enforces or (lambda term: True)
                self.api.mcp_rule = lambda name, term: self.fail("a launch must not write the rule")
                with mock.patch("subprocess.run") as run, mock.patch.object(self.m.os, "execvpe") as execvpe, \
                        mock.patch.object(self.m, "connector_ready", return_value=(Path("/p"), "sha256:" + "9" * 64, "e.js")):
                    self.refused(code, lambda: main("base", "merge-mcp"))
                    run.assert_not_called()  # no docker create
                    execvpe.assert_not_called()
                self.assertEqual(text, rules.read_text())  # refused, not repaired
        self.api.term_llm_command = lambda prefix: None  # no term-llm found: not provably enforced
        rules.write_text(config)
        self.api.term_llm_enforces = lambda term: True
        with mock.patch("subprocess.run") as run:
            self.refused("STANDARD_MERGE_MCP_RULES_UNENFORCED", lambda: main("source", "merge-dbhub"))
            run.assert_not_called()

    def test_only_exact_owned_entries_count_as_ours(self):
        ws = self.ws()
        control = self.d.mcp_entry(ws)["command"]
        good = {"command": control, "args": ["merge-mcp", "arc", RUN, GEN, "base"]}
        self.assertTrue(self.m._ours("merge-base-arc", good, ws, self.api))
        bad = {
            "other command": {"command": "/tmp/evil", "args": good["args"]},
            "extra key": {**good, "env": {"X": "1"}},
            "verb/side mismatch": {"command": control, "args": ["merge-dbhub", "arc", RUN, GEN, "base"]},
            "bad run": {"command": control, "args": ["merge-mcp", "arc", "../x", GEN, "base"]},
            "bad generation": {"command": control, "args": ["merge-mcp", "arc", RUN, "short", "base"]},
            "other project": {"command": control, "args": ["merge-mcp", "other", RUN, GEN, "base"]},
            "name of another side": None,
        }
        for label, server in bad.items():
            with self.subTest(label):
                if server is None:
                    self.assertFalse(self.m._ours("merge-result-arc", good, ws, self.api))
                else:
                    self.assertFalse(self.m._ours("merge-base-arc", server, ws, self.api))
        # A foreign entry under our name is never overwritten or removed.
        (self.config_home / "term-llm/mcp.json").write_text(json.dumps({"servers": {"merge-base-arc": bad["other command"]}}))
        self.refused("STANDARD_MERGE_MCP_NAME_TAKEN", self.info)
        self.assertEqual(0, self.m.deregister(ws, self.api))
        self.assertEqual("/tmp/evil", self.mcp()["servers"]["merge-base-arc"]["command"])

    def test_unacknowledged_create_is_cleaned_by_its_fixed_name_and_reported_uncertain_if_unconfirmed(self):
        seen = []

        def scenario(create, removal_confirms):
            seen.clear()

            def run(argv, env=None, **kwargs):
                seen.append(list(argv))
                if argv[:2] == ["docker", "create"]:
                    if create == "timeout":
                        raise subprocess.TimeoutExpired(argv, 60)
                    return subprocess.CompletedProcess(argv, 1 if create == "error" else 0, b"warning only\n", b"")
                if argv[:3] == ["docker", "container", "inspect"]:
                    return subprocess.CompletedProcess(argv, 1, b"", b"Error: No such container") if removal_confirms \
                        else subprocess.CompletedProcess(argv, 0, b"[{}]", b"")
                return subprocess.CompletedProcess(argv, 0, b"", b"")
            with mock.patch("subprocess.run", side_effect=run), mock.patch.object(self.m.os, "execvpe") as execvpe, \
                    mock.patch.object(self.m, "connector_ready", return_value=(Path("/p"), "sha256:" + "9" * 64, "e.js")):
                with self.assertRaises(self.d.Refusal) as caught:
                    self.m.main(["merge-mcp", "arc", RUN, GEN, "base"], {}, self.base, ROOT, None, self.api)
                execvpe.assert_not_called()
            name = seen[0][seen[0].index("--name") + 1]
            self.assertIn(["docker", "rm", "-f", name], seen)  # the exact name it tried to create
            return str(caught.exception)
        for create in ("timeout", "error", "garbled"):
            with self.subTest(create):
                self.assertTrue(scenario(create, True).startswith("STANDARD_MERGE_INSPECTION_UNAVAILABLE"))
                self.assertTrue(scenario(create, False).startswith("STANDARD_MERGE_INSPECTION_LAUNCH_UNCERTAIN"))

    def test_preparation_is_serialized_and_never_deletes_an_install(self):
        pin, lock_sha = self.m.runtime_pin(ROOT)
        target = self.m.connector_dir(lock_sha)
        target.parent.mkdir(parents=True)
        import fcntl
        fd = os.open(target.parent / ".prepare.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            with mock.patch.object(self.m, "PREPARE_LOCK_WAIT", 0.3), self.assertRaises(ValueError) as caught:
                self.m.prepare_connector(ROOT, self.api, pull=False, runner=lambda argv: self.fail("must wait for the lock"))
            self.assertIn("another preparation", str(caught.exception))
        finally:
            os.close(fd)
        # An existing (failed-verification) install that a launcher may still mount is moved aside, intact.
        (target / "install").mkdir(parents=True)
        (target / "install/in-use.js").write_text("mounted")

        def runner(argv):
            work = Path(argv[argv.index("--mount") + 1].split(",")[1].split("=", 1)[1])
            (work / "node_modules/@discourse/mcp").mkdir(parents=True)
            (work / "node_modules/@discourse/mcp/package.json").write_text(json.dumps({"version": "0.3.1"}))
            (work / "node_modules/.package-lock.json").write_text(json.dumps(
                {"packages": {"node_modules/@discourse/mcp": {"version": "0.3.1", "integrity": pin["package_integrity"]}}}))
            return 0
        self.assertEqual("prepared", self.m.prepare_connector(ROOT, self.api, pull=False, runner=runner)["status"])
        retired = [p for p in target.parent.iterdir() if p.name.startswith(".retired-")]
        self.assertEqual(1, len(retired))
        self.assertEqual("mounted", (retired[0] / "install/in-use.js").read_text())

    def test_launchers_refuse_tampered_credentials_wrong_sides_and_unprepared_connectors(self):
        self.write_secret("base.key", "0" * 64)  # e.g. a restored production key swapped in
        with mock.patch("subprocess.run") as run, mock.patch.object(self.m.os, "execvpe") as execvpe, \
                mock.patch.object(self.m, "connector_ready", return_value=(Path("/p"), "sha256:" + "9" * 64, "e.js")):
            self.refused("STANDARD_MERGE_INSPECTION_INVALID", lambda: self.m.main(["merge-mcp", "arc", RUN, GEN, "base"], {}, self.base, ROOT, None, self.api))
            for bad in (["merge-mcp", "arc", RUN, GEN, "source"], ["merge-dbhub", "arc", RUN, GEN, "base"], ["merge-mcp", "arc", RUN, GEN]):
                self.refused("STANDARD_ARGUMENTS_INVALID", lambda: self.m.main(bad, {}, self.base, ROOT, None, self.api))
            run.assert_not_called()
            execvpe.assert_not_called()
        with mock.patch("subprocess.run") as run, mock.patch.object(self.m.os, "execvpe") as execvpe, \
                mock.patch.object(self.m, "connector_ready", return_value=None):
            self.refused("STANDARD_MERGE_MCP_NOT_PREPARED", lambda: self.m.main(["merge-mcp", "arc", RUN, GEN, "base"], {}, self.base, ROOT, None, self.api))
            run.assert_not_called()
        self.save({**self.manifest, "state": "fencing"})
        with mock.patch("subprocess.run") as run, mock.patch.object(self.m.os, "execvpe"), \
                mock.patch.object(self.m, "connector_ready", return_value=(Path("/p"), "sha256:" + "9" * 64, "e.js")):
            self.refused("STANDARD_MERGE_INSPECTION_STALE", lambda: self.m.main(["merge-dbhub", "arc", RUN, GEN, "source"], {}, self.base, ROOT, None, self.api))
            run.assert_not_called()

    # -- connector pin/preparation ------------------------------------------------------------

    def test_pin_is_exact_and_preparation_never_pulls_when_told_not_to(self):
        pin, lock = self.m.runtime_pin(ROOT)
        self.assertEqual(("@discourse/mcp", "0.3.1"), (pin["package"], pin["package_version"]))
        self.assertRegex(pin["node_image"], r"@sha256:[0-9a-f]{64}$")
        self.assertEqual(64, len(lock))
        self.docker.image_present = False
        with self.assertRaises(ValueError) as caught:
            self.m.prepare_connector(ROOT, self.api, pull=False, runner=lambda argv: self.fail("must not install"))
        self.assertIn("MERGE_MCP_PREPARE_FAILED", str(caught.exception))
        self.assertIsNone(self.m.connector_ready(ROOT, self.api))

    def test_prepare_installs_only_from_the_committed_lock_inside_the_pinned_image(self):
        seen = []

        def runner(argv):
            seen.append(argv)
            work = Path(argv[argv.index("--mount") + 1].split(",")[1].split("=", 1)[1])
            self.assertEqual({"package.json", "package-lock.json"}, {p.name for p in work.iterdir()})
            package = work / "node_modules/@discourse/mcp"
            package.mkdir(parents=True)
            pin, _ = self.m.runtime_pin(ROOT)
            (package / "package.json").write_text(json.dumps({"version": "0.3.1"}))
            (work / "node_modules/.package-lock.json").write_text(json.dumps(
                {"packages": {"node_modules/@discourse/mcp": {"version": "0.3.1", "integrity": pin["package_integrity"]}}}))
            return 0
        self.docker.image_present = True
        result = self.m.prepare_connector(ROOT, self.api, pull=False, runner=runner)
        self.assertEqual("prepared", result["status"])
        argv = seen[0]
        for flag in ("--ignore-scripts", "--no-bin-links", "--omit=dev", "--pull=never", "--read-only"):
            self.assertIn(flag, argv)
        self.assertEqual(["npm", "ci"], argv[argv.index("sha256:" + "9" * 64) + 1:][:2])
        self.assertIsNotNone(self.m.connector_ready(ROOT, self.api))
        self.assertEqual("ready", self.m.prepare_connector(ROOT, self.api, pull=False, runner=lambda a: self.fail("reinstall"))["status"])
        install = self.m.connector_ready(ROOT, self.api)[0]
        (install / "node_modules/@discourse/mcp/extra.js").write_text("tampered")
        self.assertIsNone(self.m.connector_ready(ROOT, self.api))

    def test_pinned_node_image_accepts_only_the_exact_digest_canonical_or_fixed_mirror(self):
        pin, _ = self.m.runtime_pin(ROOT)
        image = lambda: self.m.pinned_node_image(self.api, pin)
        other = "sha256:" + "8" * 64
        self.assertEqual("sha256:" + "9" * 64, image())  # canonical ref, RepoDigest node@digest
        # Mirrored pull (containerd store): canonical tag@digest misses, the bare digest is the ID.
        self.docker.node_refs = {NODE_DIGEST: (NODE_DIGEST, [MIRROR_REF])}
        self.assertEqual(NODE_DIGEST, image())
        # Classic store via the mirror: ID is the config digest, RepoDigest names the mirror@digest.
        self.docker.node_refs = {MIRROR_REF: ("sha256:" + "7" * 64, [MIRROR_REF])}
        self.assertEqual("sha256:" + "7" * 64, image())
        refused = {
            "tag only": {"node:24.22.3-bookworm-slim": ("sha256:" + "7" * 64, [])},
            "other digest": {NODE_REF: ("sha256:" + "7" * 64, ["node@" + other])},
            "other repository": {MIRROR_REF: ("sha256:" + "7" * 64, ["evil.example/node@" + NODE_DIGEST])},
            "no repo digests": {NODE_DIGEST: ("sha256:" + "7" * 64, [])},
            "malformed": {NODE_REF: ("not-an-id", ["node@" + NODE_DIGEST])},
        }
        for label, refs in refused.items():
            with self.subTest(label):
                self.docker.node_refs = refs
                self.assertIsNone(image())

    def test_prepare_falls_back_to_the_fixed_mirror_by_the_same_digest_only(self):
        self.docker.node_refs = {}
        with self.assertRaises(ValueError):
            self.m.prepare_connector(ROOT, self.api, pull=False, runner=lambda argv: self.fail("must not install"))
        self.assertEqual([], self.docker.pulls)  # pull=False never pulls
        # Canonical 429, mirror by digest succeeds; the install then runs on exactly that image.
        self.docker.pullable = {MIRROR_REF: {NODE_DIGEST: (NODE_DIGEST, [MIRROR_REF])}}
        seen = []

        def runner(argv):
            seen.append(argv)
            work = Path(argv[argv.index("--mount") + 1].split(",")[1].split("=", 1)[1])
            pin, _ = self.m.runtime_pin(ROOT)
            (work / "node_modules/@discourse/mcp").mkdir(parents=True)
            (work / "node_modules/@discourse/mcp/package.json").write_text(json.dumps({"version": "0.3.1"}))
            (work / "node_modules/.package-lock.json").write_text(json.dumps(
                {"packages": {"node_modules/@discourse/mcp": {"version": "0.3.1", "integrity": pin["package_integrity"]}}}))
            return 0
        with mock.patch.object(self.m, "connector_ready", side_effect=[None, ("install", NODE_DIGEST, "entry")]):
            self.assertEqual("prepared", self.m.prepare_connector(ROOT, self.api, pull=True, runner=runner)["status"])
        self.assertEqual([NODE_REF, MIRROR_REF], self.docker.pulls)
        self.assertIn(NODE_DIGEST, seen[0])
        # A mirror that serves something else under that name is not accepted.
        self.docker.node_refs, self.docker.pulls = {}, []
        self.docker.pullable = {MIRROR_REF: {MIRROR_REF: ("sha256:" + "7" * 64, ["mirror.gcr.io/library/node@sha256:" + "8" * 64])}}
        with self.assertRaises(ValueError) as caught:
            self.m.prepare_connector(ROOT, self.api, pull=True, runner=lambda argv: self.fail("must not install"))
        self.assertIn("could not be pulled", str(caught.exception))
        self.assertTrue(all("@" + NODE_DIGEST in ref for ref in self.docker.pulls))  # never a tag or other digest

    # -- the real data_tools module, as op_merge_inspection passes it -----------------------

    def real_module(self):
        """data_tools as the parent dispatches it: roles_api() snapshot of its own globals; only
        Docker and the term-llm binary are faked, the mcp.json lock/writes are its own."""
        patches = [mock.patch.object(self.d, "docker", self.docker),
                   mock.patch.object(self.d, "term_llm_command", lambda prefix: "/bin/true"),
                   mock.patch.object(self.d, "term_llm_enforces", lambda term: True),
                   mock.patch.object(self.d, "dbhub_image", lambda pull_seconds=0: self.docker.image_present)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        data = self.base / "arc/.silo-migrate/data"
        data.mkdir(mode=0o700, exist_ok=True)
        (data / "workspace.json").write_text(json.dumps({"platform": "discourse"}))

    def test_op_merge_inspection_runs_through_the_real_data_module_and_its_mcp_lock(self):
        self.real_module()
        self.assertTrue(hasattr(self.d, "op_merge_inspection") and hasattr(self.d, "roles_api"))
        lock = self.config_home / "term-llm/.mcp.json.silo-lock"
        held = []
        original = self.d.write_mcp_config

        def write_while_checking_lock(path, config):
            # The very lock legacy mcp_register takes must be held while mcp.json is replaced.
            fd = os.open(lock, os.O_RDWR)
            try:
                import fcntl
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    held.append(False)
                    fcntl.flock(fd, fcntl.LOCK_UN)
                except BlockingIOError:
                    held.append(True)
            finally:
                os.close(fd)
            return original(path, config)

        with mock.patch.object(self.d, "write_mcp_config", write_while_checking_lock):
            result = self.d.op_merge_inspection(self.ws(), {"run_id": RUN, "generation": GEN, "side": "base"})
            source = self.d.op_merge_inspection(self.ws(), {"run_id": RUN, "generation": GEN, "side": "source"})
        self.assertEqual(("merge-base-arc", "merge-source-arc"), (result["mcp_server"], source["mcp_server"]))
        self.assertTrue(held and all(held), held)
        self.assertNotIn(KEY, json.dumps(result) + (self.config_home / "term-llm/mcp.json").read_text())
        with self.assertRaises(self.d.Refusal):
            self.d.op_merge_inspection(self.ws(), {"run_id": RUN, "generation": "d" * 64, "side": "base"})

    def test_host_main_validates_through_the_real_data_module(self):
        self.real_module()
        for bad in (["merge-mcp", "arc", RUN, GEN, "source"], ["merge-dbhub", "arc", RUN, GEN, "base"], ["merge-mcp", "arc", RUN, GEN]):
            with self.subTest(args=bad), mock.patch.object(self.m.os, "execvpe") as execvpe, self.assertRaises(self.d.Refusal):
                self.m.main(bad, {}, self.base, ROOT, None, self.d)
            execvpe.assert_not_called()

    # -- host cleanup after close/merge/reset --------------------------------------------

    def test_cleanup_keeps_open_generations_at_status_time_and_removes_after_close(self):
        self.real_module()
        self.d.op_merge_inspection(self.ws(), {"run_id": RUN, "generation": GEN, "side": "base"})
        self.d.op_merge_inspection(self.ws(), {"run_id": RUN, "generation": GEN, "side": "source"})
        servers = self.mcp()["servers"]
        servers["mine"] = {"command": "x", "args": ["merge-mcp", "arc", RUN, GEN, "base"]}  # not ours by name
        servers["db-arc"] = {"command": "c", "args": ["dbhub", "arc"]}
        control = self.d.mcp_entry(self.ws())["command"]
        servers["merge-result-arc"] = {"command": control, "args": ["merge-mcp", "arc", "run-" + "0" * 32, GEN, "result"]}  # stale
        (self.config_home / "term-llm/mcp.json").write_text(json.dumps({"servers": servers}))
        live, stale = "3" * 64, "4" * 64
        self.docker.launchers = [("merge-mcp", live, RUN, GEN, "base"), ("merge-mcp", stale, RUN, "d" * 64, "base")]
        # Status-time (no run): only what no longer validates goes.
        self.assertEqual({"version": 1, "launchers_removed": 1, "servers_removed": 1}, self.m.cleanup(self.ws(), self.d))
        self.assertEqual({"merge-base-arc", "merge-source-arc", "mine", "db-arc"}, set(self.mcp()["servers"]))
        self.assertEqual([live], [row[1] for row in self.docker.launchers])
        # After Ruby merge_inspection_close the manifest is closed: everything owned goes.
        self.save({**self.manifest, "state": "closed"})
        self.assertEqual({"version": 1, "launchers_removed": 1, "servers_removed": 2}, self.m.cleanup(self.ws(), self.d))
        self.assertEqual({"mine", "db-arc"}, set(self.mcp()["servers"]))
        self.assertEqual({"version": 1, "launchers_removed": 0, "servers_removed": 0}, self.m.cleanup(self.ws(), self.d))  # idempotent
        audit = (self.base / "arc/.silo-migrate/data/audit.jsonl").read_text()
        self.assertIn("merge_mcp_cleanup", audit)
        self.assertNotIn(KEY, audit)

    def test_cleanup_for_a_run_fences_even_an_open_manifest_and_reports_failures(self):
        self.real_module()
        self.d.op_merge_inspection(self.ws(), {"run_id": RUN, "generation": GEN, "side": "base"})
        self.docker.launchers = [("merge-mcp", "3" * 64, RUN, GEN, "base"), ("merge-dbhub", "5" * 64, "run-" + "9" * 32, GEN, "source")]
        self.assertEqual({"version": 1, "launchers_removed": 1, "servers_removed": 1}, self.m.cleanup(self.ws(), self.d, run_id=RUN))
        self.assertEqual(["5" * 64], [row[1] for row in self.docker.launchers])  # another run's launcher untouched
        self.refused("STANDARD_ARGUMENTS_INVALID", lambda: self.m.cleanup(self.ws(), self.d, run_id="../x"))
        self.docker.ps_fails = True
        self.refused("STANDARD_MERGE_INSPECTION_CLEANUP_FAILED", lambda: self.m.cleanup(self.ws(), self.d))

    # -- the pinned connector itself ---------------------------------------------------------

    def connector(self):
        """The pinned 0.3.1 package: a prepared install, or MERGE_MCP_CONNECTOR_ROOT, plus host node."""
        import shutil
        node = shutil.which("node")
        candidates = []
        prepared = self.m.connector_ready(ROOT, self.d) if os.environ.get("XDG_DATA_HOME") else None
        if prepared:
            candidates.append(prepared[0] / "node_modules/@discourse/mcp")
        for root in (os.environ.get("MERGE_MCP_CONNECTOR_ROOT"), "/usr/local/lib/node_modules/@discourse/mcp"):
            if root:
                candidates.append(Path(root))
        for root in candidates:
            try:
                if json.loads((root / "package.json").read_text()).get("version") == "0.3.1" and node:
                    return node, root
            except (OSError, ValueError):
                continue
        self.skipTest("pinned @discourse/mcp 0.3.1 and node are not available on this host")

    def test_pinned_connector_lists_exactly_the_reviewed_read_tools_and_restricted_categories(self):
        import http.server
        import select
        import threading
        node, root = self.connector()
        seen = []
        categories = {"category_list": {"categories": [
            {"id": 3, "name": "Invented public", "slug": "invented-public", "read_restricted": False, "topic_count": 1, "post_count": 2},
            {"id": 4, "name": "Invented staff", "slug": "invented-staff", "read_restricted": True, "topic_count": 5, "post_count": 6}]}}

        class Site(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, body):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                seen.append(("GET", self.path.split("?")[0], self.headers.get("Api-Key"), self.headers.get("Api-Username")))
                if self.path == "/about.json":
                    return self.reply(200, {"about": {"title": "Invented"}})
                if self.path.startswith("/categories.json"):
                    return self.reply(200, categories)
                return self.reply(404, {})

            def do_POST(self):
                seen.append(("POST", self.path.split("?")[0], self.headers.get("Api-Key"), self.headers.get("Api-Username")))
                # A read_only (global:read) key: Discourse refuses non-GET requests with 403.
                self.reply(403, {"errors": ["invalid_access"]})

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Site)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        site = "http://127.0.0.1:%d" % server.server_address[1]
        endpoint = self.manifest["endpoints"]["base"]
        profile = self.m.mcp_profile(endpoint, KEY)
        # The only deviation from the launcher's profile: the invented site's loopback URL.
        profile["site"] = site
        profile["auth_pairs"][0]["site"] = site
        path = Path(self.tmp.name) / "profile.json"
        path.write_text(json.dumps(profile))
        path.chmod(0o600)
        process = subprocess.Popen([node, str(root / "dist/index.js"), "--profile", str(path)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={"PATH": "/usr/bin:/bin", "HOME": self.tmp.name})
        self.addCleanup(lambda: process.poll() is None and process.kill())
        messages = [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
                     "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "silo-test", "version": "1"}}},
                    {"jsonrpc": "2.0", "method": "notifications/initialized"},
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
                    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "discourse_list_categories", "arguments": {}}},
                    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "discourse_manage_user_activation", "arguments": {}}},
                    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "discourse_list_categories", "arguments": {"max_pages": 1, "max_requests": 1, "max_results": 3}}},
                    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "discourse_list_categories", "arguments": {"max_pages": 1, "max_requests": 4, "max_results": 3}}}]
        process.stdin.write("".join(json.dumps(message) + "\n" for message in messages).encode())
        process.stdin.flush()
        replies, buffer = {}, b""
        deadline = __import__("time").monotonic() + 60
        while len(replies) < 6 and __import__("time").monotonic() < deadline:
            ready, _, _ = select.select([process.stdout], [], [], 1)
            if not ready:
                if process.poll() is not None:
                    break
                continue
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") in (1, 2, 3, 4, 5, 6):
                    replies[message["id"]] = message
        process.stdin.close()
        process.wait(timeout=10)
        stderr = process.stderr.read()
        process.stdout.close()
        process.stderr.close()
        self.assertEqual({1, 2, 3, 4, 5, 6}, set(replies), stderr.decode("utf-8", "replace")[-500:])
        self.assertEqual(b"", stderr)  # log_level silent: no site title/URL on stderr
        names = {tool["name"] for tool in replies[2]["result"]["tools"]}
        self.assertEqual(set(self.m.EXPECTED_TOOLS), names)
        self.assertIn("discourse_list_categories", names)
        self.assertFalse({"discourse_manage_user_activation", "discourse_update_site_setting", "discourse_select_site",
                          "discourse_create_post", "discourse_create_category"} & names)
        call = replies[3]["result"]
        self.assertFalse(call.get("isError"), call)
        listed = {c["slug"]: c["read_restricted"] for c in call["structuredContent"]["categories"]}
        self.assertEqual({"invented-public": False, "invented-staff": True}, listed)
        # A one-request budget is exhausted by the GET-only key refusing category
        # search POST. It is explicitly incomplete, NOT a complete empty site. A
        # budget of four can reach the GET fallback without broadening key scopes.
        limited = replies[5]["result"]["structuredContent"]
        self.assertEqual([], limited["categories"])
        self.assertEqual((False, True, 0, "page_limit"), (limited["meta"]["complete"], limited["meta"]["has_more"],
                         limited["meta"]["pages_fetched"], limited["meta"]["truncated_reason"]))
        fallback = replies[6]["result"]["structuredContent"]
        self.assertEqual(2, len(fallback["categories"]))
        self.assertEqual(1, fallback["meta"]["pages_fetched"])
        # An unregistered write tool is refused by the connector before any request.
        self.assertTrue("error" in replies[4] or replies[4]["result"].get("isError"))
        # Every request carried the scoped key for the tethered identity; the only non-GET was the
        # connector's category search POST, which a read_only key gets refused (then GET fallback).
        self.assertTrue(all(key == KEY and user == endpoint["username"] for _, _, key, user in seen), seen)
        self.assertEqual({("POST", "/categories/search.json")}, {(m, p) for m, p, _, _ in seen if m != "GET"})
        self.assertIn(("GET", "/categories.json"), {(m, p) for m, p, _, _ in seen})


RUBY_IMAGE = "ruby:3.3-bookworm"
PG_IMAGE = "postgres:16-alpine"
POLICY_RUBY = r'''
module SiloMigrate
  class StandardWorkflowError < StandardError
    attr_reader :code
    def initialize(code, detail = nil) = (@code = code; super(code))
  end
end
require "json"
require "/silo/lib/silo_migrate/services/standard_merge_inspection"
M = SiloMigrate::Services::StandardMergeInspection
o = Object.new.extend(M)
if ARGV[0] == "sql"
  puts JSON.generate("inventory" => M::SOURCE_INVENTORY_SQL, "hba_script" => M::SOURCE_HBA_SCRIPT, "hba_rules" => M::SOURCE_HBA_RULES_SQL)
else
  role, password, db = ARGV[1, 3]
  begin
    plan = o.send(:source_policy_plan, STDIN.read)
    puts JSON.generate("role_sql" => o.send(:source_role_sql, role, password, db, plan["grants"]),
                       "hba" => o.send(:source_hba_lines, role, db), "marker" => o.send(:source_hba_marker, role))
  rescue SiloMigrate::StandardWorkflowError => e
    puts JSON.generate("code" => e.code)
  end
end
'''
MALICIOUS = r'''
CREATE TABLE users (id int, username text, password_hash text);
INSERT INTO users VALUES (1, 'alice', 'HASH-CANARY');
CREATE TABLE plugin_secret_tokens (token text);
INSERT INTO plugin_secret_tokens VALUES ('TOKEN-CANARY');
GRANT SELECT ON plugin_secret_tokens TO PUBLIC;
CREATE TABLE posts (id int, raw text);
GRANT ALL ON posts TO PUBLIC;
CREATE FUNCTION leak() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$SELECT token FROM plugin_secret_tokens LIMIT 1$$;
CREATE SCHEMA extra;
CREATE TABLE extra.users (secret text);
INSERT INTO extra.users VALUES ('EXTRA-CANARY');
GRANT USAGE, CREATE ON SCHEMA extra TO PUBLIC;
GRANT SELECT ON extra.users TO PUBLIC;
DO $$DECLARE o oid; BEGIN o := lo_from_bytea(424242, 'LO-CANARY'::bytea); EXECUTE format('GRANT SELECT ON LARGE OBJECT %s TO PUBLIC', o); END$$;
'''


class SourceReadPolicyLiveTest(unittest.TestCase):
    """The generated source read-role SQL against a real PostgreSQL with a hostile restored dump:
    PUBLIC grants on an unreviewed secret table, a reviewed name that is a view, a SECURITY DEFINER
    function, a PUBLIC-writable table, a PUBLIC schema and large object, and another database.
    Both containers run without a network; invented data only."""

    def docker(self, *argv, input=None, env=None, check=True, timeout=120):
        result = subprocess.run(["docker", *argv], input=input, capture_output=True, timeout=timeout, env=env)
        if check and result.returncode:
            self.fail("docker %s failed: %s" % (argv[:2], result.stderr.decode("utf-8", "replace")[-300:]))
        return result

    def setUp(self):
        import shutil
        import secrets as random
        if not shutil.which("docker"):
            self.skipTest("docker unavailable")
        for image in (RUBY_IMAGE, PG_IMAGE):
            if subprocess.run(["docker", "image", "inspect", image], capture_output=True).returncode:
                self.skipTest(image + " is not present locally")
        self.pg = "silo-policy-test-" + random.token_hex(4)
        self.docker("run", "-d", "--rm", "--pull=never", "--network", "none", "--name", self.pg,
                    "-e", "POSTGRES_PASSWORD=" + random.token_hex(16), PG_IMAGE)
        self.addCleanup(lambda: subprocess.run(["docker", "rm", "-f", self.pg], capture_output=True))
        import time
        deadline = time.monotonic() + 60
        while self.docker("exec", self.pg, "pg_isready", "-q", "-h", "127.0.0.1", "-U", "postgres", check=False).returncode:
            if time.monotonic() > deadline:
                self.fail("postgres did not start")
            time.sleep(0.5)
        self.role, self.password = "silo_mi_" + random.token_hex(4), random.token_hex(24)

    def ruby(self, *args, input=b""):
        out = self.docker("run", "--rm", "-i", "--pull=never", "--network", "none", "--read-only", "--cap-drop", "ALL",
                          "--mount", "type=bind,src=%s,dst=/silo,readonly" % ROOT, RUBY_IMAGE, "ruby", "-e", POLICY_RUBY, *args, input=input)
        return json.loads(out.stdout)

    def admin(self, database, sql):
        return self.docker("exec", "-i", self.pg, "psql", "-X", "-q", "-At", "-U", "postgres", "-d", database, "-v", "ON_ERROR_STOP=1",
                           input=sql.encode()).stdout.decode()

    def as_role(self, sql, database="merge_source_inspect", password=None, host=True):
        argv = ["exec", "-e", "PGPASSWORD=" + (password or self.password), self.pg, "psql", "-X", "-At", "-U", self.role, "-d", database,
                "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=sqlstate", "-c", sql]
        if host:
            argv[argv.index("-U"):argv.index("-U")] = ["-h", "127.0.0.1"]
        return self.docker(*argv, check=False)

    def test_hostile_restored_source_cannot_be_read_called_or_written_beyond_reviewed_columns(self):
        sql = self.ruby("sql")
        # A reviewed name that is a view over a secret refuses the whole open.
        self.admin("postgres", "CREATE DATABASE merge_source_view;\nCREATE DATABASE merge_source_inspect;\n")
        self.admin("merge_source_view", "CREATE TABLE secret_tokens (token text);\nINSERT INTO secret_tokens VALUES ('VIEW-CANARY');\n"
                   "CREATE VIEW users AS SELECT 1 AS id, token AS username FROM secret_tokens;\n")
        refused = self.ruby("plan", self.role, self.password, "merge_source_view", input=self.admin("merge_source_view", sql["inventory"]).encode())
        self.assertEqual({"code": "STANDARD_MERGE_INSPECTION_POLICY_UNSAFE"}, refused)

        self.admin("postgres", "CREATE TABLE base_secret (s text);\nINSERT INTO base_secret VALUES ('BASE-CANARY');\nGRANT SELECT ON base_secret TO PUBLIC;\n")
        self.admin("merge_source_inspect", MALICIOUS)
        planned = self.ruby("plan", self.role, self.password, "merge_source_inspect", input=self.admin("merge_source_inspect", sql["inventory"]).encode())
        self.assertNotIn("code", planned)
        # pg_hba first (as the module does), verified, then the role in one checked transaction.
        path = self.admin("postgres", "SHOW hba_file;\n").strip()
        self.docker("exec", "-i", self.pg, "sh", "-c", sql["hba_script"], "sh", path, planned["marker"], input=planned["hba"].encode())
        rules = self.admin("postgres", sql["hba_rules"]).split()
        self.assertEqual(["0", "host|merge_source_inspect|%s|md5" % self.role, "host|all|%s|reject" % self.role, "local|all|%s|reject" % self.role], rules)
        self.admin("postgres", "SELECT pg_reload_conf();\n")
        self.admin("merge_source_inspect", planned["role_sql"])

        allowed = self.as_role("SELECT id, username FROM users")
        self.assertEqual((0, b"1|alice\n"), (allowed.returncode, allowed.stdout), allowed.stderr)
        privileges = self.as_role("SELECT has_table_privilege('public.users', 'SELECT'), "
                                  "has_any_column_privilege('public.users', 'SELECT'), "
                                  "has_column_privilege('public.users', 'id', 'SELECT'), "
                                  "has_column_privilege('public.users', 'password_hash', 'SELECT'), "
                                  "(SELECT count(*) FROM public.users)")
        self.assertEqual((0, b"f|t|t|f|1\n"), (privileges.returncode, privileges.stdout), privileges.stderr)
        denied = {
            "unreviewed column": "SELECT password_hash FROM users",
            "PUBLIC-granted secret table": "SELECT token FROM plugin_secret_tokens",
            "SECURITY DEFINER function": "SELECT leak()",
            "PUBLIC schema/table elsewhere": "SELECT secret FROM extra.users",
            "PUBLIC large object": "SELECT lo_get(424242)",
            "PUBLIC-writable table": "BEGIN READ WRITE; INSERT INTO posts VALUES (2, 'x'); COMMIT",
            "create in public": "BEGIN READ WRITE; CREATE TABLE public.t (i int); COMMIT",
            "create in PUBLIC-creatable schema": "BEGIN READ WRITE; CREATE TABLE extra.t (i int); COMMIT",
            "temporary table": "BEGIN READ WRITE; CREATE TEMP TABLE t (i int); COMMIT",
        }
        for label, statement in denied.items():
            with self.subTest(label):
                result = self.as_role(statement)
                self.assertNotEqual(0, result.returncode)
                self.assertIn(b"42501", result.stderr)  # insufficient privilege, not merely read-only
                self.assertNotIn(b"CANARY", result.stdout + result.stderr)
        for label, kwargs in {"other database (clean Base/original/postgres)": {"database": "postgres"},
                              "local socket": {"host": False}, "wrong password": {"password": "0" * 48}}.items():
            with self.subTest(label):
                result = self.as_role("SELECT s FROM base_secret", **kwargs) if label.startswith("other") else self.as_role("SELECT 1", **kwargs)
                self.assertNotEqual(0, result.returncode)
                self.assertNotIn(b"CANARY", result.stdout + result.stderr)
        # Removing the lines (fence cleanup) leaves the image's own rules intact.
        before = self.admin("postgres", "SELECT count(*) FROM pg_hba_file_rules;\n").strip()
        self.docker("exec", "-i", self.pg, "sh", "-c", sql["hba_script"], "sh", path, planned["marker"], input=b"")
        self.assertEqual(int(before) - 3, int(self.admin("postgres", "SELECT count(*) FROM pg_hba_file_rules;\n").strip()))
        self.assertEqual("0", self.admin("postgres", "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;\n").strip())


if __name__ == "__main__":
    unittest.main()
