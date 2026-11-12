"""Engineer-owned effective file assignments; delivery and workflow provenance is immutable.

Mutations opportunistically take standard/op.lock, then require state.lock and
the data lock. No host execution lock is acquired here. Supporting custody may be prepared before the final registry replace;
its stable origin_id makes retry after a crash safe.
"""
import base64
import copy
import hashlib
import json
import os
import re
import stat
import struct
import zipfile
from contextlib import ExitStack
from pathlib import Path

ROLES = {"source", "uploads", "reference", "base_site", "unassigned"}
KINDS = {"development", "launch", "base_site"}
FILE_ID = re.compile(r"file-[0-9a-f]{32}\Z")
DATASET = re.compile(r"dataset-[0-9a-f]{32}\Z")
INPUT = re.compile(r"input-[0-9a-f]{32}\Z")
ACTIVE_STATUSES = {"running", "starting", "claimed", "queued", "preparing", "stopping", "resetting", "executing"}
MAX_STATE = 16 * 1024 * 1024
MISSING = object()  # JSON null is an existing invalid document, never absence


def fail(api, detail="INVALID"):
    api.refuse("STANDARD_FILE_ROLES_" + detail)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()


def read_json(ws, path, api, default=None):
    """Descriptor confinement also checks every parent, not just the final symlink."""
    root = api.open_root(ws.root)
    try:
        try:
            fd, info = api.open_regular(root, api.parts_of(str(path.relative_to(ws.root))))
        except api.Refusal as error:
            if str(error) == "STANDARD_PATH_MISSING":
                return default
            raise
        try:
            if info.st_uid != os.getuid() or info.st_size > MAX_STATE:
                fail(api)
            private = path == ws.data / "file-roles.json" or ws.data / "file-role-inventories" in path.parents
            if private and (info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
                fail(api)
            try:
                return json.loads(os.read(fd, MAX_STATE + 1))
            except (ValueError, UnicodeError):
                fail(api)
        finally:
            os.close(fd)
    finally:
        os.close(root)


def file_id(ws, dataset, identity, input_id=None):
    return "file-" + digest([ws.name, dataset, identity, input_id])[:32]


def seed(ws, api):
    records = api.read_deliveries(ws)
    inputs = ws.named_state().get("inputs") or {}
    state = {"version": 1, "revision": 1, "active": {}, "snapshots": {}, "files": {}, "history": [], "invalidated_plans": []}
    linked = set()
    for dataset, record in sorted(records.items(), key=lambda pair: pair[1].get("sequence", 0)):
        kind = record.get("kind")
        if kind not in KINDS or not DATASET.fullmatch(dataset):
            fail(api)
        state["snapshots"][dataset] = {"dataset_id": dataset, "kind": kind, "label": api.delivery_label(record),
                                        "revision": 1, "eligible": True, "legacy": True}
        # Preserve precisely the old newest/non-replaced selection, even if it was wrong.
        if not record.get("replaced_by"):
            state["active"][kind] = dataset
        for entry in record.get("files") or []:
            if not all(key in entry for key in api.IDENTITY):
                fail(api, "LEGACY_IDENTITY_MISSING")
            identity = {key: entry[key] for key in api.IDENTITY}
            input_id = entry.get("taken")
            item = {"id": file_id(ws, dataset, identity), "identity": identity, "path": entry["path"], "bytes": entry["bytes"],
                    "role": "base_site" if kind == "base_site" else "source", "dataset_id": dataset, "original_dataset_id": dataset}
            if input_id:
                if input_id not in inputs or inputs[input_id].get("dataset_id") != dataset:
                    fail(api, "LEGACY_INPUT_MISSING")
                item.update(input_id=input_id, sha256=inputs[input_id].get("sha256"))
                if inputs[input_id].get("type") in {"converter-settings", "merge-settings", "reconciliation", "settings", "count-checks"}:
                    item["derived"] = True
                linked.add(input_id)
            state["files"][item["id"]] = item
    # Pre-label named inputs have no drop identity. Keep that absence explicit; never
    # fabricate an inode/stamp from today's file or guess a label/active snapshot.
    for input_id, entry in inputs.items():
        if input_id in linked:
            continue
        dataset = entry.get("dataset_id")
        if not dataset or not INPUT.fullmatch(input_id):
            fail(api)
        path = base64.b64decode(entry["path"], validate=True).decode()
        item = {"id": file_id(ws, dataset, None, input_id), "identity": None, "path": path, "bytes": entry["bytes"],
                "role": "base_site" if entry.get("type") == "base_site" else "source", "dataset_id": dataset,
                "original_dataset_id": dataset, "input_id": input_id, "sha256": entry.get("sha256"),
                "derived": path.startswith("inputs/derived/") or entry.get("type") in {"converter-settings", "merge-settings", "reconciliation", "settings", "count-checks"}}
        state["files"][item["id"]] = item
    return state


def _validate(state, api):
    if (not isinstance(state, dict) or type(state.get("version")) is not int or state.get("version") != 1 or type(state.get("revision")) is not int
            or state["revision"] < 1 or not isinstance(state.get("active"), dict)
            or not isinstance(state.get("snapshots"), dict) or not isinstance(state.get("files"), dict)
            or not isinstance(state.get("history"), list)
            or not isinstance(state.get("invalidated_plans", []), list)
            or any(not isinstance(key, str) or not re.fullmatch(r"plan-[0-9a-f]{32}", key) for key in state.get("invalidated_plans", []))):
        fail(api)
    for dataset, snapshot in state["snapshots"].items():
        if (not DATASET.fullmatch(dataset) or not isinstance(snapshot, dict) or snapshot.get("dataset_id") != dataset
                or snapshot.get("kind") not in KINDS or type(snapshot.get("revision")) is not int or snapshot["revision"] < 1
                or type(snapshot.get("eligible")) is not bool):
            fail(api)
    for kind, dataset in state["active"].items():
        if kind in KINDS and dataset is None:
            continue
        snapshot = state["snapshots"].get(dataset)
        if kind not in KINDS or not snapshot or snapshot["kind"] != kind or not snapshot["eligible"]:
            fail(api)
    for key, item in state["files"].items():
        if (not FILE_ID.fullmatch(key) or not isinstance(item, dict) or item.get("id") != key or item.get("role") not in ROLES
                or type(item.get("bytes")) is not int or item["bytes"] < 0):
            fail(api)
        api.parts_of(item.get("path"))
        if item.get("dataset_id") is not None and not DATASET.fullmatch(item["dataset_id"]):
            fail(api)
        if item.get("input_id") is not None and not INPUT.fullmatch(item["input_id"]):
            fail(api)
        if item.get("sha256") is not None and not re.fullmatch(r"[0-9a-f]{64}", item["sha256"]):
            fail(api)
        if "derived" in item and type(item["derived"]) is not bool:
            fail(api)
        if item.get("support_id") is not None and not re.fullmatch(r"support-[0-9a-f]{32}", item["support_id"]):
            fail(api)
        if item.get("asset_path") is not None and item["asset_path"] != "file-role-assets/" + key:
            fail(api)
        if item.get("original_dataset_id") is not None and not DATASET.fullmatch(item["original_dataset_id"]):
            fail(api)
        if item["role"] in {"reference", "unassigned"} and item.get("dataset_id") is not None:
            fail(api)
        identity = item.get("identity")
        if identity is not None:
            if not isinstance(identity, dict) or set(identity) != set(api.IDENTITY):
                fail(api)
            api.parts_of(identity.get("path"))
            if type(identity.get("bytes")) is not int or identity["bytes"] != item["bytes"]:
                fail(api)
            if any(not isinstance(identity.get(key), str) or not identity[key].isdigit() for key in ("ino", "mtime_ns", "ctime_ns")):
                fail(api)
    incomplete = state.get("incomplete_deliveries", {})
    if not isinstance(incomplete, dict) or any(dataset not in state["snapshots"] or not isinstance(note, str) for dataset, note in incomplete.items()):
        fail(api)
    for event in state["history"]:
        if not isinstance(event, dict) or not isinstance(event.get("change"), dict) or not isinstance(event.get("impacts"), dict):
            fail(api)
        for category in ("pending", "active", "completed", "releases"):
            if not isinstance(event["impacts"].get(category), list):
                fail(api)
        for item in event["impacts"]["pending"] + event["impacts"]["completed"]:
            plan_id = item.get("plan_id") if isinstance(item, dict) else item
            if not isinstance(plan_id, str) or not re.fullmatch(r"plan-[0-9a-f]{32}", plan_id):
                fail(api)
    return state


def validate(state, api):
    try:
        return _validate(state, api)
    except api.Refusal:
        raise
    except (TypeError, KeyError, ValueError, AttributeError):
        fail(api)


def load(ws, api, persist=False, include_supporting=False):
    private_directories(ws, api)
    state = read_json(ws, ws.data / "file-roles.json", api, MISSING)
    if state is MISSING:
        state = seed(ws, api)
        validate(state, api)
        if persist:
            save(ws, state, api)
    else:
        validate(state, api)
        recover_incomplete(ws, state, api)
    if (persist or include_supporting) and not ws.chat:
        merge_supporting(ws, state, api)
    return validate(state, api)


def inventory_of(state, dataset, revision=None):
    snapshot = dict(state["snapshots"][dataset])
    if revision is not None:
        snapshot["revision"] = revision
    return dict(snapshot, files=[state["files"][key] for key in sorted(state["files"])
                                if state["files"][key].get("dataset_id") == dataset])


def checked_inventory(ws, path, dataset, revision, api):
    inventory = read_json(ws, path, api, MISSING)
    if inventory is MISSING:
        return MISSING
    if (not isinstance(inventory, dict) or inventory.get("dataset_id") != dataset
            or inventory.get("revision") != revision or not isinstance(inventory.get("files"), list)):
        fail(api, "INVENTORY_INVALID")
    files = inventory["files"]
    if any(not isinstance(item, dict) or not isinstance(item.get("id"), str)
           or item.get("dataset_id") != dataset for item in files):
        fail(api, "INVENTORY_INVALID")
    mapping = {item["id"]: item for item in files}
    if len(mapping) != len(files):
        fail(api, "INVENTORY_INVALID")
    validate({"version": 1, "revision": 1, "active": {}, "snapshots": {
        dataset: {key: value for key, value in inventory.items() if key != "files"}},
        "files": mapping, "history": []}, api)
    return inventory


def save(ws, state, api):
    private_directories(ws, api)
    validate(state, api)
    committed = read_json(ws, ws.data / "file-roles.json", api, MISSING)
    if committed is not MISSING:
        validate(committed, api)  # null/corrupt authoritative state is never bootstrap
    ws.data_dir()
    directory = ws.data_dir("file-role-inventories")
    info = directory.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        fail(api)
    names = os.listdir(directory)
    prepared, allocations = [], {}
    # Preflight EVERY snapshot before publishing any inventory. Revisions at or
    # below the authoritative registry's current revision are never replaceable.
    # Higher slots may be preparations left by an interrupted write: reuse exact
    # content, or allocate a higher unused revision for a different approved intent.
    for dataset in sorted(state["snapshots"]):
        revision = state["snapshots"][dataset]["revision"]
        current = 0 if committed is MISSING else (committed["snapshots"].get(dataset) or {}).get("revision", 0)
        if revision < current or (revision == current and inventory_of(state, dataset) != inventory_of(committed, dataset)):
            fail(api, "INVENTORY_CONFLICT")
        path = directory / (dataset + "-r%d.json" % revision)
        existing = checked_inventory(ws, path, dataset, revision, api)
        desired = inventory_of(state, dataset)
        if existing is not MISSING and existing != desired:
            if revision <= current:
                fail(api, "INVENTORY_CONFLICT")
            pattern = re.compile(re.escape(dataset) + r"-r([1-9][0-9]*)\.json\Z")
            occupied = sorted(int(match[1]) for name in names if (match := pattern.fullmatch(name)))
            reuse = None
            for slot in occupied:
                if slot <= max(current, revision):
                    continue
                candidate = checked_inventory(ws, directory / (dataset + "-r%d.json" % slot), dataset, slot, api)
                if candidate == inventory_of(state, dataset, slot):
                    reuse = slot
                    break
            revision = reuse if reuse is not None else max([revision, *occupied]) + 1
            path = directory / (dataset + "-r%d.json" % revision)
            existing = checked_inventory(ws, path, dataset, revision, api)
            desired = inventory_of(state, dataset, revision)
            if existing is not MISSING and existing != desired:
                fail(api, "INVENTORY_CONFLICT")
        allocations[dataset] = revision
        if existing is MISSING:
            prepared.append((path, desired))
    for dataset, revision in allocations.items():
        state["snapshots"][dataset]["revision"] = revision
    if len(json.dumps(state).encode()) > MAX_STATE:
        fail(api, "LIMIT")
    for path, inventory in prepared:
        ws.write_json(path, inventory)
    ws.write_json(ws.data / "file-roles.json", state)


def view(state):
    return {"revision": state["revision"], "active": state["active"],
            "snapshots": [dict(snapshot, **({"recovered": True, "incomplete": True, "recovery_note": state["incomplete_deliveries"][dataset]} if dataset in state.get("incomplete_deliveries", {}) else {}),
                               files=[item for item in state["files"].values() if item.get("dataset_id") == dataset])
                          for dataset, snapshot in state["snapshots"].items()],
            "references": [item for item in state["files"].values() if item["role"] == "reference"],
            "unassigned": [item for item in state["files"].values() if item["role"] == "unassigned"], "history": state["history"][-20:], "history_more": len(state["history"]) > 20}


def locks(ws, api):
    stack = ExitStack()
    try:
        standard = ws.root / ".silo-migrate/named/standard"
        root = api.open_root(ws.root)
        try:
            fd = api.walk_dirs(root, [".silo-migrate", "named", "standard"])
            os.close(fd)
        finally:
            os.close(root)
        try:
            stack.enter_context(api.Locked(standard / "op.lock"))
        except api.Refusal as error:
            if str(error) != "STANDARD_BUSY":
                raise
            # An unrelated run may hold op.lock for hours. state.lock excludes
            # new claims/approvals; dependency inspection below rejects only
            # affected active work. Never acquire the host execution lock.
        stack.enter_context(api.Locked(standard / "state.lock"))
        stack.enter_context(ws.lock())
        return stack
    except BaseException:
        stack.close()
        raise


def evidence(ws, item, api):
    if item.get("asset_path") and not item.get("input_id"):
        return asset_evidence(ws, item, api)
    if item.get("origin") == "supporting":
        return supporting_evidence(ws, item, api)
    input_id = item.get("input_id")
    if input_id:
        registered = (ws.named_state().get("inputs") or {}).get(input_id)
        if not registered or registered.get("sha256") != item.get("sha256"):
            fail(api, "FILES_CHANGED")
        path = base64.b64decode(registered["path"], validate=True).decode()
        parts = api.parts_of(path)
        if len(parts) < 2 or parts[0] != "inputs":
            fail(api)
        area, path = "inputs", "/".join(parts[1:])
    else:
        area, path = "intake", item["path"]
    root = ws.open_area(area)
    try:
        fd, info = api.open_regular(root, api.parts_of(path))
        try:
            if info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_size != item["bytes"]:
                fail(api, "FILES_CHANGED")
            stamp = {"path": path, "bytes": info.st_size, "ino": str(info.st_ino), "mtime_ns": str(info.st_mtime_ns), "ctime_ns": str(info.st_ctime_ns)}
            if not input_id and stamp != item.get("identity"):
                fail(api, "FILES_CHANGED")
            checksum = api.sha256_fd(fd)
            after = os.fstat(fd)
            if any(getattr(info, key) != getattr(after, key) for key in ("st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")):
                fail(api, "FILES_CHANGED")
            if input_id and checksum != item.get("sha256"):
                fail(api, "FILES_CHANGED")
            return {"area": area, "path": path, "stamp": stamp, "sha256": checksum}
        finally:
            os.close(fd)
    finally:
        os.close(root)


def source_checks(ws, files, api, *, area="intake"):
    if ws.meta().get("platform") != api.MERGE_PLATFORM:
        # No spreadsheet converter contract is registered by this backend.
        for item in files:
            if Path(item["path"]).suffix.lower() in {".xlsx", ".xls", ".ods"}:
                fail(api, "SOURCE_PLATFORM_INVALID")
            reject_workbook(ws, item["path"], area, api)
        return
    if len(files) != 1 or not api.DISCOURSE_BACKUP_NAME.search(Path(files[0]["path"]).name):
        fail(api, "SOURCE_INVALID: keep the original full Discourse backup name ending -v<version>.tar.gz")
    root = ws.open_area(area)
    try:
        fd, _ = api.open_regular(root, api.parts_of(files[0]["path"]))
        try:
            if os.read(fd, 2) != b"\x1f\x8b":
                fail(api, "SOURCE_INVALID: full backup must be gzip")
        finally:
            os.close(fd)
    finally:
        os.close(root)


def tokens(value):
    if isinstance(value, dict):
        result = set(value)
        for item in value.values():
            result.update(tokens(item))
        return result
    if isinstance(value, list):
        return set().union(*(tokens(item) for item in value)) if value else set()
    return {value} if isinstance(value, str) else set()


def dependencies(ws, datasets, inputs, api):
    state = read_json(ws, ws.root / ".silo-migrate/named/standard/state.json", api, {})
    wanted = set(datasets) | set(inputs)
    impacts = {"pending": [], "active": [], "completed": [], "releases": []}
    plans, runs = state.get("plans") or {}, state.get("runs") or {}
    jobs = api.jobs_of(ws)
    jobs = list(jobs.values()) if isinstance(jobs, dict) else jobs
    named_inputs = ws.named_state().get("inputs") or {}
    job_bindings = []
    for job in jobs:
        binding = tokens(job)
        source = job.get("source") or {}
        if job.get("kind") == "db_load" and isinstance(source, dict) and source.get("path") and source.get("sha256"):
            for input_id, record in named_inputs.items():
                try:
                    path = base64.b64decode(record["path"], validate=True).decode()
                except (ValueError, UnicodeError, KeyError):
                    continue
                if path == source["path"] and record.get("sha256") == source["sha256"]:
                    binding.update([input_id, record.get("dataset_id")])
        job_bindings.append(binding)
    hit, hit_runs, hit_jobs = set(), set(), set()
    # Propagate canonical IDs across ALL work kinds. In particular, a completed
    # data job can feed a running job or a later plan/run without naming an input.
    changed = True
    while changed:
        changed = False
        for key, plan in plans.items():
            if key not in hit and tokens(plan.get("body") or plan) & wanted:
                hit.add(key)
                wanted.add(key)
                changed = True
        for key, run in runs.items():
            if key not in hit_runs and (run.get("plan_id") in hit or tokens(run) & wanted):
                hit_runs.add(key)
                wanted.add(key)
                changed = True
        for index, (job, binding) in enumerate(zip(jobs, job_bindings)):
            if index not in hit_jobs and binding & wanted:
                hit_jobs.add(index)
                for identity in (job.get("id"), job.get("job_id")):
                    if isinstance(identity, str):
                        wanted.add(identity)
                changed = True
    for key in sorted(hit):
        plan = plans[key]
        if plan.get("status") in {"proposed", "approved", "pending"}:
            impacts["pending"].append({"plan_id": key, "status": plan.get("status")})
    for key in sorted(hit_runs):
        run = runs[key]
        item = {"run_id": key, "plan_id": run.get("plan_id"), "status": run.get("status")}
        impacts["active" if run.get("status") in ACTIVE_STATUSES else "completed"].append(item)
        if run.get("release"):
            impacts["releases"].append({"run_id": key, "release": run["release"]})
    releases = {key: release for key, release in (state.get("releases") or {}).items() if tokens(release) & wanted}
    impacts["releases"].extend({"release_id": key} for key in sorted(releases))
    relevant_jobs = [jobs[index] for index in sorted(hit_jobs)]
    for job in relevant_jobs:
        if job.get("status") in ACTIVE_STATUSES:
            impacts["active"].append({"job_id": job.get("id") or job.get("job_id"), "status": job.get("status")})
    relevant = {"plans": {key: plans[key] for key in sorted(hit)},
                "runs": {key: runs[key] for key in sorted(hit_runs)}, "releases": releases, "jobs": relevant_jobs}
    return impacts, digest(relevant)


def preview_locked(ws, request, api):
    state = load(ws, api, include_supporting=True)
    actor = request.get("by")
    if not isinstance(actor, str) or not actor.strip() or len(actor) > api.MAX_LABELLED_BY or any(ord(c) < 32 for c in actor):
        fail(api, "ACTOR_INVALID")
    change = copy.deepcopy(request.get("change"))
    if not isinstance(change, dict) or set(change) - {"action", "files", "file_ids", "role", "kind", "dataset_id", "restore_dataset_id", "reason", "confirm"}:
        fail(api, "CHANGE_INVALID")
    action, role = change.get("action"), change.get("role")
    if action not in {"classify", "correct", "activate"}:
        fail(api, "CHANGE_INVALID")
    if action in {"correct", "activate"} and (not isinstance(change.get("reason"), str) or not change["reason"].strip() or len(change["reason"]) > 2000):
        fail(api, "REASON_REQUIRED")
    after = copy.deepcopy(state["active"])
    files, checked, affected = [], [], set()
    if action == "activate":
        if any(key in change for key in ("files", "file_ids", "role", "restore_dataset_id")):
            fail(api, "CHANGE_INVALID")
        target = state["snapshots"].get(change.get("dataset_id"))
        if not target or not target["eligible"]:
            fail(api, "SNAPSHOT_INVALID")
        kind = target["kind"]
        # Activation changes selection, not any immutable snapshot/input binding.
        after[kind] = target["dataset_id"]
        files = [copy.deepcopy(item) for item in state["files"].values() if item.get("dataset_id") == target["dataset_id"] and item["role"] == ("base_site" if kind == "base_site" else "source") and not item.get("derived")]
        checked = snapshot_checks(ws, state, target["dataset_id"], api)
    else:
        if role not in ROLES:
            fail(api, "ROLE_INVALID")
        if action == "correct":
            if "files" in change or role not in {"reference", "uploads", "unassigned"}:
                fail(api, "CHANGE_INVALID")
            ids = change.get("file_ids")
            if not isinstance(ids, list) or not ids or any(not isinstance(key, str) or key not in state["files"] for key in ids) or len(set(ids)) != len(ids):
                fail(api, "FILES_INVALID")
            files = [copy.deepcopy(state["files"][key]) for key in ids]
            if any(item.get("origin") == "supporting" for item in files) and role not in {"unassigned", "reference"}:
                fail(api, "REINTAKE_REQUIRED: keep and explicitly deliver the original file before promoting a chat-only reference")
            affected.update(item["dataset_id"] for item in files if item.get("dataset_id"))
        else:
            if "file_ids" in change:
                fail(api, "CHANGE_INVALID")
            incoming = change.get("files")
            if not isinstance(incoming, list) or not incoming or not all(isinstance(item, dict) for item in incoming):
                fail(api, "FILES_INVALID")
            current = {item["path"]: item for item in api.drop_listing(ws) if item["ready"]}
            for item in incoming:
                seen = current.get(item.get("path"))
                identity = {key: item.get(key) for key in api.IDENTITY}
                if not seen or any(seen[key] != item.get(key) for key in api.IDENTITY):
                    fail(api, "FILES_CHANGED")
                previous = next((old for old in state["files"].values() if old.get("identity") == identity), None)
                if previous:
                    if previous["role"] != "unassigned":
                        fail(api, "ALREADY_ASSIGNED")
                    if previous.get("input_id") or previous.get("origin") == "supporting":
                        fail(api, "REINTAKE_REQUIRED: registered/chat-only input assignments cannot be rewritten")
                    current_item = copy.deepcopy(previous)
                    current_item.pop("asset_path", None)  # retained in immutable audit/custody, not the new source location
                    files.append(current_item)
                else:
                    files.append({"id": file_id(ws, None, identity), "identity": identity, "path": item["path"], "bytes": item["bytes"], "role": role, "dataset_id": None})
            change["files"] = [item["identity"] for item in files]
            if len({item["id"] for item in files}) != len(files):
                fail(api, "FILES_INVALID")
        for item in files:
            checked.append(evidence(ws, item, api))
        if role == "source":
            if action != "classify" or change.get("kind") not in {"development", "launch"} or "dataset_id" in change:
                fail(api, "CHANGE_INVALID")
            source_checks(ws, files, api)
            kind = change["kind"]
            after[kind] = "new-source-snapshot"
        elif role == "base_site":
            api.validate_base_site(ws, [item["identity"] for item in files])
            kind = "base_site"
            if after.get(kind):
                affected.add(after[kind])
            after[kind] = "new-base-snapshot"
        elif role == "uploads":
            target = state["snapshots"].get(change.get("dataset_id"))
            if not target or not target["eligible"] or target["kind"] == "base_site":
                fail(api, "SNAPSHOT_INVALID")
            if action == "correct" and not any(item["role"] == "source" and not item.get("derived") and item.get("dataset_id") == target["dataset_id"] and item["id"] not in {selected["id"] for selected in files} for item in state["files"].values()):
                fail(api, "SNAPSHOT_INVALID")
            affected.add(target["dataset_id"])
            kind = target["kind"]
        else:
            kind = None
            if "dataset_id" in change:
                fail(api, "CHANGE_INVALID")
        if action == "correct":
            selected = {item["id"] for item in files}
            for old_kind, dataset in list(after.items()):
                if dataset in affected and not any(item["id"] not in selected and item.get("dataset_id") == dataset and item["role"] in {"source", "base_site"} and not item.get("derived") for item in state["files"].values()):
                    restore_id = change.get("restore_dataset_id")
                    if restore_id is None:
                        after[old_kind] = None
                    else:
                        restore = state["snapshots"].get(restore_id)
                        if not restore or not restore["eligible"] or restore["kind"] != old_kind or restore["dataset_id"] == dataset:
                            fail(api, "SNAPSHOT_INVALID")
                        checked.extend(snapshot_checks(ws, state, restore["dataset_id"], api))
                        after[old_kind] = restore["dataset_id"]

            if change.get("restore_dataset_id"):
                target = state["snapshots"].get(change["restore_dataset_id"])
                if not target or not target["eligible"] or target["dataset_id"] in {item.get("dataset_id") for item in files}:
                    fail(api, "SNAPSHOT_INVALID")
                checked.extend(snapshot_checks(ws, state, target["dataset_id"], api))
                previous_kinds = {state["snapshots"][item["dataset_id"]]["kind"] for item in files if item.get("dataset_id") in state["snapshots"]}
                if target["kind"] not in previous_kinds:
                    fail(api, "SNAPSHOT_INVALID")
                after[target["kind"]] = target["dataset_id"]

    launch = kind == "launch" or after.get("launch") != state["active"].get("launch") or any(state["snapshots"].get(dataset, {}).get("kind") == "launch" for dataset in affected)
    if launch and change.get("confirm") != "LAUNCH":
        fail(api, "CONFIRM_LAUNCH")
    inputs = [item["input_id"] for item in files if item.get("input_id")]
    impacts, dependency_hash = dependencies(ws, affected, inputs, api)
    blocked = ["Affected work is active; settle it before changing assignments."] if impacts["active"] else []
    warnings = []
    if "development" in after and after["development"] is None:
        warnings.append("No source current; choose a valid Development source before planning.")
    if "launch" in after and after["launch"] is None:
        warnings.append("No Launch snapshot is current; Launch execution remains unavailable.")
    if "base_site" in after and after["base_site"] is None:
        warnings.append("No Base backup is current; select a valid SQL-only backup or deliberately use a fresh review site.")
    if impacts["completed"] or impacts["releases"]:
        warnings.append("Historical run/release bytes and bindings remain unchanged; reassess affected output deliberately.")
    if role == "uploads":
        warnings.append("Stored assets are not imported by this workflow; classification does not implement media import.")
    public = {"revision": state["revision"], "change": change, "files": files, "before_active": state["active"], "after_active": after,
              "impacts": impacts, "blocked": blocked, "warnings": warnings}
    selected_datasets = {item.get("dataset_id") for item in files}
    selected_datasets.update([change.get("dataset_id"), change.get("restore_dataset_id")])
    snapshot_binding = {dataset: state["snapshots"][dataset] for dataset in sorted(filter(None, selected_datasets)) if dataset in state["snapshots"]}
    public["digest"] = digest([actor, public, checked, dependency_hash, snapshot_binding])
    return public


def preview(ws, request, api):
    api.engineer_only(ws)
    ws.require()
    with locks(ws, api):
        return preview_locked(ws, request, api)


def admit(ws, item, checked, by, api):
    if checked["area"] == "supporting":
        return {"id": item["support_id"], "filename": Path(item["path"]).name, "size_bytes": item["bytes"], "sha256": checked["sha256"]}
    if checked["area"] == "assets":
        return api.supporting_module().admit_asset_reference(ws, {"origin_id": item["id"], "filename": Path(item["path"]).name,
                                                                "sha256": checked["sha256"], "by": by}, api.supporting_api())["file"]
    request = {"area": checked["area"], "path": checked["path"], "origin_id": item["id"], "by": by}
    if checked["area"] == "intake":
        request["identity"] = item["identity"]
    else:
        request["sha256"] = checked["sha256"]
    return api.supporting_module().admit_reference(ws, request, api.supporting_api())["file"]


def commit(ws, request, api):
    api.engineer_only(ws)
    ws.require()
    with locks(ws, api):
        result = preview_locked(ws, request, api)
        if request.get("digest") != result["digest"]:
            fail(api, "STALE_PREVIEW")
        if result["blocked"]:
            fail(api, "ACTIVE_DEPENDENCY")
        # Seed is durable before any delivery operation. A crash must never change
        # legacy newest-selection semantics when the next process bootstraps.
        state = load(ws, api, persist=True)
        persisted = read_json(ws, ws.data / "file-roles.json", api, MISSING)
        validate(persisted, api)
        persisted_ids = set(persisted["files"])
        change, files = result["change"], result["files"]
        before = [copy.deepcopy(state["files"].get(item["id"], dict(item, role="unassigned", dataset_id=None))) for item in files]
        action, role = change["action"], change.get("role")
        affected = {item.get("dataset_id") for item in files if item.get("dataset_id")} if action != "activate" else set()
        new_dataset = None
        if action == "classify" and role in {"source", "base_site"}:
            kind = change["kind"] if role == "source" else "base_site"
            labelled = api.op_delivery_label(ws, {"kind": kind, "by": request["by"], "files": change["files"],
                                                  "confirm": change.get("confirm"), "replaces_launch": True}, held_lock=True, sync_roles=False, auto_take=False)
            new_dataset = labelled["dataset_id"]
            record = api.read_deliveries(ws)[new_dataset]
            state["snapshots"][new_dataset] = {"dataset_id": new_dataset, "kind": kind, "label": api.delivery_label(record), "revision": 1, "eligible": True}
            affected.add(new_dataset)
        for item in files:
            if action == "activate":
                break
            checked = evidence(ws, item, api)
            item["sha256"] = checked["sha256"]
            if role == "reference":
                item["support_id"] = admit(ws, item, checked, request["by"], api)["id"]
                # A crash after custody publication but before the registry replace
                # can expose the prepared copy as an ephemeral native reference.
                # Reconcile only that unpersisted alias; never delete historic IDs.
                for alias, old in list(state["files"].items()):
                    if alias != item["id"] and alias not in persisted_ids and old.get("origin") == "supporting" and old.get("support_id") == item["support_id"]:
                        del state["files"][alias]
            elif role == "uploads":
                item["asset_path"] = store_asset(ws, item, checked, api)
            if action == "correct":
                item.setdefault("original_dataset_id", item.get("dataset_id"))
            item["role"] = role
            item["dataset_id"] = new_dataset or change.get("dataset_id") if role in {"source", "base_site", "uploads"} else None
            state["files"][item["id"]] = item
        if role == "uploads":
            affected.add(change["dataset_id"])
        for dataset in affected:
            snapshot = state["snapshots"].get(dataset)
            if not snapshot:
                continue
            if dataset != new_dataset:
                snapshot["revision"] += 1
            snapshot["eligible"] = any(item.get("dataset_id") == dataset and item["role"] in {"source", "base_site"} and not item.get("derived") for item in state["files"].values())
        state["active"] = {kind: new_dataset if value in {"new-source-snapshot", "new-base-snapshot"} else value for kind, value in result["after_active"].items()}
        if action == "correct" or role == "uploads":
            state.setdefault("invalidated_plans", [])
            state["invalidated_plans"] = sorted(set(state["invalidated_plans"]) | {item["plan_id"] for item in result["impacts"]["pending"]})
        if action == "activate":
            state.get("incomplete_deliveries", {}).pop(change["dataset_id"], None)
        state["revision"] += 1
        audit = {"at": api.now(), "by": request["by"], "revision": state["revision"], "change": change, "digest": result["digest"],
                 "before": before, "after": files, "before_active": result["before_active"], "after_active": state["active"], "impacts": result["impacts"]}
        state["history"].append(audit)
        save(ws, state, api)
        warnings = list(result["warnings"])
        if action == "activate" and state["snapshots"][change["dataset_id"]]["kind"] == "base_site" and not any(item.get("input_id") for item in files):
            warnings.append("Base selection committed; its original backup is not registered yet. Take the existing labelled file with data_take type=base_site; no new Base version is needed.")
        if role == "base_site":
            try:
                api.op_take(ws, {"path": files[0]["path"], "type": "base_site"}, held_lock=True)
            except (api.Refusal, OSError):
                # The assignment is already committed. Do not report a rolled-back
                # transaction or invite the UI to manufacture another Base version.
                warnings.append("Base assignment committed, but automatic take did not finish. Inspect/resume the existing Base delivery with data_take type=base_site; do not classify a replacement to retry.")
            state = load(ws, api)
        return {"status": "ok", "revision": state["revision"], "roles": view(state), "impacts": result["impacts"], "warnings": warnings}


def effective_input(ws, input_id, api, source=False):
    """Gate old take/job/proposal entry points too; the UI is not the boundary."""
    state = load(ws, api)
    items = [item for item in state["files"].values() if item.get("input_id") == input_id]
    if not items:
        registered = (ws.named_state().get("inputs") or {}).get(input_id)
        if registered and (ws.data / "file-roles.json").exists():
            snapshot = state["snapshots"].get(registered.get("dataset_id"))
            if not snapshot or not snapshot["eligible"]:
                fail(api, "INPUT_INELIGIBLE")
        return  # derived settings retain their contracts only in an eligible snapshot
    item = items[0]
    if item["role"] not in ({"source"} if source else {"source", "base_site"}):
        fail(api, "INPUT_INELIGIBLE")
    snapshot = state["snapshots"].get(item.get("dataset_id"))
    if (snapshot and not snapshot["eligible"]) or (snapshot is None and (ws.data / "file-roles.json").exists()):
        fail(api, "INPUT_INELIGIBLE")
    if source and ws.meta().get("platform") == api.MERGE_PLATFORM:
        original = (item.get("identity") or {}).get("path", item["path"])
        if not api.DISCOURSE_BACKUP_NAME.search(Path(original).name):
            fail(api, "SOURCE_INVALID")
        checked = evidence(ws, item, api)
        root = ws.open_area(checked["area"])
        try:
            fd, _ = api.open_regular(root, api.parts_of(checked["path"]))
            try:
                if os.read(fd, 2) != b"\x1f\x8b":
                    fail(api, "SOURCE_INVALID")
            finally:
                os.close(fd)
        finally:
            os.close(root)


def sync_taken(ws, dataset, drop_path, input_id, api):
    if not (ws.data / "file-roles.json").exists():
        return
    state = load(ws, api)
    registered = (ws.named_state().get("inputs") or {})[input_id]
    for item in state["files"].values():
        if item.get("identity", {}) and item["identity"].get("path") == drop_path and item.get("dataset_id") == dataset:
            if item.get("input_id") == input_id and item.get("sha256") == registered["sha256"]:
                return  # retry after successful synchronization is metadata-idempotent
            if item.get("input_id") is not None:
                fail(api, "INPUT_INELIGIBLE")
            item.update(input_id=input_id, sha256=registered["sha256"])
            if registered.get("type") in {"converter-settings", "merge-settings", "reconciliation", "settings", "count-checks"}:
                item["derived"] = True
            impacts, _ = dependencies(ws, [dataset], [input_id], api)
            state.setdefault("invalidated_plans", [])
            state["invalidated_plans"] = sorted(set(state["invalidated_plans"]) | {entry["plan_id"] for entry in impacts["pending"]})
            state["revision"] += 1
            if dataset in state["snapshots"]:
                state["snapshots"][dataset]["revision"] += 1
            save(ws, state, api)
            return


def input_is_source(state, input_id):
    item = next((item for item in state["files"].values() if item.get("input_id") == input_id), None)
    return bool(item and item["role"] == "source" and not item.get("derived") and (state["snapshots"].get(item.get("dataset_id")) or {"eligible": True})["eligible"])


def dataset_eligible(ws, dataset, api):
    state = load(ws, api)
    snapshot = state["snapshots"].get(dataset)
    return bool(snapshot and snapshot["eligible"])


def effective_claim(ws, records, identity, api):
    if not (ws.data / "file-roles.json").exists():
        return api.claim(records, identity)
    state = load(ws, api)
    stamp = {key: identity.get(key) for key in api.IDENTITY}
    item = next((item for item in state["files"].values() if item.get("identity") == stamp), None)
    if not item or item["role"] not in {"source", "base_site"} or item.get("input_id"):
        return None, None
    dataset = item.get("dataset_id")
    if not (state["snapshots"].get(dataset) or {}).get("eligible"):
        return None, None
    record = records.get(dataset) or {}
    if record.get("replaced_by") and state["active"].get(record.get("kind")) != dataset:
        return None, None
    entry = next((entry for entry in record.get("files", []) if all(entry.get(key) == stamp.get(key) for key in api.IDENTITY)), None)
    return (dataset, entry) if entry else (None, None)


def take_allowed(ws, dataset, path, kind, api):
    state = load(ws, api)
    if not (ws.data / "file-roles.json").exists():
        return
    item = next((item for item in state["files"].values() if item.get("dataset_id") == dataset and item.get("identity") and item["identity"]["path"] == path), None)
    if (not item or item["role"] not in {"source", "base_site"}
            or not (state["snapshots"].get(dataset) or {}).get("eligible")):
        fail(api, "INPUT_INELIGIBLE")
    if item["role"] == "source" and ws.meta().get("platform") == api.MERGE_PLATFORM and kind != api.MERGE_SOURCE_TYPE:
        fail(api, "SOURCE_TYPE_INVALID")


def sync_label(ws, dataset, api):
    """Compatibility for the old explicit label API; never re-seed existing assignments."""
    state = load(ws, api)
    record = api.read_deliveries(ws)[dataset]
    legacy = seed(ws, api)
    state["snapshots"][dataset] = legacy["snapshots"][dataset]
    for key, item in legacy["files"].items():
        if item.get("dataset_id") == dataset and key not in state["files"]:
            state["files"][key] = item
    state["active"][record["kind"]] = dataset
    state["snapshots"][dataset]["eligible"] = any(item.get("dataset_id") == dataset and item["role"] in {"source", "base_site"} and not item.get("derived") for item in state["files"].values())
    state["revision"] += 1
    save(ws, state, api)


def store_asset(ws, item, checked, api):
    """Private storage-only assets, not supporting-reader references or run inputs."""
    if checked["area"] == "assets":
        return item["asset_path"]
    ws.data_dir("file-role-assets")
    root = api.open_root(ws.root)
    destination = None
    source = ws.open_area(checked["area"])
    fd = out = None
    staged = "." + item["id"] + "-" + os.urandom(8).hex() + ".tmp"
    try:
        destination = api.walk_dirs(root, [".silo-migrate", "data", "file-role-assets"])
        try:
            existing, info = api.open_regular(destination, [item["id"]])
        except api.Refusal as error:
            if str(error) != "STANDARD_PATH_MISSING":
                raise
        else:
            try:
                if info.st_size != item["bytes"] or info.st_mode & 0o222 or api.sha256_fd(existing) != checked["sha256"]:
                    fail(api, "ASSET_CONFLICT")
            finally:
                os.close(existing)
            return "file-role-assets/" + item["id"]
        fd, before = api.open_regular(source, api.parts_of(checked["path"]))
        out = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=destination)
        count, checksum = 0, hashlib.sha256()
        while True:
            chunk = os.read(fd, api.CHUNK)
            if not chunk:
                break
            checksum.update(chunk)
            count += len(chunk)
            view = memoryview(chunk)
            while view:
                view = view[os.write(out, view):]
        if count != item["bytes"] or checksum.hexdigest() != checked["sha256"] or any(getattr(os.fstat(fd), key) != getattr(before, key) for key in ("st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")):
            fail(api, "FILES_CHANGED")
        # Reopen/recheck the source name as well as the held descriptor.
        if evidence(ws, item, api) != checked:
            fail(api, "FILES_CHANGED")
        os.fchmod(out, 0o400)
        os.fsync(out)
        os.rename(staged, item["id"], src_dir_fd=destination, dst_dir_fd=destination)
        os.fsync(destination)
        return "file-role-assets/" + item["id"]
    finally:
        if out is not None:
            os.close(out)
            try:
                os.unlink(staged, dir_fd=destination)
            except FileNotFoundError:
                pass
        if fd is not None:
            os.close(fd)
        os.close(source)
        os.close(root)
        if destination is not None:
            os.close(destination)


def merge_supporting(ws, state, api):
    """Native chat custody is project-wide; never invent a drop stamp for it."""
    supporting = ws.data / "supporting"
    if not supporting.exists():
        return
    if supporting.is_symlink():
        fail(api)
    known = {item.get("support_id") for item in state["files"].values()}
    module, supporting_api = api.supporting_module(), api.supporting_api()
    for public in module.engineer_list(ws, supporting_api):
        support_id = public["id"]
        origin = module.reference_origin(ws, support_id, supporting_api)
        if origin and origin.get("origin_id") is not None:
            # An engineer copy is prepared custody, not a new native attachment.
            # Only the explicit role commit may link it to its stable origin ID.
            # Never publish a second active alias after a failed registry write.
            continue
        if support_id in known:
            continue
        identity = "file-" + digest([ws.name, "supporting", support_id])[:32]
        state["files"][identity] = {"id": identity, "identity": None, "path": public["filename"], "bytes": public["size_bytes"],
                                    "role": "reference", "dataset_id": None, "support_id": support_id, "sha256": public["sha256"], "origin": "supporting"}


def supporting_evidence(ws, item, api):
    support_id = item.get("support_id")
    if not isinstance(support_id, str) or not re.fullmatch(r"support-[0-9a-f]{32}", support_id):
        fail(api)
    root = api.open_root(ws.root)
    try:
        parts = [".silo-migrate", "data", "supporting", "files", support_id]
        fd, info = api.open_regular(root, parts)
        try:
            if info.st_uid != os.getuid() or info.st_mode & 0o222 or info.st_nlink != 1 or info.st_size != item["bytes"] or api.sha256_fd(fd) != item["sha256"]:
                fail(api, "FILES_CHANGED")
            return {"area": "supporting", "path": support_id, "sha256": item["sha256"],
                    "stamp": {"ino": str(info.st_ino), "bytes": info.st_size, "ctime_ns": str(info.st_ctime_ns), "mtime_ns": str(info.st_mtime_ns)}}
        finally:
            os.close(fd)
    finally:
        os.close(root)


def reference_active(ws, support_id, api):
    # Do not call load/engineer_list here: supporting.handle invokes this while
    # holding its lock. Unknown native references remain active by default;
    # engineer copies require their canonical origin assignment to be committed.
    state = read_json(ws, ws.data / "file-roles.json", api, MISSING)
    if state is MISSING:
        return True
    private_directories(ws, api)
    validate(state, api)
    if (ws.data / "supporting").exists():
        origin = api.supporting_module().reference_origin(ws, support_id, api.supporting_api())
        if origin and origin.get("origin_id") is not None:
            canonical = state["files"].get(origin["origin_id"])
            return bool(canonical and canonical.get("support_id") == support_id and canonical["role"] == "reference")
    return all(item["role"] == "reference" for item in state["files"].values() if item.get("support_id") == support_id)


def private_directories(ws, api):
    """Match the Ruby reader's private registry boundary, without chmod repairs."""
    root = api.open_root(ws.root)
    fd = root
    try:
        for name in (".silo-migrate", "data"):
            try:
                child = os.open(name, api.DIR_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                return
            except OSError:
                fail(api)
            if fd != root:
                os.close(fd)
            fd = child
            info = os.fstat(fd)
            if info.st_uid != os.getuid() or info.st_mode & 0o077:
                fail(api)
    finally:
        if fd != root:
            os.close(fd)
        os.close(root)


def snapshot_checks(ws, state, dataset, api):
    base = (state["snapshots"].get(dataset) or {}).get("kind") == "base_site"
    files = [item for item in state["files"].values() if item.get("dataset_id") == dataset
             and item["role"] == ("base_site" if base else "source") and not item.get("derived")]
    if not files:
        fail(api, "SNAPSHOT_INVALID")
    checked = [evidence(ws, item, api) for item in files]
    if (base or ws.meta().get("platform") == api.MERGE_PLATFORM) and len(files) != 1:
        fail(api, "SOURCE_INVALID")
    for item, check in zip(files, checked):
        original = (item.get("identity") or {}).get("path", item["path"])
        if base:
            if not api.discourse_version.backup(Path(original).name):
                fail(api, "BASE_INVALID: keep the original SQL-only backup name")
            root = ws.open_area(check["area"])
            try:
                fd, _ = api.open_regular(root, api.parts_of(check["path"]))
                try:
                    if os.read(fd, 2) != b"\x1f\x8b":
                        fail(api, "BASE_INVALID: SQL-only backup must be gzip")
                finally:
                    os.close(fd)
            finally:
                os.close(root)
        else:
            if ws.meta().get("platform") == api.MERGE_PLATFORM and not api.DISCOURSE_BACKUP_NAME.search(Path(original).name):
                fail(api, "SOURCE_INVALID")
            source_checks(ws, [{"path": check["path"]}], api, area=check["area"])
    return checked


def asset_evidence(ws, item, api):
    root = api.open_root(ws.root)
    try:
        fd, info = api.open_regular(root, [".silo-migrate", "data", "file-role-assets", item["id"]])
        try:
            checksum = api.sha256_fd(fd)
            if info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o222 or info.st_size != item["bytes"] or checksum != item.get("sha256"):
                fail(api, "FILES_CHANGED")
            return {"area": "assets", "path": item["id"], "sha256": checksum,
                    "stamp": {"ino": str(info.st_ino), "bytes": info.st_size, "ctime_ns": str(info.st_ctime_ns), "mtime_ns": str(info.st_mtime_ns)}}
        finally:
            os.close(fd)
    finally:
        os.close(root)


def reject_workbook(ws, path, area, api):
    root = ws.open_area(area)
    try:
        fd, info = api.open_regular(root, api.parts_of(path))
        try:
            head = os.read(fd, 8)
            if head.startswith(b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"):
                fail(api, "SOURCE_PLATFORM_INVALID")  # legacy Office compound document
            if head[:4] != b"PK\x03\x04":
                return
            os.lseek(fd, max(0, info.st_size - 65557), os.SEEK_SET)
            tail = os.read(fd, 65557)
            position = tail.rfind(b"PK\x05\x06")
            if position >= 0 and len(tail) - position >= 22:
                end = struct.unpack_from("<4s4H2LH", tail, position)
                if end[4] > 100000 or end[5] > 8 * 1024 * 1024:
                    fail(api, "SOURCE_ARCHIVE_METADATA_LIMIT")
            # Inspect names only, never extract/decompress or parse XML. A normal
            # ZIP export is allowed; a renamed OOXML/ODS workbook is not.
            with os.fdopen(os.dup(fd), "rb") as stream:
                try:
                    with zipfile.ZipFile(stream) as archive:
                        if any(entry.filename.lower() in {"xl/workbook.xml", "xl/workbook.bin"} for entry in archive.infolist()):
                            fail(api, "SOURCE_PLATFORM_INVALID")
                        if "mimetype" in archive.namelist():
                            entry = archive.getinfo("mimetype")
                            if entry.file_size <= 256 and archive.read(entry) == b"application/vnd.oasis.opendocument.spreadsheet":
                                fail(api, "SOURCE_PLATFORM_INVALID")
                except zipfile.BadZipFile:
                    return  # ambiguous/malformed archive is not a workbook assertion
        finally:
            os.close(fd)
    finally:
        os.close(root)


def recovery_inventory(ws, dataset, api):
    """Reuse an already-published immutable inventory; never rewrite it on read."""
    root = api.open_root(ws.root)
    directory = None
    try:
        try:
            directory = api.walk_dirs(root, [".silo-migrate", "data", "file-role-inventories"])
        except api.Refusal as error:
            if str(error) == "STANDARD_PATH_MISSING":
                return None
            raise
        info = os.fstat(directory)
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            fail(api)
        pattern = re.compile(re.escape(dataset) + r"-r([1-9][0-9]{0,17})\.json\Z")
        candidates = [(int(match[1]), name) for name in os.listdir(directory) if (match := pattern.fullmatch(name))]
        if not candidates:
            return None
        revision, name = max(candidates)
        inventory = read_json(ws, ws.data / "file-role-inventories" / name, api)
        if (not isinstance(inventory, dict) or inventory.get("dataset_id") != dataset
                or inventory.get("revision") != revision or not isinstance(inventory.get("files"), list)):
            fail(api, "RECOVERY_INVALID")
        return inventory
    finally:
        if directory is not None:
            os.close(directory)
        os.close(root)


def _recover_incomplete(ws, state, api):
    """Project authorized but interrupted labels as INACTIVE, without any writes.

    This is not a transaction journal or rollback. A fresh activation/correction
    commits the projected inventory. The persisted active map is never inferred
    from delivery sequence, including when an earlier Base was marked replaced.
    """
    document = read_json(ws, api.deliveries_file(ws), api, {})
    records = document.get("deliveries") if isinstance(document, dict) else None
    if not isinstance(records, dict):
        return
    missing = set(records) - set(state["snapshots"])
    if not missing:
        return
    legacy = seed(ws, api)
    named_inputs = ws.named_state().get("inputs") or {}
    for dataset in sorted(missing):
        record = records[dataset]
        if not isinstance(record, dict) or not record.get("labelled_by") or not record.get("labelled_at"):
            fail(api, "RECOVERY_INVALID")
        inventory = recovery_inventory(ws, dataset, api)
        if inventory is not None:
            snapshot = {key: copy.deepcopy(value) for key, value in inventory.items() if key != "files"}
            files = copy.deepcopy(inventory["files"])
            if snapshot.get("kind") != record.get("kind"):
                fail(api, "RECOVERY_INVALID")
        else:
            snapshot = copy.deepcopy(legacy["snapshots"][dataset])
            files = [copy.deepcopy(item) for item in legacy["files"].values() if item.get("dataset_id") == dataset]
        changed_inventory = False
        ids = set()
        for item in files:
            if (not isinstance(item, dict) or not isinstance(item.get("id"), str) or not FILE_ID.fullmatch(item["id"])
                    or item.get("dataset_id") != dataset or item["id"] in ids):
                fail(api, "RECOVERY_INVALID")
            ids.add(item.get("id"))
            if item.get("input_id"):
                registered = named_inputs.get(item["input_id"]) or {}
                if registered.get("dataset_id") != dataset or registered.get("sha256") != item.get("sha256"):
                    fail(api, "RECOVERY_INVALID")
                path = base64.b64decode(registered["path"], validate=True).decode()
                if (path.startswith("inputs/derived/") or registered.get("type") in {"converter-settings", "merge-settings", "reconciliation", "settings", "count-checks"}) and not item.get("derived"):
                    item["derived"] = True
                    changed_inventory = True
            if item.get("identity") is not None and item.get("role") in {"source", "base_site"}:
                if not any(all(entry.get(key) == item["identity"].get(key) for key in api.IDENTITY) for entry in record.get("files", [])):
                    fail(api, "RECOVERY_INVALID")
            existing = state["files"].get(item["id"])
            if existing is None:
                existing = next((old for old in state["files"].values()
                                 if (item.get("identity") is not None and old.get("identity") == item["identity"])
                                 or (item.get("input_id") and old.get("input_id") == item["input_id"])), None)
            if existing is not None:
                if existing.get("dataset_id") != dataset and existing.get("role") != "unassigned":
                    # An existing effective assignment wins over an interrupted
                    # classification; never overwrite a later correction on GET.
                    changed_inventory = True
                    continue
                if existing["id"] != item["id"]:
                    item["id"] = existing["id"]
                    changed_inventory = True
            state["files"][item["id"]] = item
        eligible = any(item.get("dataset_id") == dataset and item.get("role") in {"source", "base_site"}
                       and not item.get("derived") for item in state["files"].values())
        if snapshot.get("eligible") != eligible:
            snapshot["eligible"] = eligible
            changed_inventory = True
        if changed_inventory and inventory is not None:
            snapshot["revision"] += 1
        state["snapshots"][dataset] = snapshot
        state.setdefault("incomplete_deliveries", {})[dataset] = (
            "Classification was interrupted before the role registry was published. "
            "This snapshot is inactive; inspect its original delivery and use a fresh activation preview to make it current. "
            "A waiting Base backup can be taken from its existing label after selection; no new version is needed.")
    if len(json.dumps(state).encode()) > MAX_STATE:
        fail(api, "LIMIT")


def recover_incomplete(ws, state, api):
    try:
        _recover_incomplete(ws, state, api)
    except api.Refusal:
        raise
    except (TypeError, KeyError, ValueError, AttributeError):
        fail(api, "RECOVERY_INVALID")
