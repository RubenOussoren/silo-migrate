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
from contextlib import nullcontext
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
import shutil
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
ENGINEER_OUTPUT_LIMIT = 64 * 1024 * 1024  # four bounded role-registry documents; never a chat limit
MAX_LIST = 400
MAX_PEEK = 32 * 1024
MAX_MATCHES = 100
MAX_LINE = 300
SCAN_SECONDS = 40
MAX_SCRIPT = 256 * 1024
MAX_FINDING = 256 * 1024
LOG_TAIL = 16 * 1024
CHUNK = 1024 * 1024
OVERLAP = 512
JOB_DEFAULT_MINUTES = 30
JOB_MAX_MINUTES = 360
SANDBOX = {"cpus": "2", "memory": "4g", "pids": "256", "tmp": "1g"}
DB_LIMITS = {"cpus": "2", "memory": "4g", "pids": "512"}
CHARSETS = ("utf8mb4", "utf8mb3", "utf8", "latin1", "binary")
ENGINES = {"mariadb": "source_db", "postgres": "db"}
RO_USER = "silo_ro"
DISK_RESERVE = 20 * 1024 ** 3
# A chat tool has 300 s; checksumming twice (here and in the registry) fits comfortably below
# this. Larger files: the engineer runs the same request from a shell (no time limit).
MAX_TOOL_INPUT = 16 * 1024 ** 3
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
            refuse("STANDARD_ARGUMENTS_INVALID: workspace")
        self.name = name
        self.base = Path(base)
        self.root = self.base / name
        # The install prefix, where `silo` keeps the drop folders and settings: workspaces may live elsewhere.
        self.prefix = self.repo_prefix(Path(repo), self.base)
        self.intake = self.prefix / "intake" / name
        self.repo = Path(repo)
        self.host = host
        self.values = values
        self.control = control
        self.data = self.root / ".silo-migrate" / "data"
        self.chat = False

    @staticmethod
    def repo_prefix(repo, base):
        return repo.parent.parent if repo.parent.name == "releases" else base.parent

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
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, DIR_FLAGS)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

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
            refuse("STANDARD_ARGUMENTS_INVALID: area")
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
    def __init__(self, path, wait=False):
        self.path = path
        self.wait = wait

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | (0 if self.wait else fcntl.LOCK_NB))
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
    deliveries = read_deliveries(ws)
    for record in list(state.get("inputs", {}).values())[:200]:
        try:
            path = base64.b64decode(record["path"]).decode("utf-8", "replace")
        except (ValueError, KeyError):
            path = None
        inputs.append({"input_id": record.get("id"), "path": path, "type": record.get("type"), "bytes": record.get("bytes"),
                       "sha256": record.get("sha256"), "dataset_id": record.get("dataset_id"),
                       "delivery": delivery_label(deliveries[record["dataset_id"]]) if record.get("dataset_id") in deliveries else None})
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


def input_identity(ws, relative):
    record = find_registered(ws, relative) or {}
    delivery = read_deliveries(ws).get(record.get("dataset_id"))
    return {"input_type": record.get("type"), "delivery": delivery_label(delivery) if delivery else None}


def op_list(ws, request):
    area = request.get("area", "intake")
    if area not in AREAS:
        refuse("STANDARD_ARGUMENTS_INVALID: area")
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
                if area == "inputs":
                    entry.update(input_identity(ws, "/".join([area, *parts, name])))
                entries.append(entry)
            else:
                entries.append({"name": name, "type": "symlink" if stat.S_ISLNK(info.st_mode) else "other", "note": "ignored by every tool"})
    finally:
        os.close(fd)
    return {"area": area, "path": "/".join(parts), "entries": entries, "total": total, "listed": len(entries)}


def op_peek(ws, request):
    area = request.get("area", "intake")
    if area not in AREAS:
        refuse("STANDARD_ARGUMENTS_INVALID: area")
    parts = parts_of(request.get("path"))
    mode = request.get("mode", "head")
    limit = request.get("bytes", 8192)
    if not isinstance(limit, int) or not 1 <= limit <= MAX_PEEK:
        refuse("STANDARD_ARGUMENTS_INVALID: bytes")
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
        if area == "inputs":
            result.update(input_identity(ws, "/".join([area, *parts])))
        if mode == "head":
            offset = request.get("offset", 0)
            if not isinstance(offset, int) or offset < 0:
                refuse("STANDARD_ARGUMENTS_INVALID: offset")
            stream, compressed = reader(fd, decompress)
            deadline = time.monotonic() + SCAN_SECONDS
            try:
                skipped = 0
                while skipped < offset:
                    chunk = stream.read(min(CHUNK, offset - skipped))
                    if not chunk:
                        break
                    skipped += len(chunk)
                    if time.monotonic() > deadline:
                        refuse("STANDARD_OFFSET_TOO_FAR")
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
            refuse("STANDARD_ARGUMENTS_INVALID: mode")
    finally:
        os.close(fd)
    return result


def search(fd, request, decompress):
    pattern = request.get("pattern")
    if not isinstance(pattern, str) or not 1 <= len(pattern) <= 200:
        refuse("STANDARD_ARGUMENTS_INVALID: pattern")
    flags = re.IGNORECASE if request.get("ignore_case") else 0
    try:
        matcher = re.compile(pattern.encode("utf-8") if request.get("regex") else re.escape(pattern.encode("utf-8")), flags)
    except re.error:
        refuse("STANDARD_ARGUMENTS_INVALID: pattern")
    wanted = request.get("max_matches", 40)
    if not isinstance(wanted, int) or not 1 <= wanted <= MAX_MATCHES:
        refuse("STANDARD_ARGUMENTS_INVALID: max_matches")
    stream, compressed = reader(fd, decompress)
    matches, scanned, number, complete = [], 0, 1, True
    deadline = time.monotonic() + SCAN_SECONDS
    tail = b""  # the end of the previous piece of a long line, so matches across pieces are found
    try:
        while True:
            # Never more than one bounded piece in memory: lines can be gigabytes (one INSERT
            # per table, or no newline at all in binary or hostile input).
            piece = stream.readline(CHUNK)
            if not piece:
                break
            window = tail + piece
            found = next((match for match in matcher.finditer(window) if match.end() > len(tail)), None)
            if found:
                start = max(0, found.start() - 80)
                matches.append({"line": number, "offset": scanned - len(tail) + found.start(), "text": text_of(window[start:start + MAX_LINE])})
                if len(matches) >= wanted:
                    complete = False
                    scanned += len(piece)
                    break
            scanned += len(piece)
            if piece.endswith(b"\n"):
                number += 1
                tail = b""
            else:
                tail = piece[-OVERLAP:]
            if time.monotonic() > deadline:
                complete = False
                break
    except (OSError, EOFError, lzma.LZMAError):
        return {"matches": matches, "scanned_bytes": scanned, "complete": False, "error": "STANDARD_READ_FAILED"}
    finally:
        stream.close()
    return {"pattern": pattern, "matches": matches, "scanned_bytes": scanned, "lines_scanned": number - 1, "decompressed": bool(compressed),
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
        refuse("STANDARD_ARGUMENTS_INVALID: platform")
    repo = request.get("converter_repo") or CONVERTER_REPO
    branch = request.get("converter_branch") or "main"
    if not isinstance(repo, str) or not re.fullmatch(r"https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+?(\.git)?", repo):
        refuse("STANDARD_ARGUMENTS_INVALID: converter_repo")
    if not isinstance(branch, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,99}", branch) or ".." in branch:
        refuse("STANDARD_ARGUMENTS_INVALID: converter_branch")
    done = []
    with Locked(ws.base / ".silo-data-create.lock"):
        if not ws.initialized():
            ws.control(["named", "init", ws.name])
            done.append("workspace")
        return create_steps(ws, platform, repo, branch, done)


def create_steps(ws, platform, repo, branch, done):
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
        refuse("STANDARD_ARGUMENTS_INVALID: name")
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


def settle(ws, meta, dest_fd, name, relative, kind, pending, record):
    """Make a placed file read-only, checksum it, register it and record provenance. A retry after
    an interruption (the tool's time limit, a failed registration) resumes here from the pending
    record written before the move, instead of finding the destination taken."""
    placed = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dest_fd)
    try:
        info = os.fstat(placed)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or (info.st_dev, info.st_ino) != (record["dev"], record["ino"]):
            refuse("STANDARD_INPUT_CHANGED")
        os.fchmod(placed, 0o400)
        digest = sha256_fd(placed)
        size = os.fstat(placed).st_size
    finally:
        os.close(placed)
    # A take killed at the tool's time limit can leave its registration finishing on its own:
    # then the registry already holds exactly these bytes, and the retry adopts that record.
    existing = find_registered(ws, relative)
    if existing and (existing["sha256"], existing["bytes"]) != (digest, size):
        refuse("STANDARD_INPUT_CHANGED")
    input_id = existing["id"] if existing else register(ws, meta, relative, digest, size, kind)
    ws.append("provenance.jsonl", dict(record["provenance"], at=now(), input_id=input_id, path=relative, sha256=digest, bytes=size, type=kind))
    pending.unlink()
    return {"input_id": input_id, "path": relative, "sha256": digest, "bytes": size, "type": kind}


def pending_for(ws, relative):
    return ws.data_dir("pending") / (hashlib.sha256(relative.encode("utf-8")).hexdigest()[:32] + ".json")


def move_in(ws, meta, src_root, parts, dest_fd, name, relative, kind, provenance, owner_check=True, inode=None):
    """Move one regular file into place, then settle it; resume a pending move of the same file."""
    pending = pending_for(ws, relative)
    record = ws.read_json(pending, None)
    if record:
        try:
            os.stat(name, dir_fd=dest_fd, follow_symlinks=False)
        except FileNotFoundError:
            pending.unlink()  # interrupted before the move: start again
        else:
            return dict(settle(ws, meta, dest_fd, name, relative, kind, pending, record), how="resumed")
    fd, info = open_regular(src_root, parts)
    parent = walk_dirs(src_root, parts[:-1])
    try:
        if inode is not None and info.st_ino != inode:  # swapped since its label was checked
            refuse("STANDARD_DELIVERY_UNLABELLED: the file changed")
        if info.st_nlink != 1 or (owner_check and info.st_uid != os.getuid()):
            # Not yet handed to the account (run `silo intake` as root) or linked elsewhere.
            refuse("STANDARD_PATH_INVALID")
        if ws.chat and info.st_size > MAX_TOOL_INPUT:
            refuse("STANDARD_INPUT_TOO_LARGE_FOR_TOOL")
        try:
            os.stat(name, dir_fd=dest_fd, follow_symlinks=False)
            refuse("STANDARD_INPUT_EXISTS")
        except FileNotFoundError:
            pass
        record = {"dev": info.st_dev, "ino": info.st_ino, "provenance": provenance}
        ws.write_json(pending, record)
        try:
            placed, how = place(ws, fd, parent, parts[-1], dest_fd, name)
        except BaseException:
            pending.unlink()
            raise
        new = os.fstat(placed)
        os.close(placed)
        if (new.st_dev, new.st_ino) != (record["dev"], record["ino"]):  # a copy across filesystems
            record.update(dev=new.st_dev, ino=new.st_ino)
            ws.write_json(pending, record)
    finally:
        os.close(fd)
        os.close(parent)
    record["provenance"]["how"] = how
    ws.write_json(pending, record)
    return dict(settle(ws, meta, dest_fd, name, relative, kind, pending, record), how=how)


# -- deliveries: which data is for what ---------------------------------------------------------
# One set of files received together, with a purpose only the engineer can set. Each is its own
# dataset. The record is kept beside the workspace's registry rather than in it, so that a rollback
# to a release that doesn't know about deliveries can still read the registry.

DELIVERY_KINDS = ("development", "launch", "base_site")
MAX_LABELLED_BY = 120
MAX_DROP_FILES = 10000
SHOWN_FILES = 200
# What makes a dropped file the one that was labelled. Times and inode as strings: the page's
# JavaScript can't hold them as numbers. Changing, replacing or re-copying a file changes these.
IDENTITY = ("path", "bytes", "mtime_ns", "ctime_ns", "ino")


def deliveries_file(ws):
    return ws.root / ".silo-migrate/named/deliveries.json"


def read_deliveries(ws):
    """{dataset_id: record}. Nothing here is written by an agent."""
    path = deliveries_file(ws)
    if path.is_symlink() or path.parent.is_symlink():
        refuse("STANDARD_PATH_INVALID")
    document = ws.read_json(path, {})
    records = document.get("deliveries") if isinstance(document, dict) else None
    return {key: value for key, value in records.items() if isinstance(value, dict)} if isinstance(records, dict) else {}


def write_deliveries(ws, records):
    ws.write_json(deliveries_file(ws), {"version": 1, "deliveries": records})


def delivery_label(record):
    return ("Base site v%d" % record["version"] if record["kind"] == "base_site" else
            "Development v%d" % record["version"] if record["kind"] == "development" else "Launch")


def drop_listing(ws):
    """Regular files in the drop folder. `ready` is false until `silo intake` has handed a file to this
    account, or when its name can't be shown; such files can't be labelled."""
    if not ws.intake.is_dir() or ws.intake.is_symlink():
        return []
    files = []
    for folder, _dirs, names, dirfd in os.fwalk(str(ws.intake), follow_symlinks=False):
        for name in names:
            info = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
            if not stat.S_ISREG(info.st_mode):
                continue
            relative = os.path.relpath(os.path.join(folder, name), str(ws.intake))
            try:
                relative.encode("utf-8")
                readable = True
            except UnicodeEncodeError:
                relative, readable = relative.encode("utf-8", "surrogateescape").decode("utf-8", "replace"), False
            files.append({"path": relative, "bytes": info.st_size, "mtime_ns": str(info.st_mtime_ns), "ctime_ns": str(info.st_ctime_ns),
                          "ino": str(info.st_ino), "ready": readable and info.st_uid == os.getuid() and info.st_nlink == 1})
            if len(files) >= MAX_DROP_FILES:
                return sorted(files, key=lambda item: item["path"])
    return sorted(files, key=lambda item: item["path"])


def claim(records, item):
    """(dataset_id, file entry) of the delivery holding exactly this file, or (None, None). A replaced
    delivery holds nothing any more, and a file already taken can't be claimed again."""
    for dataset_id, record in records.items():
        if record.get("replaced_by"):
            continue
        for entry in record.get("files") or []:
            if not entry.get("taken") and all(entry.get(key) == item.get(key) for key in IDENTITY):
                return dataset_id, entry
    return None, None


def split_drop_files(ws, records):
    """Every file in the drop folder, by what's needed next."""
    groups = {"labelled": [], "unlabelled": [], "refused": [], "not_ready": []}
    role_state = file_roles.load(ws, roles_api()) if ws.initialized() else None
    for item in drop_listing(ws):
        assignment = next((f for f in role_state["files"].values() if f.get("identity") == {key: item[key] for key in IDENTITY}), None) if role_state else None
        if assignment and assignment["role"] in ("reference", "uploads"):
            continue
        dataset, entry = file_roles.effective_claim(ws, records, item, roles_api())
        if entry and entry.get("refused"):
            groups["refused"].append(dict(item, refused=entry["refused"], delivery=delivery_label(records[dataset])))
        elif entry:
            groups["labelled"].append(dict(item, delivery=delivery_label(records[dataset])))
        elif item["ready"]:
            groups["unlabelled"].append(item)
        else:
            groups["not_ready"].append(item)
    return groups


def unlabelled_data(ws, records):
    """Datasets already holding files but never labelled: anything taken before labels existed."""
    state = ws.named_state()
    holding = {record.get("dataset_id") for record in (state.get("inputs") or {}).values()}
    return [dataset_id for dataset_id in (state.get("datasets") or {}) if dataset_id in holding and dataset_id not in records]


def delivery_of_take(ws, root, parts, dest_fd, name, relative):
    """(dataset, inode) for a take. Only the engineer's label makes a file takeable."""
    pending = ws.read_json(pending_for(ws, relative), None)
    if pending:
        try:
            os.stat(name, dir_fd=dest_fd, follow_symlinks=False)
            placed = True
        except FileNotFoundError:
            placed = False
        dataset = (pending.get("provenance") or {}).get("dataset_id")
        if placed:  # finishing an interrupted take of a file already moved: already decided
            if not dataset:
                refuse("STANDARD_DELIVERY_UNLABELLED: a take from before labels was interrupted; ask the engineer")
            return dataset, None
    records = read_deliveries(ws)
    fd, info = open_regular(root, parts)
    try:
        item = {"path": "/".join(parts), "bytes": info.st_size, "mtime_ns": str(info.st_mtime_ns), "ctime_ns": str(info.st_ctime_ns), "ino": str(info.st_ino)}
        dataset, entry = file_roles.effective_claim(ws, records, item, roles_api())
        if dataset is None:
            refuse("STANDARD_DELIVERY_UNLABELLED: the engineer labels new files on the Project page")
        if entry.get("refused"):
            refuse(entry["refused"])
        if records[dataset]["kind"] != "base_site":
            file_roles.source_checks(ws, [item], roles_api())
        refuse_if_copy_of_other_kind(ws, records, records[dataset]["kind"], fd, info, entry)
    finally:
        os.close(fd)
    return dataset, info.st_ino


def refuse_if_copy_of_other_kind(ws, records, kind, fd, info, entry):
    """Development and launch data that are byte-for-byte the same is almost certainly the wrong
    file. Only files of the same size are hashed, so this costs nothing in the normal case. The
    refusal is kept on the file, so the guide asks the engineer to remove it."""
    if kind == "base_site":
        return
    other = {dataset_id for dataset_id, record in records.items() if record["kind"] not in (kind, "base_site")}
    candidates = [record for record in (ws.named_state().get("inputs") or {}).values()
                  if record.get("dataset_id") in other and record.get("bytes") == info.st_size]
    if candidates:
        os.lseek(fd, 0, os.SEEK_SET)
        digest = sha256_fd(fd)
        if any(record.get("sha256") == digest for record in candidates):
            code = "STANDARD_DELIVERY_SAME_AS_DEVELOPMENT" if kind == "launch" else "STANDARD_DELIVERY_SAME_AS_LAUNCH"
            entry["refused"] = code
            write_deliveries(ws, records)
            refuse(code)


def mark_taken(ws, dataset, relative_drop, input_id):
    records = read_deliveries(ws)
    for entry in (records.get(dataset) or {}).get("files") or []:
        if entry.get("path") == relative_drop and not entry.get("taken"):
            entry["taken"] = input_id
            write_deliveries(ws, records)
            return


def job_delivery(ws, request):
    """The one delivery a job reads, and the files of it to mount. Its outputs belong to it."""
    records = read_deliveries(ws)
    if not records and not (ws.data / "file-roles.json").exists():  # pre-role compatibility only
        return None, None
    wanted = request.get("delivery")
    roles = file_roles.load(ws, roles_api())
    if wanted is None and (ws.data / "file-roles.json").exists():
        wanted = roles["active"].get("development")
        if wanted is None:
            refuse("STANDARD_FILE_ROLES_NO_ACTIVE_SOURCE")
    if wanted is None and all(record.get("kind") == "base_site" for record in records.values()):
        # A Base site label must not switch pre-label source-data jobs into labelled mode,
        # nor add the sandbox to their old whole-inputs mount.
        datasets = {item.get("dataset_id") for item in (ws.named_state().get("inputs") or {}).values()
                    if item.get("dataset_id") not in records}
        return None, [mount for dataset in datasets for mount in delivery_mounts(ws, dataset)]
    if wanted is None:
        holding = {record.get("dataset_id") for record in (ws.named_state().get("inputs") or {}).values()}
        candidates = [dataset_id for dataset_id in records if dataset_id in holding and records[dataset_id].get("kind") != "base_site" and not records[dataset_id].get("replaced_by")]
        if len(candidates) != 1:
            refuse("STANDARD_ARGUMENTS_INVALID: delivery (this project has more than one: give the dataset_id from data_guide)")
        wanted = candidates[0]
    if not isinstance(wanted, str) or wanted not in records or not file_roles.dataset_eligible(ws, wanted, roles_api()):
        refuse("STANDARD_ARGUMENTS_INVALID: delivery")
    if records[wanted].get("kind") not in ("development", "launch") or (roles["snapshots"].get(wanted) or {}).get("kind") not in ("development", "launch"):
        refuse("STANDARD_BASE_SITE_ROLE: Base backups are available only to the dedicated review/merge workflow, not source-data jobs")
    return wanted, delivery_mounts(ws, wanted)


def delivery_mounts(ws, dataset_id):
    """Read-only mounts of exactly this delivery's registered inputs, at their usual places under /in."""
    mounts = []
    roles = file_roles.load(ws, roles_api())
    for input_id, record in (ws.named_state().get("inputs") or {}).items():
        assigned = next((item for item in roles["files"].values() if item.get("input_id") == input_id), None)
        effective = assigned.get("dataset_id") if assigned else record.get("dataset_id")
        if effective == dataset_id and (not assigned or assigned["role"] == "source"):
            relative = base64.b64decode(record["path"]).decode("utf-8")
            parts = parts_of(relative)
            if parts[0] != "inputs" or len(parts) < 2:
                refuse("STANDARD_PATH_INVALID")
            mounts.append((ws.root.joinpath(*parts), "/in/" + "/".join(parts[1:])))
    return mounts


def engineer_only(ws):
    # Agents have no mapping to these operations. This is a second lock on the same door.
    if ws.chat:
        refuse("STANDARD_DATA_OPERATION_REFUSED")


def delivery_summary(record):
    files = record.get("files") or []
    return dict({key: record.get(key) for key in ("dataset_id", "kind", "version", "sequence", "labelled_at", "labelled_by", "replaced_by")},
                label=delivery_label(record), files=files[:5], file_count=len(files))


def setup_view(ws):
    """For the Files tab's Create workspace card: whether every step of op_create is done, and the
    platform once it is set (it can't change afterwards)."""
    meta = ws.meta() if ws.initialized() else {}
    complete = bool(meta.get("source_id") and meta.get("dataset_id") and (ws.root / "converter").exists()
                    and (ws.root / ".silo-migrate/named/standard/state.json").is_file())
    return {"complete": complete, "platform": meta.get("platform")}


def op_deliveries(ws, request):
    """The engineer's view for the Project page. It holds file names, so it never reaches a chat."""
    engineer_only(ws)
    empty = {"initialized": False, "setup": setup_view(ws), "deliveries": [], "unlabelled_data": []}
    if not ws.initialized():
        listing = drop_listing(ws)
        return dict(empty, unlabelled_files=[item for item in listing if item["ready"]][:SHOWN_FILES], labelled_files=[], refused_files=[],
                    not_ready_files=[item for item in listing if not item["ready"]][:SHOWN_FILES])
    with ws.lock():
        role_state = file_roles.load(ws, roles_api(), persist=True)
    records = read_deliveries(ws)
    groups = split_drop_files(ws, records)
    ordered = sorted(records.values(), key=lambda record: record.get("sequence", 0), reverse=True)
    return {"initialized": True, "setup": setup_view(ws), "roles": file_roles.view(role_state), "deliveries": [delivery_summary(record) for record in ordered],
            "unlabelled_files": groups["unlabelled"][:SHOWN_FILES], "labelled_files": groups["labelled"][:SHOWN_FILES],
            "refused_files": groups["refused"][:SHOWN_FILES], "not_ready_files": groups["not_ready"][:SHOWN_FILES],
            "counts": {key: len(value) for key, value in groups.items()}, "unlabelled_data": unlabelled_data(ws, records)}


# Path-based import also works under Python -I (bin is not on sys.path).
import importlib.util
_version_spec = importlib.util.spec_from_file_location("discourse_version", Path(__file__).with_name("discourse_version.py"))
discourse_version = importlib.util.module_from_spec(_version_spec)
_version_spec.loader.exec_module(discourse_version)
BASE_SITE_NAME = discourse_version.backup_pattern()
# A merge project: the source is another Discourse site, given as its full backup (with uploads).
MERGE_PLATFORM = "discourse"
MERGE_SOURCE_TYPE = "discourse-backup"
MERGE_SETTINGS_TYPE = "merge-settings"
DISCOURSE_BACKUP_NAME = discourse_version.backup_pattern("tar.gz")


def validate_base_site(ws, files):
    if len(files) != 1:
        refuse("STANDARD_BASE_SITE_INVALID: select exactly one SQL-only Discourse backup")
    parts = parts_of(files[0]["path"])
    versions = discourse_version.backup(parts[-1])
    if not versions:
        refuse("STANDARD_BASE_SITE_INVALID: keep the original backup name and take it without uploads (discourse backup --sql-only)")
    root = ws.open_area("intake")
    try:
        fd, info = open_regular(root, parts)
        try:
            identity = {"path": "/".join(parts), "bytes": info.st_size, "mtime_ns": str(info.st_mtime_ns),
                        "ctime_ns": str(info.st_ctime_ns), "ino": str(info.st_ino)}
            if (info.st_uid != os.getuid() or info.st_nlink != 1
                    or any(identity[key] != files[0].get(key) for key in IDENTITY) or os.read(fd, 2) != b"\x1f\x8b"):
                refuse("STANDARD_BASE_SITE_INVALID: not an unchanged gzip SQL-only backup")
        finally:
            os.close(fd)
    finally:
        os.close(root)
    return {"filename": True, "gzip": True, "sql_only_name": True, "discourse_version": versions["discourse_version"]}


def op_delivery_label(ws, request, *, held_lock=False, sync_roles=True, auto_take=True):
    """Set what a delivery is for. Engineer only, from the Project page. A label never changes."""
    engineer_only(ws)
    if not held_lock and ws.initialized() and (ws.root / ".silo-migrate/named/standard").is_dir():
        with file_roles.locks(ws, roles_api()):
            roles = file_roles.load(ws, roles_api(), persist=True)
            if request.get("kind") in ("base_site", "launch"):
                affected = roles["active"].get(request["kind"])
                if affected and file_roles.dependencies(ws, [affected], [], roles_api())[0]["active"]:
                    refuse("STANDARD_FILE_ROLES_ACTIVE_DEPENDENCY")
            return op_delivery_label(ws, request, held_lock=True, sync_roles=sync_roles, auto_take=auto_take)
    kind, by = request.get("kind"), request.get("by")
    if kind not in DELIVERY_KINDS:
        refuse("STANDARD_ARGUMENTS_INVALID: kind")
    if not isinstance(by, str) or not by.strip() or len(by) > MAX_LABELLED_BY or re.search(r"[\x00-\x1f]", by):
        refuse("STANDARD_ARGUMENTS_INVALID: by")
    if kind == "launch" and request.get("confirm") != "LAUNCH":
        refuse("STANDARD_DELIVERY_CONFIRM_LAUNCH")
    if not ws.initialized():
        if kind != "base_site":
            refuse("STANDARD_NOT_INITIALIZED")
        wanted = request.get("files")
        if not isinstance(wanted, list) or not all(isinstance(item, dict) for item in wanted):
            refuse("STANDARD_BASE_SITE_INVALID: select exactly one SQL-only Discourse backup")
        validate_base_site(ws, wanted)  # before even creating the named workspace
        ws.control(["named", "init", ws.name])
    with nullcontext() if held_lock else ws.lock():
        records, meta = read_deliveries(ws), ws.meta()
        same_kind = [record for record in records.values() if record["kind"] == kind]
        current_launch = [record for record in same_kind if kind == "launch" and not record.get("replaced_by")]
        if current_launch and request.get("replaces_launch") is not True:
            refuse("STANDARD_DELIVERY_LAUNCH_EXISTS")
        state = ws.named_state()
        untagged = [dataset_id for dataset_id in (state.get("datasets") or {}) if dataset_id not in records]
        holding = set(unlabelled_data(ws, records))
        files = []
        if "dataset_id" in request:  # data taken before labels existed
            dataset_id = request["dataset_id"]
            if kind != "development" or dataset_id not in holding or "files" in request:
                refuse("STANDARD_ARGUMENTS_INVALID: dataset_id")
            file_roles.snapshot_checks(ws, file_roles.load(ws, roles_api()), dataset_id, roles_api())
        else:
            if holding and kind != "base_site":
                refuse("STANDARD_DELIVERY_LABEL_EXISTING_FIRST")
            wanted = request.get("files")
            if not isinstance(wanted, list) or not wanted or not all(isinstance(item, dict) for item in wanted):
                refuse("STANDARD_ARGUMENTS_INVALID: files")
            current = {item["path"]: item for item in split_drop_files(ws, records)["unlabelled"]}
            for item in wanted:
                seen = current.get(item.get("path"))
                if not seen or any(seen[key] != item.get(key) for key in IDENTITY):
                    refuse("STANDARD_DELIVERY_FILES_CHANGED: the files changed since the page loaded")
            files = [{key: current[item["path"]][key] for key in IDENTITY} for item in wanted]
            checks = validate_base_site(ws, files) if kind == "base_site" else None
            if kind != "base_site":
                file_roles.source_checks(ws, files, roles_api())
            if kind != "base_site" and untagged and not any(record.get("dataset_id") == untagged[0] for record in (state.get("inputs") or {}).values()):
                dataset_id = untagged[0]
            else:
                source_id = meta.get("source_id")
                if not source_id and kind == "base_site":
                    source_id = json.loads(ws.control(["named", "source", "add", ws.name, "--platform", "discourse"]))["source_id"]
                if not source_id:
                    refuse("STANDARD_NOT_INITIALIZED")
                dataset_id = json.loads(ws.control(["named", "dataset", "add", ws.name, "--source", source_id, "--label", kind]))["dataset_id"]
        version = 1 + max((record["version"] for record in same_kind), default=0)
        record = {"dataset_id": dataset_id, "kind": kind, "version": version, "labelled_at": now(), "labelled_by": by.strip(), "files": files,
                  "sequence": 1 + max((record.get("sequence", 0) for record in records.values()), default=0)}
        for old in ([r for r in same_kind if not r.get("replaced_by")] if kind == "base_site" else current_launch):  # its files, labelled but not taken, can't be taken any more
            old["replaced_by"] = dataset_id
        records[dataset_id] = record
        write_deliveries(ws, records)
        if sync_roles:
            file_roles.sync_label(ws, dataset_id, roles_api())
    result = {"dataset_id": dataset_id, "kind": kind, "delivery": delivery_label(record), "files": len(files)}
    if kind == "base_site":
        result["checks"] = checks
        if auto_take and (ws.root / ".silo-migrate/named/standard/state.json").is_file():
            result["input"] = op_take(ws, {"path": files[0]["path"], "type": "base_site"}, held_lock=held_lock)
    return result


# -- findings the engineer marks done ---------------------------------------------------------
# A released finding is done when a pass on its fix passes, or when the engineer says it needed no
# converter change (or was fixed before fixes were linked to findings). Only the second is stored.

def finding_marks_file(ws):
    return ws.root / ".silo-migrate/named/finding-progress.json"


def op_finding_done(ws, request):
    engineer_only(ws)
    ws.require()
    finding_id, by = request.get("finding_id"), request.get("by")
    if not isinstance(finding_id, str) or not re.fullmatch(r"finding-[0-9a-f]{32}", finding_id):
        refuse("STANDARD_ARGUMENTS_INVALID: finding_id")
    if not isinstance(by, str) or not by.strip() or len(by) > MAX_LABELLED_BY or re.search(r"[\x00-\x1f]", by):
        refuse("STANDARD_ARGUMENTS_INVALID: by")
    with ws.lock():
        state = ws.read_json(ws.root / ".silo-migrate/named/standard/state.json", {}) or {}
        # Marking needs a released finding; taking a mark back works whatever became of it since.
        if request.get("undo") is not True and ((state.get("findings") or {}).get(finding_id) or {}).get("status") != "released":
            refuse("STANDARD_ARGUMENTS_INVALID: finding_id (only a released finding)")
        path = finding_marks_file(ws)
        if path.is_symlink():
            refuse("STANDARD_PATH_INVALID")
        marks = (ws.read_json(path, {}) or {}).get("done") or {}
        if request.get("undo") is True:
            marks.pop(finding_id, None)
        else:
            marks[finding_id] = {"by": by.strip(), "at": now()}
        ws.write_json(path, {"version": 1, "done": marks})
    return {"finding_id": finding_id, "done": finding_id in marks}


# -- site reviews: the engineer's verdict on a review site -------------------------------------
# Accepting a passing import's site freezes the process that made it (data, converter, settings,
# checks, Discourse): the "accepted process" that launch repeats. Only an acceptance on the
# customer's approval counts for that; the engineer's own check is recorded and shown. "Needs
# changes" keeps a short note for migration-data. Kept beside the registry, written only from the
# Project page (no agent tool maps to these), append-only: a withdrawal is a new entry.

SITE_VERDICTS = ("accepted", "needs_changes", "withdrawn")
SITE_BASES = ("customer", "engineer")
MAX_SITE_NOTE = 2000
MAX_SITE_REVIEWS = 2000


def site_reviews_file(ws):
    return ws.root / ".silo-migrate/named/site-reviews.json"


def read_site_reviews(ws):
    path = site_reviews_file(ws)
    if path.is_symlink() or path.parent.is_symlink():
        refuse("STANDARD_PATH_INVALID")
    document = ws.read_json(path, {}) if ws.initialized() else {}
    reviews = document.get("reviews") if isinstance(document, dict) else None
    return [entry for entry in reviews if isinstance(entry, dict)] if isinstance(reviews, list) else []


def standard_state(ws):
    path = ws.root / ".silo-migrate/named/standard/state.json"
    if path.is_symlink() or path.parent.is_symlink() or not path.is_file():
        refuse("STANDARD_NOT_INITIALIZED")
    state = ws.read_json(path, {})
    return state if isinstance(state, dict) else {}


def run_passed(run):
    results = (run or {}).get("results") or {}
    checks = results.get("reconciliation_checks") or 0
    return (run or {}).get("status") == "completed" and checks > 0 and results.get("reconciliation_matched") == checks


def site_process(state, run_id):
    """(process, digest, passed) of a review run: what accepting its site freezes. IDs, hashes and
    counts only, never file names or customer values."""
    if not isinstance(run_id, str) or not RUN.fullmatch(run_id):
        refuse("STANDARD_ARGUMENTS_INVALID: run_id")
    runs = state.get("runs") if isinstance(state.get("runs"), dict) else {}
    plans = state.get("plans") if isinstance(state.get("plans"), dict) else {}
    run = runs.get(run_id)
    plan = plans.get((run or {}).get("plan_id")) or {}
    body = plan.get("body") or {}
    if not run:
        refuse("STANDARD_REFERENCE_INVALID")
    if body.get("operation") != "standard_review":
        refuse("STANDARD_SITE_NOT_REVIEW: only an import into a review site can be accepted")
    convert_run_id = (body.get("from_run") or {}).get("run_id")
    convert_run = runs.get(convert_run_id) or {}
    convert_plan = plans.get(convert_run.get("plan_id")) or {}
    convert_body = convert_plan.get("body") or {}

    def bound(source, role):
        input_id = (source.get("roles") or {}).get(role)
        found = next((item for item in source.get("input_binding") or [] if isinstance(item, dict) and item.get("id") == input_id), None)
        return {"id": input_id, "sha256": found.get("sha256")} if input_id and found else None

    def counts(record):
        results = (record or {}).get("results") or {}
        return {"checks": results.get("reconciliation_checks") or 0, "matched": results.get("reconciliation_matched") or 0}

    delivery = body.get("delivery") if isinstance(body.get("delivery"), dict) else {}
    converter = convert_body.get("converter") if isinstance(convert_body.get("converter"), dict) else {}
    process = {
        "run_id": run_id, "plan_id": run.get("plan_id"), "plan_digest": plan.get("digest"),
        "convert_run_id": convert_run_id, "convert_plan_id": convert_run.get("plan_id"), "convert_plan_digest": convert_plan.get("digest"),
        "delivery": {key: delivery.get(key) for key in ("dataset_id", "kind", "version")},
        "converter": {"revision": convert_body.get("converter_revision"), "branch": converter.get("branch"), "repository": converter.get("repo") or converter.get("repository")},
        "source": bound(convert_body, "source"), "settings": bound(convert_body, "settings"),
        "checks": {"convert": bound(convert_body, "reconciliation"), "import": bound(body, "reconciliation")},
        "charset": convert_body.get("source_charset"),
        "discourse_profile": body.get("discourse_profile"), "runtime_lock_sha256": body.get("runtime_lock_sha256"),
        "results": {"convert": counts(convert_run), "import": counts(run)},
    }
    digest = hashlib.sha256(json.dumps(process, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
    return process, digest, run_passed(run) and run_passed(convert_run)


def site_entry_summary(entry):
    process = entry.get("process") or {}
    delivery = process.get("delivery") or {}
    return {"id": entry.get("id"), "run_id": entry.get("run_id"), "verdict": entry.get("verdict"), "basis": entry.get("basis"),
            "by": entry.get("by"), "at": entry.get("at"), "note": entry.get("note"),
            "data": ("Development v%s" % delivery.get("version")) if delivery.get("kind") == "development" else delivery.get("kind"),
            "converter": (process.get("converter") or {}).get("revision"), "process": process or None}


def site_verdicts(reviews):
    """{run_id: entry}: each run's latest verdict (accepted or needs changes), unless that acceptance was
    withdrawn. The Project page's board.site_verdicts reads the record the same way (a test keeps them equal)."""
    withdrawn = {entry.get("of") for entry in reviews if entry.get("verdict") == "withdrawn"}
    latest = {}
    for entry in reviews:
        if entry.get("verdict") in ("accepted", "needs_changes"):
            latest[entry.get("run_id")] = entry
    return {run_id: entry for run_id, entry in latest.items() if entry.get("id") not in withdrawn}


def current_acceptance(reviews, verdicts=None):
    """The accepted process: the newest acceptance on the customer's approval, while it is still its
    run's verdict. Never an older one (board.current_acceptance matches it)."""
    verdicts = site_verdicts(reviews) if verdicts is None else verdicts
    newest = next((entry for entry in reversed(reviews) if entry.get("verdict") == "accepted" and entry.get("basis") == "customer"), None)
    return newest if newest and verdicts.get(newest.get("run_id")) is newest else None


def site_summary(ws, state=None, deliveries=None, *, records=None):
    """The current acceptance (the customer's, which launch repeats), the engineer's own latest check,
    the latest verdict per run, and what changed since the acceptance. Cached public
    records avoid a second status read; callers holding operation locks must supply
    that projection rather than initiating a Ruby control call here."""
    reviews = read_site_reviews(ws)
    current = site_verdicts(reviews)
    # The accepted process is the newest acceptance on the customer's approval. Once that one is
    # withdrawn (or its run has a later verdict), nothing is accepted: an older one never comes back.
    accepted = current_acceptance(reviews, current)
    own = next((entry for entry in reversed(reviews) if entry.get("verdict") == "accepted" and entry.get("basis") == "engineer"), None)
    checked = own if own and current.get(own.get("run_id")) is own else None
    by_run = {run_id: site_entry_summary(entry) for run_id, entry in current.items()}
    changed = []
    accepted_lineage_current = None
    if accepted:
        process = accepted.get("process") or {}
        state = state if state is not None else standard_state(ws)
        current = ((state.get("config") or {}).get("converter_revision"))
        was = (process.get("converter") or {}).get("revision")
        if current and was and current != was:
            changed.append("converter %s → %s" % (was[:7], current[:7]))
        deliveries = deliveries if deliveries is not None else read_deliveries(ws)
        newest = [record for record in sorted(deliveries.values(), key=lambda record: record.get("sequence", 0))
                  if record.get("kind") == "development" and not record.get("replaced_by")]
        accepted_data = (process.get("delivery") or {}).get("dataset_id")
        if (ws.data / "file-roles.json").exists():
            active_dataset = file_roles.load(ws, roles_api())["active"].get("development")
            current_delivery = deliveries.get(active_dataset)
            if accepted_data and active_dataset != accepted_data:
                current_label = delivery_label(current_delivery) if current_delivery else "no current source"
                changed.append("data Development v%s → %s" % ((process.get("delivery") or {}).get("version"), current_label))
        elif newest and accepted_data and newest[-1].get("dataset_id") != accepted_data:
            changed.append("data Development v%s → Development v%s" % ((process.get("delivery") or {}).get("version"), newest[-1].get("version")))
        profile = (state.get("config") or {}).get("discourse_profile")
        if profile and process.get("discourse_profile") and profile != process.get("discourse_profile"):
            changed.append("Discourse %s → %s" % (process.get("discourse_profile"), profile))
        records = guide_records(ws) if records is None else records
        plans = {plan["plan_id"]: plan for plan in records["plans"]}
        accepted_run = next((run for run in records["runs"] if run.get("run_id") == accepted.get("run_id")), {})
        accepted_lineage_current = accepted_run.get("file_role_lineage_current", True) is True and all(
            plans.get(plan_id, {}).get("file_role_lineage_current", True) is True
            for plan_id in (accepted_run.get("plan_id"), process.get("plan_id"), process.get("convert_plan_id")))
        if not accepted_lineage_current:
            changed.append("input set changed since acceptance; prepare a fresh conversion/merge and review")
    return {"accepted": site_entry_summary(accepted) if accepted else None, "checked": site_entry_summary(checked) if checked else None,
            "by_run": by_run, "changed": changed, "accepted_lineage_current": accepted_lineage_current}


def site_note(request, required):
    note = request.get("note")
    if note is None or note == "":
        if required:
            refuse("STANDARD_ARGUMENTS_INVALID: note (say what needs changing)")
        return None
    if not isinstance(note, str) or len(note) > MAX_SITE_NOTE or re.search(r"[\x00-\x08\x0b-\x1f\x7f\u202a-\u202e\u2066-\u2069]", note) or not note.strip():
        refuse("STANDARD_ARGUMENTS_INVALID: note")
    return note.strip()


def op_site_process(ws, request):
    """What accepting a review run's site would freeze, and whether it can be accepted. Engineer only."""
    engineer_only(ws)
    ws.require()
    process, digest, passed = site_process(standard_state(ws), request.get("run_id"))
    delivery = process["delivery"]
    reason = None
    if not passed:
        reason = "only a site whose convert and import runs both matched every check can be accepted"
    elif delivery.get("kind") != "development":
        reason = "only a site built from development data can be accepted"
    return {"process": process, "process_digest": digest, "can_accept": reason is None, "reason": reason,
            "current": site_summary(ws)["by_run"].get(process["run_id"])}


def op_site_review(ws, request):
    """Accept a review site, say it needs changes, or withdraw an acceptance. Engineer only, from the
    Project page; an acceptance names the exact process the engineer was shown (process_digest)."""
    engineer_only(ws)
    ws.require()
    verdict, by = request.get("verdict"), request.get("by")
    if verdict not in SITE_VERDICTS:
        refuse("STANDARD_ARGUMENTS_INVALID: verdict")
    if not isinstance(by, str) or not by.strip() or len(by) > MAX_LABELLED_BY or re.search(r"[\x00-\x1f]", by):
        refuse("STANDARD_ARGUMENTS_INVALID: by")
    with ws.lock():
        reviews = read_site_reviews(ws)
        if len(reviews) >= MAX_SITE_REVIEWS:
            refuse("STANDARD_ARGUMENTS_INVALID: too many site reviews in this project")
        entry = {"id": "review-" + secrets.token_hex(8), "verdict": verdict, "by": by.strip(), "at": now()}
        if verdict == "withdrawn":
            target = request.get("review_id")
            found = next((item for item in reviews if item.get("id") == target and item.get("verdict") == "accepted"), None)
            # Only an acceptance that is still its run's verdict: not withdrawn, not replaced by a later one.
            if not isinstance(target, str) or not found or site_verdicts(reviews).get(found.get("run_id")) is not found:
                refuse("STANDARD_ARGUMENTS_INVALID: review_id (only an acceptance that stands can be withdrawn)")
            entry.update(of=target, run_id=found.get("run_id"))
        else:
            state = standard_state(ws)
            process, digest, passed = site_process(state, request.get("run_id"))
            standing = current_acceptance(reviews)
            if standing and standing.get("run_id") == process["run_id"]:
                refuse("STANDARD_SITE_ACCEPTED: this site's acceptance stands; withdraw it first (on the Overview)")
            run = (state.get("runs") or {}).get(process["run_id"]) or {}
            if run.get("status") != "completed":
                refuse("STANDARD_SITE_NOT_FINISHED: the import hasn't finished")
            entry.update(run_id=process["run_id"], note=site_note(request, verdict == "needs_changes"))
            if verdict == "accepted":
                if request.get("basis") not in SITE_BASES:
                    refuse("STANDARD_ARGUMENTS_INVALID: basis")
                if not passed:
                    refuse("STANDARD_SITE_NOT_PASSED: only a site whose convert and import runs both matched every check can be accepted")
                if process["delivery"].get("kind") != "development":
                    refuse("STANDARD_SITE_NOT_PASSED: only a site built from development data can be accepted")
                # The engineer accepts exactly what the page showed; anything changed since is refused.
                if request.get("process_digest") != digest:
                    refuse("STANDARD_APPROVAL_MISMATCH")
                entry.update(basis=request["basis"], process=process, process_digest=digest)
        reviews.append(entry)
        path = site_reviews_file(ws)
        if path.is_symlink():
            refuse("STANDARD_PATH_INVALID")
        ws.write_json(path, {"version": 1, "reviews": reviews})
    try:
        site = site_summary(ws)
    except Refusal:
        site = None  # recorded; the page reads the rest again
    return {"review": site_entry_summary(entry), "site": site}


def completed_take(ws, root, inputs, parts, name, relative, kind):
    """Recover ONLY a completed registered take whose old intake path is absent.

    The named record, immutable destination, exact delivery, and existing take
    receipt must agree. This does not resume arbitrary named inputs or restore a
    corrected/ineligible assignment, and never creates a registration or version.
    Caller holds the standard state and data locks.
    """
    existing = find_registered(ws, relative)
    if not existing:
        return None
    try:
        source, _ = open_regular(root, parts)
    except Refusal as error:
        if str(error) != "STANDARD_PATH_MISSING":
            raise
    else:
        os.close(source)
        return None  # a fresh intake file must NOT be confused with the old take
    dataset = existing.get("dataset_id")
    record = read_deliveries(ws).get(dataset) or {}
    entry = next((entry for entry in record.get("files", []) if entry.get("path") == "/".join(parts)
                  and entry.get("taken") in (None, existing.get("id"))), None)
    if not entry or existing.get("type") != kind:
        refuse("STANDARD_INPUT_CHANGED")
    file_roles.take_allowed(ws, dataset, "/".join(parts), kind, roles_api())
    fd, info = open_regular(inputs, [name])
    try:
        if (info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o222
                or info.st_size != existing.get("bytes") or info.st_size != entry.get("bytes")
                or sha256_fd(fd) != existing.get("sha256")):
            refuse("STANDARD_INPUT_CHANGED")
    finally:
        os.close(fd)
    workspace = open_root(ws.root)
    try:
        receipt_fd, receipt_info = open_regular(workspace, [".silo-migrate", "data", "provenance.jsonl"])
        try:
            if (receipt_info.st_uid != os.getuid() or receipt_info.st_nlink != 1 or receipt_info.st_mode & 0o077
                    or receipt_info.st_size > file_roles.MAX_STATE):
                refuse("STANDARD_INPUT_CHANGED")
            receipts = [json.loads(line) for line in os.read(receipt_fd, file_roles.MAX_STATE + 1).splitlines()]
        except (ValueError, UnicodeError):
            refuse("STANDARD_INPUT_CHANGED")
        finally:
            os.close(receipt_fd)
    finally:
        os.close(workspace)
    if not any(isinstance(receipt, dict) and receipt.get("event") == "take"
               and receipt.get("from") == "intake/" + "/".join(parts) and receipt.get("path") == relative
               and receipt.get("dataset_id") == dataset and receipt.get("input_id") == existing.get("id")
               and receipt.get("sha256") == existing.get("sha256") and receipt.get("bytes") == existing.get("bytes")
               and receipt.get("type") == kind for receipt in receipts):
        refuse("STANDARD_INPUT_CHANGED")
    return dataset, {"input_id": existing["id"], "path": relative, "sha256": existing["sha256"],
                     "bytes": existing["bytes"], "type": kind, "how": "resumed"}


def op_take(ws, request, *, held_lock=False):
    """Move one file from the drop folder into inputs/, make it read-only, register it."""
    ws.require()
    if not held_lock:
        with file_roles.locks(ws, roles_api()):
            return op_take(ws, request, held_lock=True)
    parts = parts_of(request.get("path"))
    kind = request.get("type")
    if not isinstance(kind, str) or not TYPE.fullmatch(kind):
        refuse("STANDARD_ARGUMENTS_INVALID: type")
    name = dest_name(request.get("name"), parts[-1])
    with nullcontext() if held_lock else ws.lock():
        meta = ws.meta()
        # A labelled Base site supplies its own dataset, including in workspaces
        # created through the Ruby CLI without migration-data's default dataset.
        if not meta.get("dataset_id") and kind != "base_site":
            refuse("STANDARD_NOT_INITIALIZED")
        if kind == MERGE_SOURCE_TYPE:
            if meta.get("platform") != MERGE_PLATFORM:
                refuse("STANDARD_MERGE_SOURCE_INVALID: type discourse-backup is for a project whose source platform is discourse")
            if name != parts[-1] or not DISCOURSE_BACKUP_NAME.search(name):
                refuse("STANDARD_MERGE_SOURCE_INVALID: keep the backup's original name (it ends -v<version>.tar.gz); a merge needs the full backup with uploads")
        root, inputs = ws.open_area("intake"), None
        try:
            inputs = ws.open_area("inputs")
            pending = ws.read_json(pending_for(ws, "inputs/" + name), None)
            resumed = completed_take(ws, root, inputs, parts, name, "inputs/" + name, kind) if not pending else None
            if resumed:
                dataset, result = resumed
                inode = None
            else:
                dataset, inode = delivery_of_take(ws, root, parts, inputs, name, "inputs/" + name)
            file_roles.take_allowed(ws, dataset, "/".join(parts), kind, roles_api())
            base = (read_deliveries(ws).get(dataset) or {}).get("kind") == "base_site"
            if base != (kind == "base_site"):
                refuse("STANDARD_BASE_SITE_TYPE: Base site files must be taken as base_site; other deliveries cannot use that type")
            if not resumed:
                result = move_in(ws, dict(meta, dataset_id=dataset), root, parts, inputs, name, "inputs/" + name, kind,
                                 {"event": "take", "from": "intake/" + "/".join(parts), "dataset_id": dataset}, inode=inode)
            # A resumed take marks the file it started with, whatever path this call named.
            started_from = ((pending or {}).get("provenance") or {}).get("from") if inode is None else None
            mark_taken(ws, dataset, started_from.removeprefix("intake/") if started_from else "/".join(parts), result["input_id"])
            file_roles.sync_taken(ws, dataset, started_from.removeprefix("intake/") if started_from else "/".join(parts), result["input_id"], roles_api())
        finally:
            os.close(root)
            if inputs is not None:
                os.close(inputs)
    return dict(result, note="the original bytes are now read-only in inputs/; nothing was changed")


def op_register(ws, request):
    """Move a finished output file from work/ into inputs/derived/, read-only, registered with provenance."""
    ws.require()
    parts = parts_of(request.get("path"))
    kind = request.get("type")
    if not isinstance(kind, str) or not TYPE.fullmatch(kind) or len(parts) < 2 or not WORK_NAME.fullmatch(parts[0]):
        refuse("STANDARD_ARGUMENTS_INVALID: type or path")
    if kind == "base_site":
        refuse("STANDARD_BASE_SITE_TYPE: only the engineer can label an original Base site backup")
    name = dest_name(request.get("name"), parts[0] + "-" + parts[-1])
    with ws.lock():
        meta = ws.meta()
        jobs = refresh_jobs(ws)
        if any(job.get("into") == parts[0] and job.get("status") == "running" for job in jobs):
            refuse("STANDARD_BUSY")
        producer = next((job for job in reversed(jobs) if job.get("into") == parts[0]), None)
        # An output belongs to the delivery its job read, never to whichever was labelled last.
        records = read_deliveries(ws)
        dataset = producer.get("dataset_id") if producer else None
        role_state = file_roles.load(ws, roles_api())
        assignment = dataset if producer else meta.get("dataset_id")
        if ((records.get(assignment) or {}).get("kind") == "base_site"
                or (role_state["snapshots"].get(assignment) or {}).get("kind") == "base_site"):
            refuse("STANDARD_BASE_SITE_ROLE: an output from a Base backup job cannot become migration-derived input")
        if any(record.get("kind") != "base_site" for record in records.values()) or dataset in records:
            if dataset not in records:
                refuse("STANDARD_DELIVERY_UNLABELLED: this output's job didn't read one labelled delivery; run the job again")
            meta = dict(meta, dataset_id=dataset)
        root, inputs, derived = ws.open_area("work"), None, None
        try:
            inputs = ws.open_area("inputs")
            try:
                os.mkdir("derived", 0o700, dir_fd=inputs)
            except FileExistsError:
                pass
            derived = os.open("derived", DIR_FLAGS, dir_fd=inputs)
            result = move_in(ws, meta, root, parts, derived, name, "inputs/derived/" + name, kind,
                             {"event": "derived", "from": "work/" + "/".join(parts),
                              "job": producer and {key: producer.get(key) for key in ("id", "kind", "script_sha256", "inputs", "source", "references", "preparation_sha256")
                                          if key in producer or key in ("id", "kind", "script_sha256", "inputs", "source")}})
        finally:
            for fd in (root, inputs, derived):
                if fd is not None:
                    os.close(fd)
    return dict(result, produced_by=producer and producer.get("id"))


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
        refuse("STANDARD_ARGUMENTS_INVALID: timeout_minutes")
    return value


def work_dir(ws, into, fresh=True):
    if not isinstance(into, str) or not WORK_NAME.fullmatch(into):
        refuse("STANDARD_ARGUMENTS_INVALID: into")
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


def sandbox_argv(ws, name, out, extra_mounts, command, inputs=None):
    """No network, read-only root, this account's uid, no capabilities, bounded resources. `inputs`
    lists the files of one delivery to mount under /in; None mounts the whole folder (before labels)."""
    gems = ws.values.get("SILO_CONTROL_GEMS")
    argv = ["run", "-d", "--name", name, "--label", "silo.workspace=" + ws.name, "--label", "silo.role=data-job",
            "--pull=never", "--restart", "no", "--network", "none", "--read-only", "--user", f"{os.getuid()}:{os.getgid()}",
            "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--cpus", SANDBOX["cpus"], "--memory", SANDBOX["memory"],
            "--memory-swap", SANDBOX["memory"], "--pids-limit", SANDBOX["pids"], "--log-opt", "max-size=4m", "--log-opt", "max-file=1",
            "--tmpfs", "/tmp:rw,exec,size=" + SANDBOX["tmp"],
            *(mount(ws.root / "inputs", "/in") if inputs is None else [arg for src, dst in inputs for arg in mount(src, dst)]), *mount(out, "/out", False),
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
    if low_disk(ws):
        refuse("STANDARD_DISK_LOW")
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
        refuse("STANDARD_ARGUMENTS_INVALID: language or code")
    limit = minutes(request)
    with ws.lock():
        dataset, inputs = job_delivery(ws, request)
        if not isinstance(request.get("into"), str) or not WORK_NAME.fullmatch(request["into"]):
            refuse("STANDARD_ARGUMENTS_INVALID: into")
        # References are checked (and snapshotted) before a work folder is made, so a refused
        # reference leaves nothing behind; a refused folder removes the snapshots.
        references, snapshots = job_references(ws, request)
        out = start_with_references(ws, snapshots, lambda: work_dir(ws, request.get("into")))
        data = code.encode("utf-8")
        digest = hashlib.sha256(data).hexdigest()
        script = ws.data_dir("scripts") / (digest + (".rb" if language == "ruby" else ".py"))
        if not script.exists():
            fd = os.open(script, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
        target = "/job/script.rb" if language == "ruby" else "/job/script.py"
        interpreter = ["ruby", target] if language == "ruby" else ["python3", "-I", target]
        mounts = [(script, target)] + [(snapshots / item["id"], "/reference/" + item["id"]) for item in references]
        extra = {"language": language, "script_sha256": digest, "inputs": input_digests(ws), "timeout_minutes": limit, "dataset_id": dataset}
        if references:
            extra.update(references=reference_lineage(references), reference_dir=snapshots.name)
        record = start_with_references(ws, snapshots, lambda: start_job(
            ws, "script", out.name, lambda name: sandbox_argv(ws, name, out, mounts, ["-s", "KILL", str(limit * 60), *interpreter], inputs), extra))
    result = {"job_id": record["id"], "status": "running", "script_sha256": digest, "into": "work/" + out.name,
              "next": "poll data_job until it finishes; outputs land in work/" + out.name}
    if references:
        result["references"] = [{"id": item["id"], "mounted_at": "/reference/" + item["id"]} for item in references]
    return result


# -- supporting references in jobs -------------------------------------------------------
# A job may read named, active project references through verified per-job snapshots
# (never the custody originals). Only the protected-session context the fixed adapter
# supplies admits them; the outputs' provenance records each reference's ID and digest.

REFERENCE_DIR = re.compile(r"refs-[0-9a-f]{16}\Z")


def reference_lineage(references):
    return [{key: item[key] for key in ("id", "sha256", "size_bytes")} for item in references]


def job_references(ws, request, identities=None):
    """Caller holds ws.lock(). ([], None) when the request names no references."""
    identities = request.get("references") if identities is None else identities
    if identities is None:
        return [], None
    module, api = supporting_module(), supporting_api()
    api.reference_active = lambda support_id: file_roles.reference_active(ws, support_id, roles_api())
    module.session_context(request, api)
    directory = ws.data_dir("jobs") / ("refs-" + secrets.token_hex(8))
    directory.mkdir(mode=0o700)
    try:
        return module.resolve_references(ws, request, api, identities, directory), directory
    except BaseException:
        shutil.rmtree(directory, ignore_errors=True)
        raise


def start_with_references(ws, snapshots, start):
    try:
        return start()
    except BaseException:
        if snapshots is not None:
            shutil.rmtree(snapshots, ignore_errors=True)
        raise


def drop_reference_snapshots(ws, job):
    name = job.get("reference_dir")
    if isinstance(name, str) and REFERENCE_DIR.fullmatch(name):
        path = ws.data / "jobs" / name
        if path.is_dir() and not path.is_symlink():
            for child in path.iterdir():
                if not child.is_symlink():
                    child.chmod(0o600)
            shutil.rmtree(path, ignore_errors=True)


PREPARE_MINUTES = 5


def preparer_digest(ws):
    digest = hashlib.sha256()
    for name in ("supporting_prepare.py", "supporting_reader.py"):
        data = (ws.repo / "bin" / name).read_bytes()
        digest.update(name.encode() + b"\0" + hashlib.sha256(data).hexdigest().encode() + b"\n")
    return digest.hexdigest()


def preparer_module():
    import sys
    directory = str(Path(__file__).with_name("supporting_reader.py").parent)
    if directory not in sys.path:
        sys.path.insert(0, directory)
    spec = importlib.util.spec_from_file_location("supporting_prepare", Path(__file__).with_name("supporting_prepare.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def op_supporting_prepare(ws, request):
    """Deterministically project a bounded CSV/XLSX table region of one active reference
    into a declared converter-native file (CSV, JSON or YAML) in work/<into>/, as a
    confined no-network job. Register the result with data_register; its provenance
    names the reference digest, spec digest and preparer code digest."""
    ws.require()
    identity = request.get("id")
    preparer = preparer_module()
    raw = {key: request[key] for key in ("sheet", "header_row", "max_rows", "columns") if key in request}
    raw["output"] = {key: request[key] for key in ("format", "shape", "name") if key in request}
    with ws.lock():
        dataset, _mounts = job_delivery(ws, request)
        references, snapshots = job_references(ws, request, [identity])
        try:
            suffix = Path(references[0]["filename"]).suffix.lower()
            if suffix not in (".csv", ".tsv", ".xlsx"):
                refuse("STANDARD_SUPPORTING_UNSUPPORTED")
            raw["format"] = "xlsx" if suffix == ".xlsx" else "csv"
            try:
                spec = preparer.validate_spec(raw)
            except preparer.Refusal as error:
                refuse(error.code)
            encoded = preparer.canonical(spec)
            path = snapshots / "spec.json"
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
            with os.fdopen(fd, "wb") as handle:
                handle.write(encoded)
            out = work_dir(ws, request.get("into"))
        except BaseException:
            shutil.rmtree(snapshots, ignore_errors=True)
            raise
        command = ["-s", "KILL", str(PREPARE_MINUTES * 60), "python3", "-I", "-B", "/silo/bin/supporting_prepare.py",
                   "/job/spec.json", "/reference/input", "/out"]
        mounts = [(snapshots / identity, "/reference/input"), (path, "/job/spec.json")]
        reader_ws = supporting_module().ReaderWorkspace(ws)
        digest = preparer_digest(ws)
        record = start_with_references(ws, snapshots, lambda: start_job(
            ws, "prepare", out.name, lambda name: sandbox_argv(reader_ws, name, out, mounts, command, inputs=[]),
            {"script_sha256": digest, "preparation": spec, "preparation_sha256": hashlib.sha256(encoded).hexdigest(),
             "references": reference_lineage(references), "reference_dir": snapshots.name, "inputs": [],
             "timeout_minutes": PREPARE_MINUTES, "dataset_id": dataset}))
    return {"job_id": record["id"], "status": "running", "into": "work/" + out.name, "output": "work/%s/%s" % (out.name, spec["output"]["name"]),
            "preparation_sha256": record["preparation_sha256"], "preparer_sha256": digest,
            "next": ("poll data_job until it finishes; its log shows rows/skipped_blank/sha256. Preview the output with data_peek, "
                     "then register it with data_register (type mapping or run-input for converter run inputs, merge-settings for a merge) so a plan can bind it.")}


def op_extract(ws, request):
    ws.require()
    parts = parts_of(request.get("path"))
    if parts[0] != "inputs" or len(parts) < 2:
        refuse("STANDARD_ARGUMENTS_INVALID: path")
    limit = minutes(request)
    with ws.lock():
        source = registered(ws, "/".join(parts))
        refuse_base_roles(ws, [source.get("id")])
        digest = source["sha256"]
        records = read_deliveries(ws)
        labelled_mode = any(record.get("kind") != "base_site" for record in records.values()) or source.get("dataset_id") in records
        dataset = source.get("dataset_id") if labelled_mode else None
        if dataset is not None and dataset not in records:
            refuse("STANDARD_DELIVERY_UNLABELLED")
        root = ws.open_area("inputs")
        try:
            fd, _info = open_regular(root, parts[1:])
            os.close(fd)
        finally:
            os.close(root)
        out = work_dir(ws, request.get("into"))
        command = ["-s", "KILL", str(limit * 60), "python3", "-I", "/silo/bin/data_extract.py", "/in/" + "/".join(parts[1:]), "/out"]
        mounts = job_delivery(ws, {})[1] if dataset is None else delivery_mounts(ws, dataset)
        record = start_job(ws, "extract", out.name, lambda name: sandbox_argv(ws, name, out, [], command, mounts),
                           {"source": {"path": "/".join(parts), "sha256": digest}, "timeout_minutes": limit, "dataset_id": dataset})
    return {"job_id": record["id"], "status": "running", "into": "work/" + out.name, "next": "poll data_job"}


def refresh_jobs(ws):
    jobs = jobs_of(ws)
    for job in jobs:
        if job.get("status") == "running":
            finish(ws, job)
    return jobs


def secret_values(ws):
    """Every password this workspace's database uses, to keep them out of anything shown."""
    values = []
    for name in ("secret.env", "ro.env"):
        path = ws.data / "db" / name
        if path.is_file() and not path.is_symlink():
            values += [line.split("=", 1)[1].encode() for line in path.read_text().splitlines() if "PASSWORD=" in line]
    return [value for value in values if len(value) >= 16]


def redact(ws, data):
    for value in secret_values(ws):
        data = data.replace(value, b"[redacted]")
    return data


def free_bytes(path):
    info = os.statvfs(path)
    return info.f_bavail * info.f_frsize


def low_disk(ws):
    """True when the disk holding the workspace is below the reserve every service needs."""
    try:
        info = os.statvfs(ws.root)
    except OSError:
        return False
    total = info.f_blocks * info.f_frsize
    return free_bytes(ws.root) < max(DISK_RESERVE, total // 10)


def finish(ws, job):
    """Update a running job from its container; when it has exited, keep its log tail and remove it."""
    result = docker(["inspect", "--type", "container", "--format", "{{json .State}}", job["container"]], timeout=30)
    if result.returncode:
        # Only a container Docker says is gone is lost; any other failure leaves the job running.
        if b"No such" not in result.stderr:
            return None
        docker(["rm", "-f", job["container"]], timeout=60)
        job.update(status="lost", finished_at=now())
        drop_reference_snapshots(ws, job)
        ws.write_json(ws.data_dir("jobs") / (job["id"] + ".json"), job)
        return None
    state = json.loads(result.stdout)
    if state.get("Running") or state.get("Status") in ("created", "running", "restarting"):
        if job.get("kind") != "db_load" and low_disk(ws):
            docker(["kill", job["container"]], timeout=60)
            job["stopped_for_disk"] = True
            ws.write_json(ws.data_dir("jobs") / (job["id"] + ".json"), job)
        return None
    logs = docker(["logs", "--tail", "400", job["container"]], timeout=60)
    combined = redact(ws, logs.stdout + (b"\n--- stderr ---\n" + logs.stderr if logs.stderr else b""))
    log_dir = ws.data_dir("jobs")
    fd = os.open(log_dir / (job["id"] + ".log"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(combined[-256 * 1024:])
    code = state.get("ExitCode")
    status = "succeeded" if code == 0 else ("timed_out" if code == 137 and not state.get("OOMKilled") else "failed")
    if job.get("stopped_for_disk"):
        status = "stopped_low_disk"
    job.update(status=status, exit_code=code, oom_killed=bool(state.get("OOMKilled")), finished_at=now())
    if job.get("kind") == "db_load":
        # The dump ran as the database administrator and may have changed the read-only user.
        try:
            checked = harden_ro_user(ws, job.get("engine"))
        except Refusal:
            checked = False
        job["read_only_user_checked"] = checked
        db = db_state(ws)
        if db:
            db["ro_user"] = checked
            ws.write_json(ws.data_dir("db") / "state.json", db)
    drop_reference_snapshots(ws, job)
    ws.write_json(log_dir / (job["id"] + ".json"), job)
    docker(["rm", "-f", job["container"]], timeout=60)
    return combined


def output_listing(directory, limit=50, seconds=20):
    """Files a job wrote: names and sizes only, never following links, bounded in count and time."""
    files, total, deadline = [], 0, time.monotonic() + seconds
    for top, _dirs, names, dirfd in os.fwalk(str(directory), follow_symlinks=False):
        for name in names:
            try:
                info = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if stat.S_ISREG(info.st_mode):
                total += 1
                if len(files) < limit:
                    files.append({"path": os.path.relpath(os.path.join(top, name), directory.parent), "bytes": info.st_size})
        if time.monotonic() > deadline:
            return files, total, False
    return sorted(files, key=lambda entry: entry["path"]), total, True


def op_job(ws, request):
    ws.require(standard=False)
    job_id = request.get("job_id")
    if not isinstance(job_id, str) or not JOB.fullmatch(job_id):
        refuse("STANDARD_ARGUMENTS_INVALID: job_id")
    path = ws.data / "jobs" / (job_id + ".json")
    job = ws.read_json(path, None)
    if not job:
        refuse("STANDARD_REFERENCE_INVALID")
    if job.get("status") == "running":
        with ws.lock():
            finish(ws, job)
    result = {key: job.get(key) for key in ("id", "kind", "status", "exit_code", "oom_killed", "started_at", "finished_at", "into",
                                             "script_sha256", "timeout_minutes", "source", "error", "read_only_user_checked",
                                             "references", "preparation_sha256") if key in job or key not in ("references", "preparation_sha256")}
    if job.get("status") == "running":
        logs = docker(["logs", "--tail", "200", job["container"]], timeout=60)
        result["log_tail"], result["log_truncated"] = tail_text(redact(ws, logs.stdout + logs.stderr))
    else:
        log = ws.data / "jobs" / (job_id + ".log")
        result["log_tail"], result["log_truncated"] = tail_text(log.read_bytes() if log.is_file() else b"")
    work = ws.root / "work" / (job.get("into") or "")
    if job.get("into") and work.is_dir() and not work.is_symlink():
        result["outputs"], result["outputs_total"], result["outputs_complete"] = output_listing(work)
    return result


# -- the source database ---------------------------------------------------------------

def db_names(ws):
    return {"network": "silo-src-" + ws.name, "container": "silo-src-" + ws.name, "volume": "silo-src-" + ws.name + "-data"}


def db_state(ws):
    return ws.read_json(ws.data_dir("db") / "state.json", None)


def db_secret(ws, engine=None):
    """secret.env: the server's administrator password, given to the server and loader containers.
    ro.env: the read-only user's password, used only from the host (and later DBHub), so a dump
    that runs commands in a client container can't see it."""
    path = ws.data_dir("db") / "secret.env"
    if engine:
        root, ro = secrets.token_hex(24), secrets.token_hex(24)
        lines = {"mariadb": ["MARIADB_ROOT_PASSWORD=" + root, "MARIADB_DATABASE=source"],
                 "postgres": ["POSTGRES_PASSWORD=" + root, "DB_PASSWORD=" + root, "DB_USER=postgres", "POSTGRES_DB=source"]}[engine]
        for name, content in (("secret.env", lines), ("ro.env", ["SILO_RO_USER=" + RO_USER, "SILO_RO_PASSWORD=" + ro])):
            fd = os.open(ws.data_dir("db") / name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as handle:
                handle.write("\n".join(content) + "\n")
    return path


def db_exec(ws, engine, sql=None, query=None, timeout=60):
    """Run SQL as the database's administrator inside the server container (never shown to the agent)."""
    container = db_names(ws)["container"]
    if engine == "mariadb":
        argv = ["exec", "-i", "--env-file", str(db_secret(ws)), container, "bash", "-c",
                'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -N -B --protocol=socket --sandbox']
    else:
        argv = ["exec", "-i", container, "psql", "-U", "postgres", "-d", "source", "-v", "ON_ERROR_STOP=1", "-q", "-At"]
    return docker(argv, timeout=timeout, input=(sql or query).encode("utf-8"))


def ro_password(ws):
    path = ws.data / "db" / "ro.env"
    password = next((line.split("=", 1)[1] for line in path.read_text().splitlines() if line.startswith("SILO_RO_PASSWORD=")), "") if path.is_file() else ""
    if not re.fullmatch(r"[0-9a-f]{48}", password):
        refuse("STANDARD_DB_STATE_MISSING")
    return password


def harden_ro_user(ws, engine):
    """(Re)create the read-only user and reduce it to reading after a dump ran as administrator.
    Best effort against a hostile dump: the source database is untrusted and disposable, and
    query access (DBHub) must open its sessions read-only itself."""
    if engine not in ENGINES:
        return False
    password = ro_password(ws)
    if engine == "mariadb":
        listed = db_exec(ws, engine, query=(f"SELECT 'role', Role FROM mysql.roles_mapping WHERE User = '{RO_USER}' AND Role <> '';\n"
                                            f"SELECT 'host', Host FROM mysql.user WHERE User = '{RO_USER}' AND Host <> '%';\nSHOW DATABASES;\n"))
        if listed.returncode:
            return False
        roles, hosts, databases, rejected = [], [], [], False
        for line in listed.stdout.decode("utf-8", "replace").splitlines():
            kind, tab, value = line.partition("\t")
            # Names come from the dump: only plain ones are ever put into a statement. A role or
            # host entry that can't be named safely can't be removed, so the check fails.
            if tab and kind in ("role", "host"):
                if re.fullmatch(r"[A-Za-z0-9_$.%-]{1,64}", value):
                    (roles if kind == "role" else hosts).append(value)
                else:
                    rejected = True
            elif not tab and re.fullmatch(r"[A-Za-z0-9_$-]{1,64}", line) and line not in SYSTEM_DATABASES.split("|"):
                databases.append(line)  # no % (a wildcard in grants); _ is escaped below
        sql = (f"CREATE USER IF NOT EXISTS '{RO_USER}'@'%';\nALTER USER '{RO_USER}'@'%' IDENTIFIED BY '{password}';\n"
               + "".join(f"DROP USER IF EXISTS '{RO_USER}'@'{host}';\n" for host in hosts)
               + f"REVOKE ALL PRIVILEGES, GRANT OPTION FROM '{RO_USER}'@'%';\nSET DEFAULT ROLE NONE FOR '{RO_USER}'@'%';\n"
               # MariaDB 11.4 rejects revoking from a PUBLIC with no grants (ERROR 1959): give it one first.
               + "GRANT USAGE ON *.* TO PUBLIC;\nREVOKE ALL PRIVILEGES, GRANT OPTION FROM PUBLIC;\n"
               + "".join(f"REVOKE `{role}` FROM '{RO_USER}'@'%';\n" for role in roles)
               + "".join("GRANT SELECT, SHOW VIEW ON `" + name.replace("_", "\\_") + f"`.* TO '{RO_USER}'@'%';\n" for name in databases)
               + "FLUSH PRIVILEGES;\n")
        return db_exec(ws, engine, sql).returncode == 0 and not rejected
    each_schema = ("DO $$DECLARE s text; BEGIN FOR s IN SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg\\_%' "
                   "AND nspname <> 'information_schema' LOOP {body} END LOOP; END$$;\n")
    sql = (f"DO $$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '{RO_USER}') THEN CREATE ROLE {RO_USER} LOGIN; END IF; END$$;\n"
           f"ALTER ROLE {RO_USER} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD '{password}';\n"
           f"ALTER ROLE {RO_USER} RESET ALL;\nALTER ROLE {RO_USER} IN DATABASE source RESET ALL;\n"
           f"ALTER ROLE {RO_USER} SET default_transaction_read_only = on;\n"
           f"DO $$DECLARE r text; BEGIN FOR r IN SELECT b.rolname FROM pg_auth_members m JOIN pg_roles b ON b.oid = m.roleid "
           f"JOIN pg_roles u ON u.oid = m.member WHERE u.rolname = '{RO_USER}' LOOP EXECUTE format('REVOKE %I FROM {RO_USER}', r); END LOOP; END$$;\n"
           f"REVOKE CREATE, TEMPORARY ON DATABASE source FROM PUBLIC, {RO_USER};\nGRANT CONNECT ON DATABASE source TO {RO_USER};\n"
           + each_schema.format(body=(
               f"EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM PUBLIC, {RO_USER}', s); "
               f"EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM PUBLIC, {RO_USER}', s); "
               f"EXECUTE format('REVOKE ALL ON ALL ROUTINES IN SCHEMA %I FROM PUBLIC, {RO_USER}', s); "
               f"EXECUTE format('REVOKE CREATE ON SCHEMA %I FROM PUBLIC, {RO_USER}', s); "
               f"EXECUTE format('GRANT USAGE ON SCHEMA %I TO {RO_USER}', s); "
               f"EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO {RO_USER}', s);")))
    return db_exec(ws, engine, sql).returncode == 0


def db_ready(ws, engine):
    container = db_names(ws)["container"]
    if engine == "mariadb":
        result = docker(["exec", container, "mariadb-admin", "--protocol=tcp", "-h127.0.0.1", "ping", "--silent"], timeout=20)
    else:
        result = docker(["exec", container, "pg_isready", "-q", "-h", "127.0.0.1", "-U", "postgres"], timeout=20)
    return result.returncode == 0


def network_safe(ws):
    """The project network must be internal and give the host no address on it: a plain
    --internal bridge still lets containers reach host services through its gateway."""
    result = docker(["network", "inspect", "--format", "{{json .}}", db_names(ws)["network"]], timeout=30)
    if result.returncode:
        return None
    network = json.loads(result.stdout)
    return bool(network.get("Internal")) and (network.get("Options") or {}).get("com.docker.network.bridge.inhibit_ipv4") == "true"


def op_db_up(ws, request):
    ws.require()
    engine = request.get("engine")
    if engine not in ENGINES:
        refuse("STANDARD_ARGUMENTS_INVALID: engine")
    names = db_names(ws)
    with ws.lock():
        state = db_state(ws)
        if state and state["engine"] != engine:
            refuse("STANDARD_DB_ENGINE_MISMATCH")
        image = ws.image(ENGINES[engine])
        safe = network_safe(ws)
        if safe is False:
            refuse("STANDARD_DB_NETWORK_UNSAFE")
        inspected = docker(["inspect", "--type", "container", "--format", "{{.State.Running}}", names["container"]], timeout=30)
        if inspected.returncode == 0:
            if not state:
                refuse("STANDARD_DB_STATE_MISSING")
            if inspected.stdout.strip() != b"true":
                docker_ok(["start", names["container"]])
        else:
            if safe is None:
                docker_ok(["network", "create", "--internal", "-o", "com.docker.network.bridge.inhibit_ipv4=true",
                           "--label", "silo.workspace=" + ws.name, names["network"]])
            if not state:
                if docker(["volume", "inspect", names["volume"]], timeout=30).returncode == 0:
                    refuse("STANDARD_DB_STATE_MISSING")
                db_secret(ws, engine)
            command = (["--innodb-buffer-pool-size=1G", "--max-allowed-packet=1G", "--innodb-flush-log-at-trx-commit=2", "--skip-name-resolve",
                        "--event-scheduler=DISABLED"]
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
            if not state:
                state = {"engine": engine, "image": image, "created_at": now(), "loads": [], "ro_user": False}
                ws.write_json(ws.data_dir("db") / "state.json", state)
        deadline = time.monotonic() + 90
        ready = db_ready(ws, engine)
        while not ready and time.monotonic() < deadline:
            time.sleep(2)
            ready = db_ready(ws, engine)
        if ready and not state.get("ro_user"):
            state["ro_user"] = harden_ro_user(ws, engine)
            ws.write_json(ws.data_dir("db") / "state.json", state)
    return {"engine": engine, "ready": ready, "network": names["network"] + " (internal: no outside access, no host address)",
            "read_only_user": RO_USER if state.get("ro_user") else None,
            "queries": dbhub_info(ws, pull_seconds=90) if ready else None,
            "next": "data_db_load with a registered input" if ready else "still starting; check data_db_status"}


def find_registered(ws, relative):
    for record in ws.named_state().get("inputs", {}).values():
        if base64.b64decode(record["path"]).decode("utf-8", "replace") == relative:
            return record
    return None


def registered(ws, relative):
    """The registry record of an input path: its checksum stands for the bytes (inputs are read-only)."""
    return find_registered(ws, relative) or refuse("STANDARD_INPUT_NOT_REGISTERED")


SQL_KINDS = {"mariadb": ("mysql-dump", "sql", "text"), "postgres": ("postgres-dump", "sql", "text")}


def op_db_load(ws, request):
    ws.require()
    parts = parts_of(request.get("path"))
    if parts[0] != "inputs" or len(parts) < 2:
        refuse("STANDARD_ARGUMENTS_INVALID: path")
    charset = request.get("charset", "utf8mb4")
    stop_on_error = request.get("stop_on_error", True) is not False
    limit = minutes({"timeout_minutes": request.get("timeout_minutes", 120)})
    if charset not in CHARSETS:
        refuse("STANDARD_ARGUMENTS_INVALID: charset")
    refuse_base_roles(ws, [(registered(ws, "/".join(parts)) or {}).get("id")])
    names = db_names(ws)
    with ws.lock():
        state = db_state(ws)
        if not state:
            refuse("STANDARD_DB_NOT_UP")
        engine = state["engine"]
        if not db_ready(ws, engine):
            refuse("STANDARD_DB_NOT_READY")
        if network_safe(ws) is not True:
            refuse("STANDARD_DB_NETWORK_UNSAFE")
        record = registered(ws, "/".join(parts))
        refuse_base_roles(ws, [record.get("id")])
        root = ws.open_area("inputs")
        try:
            fd, info = open_regular(root, parts[1:])
            kind = describe(fd)
            os.close(fd)
        finally:
            os.close(root)
        if info.st_size != record["bytes"] or info.st_mode & 0o222:
            refuse("STANDARD_INPUT_CHANGED")
        compressed, inner = (kind["kind"], kind["inner"]) if "inner" in kind else (None, kind["kind"])
        custom = engine == "postgres" and inner == "postgres-custom-dump" and compressed is None
        if not custom and (compressed not in (None, "gzip", "bzip2", "xz") or inner not in SQL_KINDS[engine]):
            # e.g. an archive (extract it first), zstd, a MySQL dump for PostgreSQL or the reverse.
            refuse("STANDARD_DUMP_KIND_UNSUPPORTED")
        source = ws.root / "inputs" / "/".join(parts[1:])
        decompress = {"gzip": "gzip -dc", "bzip2": "bzip2 -dc", "xz": "xz -dc"}.get(compressed, "cat")
        if engine == "mariadb":
            # --sandbox: the client refuses \! and system, so the dump can't run commands here.
            script = (f'set -o pipefail; {decompress} /in/dump | MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -h source-db -uroot --sandbox '
                      f'--default-character-set={charset} {"" if stop_on_error else "--force "}source > /dev/null; code=$?; echo LOAD_DONE; exit $code')
        elif custom:
            script = (f'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore --no-owner --no-privileges -h source-db -U postgres -d source '
                      f'{"--exit-on-error " if stop_on_error else ""}/in/dump > /dev/null; code=$?; echo LOAD_DONE; exit $code')
        else:
            # psql runs backslash commands from the dump (\! runs a shell). A random \restrict key,
            # with the dump's own \restrict/\unrestrict lines dropped, refuses all of them.
            key = secrets.token_hex(16)
            script = (f'set -o pipefail; {{ printf "%s\\n" "\\\\restrict {key}"; {decompress} /in/dump | sed -E "/^\\\\\\\\(un)?restrict /d"; }} | '
                      f'PGPASSWORD="$POSTGRES_PASSWORD" psql -h source-db -U postgres -d source -q -v ON_ERROR_STOP={1 if stop_on_error else 0} > /dev/null; '
                      'code=$?; echo LOAD_DONE; exit $code')

        def argv(name):
            return ["run", "-d", "--name", name, "--label", "silo.workspace=" + ws.name, "--label", "silo.role=data-job",
                    "--pull=never", "--restart", "no", "--network", names["network"], "--read-only",
                    "--user", f"{os.getuid()}:{os.getgid()}", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                    "--cpus", "1", "--memory", "1g", "--memory-swap", "1g", "--pids-limit", "64", "--log-opt", "max-size=4m",
                    "--log-opt", "max-file=1", "--tmpfs", "/tmp:rw,size=64m", "-e", "HOME=/tmp", *mount(source, "/in/dump"),
                    "--env-file", str(db_secret(ws)), "--entrypoint", "timeout", state["image"], "-s", "KILL", str(limit * 60),
                    "bash", "-c", script]
        record = start_job(ws, "db_load", None, argv, {"source": {"path": "/".join(parts), "sha256": record["sha256"], "kind": kind},
                                                        "dataset_id": record.get("dataset_id"), "input_id": record.get("id"),
                                                        "engine": engine, "charset": charset, "timeout_minutes": limit})
        state["loads"].append({"job_id": record["id"], "path": "/".join(parts), "sha256": record["source"]["sha256"], "started_at": record["started_at"],
                               "dataset_id": (find_registered(ws, "/".join(parts)) or {}).get("dataset_id")})
        ws.write_json(ws.data_dir("db") / "state.json", state)
    return {"job_id": record["id"], "status": "running", "engine": engine, "source_kind": kind,
            "next": "poll data_job; then data_db_status"}


def op_db_status(ws, request):
    ws.require()
    state = db_state(ws)
    if not state:
        return {"source_db": None, "next": "data_db_up with engine mariadb or postgres"}
    names = db_names(ws)
    inspected = docker(["inspect", "--type", "container", "--format", "{{.State.Status}}", names["container"]], timeout=30)
    running = inspected.returncode == 0 and inspected.stdout.strip() == b"running"
    result = {"engine": state["engine"], "container": inspected.stdout.decode().strip() if inspected.returncode == 0 else "missing",
              "ready": running and db_ready(ws, state["engine"]), "read_only_user": RO_USER if state.get("ro_user") else None,
              "loads": state.get("loads", [])[-20:], "network": names["network"] + " (internal)"}
    if result["ready"]:
        if state["engine"] == "mariadb":
            query = (f"SELECT table_schema, COUNT(*), ROUND(SUM(data_length + index_length) / 1048576) FROM information_schema.tables "
                     f"WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys') GROUP BY table_schema;")
        else:
            query = ("SELECT table_schema, COUNT(*), pg_database_size('source') / 1048576 FROM information_schema.tables "
                     "WHERE table_schema NOT IN ('pg_catalog','information_schema') GROUP BY table_schema;")
        out = db_exec(ws, state["engine"], query=query)
        rows = [line.split("\t" if state["engine"] == "mariadb" else "|") for line in out.stdout.decode("utf-8", "replace").splitlines() if line.strip()]
        result["schemas"] = [{"schema": row[0], "tables": int(row[1]), "approx_mb": row[2]} for row in rows[:20] if len(row) == 3 and row[1].isdigit()]
        result["queries"] = dbhub_info(ws)
    return result


def op_db_reset(ws, request):
    ws.require()
    if request.get("confirm") is not True:
        refuse("STANDARD_CONFIRMATION_REQUIRED")
    names = db_names(ws)
    with ws.lock():
        if any(job.get("status") == "running" and job.get("kind") == "db_load" for job in refresh_jobs(ws)):
            refuse("STANDARD_BUSY")
        # Its MCP entry goes first, then chats' DBHub processes (again before the network goes).
        mcp_register(ws, present=False)
        stop_dbhub(ws)
        docker(["rm", "-f", names["container"]], timeout=120)
        docker(["volume", "rm", "-f", names["volume"]], timeout=120)
        # Passwords stay with the data: forget them only once the container and volume are gone.
        if docker(["inspect", "--type", "container", names["container"]], timeout=30).returncode == 0 or docker(["volume", "inspect", names["volume"]], timeout=30).returncode == 0:
            refuse("STANDARD_DB_RESET_INCOMPLETE")
        # A DBHub container a chat just closed (or started meanwhile) can hold the network briefly.
        for attempt in range(5):
            stop_dbhub(ws)
            if docker(["network", "rm", names["network"]], timeout=60).returncode == 0 or \
                    docker(["network", "inspect", names["network"]], timeout=30).returncode != 0:
                break
            time.sleep(2)
        else:
            refuse("STANDARD_DB_RESET_INCOMPLETE: the network is still in use; run data_db_reset again")
        for name in ("state.json", "secret.env", "ro.env", "dbhub.toml"):
            path = ws.data / "db" / name
            if path.is_file() and not path.is_symlink():
                path.unlink()
    return {"source_db": None, "note": "the source database was removed; registered inputs are untouched"}


# -- DBHub: free read-only queries over MCP ------------------------------------------------
# Each project's source database gets one MCP server in term-llm's mcp.json, `db-<project>`,
# and a rule in config.yaml (mcp.servers.db-<project>.agents: [migration-data]) that term-llm
# 0.9.96+ enforces (SamSaffron/term-llm#1341): only migration-data, loaded from
# ~/.config/term-llm/agents, may turn it on. The rule is written first, so the server is never
# listed without it; it stays when the server goes, so a project re-created under the same
# name is limited from the start. term-llm starts the server per chat as
# `silo-migrate-control dbhub <project>` (stdio), which runs DBHub in a container on the
# project's internal network as the read-only user. Every data_db_up / data_db_status puts
# the entry and the rule back if someone changed them.

DBHUB_IMAGE = "bytebase/dbhub:1.5.1@sha256:86edce0447fd9d4bd9eeb7cea7dd3b83473b732a0c437c552b36004c034ff5a9"
DBHUB_MAX_ROWS = 50
MCP_AGENT = "migration-data"
DBHUB_DSN = {"mariadb": "mariadb://" + RO_USER + ":${DB_PASSWORD}@source-db:3306/source?sslmode=disable",
             "postgres": "postgres://" + RO_USER + ":${DB_PASSWORD}@source-db:5432/source?sslmode=disable"}


def term_llm_config_dir():
    return Path(os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")) / "term-llm"


def mcp_config_path():
    return term_llm_config_dir() / "mcp.json"


def yaml_scalar(raw):
    value = re.sub(r"\s+#.*$", "", raw).strip()
    if value in ("", "~", "null"):
        return None
    if value == "{}":
        return {}
    if value.startswith("["):
        if not value.endswith("]"):
            raise ValueError("flow list")
        return [yaml_scalar(item) for item in value[1:-1].split(",") if item.strip()]
    if len(value) > 1 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def yaml_tree(entries, pos, indent):
    """The block at exactly `indent` from entries[pos]: a mapping, or a list of scalars. Enough for the
    mcp: section term-llm writes; anything else raises ValueError (callers then say it can't be read)."""
    if entries[pos][1].startswith("- ") or entries[pos][1] == "-":
        items = []
        while pos < len(entries) and entries[pos][0] == indent and (entries[pos][1].startswith("- ") or entries[pos][1] == "-"):
            items.append(yaml_scalar(entries[pos][1][1:]))
            pos += 1
        return items, pos
    mapping = {}
    while pos < len(entries) and entries[pos][0] == indent:
        match = re.fullmatch(r"(\"[^\"]*\"|'[^']*'|[^:\s][^:]*?)\s*:(?:\s+(.*))?", entries[pos][1])
        if not match or entries[pos][1].startswith("- "):
            raise ValueError("not a mapping")
        key, rest = yaml_scalar(match[1]), match[2]
        pos += 1
        if rest is not None and re.sub(r"\s*#.*$", "", rest).strip():
            mapping[key] = yaml_scalar(rest)
        elif pos < len(entries) and (entries[pos][0] > indent or (entries[pos][0] == indent and entries[pos][1].startswith("- "))):
            mapping[key], pos = yaml_tree(entries, pos, entries[pos][0])
        else:
            mapping[key] = None
    if pos < len(entries) and entries[pos][0] > indent:
        raise ValueError("indentation")
    return mapping, pos


def mcp_rules_of(text):
    """{server: agents} from config.yaml's mcp.servers.NAME.agents, for the servers that have one."""
    lines = text.split("\n")
    starts = [i for i, line in enumerate(lines) if re.fullmatch(r"mcp:\s*(#.*)?", line)]
    if not starts:
        return {}
    if len(starts) > 1:
        raise ValueError("two mcp sections")
    entries = []
    for line in lines[starts[0] + 1:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            break
        if "\t" in line[:len(line) - len(line.lstrip())]:
            raise ValueError("tab indentation")
        entries.append((len(line) - len(line.lstrip()), line.strip()))
    if not entries:
        return {}
    section, _ = yaml_tree(entries, 0, entries[0][0])
    servers = section.get("servers") if isinstance(section, dict) else None
    if servers is None:
        return {}
    if not isinstance(servers, dict):
        raise ValueError("servers")
    return {name: rule.get("agents") for name, rule in servers.items() if isinstance(rule, dict) and "agents" in rule}


def mcp_rule_present(name):
    try:
        return mcp_rules_of((term_llm_config_dir() / "config.yaml").read_text()).get(name) == [MCP_AGENT]
    except (OSError, ValueError, UnicodeDecodeError):
        return False


def term_llm_command(prefix):
    installed = Path(prefix) / "bin/term-llm"
    return str(installed) if installed.is_file() else shutil.which("term-llm")


MCP_RULES_SINCE = (0, 9, 96)
_enforcing = {}


def term_llm_enforces(term):
    """False only for a term-llm known to be older than 0.9.96, which doesn't enforce config.yaml's MCP
    rules and would write one as a plain value that 0.9.99 refuses to read. A version that can't be
    read counts as enforcing (the rule is then required), and isn't remembered."""
    if term in _enforcing:
        return _enforcing[term]
    try:
        result = subprocess.run([term, "--version"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30,
                                env={"HOME": os.path.expanduser("~"), "PATH": os.environ.get("PATH") or "/usr/bin:/bin", "LANG": "C.UTF-8"})
        match = re.search(r"version (\d+)\.(\d+)\.(\d+)", result.stdout or "")
    except (OSError, subprocess.TimeoutExpired):
        match = None
    if not match:
        return True
    _enforcing[term] = tuple(int(part) for part in match.groups()) >= MCP_RULES_SINCE
    return _enforcing[term]


def mcp_rule(name, term):
    """Only migration-data may use MCP server NAME: config.yaml's mcp.servers.NAME.agents, written with
    term-llm's own `config set` (it keeps the rest of the file as it is). True once the file says so."""
    if mcp_rule_present(name):
        return True
    if not term or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", name) or not term_llm_enforces(term):
        return False
    env = {"HOME": os.path.expanduser("~"), "PATH": os.environ.get("PATH") or "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8"}
    if os.environ.get("XDG_CONFIG_HOME"):
        env["XDG_CONFIG_HOME"] = os.environ["XDG_CONFIG_HOME"]
    try:
        result = subprocess.run([term, "config", "set", "mcp.servers." + name + ".agents", MCP_AGENT], env=env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and mcp_rule_present(name)


def silo_servers(servers):
    return {name: server for name, server in servers.items()
            if isinstance(name, str) and name.startswith("db-") and isinstance(server, dict) and (server.get("args") or [None])[0] == "dbhub"}


def write_mcp_config(path, config):
    temporary = path.with_name("." + path.name + ".silo-" + secrets.token_hex(4))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, path)


def mcp_lock():
    path = mcp_config_path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    return Locked(path.parent / ".mcp.json.silo-lock", wait=True)


def mcp_rules_main(args, values, base, repo):
    """`mcp-rules`: the rule for every project database already in mcp.json (silo update runs it once
    term-llm can enforce them). Prints counts only: project names can identify customers."""
    if args != ["mcp-rules"]:
        refuse("STANDARD_ARGUMENTS_INVALID")
    path = mcp_config_path()
    with mcp_lock():
        try:
            if not stat.S_ISREG(os.lstat(path).st_mode):
                refuse("STANDARD_OPERATION_FAILED: mcp.json is not a plain file")
            config = json.loads(path.read_text())
        except FileNotFoundError:
            config = {}
        except (OSError, ValueError):
            refuse("STANDARD_OPERATION_FAILED: mcp.json can't be read")
        servers = config.get("servers") if isinstance(config, dict) else None
        ours = silo_servers(servers if isinstance(servers, dict) else {})
        term = term_llm_command(Workspace.repo_prefix(Path(repo), Path(base)))
        if not (term and term_llm_enforces(term)):
            print(json.dumps({"version": 1, "project_servers": len(ours), "enforced": False}))
            refuse("STANDARD_OPERATION_FAILED: this term-llm doesn't enforce MCP rules (0.9.96+ does); nothing was changed")
        open_ = [name for name in ours if not mcp_rule(name, term)]
        # One that can't be limited comes out (data_db_status puts it back with its rule).
        for name in open_:
            del servers[name]
        if open_:
            write_mcp_config(path, config)
    print(json.dumps({"version": 1, "project_servers": len(ours), "limited_to_migration_data": len(ours) - len(open_), "taken_out": len(open_)}))
    if open_:
        refuse("STANDARD_OPERATION_FAILED: not every project database could be limited to migration-data; those were taken out of mcp.json")
    return 0


def mcp_name(ws):
    return "db-" + ws.name


def mcp_entry(ws):
    # The installed shim sets the control config itself; term-llm passes it no environment.
    repo = ws.repo.resolve()
    control = repo.parent.parent / "bin/silo-migrate-control" if repo.parent.name == "releases" else repo / "bin/silo-migrate-control"
    return {"command": str(control), "args": ["dbhub", ws.name]}


PROTECTED_SESSIONS_KEY = "SILO_PROTECTED_SESSIONS"


def protected_sessions_enabled(values):
    """True only when the installer-managed control config literally says SILO_PROTECTED_SESSIONS=1.

    The root-selected path is account-owned; same-account operator writes are trusted,
    not an OS sandbox. Unsafe, linked, mutable or oversized flag files fail closed.
    The installer writes it only after verifying a native host that keeps MCP results in a
    protected migration-data session. Never read from the environment: values begin as
    os.environ, which a tool host or service unit could carry. DBHub's MCP tools bypass
    the custom-tool session gate, so without this they are neither registered nor started."""
    path = values.get("SILO_CONTROL_CONFIG")
    if not path:
        return False
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "r", encoding="utf-8") as handle:
            info = os.fstat(handle.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, os.getuid())
                    or info.st_nlink != 1 or info.st_mode & 0o022 or info.st_size > 64 * 1024):
                return False
            content = handle.read(64 * 1024 + 1)
            after = os.fstat(handle.fileno())
            if (info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                return False
        if len(content) > 64 * 1024 or "\x00" in content:
            return False
        lines = content.splitlines()
    except (OSError, UnicodeError):
        return False
    return lines.count(PROTECTED_SESSIONS_KEY + "=1") == 1 and not any(
        line.startswith(PROTECTED_SESSIONS_KEY + "=") and line != PROTECTED_SESSIONS_KEY + "=1" for line in lines)


def mcp_register(ws, present=True):
    """Put this project's entry in mcp.json (or take it out), leaving everything else as it is.
    Returns "added", "registered" (already right), "removed", "absent" or why nothing changed.
    Without protected-session enablement an add instead removes any existing entry."""
    if present and not protected_sessions_enabled(ws.values):
        removed = mcp_register(ws, present=False)
        return ("not changed: free SQL needs a node whose term-llm keeps database results in a protected migration-data chat"
                + ("; the old entry was removed" if removed == "removed" else ""))
    path = mcp_config_path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Serialises silo's own writers (term-llm's web UI can't be coordinated; status repairs it).
    lock = os.open(path.parent / ".mcp.json.silo-lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            if not stat.S_ISREG(os.lstat(path).st_mode):
                return "not changed: mcp.json is not a plain file"
            config = json.loads(path.read_text())
        except FileNotFoundError:
            config = {}
        except (OSError, ValueError):
            return "not changed: mcp.json can't be read"
        servers = config.setdefault("servers", {}) if isinstance(config, dict) else None
        if not isinstance(servers, dict):
            return "not changed: mcp.json has an unexpected shape"
        name, entry = mcp_name(ws), mcp_entry(ws)
        existing = servers.get(name)
        if existing is not None and not (isinstance(existing, dict) and (existing.get("args") or [None])[0] == "dbhub"):
            return "not changed: an existing " + name + " server isn't silo-migrate's; rename it"
        # The rule first: the server is never listed for a chat that may not use it. A term-llm that
        # doesn't enforce rules (before 0.9.96, e.g. after a rollback) gets the server as before;
        # silo doctor warns about that.
        term = term_llm_command(ws.prefix)
        enforced = bool(term) and term_llm_enforces(term)
        if present and enforced and not mcp_rule(name, term):
            return "not changed: it couldn't be limited to migration-data in term-llm's config.yaml"
        if present and existing == entry:
            return "registered"
        if not present and existing is None:
            return "absent"
        if present:
            servers[name] = entry
        else:
            del servers[name]
        write_mcp_config(path, config)
        # config.yaml has other writers (the web UI, an engineer's config set): if the rule went
        # meanwhile, the server comes back out rather than staying open to every agent.
        if present and enforced and not mcp_rule_present(name):
            del servers[name]
            write_mcp_config(path, config)
            ws.append("audit.jsonl", {"at": now(), "op": "mcp_register", "server": name, "result": "removed: rule missing"})
            return "not changed: its rule left term-llm's config.yaml while it was being added; run this again"
    finally:
        os.close(lock)
    ws.append("audit.jsonl", {"at": now(), "op": "mcp_register", "server": name, "result": "added" if present else "removed"})
    return "added" if present else "removed"


def stop_dbhub(ws):
    running = docker(["ps", "-aq", "--filter", "label=silo.role=dbhub", "--filter", "label=silo.workspace=" + ws.name], timeout=30)
    for container in running.stdout.decode().split():
        docker(["rm", "-f", container], timeout=60)


def dbhub_image(pull_seconds=0):
    """Present, or pulled by its pinned digest (Docker checks the content)."""
    if docker(["image", "inspect", "--format", "{{.Id}}", DBHUB_IMAGE], timeout=30).returncode == 0:
        return True
    return bool(pull_seconds) and docker(["pull", "--quiet", DBHUB_IMAGE], timeout=pull_seconds).returncode == 0


def dbhub_info(ws, pull_seconds=0):
    """Register the project's DBHub server and say how the engineer turns it on."""
    state = db_state(ws)
    if not (state and state.get("ro_user")):
        return {"mcp_server": None, "note": "available once the source database is up with its read-only user"}
    registration = mcp_register(ws)
    image = dbhub_image(pull_seconds)
    return {"mcp_server": mcp_name(ws), "registration": registration, "image": "ready" if image else "missing: run data_db_up again to fetch it",
            "how": ("The engineer turns on MCP server " + mcp_name(ws) + " in this chat (MCP button). Its tools: execute_sql (read-only, "
                    "at most " + str(DBHUB_MAX_ROWS) + " rows: select only the columns you need and shorten long text), search_objects "
                    "(tables, columns, indexes) and explain_sql. Use only the server for this chat's project.")}


def dbhub_toml(engine):
    return ("# Written by silo-migrate. The read-only user is the limit; DBHub adds read-only transactions and a row cap.\n"
            "[[sources]]\nid = \"source\"\ndsn = \"" + DBHUB_DSN[engine] + "\"\nconnection_timeout = 10\nquery_timeout = 120\n\n"
            "[[tools]]\nname = \"execute_sql\"\nsource = \"source\"\nreadonly = true\nmax_rows = " + str(DBHUB_MAX_ROWS) + "\n\n"
            "[[tools]]\nname = \"search_objects\"\nsource = \"source\"\n\n"
            "[[tools]]\nname = \"explain_sql\"\nsource = \"source\"\n")


def dbhub_main(args, values, base, repo, host):
    """`dbhub WS`: started by term-llm as the project's MCP server (stdio). Becomes `docker run -i`
    of DBHub on the project's internal network, signed in as the read-only user. Prints nothing."""
    if len(args) != 2 or args[0] != "dbhub":
        refuse("STANDARD_ARGUMENTS_INVALID")
    ws = Workspace(base, args[1], repo, host, values, None)
    ws.require(standard=False)
    # A stale mcp.json entry (older release, manual edit) must not open a bypass.
    if not protected_sessions_enabled(values):
        refuse("STANDARD_SUPPORTING_NODE_UPDATE_REQUIRED: free SQL needs protected-session native support")
    state = db_state(ws)
    if not (state and state.get("ro_user") and state.get("engine") in DBHUB_DSN):
        refuse("STANDARD_DB_STATE_MISSING: start the project's source database with data_db_up first")
    if network_safe(ws) is not True:
        refuse("STANDARD_DB_NETWORK_UNSAFE")
    password = ro_password(ws)
    config = ws.data_dir("db") / "dbhub.toml"
    temporary = config.with_name(".dbhub.toml." + secrets.token_hex(4))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(dbhub_toml(state["engine"]))
    os.replace(temporary, config)
    if "," in str(config):
        refuse("STANDARD_OPERATION_FAILED")
    argv = ["docker", "run", "-i", "--rm", "--pull=never", "--name", "silo-dbhub-" + ws.name + "-" + secrets.token_hex(3),
            "--label", "silo.workspace=" + ws.name, "--label", "silo.role=dbhub", "--network", db_names(ws)["network"],
            "--read-only", "--tmpfs", "/tmp:rw,size=64m,mode=1777", "--user", f"{os.getuid()}:{os.getgid()}",
            "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--cpus", "1", "--memory", "512m", "--memory-swap", "512m",
            "--pids-limit", "128", "--log-driver", "none", "-e", "HOME=/tmp", "-e", "DB_PASSWORD",
            "--mount", f"type=bind,src={config},dst=/config/dbhub.toml,readonly",
            DBHUB_IMAGE, "--transport", "stdio", "--config", "/config/dbhub.toml"]
    # The password reaches docker through the environment, never argv.
    env = {"PATH": os.environ.get("PATH") or "/usr/local/bin:/usr/bin:/bin", "DB_PASSWORD": password, "HOME": os.path.expanduser("~")}
    for key in ("DOCKER_HOST", "DOCKER_CONFIG", "XDG_RUNTIME_DIR"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    os.execvpe(argv[0], argv, env)


# -- runs and findings --------------------------------------------------------------------

PLAN_ID = re.compile(r"plan-[0-9a-f]{32}\Z")


def run_of(ws, request):
    """The run ID, or the run a plan ID started (the Project page's Runs tab shows both); returns the run ID."""
    run_id = request.get("run_id")
    if isinstance(run_id, str) and PLAN_ID.fullmatch(run_id):
        run_id = json.loads(ws.control(["standard", "plan", "show", ws.name, run_id], timeout=30)).get("run_id")
        if not run_id:
            refuse("STANDARD_RUN_NOT_FOUND")
    if not isinstance(run_id, str) or not RUN.fullmatch(run_id):
        refuse("STANDARD_ARGUMENTS_INVALID: run_id")
    return run_id


def op_run_evidence(ws, request):
    run_id = run_of(ws, request)
    evidence = json.loads(ws.control(["standard", "analyst", "evidence", ws.name, run_id]))
    run = (standard_state(ws).get("runs") or {}).get(run_id) or {}
    # Private analyst evidence, never the engineer/public run projection.
    results = run.get("results") or {}
    if results.get("review_runtime"):
        evidence["review_runtime"] = results["review_runtime"]
    if results.get("base_site"):
        evidence["base_site"] = {key: results.get(key) for key in
                                 ("base_site_newer_migrations", "prior_import_id_rows")}
    # Backup identity and release metadata, not arbitrary private artifact paths.
    if (run.get("artifacts") or {}).get("backup"):
        evidence["backup"] = {key: run["artifacts"]["backup"].get(key) for key in ("filename", "sha256", "bytes", "label")}
    if run.get("release"):
        evidence["release"] = {key: run["release"].get(key) for key in
                               ("released_at", "released_by", "sha256", "filename", "outbox", "manifest", "acknowledged_differences")}
    return {"run_id": run_id, "evidence": evidence}


def op_run_count(ws, request):
    """One count on a run's intermediate database, or on a review run's site (read-only role)."""
    started = time.monotonic()
    run_id = run_of(ws, request)
    side, sql = request.get("side"), request.get("sql")
    if side not in ("intermediate", "destination") or not isinstance(sql, str) or not 0 < len(sql.encode()) <= 4096:
        refuse("STANDARD_ARGUMENTS_INVALID: side or sql")
    # On stdin, never in argv: the SQL may quote customer values.
    counted = json.loads(ws.control(["standard", "analyst", "count", ws.name, run_id, "--side", side, "--sql-file", "-"], input=sql,
                                 timeout=max(10, 285 - int(time.monotonic() - started))))
    return {key: counted.get(key) for key in ("run_id", "side", "count", "error")}


INPUT_ID = re.compile(r"input-[0-9a-f]{32}\Z")


def refuse_base_roles(ws, ids):
    ids = list(ids)
    for input_id in ids:
        file_roles.effective_input(ws, input_id, roles_api())
    state = ws.named_state().get("inputs") or {}
    records = read_deliveries(ws)
    if any(key in ids and (item.get("type") == "base_site" or (records.get(item.get("dataset_id")) or {}).get("kind") == "base_site")
           for key, item in state.items()):
        refuse("STANDARD_BASE_SITE_ROLE: a Base site is not source data, settings or count checks")


def base_site_warning(base):
    return ("The sandbox is on a newer schema (%s) than this server's Discourse (%s). Normal for hosted sandboxes. It will be restored anyway." %
            (base.get("schema_version"), base.get("site_schema_version")))


def review_base_site(ws, request):
    fresh, explicit = request.get("fresh_site", False), request.get("base_site")
    if not isinstance(fresh, bool) or ("fresh_site" in request and "base_site" in request):
        refuse("STANDARD_ARGUMENTS_INVALID: choose base_site or fresh_site, not both")
    inputs = ws.named_state().get("inputs") or {}
    records = read_deliveries(ws)
    if "base_site" in request:
        if not isinstance(explicit, str) or not INPUT_ID.fullmatch(explicit):
            refuse("STANDARD_ARGUMENTS_INVALID: base_site must be an input id")
        item = inputs.get(explicit)
        if not item or item.get("type") != "base_site":
            refuse("STANDARD_BASE_SITE_INVALID: base_site must name a registered Base site input")
        file_roles.effective_input(ws, explicit, roles_api())
        return explicit
    if fresh:
        return None
    roles = file_roles.load(ws, roles_api())
    current = [records[roles["active"]["base_site"]]] if roles["active"].get("base_site") in records else []
    if not current:
        return None
    record = current[-1]
    found = next((key for key, item in inputs.items() if item.get("dataset_id") == record["dataset_id"] and item.get("type") == "base_site"), None)
    if not found:
        refuse("STANDARD_BASE_SITE_NOT_TAKEN: take the labelled Base site file with data_take type=base_site, then propose again (or choose fresh_site=true)")
    return found


def runtime_preparing(plan):
    if plan.get("status") != "runtime_preparing":
        return None
    return {"status": "runtime_preparing", "next": "Preparing the matching public Discourse runtime. No customer data is used and no import has started. Poll this same proposal after a short wait; it will return a plan for the engineer to approve when ready."}


# -- exact plan inputs and preparation metadata -------------------------------------
# Optional; the Ruby plan backend (services/standard_run_inputs.rb) owns validation,
# digest binding, materialization and display. Here: fill identities and lineage from
# this workspace's own records (never from the agent), translate supporting reference
# IDs to the file-roles registry entries the backend checks, and hand each document
# over as a bounded private file. Without these keys proposals are exactly as before.
RUN_INPUT_TYPES = ("run-input", "mapping")
DATASET_ID = re.compile(r"dataset-[0-9a-f]{32}\Z")
MAX_PLAN_DOCUMENT = 64 * 1024
ANALYST_LABEL = "migration-data analyst (interpretation, not evidence)"
SUPPORT_ID = re.compile(r"support-[0-9a-f]{32}\Z")
FILE_ID = re.compile(r"file-[0-9a-f]{32}\Z")
JOB_TOOLS = {"prepare": "data_supporting_prepare", "script": "data_script", "extract": "data_extract"}


def reference_identity(ws, entry, roles, code):
    """{file_id|input_id, sha256} for one cited reference, as the backend will recheck it.
    An optional sha256 (e.g. a re-proposal of a plan's bound form) must still be current."""
    if not isinstance(entry, dict) or not 1 <= len(entry) <= 2 or (len(entry) == 2 and "sha256" not in entry):
        refuse(code + ": a reference is {support_id}, {file_id} or {input_id}")
    entry = dict(entry)
    expected = entry.pop("sha256", None)
    if len(entry) != 1:
        refuse(code + ": a reference is {support_id}, {file_id} or {input_id}")
    resolved = _reference_identity(ws, entry, roles, code)
    if expected is not None and expected != resolved["sha256"]:
        refuse(code + ": a cited reference changed since it was bound; propose from the current reference")
    return resolved


def _reference_identity(ws, entry, roles, code):
    (key, value), = entry.items()
    if key == "support_id" and isinstance(value, str) and SUPPORT_ID.fullmatch(value):
        found = [item for item in roles["files"].values() if item.get("support_id") == value and item.get("role") == "reference"]
        if len(found) != 1:
            refuse(code + ": reference %s is not yet recorded as a supporting reference on the Files tab (intake references are; a chat attachment is recorded by the engineer's next Files role change)" % value)
        return {"file_id": found[0]["id"], "sha256": found[0]["sha256"]}
    if key == "file_id" and isinstance(value, str) and FILE_ID.fullmatch(value):
        item = roles["files"].get(value)
        if not item or item.get("role") != "reference":
            refuse(code + ": file_id is not a supporting reference")
        return {"file_id": value, "sha256": item["sha256"]}
    if key == "input_id" and isinstance(value, str) and INPUT_ID.fullmatch(value):
        item = (ws.named_state().get("inputs") or {}).get(value)
        if not item:
            refuse(code + ": input_id is not registered")
        return {"input_id": value, "sha256": item["sha256"]}
    refuse(code + ": a reference is {support_id}, {file_id} or {input_id}")


def derived_lineage(ws, input_id, roles):
    """Lineage of a derived input from its provenance record and producing job, or None."""
    path = ws.data / "provenance.jsonl"
    record = None
    if path.is_file() and not path.is_symlink():
        for line in path.read_text().splitlines():
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if item.get("input_id") == input_id and item.get("event") == "derived":
                record = item
    job = (record or {}).get("job")
    if not isinstance(job, dict) or not isinstance(job.get("id"), str) or not JOB.fullmatch(job["id"]):
        return None
    preparation = {"job": job["id"], "tool": JOB_TOOLS.get(job.get("kind"), "data_job")}
    if isinstance(job.get("script_sha256"), str) and DIGEST.fullmatch(job["script_sha256"]):
        preparation["script_sha256"] = job["script_sha256"]
    if job.get("kind") == "prepare":
        # The deterministic preparer's exact normalized spec, as recorded when the job started.
        if not (isinstance(job.get("preparation_sha256"), str) and DIGEST.fullmatch(job["preparation_sha256"])):
            refuse("STANDARD_RUN_INPUTS_INVALID: a prepared file's job record has no spec digest")
        preparation["preparation_sha256"] = job["preparation_sha256"]
    lineage = {"preparation": preparation}
    references = job.get("references") or []
    if references:
        bound = []
        for item in references:
            # The digest of the bytes the job actually read (its verified snapshot), which must
            # still be the reference's current registered digest: never re-describe old output
            # with a newer reference's hash.
            used = item.get("sha256") if isinstance(item, dict) else None
            if not (isinstance(used, str) and DIGEST.fullmatch(used)):
                refuse("STANDARD_RUN_INPUTS_INVALID: a prepared file's job record has no reference digest")
            bound.append(reference_identity(ws, {"support_id": item.get("id"), "sha256": used}, roles, "STANDARD_RUN_INPUTS_INVALID"))
        lineage["references"] = bound
    return lineage


def chat_session_required(ws, request):
    """Model-facing requests (via chat, fixed by the adapter) must carry the host's protected
    session for private plan documents. The engineer's own proposal (Project page/shell,
    ws.chat False) is the trusted signed-in path and needs no native chat context."""
    if ws.chat:
        supporting_module().session_context(request, supporting_api())


# Keys a plan's stored (bound) run_inputs carries that the backend recomputes itself.
BOUND_RUN_INPUT_KEYS = {"mount", "writable"}


def run_inputs_document(ws, request, source):
    if "run_inputs" not in request:
        return None
    code = "STANDARD_RUN_INPUTS_INVALID"
    chat_session_required(ws, request)
    manifest = request["run_inputs"]
    # files may be empty: e.g. every optional map left at the converter's default, with a fresh
    # writable directory for declared generated files. Never synthesize a placeholder file:
    # header-only and absent files mean different things to converters.
    if not isinstance(manifest, dict) or not isinstance(manifest.get("files"), list):
        refuse(code + ": run_inputs needs consumer and files (a list, possibly empty)")
    inputs = ws.named_state().get("inputs") or {}
    roles = file_roles.load(ws, roles_api())
    consumer = manifest.get("consumer")
    if not isinstance(consumer, dict):
        refuse(code + ": consumer")
    consumer = dict(consumer)
    consumer.setdefault("platform", ws.meta().get("platform"))
    files = []
    for index, entry in enumerate(manifest["files"], 1):
        # Lineage comes from this workspace's records. Only the engineer's re-proposal of a
        # bound plan may repeat it, and then it must equal what the records say now.
        allowed = {"name", "input_id", "sha256", "bytes", "reuse"} | (set() if ws.chat else {"lineage"})
        if not isinstance(entry, dict) or set(entry) - allowed:
            refuse(code + ": file %d is {name, input_id}; lineage comes from the workspace's records" % index)
        item = inputs.get(entry.get("input_id")) if isinstance(entry.get("input_id"), str) else None
        if not item or item.get("type") not in RUN_INPUT_TYPES:
            refuse(code + ": file %d must be a registered input of type run-input or mapping" % index)
        for key, value in (("sha256", item.get("sha256")), ("bytes", item.get("bytes"))):
            if key in entry and entry[key] != value:
                refuse(code + ": file %d %s differs from the registered input" % (index, key))
        bound = {"name": entry.get("name"), "input_id": entry["input_id"], "sha256": item.get("sha256"), "bytes": item.get("bytes")}
        lineage = derived_lineage(ws, entry["input_id"], roles)
        if "lineage" in entry and entry["lineage"] != lineage:
            refuse(code + ": file %d lineage differs from the workspace's records" % index)
        if lineage:
            bound["lineage"] = lineage
        if "reuse" in entry:
            # Explicit cross-delivery reuse: the file's own dataset and the source digest it was
            # prepared against. Shape only here; the plan backend owns its meaning and checks.
            reuse = entry["reuse"]
            if (not isinstance(reuse, dict) or set(reuse) != {"dataset_id", "source_sha256"}
                    or not isinstance(reuse["dataset_id"], str) or not DATASET_ID.fullmatch(reuse["dataset_id"])
                    or not isinstance(reuse["source_sha256"], str) or not DIGEST.fullmatch(reuse["source_sha256"])):
                refuse(code + ": file %d reuse is {dataset_id, source_sha256}" % index)
            bound["reuse"] = {"dataset_id": reuse["dataset_id"], "source_sha256": reuse["source_sha256"]}
        files.append(bound)
    refuse_base_roles(ws, [entry["input_id"] for entry in files])
    document = {"version": manifest.get("version", 1), "consumer": consumer, "source_sha256": inputs.get(source, {}).get("sha256"), "files": files}
    if "source_sha256" in manifest and manifest["source_sha256"] != document["source_sha256"]:
        refuse(code + ": source_sha256 differs from the plan's source")
    for key in ("absent_defaults", "generated"):
        if key in manifest:
            document[key] = manifest[key]
    if set(manifest) - {"version", "consumer", "source_sha256", "files", "absent_defaults", "generated"} - (set() if ws.chat else BOUND_RUN_INPUT_KEYS):
        refuse(code + ": unknown key")
    return document


def preparation_document(ws, request):
    """Analyst-labelled preparation metadata. Needs the protected-session context."""
    if "preparation" not in request:
        return None
    code = "STANDARD_PREPARATION_INVALID"
    document = request["preparation"]
    if not isinstance(document, dict) or not isinstance(document.get("analyst"), dict):
        refuse(code + ": preparation needs analyst.text")
    chat_session_required(ws, request)
    document = dict(document)
    document.setdefault("version", 1)
    # The label is fixed: the agent cannot present its interpretation as anyone else's.
    document["analyst"] = {"label": ANALYST_LABEL, "text": document["analyst"].get("text")}
    if "references" in document:
        if not isinstance(document["references"], list):
            refuse(code + ": references")
        roles = file_roles.load(ws, roles_api())
        document["references"] = [reference_identity(ws, entry, roles, code) for entry in document["references"]]
    return document


class PlanDocuments:
    """Bounded private JSON files for the backend's --run-inputs/--preparation; removed after the call."""

    def __init__(self, ws, documents):
        self.ws, self.documents, self.paths = ws, documents, []

    def __enter__(self):
        argv = []
        directory = self.ws.data_dir("plan-documents")
        for flag, (code, document) in self.documents.items():
            if document is None:
                continue
            data = json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
            if len(data) > MAX_PLAN_DOCUMENT:
                refuse(code + ": larger than 64 KiB")
            path = directory / (secrets.token_hex(16) + ".json")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            self.paths.append(path)
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
            argv += [flag, str(path)]
        return argv

    def __exit__(self, *exc):
        for path in self.paths:
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def op_plan_propose(ws, request):
    """Propose conversion from inputs or review from a completed convert run.
    Only a proposal: the engineer approves and starts it."""
    ws.require()
    from_run = request.get("from_run")
    if "from_run" in request:
        if (not isinstance(from_run, str) or not RUN.fullmatch(from_run)
                or any(key in request for key in ("source", "settings", "charset", "run_inputs", "preparation"))):
            refuse("STANDARD_ARGUMENTS_INVALID: from_run")
        reconciliation = request.get("reconciliation")
        if reconciliation is not None and (not isinstance(reconciliation, str) or not INPUT_ID.fullmatch(reconciliation)):
            refuse("STANDARD_ARGUMENTS_INVALID: reconciliation")
        refuse_base_roles(ws, [reconciliation])
        base_input = review_base_site(ws, request)
        argv = ["standard", "plan", "propose", ws.name, "--operation", "review", "--from-run", from_run]
        if base_input:
            argv += ["--base-site", base_input]
        if reconciliation is not None:
            argv += ["--reconciliation", reconciliation]
        # The proposal hashes the convert run's intermediate database (can be GBs).
        plan = json.loads(ws.control(argv, timeout=120))
        if pending := runtime_preparing(plan):
            return pending
        return {**{key: plan.get(key) for key in ("plan_id", "digest", "status", "operation", "platform", "from_run", "review_runtime",
                                                  "roles", "inputs", "limits", "mutations", "not_included", "base_site")},
                "instances": {"review": {"port": ((plan.get("instances") or {}).get("review") or {}).get("port")}},
                "next": ("Tell the engineer the review %s is waiting in the Project page's Runs tab, where they approve and start it. " %
                         ("on " + delivery_label((plan.get("base_site") or {}).get("delivery") or {"kind": "base_site", "version": 1}) if plan.get("base_site") else "on a fresh site") +
                         (base_site_warning(plan["base_site"]) + " " if (plan.get("base_site") or {}).get("ahead") else "") +
                         "Access the review site via an SSH tunnel; it stays until Reset.")}
    roles = {key: request.get(key) for key in ("source", "settings", "reconciliation")}
    charset = request.get("charset", "utf8mb4")
    if roles["reconciliation"] is None:
        del roles["reconciliation"]
    if not all(isinstance(value, str) and INPUT_ID.fullmatch(value) for value in roles.values()) or charset not in CHARSETS:
        refuse("STANDARD_ARGUMENTS_INVALID: source, settings, reconciliation or charset")
    refuse_base_roles(ws, roles.values())
    file_roles.effective_input(ws, roles["source"], roles_api(), source=True)
    if "base_site" in request or "fresh_site" in request:
        refuse("STANDARD_ARGUMENTS_INVALID: base_site and fresh_site are review options")
    argv = ["standard", "plan", "propose", ws.name, "--operation", "convert", "--charset", charset,
            *[flag for key, value in roles.items() for flag in ("--" + key, value)]]
    documents = {"--run-inputs": ("STANDARD_RUN_INPUTS_INVALID", run_inputs_document(ws, request, roles["source"])),
                 "--preparation": ("STANDARD_PREPARATION_INVALID", preparation_document(ws, request))}

    def propose():
        with PlanDocuments(ws, documents) as extra:
            return json.loads(ws.control(argv + extra, timeout=30))
    prepared = None
    # Bind the workspace to the converter's committed branch head (a dirty checkout refuses:
    # commit first). The plan shows that commit and the engineer approves exactly it.
    converter = json.loads(ws.control(["standard", "converter", "refresh", ws.name, "--if-changed"], timeout=30))
    try:
        plan = propose()
    except Refusal as refusal:
        if not str(refusal).startswith("STANDARD_CONVERTER_DEPS_MISSING"):
            raise
        # The converter commit's locked gems aren't prepared yet: prepare them (public gems
        # only, the same step dev_test runs), then propose again.
        # 150 s to build (+ up to ~35 s to remove a container that ran out of time) fits in
        # this call's 190, and 30 + 30 + 190 + 30 stays inside the tool's 290.
        prepared = json.loads(ws.control(["converter", "deps", ws.name, "--budget", "150"], timeout=190)).get("dependencies")
        plan = propose()
    return {"plan_id": plan.get("plan_id"), "digest": plan.get("digest"), "status": plan.get("status"), "operation": plan.get("operation"),
            "platform": plan.get("platform"), "roles": plan.get("roles"), "inputs": plan.get("inputs"), "source_charset": plan.get("source_charset"),
            "converter_revision": plan.get("converter_revision"), "converter_branch": converter.get("branch"),
            "converter_deps": plan.get("converter_deps"), "dependencies_prepared": prepared,
            "mutations": plan.get("mutations"), "not_included": plan.get("not_included"),
            **{key: plan[key] for key in ("run_inputs", "preparation") if key in plan},
            "next": ("Tell the engineer the plan is waiting in the Project page's Runs tab, where they review, "
                     "approve and start it. When it has finished, read it with data_run_evidence.")}


MASTER_LIST = re.compile(r"[a-z][a-z_]{0,31}\Z")


def op_master_lists_propose(ws, request):
    """Propose the converter's own master-list export (e.g. Khoros) on a disposable copy of
    the registered source. Only a proposal: it mutates staging when run, so the engineer
    approves and starts it in Runs; the exported CSVs become that run's bound artifacts."""
    ws.require()
    roles = {key: request.get(key) for key in ("source", "settings")}
    charset, wanted = request.get("charset", "utf8mb4"), request.get("list", "all")
    if (not all(isinstance(value, str) and INPUT_ID.fullmatch(value) for value in roles.values()) or charset not in CHARSETS
            or not isinstance(wanted, str) or not MASTER_LIST.fullmatch(wanted)):
        refuse("STANDARD_ARGUMENTS_INVALID: source, settings, list or charset")
    refuse_base_roles(ws, roles.values())
    file_roles.effective_input(ws, roles["source"], roles_api(), source=True)
    argv = ["standard", "plan", "propose", ws.name, "--operation", "master-lists", "--source", roles["source"],
            "--settings", roles["settings"], "--charset", charset]
    if "list" in request:
        argv += ["--list", wanted]
    documents = {"--run-inputs": ("STANDARD_RUN_INPUTS_INVALID", run_inputs_document(ws, request, roles["source"]))}

    def propose():
        with PlanDocuments(ws, documents) as extra:
            return json.loads(ws.control(argv + extra, timeout=30))
    converter = json.loads(ws.control(["standard", "converter", "refresh", ws.name, "--if-changed"], timeout=30))
    prepared = None
    try:
        plan = propose()
    except Refusal as refusal:
        if not str(refusal).startswith("STANDARD_CONVERTER_DEPS_MISSING"):
            raise
        prepared = json.loads(ws.control(["converter", "deps", ws.name, "--budget", "150"], timeout=190)).get("dependencies")
        plan = propose()
    return {**{key: plan.get(key) for key in ("plan_id", "digest", "status", "operation", "platform", "roles", "inputs", "source_charset",
                                              "converter_revision", "converter_deps", "master_lists", "mutations", "not_included")},
            **({"run_inputs": plan["run_inputs"]} if "run_inputs" in plan else {}),
            "converter_branch": converter.get("branch"), "dependencies_prepared": prepared,
            "next": ("Tell the engineer the master-list export is waiting in the Project page's Runs tab: it loads a disposable copy of "
                     "the source and runs the converter's committed exporter, which rebuilds staging tables there (not a read-only check). "
                     "They approve and start it; nothing runs until then. Its CSVs are kept as that run's artifacts.")}


MERGE_OPTIONS = ("ignore_global_pins", "separate_same_named_groups")


def merge_source(ws, request, inputs, records):
    """The source site's backup: the one named, else the only one of the newest Development delivery."""
    explicit = request.get("source")
    if "source" in request:
        if not isinstance(explicit, str) or not INPUT_ID.fullmatch(explicit) or (inputs.get(explicit) or {}).get("type") != MERGE_SOURCE_TYPE:
            refuse("STANDARD_MERGE_SOURCE_INVALID: source must name a registered input of type discourse-backup")
        file_roles.effective_input(ws, explicit, roles_api(), source=True)
        return explicit
    development = sorted((r for r in records.values() if r.get("kind") == "development"), key=lambda r: r.get("sequence", 0))
    roles = file_roles.load(ws, roles_api())
    dataset = roles["active"].get("development")
    found = [key for key, item in inputs.items()
             if dataset and item.get("dataset_id") == dataset and item.get("type") == MERGE_SOURCE_TYPE
             and file_roles.input_is_source(roles, key)]
    if len(found) != 1:
        refuse("STANDARD_MERGE_SOURCE_NOT_TAKEN: take the source site's full backup from the active Development source snapshot with data_take "
               "type=discourse-backup (exactly one), or name one with source")
    file_roles.effective_input(ws, found[0], roles_api(), source=True)
    return found[0]


def op_merge_propose(ws, request):
    """Propose merging the project's source Discourse site into its Base site. Only a proposal:
    the engineer approves and starts it."""
    ws.require()
    if ws.meta().get("platform") != MERGE_PLATFORM:
        refuse("STANDARD_MERGE_NOT_DISCOURSE: a merge needs a project whose source platform is discourse")
    options = {key: request.get(key, False) for key in MERGE_OPTIONS}
    if not all(isinstance(value, bool) for value in options.values()):
        refuse("STANDARD_ARGUMENTS_INVALID: options are true or false")
    inputs = ws.named_state().get("inputs") or {}
    source = merge_source(ws, request, inputs, read_deliveries(ws))
    try:
        base = review_base_site(ws, {"base_site": request["base_site"]} if "base_site" in request else {})
    except Refusal as refusal:
        if not str(refusal).startswith("STANDARD_BASE_SITE_NOT_TAKEN"):
            raise
        refuse("STANDARD_BASE_SITE_NOT_TAKEN: take the labelled Base site file with data_take type=base_site, then propose again")
    if not base:
        refuse("STANDARD_MERGE_BASE_SITE_MISSING: a merge needs the site to merge into: the engineer labels its SQL-only backup Base site on the Files tab")
    settings = request.get("settings")
    if settings is not None and (not isinstance(settings, str) or not INPUT_ID.fullmatch(settings)
                                 or (inputs.get(settings) or {}).get("type") != MERGE_SETTINGS_TYPE):
        refuse("STANDARD_MERGE_SETTINGS_INVALID: settings must name a registered input of type merge-settings")
    argv = ["standard", "plan", "propose", ws.name, "--operation", "merge", "--source", source, "--base-site", base]
    if settings is not None:
        argv += ["--settings", settings]
    preparation = preparation_document(ws, request)
    argv += ["--" + key.replace("_", "-") for key, value in options.items() if value]
    # Bind the workspace to the converter checkout's committed branch head: the merge layer, if the
    # project has one, is read from exactly that commit. A dirty checkout refuses: commit first.
    converter = json.loads(ws.control(["standard", "converter", "refresh", ws.name, "--if-changed"], timeout=30))
    # checks the registered inputs (a backup can be GBs)
    with PlanDocuments(ws, {"--preparation": ("STANDARD_PREPARATION_INVALID", preparation)}) as extra:
        plan = json.loads(ws.control(argv + extra, timeout=240))
    if pending := runtime_preparing(plan):
        return pending
    merge = plan.get("merge") or {}
    layer = merge.get("layer") or {}
    return {**{key: plan.get(key) for key in ("plan_id", "digest", "status", "operation", "roles", "inputs", "base_site", "merge", "review_runtime",
                                              "converter_revision", "limits", "mutations", "not_included")},
            **({"preparation": plan["preparation"]} if "preparation" in plan else {}),
            "converter_branch": converter.get("branch"),
            "instances": {"review": {"port": ((plan.get("instances") or {}).get("review") or {}).get("port")}},
            "next": ("Tell the engineer the merge is waiting in the Project page's Runs tab, where they approve and start it. " +
                     ("It runs the project's merge layer (%s at %s) on top of Discourse's merger. " % (layer.get("path"), str(layer.get("revision") or "")[:12])
                      if layer.get("present") else "It runs Discourse's own merger with no project merge layer. ") +
                     (base_site_warning(plan["base_site"]) + " " if (plan.get("base_site") or {}).get("ahead") else "") +
                     "When it has finished, read it with data_run_evidence.")}


def op_propose_finding(ws, request):
    text = request.get("text")
    run_id = request.get("run_id")
    if not isinstance(text, str) or not text.strip() or len(text.encode("utf-8")) > MAX_FINDING:
        refuse("STANDARD_ARGUMENTS_INVALID: text")
    if run_id is None:
        argv = ["standard", "finding", "propose", ws.name, "--kind", "schema", "--file", "-"]
    elif isinstance(run_id, str) and RUN.fullmatch(run_id):
        argv = ["standard", "finding", "propose", ws.name, "--run", run_id, "--file", "-"]
    else:
        refuse("STANDARD_ARGUMENTS_INVALID: run_id")
    result = json.loads(ws.control(argv, input=text))
    return {"finding_id": result.get("finding_id"), "status": result.get("status"), "kind": "schema" if run_id is None else "finding",
            "note": "private proposal; the engineer reviews and decides what is released to coding agents"}


# -- dispatch ------------------------------------------------------------------------------

# -- project notes: migration-data's memory, one file per workspace ---------------------------
# term-llm's own memory is kept per agent, so with one agent for every customer it would mix
# projects. Notes live in the workspace instead and are reached only through that workspace.

NOTES_JSON_BYTES = 40 * 1024  # as JSON, so a read always fits the tool output whole
NOTES_VERSIONS = 20


def notes_path(ws):
    return ws.data_dir() / "notes.md"


def op_notes(ws, request):
    if not ws.initialized():
        return {"notes": "", "updated_at": None, "note": "a new project: the workspace doesn't exist yet (data_create makes it)"}
    path = notes_path(ws)
    if path.is_symlink():
        refuse("STANDARD_PATH_INVALID")
    if not path.is_file():
        return {"notes": "", "updated_at": None, "note": "no notes yet: keep them with data_notes_write"}
    info = path.stat()
    return {"notes": path.read_text(encoding="utf-8", errors="replace"), "bytes": info.st_size,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(info.st_mtime))}


def op_notes_write(ws, request):
    ws.require(standard=False)
    text = request.get("text")
    if not isinstance(text, str) or not text.strip() or "\x00" in text:
        refuse("STANDARD_ARGUMENTS_INVALID: text")
    if len(json.dumps(text, ensure_ascii=False).encode("utf-8")) > NOTES_JSON_BYTES:
        refuse("STANDARD_NOTES_TOO_LARGE: keep notes under about 32 KiB; summarise older parts")
    with ws.lock():
        path = notes_path(ws)
        if path.is_symlink():
            refuse("STANDARD_PATH_INVALID")
        history = ws.data_dir("notes-history")
        temporary = path.with_name(".notes." + secrets.token_hex(4))
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text if text.endswith("\n") else text + "\n")
        if path.is_file():
            # The previous version is kept (a second name for it, so notes.md never goes missing);
            # nanosecond names sort in the order they were written.
            os.link(path, history / ("%020d.md" % time.time_ns()))
        os.replace(temporary, path)
        for old in sorted(history.glob("*.md"))[:-NOTES_VERSIONS]:
            old.unlink()
    return {"bytes": path.stat().st_size, "previous_versions": len(list(history.glob("*.md")))}


# -- decisions: choices that must survive any chat ---------------------------------------------
# Append-only. Unlike the notes, nothing rewrites an entry: a changed decision is a new entry on
# the same topic. Kept apart from data_notes so that the notes still always fit a read whole.
# Every entry says what it rests on, so an assumption can't read as the engineer's ruling.

MAX_DECISION_TOPIC = 120
MAX_DECISION = 2000
DECISIONS_SHOWN = 200
DECISION_BASES = ("engineer_ruling", "default")


def decisions_path(ws):
    return ws.data_dir() / "decisions.jsonl"


def read_decisions(ws):
    """Oldest first. A damaged line is skipped rather than hiding every other decision."""
    try:
        fd = os.open(decisions_path(ws), os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return []
    except OSError:
        refuse("STANDARD_PATH_INVALID")
    entries = []
    with os.fdopen(fd, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict):
                entries.append(entry)
    return entries


def op_decide(ws, request):
    ws.require(standard=False)
    topic, decision = request.get("topic"), request.get("decision")
    if not isinstance(topic, str) or not topic.strip() or len(topic) > MAX_DECISION_TOPIC or re.search(r"[\x00-\x1f]", topic):
        refuse("STANDARD_ARGUMENTS_INVALID: topic")
    if not isinstance(decision, str) or not decision.strip() or len(decision) > MAX_DECISION or "\x00" in decision:
        refuse("STANDARD_ARGUMENTS_INVALID: decision")
    basis = request.get("basis")
    if basis not in DECISION_BASES:
        refuse("STANDARD_ARGUMENTS_INVALID: basis")
    entry = {"id": "decision-" + secrets.token_hex(8), "at": now(), "topic": topic.strip(), "decision": decision.strip(), "basis": basis}
    with ws.lock():
        ws.append("decisions.jsonl", entry)
    return {"id": entry["id"], "at": entry["at"]}


def op_decisions(ws, request):
    if not ws.initialized():
        return {"decisions": [], "total": 0}
    # Entries written before `basis` existed can't be told apart, so they say so.
    entries = [dict({"basis": "not_recorded"}, **entry) for entry in read_decisions(ws)]
    return {"decisions": entries[-DECISIONS_SHOWN:][::-1], "total": len(entries)}


# -- the guide: one computed answer to "where are we and what's next" --------------------------
# Worked out from disk on every call and never remembered, so a new chat knows as much as an old
# one. Only stages, IDs, statuses, codes and totals: no file names or customer values.

GUIDE_STAGES = (("files", "Customer files received"), ("workspace", "Workspace created"), ("source_db", "Source database loaded"),
                ("finding", "Finding released"), ("converter", "Converter pushed"), ("convert", "Convert run passed its checks"),
                ("review", "Review import passed its checks"), ("site", "Site accepted (the customer approved it)"))
GUIDE_RECENT = 10
GUIDE_ACTIVE = ("claimed", "running")
NO_SITE = {"accepted": None, "checked": None, "by_run": {}, "changed": []}
DEFAULT_CONTACT = "your node admin"
MAX_CONTACT = 200


def support_contact(ws):
    """The person to ask, set per server by the node admin (`silo set-contact`)."""
    try:
        fd = os.open(ws.prefix / "etc" / "support-contact", os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as handle:
            text = handle.read(MAX_CONTACT * 4 + 1).decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return DEFAULT_CONTACT
    text = text.strip()
    return text if text and len(text) <= MAX_CONTACT and not re.search(r"[\x00-\x1f]", text) else DEFAULT_CONTACT


def guide_records(ws):
    """The workbench's own view of plans and runs (it knows staleness and dead processes), joined
    with what that view leaves out: each plan's kind, findings and converter pushes."""
    standard = ws.root / ".silo-migrate/named/standard"
    empty = {"plans": [], "runs": [], "sites": [], "findings": [], "pushes": [], "warning": None}
    state_file = standard / "state.json"
    if standard.is_symlink() or state_file.is_symlink() or not state_file.is_file():
        return empty
    state = ws.read_json(state_file, {})
    state = state if isinstance(state, dict) else {}
    bodies = state.get("plans") if isinstance(state.get("plans"), dict) else {}
    kinds = {key: str((plan.get("body") or {}).get("operation") or "").replace("standard_", "") or None
             for key, plan in bodies.items() if isinstance(plan, dict)}
    try:
        status = json.loads(ws.control(["standard", "status", ws.name], timeout=45))
    except (Refusal, ValueError, subprocess.SubprocessError) as error:
        return dict(empty, findings=guide_findings(state), pushes=guide_pushes(standard),
                    warning=str(error).split(":")[0] if isinstance(error, Refusal) else "STANDARD_OPERATION_FAILED")
    lineage = {plan.get("plan_id"): plan.get("file_role_lineage_current", True) is True for plan in status.get("plans", [])}
    named_inputs = (ws.named_state().get("inputs") or {})

    def dataset_of(plan_id, seen=None):
        seen = set() if seen is None else seen
        if plan_id in seen:
            return None
        seen.add(plan_id)
        body = (bodies.get(plan_id) or {}).get("body") or {}
        delivery = body.get("delivery") or {}
        dataset = body.get("dataset_id") or delivery.get("dataset_id")
        source = (body.get("roles") or {}).get("source")
        if not dataset and source:
            bound = next((item for item in body.get("input_binding", []) if item.get("id") == source), {})
            dataset = bound.get("dataset_id") or (named_inputs.get(source) or {}).get("dataset_id")
        if not dataset:
            from_run = body.get("from_run") or {}
            from_run = from_run.get("run_id") if isinstance(from_run, dict) else from_run
            parent = (state.get("runs") or {}).get(from_run) or {}
            if parent.get("plan_id"):
                dataset = dataset_of(parent["plan_id"], seen)
        return dataset

    plans = [{"plan_id": plan.get("plan_id"), "file_role_lineage_current": lineage.get(plan.get("plan_id"), True), "dataset_id": dataset_of(plan.get("plan_id")), "kind": kinds.get(plan.get("plan_id")), "status": plan.get("status"), "delivery": plan.get("delivery"),
              "run_id": plan.get("run_id"), "created_at": plan.get("created_at") or ""} for plan in status.get("plans", [])]
    runs = []
    for run in status.get("runs", []):
        results = run.get("results") or {}
        failure = run.get("failure")
        runs.append({"run_id": run.get("run_id"), "plan_id": run.get("plan_id"),
                     "file_role_lineage_current": lineage.get(run.get("plan_id"), True), "dataset_id": dataset_of(run.get("plan_id")),
                     "delivery": ((bodies.get(run.get("plan_id")) or {}).get("body") or {}).get("delivery"), "kind": kinds.get(run.get("plan_id")), "status": run.get("status"),
                     "stage": run.get("stage"), "started_at": run.get("started_at") or "", "finished_at": run.get("finished_at"),
                     "checks": results.get("reconciliation_checks") or 0, "matched": results.get("reconciliation_matched") or 0,
                     "differ": results.get("reconciliation_differs") or 0, "errors": results.get("reconciliation_errors") or 0,
                     "release": run.get("release"), "backup": (run.get("artifacts") or {}).get("backup"),
                     "import_issues": results.get("import_issues"), "failure": failure.get("code") if isinstance(failure, dict) else None})
    sites = [{"run_id": site.get("run_id"), "state": site.get("state"), "live": site.get("live"), "port": site.get("port")}
             for site in status.get("instances", []) if site.get("role") == "review" and site.get("state") != "removed"]
    return {"plans": plans, "runs": runs, "sites": sites, "findings": guide_findings(state), "pushes": guide_pushes(standard), "warning": None}


def guide_findings(state):
    found = state.get("findings") if isinstance(state.get("findings"), dict) else {}
    out = []
    for key, record in found.items():
        if isinstance(record, dict):
            release = record.get("release") if isinstance(record.get("release"), dict) else {}
            out.append({"id": key, "status": record.get("status"), "at": release.get("released_at") or record.get("proposed_at") or ""})
    return sorted(out, key=lambda item: str(item["at"]))


def guide_pushes(standard):
    """Oldest first. Only the newest proposal for a branch can still be pushed."""
    directory = standard / "converter-pushes"
    if directory.is_symlink() or not directory.is_dir():
        return []
    records = []
    for path in sorted(directory.glob("*.json")):
        if path.is_symlink() or not DIGEST.fullmatch(path.stem):
            continue
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(record, dict) and isinstance(record.get("proposal"), dict):
            records.append(record)
    records.sort(key=lambda record: str(record.get("proposed_at") or ""))
    newest = {record["proposal"].get("branch"): index for index, record in enumerate(records)}
    return [{"id": record.get("digest"), "at": str(record.get("pushed_at") or record.get("proposed_at") or ""),
             "status": "superseded" if record.get("status") == "proposed" and newest[record["proposal"].get("branch")] != index else record.get("status")}
            for index, record in enumerate(records)]


def guide_passed(run):
    return bool(run) and run["status"] == "completed" and run["checks"] > 0 and run["matched"] == run["checks"]


def guide_problem(run, kind):
    """What to do about a run that finished without passing, or None if it passed or is still going."""
    label = "The %s run %s" % (kind, run["run_id"])
    if run["status"] in GUIDE_ACTIVE or guide_passed(run):
        return None
    if run["status"] in ("abandoned", "not_started"):
        return ("engineer", label + " stopped without finishing. Recover it in the Project page's Runs tab, then a new plan can be proposed.", "Runs tab")
    if run["status"] != "completed":
        return ("agent", "%s failed at stage %s (%s). Read data_run_evidence and explain the cause." % (label, run["stage"], run["failure"] or "no code"), "this chat")
    if not run["checks"]:
        return ("agent", label + " has no count checks, so nothing proved it. Register checks and propose it again.", "this chat")
    return ("agent", "%s finished with %d of %d checks matching (%d differ, %d errors). Read data_run_evidence and explain why; "
            "a difference stops the process until it's explained." % (label, run["matched"], run["checks"], run["differ"], run["errors"]), "this chat")


def guide_site(review, site, records):
    """The next step once the latest review import has passed: the engineer's verdict on its site."""
    verdict = site["by_run"].get(review["run_id"])
    live = any(item["run_id"] == review["run_id"] and item["live"] for item in records["sites"])
    reset = " Its review site is still up and holds customer data until it's reset in the Runs tab." if live else ""
    if verdict and verdict["verdict"] == "needs_changes":
        return ("agent", "The engineer says the site of review run %s needs changes: \"%s\". Work out the cause with them. The note may hold customer "
                "details: never quote it to converter-developer; if the converter must change, propose a finding that describes the problem with "
                "invented examples (the engineer releases it), then a push and a new pass." % (review["run_id"], verdict["note"]), "this chat")
    if verdict and verdict["basis"] == "customer":
        return ("nobody", "The process of review run %s is accepted: the customer approved it (recorded by %s). Launch repeats it; when the launch dump "
                "arrives the engineer labels it Launch. Running on launch data isn't built yet.%s" % (review["run_id"], verdict["by"], reset), "Runs tab")
    if verdict:
        return ("engineer", "You checked the site of review run %s yourself. Once the customer approves it, accept it again on its pass in the Runs tab "
                "with \"the customer approved it\": that is the process launch repeats.%s" % (review["run_id"], reset), "Runs tab")
    if live:
        return ("engineer", "Open the review site of run %s through the SSH tunnel shown in the Runs tab and check it, then accept it or say what needs "
                "changing on its pass. Reset it before the next review run." % review["run_id"], "Runs tab")
    return ("engineer", "Review run %s passed and its site is gone: accept it on its pass in the Runs tab, or say what needs changing." % review["run_id"], "Runs tab")


def guide_acceptance(site):
    """For the agent: the accepted process (the customer's approval), the engineer's own latest check,
    and what changed since the acceptance. No file names: IDs, versions and commits."""
    def brief(entry):
        return entry and {key: entry.get(key) for key in ("id", "run_id", "data", "converter", "by", "at", "note")}
    note = None if site["accepted"] else "nothing accepted yet: the engineer accepts a passing import's site on its pass in the Runs tab"
    if site.get("accepted_lineage_current") is False:
        note = "The recorded acceptance is historical: its input set changed. Prepare a fresh conversion/merge and review."
    return {"accepted": brief(site["accepted"]), "own_check": brief(site["checked"]), "changed_since_acceptance": site["changed"], "note": note}


def guide_flow(ws, facts, records, site=NO_SITE):
    """The next step along the stages, once nothing is running or waiting on the engineer."""
    copy_files = ("engineer", "Copy the customer's files to the drop folder (%s) with scp, then run `silo intake %s` as root." % (ws.intake, ws.name), "server terminal")
    if not facts["initialized"]:
        if facts["drop_files"]:
            return ("engineer", "On the Files tab, create the workspace (it asks for the source platform), then say what the files are for.", "Project page")
        return copy_files
    if facts["labelled_files"]:
        return ("agent", "Take the labelled files in the drop folder with data_take, each with a clear type." +
                (" Base site files must use type=base_site; never load them as source data." if facts.get("base_site") else ""), "this chat")
    if not facts["inputs"]:
        return copy_files
    runs = records["runs"]
    converts = [run for run in runs if run["kind"] == "convert"]
    reviews = [run for run in runs if run["kind"] == "review"]
    if not facts["db_loaded"] and not runs:
        return ("agent", "Start the source database with data_db_up and load the dump with data_db_load.", "this chat")
    released = [item for item in records["findings"] if item["status"] == "released"]
    if not released and not runs:
        return ("agent", "Profile the source database and propose a finding with data_propose_finding, so converter work can start.", "this chat")
    pushed = [item for item in records["pushes"] if item["status"] == "pushed"]
    last_push = pushed[-1]["at"] if pushed else ""
    # Newer than the last push and the last convert run: following the "no change needed" advice
    # and running a convert run settles a finding just as a push does.
    if released and released[-1]["at"] > max(last_push, converts[-1]["started_at"] if converts else ""):
        return ("engineer", "Open a converter-developer chat in this project and ask it to work from released finding %s. If the converter needs no change for it, "
                "ask migration-data to propose a convert run instead." % released[-1]["id"], "new chat")
    latest = converts[-1] if converts else None
    if not latest or latest["started_at"] < last_push:
        return ("agent", "Register the converter settings and count checks if they aren't already, then propose a convert run with data_plan_propose.", "this chat")
    problem = guide_problem(latest, "convert")
    if problem:
        return problem
    review = reviews[-1] if reviews else None
    if not review or review["started_at"] < latest["started_at"]:
        return ("agent", "Propose a review import of the passed convert run with data_plan_propose from_run=%s. Destination count checks need registering first if they aren't." % latest["run_id"], "this chat")
    problem = guide_problem(review, "review")
    if problem:
        return problem
    return guide_site(review, site, records)


def guide_stages(facts, records, site=NO_SITE):
    """Which stages are done. A later stage's evidence counts for the ones before it, since not
    every migration needs each of them (an existing converter needs no finding or push)."""
    runs = records["runs"]
    latest = {}
    for run in runs:
        latest[run["kind"]] = run
    convert, review = latest.get("convert"), latest.get("review")
    done = {"files": facts["drop_files"] > 0 or facts["inputs"] > 0, "workspace": facts["initialized"],
            "source_db": facts["db_loaded"] or bool(runs), "finding": any(item["status"] == "released" for item in records["findings"]) or bool(runs),
            "converter": any(item["status"] == "pushed" for item in records["pushes"]) or bool(runs),
            "convert": guide_passed(convert), "review": guide_passed(review) and review["started_at"] >= (convert or {}).get("started_at", "")}
    # Accepted on the customer's approval, for the latest import.
    done["site"] = bool(done["review"] and site["accepted"] and site["accepted"]["run_id"] == review["run_id"])
    stages_spec = GUIDE_STAGES
    if facts.get("base_site"):
        stages_spec = tuple((key, "Import on " + facts["base_site"] if key == "review" else "Check site" if key == "site" else label)
                            for key, label in GUIDE_STAGES) + (("release", "Release backup"),)
        done["site"] = bool(done["review"] and any((site.get(key) or {}).get("run_id") == review["run_id"] for key in ("checked", "accepted")))
        passed = [run for run in runs if run.get("kind") == "review" and guide_passed(run)]
        done["release"] = bool(passed and passed[-1].get("release"))
    current = next((key for key, _label in stages_spec if not done[key]), "accepted")
    stages = [{"id": key, "label": label, "state": "done" if done[key] else "current" if key == current else "to_do"} for key, label in stages_spec]
    return current, stages


MERGE_GUIDE_STAGES = (("files", "Customer files received"), ("workspace", "Workspace created"), ("source", "Source site backup taken"),
                      ("base", "Site to merge into taken"), ("merge", "Merge run finished"), ("release", "Release backup"))


def guide_merge_runs(records):
    return [run for run in records["runs"] if run["kind"] == "merge"]


def guide_merge_stages(facts, records):
    """A merge project's stages: one Discourse site (the source backup) into another (the Base site)."""
    merges = guide_merge_runs(records)
    latest = merges[-1] if merges else None
    finished = bool(latest) and latest["status"] == "completed"
    done = {"files": facts["drop_files"] > 0 or facts["inputs"] > 0, "workspace": facts["initialized"],
            "source": facts["merge_source"] > 0 or bool(merges), "base": facts["base_taken"] or bool(merges),
            "merge": finished, "release": finished and bool(latest.get("release"))}
    current = next((key for key, _label in MERGE_GUIDE_STAGES if not done[key]), "released")
    return current, [{"id": key, "label": label, "state": "done" if done[key] else "current" if key == current else "to_do"}
                     for key, label in MERGE_GUIDE_STAGES]


def guide_merge_flow(ws, facts, records):
    """The next step of a merge project, once nothing is running or waiting on the engineer."""
    if not facts["initialized"]:
        if facts["drop_files"]:
            return ("engineer", "On the Files tab, create the workspace (it asks for the source platform), then say what the files are for.", "Project page")
        return ("engineer", "Copy the source site's full backup (with uploads) and the SQL-only backup of the site to merge into to the drop folder (%s) "
                "with scp, then run `silo intake %s` as root." % (ws.intake, ws.name), "server terminal")
    if facts["labelled_files"]:
        return ("agent", "Take the labelled files with data_take: the source site's full backup (Development) with type=discourse-backup and its "
                "original name; the Base site file with type=base_site. Never extract or load either yourself.", "this chat")
    merges = guide_merge_runs(records)
    if not facts["merge_source"] and not merges:
        return ("engineer", "Copy the source site's full backup (with uploads, original name) to the drop folder (%s), run `silo intake %s` as root, "
                "then label it Development on the Files tab." % (ws.intake, ws.name), "server terminal")
    if not facts["base_taken"] and not merges:
        if facts.get("base_site"):
            return ("agent", "Take the labelled Base site file with data_take type=base_site.", "this chat")
        return ("engineer", "Copy the SQL-only backup of the site to merge into (discourse backup --sql-only, original name) to the drop folder, run "
                "`silo intake %s` as root, then label it Base site on the Files tab." % ws.name, "server terminal")
    latest = merges[-1] if merges else None
    pushed = [item for item in records["pushes"] if item["status"] == "pushed"]
    if not latest or latest["started_at"] < (pushed[-1]["at"] if pushed else ""):
        return ("agent", "Propose the merge with data_merge_propose; the engineer approves and starts it on the Project page. If this merge needs rules of "
                "its own (for example source categories into chosen categories of the other site), the engineer first asks converter-developer for a "
                "merge layer, and you register the values it reads as type merge-settings.", "this chat")
    if latest["status"] in ("abandoned", "not_started"):
        return ("engineer", "The merge run %s stopped without finishing. Recover it in the Project page's Runs tab, then a new plan can be proposed." % latest["run_id"], "Runs tab")
    if latest["status"] != "completed":
        return ("agent", "The merge run %s failed at stage %s (%s). Read data_run_evidence and explain the cause. If the merge layer must change, propose a "
                "finding that describes the problem with invented examples (the engineer releases it to converter-developer)."
                % (latest["run_id"], latest["stage"], latest["failure"] or "no code"), "this chat")
    live = any(item["run_id"] == latest["run_id"] and item["live"] for item in records["sites"])
    if latest.get("release"):
        return ("engineer", "Copy the released backup from the output folder and restore it on the hosted migration site. That restore is outside this tool.%s"
                % (" Reset the merged site in the Runs tab when you're done with it: it holds customer data." if live else ""), "Runs tab")
    if live:
        return ("engineer", "Open the merged site of run %s through the SSH tunnel shown in the Runs tab and check it. Then release the backup for customer "
                "review, or say what needs changing in a chat." % latest["run_id"], "Runs tab")
    return ("engineer", "Merge run %s finished and its site is gone: release its backup in the Runs tab, or ask migration-data to propose the merge again." % latest["run_id"], "Runs tab")


def guide_data(records, roles=None):
    """Which delivery is which: labels, versions and IDs only, never file names. The newest of each
    kind is current; launch work isn't possible yet, so development is what runs use."""
    ordered = sorted(records.values(), key=lambda record: record.get("sequence", 0), reverse=True)
    newest = {}
    for record in ordered:
        if not record.get("replaced_by"):
            newest.setdefault(record["kind"], record["dataset_id"])
    if roles is not None:
        newest = roles["active"]
    label_of = lambda kind: delivery_label(records[newest[kind]]) if newest.get(kind) in records else None  # noqa: E731
    return {"development": label_of("development"), "launch": label_of("launch"), "base_site": label_of("base_site"),
            "note": None if ordered else "no data is labelled yet: only the engineer can say what files are for",
            "deliveries": [{"label": delivery_label(record), "kind": record["kind"], "dataset_id": record["dataset_id"], "labelled_at": record["labelled_at"],
                            "state": "current" if newest.get(record["kind"]) == record["dataset_id"] else "replaced"} for record in ordered]}


def op_guide(ws, request):
    state = ws.named_state() if ws.initialized() else {}
    db = ws.read_json(ws.data / "db" / "state.json", None) if ws.initialized() and (ws.data / "db").is_dir() else None
    drop_files = 0
    if ws.intake.is_dir() and not ws.intake.is_symlink():
        for _path, _dirs, files, _dirfd in os.fwalk(str(ws.intake), follow_symlinks=False):
            drop_files += len(files)
    deliveries = read_deliveries(ws) if ws.initialized() else {}
    groups = split_drop_files(ws, deliveries) if ws.initialized() else {"labelled": [], "unlabelled": [], "refused": [], "not_ready": []}
    unlabelled = groups["unlabelled"]
    not_labelled = unlabelled_data(ws, deliveries) if ws.initialized() else []
    role_state = file_roles.load(ws, roles_api()) if ws.initialized() else None
    facts = {"initialized": ws.initialized() and (ws.root / ".silo-migrate/named/standard/state.json").is_file(), "drop_files": drop_files, "labelled_files": len(groups["labelled"]), "inputs": sum(1 for item in (state.get("inputs") or {}).values()
                           if item.get("type") != "base_site" and (deliveries.get(item.get("dataset_id")) or {}).get("kind") != "base_site"
                           and file_roles.input_is_source(role_state, item.get("id"))),
             "db_loaded": bool(db and db.get("loads")), "base_site": guide_data(deliveries, role_state)["base_site"]}
    merge = ws.initialized() and ws.meta().get("platform") == MERGE_PLATFORM
    scoped = ws.initialized() and (ws.data / "file-roles.json").exists()
    if scoped:
        current_base = [role_state["active"]["base_site"]] if role_state["active"].get("base_site") else []
    else:
        current_base = [record["dataset_id"] for record in deliveries.values() if record.get("kind") == "base_site" and not record.get("replaced_by")]
    facts.update(merge=merge, merge_source=sum(1 for item in (state.get("inputs") or {}).values() if item.get("type") == MERGE_SOURCE_TYPE and file_roles.input_is_source(role_state, item.get("id"))),
                 base_taken=any(item.get("type") == "base_site" and item.get("dataset_id") in current_base for item in (state.get("inputs") or {}).values()))
    if scoped:
        active_dataset = role_state["active"].get("development")
        current_inputs = [item for input_id, item in (state.get("inputs") or {}).items()
                          if active_dataset and item.get("dataset_id") == active_dataset and file_roles.input_is_source(role_state, input_id)]
        labelled_stamps = [{key: item[key] for key in IDENTITY} for item in groups["labelled"]]
        current_datasets = {dataset for dataset in (active_dataset, role_state["active"].get("base_site")) if dataset}
        facts["labelled_files"] = sum(item.get("dataset_id") in current_datasets and not item.get("input_id")
                                      and item["role"] in ("source", "base_site") and item.get("identity") in labelled_stamps
                                      for item in role_state["files"].values())
        facts["inputs"] = len(current_inputs)
        facts["merge_source"] = sum(item.get("type") == MERGE_SOURCE_TYPE for item in current_inputs)
        last_load = ((db or {}).get("loads") or [{}])[-1]
        load_dataset = last_load.get("dataset_id")
        if not load_dataset and last_load.get("path"):
            registered_load = find_registered(ws, last_load["path"]) or {}
            if registered_load.get("sha256") == last_load.get("sha256"):
                load_dataset = registered_load.get("dataset_id")
        facts["db_loaded"] = bool(active_dataset and load_dataset == active_dataset)
    records = guide_records(ws) if ws.initialized() else {"plans": [], "runs": [], "sites": [], "findings": [], "pushes": [], "warning": None}
    current_runs = [run for run in records["runs"] if run.get("file_role_lineage_current", True) is True
                    and (not scoped or (active_dataset and run.get("dataset_id") == active_dataset))]
    current_run_ids = {run["run_id"] for run in current_runs}
    stage_records = dict(records, runs=current_runs,
                         plans=[plan for plan in records["plans"] if plan.get("file_role_lineage_current", True) is True
                                and (not scoped or (active_dataset and plan.get("dataset_id") == active_dataset))],
                         sites=[site for site in records["sites"] if site.get("run_id") in current_run_ids])
    site_warning = None
    try:
        site = site_summary(ws, deliveries=deliveries, records=records) if ws.initialized() else NO_SITE
    except Refusal as refusal:
        site, site_warning = NO_SITE, str(refusal).split(":")[0]
    contact = support_contact(ws)
    active = [run for run in records["runs"] if run["status"] in GUIDE_ACTIVE]
    happening = ["%s run %s is %s (stage %s)." % (run["kind"] or "workflow", run["run_id"], run["status"], run["stage"]) for run in active]
    waiting, also = [], []
    if not_labelled:
        waiting.append({"what": "Review the data already in this project on the Project page; source snapshots and supporting references are separate.", "where": "Project page"})
    if unlabelled and not facts["initialized"]:  # a workspace begun but not finished (a failed clone, say)
        waiting.append({"what": "Finish creating the workspace on the Files tab, then say what the new files are for.", "where": "Project page"})
    elif unlabelled:
        arrived = "1 new file arrived" if len(unlabelled) == 1 else "%d new files arrived" % len(unlabelled)
        waiting.append({"what": arrived + ": say what they're for: choose a role (source snapshot, uploads/assets, supporting reference or Base site) on the Project page.", "where": "Project page"})
    if groups["refused"]:
        waiting.append({"what": "%d labelled file(s) can't be taken: each is identical to data of the other kind. Remove them from the drop folder." % len(groups["refused"]),
                        "where": "server terminal"})
    if groups["not_ready"]:
        waiting.append({"what": "%d file(s) in the drop folder aren't handed over yet, or have names that can't be shown: run `silo intake %s` as root, and rename any odd names."
                        % (len(groups["not_ready"]), ws.name), "where": "server terminal"})
    latest_start = {run["kind"]: run["started_at"] or "" for run in records["runs"]}
    for plan in records["plans"]:
        if plan["status"] not in ("proposed", "approved"):
            continue
        kind = plan["kind"] or "workflow"
        # Left behind by a later run of the same kind: worth tidying, but not the next step.
        if (plan["created_at"] or "") < latest_start.get(plan["kind"], ""):
            also.append("%s plan %s is older than the latest %s run and was never run: discard it in the Project page's Runs tab unless it's still wanted." % (kind, plan["plan_id"], kind))
        elif plan["status"] == "proposed":
            waiting.append({"what": "Approve or discard %s plan %s." % (kind, plan["plan_id"]), "where": "Runs tab"})
        else:
            waiting.append({"what": "Start approved %s plan %s." % (kind, plan["plan_id"]), "where": "Runs tab"})
    waiting += [{"what": "Review converter push %s and push it." % item["id"], "where": "Runs tab"} for item in records["pushes"] if item["status"] == "proposed"]
    waiting += [{"what": "Review finding %s and release, amend or reject it." % item["id"], "where": "Findings tab"} for item in records["findings"] if item["status"] == "proposed"]
    stale = [plan for plan in records["plans"] if plan["status"] == "stale"]
    if stale:
        also.append("Plan %s is out of date because something it depends on changed: propose it again, and discard the old one in the Project page's Runs tab." % stale[-1]["plan_id"])
    also += ["The review site of run %s is still up and holds customer data until it's reset in the Project page's Runs tab." % item["run_id"] for item in records["sites"]]
    if site_warning:
        also.append("The site reviews couldn't be read (%s), so acceptance shows as none: tell the engineer, and ask %s." % (site_warning, contact))
    if records["warning"]:
        step = ("agent", "Plans and runs couldn't be read (%s). Tell the engineer, and ask %s if it keeps happening." % (records["warning"], contact), "this chat")
    elif active:
        step = ("nobody", happening[0] + " Nothing is needed until it finishes.", "Runs tab")
    elif waiting:
        step = ("engineer", waiting[0]["what"], waiting[0]["where"])
    else:
        step = guide_merge_flow(ws, facts, stage_records) if merge else guide_flow(ws, facts, stage_records, site)
    current, stages = guide_merge_stages(facts, stage_records) if merge else guide_stages(facts, stage_records, site)
    if facts.get("base_site") and not merge and not active and not waiting and not records["warning"]:
        if current == "review" and step[0] == "agent" and step[1].startswith("Propose a review import"):
            step = ("agent", "Propose the review import on %s with data_plan_propose; the engineer approves and starts it on the Project page." % facts["base_site"], "this chat")
        elif current == "site" and step[0] == "engineer":
            step = ("engineer", "Check the site through the SSH tunnel, then record your own check on its pass. Next, release the backup for customer review.", "Runs tab")
        elif current == "release":
            step = ("engineer", "Release backup on the newest passed pass. Then copy it from the output folder and restore it on the hosted migration site; that restore is outside this tool.", "Runs tab")
        elif current == "accepted":
            step = ("engineer", "Copy the released backup from the output folder and restore it on the hosted migration site. That restore is outside this tool.", "Runs tab")
    return {"project": ws.name, "stage": current, "stages": stages, "happening": happening, "waiting_on_engineer": waiting,
            "next": {"who": step[0], "action": step[1], "where": step[2]}, "also": also,
            "plans": records["plans"][-GUIDE_RECENT:][::-1], "runs": records["runs"][-GUIDE_RECENT:][::-1],
            "data": guide_data(deliveries, role_state), "site_acceptance": guide_acceptance(site), "support_contact": contact,
            "decisions_recorded": len(read_decisions(ws)) if ws.initialized() else 0}


def supporting_module():
    spec = importlib.util.spec_from_file_location("supporting_files", Path(__file__).with_name("supporting_files.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def supporting_api():
    from types import SimpleNamespace
    return SimpleNamespace(open_root=open_root, open_regular=open_regular,
                           sandbox_argv=sandbox_argv, docker=docker, refuse=refuse)


_roles_spec = importlib.util.spec_from_file_location("file_roles", Path(__file__).with_name("file_roles.py"))
file_roles = importlib.util.module_from_spec(_roles_spec)
_roles_spec.loader.exec_module(file_roles)


def roles_api():
    from types import SimpleNamespace
    return SimpleNamespace(**globals())


def op_file_roles_preview(ws, request):
    return file_roles.preview(ws, request, roles_api())


def op_file_roles_commit(ws, request):
    return file_roles.commit(ws, request, roles_api())


def op_supporting(ws, request):
    """Supporting references deliberately bypass named-input/delivery mutation.
    Admission is a native locked-session capability supplied by the fixed adapter,
    not a model-selected upload path or workspace."""
    module = supporting_module()
    api = supporting_api()
    api.reference_active = lambda support_id: file_roles.reference_active(ws, support_id, roles_api())
    return module.handle(ws, request, api)


OPS = {"status": op_status, "list": op_list, "peek": op_peek, "create": op_create, "take": op_take, "register": op_register,
       "file_roles_preview": op_file_roles_preview, "file_roles_commit": op_file_roles_commit,
       "supporting_list": op_supporting, "supporting_take": op_supporting, "supporting_read": op_supporting,
       "supporting_prepare": op_supporting_prepare,
       "script": op_script, "extract": op_extract, "job": op_job, "db_up": op_db_up, "db_load": op_db_load,
       "db_status": op_db_status, "db_reset": op_db_reset, "run_evidence": op_run_evidence, "run_count": op_run_count, "propose_finding": op_propose_finding,
       "plan_propose": op_plan_propose, "merge_propose": op_merge_propose, "master_lists_propose": op_master_lists_propose,
       "notes": op_notes, "notes_write": op_notes_write, "guide": op_guide, "decide": op_decide, "decisions": op_decisions, "deliveries": op_deliveries, "delivery_label": op_delivery_label,
       "finding_done": op_finding_done, "site_process": op_site_process, "site_review": op_site_review}
# Logged with their arguments (minus script code, finding text, count SQL and decisions, logged by hash).
QUIET = {"status", "list", "job", "db_status", "notes", "guide", "decisions", "deliveries", "site_process"}


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
        if key in ("code", "text", "sql", "decision", "topic", "note") and isinstance(value, str):
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
            match = re.search(r"Error: ((?:STANDARD|NAMED)_[A-Z_]+)([^\n]*)", result.stderr)
            if not match:
                refuse("STANDARD_OPERATION_FAILED")
            # The code, plus the short detail some refusals add ("check 3: source_sql"): the text
            # after ": " up to the recovery sentence, kept only when it is short.
            detail = re.fullmatch(r": (.{1,200}?)(?:\. .*|\.)?", match[2])
            refuse(match[1] + (": " + detail[1] if detail else ""))
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
    # Set by migration-data's adapter on every request (the agent can't change it): chat tools
    # have 300 s, a shell has no limit.
    ws.chat = request.get("via") == "chat"
    op = request["op"]
    error = None
    try:
        result = dict(version=1, **OPS[op](ws, request))
        if op in ("deliveries", "file_roles_preview", "file_roles_commit") and not ws.chat:
            # Never silently slice structured identities/digests. Commit may omit
            # the refreshable inventory, but must not report failure after apply.
            if len(json.dumps(result, ensure_ascii=False).encode("utf-8")) > ENGINEER_OUTPUT_LIMIT:
                if op == "file_roles_commit":
                    result.pop("roles", None)
                    result["roles_omitted"] = True
                if len(json.dumps(result, ensure_ascii=False).encode("utf-8")) > ENGINEER_OUTPUT_LIMIT:
                    refuse("STANDARD_OUTPUT_TOO_LARGE")
            return result
        return fit(result)
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
