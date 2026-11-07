"""Host-side converter development for the converter-developer and reviewer agents.

Imported by bin/silo-migrate-control. Agent operations only ever see, in
workspaces/<ws>/converter, files whose current content Git or the agent vouches for:
tracked at HEAD and unchanged from the HEAD blob, or last written by the developer's
tools (SHA-256 recorded in the workspace's converter-dev-files.json). Every other file
is invisible whatever .gitignore says (the converter repository's .gitignore doesn't
cover everything a run or an engineer might leave there), as are .git, symlinks,
other workspace content and customer data: never read, listed, searched, exported to
tests or committed. Commits are built from exactly those verified bytes. term-llm runs custom
tools without an approval prompt, so every limit is enforced here.

The engineer's push approval (`converter push WS --sha256 DIGEST`) is the only path
that reads the GitHub token; no agent operation does.

Trust boundary: the service account (and an engineer approving its writes) is inside
it; same-account races between checking and opening a path are not defended.
"""
import datetime
import difflib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

WORKSPACE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\Z")
TOPIC = re.compile(r"[a-z0-9][a-z0-9._-]{0,47}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
GITHUB_REMOTE = re.compile(r"https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]{1,100}?)(?:\.git)?/?\Z")
TOKEN_TEXT = re.compile(r"[A-Za-z0-9_]{20,255}\Z")
# term-llm 0.9.93 cuts custom tool output at 50 KiB; stay well under it.
MAX_TEXT_BYTES = 32 * 1024
MAX_LINES = 2000
MAX_LINE_CHARS = 2000
MAX_WRITE_BYTES = 512 * 1024
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_MATCHES = 200
MAX_COMMITS = 50
TEST_TIMEOUT = 240
# Paths an agent may never write: they change what Git ignores or how it treats
# files, or (workflows) need a token permission the engineer did not grant.
PROTECTED_NAMES = {".gitignore", ".gitattributes", ".gitmodules", ".git"}
# Agents can't edit what selects gems: the dependency step (see prepare_dependencies)
# installs exactly what the checkout's committed Gemfile.lock pins, with network.
PROTECTED_PATHS = {"Gemfile", "Gemfile.lock", ".bundle/config"}
ROLES = {
    "developer": {"list", "read", "search", "status", "diff", "test", "push-show",
                  "write", "edit", "delete", "branch", "commit", "push-propose"},
    "reviewer": {"list", "read", "search", "status", "diff", "test", "push-show"},
}
TRAILER = {"developer": "Assisted-by: converter-developer (term-llm agent)"}


class Refusal(ValueError):
    pass


def refuse(code):
    raise Refusal(code)


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def git_env(extra=None):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0", LC_ALL="C")
    env.update(extra or {})
    return env


class Checkout:
    """One workspace's converter checkout, gated before any Git command."""

    def __init__(self, base, workspace, host):
        if not isinstance(workspace, str) or not WORKSPACE.fullmatch(workspace):
            refuse("STANDARD_ARGUMENTS_INVALID")
        self.workspace = workspace
        self.host = host
        self.root = Path(base) / workspace
        if self.root.is_symlink() or not (self.root / ".silo-migrate/named/state.json").is_file():
            refuse("STANDARD_NOT_INITIALIZED")
        self.standard = self.root / ".silo-migrate/named/standard"
        self.state = json.loads((self.standard / "state.json").read_text())
        self.config = self.state["config"]
        path = self.root / "converter"
        if path.is_symlink() or not path.is_dir():
            refuse("STANDARD_CONVERTER_MISSING")
        if Path(self.config["converter_worktree"]).resolve() != path.resolve():
            refuse("STANDARD_RUNTIME_MISMATCH")
        self.path = path.resolve()
        host.converter_config_safe(self.path)
        self.argv = host.converter_git(self.path)

    def git(self, *args, ok=(0,), input=None, env=None, timeout=60, extra=()):
        try:
            result = subprocess.run([*self.argv[:-2], *extra, *self.argv[-2:], *args], input=input, capture_output=True,
                                    env=git_env(env), timeout=timeout)
        except subprocess.TimeoutExpired:
            refuse("STANDARD_OPERATION_TIMEOUT")
        if result.returncode not in ok:
            refuse("STANDARD_OPERATION_FAILED")
        return result

    def out(self, *args, **kwargs):
        return self.git(*args, **kwargs).stdout.decode("utf-8", "replace")

    # -- what an agent may see ------------------------------------------------
    # A file is visible only while its *content* is one Git or the agent vouches for:
    # tracked at HEAD and unchanged from its HEAD blob, or last written by the agent
    # (SHA-256 recorded at that write). A run or a person changing a file in the
    # checkout makes it invisible; untracked files nobody recorded never appear.

    def manifest_path(self):
        return self.standard / "converter-dev-files.json"

    def manifest(self):
        path = self.manifest_path()
        data = {}
        if path.is_file() and not path.is_symlink():
            try:
                data = json.loads(path.read_text())
            except ValueError:
                data = {}
        if not isinstance(data, dict):
            data = {}
        files = data.get("files") if isinstance(data.get("files"), dict) else {}
        branches = data.get("branches") if isinstance(data.get("branches"), list) else []
        return {"files": {k: v for k, v in files.items() if isinstance(k, str) and isinstance(v, str)},
                "branches": [b for b in branches if isinstance(b, str)]}

    def save_manifest(self, data):
        path = self.manifest_path()
        # A unique temporary name: concurrent savers must never share (and steal) one file.
        descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
        try:
            with os.fdopen(descriptor, "w") as stream:
                stream.write(json.dumps({"files": dict(sorted(data["files"].items())), "branches": sorted(set(data["branches"]))}, indent=1) + "\n")
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        self._visible = None

    def record_write(self, relative, data):
        manifest = self.manifest()
        manifest["files"][relative] = hashlib.sha256(data).hexdigest()
        self.save_manifest(manifest)

    def forget(self, relatives):
        manifest = self.manifest()
        for relative in relatives:
            manifest["files"].pop(relative, None)
        self.save_manifest(manifest)

    def tree(self):
        """{path: (mode, object id)} of HEAD."""
        if getattr(self, "_tree", None) is None:
            raw = self.git("ls-tree", "-r", "-z", "--full-tree", "HEAD").stdout.decode("utf-8", "surrogateescape")
            tree = {}
            for record in raw.split("\0"):
                meta, _, name = record.partition("\t")
                parts = meta.split()
                if name and len(parts) == 3:
                    tree[name] = (parts[0], parts[2])
            self._tree = tree
        return self._tree

    def blob_id(self, data):
        if getattr(self, "_format", None) is None:
            self._format = self.out("rev-parse", "--show-object-format").strip() or "sha1"
        digest = hashlib.new("sha256" if self._format == "sha256" else "sha1")
        digest.update(b"blob %d\0" % len(data))
        digest.update(data)
        return digest.hexdigest()

    def vouched(self, relative, data):
        entry = self.tree().get(relative)
        if entry and entry[0] in ("100644", "100755") and self.blob_id(data) == entry[1]:
            return True
        recorded = self.manifest()["files"].get(relative)
        return recorded is not None and hashlib.sha256(data).hexdigest() == recorded

    def load(self, relative):
        """(bytes, stat) of a visible file, verified on exactly the bytes returned."""
        if any(part in PROTECTED_NAMES - {".gitignore", ".gitattributes"} for part in relative.split("/")) or not self.inside(relative):
            refuse("STANDARD_DEV_PATH_NOT_VISIBLE")
        try:
            descriptor = os.open(self.path / relative, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0))
        except OSError:
            refuse("STANDARD_DEV_PATH_NOT_VISIBLE")
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            os.close(descriptor)
            refuse("STANDARD_DEV_PATH_NOT_VISIBLE")
        with os.fdopen(descriptor, "rb") as stream:
            if info.st_size > MAX_FILE_BYTES:
                refuse("STANDARD_DEV_FILE_TOO_LARGE")
            data = stream.read(MAX_FILE_BYTES + 1)
        if not self.vouched(relative, data):
            refuse("STANDARD_DEV_PATH_NOT_VISIBLE")
        return data, info

    def visible(self, prefix=""):
        """Visible files (see above), optionally under a prefix."""
        if getattr(self, "_visible", None) is None:
            names = set(self.tree()) | set(self.manifest()["files"])
            files = []
            for name in sorted(names):
                try:
                    self.load(name)
                except Refusal:
                    continue
                files.append(name)
            self._visible = files
        if not prefix:
            return list(self._visible)
        return [name for name in self._visible if name == prefix or name.startswith(prefix if prefix.endswith("/") else prefix + "/")]

    def inside(self, relative):
        """No component of the path is a symlink and it resolves inside the checkout."""
        current = self.path
        for part in relative.split("/"):
            current = current / part
            try:
                if stat.S_ISLNK(os.lstat(current).st_mode):
                    return False
            except FileNotFoundError:
                break
        resolved = os.path.realpath(self.path / relative)
        return resolved == str(self.path) or resolved.startswith(str(self.path) + "/")

    def ignored(self, relative):
        result = self.git("check-ignore", "-q", "--", relative, ok=(0, 1))
        return result.returncode == 0

    def running(self):
        return any(run.get("status") in ("claimed", "running") for run in self.state.get("runs", {}).values())

    def branch(self):
        return self.out("rev-parse", "--abbrev-ref", "HEAD").strip()

    def head(self):
        head = self.out("rev-parse", "HEAD").strip()
        if not re.fullmatch(r"[0-9a-f]{40}", head):
            refuse("STANDARD_RUNTIME_MISMATCH")
        return head

    def migration_prefix(self):
        return "migration/" + self.workspace + "/"


def relative_path(raw, allow_root=False):
    if raw is None and allow_root:
        return ""
    if not isinstance(raw, str) or len(raw) > 1024 or "\0" in raw or "\\" in raw or raw.startswith("/") or raw.startswith("~"):
        refuse("STANDARD_ARGUMENTS_INVALID")
    parts = [part for part in raw.split("/") if part not in ("", ".")]
    if ".." in parts:
        refuse("STANDARD_DEV_PATH_REFUSED")
    if not parts:
        if allow_root:
            return ""
        refuse("STANDARD_ARGUMENTS_INVALID")
    if ".git" in parts:
        refuse("STANDARD_DEV_PATH_REFUSED")
    return "/".join(parts)


def text_lines(stream, start):
    lines, used, next_line = [], 0, None
    for number, raw in enumerate(stream, 1):
        if number < start:
            continue
        text = raw.decode("utf-8", "replace")
        if len(text) > MAX_LINE_CHARS:
            text = text[:MAX_LINE_CHARS].rstrip("\n") + " …[line truncated]\n"
        cost = len(json.dumps(text).encode("utf-8"))
        if len(lines) >= MAX_LINES or used + cost > MAX_TEXT_BYTES:
            next_line = number
            break
        lines.append(text)
        used += cost
    return lines, next_line


def bounded(text, limit=MAX_TEXT_BYTES):
    data = text.encode("utf-8", "replace")
    if len(data) <= limit:
        return text, False
    return data[:limit].decode("utf-8", "ignore") + "\n…[truncated]\n", True


# -- read-only operations ------------------------------------------------------

def op_list(checkout, request):
    directory = relative_path(request.get("path"), allow_root=True)
    prefix = directory + "/" if directory else ""
    entries = {}
    for name in checkout.visible(prefix):
        rest = name[len(prefix):]
        child, _, deeper = rest.partition("/")
        if deeper:
            entry = entries.setdefault(child, {"name": child, "type": "dir", "files": 0})
            entry["files"] += 1
        else:
            entries[child] = {"name": child, "type": "file", "bytes": os.lstat(checkout.path / name).st_size}
    if directory and not entries:
        refuse("STANDARD_DEV_PATH_NOT_VISIBLE")
    listed, used, truncated = [], 0, False
    for entry in sorted(entries.values(), key=lambda item: (item["type"] != "dir", item["name"])):
        cost = len(json.dumps(entry)) + 2
        if used + cost > MAX_TEXT_BYTES:
            truncated = True
            break
        listed.append(entry)
        used += cost
    return {"path": directory or ".", "entries": listed, "total": len(entries), "truncated": truncated,
            "note": "Only files tracked at HEAD (unchanged since, or changed by your own tools) and files you created are listed."}


def op_read(checkout, request):
    relative = relative_path(request.get("path"))
    start = request.get("start_line", 1)
    if not isinstance(start, int) or isinstance(start, bool) or start < 1:
        refuse("STANDARD_ARGUMENTS_INVALID")
    data, info = checkout.load(relative)
    if b"\0" in data[:8192]:
        return {"path": relative, "bytes": info.st_size, "binary": True}
    lines, next_line = text_lines(io.BytesIO(data), start)
    return {"path": relative, "bytes": info.st_size, "start_line": start, "lines": len(lines), "next_line": next_line, "text": "".join(lines)}


def op_search(checkout, request):
    pattern = request.get("pattern")
    if not isinstance(pattern, str) or not pattern or len(pattern) > 300 or "\0" in pattern or "\n" in pattern:
        refuse("STANDARD_ARGUMENTS_INVALID")
    directory = relative_path(request.get("path"), allow_root=True)
    flags = ["--fixed-strings"] if request.get("fixed", True) else ["--extended-regexp"]
    if request.get("ignore_case"):
        flags.append("--ignore-case")
    # Tracked files through Git (results are kept only for visible files), the agent's
    # own new files through --no-index: one regex engine, no untracked discovery.
    scope = directory + "/" if directory else ""
    result = checkout.git("grep", "-z", "-n", "-I", "--no-color", *flags, "-e", pattern, "--",
                          *([":(literal)" + directory] if directory else []), ok=(0, 1, 128), timeout=60)
    if result.returncode == 128:
        refuse("STANDARD_ARGUMENTS_INVALID")
    records = result.stdout.decode("utf-8", "replace").split("\n")
    created = [name for name in checkout.visible(scope) if name not in checkout.tree()]
    if created:
        extra = checkout.git("--literal-pathspecs", "grep", "--no-index", "-z", "-n", "-I", "--no-color", *flags, "-e", pattern, "--", *created,
                             ok=(0, 1, 128), timeout=60)
        if extra.returncode == 128:
            refuse("STANDARD_ARGUMENTS_INVALID")
        records += extra.stdout.decode("utf-8", "replace").split("\n")
    visible = None
    matches, used, truncated = [], 0, False
    for record in records:
        if not record:
            continue
        name, _, rest = record.partition("\0")
        found = re.match(r"(\d+)[:\0](.*)\Z", rest, re.S)
        number, text = (found[1], found[2]) if found else ("", rest)
        if any(part in PROTECTED_NAMES - {".gitignore", ".gitattributes"} for part in name.split("/")):
            continue
        if visible is None:
            visible = set(checkout.visible(directory + "/" if directory else ""))
        if name not in visible:
            continue
        match = {"path": name, "line": int(number) if number.isdigit() else None, "text": text[:300]}
        cost = len(json.dumps(match)) + 2
        if len(matches) >= MAX_MATCHES or used + cost > MAX_TEXT_BYTES:
            truncated = True
            break
        matches.append(match)
        used += cost
    return {"matches": matches, "truncated": truncated}


def status_entries(checkout):
    raw = checkout.git("--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all").stdout
    entries, records = [], raw.decode("utf-8", "surrogateescape").split("\0")
    index = 0
    while index < len(records):
        record = records[index]
        index += 1
        if len(record) < 4:
            continue
        code, name = record[:2], record[3:]
        if code[0] in "RC":
            index += 1  # rename source follows
        entries.append({"status": code.strip() or code, "path": name})
    return entries


def changes(checkout):
    """Status entries an agent may see and commit: visible files (tracked at HEAD or created by
    the agent) and deletions of files tracked at HEAD. Anything else is only counted."""
    entries = status_entries(checkout)
    visible = set(checkout.visible())
    tracked = checkout.tree()
    shown, hidden = [], 0
    for entry in entries:
        deleted = "D" in entry["status"] and entry["path"] in tracked and not os.path.lexists(checkout.path / entry["path"])
        if entry["path"] in visible or deleted:
            shown.append(entry)
        else:
            hidden += 1
    return shown, hidden


def unpushed(checkout):
    raw = checkout.out("log", "--format=%H%x00%an%x00%ae%x00%s", "-n", str(MAX_COMMITS + 1), "HEAD", "--not", "--remotes=origin")
    commits = []
    for line in raw.splitlines():
        sha, name, email, subject = (line.split("\0") + ["", "", "", ""])[:4]
        commits.append({"sha": sha, "author": name + " <" + email + ">", "subject": subject})
    return commits


def op_status(checkout, request):
    commits = unpushed(checkout)
    shown, hidden = changes(checkout)
    return {"branch": checkout.branch(), "head": checkout.head(), "changes": shown[:500], "other_changes_not_shown": hidden,
            "unpushed_commits": commits[:MAX_COMMITS], "unpushed_truncated": len(commits) > MAX_COMMITS,
            "migration_branch_prefix": checkout.migration_prefix()}


def converter_log(checkout, limit=30):
    """Engineer view (the Runs widget): where the checkout is, what is committed and what has
    reached GitHub. Commits are pushed when an origin branch contains them."""
    unpushed_shas = {commit["sha"] for commit in unpushed(checkout)}
    commits = []
    for line in checkout.out("log", "--format=%H%x00%an%x00%aI%x00%s", "-n", str(limit), "HEAD").splitlines():
        sha, name, date, subject = (line.split("\0") + ["", "", "", ""])[:4]
        if re.fullmatch(r"[0-9a-f]{40}", sha):
            commits.append({"sha": sha, "author": name[:120], "date": date[:40], "subject": subject[:200], "pushed": sha not in unpushed_shas})
    branches = []
    refs = checkout.out("for-each-ref", "--format=%(refname:short)%00%(objectname)%00%(committerdate:iso-strict)",
                        "refs/heads/" + checkout.migration_prefix())
    for line in refs.splitlines()[:50]:
        name, sha, date = (line.split("\0") + ["", "", ""])[:3]
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            continue
        ahead = checkout.out("rev-list", "--count", sha, "--not", "--remotes=origin").strip()
        on_remote = checkout.git("show-ref", "--verify", "--quiet", "refs/remotes/origin/" + name, ok=(0, 1)).returncode == 0
        branches.append({"name": name, "head": sha, "date": date[:40], "not_pushed": int(ahead) if ahead.isdigit() else None, "on_github": on_remote})
    base = checkout.git("show-ref", "--verify", "--quiet", "refs/remotes/origin/main", ok=(0, 1)).returncode == 0
    ahead_of_main = checkout.out("rev-list", "--count", "HEAD", "--not", "refs/remotes/origin/main").strip() if base else ""
    shown, hidden = changes(checkout)
    return {"workspace": checkout.workspace, "branch": checkout.branch(), "head": checkout.head(), "uncommitted": len(shown) + hidden,
            "ahead_of_main": int(ahead_of_main) if ahead_of_main.isdigit() else None, "not_pushed": len(unpushed_shas),
            "commits": commits, "branches": branches}


EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def op_diff(checkout, request):
    scope = request.get("scope", "working")
    path = relative_path(request.get("path"), allow_root=True)
    spec = ["--", ":(literal)" + path] if path else []
    no_drivers = ["--no-color", "--no-ext-diff", "--no-textconv"]
    if scope == "working":
        # Only visible changed paths: never an engineer's staged file or content changed outside the tools.
        names = [entry["path"] for entry in changes(checkout)[0] if not path or entry["path"] == path or entry["path"].startswith(path + "/")]
        tracked = [name for name in names if name in checkout.tree()]
        text = stat_text = ""
        if tracked:
            text = checkout.out("--literal-pathspecs", "diff", *no_drivers, "HEAD", "--", *tracked)
            stat_text = checkout.out("--literal-pathspecs", "diff", "--stat=120", *no_drivers, "HEAD", "--", *tracked)
        for name in names:
            if name not in checkout.tree():
                extra = checkout.git("diff", *no_drivers, "--no-index", "--", "/dev/null", name, ok=(0, 1)).stdout
                text += extra.decode("utf-8", "replace")
                stat_text += " " + name + " (new)\n"
    elif scope == "unpushed":
        commits = unpushed(checkout)
        if not commits:
            return {"scope": scope, "stat": "", "diff": "", "truncated": False, "note": "No unpushed commits."}
        if len(commits) > MAX_COMMITS:
            refuse("STANDARD_DEV_TOO_MANY_COMMITS")
        oldest = commits[-1]["sha"]
        parents = checkout.out("rev-list", "--parents", "-n", "1", oldest).split()
        base = parents[1] if len(parents) > 1 else EMPTY_TREE
        text = checkout.out("diff", *no_drivers, base, "HEAD", *spec)
        stat_text = checkout.out("diff", "--stat=120", *no_drivers, base, "HEAD", *spec)
    else:
        refuse("STANDARD_ARGUMENTS_INVALID")
    stat_text, _ = bounded(stat_text, 6 * 1024)
    diff_text, truncated = bounded(text, MAX_TEXT_BYTES - len(stat_text.encode()) - 512)
    return {"scope": scope, "stat": stat_text, "diff": diff_text, "truncated": truncated,
            "note": "Use path to see one file's diff when truncated." if truncated else ""}


# -- writes (developer) ----------------------------------------------------------

def writable(checkout, relative, must_exist):
    parts = relative.split("/")
    if any(part in PROTECTED_NAMES for part in parts) or relative.startswith((".github/workflows/", ".bundle/")) or relative in PROTECTED_PATHS:
        refuse("STANDARD_DEV_PATH_PROTECTED")
    if not checkout.inside(relative):
        refuse("STANDARD_DEV_PATH_REFUSED")
    target = checkout.path / relative
    exists = os.path.lexists(target)
    if exists:
        if relative not in checkout.visible(relative):
            refuse("STANDARD_DEV_PATH_NOT_VISIBLE")
    elif must_exist:
        refuse("STANDARD_DEV_PATH_NOT_VISIBLE")
    elif checkout.ignored(relative):
        refuse("STANDARD_DEV_PATH_IGNORED")
    return target, exists


def atomic_write(target, data, mode):
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".silo-dev-", dir=target.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def small_diff(relative, before, after):
    lines = difflib.unified_diff(before.splitlines(True), after.splitlines(True), "a/" + relative, "b/" + relative)
    return bounded("".join(lines), 8 * 1024)[0]


def op_write(checkout, request):
    relative = relative_path(request.get("path"))
    content = request.get("content")
    if not isinstance(content, str) or len(content.encode("utf-8")) > MAX_WRITE_BYTES or "\0" in content:
        refuse("STANDARD_ARGUMENTS_INVALID")
    target, exists = writable(checkout, relative, must_exist=False)
    before = ""
    mode = 0o644
    if exists:
        data, info = checkout.load(relative)
        before = data.decode("utf-8", "replace")
        mode = stat.S_IMODE(info.st_mode) & 0o755
    atomic_write(target, content.encode("utf-8"), mode)
    try:
        checkout.record_write(relative, content.encode("utf-8"))
    except Exception:
        # Never leave a file the agent wrote but can't see: remove it, or put the old bytes back.
        try:
            atomic_write(target, data, mode) if exists else os.unlink(target)
        except OSError:
            pass
        raise
    return {"path": relative, "created": not exists, "bytes": len(content.encode("utf-8")), "diff": small_diff(relative, before, content)}


def op_edit(checkout, request):
    relative = relative_path(request.get("path"))
    old, new = request.get("old_text"), request.get("new_text")
    if not (isinstance(old, str) and old and isinstance(new, str)) or "\0" in old + new:
        refuse("STANDARD_ARGUMENTS_INVALID")
    target, _ = writable(checkout, relative, must_exist=True)
    raw, info = checkout.load(relative)
    if b"\0" in raw[:8192]:
        refuse("STANDARD_DEV_BINARY")
    before = raw.decode("utf-8")
    count = before.count(old)
    if count == 0:
        refuse("STANDARD_DEV_EDIT_NOT_FOUND")
    if count > 1 and not request.get("replace_all"):
        refuse("STANDARD_DEV_EDIT_AMBIGUOUS")
    after = before.replace(old, new)
    if len(after.encode("utf-8")) > MAX_WRITE_BYTES:
        refuse("STANDARD_ARGUMENTS_INVALID")
    atomic_write(target, after.encode("utf-8"), stat.S_IMODE(info.st_mode) & 0o755)
    try:
        checkout.record_write(relative, after.encode("utf-8"))
    except Exception:
        try:
            atomic_write(target, raw, stat.S_IMODE(info.st_mode) & 0o755)  # back to the visible version
        except OSError:
            pass
        raise
    return {"path": relative, "replacements": count, "diff": small_diff(relative, before, after)}


def op_delete(checkout, request):
    relative = relative_path(request.get("path"))
    target, _ = writable(checkout, relative, must_exist=True)
    os.unlink(target)
    checkout.forget([relative])
    return {"path": relative, "deleted": True}


# -- branch, commit, push ----------------------------------------------------------

# Operations that change the checkout or the manifest of what the agent wrote. Models often send
# several tool calls at once; these run one at a time per workspace (reads don't wait).
MUTATING = {"write", "edit", "delete", "branch", "commit", "push-propose"}
DEV_LOCK_WAIT = 25  # the adapter gives a call 55 s; leave the operation itself ~30 s


class DevLock:
    def __init__(self, checkout, wait=DEV_LOCK_WAIT):
        self.checkout, self.wait = checkout, wait

    def __enter__(self):
        import fcntl
        try:
            self.fd = os.open(self.checkout.standard / "converter-dev.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        except OSError:
            refuse("STANDARD_PATH_INVALID")
        deadline = time.monotonic() + self.wait
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    os.close(self.fd)
                    refuse("STANDARD_BUSY")
                time.sleep(0.05)

    def __exit__(self, *exc):
        os.close(self.fd)


class Locked:
    """The workspace op.lock, as `converter update` and StandardStore take it."""

    def __init__(self, checkout):
        self.checkout = checkout

    def __enter__(self):
        import fcntl
        # As StandardStore opens it: created if missing (a workspace that never ran anything has
        # none yet), never through a link, never truncated.
        try:
            self.fd = os.open(self.checkout.standard / "op.lock", os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        except FileNotFoundError:
            refuse("STANDARD_NOT_INITIALIZED")
        except OSError:  # a link (ELOOP) or anything else odd: refuse, never follow
            refuse("STANDARD_PATH_INVALID")
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.fd)
            refuse("STANDARD_BUSY")
        self.checkout.state = json.loads((self.checkout.standard / "state.json").read_text())
        if self.checkout.running():
            os.close(self.fd)
            refuse("STANDARD_BUSY")
        return self

    def __exit__(self, *exc):
        os.close(self.fd)


def op_branch(checkout, request):
    topic = request.get("topic")
    if not isinstance(topic, str) or not TOPIC.fullmatch(topic) or ".." in topic or topic.endswith((".", ".lock")):
        refuse("STANDARD_ARGUMENTS_INVALID")
    name = checkout.migration_prefix() + topic
    checkout.git("check-ref-format", "--branch", name)
    with Locked(checkout):
        exists = checkout.git("show-ref", "--verify", "--quiet", "refs/heads/" + name, ok=(0, 1)).returncode == 0
        manifest = checkout.manifest()
        if exists and name != checkout.branch() and name not in manifest["branches"]:
            # Switching makes that branch's HEAD tree visible: only branches this agent
            # created, or whose tip is already on the remote, are trusted.
            tip = checkout.out("rev-parse", "refs/heads/" + name).strip()
            if not checkout.out("for-each-ref", "--count=1", "--contains", tip, "--format=%(refname)", "refs/remotes/origin").strip():
                refuse("STANDARD_DEV_BRANCH_UNTRUSTED")
        checkout.git("switch", *([] if exists else ["-c"]), name)
        if not exists:
            manifest["branches"].append(name)
            checkout.save_manifest(manifest)
        checkout._tree = checkout._visible = None
    return {"branch": name, "created": not exists, "head": checkout.head(),
            "note": "Uncommitted changes, if any, came along. Workflow runs use the committed head of this checkout (migration-data binds it when it proposes a run)."}


def identity(checkout, home):
    name = checkout.out("config", "--local", "--get", "user.name", ok=(0, 1)).strip()
    email = checkout.out("config", "--local", "--get", "user.email", ok=(0, 1)).strip()
    if not (name and email):
        path = Path(home) / ".config/silo-migrate/git-identity"
        try:
            info = os.lstat(path)
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o022:
                values = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
                name, email = values.get("name", "").strip(), values.get("email", "").strip()
        except OSError:
            pass
    if not (name and email) or len(name) > 100 or len(email) > 200 or "\n" in name + email or "@" not in email:
        refuse("STANDARD_DEV_IDENTITY_MISSING")
    return name, email


def op_commit(checkout, request, home):
    message = request.get("message")
    if not isinstance(message, str) or not message.strip() or len(message) > 5000 or "\0" in message:
        refuse("STANDARD_ARGUMENTS_INVALID")
    subject = message.strip().splitlines()[0]
    if len(subject) > 100:
        refuse("STANDARD_DEV_SUBJECT_TOO_LONG")
    with Locked(checkout):
        if not checkout.branch().startswith(checkout.migration_prefix()):
            refuse("STANDARD_DEV_NOT_MIGRATION_BRANCH")
        name_, email = identity(checkout, home)
        # The commit is built from exactly the verified bytes of visible changes (and
        # deletions of tracked files) in a temporary index: nothing else in the working
        # tree or the engineer's index can enter it, and no hook runs.
        paths = [entry["path"] for entry in changes(checkout)[0]]
        if not paths:
            refuse("STANDARD_DEV_NOTHING_TO_COMMIT")
        parent = checkout.head()
        with tempfile.TemporaryDirectory(prefix="silo-dev-commit-") as scratch:
            index = {"GIT_INDEX_FILE": os.path.join(scratch, "index")}
            checkout.git("read-tree", parent, env=index)
            for name in paths:
                if not os.path.lexists(checkout.path / name):
                    checkout.git("--literal-pathspecs", "update-index", "--force-remove", "--", name, env=index)
                    continue
                data, info = checkout.load(name)
                blob = checkout.out("hash-object", "-w", "--no-filters", "--stdin", input=data).strip()
                mode = checkout.tree()[name][0] if name in checkout.tree() else ("100755" if info.st_mode & 0o111 else "100644")
                checkout.git("--literal-pathspecs", "update-index", "--add", "--cacheinfo", mode + "," + blob + "," + name, env=index)
            tree = checkout.out("write-tree", env=index).strip()
            text = checkout.git("stripspace", input=message.encode("utf-8")).stdout
            text = checkout.git("interpret-trailers", "--trailer", TRAILER["developer"], input=text).stdout
            env = {"GIT_AUTHOR_NAME": name_, "GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_NAME": name_, "GIT_COMMITTER_EMAIL": email}
            commit = checkout.out("commit-tree", tree, "-p", parent, "-F", "-", input=text, env=env).strip()
        # Compare-and-swap: refuses if HEAD moved meanwhile.
        checkout.git("update-ref", "-m", "commit (converter-developer)", "HEAD", commit, parent)
        # Bring the real index in line for these paths only; other staged entries stay.
        warning = None
        try:
            checkout.git("--literal-pathspecs", "reset", "-q", "--", *paths)
        except Refusal:
            warning = "Committed, but the index for these paths was not refreshed; the engineer can run git reset -q -- PATHS."
        checkout._tree = checkout._visible = None
        checkout.forget(paths)
    result = {"commit": checkout.head(), "branch": checkout.branch(), "subject": subject, "author": name_ + " <" + email + ">", "files": paths}
    if warning:
        result["warning"] = warning
    return result


def github_target(checkout):
    url = checkout.out("remote", "get-url", "origin").strip()
    match = GITHUB_REMOTE.fullmatch(url)
    if not match:
        refuse("STANDARD_PUSH_REMOTE")
    return {"url": "https://github.com/" + match[1] + "/" + match[2] + ".git", "owner": match[1], "repo": match[2]}


def proposal_dir(checkout):
    path = checkout.standard / "converter-pushes"
    path.mkdir(mode=0o700, exist_ok=True)
    if path.is_symlink():
        refuse("STANDARD_OPERATION_FAILED")
    return path


def current_proposal(checkout, request_base, title, body):
    branch = checkout.branch()
    if not branch.startswith(checkout.migration_prefix()):
        refuse("STANDARD_DEV_NOT_MIGRATION_BRANCH")
    if changes(checkout)[0]:
        refuse("STANDARD_CONVERTER_DIRTY")
    commits = unpushed(checkout)
    if not commits:
        refuse("STANDARD_DEV_NOTHING_TO_PUSH")
    if len(commits) > MAX_COMMITS:
        refuse("STANDARD_DEV_TOO_MANY_COMMITS")
    target = github_target(checkout)
    base = request_base
    if not isinstance(base, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,100}", base) or ".." in base:
        refuse("STANDARD_ARGUMENTS_INVALID")
    if checkout.git("show-ref", "--verify", "--quiet", "refs/remotes/origin/" + base, ok=(0, 1)).returncode:
        refuse("STANDARD_PUSH_BASE_UNKNOWN")
    files = checkout.out("diff", "--name-status", "--no-color", "--no-ext-diff", "--no-renames", "refs/remotes/origin/" + base + "...HEAD").splitlines()
    stat_text = checkout.out("diff", "--stat=100", "--no-color", "--no-ext-diff", "refs/remotes/origin/" + base + "...HEAD")
    return {"version": 1, "workspace": checkout.workspace, "repository": target["owner"] + "/" + target["repo"],
            "branch": branch, "base": base, "head": checkout.head(), "commits": commits,
            "files": files[:300], "files_total": len(files), "stat": bounded(stat_text, 4096)[0], "title": title, "body": body}


def op_push_propose(checkout, request):
    title, body = request.get("title"), request.get("body", "")
    if not isinstance(title, str) or not title.strip() or len(title) > 120 or "\n" in title:
        refuse("STANDARD_ARGUMENTS_INVALID")
    if not isinstance(body, str) or len(body) > 20000 or "\0" in body:
        refuse("STANDARD_ARGUMENTS_INVALID")
    proposal = current_proposal(checkout, request.get("base", "main"), title.strip(), body)
    digest = hashlib.sha256(canonical(proposal).encode("utf-8")).hexdigest()
    record = {"digest": digest, "status": "proposed", "proposed_at": now(), "proposal": proposal}
    path = proposal_dir(checkout) / (digest + ".json")
    # Earlier proposals for this branch still waiting are replaced by this one.
    for older in load_proposals(checkout):
        if older.get("status") == "proposed" and older.get("digest") != digest and (older.get("proposal") or {}).get("branch") == proposal["branch"]:
            older_path = proposal_dir(checkout) / (str(older.get("digest")) + ".json")
            if DIGEST.fullmatch(str(older.get("digest"))) and older_path.is_file() and not older_path.is_symlink():
                write_record(older_path, dict(older, status="superseded", superseded_by=digest, superseded_at=now()))
    if not path.exists():
        temporary = path.with_name("." + digest + ".tmp")
        temporary.write_text(json.dumps(record, indent=2) + "\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    return {"digest": digest, "status": "proposed", "proposal": proposal,
            "approve": "silo-migrate-control converter push " + checkout.workspace + " --sha256 " + digest,
            "note": "Nothing is pushed until the engineer approves it in the web UI's Runs widget (or runs the approve command). A draft PR is then opened with the server's GitHub token."}


def load_proposals(checkout):
    directory = checkout.standard / "converter-pushes"
    if not directory.is_dir() or directory.is_symlink():
        return []
    records = []
    for path in sorted(directory.glob("*.json")):
        if path.is_symlink() or not DIGEST.fullmatch(path.stem):
            continue
        try:
            records.append(json.loads(path.read_text()))
        except (OSError, ValueError):
            continue
    return sorted(records, key=lambda record: record.get("proposed_at", ""), reverse=True)


def op_push_show(checkout, request, full=False):
    records = load_proposals(checkout)
    digest = request.get("digest")
    if digest is not None:
        records = [record for record in records if record.get("digest") == digest]
    shown = []
    for record in records[:5 if full else 2]:
        proposal = dict(record.get("proposal", {}))
        if not full:
            # The agent's view stays well under the tool limit; the engineer's CLI shows it all.
            proposal["body"] = bounded(proposal.get("body", ""), 4096)[0]
            proposal["files"] = proposal.get("files", [])[:50]
            proposal["commits"] = proposal.get("commits", [])[:20]
        shown.append({"digest": record.get("digest"), "status": record.get("status"), "proposed_at": record.get("proposed_at"),
                      "pushed_at": record.get("pushed_at"), "pull_request": record.get("pull_request"), "proposal": proposal})
    return {"proposals": shown, "total": len(records)}


# -- the test runner ---------------------------------------------------------------

def converter_image(checkout, values, repo):
    return converter_image_document(checkout, values, repo)["Id"]


def converter_image_document(checkout, values, repo):
    config = checkout.config
    name = config["discourse_profile"]
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}", name):
        refuse("STANDARD_RUNTIME_MISMATCH")
    directories = {Path(repo) / "runtime/profiles", Path(values.get("SILO_RUNTIME_PROFILES_DIR", str(Path(repo) / "runtime/profiles")))}
    paths = list({candidate.resolve() for directory in directories if (candidate := directory / (name + ".json")).is_file()})
    if len(paths) != 1:
        refuse("STANDARD_RUNTIME_MISMATCH")
    raw = paths[0].read_bytes()
    if hashlib.sha256(raw).hexdigest() != config["discourse_profile_sha256"]:
        refuse("STANDARD_RUNTIME_MISMATCH")
    image = json.loads(raw)["images"]["converter"]
    host = checkout.host
    try:
        document = host.inspect(image["ref"])
    except ValueError:
        document = host.inspect("silo-migrate/loaded:" + image["content_id"][7:])
    if host.identity(document) != image["content_id"] or not re.fullmatch(r"sha256:[0-9a-f]{64}", document.get("Id", "")):
        refuse("STANDARD_RUNTIME_MISMATCH")
    return document


def export_visible(checkout, destination):
    """Copy only visible files, from their verified bytes; everything else stays behind."""
    copied = 0
    for name in checkout.visible():
        data, info = checkout.load(name)
        target = Path(destination) / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "wb") as out:
            out.write(data)
        os.chmod(target, 0o755 if info.st_mode & 0o111 else 0o644)
        copied += 1
    return copied


TAIL_BYTES = 64 * 1024


def docker(argv, timeout):
    """Run, keeping only the last TAIL_BYTES of stdout and stderr: memory stays bounded
    however much a test prints. Returns (exit code or None on timeout, stdout, stderr)."""
    import selectors
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    tails = {process.stdout: bytearray(), process.stderr: bytearray()}
    selector = selectors.DefaultSelector()
    for stream in tails:
        selector.register(stream, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                process.kill()
                process.wait()
                return None, bytes(tails[process.stdout]), bytes(tails[process.stderr])
            for key, _ in selector.select(min(remaining, 1.0)):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                tail = tails[key.fileobj]
                tail.extend(chunk)
                del tail[:-TAIL_BYTES]
        return process.wait(), bytes(tails[process.stdout]), bytes(tails[process.stderr])
    finally:
        selector.close()
        process.stdout.close()
        process.stderr.close()


def clean_stale_exports(directory):
    """Exports of a test run killed from outside (e.g. the tool timeout) are removed later."""
    for path in Path(directory).glob("silo-devtest-*"):
        try:
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and time.time() - info.st_mtime > 3600:
                shutil.rmtree(path, ignore_errors=True)
        except OSError:
            pass


# -- dependencies: the checkout's locked gems and Discourse's emoji table ------------
# The converter image carries a gem bundle frozen when it was built; upstream's lockfile
# keeps moving. Before tests, one container *with network* installs only the gems the
# checkout's committed Gemfile.lock pins that the image lacks, into a cache shared by
# workspaces and keyed by (image, Gemfile, Gemfile.lock). It sees those two files and
# the cache, never agent code or workspace content. The converter also downloads
# Discourse's emoji table at run time (support/emojis/discourse_emoji_data.rb); the same
# step fetches it so offline tests find it in tmp/emoji_cache. Tests stay network-none
# and mount both read-only. Everything cached is public.

DEPS_RECIPE = 1
DEPS_TIMEOUT = 180
# Below this many seconds left after preparing, ask for a rerun instead of a cut-off test.
TEST_MIN_SECONDS = 90
BUNDLER_VERSION = "2.6.3"
EMOJI_BASE = "https://raw.githubusercontent.com/discourse/discourse-emojis/main/"
EMOJI_FILES = ("dist/emojis.json", "dist/aliases.json", "dist/tonable_emojis.json")
EMOJI_MAX_BYTES = 8 * 1024 * 1024
LOCK_SECTIONS = {"GEM", "PLATFORMS", "DEPENDENCIES", "RUBY VERSION", "BUNDLED WITH", "CHECKSUMS"}


def emoji_repo_key():
    # As discourse_emoji_data.rb names its cache folder.
    return re.sub(r"[^a-zA-Z0-9_-]", "_", re.sub(r"^https?://", "", EMOJI_BASE))


EMOJI_SOURCE = "support/emojis/discourse_emoji_data.rb"


def emoji_warning(checkout):
    """None, or a note when the checkout's emoji code no longer uses the URL this step caches."""
    try:
        data, _ = checkout.load(EMOJI_SOURCE)
    except Refusal:
        return None
    if ('BASE_URI = "' + EMOJI_BASE + '"').encode() in data:
        return None
    return ("The converter's emoji download URL changed (" + EMOJI_SOURCE + "), so the cached emoji table isn't used: "
            "tests that map emoji may fail offline. Tell the engineer: dev_test, emoji URL changed.")


def committed(checkout, relative):
    """Bytes of a file only as committed at HEAD (agents can't write these paths)."""
    try:
        data, _ = checkout.load(relative)
    except Refusal:
        refuse("STANDARD_DEV_DEPS_UNSUPPORTED")
    entry = checkout.tree().get(relative)
    if not entry or entry[0] != "100644" or checkout.blob_id(data) != entry[1]:
        refuse("STANDARD_DEV_DEPS_UNSUPPORTED")
    return data


def check_lockfile(data):
    """rubygems.org only (no git, path or plugin sources) and the image's Bundler."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        refuse("STANDARD_DEV_DEPS_UNSUPPORTED")
    section, remotes, bundler = None, [], None
    for line in text.splitlines():
        if line and not line[0].isspace():
            section = line.strip()
            if section not in LOCK_SECTIONS:
                refuse("STANDARD_DEV_DEPS_UNSUPPORTED")
        elif section == "GEM" and line.strip().startswith("remote:"):
            remotes.append(line.split(":", 1)[1].strip())
        elif section == "BUNDLED WITH" and line.strip():
            bundler = line.strip()
    if remotes != ["https://rubygems.org/"] or bundler != BUNDLER_VERSION:
        refuse("STANDARD_DEV_DEPS_UNSUPPORTED")


# Both containers read Bundler settings from an empty place, never from a config file the
# image (or the checkout's .bundle/) might carry: only the environment below decides.
BUNDLE_ENV = ("BUNDLE_APP_CONFIG=/tmp/bundle-config", "BUNDLE_USER_HOME=/tmp/bundle-home", "BUNDLE_FROZEN=true")


def image_gem_env(document, overlay):
    """Environment that layers the overlay over the image's own bundle (BUNDLE_PATH/ruby/ABI),
    as Bundler's BUNDLE_PATH mode would set it up: gems, then executables (rubocop...)."""
    env = dict(item.split("=", 1) for item in document.get("Config", {}).get("Env") or [] if "=" in item)
    bundle, home, version, path = env.get("BUNDLE_PATH", ""), env.get("GEM_HOME", ""), env.get("RUBY_VERSION", ""), env.get("PATH", "")
    match = re.fullmatch(r"(\d+)\.(\d+)\.\d+", version)
    safe = re.compile(r"/[A-Za-z0-9/._-]+")
    if not (match and safe.fullmatch(bundle) and safe.fullmatch(home) and all(safe.fullmatch(part) for part in path.split(":"))):
        refuse("STANDARD_RUNTIME_MISMATCH")
    gems = f"{bundle.rstrip('/')}/ruby/{match[1]}.{match[2]}.0"
    return [*BUNDLE_ENV, "GEM_HOME=" + overlay, "GEM_PATH=" + ":".join((overlay, gems, home)), "PATH=" + ":".join((overlay + "/bin", gems + "/bin", path))]


def deps_root(checkout):
    # <prefix>/state/converter-deps beside <prefix>/workspaces (as intake is).
    root = checkout.root.parent.parent / "state" / "converter-deps"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if root.is_symlink() or not root.is_dir() or root.stat().st_uid != os.getuid():
        refuse("STANDARD_OPERATION_FAILED")
    return root


def fetch_emoji(destination, deadline):
    folder = Path(destination) / emoji_repo_key()
    for name in EMOJI_FILES:
        remaining = deadline - time.monotonic()
        if remaining <= 5:
            raise TimeoutError("emoji")
        request = urllib.request.Request(EMOJI_BASE + name, headers={"User-Agent": "silo-migrate"})
        with urllib.request.urlopen(request, timeout=min(30, remaining)) as response:
            data = response.read(EMOJI_MAX_BYTES + 1)
        if len(data) > EMOJI_MAX_BYTES:
            raise ValueError("emoji file too large")
        json.loads(data)  # what the converter will parse
        target = folder / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        os.chmod(target, 0o644)


def clean_stale_builds(root):
    for path in root.glob(".build-*"):
        try:
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and time.time() - info.st_mtime > 3600:
                shutil.rmtree(path, ignore_errors=True)
        except OSError:
            pass


def prepare_dependencies(checkout, document, started, budget=None):
    """(ready directory, result dict) or (None, failure dict). Builds once per key, within
    budget seconds of started (plus up to ~35 s to remove a container that ran out of time)."""
    import fcntl
    gemfile, lockfile = committed(checkout, "Gemfile"), committed(checkout, "Gemfile.lock")
    check_lockfile(lockfile)
    key = hashlib.sha256(canonical({"recipe": DEPS_RECIPE, "image": document["Id"], "gemfile": hashlib.sha256(gemfile).hexdigest(),
                                    "lockfile": hashlib.sha256(lockfile).hexdigest()}).encode()).hexdigest()
    root = deps_root(checkout)
    if "," in str(root):  # --mount separates its fields with commas
        refuse("STANDARD_OPERATION_FAILED")
    ready = root / key
    if (ready / "ready.json").is_file():
        return ready, {"status": "ready", "key": key[:12]}
    deadline = started + (DEPS_TIMEOUT if budget is None else budget)
    descriptor = os.open(root / (".lock-" + key), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        while True:  # another tool call may be preparing the same key: wait for it
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    return None, {"status": "busy", "key": key[:12]}
                time.sleep(1)
        if (ready / "ready.json").is_file():
            return ready, {"status": "ready", "key": key[:12]}
        if ready.is_symlink() or ready.is_file():
            ready.unlink()
        elif ready.exists():
            shutil.rmtree(ready)
        clean_stale_builds(root)
        build = Path(tempfile.mkdtemp(prefix=".build-", dir=root))
        try:
            (build / "gems").mkdir()
            (build / "emoji_cache").mkdir()
            (build / "lock").mkdir()
            (build / "lock/Gemfile").write_bytes(gemfile)
            (build / "lock/Gemfile.lock").write_bytes(lockfile)
            for path in (build, build / "gems", build / "emoji_cache", build / "lock"):
                os.chmod(path, 0o755)
            name = "silo-devdeps-" + secrets.token_hex(6)
            argv = ["docker", "run", "--rm", "--name", name, "--pull=never", "--network", "bridge", "--read-only", "--stop-timeout", "5",
                    "--user", f"{os.getuid()}:{os.getgid()}", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                    "--cpus", "2", "--memory", "2g", "--memory-swap", "2g", "--pids-limit", "512", "--log-opt", "max-size=1m",
                    "--tmpfs", "/tmp:rw,exec,size=1g",
                    "--mount", f"type=bind,src={build / 'lock'},dst=/lock,readonly", "--mount", f"type=bind,src={build / 'gems'},dst=/deps",
                    "-e", "HOME=/tmp", "-e", "TMPDIR=/tmp", "-e", "LANG=C.UTF-8", "-e", "LC_ALL=C.UTF-8",
                    "-e", "BUNDLE_GEMFILE=/lock/Gemfile", *[arg for item in image_gem_env(document, "/deps") for arg in ("-e", item)],
                    "-w", "/tmp", "--entrypoint", "env", document["Id"], "-u", "BUNDLE_PATH",
                    "bundle", "_" + BUNDLER_VERSION + "_", "install", "--no-cache"]
            code, stdout, stderr = docker(argv, max(10, int(deadline - time.monotonic())))
            if code is None:
                subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=30)
            if code != 0:
                return None, {"status": "failed", "step": "gems", "exit_code": code, "timed_out": code is None,
                              "stdout_tail": stdout[-2048:].decode("utf-8", "replace"), "stderr_tail": stderr[-2048:].decode("utf-8", "replace")}
            added = sorted(path.name[:-len(".gemspec")] for path in (build / "gems/specifications").glob("*.gemspec"))
            try:
                fetch_emoji(build / "emoji_cache", deadline)
            except (OSError, ValueError, TimeoutError) as error:
                return None, {"status": "failed", "step": "emoji", "error": type(error).__name__}
            shutil.rmtree(build / "lock")
            record = {"recipe": DEPS_RECIPE, "image": document["Id"], "gemfile_sha256": hashlib.sha256(gemfile).hexdigest(),
                      "lockfile_sha256": hashlib.sha256(lockfile).hexdigest(), "gems_added": added, "emoji_base": EMOJI_BASE, "prepared_at": now()}
            (build / "ready.json").write_text(canonical(record) + "\n")
            os.rename(build, ready)
            return ready, {"status": "prepared", "key": key[:12], "gems_added": added[:50], "seconds": round(time.monotonic() - started)}
        finally:
            if build.exists():
                shutil.rmtree(build, ignore_errors=True)
    finally:
        os.close(descriptor)


def site_settings_cache(checkout):
    """The Discourse site settings the workspace bound at `standard init` (sha256 checked), or None.
    `convert` loads them through support/remote_requires.rb, which downloads unless a cached copy
    is in tmp/requires/discourse/config: runs place this one there, and so do tests."""
    path, digest = checkout.config.get("site_settings"), checkout.config.get("site_settings_sha256")
    if not path:
        return None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        refuse("STANDARD_RUNTIME_MISMATCH")
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode) or hashlib.sha256(stream.read()).hexdigest() != digest:
            refuse("STANDARD_RUNTIME_MISMATCH")
    if "," in path:
        refuse("STANDARD_OPERATION_FAILED")
    return path


def op_test(checkout, request, values, repo):
    suite = request.get("suite", "test")
    file = request.get("file") or None  # "" means the whole suite
    if suite == "test":
        command = ["bundle", "_2.6.3_", "exec", "rake", "test"]
        if file is not None:
            file = relative_path(file)
            if not re.fullmatch(r"test/[A-Za-z0-9_./-]+_test\.rb", file) or file not in checkout.visible(file):
                refuse("STANDARD_ARGUMENTS_INVALID")
            command.append("TEST=" + file)
    elif suite == "lint":
        command = ["bundle", "_2.6.3_", "exec", "rubocop", "--format", "simple", "--no-color"]
        if file is not None:
            file = relative_path(file)
            if not file.endswith(".rb") or file not in checkout.visible(file):
                refuse("STANDARD_ARGUMENTS_INVALID")
            command.append(file)
    else:
        refuse("STANDARD_ARGUMENTS_INVALID")
    started = time.monotonic()
    document = converter_image_document(checkout, values, repo)
    image = document["Id"]
    deps, prepared = prepare_dependencies(checkout, document, started)
    warning = emoji_warning(checkout)
    if warning:
        prepared = dict(prepared, emoji_warning=warning)
    if deps is None:
        return {"suite": suite, "file": file, "exit_code": None, "timed_out": False, "summary": None, "dependencies": prepared,
                "note": "Tests did not run: the step that installs the checkout's locked gems (and the emoji table) didn't finish. "
                        "Retry once; if it fails again, stop and tell the engineer: dev_test, dependencies " + prepared["status"] + "."}
    if TEST_TIMEOUT - (time.monotonic() - started) < TEST_MIN_SECONDS:
        return {"suite": suite, "file": file, "exit_code": None, "timed_out": False, "summary": None, "dependencies": prepared,
                "note": "Dependencies are ready, but not enough time is left for tests in this call. Run dev_test again."}
    clean_stale_exports(tempfile.gettempdir())
    export = tempfile.mkdtemp(prefix="silo-devtest-")
    name = "silo-devtest-" + secrets.token_hex(6)
    try:
        os.chmod(export, 0o700)
        copied = export_visible(checkout, export)
        # Docker would create these mount points as root inside the export: make them ours first.
        settings = site_settings_cache(checkout)
        settings_target = Path(export) / "tmp/requires/discourse/config/site_settings.yml"
        try:
            (Path(export) / "tmp/emoji_cache").mkdir(parents=True, exist_ok=True)
            if settings:
                settings_target.parent.mkdir(parents=True, exist_ok=True)
                settings_target.touch()
        except OSError:
            refuse("STANDARD_OPERATION_FAILED")
        # The tool itself is killed at ~290 s: keep the container inside that, after the export.
        budget = max(30, TEST_TIMEOUT - int(time.monotonic() - started))
        if "," in export:
            refuse("STANDARD_OPERATION_FAILED")
        argv = ["docker", "run", "--rm", "--name", name, "--pull=never", "--network", "none", "--read-only", "--stop-timeout", "5",
                "--user", f"{os.getuid()}:{os.getgid()}", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                "--cpus", "2", "--memory", "2g", "--memory-swap", "2g", "--pids-limit", "512", "--log-opt", "max-size=1m",
                "--tmpfs", "/tmp:rw,exec,size=512m", "--mount", f"type=bind,src={export},dst=/app",
                "--mount", f"type=bind,src={deps / 'gems'},dst=/deps,readonly",
                "--mount", f"type=bind,src={deps / 'emoji_cache'},dst=/app/tmp/emoji_cache,readonly",
                *(["--mount", f"type=bind,src={settings},dst=/app/tmp/requires/discourse/config/site_settings.yml,readonly"] if settings else []),
                "-e", "HOME=/tmp", "-e", "TMPDIR=/tmp", "-e", "LANG=C.UTF-8", "-e", "LC_ALL=C.UTF-8",
                *[arg for item in image_gem_env(document, "/deps") for arg in ("-e", item)], "-w", "/app",
                "--entrypoint", "env", image, "-u", "BUNDLE_PATH", *command]
        code, stdout, stderr = docker(argv, budget)
        if code is None:
            subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=30)
    finally:
        shutil.rmtree(export, ignore_errors=True)
    out, err = stdout.decode("utf-8", "replace"), stderr.decode("utf-8", "replace")
    summary = re.findall(r"\d+ (?:runs|tests), \d+ assertions, \d+ failures, \d+ errors, \d+ skips|\d+ files? inspected, (?:no|\d+) offenses? detected", out)

    def tail(text, limit):
        data = text.encode("utf-8")
        return data[-limit:].decode("utf-8", "ignore"), len(data) > limit
    out_tail, out_cut = tail(out, 20 * 1024)
    err_tail, err_cut = tail(err, 4 * 1024)
    return {"suite": suite, "file": file, "exit_code": code, "timed_out": code is None, "files_exported": copied,
            "seconds": round(time.monotonic() - started), "summary": summary[-1] if summary else None, "dependencies": prepared,
            "stdout_tail": out_tail, "stdout_truncated": out_cut, "stderr_tail": err_tail, "stderr_truncated": err_cut,
            "sandbox": "converter image, no network, read-only root, only the files your tools can see, plus the locked gems, the emoji table and Discourse's site settings (tmp/requires) read-only, as in workflow runs"}


# -- engineer: push approval -------------------------------------------------------

def token_for(owner, home):
    path = Path(home) / ".config/silo-migrate/github" / ("token-" + owner.lower())
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        refuse("STANDARD_PUSH_TOKEN_MISSING")
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 1024:
            refuse("STANDARD_PUSH_TOKEN_UNSAFE")
        token = os.read(descriptor, 1024).decode("ascii", "replace").strip()
    finally:
        os.close(descriptor)
    if not TOKEN_TEXT.fullmatch(token):
        refuse("STANDARD_PUSH_TOKEN_UNSAFE")
    return path, token


# Answers only `get` for https://github.com; any other host gets nothing.
CREDENTIAL_HELPER = ('!f() { test "$1" = get || exit 0; h=; p=; while IFS= read -r l && test -n "$l"; do case "$l" in '
                     'host=github.com) h=1;; protocol=https) p=1;; esac; done; test "$h$p" = 11 || exit 0; '
                     'echo username=x-access-token; printf "password=%s\\n" "$(cat "$SILO_GITHUB_TOKEN_FILE")"; }; f')


def credential_config(token_path):
    """Git -c options and environment that supply the token only to this command, never in argv or a URL."""
    return ["-c", "credential.helper=", "-c", "credential.helper=" + CREDENTIAL_HELPER], {"SILO_GITHUB_TOKEN_FILE": str(token_path)}


def github_api(method, path, token, payload=None):
    request = urllib.request.Request("https://api.github.com" + path, method=method,
                                     data=None if payload is None else json.dumps(payload).encode("utf-8"),
                                     headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                                              "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "silo-migrate-control"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read() or b"null")
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.loads(error.read() or b"null")
        except ValueError:
            return error.code, None


def open_draft_pr(target, proposal, digest, token):
    body = (proposal["body"].rstrip() + "\n\n---\nProposed by the converter-developer agent on this Migrations node and pushed "
            "after engineer approval of digest `" + digest + "`. Review before marking ready.")
    path = "/repos/" + target["owner"] + "/" + target["repo"] + "/pulls"
    status, data = github_api("POST", path, token, {"title": proposal["title"], "head": proposal["branch"], "base": proposal["base"],
                                                    "body": body, "draft": True})
    if status == 201 and isinstance(data, dict):
        return {"number": data.get("number"), "url": data.get("html_url"), "draft": data.get("draft"), "created": True}
    if status == 422:
        query = urllib.parse.urlencode({"state": "open", "head": target["owner"] + ":" + proposal["branch"]})
        status, data = github_api("GET", path + "?" + query, token)
        if status == 200 and isinstance(data, list) and data:
            return {"number": data[0].get("number"), "url": data[0].get("html_url"), "draft": data[0].get("draft"), "created": False}
    refuse("STANDARD_PR_FAILED")


def push(checkout, digest, home, open_pr=True):
    if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
        refuse("STANDARD_ARGUMENTS_INVALID")
    path = checkout.standard / "converter-pushes" / (digest + ".json")
    if path.is_symlink() or not path.is_file():
        refuse("STANDARD_PUSH_UNKNOWN")
    record = json.loads(path.read_text())
    if record.get("digest") != digest or record.get("status") not in ("proposed", "pushed"):
        refuse("STANDARD_PUSH_UNKNOWN")
    proposal = record["proposal"]
    with Locked(checkout):
        current = current_proposal(checkout, proposal["base"], proposal["title"], proposal["body"]) if record["status"] == "proposed" else None
        if current is not None and (current != proposal or hashlib.sha256(canonical(current).encode("utf-8")).hexdigest() != digest):
            refuse("STANDARD_PUSH_STALE")
        target = github_target(checkout)
        token_path, token = token_for(target["owner"], home)
        if record["status"] == "proposed":
            options, env = credential_config(token_path)
            # Non-force; updates refs/remotes/origin/<branch> so the commits stop counting as unpushed.
            result = checkout.git("push", "--porcelain", "origin", proposal["head"] + ":refs/heads/" + proposal["branch"],
                                  ok=(0, 1, 128), env=env, extra=options, timeout=300)
            if result.returncode:
                text = (result.stdout + result.stderr).decode("utf-8", "replace")
                rejected = "rejected" in text or "non-fast-forward" in text or "fetch first" in text
                refuse("STANDARD_PUSH_REJECTED" if rejected else "STANDARD_PUSH_FAILED")
            record.update(status="pushed", pushed_at=now())
            write_record(path, record)
        if open_pr and not record.get("pull_request"):
            record["pull_request"] = open_draft_pr(target, proposal, digest, token)
            write_record(path, record)
    return {"digest": digest, "status": record["status"], "branch": proposal["branch"], "head": proposal["head"],
            "repository": proposal["repository"], "pull_request": record.get("pull_request")}


def push_discard(checkout, digest):
    """Engineer: set aside a push proposal that will never be pushed (stale or replaced)."""
    if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
        refuse("STANDARD_ARGUMENTS_INVALID")
    path = checkout.standard / "converter-pushes" / (digest + ".json")
    if path.is_symlink() or not path.is_file():
        refuse("STANDARD_PUSH_UNKNOWN")
    with Locked(checkout):
        record = json.loads(path.read_text())
        if record.get("digest") != digest or record.get("status") not in ("proposed", "superseded"):
            refuse("STANDARD_TRANSITION_INVALID")
        write_record(path, dict(record, status="discarded", discarded_at=now()))
    return {"digest": digest, "status": "discarded"}


def write_record(path, record):
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(json.dumps(record, indent=2) + "\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


# -- dispatch ------------------------------------------------------------------------

OUTPUT_LIMIT = 46 * 1024


def fit(result):
    """Keep the printed JSON (UTF-8, ensure_ascii=False) under the tool limit: shorten the
    largest text field (keeping the end of *_tail fields) until it fits."""
    for _ in range(16):
        if len(json.dumps(result, ensure_ascii=False).encode("utf-8")) <= OUTPUT_LIMIT:
            return result
        texts = [key for key, value in result.items() if isinstance(value, str) and len(value) > 256]
        if not texts:
            break
        key = max(texts, key=lambda k: len(result[k].encode("utf-8")))
        half = len(result[key]) // 2
        result[key] = ("…[shortened to fit]\n" + result[key][-half:]) if key.endswith("_tail") else (result[key][:half] + "\n…[shortened to fit]\n")
        result["shortened"] = True
    if len(json.dumps(result, ensure_ascii=False).encode("utf-8")) > OUTPUT_LIMIT:
        refuse("STANDARD_OUTPUT_TOO_LARGE")
    return result

def main(args, values, base, repo, host, stdin, home=None):
    """`converter dev WS --role ROLE` (JSON request on stdin), `converter push WS --sha256 D [--no-pr]`,
    `converter push-show WS`, `converter deps WS`, `converter log WS`."""
    home = home or os.path.expanduser("~")
    if len(args) >= 3 and args[1] == "dev":
        workspace, rest = args[2], args[3:]
        if len(rest) != 2 or rest[0] != "--role" or rest[1] not in ROLES:
            refuse("STANDARD_ARGUMENTS_INVALID")
        role = rest[1]
        try:
            request = json.loads(stdin.read(4 * 1024 * 1024))
        except ValueError:
            refuse("STANDARD_ARGUMENTS_INVALID")
        if not isinstance(request, dict) or request.get("op") not in ROLES[role]:
            refuse("STANDARD_DEV_OPERATION_REFUSED")
        checkout = Checkout(base, workspace, host)
        op = request["op"]
        handlers = {"list": op_list, "read": op_read, "search": op_search, "status": op_status, "diff": op_diff,
                    "push-show": op_push_show, "write": op_write, "edit": op_edit, "delete": op_delete,
                    "branch": op_branch, "push-propose": op_push_propose}
        if op == "test":
            result = op_test(checkout, request, values, repo)
        elif op in MUTATING:
            with DevLock(checkout):
                result = op_commit(checkout, request, home) if op == "commit" else handlers[op](checkout, request)
        else:
            result = handlers[op](checkout, request)
        return fit(dict(version=1, **result))
    if len(args) >= 3 and args[1] == "push":
        workspace, rest = args[2], args[3:]
        open_pr = "--no-pr" not in rest
        rest = [arg for arg in rest if arg != "--no-pr"]
        if len(rest) != 2 or rest[0] != "--sha256":
            refuse("STANDARD_ARGUMENTS_INVALID")
        return dict(version=1, **push(Checkout(base, workspace, host), rest[1], home, open_pr))
    if len(args) in (3, 5) and args[1] == "deps":
        # Engineer or migration-data: prepare the locked gems for the checkout's HEAD (the
        # step dev_test runs first), e.g. before proposing a convert plan. `--budget S`
        # keeps it inside a caller's own time limit.
        budget = None
        if len(args) == 5:
            if args[3] != "--budget" or not args[4].isdigit() or not 30 <= int(args[4]) <= DEPS_TIMEOUT:
                refuse("STANDARD_ARGUMENTS_INVALID")
            budget = int(args[4])
        checkout = Checkout(base, args[2], host)
        ready, prepared = prepare_dependencies(checkout, converter_image_document(checkout, values, repo), time.monotonic(), budget)
        if ready is None:
            refuse("STANDARD_CONVERTER_DEPS_FAILED: " + prepared["status"] + (" (" + prepared["step"] + ")" if prepared.get("step") else ""))
        return dict(version=1, head=checkout.head(), dependencies=prepared)
    if len(args) == 5 and args[1] == "push-discard" and args[3] == "--sha256":
        return dict(version=1, **push_discard(Checkout(base, args[2], host), args[4]))
    if len(args) == 3 and args[1] == "log":
        return dict(version=1, **converter_log(Checkout(base, args[2], host)))
    if len(args) == 3 and args[1] == "push-show":
        # The engineer's view: full PR text, files and diff stat of every proposal.
        return dict(version=1, **op_push_show(Checkout(base, args[2], host), {}, full=True))
    refuse("STANDARD_ARGUMENTS_INVALID")
