"""Passes and the findings track for the Project page, worked out from what the workbench stores.

Pure functions over plain data, so they're easy to test. A pass is one convert run with the imports
made from it, or (in a merge project) one merge run; converter updates are the pushes; a finding moves
from released to fixed to checked as the pushes that name it are pushed and a later pass passes.
"""

from datetime import datetime, timezone
import re

ACTIVE = ("claimed", "running")
_EARLIEST = datetime.min.replace(tzinfo=timezone.utc)


def _t(value):
    """An ISO time as a comparable instant, whatever its format (Z or +00:00, fractions, offsets)."""
    if not isinstance(value, str) or not value:
        return _EARLIEST
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return _EARLIEST
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
WAITING = ("proposed", "approved")


def _short(value, n=7):
    return value[:n] if isinstance(value, str) else None


def _passed(step):
    return bool(step) and step.get("run_status") == "completed" and step.get("checks", 0) > 0 and step.get("matched") == step.get("checks")


def _step(kind, plan, run):
    run = run or {}
    results = run.get("results") or {}
    step = {"kind": kind, "plan_id": plan.get("plan_id"), "plan_status": plan.get("status"), "run_id": run.get("run_id"),
            "run_status": run.get("status"), "stage": run.get("stage"), "started_at": run.get("started_at") or plan.get("created_at") or "",
            "finished_at": run.get("finished_at"), "checks": results.get("reconciliation_checks") or 0,
            "matched": results.get("reconciliation_matched") or 0, "differ": results.get("reconciliation_differs") or 0,
            "errors": results.get("reconciliation_errors") or 0, "import_issues": results.get("import_issues")}
    base = plan.get("base_site") or {}
    delivery = base.get("delivery") or {}
    step.update(base_site=("Base site v%s" % delivery.get("version")) if base else None,
                base_site_details=base, backup=(run.get("artifacts") or {}).get("backup"), release=run.get("release"),
                backup_state="released" if run.get("release") else "ready" if (run.get("artifacts") or {}).get("backup") else "none",
                results=results)
    return step


def site_verdicts(reviews):
    """The engineer's latest verdict on each review run's site (bin/data_tools.py site_summary's by_run):
    accepted or needs changes, unless that acceptance was withdrawn."""
    reviews = [entry for entry in reviews if isinstance(entry, dict)]
    withdrawn = {entry.get("of") for entry in reviews if entry.get("verdict") == "withdrawn"}
    latest = {}
    for entry in reviews:
        if entry.get("verdict") in ("accepted", "needs_changes"):
            latest[entry.get("run_id")] = entry
    current = {run_id: entry for run_id, entry in latest.items() if entry.get("id") not in withdrawn}
    # The accepted process (data_tools.current_acceptance): the newest customer acceptance, while it stands.
    newest = next((entry for entry in reversed(reviews) if entry.get("verdict") == "accepted" and entry.get("basis") == "customer"), None)
    standing = newest.get("id") if newest and current.get(newest.get("run_id")) is newest else None
    return {run_id: dict({key: entry.get(key) for key in ("id", "verdict", "basis", "by", "at", "note")},
                         replaced=entry.get("verdict") == "accepted" and entry.get("basis") == "customer" and entry.get("id") != standing)
            for run_id, entry in current.items()}


def build_passes(plans, runs, bodies, review_sites, pushes, deliveries, reviews=(), active=None):
    """plans/runs: the workbench's status views; bodies: {plan_id: body}; review_sites: {run_id: up?};
    pushes: raw push records; deliveries: {dataset_id: record}; reviews: site-reviews.json's entries."""
    verdicts = site_verdicts(reviews)
    run_of_plan = {run.get("plan_id"): run for run in runs}
    groups = {}
    for plan in plans:
        body = bodies.get(plan.get("plan_id")) or {}
        if body.get("operation") != "standard_convert":
            continue
        run = run_of_plan.get(plan.get("plan_id"))
        if not run and plan.get("status") not in WAITING + ("stale",):
            continue  # discarded, never run: not part of any pass
        step = _step("convert", plan, run)
        delivery = body.get("delivery") or {}
        # Keyed by the convert plan: the same before and after it runs.
        groups[plan.get("plan_id")] = {
            "key": plan.get("plan_id"), "convert": step, "imports": [],
            "delivery": ("Launch" if delivery.get("kind") == "launch" else "Development v%s" % delivery.get("version")) if delivery else None,
            "dataset_id": delivery.get("dataset_id") or body.get("dataset_id"),
            "converter": body.get("converter_revision"), "branch": (body.get("converter") or {}).get("branch"),
            "started_at": step["started_at"], "created_at": plan.get("created_at") or step["started_at"], "roles": body.get("roles") or {}}
    for plan in plans:
        # A merge run is a pass of its own: one step (in the convert slot, so everything that walks a
        # pass's steps still works), with the merged site and its backup on that step.
        body = bodies.get(plan.get("plan_id")) or {}
        if body.get("operation") != "standard_merge":
            continue
        run = run_of_plan.get(plan.get("plan_id"))
        if not run and plan.get("status") not in WAITING + ("stale",):
            continue
        step = _step("merge", dict(plan, base_site=body.get("base_site")), run)
        step["site_up"] = bool(run and review_sites.get(run.get("run_id")))
        merge = body.get("merge") if isinstance(body.get("merge"), dict) else {}
        layer = merge.get("layer") if isinstance(merge.get("layer"), dict) else {}
        delivery = body.get("delivery") or {}
        # A merge proposed from a prepared environment names exactly which one (and which generation).
        step["prepared_from"] = body_prepared_from(body)
        groups[plan.get("plan_id")] = {
            "key": plan.get("plan_id"), "kind": "merge", "convert": step, "imports": [], "prepared_from": step["prepared_from"],
            "delivery": ("Launch" if delivery.get("kind") == "launch" else "Development v%s" % delivery.get("version")) if delivery else None,
            "dataset_id": delivery.get("dataset_id") or body.get("dataset_id"),
            "converter": body.get("converter_revision"), "branch": (body.get("converter") or {}).get("branch"),
            "layer": {"present": True, "path": layer.get("path"), "revision": layer.get("revision"), "files": layer.get("files"),
                      "sha256": layer.get("sha256")} if layer.get("present") else {"present": False},
            "started_at": step["started_at"], "created_at": plan.get("created_at") or step["started_at"], "roles": body.get("roles") or {}}
    for plan in plans:
        body = bodies.get(plan.get("plan_id")) or {}
        if body.get("operation") != "standard_review":
            continue
        run = run_of_plan.get(plan.get("plan_id"))
        if not run and plan.get("status") not in WAITING + ("stale",):
            continue
        source = (body.get("from_run") or {}).get("run_id")
        group = next((candidate for candidate in groups.values() if candidate["convert"]["run_id"] and candidate["convert"]["run_id"] == source), None)
        if group:
            step = _step("import", dict(plan, base_site=body.get("base_site")), run)
            step["site_up"] = bool(run and review_sites.get(run.get("run_id")))
            step["review"] = verdicts.get(run.get("run_id")) if run else None
            group["imports"].append(step)
    # Numbered in the order they were proposed, so a pass keeps its number when it runs.
    ordered = sorted(groups.values(), key=lambda group: (_t(group["created_at"]), group["key"]))
    for number, group in enumerate(ordered, 1):
        group["number"] = number
        group["imports"].sort(key=lambda step: _t(step["started_at"]))
        group["status"] = merge_status(group["convert"]) if group.get("kind") == "merge" else pass_status(group)
        latest = group["convert"] if group.get("kind") == "merge" else group["imports"][-1] if group["imports"] else {}
        for key in ("base_site", "backup_state", "release"):
            group[key] = latest.get(key, "none" if key == "backup_state" else None)
    used = {}
    for group in ordered:
        if group["convert"]["run_id"]:
            used.setdefault(group["converter"], []).append(group["number"])
    updates = []
    for record in pushes:
        proposal = record.get("proposal") or {}
        head = proposal.get("head")
        updates.append({"digest": record.get("digest"), "status": record.get("status"), "title": proposal.get("title"), "head": _short(head),
                        "full_head": head, "branch": proposal.get("branch"), "pushed_at": record.get("pushed_at"), "proposed_at": record.get("proposed_at"),
                        "findings": proposal.get("findings") or [], "used_by": used.get(head, [])})
    updates.sort(key=lambda update: _t(update.get("pushed_at") or update.get("proposed_at")), reverse=True)
    prepared = environments(plans, run_of_plan, bodies, ordered)
    shown = banner(ordered, updates, deliveries, active=active)
    if any(item["status"][0] in ("Waiting for your approval", "Running") for item in prepared):
        shown = None
    elif shown and shown.get("kind") == "converter" and any(item["live"] for item in prepared):
        # Its action re-proposes the last merge, which is not bound to the live prepared environment:
        # a prepared merge plan comes from migration-data, never from this shortcut.
        shown = None
    return {"passes": ordered[::-1], "updates": updates, "banner": shown,
            "preparations": preparations(plans, run_of_plan, bodies), "environments": prepared}


# -- prepared merge environment ---------------------------------------------------------------
# Only these fixed, non-secret facts leave the host's records: never connector profiles, keys,
# host paths, URLs, customer file names or private contents.

_RUN_ID = re.compile(r"run-[0-9a-f]{32}\Z")
_PHASE = re.compile(r"[a-z][a-z_]{0,31}\Z")
_ENDPOINT_NAME = re.compile(r"[a-z][a-z0-9_-]{0,63}\Z")
_DIGEST = re.compile(r"[0-9a-f]{64}\Z")
ENDPOINT_KINDS = ("dbhub", "discourse_mcp")
PREPARE_OPERATION = "standard_merge_prepare"
LIVE_PHASES = ("ready", "inspection")  # prepared and clean; inspection copies may be in use
INTENTS = ("stock", "custom")


def _generation(value):
    """A generation as the host records it: its 64-hex identity (or a small counter)."""
    if type(value) is int and 0 < value < 2**31:
        return value
    return value if isinstance(value, str) and _DIGEST.fullmatch(value) else None


def prepared_from(value, generation=None):
    """{run_id, generation} of the prepared environment a merge plan binds, or None if absent/unsafe.
    Accepts {run_id, generation} or a run ID with its generation recorded beside it."""
    if isinstance(value, str):
        value = {"run_id": value, "generation": generation}
    if not isinstance(value, dict):
        return None
    run_id, generation = value.get("run_id"), _generation(value.get("generation"))
    if not isinstance(run_id, str) or not _RUN_ID.fullmatch(run_id) or generation is None:
        return None
    return {"run_id": run_id, "generation": generation}


def body_prepared_from(body):
    """A merge plan body's binding, whichever of the two recorded shapes it uses."""
    body = body if isinstance(body, dict) else {}
    return prepared_from(body.get("prepared_from"), body.get("generation"))


def merge_environment(value):
    """The safe projection of a prepared merge environment: preparation run, generation, phase and,
    only if the host provided them, the fixed inspection endpoints' kind, name and readiness."""
    if not isinstance(value, dict):
        return None
    run_id = value.get("preparation_run_id")
    phase = value.get("phase")
    result = {"preparation_run_id": run_id if isinstance(run_id, str) and _RUN_ID.fullmatch(run_id) else None,
              "generation": _generation(value.get("generation")),
              "phase": phase if isinstance(phase, str) and _PHASE.fullmatch(phase) else None}
    endpoints = []
    for entry in value.get("endpoints") if isinstance(value.get("endpoints"), list) else []:
        if not isinstance(entry, dict) or entry.get("kind") not in ENDPOINT_KINDS or not isinstance(entry.get("ready"), bool):
            continue
        name = entry.get("name")
        endpoints.append({"kind": entry["kind"], "name": name if isinstance(name, str) and _ENDPOINT_NAME.fullmatch(name) else None,
                          "ready": entry["ready"]})
    if endpoints:
        result["endpoints"] = endpoints[:4]
    return result if any(result.get(key) is not None for key in ("preparation_run_id", "generation", "phase")) else None


def run_environment(run):
    """A run record's environment, wherever the host put it (top level or in its results)."""
    run = run if isinstance(run, dict) else {}
    results = run.get("results") if isinstance(run.get("results"), dict) else {}
    return merge_environment(run.get("merge_environment") if run.get("merge_environment") is not None else results.get("merge_environment"))


def environment_status(step, env, used_by):
    """One phrase for where a prepared environment stands, and its tone. Ready never means migrated."""
    if step["run_status"] in ACTIVE:
        return ("Running", "now")
    if step["run_status"] is None:
        if step["plan_status"] in WAITING:
            return ("Waiting for your approval", "now")
        return ("Out of date: propose it again", "warn") if step["plan_status"] == "stale" else ("Not started", "wait")
    if step["run_status"] != "completed":
        return ("Preparation needs a look", "warn")
    phase = (env or {}).get("phase")  # the host's record decides; a merge refused before writing leaves it ready
    if phase in LIVE_PHASES:
        return ("Ready: inspect, then propose the merge", "now")
    if phase in ("fencing", "merging"):
        return ("In use by a merge", "now")
    if phase == "consumed" or (phase is None and used_by):
        return ("Used by a merge", "ok")
    if phase == "dirty":
        return ("Not clean: prepare it again", "warn")
    if phase == "reset":
        return ("Reset", "wait")
    return ("Prepared: state unknown", "warn")


def environments(plans, run_of_plan, bodies, merge_passes=()):
    """Prepare merge environment jobs: not a pass and never numbered. No migration happens in them,
    so they carry no backup or release; they show which merge pass (if any) used them."""
    items = []
    for plan in plans:
        body = bodies.get(plan.get("plan_id")) or {}
        if body.get("operation") != PREPARE_OPERATION:
            continue
        run = run_of_plan.get(plan.get("plan_id"))
        if not run and plan.get("status") not in WAITING + ("stale",):
            continue
        step = _step("merge_prepare", dict(plan, base_site=body.get("base_site")), run)
        # Nothing to release before a clean merged artifact; raw results may name connector details.
        step.update(backup=None, release=None, backup_state="none", results={})
        env = run_environment(run) if run else None
        if env and env.get("preparation_run_id") not in (None, step["run_id"]):
            env = None  # another run's environment: never shown as this one's
        used_by = sorted(group["number"] for group in merge_passes if group.get("kind") == "merge" and group["convert"].get("run_id")
                         and (group.get("prepared_from") or {}).get("run_id") == step["run_id"] and step["run_id"])
        bound_by = sorted(group["number"] for group in merge_passes if group.get("kind") == "merge" and not group["convert"].get("run_id")
                          and (group.get("prepared_from") or {}).get("run_id") == step["run_id"] and step["run_id"])
        status = environment_status(step, env, used_by)
        delivery = body.get("delivery") or {}
        items.append({"key": plan.get("plan_id"), "kind": "merge_prepare", "name": "Prepare merge environment", "step": step,
                      "environment": env, "used_by": used_by, "proposed_merges": bound_by, "status": status,
                      "live": step["run_status"] == "completed" and (env or {}).get("phase") in LIVE_PHASES,
                      "delivery": ("Launch" if delivery.get("kind") == "launch" else "Development v%s" % delivery.get("version")) if delivery else None,
                      "base_site": step["base_site"], "at": step["started_at"]})
    items.sort(key=lambda item: _t(item["at"]), reverse=True)
    return items[:10]


PREPARATION_OPERATIONS = {"standard_master_lists": "Master-list export"}


def preparations(plans, run_of_plan, bodies):
    """Preparation jobs (e.g. the converter's master-list export): not a pass, never numbered,
    never a conversion or import, and not counted towards the "what's next" banner."""
    items = []
    for plan in plans:
        body = bodies.get(plan.get("plan_id")) or {}
        name = PREPARATION_OPERATIONS.get(body.get("operation"))
        if not name:
            continue
        run = run_of_plan.get(plan.get("plan_id")) or {}
        if not run and plan.get("status") not in WAITING + ("stale",):
            continue
        delivery = body.get("delivery") or {}
        master = body.get("master_lists") if isinstance(body.get("master_lists"), dict) else {}
        items.append({"kind": body["operation"], "name": name, "plan_id": plan.get("plan_id"), "plan_status": plan.get("status"),
                      "run_id": run.get("run_id"), "run_status": run.get("status"), "stage": run.get("stage"),
                      "list": master.get("list") if isinstance(master.get("list"), str) else None,
                      "delivery": ("Launch" if delivery.get("kind") == "launch" else "Development v%s" % delivery.get("version")) if delivery else None,
                      "at": run.get("started_at") or plan.get("created_at") or ""})
    items.sort(key=lambda item: _t(item["at"]), reverse=True)
    return items[:20]


def merge_status(step):
    """Where a merge pass stands. A merge has no automatic count checks: finished means the merger
    ran to the end and the site came up; whether it is right is the engineer's check of the site."""
    if step["run_status"] in ACTIVE:
        return ("Running", "now")
    if step["run_status"] is None:
        if step["plan_status"] in WAITING:
            return ("Waiting for your approval", "now")
        return ("Out of date: propose it again", "warn") if step["plan_status"] == "stale" else ("Not started", "wait")
    if step["run_status"] != "completed":
        return ("Merge needs a look", "warn")
    if step.get("release"):
        return ("Backup released", "ok")
    return ("Ready to check", "now") if step.get("site_up") else ("Merged", "ok")


def pass_status(group):
    """One phrase for where a pass stands, and its tone: now, ok, warn, wait."""
    convert, imports = group["convert"], group["imports"]
    latest = imports[-1] if imports else None
    steps = [convert] + imports
    if any(step["run_status"] in ACTIVE for step in steps):
        return ("Running", "now")
    if any(step["run_status"] is None and step["plan_status"] in WAITING for step in steps):
        return ("Waiting for your approval", "now")
    if convert["run_status"] is None and convert["plan_status"] == "stale":
        return ("Out of date: propose it again", "warn")
    if not _passed(convert):
        return ("Convert needs a look", "warn") if convert["run_status"] else ("Not started", "wait")
    if not latest or latest["run_status"] is None:
        return ("Converted: import next", "now")
    if not _passed(latest):
        return ("Import needs a look", "warn")
    review = latest.get("review") or {}
    if review.get("verdict") == "needs_changes":
        return ("Needs changes", "warn")
    if review.get("verdict") == "accepted":
        if review.get("replaced"):
            return ("Accepted earlier", "wait")
        return ("Accepted", "ok") if review.get("basis") == "customer" else ("Checked by you", "ok")
    if latest.get("site_up"):
        return ("Ready to check", "now")
    return ("All checks matched", "ok")


def banner(ordered, updates, deliveries, active=None):
    """New work for the explicitly current source, not the newest arrival.

    Missing role metadata retains legacy selection. An empty/null active pointer
    is intentional and must never fall back to a corrected delivery.
    """
    ran = [group for group in ordered if group["convert"]["run_id"]]
    if not ran or any(group["status"][0] in ("Waiting for your approval", "Running") for group in ordered):
        return None
    last = ran[-1]
    pushed = [update for update in updates if update["status"] == "pushed" and update["full_head"] and _t(update["pushed_at"]) > _t(last["started_at"])]
    merge = {"merge": True} if last.get("kind") == "merge" else {}  # the page words it for a merge project
    if pushed and not pushed[0]["used_by"]:
        return {"kind": "converter", "head": pushed[0]["head"], "title": pushed[0]["title"], "run_id": last["convert"]["run_id"], "next": last["number"] + 1, **merge}
    if active is None:
        newest = [record for record in sorted(deliveries.values(), key=lambda record: record.get("sequence", 0)) if record.get("kind") == "development" and not record.get("replaced_by")]
    else:
        current = deliveries.get(active.get("development"))
        newest = [current] if isinstance(current, dict) and current.get("kind") == "development" else []
    if newest and newest[-1].get("dataset_id") not in {group["dataset_id"] for group in ran}:
        return {"kind": "data", "label": "Development v%s" % newest[-1].get("version"), "next": last["number"] + 1, **merge}
    return None


def build_findings(records, passes, updates, marks):
    """records: the Findings store's records (with titles); passes/updates: from build_passes; marks:
    {finding_id: {by, at}} the engineer set. Groups: review, progress, done, other."""
    by_id = {record["id"]: record for record in records}
    run_pass = {}
    for group in passes:
        for step in [group["convert"]] + group["imports"]:
            if step["run_id"]:
                run_pass[step["run_id"]] = (group["number"], step["kind"])
    groups = {"review": [], "progress": [], "done": [], "other": []}
    for record in records:
        lineage = {record["id"]}
        cursor = record
        while cursor.get("supersedes") in by_id and cursor["supersedes"] not in lineage:  # a correction keeps its fixes
            cursor = by_id[cursor["supersedes"]]
            lineage.add(cursor["id"])
        fixes = [update for update in updates if lineage & set(update["findings"]) and update["status"] in ("proposed", "pushed")]
        pushed = sorted((update for update in fixes if update["status"] == "pushed"), key=lambda update: _t(update["pushed_at"]))
        first_fix = pushed[0] if pushed else None

        def carries_fix(group):
            # The pass ran the fix itself, or a later commit of the same branch pushed after it. A pass
            # on another branch (a new topic from main, say) doesn't count.
            if not group["convert"]["run_id"]:
                return False
            if any(group["converter"] == fix["full_head"] for fix in pushed):
                return True
            return any(fix["branch"] and group.get("branch") == fix["branch"] and _t(group["started_at"]) >= _t(fix["pushed_at"]) for fix in pushed)
        checked = None
        for group in sorted(passes, key=lambda group: group["number"]):
            last = (group["imports"] or [group["convert"]])[-1]
            if carries_fix(group) and _passed(group["convert"]) and _passed(last):
                checked = group["number"]
                break
        later = any(carries_fix(group) for group in passes)
        origin = run_pass.get(record.get("run_id"))
        item = {"id": record["id"], "title": record.get("title") or record["id"], "kind": record.get("kind"), "status": record["status"],
                "proposed_at": record.get("proposed_at"), "decided_at": record.get("decided_at"),
                "origin": {"pass": origin[0], "step": origin[1]} if origin else None,
                "fix": {"head": first_fix["head"], "title": first_fix["title"]} if first_fix else ({"proposed": True} if fixes else None),
                "ran": bool(later), "checked_in": checked}
        # A mark follows the finding through its corrections.
        marked_id = next((finding_id for finding_id in [record["id"]] + sorted(lineage - {record["id"]}) if marks.get(finding_id)), None)
        item["marked"] = marks.get(marked_id) if marked_id else None
        item["marked_id"] = marked_id
        if record["status"] == "proposed":
            groups["review"].append(item)
        elif record["status"] == "released":
            (groups["done"] if checked or item["marked"] else groups["progress"]).append(item)
        else:
            groups["other"].append(item)
    for items in groups.values():
        items.sort(key=lambda item: _t(item.get("decided_at") or item.get("proposed_at")), reverse=True)
    return groups
