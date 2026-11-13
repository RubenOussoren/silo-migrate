"""Prepared-merge inspection connectors: generation-bound local Discourse MCP (Base/result site)
and DBHub (prepared source database), for the trusted migration-data agent only.

Host-side only; loaded by bin/data_tools.py (op merge_inspection -> inspection_info) and by
bin/silo-migrate-control, which dispatches

    merge-mcp   WS RUN_ID GENERATION base|result      (stdio; term-llm starts it)
    merge-dbhub WS RUN_ID GENERATION source           (stdio; term-llm starts it)

to main(args, values, base, repo, host, data_module).

Authority comes from the private manifest written by StandardMergeInspection
(runs/RUN/private/merge-access.json, 0600 under 0700 directories). Every launch re-checks,
under a shared flock the Ruby fence takes exclusively: confined no-symlink private paths,
the exact generation/phase/endpoint state, the stack's container IDs, ownership labels and
internal-only network, and the credential's recorded digest. Credentials are read from
private files and handed to the connector by a private read-only bind mount (MCP profile
or DBHub config), never env, argv, stdout or logs.

The connector is the pinned @discourse/mcp 0.3.1 installed beforehand by
script/prepare-discourse-mcp (npm ci --ignore-scripts from the committed lockfile, pinned
Node image). A launch verifies the prepared tree digest and image ID and never downloads.

Admission reuses data_tools' term-llm MCP rule (mcp.servers.NAME.agents: [migration-data],
enforced by term-llm 0.9.96+). That rule is agent-scoped: it is not a chat->project or
provider attestation. Choosing the right project's server stays procedural, as for DBHub.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import time

MANIFEST_VERSION = 1
RUN = re.compile(r"run-[0-9a-f]{32}\Z")
GENERATION = re.compile(r"[0-9a-f]{64}\Z")
CONTAINER_ID = re.compile(r"[0-9a-f]{64}\Z")
DB_NAME = re.compile(r"[a-z_][a-z0-9_]{0,62}\Z")
ROLE = re.compile(r"silo_mi_[0-9a-f]{8}\Z")
USERNAME = re.compile(r"silo_inspect_[0-9a-f]{8}\Z")
SIDES = {"base": "merge-mcp", "result": "merge-mcp", "source": "merge-dbhub"}
CREDENTIALS = {"base": "base.key", "result": "result.key", "source": "source.env"}
SITE = "http://web"
PRIVATE = (".silo-migrate", "named", "standard", "runs")
MANIFEST_MAX = 256 * 1024
LOCK_WAIT = 10
# Explicit read domains of the pinned @discourse/mcp 0.3.1 catalog; 0.3.1 has no per-tool filter.
# "administration" is the only domain carrying discourse_list_categories (restricted-category
# inventory), plus discourse_list_site_settings (connector-masked secrets). Its one mutation
# (discourse_manage_user_activation) is writes_enabled, so it is never registered with
# allow_writes false; the server-side read_only key (global:read, GET only) also refuses it.
# "site" adds nothing while tethered (select_site hidden), so it is not listed.
TOOLSETS = ["search", "topics", "users", "groups", "administration"]
# Exactly what tools/list must show for that profile (checked by the connector integration test).
EXPECTED_TOOLS = frozenset({
    "discourse_search", "discourse_filter_topics", "discourse_read_topic", "discourse_read_post",
    "discourse_read_topic_posts", "discourse_search_posts", "discourse_get_user", "discourse_list_user_posts",
    "discourse_list_users", "discourse_list_groups", "discourse_get_group", "discourse_list_group_posts",
    "discourse_list_group_members", "discourse_list_group_membership_requests",
    "discourse_list_categories", "discourse_list_site_settings"})
MAX_READ_LENGTH = 20000
CONNECTOR_MAX_FILES = 20000
CONNECTOR_MAX_BYTES = 256 * 1024 * 1024
LABEL_RUN = "silo.merge-run"
LABEL_GENERATION = "silo.merge-generation"
LABEL_SIDE = "silo.merge-side"


class _Fail(Exception):
    pass


def _refuse(data_module, code):
    data_module.refuse(code)
    raise _Fail(code)  # data_module.refuse always raises; this keeps static readers honest


# -- the pinned connector ------------------------------------------------------------------

def runtime_pin(repo):
    """integrations/discourse-mcp/runtime.json plus the lockfile's digest (both committed)."""
    directory = Path(repo) / "integrations/discourse-mcp"
    pin = json.loads((directory / "runtime.json").read_text())
    lock = (directory / "package-lock.json").read_bytes()
    locked = json.loads(lock)["packages"]["node_modules/" + pin["package"]]
    if locked.get("version") != pin["package_version"] or locked.get("integrity") != pin["package_integrity"]:
        raise ValueError("lock does not match the pin")
    if not re.fullmatch(r"[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}", pin["node_image"]):
        raise ValueError("node image is not pinned by digest")
    return pin, hashlib.sha256(lock).hexdigest()


def connector_dir(lock_sha256, env=None):
    env = os.environ if env is None else env
    data_home = env.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return Path(data_home) / "silo-migrate" / "discourse-mcp" / lock_sha256[:16]


def tree_digest(root):
    """Digest of a prepared install: relative paths, executable bits and contents. Symlinks,
    devices and oversized trees are refused (npm ci runs with --no-bin-links)."""
    digest, files, total = hashlib.sha256(), 0, 0
    root = Path(root)
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        for name in sorted(dirnames + filenames):
            path = Path(directory) / name
            info = os.lstat(path)
            if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise ValueError("unexpected entry")
            if stat.S_ISREG(info.st_mode):
                files += 1
                total += info.st_size
                if files > CONNECTOR_MAX_FILES or total > CONNECTOR_MAX_BYTES:
                    raise ValueError("too large")
                with open(path, "rb") as handle:
                    content = hashlib.sha256(handle.read()).hexdigest()
                digest.update(json.dumps([str(path.relative_to(root)), bool(info.st_mode & 0o111), content]).encode() + b"\n")
    return digest.hexdigest(), files


def connector_ready(repo, data_module, env=None):
    """(install_dir, image_id, entry) of the verified prepared connector, or None."""
    try:
        pin, lock_sha = runtime_pin(repo)
        directory = connector_dir(lock_sha, env)
        info = os.lstat(directory)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            return None
        stamp = json.loads((directory / "stamp.json").read_text())
        if (stamp.get("version") != 1 or stamp.get("lock_sha256") != lock_sha or stamp.get("package_integrity") != pin["package_integrity"]
                or stamp.get("node_image") != pin["node_image"] or not re.fullmatch(r"sha256:[0-9a-f]{64}", stamp.get("image_id") or "")):
            return None
        tree, _ = tree_digest(directory / "install")
        if tree != stamp.get("tree_sha256"):
            return None
        package = json.loads((directory / "install/node_modules" / pin["package"] / "package.json").read_text())
        if package.get("version") != pin["package_version"]:
            return None
        inspected = data_module.docker(["image", "inspect", "--format", "{{.Id}}", stamp["image_id"]], timeout=30)
        if inspected.returncode or inspected.stdout.decode().strip() != stamp["image_id"]:
            return None
        return directory / "install", stamp["image_id"], pin["entry"]
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


# The only accepted homes of the pinned Node digest: the canonical repository and one fixed
# public mirror of it. Never a tag, never another repository, never a different digest.
NODE_REPOSITORIES = ("node", "docker.io/library/node", "library/node")
NODE_MIRROR = "mirror.gcr.io/library/node"


def pinned_node_image(data_module, pin):
    """Local image ID holding exactly the pinned Node digest, or None. Accepted when the image's
    ID is that digest (containerd image store) or one of its RepoDigests is canonical/mirror
    repository @ that digest. A local inspect by canonical tag@digest can miss a mirrored pull,
    so the canonical ref, the mirror ref and the bare digest are each inspected and verified."""
    digest = pin["node_image"].split("@", 1)[1]
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        return None
    allowed = {repo + "@" + digest for repo in (*NODE_REPOSITORIES, NODE_MIRROR)}
    for ref in (pin["node_image"], NODE_MIRROR + "@" + digest, digest):
        result = data_module.docker(["image", "inspect", "--format", "{{.Id}} {{json .RepoDigests}}", ref], timeout=30)
        if result.returncode:
            continue
        try:
            image_id, _, digests = result.stdout.decode("utf-8", "replace").strip().partition(" ")
            digests = json.loads(digests) or []
        except ValueError:
            continue
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id) or not isinstance(digests, list):
            continue
        if image_id == digest or any(isinstance(item, str) and item in allowed for item in digests):
            return image_id
    return None


def _docker_ok(data_module, argv, timeout):
    result = data_module.docker(argv, timeout=timeout)
    return result.returncode == 0, result.stdout.decode("utf-8", "replace").strip()


def prepare_connector(repo, data_module, pull=True, env=None, runner=None):
    """Host preparation hook (silo update / script/prepare-discourse-mcp; never at launch).

    Needs only Docker: the pinned Node image (by digest) runs `npm ci --ignore-scripts --omit=dev
    --no-bin-links` on a staging directory holding nothing but the committed package.json and
    package-lock.json (no customer build context). npm verifies every tarball against the lock's
    sha512 integrity; the result is then digested and stamped. Network is used only here, for the
    public image registry (when pull) and the public npm registry. Idempotent: an already verified
    install is kept. Returns a non-secret summary; raises ValueError("MERGE_MCP_PREPARE_FAILED: ...")."""
    import fcntl
    pin, lock_sha = runtime_pin(repo)
    target = connector_dir(lock_sha, env)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # One preparer at a time (silo update, doctor, script): no concurrent install/rename.
    fd = os.open(target.parent / ".prepare.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        deadline = time.monotonic() + PREPARE_LOCK_WAIT
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ValueError("MERGE_MCP_PREPARE_FAILED: another preparation is running")
                time.sleep(0.2)
        return _prepare_locked(repo, data_module, pull, env, runner, pin, lock_sha, target)
    finally:
        os.close(fd)


PREPARE_LOCK_WAIT = 1800


def _prepare_locked(repo, data_module, pull, env, runner, pin, lock_sha, target):
    import shutil
    import subprocess
    if connector_ready(repo, data_module, env) is not None:
        return {"version": 1, "connector": pin["package"] + "@" + pin["package_version"], "status": "ready"}
    image_id = pinned_node_image(data_module, pin)
    if image_id is None:
        if not pull:
            raise ValueError("MERGE_MCP_PREPARE_FAILED: pinned Node image missing")
        # Canonical first; on failure (e.g. Docker Hub 429) the one fixed public mirror, still by
        # the same digest. Docker verifies pulled content against the digest either way.
        digest = pin["node_image"].split("@", 1)[1]
        for ref in (pin["node_image"], NODE_MIRROR + "@" + digest):
            if data_module.docker(["pull", "--quiet", ref], timeout=900).returncode == 0:
                break
        image_id = pinned_node_image(data_module, pin)
    if image_id is None:
        raise ValueError("MERGE_MCP_PREPARE_FAILED: pinned Node image could not be pulled")
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    staging = target.parent / (".staging-" + secrets.token_hex(6))
    staging.mkdir(mode=0o700)
    try:
        install = staging / "install"
        install.mkdir(mode=0o700)
        source = Path(repo) / "integrations/discourse-mcp"
        for name in ("package.json", "package-lock.json"):
            shutil.copyfile(source / name, install / name)
        if "," in str(install):
            raise ValueError("MERGE_MCP_PREPARE_FAILED: install path")
        argv = ["docker", "run", "--rm", "--pull=never", "--user", f"{os.getuid()}:{os.getgid()}", "--cap-drop", "ALL",
                "--security-opt", "no-new-privileges", "--read-only", "--tmpfs", "/tmp:rw,size=512m,mode=1777",
                "-e", "HOME=/tmp", "-e", "npm_config_cache=/tmp/npm-cache", "-e", "npm_config_update_notifier=false",
                "--mount", f"type=bind,src={install},dst=/work", "-w", "/work", image_id,
                "npm", "ci", "--ignore-scripts", "--omit=dev", "--no-bin-links", "--no-audit", "--no-fund", "--loglevel=error"]
        run = runner or (lambda command: subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                                         stderr=subprocess.DEVNULL, timeout=900).returncode)
        if run(argv) != 0:
            raise ValueError("MERGE_MCP_PREPARE_FAILED: npm ci from the pinned lock failed")
        installed = json.loads((install / "node_modules/.package-lock.json").read_text())["packages"]["node_modules/" + pin["package"]]
        package = json.loads((install / "node_modules" / pin["package"] / "package.json").read_text())
        if installed.get("integrity") != pin["package_integrity"] or package.get("version") != pin["package_version"]:
            raise ValueError("MERGE_MCP_PREPARE_FAILED: installed connector does not match the pin")
        tree, files = tree_digest(install)
        stamp = {"version": 1, "package": pin["package"], "package_version": pin["package_version"],
                 "package_integrity": pin["package_integrity"], "lock_sha256": lock_sha, "node_image": pin["node_image"],
                 "image_id": image_id, "tree_sha256": tree, "files": files, "prepared_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        fd = os.open(staging / "stamp.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(stamp, handle, indent=2, sort_keys=True)
        if target.exists() or target.is_symlink():
            # Only reached when the existing install failed verification. It may still be bind-
            # mounted by a running launcher: move it aside, never delete it here.
            os.rename(target, target.parent / (".retired-" + secrets.token_hex(6)))
        os.rename(staging, target)
    except (OSError, KeyError, ValueError, subprocess.TimeoutExpired) as error:
        shutil.rmtree(staging, ignore_errors=True)
        if isinstance(error, ValueError) and str(error).startswith("MERGE_MCP_PREPARE_FAILED"):
            raise
        raise ValueError("MERGE_MCP_PREPARE_FAILED: install could not be verified")
    if connector_ready(repo, data_module, env) is None:
        raise ValueError("MERGE_MCP_PREPARE_FAILED: install could not be verified")
    return {"version": 1, "connector": pin["package"] + "@" + pin["package_version"], "status": "prepared", "files": files}


# -- the private manifest ---------------------------------------------------------------------

def _private_fd(ws, run_id, data_module):
    """Descriptor of runs/RUN/private: no symlinks on the way, owned by us, 0700."""
    refusal = getattr(data_module, "Refusal", ValueError)
    try:
        root = data_module.open_root(str(ws.root))
    except refusal:
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")
    try:
        fd = data_module.walk_dirs(root, [*PRIVATE, run_id, "private"])
    except refusal as error:
        # Never opened for this run (no private directory yet) versus a link/unsafe path.
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_STALE" if str(error) == "STANDARD_PATH_MISSING" else "STANDARD_MERGE_INSPECTION_INVALID")
    finally:
        os.close(root)
    info = os.fstat(fd)
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        os.close(fd)
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")
    return fd


def _read_private(dir_fd, name, limit, data_module):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=dir_fd)
    except OSError:
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077 or info.st_size > limit:
            _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")
        data = os.read(fd, limit + 1)
        if len(data) > limit:
            _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")
        return data
    finally:
        os.close(fd)


class _SharedLock:
    """Shared flock on merge-access.lock: the Ruby fence holds it exclusively while it marks the
    manifest and removes launchers, so no validated launch can straddle a fence."""

    def __init__(self, dir_fd, data_module):
        self.dir_fd, self.data_module = dir_fd, data_module

    def __enter__(self):
        try:
            self.fd = os.open("merge-access.lock", os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=self.dir_fd)
        except OSError:
            _refuse(self.data_module, "STANDARD_MERGE_INSPECTION_INVALID")
        info = os.fstat(self.fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            os.close(self.fd)
            _refuse(self.data_module, "STANDARD_MERGE_INSPECTION_INVALID")
        deadline = time.monotonic() + LOCK_WAIT
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    os.close(self.fd)
                    _refuse(self.data_module, "STANDARD_BUSY")
                time.sleep(0.1)

    def __exit__(self, *exc):
        os.close(self.fd)


def validate_manifest(manifest, ws_name, run_id, generation, side, data_module):
    """The endpoint record for SIDE of an open manifest of exactly this run/generation."""
    def bad():
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")

    if not isinstance(manifest, dict) or manifest.get("version") != MANIFEST_VERSION or manifest.get("run_id") != run_id:
        bad()
    if not isinstance(manifest.get("preparation_run_id"), str) or not RUN.fullmatch(manifest["preparation_run_id"]):
        bad()
    owner, containers = manifest.get("owner"), manifest.get("containers")
    if not (isinstance(owner, dict) and owner.get("workspace") == ws_name and isinstance(owner.get("instance"), str)
            and re.fullmatch(r"silomig-[0-9a-f]{8}-review", owner["instance"])):
        bad()
    if not (isinstance(containers, dict) and all(isinstance(containers.get(k), str) and CONTAINER_ID.fullmatch(containers[k]) for k in ("web", "db"))):
        bad()
    if manifest.get("network") != owner["instance"] + "-int":
        bad()
    # Stale or fenced generations are refused with a distinct fixed code.
    if manifest.get("generation") != generation or manifest.get("state") != "open":
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_STALE")
    phase = manifest.get("phase")
    if phase not in ("base", "result") or (side in ("base", "result") and side != phase) or (side == "source" and phase != "base"):
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_STALE")
    endpoints = manifest.get("endpoints")
    if not isinstance(endpoints, dict):
        bad()
    endpoint = endpoints.get(side)
    if not isinstance(endpoint, dict) or endpoint.get("state") != "open" or endpoint.get("credential") != CREDENTIALS[side]:
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_STALE")
    if not (isinstance(endpoint.get("credential_sha256"), str) and GENERATION.fullmatch(endpoint["credential_sha256"])):
        bad()
    if side == "source":
        policy = endpoint.get("policy")
        if not isinstance(policy, dict):
            bad()
        if not (endpoint.get("kind") == "dbhub" and isinstance(endpoint.get("role"), str) and ROLE.fullmatch(endpoint["role"])
                and isinstance(endpoint.get("database"), str) and DB_NAME.fullmatch(endpoint["database"])
                and endpoint["database"] not in ("discourse", "postgres", "template0", "template1")
                and isinstance(policy.get("version"), str) and policy["version"].startswith("merge-source-read-v")):
            bad()
    else:
        if not (endpoint.get("kind") == "discourse-mcp" and endpoint.get("site") == SITE and isinstance(endpoint.get("username"), str)
                and USERNAME.fullmatch(endpoint["username"]) and endpoint.get("scope_mode") == "read_only"
                and endpoint.get("scopes") == ["global:read"] and isinstance(endpoint.get("api_key_id"), int)):
            bad()
    return endpoint


def load_manifest(ws, run_id, data_module, dir_fd):
    raw = _read_private(dir_fd, "merge-access.json", MANIFEST_MAX, data_module)
    try:
        return json.loads(raw)
    except ValueError:
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")


def read_credential(dir_fd, side, endpoint, data_module):
    """The endpoint's secret, only if its bytes match the digest recorded when it was minted."""
    try:
        sub = os.open("merge-inspection", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)
    except OSError:
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")
    try:
        info = os.fstat(sub)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")
        raw = _read_private(sub, CREDENTIALS[side], 4096, data_module)
    finally:
        os.close(sub)
    if hashlib.sha256(raw).hexdigest() != endpoint["credential_sha256"]:
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")
    text = raw.decode("ascii", "replace")
    if side == "source":
        values = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
        if values.get("SILO_MI_ROLE") != endpoint["role"] or not re.fullmatch(r"[0-9a-f]{48}", values.get("SILO_MI_PASSWORD", "")):
            _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")
        return values["SILO_MI_PASSWORD"]
    if not re.fullmatch(r"[0-9a-f]{64}", text):
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")
    return text


def verify_environment(manifest, data_module):
    """The recorded web/db containers still run with the stack's ownership labels, each attached to
    the internal network only, and that network is internal and owned by the same instance."""
    instance, network = manifest["owner"]["instance"], manifest["network"]
    for role in ("web", "db"):
        result = data_module.docker(["container", "inspect", "--format", "{{json .}}", manifest["containers"][role]], timeout=30)
        try:
            document = json.loads(result.stdout) if result.returncode == 0 else None
        except ValueError:
            document = None
        labels = ((document or {}).get("Config") or {}).get("Labels") or {}
        networks = (((document or {}).get("NetworkSettings") or {}).get("Networks") or {})
        if not (document and document.get("Id") == manifest["containers"][role] and (document.get("State") or {}).get("Running") is True
                and document.get("Name") == "/" + instance + "-" + role and labels.get("silo-migrate.managed") == "true"
                and labels.get("silo-migrate.instance") == instance and set(networks) == {network}):
            _refuse(data_module, "STANDARD_MERGE_INSPECTION_UNAVAILABLE")
    result = data_module.docker(["network", "inspect", "--format", "{{json .}}", network], timeout=30)
    try:
        document = json.loads(result.stdout) if result.returncode == 0 else None
    except ValueError:
        document = None
    labels = (document or {}).get("Labels") or {}
    if not (document and document.get("Name") == network and document.get("Internal") is True
            and labels.get("silo-migrate.instance") == instance and labels.get("silo-migrate.managed") == "true"):
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_UNAVAILABLE")


def _checked_request(request, data_module):
    run_id, generation, side = request.get("run_id"), request.get("generation"), request.get("side")
    if not isinstance(run_id, str) or not RUN.fullmatch(run_id):
        _refuse(data_module, "STANDARD_ARGUMENTS_INVALID: run_id")
    if not isinstance(generation, str) or not GENERATION.fullmatch(generation):
        _refuse(data_module, "STANDARD_ARGUMENTS_INVALID: generation")
    if side not in SIDES:
        _refuse(data_module, "STANDARD_ARGUMENTS_INVALID: side is source, base or result")
    return run_id, generation, side


def validate_run_environment(ws, manifest, side, data_module):
    """An open credential manifest is necessary, not sufficient: failure/recovery can
    invalidate the owning generation after opening. Read current atomic state under
    the shared endpoint fence before handing any credential to a new launcher."""
    root = data_module.open_root(str(ws.root))
    standard = None
    try:
        standard = data_module.walk_dirs(root, [".silo-migrate", "named", "standard"])
        raw = _read_private(standard, "state.json", 64 * 1024 * 1024, data_module)
        state = json.loads(raw)
    except (OSError, ValueError, TypeError, RecursionError):
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_STALE")
    finally:
        if standard is not None:
            os.close(standard)
        os.close(root)
    try:
        run_id, preparation = manifest["run_id"], manifest["preparation_run_id"]
        runs = state["runs"]
        run, prepared = runs[run_id], runs[preparation]
        environment = prepared["merge_environment"]
        instance = state["instances"][environment["instance"]]
        if not all(isinstance(item, dict) for item in (state, runs, run, prepared, environment, instance)):
            _refuse(data_module, "STANDARD_MERGE_INSPECTION_STALE")
        valid = (run["status"] == "completed" and prepared["status"] == "completed"
                 and environment["preparation_run_id"] == preparation
                 and environment["generation"] == manifest["generation"]
                 and instance["name"] == manifest["owner"]["instance"]
                 and instance["state"] != "removed")
        if side == "result":
            binding = state["plans"][run["plan_id"]]["body"]["prepared_from"]
            backup = run["artifacts"]["backup"]
            valid = (valid and environment["phase"] == "result" and environment["consumed_by"] == run_id
                     and binding == {"run_id": preparation, "generation": manifest["generation"]}
                     and backup["merge_generation"] == manifest["generation"]
                     and backup["preparation_run_id"] == preparation)
        else:
            valid = (valid and run_id == preparation and environment["phase"] == "ready"
                     and environment.get("consumed_by") is None and instance["state"] == "prepared")
        if not valid:
            _refuse(data_module, "STANDARD_MERGE_INSPECTION_STALE")
    except (KeyError, TypeError, AttributeError):
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_STALE")


def checked_endpoint(ws, run_id, generation, side, data_module, dir_fd):
    manifest = load_manifest(ws, run_id, data_module, dir_fd)
    endpoint = validate_manifest(manifest, ws.name, run_id, generation, side, data_module)
    validate_run_environment(ws, manifest, side, data_module)
    verify_environment(manifest, data_module)
    return manifest, endpoint


# -- registration (trusted migration-data admission) ----------------------------------------

def server_name(ws, side):
    return "merge-" + side + "-" + ws.name


def _ours(name, server, ws, data_module):
    """Exactly an entry this module writes: fixed control command, verb matching its side, this
    project, well-formed run/generation, and the server name of that side. Nothing else."""
    if not (isinstance(server, dict) and set(server) == {"command", "args"}):
        return False
    args = server.get("args")
    if not (isinstance(args, list) and len(args) == 5 and all(isinstance(arg, str) for arg in args)):
        return False
    verb, workspace, run_id, generation, side = args
    return (side in SIDES and SIDES[side] == verb and workspace == ws.name and name == server_name(ws, side)
            and RUN.fullmatch(run_id) is not None and GENERATION.fullmatch(generation) is not None
            and server.get("command") == data_module.mcp_entry(ws)["command"])


def _entry(ws, run_id, generation, side, data_module):
    return {"command": data_module.mcp_entry(ws)["command"], "args": [SIDES[side], ws.name, run_id, generation, side]}


def _edit_servers(ws, data_module, change):
    """Run change(servers) under term-llm's mcp.json lock; write only if it returns True."""
    path = data_module.mcp_config_path()
    with data_module.mcp_lock():
        try:
            if not stat.S_ISREG(os.lstat(path).st_mode):
                _refuse(data_module, "STANDARD_MERGE_MCP_CONFIG_UNREADABLE")
            config = json.loads(path.read_text())
        except FileNotFoundError:
            config = {}
        except (OSError, ValueError):
            _refuse(data_module, "STANDARD_MERGE_MCP_CONFIG_UNREADABLE")
        servers = config.setdefault("servers", {}) if isinstance(config, dict) else None
        if not isinstance(servers, dict):
            _refuse(data_module, "STANDARD_MERGE_MCP_CONFIG_UNREADABLE")
        result = change(servers)
        if result:
            data_module.write_mcp_config(path, config)
        return result, servers, config, path


def register(ws, run_id, generation, side, data_module):
    """Rule first (migration-data only, enforced by term-llm 0.9.96+), then this environment's
    entry; other generations' entries of this project are dropped. No rule, no server."""
    name = server_name(ws, side)
    term = data_module.term_llm_command(ws.prefix)
    if not (term and data_module.term_llm_enforces(term)):
        _refuse(data_module, "STANDARD_MERGE_MCP_RULES_UNENFORCED: this term-llm doesn't enforce MCP agent rules (0.9.96+ does)")
    if not data_module.mcp_rule(name, term):
        _refuse(data_module, "STANDARD_MERGE_MCP_RULE_MISSING: the server could not be limited to migration-data")
    entry = _entry(ws, run_id, generation, side, data_module)

    def change(servers):
        existing = servers.get(name)
        if existing is not None and not _ours(name, existing, ws, data_module):
            _refuse(data_module, "STANDARD_MERGE_MCP_NAME_TAKEN: an existing server with this name isn't silo-migrate's")
        if existing == entry:
            return False
        servers[name] = entry
        return True

    changed, servers, config, path = _edit_servers(ws, data_module, change)
    if not data_module.mcp_rule_present(name):
        # config.yaml has other writers: never leave the server listed without its rule.
        _edit_servers(ws, data_module, lambda current: current.pop(name, None) is not None)
        _refuse(data_module, "STANDARD_MERGE_MCP_RULE_MISSING: its rule left term-llm's config.yaml; run this again")
    if changed:
        ws.append("audit.jsonl", {"at": data_module.now(), "op": "merge_mcp_register", "server": name, "run_id": run_id,
                                  "generation": generation, "result": "added"})
    return name, "added" if changed else "registered"


def deregister(ws, data_module, keep=()):
    """Remove this project's merge-inspection entries (rules stay, as for DBHub)."""
    keep = set(keep)

    def change(servers):
        stale = [name for name, server in servers.items() if _ours(name, server, ws, data_module) and name not in keep]
        for name in stale:
            del servers[name]
        return stale

    removed = _edit_servers(ws, data_module, change)[0]
    if removed:
        ws.append("audit.jsonl", {"at": data_module.now(), "op": "merge_mcp_deregister", "servers": len(removed)})
    return len(removed or [])


def stop_launchers(ws, data_module, run_id=None):
    """Remove this project's labelled merge-inspection launcher containers (all runs, or one)."""
    if run_id is not None and not (isinstance(run_id, str) and RUN.fullmatch(run_id)):
        _refuse(data_module, "STANDARD_ARGUMENTS_INVALID")
    removed, failed = 0, 0
    for role in ("merge-mcp", "merge-dbhub"):
        filters = ["--filter", "label=silo.workspace=" + ws.name, "--filter", "label=silo.role=" + role,
                   "--filter", "label=" + LABEL_SIDE]
        if run_id:
            filters += ["--filter", "label=" + LABEL_RUN + "=" + run_id]
        listed = data_module.docker(["ps", "-a", "--no-trunc", *filters, "--format",
                                     "{{.ID}} {{.Label \"" + LABEL_RUN + "\"}} {{.Label \"" + LABEL_GENERATION + "\"}} {{.Label \"" + LABEL_SIDE + "\"}}"],
                                    timeout=30)
        if listed.returncode:
            failed += 1
            continue
        for line in listed.stdout.decode("ascii", "replace").splitlines():
            fields = line.split()
            if not fields:
                continue
            container = fields[0]
            if not CONTAINER_ID.fullmatch(container):
                failed += 1
                continue
            # Without a run to clean, a launcher of a still-open generation keeps serving its chat.
            if run_id is None and len(fields) == 4 and _still_open(ws, fields[1], fields[2], fields[3], data_module):
                continue
            if data_module.docker(["rm", "-f", container], timeout=60).returncode:
                failed += 1
            else:
                removed += 1
    return removed, failed


def cleanup(ws, data_module, run_id=None):
    """Host-side cleanup after Ruby merge_inspection_close, a merge start or a reset: stop this
    project's launchers and remove its owned merge-* entries from mcp.json (rules stay, as for
    DBHub). Idempotent; touches only entries/containers that match this project's fixed shape.
    Returns counts only. Raises a fixed refusal if something owned could not be removed."""
    removed, failed = stop_launchers(ws, data_module, run_id)

    def change(servers):
        stale = []
        for name, server in list(servers.items()):
            if not _ours(name, server, ws, data_module):
                continue
            _, _, entry_run, entry_generation, entry_side = server["args"]
            # Safe at any time (status, fence, reset): only an entry whose own manifest is still
            # open at that exact generation/side survives, and never while that run is cleaned.
            if entry_run != run_id and _still_open(ws, entry_run, entry_generation, entry_side, data_module):
                continue
            del servers[name]
            stale.append(name)
        return stale

    stale = _edit_servers(ws, data_module, change)[0]
    deregistered = len(stale or [])
    if deregistered:
        ws.append("audit.jsonl", {"at": data_module.now(), "op": "merge_mcp_cleanup", "servers": deregistered})
    if failed:
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_CLEANUP_FAILED")
    return {"version": 1, "launchers_removed": removed, "servers_removed": deregistered}


def inspection_info(ws, request, data_module):
    """data_merge_inspection: validate the open generation and register its connector for
    migration-data. Returns only safe fields: no paths, credentials, hostnames or ports."""
    ws.require()
    run_id, generation, side = _checked_request(request, data_module)
    dir_fd = _private_fd(ws, run_id, data_module)
    try:
        with _SharedLock(dir_fd, data_module):
            checked_endpoint(ws, run_id, generation, side, data_module, dir_fd)
    finally:
        os.close(dir_fd)
    if side == "source":
        ready = bool(data_module.dbhub_image(0))
        missing = "the pinned DBHub image is missing: the engineer runs silo update to prepare the public inspection dependencies"
    else:
        ready = connector_ready(ws.repo, data_module) is not None
        missing = "the pinned Discourse MCP connector is not prepared: the engineer runs silo update to prepare the public inspection dependencies"
    name, registration = register(ws, run_id, generation, side, data_module)
    # Other generations/phases of this project are no longer listed.
    deregister(ws, data_module, keep=[server_name(ws, s) for s in SIDES if s == side or _still_open(ws, run_id, generation, s, data_module)])
    what = ("read-only SQL on the prepared source inspection copy (reviewed core columns only; at most 50 rows per query)" if side == "source"
            else "read-only Discourse API tools on the local " + side + " inspection site (writes disabled, emails hidden)")
    return {"run_id": run_id, "generation": generation, "side": side, "mcp_server": name, "registration": registration, "ready": ready,
            "access_model": ("reviewed column-level SELECT grants, not table-level SELECT; use has_any_column_privilege/has_column_privilege to inspect grants" if side == "source"
                             else "admin visibility for restricted-content inspection; read-only global:read API key, GET only; no mutation tools"),
            "category_budget": None if side == "source" else "Use default request budgets or max_requests >= 4 for category discovery. The GET-only key rejects the initial category-search POST; its GET fallback consumes another request. An incomplete empty response is not evidence of an empty site.",
            "next": ("Bound to run " + run_id + " generation " + generation + ". The engineer turns on MCP server " + name + " in this chat (MCP button): " + what + ". Use only this project's server; "
                     "it stops working when the environment is fenced for the merge or reset.") if ready else missing}


def _still_open(ws, run_id, generation, side, data_module):
    try:
        dir_fd = _private_fd(ws, run_id, data_module)
    except Exception:
        return False
    try:
        manifest = load_manifest(ws, run_id, data_module, dir_fd)
        validate_manifest(manifest, ws.name, run_id, generation, side, data_module)
        validate_run_environment(ws, manifest, side, data_module)
        return True
    except Exception:
        return False
    finally:
        os.close(dir_fd)


# -- stdio launchers ----------------------------------------------------------------------

def _write_launch_file(dir_fd, name, content, data_module):
    sub = os.open("merge-inspection", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)
    try:
        temporary = "." + name + "." + secrets.token_hex(4)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=sub)
        with os.fdopen(fd, "w") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, name, src_dir_fd=sub, dst_dir_fd=sub)
    finally:
        os.close(sub)


def mcp_profile(endpoint, key):
    """The connector's whole configuration: tethered to the local site, writes off, API-only
    tools (no remote tool discovery), explicit read toolsets, emails hidden, logs silent."""
    return {"auth_pairs": [{"site": SITE, "api_key": key, "api_username": endpoint["username"]}],
            "site": SITE, "allow_writes": False, "read_only": True, "tools_mode": "discourse_api_only",
            "toolsets": list(TOOLSETS), "show_emails": False, "log_level": "silent", "max_read_length": MAX_READ_LENGTH,
            "timeout_ms": 15000, "concurrency": 2, "transport": "stdio"}


def dbhub_toml(endpoint, password, data_module):
    if not re.fullmatch(r"[0-9a-f]{48}", password or ""):
        _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")
    # The password lives only in this private 0600 file (bind-mounted read-only): not in the
    # container's environment (docker inspect shows it) nor in argv.
    dsn = "postgres://" + endpoint["role"] + ":" + password + "@db:5432/" + endpoint["database"] + "?sslmode=disable"
    return ("# Written by silo-migrate for a fenced, generation-bound merge inspection. The read role's reviewed\n"
            "# column grants are the limit; DBHub adds read-only transactions and a row cap.\n"
            "[[sources]]\nid = \"source\"\ndsn = \"" + dsn + "\"\nconnection_timeout = 10\nquery_timeout = 120\n\n"
            "[[tools]]\nname = \"execute_sql\"\nsource = \"source\"\nreadonly = true\nmax_rows = " + str(data_module.DBHUB_MAX_ROWS) + "\n\n"
            "[[tools]]\nname = \"search_objects\"\nsource = \"source\"\n\n"
            "[[tools]]\nname = \"explain_sql\"\nsource = \"source\"\n")


def launch_argv(ws, manifest, side, run_id, generation, image, mounts, arguments, entrypoint=None, env_names=()):
    labels = {"silo.workspace": ws.name, "silo.role": SIDES[side], LABEL_RUN: run_id, LABEL_GENERATION: generation, LABEL_SIDE: side}
    argv = ["docker", "create", "-i", "--rm", "--pull=never", "--name", "silo-mi-" + ws.name + "-" + side + "-" + secrets.token_hex(3)]
    for key, value in labels.items():
        argv += ["--label", key + "=" + value]
    argv += ["--network", manifest["network"], "--read-only", "--tmpfs", "/tmp:rw,size=64m,mode=1777",
             "--user", f"{os.getuid()}:{os.getgid()}", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
             "--cpus", "1", "--memory", "512m", "--memory-swap", "512m", "--pids-limit", "128", "--log-driver", "none",
             "-e", "HOME=/tmp"]
    for name in env_names:
        argv += ["-e", name]
    for source, target in mounts:
        argv += ["--mount", f"type=bind,src={source},dst={target},readonly"]
    if entrypoint:
        argv += ["--entrypoint", entrypoint]
    return argv + [image, *arguments]


def _docker_env(extra=None):
    env = {"PATH": os.environ.get("PATH") or "/usr/local/bin:/usr/bin:/bin", "HOME": os.path.expanduser("~")}
    for key in ("DOCKER_HOST", "DOCKER_CONFIG", "XDG_RUNTIME_DIR"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    env.update(extra or {})
    return env


def _create(argv, env, data_module):
    """docker create, acknowledged by a container ID. If the outcome is unacknowledged (error,
    timeout, odd output) a container may still exist or appear late: remove it by its fixed,
    unique name and only report a plain failure once Docker confirms that name is absent;
    otherwise the outcome stays uncertain (the run-labelled container is also swept by the
    Ruby fence and the host cleanup)."""
    import subprocess
    name = argv[argv.index("--name") + 1]
    try:
        result = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
        container = result.stdout.decode("ascii", "replace").strip()
        if result.returncode == 0 and CONTAINER_ID.fullmatch(container):
            return container
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        subprocess.run(["docker", "rm", "-f", name], env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
        gone = subprocess.run(["docker", "container", "inspect", name], env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        absent = gone.returncode != 0 and b"no such" in gone.stderr.lower()
    except (OSError, subprocess.TimeoutExpired):
        absent = False
    _refuse(data_module, "STANDARD_MERGE_INSPECTION_UNAVAILABLE" if absent else "STANDARD_MERGE_INSPECTION_LAUNCH_UNCERTAIN")


def require_admission(ws, side, data_module):
    """Every launch: term-llm must enforce per-agent MCP rules and config.yaml must still limit this
    exact server to migration-data. Otherwise a still-listed server would be admitted to any agent.
    Refuses (no repair here: mcp-rules/doctor/inspection_info put rules back under their lock)."""
    term = data_module.term_llm_command(ws.prefix)
    if not (term and data_module.term_llm_enforces(term)):
        _refuse(data_module, "STANDARD_MERGE_MCP_RULES_UNENFORCED")
    if not data_module.mcp_rule_present(server_name(ws, side)):
        _refuse(data_module, "STANDARD_MERGE_MCP_RULE_MISSING")


def main(args, values, base, repo, host, data_module):
    """`merge-mcp WS RUN GEN base|result` / `merge-dbhub WS RUN GEN source`: started by term-llm as a
    stdio MCP server. Validates under the shared fence lock, creates one labelled container on the
    stack's internal network, releases the lock and becomes `docker start -ai`. Prints nothing."""
    if len(args) != 5 or args[0] not in ("merge-mcp", "merge-dbhub") or args[4] not in SIDES or SIDES[args[4]] != args[0]:
        _refuse(data_module, "STANDARD_ARGUMENTS_INVALID")
    ws = data_module.Workspace(base, args[1], repo, host, values, None)
    ws.require()
    run_id, generation, side = _checked_request({"run_id": args[2], "generation": args[3], "side": args[4]}, data_module)
    require_admission(ws, side, data_module)
    if side == "source":
        image = data_module.DBHUB_IMAGE
        if not data_module.dbhub_image(0):
            _refuse(data_module, "STANDARD_MERGE_DBHUB_NOT_PREPARED")
        prepared = None
    else:
        prepared = connector_ready(repo, data_module)
        if prepared is None:
            _refuse(data_module, "STANDARD_MERGE_MCP_NOT_PREPARED: run script/prepare-discourse-mcp; nothing is downloaded at launch")
    dir_fd = _private_fd(ws, run_id, data_module)
    try:
        private = ws.root.joinpath(*PRIVATE, run_id, "private", "merge-inspection")
        if "," in str(private) or (prepared and "," in str(prepared[0])):
            _refuse(data_module, "STANDARD_MERGE_INSPECTION_INVALID")
        with _SharedLock(dir_fd, data_module):
            manifest, endpoint = checked_endpoint(ws, run_id, generation, side, data_module, dir_fd)
            secret = read_credential(dir_fd, side, endpoint, data_module)
            if side == "source":
                _write_launch_file(dir_fd, "source.dbhub.toml", dbhub_toml(endpoint, secret, data_module), data_module)
                argv = launch_argv(ws, manifest, side, run_id, generation, image,
                                   [(private / "source.dbhub.toml", "/config/dbhub.toml")],
                                   ["--transport", "stdio", "--config", "/config/dbhub.toml"])
                container = _create(argv, _docker_env(), data_module)
            else:
                install, image_id, entry = prepared
                profile = side + ".profile.json"
                _write_launch_file(dir_fd, profile, json.dumps(mcp_profile(endpoint, secret)), data_module)
                argv = launch_argv(ws, manifest, side, run_id, generation, image_id,
                                   [(install, "/opt/discourse-mcp"), (private / profile, "/config/profile.json")],
                                   ["/opt/discourse-mcp/" + entry, "--profile", "/config/profile.json"], entrypoint="node")
                container = _create(argv, _docker_env(), data_module)
            secret = None
    finally:
        os.close(dir_fd)
    os.execvpe("docker", ["docker", "start", "-a", "-i", container], _docker_env())
