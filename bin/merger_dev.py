"""Coding agents' bounded tools for a project's standalone local merger repository.

    <workspace root>/merger/     a local Git repository with no remote
      merger.rb                  the one entry point a prepared custom merge runs
      helpers/**.rb              Ruby files it requires
      test/                      invented tests and fixtures: never run by a merge
      README.md                  notes: never run

The path is derived from the managed workspace, never given, and there is no other place
these tools look: without the repository every operation but the guide and init refuses.
Nothing here pushes, fetches, switches branches or names a remote.

The content rule, the writes, the commit built from verified bytes and the sealed test
container are bin/converter_dev.py's own (MergerCheckout is its Checkout with another gate
and layout), so there is one hardened implementation. What differs:

- The gate is the Python twin of StandardMergeCode#assert_merger_store! (lib/silo_migrate/
  services/standard_merge_code.rb): refused before any other Git command if the repository's
  config or layout could redirect objects, name a remote or run a command.
- No converter repository, identity or dependency step is involved: tests run on the pinned
  converter image's own Ruby and minitest, with no network at any point.
- `layer` is what a merge plan would bind for a commit, computed exactly as the Ruby side does.

Control: `silo-migrate-control merger dev WS --role developer|reviewer`, one JSON request
{"op": ...} on stdin. init (developer) runs the explicit service action `standard merger init WS`.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import time


def _beside(name):
    # Loaded by path from beside this file, never from sys.path or the working directory.
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dev = _beside("converter_dev")
contract = _beside("merge_contract")
refuse, Refusal = dev.refuse, dev.Refusal

ROLES = {
    "developer": {"list", "read", "search", "status", "diff", "test", "merge-guide", "write", "edit", "delete", "format", "commit", "init"},
    "reviewer": {"list", "read", "search", "status", "diff", "test", "merge-guide"},
}
MUTATING = {"write", "edit", "delete", "format", "commit", "init"}
DIRECTORY = "merger"
ENTRY = "merger.rb"
STORE = "merger"
PLAN_REFS = "refs/silo/merge-plans/"
# As the Ruby twin: MERGER_TOP_LEVEL, MERGER_CONFIG_KEYS, and its redirect list.
TOP_LEVEL = ("merger.rb", "helpers", "test", "README.md", ".gitignore")
CONFIG_KEYS = re.compile(r"(?:core\.(?:repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|precomposeunicode)|user\.(?:name|email))\Z")
REDIRECTS = ("commondir", "gitdir", "config.worktree", "shallow", "objects/info/alternates", "objects/info/http-alternates", "info/grafts")
PART = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\Z")
TEST_FILES = (".rb", ".yml", ".yaml", ".json", ".md", ".txt")
REVIEWED = ("merger.rb", "helpers", "test", "README.md")
MISSING = ("STANDARD_MERGER_MISSING: this project has no local merger repository yet; a developer creates it with dev_merger_init "
           "(the engineer: silo-migrate-control standard merger init WORKSPACE)")
SANDBOX_NOTE = ("pinned converter image's Ruby and minitest, no network, read-only root, only the merger files your tools can see; "
                "no Bundler, no installed gems, no Discourse: stub what the layer calls.")
NO_FORMATTER = ("STANDARD_MERGER_FORMATTER_UNAVAILABLE: this project's pinned converter image has no syntax_tree (stree), so nothing "
                "was formatted or changed; tell the engineer. Formatting is not required for a merge plan")
# Fixed: every committed test file, or the one named. Nothing an agent sends becomes a command.
TEST_RUNNER = ('files = ARGV.empty? ? Dir["test/**/*_test.rb"].sort : ARGV.dup; ARGV.clear; '
               'abort("No test files: put tests in test/..._test.rb") if files.empty?; '
               'require "minitest/autorun"; files.each { |file| require File.expand_path(file) }')


def owned(path, directory):
    try:
        info = os.lstat(path)
    except OSError:
        refuse("STANDARD_MERGER_CONFIG")
    kind = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
    if not kind or info.st_uid != os.getuid() or info.st_mode & 0o022:
        refuse("STANDARD_MERGER_CONFIG")


class MergerCheckout(dev.Checkout):
    """One workspace's standalone merger repository, gated before any other Git command."""

    dev_lock = "merger-dev.lock"
    manifest_name = "merger-dev-files.json"
    # A claimed/running record alone is no barrier: its plan retains an exact commit.
    # The workspace op lock is still taken, so an actively executing run serializes commits.
    busy_while_running = False
    sandbox_dependencies = False
    format_command = ("stree", "write", "--print-width=100")
    write_refusal = "STANDARD_MERGER_PATH_REFUSED"

    def __init__(self, base, workspace, host):
        if not isinstance(workspace, str) or not dev.WORKSPACE.fullmatch(workspace):
            refuse("STANDARD_ARGUMENTS_INVALID")
        self.workspace = workspace
        self.host = host
        self.root = Path(base) / workspace
        if self.root.is_symlink() or not (self.root / ".silo-migrate/named/state.json").is_file():
            refuse("STANDARD_NOT_INITIALIZED")
        self.standard = self.root / ".silo-migrate/named/standard"
        self.state = json.loads((self.standard / "state.json").read_text())
        self.config = self.state.get("config") if isinstance(self.state.get("config"), dict) else {}
        # The fixed place, under the resolved workspace root; never a configured or requested path.
        self.path = self.root.resolve() / DIRECTORY
        self.argv = ["git", "--no-replace-objects", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                     "-c", "core.untrackedCache=false", "-c", "credential.helper=", "-c", "protocol.allow=never",
                     "-c", "submodule.recurse=false", "-c", "fetch.recurseSubmodules=false", "-c", "gc.auto=0",
                     "-c", "maintenance.auto=false", "-c", "core.attributesFile=/dev/null", "-c", "core.excludesFile=/dev/null",
                     "-c", "safe.directory=" + str(self.path), "-C", str(self.path)]
        # Anything at the store's .git (or a link in its place) is a store, to be gated.
        self.present = self.path.is_symlink() or os.path.lexists(self.path / ".git")
        if self.present:
            self.gate()

    def git(self, *args, ok=(0,), input=None, env=None, timeout=60):
        # converter_dev.git_env drops every inherited GIT_* variable. On top of that: no global config and no
        # replace objects, whatever a caller's env says (a commit passes its index file and identity). There is
        # deliberately no `extra`: the converter's per-command Git options carry push credentials, and nothing
        # here talks to a remote.
        env = dict(env or {}, GIT_CONFIG_GLOBAL="/dev/null", GIT_NO_REPLACE_OBJECTS="1")
        return super().git(*args, ok=ok, input=input, env=env, timeout=timeout)

    def gate(self):
        dot_git = self.path / ".git"
        owned(self.path, True)
        owned(dot_git, True)
        owned(dot_git / "config", False)
        for name in ("objects", "refs"):
            owned(dot_git / name, True)
        if any(os.path.lexists(redirect) for redirect in [dot_git / name for name in REDIRECTS] + [self.path / ".gitmodules"]):
            refuse("STANDARD_MERGER_CONFIG")
        try:
            own = ("file:.git/config", "file:" + os.path.realpath(dot_git) + "/config")
            fields = self.out("config", "--list", "--show-origin", "--show-scope", "--null").split("\0")
            if fields and fields[-1] == "":
                fields.pop()
            if len(fields) % 3:
                refuse("STANDARD_MERGER_CONFIG")
            for scope, origin, entry in zip(fields[0::3], fields[1::3], fields[2::3]):
                if scope == "command":
                    continue
                key, _, value = entry.partition("\n")
                fixed = {"core.repositoryformatversion": "0", "core.bare": "false"}.get(key)
                if not (scope == "local" and origin in own and CONFIG_KEYS.fullmatch(key) and "\n" not in value and fixed in (None, value)):
                    refuse("STANDARD_MERGER_CONFIG")
            dirs = self.out("rev-parse", "--git-dir", "--git-common-dir").split("\n")
            if dirs and dirs[-1] == "":
                dirs.pop()
            if len(dirs) != 2 or any(item not in (".git", os.path.realpath(dot_git)) for item in dirs):
                refuse("STANDARD_MERGER_CONFIG")
            if any(not line.startswith(("100644 ", "100755 ")) for line in self.out("ls-files", "--stage").splitlines()):
                refuse("STANDARD_MERGER_CONFIG")
        except Refusal:
            refuse("STANDARD_MERGER_CONFIG")

    # init makes no commit: until the first one HEAD is unborn and nothing is tracked.
    def head(self):
        result = self.git("rev-parse", "--verify", "--quiet", "HEAD^{commit}", ok=(0, 1))
        head = result.stdout.decode("utf-8", "replace").strip()
        return head if result.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", head) else None

    def tree(self):
        if getattr(self, "_tree", None) is None and self.head() is None:
            return {}
        return super().tree()

    def branch(self):
        return self.out("symbolic-ref", "--quiet", "--short", "HEAD", ok=(0, 1)).strip() or "detached"

    def load(self, relative):
        # Only the repository's own layout is ever shown, whatever else a commit or a folder holds.
        if relative.split("/")[0] not in TOP_LEVEL:
            refuse("STANDARD_DEV_PATH_NOT_VISIBLE")
        return super().load(relative)

    def write_allowed(self, relative):
        parts = relative.split("/")
        if not all(PART.fullmatch(part) for part in parts):
            return False
        if relative in (ENTRY, "README.md"):
            return True
        if parts[0] == "helpers":
            return len(parts) > 1 and relative.endswith(".rb")
        return parts[0] == "test" and len(parts) > 1 and relative.endswith(TEST_FILES)

    def commit_gate(self):
        # A commit on a detached HEAD belongs to no branch and is easily lost.
        if self.branch() == "detached":
            refuse("STANDARD_MERGER_DETACHED")


def layer(checkout, commit):
    """(layer, None) exactly as StandardMergeCode#merger_layer! binds a commit into a merge plan,
    or (None, "STANDARD_MERGE_LAYER_INVALID"). Read from objects only; blobs are rehashed."""
    invalid = (None, "STANDARD_MERGE_LAYER_INVALID")
    listing = checkout.git("ls-tree", "-r", "-l", "-z", "--full-tree", commit).stdout
    manifest, files, total = [], 0, 0
    for entry in filter(None, listing.split(b"\0")):
        match = re.fullmatch(rb"(\d{6}) (\w+) ([0-9a-f]{40}) +(-|\d+)\t(.+)", entry, re.S)
        if not match:
            return invalid
        mode, kind, sha, size, name = match.groups()
        parts = name.split(b"/")
        if not (kind == b"blob" and mode in (b"100644", b"100755") and parts[0] in [item.encode() for item in TOP_LEVEL]
                and not any(part in (b"", b".", b"..") for part in parts) and not re.search(rb"[\x00-\x1f\\]", name)):
            return invalid
        if not (name == ENTRY.encode() or parts[0] == b"helpers"):
            continue
        if not (mode == b"100644" and all(PART.fullmatch(part.decode("ascii", "replace")) for part in parts) and name.endswith(b".rb")
                and files < contract.MERGE_LAYER_MAX_FILES and int(size) + total <= contract.MERGE_LAYER_MAX_BYTES):
            return invalid
        data = checkout.git("cat-file", "blob", sha.decode()).stdout
        if len(data) != int(size) or hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest() != sha.decode():
            return invalid
        files, total = files + 1, total + len(data)
        manifest.append(hashlib.sha256(data).hexdigest().encode() + b" " + name + b"\n")
    if not any(line.endswith(b" " + ENTRY.encode() + b"\n") for line in manifest):
        return invalid
    return {"present": True, "store": STORE, "path": ENTRY, "revision": commit, "files": files, "bytes": total,
            "sha256": hashlib.sha256(b"".join(sorted(manifest))).hexdigest()}, None


def store(checkout):
    """Where the repository actually is and what a merge plan would bind now. Never file contents."""
    facts = {"path": str(checkout.path), "initialized": checkout.present, "branch": None, "head": None, "dirty": None,
             "layer": None, "layer_error": None}
    if not checkout.present:
        return facts
    head = checkout.head()
    facts.update(branch=checkout.branch(), head=head, dirty=bool(dev.status_entries(checkout)))
    if head is None:
        facts["layer_error"] = "STANDARD_MERGE_INTENT_MISMATCH"  # nothing committed yet, as the service reports it
    else:
        facts["layer"], facts["layer_error"] = layer(checkout, head)
    return facts


def op_status(checkout, request):
    shown, hidden = dev.changes(checkout)
    commits = []
    if checkout.head():
        for line in checkout.out("log", "--format=%H%x00%an%x00%ae%x00%aI%x00%s", "-n", "20", "HEAD").splitlines():
            sha, name, email, date, subject = (line.split("\0") + [""] * 5)[:5]
            if re.fullmatch(r"[0-9a-f]{40}", sha):
                commits.append({"sha": sha, "author": (name + " <" + email + ">")[:300], "date": date[:40], "subject": subject[:200]})
    return dict(store(checkout), changes=shown[:500], other_changes_not_shown=hidden, commits=commits,
                note="Local repository: nothing is pushed or fetched. A merge plan binds head and layer when migration-data proposes it, "
                     "and is refused while dirty is true (other_changes_not_shown counts files only the engineer can deal with).")


def op_diff(checkout, request):
    scope = request.get("scope", "working")
    if scope == "working":
        return dev.op_diff(checkout, request)
    if scope != "commit":
        refuse("STANDARD_ARGUMENTS_INVALID")
    # One commit against its parent: HEAD, one of its ancestors, or a commit a merge plan retains.
    head = checkout.head()
    commit = request.get("commit") or head
    if not (head and isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit)):
        refuse("STANDARD_ARGUMENTS_INVALID")
    if checkout.out("cat-file", "-t", commit, ok=(0, 1, 128)).strip() != "commit":
        refuse("STANDARD_ARGUMENTS_INVALID")
    if checkout.git("merge-base", "--is-ancestor", commit, head, ok=(0, 1)).returncode != 0 and not checkout.out(
            "for-each-ref", "--count=1", "--contains", commit, "--format=%(refname)", PLAN_REFS).strip():
        refuse("STANDARD_ARGUMENTS_INVALID")
    path = dev.relative_path(request.get("path"), allow_root=True)
    if path and path.split("/")[0] not in REVIEWED:
        refuse("STANDARD_DEV_PATH_NOT_VISIBLE")
    parents = checkout.out("rev-list", "--parents", "-n", "1", commit).split()
    base = parents[1] if len(parents) > 1 else dev.EMPTY_TREE
    arguments = ["--no-color", "--no-ext-diff", "--no-textconv", base, commit, "--", *([path] if path else REVIEWED)]
    stat_text, _ = dev.bounded(checkout.out("--literal-pathspecs", "diff", "--stat=120", *arguments), 6 * 1024)
    text, truncated = dev.bounded(checkout.out("--literal-pathspecs", "diff", *arguments), dev.MAX_TEXT_BYTES - len(stat_text.encode()) - 512)
    return {"scope": scope, "commit": commit, "parent": parents[1] if len(parents) > 1 else None, "stat": stat_text, "diff": text,
            "truncated": truncated, "note": "Use path to see one file's diff when truncated." if truncated else ""}


def op_test(checkout, request, values, repo):
    if request.get("suite", "test") != "test":
        refuse("STANDARD_ARGUMENTS_INVALID")
    file = request.get("file") or None  # "" means every test file
    command = ["ruby", "-I", "test", "-e", TEST_RUNNER]
    if file is not None:
        file = dev.relative_path(file)
        if not re.fullmatch(r"test/[A-Za-z0-9_./-]+_test\.rb", file) or file not in checkout.visible(file):
            refuse("STANDARD_ARGUMENTS_INVALID")
        command += ["--", file]
    kind, ran = dev.run_in_sandbox(checkout, values, repo, command, tool="dev_merger_test")
    if kind == "early":  # not enough time left in this call
        return dict(suite="test", file=file, **ran)
    summary = re.findall(r"\d+ (?:runs|tests), \d+ assertions, \d+ failures, \d+ errors, \d+ skips", ran["out"])
    out_tail, out_cut = dev.tail_text(ran["out"], 20 * 1024)
    err_tail, err_cut = dev.tail_text(ran["err"], 4 * 1024)
    return {"suite": "test", "file": file, "exit_code": ran["code"], "timed_out": ran["code"] is None, "files_exported": ran["copied"],
            "seconds": round(time.monotonic() - ran["started"]), "summary": summary[-1] if summary else None,
            "stdout_tail": out_tail, "stdout_truncated": out_cut, "stderr_tail": err_tail, "stderr_truncated": err_cut, "sandbox": SANDBOX_NOTE}


def op_format(checkout, request, values, repo):
    result = dev.op_format(checkout, request, values, repo)
    if result.get("exit_code") in (126, 127):
        # env couldn't run stree at all: say so, rather than a result that reads like "nothing needed formatting".
        refuse(NO_FORMATTER)
    if result.get("formatted"):
        result["note"] = "Formatted with syntax_tree (print width 100). Review the changes (diff), run the tests, then commit."
    return result


def op_commit(checkout, request, home):
    result = dev.op_commit(checkout, request, home)
    facts = store(checkout)
    return dict(result, dirty=facts["dirty"], layer=facts["layer"], layer_error=facts["layer_error"],
                note="Committed locally (nothing is pushed). A new merge plan binds this commit and layer; it is refused while dirty is true "
                     "or layer is missing (layer_error says why).")


def op_init(checkout, base, host, init):
    """The one explicit service action (`standard merger init WS`), then the gate again."""
    created = not checkout.present
    if created:
        if init is None:
            refuse("STANDARD_OPERATION_FAILED")
        init(checkout.workspace)
        checkout = MergerCheckout(base, checkout.workspace, host)
        if not checkout.present:
            refuse("STANDARD_MERGER_MISSING")
    return dict(op_status(checkout, {}), created=created)


def op_merge_guide(checkout, request, values, repo):
    """How to write this project's merge layer, where it actually is, what is committed and which
    Discourse revision to read the stock merger at. Works before the repository exists."""
    facts = dict(store(checkout), entry=ENTRY, helpers="helpers", tests="test", uncommitted_changes=[], other_changes_not_shown=0)
    if checkout.present:
        shown, hidden = dev.changes(checkout)
        facts.update(uncommitted_changes=[item["path"] for item in shown][:50], other_changes_not_shown=hidden)
    else:
        facts["note"] = "Not created yet: a developer runs dev_merger_init (the engineer: silo-migrate-control standard merger init WORKSPACE)."
    platforms = dev.workspace_platforms(checkout)
    result = {"merge_project": "discourse" in platforms, "merger": facts, "recent_runs": dev.merge_runs(checkout),
              "guide": contract.STANDALONE_MERGE_GUIDE.format(path=str(checkout.path), files=contract.MERGE_LAYER_MAX_FILES,
                                                              kib=contract.MERGE_LAYER_MAX_BYTES // 1024)}
    if "discourse" not in platforms:
        result["note"] = "This project's source platform is not discourse, so it has no merge runs; a merge layer here would never be applied."
    result.update(dev.merge_discourse(checkout, values, repo))
    return result


def main(args, values, base, repo, host, stdin, init=None, home=None):
    """`merger dev WS --role ROLE` with one JSON request on stdin. init(workspace) runs the service's
    explicit `standard merger init WS`."""
    home = home or os.path.expanduser("~")
    if len(args) != 5 or args[:2] != ["merger", "dev"] or args[3] != "--role" or args[4] not in ROLES:
        refuse("STANDARD_ARGUMENTS_INVALID")
    role = args[4]
    try:
        request = json.loads(stdin.read(4 * 1024 * 1024))
    except ValueError:
        refuse("STANDARD_ARGUMENTS_INVALID")
    if not isinstance(request, dict) or request.get("op") not in ROLES[role]:
        refuse("STANDARD_DEV_OPERATION_REFUSED")
    checkout = MergerCheckout(base, args[2], host)
    op = request["op"]
    if op == "merge-guide":
        result = op_merge_guide(checkout, request, values, repo)
    elif op == "init":
        with dev.DevLock(checkout):
            result = op_init(checkout, base, host, init)
    elif not checkout.present:
        refuse(MISSING)
    elif op == "test":
        result = op_test(checkout, request, values, repo)
    elif op in MUTATING:
        with dev.DevLock(checkout):
            if op == "commit":
                result = op_commit(checkout, request, home)
            elif op == "format":
                result = op_format(checkout, request, values, repo)
            else:
                result = {"write": dev.op_write, "edit": dev.op_edit, "delete": dev.op_delete}[op](checkout, request)
    else:
        result = {"list": dev.op_list, "read": dev.op_read, "search": dev.op_search, "status": op_status, "diff": op_diff}[op](checkout, request)
    return dev.fit(dict(version=1, **result))
