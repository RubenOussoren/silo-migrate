"""Runs widget: the engineer's approvals for workflow runs and converter pushes, in the web UI.

term-llm starts this on demand (widget.yaml) on a Unix socket and serves it, behind the web
UI's sign-in, at <base>/widgets/runs/. It replaces the terminal steps an engineer had to run as
the service account:

  plans   migration-data (or the operator) proposes; here the engineer reads what the plan
          binds (for a convert run: the settings and the reconciliation checks themselves),
          approves its exact digest, starts it, or discards it
  runs    progress, results (including the private reconciliation numbers: the engineer may
          see them), reset and recover
  pushes  converter-developer proposes; here the engineer reads the PR text, commits and files
          and pushes it as a draft PR (exact digest)

Every decision runs through `silo-migrate-control …`, which locks, validates and records it,
exactly as on the command line. The tab's counts are read straight from disk (cheap to poll);
the views that need the workflow's own checks (stale plans, abandoned runs) come from
`standard status` / `plan show` / `run show`.

Models never reach this: agents have no web UI sign-in, and the socket isn't a TCP port.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import socketserver
import stat
import subprocess
import sys
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlsplit

WORKSPACE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\Z")
PLAN = re.compile(r"plan-[0-9a-f]{32}\Z")
RUN = re.compile(r"run-[0-9a-f]{32}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
MAX_STATE = 4 * 1024 * 1024     # the stores' limit for state.json
MAX_INPUT_TEXT = 256 * 1024     # settings and reconciliation inputs shown in a plan
MAX_EVIDENCE = 64 * 1024
MAX_BODY = 4096                 # POST bodies are a few IDs
HERE = Path(__file__).resolve().parent
INSTALLED = re.compile(r"(/.+)/releases/[0-9a-f]{40}/integrations/term-llm/widgets/[a-z0-9-]+")
STATIC = {"/": ("index.html", "text/html; charset=utf-8"), "/app.js": ("app.js", "text/javascript; charset=utf-8"),
          "/app.css": ("app.css", "text/css; charset=utf-8")}
HEADERS = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
           "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"}
# Seconds per control call: a push talks to GitHub (git push has 300 s); the rest is local.
TIMEOUTS = {"push": 330, "start": 120, "reset": 300}
DEFAULT_TIMEOUT = 90


class Refused(Exception):
    def __init__(self, code, status=400):
        super().__init__(code)
        self.code, self.status = code, status


def locate():
    """(control command, workspaces folder) from the installed layout. SILO_RUNS_* are for tests only."""
    if os.environ.get("SILO_TESTING") == "1" and os.environ.get("SILO_RUNS_CONTROL"):
        return os.environ["SILO_RUNS_CONTROL"], Path(os.environ["SILO_RUNS_BASE"])
    installed = INSTALLED.fullmatch(str(HERE))
    if not installed:
        raise SystemExit("runs widget: not an installed release")
    prefix = Path(installed[1])
    base = None
    for line in (prefix / "etc/silo-control.env").read_text().splitlines():
        if line.startswith("SILO_MIGRATE_BASE_PATH="):
            base = line.split("=", 1)[1]
    if not base:
        raise SystemExit("runs widget: SILO_MIGRATE_BASE_PATH missing from etc/silo-control.env")
    return str(prefix / "bin/silo-migrate-control"), Path(base)


def read_file(path, limit):
    """A regular file, not through a link at its last component, at most `limit` bytes."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise Refused("STANDARD_FILE_INVALID", 500)
        chunks, size = [], 0
        while size < info.st_size:
            chunk = os.read(fd, min(65536, limit - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def text_or_none(value):
    return value if isinstance(value, str) else None


class Store:
    """Read-only views straight from disk: the tab's counts, plan bodies, input texts, pushes."""

    def __init__(self, base):
        self.base = Path(base)

    def root(self, workspace):
        if not isinstance(workspace, str) or not WORKSPACE.fullmatch(workspace):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        root = self.base / workspace
        standard = root / ".silo-migrate/named/standard"
        for level in (root, root / ".silo-migrate", root / ".silo-migrate/named", standard):
            if level.is_symlink() or not level.is_dir():
                raise Refused("STANDARD_NOT_INITIALIZED", 404)
        return standard

    def workspaces(self):
        names = []
        try:
            entries = sorted(os.listdir(self.base))
        except OSError:
            return names
        for name in entries:
            if WORKSPACE.fullmatch(name):
                try:
                    if (self.root(name) / "state.json").is_file():
                        names.append(name)
                except Refused:
                    continue
        return names

    def state(self, workspace):
        try:
            state = json.loads(read_file(self.root(workspace) / "state.json", MAX_STATE))
        except (OSError, ValueError):
            return {}
        return state if isinstance(state, dict) else {}

    def named(self, workspace):
        self.root(workspace)
        try:
            state = json.loads(read_file(self.base / workspace / ".silo-migrate/named/state.json", MAX_STATE))
        except (OSError, ValueError):
            return {}
        return state if isinstance(state, dict) else {}

    def plans(self, workspace):
        plans = self.state(workspace).get("plans")
        return {key: plan for key, plan in plans.items() if PLAN.fullmatch(str(key)) and isinstance(plan, dict)} if isinstance(plans, dict) else {}

    def runs(self, workspace):
        runs = self.state(workspace).get("runs")
        return {key: run for key, run in runs.items() if RUN.fullmatch(str(key)) and isinstance(run, dict)} if isinstance(runs, dict) else {}

    def pushes(self, workspace):
        directory = self.root(workspace) / "converter-pushes"
        if directory.is_symlink() or not directory.is_dir():
            return []
        records = []
        for path in sorted(directory.glob("*.json")):
            if not DIGEST.fullmatch(path.stem):
                continue
            try:
                record = json.loads(read_file(path, MAX_STATE))
            except (OSError, ValueError, Refused):
                continue
            if isinstance(record, dict) and record.get("digest") == path.stem and isinstance(record.get("proposal"), dict):
                records.append(record)
        return sorted(records, key=lambda record: str(record.get("proposed_at") or ""), reverse=True)

    def input_text(self, workspace, input_id, binding):
        """A registered input's text, only if its bytes are still exactly the plan's."""
        record = (self.named(workspace).get("inputs") or {}).get(input_id)
        if not isinstance(record, dict) or not isinstance(binding, dict):
            return None
        try:
            relative = base64.b64decode(record["path"]).decode("utf-8")
        except (KeyError, ValueError, TypeError):
            return None
        root = (self.base / workspace).resolve()
        path = root / relative
        if not os.path.realpath(path.parent).startswith(str(root) + os.sep):
            return None
        try:
            data = read_file(path, MAX_INPUT_TEXT)
        except (OSError, Refused):
            return None
        if hashlib.sha256(data).hexdigest() != binding.get("sha256"):
            return None
        return data.decode("utf-8", "replace")

    def evidence(self, workspace, run_id, name):
        if not RUN.fullmatch(str(run_id)):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        standard = self.root(workspace)
        folder = standard / "runs" / run_id / "evidence"
        if os.path.realpath(folder) != os.path.join(os.path.realpath(standard), "runs", run_id, "evidence"):
            return None
        try:
            return read_file(folder / name, MAX_EVIDENCE).decode("utf-8", "replace")
        except (OSError, Refused):
            return None


# -- control ------------------------------------------------------------------------

def control_call(control, argv, timeout=DEFAULT_TIMEOUT):
    """Run silo-migrate-control; its JSON (the first line, for start-run), or a refusal with its
    code and the short fixed detail some refusals add."""
    try:
        result = subprocess.run([control, *argv], capture_output=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise Refused("STANDARD_OPERATION_TIMEOUT", 504)
    if result.returncode != 0:
        match = re.search(rb"Error: ((?:STANDARD|NAMED)_[A-Z_]+)([^\n]*)", result.stderr)
        if not match:
            raise Refused("STANDARD_OPERATION_FAILED", 409)
        detail = re.fullmatch(rb": (.{1,200}?)(?:\. .*|\.)?", match[2])
        raise Refused(match[1].decode() + (": " + detail[1].decode("utf-8", "replace") if detail else ""), 409)
    try:
        outcome = json.loads((result.stdout.decode("utf-8", "replace").strip().splitlines() or ["{}"])[0])
    except ValueError:
        raise Refused("STANDARD_OPERATION_FAILED", 502)
    return outcome if isinstance(outcome, dict) else {}


def reviewer_name():
    """The engineer's commit identity (the web UI doesn't pass on who is signed in)."""
    name = ""
    try:
        for line in (Path(pwd.getpwuid(os.getuid()).pw_dir) / ".config/silo-migrate/git-identity").read_text().splitlines():
            if line.startswith("name="):
                name = line.split("=", 1)[1].strip()
    except OSError:
        pass
    name = name if re.fullmatch(r"[^\x00-\x1f\x7f]{1,80}", name) else "engineer"
    return name + " (web UI)"


# -- views --------------------------------------------------------------------------

def push_summary(record):
    proposal = record["proposal"]
    pull = record.get("pull_request") if isinstance(record.get("pull_request"), dict) else {}
    return {"digest": record["digest"], "status": text_or_none(record.get("status")), "proposed_at": text_or_none(record.get("proposed_at")),
            "pushed_at": text_or_none(record.get("pushed_at")), "title": text_or_none(proposal.get("title")),
            "branch": text_or_none(proposal.get("branch")), "pull_request": safe_pull(pull)}


def safe_pull(pull):
    url = pull.get("url") if isinstance(pull, dict) else None
    return {"number": pull.get("number") if isinstance(pull.get("number"), int) else None,
            "url": url if isinstance(url, str) and re.fullmatch(r"https://github\.com/[A-Za-z0-9._/-]{1,200}", url) else None} if pull else None


def waiting(store, workspace):
    """What waits for the engineer in one project, from disk."""
    items = []
    for plan_id, plan in store.plans(workspace).items():
        if plan.get("status") in ("proposed", "approved"):
            body = plan.get("body") if isinstance(plan.get("body"), dict) else {}
            items.append({"kind": "plan", "workspace": workspace, "id": plan_id, "status": plan["status"],
                          "operation": text_or_none(body.get("operation")), "at": text_or_none(plan.get("created_at")) or ""})
    for record in store.pushes(workspace):
        if record.get("status") == "proposed":
            items.append({"kind": "push", "workspace": workspace, "id": record["digest"], "status": "proposed",
                          "title": text_or_none(record["proposal"].get("title")), "at": text_or_none(record.get("proposed_at")) or ""})
    running = [{"kind": "run", "workspace": workspace, "id": run_id, "status": run.get("status"), "stage": text_or_none(run.get("stage")),
                "at": text_or_none(run.get("started_at")) or ""}
               for run_id, run in store.runs(workspace).items() if run.get("status") in ("claimed", "running")]
    return items, running


def summary(store):
    pending, active, counts = [], [], []
    for name in store.workspaces():
        items, running = waiting(store, name)
        pending += items
        active += running
        if items or running:
            counts.append({"workspace": name, "waiting": len(items), "running": len(running)})
    pending.sort(key=lambda item: (item["at"], item["id"]), reverse=True)
    return {"waiting": len(pending), "running": len(active), "workspaces": counts, "latest": pending[:8], "active": active[:8]}


def overview(store, control, workspace):
    store.root(workspace)
    status = control_call(control, ["standard", "status", workspace])
    plans = [plan for plan in status.get("plans", []) if isinstance(plan, dict)]
    bodies = store.plans(workspace)
    for plan in plans:
        body = (bodies.get(plan.get("plan_id")) or {}).get("body") or {}
        plan["operation"] = text_or_none(body.get("operation"))
        plan["platform"] = text_or_none(body.get("platform"))
    return {"workspace": workspace, "workspaces": store.workspaces(), "plans": plans,
            "runs": [run for run in status.get("runs", []) if isinstance(run, dict)],
            "pushes": [push_summary(record) for record in store.pushes(workspace)][:20]}


def plan_detail(store, control, workspace, plan_id):
    if not isinstance(plan_id, str) or not PLAN.fullmatch(plan_id):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    shown = control_call(control, ["standard", "plan", "show", workspace, plan_id])
    plan = store.plans(workspace).get(plan_id) or {}
    body = plan.get("body") if isinstance(plan.get("body"), dict) else {}
    texts = {}
    roles = body.get("roles") if isinstance(body.get("roles"), dict) else {}
    bindings = {entry.get("id"): entry for entry in body.get("input_binding") or [] if isinstance(entry, dict)}
    for role in ("settings", "reconciliation"):
        if isinstance(roles.get(role), str):
            texts[role] = store.input_text(workspace, roles[role], bindings.get(roles[role]))
    named = store.named(workspace).get("inputs") or {}
    paths = {}
    for input_id in bindings:
        try:
            paths[input_id] = base64.b64decode(named[input_id]["path"]).decode("utf-8", "replace")
        except (KeyError, ValueError, TypeError):
            paths[input_id] = None
    return dict(shown, workspace=workspace, limits=body.get("limits"), input_paths=paths, texts=texts,
                discarded=plan.get("discarded") if isinstance(plan.get("discarded"), dict) else None)


def run_detail(store, control, workspace, run_id):
    if not isinstance(run_id, str) or not RUN.fullmatch(run_id):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    shown = control_call(control, ["standard", "run", "show", workspace, run_id])
    run = store.runs(workspace).get(run_id) or {}
    results = run.get("results") if isinstance(run.get("results"), dict) else {}
    reconciliation = results.get("reconciliation") if isinstance(results.get("reconciliation"), list) else None
    return dict(shown, workspace=workspace, reconciliation=reconciliation,
                conversion_summary=store.evidence(workspace, run_id, "conversion-summary.txt"))


def push_detail(store, workspace, digest):
    if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    record = next((record for record in store.pushes(workspace) if record["digest"] == digest), None)
    if not record:
        raise Refused("STANDARD_REFERENCE_INVALID", 404)
    proposal = record["proposal"]
    keep = ("repository", "branch", "base", "head", "title", "body", "stat", "files_total")
    return dict(push_summary(record), workspace=workspace, **{key: proposal.get(key) for key in keep},
                commits=[commit for commit in proposal.get("commits") or [] if isinstance(commit, (str, dict))][:50],
                files=[name for name in proposal.get("files") or [] if isinstance(name, str)][:300])


# -- decisions ----------------------------------------------------------------------

def decide(store, control, action, body):
    workspace = body.get("workspace")
    store.root(workspace)
    plan_id, run_id, digest = body.get("plan_id"), body.get("run_id"), body.get("digest")
    plan_ok = isinstance(plan_id, str) and PLAN.fullmatch(plan_id)
    run_ok = isinstance(run_id, str) and RUN.fullmatch(run_id)
    digest_ok = isinstance(digest, str) and DIGEST.fullmatch(digest)
    if action == "approve" and plan_ok and digest_ok:
        # The digest the page showed: if the plan were any other, approval is refused.
        argv = ["standard", "plan", "approve", workspace, plan_id, "--sha256", digest, "--reviewer", reviewer_name()]
    elif action == "discard" and plan_ok:
        argv = ["standard", "plan", "discard", workspace, plan_id, "--reviewer", reviewer_name()]
    elif action == "start" and plan_ok:
        argv = ["start-run", workspace, plan_id]
    elif action == "recover" and run_ok:
        argv = ["standard", "run", "recover", workspace, run_id]
    elif action == "reset" and run_ok:
        argv = ["standard", "run", "reset", workspace, run_id, "--yes"]
    elif action == "push" and digest_ok:
        argv = ["converter", "push", workspace, "--sha256", digest]
    else:
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    return control_call(control, argv, TIMEOUTS.get(action, DEFAULT_TIMEOUT))


class Handler(BaseHTTPRequestHandler):
    server_version = "silo-runs"
    sys_version = ""

    def log_message(self, *args):  # requests name customers' workspaces; keep them out of logs
        pass

    def send(self, status, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for key, value in HEADERS.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlsplit(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        store, control = self.server.store, self.server.control
        try:
            if url.path in STATIC:
                name, content_type = STATIC[url.path]
                return self.send(200, (HERE / name).read_bytes(), content_type)
            if url.path == "/api/summary":
                return self.send(200, summary(store))
            if url.path == "/api/workspaces":
                return self.send(200, {"workspaces": store.workspaces()})
            if url.path == "/api/overview":
                return self.send(200, overview(store, control, query.get("workspace")))
            if url.path == "/api/plan":
                return self.send(200, plan_detail(store, control, query.get("workspace"), query.get("id")))
            if url.path == "/api/run":
                return self.send(200, run_detail(store, control, query.get("workspace"), query.get("id")))
            if url.path == "/api/push":
                return self.send(200, push_detail(store, query.get("workspace"), query.get("id")))
            return self.send(404, {"error": "STANDARD_NOT_FOUND"})
        except Refused as refused:
            return self.send(refused.status, {"error": refused.code})
        except Exception:  # noqa: BLE001 - never a traceback (it could quote customer text) in term-llm's log
            return self.send(500, {"error": "STANDARD_OPERATION_FAILED"})

    def do_POST(self):
        # term-llm only forwards same-origin, signed-in POSTs; the custom header and JSON body
        # are a second check that the request came from this page's script.
        try:
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            if not 0 < length <= MAX_BODY:
                self.close_connection = True
                raise Refused("STANDARD_ARGUMENTS_INVALID", 413 if length > 0 else 400)
            raw = self.rfile.read(length)
            if self.headers.get("X-Silo-Runs") != "1" or not (self.headers.get("Content-Type") or "").startswith("application/json"):
                raise Refused("STANDARD_REQUEST_REFUSED", 403)
            body = json.loads(raw)
            if not isinstance(body, dict):
                raise Refused("STANDARD_ARGUMENTS_INVALID")
            action = urlsplit(self.path).path.removeprefix("/api/")
            return self.send(200, decide(self.server.store, self.server.control, action, body))
        except (ValueError, UnicodeDecodeError):
            return self.send(400, {"error": "STANDARD_ARGUMENTS_INVALID"})
        except Refused as refused:
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
    control, base = locate()
    # term-llm 0.9.93 puts widget sockets in /tmp/term-llm-widgets without checking who owns it:
    # refuse to run unless the folder is ours and private (the installer reserves it).
    folder = os.lstat(os.path.dirname(argv[1]))
    if not stat.S_ISDIR(folder.st_mode) or folder.st_uid != os.geteuid() or folder.st_mode & 0o077:
        raise SystemExit("runs widget: " + os.path.dirname(argv[1]) + " must be a folder owned by this account, mode 0700")
    os.umask(0o077)
    try:
        os.unlink(argv[1])
    except FileNotFoundError:
        pass
    server = Server(argv[1], Handler)
    server.store, server.control = Store(base), control
    server.serve_forever()


if __name__ == "__main__":
    main(sys.argv)
