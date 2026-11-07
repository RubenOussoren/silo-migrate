"""migration-data host operations: intake, sandboxed jobs, the project's source database.

Reached only through `silo-migrate-control data WS` (JSON request on stdin) from the
Frontier-only migration-data agent's fixed tools. This is the one place customer data is
handled by an agent, so every operation is confined to:

  intake   <prefix>/intake/WS          the drop folder (read; files are moved out, never edited)
  inputs   <prefix>/workspaces/WS/inputs  registered inputs (read-only 0400 once registered)
  work     <prefix>/workspaces/WS/work    sandbox output folders (one writable folder per job)

Paths are opened one component at a time without following symlinks. Scripts and archive
extraction run in the control image with no network, a read-only root, inputs read-only and
one writable output folder, CPU/memory/pids/time limits. The source database runs on an
internal Docker network (no egress) with a read-only user for later query access. Every
operation is appended to the workspace's audit log; moved and derived files get a
provenance record (checksums, script hash, job). Output stays under the tool limit.
"""
import base64
import bz2
import fcntl
import gzip
import hashlib
import json
import lzma
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import tarfile
import time
import zipfile

WORKSPACE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\Z")
WORK_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,47}\Z")
SAFE_NAME = re.compile(r"[A-Za-z0-9._-]{1,128}\Z")
TYPE = re.compile(r"[a-z][a-z0-9_-]{0,31}\Z")
PLATFORM = re.compile(r"[a-z][a-z0-9_.-]{0,31}\Z")
JOB = re.compile(r"job-[0-9a-f]{12}\Z")
RUN = re.compile(r"run-[0-9a-f]{32}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
CONVERTER_REPO = "https://github.com/discourse-org/discourse-converters.git"
AREAS = ("intake", "inputs", "work", "converter")
OUTPUT_LIMIT = 46 * 1024
MAX_LIST = 400
MAX_PEEK = 32 * 1024
MAX_MATCHES = 100
MAX_LINE = 300
SCAN_SECONDS = 40
MAX_SCRIPT = 256 * 1024
MAX_FINDING = 256 * 1024
LOG_TAIL = 16 * 1024
JOB_DEFAULT_MINUTES = 30
JOB_MAX_MINUTES = 360
SANDBOX = {"cpus": "2", "memory": "4g", "pids": "256", "tmp": "1g"}
DB_LIMITS = {"cpus": "2", "memory": "4g", "pids": "512"}
CHARSETS = ("utf8mb4", "utf8mb3", "utf8", "latin1", "binary")
ENGINES = {"mariadb": "source_db", "postgres": "db"}
RO_USER = "silo_ro"
SYSTEM_DATABASES = "mysql|information_schema|performance_schema|sys"


class Refusal(ValueError):
    pass


def refuse(code):
    raise Refusal(code)


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# -- confined paths ------------------------------------------------------------------

def parts_of(raw, allow_empty=False):
    """A relative path as components: no absolute paths, '.', '..', NUL or control characters."""
    if raw in (None, "") and allow_empty:
        return []
    if not isinstance(raw, str) or not raw or len(raw.encode("utf-8")) > 1024 or raw.startswith("/"):
        refuse("STANDARD_PATH_INVALID")
    parts = [part for part in raw.split("/") if part != ""]
    if not parts or any(part in (".", "..") or len(part.encode("utf-8")) > 255 or any(ord(c) < 32 or c == "\x7f" for c in part) for part in parts):
        refuse("STANDARD_PATH_INVALID")
    return parts


DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def open_root(path):
    """Open an area root; the root itself must be a real directory owned by this account."""
    try:
        fd = os.open(path, DIR_FLAGS)
    except FileNotFoundError:
        refuse("STANDARD_AREA_MISSING")
    except OSError:
        refuse("STANDARD_PATH_INVALID")
    if os.fstat(fd).st_uid != os.getuid():
        os.close(fd)
        refuse("STANDARD_PATH_INVALID")
    return fd


def walk_dirs(root_fd, parts):
    """Descend through directories by descriptor, never following a symlink. Caller closes."""
    fd = os.dup(root_fd)
    for part in parts:
        try:
            nxt = os.open(part, DIR_FLAGS, dir_fd=fd)
        except FileNotFoundError:
            os.close(fd)
            refuse("STANDARD_PATH_MISSING")
        except OSError:
            os.close(fd)
            refuse("STANDARD_PATH_INVALID")
        os.close(fd)
        fd = nxt
    return fd


def open_regular(root_fd, parts):
    """(fd, stat) of a regular file below root_fd; symlinks anywhere are refused."""
    parent = walk_dirs(root_fd, parts[:-1])
    try:
        try:
            fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
        except FileNotFoundError:
            refuse("STANDARD_PATH_MISSING")
        except OSError:
            refuse("STANDARD_PATH_INVALID")
    finally:
        os.close(parent)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        os.close(fd)
        refuse("STANDARD_PATH_NOT_FILE")
    return fd, info


def sha256_fd(fd):
    digest = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    return digest.hexdigest()


# -- type sniffing ---------------------------------------------------------------------

def sniff(head):
    """Best guess at a file's kind from its first bytes. A hint, not validation."""
    if head.startswith(b"\x1f\x8b"):
        return "gzip"
    if head.startswith(b"BZh"):
        return "bzip2"
    if head.startswith(b"\xfd7zXZ\x00"):
        return "xz"
    if head.startswith(b"\x28\xb5\x2f\xfd"):
        return "zstd"
    if head.startswith(b"PK\x03\x04") or head.startswith(b"PK\x05\x06"):
        return "zip"
    if head.startswith(b"7z\xbc\xaf\x27\x1c"):
        return "7z"
    if len(head) > 262 and head[257:262] == b"ustar":
        return "tar"
    if head.startswith(b"PGDMP"):
        return "postgres-custom-dump"
    if head.startswith(b"SQLite format 3\x00"):
        return "sqlite"
    text = head.lstrip(b"\xef\xbb\xbf \t\r\n")
    lowered = text[:4096].lower()
    if lowered.startswith(b"-- mysql dump") or lowered.startswith(b"-- mariadb dump") or b"mysqldump" in lowered[:400]:
        return "mysql-dump"
    if b"postgresql database dump" in lowered[:400]:
        return "postgres-dump"
    if re.match(rb"(--[^\n]*\n|/\*.*?\*/;?\s*|set |create |insert |drop |use |begin|start transaction)", lowered, re.S):
        return "sql"
    if lowered.startswith(b"<?xml") or lowered.startswith(b"<"):
        return "xml"
    if lowered[:1] in (b"{", b"["):
        return "json"
    if b"\x00" in head[:4096]:
        return "binary"
    first = text.split(b"\n", 1)[0]
    if first.count(b",") >= 2 or first.count(b"\t") >= 2 or first.count(b";") >= 2:
        return "csv-like"
    return "text"


DECOMPRESSORS = {"gzip": gzip.GzipFile, "bzip2": bz2.BZ2File, "xz": lzma.LZMAFile}


def reader(fd, decompress=True):
    """A binary stream over the file, decompressed when it is gzip/bzip2/xz (and decompress)."""
    os.lseek(fd, 0, os.SEEK_SET)
    raw = os.fdopen(os.dup(fd), "rb")
    kind = sniff(raw.read(512))
    raw.seek(0)
    if decompress and kind in DECOMPRESSORS:
        return DECOMPRESSORS[kind](fileobj=raw, mode="rb") if kind == "gzip" else DECOMPRESSORS[kind](raw), kind
    return raw, None


def describe(fd):
    """kind, plus the inner kind of a compressed file."""
    stream, compressed = reader(fd)
    try:
        head = stream.read(64 * 1024)
    except (OSError, EOFError, lzma.LZMAError):
        return {"kind": compressed or "unknown", "inner": "unreadable"}
    finally:
        stream.close()
    return {"kind": compressed, "inner": sniff(head)} if compressed else {"kind": sniff(head)}


def text_of(data):
    return data.decode("utf-8", "replace")


# -- the workspace ---------------------------------------------------------------------

class Workspace:
    def __init__(self, base, name, repo, host, values, control):
        if not isinstance(name, str) or not WORKSPACE.fullmatch(name):
            refuse("STANDARD_ARGUMENTS_INVALID")
        self.name = name
        self.base = Path(base)
        self.root = self.base / name
        self.intake = self.base.parent / "intake" / name
        self.repo = Path(repo)
        self.host = host
        self.values = values
        self.control = control
        self.data = self.root / ".silo-migrate" / "data"

    # state -------------------------------------------------------------------
    def initialized(self):
        return not self.root.is_symlink() and (self.root / ".silo-migrate/named/state.json").is_file()

    def require(self, standard=True):
        if not self.initialized():
            refuse("STANDARD_NOT_INITIALIZED")
        if standard and not (self.root / ".silo-migrate/named/standard/state.json").is_file():
            refuse("STANDARD_NOT_INITIALIZED")

    def data_dir(self, *parts):
        path = self.data.joinpath(*parts)
        for directory in [self.data, *[self.data.joinpath(*parts[:i + 1]) for i in range(len(parts))]]:
            if directory.is_symlink():
                refuse("STANDARD_PATH_INVALID")
            directory.mkdir(mode=0o700, exist_ok=True)
        return path

    def read_json(self, path, default=None):
        try:
            with open(path, "rb") as handle:
                return json.load(handle)
        except FileNotFoundError:
            return default

    def write_json(self, path, record):
        temporary = Path(str(path) + ".tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(record, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)

    def append(self, name, record):
        directory = self.data_dir()
        fd = os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "a") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")

    def meta(self):
        return self.read_json(self.data / "workspace.json", {}) if self.data.is_dir() else {}

    def named_state(self):
        return json.loads((self.root / ".silo-migrate/named/state.json").read_text())

    def standard_config(self):
        return json.loads((self.root / ".silo-migrate/named/standard/state.json").read_text())["config"]

    # areas -------------------------------------------------------------------
    def area_path(self, area):
        if area == "intake":
            return self.intake
        if area not in ("inputs", "work", "converter"):
            refuse("STANDARD_ARGUMENTS_INVALID")
        self.require(standard=False)
        return self.root / area

    def open_area(self, area):
        return open_root(str(self.area_path(area)))

    def lock(self):
        return Locked(self.data_dir() / "lock")

    # images ------------------------------------------------------------------
    def image(self, key):
        """A runtime-profile image (control/source_db/db), verified by content ID like the converter image."""
        config = self.standard_config()
        name = config["discourse_profile"]
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}", name):
            refuse("STANDARD_RUNTIME_MISMATCH")
        directories = {self.repo / "runtime/profiles", Path(self.values.get("SILO_RUNTIME_PROFILES_DIR", str(self.repo / "runtime/profiles")))}
        paths = list({candidate.resolve() for directory in directories if (candidate := directory / (name + ".json")).is_file()})
        if len(paths) != 1:
            refuse("STANDARD_RUNTIME_MISMATCH")
        raw = paths[0].read_bytes()
        if hashlib.sha256(raw).hexdigest() != config["discourse_profile_sha256"]:
            refuse("STANDARD_RUNTIME_MISMATCH")
        image = json.loads(raw)["images"][key]
        try:
            document = self.host.inspect(image["ref"])
        except ValueError:
            document = self.host.inspect("silo-migrate/loaded:" + image["content_id"][7:])
        if self.host.identity(document) != image["content_id"] or not re.fullmatch(r"sha256:[0-9a-f]{64}", document.get("Id", "")):
            refuse("STANDARD_RUNTIME_MISMATCH")
        return document["Id"]


class Locked:
    def __init__(self, path):
        self.path = path

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.fd)
            refuse("STANDARD_BUSY")
        return self

    def __exit__(self, *exc):
        os.close(self.fd)


def docker(argv, timeout=120, input=None):
    try:
        result = subprocess.run(["docker", *argv], input=input, capture_output=True, timeout=timeout, stdin=None if input is not None else subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        refuse("STANDARD_OPERATION_TIMEOUT")
    return result


def docker_ok(argv, timeout=120, input=None):
    result = docker(argv, timeout, input)
    if result.returncode:
        refuse("STANDARD_DOCKER_FAILED")
    return result.stdout.decode("utf-8", "replace")


def tail_text(data, limit=LOG_TAIL):
    return text_of(data[-limit:]), len(data) > limit


# -- read operations -------------------------------------------------------------------

def op_status(ws, request):
    result = {"workspace": ws.name, "initialized": ws.initialized(), "drop_folder": str(ws.intake)}
    if ws.intake.is_dir() and not ws.intake.is_symlink():
        count = total = 0
        for _path, _dirs, files, dirfd in os.fwalk(str(ws.intake), follow_symlinks=False):
            for name in files:
                info = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
                if stat.S_ISREG(info.st_mode):
                    count, total = count + 1, total + info.st_size
        result["drop_folder_files"], result["drop_folder_bytes"] = count, total
    else:
        result["drop_folder_files"] = None
    if not ws.initialized():
        result["next"] = "create the workspace (data_create) before taking files"
        return result
    meta = ws.meta()
    state = ws.named_state()
    inputs = []
    for record in list(state.get("inputs", {}).values())[:200]:
        try:
            path = base64.b64decode(record["path"]).decode("utf-8", "replace")
        except (ValueError, KeyError):
            path = None
        inputs.append({"input_id": record.get("id"), "path": path, "type": record.get("type"), "bytes": record.get("bytes"),
                       "sha256": record.get("sha256"), "dataset_id": record.get("dataset_id")})
    result.update(platform=meta.get("platform"), source_id=meta.get("source_id"), dataset_id=meta.get("dataset_id"),
                  converter=(ws.root / "converter").is_dir(), standard=(ws.root / ".silo-migrate/named/standard/state.json").is_file(),
                  inputs=inputs)
    work = ws.root / "work"
    result["work"] = sorted(path.name for path in work.iterdir() if path.is_dir() and not path.is_symlink())[:100] if work.is_dir() and not work.is_symlink() else []
    jobs = sorted((ws.read_json(path, {}) for path in (ws.data / "jobs").glob("job-*.json")), key=lambda job: job.get("started_at", ""))[-10:] if (ws.data / "jobs").is_dir() else []
    result["recent_jobs"] = [{key: job.get(key) for key in ("id", "kind", "status", "into", "started_at", "exit_code")} for job in jobs]
    db = ws.read_json(ws.data / "db" / "state.json", None) if (ws.data / "db").is_dir() else None
    result["source_db"] = {key: db.get(key) for key in ("engine", "created_at", "loads")} if db else None
    return result


def op_list(ws, request):
    area = request.get("area", "intake")
    if area not in AREAS:
        refuse("STANDARD_ARGUMENTS_INVALID")
    parts = parts_of(request.get("path"), allow_empty=True)
    if area == "converter" and ".git" in parts:
        refuse("STANDARD_PATH_INVALID")
    root = ws.open_area(area)
    try:
        fd = walk_dirs(root, parts)
    finally:
        os.close(root)
    entries, total = [], 0
    try:
        for name in sorted(os.listdir(fd)):
            if area == "converter" and name == ".git":
                continue
            total += 1
            if len(entries) >= MAX_LIST:
                continue
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                entries.append({"name": name, "type": "dir"})
            elif stat.S_ISREG(info.st_mode):
                entry = {"name": name, "type": "file", "bytes": info.st_size, "read_only": not info.st_mode & 0o222}
                try:
                    child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=fd)
                    try:
                        entry.update(describe(child))
                    finally:
                        os.close(child)
                except OSError:
                    entry["kind"] = "unreadable"
                entries.append(entry)
            else:
                entries.append({"name": name, "type": "symlink" if stat.S_ISLNK(info.st_mode) else "other", "note": "ignored by every tool"})
    finally:
        os.close(fd)
    return {"area": area, "path": "/".join(parts), "entries": entries, "total": total, "listed": len(entries)}


def op_peek(ws, request):
    area = request.get("area", "intake")
    if area not in AREAS:
        refuse("STANDARD_ARGUMENTS_INVALID")
    parts = parts_of(request.get("path"))
    mode = request.get("mode", "head")
    limit = request.get("bytes", 8192)
    if not isinstance(limit, int) or not 1 <= limit <= MAX_PEEK:
        refuse("STANDARD_ARGUMENTS_INVALID")
    decompress = request.get("decompress", True) is not False
    if area == "converter" and ".git" in parts:
        refuse("STANDARD_PATH_INVALID")
    root = ws.open_area(area)
    try:
        fd, info = open_regular(root, parts)
    finally:
        os.close(root)
    try:
        result = {"area": area, "path": "/".join(parts), "bytes": info.st_size, "mode": mode, **describe(fd)}
        if mode == "head":
            offset = request.get("offset", 0)
            if not isinstance(offset, int) or offset < 0:
                refuse("STANDARD_ARGUMENTS_INVALID")
            stream, compressed = reader(fd, decompress)
            try:
                skipped = 0
                while skipped < offset:
                    chunk = stream.read(min(1024 * 1024, offset - skipped))
                    if not chunk:
                        break
                    skipped += len(chunk)
                data = stream.read(limit)
            finally:
                stream.close()
            result.update(offset=offset, decompressed=bool(compressed), text=text_of(data), returned=len(data))
        elif mode == "tail":
            start = max(0, info.st_size - limit)
            os.lseek(fd, start, os.SEEK_SET)
            data = os.read(fd, limit)
            result.update(offset=start, text=text_of(data), returned=len(data),
                          note="raw bytes; for a compressed file use head or search, which decompress")
        elif mode == "search":
            result.update(search(fd, request, decompress))
        elif mode == "archive":
            result.update(archive_listing(fd))
        else:
            refuse("STANDARD_ARGUMENTS_INVALID")
    finally:
        os.close(fd)
    return result


def search(fd, request, decompress):
    pattern = request.get("pattern")
    if not isinstance(pattern, str) or not 1 <= len(pattern) <= 200:
        refuse("STANDARD_ARGUMENTS_INVALID")
    flags = re.IGNORECASE if request.get("ignore_case") else 0
    try:
        matcher = re.compile(pattern.encode("utf-8") if request.get("regex") else re.escape(pattern.encode("utf-8")), flags)
    except re.error:
        refuse("STANDARD_ARGUMENTS_INVALID")
    wanted = request.get("max_matches", 40)
    if not isinstance(wanted, int) or not 1 <= wanted <= MAX_MATCHES:
        refuse("STANDARD_ARGUMENTS_INVALID")
    stream, compressed = reader(fd, decompress)
    matches, scanned, number, complete = [], 0, 0, True
    deadline = time.monotonic() + SCAN_SECONDS
    try:
        for line in stream:
            number += 1
            # Lines can be huge (one INSERT per table); match on a bounded window per line.
            window = line[:1024 * 1024]
            found = matcher.search(window)
            if found:
                start = max(0, found.start() - 80)
                matches.append({"line": number, "offset": scanned + found.start(), "text": text_of(window[start:start + MAX_LINE])})
                if len(matches) >= wanted:
                    complete = False
                    scanned += len(line)
                    break
            scanned += len(line)
            if number % 512 == 0 and time.monotonic() > deadline:
                complete = False
                break
    except (OSError, EOFError, lzma.LZMAError):
        return {"matches": matches, "scanned_bytes": scanned, "complete": False, "error": "STANDARD_READ_FAILED"}
    finally:
        stream.close()
    return {"pattern": pattern, "matches": matches, "scanned_bytes": scanned, "lines_scanned": number, "decompressed": bool(compressed),
            "complete": complete, "note": None if complete else "stopped early (match limit or time); search again with a narrower pattern"}


def archive_listing(fd):
    entries, total, deadline = [], 0, time.monotonic() + SCAN_SECONDS
    os.lseek(fd, 0, os.SEEK_SET)
    handle = os.fdopen(os.dup(fd), "rb")
    try:
        if zipfile.is_zipfile(handle):
            handle.seek(0)
            try:
                with zipfile.ZipFile(handle) as archive:
                    for item in archive.infolist():
                        total += 1
                        if len(entries) < MAX_LIST:
                            entries.append({"name": item.filename, "bytes": item.file_size, "dir": item.is_dir()})
            except (zipfile.BadZipFile, OSError, ValueError):
                refuse("STANDARD_NOT_ARCHIVE")
            return {"archive": "zip", "entries": entries, "total": total, "complete": True}
        handle.seek(0)
        try:
            with tarfile.open(fileobj=handle, mode="r:*") as archive:
                for item in archive:
                    total += 1
                    if len(entries) < MAX_LIST:
                        entries.append({"name": item.name, "bytes": item.size, "type": "dir" if item.isdir() else "file" if item.isreg() else "link/other"})
                    if time.monotonic() > deadline:
                        return {"archive": "tar", "entries": entries, "total": total, "complete": False}
            return {"archive": "tar", "entries": entries, "total": total, "complete": True}
        except (tarfile.TarError, OSError, EOFError, lzma.LZMAError):
            refuse("STANDARD_NOT_ARCHIVE")
    finally:
        handle.close()


# -- create, take, register -----------------------------------------------------------

def op_create(ws, request):
    platform = request.get("platform")
    if not isinstance(platform, str) or not PLATFORM.fullmatch(platform):
        refuse("STANDARD_ARGUMENTS_INVALID")
    repo = request.get("converter_repo") or CONVERTER_REPO
    branch = request.get("converter_branch") or "main"
    if not isinstance(repo, str) or not re.fullmatch(r"https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+?(\.git)?", repo):
        refuse("STANDARD_ARGUMENTS_INVALID")
    if not isinstance(branch, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,99}", branch) or ".." in branch:
        refuse("STANDARD_ARGUMENTS_INVALID")
    done = []
    if not ws.initialized():
        ws.control(["named", "init", ws.name])
        done.append("workspace")
    with ws.lock():
        meta = ws.meta()
        if meta.get("platform") and meta["platform"] != platform:
            refuse("STANDARD_PLATFORM_MISMATCH")
        if not meta.get("source_id"):
            meta["source_id"] = json.loads(ws.control(["named", "source", "add", ws.name, "--platform", platform]))["source_id"]
            meta["platform"] = platform
            done.append("source")
            ws.write_json(ws.data_dir() / "workspace.json", meta)
        if not meta.get("dataset_id"):
            meta["dataset_id"] = json.loads(ws.control(["named", "dataset", "add", ws.name, "--source", meta["source_id"], "--label", "initial"]))["dataset_id"]
            done.append("dataset")
            ws.write_json(ws.data_dir() / "workspace.json", meta)
        if not (ws.root / "converter").exists():
            ws.control(["converter", "clone", ws.name, "--repo", repo, "--branch", branch], timeout=240)
            meta["converter"] = {"repo": repo, "branch": branch}
            done.append("converter")
            ws.write_json(ws.data_dir() / "workspace.json", meta)
        if not (ws.root / ".silo-migrate/named/standard/state.json").is_file():
            ws.control(["standard", "init", ws.name])
            done.append("standard")
        for area in ("inputs", "work"):
            path = ws.root / area
            if not path.exists():
                path.mkdir(mode=0o700)
    return {"workspace": ws.name, "created": done, "source_id": meta["source_id"], "dataset_id": meta["dataset_id"],
            "platform": meta["platform"], "converter": meta.get("converter")}


def dest_name(raw, fallback):
    name = raw if raw is not None else re.sub(r"[^A-Za-z0-9._-]+", "_", fallback).strip("._") or "input"
    if not isinstance(name, str) or not SAFE_NAME.fullmatch(name) or name.startswith("."):
        refuse("STANDARD_ARGUMENTS_INVALID")
    return name


def register(ws, meta, relative, digest, size, kind):
    result = json.loads(ws.control(["named", "input", "add", ws.name, "--dataset", meta["dataset_id"], "--path", relative,
                                    "--sha256", digest, "--bytes", str(size), "--type", kind], timeout=280))
    return result["input_id"]


def place(ws, src_fd, src_dir_fd, src_name, dest_dir_fd, name):
    """Move one regular file into a directory: rename on the same filesystem, else a verified copy."""
    try:
        os.stat(name, dir_fd=dest_dir_fd, follow_symlinks=False)
        refuse("STANDARD_INPUT_EXISTS")
    except FileNotFoundError:
        pass
    try:
        os.rename(src_name, name, src_dir_fd=src_dir_fd, dst_dir_fd=dest_dir_fd)
        moved = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dest_dir_fd)
        if os.fstat(moved).st_ino != os.fstat(src_fd).st_ino:
            os.close(moved)
            refuse("STANDARD_INPUT_CHANGED")
        return moved, "moved"
    except OSError as error:
        if error.errno != 18:  # EXDEV
            raise
    out = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dest_dir_fd)
    os.lseek(src_fd, 0, os.SEEK_SET)
    with os.fdopen(out, "wb") as handle:
        while True:
            chunk = os.read(src_fd, 1024 * 1024)
            if not chunk:
                break
            handle.write(chunk)
        handle.flush()
        os.fsync(handle.fileno())
    copied = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dest_dir_fd)
    if sha256_fd(copied) != sha256_fd(src_fd):
        os.close(copied)
        os.unlink(name, dir_fd=dest_dir_fd)
        refuse("STANDARD_COPY_MISMATCH")
    os.unlink(src_name, dir_fd=src_dir_fd)
    return copied, "copied"


def op_take(ws, request):
    """Move one file from the drop folder into inputs/, make it read-only, register it."""
    ws.require()
    parts = parts_of(request.get("path"))
    kind = request.get("type")
    if not isinstance(kind, str) or not TYPE.fullmatch(kind):
        refuse("STANDARD_ARGUMENTS_INVALID")
    name = dest_name(request.get("name"), parts[-1])
    with ws.lock():
        meta = ws.meta()
        if not meta.get("dataset_id"):
            refuse("STANDARD_NOT_INITIALIZED")
        root = ws.open_area("intake")
        try:
            fd, info = open_regular(root, parts)
            parent = walk_dirs(root, parts[:-1])
        finally:
            os.close(root)
        inputs = ws.open_area("inputs")
        try:
            if info.st_nlink != 1:
                refuse("STANDARD_PATH_INVALID")
            placed, how = place(ws, fd, parent, parts[-1], inputs, name)
        finally:
            os.close(fd)
            os.close(parent)
            os.close(inputs)
        try:
            os.fchmod(placed, 0o400)
            digest = sha256_fd(placed)
            size = os.fstat(placed).st_size
        finally:
            os.close(placed)
        relative = "inputs/" + name
        input_id = register(ws, meta, relative, digest, size, kind)
        record = {"at": now(), "event": "take", "input_id": input_id, "path": relative, "from": "intake/" + "/".join(parts),
                  "sha256": digest, "bytes": size, "type": kind, "how": how}
        ws.append("provenance.jsonl", record)
    return {"input_id": input_id, "path": relative, "sha256": digest, "bytes": size, "type": kind, "how": how,
            "note": "the original bytes are now read-only in inputs/; nothing was changed"}


def op_register(ws, request):
    """Move a finished output file from work/ into inputs/derived/, read-only, registered with provenance."""
    ws.require()
    parts = parts_of(request.get("path"))
    kind = request.get("type")
    if not isinstance(kind, str) or not TYPE.fullmatch(kind) or len(parts) < 2 or not WORK_NAME.fullmatch(parts[0]):
        refuse("STANDARD_ARGUMENTS_INVALID")
    name = dest_name(request.get("name"), parts[0] + "-" + parts[-1])
    with ws.lock():
        meta = ws.meta()
        if any(job.get("into") == parts[0] and job.get("status") == "running" for job in jobs_of(ws)):
            refuse("STANDARD_BUSY")
        root = ws.open_area("work")
        try:
            fd, info = open_regular(root, parts)
            parent = walk_dirs(root, parts[:-1])
        finally:
            os.close(root)
        inputs = ws.open_area("inputs")
        try:
            if info.st_nlink != 1 or info.st_uid != os.getuid():
                refuse("STANDARD_PATH_INVALID")
            try:
                os.mkdir("derived", 0o700, dir_fd=inputs)
            except FileExistsError:
                pass
            derived = os.open("derived", DIR_FLAGS, dir_fd=inputs)
            try:
                placed, how = place(ws, fd, parent, parts[-1], derived, name)
            finally:
                os.close(derived)
        finally:
            os.close(fd)
            os.close(parent)
            os.close(inputs)
        try:
            os.fchmod(placed, 0o400)
            digest = sha256_fd(placed)
            size = os.fstat(placed).st_size
        finally:
            os.close(placed)
        relative = "inputs/derived/" + name
        input_id = register(ws, meta, relative, digest, size, kind)
        producer = next((job for job in reversed(jobs_of(ws)) if job.get("into") == parts[0]), None)
        record = {"at": now(), "event": "derived", "input_id": input_id, "path": relative, "from": "work/" + "/".join(parts),
                  "sha256": digest, "bytes": size, "type": kind,
                  "job": producer and {key: producer.get(key) for key in ("id", "kind", "script_sha256", "inputs", "source")}}
        ws.append("provenance.jsonl", record)
    return {"input_id": input_id, "path": relative, "sha256": digest, "bytes": size, "type": kind,
            "produced_by": producer and producer.get("id")}


# -- sandboxed jobs ----------------------------------------------------------------------

def jobs_of(ws):
    directory = ws.data / "jobs"
    if not directory.is_dir():
        return []
    return sorted((ws.read_json(path, {}) for path in directory.glob("job-*.json")), key=lambda job: job.get("started_at", ""))


def input_digests(ws):
    state = ws.named_state()
    return [{"path": base64.b64decode(record["path"]).decode("utf-8", "replace"), "sha256": record["sha256"]} for record in state.get("inputs", {}).values()]


def minutes(request):
    value = request.get("timeout_minutes", JOB_DEFAULT_MINUTES)
    if not isinstance(value, int) or not 1 <= value <= JOB_MAX_MINUTES:
        refuse("STANDARD_ARGUMENTS_INVALID")
    return value


def work_dir(ws, into, fresh=True):
    if not isinstance(into, str) or not WORK_NAME.fullmatch(into):
        refuse("STANDARD_ARGUMENTS_INVALID")
    work = ws.root / "work"
    if work.is_symlink():
        refuse("STANDARD_PATH_INVALID")
    work.mkdir(mode=0o700, exist_ok=True)
    path = work / into
    if path.is_symlink():
        refuse("STANDARD_PATH_INVALID")
    if path.exists():
        if fresh and any(path.iterdir()):
            refuse("STANDARD_OUTPUT_EXISTS")
    else:
        path.mkdir(mode=0o700)
    if path.lstat().st_uid != os.getuid():
        refuse("STANDARD_PATH_INVALID")
    return path


def mount(src, dst, readonly=True):
    if "," in str(src) or "," in str(dst) or not str(src).startswith("/"):
        refuse("STANDARD_PATH_INVALID")
    return ["--mount", f"type=bind,src={src},dst={dst}" + (",readonly" if readonly else "")]


def sandbox_argv(ws, name, out, extra_mounts, command):
    """No network, read-only root, this account's uid, no capabilities, bounded resources."""
    gems = ws.values.get("SILO_CONTROL_GEMS")
    argv = ["run", "-d", "--name", name, "--label", "silo.workspace=" + ws.name, "--label", "silo.role=data-job",
            "--pull=never", "--restart", "no", "--network", "none", "--read-only", "--user", f"{os.getuid()}:{os.getgid()}",
            "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--cpus", SANDBOX["cpus"], "--memory", SANDBOX["memory"],
            "--memory-swap", SANDBOX["memory"], "--pids-limit", SANDBOX["pids"], "--log-opt", "max-size=4m", "--log-opt", "max-file=1",
            "--tmpfs", "/tmp:rw,exec,size=" + SANDBOX["tmp"], *mount(ws.root / "inputs", "/in"), *mount(out, "/out", False),
            *mount(ws.repo, "/silo")]
    if gems and Path(gems).is_dir():
        argv += [*mount(gems, "/gems"), "-e", "GEM_PATH=/gems:/gems/ruby/3.3.0", "-e", "BUNDLE_PATH=/gems", "-e", "BUNDLE_FROZEN=true",
                 "-e", "BUNDLE_GEMFILE=/silo/Gemfile", "-e", "BUNDLE_APP_CONFIG=/tmp/bundle-config", "-e", "BUNDLE_DISABLE_VERSION_CHECK=true"]
    for src, dst in extra_mounts:
        argv += mount(src, dst)
    argv += ["-e", "HOME=/tmp", "-e", "TMPDIR=/tmp", "-e", "LANG=C.UTF-8", "-e", "LC_ALL=C.UTF-8", "-w", "/tmp", "--entrypoint", "timeout",
             ws.image("control"), *command]
    return argv


def start_job(ws, kind, into, argv_for, extra=None):
    if any(job.get("status") == "running" for job in refresh_jobs(ws)):
        refuse("STANDARD_BUSY")
    job_id = "job-" + secrets.token_hex(6)
    container = "silo-data-" + ws.name + "-" + job_id[4:]
    argv = argv_for(container)
    record = {"id": job_id, "kind": kind, "container": container, "into": into, "started_at": now(), "status": "running", **(extra or {})}
    ws.write_json(ws.data_dir("jobs") / (job_id + ".json"), record)
    result = docker(argv, timeout=120)
    if result.returncode:
        record.update(status="failed_to_start", finished_at=now(), error=tail_text(result.stderr, 2048)[0])
        ws.write_json(ws.data_dir("jobs") / (job_id + ".json"), record)
        docker(["rm", "-f", container], timeout=30)
        refuse("STANDARD_JOB_NOT_STARTED")
    return record


def op_script(ws, request):
    ws.require()
    language = request.get("language", "ruby")
    code = request.get("code")
    if language not in ("ruby", "python") or not isinstance(code, str) or not code.strip() or len(code.encode("utf-8")) > MAX_SCRIPT:
        refuse("STANDARD_ARGUMENTS_INVALID")
    limit = minutes(request)
    with ws.lock():
        out = work_dir(ws, request.get("into"))
        data = code.encode("utf-8")
        digest = hashlib.sha256(data).hexdigest()
        script = ws.data_dir("scripts") / (digest + (".rb" if language == "ruby" else ".py"))
        if not script.exists():
            fd = os.open(script, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
        target = "/job/script.rb" if language == "ruby" else "/job/script.py"
        interpreter = ["ruby", target] if language == "ruby" else ["python3", "-I", target]
        record = start_job(ws, "script", out.name,
                           lambda name: sandbox_argv(ws, name, out, [(script, target)], ["-s", "KILL", str(limit * 60), *interpreter]),
                           {"language": language, "script_sha256": digest, "inputs": input_digests(ws), "timeout_minutes": limit})
    return {"job_id": record["id"], "status": "running", "script_sha256": digest, "into": "work/" + out.name,
            "next": "poll data_job until it finishes; outputs land in work/" + out.name}


def op_extract(ws, request):
    ws.require()
    parts = parts_of(request.get("path"))
    if parts[0] != "inputs" or len(parts) < 2:
        refuse("STANDARD_ARGUMENTS_INVALID")
    limit = minutes(request)
    with ws.lock():
        root = ws.open_area("inputs")
        try:
            fd, _info = open_regular(root, parts[1:])
            digest = sha256_fd(fd)
            os.close(fd)
        finally:
            os.close(root)
        out = work_dir(ws, request.get("into"))
        command = ["-s", "KILL", str(limit * 60), "python3", "-I", "/silo/bin/data_extract.py", "/in/" + "/".join(parts[1:]), "/out"]
        record = start_job(ws, "extract", out.name, lambda name: sandbox_argv(ws, name, out, [], command),
                           {"source": {"path": "/".join(parts), "sha256": digest}, "timeout_minutes": limit})
    return {"job_id": record["id"], "status": "running", "into": "work/" + out.name, "next": "poll data_job"}


def refresh_jobs(ws):
    jobs = jobs_of(ws)
    for job in jobs:
        if job.get("status") == "running":
            finish(ws, job)
    return jobs


def finish(ws, job, keep_logs=False):
    """Update a running job from its container; when it has exited, keep its log tail and remove it."""
    result = docker(["inspect", "--format", "{{json .State}}", job["container"]], timeout=30)
    if result.returncode:
        job.update(status="lost", finished_at=now())
        ws.write_json(ws.data_dir("jobs") / (job["id"] + ".json"), job)
        return None
    state = json.loads(result.stdout)
    if state.get("Running") or state.get("Status") in ("created", "running", "restarting"):
        return None
    logs = docker(["logs", "--tail", "400", job["container"]], timeout=60)
    combined = logs.stdout + (b"\n--- stderr ---\n" + logs.stderr if logs.stderr else b"")
    log_dir = ws.data_dir("jobs")
    fd = os.open(log_dir / (job["id"] + ".log"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(combined[-256 * 1024:])
    code = state.get("ExitCode")
    job.update(status="succeeded" if code == 0 else ("timed_out" if code == 137 and not state.get("OOMKilled") else "failed"),
               exit_code=code, oom_killed=bool(state.get("OOMKilled")), finished_at=now())
    ws.write_json(log_dir / (job["id"] + ".json"), job)
    docker(["rm", "-f", job["container"]], timeout=60)
    return combined


def op_job(ws, request):
    ws.require(standard=False)
    job_id = request.get("job_id")
    if not isinstance(job_id, str) or not JOB.fullmatch(job_id):
        refuse("STANDARD_ARGUMENTS_INVALID")
    path = ws.data / "jobs" / (job_id + ".json")
    job = ws.read_json(path, None)
    if not job:
        refuse("STANDARD_REFERENCE_INVALID")
    if job.get("status") == "running":
        with ws.lock():
            finish(ws, job)
    result = {key: job.get(key) for key in ("id", "kind", "status", "exit_code", "oom_killed", "started_at", "finished_at", "into",
                                             "script_sha256", "timeout_minutes", "source", "error")}
    if job.get("status") == "running":
        logs = docker(["logs", "--tail", "200", job["container"]], timeout=60)
        result["log_tail"], result["log_truncated"] = tail_text(logs.stdout + logs.stderr)
    else:
        log = ws.data / "jobs" / (job_id + ".log")
        result["log_tail"], result["log_truncated"] = tail_text(log.read_bytes() if log.is_file() else b"")
    if job.get("into") and (ws.root / "work" / job["into"]).is_dir():
        files, total = [], 0
        for path in sorted((ws.root / "work" / job["into"]).rglob("*")):
            if path.is_file() and not path.is_symlink():
                total += 1
                if len(files) < 50:
                    files.append({"path": str(path.relative_to(ws.root / "work")), "bytes": path.stat().st_size})
        result["outputs"], result["outputs_total"] = files, total
    return result


# -- the source database ---------------------------------------------------------------

def db_names(ws):
    return {"network": "silo-src-" + ws.name, "container": "silo-src-" + ws.name, "volume": "silo-src-" + ws.name + "-data"}


def db_state(ws):
    return ws.read_json(ws.data_dir("db") / "state.json", None)


def db_secret(ws, engine=None):
    path = ws.data_dir("db") / "secret.env"
    if engine:
        root, ro = secrets.token_hex(24), secrets.token_hex(24)
        lines = {"mariadb": ["MARIADB_ROOT_PASSWORD=" + root, "MARIADB_DATABASE=source"],
                 "postgres": ["POSTGRES_PASSWORD=" + root, "DB_PASSWORD=" + root, "DB_USER=postgres", "POSTGRES_DB=source"]}[engine]
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write("\n".join(lines + ["SILO_RO_USER=" + RO_USER, "SILO_RO_PASSWORD=" + ro]) + "\n")
    return path


def db_exec(ws, engine, sql=None, query=None, timeout=60):
    """Run SQL as the database's administrator inside the server container (never shown to the agent)."""
    container = db_names(ws)["container"]
    if engine == "mariadb":
        argv = ["exec", "-i", "--env-file", str(db_secret(ws)), container, "bash", "-c",
                'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -N -B --protocol=socket']
    else:
        argv = ["exec", "-i", container, "psql", "-U", "postgres", "-d", "source", "-v", "ON_ERROR_STOP=1", "-q", "-At"]
    return docker(argv, timeout=timeout, input=(sql or query).encode("utf-8"))


def ensure_ro_user(ws, engine):
    password = next(line.split("=", 1)[1] for line in db_secret(ws).read_text().splitlines() if line.startswith("SILO_RO_PASSWORD="))
    if not re.fullmatch(r"[0-9a-f]{48}", password):
        refuse("STANDARD_OPERATION_FAILED")
    if engine == "mariadb":
        sql = (f"CREATE USER IF NOT EXISTS '{RO_USER}'@'%' IDENTIFIED BY '{password}';\n"
               f"GRANT SELECT, SHOW VIEW ON `source`.* TO '{RO_USER}'@'%';\n")
    else:
        sql = (f"DO $$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '{RO_USER}') THEN "
               f"CREATE ROLE {RO_USER} LOGIN PASSWORD '{password}'; END IF; END$$;\n"
               f"ALTER ROLE {RO_USER} SET default_transaction_read_only = on;\n"
               f"GRANT CONNECT ON DATABASE source TO {RO_USER};\n" + pg_grants())
    return db_exec(ws, engine, sql).returncode == 0


def pg_grants():
    return ("DO $$DECLARE s text; BEGIN FOR s IN SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg\\_%' "
            f"AND nspname <> 'information_schema' LOOP EXECUTE format('GRANT USAGE ON SCHEMA %I TO {RO_USER}', s); "
            f"EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO {RO_USER}', s); END LOOP; END$$;\n")


def db_ready(ws, engine):
    container = db_names(ws)["container"]
    if engine == "mariadb":
        result = docker(["exec", container, "mariadb-admin", "--protocol=tcp", "-h127.0.0.1", "ping", "--silent"], timeout=20)
    else:
        result = docker(["exec", container, "pg_isready", "-q", "-h", "127.0.0.1", "-U", "postgres"], timeout=20)
    return result.returncode == 0


def op_db_up(ws, request):
    ws.require()
    engine = request.get("engine")
    if engine not in ENGINES:
        refuse("STANDARD_ARGUMENTS_INVALID")
    names = db_names(ws)
    with ws.lock():
        state = db_state(ws)
        if state and state["engine"] != engine:
            refuse("STANDARD_DB_ENGINE_MISMATCH")
        image = ws.image(ENGINES[engine])
        inspected = docker(["inspect", "--format", "{{.State.Running}}", names["container"]], timeout=30)
        if inspected.returncode == 0:
            if inspected.stdout.strip() != b"true":
                docker_ok(["start", names["container"]])
        else:
            if docker(["network", "inspect", names["network"]], timeout=30).returncode:
                docker_ok(["network", "create", "--internal", "--label", "silo.workspace=" + ws.name, names["network"]])
            if not state:
                db_secret(ws, engine)
            command = (["--innodb-buffer-pool-size=1G", "--max-allowed-packet=1G", "--innodb-flush-log-at-trx-commit=2", "--skip-name-resolve"]
                       if engine == "mariadb" else
                       ["postgres", "-c", "fsync=off", "-c", "full_page_writes=off", "-c", "max_wal_size=4GB", "-c", "maintenance_work_mem=512MB"])
            data = "/var/lib/mysql" if engine == "mariadb" else "/var/lib/postgresql"
            docker_ok(["run", "-d", "--name", names["container"], "--label", "silo.workspace=" + ws.name, "--label", "silo.role=source-db",
                       "--pull=never", "--restart", "no", "--network", names["network"], "--network-alias", "source-db",
                       "--cap-drop", "ALL", *[flag for cap in ("CHOWN", "SETUID", "SETGID", "DAC_OVERRIDE", "FOWNER") for flag in ("--cap-add", cap)],
                       "--security-opt", "no-new-privileges", "--cpus", DB_LIMITS["cpus"], "--memory", DB_LIMITS["memory"],
                       "--memory-swap", DB_LIMITS["memory"], "--pids-limit", DB_LIMITS["pids"], "--log-opt", "max-size=4m",
                       "--log-opt", "max-file=1", "--shm-size", "256m", "--mount", f"type=volume,src={names['volume']},dst={data}",
                       "--env-file", str(db_secret(ws)), image, *command])
            state = {"engine": engine, "image": image, "created_at": now(), "loads": [], "ro_user": False}
            ws.write_json(ws.data_dir("db") / "state.json", state)
        deadline = time.monotonic() + 90
        ready = db_ready(ws, engine)
        while not ready and time.monotonic() < deadline:
            time.sleep(2)
            ready = db_ready(ws, engine)
        if ready and not state.get("ro_user"):
            state["ro_user"] = ensure_ro_user(ws, engine)
            ws.write_json(ws.data_dir("db") / "state.json", state)
    return {"engine": engine, "ready": ready, "network": names["network"] + " (internal: no outside access)",
            "read_only_user": RO_USER if state.get("ro_user") else None,
            "next": "data_db_load with a registered input" if ready else "still starting; check data_db_status"}


def op_db_load(ws, request):
    ws.require()
    parts = parts_of(request.get("path"))
    if parts[0] != "inputs" or len(parts) < 2:
        refuse("STANDARD_ARGUMENTS_INVALID")
    charset = request.get("charset", "utf8mb4")
    stop_on_error = request.get("stop_on_error", True) is not False
    limit = minutes({"timeout_minutes": request.get("timeout_minutes", 120)})
    if charset not in CHARSETS:
        refuse("STANDARD_ARGUMENTS_INVALID")
    names = db_names(ws)
    with ws.lock():
        state = db_state(ws)
        if not state:
            refuse("STANDARD_DB_NOT_UP")
        engine = state["engine"]
        if not db_ready(ws, engine):
            refuse("STANDARD_DB_NOT_READY")
        if not state.get("ro_user"):
            state["ro_user"] = ensure_ro_user(ws, engine)
        root = ws.open_area("inputs")
        try:
            fd, _info = open_regular(root, parts[1:])
            kind = describe(fd)
            digest = sha256_fd(fd)
            os.close(fd)
        finally:
            os.close(root)
        source = ws.root / "inputs" / "/".join(parts[1:])
        decompress = {"gzip": "gzip -dc", "bzip2": "bzip2 -dc", "xz": "xz -dc"}.get(kind["kind"], "cat")
        if engine == "mariadb":
            script = (f'set -o pipefail; {decompress} /in/dump | MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -h source-db -uroot '
                      f'--default-character-set={charset} {"" if stop_on_error else "--force "}source && '
                      f'for d in $(MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -h source-db -uroot -N -B -e "SHOW DATABASES" | grep -vxE "{SYSTEM_DATABASES}"); do '
                      f'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -h source-db -uroot -e "GRANT SELECT, SHOW VIEW ON \\`$d\\`.* TO \'{RO_USER}\'@\'%\'"; done; echo LOAD_DONE')
        elif kind.get("kind") == "postgres-custom-dump":
            script = (f'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore --no-owner --no-privileges -h source-db -U postgres -d source '
                      f'{"--exit-on-error " if stop_on_error else ""}/in/dump; code=$?; '
                      f'PGPASSWORD="$POSTGRES_PASSWORD" psql -h source-db -U postgres -d source -q <<\'SQL\'\n{pg_grants()}SQL\n'
                      'echo LOAD_DONE; exit $code')
        else:
            script = (f'set -o pipefail; {decompress} /in/dump | PGPASSWORD="$POSTGRES_PASSWORD" psql -h source-db -U postgres -d source -q '
                      f'-v ON_ERROR_STOP={1 if stop_on_error else 0}; code=$?; '
                      f'PGPASSWORD="$POSTGRES_PASSWORD" psql -h source-db -U postgres -d source -q <<\'SQL\'\n{pg_grants()}SQL\n'
                      'echo LOAD_DONE; exit $code')

        def argv(name):
            return ["run", "-d", "--name", name, "--label", "silo.workspace=" + ws.name, "--label", "silo.role=data-job",
                    "--pull=never", "--restart", "no", "--network", names["network"], "--read-only",
                    "--user", f"{os.getuid()}:{os.getgid()}", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                    "--cpus", "1", "--memory", "1g", "--memory-swap", "1g", "--pids-limit", "64", "--log-opt", "max-size=4m",
                    "--log-opt", "max-file=1", "--tmpfs", "/tmp:rw,size=64m", "-e", "HOME=/tmp", *mount(source, "/in/dump"),
                    "--env-file", str(db_secret(ws)), "--entrypoint", "timeout", state["image"], "-s", "KILL", str(limit * 60),
                    "bash", "-c", script]
        record = start_job(ws, "db_load", None, argv, {"source": {"path": "/".join(parts), "sha256": digest, "kind": kind},
                                                        "engine": engine, "charset": charset, "timeout_minutes": limit})
        state["loads"].append({"job_id": record["id"], "path": "/".join(parts), "sha256": digest, "started_at": record["started_at"]})
        ws.write_json(ws.data_dir("db") / "state.json", state)
    return {"job_id": record["id"], "status": "running", "engine": engine, "source_kind": kind,
            "next": "poll data_job; then data_db_status"}


def op_db_status(ws, request):
    ws.require()
    state = db_state(ws)
    if not state:
        return {"source_db": None, "next": "data_db_up with engine mariadb or postgres"}
    names = db_names(ws)
    inspected = docker(["inspect", "--format", "{{.State.Status}}", names["container"]], timeout=30)
    running = inspected.returncode == 0 and inspected.stdout.strip() == b"running"
    result = {"engine": state["engine"], "container": inspected.stdout.decode().strip() if inspected.returncode == 0 else "missing",
              "ready": running and db_ready(ws, state["engine"]), "read_only_user": RO_USER if state.get("ro_user") else None,
              "loads": state.get("loads", []), "network": names["network"] + " (internal)"}
    if result["ready"]:
        if state["engine"] == "mariadb":
            query = (f"SELECT table_schema, COUNT(*), ROUND(SUM(data_length + index_length) / 1048576) FROM information_schema.tables "
                     f"WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys') GROUP BY table_schema;")
        else:
            query = ("SELECT table_schema, COUNT(*), pg_database_size('source') / 1048576 FROM information_schema.tables "
                     "WHERE table_schema NOT IN ('pg_catalog','information_schema') GROUP BY table_schema;")
        out = db_exec(ws, state["engine"], query=query)
        rows = [line.split("\t" if state["engine"] == "mariadb" else "|") for line in out.stdout.decode("utf-8", "replace").splitlines() if line.strip()]
        result["schemas"] = [{"schema": row[0], "tables": int(row[1]), "approx_mb": row[2]} for row in rows[:20] if len(row) == 3]
        result["queries"] = "free queries: through DBHub once term-llm can attach an MCP server to migration-data only"
    return result


def op_db_reset(ws, request):
    ws.require()
    if request.get("confirm") is not True:
        refuse("STANDARD_CONFIRMATION_REQUIRED")
    names = db_names(ws)
    with ws.lock():
        if any(job.get("status") == "running" and job.get("kind") == "db_load" for job in refresh_jobs(ws)):
            refuse("STANDARD_BUSY")
        docker(["rm", "-f", names["container"]], timeout=120)
        docker(["volume", "rm", "-f", names["volume"]], timeout=120)
        docker(["network", "rm", names["network"]], timeout=60)
        for name in ("state.json", "secret.env"):
            path = ws.data / "db" / name
            if path.is_file() and not path.is_symlink():
                path.unlink()
    return {"source_db": None, "note": "the source database was removed; registered inputs are untouched"}


# -- runs and findings --------------------------------------------------------------------

def op_run_evidence(ws, request):
    run_id = request.get("run_id")
    if not isinstance(run_id, str) or not RUN.fullmatch(run_id):
        refuse("STANDARD_ARGUMENTS_INVALID")
    return {"evidence": json.loads(ws.control(["standard", "analyst", "evidence", ws.name, run_id]))}


def op_propose_finding(ws, request):
    text = request.get("text")
    run_id = request.get("run_id")
    if not isinstance(text, str) or not text.strip() or len(text.encode("utf-8")) > MAX_FINDING:
        refuse("STANDARD_ARGUMENTS_INVALID")
    if run_id is None:
        argv = ["standard", "finding", "propose", ws.name, "--kind", "schema", "--file", "-"]
    elif isinstance(run_id, str) and RUN.fullmatch(run_id):
        argv = ["standard", "finding", "propose", ws.name, "--run", run_id, "--file", "-"]
    else:
        refuse("STANDARD_ARGUMENTS_INVALID")
    result = json.loads(ws.control(argv, input=text))
    return {"finding_id": result.get("finding_id"), "status": result.get("status"), "kind": "schema" if run_id is None else "finding",
            "note": "private proposal; the engineer reviews and decides what is released to coding agents"}


# -- dispatch ------------------------------------------------------------------------------

OPS = {"status": op_status, "list": op_list, "peek": op_peek, "create": op_create, "take": op_take, "register": op_register,
       "script": op_script, "extract": op_extract, "job": op_job, "db_up": op_db_up, "db_load": op_db_load,
       "db_status": op_db_status, "db_reset": op_db_reset, "run_evidence": op_run_evidence, "propose_finding": op_propose_finding}
# Logged with their arguments (minus script code and finding text, logged by hash).
QUIET = {"status", "list", "job", "db_status"}


def fit(result):
    """Keep the printed JSON under the tool limit: shorten the largest text, then drop list tails."""
    for _ in range(24):
        size = len(json.dumps(result, ensure_ascii=False).encode("utf-8"))
        if size <= OUTPUT_LIMIT:
            return result
        texts = [key for key, value in result.items() if isinstance(value, str) and len(value) > 256]
        lists = [key for key, value in result.items() if isinstance(value, list) and len(value) > 1]
        if texts:
            key = max(texts, key=lambda k: len(result[k].encode("utf-8")))
            half = len(result[key]) // 2
            result[key] = ("…[shortened]\n" + result[key][-half:]) if key.endswith("_tail") else (result[key][:half] + "\n…[shortened]")
        elif lists:
            key = max(lists, key=lambda k: len(json.dumps(result[k], ensure_ascii=False)))
            result[key] = result[key][: len(result[key]) // 2]
        else:
            break
        result["shortened"] = True
    if len(json.dumps(result, ensure_ascii=False).encode("utf-8")) > OUTPUT_LIMIT:
        refuse("STANDARD_OUTPUT_TOO_LARGE")
    return result


def audit_args(request):
    shown = {}
    for key, value in request.items():
        if key in ("code", "text") and isinstance(value, str):
            shown[key + "_sha256"] = hashlib.sha256(value.encode("utf-8")).hexdigest()
        elif isinstance(value, (str, int, bool)) or value is None:
            shown[key] = value if not isinstance(value, str) else value[:300]
    return shown


def control_runner(path):
    """Calls back into silo-migrate-control (named/standard/converter) and keeps its error code."""
    def call(argv, input=None, timeout=120):
        try:
            result = subprocess.run([str(path), *argv], input=input, capture_output=True, text=True, timeout=timeout,
                                    stdin=None if input is not None else subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            refuse("STANDARD_OPERATION_TIMEOUT")
        if result.returncode:
            match = re.search(r"Error: ((?:STANDARD|NAMED)_[A-Z_]+)", result.stderr)
            refuse(match[1] if match else "STANDARD_OPERATION_FAILED")
        return result.stdout
    return call


def main(args, values, base, repo, host, stdin, control):
    """`data WS` with one JSON request on stdin; control runs silo-migrate-control subcommands."""
    if len(args) != 2 or args[0] != "data":
        refuse("STANDARD_ARGUMENTS_INVALID")
    try:
        request = json.loads(stdin.read(1024 * 1024))
    except ValueError:
        refuse("STANDARD_ARGUMENTS_INVALID")
    if not isinstance(request, dict) or request.get("op") not in OPS:
        refuse("STANDARD_DATA_OPERATION_REFUSED")
    ws = Workspace(base, args[1], repo, host, values, control)
    op = request["op"]
    error = None
    try:
        return fit(dict(version=1, **OPS[op](ws, request)))
    except Refusal as refusal:
        error = str(refusal)
        raise
    except Exception:  # noqa: BLE001 - corrupt input (zlib/zip errors...) must not print a traceback
        error = "STANDARD_OPERATION_FAILED"
        refuse(error)
    finally:
        if op not in QUIET and ws.initialized() and not ws.data.is_symlink():
            try:
                ws.append("audit.jsonl", {"at": now(), "op": op, "args": audit_args({k: v for k, v in request.items() if k != "op"}),
                                          "result": error or "ok"})
            except OSError:
                pass
