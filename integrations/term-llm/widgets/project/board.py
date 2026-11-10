"""Passes and the findings track for the Project page, worked out from what the workbench stores.

Pure functions over plain data, so they're easy to test. A pass is one convert run with the imports
made from it; converter updates are the pushes; a finding moves from released to fixed to checked
as the pushes that name it are pushed and a later pass passes.
"""

from datetime import datetime, timezone

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
    return step


def build_passes(plans, runs, bodies, review_sites, pushes, deliveries):
    """plans/runs: the workbench's status views; bodies: {plan_id: body}; review_sites: {run_id: up?};
    pushes: raw push records; deliveries: {dataset_id: record}."""
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
        body = bodies.get(plan.get("plan_id")) or {}
        if body.get("operation") != "standard_review":
            continue
        run = run_of_plan.get(plan.get("plan_id"))
        if not run and plan.get("status") not in WAITING + ("stale",):
            continue
        source = (body.get("from_run") or {}).get("run_id")
        group = next((candidate for candidate in groups.values() if candidate["convert"]["run_id"] and candidate["convert"]["run_id"] == source), None)
        if group:
            step = _step("import", plan, run)
            step["site_up"] = bool(run and review_sites.get(run.get("run_id")))
            group["imports"].append(step)
    # Numbered in the order they were proposed, so a pass keeps its number when it runs.
    ordered = sorted(groups.values(), key=lambda group: (_t(group["created_at"]), group["key"]))
    for number, group in enumerate(ordered, 1):
        group["number"] = number
        group["imports"].sort(key=lambda step: _t(step["started_at"]))
        group["status"] = pass_status(group)
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
    return {"passes": ordered[::-1], "updates": updates, "banner": banner(ordered, updates, deliveries)}


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
    if latest.get("site_up"):
        return ("Ready to check", "now")
    return ("All checks matched", "ok")


def banner(ordered, updates, deliveries):
    """Something new that no pass has used yet: a pushed converter update, or newer data."""
    ran = [group for group in ordered if group["convert"]["run_id"]]
    if not ran or any(group["status"][0] in ("Waiting for your approval", "Running") for group in ordered):
        return None
    last = ran[-1]
    pushed = [update for update in updates if update["status"] == "pushed" and update["full_head"] and _t(update["pushed_at"]) > _t(last["started_at"])]
    if pushed and not pushed[0]["used_by"]:
        return {"kind": "converter", "head": pushed[0]["head"], "title": pushed[0]["title"], "run_id": last["convert"]["run_id"], "next": last["number"] + 1}
    newest = [record for record in sorted(deliveries.values(), key=lambda record: record.get("sequence", 0)) if record.get("kind") == "development" and not record.get("replaced_by")]
    if newest and newest[-1].get("dataset_id") not in {group["dataset_id"] for group in ran}:
        return {"kind": "data", "label": "Development v%s" % newest[-1].get("version"), "next": last["number"] + 1}
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
