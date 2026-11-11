#!/usr/bin/env python3
"""On-demand, bounded public-runtime preparation; no scheduler and no customer mounts.

A proposal may outlive a chat's 300-second tool budget. It starts one fixed worker,
returns `runtime_preparing`, and subsequent proposals poll the same request.
Customer-derived inventories and comparisons remain in workspace-private records;
only public profiles/images may enter the shared image cache.
"""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

MAX_BYTES = 1024 * 1024
FRESH_SECONDS = 900
WORK_SECONDS = 1200
STARTUP_SECONDS = 5
CODE = re.compile(r"STANDARD_REVIEW_RUNTIME_[A-Z_]+\Z")
NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\Z")


def fail(code="STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED"):
    raise ValueError(code)


def encoded(body):
    return json.dumps(body, sort_keys=True, separators=(",", ":")).encode()


def directory(path, *, private=False):
    if ".." in path.parts:
        fail()
    path = path.absolute()
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            pass
        if current.is_symlink() or not current.is_dir():
            fail()
    if path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o022:
        fail()
    if private and stat.S_IMODE(path.stat().st_mode) != 0o700:
        fail()
    return path


def private_directory(path):
    # No fallback to the shared cache. Jobs are direct children of this directory.
    if path.parts[-3:] != (".silo-migrate", "data", "review-runtime-jobs"):
        fail()
    return directory(path, private=True)


def open_path(path, flags, mode=0o600):
    # Resolve every parent relative to an already-open descriptor. A rename or
    # symlink swap cannot redirect a later open outside that descriptor chain.
    if ".." in path.parts:
        fail()
    path = path.absolute()
    parent = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in path.parts[1:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=parent)
            os.close(parent)
            parent = child
        return os.open(path.name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, mode, dir_fd=parent)
    finally:
        os.close(parent)


def lifetime_lock(target):
    fd = open_path(target.with_suffix(".live"), os.O_RDWR | os.O_CREAT)
    info = os.fstat(fd)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
            stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        os.close(fd)
        fail()
    return fd


def read(path):
    fd = open_path(path, os.O_RDONLY)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_size > MAX_BYTES or
                info.st_uid != os.getuid() or info.st_mode & 0o022 or info.st_nlink != 1):
            fail()
        return json.load(stream)


def write(path, body):
    raw = encoded(body)
    if len(raw) > MAX_BYTES:
        fail()
    temporary = path.with_name(path.name + ".tmp-" + os.urandom(8).hex())
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        temporary.unlink(missing_ok=True)


def request(*, repo, cache, private_dir, baseline, version=None, schema=None, required_migrations=None):
    # Recipe changes create a different request. Inventories stay in the private
    # record; the fixed worker receives only its opaque record path.
    cache = directory(cache)
    jobs = private_directory(private_dir)
    recipes = [repo / "bin/review_runtime.py", repo / "bin/discourse_version.py",
               repo / "runtime/prebuilt-discourse/review-runtime.Dockerfile"]
    inputs = {"baseline": baseline, "version": version, "schema": schema, "required_migrations": required_migrations,
              "recipes": [hashlib.sha256(path.read_bytes()).hexdigest() for path in recipes]}
    key = hashlib.sha256(encoded(inputs)).hexdigest()
    lock = os.open(jobs / ".request.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(lock)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            fail()
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        target = jobs / (key + ".json")
        previous = read(target) if target.exists() or target.is_symlink() else None
        if previous:
            if previous.get("cache") != str(cache):
                fail()
            age = time.time() - previous["created_at"]
            if previous["status"] == "preparing":
                if age >= STARTUP_SECONDS:
                    live = lifetime_lock(target)
                    try:
                        try:
                            fcntl.flock(live, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            if age > WORK_SECONDS + 60:
                                fail("STANDARD_REVIEW_RUNTIME_TIMEOUT")
                            return {"status": "runtime_preparing"}
                        # Keep the lease while failing the record, so a queued
                        # worker cannot read pending state and start effects.
                        try:
                            marker = read(cache / ".inflight.json")
                        except FileNotFoundError:
                            marker = {}
                        code = ("STANDARD_REVIEW_RUNTIME_RECOVERY_REQUIRED"
                                if marker.get("attempt") == previous["attempt"]
                                else "STANDARD_REVIEW_RUNTIME_TIMEOUT")
                        write(target, dict(previous, status="failed", created_at=time.time(), error=code))
                        fail(code)
                    finally:
                        os.close(live)
                return {"status": "runtime_preparing"}
            if previous["status"] == "ready" and time.time() - previous.get("finished_at", previous["created_at"]) < FRESH_SECONDS:
                result = previous["result"]
                if not NAME.fullmatch(result.get("name", "")) or not re.fullmatch(r"[0-9a-f]{64}", result.get("sha256", "")):
                    fail()
                if not isinstance(result.get("comparison"), dict):
                    fail()
                profile = directory(cache / "profiles") / (result["name"] + ".json")
                fd = open_path(profile, os.O_RDONLY)
                with os.fdopen(fd, "rb") as stream:
                    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode) or hashlib.sha256(stream.read(MAX_BYTES + 1)).hexdigest() != result["sha256"]:
                        fail()
                return dict(result, status="ready")
            if previous["status"] == "failed" and (age < 30 or previous.get("error") == "STANDARD_REVIEW_RUNTIME_RECOVERY_REQUIRED"):
                fail(previous["error"] if CODE.fullmatch(previous.get("error", "")) else "STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED")
        record = {"status": "preparing", "created_at": time.time(), "attempt": os.urandom(16).hex(), "inputs": inputs, "cache": str(cache)}
        write(target, record)
        try:
            subprocess.Popen([sys.executable, "-I", "-B", str(Path(__file__).resolve()), str(target)],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             close_fds=True, start_new_session=True,
                             env={"PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8"})
        except OSError:
            write(target, dict(record, status="failed", error="STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED"))
            fail()
        return {"status": "runtime_preparing"}
    except BlockingIOError:
        return {"status": "runtime_preparing"}
    finally:
        os.close(lock)


def finish(target, record, **updates):
    # An expired/interrupted attempt must not overwrite a newer request after
    # it eventually returns. Only this attempt's still-pending state can finish.
    fd = os.open(target.parent / ".request.lock", os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        # Cleanup has its own small grace budget, never an asynchronous alarm
        # that could interrupt a successful ready publication.
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError()
                time.sleep(min(0.05, remaining))
        current = read(target)
        if current.get("attempt") == record.get("attempt") and current.get("status") == "preparing":
            write(target, dict(record, **updates))
    finally:
        os.close(fd)


def worker(target):
    deadline = time.monotonic() + WORK_SECONDS
    if not target.is_absolute() or not re.fullmatch(r"[0-9a-f]{64}\.json", target.name):
        fail()
    private_directory(target.parent)
    live = lifetime_lock(target)
    try:
        fcntl.flock(live, fcntl.LOCK_EX | fcntl.LOCK_NB)
        record = read(target)
        if (record["status"] != "preparing" or
                not re.fullmatch(r"[0-9a-f]{32}", record.get("attempt", ""))):
            fail()
        cache_path = Path(record["cache"])
        if not cache_path.is_absolute():
            fail()
        cache = directory(cache_path)
        inputs = record["inputs"]
        if hashlib.sha256(encoded(inputs)).hexdigest() + ".json" != target.name:
            fail()
        repo = Path(__file__).resolve().parent.parent
        paths = [repo / "bin/review_runtime.py", repo / "bin/discourse_version.py",
                   repo / "runtime/prebuilt-discourse/review-runtime.Dockerfile"]
        if inputs["recipes"] != [hashlib.sha256(path.read_bytes()).hexdigest() for path in paths]:
            fail()
        try:
            spec = importlib.util.spec_from_file_location("review_runtime", paths[0])
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            result = module.prepare(repo=repo, cache=cache, baseline=inputs["baseline"],
                                    version=inputs["version"], schema=inputs["schema"], required_migrations=inputs["required_migrations"],
                                    deadline=deadline, attempt=record["attempt"])
            finish(target, record, status="ready", finished_at=time.time(), result={key: result[key] for key in ("name", "sha256", "comparison")})
        except Exception as error:
            code = "STANDARD_REVIEW_RUNTIME_TIMEOUT" if isinstance(error, TimeoutError) else str(error)
            finish(target, record, status="failed", created_at=time.time(), error=code if CODE.fullmatch(code) else "STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED")
    finally:
        os.close(live)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            fail()
        worker(Path(sys.argv[1]))
    except Exception:
        sys.exit(1)
