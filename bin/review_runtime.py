"""Public stock-image preparation for review/merge only (not full-stack qualification).

No backup contents are opened here. version/schema are bounded metadata, never Docker
arguments other than a strictly parsed public product tag. Callers must admit the
returned profile only for review/merge, and re-resolve for every new Base backup.
"""
import copy
import contextvars
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import secrets
import signal
import shutil
import subprocess
import tempfile
import time

PUBLIC = "docker.io/discourse/discourse"
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
_VERSION_SPEC = importlib.util.spec_from_file_location("review_discourse_version", Path(__file__).resolve().with_name("discourse_version.py"))
_VERSIONS = importlib.util.module_from_spec(_VERSION_SPEC)
_VERSION_SPEC.loader.exec_module(_VERSIONS)
MAX_OUTPUT = 2 * 1024 * 1024
RECIPE = Path("runtime/prebuilt-discourse/review-runtime.Dockerfile")
TOTAL_SECONDS = 1200
CLEANUP_SECONDS = 30
_BUDGET = contextvars.ContextVar("review_runtime_budget", default=None)


class Budget:
    def __init__(self, deadline):
        self.deadline = deadline
        self.uncertain = False
        self.attempt = None
        self.phase = None
        self.lease_path = None

    def limit(self, timeout, cleanup=False):
        remaining = self.deadline - time.monotonic() - (0 if cleanup else CLEANUP_SECONDS)
        if remaining <= 0:
            refuse("TIMEOUT")
        return min(timeout, remaining)


@contextmanager
def preparation_lease(cache, budget):
    """Fence an interrupted daemon operation, rather than assuming killing its
    client cancelled it. Only a settled attempt removes its own public lease."""
    path = cache / ".inflight.json"
    attempt = budget.attempt or secrets.token_hex(16)
    budget.attempt, budget.lease_path = attempt, path
    body = encoded({"version": 1, "attempt": attempt, "status": "in_progress", "started_at": time.time()})
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        refuse("RECOVERY_REQUIRED")
    with os.fdopen(fd, "wb") as stream:
        stream.write(body)
        stream.flush()
        os.fsync(stream.fileno())
    directory_fd = os.open(cache, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    try:
        yield
    finally:
        if json.loads(read_regular(path)).get("attempt") != attempt:
            refuse("RECOVERY_REQUIRED")
        # SIGKILL/power loss intentionally leaves this lease for operator recovery.
        # A timed-out pull/build also stays fenced even if the CLI exited.
        if budget.uncertain:
            temporary = cache / (".inflight-" + attempt)
            try:
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "wb") as stream:
                    stream.write(encoded({"version": 1, "attempt": attempt, "status": "outcome_unknown", "phase": budget.phase}))
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)
        else:
            path.unlink()
        fd = os.open(cache, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def record_phase(budget, args):
    if not budget.lease_path or args[:2] not in (["docker", "pull"], ["docker", "build"], ["docker", "run"]):
        return
    if args[1] == "run":
        budget.phase = {"operation": "run", "container": args[args.index("--name") + 1]}
    else:
        ref = args[2] if args[1] == "pull" else args[args.index("--tag") + 1]
        budget.phase = {"operation": args[1], "image_ref": ref}
    current = json.loads(read_regular(budget.lease_path))
    if current.get("attempt") != budget.attempt:
        refuse("RECOVERY_REQUIRED")
    temporary = budget.lease_path.with_name(".phase-" + secrets.token_hex(16))
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded(dict(current, phase=budget.phase)))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, budget.lease_path)
        fd = os.open(budget.lease_path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        temporary.unlink(missing_ok=True)


def acquire_lock(lock, budget):
    while True:
        budget.limit(1)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            time.sleep(0.1)


class Refusal(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def refuse(reason):
    raise Refusal("STANDARD_REVIEW_RUNTIME_" + reason)


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def identity(document):
    # Keep identical to silo-migrate-control's image-identity contract.
    config = document["Config"]
    body = {"architecture": document.get("Architecture") or "", "os": document.get("Os") or "",
            "diff_ids": document["RootFS"].get("Layers") or [],
            "config": {key: config.get(key) or ([] if key in ("Cmd", "Entrypoint", "Env") else "")
                       for key in ("Cmd", "Entrypoint", "Env", "User", "WorkingDir")}}
    return "sha256:" + sha(encoded(body))


def parse_version(value):
    parsed = _VERSIONS.parse(value)
    if parsed is None:
        refuse("VERSION_INVALID")
    release, phase, suffix = parsed["numeric"]
    return parsed["track"], tuple(release) + (phase, suffix)


def run(args, *, timeout=120, cwd=None, input_bytes=None, cleanup=False):
    """Bound one command by the shared deadline, cap both output streams, and
    kill its complete client/plugin process group on interruption. Daemon-side
    pull/build outcomes are fenced when interruption makes them uncertain."""
    budget = _BUDGET.get()
    if budget:
        timeout = budget.limit(timeout, cleanup=cleanup)
    env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8"}
    with tempfile.TemporaryDirectory(prefix="docker-public-") as config, tempfile.TemporaryFile() as source:
        env["DOCKER_CONFIG"] = config
        if input_bytes is not None:
            if len(input_bytes) > MAX_OUTPUT:
                refuse("OUTPUT_LIMIT")
            source.write(input_bytes)
            source.seek(0)
        proc = None
        interrupted = True
        try:
            if budget:
                record_phase(budget, args)
            proc = subprocess.Popen(args, cwd=cwd, env=env,
                                    stdin=source if input_bytes is not None else subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            result, total = bytearray(), 0
            deadline = time.monotonic() + timeout
            with selectors.DefaultSelector() as selector:
                selector.register(proc.stdout, selectors.EVENT_READ)
                selector.register(proc.stderr, selectors.EVENT_READ)
                while selector.get_map():
                    if time.monotonic() >= deadline:
                        refuse("TIMEOUT")
                    for key, _ in selector.select(min(0.2, max(0, deadline - time.monotonic()))):
                        block = os.read(key.fileobj.fileno(), 65536)
                        if not block:
                            selector.unregister(key.fileobj)
                            continue
                        total += len(block)
                        if total > MAX_OUTPUT:
                            refuse("OUTPUT_LIMIT")
                        if key.fileobj is proc.stdout:
                            result.extend(block)
            code = proc.wait(timeout=max(0.01, deadline - time.monotonic()))
            if code < 0:
                if budget and args[:2] == ["docker", "run"]:
                    budget.uncertain = True
                refuse("PREPARATION_FAILED")
            interrupted = False
            if code:
                refuse("PREPARATION_FAILED")
            return result.decode("utf-8")
        except Refusal:
            raise
        except (OSError, ValueError, UnicodeError, subprocess.SubprocessError) as error:
            refuse("TIMEOUT" if isinstance(error, (TimeoutError, subprocess.TimeoutExpired)) else "PREPARATION_FAILED")
        finally:
            if proc is not None:
                if interrupted:
                    if budget and args[:2] in (["docker", "pull"], ["docker", "build"]):
                        budget.uncertain = True
                    try:
                        os.killpg(proc.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        pass
                    # The CLI leader can exit before a plugin/descendant. Always
                    # terminate the group, not just a still-running leader.
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        if budget:
                            budget.uncertain = True
                        refuse("RECOVERY_REQUIRED")
                proc.stdout.close()
                proc.stderr.close()


def sandbox(arguments):
    name = "silo-rr-" + secrets.token_hex(16)
    budget = _BUDGET.get()
    labels = ["--label=silo-migrate.review-prep=true"]
    if budget and budget.attempt:
        labels += ["--label=silo-migrate.review-attempt=" + budget.attempt]
    with tempfile.TemporaryDirectory(prefix="silo-rr-cid-") as directory:
        cid = Path(directory) / "id"
        try:
            return run(["docker", "run", "--name", name, "--cidfile", str(cid), *labels, *arguments])
        except Refusal as error:
            if error.code in ("STANDARD_REVIEW_RUNTIME_TIMEOUT", "STANDARD_REVIEW_RUNTIME_OUTPUT_LIMIT"):
                # A cidfile is written only after create has acknowledged. With
                # no acknowledged ID, absence now cannot exclude a late create.
                acknowledged = cid.is_file() and re.fullmatch(r"[0-9a-f]{64}\n?", cid.read_text())
                budget = _BUDGET.get()
                if budget and not acknowledged:
                    budget.uncertain = True
            raise
        finally:
            try:
                try:
                    run(["docker", "rm", "--force", name], timeout=10, cleanup=True)
                except Refusal:
                    # --rm may already have removed it. Prove absence rather than
                    # interpreting private daemon error text or assuming success.
                    pass
                left = run(["docker", "container", "ls", "--all", "--quiet", "--filter", "name=^/" + name + "$"],
                           timeout=10, cleanup=True)
                if left.strip():
                    refuse("CLEANUP_FAILED")
            except Refusal:
                budget = _BUDGET.get()
                if budget:
                    budget.uncertain = True
                refuse("RECOVERY_REQUIRED")


def inspect(ref):
    docs = json.loads(run(["docker", "image", "inspect", ref]))
    if not isinstance(docs, list) or len(docs) != 1 or not DIGEST.fullmatch(docs[0].get("Id", "")):
        refuse("METADATA_INVALID")
    identity(docs[0])
    return docs[0]


# No Rails boot, database, plugins, mounts or network. Stock images retain the
# actual core revision via git-utils overrides even when .git has been removed.
PROBE = r'''
require "json"
require "digest"
require "bundler"
Dir.chdir("/var/www/discourse")
require_relative "lib/version"
overrides = JSON.parse(File.read("config/git-utils-overrides.json"))
revision = overrides["commit_hash"] || overrides["git_version"] || overrides["revision"]
abort "revision unavailable" unless revision.is_a?(String) && revision.match?(/\A[0-9a-f]{40}\z/)
lock = File.read("Gemfile.lock")
bundler = lock[/BUNDLED WITH\s+([0-9.]+)/, 1]
migrations = Dir.glob("db/{migrate,post_migrate}/*.rb").map { |p| File.basename(p)[/\A[0-9]{14}(?=_)/] }.compact.uniq.sort
# Only report explicit upstream minimum constants, not guessed server versions.
pg = ["lib/version.rb", "lib/discourse.rb", "config/initializers/001-ensure-pg-schema.rb"].filter_map do |p|
  next unless File.file?(p)
  File.read(p)[/(?:MINIMUM_PG_VERSION|MINIMUM_POSTGRES_VERSION)\s*=\s*["']?(\d+)/, 1]
end.first
puts JSON.generate(version: Discourse::VERSION::STRING, revision: revision,
  ruby: RUBY_VERSION, bundler: bundler, gemfile_lock_sha256: Digest::SHA256.hexdigest(lock),
  core_migrations: migrations, postgres_major: pg)
'''


def probe(image):
    data = json.loads(sandbox(["--rm", "--pull=never", "--network=none", "--read-only",
                          "--cap-drop=ALL", "--security-opt=no-new-privileges", "--pids-limit=64",
                          "--memory=512m", "--cpus=1", "--user=discourse", "--workdir=/var/www/discourse",
                          "--entrypoint=ruby", image, "-e", PROBE]))
    parse_version(data["version"])
    if (not re.fullmatch(r"[0-9a-f]{40}", data.get("revision", "")) or
        not re.fullmatch(r"[0-9a-f]{64}", data.get("gemfile_lock_sha256", "")) or
        any(not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", data.get(k, "")) for k in ("ruby", "bundler")) or
        not isinstance(data.get("core_migrations"), list) or not data["core_migrations"] or
        len(data["core_migrations"]) > 20000 or
        any(not isinstance(v, str) or not re.fullmatch(r"[0-9]{14}", v) for v in data["core_migrations"]) or
        (data.get("postgres_major") is not None and not re.fullmatch(r"[0-9]{1,3}", str(data["postgres_major"])))):
        refuse("METADATA_INVALID")
    return data


def safe_directory(path):
    path = Path(os.path.abspath(path))
    for part in reversed([path, *path.parents]):
        if part.is_symlink():
            refuse("CACHE_INVALID")
        if not part.exists():
            part.mkdir(mode=0o700)
        if not part.is_dir():
            refuse("CACHE_INVALID")
    info = path.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        refuse("CACHE_INVALID")
    return path


def read_regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as handle:
        import stat
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            refuse("CACHE_INVALID")
        raw = handle.read(MAX_OUTPUT + 1)
        if len(raw) > MAX_OUTPUT:
            refuse("CACHE_INVALID")
        return raw


def publish(directory, name, raw):
    target = directory / (name + ".json")
    if target.exists() or target.is_symlink():
        if read_regular(target) != raw:
            refuse("CACHE_INVALID")
        return
    fd, temp = tempfile.mkstemp(prefix=".profile-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        # link is atomic and never overwrites an existing path (including symlinks).
        os.link(temp, target)
        dfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        os.unlink(temp)


def prepare(repo: Path, cache: Path, baseline: dict, version: str | None, schema: str | None,
            required_migrations=None, deadline=None, attempt=None):
    """Return public profile plus a private request comparison. One monotonic
    deadline covers lock acquisition, all commands and reserved cleanup."""
    if attempt is not None and (not isinstance(attempt, str) or not re.fullmatch(r"[0-9a-f]{32}", attempt)):
        refuse("CACHE_INVALID")
    budget = Budget(deadline if deadline is not None else time.monotonic() + TOTAL_SECONDS)
    budget.attempt = attempt
    token = _BUDGET.set(budget)
    try:
        return _prepare(repo, cache, baseline, version, schema, required_migrations)
    except Refusal:
        if budget.uncertain:
            refuse("RECOVERY_REQUIRED")
        raise
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError):
        if budget.uncertain:
            refuse("RECOVERY_REQUIRED")
        refuse("PREPARATION_FAILED")
    finally:
        _BUDGET.reset(token)


def current_version_tag(requested):
    """Enumerate at most 500 public names; never follow a server-supplied URL.

    Refuse an incomplete listing rather than pretending that an observed tag is
    the newest on the requested track. No registry login, arbitrary repository or private API.
    """
    candidates = []
    for page in range(1, 6):
        url = ("https://hub.docker.com/v2/repositories/discourse/discourse/tags"
               "?page_size=100&page=" + str(page))
        document = json.loads(run(["curl", "-q", "--proto", "=https", "--tlsv1.2", "--fail",
            "--silent", "--show-error", "--max-time", "20", "--max-filesize", str(MAX_OUTPUT), url], timeout=25))
        if not isinstance(document, dict) or not isinstance(document.get("results"), list):
            refuse("VERSION_UNAVAILABLE")
        if len(document["results"]) > 100:
            refuse("VERSION_UNAVAILABLE")
        for entry in document["results"]:
            tag = entry.get("name") if isinstance(entry, dict) else None
            if isinstance(tag, str) and _VERSIONS.parse(tag) is not None:
                parsed = parse_version(tag)
                if parsed[0] == requested[0] and parsed[1] >= requested[1]:
                    candidates.append((parsed[1], tag))
        if not document.get("next"):
            if not candidates:
                refuse("VERSION_UNAVAILABLE")
            return max(candidates)[1]
    refuse("VERSION_UNAVAILABLE")


def resolve_candidate(tag, requested):
    ref = PUBLIC + ":" + tag
    # Always refresh even an exact version: upstream may rebuild that tag.
    run(["docker", "pull", ref], timeout=600)
    stock = inspect(ref)
    if stock["Config"].get("Volumes"):
        # Docker would otherwise create anonymous data volumes implicitly.
        refuse("METADATA_INVALID")
    digests = []
    for digest in stock.get("RepoDigests", []):
        if not isinstance(digest, str) or "@" not in digest:
            continue
        repository, value = digest.split("@", 1)
        # Docker inspect commonly omits docker.io in canonical RepoDigests.
        if repository in (PUBLIC, "discourse/discourse") and DIGEST.fullmatch(value):
            digests.append(PUBLIC + "@" + value)
    if len(set(digests)) != 1:
        refuse("METADATA_INVALID")
    metadata = probe(stock["Id"])
    actual = parse_version(metadata["version"])
    if requested and (actual[0] != requested[0] or actual[1] < requested[1]):
        refuse("VERSION_UNAVAILABLE")
    if not requested and actual[0] != "latest":
        refuse("VERSION_UNAVAILABLE")
    return (ref, digests[0], stock, metadata, actual)


def select_candidate(version, requested, required_migrations):
    if requested is None:
        return resolve_candidate("latest", None), False, set(), set()
    exact = None
    exact_error = None
    try:
        exact = resolve_candidate(version, requested)
    except Refusal as error:
        budget = _BUDGET.get()
        if budget and budget.uncertain:
            raise
        if error.code not in ("STANDARD_REVIEW_RUNTIME_VERSION_UNAVAILABLE", "STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED"):
            raise
        exact_error = error
    alternate = None
    comparison_complete = False
    try:
        tag = "latest" if requested[0] == "latest" else current_version_tag(requested)
        alternate = exact if tag == version and exact is not None else resolve_candidate(tag, requested)
        if exact is not None and alternate[4][1] < exact[4][1]:
            alternate = None
            refuse("VERSION_UNAVAILABLE")
        comparison_complete = exact is not None and required_migrations is not None
    except Refusal as error:
        budget = _BUDGET.get()
        if budget and budget.uncertain:
            raise
        if error.code not in ("STANDARD_REVIEW_RUNTIME_VERSION_UNAVAILABLE", "STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED"):
            raise
        # A usable exact runtime remains useful when current availability fails;
        # integrity/provenance failures are never downgraded to this warning.
        # MUST NOT become a claim that its core matches this backup.
        if exact is None:
            if exact_error and exact_error.code != "STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED":
                raise exact_error
            refuse("VERSION_UNAVAILABLE")
    candidates = [candidate for candidate in (exact, alternate) if candidate is not None]
    union = set().union(*(set(candidate[3]["core_migrations"]) for candidate in candidates))
    required = set(required_migrations or [])
    known = required & union
    # Exact wins ties and always wins when it covers all known backup core IDs.
    # Unknown (e.g. plugin) IDs do not enter the score or force an upgrade.
    chosen = max(candidates, key=lambda candidate: len(known & set(candidate[3]["core_migrations"])))
    return chosen, comparison_complete, known, required - union


def _prepare(repo, cache, baseline, version, schema, required_migrations):
    if version is not None:
        parsed = _VERSIONS.parse(version)
        if parsed is None:
            refuse("VERSION_INVALID")
        version = parsed["canonical"]
    requested = parse_version(version) if version is not None else None
    if schema is not None and (not isinstance(schema, str) or not re.fullmatch(r"[0-9]{1,20}", schema)):
        refuse("SCHEMA_INVALID")
    if required_migrations is not None and (
        not isinstance(required_migrations, list) or len(required_migrations) > 20000 or
        any(not isinstance(item, str) or not re.fullmatch(r"[0-9]{14}", item) for item in required_migrations)
    ):
        refuse("SCHEMA_INVALID")
    recipe_path = repo / RECIPE
    if recipe_path.is_symlink() or not recipe_path.resolve().is_relative_to(repo.resolve()):
        refuse("RECIPE_INVALID")
    absolute_cache = Path(os.path.abspath(cache))
    if any(absolute_cache == repo.resolve() / area or
           (repo.resolve() / area) in absolute_cache.parents for area in ("runtime", "config", "bin", "test")):
        refuse("CACHE_INVALID")
    recipe = read_regular(recipe_path)
    recipe_hash = sha(recipe)
    cache = safe_directory(cache)
    profiles = safe_directory(cache / "profiles")
    lockfd = os.open(cache / ".prepare.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(lockfd, "r+") as lock:
        import stat
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            refuse("CACHE_INVALID")
        budget = _BUDGET.get()
        acquire_lock(lock, budget)
        with preparation_lease(cache, budget):
            return prepare_locked(cache, baseline, version, schema, required_migrations, requested, profiles, recipe, recipe_hash)


def prepare_locked(cache, baseline, version, schema, required_migrations, requested, profiles, recipe, recipe_hash):
    minimum = (max(8, int(baseline.get("limits", {}).get("host_free_min_gib", 8))) + 6) * 1024**3
    if shutil.disk_usage(cache).free < minimum:
        refuse("CAPACITY")
    selected, comparison_complete, known_required, unknown_required = select_candidate(
        version, requested, required_migrations)
    ref, stock_ref, stock, metadata, actual = selected
    pg = metadata.get("postgres_major")
    if pg is not None and int(pg) > int(baseline["app"]["postgres_major"]):
        refuse("POSTGRES_INCOMPATIBLE")
    key = sha(encoded({"source": stock_ref, "id": stock["Id"], "recipe": recipe_hash,
                       "lock": metadata["gemfile_lock_sha256"]}))
    overlay_ref = "silo-migrate/review-runtime:" + key
    # A locally named tag alone is not evidence that we built this recipe.
    # Accept reuse only if an immutable, content-addressed cache record attests
    # the current image identity. Still recheck metadata and frozen bundle below.
    attested = False
    try:
        overlay = inspect(overlay_ref)
        for candidate in profiles.glob("review-*.json"):
            raw = read_regular(candidate)
            if candidate.name != "review-" + sha(raw) + ".json":
                refuse("CACHE_INVALID")
            prior = json.loads(raw)
            if (prior.get("preparation", {}).get("key") == key and
                prior.get("images", {}).get("web", {}).get("ref") == overlay_ref and
                prior["images"]["web"].get("local_id") == overlay["Id"] and
                prior["images"]["web"].get("content_id") == identity(overlay)):
                attested = True
    except Refusal as error:
        if error.code != "STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED":
            raise
    if not attested:
        if shutil.disk_usage(cache).free < minimum:
            refuse("CAPACITY")
        # Tar context contains ONLY the fixed recipe; never send the repo,
        # backup, credentials or local Docker configuration to the builder.
        import io
        import tarfile
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            item = tarfile.TarInfo("Dockerfile")
            item.size = len(recipe)
            item.mode = 0o644
            archive.addfile(item, io.BytesIO(recipe))
        run(["docker", "build", "--pull=false", "--memory=2g", "--memory-swap=2g", "--cpu-period=100000", "--cpu-quota=200000", "--tag", overlay_ref,
             "--build-arg", "STOCK_IMAGE=" + stock_ref,
             "--build-arg", "EXPECTED_LOCK_SHA256=" + metadata["gemfile_lock_sha256"],
             "-"], timeout=1800, input_bytes=stream.getvalue())
        overlay = inspect(overlay_ref)
    if probe(overlay["Id"]) != metadata:
        refuse("METADATA_INVALID")
    sandbox(["--rm", "--pull=never", "--network=none", "--read-only",
         "--cap-drop=ALL", "--security-opt=no-new-privileges", "--memory=512m", "--cpus=1",
         "--pids-limit=64", "--user=discourse", "--workdir=/var/www/discourse",
         "--env=BUNDLE_FROZEN=true", "--env=BUNDLE_WITH=generic_import", "--entrypoint=bundle",
         overlay["Id"], "check"])
    profile = copy.deepcopy(baseline)
    profile["images"]["web"] = {"ref": overlay_ref, "content_id": identity(overlay),
        "source": "package", "derived_from": stock_ref, "dockerfile_sha256": recipe_hash,
        "local_id": overlay["Id"]}
    app = copy.deepcopy(baseline["app"])
    app.update({k: metadata[k] for k in ("version", "revision", "ruby", "bundler", "gemfile_lock_sha256")})
    app.update(track=actual[0], core_migrations=metadata["core_migrations"], schema=max(metadata["core_migrations"]))
    # postgres_major describes the actual preserved DB image, not the
    # application's minimum requirement (already checked against it above).
    profile["app"] = app
    # Replace stale baseline selector metadata; other roles/limits stay intact.
    profile["selector"] = {"channel": actual[0],
        "release": ".".join(map(str, actual[1][:3])), "stock_index_digest": stock_ref.split("@", 1)[1]}
    profile["review_runtime"] = {"core_migrations": metadata["core_migrations"],
        "schema_version": max(metadata["core_migrations"]),
        "track": actual[0], "postgres_requirement_known": pg is not None,
        "postgres_minimum_major": str(pg) if pg is not None else None,
        "source": {"ref": ref, "digest": stock_ref.split("@", 1)[1],
                   "local_id": stock["Id"], "content_id": identity(stock)},
        "preparation_method": "public-stock-generic-import-v1", "recipe_sha256": recipe_hash}
    profile["qualification"] = {"status": "review_ready", "scope": ["review", "merge"],
        "full_stack_qualified": False}
    profile["preparation"] = {"method": "public-stock-generic-import-v1", "recipe_sha256": recipe_hash,
        "key": key, "source": {"ref": ref, "digest": stock_ref.split("@", 1)[1],
        "local_id": stock["Id"], "content_id": identity(stock)},
        "track": actual[0], "core_migrations": metadata["core_migrations"],
        "schema_commit_exact": False}
    raw = encoded(profile) + b"\n"
    name = "review-" + sha(raw)
    publish(profiles, name, raw)
    # Per-request comparison is private to this workspace, never part of
    # the globally shared, image-derived profile or its identity.
    comparison = {"core_comparison_complete": comparison_complete,
                  "required_migrations_supplied": required_migrations is not None,
                  "known_required_core_migrations": len(known_required),
                  "missing_known_core_migrations": len(known_required - set(metadata["core_migrations"])),
                  "unknown_required_migrations_count": len(unknown_required),
                  "requested_schema": schema}
    return {"name": name, "sha256": sha(raw), "profile": profile, "comparison": comparison}
