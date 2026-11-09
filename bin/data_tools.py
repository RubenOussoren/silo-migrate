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


def move_in(ws, meta, src_root, parts, dest_fd, name, relative, kind, provenance, owner_check=True):
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

DELIVERY_KINDS = ("development", "launch")
MAX_LABELLED_BY = 120


def deliveries_file(ws):
    return ws.root / ".silo-migrate/named/deliveries.json"


def read_deliveries(ws):
    """{dataset_id: record}. Nothing here is written by an agent."""
    path = deliveries_file(ws)
    if path.is_symlink():
        refuse("STANDARD_PATH_INVALID")
    document = ws.read_json(path, {})
    records = document.get("deliveries") if isinstance(document, dict) else None
    return records if isinstance(records, dict) else {}


def delivery_label(record):
    return "%s v%d" % (record["kind"].capitalize(), record["version"]) if record["kind"] == "development" else "Launch"


def drop_listing(ws):
    """Regular files in the drop folder: relative path, size and modification time."""
    if not ws.intake.is_dir() or ws.intake.is_symlink():
        return []
    files = []
    for folder, _dirs, names, dirfd in os.fwalk(str(ws.intake), follow_symlinks=False):
        for name in names:
            info = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
            if stat.S_ISREG(info.st_mode):
                relative = os.path.relpath(os.path.join(folder, name), str(ws.intake))
                files.append({"path": relative, "bytes": info.st_size, "mtime_ns": info.st_mtime_ns})
    return sorted(files, key=lambda item: item["path"])[:MAX_LIST]


def claimed_by(records, path, size, mtime_ns):
    """The dataset whose delivery holds exactly this file, or None. A changed file isn't claimed."""
    for dataset_id, record in records.items():
        for item in record.get("files") or []:
            if item.get("path") == path and item.get("bytes") == size and item.get("mtime_ns") == mtime_ns:
                return dataset_id
    return None


def split_drop_files(ws, records):
    labelled, unlabelled = [], []
    for item in drop_listing(ws):
        (labelled if claimed_by(records, item["path"], item["bytes"], item["mtime_ns"]) else unlabelled).append(item)
    return labelled, unlabelled


def unlabelled_data(ws, records):
    """Datasets already holding files but never labelled: anything taken before labels existed."""
    state = ws.named_state()
    holding = {record.get("dataset_id") for record in (state.get("inputs") or {}).values()}
    return [dataset_id for dataset_id in (state.get("datasets") or {}) if dataset_id in holding and dataset_id not in records]


def delivery_of_take(ws, root, parts, relative):
    """The dataset this file goes into. Only the engineer's label makes a file takeable."""
    pending = ws.read_json(pending_for(ws, relative), None)
    if pending:  # finishing an interrupted take: already decided
        return pending["provenance"].get("dataset_id") or ws.meta()["dataset_id"]
    records = read_deliveries(ws)
    fd, info = open_regular(root, parts)
    try:
        dataset = claimed_by(records, "/".join(parts), info.st_size, info.st_mtime_ns)
        if dataset is None:
            refuse("STANDARD_DELIVERY_UNLABELLED: the engineer labels new files on the Project page")
        if records[dataset]["kind"] == "launch":
            refuse_if_development_copy(ws, records, fd, info)
    finally:
        os.close(fd)
    return dataset


def refuse_if_development_copy(ws, records, fd, info):
    """Launch data identical to a development delivery is almost certainly the wrong file. Only
    files of the same size are hashed, so this costs nothing in the normal case."""
    development = {dataset_id for dataset_id, record in records.items() if record["kind"] == "development"}
    candidates = [record for record in (ws.named_state().get("inputs") or {}).values()
                  if record.get("dataset_id") in development and record.get("bytes") == info.st_size]
    if candidates:
        os.lseek(fd, 0, os.SEEK_SET)
        digest = sha256_fd(fd)
        if any(record.get("sha256") == digest for record in candidates):
            refuse("STANDARD_DELIVERY_SAME_AS_DEVELOPMENT")


def engineer_only(ws):
    # Agents have no mapping to these operations. This is a second lock on the same door.
    if ws.chat:
        refuse("STANDARD_DATA_OPERATION_REFUSED")


def op_deliveries(ws, request):
    """The engineer's view for the Project page. It holds file names, so it never reaches a chat."""
    engineer_only(ws)
    if not ws.initialized():
        return {"initialized": False, "deliveries": [], "unlabelled_files": [], "labelled_files": [], "unlabelled_data": []}
    records = read_deliveries(ws)
    labelled, unlabelled = split_drop_files(ws, records)
    return {"initialized": True, "deliveries": sorted(records.values(), key=lambda record: record["labelled_at"], reverse=True),
            "unlabelled_files": unlabelled, "labelled_files": labelled, "unlabelled_data": unlabelled_data(ws, records)}


def op_delivery_label(ws, request):
    """Set what a delivery is for. Engineer only, from the Project page. A label never changes."""
    engineer_only(ws)
    ws.require(standard=False)
    kind, by = request.get("kind"), request.get("by")
    if kind not in DELIVERY_KINDS:
        refuse("STANDARD_ARGUMENTS_INVALID: kind")
    if not isinstance(by, str) or not by.strip() or len(by) > MAX_LABELLED_BY or re.search(r"[\x00-\x1f]", by):
        refuse("STANDARD_ARGUMENTS_INVALID: by")
    if kind == "launch" and request.get("confirm") != "LAUNCH":
        refuse("STANDARD_DELIVERY_CONFIRM_LAUNCH")
    with ws.lock():
        records, meta = read_deliveries(ws), ws.meta()
        same_kind = [record for record in records.values() if record["kind"] == kind]
        if kind == "launch" and same_kind and request.get("replaces_launch") is not True:
            refuse("STANDARD_DELIVERY_LAUNCH_EXISTS")
        state = ws.named_state()
        untagged = [dataset_id for dataset_id in (state.get("datasets") or {}) if dataset_id not in records]
        holding = set(unlabelled_data(ws, records))
        files = []
        if "dataset_id" in request:  # data taken before labels existed
            dataset_id = request["dataset_id"]
            if kind != "development" or dataset_id not in holding or "files" in request:
                refuse("STANDARD_ARGUMENTS_INVALID: dataset_id")
        else:
            if holding:
                refuse("STANDARD_DELIVERY_LABEL_EXISTING_FIRST")
            wanted = request.get("files")
            if not isinstance(wanted, list) or not wanted or not all(isinstance(item, dict) for item in wanted):
                refuse("STANDARD_ARGUMENTS_INVALID: files")
            _labelled, unlabelled = split_drop_files(ws, records)
            current = {item["path"]: item for item in unlabelled}
            for item in wanted:
                if current.get(item.get("path")) != {key: item.get(key) for key in ("path", "bytes", "mtime_ns")}:
                    refuse("STANDARD_DELIVERY_FILES_CHANGED: the files changed since the page loaded")
            files = [current[item["path"]] for item in wanted]
            if untagged:
                dataset_id = untagged[0]
            else:
                dataset_id = json.loads(ws.control(["named", "dataset", "add", ws.name, "--source", meta["source_id"], "--label", kind]))["dataset_id"]
        version = 1 + max((record["version"] for record in same_kind), default=0)
        record = {"dataset_id": dataset_id, "kind": kind, "version": version, "labelled_at": now(), "labelled_by": by.strip(), "files": files}
        records[dataset_id] = record
        ws.write_json(deliveries_file(ws), {"version": 1, "deliveries": records})
        meta["dataset_id"] = dataset_id
        ws.write_json(ws.data_dir() / "workspace.json", meta)
    return {"dataset_id": dataset_id, "kind": kind, "delivery": delivery_label(record), "files": len(files)}


def op_take(ws, request):
    """Move one file from the drop folder into inputs/, make it read-only, register it."""
    ws.require()
    parts = parts_of(request.get("path"))
    kind = request.get("type")
    if not isinstance(kind, str) or not TYPE.fullmatch(kind):
        refuse("STANDARD_ARGUMENTS_INVALID: type")
    name = dest_name(request.get("name"), parts[-1])
    with ws.lock():
        meta = ws.meta()
        if not meta.get("dataset_id"):
            refuse("STANDARD_NOT_INITIALIZED")
        root, inputs = ws.open_area("intake"), None
        try:
            inputs = ws.open_area("inputs")
            dataset = delivery_of_take(ws, root, parts, "inputs/" + name)
            result = move_in(ws, dict(meta, dataset_id=dataset), root, parts, inputs, name, "inputs/" + name, kind,
                             {"event": "take", "from": "intake/" + "/".join(parts), "dataset_id": dataset})
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
    name = dest_name(request.get("name"), parts[0] + "-" + parts[-1])
    with ws.lock():
        meta = ws.meta()
        jobs = refresh_jobs(ws)
        if any(job.get("into") == parts[0] and job.get("status") == "running" for job in jobs):
            refuse("STANDARD_BUSY")
        producer = next((job for job in reversed(jobs) if job.get("into") == parts[0]), None)
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
                              "job": producer and {key: producer.get(key) for key in ("id", "kind", "script_sha256", "inputs", "source")}})
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
        refuse("STANDARD_ARGUMENTS_INVALID: path")
    limit = minutes(request)
    with ws.lock():
        digest = registered(ws, "/".join(parts))["sha256"]
        root = ws.open_area("inputs")
        try:
            fd, _info = open_regular(root, parts[1:])
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
                                             "script_sha256", "timeout_minutes", "source", "error", "read_only_user_checked")}
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
                                                        "engine": engine, "charset": charset, "timeout_minutes": limit})
        state["loads"].append({"job_id": record["id"], "path": "/".join(parts), "sha256": record["source"]["sha256"], "started_at": record["started_at"]})
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
# limited to migration-data with `agents:`. term-llm starts it per chat as
# `silo-migrate-control dbhub <project>` (stdio), which runs DBHub in a container on the
# project's internal network as the read-only user. term-llm 0.9.93 ignores `agents:` (and
# drops it when the web UI rewrites mcp.json): until the pinned term-llm enforces it, any
# chat's MCP button can switch it on, so `silo doctor` warns and every data_db_up /
# data_db_status puts the entry back as it should be.

DBHUB_IMAGE = "bytebase/dbhub:1.5.1@sha256:86edce0447fd9d4bd9eeb7cea7dd3b83473b732a0c437c552b36004c034ff5a9"
DBHUB_MAX_ROWS = 50
MCP_AGENT = "migration-data"
DBHUB_DSN = {"mariadb": "mariadb://" + RO_USER + ":${DB_PASSWORD}@source-db:3306/source?sslmode=disable",
             "postgres": "postgres://" + RO_USER + ":${DB_PASSWORD}@source-db:5432/source?sslmode=disable"}


def mcp_config_path():
    return Path(os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")) / "term-llm" / "mcp.json"


def mcp_name(ws):
    return "db-" + ws.name


def mcp_entry(ws):
    # The installed shim sets the control config itself; term-llm passes it no environment.
    repo = ws.repo.resolve()
    control = repo.parent.parent / "bin/silo-migrate-control" if repo.parent.name == "releases" else repo / "bin/silo-migrate-control"
    return {"command": str(control), "args": ["dbhub", ws.name], "agents": [MCP_AGENT]}


def mcp_register(ws, present=True):
    """Put this project's entry in mcp.json (or take it out), leaving everything else as it is.
    Returns "added", "registered" (already right), "removed", "absent" or why nothing changed."""
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
        if present and existing == entry:
            return "registered"
        if not present and existing is None:
            return "absent"
        if present:
            servers[name] = entry
        else:
            del servers[name]
        temporary = path.with_name("." + path.name + ".silo-" + secrets.token_hex(4))
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(config, handle, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
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
    """The run ID, or the run a plan ID started (the Runs widget shows both); returns the run ID."""
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
    return {"run_id": run_id, "evidence": json.loads(ws.control(["standard", "analyst", "evidence", ws.name, run_id]))}


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


def op_plan_propose(ws, request):
    """Propose conversion from inputs or review from a completed convert run.
    Only a proposal: the engineer approves and starts it."""
    ws.require()
    from_run = request.get("from_run")
    if "from_run" in request:
        if (not isinstance(from_run, str) or not RUN.fullmatch(from_run)
                or any(key in request for key in ("source", "settings", "charset"))):
            refuse("STANDARD_ARGUMENTS_INVALID: from_run")
        reconciliation = request.get("reconciliation")
        if reconciliation is not None and (not isinstance(reconciliation, str) or not INPUT_ID.fullmatch(reconciliation)):
            refuse("STANDARD_ARGUMENTS_INVALID: reconciliation")
        argv = ["standard", "plan", "propose", ws.name, "--operation", "review", "--from-run", from_run]
        if reconciliation is not None:
            argv += ["--reconciliation", reconciliation]
        # The proposal hashes the convert run's intermediate database (can be GBs).
        plan = json.loads(ws.control(argv, timeout=120))
        return {**{key: plan.get(key) for key in ("plan_id", "digest", "status", "operation", "platform", "from_run",
                                                  "roles", "inputs", "limits", "mutations", "not_included")},
                "instances": {"review": {"port": ((plan.get("instances") or {}).get("review") or {}).get("port")}},
                "next": "Tell the engineer the plan is waiting in the Runs widget, where they approve and start it. Access the review site via an SSH tunnel; it stays until Reset."}
    roles = {key: request.get(key) for key in ("source", "settings", "reconciliation")}
    charset = request.get("charset", "utf8mb4")
    if roles["reconciliation"] is None:
        del roles["reconciliation"]
    if not all(isinstance(value, str) and INPUT_ID.fullmatch(value) for value in roles.values()) or charset not in CHARSETS:
        refuse("STANDARD_ARGUMENTS_INVALID: source, settings, reconciliation or charset")
    argv = ["standard", "plan", "propose", ws.name, "--operation", "convert", "--charset", charset,
            *[flag for key, value in roles.items() for flag in ("--" + key, value)]]
    prepared = None
    # Bind the workspace to the converter's committed branch head (a dirty checkout refuses:
    # commit first). The plan shows that commit and the engineer approves exactly it.
    converter = json.loads(ws.control(["standard", "converter", "refresh", ws.name, "--if-changed"], timeout=30))
    try:
        plan = json.loads(ws.control(argv, timeout=30))
    except Refusal as refusal:
        if not str(refusal).startswith("STANDARD_CONVERTER_DEPS_MISSING"):
            raise
        # The converter commit's locked gems aren't prepared yet: prepare them (public gems
        # only, the same step dev_test runs), then propose again.
        # 150 s to build (+ up to ~35 s to remove a container that ran out of time) fits in
        # this call's 190, and 30 + 30 + 190 + 30 stays inside the tool's 290.
        prepared = json.loads(ws.control(["converter", "deps", ws.name, "--budget", "150"], timeout=190)).get("dependencies")
        plan = json.loads(ws.control(argv, timeout=30))
    return {"plan_id": plan.get("plan_id"), "digest": plan.get("digest"), "status": plan.get("status"), "operation": plan.get("operation"),
            "platform": plan.get("platform"), "roles": plan.get("roles"), "inputs": plan.get("inputs"), "source_charset": plan.get("source_charset"),
            "converter_revision": plan.get("converter_revision"), "converter_branch": converter.get("branch"),
            "converter_deps": plan.get("converter_deps"), "dependencies_prepared": prepared,
            "mutations": plan.get("mutations"), "not_included": plan.get("not_included"),
            "next": ("Tell the engineer the plan is waiting in the web UI's Runs widget (the Runs tab), where they review, "
                     "approve and start it. When it has finished, read it with data_run_evidence.")}


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
                ("review", "Review import passed its checks"), ("site", "Site reviewed"))
GUIDE_RECENT = 10
GUIDE_ACTIVE = ("claimed", "running")
GUIDE_ACCEPTANCE = "not recorded yet: the engineer's review of a site isn't stored anywhere"
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
    plans = [{"plan_id": plan.get("plan_id"), "kind": kinds.get(plan.get("plan_id")), "status": plan.get("status"), "delivery": plan.get("delivery"),
              "run_id": plan.get("run_id"), "created_at": plan.get("created_at") or ""} for plan in status.get("plans", [])]
    runs = []
    for run in status.get("runs", []):
        results = run.get("results") or {}
        failure = run.get("failure")
        runs.append({"run_id": run.get("run_id"), "plan_id": run.get("plan_id"), "kind": kinds.get(run.get("plan_id")), "status": run.get("status"),
                     "stage": run.get("stage"), "started_at": run.get("started_at") or "", "finished_at": run.get("finished_at"),
                     "checks": results.get("reconciliation_checks") or 0, "matched": results.get("reconciliation_matched") or 0,
                     "differ": results.get("reconciliation_differs") or 0, "errors": results.get("reconciliation_errors") or 0,
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
        return ("engineer", label + " stopped without finishing. Recover it in the Runs widget, then a new plan can be proposed.", "Runs widget")
    if run["status"] != "completed":
        return ("agent", "%s failed at stage %s (%s). Read data_run_evidence and explain the cause." % (label, run["stage"], run["failure"] or "no code"), "this chat")
    if not run["checks"]:
        return ("agent", label + " has no count checks, so nothing proved it. Register checks and propose it again.", "this chat")
    return ("agent", "%s finished with %d of %d checks matching (%d differ, %d errors). Read data_run_evidence and explain why; "
            "a difference stops the process until it's explained." % (label, run["matched"], run["checks"], run["differ"], run["errors"]), "this chat")


def guide_flow(ws, facts, records):
    """The next step along the stages, once nothing is running or waiting on the engineer."""
    copy_files = ("engineer", "Copy the customer's files to the drop folder (%s) with scp, then run `silo intake %s` as root." % (ws.intake, ws.name), "server terminal")
    if not facts["initialized"]:
        if facts["drop_files"]:
            return ("agent", "Create the workspace with data_create (ask the engineer for the source platform if it isn't clear), then take the files with data_take.", "this chat")
        return copy_files
    if facts["labelled_files"]:
        return ("agent", "Take the labelled files in the drop folder with data_take, each with a clear type.", "this chat")
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
    if any(site["run_id"] == review["run_id"] and site["live"] for site in records["sites"]):
        return ("engineer", "Open review site of run %s through the SSH tunnel shown in the Runs widget and check it. Reset it there before the next review run." % review["run_id"], "Runs widget")
    return ("nobody", "The last review import passed and its site is gone. New files or a converter fix start the next pass.", "this chat")


def guide_stages(facts, records):
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
    current = next((key for key, _label in GUIDE_STAGES[:-1] if not done[key]), "site")
    stages = [{"id": key, "label": label, "state": "not_recorded" if key == "site" else "done" if done[key] else "current" if key == current else "to_do"}
              for key, label in GUIDE_STAGES]
    return current, stages


def guide_data(records):
    """Which delivery is which: labels, versions and IDs only, never file names."""
    ordered = sorted(records.values(), key=lambda record: record["labelled_at"], reverse=True)
    newest = {}
    for record in ordered:
        newest.setdefault(record["kind"], record["dataset_id"])
    return {"current": delivery_label(ordered[0]) if ordered else None,
            "note": None if ordered else "no data is labelled yet: only the engineer can say what files are for",
            "deliveries": [{"label": delivery_label(record), "kind": record["kind"], "dataset_id": record["dataset_id"], "labelled_at": record["labelled_at"],
                            "state": "current" if newest[record["kind"]] == record["dataset_id"] else "replaced"} for record in ordered]}


def op_guide(ws, request):
    state = ws.named_state() if ws.initialized() else {}
    db = ws.read_json(ws.data / "db" / "state.json", None) if ws.initialized() and (ws.data / "db").is_dir() else None
    drop_files = 0
    if ws.intake.is_dir() and not ws.intake.is_symlink():
        for _path, _dirs, files, _dirfd in os.fwalk(str(ws.intake), follow_symlinks=False):
            drop_files += len(files)
    deliveries = read_deliveries(ws) if ws.initialized() else {}
    labelled, unlabelled = split_drop_files(ws, deliveries) if ws.initialized() else ([], [])
    not_labelled = unlabelled_data(ws, deliveries) if ws.initialized() else []
    facts = {"initialized": ws.initialized(), "drop_files": drop_files, "labelled_files": len(labelled), "inputs": len(state.get("inputs") or {}),
             "db_loaded": bool(db and db.get("loads"))}
    records = guide_records(ws) if ws.initialized() else {"plans": [], "runs": [], "sites": [], "findings": [], "pushes": [], "warning": None}
    contact = support_contact(ws)
    active = [run for run in records["runs"] if run["status"] in GUIDE_ACTIVE]
    happening = ["%s run %s is %s (stage %s)." % (run["kind"] or "workflow", run["run_id"], run["status"], run["stage"]) for run in active]
    waiting, also = [], []
    if not_labelled:
        waiting.append({"what": "Label the data already in this project as Development on the Project page.", "where": "Project page"})
    if unlabelled:
        waiting.append({"what": "%d new file(s) arrived: say what they're for (Development or Launch) on the Project page." % len(unlabelled), "where": "Project page"})
    latest_start = {run["kind"]: run["started_at"] or "" for run in records["runs"]}
    for plan in records["plans"]:
        if plan["status"] not in ("proposed", "approved"):
            continue
        kind = plan["kind"] or "workflow"
        # Left behind by a later run of the same kind: worth tidying, but not the next step.
        if (plan["created_at"] or "") < latest_start.get(plan["kind"], ""):
            also.append("%s plan %s is older than the latest %s run and was never run: discard it in the Runs widget unless it's still wanted." % (kind, plan["plan_id"], kind))
        elif plan["status"] == "proposed":
            waiting.append({"what": "Approve or discard %s plan %s." % (kind, plan["plan_id"]), "where": "Runs widget"})
        else:
            waiting.append({"what": "Start approved %s plan %s." % (kind, plan["plan_id"]), "where": "Runs widget"})
    waiting += [{"what": "Review converter push %s and push it." % item["id"], "where": "Runs widget"} for item in records["pushes"] if item["status"] == "proposed"]
    waiting += [{"what": "Review finding %s and release, amend or reject it." % item["id"], "where": "Findings widget"} for item in records["findings"] if item["status"] == "proposed"]
    stale = [plan for plan in records["plans"] if plan["status"] == "stale"]
    if stale:
        also.append("Plan %s is out of date because something it depends on changed: propose it again, and discard the old one in the Runs widget." % stale[-1]["plan_id"])
    also += ["The review site of run %s is still up and holds customer data until it's reset in the Runs widget." % site["run_id"] for site in records["sites"]]
    if records["warning"]:
        step = ("agent", "Plans and runs couldn't be read (%s). Tell the engineer, and ask %s if it keeps happening." % (records["warning"], contact), "this chat")
    elif active:
        step = ("nobody", happening[0] + " Nothing is needed until it finishes.", "Runs widget")
    elif waiting:
        step = ("engineer", waiting[0]["what"], waiting[0]["where"])
    else:
        step = guide_flow(ws, facts, records)
    current, stages = guide_stages(facts, records)
    return {"project": ws.name, "stage": current, "stages": stages, "happening": happening, "waiting_on_engineer": waiting,
            "next": {"who": step[0], "action": step[1], "where": step[2]}, "also": also,
            "plans": records["plans"][-GUIDE_RECENT:][::-1], "runs": records["runs"][-GUIDE_RECENT:][::-1],
            "data": guide_data(deliveries), "site_acceptance": GUIDE_ACCEPTANCE, "support_contact": contact,
            "decisions_recorded": len(read_decisions(ws)) if ws.initialized() else 0}


OPS = {"status": op_status, "list": op_list, "peek": op_peek, "create": op_create, "take": op_take, "register": op_register,
       "script": op_script, "extract": op_extract, "job": op_job, "db_up": op_db_up, "db_load": op_db_load,
       "db_status": op_db_status, "db_reset": op_db_reset, "run_evidence": op_run_evidence, "run_count": op_run_count, "propose_finding": op_propose_finding,
       "plan_propose": op_plan_propose,
       "notes": op_notes, "notes_write": op_notes_write, "guide": op_guide, "decide": op_decide, "decisions": op_decisions, "deliveries": op_deliveries, "delivery_label": op_delivery_label}
# Logged with their arguments (minus script code, finding text, count SQL and decisions, logged by hash).
QUIET = {"status", "list", "job", "db_status", "notes", "guide", "decisions", "deliveries"}


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
        if key in ("code", "text", "sql", "decision", "topic") and isinstance(value, str):
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
