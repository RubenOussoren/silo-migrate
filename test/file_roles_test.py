"""Invented local fixtures only. Run: python3 -I -B test/file_roles_test.py."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("data_tools_tests", Path(__file__).with_name("data_tools_test.py"))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class FileRolesTest(unittest.TestCase):
    def setUp(self):
        old_umask = os.umask(0o077)
        self.addCleanup(os.umask, old_umask)
        self.fixture = fixtures.DataToolsTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.auto_label = False
        self.op = self.fixture.op
        self.d = self.fixture.d
        self.fixture.create()
        self.root = self.fixture.base / "arc"
        self.intake = self.fixture.intake
        self.data = self.root / ".silo-migrate/data"
        self.named = self.root / ".silo-migrate/named"
        self.standard = self.named / "standard"
        self.ws = self.d.Workspace(self.fixture.base, "arc", fixtures.ROOT, self.fixture.host, self.fixture.values, self.fixture.control)

    def listing(self, name):
        return next(item for item in self.d.drop_listing(self.ws) if item["path"] == name)

    def write(self, name, body=b"invented data"):
        (self.intake / name).write_bytes(body)
        return self.listing(name)

    def preview(self, change, **kwargs):
        return self.op("file_roles_preview", change=change, by="Engineer", **kwargs)

    def commit(self, change, **kwargs):
        preview = self.preview(change)
        return self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer", **kwargs)

    def state(self):
        return json.loads((self.data / "file-roles.json").read_text())

    def source(self, name="source.sql"):
        item = self.write(name, b"-- MySQL dump\nCREATE TABLE invented (id int);")
        result = self.commit({"action": "classify", "role": "source", "kind": "development", "files": [item]})
        return result["roles"]["active"]["development"]

    def legacy(self, taken=False, derived=False):
        """Construct the pre-role incident without going through today's validation."""
        first = json.loads((self.named / "state.json").read_text())["datasets"].keys()
        first = next(iter(first))
        second = json.loads(self.fixture.control(["named", "dataset", "add", "arc", "--source", self.ws.meta()["source_id"], "--label", "development"]))["dataset_id"]
        one, two = self.write("original.sql"), self.write("mapping.xlsx", b"PK\x03\x04invented workbook")
        records = {}
        for index, (dataset, item) in enumerate(((first, one), (second, two)), 1):
            records[dataset] = {"dataset_id": dataset, "kind": "development", "version": index, "sequence": index,
                                "labelled_at": "2026-11-01T00:00:00Z", "labelled_by": "Original engineer",
                                "files": [{key: item[key] for key in self.d.IDENTITY}]}
        input_id = None
        if taken:
            target = self.root / "inputs/mapping.xlsx"
            (self.intake / "mapping.xlsx").rename(target)
            target.chmod(0o400)
            sha = hashlib.sha256(target.read_bytes()).hexdigest()
            input_id = json.loads(self.fixture.control(["named", "input", "add", "arc", "--path", "inputs/mapping.xlsx", "--sha256", sha,
                                                        "--bytes", str(target.stat().st_size), "--type", "xlsx", "--dataset", second]))["input_id"]
            records[second]["files"][0]["taken"] = input_id
        if derived:
            directory = self.root / "inputs/derived"
            directory.mkdir(mode=0o700)
            settings = directory / "settings.json"
            settings.write_bytes(b"{}")
            settings.chmod(0o400)
            self.fixture.control(["named", "input", "add", "arc", "--path", "inputs/derived/settings.json",
                                  "--sha256", hashlib.sha256(b"{}").hexdigest(), "--bytes", "2", "--type", "converter-settings", "--dataset", second])
        self.d.write_deliveries(self.ws, records)
        roles = self.op("deliveries")["roles"]
        wrong = next(item for snap in roles["snapshots"] if snap["dataset_id"] == second for item in snap["files"])
        return first, second, wrong, input_id

    def correction(self, wrong, first, role="reference", **extra):
        return {"action": "correct", "file_ids": [wrong["id"]], "role": role, "restore_dataset_id": first,
                "reason": "Workbook was mistakenly labelled as a source", **extra}

    def test_reference_does_not_create_dataset_or_change_source_revision(self):
        dataset = self.source()
        before = self.state()
        datasets = json.loads((self.named / "state.json").read_text())["datasets"]
        item = self.write("notes.txt", b"invented mapping notes")
        result = self.commit({"action": "classify", "role": "reference", "files": [item]})
        after = self.state()
        self.assertEqual(datasets, json.loads((self.named / "state.json").read_text())["datasets"])
        self.assertEqual(before["active"], after["active"])
        self.assertEqual(before["snapshots"][dataset], after["snapshots"][dataset])
        reference = result["roles"]["references"][0]
        self.assertRegex(reference["support_id"], r"^support-[0-9a-f]{32}$")
        self.assertEqual([], self.op("deliveries")["unlabelled_files"])
        self.assertNotIn("new file arrived", json.dumps(self.op("guide")))
        self.assertEqual(b"invented mapping notes", (self.data / "supporting/files" / reference["support_id"]).read_bytes())

    def test_assets_keep_snapshot_and_delivery_version_and_are_private_storage_only(self):
        dataset = self.source()
        before = self.state()
        for name in ("assets-one.zip", "assets-two.zip"):
            item = self.write(name)
            result = self.commit({"action": "classify", "role": "uploads", "dataset_id": dataset, "files": [item]})
            self.assertTrue(result["roles"]["active"]["development"] == dataset)
        after = self.state()
        self.assertEqual(before["snapshots"][dataset]["revision"] + 2, after["snapshots"][dataset]["revision"])
        self.assertEqual(1, len(self.d.read_deliveries(self.ws)))
        self.assertEqual(1, self.d.read_deliveries(self.ws)[dataset]["version"])
        assets = [item for item in after["files"].values() if item["role"] == "uploads"]
        self.assertEqual(2, len(assets))
        for item in assets:
            path = self.data / item["asset_path"]
            self.assertEqual(b"invented data", path.read_bytes())
            self.assertEqual(0o400, path.stat().st_mode & 0o777)
        self.assertEqual([], self.op("deliveries")["unlabelled_files"])
        self.assertEqual([], self.d.delivery_mounts(self.ws, dataset))

    def test_waiting_legacy_correction_restores_source_preserving_original_records(self):
        first, second, wrong, _ = self.legacy()
        original = (self.named / "deliveries.json").read_bytes()
        self.assertEqual(second, self.state()["active"]["development"])
        self.commit(self.correction(wrong, first))
        state = self.state()
        self.assertEqual(first, state["active"]["development"])
        self.assertFalse(state["snapshots"][second]["eligible"])
        self.assertEqual("reference", state["files"][wrong["id"]]["role"])
        self.assertEqual(second, state["files"][wrong["id"]]["original_dataset_id"])
        self.assertEqual(original, (self.named / "deliveries.json").read_bytes())
        self.assertEqual("original.sql", self.op("deliveries")["labelled_files"][0]["path"])
        with self.assertRaisesRegex(self.d.Refusal, "STANDARD_DELIVERY_UNLABELLED"):
            self.op("take", path="mapping.xlsx", type="xlsx")

    def test_taken_correction_preserves_input_id_bytes_and_excludes_legacy_paths(self):
        first, second, wrong, input_id = self.legacy(taken=True)
        named = (self.named / "state.json").read_bytes()
        path = self.root / "inputs/mapping.xlsx"
        before = path.read_bytes()
        self.commit(self.correction(wrong, first))
        self.assertEqual(before, path.read_bytes())
        self.assertEqual(named, (self.named / "state.json").read_bytes())
        self.assertEqual(input_id, self.state()["files"][wrong["id"]]["input_id"])
        self.assertEqual([], self.d.delivery_mounts(self.ws, second))
        with self.assertRaisesRegex(self.d.Refusal, "INPUT_INELIGIBLE"):
            self.d.refuse_base_roles(self.ws, [input_id])
        with self.assertRaisesRegex(self.d.Refusal, "INPUT_INELIGIBLE"):
            self.d.file_roles.effective_input(self.ws, input_id, self.d.roles_api(), source=True)
        self.assertEqual(first, self.d.job_delivery(self.ws, {})[0])

    def test_correction_can_explicitly_clear_current_without_a_restore(self):
        _, second, wrong, _ = self.legacy()
        change = {"action": "correct", "file_ids": [wrong["id"]], "role": "reference", "reason": "mistake"}
        preview = self.preview(change)
        self.assertIsNone(preview["after_active"]["development"])
        self.assertIn("No source current", " ".join(preview["warnings"]))
        self.commit(change)
        self.assertIsNone(self.state()["active"]["development"])
        self.assertFalse(self.state()["snapshots"][second]["eligible"])
        with self.assertRaisesRegex(self.d.Refusal, "NO_ACTIVE_SOURCE"):
            self.d.job_delivery(self.ws, {})

    def test_clearing_base_does_not_claim_the_development_source_was_cleared(self):
        source = self.source()
        name = self.fixture.base_backup()
        result = self.commit({"action": "classify", "role": "base_site", "files": [self.listing(name)]})
        base = next(snapshot for snapshot in result["roles"]["snapshots"] if snapshot["kind"] == "base_site")
        change = {"action": "correct", "role": "reference", "file_ids": [base["files"][0]["id"]], "reason": "This is a retained baseline reference, not the selected Base."}
        preview = self.preview(change)
        self.assertEqual(source, preview["after_active"]["development"])
        self.assertIsNone(preview["after_active"]["base_site"])
        self.assertNotIn("No source current", " ".join(preview["warnings"]))
        self.assertIn("No Base backup is current", " ".join(preview["warnings"]))

    def test_stale_digest_binds_actor_revision_identity_and_dependencies(self):
        self.source()
        change = {"action": "classify", "role": "reference", "files": [self.write("notes.txt")]}
        preview = self.preview(change)
        with self.assertRaisesRegex(self.d.Refusal, "STALE_PREVIEW"):
            self.op("file_roles_commit", change=change, digest=preview["digest"], by="Another engineer")
        path = self.standard / "state.json"
        state = json.loads(path.read_text())
        state["plans"] = {"plan-55555555555555555555555555555555": {"status": "proposed", "body": {}}}
        path.write_text(json.dumps(state))
        self.assertEqual(preview["digest"], self.preview(change)["digest"])  # unrelated workflow additions do not stale a reference
        preview = self.preview(change)
        self.commit({"action": "classify", "role": "reference", "files": [self.write("other.txt")]})
        with self.assertRaisesRegex(self.d.Refusal, "STALE_PREVIEW"):
            self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
        (self.intake / "notes.txt").write_bytes(b"changed")
        with self.assertRaisesRegex(self.d.Refusal, "FILES_CHANGED"):
            self.preview(change)

    def test_impacts_include_legacy_pending_transitive_active_completed_and_release(self):
        first, second, wrong, input_id = self.legacy(taken=True)
        path = self.standard / "state.json"
        state = json.loads(path.read_text())
        state.update(plans={"plan-11111111111111111111111111111111": {"status": "approved", "body": {"roles": {"source": input_id}}},
                            "plan-22222222222222222222222222222222": {"status": "proposed", "body": {"delivery": {"dataset_id": first}}},
                            "plan-33333333333333333333333333333333": {"status": "consumed", "body": {"delivery": {"dataset_id": second}}},
                            "plan-44444444444444444444444444444444": {"status": "proposed", "body": {"from_run": "run-old"}}},
                     runs={"run-old": {"plan_id": "plan-33333333333333333333333333333333", "status": "completed", "release": {"id": "release-1"}},
                           "run-child": {"plan_id": "plan-44444444444444444444444444444444", "status": "running"}})
        path.write_text(json.dumps(state))
        change = self.correction(wrong, first)
        preview = self.preview(change)
        self.assertTrue(preview["blocked"])
        self.assertEqual("run-child", preview["impacts"]["active"][0]["run_id"])
        self.assertEqual("run-old", preview["impacts"]["completed"][0]["run_id"])
        self.assertTrue(preview["impacts"]["releases"])
        with self.assertRaisesRegex(self.d.Refusal, "ACTIVE_DEPENDENCY"):
            self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
        state["runs"]["run-child"]["status"] = "completed"
        path.write_text(json.dumps(state))
        body = path.read_bytes()
        self.commit(change)
        self.assertEqual(body, path.read_bytes())
        invalidated = self.state()["invalidated_plans"]
        self.assertIn("plan-11111111111111111111111111111111", invalidated)
        self.assertIn("plan-44444444444444444444444444444444", invalidated)
        self.assertNotIn("plan-33333333333333333333333333333333", invalidated)
        self.assertNotIn("plan-22222222222222222222222222222222", invalidated)

    def test_stale_job_requires_explicit_reconciliation_and_a_fresh_correction_preview(self):
        first, second, wrong, _ = self.legacy(taken=True)
        started = self.op("script", code="puts 1", into="analysis", delivery=second)
        job_id = started["job_id"]
        job_path = self.data / "jobs" / (job_id + ".json")
        container = json.loads(job_path.read_text())["container"]
        partial = self.root / "work/analysis/partial.txt"
        partial.write_bytes(b"invented partial output")
        originals = {path: path.read_bytes() for path in (
            self.named / "state.json", self.named / "deliveries.json", self.standard / "state.json",
            self.data / "file-roles.json", self.root / "inputs/mapping.xlsx", self.intake / "original.sql")}
        change = self.correction(wrong, first)
        blocked = self.preview(change)
        self.assertEqual([{"job_id": job_id, "status": "running"}], blocked["impacts"]["active"])
        # Polling genuinely live work does not turn it terminal or clear the guard.
        self.assertEqual("running", self.op("job", job_id=job_id, via="chat")["status"])
        self.assertTrue(self.preview(change)["blocked"])
        self.assertIn(container, self.fixture.docker.state)
        # The container has now exited, but GET/preview must not finalize jobs.
        self.fixture.docker.state[container] = {"Running": False, "Status": "exited", "ExitCode": 137,
                                                "OOMKilled": False, "FinishedAt": "2026-11-11T12:00:00Z"}
        calls = len(self.fixture.docker.calls)
        stale = self.preview(change)
        self.assertTrue(stale["blocked"])
        self.assertEqual("running", json.loads(job_path.read_text())["status"])
        self.assertEqual(calls, len(self.fixture.docker.calls))
        # This models the separately approved one-job reconciliation, not a new job.
        with mock.patch.object(self.d, "now", return_value="2026-11-12T12:00:00Z"), \
                mock.patch.object(self.d, "harden_ro_user") as harden:
            result = self.op("job", job_id=job_id, via="chat")
        harden.assert_not_called()  # script jobs do not do post-load DB hardening
        self.assertEqual(("script", "timed_out", 137, False),
                         tuple(result[key] for key in ("kind", "status", "exit_code", "oom_killed")))
        self.assertEqual("2026-11-12T12:00:00Z", result["finished_at"])  # reconciliation time, not FinishedAt
        self.assertNotIn(container, self.fixture.docker.state)
        self.assertEqual(1, len(self.fixture.docker.argvs("run")))  # no rerun
        self.assertEqual(b"invented partial output", partial.read_bytes())
        self.assertEqual(originals, {path: path.read_bytes() for path in originals})
        with self.assertRaisesRegex(self.d.Refusal, "STALE_PREVIEW"):
            self.op("file_roles_commit", change=change, digest=stale["digest"], by="Engineer")
        fresh = self.preview(change)
        self.assertEqual([], fresh["blocked"])
        self.assertEqual([], fresh["impacts"]["active"])
        self.assertNotEqual(stale["digest"], fresh["digest"])
        self.assertEqual(originals, {path: path.read_bytes() for path in originals})  # no auto-correction

    def test_activate_does_not_revise_or_invalidate_snapshot(self):
        one = self.source()
        two = self.source("next.sql")
        before = self.state()
        self.commit({"action": "activate", "dataset_id": one, "reason": "Use earlier export"})
        after = self.state()
        self.assertEqual(before["snapshots"], after["snapshots"])
        self.assertEqual(one, after["active"]["development"])
        self.assertEqual([], after["invalidated_plans"])
        self.assertNotEqual(one, two)
        self.assertEqual(one, self.d.job_delivery(self.ws, {})[0])

    def test_platform_and_legacy_take_contracts(self):
        self.ws.write_json(self.data / "workspace.json", dict(self.ws.meta(), platform="discourse"))
        for name, content in (("mapping.xlsx", b"PK\x03\x04"), (fixtures.DataToolsTest.SOURCE_BACKUP, b"not gzip"), ("random.tar.gz", b"\x1f\x8babc")):
            item = self.write(name, content)
            with self.assertRaisesRegex(self.d.Refusal, "SOURCE_INVALID"):
                self.preview({"action": "classify", "role": "source", "kind": "development", "files": [item]})
        import gzip
        item = self.write(fixtures.DataToolsTest.SOURCE_BACKUP, gzip.compress(b"invented archive"))
        self.commit({"action": "classify", "role": "source", "kind": "development", "files": [item]})
        with self.assertRaisesRegex(self.d.Refusal, "SOURCE_TYPE_INVALID"):
            self.op("take", path=item["path"], type="mysql-dump")
        self.op("take", path=item["path"], type="discourse-backup")

    def test_cross_project_paths_ids_and_chat_cannot_mutate(self):
        dataset = self.source()
        item = self.write("notes.txt")
        change = {"action": "classify", "role": "reference", "files": [item]}
        with self.assertRaisesRegex(self.d.Refusal, "OPERATION_REFUSED"):
            self.preview(change, via="chat")
        for malicious in (dict(item, path="../notes.txt"), dict(item, path="/etc/passwd"), dict(item, ino="0")):
            with self.assertRaises(self.d.Refusal):
                self.preview(dict(change, files=[malicious]))
        with self.assertRaisesRegex(self.d.Refusal, "FILES_INVALID"):
            self.preview({"action": "correct", "role": "reference", "file_ids": ["file-" + "f" * 32], "reason": "other project"})
        with self.assertRaisesRegex(self.d.Refusal, "SNAPSHOT_INVALID"):
            self.preview({"action": "activate", "dataset_id": "dataset-" + "f" * 32, "reason": "other project"})
        self.assertEqual(dataset, self.state()["active"]["development"])

    def test_registry_symlink_and_schema_corruption_fail_closed(self):
        self.source()
        path = self.data / "file-roles.json"
        original = path.read_bytes()
        path.unlink()
        outside = self.root / "outside.json"
        outside.write_bytes(original)
        path.symlink_to(outside)
        with self.assertRaisesRegex(self.d.Refusal, "STANDARD_PATH_INVALID"):
            self.op("deliveries")
        path.unlink()
        value = json.loads(original)
        value["snapshots"][next(iter(value["snapshots"]))]["revision"] = True
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(self.d.Refusal, "FILE_ROLES_INVALID"):
            self.op("deliveries")

    def test_preview_holds_operation_state_and_workspace_locks(self):
        self.source()
        item = self.write("notes.txt")
        change = {"action": "classify", "role": "reference", "files": [item]}
        for path in (self.standard / "state.lock", self.data / "lock"):
            with self.d.Locked(path):
                with self.assertRaisesRegex(self.d.Refusal, "STANDARD_BUSY"):
                    self.preview(change)

    def test_unrelated_running_work_allows_references_corrections_activation_and_new_source(self):
        one = self.source()
        two = self.source("second.sql")
        path = self.standard / "state.json"
        state = json.loads(path.read_text())
        plan = "plan-" + "7" * 32
        state.update(plans={plan: {"status": "consumed", "body": {"dataset_id": one}}},
                     runs={"run-" + "8" * 32: {"plan_id": plan, "status": "running", "stage": "convert"}})
        path.write_text(json.dumps(state))
        change = {"action": "classify", "role": "reference", "files": [self.write("unrelated.txt")]}
        preview = self.preview(change)
        state["runs"]["run-" + "8" * 32]["stage"] = "export"
        path.write_text(json.dumps(state))
        with self.d.Locked(self.standard / "op.lock"):
            self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
            self.commit({"action": "activate", "dataset_id": one, "reason": "Use earlier unchanged source"})
            self.source("third.sql")
            file = next(item for item in self.state()["files"].values() if item.get("dataset_id") == two)
            self.commit({"action": "correct", "file_ids": [file["id"]], "role": "reference", "reason": "Not a source"})
        self.assertNotIn(plan, self.state()["invalidated_plans"])

    def test_relevant_dependency_added_after_preview_is_stale(self):
        first, second, wrong, input_id = self.legacy(taken=True)
        change = self.correction(wrong, first)
        preview = self.preview(change)
        path = self.standard / "state.json"
        state = json.loads(path.read_text())
        state["plans"] = {"plan-" + "6" * 32: {"status": "approved", "body": {"source": input_id}}}
        path.write_text(json.dumps(state))
        with self.assertRaisesRegex(self.d.Refusal, "STALE_PREVIEW"):
            self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")

    def test_workbook_bytes_under_sql_name_are_not_a_source_but_export_zip_is(self):
        import io
        import zipfile
        workbook = io.BytesIO()
        with zipfile.ZipFile(workbook, "w") as archive:
            archive.writestr("xl/workbook.xml", "<invented/>")
        item = self.write("renamed.sql", workbook.getvalue())
        with self.assertRaisesRegex(self.d.Refusal, "SOURCE_PLATFORM_INVALID"):
            self.preview({"action": "classify", "role": "source", "kind": "development", "files": [item]})
        export = io.BytesIO()
        with zipfile.ZipFile(export, "w") as archive:
            archive.writestr("database.sql", "-- invented SQL export")
        item = self.write("export.zip", export.getvalue())
        self.commit({"action": "classify", "role": "source", "kind": "development", "files": [item]})

    def test_native_chat_reference_inventory_and_soft_unassignment_use_same_custody(self):
        uploads = self.root / "native-uploads"
        uploads.mkdir(mode=0o700)
        ref = "a" * 32
        original = uploads / ref
        original.write_bytes(b"invented chat notes")
        context = {"via": "chat", "_private_session": True, "_session_id": "chat-1",
                   "_uploads": [{"id": ref, "path": str(original), "filename": "chat-notes.txt", "media_type": "text/plain", "size_bytes": original.stat().st_size}]}
        with mock.patch.dict(os.environ, {"SILO_TESTING": "1", "SILO_SUPPORT_UPLOADS_ROOT": str(uploads)}):
            registered = self.op("supporting_take", ref=ref, **context)["file"]
            reference = self.op("deliveries")["roles"]["references"][0]
            self.assertEqual(registered["id"], reference["support_id"])
            self.assertIsNone(reference["identity"])
            self.assertEqual("supporting", reference["origin"])
            with self.assertRaisesRegex(self.d.Refusal, "REINTAKE_REQUIRED"):
                self.preview({"action": "correct", "file_ids": [reference["id"]], "role": "uploads", "reason": "promotion"})
            blob = self.data / "supporting/files" / registered["id"]
            original_blob = blob.read_bytes()
            self.commit({"action": "correct", "file_ids": [reference["id"]], "role": "unassigned", "reason": "Not relevant"})
            self.assertEqual([], self.op("supporting_list", **context)["files"])
            with self.assertRaisesRegex(self.d.Refusal, "STANDARD_SUPPORTING_INACTIVE"):
                self.op("supporting_read", id=registered["id"], **context)
            with self.assertRaisesRegex(self.d.Refusal, "STANDARD_SUPPORTING_INACTIVE"):
                self.op("supporting_take", ref=ref, **context)
            with self.assertRaisesRegex(self.d.Refusal, "PRIVATE_SESSION_REQUIRED"):
                self.op("supporting_list", via="chat")
            self.assertEqual(original_blob, blob.read_bytes())
            self.commit({"action": "correct", "file_ids": [reference["id"]], "role": "reference", "reason": "Restore archived reference"})
            self.assertEqual(registered["id"], self.op("supporting_list", **context)["files"][0]["id"])
            self.assertEqual(registered["id"], self.op("supporting_take", ref=ref, **context)["file"]["id"])

    def test_private_mode_hardlink_and_invalid_json_registry_rejected(self):
        self.source()
        path = self.data / "file-roles.json"
        original = path.read_bytes()
        path.chmod(0o644)
        with self.assertRaisesRegex(self.d.Refusal, "FILE_ROLES_INVALID"):
            self.op("deliveries")
        path.chmod(0o600)
        os.link(path, self.root / "hardlink")
        with self.assertRaisesRegex(self.d.Refusal, "FILE_ROLES_INVALID"):
            self.op("deliveries")
        (self.root / "hardlink").unlink()
        path.write_text("{broken")
        with self.assertRaisesRegex(self.d.Refusal, "FILE_ROLES_INVALID"):
            self.op("deliveries")
        path.write_bytes(original)
        self.data.chmod(0o755)
        with self.assertRaisesRegex(self.d.Refusal, "FILE_ROLES_INVALID"):
            self.op("deliveries")

    def test_base_classification_preserves_auto_take_and_original_backup(self):
        self.fixture.base_backup()
        item = next(item for item in self.d.drop_listing(self.ws) if item["path"].endswith(".sql.gz"))
        body = (self.intake / item["path"]).read_bytes()
        result = self.commit({"action": "classify", "role": "base_site", "files": [item]})
        dataset = result["roles"]["active"]["base_site"]
        registered = next(item for item in self.state()["files"].values() if item.get("dataset_id") == dataset)
        self.assertTrue(registered["input_id"])
        named = self.ws.named_state()["inputs"][registered["input_id"]]
        self.assertEqual(body, (self.root / base64.b64decode(named["path"]).decode()).read_bytes())

    def test_original_manifests_remain_immutable_after_inventory_revision(self):
        dataset = self.source()
        inventory = self.data / "file-role-inventories" / (dataset + "-r1.json")
        original = inventory.read_bytes()
        self.commit({"action": "classify", "role": "uploads", "dataset_id": dataset, "files": [self.write("assets.zip")]})
        self.assertEqual(original, inventory.read_bytes())
        self.assertTrue((inventory.parent / (dataset + "-r2.json")).is_file())

    def test_legacy_derived_settings_do_not_keep_corrected_snapshot_eligible(self):
        first, second, wrong, _ = self.legacy(taken=True, derived=True)
        state = self.state()
        prepared = [item for item in state["files"].values() if item.get("derived")]
        self.assertEqual(1, len(prepared))
        self.assertIsNone(prepared[0]["identity"])
        named_before = (self.named / "state.json").read_bytes()
        self.commit(self.correction(wrong, first))
        state = self.state()
        self.assertFalse(state["snapshots"][second]["eligible"])
        self.assertEqual(first, state["active"]["development"])
        self.assertEqual(named_before, (self.named / "state.json").read_bytes())
        self.assertIn(prepared[0]["id"], state["files"])
        self.assertIn("/in/derived/settings.json", [target for _, target in self.d.delivery_mounts(self.ws, second)])
        with self.assertRaisesRegex(self.d.Refusal, "INPUT_INELIGIBLE"):
            self.d.file_roles.effective_input(self.ws, prepared[0]["input_id"], self.d.roles_api())

    def test_reference_custody_retry_after_registry_write_failure_is_idempotent(self):
        self.source()
        change = {"action": "classify", "role": "reference", "files": [self.write("retry.txt")]}
        preview = self.preview(change)
        original = self.d.Workspace.write_json
        def interrupted(workspace, path, document):
            if path.name == "file-roles.json":
                raise OSError("synthetic interrupted atomic write")
            return original(workspace, path, document)
        with mock.patch.object(self.d.Workspace, "write_json", interrupted):
            with self.assertRaisesRegex(self.d.Refusal, "STANDARD_OPERATION_FAILED"):
                self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
        self.assertEqual(1, len(list((self.data / "supporting/index").glob("*.json"))))
        self.commit(change)
        self.assertEqual(1, len(list((self.data / "supporting/index").glob("*.json"))))
        self.assertEqual(1, len(self.op("deliveries")["roles"]["references"]))

    def test_intake_reference_unassignment_allows_explicit_reclassification_with_same_file_id(self):
        item = self.write("export.sql", b"-- MySQL dump invented")
        result = self.commit({"action": "classify", "role": "reference", "files": [item]})
        reference = result["roles"]["references"][0]
        self.commit({"action": "correct", "file_ids": [reference["id"]], "role": "unassigned", "reason": "This was the source export"})
        deliveries = self.op("deliveries")
        self.assertEqual(reference["id"], deliveries["roles"]["unassigned"][0]["id"])
        self.assertEqual("export.sql", deliveries["unlabelled_files"][0]["path"])
        result = self.commit({"action": "classify", "role": "source", "kind": "development", "files": [item]})
        state = self.state()
        self.assertEqual(1, len(state["files"]))
        self.assertEqual("source", state["files"][reference["id"]]["role"])
        self.assertEqual(3, len(state["history"]))
        self.assertEqual("unassigned", state["history"][-1]["before"][0]["role"])
        self.assertTrue(result["roles"]["active"]["development"])
        self.assertFalse(self.d.file_roles.reference_active(self.ws, reference["support_id"], self.d.roles_api()))

    def test_large_engineer_inventory_and_commit_are_not_chat_truncated(self):
        import io
        dataset = self.ws.meta()["dataset_id"]
        entries = []
        for index in range(200):
            item = self.write("invented-source-%03d-" % index + "a" * 120 + ".sql")
            entries.append({key: item[key] for key in self.d.IDENTITY})
        self.d.write_deliveries(self.ws, {dataset: {"dataset_id": dataset, "kind": "development", "version": 1, "sequence": 1,
                                                 "labelled_at": "invented", "labelled_by": "Engineer", "files": entries}})
        def root_call(op, **kwargs):
            return self.d.main(["data", "arc"], self.fixture.values, self.fixture.base, fixtures.ROOT, self.fixture.host,
                               io.StringIO(json.dumps(dict(op=op, **kwargs))), self.fixture.control)
        result = root_call("deliveries")
        self.assertGreater(len(json.dumps(result).encode()), self.d.OUTPUT_LIMIT)
        self.assertLess(len(json.dumps(result).encode()), self.d.ENGINEER_OUTPUT_LIMIT)
        self.assertEqual(200, len(result["roles"]["snapshots"][0]["files"]))
        change = {"action": "classify", "role": "reference", "files": [self.write("large-inventory-notes.txt")]}
        preview = root_call("file_roles_preview", change=change, by="Engineer")
        committed = root_call("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
        self.assertEqual("ok", committed["status"])
        self.assertGreater(len(json.dumps(committed).encode()), self.d.OUTPUT_LIMIT)
        with self.assertRaisesRegex(self.d.Refusal, "STANDARD_DATA_OPERATION_REFUSED"):
            root_call("deliveries", via="chat")
        with self.assertRaisesRegex(self.d.Refusal, "STANDARD_DATA_OPERATION_REFUSED"):
            root_call("file_roles_preview", change=change, by="Engineer", via="chat")
        change = {"action": "classify", "role": "reference", "files": [self.write("second-large-inventory-notes.txt")]}
        preview = root_call("file_roles_preview", change=change, by="Engineer")
        with mock.patch.object(self.d, "ENGINEER_OUTPUT_LIMIT", 1024):
            committed = root_call("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
        self.assertEqual("ok", committed["status"])
        self.assertTrue(committed["roles_omitted"])
        self.assertNotIn("roles", committed)

    def test_acceptance_uses_restored_active_source_not_newest_delivery(self):
        one = self.source()
        self.source("second.sql")
        self.ws.write_json(self.d.site_reviews_file(self.ws), {"reviews": [{"id": "review-invented", "run_id": "run-" + "1" * 32,
                            "verdict": "accepted", "basis": "customer", "process": {"delivery": {"dataset_id": one, "kind": "development", "version": 1}}}]})
        self.assertTrue(self.d.site_summary(self.ws)["changed"])
        self.commit({"action": "activate", "dataset_id": one, "reason": "Restore accepted source"})
        self.assertEqual([], self.d.site_summary(self.ws)["changed"])
        original = next(item for item in self.state()["files"].values() if item.get("dataset_id") == one)
        self.commit({"action": "correct", "file_ids": [original["id"]], "role": "reference", "reason": "No valid source selected"})
        self.assertIn("no current source", " ".join(self.d.site_summary(self.ws)["changed"]))

    def test_guide_current_stages_inputs_and_database_do_not_reuse_other_snapshot_runs(self):
        one = self.source()
        self.op("take", path="source.sql", type="mysql-dump")
        self.ws.write_json(self.ws.data_dir("db") / "state.json", {"loads": [{"dataset_id": one}]})
        runs = [{"run_id": "run-" + "1" * 32, "plan_id": "plan-" + "1" * 32, "kind": "convert", "dataset_id": one,
                 "status": "completed", "checks": 1, "matched": 1},
                {"run_id": "run-" + "2" * 32, "plan_id": "plan-" + "2" * 32, "kind": "review", "dataset_id": one,
                 "status": "completed", "checks": 1, "matched": 1}]
        self.fixture.guide_state(runs=runs)
        self.assertEqual("site", self.op("guide")["stage"])
        two = self.source("second.sql")
        self.op("take", path="second.sql", type="mysql-dump")
        guide = self.op("guide")
        self.assertEqual("source_db", guide["stage"])
        self.assertIn("data_db_load", guide["next"]["action"])
        self.assertEqual(2, len(guide["runs"]))  # history is not filtered away
        self.assertEqual({one}, {run["dataset_id"] for run in guide["runs"]})
        self.assertNotEqual(one, two)
        runs[0]["status"] = "running"
        self.fixture.guide_state(runs=runs)
        guide = self.op("guide")
        self.assertEqual("source_db", guide["stage"])
        self.assertTrue(guide["happening"])
        self.assertEqual("nobody", guide["next"]["who"])  # global active notice retained

    def test_legacy_unbound_review_guide_inherits_convert_snapshot_binding(self):
        dataset = self.source()
        plan, child = "plan-" + "1" * 32, "plan-" + "2" * 32
        run, review = "run-" + "1" * 32, "run-" + "2" * 32
        state = json.loads((self.standard / "state.json").read_text())
        state.update(plans={plan: {"body": {"operation": "standard_convert", "dataset_id": dataset}},
                            child: {"body": {"operation": "standard_review", "from_run": {"run_id": run}}}},
                     runs={run: {"plan_id": plan}, review: {"plan_id": child}})
        (self.standard / "state.json").write_text(json.dumps(state))
        self.fixture.control.status = {"runs": [{"run_id": review, "plan_id": child, "status": "completed"}]}
        self.assertEqual(dataset, self.d.guide_records(self.ws)["runs"][0]["dataset_id"])

    def test_active_database_load_new_and_legacy_metadata_blocks_affected_correction(self):
        dataset = self.source()
        input_id = self.op("take", path="source.sql", type="mysql-dump")["input_id"]
        original = next(item for item in self.state()["files"].values() if item.get("input_id") == input_id)
        self.op("db_up", engine="mariadb")
        job = self.op("db_load", path="inputs/source.sql")
        path = self.data / "jobs" / (job["job_id"] + ".json")
        metadata = json.loads(path.read_text())
        self.assertEqual(dataset, metadata["dataset_id"])
        self.assertEqual(input_id, metadata["input_id"])
        change = {"action": "correct", "file_ids": [original["id"]], "role": "reference", "reason": "Wrong source"}
        self.assertTrue(self.preview(change)["blocked"])
        metadata.pop("dataset_id")
        metadata.pop("input_id")
        path.write_text(json.dumps(metadata))
        self.assertEqual(job["job_id"], self.preview(change)["impacts"]["active"][0]["job_id"])
        unrelated = {"action": "classify", "role": "reference", "files": [self.write("unrelated-load-notes.txt")]}
        self.assertFalse(self.preview(unrelated)["blocked"])

    def test_assets_become_references_from_immutable_custody_not_changed_intake(self):
        dataset = self.source()
        item = self.write("asset-mapping.xlsx", b"PK-invented-workbook")
        self.commit({"action": "classify", "role": "uploads", "dataset_id": dataset, "files": [item]})
        asset = next(file for file in self.state()["files"].values() if file["role"] == "uploads")
        (self.intake / item["path"]).write_bytes(b"replacement must never be copied")
        self.commit({"action": "correct", "file_ids": [asset["id"]], "role": "reference", "reason": "Workbook is a supporting reference"})
        corrected = self.state()["files"][asset["id"]]
        self.assertEqual(b"PK-invented-workbook", (self.data / "supporting/files" / corrected["support_id"]).read_bytes())
        self.assertEqual(b"replacement must never be copied", (self.intake / item["path"]).read_bytes())

    def test_new_discourse_source_does_not_inherit_prior_completed_merge_stage(self):
        import gzip
        self.ws.write_json(self.data / "workspace.json", dict(self.ws.meta(), platform="discourse"))
        original_name = "first-" + self.fixture.SOURCE_BACKUP
        item = self.write(original_name, gzip.compress(b"invented first source"))
        one = self.commit({"action": "classify", "role": "source", "kind": "development", "files": [item]})["roles"]["active"]["development"]
        self.op("take", path=original_name, type="discourse-backup")
        self.fixture.base_backup()
        self.fixture.label("base_site")
        self.fixture.guide_state(runs=[{"run_id": "run-" + "1" * 32, "plan_id": "plan-" + "1" * 32, "kind": "merge",
                                       "status": "completed", "dataset_id": one}])
        self.assertEqual("release", self.op("guide")["stage"])
        second_name = "second-" + self.fixture.SOURCE_BACKUP
        item = self.write(second_name, gzip.compress(b"invented second source"))
        self.commit({"action": "classify", "role": "source", "kind": "development", "files": [item]})
        self.op("take", path=second_name, type="discourse-backup")
        guide = self.op("guide")
        self.assertEqual("merge", guide["stage"])
        self.assertIn("data_merge_propose", guide["next"]["action"])
        self.assertEqual("current", next(stage["state"] for stage in guide["stages"] if stage["id"] == "merge"))
        self.assertEqual(1, len(guide["runs"]))

    def test_interrupted_source_label_is_inactive_visible_and_explicitly_activatable(self):
        old = self.source()
        before = (self.data / "file-roles.json").read_bytes()
        item = self.write("interrupted.sql", b"-- MySQL dump invented second source")
        change = {"action": "classify", "role": "source", "kind": "development", "files": [item]}
        preview = self.preview(change)
        original = self.d.Workspace.write_json
        def interrupted(workspace, path, document):
            if path.name == "file-roles.json":
                raise OSError("synthetic final registry interruption")
            return original(workspace, path, document)
        with mock.patch.object(self.d.Workspace, "write_json", interrupted):
            with self.assertRaisesRegex(self.d.Refusal, "STANDARD_OPERATION_FAILED"):
                self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
        new = next(dataset for dataset in self.d.read_deliveries(self.ws) if dataset != old)
        raw = (self.named / "deliveries.json").read_bytes()
        named = (self.named / "state.json").read_bytes()
        inventory = self.data / "file-role-inventories" / (new + "-r1.json")
        original_inventory = inventory.read_bytes()
        shown = self.op("deliveries")["roles"]
        recovered = next(snapshot for snapshot in shown["snapshots"] if snapshot["dataset_id"] == new)
        self.assertTrue(recovered["recovered"])
        self.assertTrue(recovered["eligible"])
        self.assertEqual(preview["files"][0]["id"], recovered["files"][0]["id"])
        self.assertEqual(old, shown["active"]["development"])
        self.assertEqual(before, (self.data / "file-roles.json").read_bytes())  # GET did not publish recovery
        result = self.commit({"action": "activate", "dataset_id": new, "reason": "Recover the reviewed interrupted classification"})
        self.assertEqual(new, result["roles"]["active"]["development"])
        self.assertFalse(self.state().get("incomplete_deliveries", {}).get(new))
        self.assertEqual(raw, (self.named / "deliveries.json").read_bytes())
        self.assertEqual(named, (self.named / "state.json").read_bytes())
        self.assertEqual(original_inventory, inventory.read_bytes())
        self.assertEqual(2, len(self.d.read_deliveries(self.ws)))

    def test_interrupted_base_label_recovers_by_explicit_selection_then_existing_take(self):
        first_name = self.fixture.base_backup()
        initial = self.commit({"action": "classify", "role": "base_site", "files": [self.listing(first_name)]})
        old = initial["roles"]["active"]["base_site"]
        second_name = self.fixture.base_backup("20261111123456")
        change = {"action": "classify", "role": "base_site", "files": [self.listing(second_name)]}
        preview = self.preview(change)
        original = self.d.Workspace.write_json
        def interrupted(workspace, path, document):
            if path.name == "file-roles.json":
                raise OSError("synthetic Base registry interruption")
            return original(workspace, path, document)
        with mock.patch.object(self.d.Workspace, "write_json", interrupted):
            with self.assertRaisesRegex(self.d.Refusal, "STANDARD_OPERATION_FAILED"):
                self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
        before = (self.data / "file-roles.json").read_bytes()
        new = next(dataset for dataset in self.d.read_deliveries(self.ws) if dataset != old)
        raw = (self.named / "deliveries.json").read_bytes()
        shown = self.op("deliveries")["roles"]
        self.assertEqual(old, shown["active"]["base_site"])
        self.assertTrue(next(snapshot for snapshot in shown["snapshots"] if snapshot["dataset_id"] == new)["incomplete"])
        self.assertEqual(before, (self.data / "file-roles.json").read_bytes())
        selected = self.commit({"action": "activate", "dataset_id": new, "reason": "Recover reviewed Base selection"})
        self.assertEqual(new, selected["roles"]["active"]["base_site"])
        self.assertIn("not registered", " ".join(selected["warnings"]))
        self.assertTrue((self.intake / second_name).exists())  # selection did not silently resume take
        self.assertEqual(raw, (self.named / "deliveries.json").read_bytes())
        registered = self.op("take", path=second_name, type="base_site")
        self.assertTrue(registered["input_id"])
        self.assertEqual(2, len(self.d.read_deliveries(self.ws)))
        restored = self.commit({"action": "activate", "dataset_id": old, "reason": "Select earlier registered SQL-only Base"})
        self.assertEqual(old, restored["roles"]["active"]["base_site"])
        self.assertEqual(self.d.review_base_site(self.ws, {}), next(item["input_id"] for item in self.state()["files"].values() if item.get("dataset_id") == old))

    def test_native_reference_without_roles_preserves_legacy_parent_permissions(self):
        parent = self.root / ".silo-migrate"
        self.assertFalse((self.data / "file-roles.json").exists())
        parent.chmod(0o755)
        self.assertTrue(self.d.file_roles.reference_active(self.ws, "support-" + "a" * 32, self.d.roles_api()))
        parent.chmod(0o700)
        self.source()
        parent.chmod(0o755)
        with self.assertRaisesRegex(self.d.Refusal, "FILE_ROLES_INVALID"):
            self.d.file_roles.reference_active(self.ws, "support-" + "a" * 32, self.d.roles_api())

    def test_existing_null_registry_fails_closed_without_bootstrap_or_disk_mutation(self):
        first, _, wrong, input_id = self.legacy(taken=True)
        standard_path = self.standard / "state.json"
        standard = json.loads(standard_path.read_text())
        standard["plans"] = {"plan-" + "a" * 32: {"status": "approved", "body": {"source": input_id}}}
        standard_path.write_text(json.dumps(standard))
        self.commit(self.correction(wrong, first))
        valid = self.state()
        self.assertTrue(valid["history"])
        self.assertTrue(valid["invalidated_plans"])
        path = self.data / "file-roles.json"
        path.write_bytes(b"null\n")
        before = {file: file.read_bytes() for file in (self.data / "file-role-inventories").glob("*.json")}
        before.update({path: path.read_bytes(), self.named / "state.json": (self.named / "state.json").read_bytes(),
                       self.named / "deliveries.json": (self.named / "deliveries.json").read_bytes(), standard_path: standard_path.read_bytes()})
        for call in (lambda: self.d.file_roles.load(self.ws, self.d.roles_api(), persist=True),
                     lambda: self.d.file_roles.reference_active(self.ws, valid["files"][wrong["id"]]["support_id"], self.d.roles_api()),
                     lambda: self.op("deliveries")):
            with self.assertRaisesRegex(self.d.Refusal, "^STANDARD_FILE_ROLES_INVALID$"):
                call()
            self.assertEqual(before, {file: file.read_bytes() for file in before})
        self.assertEqual(set(before) - {path, self.named / "state.json", self.named / "deliveries.json", standard_path},
                         set((self.data / "file-role-inventories").glob("*.json")))

    def test_jobs_reach_fixed_point_and_keep_unrelated_chains_out_of_impacts(self):
        first, _, wrong, input_id = self.legacy(taken=True)
        jobs = self.ws.data_dir("jobs")
        upstream, child = "job-" + "a" * 12, "job-" + "b" * 12
        unrelated, other_child = "job-" + "c" * 12, "job-" + "d" * 12
        for job in ({"id": upstream, "status": "completed", "input_id": input_id, "started_at": "2"},
                    {"job_id": child, "status": "running", "from_job": upstream, "started_at": "1"},
                    {"id": unrelated, "status": "completed", "input_id": "input-" + "f" * 32},
                    {"id": other_child, "status": "running", "from_job": unrelated}):
            self.ws.write_json(jobs / ((job.get("id") or job["job_id"]) + ".json"), job)
        preview = self.preview(self.correction(wrong, first))
        self.assertTrue(preview["blocked"])
        self.assertEqual([child], [item["job_id"] for item in preview["impacts"]["active"]])
        plan, run = "plan-" + "e" * 32, "run-" + "e" * 32
        path = self.standard / "state.json"
        state = json.loads(path.read_text())
        state.update(plans={plan: {"status": "consumed", "body": {"source_job": upstream}}},
                     runs={run: {"plan_id": plan, "status": "claimed"}})
        path.write_text(json.dumps(state))
        preview = self.preview(self.correction(wrong, first))
        self.assertIn(run, [item.get("run_id") for item in preview["impacts"]["active"]])
        self.assertNotIn(other_child, [item.get("job_id") for item in preview["impacts"]["active"]])

    def test_new_downstream_job_after_preview_is_stale_even_without_direct_input_ids(self):
        first, _, wrong, input_id = self.legacy(taken=True)
        upstream, child = "job-" + "a" * 12, "job-" + "b" * 12
        jobs = self.ws.data_dir("jobs")
        self.ws.write_json(jobs / (upstream + ".json"), {"id": upstream, "status": "completed", "input_id": input_id})
        change = self.correction(wrong, first)
        preview = self.preview(change)
        self.assertFalse(preview["blocked"])
        self.ws.write_json(jobs / (child + ".json"), {"id": child, "status": "running", "from_job": upstream})
        with self.assertRaisesRegex(self.d.Refusal, "STALE_PREVIEW"):
            self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")

    def interrupted_inventory_fixture(self):
        target = self.source("target.sql")
        items = [self.write("part-one.sql", b"-- MySQL dump invented first part"),
                 self.write("part-two.sql", b"-- MySQL dump invented second part")]
        source = self.commit({"action": "classify", "role": "source", "kind": "development", "files": items})["roles"]["active"]["development"]
        files = {item["path"]: item for item in self.state()["files"].values() if item.get("dataset_id") == source}
        change = {"action": "correct", "file_ids": [files["part-one.sql"]["id"]], "role": "uploads", "dataset_id": target,
                  "reason": "The first part is an asset for the earlier source"}
        preview = self.preview(change)
        before = (self.data / "file-roles.json").read_bytes()
        named = (self.named / "state.json").read_bytes()
        deliveries = (self.named / "deliveries.json").read_bytes()
        original = self.d.Workspace.write_json
        def interrupted(workspace, path, document):
            if path.name == target + "-r2.json":
                raise OSError("synthetic second-inventory publication failure")
            return original(workspace, path, document)
        with mock.patch.object(self.d.Workspace, "write_json", interrupted):
            with self.assertRaisesRegex(self.d.Refusal, "STANDARD_OPERATION_FAILED"):
                self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
        inventory = self.data / "file-role-inventories" / (source + "-r2.json")
        self.assertTrue(inventory.is_file())
        self.assertFalse((inventory.parent / (target + "-r2.json")).exists())
        self.assertEqual(before, (self.data / "file-roles.json").read_bytes())
        shown = self.op("deliveries")["roles"]
        source_view = next(snapshot for snapshot in shown["snapshots"] if snapshot["dataset_id"] == source)
        self.assertEqual(1, source_view["revision"])
        self.assertTrue(all(item["role"] == "source" for item in source_view["files"]))
        self.assertEqual(before, (self.data / "file-roles.json").read_bytes())  # no read-time replay
        return source, target, files, change, preview, inventory, named, deliveries

    def test_exact_retry_reuses_prepared_inventory_after_partial_publication(self):
        source, target, _, change, preview, inventory, named, deliveries = self.interrupted_inventory_fixture()
        prepared = inventory.read_bytes()
        committed = (inventory.parent / (source + "-r1.json")).read_bytes()
        result = self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
        self.assertEqual("ok", result["status"])
        self.assertEqual(2, self.state()["snapshots"][source]["revision"])
        self.assertEqual(2, self.state()["snapshots"][target]["revision"])
        self.assertEqual(prepared, inventory.read_bytes())
        self.assertEqual(committed, (inventory.parent / (source + "-r1.json")).read_bytes())
        self.assertEqual(named, (self.named / "state.json").read_bytes())
        self.assertEqual(deliveries, (self.named / "deliveries.json").read_bytes())

    def test_different_intent_uses_higher_revision_without_overwriting_any_inventory(self):
        source, target, files, _, _, inventory, named, deliveries = self.interrupted_inventory_fixture()
        preserved = {file: file.read_bytes() for file in inventory.parent.glob("*.json")}
        self.commit({"action": "correct", "file_ids": [files["part-two.sql"]["id"]], "role": "reference", "reason": "Only the second part is a reference"})
        state = self.state()
        self.assertEqual(3, state["snapshots"][source]["revision"])
        self.assertEqual(1, state["snapshots"][target]["revision"])
        self.assertEqual("source", state["files"][files["part-one.sql"]["id"]]["role"])
        self.assertEqual("reference", state["files"][files["part-two.sql"]["id"]]["role"])
        self.assertEqual(preserved, {file: file.read_bytes() for file in preserved})
        self.assertTrue((inventory.parent / (source + "-r3.json")).is_file())
        self.assertEqual(named, (self.named / "state.json").read_bytes())
        self.assertEqual(deliveries, (self.named / "deliveries.json").read_bytes())
        self.assertEqual(2, len(self.d.read_deliveries(self.ws)))

    def test_preflight_rejects_committed_conflict_before_publishing_other_inventory(self):
        import copy
        first = self.source()
        second = self.source("second.sql")
        state = copy.deepcopy(self.state())
        state["snapshots"][second]["revision"] += 1
        for item in state["files"].values():
            if item.get("dataset_id") == first:
                item["bytes"] += 1
                item["identity"]["bytes"] += 1
        before = {file: file.read_bytes() for file in (self.data / "file-role-inventories").glob("*.json")}
        with self.d.file_roles.locks(self.ws, self.d.roles_api()):
            with self.assertRaisesRegex(self.d.Refusal, "INVENTORY_CONFLICT"):
                self.d.file_roles.save(self.ws, state, self.d.roles_api())
        self.assertEqual(set(before), set((self.data / "file-role-inventories").glob("*.json")))
        self.assertEqual(before, {file: file.read_bytes() for file in before})

    def test_failed_engineer_copy_never_becomes_native_alias_between_failure_and_retry(self):
        first, _, wrong, _ = self.legacy(taken=True)
        change = self.correction(wrong, first)
        preview = self.preview(change)
        original = self.d.Workspace.write_json
        def interrupted(workspace, path, document):
            if path.name == "file-roles.json":
                raise OSError("synthetic registry write failure after reference admission")
            return original(workspace, path, document)
        with mock.patch.object(self.d.Workspace, "write_json", interrupted):
            with self.assertRaisesRegex(self.d.Refusal, "STANDARD_OPERATION_FAILED"):
                self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
        with self.ws.lock():
            custody = self.d.supporting_module().engineer_list(self.ws, self.d.supporting_api())
        support_id = custody[0]["id"]
        self.assertFalse(self.d.file_roles.reference_active(self.ws, support_id, self.d.roles_api()))
        self.assertEqual([], self.op("deliveries")["roles"]["references"])
        self.commit({"action": "classify", "role": "reference", "files": [self.write("unrelated-reference.txt")]})
        context = {"via": "chat", "_private_session": True, "_session_id": "chat-1"}
        self.assertNotIn(support_id, [item["id"] for item in self.op("supporting_list", **context)["files"]])
        self.commit(change)
        linked = [item for item in self.state()["files"].values() if item.get("support_id") == support_id]
        self.assertEqual([wrong["id"]], [item["id"] for item in linked])
        self.assertTrue(self.d.file_roles.reference_active(self.ws, support_id, self.d.roles_api()))
        self.assertEqual(2, len(self.op("supporting_list", **context)["files"]))
        self.commit({"action": "correct", "file_ids": [wrong["id"]], "role": "unassigned", "reason": "Archive the corrected reference"})
        self.assertNotIn(support_id, [item["id"] for item in self.op("supporting_list", **context)["files"]])
        self.commit({"action": "correct", "file_ids": [wrong["id"]], "role": "reference", "reason": "Restore the canonical reference"})
        self.assertIn(support_id, [item["id"] for item in self.op("supporting_list", **context)["files"]])
        state = self.state()
        alias = dict(state["files"][wrong["id"]], id="file-" + "f" * 32, identity=None, role="unassigned", origin="supporting")
        state["files"][alias["id"]] = alias
        self.ws.write_json(self.data / "file-roles.json", state)
        self.assertTrue(self.d.file_roles.reference_active(self.ws, support_id, self.d.roles_api()))  # canonical origin wins over an old alias

    def test_exact_retry_can_reuse_a_higher_prepared_slot_after_different_intent(self):
        source, _, files, _, _, inventory, _, _ = self.interrupted_inventory_fixture()
        change = {"action": "correct", "file_ids": [files["part-two.sql"]["id"]], "role": "reference", "reason": "Only second part is reference"}
        preview = self.preview(change)
        original = self.d.Workspace.write_json
        def interrupted(workspace, path, document):
            if path.name == "file-roles.json":
                raise OSError("synthetic final registry failure after higher revision publication")
            return original(workspace, path, document)
        with mock.patch.object(self.d.Workspace, "write_json", interrupted):
            with self.assertRaisesRegex(self.d.Refusal, "STANDARD_OPERATION_FAILED"):
                self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
        higher = inventory.parent / (source + "-r3.json")
        prepared = higher.read_bytes()
        self.assertEqual(1, self.state()["snapshots"][source]["revision"])
        self.op("file_roles_commit", change=change, digest=preview["digest"], by="Engineer")
        self.assertEqual(3, self.state()["snapshots"][source]["revision"])
        self.assertEqual(prepared, higher.read_bytes())
        self.assertFalse((inventory.parent / (source + "-r4.json")).exists())

    def test_base_is_rejected_for_general_jobs_and_forged_producer_outputs(self):
        name = self.fixture.base_backup()
        result = self.commit({"action": "classify", "role": "base_site", "files": [self.listing(name)]})
        dataset = result["roles"]["active"]["base_site"]
        registered = next(item for item in self.state()["files"].values() if item.get("dataset_id") == dataset)
        before = (self.named / "state.json").read_bytes()
        docker_calls = list(self.fixture.docker.calls)
        with self.assertRaisesRegex(self.d.Refusal, "STANDARD_BASE_SITE_ROLE"):
            self.op("script", delivery=dataset, code="puts 'invented output'", into="base-job")
        with self.assertRaisesRegex(self.d.Refusal, "STANDARD_BASE_SITE_ROLE"):
            self.op("extract", path="inputs/" + name, into="base-extract")
        self.assertEqual(docker_calls, self.fixture.docker.calls)
        self.assertEqual([], self.d.jobs_of(self.ws))
        work = self.root / "work/legacy-base-job"
        work.mkdir(parents=True)
        output = work / "output.sql"
        output.write_bytes(b"-- invented source output from an old Base job")
        self.ws.write_json(self.ws.data_dir("jobs") / ("job-" + "f" * 12 + ".json"),
                           {"id": "job-" + "f" * 12, "status": "completed", "kind": "script", "into": work.name, "dataset_id": dataset})
        with self.assertRaisesRegex(self.d.Refusal, "STANDARD_BASE_SITE_ROLE"):
            self.op("register", path=work.name + "/output.sql", type="mysql-dump")
        self.assertTrue(output.exists())
        self.assertEqual(before, (self.named / "state.json").read_bytes())
        self.assertEqual(registered["input_id"], self.d.review_base_site(self.ws, {}))  # dedicated Base use remains valid

    def assert_resumable_base_take(self, boundary):
        name = self.fixture.base_backup()
        original_bytes = (self.intake / name).read_bytes()
        change = {"action": "classify", "role": "base_site", "files": [self.listing(name)]}
        if boundary == "after_move":
            patcher = mock.patch.object(self.d, "mark_taken", side_effect=OSError("synthetic after move before mark"))
        elif boundary == "after_mark":
            patcher = mock.patch.object(self.d.file_roles, "sync_taken", side_effect=OSError("synthetic after mark before sync"))
        else:
            original = self.d.Workspace.write_json
            def interrupted(workspace, path, document):
                if path.name == "file-roles.json" and any(item.get("input_id") for item in document.get("files", {}).values()):
                    if boundary == "after_sync_publish":
                        original(workspace, path, document)
                    raise OSError("synthetic synchronization registry-write interruption")
                return original(workspace, path, document)
            patcher = mock.patch.object(self.d.Workspace, "write_json", interrupted)
        with patcher:
            result = self.commit(change)
        self.assertEqual("ok", result["status"])
        self.assertIn("automatic take did not finish", " ".join(result["warnings"]))
        dataset = result["roles"]["active"]["base_site"]
        inputs = self.ws.named_state()["inputs"]
        self.assertEqual(1, len(inputs))
        input_id = next(iter(inputs))
        named_before = (self.named / "state.json").read_bytes()
        target = self.root / "inputs" / name
        inode = target.stat().st_ino
        self.assertEqual(0o400, target.stat().st_mode & 0o777)
        self.assertFalse((self.intake / name).exists())
        provenance = (self.data / "provenance.jsonl").read_bytes()
        prepared = {file: file.read_bytes() for file in (self.data / "file-role-inventories").glob("*.json")}
        resumed = self.op("take", path=name, type="base_site")
        self.assertEqual(input_id, resumed["input_id"])
        self.assertEqual("resumed", resumed["how"])
        self.assertEqual(named_before, (self.named / "state.json").read_bytes())
        self.assertEqual(original_bytes, target.read_bytes())
        self.assertEqual(inode, target.stat().st_ino)
        self.assertEqual(0o400, target.stat().st_mode & 0o777)
        self.assertEqual(provenance, (self.data / "provenance.jsonl").read_bytes())
        self.assertEqual(1, len(self.d.read_deliveries(self.ws)))
        self.assertEqual(1, self.d.read_deliveries(self.ws)[dataset]["version"])
        self.assertEqual(input_id, self.d.read_deliveries(self.ws)[dataset]["files"][0]["taken"])
        self.assertEqual(input_id, next(item["input_id"] for item in self.state()["files"].values() if item.get("dataset_id") == dataset))
        self.assertEqual(prepared, {file: file.read_bytes() for file in prepared})
        roles = (self.data / "file-roles.json").read_bytes()
        self.assertEqual(input_id, self.op("take", path=name, type="base_site")["input_id"])
        self.assertEqual(roles, (self.data / "file-roles.json").read_bytes())  # successful retries do not revise the snapshot again

    def test_base_take_recovers_after_move_before_mark_taken(self):
        self.assert_resumable_base_take("after_move")

    def test_base_take_recovers_after_mark_before_role_sync(self):
        self.assert_resumable_base_take("after_mark")

    def test_base_take_recovers_after_partial_sync_inventory_publication(self):
        self.assert_resumable_base_take("during_sync_save")

    def test_base_take_retry_is_idempotent_after_registry_replace_then_io_error(self):
        self.assert_resumable_base_take("after_sync_publish")

    def test_completed_take_recovery_cannot_reactivate_a_corrected_base(self):
        name = self.fixture.base_backup()
        result = self.commit({"action": "classify", "role": "base_site", "files": [self.listing(name)]})
        dataset = result["roles"]["active"]["base_site"]
        file = next(item for item in self.state()["files"].values() if item.get("dataset_id") == dataset)
        self.commit({"action": "correct", "file_ids": [file["id"]], "role": "reference", "reason": "The backup is reference material only"})
        before = (self.data / "file-roles.json").read_bytes()
        with self.assertRaisesRegex(self.d.Refusal, "INPUT_INELIGIBLE"):
            self.op("take", path=name, type="base_site")
        self.assertIsNone(self.state()["active"]["base_site"])
        self.assertEqual(before, (self.data / "file-roles.json").read_bytes())

    def test_completed_take_recovery_does_not_adopt_a_new_intake_file_or_changed_input(self):
        name = self.fixture.base_backup()
        self.commit({"action": "classify", "role": "base_site", "files": [self.listing(name)]})
        target = self.root / "inputs" / name
        (self.intake / name).write_bytes(b"new unrelated incoming file")
        with self.assertRaisesRegex(self.d.Refusal, "DELIVERY_UNLABELLED"):
            self.op("take", path=name, type="base_site")
        (self.intake / name).unlink()
        target.chmod(0o600)
        target.write_bytes(b"changed registered file")
        target.chmod(0o400)
        with self.assertRaisesRegex(self.d.Refusal, "STANDARD_INPUT_CHANGED"):
            self.op("take", path=name, type="base_site")

    def lineage_guide_fixture(self, bound=True):
        items = [self.write("primary.sql", b"-- MySQL dump invented primary"),
                 self.write("extra.sql", b"-- MySQL dump invented secondary")]
        dataset = self.commit({"action": "classify", "role": "source", "kind": "development", "files": items})["roles"]["active"]["development"]
        primary = self.op("take", path="primary.sql", type="mysql-dump")["input_id"]
        self.op("take", path="extra.sql", type="mysql-dump")
        self.ws.write_json(self.ws.data_dir("db") / "state.json", {"loads": [{"dataset_id": dataset}]})
        convert_plan, review_plan = "plan-" + "1" * 32, "plan-" + "2" * 32
        convert_run, review_run = "run-" + "1" * 32, "run-" + "2" * 32
        self.fixture.guide_state(
            findings={"finding-" + "1" * 32: {"status": "released", "release": {"released_at": "2026-01-01T00:00:00Z"}}},
            pushes=[{"digest": "a" * 64, "status": "pushed", "pushed_at": "2026-01-02T00:00:00Z"}],
            plans=[{"plan_id": convert_plan, "kind": "convert", "status": "consumed", "dataset_id": dataset},
                   {"plan_id": review_plan, "kind": "review", "status": "consumed", "dataset_id": dataset}],
            runs=[{"run_id": convert_run, "plan_id": convert_plan, "kind": "convert", "status": "completed", "dataset_id": dataset,
                   "checks": 1, "matched": 1, "started_at": "2026-01-03T00:00:00Z"},
                  {"run_id": review_run, "plan_id": review_plan, "kind": "review", "status": "completed", "dataset_id": dataset,
                   "checks": 1, "matched": 1, "started_at": "2026-01-04T00:00:00Z"}])
        path = self.standard / "state.json"
        state = json.loads(path.read_text())
        state["runs"] = {convert_run: {"plan_id": convert_plan, "status": "completed"},
                         review_run: {"plan_id": review_plan, "status": "completed"}}
        state["plans"][review_plan]["body"]["from_run"] = {"run_id": convert_run, "plan_id": convert_plan}
        if bound:
            binding = {"version": 1, "inputs": [{"role": "source", "input_id": primary, "dataset_id": dataset,
                                                 "revision": self.state()["snapshots"][dataset]["revision"], "eligible": True}]}
            state["plans"][convert_plan]["body"]["file_role_binding"] = binding
            state["plans"][review_plan]["body"]["source_file_role_binding"] = binding
        path.write_text(json.dumps(state))
        self.ws.write_json(self.d.site_reviews_file(self.ws), {"reviews": [{"id": "review-invented", "run_id": review_run,
            "verdict": "accepted", "basis": "customer", "by": "Engineer", "process": {"plan_id": review_plan,
            "convert_plan_id": convert_plan, "delivery": {"dataset_id": dataset, "kind": "development", "version": 1}}}]})
        for plan in self.fixture.control.status["plans"]:
            plan["file_role_lineage_current"] = True  # public Ruby projection; Python does not reimplement its policy
        return dataset, convert_plan, review_plan, convert_run, review_run

    def test_same_snapshot_revision_change_requires_fresh_conversion_not_old_review(self):
        dataset, convert_plan, review_plan, convert_run, _ = self.lineage_guide_fixture()
        initial = self.op("guide")
        self.assertEqual("accepted", initial["stage"])
        source_revision = self.state()["snapshots"][dataset]["revision"]
        standard = (self.standard / "state.json").read_bytes()
        self.commit({"action": "classify", "role": "uploads", "dataset_id": dataset, "files": [self.write("extra-assets.zip")]})
        self.assertEqual(dataset, self.state()["active"]["development"])
        self.assertGreater(self.state()["snapshots"][dataset]["revision"], source_revision)
        for plan in self.fixture.control.status["plans"]:
            plan["file_role_lineage_current"] = False
        for run in self.fixture.control.status["runs"]:
            run["file_role_lineage_current"] = True  # only the plan-ID join is authoritative
        before_calls = sum(call[0][:2] == ["standard", "status"] for call in self.fixture.control.calls)
        guide = self.op("guide")
        after_calls = sum(call[0][:2] == ["standard", "status"] for call in self.fixture.control.calls)
        self.assertEqual(before_calls + 1, after_calls)  # acceptance reuses the fetched public projection
        self.assertEqual("convert", guide["stage"])
        self.assertIn("propose a convert run", guide["next"]["action"])
        self.assertNotIn("from_run=", guide["next"]["action"])
        self.assertEqual({convert_plan, review_plan}, {plan["plan_id"] for plan in guide["plans"]})
        self.assertTrue(all(plan["status"] == "consumed" for plan in guide["plans"]))
        self.assertTrue(all(run["status"] == "completed" and run["file_role_lineage_current"] is False for run in guide["runs"]))
        self.assertIn("input set changed", " ".join(guide["site_acceptance"]["changed_since_acceptance"]))
        self.assertIn("historical", guide["site_acceptance"]["note"])
        self.assertEqual(standard, (self.standard / "state.json").read_bytes())
        self.fixture.control.status["runs"][0]["status"] = "running"
        guide = self.op("guide")
        self.assertEqual("convert", guide["stage"])
        self.assertEqual("nobody", guide["next"]["who"])
        self.assertIn(convert_run, " ".join(guide["happening"]))  # stale lineage still gets global active notices

    def test_legacy_completed_impact_uses_public_lineage_gate_without_rewriting_history(self):
        dataset, convert_plan, _, _, _ = self.lineage_guide_fixture(bound=False)
        standard = (self.standard / "state.json").read_bytes()
        extra = next(item for item in self.state()["files"].values() if item["path"] == "extra.sql")
        self.commit({"action": "correct", "file_ids": [extra["id"]], "role": "reference", "reason": "Extra SQL is a reference, not a source"})
        self.assertTrue(self.state()["snapshots"][dataset]["eligible"])
        self.assertIn(convert_plan, [entry["plan_id"] for entry in self.state()["history"][-1]["impacts"]["completed"]])
        for plan in self.fixture.control.status["plans"]:
            plan["file_role_lineage_current"] = False
        guide = self.op("guide")
        self.assertEqual("convert", guide["stage"])
        self.assertEqual(2, len(guide["runs"]))
        self.assertIn("input set changed", " ".join(guide["site_acceptance"]["changed_since_acceptance"]))
        self.assertEqual(standard, (self.standard / "state.json").read_bytes())

    def test_unrelated_reference_preserves_public_current_lineage_and_progression(self):
        dataset, _, _, _, _ = self.lineage_guide_fixture()
        revision = self.state()["snapshots"][dataset]["revision"]
        self.commit({"action": "classify", "role": "reference", "files": [self.write("unrelated-progress-notes.txt")]})
        self.assertEqual(revision, self.state()["snapshots"][dataset]["revision"])
        guide = self.op("guide")
        self.assertEqual("accepted", guide["stage"])
        self.assertTrue(all(run["file_role_lineage_current"] for run in guide["runs"]))
        self.assertEqual([], guide["site_acceptance"]["changed_since_acceptance"])
        self.assertIsNone(guide["site_acceptance"]["note"])

    def test_missing_public_lineage_field_preserves_legacy_fixture_progression(self):
        self.lineage_guide_fixture(bound=False)
        for plan in self.fixture.control.status["plans"]:
            plan.pop("file_role_lineage_current")
        for run in self.fixture.control.status["runs"]:
            run["file_role_lineage_current"] = False
        guide = self.op("guide")
        self.assertEqual("accepted", guide["stage"])
        self.assertTrue(all(plan["file_role_lineage_current"] for plan in guide["plans"]))
        self.assertTrue(all(run["file_role_lineage_current"] for run in guide["runs"]))

    def test_acceptance_cached_lineage_projection_avoids_control_calls_under_locks(self):
        self.lineage_guide_fixture()
        records = self.d.guide_records(self.ws)
        for plan in records["plans"]:
            plan["file_role_lineage_current"] = False
        for run in records["runs"]:
            run["file_role_lineage_current"] = False
        with mock.patch.object(self.ws, "control", side_effect=AssertionError("control call while locked")):
            with self.d.file_roles.locks(self.ws, self.d.roles_api()):
                site = self.d.site_summary(self.ws, records=records)
        self.assertFalse(site["accepted_lineage_current"])
        self.assertIn("input set changed", " ".join(site["changed"]))


if __name__ == "__main__":
    unittest.main()
