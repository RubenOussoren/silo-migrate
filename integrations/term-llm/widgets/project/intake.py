"""Intake-first plan and reference projections for the Project page.

Pure-ish functions over the workbench's own plan/run records (read through the Runs module's
Store). Nothing here creates, approves or starts anything, and nothing here invents state:

* A plan's optional ``preparation`` (labelled analyst text, outcomes and their dispositions,
  questions with their resolutions, exclusions, computed code readiness) and ``run_inputs`` (the
  converter input manifest with lineage) are bound into the plan body by the backend
  (lib/silo_migrate/services/standard_run_inputs.rb), so the approval digest already covers them. Older plans have neither and are shown as
  before, never as "ready".
* Readiness fails closed: unresolved material questions, unresolved wishes without an explicit
  exclusion, required-but-unpinned code, malformed fields, and selected inputs that are not
  bound, not readable or not byte-identical all block.
* "Used by" for a reference is derived from plan/run provenance, never stored as a toggle.
"""

import base64
import hashlib
import os
import re
import stat

FILE_ID = re.compile(r"file-[0-9a-f]{16,64}\Z")
INPUT_ID = re.compile(r"input-[0-9a-f]{16,64}\Z")
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\Z")
ITEM_ID = re.compile(r"[a-z0-9][a-z0-9_-]{0,31}\Z")
SETTING = re.compile(r"[a-z_][a-z0-9_]{0,63}(?:\.[a-z_][a-z0-9_]{0,63}){0,7}\Z")
SEGMENT = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\Z")
SHA = re.compile(r"[0-9a-f]{64}\Z")
DATASET = re.compile(r"dataset-[0-9a-f]{32}\Z")
VERIFICATION = ("custody_bytes", "registry_digest")
REVISION = re.compile(r"[0-9a-f]{7,64}\Z")
# The backend's vocabulary (lib/silo_migrate/services/standard_run_inputs.rb).
DISPOSITIONS = ("stock", "setting", "prepared_input", "code", "manual", "excluded")
QUESTION_STATUSES = ("resolved", "excluded", "scope_narrowed")
MAX_TEXT = 8000
MAX_ITEMS = 256
MAX_PREVIEW = 64 * 1024
# Exact-hash re-verification streams the whole file (64 KiB preview only). Above this the page
# does not spend the request on hashing: it says so (state "not_verified_here") without
# claiming verification, and the run still checks the bound sha256 before using the bytes.
MAX_VERIFY = 2 * 1024 * 1024 * 1024
TEXT_SUFFIXES = (".csv", ".tsv", ".yml", ".yaml", ".json", ".txt", ".md")
OPEN_STATUSES = ("proposed", "approved")


class Malformed(ValueError):
    pass


def _text(value, limit=MAX_TEXT, required=True):
    if value is None and not required:
        return None
    if not isinstance(value, str) or not value or len(value) > limit or "\x00" in value:
        raise Malformed()
    return value


def _list(value, limit=MAX_ITEMS):
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > limit or not all(isinstance(item, dict) for item in value):
        raise Malformed()
    return value


def _item_id(value, seen):
    if not isinstance(value, str) or not ITEM_ID.fullmatch(value) or value in seen:
        raise Malformed()
    seen.add(value)
    return value


def _name(name):
    parts = name.split("/") if isinstance(name, str) else []
    if not isinstance(name, str) or len(name.encode("utf-8")) > 255 or not 1 <= len(parts) <= 4 or not all(SEGMENT.fullmatch(part) and part not in (".", "..") for part in parts):
        raise Malformed()
    return name


def _names(value):
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > 64:
        raise Malformed()
    return [_name(name) for name in value]


def _reference(entry):
    if not isinstance(entry, dict) or not isinstance(entry.get("sha256"), str) or not SHA.fullmatch(entry["sha256"]):
        raise Malformed()
    file_id, input_id = entry.get("file_id"), entry.get("input_id")
    if (file_id is None) == (input_id is None):
        raise Malformed()
    if file_id is not None and not (isinstance(file_id, str) and FILE_ID.fullmatch(file_id)):
        raise Malformed()
    if input_id is not None and not (isinstance(input_id, str) and INPUT_ID.fullmatch(input_id)):
        raise Malformed()
    result = {key: entry[key] for key in ("file_id", "input_id", "sha256") if entry.get(key) is not None}
    # Backend-enriched: whether the proposal re-read the custody bytes or only matched the
    # registry's recorded digest. Display only; never sent back on a re-proposal.
    if "verified" in entry:
        if entry["verified"] not in VERIFICATION:
            raise Malformed()
        result["verified"] = entry["verified"]
    return result


def normalize_preparation(raw):
    """The plan's bound preparation metadata, re-checked field by field. Raises Malformed."""
    if not isinstance(raw, dict) or raw.get("version") != 1 or not isinstance(raw.get("analyst"), dict):
        raise Malformed()
    analyst = {"label": _text(raw["analyst"].get("label"), 80), "text": _text(raw["analyst"].get("text"))}
    references = [_reference(entry) for entry in _list(raw.get("references"), 32)]
    seen = set()
    exclusions = [{"id": _item_id(item.get("id"), seen), "text": _text(item.get("text"), 1000), "reason": _text(item.get("reason"), 1000, required=False)}
                  for item in _list(raw.get("exclusions"))]
    exclusion_ids = {item["id"] for item in exclusions}
    seen = set()
    questions = []
    for item in _list(raw.get("questions")):
        entry = {"id": _item_id(item.get("id"), seen), "text": _text(item.get("text"), 1000), "status": item.get("status")}
        if entry["status"] not in QUESTION_STATUSES:
            # Fail closed: a question without a recorded resolution blocks; it is never a default.
            entry["status"], entry["resolution"] = None, None
        else:
            entry["resolution"] = _text(item.get("resolution"), 1000)
        if entry["status"] == "excluded":
            if item.get("exclusion") not in exclusion_ids:
                raise Malformed()
            entry["exclusion"] = item["exclusion"]
        questions.append(entry)
    seen = set()
    outcomes = []
    for item in _list(raw.get("outcomes")):
        if item.get("disposition") not in DISPOSITIONS:
            raise Malformed()
        entry = {"id": _item_id(item.get("id"), seen), "requirement": _text(item.get("requirement"), 1000), "disposition": item["disposition"]}
        if entry["disposition"] == "prepared_input":
            target = item.get("input")
            if target != "settings":
                _name(target)
            entry["input"] = target
        if entry["disposition"] == "excluded":
            if item.get("exclusion") not in exclusion_ids:
                raise Malformed()
            entry["exclusion"] = item["exclusion"]
        outcomes.append(entry)
    readiness = raw.get("code_readiness")
    if readiness is not None:
        if not isinstance(readiness, dict) or readiness.get("kind") not in ("converter", "merge_layer") or not isinstance(readiness.get("present"), bool):
            raise Malformed()
        revision = readiness.get("revision")
        if revision is not None and not (isinstance(revision, str) and REVISION.fullmatch(revision)):
            raise Malformed()
        readiness = {"kind": readiness["kind"], "present": readiness["present"], "required": readiness.get("required") is True,
                     "revision": revision, "path": readiness.get("path") if isinstance(readiness.get("path"), str) and len(readiness["path"]) <= 300 else None}
    return {"analyst": analyst, "references": references, "outcomes": outcomes, "questions": questions, "exclusions": exclusions, "code_readiness": readiness}


def normalize_run_inputs(raw):
    if not isinstance(raw, dict) or raw.get("version") != 1:
        raise Malformed()
    consumer = raw.get("consumer")
    if not isinstance(consumer, dict) or not isinstance(consumer.get("setting"), str) or not SETTING.fullmatch(consumer["setting"]):
        raise Malformed()
    if not isinstance(raw.get("files"), list):
        raise Malformed()
    files, names = [], set()
    # An empty list is valid: the run gets a fresh, empty run-owned directory, so the converter's
    # own defaults apply (e.g. Khoros generating trust_level_mapping.yml). Not a dummy/header file.
    for item in _list(raw["files"]):
        name = _name(item.get("name"))
        if name.lower() in names or not isinstance(item.get("input_id"), str) or not INPUT_ID.fullmatch(item["input_id"]):
            raise Malformed()
        if not isinstance(item.get("sha256"), str) or not SHA.fullmatch(item["sha256"]) or type(item.get("bytes")) is not int or item["bytes"] < 0:
            raise Malformed()
        names.add(name.lower())
        lineage = item.get("lineage")
        if lineage is not None:
            if not isinstance(lineage, dict):
                raise Malformed()
            prep = lineage.get("preparation")
            if prep is not None and not (isinstance(prep, dict) and isinstance(prep.get("job"), str) and TOKEN.fullmatch(prep["job"])):
                raise Malformed()
            if prep is not None and any(key in prep and not (isinstance(prep[key], str) and SHA.fullmatch(prep[key])) for key in ("script_sha256", "preparation_sha256")):
                raise Malformed()
            lineage = {"references": [_reference(entry) for entry in _list(lineage.get("references"), 32)],
                       "preparation": {key: prep[key] for key in ("job", "tool", "script_sha256", "preparation_sha256") if isinstance(prep.get(key), str)} if prep else None}
        reuse = item.get("reuse")
        if reuse is not None:
            # Explicit reuse of an earlier delivery's file: its own dataset and that dataset's source digest.
            if (not isinstance(reuse, dict) or set(reuse) != {"dataset_id", "source_sha256"} or not isinstance(reuse["dataset_id"], str)
                    or not DATASET.fullmatch(reuse["dataset_id"]) or not isinstance(reuse["source_sha256"], str) or not SHA.fullmatch(reuse["source_sha256"])):
                raise Malformed()
            reuse = {"dataset_id": reuse["dataset_id"], "source_sha256": reuse["source_sha256"]}
        files.append({"name": name, "input_id": item["input_id"], "sha256": item["sha256"], "bytes": item["bytes"], "lineage": lineage, "reuse": reuse})
    absent, generated = _names(raw.get("absent_defaults")), _names(raw.get("generated"))
    if any(name.lower() in names for name in absent + generated):
        raise Malformed()  # a file cannot be both bound and deliberately absent/generated
    return {"consumer": {"platform": consumer.get("platform") if isinstance(consumer.get("platform"), str) else None, "setting": consumer["setting"]},
            "writable": raw.get("writable") is True, "files": files, "absent_defaults": absent, "generated": generated}


def read_input(store, workspace, input_id, sha256, want_text):
    """Verify a registered input's exact bytes. Returns (state, preview): state is 'verified',
    'missing', 'changed', 'unreadable' or 'not_verified_here' (larger than this page re-hashes;
    never shown as verified). A preview is only of verified bytes, at most 64 KiB."""
    record = (store.named(workspace).get("inputs") or {}).get(input_id)
    if not isinstance(record, dict):
        return "missing", None
    try:
        relative = base64.b64decode(record["path"]).decode("utf-8")
    except (KeyError, ValueError, TypeError):
        return "unreadable", None
    root = os.path.realpath(store.base / workspace)
    path = os.path.join(root, relative)
    if not os.path.realpath(os.path.dirname(path)).startswith(root + os.sep):
        return "unreadable", None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return "missing", None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return "unreadable", None
        if info.st_size > MAX_VERIFY:
            return "not_verified_here", None
        digest, head, size = hashlib.sha256(), b"", 0
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
            if len(head) < MAX_PREVIEW:
                head += chunk[:MAX_PREVIEW - len(head)]
            if size > MAX_VERIFY:
                return "not_verified_here", None
    except OSError:
        return "unreadable", None
    finally:
        os.close(fd)
    if digest.hexdigest() != sha256:
        return "changed", None
    if not want_text:
        return "verified", None
    truncated = size > len(head)
    if truncated:  # a bounded preview may end inside a UTF-8 sequence: drop only that tail
        for cut in range(4):
            try:
                text = head[:len(head) - cut].decode("utf-8")
                break
            except UnicodeDecodeError:
                continue
        else:
            return "verified", None
    else:
        try:
            text = head.decode("utf-8")
        except UnicodeDecodeError:
            return "verified", None  # bound by checksum; not shown as text
    return "verified", {"text": text, "truncated": truncated, "bytes": size}


def _textual(name):
    return (name or "").lower().endswith(TEXT_SUFFIXES)


def plan_view(store, workspace, body):
    """The intake/preparation projection of one plan body, with fail-closed readiness.

    Returns None for a plan that has neither field: it keeps the existing view, no readiness claim.
    """
    if "preparation" not in body and "run_inputs" not in body:
        return None
    blockers = []
    bindings = {entry.get("id"): entry for entry in body.get("input_binding") or [] if isinstance(entry, dict)}
    roles = body.get("roles") if isinstance(body.get("roles"), dict) else {}
    try:
        preparation = normalize_preparation(body["preparation"]) if "preparation" in body else None
    except Malformed:
        preparation = None
        blockers.append({"code": "PREPARATION_UNREADABLE", "text": "The plan's preparation details could not be read. Ask migration-data to propose it again."})
    try:
        manifest = normalize_run_inputs(body["run_inputs"]) if "run_inputs" in body else None
    except Malformed:
        manifest = None
        blockers.append({"code": "RUN_INPUTS_UNREADABLE", "text": "The plan's converter input manifest could not be read. Ask migration-data to propose it again."})
    selected = [(item["input_id"], item["sha256"], item["name"], "converter input", item["lineage"], item["reuse"]) for item in (manifest or {}).get("files", [])]
    if preparation and any(item.get("input") == "settings" for item in preparation["outcomes"]):
        settings = roles.get("settings")
        binding = bindings.get(settings) if isinstance(settings, str) else None
        # Prepared settings: shown by role, not by the private name whoever wrote them chose.
        selected.append((settings, (binding or {}).get("sha256"), None, "prepared settings", None, None))
    inputs = []
    for input_id, sha256, name, origin, lineage, reuse in selected:
        binding = bindings.get(input_id) if isinstance(input_id, str) else None
        entry = {"input_id": input_id, "name": name, "sha256": sha256, "origin": origin, "lineage": lineage, "reuse": reuse, "bytes": (binding or {}).get("bytes")}
        if not isinstance(binding, dict) or not isinstance(sha256, str) or binding.get("sha256") != sha256:
            entry["state"] = "not_bound"
        else:
            entry["state"], entry["preview"] = read_input(store, workspace, input_id, sha256, origin == "prepared settings" or _textual(name))
        if entry["state"] not in ("verified", "not_verified_here"):
            blockers.append({"code": "INPUT_" + entry["state"].upper(), "input_id": input_id,
                             "text": "A selected input is %s: %s." % ({"not_bound": "not bound to this plan", "missing": "missing",
                                                                       "changed": "changed since the plan", "unreadable": "unreadable"}[entry["state"]], name or origin)})
        inputs.append(entry)
    if preparation:
        bound_names = {item["name"] for item in (manifest or {}).get("files", [])}
        for question in preparation["questions"]:
            if question["status"] is None:
                blockers.append({"code": "QUESTION_UNRESOLVED", "text": "Needs your answer: " + question["text"]})
        for outcome in preparation["outcomes"]:
            target = outcome.get("input")
            if outcome["disposition"] == "prepared_input" and target != "settings" and target not in bound_names:
                blockers.append({"code": "INPUT_NOT_BOUND", "text": "A prepared input this plan names is not bound: " + target + "."})
            if outcome["disposition"] in ("setting",) or target == "settings":
                if not isinstance(roles.get("settings"), str):
                    blockers.append({"code": "INPUT_NOT_BOUND", "text": "This plan names settings but binds none."})
        readiness = preparation["code_readiness"]
        needs_code = any(item["disposition"] == "code" for item in preparation["outcomes"])
        if needs_code and not (readiness and readiness["present"]):
            blockers.append({"code": "CODE_MISSING", "text": "Required code is not present and pinned in this plan."})
    return {"preparation": preparation, "run_inputs": manifest, "inputs": inputs, "blockers": blockers, "ready": not blockers}


RUN_INPUTS_KEYS = {"version", "consumer", "source_sha256", "mount", "writable", "files", "absent_defaults", "generated"}
RUN_INPUT_FILE_KEYS = {"name", "input_id", "sha256", "bytes", "lineage", "reuse"}
PREPARATION_KEYS = {"version", "analyst", "references", "outcomes", "questions", "exclusions", "code_readiness"}


class NotRetainable(ValueError):
    """An earlier plan's bound choices cannot be carried into a new proposal exactly."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def reproposal_documents(body):
    """The data-tool request fields that carry an earlier plan's bound input manifest and
    preparation choices into a NEW proposal (never its approval, digest or run).

    Computed labels/code-readiness and mount/writable are recomputed. Exact
    file selections, explicit reuse and recorded lineage are retained for the
    backend to revalidate against current registry/job records. Unknown fields,
    malformed or unresolved entries raise NotRetainable, never silent omission."""
    request = {}
    if "run_inputs" in body:
        raw = body["run_inputs"]
        if not isinstance(raw, dict) or set(raw) - RUN_INPUTS_KEYS or not isinstance(raw.get("files"), list) \
                or any(not isinstance(item, dict) or set(item) - RUN_INPUT_FILE_KEYS for item in raw["files"]) \
                or not isinstance(raw.get("source_sha256"), str) or not SHA.fullmatch(raw["source_sha256"]):
            raise NotRetainable("STANDARD_RUN_INPUTS_INVALID")
        try:
            manifest = normalize_run_inputs(raw)
        except Malformed:
            raise NotRetainable("STANDARD_RUN_INPUTS_INVALID") from None
        consumer = {"setting": manifest["consumer"]["setting"]}
        if manifest["consumer"]["platform"]:
            consumer["platform"] = manifest["consumer"]["platform"]
        request["run_inputs"] = {"version": 1, "consumer": consumer, "source_sha256": raw["source_sha256"],
                                 # An explicit reuse is the engineer's selection of exact earlier-source bytes: carried, never dropped.
                                 "files": [dict({key: item[key] for key in ("name", "input_id", "sha256", "bytes")}, **({"reuse": item["reuse"]} if item["reuse"] else {}),
                                                **({"lineage": _bound_lineage(item["lineage"])} if item["lineage"] else {}))
                                           for item in manifest["files"]],
                                 "absent_defaults": manifest["absent_defaults"], "generated": manifest["generated"]}
    if "preparation" in body:
        raw = body["preparation"]
        if not isinstance(raw, dict) or set(raw) - PREPARATION_KEYS:
            raise NotRetainable("STANDARD_PREPARATION_INVALID")
        try:
            preparation = normalize_preparation(raw)
        except Malformed:
            raise NotRetainable("STANDARD_PREPARATION_INVALID") from None
        if any(question["status"] is None for question in preparation["questions"]):
            raise NotRetainable("STANDARD_PREPARATION_UNRESOLVED")
        request["preparation"] = {
            "version": 1, "analyst": {"text": preparation["analyst"]["text"]},
            # The adapter takes one identity key and fills the current sha256; the caller checks it is unchanged.
            "references": [{"file_id": ref["file_id"]} if "file_id" in ref else {"input_id": ref["input_id"]} for ref in preparation["references"]],
            "outcomes": [{key: item[key] for key in ("id", "requirement", "disposition", "input", "exclusion") if key in item} for item in preparation["outcomes"]],
            "questions": [{key: item[key] for key in ("id", "text", "status", "resolution", "exclusion") if key in item} for item in preparation["questions"]],
            "exclusions": [{key: item[key] for key in ("id", "text", "reason") if item.get(key) is not None} for item in preparation["exclusions"]],
        }
    return request, (preparation["references"] if "preparation" in body else [])


def _bound_lineage(lineage):
    """The lineage as the adapter derives it from the workspace's records (identity + sha256 only),
    so the engineer path can require that it is still exactly the same."""
    result = {}
    if lineage.get("references"):
        result["references"] = [{key: ref[key] for key in ("file_id", "input_id", "sha256") if key in ref} for ref in lineage["references"]]
    if lineage.get("preparation"):
        result["preparation"] = dict(lineage["preparation"])
    return result


def blockers_of(store, workspace, plan_id):
    """Approval guard: the readiness blockers of a stored plan ([] for a legacy plan)."""
    plan = store.plans(workspace).get(plan_id) or {}
    body = plan.get("body") if isinstance(plan.get("body"), dict) else {}
    view = plan_view(store, workspace, body)
    return view["blockers"] if view else []


def _cited(body):
    """Reference file IDs a plan body binds, with the exact sha256 cited: {file_id: {sha256, ...}}."""
    cited = {}
    entries = []
    preparation = body.get("preparation")
    if isinstance(preparation, dict) and isinstance(preparation.get("references"), list):
        entries += preparation["references"]
    run_inputs = body.get("run_inputs")
    if isinstance(run_inputs, dict) and isinstance(run_inputs.get("files"), list):
        for item in run_inputs["files"]:
            lineage = item.get("lineage") if isinstance(item, dict) else None
            if isinstance(lineage, dict) and isinstance(lineage.get("references"), list):
                entries += lineage["references"]
    for entry in entries:
        if isinstance(entry, dict) and isinstance(entry.get("file_id"), str) and FILE_ID.fullmatch(entry["file_id"]):
            cited.setdefault(entry["file_id"], set()).add(entry.get("sha256") if isinstance(entry.get("sha256"), str) else None)
    return cited


def reference_usage(store, workspace):
    """{file_id: {"plans": [...], "runs": [...], "status": ...}} from plan bodies and run records."""
    plans = store.plans(workspace)
    runs_by_plan = {}
    for run_id, run in store.runs(workspace).items():
        runs_by_plan.setdefault(run.get("plan_id"), []).append((run_id, run))
    usage = {}
    for plan_id, plan in plans.items():
        body = plan.get("body") if isinstance(plan.get("body"), dict) else {}
        for file_id, hashes in _cited(body).items():
            entry = usage.setdefault(file_id, {"plans": [], "runs": []})
            entry["plans"].append({"plan_id": plan_id, "status": plan.get("status"), "operation": body.get("operation"),
                                   "sha256": sorted(value for value in hashes if value), "created_at": plan.get("created_at")})
            for run_id, run in runs_by_plan.get(plan_id, []):
                entry["runs"].append({"run_id": run_id, "plan_id": plan_id, "status": run.get("status"), "finished_at": run.get("finished_at")})
    return usage


ACTIVE_RUNS = ("claimed", "running")


def reference_status(entry, sha256=None):
    """One derived label from plan and run records. A citation of different bytes is not
    counted as this file's use. Precedence: completed run > running run > plan waiting for
    review/Start > run that did not complete > plan never run."""
    if not entry:
        return "reference_only"
    plans = [plan for plan in entry["plans"] if isinstance(sha256, str) and sha256 in plan.get("sha256", [])]
    ids = {plan["plan_id"] for plan in plans}
    runs = [run for run in entry["runs"] if run["plan_id"] in ids]
    if any(run["status"] == "completed" for run in runs):
        return "used_by_completed_run"
    if any(run["status"] in ACTIVE_RUNS for run in runs):
        return "in_use"
    ran = {run["plan_id"] for run in runs}
    if any(plan["status"] in OPEN_STATUSES and plan["plan_id"] not in ran for plan in plans):
        return "cited_by_plan"
    if runs:
        return "run_not_completed"
    return "cited_earlier" if plans else "reference_only"


def annotate_references(store, workspace, files):
    """Add derived used_by/usage_status to each reference in a deliveries view. On any trouble
    reading plans, say so rather than imply the reference is unused."""
    roles = files.get("roles") if isinstance(files, dict) else None
    if not isinstance(roles, dict) or not isinstance(roles.get("references"), list):
        return files
    try:
        usage = reference_usage(store, workspace)
    except Exception:  # noqa: BLE001 - unreadable plans: unknown, not "unused"
        usage = None
    references = []
    for ref in roles["references"]:
        if not isinstance(ref, dict):
            continue
        if usage is None:
            references.append(dict(ref, usage_status="unknown", used_by=None))
            continue
        entry = usage.get(ref.get("id"))
        references.append(dict(ref, usage_status=reference_status(entry, ref.get("sha256")), used_by=entry or {"plans": [], "runs": []}))
    return dict(files, roles=dict(roles, references=references))
