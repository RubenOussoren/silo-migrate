"""Findings: the engineer's release gate in the term-llm web UI.

The Project page (widgets/project) imports this and calls its views and decisions; it isn't a page
of its own any more. It lists each workspace's findings from the
standard store (read-only, straight from disk, so lists stay fast however many there are)
and runs every decision through `silo-migrate-control standard finding …`, which locks,
validates and records it. Release and amend take the exact text the engineer sees in the
editor; its SHA-256 is computed here from those bytes. Release and reject also name the
proposal the engineer was shown (its SHA-256, as `detail` reported it): migration-data can
revise a proposal until it is decided, and a decision on a revision nobody read is refused.

Models never reach this: agents have no web UI sign-in, and the socket isn't a TCP port.
"""
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
import unicodedata
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlsplit

WORKSPACE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\Z")
FINDING = re.compile(r"finding-[0-9a-f]{32}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
MAX_REVISIONS = 20             # the store's limit for a proposal's revisions
STATUSES = ("proposed", "released", "rejected", "superseded", "withdrawn")
MAX_TEXT = 256 * 1024          # the store's limit for a finding's text
MAX_STATE = 4 * 1024 * 1024    # the store's limit for state.json
PAGE = 25
SEARCH_LIMIT = 2000            # findings whose first line a search reads
HERE = Path(__file__).resolve().parent
INSTALLED = re.compile(r"(/.+)/releases/[0-9a-f]{40}/integrations/term-llm/widgets/[a-z0-9-]+")
STATIC = {"/": ("index.html", "text/html; charset=utf-8"), "/app.js": ("app.js", "text/javascript; charset=utf-8"),
          "/app.css": ("app.css", "text/css; charset=utf-8")}
HEADERS = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
           "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"}


class Refused(Exception):
    def __init__(self, code, status=400):
        super().__init__(code)
        self.code, self.status = code, status


def locate():
    """(control command, workspaces folder) from the installed layout. SILO_FINDINGS_* are for tests only."""
    if os.environ.get("SILO_TESTING") == "1" and os.environ.get("SILO_FINDINGS_CONTROL"):
        return os.environ["SILO_FINDINGS_CONTROL"], Path(os.environ["SILO_FINDINGS_BASE"])
    installed = INSTALLED.fullmatch(str(HERE))
    if not installed:
        raise SystemExit("findings widget: not an installed release")
    prefix = Path(installed[1])
    base = None
    for line in (prefix / "etc/silo-control.env").read_text().splitlines():
        if line.startswith("SILO_MIGRATE_BASE_PATH="):
            base = line.split("=", 1)[1]
    if not base:
        raise SystemExit("findings widget: SILO_MIGRATE_BASE_PATH missing from etc/silo-control.env")
    return str(prefix / "bin/silo-migrate-control"), Path(base)


def read_file(path, limit, head=None):
    """A regular file, not through a link at its last component, at most `limit` bytes
    (only the first `head` bytes when given)."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise Refused("STANDARD_FILE_INVALID", 500)
        chunks, size = [], 0
        want = min(limit, head) if head else limit
        while size < want:
            chunk = os.read(fd, min(65536, want - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


class Store:
    def __init__(self, base):
        self.base = Path(base)

    def root(self, workspace):
        if not isinstance(workspace, str) or not WORKSPACE.fullmatch(workspace):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        root = self.base / workspace
        standard = root / ".silo-migrate/named/standard"
        # Every level must be a real folder inside the workspaces folder.
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

    def records(self, workspace):
        try:
            state = json.loads(read_file(self.root(workspace) / "state.json", MAX_STATE))
        except (OSError, ValueError, Refused):
            return []
        found = state.get("findings") if isinstance(state, dict) else None
        out = []
        for key, record in (found or {}).items() if isinstance(found, dict) else ():
            if not (isinstance(record, dict) and FINDING.fullmatch(str(key)) and record.get("status") in STATUSES):
                continue
            release = record.get("release") if isinstance(record.get("release"), dict) else {}
            decided = {"released": release.get("released_at"), "rejected": record.get("rejected_at"),
                       "superseded": record.get("superseded_at"), "withdrawn": record.get("withdrawn_at")}.get(record["status"])
            text = lambda value: value if isinstance(value, str) else None  # noqa: E731 - odd JSON types are dropped
            record = dict(record, proposed_at=text(record.get("proposed_at")), supersedes=text(record.get("supersedes")),
                          superseded_by=text(record.get("superseded_by")))
            decided = decided if isinstance(decided, str) else None
            # A proposal from before revisions existed has no number: it is revision 1.
            revision = record.get("proposal_revision", 1)
            revision = revision if type(revision) is int and 1 <= revision <= MAX_REVISIONS else None
            digest = record.get("proposal_sha256")
            digest = digest if isinstance(digest, str) and DIGEST.fullmatch(digest) else None
            out.append({"workspace": workspace, "id": key, "kind": str(record.get("kind") or ""), "status": record["status"],
                        "proposal_revision": revision if digest else None, "proposal_sha256": digest,
                        "proposal_revised_at": text(record.get("proposal_revised_at")),
                        "run_id": record.get("run_id"), "proposed_at": record.get("proposed_at"), "decided_at": decided,
                        "updated_at": decided or record.get("proposed_at") or "",
                        "reviewer": release.get("reviewer") or record.get("rejected_by") or record.get("withdrawn_by"),
                        "sha256": release.get("sha256"), "bytes": release.get("bytes"),
                        "supersedes": record.get("supersedes"), "superseded_by": record.get("superseded_by")})
        return out

    def raw(self, workspace, finding_id, kind, limit=MAX_TEXT, revision=1):
        # Revision 1 of a proposal is proposal.txt; each later one is its own file, never rewritten.
        proposal = "proposal.txt" if revision == 1 else "proposal-%d.txt" % revision
        part = {"proposal": ("private", proposal), "released": ("released", "summary.txt")}[kind]
        standard = self.root(workspace)
        path = standard / "findings" / finding_id / part[0] / part[1]
        # Nothing reached through a link: the folders must resolve inside this store,
        # and read_file refuses a link as the file itself.
        if os.path.realpath(path.parent) != os.path.join(os.path.realpath(standard), "findings", finding_id, part[0]):
            return None
        try:
            return read_file(path, MAX_TEXT, head=limit)
        except (OSError, Refused):
            return None

    def text(self, workspace, finding_id, kind, limit=MAX_TEXT, revision=1):
        data = self.raw(workspace, finding_id, kind, limit, revision)
        return None if data is None else data.decode("utf-8", "replace")

    def proposal(self, record):
        """(text, sha256) of a record's current proposal. The digest is what a release or a rejection
        must name, so it is given only when the bytes read are the recorded revision's: the state and
        an immutable revision file are read without a lock, and both describe the same revision."""
        revision = record.get("proposal_revision")  # None when the record names no usable revision or digest
        data = self.raw(record["workspace"], record["id"], "proposal", revision=revision or 1)
        if data is None:
            return None, None
        digest = hashlib.sha256(data).hexdigest()
        return data.decode("utf-8", "replace"), digest if revision and digest == record.get("proposal_sha256") else None

    def title(self, record):
        # A line of the proposal only when its bytes are the recorded revision's (the whole file is
        # read to check that); otherwise the released text, or nothing.
        text, digest = self.proposal(record)
        text = (text[:4096] if digest else None) or self.text(record["workspace"], record["id"], "released", 4096) or ""
        line = next((line.strip() for line in text.splitlines() if line.strip()), "")
        return line[:120]


def page_of(store, query):
    workspace = query.get("workspace") or ""
    status = query.get("status") or "proposed"
    if status not in STATUSES + ("history", "all"):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    try:
        page = max(0, int(query.get("page") or 0))
    except ValueError:
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    search = (query.get("q") or "").strip().lower()[:200]
    names = [workspace] if workspace else store.workspaces()
    records = [record for name in names for record in store.records(name)]
    if status == "history":
        records = [r for r in records if r["status"] != "proposed"]
    elif status != "all":
        records = [r for r in records if r["status"] == status]
    records.sort(key=lambda r: (r["updated_at"] or "", r["id"]), reverse=True)
    if search:
        def matches(record):
            fields = [record["id"], record["kind"], record["status"], record["workspace"], record.get("reviewer") or ""]
            return any(search in str(field).lower() for field in fields) or search in store.title(record).lower()
        records = [r for r in records[:SEARCH_LIMIT] if matches(r)]
    total = len(records)
    items = records[page * PAGE:(page + 1) * PAGE]
    for record in items:
        record["title"] = store.title(record)
    return {"items": items, "total": total, "page": page, "pages": max(1, -(-total // PAGE)), "page_size": PAGE,
            "workspaces": store.workspaces()}


def summary(store):
    pending = [r for name in store.workspaces() for r in store.records(name) if r["status"] == "proposed"]
    pending.sort(key=lambda r: (r["proposed_at"] or "", r["id"]), reverse=True)
    counts = {}
    for record in pending:
        counts[record["workspace"]] = counts.get(record["workspace"], 0) + 1
    return {"pending": len(pending), "workspaces": [{"workspace": k, "pending": v} for k, v in sorted(counts.items())],
            "latest": [{k: r[k] for k in ("workspace", "id", "kind", "proposed_at")} for r in pending[:8]]}


def detail(store, workspace, finding_id):
    if not isinstance(finding_id, str) or not FINDING.fullmatch(finding_id):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    records = {r["id"]: r for r in store.records(workspace)}
    record = records.get(finding_id)
    if not record:
        raise Refused("STANDARD_REFERENCE_INVALID", 404)
    chain, seen = [], {finding_id}
    cursor = record
    while cursor.get("supersedes") in records and cursor["supersedes"] not in seen:  # older versions
        seen.add(cursor["supersedes"])
        cursor = records[cursor["supersedes"]]
        chain.insert(0, cursor)
    chain.append(record)
    cursor = record
    while cursor.get("superseded_by") in records and cursor["superseded_by"] not in seen:  # newer versions
        seen.add(cursor["superseded_by"])
        cursor = records[cursor["superseded_by"]]
        chain.append(cursor)
    proposal, digest = store.proposal(record)
    return dict(record, proposal=proposal, proposal_sha256=digest, released=store.text(workspace, finding_id, "released"),
                versions=[{k: r[k] for k in ("id", "status", "updated_at")} for r in chain])


def reviewer_name():
    """The engineer's commit identity (the web UI doesn't pass on who is signed in)."""
    name = ""
    try:
        for line in (Path(pwd.getpwuid(os.getuid()).pw_dir) / ".config/silo-migrate/git-identity").read_text().splitlines():
            if line.startswith("name="):
                name = line.split("=", 1)[1].strip()
    except OSError:
        pass
    printable = 1 <= len(name) <= 80 and all(unicodedata.category(c)[0] != "C" for c in name)  # no control/format chars (e.g. U+202E)
    name = name if printable else "engineer"
    return name + " (web UI)"


def decide(control, action, workspace, finding_id, text=None, proposal_sha256=None):
    if action not in ("release", "amend", "reject", "withdraw"):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    if not (isinstance(workspace, str) and WORKSPACE.fullmatch(workspace) and isinstance(finding_id, str) and FINDING.fullmatch(finding_id)):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    # A decision on a proposal names the revision the engineer was shown; there is no default.
    if action in ("release", "reject") and not (isinstance(proposal_sha256, str) and DIGEST.fullmatch(proposal_sha256)):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    argv = [control, "standard", "finding", action, workspace, finding_id]
    data = None
    if action in ("release", "amend"):
        if not isinstance(text, str) or not text.strip() or "\x00" in text:
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        data = text.encode("utf-8")
        if len(data) > MAX_TEXT:
            raise Refused("STANDARD_TEXT_TOO_LARGE")
        argv += ["--file", "-", "--sha256", hashlib.sha256(data).hexdigest()]
    if action in ("release", "reject"):
        argv += ["--expected-proposal-sha256", proposal_sha256]
    argv += ["--reviewer", reviewer_name()]
    try:
        result = subprocess.run(argv, input=data, capture_output=True, timeout=120, stdin=None if data is not None else subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise Refused("STANDARD_OPERATION_TIMEOUT", 504)
    if result.returncode != 0:
        code = re.search(rb"Error: ([A-Z_]+)", result.stderr)
        raise Refused(code.group(1).decode() if code else "STANDARD_OPERATION_FAILED", 409)
    try:
        outcome = json.loads(result.stdout)
    except ValueError:
        raise Refused("STANDARD_OPERATION_FAILED", 502)
    return outcome if isinstance(outcome, dict) else {}


class Handler(BaseHTTPRequestHandler):
    server_version = "silo-findings"
    sys_version = ""

    def log_message(self, *args):  # requests can name customers' workspaces; keep them out of logs
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
        try:
            if url.path in STATIC:
                name, content_type = STATIC[url.path]
                return self.send(200, (HERE / name).read_bytes(), content_type)
            if url.path == "/api/summary":
                return self.send(200, summary(self.server.store))
            if url.path == "/api/findings":
                return self.send(200, page_of(self.server.store, query))
            if url.path == "/api/finding":
                return self.send(200, detail(self.server.store, query.get("workspace"), query.get("id")))
            return self.send(404, {"error": "STANDARD_NOT_FOUND"})
        except Refused as refused:
            return self.send(refused.status, {"error": refused.code})
        except Exception:  # noqa: BLE001 - never a traceback (it could quote customer text) in term-llm's log
            return self.send(500, {"error": "STANDARD_OPERATION_FAILED"})

    def do_POST(self):
        # term-llm only forwards same-origin, signed-in POSTs; the custom header and JSON body
        # are a second check that the request came from this page's script.
        try:
            # Read the (bounded) body first, so a refusal is answered, not cut off mid-request.
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            if not 0 < length <= MAX_TEXT * 7:  # JSON can escape each byte up to 6 bytes
                self.close_connection = True
                raise Refused("STANDARD_ARGUMENTS_INVALID", 413 if length > 0 else 400)
            raw = self.rfile.read(length)
            if self.headers.get("X-Silo-Findings") != "1" or not (self.headers.get("Content-Type") or "").startswith("application/json"):
                raise Refused("STANDARD_REQUEST_REFUSED", 403)
            body = json.loads(raw)
            if not isinstance(body, dict):
                raise Refused("STANDARD_ARGUMENTS_INVALID")
            action = urlsplit(self.path).path.removeprefix("/api/")
            outcome = decide(self.server.control, action, body.get("workspace"), body.get("id"), body.get("text"), body.get("proposal_sha256"))
            return self.send(200, outcome)
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
    # term-llm 0.9.93 puts widget sockets in /tmp/term-llm-widgets without checking who owns it.
    # If another account owned it, it could swap in its own socket and page under the web UI's
    # origin: refuse to run unless the folder is ours and private (the installer reserves it).
    folder = os.lstat(os.path.dirname(argv[1]))
    if not stat.S_ISDIR(folder.st_mode) or folder.st_uid != os.geteuid() or folder.st_mode & 0o077:
        raise SystemExit("findings widget: " + os.path.dirname(argv[1]) + " must be a folder owned by this account, mode 0700")
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
