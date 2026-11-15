"""Invented PostgreSQL validation-clone acceptance (no production/customer runtime).

Default: python3 -m unittest discover -s test -p merge_validation_postgres_live_test.py
Opt in: SILO_MERGE_VALIDATION_LIVE=1 python3 -m unittest discover -s test \
    -p merge_validation_postgres_live_test.py

Uses only cached images, no pull/build/install, ports, external network or host
services. Requires the local Linux Docker socket/binary, ../../.runtime-cache/gems,
and the cached app image matching runtime/profiles' public web pin. The native
client mounts ONLY its test script and public validation helpers, shares the exact owned PG
network-none namespace, uses fixture-only SCRAM loopback auth, and boots no Rails.
The control container's Docker socket is privileged host access, NOT a sandbox
security boundary. Its Ruby bridge permits exec only against the exact owned PG ID.
Finally removes exact IDs after verifying this invocation's labels, including
reconciliation after create/start/attach timeout. JSON cleanup evidence is printed
on stderr even on failure; missing/failed cleanup fails the test, never silently skips.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
CONTROL_IMAGE = "sha256:32ca6f94a3ffe387eb1b9d34edc4be8e9308da1c80a3dce8b7b8310d84949240"
LABEL = "silo-migrate.validation-live"
APP_REF = "silo-migrate/discourse-migration:3158c750-overlay1"
APP_PROFILE = ROOT / "runtime/profiles/discourse-2026.11.0-latest-3158c750.json"


@unittest.skipUnless(os.environ.get("SILO_MERGE_VALIDATION_LIVE") == "1",
                     "opt in with SILO_MERGE_VALIDATION_LIVE=1 (cached local images only)")
class MergeValidationPostgresLiveTest(unittest.TestCase):
    def docker(self, *args, timeout=30, check=True, input_data=None):
        result = subprocess.run(["/usr/bin/docker", "--host", "unix:///var/run/docker.sock", *args],
                                text=True, capture_output=True, timeout=timeout, input=input_data)
        if check and result.returncode:
            self.fail(f"docker {args[0]} failed ({result.returncode}); runtime output withheld")
        return result

    def image(self, reference):
        # inspect never downloads; all create calls use immutable IDs + --pull=never.
        result = self.docker("image", "inspect", "--format", "{{.Id}}", reference)
        identity = result.stdout.strip()
        self.assertRegex(identity, r"^sha256:[0-9a-f]{64}$")
        return identity

    def cached_app_image(self):
        pin = json.loads(APP_PROFILE.read_text())["images"]["web"]
        self.assertEqual(APP_REF, pin["ref"])
        document, = json.loads(self.docker("image", "inspect", APP_REF).stdout)
        # Use the production public profile identity contract, not an assumption
        # that content_id is Docker's image ID (these are distinct hashes).
        spec = importlib.util.spec_from_file_location("validation_live_review_runtime", ROOT / "bin/review_runtime.py")
        runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runtime)
        self.assertEqual(pin["content_id"], runtime.identity(document), "cached app does not match public pin")
        identity = document["Id"]
        self.assertRegex(identity, r"^sha256:[0-9a-f]{64}$")
        return identity

    def test_closed_template_validation_clones(self):
        self.assertTrue(Path("/usr/bin/docker").is_file(), "local Docker binary required")
        self.assertTrue(Path("/var/run/docker.sock").is_socket(), "local Docker socket required")
        gems = ROOT.parents[1] / ".runtime-cache/gems"
        self.assertTrue(gems.is_dir(), "cached gems required; do not install")
        pg_image = self.image("postgres:16-alpine")
        self.assertEqual(CONTROL_IMAGE, self.image(CONTROL_IMAGE))
        app_image = self.cached_app_image()
        token = uuid.uuid4().hex
        owned = {}  # Names registered BEFORE create so timeout can be reconciled.
        evidence = {"invocation": token, "images": [pg_image, CONTROL_IMAGE, app_image], "cleanup": []}

        def create(kind, image, extra, *, network_container=None, command=()):
            network = "none"
            if network_container is not None:
                self.assertEqual("pgclient", kind)
                self.assertRegex(network_container, r"^[0-9a-f]{64}$")
                self.assertEqual(owned.get(f"silo-validation-live-{token}-pg"), network_container)
                network = f"container:{network_container}"
            name = f"silo-validation-live-{token}-{kind}"
            owned[name] = None
            result = self.docker(
                "create", "--pull=never", "--name", name, "--label", f"{LABEL}={token}",
                "--network", network, "--read-only", "--cap-drop", "ALL",
                "--security-opt", "no-new-privileges", "--cpus", "1",
                "--memory", "512m", "--pids-limit", "128", "--log-driver", "none",
                "--tmpfs", f"/tmp:rw,nosuid,nodev,size={64 if kind == 'pgclient' else 128}m,mode=1777",
                *extra, image, *command)
            identity = result.stdout.strip()
            self.assertRegex(identity, r"^[0-9a-f]{64}$")
            owned[name] = identity
            return identity

        try:
            pg = create("pg", pg_image, ["--label", "silo-migrate.managed=true", "--label", "silo-migrate.instance=validation-live", "--user", "postgres", "-e", "PGDATA=/tmp/pgdata",
                                         "--tmpfs", "/var/lib/postgresql/data:rw,nosuid,nodev,size=1m,mode=1777",
                                         "--tmpfs", "/var/run/postgresql:rw,nosuid,nodev,size=4m,mode=1777",
                                         "-e", "POSTGRES_HOST_AUTH_METHOD=trust"])

            self.docker("start", pg)
            deadline = time.monotonic() + 40
            while True:
                # pg_isready can succeed against the entrypoint's temporary
                # initialization server. Admit only the final PID-1 postmaster.
                process = self.docker("exec", pg, "cat", "/proc/1/comm", check=False)
                ready = self.docker("exec", pg, "pg_isready", "-U", "postgres", check=False)
                if process.returncode == 0 and process.stdout.strip() == "postgres" and ready.returncode == 0:
                    break
                if time.monotonic() >= deadline:
                    self.fail("invented PostgreSQL fixture readiness timeout")
                time.sleep(0.25)
            control = create("ruby", CONTROL_IMAGE, [
                "--entrypoint", "ruby",
                "--mount", f"type=bind,src={ROOT},dst=/src,readonly",
                "--mount", f"type=bind,src={gems},dst=/gems,readonly",
                "--mount", "type=bind,src=/usr/bin/docker,dst=/usr/local/bin/docker,readonly",
                "--mount", "type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock",
                "-e", "GEM_HOME=/gems", "-e", "GEM_PATH=/gems",
                "-e", f"VALIDATION_LIVE_PG={pg}", "-e", f"VALIDATION_LIVE_TOKEN={token}",
            ], command=["/src/test/support/merge_validation_postgres_live.rb"])
            # Container command is set at create, not via a shell or dynamic script.
            # See create() for image-specific command selection.
            result = self.docker("start", "--attach", control, timeout=180, check=False)
            if result.returncode:
                # Show source locations only; never forward SQL/password-bearing
                # exception messages from the private bridge into test output.
                import re
                locations = re.findall(r"/src/[A-Za-z0-9_./-]+:\d+", result.stderr)
                tags = re.findall(r"^VALIDATION_SQL_BRIDGE:(create_template_source|create_template_base|metadata_or_fixture):timeout$", result.stderr, re.M)
                self.fail(f"Ruby acceptance failed; source locations: {locations[:8]}; fixed timeout phases: {tags[:2]}")
            lines = result.stdout.strip().splitlines()
            self.assertTrue(lines, "Ruby harness did not emit acceptance evidence")
            report = json.loads(lines[-1])
            self.assertEqual("passed", report["status"])
            self.assertEqual(pg, report["postgres_id"])
            self.assertTrue(report["templates_unchanged"])
            self.assertTrue(report["cleanup_confirmed"])
            self.assertTrue(report["clone_identity_window_closed"])
            self.assertTrue(report["nonpublic_function_denied"])
            self.assertTrue(report["original_privileges_unchanged"])
            evidence["acceptance"] = report

            # Separate empty client DBs: production clone acceptance above remains
            # primary and has already cleaned its own role and clones. Never open
            # or grant privileges on the original templates for client testing.
            context = {"source": f"silo_val_s_{token}", "base": f"silo_val_b_{token}",
                       "role": f"silo_val_r_{token}", "password": uuid.uuid4().hex + uuid.uuid4().hex,
                       "host": "127.0.0.1", "port": 5432}
            role = context["role"]
            statements = [f"CREATE ROLE {role} LOGIN PASSWORD '{context['password']}' "
                          "NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;"]
            for side in ("source", "base"):
                database = context[side]
                statements.extend([f"CREATE DATABASE {database} TEMPLATE template0 OWNER postgres;",
                                   f"REVOKE ALL ON DATABASE {database} FROM PUBLIC;",
                                   f"GRANT CONNECT ON DATABASE {database} TO {role};",
                                   f"REVOKE CREATE, TEMPORARY ON DATABASE {database} FROM {role};",
                                   f"ALTER ROLE {role} IN DATABASE {database} SET default_transaction_read_only=on;"])
            # Require a real password over fixture loopback. Trust auth would
            # prove user rebinding but could NOT prove password rebinding.
            statements.extend([
                "COPY (SELECT line FROM (VALUES ('local all all trust'), "
                "('host all all 127.0.0.1/32 scram-sha-256'), "
                "('host all all ::1/128 scram-sha-256')) AS h(line)) TO '/tmp/pgdata/pg_hba.conf';",
                "SELECT pg_reload_conf();",
            ])
            self.docker("exec", "-i", pg, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1",
                        "-U", "postgres", "-d", "postgres", "-At", input_data="\n".join(statements), timeout=30)
            deadline = time.monotonic() + 5
            while True:
                unauthenticated = self.docker("exec", pg, "psql", "-X", "-w", "-h", "127.0.0.1",
                                              "-U", role, "-d", context["base"], "-At", "-c", "SELECT 1;",
                                              timeout=5, check=False)
                if unauthenticated.returncode and "no password supplied" in unauthenticated.stderr:
                    break
                self.assertLess(time.monotonic(), deadline, "fixture loopback password enforcement unproven")
                time.sleep(0.05)
            evidence["native_pg_password_required"] = True
            client = create("pgclient", app_image, [
                "-i", "--entrypoint", "/bin/bash", "--workdir", "/var/www/discourse",
                "-e", "BUNDLE_FROZEN=true", "-e", "BUNDLE_AUTO_INSTALL=false",
                "-e", "BUNDLE_DISABLE_VERSION_CHECK=true",
                "--mount", f"type=bind,src={ROOT / 'runtime/prebuilt-discourse/merge_validation_config.rb'},dst=/tmp/helper/merge_validation_config.rb,readonly",
                "--mount", f"type=bind,src={ROOT / 'runtime/shared/merge_validation_diagnostic.rb'},dst=/tmp/helper/merge_validation_diagnostic.rb,readonly",
                "--mount", f"type=bind,src={ROOT / 'runtime/shared/merge_contract.rb'},dst=/tmp/helper/merge_contract.rb,readonly",
                "--mount", f"type=bind,src={ROOT / 'test/support/merge_validation_pg_client.rb'},dst=/tmp/helper/merge_validation_pg_client.rb,readonly",
            ], network_container=pg,
                command=["-c", "exec bundle exec ruby /tmp/helper/merge_validation_pg_client.rb"])
            result = self.docker("start", "--attach", "--interactive", client,
                                 input_data=json.dumps(context), timeout=150, check=False)
            # Native libpq failures may be sanitized to the same tag as policy
            # refusals. Only a report containing successful-query proof can pass.
            lines = result.stdout.strip().splitlines()
            self.assertTrue(lines, "native PG acceptance evidence missing; runtime output withheld")
            native = json.loads(lines[-1])
            evidence["native_pg"] = native
            self.assertEqual(0, result.returncode, "native PG acceptance failed; inspect fixed aggregate evidence")
            self.assertEqual("passed", native["status"])
            self.assertIs(native["native_pg_queries_proven"], True)
            self.assertGreaterEqual(native["constructor_count"], 5)
            self.assertEqual(native["successful_query_count"], native["constructor_count"] * 6)
            self.assertEqual(native["endpoint_role_rebinding_count"], native["constructor_count"] * 2)
            self.assertEqual(native["fixed_tag_refusal_count"], native["constructor_count"] * 9)
            evidence["outcome"] = "passed"
        except BaseException as error:
            evidence["outcome"] = "failed"
            evidence["error_type"] = type(error).__name__
            raise
        finally:
            failures = []
            for name, known_id in reversed(list(owned.items())):
                try:
                    inspected = self.docker("container", "inspect", name, check=False)
                    if inspected.returncode:
                        # A failed inspect is not proof of absence: require successful listing.
                        absent = self.docker("container", "ls", "-aq", "--filter", f"name=^/{name}$")
                        self.assertEqual("", absent.stdout.strip())
                        self.assertIsNone(known_id, "previously created container unexpectedly absent")
                        evidence["cleanup"].append({"name": name, "created": False, "absent": True})
                        continue
                    obj, = json.loads(inspected.stdout)
                    identity = obj["Id"]
                    self.assertRegex(identity, r"^[0-9a-f]{64}$")
                    self.assertEqual(token, obj["Config"]["Labels"].get(LABEL))
                    if known_id:
                        self.assertEqual(known_id, identity)
                    self.docker("rm", "-f", "-v", identity)
                    absent = self.docker("container", "ls", "-aq", "--no-trunc",
                                         "--filter", f"id={identity}")
                    self.assertEqual("", absent.stdout.strip())
                    evidence["cleanup"].append({"id": identity, "removed": True, "absent": True})
                except Exception as error:
                    failures.append(f"{name}: {type(error).__name__}")
            evidence["cleanup_failures"] = failures
            print("SILO_VALIDATION_LIVE_EVIDENCE:" + json.dumps(evidence, sort_keys=True), file=sys.stderr)
            if failures:
                self.fail("cleanup unconfirmed: " + "; ".join(failures))


if __name__ == "__main__":
    unittest.main()
