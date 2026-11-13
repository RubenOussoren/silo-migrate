#!/usr/bin/env -S python3 -I
"""Project page: one project at a glance, its files, findings, runs and converter pushes.

Reached only through term-llm's signed-in proxy, by the engineer. It shows file names, so it never
serves an agent. The decisions are the Findings and Runs modules' own, called unchanged (their
server.py files stay as libraries): exact-digest approvals, exact-text releases, the same refusals.
Workspace creation, labels and the guide go through `silo-migrate-control data WS`, in bin/data_tools.py.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import socketserver
import stat
import sys
import time
from urllib.parse import parse_qs, urlsplit
from http.server import BaseHTTPRequestHandler

HERE = Path(__file__).resolve().parent


def _load(name, folder):
    spec = importlib.util.spec_from_file_location(name, HERE.parent / folder / "server.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runs = _load("silo_runs_widget", "runs")
findings = _load("silo_findings_widget", "findings")
_board_spec = importlib.util.spec_from_file_location("silo_project_board", HERE / "board.py")
board = importlib.util.module_from_spec(_board_spec)
_board_spec.loader.exec_module(board)
_intake_spec = importlib.util.spec_from_file_location("silo_project_intake", HERE / "intake.py")
intake = importlib.util.module_from_spec(_intake_spec)
_intake_spec.loader.exec_module(intake)
RUN = re.compile(r"run-[0-9a-f]{32}\Z")
FINDING = re.compile(r"finding-[0-9a-f]{32}\Z")

Refused = runs.Refused
REFUSALS = (runs.Refused, findings.Refused)
WORKSPACE = runs.WORKSPACE
DATASET = re.compile(r"dataset-[0-9a-f]{32}\Z")
MAX_BODY = 128 * 1024  # a label lists the files it covers
MAX_FINDING_BODY = findings.MAX_TEXT * 7  # JSON can escape each byte of a finding's text up to 6 bytes
RUN_ACTIONS = ("approve", "discard", "start", "recover", "admin-password", "reset", "push", "discard-push")
FINDING_ACTIONS = ("release", "amend", "reject", "withdraw")
RUN_PATHS = {"/api/runs/" + action for action in RUN_ACTIONS}
FINDING_PATHS = {"/api/findings/" + action for action in FINDING_ACTIONS}
RUN_VIEWS = {"plan": runs.plan_detail, "run": runs.run_detail, "push": runs.push_detail}
MAX_FILES = 400
PLATFORM = re.compile(r"[a-z][a-z0-9_.-]{0,31}\Z")  # as bin/data_tools.py
FILE_ID = re.compile(r"file-[0-9a-f]{16,64}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
FILE_CHANGE_KEYS = {"action", "role", "kind", "dataset_id", "restore_dataset_id", "reason", "confirm", "files", "file_ids"}
STATIC = {"/": ("index.html", "text/html; charset=utf-8"), "/app.js": ("app.js", "text/javascript; charset=utf-8"),
          "/ui.js": ("ui.js", "text/javascript; charset=utf-8"), "/lists.js": ("lists.js", "text/javascript; charset=utf-8"),
          "/runs.js": ("runs.js", "text/javascript; charset=utf-8"),
          "/files.js": ("files.js", "text/javascript; charset=utf-8"),
          "/findings.js": ("findings.js", "text/javascript; charset=utf-8"),
          "/intake.js": ("intake.js", "text/javascript; charset=utf-8"),
          "/app.css": ("app.css", "text/css; charset=utf-8"), "/tokens.css": ("tokens.css", "text/css; charset=utf-8")}
# Varnish's own font files, so that the page matches without a second copy of them.
FONTS = {"/fonts/Geist-Variable.woff2": "Geist-Variable.woff2", "/fonts/GeistMono-Variable.woff2": "GeistMono-Variable.woff2"}
HEADERS = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
           "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"}


def data(control, workspace, request, timeout=90):
    if not isinstance(workspace, str) or not WORKSPACE.fullmatch(workspace):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    return runs.control_call(control, ["data", workspace], timeout=timeout, send=json.dumps(request).encode("utf-8"))


def intake_folder(control, base):
    """Where `silo intake` puts drop folders: beside the installed control shim, as data_tools works it out."""
    shim = Path(control)
    if shim.name == "silo-migrate-control" and shim.parent.name == "bin" and (shim.parent.parent / "intake").is_dir():
        return shim.parent.parent / "intake"
    return base.parent / "intake"


def project_names(base, intake):
    """Every project with a workspace or a drop folder (a new project has only the drop folder)."""
    names = set()
    for folder in (base, intake):
        try:
            with os.scandir(folder) as entries:
                names |= {entry.name for entry in entries if WORKSPACE.fullmatch(entry.name) and entry.is_dir(follow_symlinks=False)}
        except OSError:
            continue
    return sorted(names)


def counts(base, workspace):
    """What waits on the engineer in one project's Findings and Runs, read straight from disk."""
    if not isinstance(workspace, str) or not WORKSPACE.fullmatch(workspace):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    try:
        items, _running = runs.waiting(runs.Store(base), workspace)
        waiting_runs = len(items)
    except REFUSALS:
        waiting_runs = 0
    try:
        to_review = sum(1 for record in findings.Store(base).records(workspace) if record["status"] == "proposed")
    except REFUSALS:
        to_review = 0
    return {"findings": to_review, "runs": waiting_runs}


def read_json_file(path):
    try:
        value = json.loads(runs.read_file(path, runs.MAX_STATE))
    except (OSError, ValueError, Refused):
        return {}
    return value if isinstance(value, dict) else {}


def passes_of(base, control, workspace):
    """The Runs tab: passes, converter updates and what's new, from the workbench's own views."""
    store = runs.Store(base)
    view = runs.overview(store, control, workspace)
    bodies = {plan_id: (plan.get("body") or {}) for plan_id, plan in store.plans(workspace).items()}
    instances = store.state(workspace).get("instances") or {}
    review_sites, recorded = {}, {}
    for run_id, run in store.runs(workspace).items():
        record = instances.get(((run.get("instances") or {}).get("review"))) if isinstance(run.get("instances"), dict) else None
        review_sites[run_id] = isinstance(record, dict) and record.get("state") != "removed"
        recorded[run_id] = board.run_environment(run)
    for run in view["runs"]:
        # A prepared environment's phase as the host recorded it, if the status view leaves it out.
        if isinstance(run, dict) and not board.run_environment(run) and recorded.get(run.get("run_id")):
            run["merge_environment"] = recorded[run.get("run_id")]
    named = base / workspace / ".silo-migrate/named"
    deliveries = read_json_file(named / "deliveries.json").get("deliveries") or {}
    reviews = read_json_file(named / "site-reviews.json").get("reviews") or []
    active = None
    role_path = named.parent / "data/file-roles.json"
    if role_path.exists() or role_path.is_symlink():
        # Use the host's checked projection, not an unchecked metadata read or a
        # fallback to the newest label if effective assignments are unreadable.
        file_view = data(control, workspace, {"op": "deliveries"}, timeout=30)
        active = (file_view.get("roles") or {}).get("active")
        if not isinstance(active, dict):
            raise Refused("STANDARD_FILE_ROLES_INVALID", 409)
    result = board.build_passes(view["plans"], view["runs"], bodies, review_sites, store.pushes(workspace), deliveries if isinstance(deliveries, dict) else {},
                                reviews if isinstance(reviews, list) else [], active=active)
    return dict(result, converter=view.get("converter"))


def site_review(control, body):
    """Accept a review site, say it needs changes, or withdraw an acceptance: only these fields pass,
    with the server's reviewer name. An acceptance carries the digest of the process the page showed."""
    verdict = body.get("verdict")
    request = {"op": "site_review", "verdict": verdict, "by": runs.reviewer_name()}
    if verdict == "withdrawn":
        if not isinstance(body.get("review_id"), str) or not re.fullmatch(r"review-[0-9a-f]{16}", body["review_id"]):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        request["review_id"] = body["review_id"]
    elif verdict in ("accepted", "needs_changes"):
        if not isinstance(body.get("run_id"), str) or not RUN.fullmatch(body["run_id"]):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        request["run_id"] = body["run_id"]
        if isinstance(body.get("note"), str):
            request["note"] = body["note"]
        if verdict == "accepted":
            if body.get("basis") not in ("customer", "engineer") or not isinstance(body.get("process_digest"), str) or not re.fullmatch(r"[0-9a-f]{64}", body["process_digest"]):
                raise Refused("STANDARD_ARGUMENTS_INVALID")
            request.update(basis=body["basis"], process_digest=body["process_digest"])
    else:
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    return data(control, body.get("workspace"), request)


def findings_board(base, control, workspace, passes=None):
    store = findings.Store(base)
    records = [dict(record, title=store.title(record)) for record in store.records(workspace)]
    if passes is None:
        try:
            passes = passes_of(base, control, workspace)
        except REFUSALS:
            passes = {"passes": [], "updates": []}
    marks = read_json_file(base / workspace / ".silo-migrate/named/finding-progress.json").get("done") or {}
    return board.build_findings(records, passes["passes"], passes["updates"], marks if isinstance(marks, dict) else {})


def propose_again(base, control, body, import_next=False):
    """A fresh proposal with a finished run's own inputs (still for the engineer to approve), or the
    import of a finished convert run with the checks its pass last used."""
    workspace, run_id = body.get("workspace"), body.get("run_id")
    if not isinstance(run_id, str) or not RUN.fullmatch(run_id):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    store = runs.Store(base)
    run = store.runs(workspace).get(run_id)
    plans = store.plans(workspace)
    plan_body = ((plans.get((run or {}).get("plan_id")) or {}).get("body") or {})
    roles = plan_body.get("roles") or {}
    operation = plan_body.get("operation")
    if import_next:
        if operation != "standard_convert":
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        # The checks of this pass's last import, else of the project's last import (they carry the site
        # queries), else the convert run's own.
        kind = (plan_body.get("delivery") or {}).get("kind")
        ran = {other.get("plan_id") for other in store.runs(workspace).values() if other.get("status") == "completed"}
        reviews = sorted((plan for plan_id, plan in plans.items() if (plan.get("body") or {}).get("operation") == "standard_review"
                          and plan_id in ran and ((plan.get("body") or {}).get("delivery") or {}).get("kind") == kind),
                         key=lambda plan: plan.get("created_at") or "")
        here = [plan for plan in reviews if ((plan.get("body") or {}).get("from_run") or {}).get("run_id") == run_id]
        chosen = (here or reviews)[-1:]
        checks = ((chosen[0].get("body") or {}).get("roles") or {}).get("reconciliation") if chosen else roles.get("reconciliation")
        request = {"op": "plan_propose", "from_run": run_id}
    elif operation == "standard_convert":
        checks = roles.get("reconciliation")
        request = {"op": "plan_propose", "source": roles.get("source"), "settings": roles.get("settings"), "charset": plan_body.get("source_charset")}
    elif operation == "standard_review":
        checks = roles.get("reconciliation")
        request = {"op": "plan_propose", "from_run": (plan_body.get("from_run") or {}).get("run_id")}
    elif operation == "standard_merge":
        # The same source backup, settings and options; the current Base site and the merge layer as committed now.
        checks = None
        options = ((plan_body.get("merge") or {}).get("options") or {})
        request = {"op": "merge_propose", "source": roles.get("source"),
                   **{key: options[key] for key in ("ignore_global_pins", "separate_same_named_groups") if isinstance(options.get(key), bool)}}
        if roles.get("settings"):
            request["settings"] = roles["settings"]
        if plan_body.get("prepared_from") is not None:
            # Continue in the same prepared environment only while it is still exactly that one:
            # never silently fall back to a fresh restore or to another generation.
            bound = current_environment(store, workspace, plan_body)
            intent = plan_body.get("intent", (plan_body.get("merge") or {}).get("intent"))
            if intent not in board.INTENTS:
                raise Refused("STANDARD_MERGE_ENVIRONMENT_INVALID: the earlier merge's stock/custom intent is not recorded; ask migration-data to propose it", 409)
            request.update(prepared_from=bound["run_id"], generation=bound["generation"], intent=intent)
            if not isinstance(request.get("source"), str):
                request.pop("source")  # the preparation binds its own source; an explicit one is only rechecked
    elif operation == board.PREPARE_OPERATION:
        # Prepare again: the same source backup on the project's current Base site, as a new
        # proposal (and a new generation) for a new approval. No layer, settings or mapping inputs.
        checks = None
        request = {"op": "merge_prepare", "source": roles.get("source")}
    else:
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    if checks:
        request["reconciliation"] = checks
    if not import_next and operation in ("standard_convert", "standard_merge"):
        # The same bound converter inputs and the engineer's recorded answers/exclusions, as a NEW
        # proposal for a new approval. Never silently dropped: refused if they can't be carried.
        request.update(retained_choices(control, store, workspace, plan_body))
    # Proposing may prepare the converter's gems first: data_tools allows itself up to 290 s.
    return data(control, workspace, request, timeout=300)


STALE_ENVIRONMENT = ("STANDARD_MERGE_ENVIRONMENT_STALE: the prepared merge environment this merge used is no longer ready"
                     " at that generation; prepare it again and ask migration-data to propose the merge")


def current_environment(store, workspace, plan_body):
    """{run_id, generation} if that prepared environment is still ready at exactly that generation and
    not consumed (the host's recorded phase); otherwise refused. The host checks again when the plan
    is proposed and when it runs: this only keeps the page from proposing a merge bound to a gone one."""
    bound = board.body_prepared_from(plan_body)
    if not bound:
        raise Refused("STANDARD_MERGE_ENVIRONMENT_INVALID", 409)
    run = store.runs(workspace).get(bound["run_id"]) or {}
    plan = store.plans(workspace).get(run.get("plan_id")) or {}
    env = board.run_environment(run)
    if ((plan.get("body") or {}).get("operation") != board.PREPARE_OPERATION or run.get("status") != "completed" or not env
            or env.get("preparation_run_id") not in (None, bound["run_id"]) or env.get("generation") != bound["generation"]
            or env.get("phase") not in board.LIVE_PHASES):
        raise Refused(STALE_ENVIRONMENT, 409)
    return bound


def retained_choices(control, store, workspace, plan_body):
    try:
        documents, references = intake.reproposal_documents(plan_body)
    except intake.NotRetainable as error:
        raise Refused(error.code + ": the earlier plan's inputs or choices cannot be carried over exactly; ask migration-data to propose again", 409)
    if references:
        # A cited reference must still be the same registered bytes.
        current = {ref.get("id"): ref.get("sha256") for ref in ((data(control, workspace, {"op": "deliveries"}, timeout=30).get("roles") or {}).get("references") or [])
                   if isinstance(ref, dict)}
        inputs = store.named(workspace).get("inputs") or {}
        for ref in references:
            now = current.get(ref["file_id"]) if "file_id" in ref else (inputs.get(ref["input_id"]) or {}).get("sha256")
            if now != ref["sha256"]:
                raise Refused("STANDARD_PREPARATION_INVALID: a cited reference changed or is no longer a supporting reference; ask migration-data to propose again", 409)
    return documents


SUMMARY_SECONDS = 20
_summary = {"at": 0.0, "value": None}


def summary(base, control):
    """For the edge tab: what waits on the engineer in each project (labels, findings, runs). Cached
    briefly: every open chat page asks for it."""
    if _summary["value"] is not None and time.monotonic() - _summary["at"] < SUMMARY_SECONDS:
        return _summary["value"]
    waiting = []
    for name in project_names(base, intake_folder(control, base)):
        try:
            view = data(control, name, {"op": "deliveries"}, timeout=20)
            count = len(view["unlabelled_files"]) + len(view["unlabelled_data"]) + len(view.get("not_ready_files") or [])
        except Exception:  # noqa: BLE001 - one project's trouble mustn't hide the others
            count = 0
        try:
            count += sum(counts(base, name).values())
        except Exception:  # noqa: BLE001
            pass
        if count:
            waiting.append({"workspace": name, "files": count})
    _summary.update(at=time.monotonic(), value={"waiting": len(waiting), "latest": waiting[:8]})
    return _summary["value"]


def label(control, body):
    request = {"op": "delivery_label", "kind": body.get("kind"), "by": runs.reviewer_name()}
    if "dataset_id" in body:
        if not isinstance(body["dataset_id"], str) or not DATASET.fullmatch(body["dataset_id"]):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        request["dataset_id"] = body["dataset_id"]
    else:
        files = body.get("files")
        if not isinstance(files, list) or not 0 < len(files) <= MAX_FILES or not all(isinstance(item, dict) for item in files):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        # What identifies each file, as the page was shown it: data_tools checks it's still the same.
        request["files"] = [{key: item.get(key) for key in ("path", "bytes", "mtime_ns", "ctime_ns", "ino")} for item in files]
    if body.get("confirm") == "LAUNCH":
        request["confirm"] = "LAUNCH"
    if body.get("replaces_launch") is True:
        request["replaces_launch"] = True
    return data(control, body.get("workspace"), request, timeout=3600 if request["kind"] == "base_site" else 90)


def file_change(body):
    """Allowlist the engineer's intent, not arbitrary data-tool operations or paths.

    Identity, role compatibility, project membership and dependency checks are
    repeated by the host operation under its locks. Preview is never approval.
    """
    raw = body.get("change")
    if not isinstance(raw, dict):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    change = {key: value for key, value in raw.items() if key in FILE_CHANGE_KEYS}
    action = change.get("action")
    if action not in ("classify", "correct", "activate"):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    if action != "activate" and change.get("role") not in ("source", "uploads", "reference", "base_site", "unassigned"):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    if "kind" in change and change["kind"] not in ("development", "launch"):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    for key in ("dataset_id", "restore_dataset_id"):
        if key in change and (not isinstance(change[key], str) or not DATASET.fullmatch(change[key])):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
    if (action == "activate" or change.get("role") == "uploads") and not change.get("dataset_id"):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    if "confirm" in change and change["confirm"] != "LAUNCH":
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    reason = change.get("reason", "")
    if (not isinstance(reason, str) or len(reason) > 2000
            or re.search(r"[\x00-\x08\x0b-\x1f\x7f]", reason)
            or (action in ("correct", "activate") and not reason.strip())):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    if action == "classify":
        files = change.get("files")
        if (not isinstance(files, list) or not 0 < len(files) <= MAX_FILES
                or "file_ids" in change or not all(isinstance(item, dict) for item in files)):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        clean, paths = [], set()
        for item in files:
            path = item.get("path")
            if (not isinstance(path, str) or not path or len(path.encode("utf-8")) > 1024
                    or path.startswith("/") or any(part in ("", ".", "..") for part in path.split("/"))
                    or re.search(r"[\x00-\x1f\x7f]", path) or path in paths
                    or type(item.get("bytes")) is not int or not 0 <= item["bytes"] < 2**63
                    or any(not isinstance(item.get(key), str) or not re.fullmatch(r"[0-9]{1,24}", item[key])
                           for key in ("mtime_ns", "ctime_ns", "ino"))):
                raise Refused("STANDARD_ARGUMENTS_INVALID")
            paths.add(path)
            clean.append({key: item[key] for key in ("path", "bytes", "mtime_ns", "ctime_ns", "ino")})
        change["files"] = clean
    elif action == "correct":
        ids = change.get("file_ids")
        if (not isinstance(ids, list) or not 0 < len(ids) <= MAX_FILES or "files" in change
                or not all(isinstance(identity, str) and FILE_ID.fullmatch(identity) for identity in ids)
                or len(set(ids)) != len(ids)):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
    elif "files" in change or "file_ids" in change:
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    return change


def change_files(control, body, commit=False):
    request = {"op": "file_roles_commit" if commit else "file_roles_preview",
               "change": file_change(body), "by": runs.reviewer_name()}
    if commit:
        digest = body.get("digest")
        if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        request["digest"] = digest
    # Both stages may checksum a large original; the ordinary chat-tool timeout
    # does not apply to these engineer-only, explicitly requested decisions.
    return data(control, body.get("workspace"), request, timeout=3600)


def create_workspace(control, body):
    """The Files tab's Create workspace: the operation migration-data's data_create calls, with only
    the platform passed on (the converter repository and branch stay the defaults)."""
    platform = body.get("platform")
    if not isinstance(platform, str) or not PLATFORM.fullmatch(platform):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    # Cloning discourse-converters is most of the time: data_tools allows the clone 240 s.
    return data(control, body.get("workspace"), {"op": "create", "platform": platform, "by": runs.reviewer_name()}, timeout=300)


def release_backup(control, body):
    workspace, run_id = body.get("workspace"), body.get("run_id")
    acknowledge = body.get("acknowledge", False)
    if (not isinstance(workspace, str) or not WORKSPACE.fullmatch(workspace)
            or not isinstance(run_id, str) or not RUN.fullmatch(run_id) or not isinstance(acknowledge, bool)):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    argv = ["standard", "run", "release", workspace, run_id, "--reviewer", runs.reviewer_name()]
    if acknowledge:
        argv.append("--acknowledge-differences")
    return runs.control_call(control, argv, timeout=3600)


def files_view(base, control, workspace):
    """The Files view, with each reference's "Used by" derived from plan/run provenance."""
    view = data(control, workspace, {"op": "deliveries"}, timeout=30)
    if not view.get("initialized"):
        return view
    store = runs.Store(base)
    try:
        store.root(workspace)
    except REFUSALS:
        standard = base / workspace / ".silo-migrate/named/standard"
        # No workbench folder at all: no plan can cite anything. Anything odd: unknown, never "unused".
        absent = not standard.exists() and not standard.is_symlink()
        return _usage_without_store(view, "reference_only" if absent else "unknown")
    return intake.annotate_references(store, workspace, view)


def _usage_without_store(view, status):
    roles = view.get("roles")
    if not isinstance(roles, dict) or not isinstance(roles.get("references"), list):
        return view
    used = {"plans": [], "runs": []} if status == "reference_only" else None
    return dict(view, roles=dict(roles, references=[dict(ref, usage_status=status, used_by=used)
                                                    for ref in roles["references"] if isinstance(ref, dict)]))


def guarded(store, control, action, body):
    """The existing exact-digest approval and Start, refused while the plan's own preparation is
    not ready (an unanswered material question, missing code, an unbound/changed/unreadable
    selected input). Plans without preparation or run inputs pass through unchanged."""
    workspace, plan_id = body.get("workspace"), body.get("plan_id")
    if isinstance(plan_id, str) and runs.PLAN.fullmatch(plan_id):
        store.root(workspace)
        if intake.blockers_of(store, workspace, plan_id):
            raise Refused("STANDARD_PLAN_NOT_READY", 409)
    return runs.decide(store, control, action, body)


def plan_detail(store, control, workspace, plan_id):
    result = runs.plan_detail(store, control, workspace, plan_id)
    plan = (store.plans(workspace).get(plan_id) or {}) if store is not None else {}
    body = plan.get("body") if isinstance(plan.get("body"), dict) else {}
    result["intake"] = intake.plan_view(store, workspace, body) if store is not None else None
    # Base-site plans name the delivery/version, never the original backup file; nor does a merge
    # plan name its source site's backup (a Discourse backup's name starts with the site's name)
    # or its settings file (named by whoever wrote it). The settings' content is still shown.
    roles = result.get("roles") or {}
    operation = result.get("operation") or body.get("operation")
    # Preparing a merge environment uses the same two backups: neither is named either.
    merge = operation in ("standard_merge", board.PREPARE_OPERATION)
    hidden = {roles.get("base_site"), roles.get("source") if merge else None, roles.get("settings") if merge else None} - {None}
    if hidden:
        result["input_paths"] = {key: value for key, value in (result.get("input_paths") or {}).items() if key not in hidden}
    return environment_view(result, operation, body)


# What a host record might carry about inspection access: only the safe projection is ever shown.
RAW_ENVIRONMENT_KEYS = ("merge_environment", "prepared_from", "inspection", "connectors", "connector", "mcp", "dbhub", "endpoints", "profile", "profiles")


def environment_view(result, operation, body, run=None):
    """Replace any raw environment/connector fields with the safe projection: preparation run,
    generation, phase, fixed endpoint kind/name/readiness and (on a merge) the bound prepared_from."""
    env = board.merge_environment(result.get("merge_environment")) or board.run_environment(result) \
        or board.merge_environment(body.get("merge_environment")) or (board.run_environment(run) if run else None)
    bound = board.prepared_from(result["prepared_from"], result.get("generation")) if result.get("prepared_from") is not None \
        else board.body_prepared_from(body)
    for key in RAW_ENVIRONMENT_KEYS:
        result.pop(key, None)
    if isinstance(result.get("results"), dict):
        result["results"] = {key: value for key, value in result["results"].items() if key not in RAW_ENVIRONMENT_KEYS}
    if operation == board.PREPARE_OPERATION:
        if env and run is not None and env.get("preparation_run_id") not in (None, result.get("run_id")):
            env = None  # another run's environment is never shown as this one's
        # No migration happened: no output backup, release or ordinary review sign-in to offer.
        result.update(release=None)
        if isinstance(result.get("artifacts"), dict):
            result["artifacts"] = {key: value for key, value in result["artifacts"].items() if key != "backup"}
        if isinstance(result.get("results"), dict):
            result["results"].pop("review_url", None)
    if env:
        result["merge_environment"] = env
    if bound and operation == "standard_merge":
        result["prepared_from"] = bound
    return result


def run_detail(store, control, workspace, run_id):
    result = runs.run_detail(store, control, workspace, run_id)
    plan = store.plans(workspace).get(result.get("plan_id")) or {}
    body = plan.get("body") if isinstance(plan.get("body"), dict) else {}
    operation = result.get("operation") or body.get("operation")
    return environment_view(dict(result, base_site=body.get("base_site")), operation, body, run=store.runs(workspace).get(run_id) or {})


def no_prepared_sign_in(store, body):
    """The page never asks for an ordinary review sign-in on a prepared (not yet merged) environment."""
    try:
        run = store.runs(body.get("workspace")).get(body.get("run_id")) or {}
        operation = ((store.plans(body.get("workspace")).get(run.get("plan_id")) or {}).get("body") or {}).get("operation")
    except REFUSALS:
        return  # the unchanged decision refuses what it cannot find
    if operation == board.PREPARE_OPERATION:
        raise Refused("STANDARD_PREPARED_ENVIRONMENT_NO_SIGN_IN", 409)


RUN_VIEWS["plan"] = plan_detail
RUN_VIEWS["run"] = run_detail


def removal_plan(control, workspace, keep):
    """What Start over or Remove would do; changes nothing (bin/project_remove.py)."""
    if not isinstance(workspace, str) or not WORKSPACE.fullmatch(workspace):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    return runs.control_call(control, ["remove-project", workspace, "--plan", *(["--keep-received"] if keep else [])], timeout=600)


def remove(control, body):
    """Start over or Remove, once the engineer has typed the project's name; the same command as
    `silo remove-project`, which checks the name again and refuses while anything is busy."""
    workspace, typed, keep = body.get("workspace"), body.get("confirm"), body.get("keep_received")
    if not isinstance(workspace, str) or not WORKSPACE.fullmatch(workspace) or not isinstance(keep, bool):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    if typed != workspace:
        raise Refused("STANDARD_CONFIRMATION_REQUIRED")
    _summary["value"] = None
    return runs.control_call(control, ["remove-project", workspace, "--confirm", typed, *(["--keep-received"] if keep else []),
                                       "--by", runs.reviewer_name()], timeout=3600)


class Handler(BaseHTTPRequestHandler):
    server_version = "silo-project"
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, status, body, content_type="application/json"):
        payload = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        for key, value in HEADERS.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        url = urlsplit(self.path)
        query = {key: value[0] for key, value in parse_qs(url.query).items()}
        control, base = self.server.control, self.server.base
        try:
            if url.path in STATIC:
                name, content_type = STATIC[url.path]
                return self.send(200, (HERE / name).read_bytes(), content_type)
            if url.path in FONTS:
                return self.send(200, (HERE.parent.parent / "extensions/varnish/fonts" / FONTS[url.path]).read_bytes(), "font/woff2")
            if url.path == "/api/projects":
                return self.send(200, {"projects": project_names(base, intake_folder(control, base))})
            if url.path == "/api/summary":
                return self.send(200, summary(base, control))
            if url.path == "/api/files":  # quick: reads only files (and plan bodies for derived "Used by")
                return self.send(200, files_view(base, control, query.get("workspace")))
            if url.path == "/api/guide":
                return self.send(200, data(control, query.get("workspace"), {"op": "guide"}))
            if url.path == "/api/counts":
                return self.send(200, counts(base, query.get("workspace")))
            if url.path == "/api/site/process":
                run_id = query.get("id")
                if not isinstance(run_id, str) or not RUN.fullmatch(run_id):
                    raise Refused("STANDARD_ARGUMENTS_INVALID")
                return self.send(200, data(control, query.get("workspace"), {"op": "site_process", "run_id": run_id}))
            if url.path == "/api/project/removal":
                return self.send(200, removal_plan(control, query.get("workspace"), query.get("keep") == "1"))
            if url.path == "/api/boards":
                workspace = query.get("workspace")
                if not isinstance(workspace, str) or not WORKSPACE.fullmatch(workspace):
                    raise Refused("STANDARD_ARGUMENTS_INVALID")
                try:
                    passes = passes_of(base, control, workspace)
                except REFUSALS as refused:
                    # Findings remain reviewable when run status is unavailable, as on their own route.
                    passes = {"passes": [], "updates": [], "error": refused.code}
                return self.send(200, {"runs": passes, "findings": findings_board(base, control, workspace, passes)})
            if url.path == "/api/runs/passes":
                return self.send(200, passes_of(base, control, query.get("workspace")))
            if url.path == "/api/findings/board":
                return self.send(200, findings_board(base, control, query.get("workspace")))
            if url.path == "/api/runs/overview":
                return self.send(200, runs.overview(runs.Store(base), control, query.get("workspace")))
            if url.path == "/api/runs/converter":
                return self.send(200, runs.converter_detail(runs.Store(base), control, query.get("workspace")))
            view = RUN_VIEWS.get(url.path.removeprefix("/api/runs/")) if url.path.startswith("/api/runs/") else None
            if view is runs.push_detail:
                return self.send(200, view(runs.Store(base), query.get("workspace"), query.get("id")))
            if view:
                return self.send(200, view(runs.Store(base), control, query.get("workspace"), query.get("id")))
            if url.path in ("/api/findings/list", "/api/findings/finding"):
                workspace = query.get("workspace")
                if not isinstance(workspace, str) or not WORKSPACE.fullmatch(workspace):  # one project only, never all
                    raise Refused("STANDARD_ARGUMENTS_INVALID")
                store = findings.Store(base)
                if url.path.endswith("/list"):
                    return self.send(200, findings.page_of(store, query))
                return self.send(200, findings.detail(store, workspace, query.get("id")))
            return self.send(404, {"error": "STANDARD_NOT_FOUND"})
        except REFUSALS as refused:
            return self.send(refused.status, {"error": refused.code})
        except Exception:  # noqa: BLE001 - never a traceback in term-llm's log
            return self.send(500, {"error": "STANDARD_OPERATION_FAILED"})

    def do_POST(self):
        # term-llm only forwards same-origin, signed-in POSTs; the custom header and JSON body
        # are a second check that the request came from this page's script.
        try:
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            path = urlsplit(self.path).path
            limit = MAX_FINDING_BODY if path.startswith("/api/findings/") else runs.MAX_BODY if path.startswith("/api/runs/") else MAX_BODY
            if not 0 < length <= limit:
                self.close_connection = True
                raise Refused("STANDARD_ARGUMENTS_INVALID", 413 if length > 0 else 400)
            raw = self.rfile.read(length)
            if self.headers.get("X-Silo-Project") != "1" or not (self.headers.get("Content-Type") or "").startswith("application/json"):
                raise Refused("STANDARD_REQUEST_REFUSED", 403)
            body = json.loads(raw)
            if not isinstance(body, dict):
                raise Refused("STANDARD_ARGUMENTS_INVALID")
            action = path.rsplit("/", 1)[-1]
            if path == "/api/label":
                result = label(self.server.control, body)
            elif path in ("/api/files/preview", "/api/files/commit"):
                result = change_files(self.server.control, body, commit=path.endswith("/commit"))
            elif path == "/api/workspace/create":
                result = create_workspace(self.server.control, body)
            elif path == "/api/project/remove":
                result = remove(self.server.control, body)
            elif path == "/api/site/review":
                result = site_review(self.server.control, body)
            elif path in ("/api/runs/again", "/api/runs/import"):
                result = propose_again(self.server.base, self.server.control, body, import_next=path.endswith("/import"))
            elif path == "/api/findings/done":
                finding_id = body.get("id")
                if not isinstance(finding_id, str) or not FINDING.fullmatch(finding_id):
                    raise Refused("STANDARD_ARGUMENTS_INVALID")
                request = {"op": "finding_done", "finding_id": finding_id, "by": runs.reviewer_name()}
                if body.get("undo") is True:
                    request["undo"] = True
                result = data(self.server.control, body.get("workspace"), request)
            elif path == "/api/runs/release":
                result = release_backup(self.server.control, body)
            elif path in ("/api/runs/approve", "/api/runs/start"):
                result = guarded(runs.Store(self.server.base), self.server.control, action, body)
            elif path in RUN_PATHS:
                if action == "admin-password" and isinstance(body.get("run_id"), str) and RUN.fullmatch(body["run_id"]):
                    no_prepared_sign_in(runs.Store(self.server.base), body)
                result = runs.decide(runs.Store(self.server.base), self.server.control, action, body)
            elif path in FINDING_PATHS:
                result = findings.decide(self.server.control, action, body.get("workspace"), body.get("id"), body.get("text"))
            else:
                raise Refused("STANDARD_ARGUMENTS_INVALID")
            _summary["value"] = None  # the tab's count may have changed
            return self.send(200, result)
        except (ValueError, UnicodeDecodeError):
            return self.send(400, {"error": "STANDARD_ARGUMENTS_INVALID"})
        except REFUSALS as refused:
            return self.send(refused.status, {"error": refused.code})
        except Exception:  # noqa: BLE001
            return self.send(500, {"error": "STANDARD_OPERATION_FAILED"})


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def get_request(self):
        request, _address = super().get_request()
        return request, ("local", 0)  # http.server expects a (host, port) pair


def main(argv):
    if len(argv) != 2 or not argv[1].startswith("/"):
        raise SystemExit("usage: server.py SOCKET")
    control, base = runs.locate()
    # As the Runs module always did: the socket folder must be ours and private.
    folder = os.lstat(os.path.dirname(argv[1]))
    if not stat.S_ISDIR(folder.st_mode) or folder.st_uid != os.geteuid() or folder.st_mode & 0o077:
        raise SystemExit("project widget: " + os.path.dirname(argv[1]) + " must be a folder owned by this account, mode 0700")
    os.umask(0o077)
    try:
        os.unlink(argv[1])
    except FileNotFoundError:
        pass
    server = Server(argv[1], Handler)
    server.control, server.base = control, base
    server.serve_forever()


if __name__ == "__main__":
    main(sys.argv)
