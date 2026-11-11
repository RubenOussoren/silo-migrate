"""Bounded local-only migration rebase. Caller must hold dev.DevLock.

No live rebase state is created. Only committed objects enter the disposable repo;
unknown worktree files are neither enumerated nor read. Refusals contain fixed codes.
rewrite_metadata is advisory for proposal construction, NOT push authorization.
The approver must use the exact pinned expected_remote_head server-side lease;
refreshing or advancing that lease at approval would invalidate the approval.
Unchanged tracked symlink leaves are preserved without following targets. Symlink
changes, gitlinks and directory-to-file transitions are deliberately unsupported.
Caller must checkpoint agent changes using dev_commit first.
"""
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import tempfile


SAFE = ("-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
        "-c", "core.untrackedCache=false", "-c", "submodule.recurse=false",
        "-c", "fetch.recurseSubmodules=false", "-c", "commit.gpgSign=false",
        "-c", "rebase.autoStash=false", "-c", "core.autocrlf=false")
MAX_PATHS = 10000
MAX_BYTES = 64 * 1024 * 1024


def _git(dev, path, *args, timeout=30, ok=(0,), env=None):
    settings = dev.git_env(dict(GIT_CONFIG_GLOBAL="/dev/null", GIT_EDITOR="false",
                                GIT_SEQUENCE_EDITOR="false", **(env or {})))
    try:
        result = subprocess.run(["git", *SAFE, "-C", str(path), *args],
                                capture_output=True, stdin=subprocess.DEVNULL,
                                env=settings, timeout=timeout)
    except subprocess.TimeoutExpired:
        dev.refuse("STANDARD_REBASE_TIMEOUT")
    if result.returncode not in ok:
        dev.refuse("STANDARD_REBASE_FAILED")
    return result


def _git_directory(checkout, dev):
    try:
        real_directory = stat.S_ISDIR((checkout.path / ".git").lstat().st_mode)
    except OSError:
        real_directory = False
    if not real_directory:
        dev.refuse("STANDARD_CONVERTER_CONFIG")


def _ancestor(checkout, older, newer):
    return checkout.git("merge-base", "--is-ancestor", older, newer, ok=(0, 1)).returncode == 0


def _remote(checkout, branch):
    result = checkout.git("rev-parse", "--verify", "refs/remotes/origin/" + branch,
                          ok=(0, 128))
    return result.stdout.decode().strip() if result.returncode == 0 else None


def _record_path(checkout):
    # No branch names in filesystem paths, and no agent-editable storage.
    key = hashlib.sha256(checkout.branch().encode()).hexdigest()
    return checkout.standard / ("converter-rebase-" + key + ".json")


def _sha(value):
    return len(value) == 40 and all(c in "0123456789abcdef" for c in value)


def _record(checkout):
    path = _record_path(checkout)
    try:
        if path.is_symlink() or not path.is_file():
            return None
        data = json.loads(path.read_text())
        sha_fields = ("before_head", "after_head", "main_head")
        if (isinstance(data, dict) and data.get("branch") == checkout.branch()
                and data.get("version") == 1
                and all(isinstance(data.get(key), str) and _sha(data[key]) for key in sha_fields)
                and (data.get("expected_remote_head") is None or
                     isinstance(data.get("expected_remote_head"), str) and _sha(data["expected_remote_head"]))
                and isinstance(data.get("backup_ref"), str)
                and data["backup_ref"].startswith("refs/silo-migrate/rebase-backups/")
                and len(data["backup_ref"].rsplit("/", 1)[-1]) == 32
                and all(c in "0123456789abcdef" for c in data["backup_ref"].rsplit("/", 1)[-1])):
            return data
    except (OSError, ValueError):
        pass
    return None


def _continuation(checkout, record, remote, head):
    return (record and record.get("expected_remote_head") == remote
            and isinstance(record.get("after_head"), str)
            and _ancestor(checkout, record["after_head"], head))


def rewrite_metadata(checkout, dev):
    """Return pinned force-with-lease fields, None for a normal push, or refuse.

    Uses fetched origin refs (never advances a stored lease). Approval must
    revalidate the proposal and use this exact pinned server-side lease, not
    refresh/advance the lease to a newly observed remote head.
    """
    _git_directory(checkout, dev)
    branch, head = checkout.branch(), checkout.head()
    if not branch.startswith(checkout.migration_prefix()):
        dev.refuse("STANDARD_DEV_NOT_MIGRATION_BRANCH")
    remote = _remote(checkout, branch)
    if remote is None or _ancestor(checkout, remote, head):
        return None
    record = _record(checkout)
    if not _continuation(checkout, record, remote, head):
        dev.refuse("STANDARD_REBASE_REMOTE_DIVERGED")
    return {"mode": "force-with-lease", "expected_remote_head": remote,
            "main_head": record["main_head"], "before_head": record["before_head"],
            "backup_ref": record["backup_ref"]}


def _tree(checkout, sha, dev):
    raw = checkout.git("ls-tree", "-rlz", "--full-tree", sha).stdout
    tree = {}
    total = 0
    for entry in raw.split(b"\0"):
        if not entry:
            continue
        meta, name = entry.split(b"\t", 1)
        mode, kind, oid, size = meta.decode().split()
        name = name.decode("utf-8", "surrogateescape")
        if (mode not in ("100644", "100755", "120000") or kind != "blob"
                or any(p in ("", ".", "..", ".git", ".gitmodules") for p in name.split("/"))):
            dev.refuse("STANDARD_REBASE_UNSUPPORTED_TREE")
        total += int(size)
        if int(size) > dev.MAX_FILE_BYTES or total > MAX_BYTES:
            dev.refuse("STANDARD_REBASE_LIMIT")
        tree[name] = (mode, oid)
    if len(tree) > MAX_PATHS:
        dev.refuse("STANDARD_REBASE_LIMIT")
    return tree


def _parents_safe(checkout, name):
    path = checkout.path
    for part in name.split("/")[:-1]:
        path = path / part
        try:
            info = path.lstat()
        except FileNotFoundError:
            return True
        if not stat.S_ISDIR(info.st_mode):
            return False
    return True


def _clean(checkout, dev, tree):
    # Index plumbing does not trust stat-cache, skip-worktree, or assume-unchanged.
    if checkout.git("diff-index", "--cached", "--quiet", "HEAD", "--", ok=(0, 1)).returncode:
        dev.refuse("STANDARD_REBASE_CHECKPOINT_REQUIRED")
    total = 0
    for name, (mode, oid) in tree.items():
        if not _parents_safe(checkout, name):
            dev.refuse("STANDARD_REBASE_CHECKPOINT_REQUIRED")
        try:
            if mode == "120000":
                info = (checkout.path / name).lstat()
                if not stat.S_ISLNK(info.st_mode):
                    dev.refuse("STANDARD_REBASE_CHECKPOINT_REQUIRED")
                # A bytes path returns the raw stored target, without resolving it
                # or opening even a dangling/outside/private target.
                data = os.readlink(os.fsencode(checkout.path / name))
            else:
                fd = os.open(checkout.path / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as stream:
                    info = os.fstat(stream.fileno())
                    if not stat.S_ISREG(info.st_mode) or info.st_size > dev.MAX_FILE_BYTES:
                        dev.refuse("STANDARD_REBASE_CHECKPOINT_REQUIRED")
                    data = stream.read(dev.MAX_FILE_BYTES + 1)
        except OSError:
            dev.refuse("STANDARD_REBASE_CHECKPOINT_REQUIRED")
        total += len(data)
        if total > MAX_BYTES:
            dev.refuse("STANDARD_REBASE_LIMIT")
        if (checkout.blob_id(data) != oid or
                mode != "120000" and bool(info.st_mode & 0o111) != (mode == "100755")):
            dev.refuse("STANDARD_REBASE_CHECKPOINT_REQUIRED")
    for name in checkout.manifest()["files"]:
        if name not in tree:
            # Do not read even a recorded new file: checkpoint it first.
            dev.refuse("STANDARD_REBASE_CHECKPOINT_REQUIRED")


def _preflight(checkout, dev, old, new):
    for name in old.keys() | new.keys():
        entries = (old.get(name), new.get(name))
        if any(entry and entry[0] == "120000" for entry in entries) and entries[0] != entries[1]:
            dev.refuse("STANDARD_REBASE_UNSUPPORTED_TREE")
    for name in new:
        if not _parents_safe(checkout, name):
            dev.refuse("STANDARD_REBASE_COLLISION")
        if name not in old and os.path.lexists(checkout.path / name):
            dev.refuse("STANDARD_REBASE_COLLISION")
    # Directory/file transitions are deliberately refused, not cleaned recursively.
    # This also avoids ever enumerating a directory of private data.


def _fetch(checkout, dev):
    url = checkout.out("remote", "get-url", "origin").strip()
    if not dev.fetchable(url):
        dev.refuse("STANDARD_REBASE_ORIGIN_REFUSED")
    credentials = checkout.host.github_credentials(checkout.path, url)
    argv, env = credentials or (checkout.host.converter_git(checkout.path, credentials=True), {})
    try:
        result = subprocess.run([*argv, "fetch", "--prune", "--no-tags", "--no-recurse-submodules",
                                 "origin", "+refs/heads/*:refs/remotes/origin/*"],
                                capture_output=True, stdin=subprocess.DEVNULL,
                                env=dev.git_env(env), timeout=40)
    except subprocess.TimeoutExpired:
        dev.refuse("STANDARD_REBASE_TIMEOUT")
    if result.returncode:
        dev.refuse("STANDARD_REBASE_FETCH_FAILED")


def _install(checkout, dev, before, after, old, new, record):
    """Preflight then journal only committed bytes. Roll back on ordinary failures.

    Same-account filesystem races and process/power loss are outside Checkout's
    trust boundary; durable backup ref remains available for engineer recovery.
    """
    _clean(checkout, dev, old)
    _preflight(checkout, dev, old, new)
    changed = sorted(name for name in old.keys() | new.keys() if old.get(name) != new.get(name))
    payload = {}
    total = 0
    entries = {tree[name] for tree in (old, new) for name in changed if name in tree}
    for entry in entries:
        size = int(checkout.out("cat-file", "-s", entry[1]).strip())
        total += size
        if size > dev.MAX_FILE_BYTES or total > MAX_BYTES:
            dev.refuse("STANDARD_REBASE_LIMIT")
        payload[entry] = checkout.git("cat-file", "blob", entry[1]).stdout
    dotgit = checkout.path / ".git"
    index = dotgit / "index"
    previous_index = None
    original_manifest = checkout.manifest()
    original_visible = getattr(checkout, "_visible", None)
    # Git's conventional lock prevents an external index writer joining mid-install.
    try:
        fd = os.open(dotgit / "index.lock", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(fd)
    except OSError:
        dev.refuse("STANDARD_BUSY")
    made_dirs, touched = [], []
    moved = manifest_saved = False

    def write(name, entry):
        path = checkout.path / name
        if entry is None:
            path.unlink()
            return
        missing = []
        parent = path.parent
        while parent != checkout.path and not parent.exists():
            missing.append(parent)
            parent = parent.parent
        for directory in reversed(missing):
            directory.mkdir()
            made_dirs.append(directory)
        descriptor, tmp = tempfile.mkstemp(prefix=".converter-rebase-", dir=path.parent)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(payload[entry])
            os.chmod(tmp, 0o755 if entry[0] == "100755" else 0o644)
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    try:
        previous_index = index.read_bytes()
        # Build a fresh index from objects; never copy live flags or stat cache.
        with tempfile.TemporaryDirectory(prefix="converter-rebase-index-") as tmp:
            scratch_index = str(Path(tmp) / "index")
            _git(dev, checkout.path, "read-tree", after, env={"GIT_INDEX_FILE": scratch_index})
            new_index = Path(scratch_index).read_bytes()
        checkout.git("update-ref", record["backup_ref"], before, "0" * 40)
        for name in changed:
            write(name, new.get(name))
            touched.append(name)
        (dotgit / "index.lock").write_bytes(new_index)
        checkout.git("update-ref", "refs/heads/" + record["branch"], after, before)
        moved = True
        os.replace(dotgit / "index.lock", index)
        checkout.save_manifest(dict(original_manifest, files={}))
        manifest_saved = True
        dev.write_record(_record_path(checkout), record)
    except BaseException:
        if moved:
            checkout.git("update-ref", "refs/heads/" + record["branch"], before, after)
        for name in reversed(touched):
            write(name, old.get(name))
        if previous_index is not None:
            index.write_bytes(previous_index)
        if manifest_saved:
            checkout.save_manifest(original_manifest)
        checkout._visible = original_visible
        for directory in reversed(made_dirs):
            try:
                directory.rmdir()
            except OSError:
                pass
        raise
    finally:
        (dotgit / "index.lock").unlink(missing_ok=True)
    checkout._tree = checkout._visible = None


def _rebase_main(checkout, dev, home):
    """Fresh origin/main only. Caller holds DevLock; this function holds op.lock.

    Returns status=rebased or status=conflict (paths are committed code only).
    All other refusals raise dev.Refusal with a fixed code. Never stashes/pushes.
    The engineer committer identity comes from dev.identity(checkout, home);
    original commit authors are retained by Git rebase.
    """
    with dev.Locked(checkout):
        states = ("rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD",
                  "MERGE_HEAD", "BISECT_LOG", "BISECT_START", "sequencer")
        if any(os.path.lexists(checkout.path / ".git" / name) for name in states):
            dev.refuse("STANDARD_REBASE_IN_PROGRESS")
        branch, before = checkout.branch(), checkout.head()
        if not branch.startswith(checkout.migration_prefix()):
            dev.refuse("STANDARD_DEV_NOT_MIGRATION_BRANCH")
        old = _tree(checkout, before, dev)
        _clean(checkout, dev, old)
        _fetch(checkout, dev)
        if branch not in checkout.manifest()["branches"]:
            if not checkout.out("for-each-ref", "--count=1", "--contains=" + before,
                                "--format=%(refname)", "refs/remotes/origin/").strip():
                dev.refuse("STANDARD_DEV_BRANCH_UNTRUSTED")
        main = _remote(checkout, "main")
        if not main:
            dev.refuse("STANDARD_REBASE_MAIN_MISSING")
        main_tree = _tree(checkout, main, dev)
        remote = _remote(checkout, branch)
        prior = _record(checkout)
        if remote and not _ancestor(checkout, remote, before) and not _continuation(checkout, prior, remote, before):
            dev.refuse("STANDARD_REBASE_REMOTE_DIVERGED")
        if checkout.out("rev-list", "--merges", main + ".." + before).strip():
            dev.refuse("STANDARD_REBASE_MERGES_UNSUPPORTED")
        if int(checkout.out("rev-list", "--count", main + ".." + before)) > dev.MAX_COMMITS:
            dev.refuse("STANDARD_REBASE_LIMIT")
        base = checkout.out("merge-base", main, before).strip()
        committer_name, committer_email = dev.identity(checkout, home)
        with tempfile.TemporaryDirectory(prefix="converter-rebase-") as tmp:
            scratch = Path(tmp)
            _git(dev, scratch, "init", "--quiet", "--template=")
            _git(dev, scratch, "fetch", "--update-shallow", "--no-tags", "--no-recurse-submodules", str(checkout.path), before, main)
            _git(dev, scratch, "checkout", "--quiet", "--detach", before)
            result = _git(dev, scratch, "rebase", "--no-autostash", "--no-gpg-sign", "--no-verify",
                          "--onto", main, base, timeout=90, ok=(0, 1),
                          env={"GIT_COMMITTER_NAME": committer_name,
                               "GIT_COMMITTER_EMAIL": committer_email})
            if result.returncode:
                raw = _git(dev, scratch, "diff", "--name-only", "--diff-filter=U", "-z").stdout
                paths = [p.decode("utf-8", "replace") for p in raw.split(b"\0") if p]
                # Only code paths recorded in the committed trees; no stderr/content.
                allowed = set(old) | set(main_tree)
                paths = [p for p in paths if p in allowed and len(p) <= 512][:50]
                return {"status": "conflict", "paths": paths,
                        "note": "Live HEAD, index and working files are unchanged. Stop and agree a conflict-resolution approach with the engineer; no live rebase needs continuing or aborting."}
            after = _git(dev, scratch, "rev-parse", "HEAD").stdout.decode().strip()
            checkout.git("fetch", "--update-shallow", "--no-tags", "--no-recurse-submodules", str(scratch), after, timeout=30)
        new = _tree(checkout, after, dev)
        record = {"version": 1, "branch": branch, "before_head": before, "after_head": after,
                  "main_head": main, "expected_remote_head": remote,
                  "backup_ref": "refs/silo-migrate/rebase-backups/" + secrets.token_hex(16)}
        _install(checkout, dev, before, after, old, new, record)
        return {"status": "rebased", "branch": branch, "before_head": before,
                "head": after, "main_head": main, "backup_ref": record["backup_ref"],
                "rewrite_required": bool(rewrite_metadata(checkout, dev))}


def rebase_main(checkout, dev, home):
    """Caller holds DevLock; see _rebase_main for the transaction contract."""
    try:
        _git_directory(checkout, dev)
        return _rebase_main(checkout, dev, home)
    except OSError:
        # Filesystem errors can embed unknown/private names. Never surface them.
        dev.refuse("STANDARD_REBASE_FAILED")
