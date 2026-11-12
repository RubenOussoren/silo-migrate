"""Private project reference files. Only trusted wrappers may supply underscore keys.

handle(ws, request, api) uses the parent's confinement, Docker and refusal helpers.
admit_reference(ws, request, api) and admit_asset_reference(ws, request, api)
are engineer-only and require the caller's lock.
Nothing here registers an input, delivery, output, job, or named-state record.
"""
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import stat
import tempfile
import time

MAX_FILE = 20 * 1024 * 1024
MAX_TOTAL = 200 * 1024 * 1024
MAX_RECORD = 64 * 1024
MAX_OUTPUT = 32 * 1024
SUPPORT_ID = re.compile(r"support-[0-9a-f]{32}\Z")
ASSET_ID = re.compile(r"file-[0-9a-f]{32}\Z")
ORIGIN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}\Z")
REF_ID = re.compile(r"[0-9a-f]{32}\Z")
PARSER_ERRORS = frozenset("STANDARD_SUPPORTING_" + code for code in (
    "INVALID_ARGUMENT", "INVALID_DOCUMENT", "IO", "LIMIT", "OUTPUT_LIMIT",
    "SHEET_NOT_FOUND", "UNSAFE_RELATIONSHIP", "UNSAFE_XML", "UNSUPPORTED",
))
SESSION_ID = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def fail(api, code):
    api.refuse("STANDARD_SUPPORTING_" + code)


def encoded(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode("utf-8")


def safe_name(value):
    return (isinstance(value, str) and 0 < len(value.encode("utf-8")) <= 128
            and value not in (".", "..")
            and not any(c in "/\\" or ord(c) < 32 or 127 <= ord(c) < 160 for c in value))


def trusted_context(request, api):
    session = request.get("_session_id")
    if request.get("_private_session") is not True or not isinstance(session, str) or not SESSION_ID.fullmatch(session):
        fail(api, "PRIVATE_SESSION_REQUIRED")
    uploads = request.get("_uploads", [])
    if not isinstance(uploads, list) or len(uploads) > 32:
        fail(api, "UPLOADS_INVALID")
    try:
        if len(encoded(uploads)) > MAX_RECORD:
            fail(api, "UPLOADS_INVALID")
    except (TypeError, ValueError, UnicodeError):
        fail(api, "UPLOADS_INVALID")
    seen = set()
    for item in uploads:
        if not isinstance(item, dict):
            fail(api, "UPLOADS_INVALID")
        ref = item.get("id")
        if not isinstance(ref, str) or not REF_ID.fullmatch(ref) or ref in seen:
            fail(api, "UPLOADS_INVALID")
        seen.add(ref)
        if (not safe_name(item.get("filename")) or not isinstance(item.get("path"), str)
                or not isinstance(item.get("media_type"), str) or len(item["media_type"]) > 128
                or any(ord(c) < 32 or ord(c) == 127 for c in item["media_type"])
                or type(item.get("size_bytes")) is not int or not 0 <= item["size_bytes"] <= MAX_FILE):
            fail(api, "UPLOADS_INVALID")
    return session, uploads


def session_context(request, api):
    """Protected-session proof without an upload manifest: reading, preparing or
    citing an already-registered (e.g. intake-admitted) reference does not depend
    on chat upload provenance, but still requires the host's protected session."""
    session = request.get("_session_id")
    if request.get("_private_session") is not True or not isinstance(session, str) or not SESSION_ID.fullmatch(session):
        fail(api, "PRIVATE_SESSION_REQUIRED")
    return session


def resolve_references(ws, request, api, identities, snapshot_dir=None):
    """Active registered references by ID, for job mounts or plan provenance.

    Caller holds ws.lock() (it is not reentrant). Requires the protected session
    context. With snapshot_dir, each file is copied to snapshot_dir/<id> (0400)
    from the held custody inode and checksum-verified; originals are never
    mounted or modified. Returns [{id, filename, size_bytes, sha256}] in request
    order. Unknown/inactive IDs refuse without revealing other records.
    """
    session_context(request, api)
    try:
        if (not isinstance(identities, list) or not identities or len(identities) > 8
                or len(set(map(str, identities))) != len(identities)
                or not all(isinstance(value, str) and SUPPORT_ID.fullmatch(value) for value in identities)):
            fail(api, "ID_INVALID")
        ws.require(standard=False)
        with store(ws, api) as (_, index, files):
            items = {item["id"]: item for item in records(index, api)}
            resolved = []
            for identity in identities:
                item = items.get(identity)
                if item is None:
                    fail(api, "NOT_FOUND")
                if not reference_active(identity, api):
                    fail(api, "INACTIVE")
                if snapshot_dir is not None:
                    fd, info = api.open_regular(files, [identity])
                    try:
                        check_file(info, api, 0o400)
                        copy_checked(fd, Path(snapshot_dir) / identity, api, item)
                    finally:
                        os.close(fd)
                resolved.append({key: item[key] for key in ("id", "filename", "size_bytes", "sha256")})
            return resolved
    except (OSError, ValueError, TypeError, UnicodeError) as error:
        if isinstance(error, ValueError) and str(error).startswith("STANDARD_"):
            raise
        fail(api, "IO")


def full_root(path, api, strict=False):
    """Unlike open_root alone, refuse symlinks in every absolute path component."""
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        fail(api, "PATH_INVALID")
    fd = os.open("/", DIR_FLAGS)
    try:
        for part in path.parts[1:]:
            nxt = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = nxt
            if strict:
                info = os.fstat(fd)
                # System ancestors may be root-owned. A root-owned sticky /tmp
                # is safe to traverse; ordinary writable/foreign ancestors are not.
                sticky_root = info.st_uid == 0 and info.st_mode & stat.S_ISVTX
                if (info.st_uid not in (0, os.getuid())
                        or (info.st_mode & 0o022 and not sticky_root)):
                    fail(api, "PATH_INVALID")
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or info.st_mode & 0o022:
            fail(api, "PATH_INVALID")
        return os.dup(fd)
    finally:
        os.close(fd)


def upload_root():
    if os.environ.get("SILO_TESTING") == "1" and os.environ.get("SILO_SUPPORT_UPLOADS_ROOT"):
        return Path(os.environ["SILO_SUPPORT_UPLOADS_ROOT"])
    base = os.environ.get("XDG_DATA_HOME")
    return (Path(base) if base else Path(pwd.getpwuid(os.getuid()).pw_dir) / ".local/share") / "term-llm/uploads"


def check_file(info, api, mode=None):
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_nlink != 1 or info.st_mode & 0o022
            or info.st_size > MAX_FILE or (mode is not None and stat.S_IMODE(info.st_mode) != mode)):
        fail(api, "FILE_INVALID")


def stamp(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
            info.st_uid, info.st_mode, info.st_nlink)


def copy_checked(fd, dest, api, expected=None, dir_fd=None):
    """Copy from held inode, hash actual bytes, and detect mutations during the copy."""
    before = os.fstat(fd)
    check_file(before, api)
    digest, count = hashlib.sha256(), 0
    os.lseek(fd, 0, os.SEEK_SET)
    out = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
    try:
        with os.fdopen(out, "wb") as stream:
            while True:
                data = os.read(fd, 1024 * 1024)
                if not data:
                    break
                count += len(data)
                if count > MAX_FILE:
                    fail(api, "LIMIT")
                digest.update(data)
                stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), 0o400)
            os.fsync(stream.fileno())
        if stamp(before) != stamp(os.fstat(fd)) or count != before.st_size:
            fail(api, "FILE_CHANGED")
        checksum = digest.hexdigest()
        if expected is not None and (count != expected["size_bytes"] or checksum != expected["sha256"]):
            fail(api, "CHECKSUM_MISMATCH")
        return count, checksum
    except BaseException:
        os.unlink(dest, dir_fd=dir_fd)
        raise


@contextlib.contextmanager
def store(ws, api):
    base = ws.data_dir()
    parent = full_root(base, api)
    try:
        try:
            os.mkdir("supporting", 0o700, dir_fd=parent)
        except FileExistsError:
            pass
        fd = os.open("supporting", DIR_FLAGS, dir_fd=parent)
    finally:
        os.close(parent)
    root = base / "supporting"
    opened = [fd]
    try:
        if os.fstat(fd).st_uid != os.getuid() or stat.S_IMODE(os.fstat(fd).st_mode) != 0o700:
            fail(api, "PATH_INVALID")
        children = []
        for name in ("index", "files"):
            try:
                os.mkdir(name, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            child = os.open(name, DIR_FLAGS, dir_fd=fd)
            opened.append(child)
            info = os.fstat(child)
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                fail(api, "PATH_INVALID")
            children.append(child)
        yield root, children[0], children[1]
    finally:
        for child in reversed(opened):
            os.close(child)


def checksum(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def reference_parts(value):
    if (not isinstance(value, str) or not 0 < len(value.encode("utf-8")) <= 1024
            or any(not safe_name(part) for part in value.split("/"))):
        return None
    return value.split("/")


def valid_identity(value, path):
    return (isinstance(value, dict) and set(value) == {"path", "bytes", "mtime_ns", "ctime_ns", "ino"}
            and value["path"] == path and type(value["bytes"]) is int and 0 <= value["bytes"] <= MAX_FILE
            and all(isinstance(value[key], str) and re.fullmatch(r"[0-9]{1,30}", value[key])
                    for key in ("mtime_ns", "ctime_ns", "ino")))


def actor(value):
    return (isinstance(value, str) and 0 < len(value.encode("utf-8")) <= 128
            and value.strip() == value and not any(ord(c) < 32 or 127 <= ord(c) < 160 for c in value))


def valid_provenance(item):
    common = {"id", "filename", "size_bytes", "sha256", "imported_at", "provenance"}
    if type(item.get("imported_at")) is not int or item["imported_at"] < 0:
        return False
    if item.get("provenance") == "private-session-upload":
        return (set(item) == common | {"session_id", "refid", "media_type"}
                and isinstance(item["session_id"], str) and SESSION_ID.fullmatch(item["session_id"])
                and isinstance(item["refid"], str) and REF_ID.fullmatch(item["refid"])
                and isinstance(item["media_type"], str) and len(item["media_type"]) <= 128
                and not any(ord(c) < 32 or ord(c) == 127 for c in item["media_type"]))
    if item.get("provenance") == "engineer-asset-reference":
        if (set(item) != common | {"origin_id", "actor", "source"}
                or not isinstance(item["origin_id"], str) or not ASSET_ID.fullmatch(item["origin_id"])
                or not actor(item["actor"])):
            return False
        source = item["source"]
        blob = "file-role-assets/" + item["origin_id"]
        return (isinstance(source, dict) and set(source) == {"blob", "identity", "device"}
                and source["blob"] == blob and valid_identity(source["identity"], blob)
                and source["identity"]["bytes"] == item["size_bytes"]
                and isinstance(source["device"], str) and re.fullmatch(r"[0-9]{1,30}", source["device"]))
    if (item.get("provenance") != "engineer-file-reference"
            or set(item) != common | {"origin_id", "actor", "source"}
            or not isinstance(item["origin_id"], str) or not ORIGIN_ID.fullmatch(item["origin_id"])
            or not actor(item["actor"])):
        return False
    source = item["source"]
    if (not isinstance(source, dict) or set(source) != {"area", "path", "identity", "registered"}
            or source["area"] not in ("intake", "inputs") or not reference_parts(source["path"])
            or not valid_identity(source["identity"], source["path"])
            or source["identity"]["bytes"] != item["size_bytes"]
            or source["path"].split("/")[-1] != item["filename"]):
        return False
    registered = source["registered"]
    if source["area"] == "intake":
        return registered is None
    return (isinstance(registered, dict) and set(registered) == {"input_id", "sha256"}
            and isinstance(registered["input_id"], str)
            and re.fullmatch(r"input-[0-9a-f]{32}", registered["input_id"])
            and registered["sha256"] == item["sha256"])


def records(index, api):
    names = os.listdir(index)
    if len(names) > 100:
        fail(api, "LIMIT")
    result = []
    for name in sorted(names):
        if not name.endswith(".json") or not SUPPORT_ID.fullmatch(name[:-5]):
            fail(api, "INDEX_INVALID")
        fd, info = api.open_regular(index, [name])
        try:
            check_file(info, api, 0o600)
            if info.st_size > MAX_RECORD:
                fail(api, "INDEX_INVALID")
            raw = os.read(fd, MAX_RECORD + 1)
            item = json.loads(raw)
            if stamp(info) != stamp(os.fstat(fd)) or len(raw) != info.st_size:
                fail(api, "INDEX_INVALID")
        finally:
            os.close(fd)
        if (not isinstance(item, dict) or item.get("id") != name[:-5]
                or not safe_name(item.get("filename"))
                or type(item.get("size_bytes")) is not int or not 0 <= item["size_bytes"] <= MAX_FILE
                or not checksum(item.get("sha256")) or not valid_provenance(item)):
            fail(api, "INDEX_INVALID")
        if any(("origin_id" in item and old.get("origin_id") == item["origin_id"])
               or (item["provenance"] == "private-session-upload"
                   and old.get("session_id") == item["session_id"] and old.get("refid") == item["refid"])
               for old in result):
            fail(api, "INDEX_INVALID")
        result.append(item)
    if sum(item["size_bytes"] for item in result) > MAX_TOTAL:
        fail(api, "LIMIT")
    return result


@contextlib.contextmanager
def pending_dir(index, api):
    """Private metadata staging sibling, never enumerated by records()."""
    root = os.open("..", DIR_FLAGS, dir_fd=index)
    pending = None
    try:
        info = os.fstat(root)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            fail(api, "PATH_INVALID")
        try:
            os.mkdir("pending", 0o700, dir_fd=root)
            os.fsync(root)
        except FileExistsError:
            pass
        pending = os.open("pending", DIR_FLAGS, dir_fd=root)
        info = os.fstat(pending)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            fail(api, "PATH_INVALID")
        yield pending
    finally:
        if pending is not None:
            os.close(pending)
        os.close(root)


def capacity(index, files, items, api, extra_bytes=0, extra_count=0):
    """Admission-only accounting under ws.lock; never delete interrupted custody.

    Indexed logical bytes remain charged even if a blob is missing. Orphan blobs
    (including interrupted 0600 copies) and partial metadata stages also consume
    quota. A blob and its stage share one count slot; stage bytes are additional.
    Reads intentionally use records(), not this interrupted-storage inspection.
    """
    charged = {item["id"]: item["size_bytes"] for item in items}
    indexed = set(charged)
    stage_bytes = 0
    with pending_dir(index, api) as pending:
        for directory, staged in ((files, False), (pending, True)):
            names = os.listdir(directory)
            if len(names) > 100:
                fail(api, "LIMIT")
            for name in names:
                identity = name[:-5] if staged and name.endswith(".json") else name
                if not SUPPORT_ID.fullmatch(identity) or (staged and name != identity + ".json"):
                    fail(api, "STORAGE_INVALID")
                fd, info = api.open_regular(directory, [name])
                try:
                    check_file(info, api)
                    modes = (0o600,) if staged else ((0o400,) if identity in indexed else (0o400, 0o600))
                    if (stat.S_IMODE(info.st_mode) not in modes
                            or (staged and info.st_size > MAX_RECORD)
                            or stamp(info) != stamp(os.fstat(fd))):
                        fail(api, "STORAGE_INVALID")
                finally:
                    os.close(fd)
                if staged:
                    stage_bytes += info.st_size
                    charged.setdefault(identity, 0)
                else:
                    charged[identity] = max(charged.get(identity, 0), info.st_size)
    if (len(charged) + extra_count > 100
            or sum(charged.values()) + stage_bytes + extra_bytes > MAX_TOTAL):
        fail(api, "LIMIT")


def public(item):
    return {key: item[key] for key in ("id", "filename", "size_bytes", "sha256")}


def engineer_list(ws, api):
    """Engineer inventory: all public custody records, including archived copies.

    Caller holds ws.lock(), as for admit_reference. Uses the existing store/index
    validation and deliberately does not apply reference_active: the engineer UI
    needs archived records too. Reading an empty project benignly initializes the
    private supporting/index/files directories (and ws.data_dir()) via store().
    No provenance, session metadata, or role-registry file IDs are returned.
    """
    try:
        if ws.chat:
            api.refuse("STANDARD_DATA_OPERATION_REFUSED")
        ws.require(standard=False)
        with store(ws, api) as (_, index, files):
            return [public(item) for item in records(index, api)]
    except (OSError, ValueError, TypeError, UnicodeError) as error:
        if isinstance(error, ValueError) and str(error).startswith("STANDARD_"):
            raise
        fail(api, "IO")


def reference_origin(ws, support_id, api):
    """Internal checked origin lookup; caller holds ws.lock(), including in chat.

    Not a custom operation or a public projection. Exposes only the provenance
    discriminator and engineer origin ID (None for native session uploads), never
    paths, session IDs, or bytes. Missing registered IDs return None. Like the
    engineer inventory, an empty store may benignly initialize private dirs.
    """
    try:
        if not isinstance(support_id, str) or not SUPPORT_ID.fullmatch(support_id):
            fail(api, "ID_INVALID")
        ws.require(standard=False)
        with store(ws, api) as (_, index, files):
            item = next((item for item in records(index, api) if item["id"] == support_id), None)
            if item is None:
                return None
            return {"provenance": item["provenance"], "origin_id": item.get("origin_id")}
    except (OSError, ValueError, TypeError, UnicodeError) as error:
        if isinstance(error, ValueError) and str(error).startswith("STANDARD_"):
            raise
        fail(api, "IO")


def reference_active(identity, api):
    """Optional internal role authority. Never derived from request arguments."""
    callback = getattr(api, "reference_active", None)
    if callback is None:
        return True
    if not callable(callback):
        fail(api, "REFERENCE_STATE_INVALID")
    try:
        active = callback(identity)
    except Exception:
        # Role-state errors must fail closed, without leaking private details.
        fail(api, "REFERENCE_STATE_INVALID")
    if type(active) is not bool:
        fail(api, "REFERENCE_STATE_INVALID")
    return active


def bounded(value, api):
    if len(encoded(value)) > MAX_OUTPUT:
        fail(api, "OUTPUT_LIMIT")
    return value


def take(ws, request, api, root, index, files, items, session, uploads):
    ref = request.get("ref")
    if not isinstance(ref, str) or not REF_ID.fullmatch(ref):
        fail(api, "REF_INVALID")
    upload = next((item for item in uploads if item["id"] == ref), None)
    if upload is None:
        fail(api, "REF_NOT_AVAILABLE")
    old = next((item for item in items if item.get("provenance") == "private-session-upload"
                and item["session_id"] == session and item["refid"] == ref), None)
    if old:
        if not reference_active(old["id"], api):
            fail(api, "INACTIVE")
        return {"status": "ok", "file": public(old), "already_registered": True}
    capacity(index, files, items, api, upload["size_bytes"], 1)
    source_root = upload_root()
    source = Path(upload["path"])
    # No resolution/normalization that could silently accept ../ or nested paths.
    if (not source.is_absolute() or source.parent != source_root or ".." in source.parts
            or upload["path"] != str(source) or not safe_name(source.name)):
        fail(api, "PATH_INVALID")
    source_dir = full_root(source_root, api)
    try:
        fd, info = api.open_regular(source_dir, [source.name])
    finally:
        os.close(source_dir)
    identity = "support-" + secrets.token_hex(16)
    try:
        check_file(info, api)
        if info.st_size != upload["size_bytes"]:
            fail(api, "FILE_CHANGED")
        count, digest = copy_checked(fd, identity, api, dir_fd=files)
        try:
            if stamp(info) != stamp(os.fstat(fd)) or count != info.st_size:
                fail(api, "FILE_CHANGED")
            capacity(index, files, items, api)
        except BaseException:
            os.unlink(identity, dir_fd=files)
            raise
    finally:
        os.close(fd)
    item = {"id": identity, "filename": upload["filename"], "size_bytes": count,
            "sha256": digest, "session_id": session, "refid": ref,
            "media_type": upload["media_type"], "imported_at": int(time.time()),
            "provenance": "private-session-upload"}
    return publish(item, index, files, api)


def publish(item, index, files, api):
    identity = item["id"]
    metadata_fd = None
    created = committed = False
    try:
        metadata = encoded(item)
        if len(metadata) > MAX_RECORD:
            fail(api, "INDEX_INVALID")
        # Reserve the temporary metadata bytes as well as the already-copied
        # blob, so abrupt exits cannot push physical pending usage over quota.
        capacity(index, files, records(index, api), api, len(metadata))
        # Persist the completed blob's directory entry before its registry record.
        os.fsync(files)
        with pending_dir(index, api) as pending:
            try:
                metadata_fd = os.open(identity + ".json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                      0o600, dir_fd=pending)
                created = True
                with os.fdopen(metadata_fd, "wb") as stream:
                    metadata_fd = None
                    stream.write(metadata)
                    stream.flush()
                    os.fchmod(stream.fileno(), 0o600)
                    os.fsync(stream.fileno())
                # The random ID and caller-held lock make this a no-collision
                # publication. Never overwrite even an unexpected existing index.
                try:
                    os.stat(identity + ".json", dir_fd=index, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    fail(api, "INDEX_INVALID")
                os.rename(identity + ".json", identity + ".json", src_dir_fd=pending, dst_dir_fd=index)
                committed = True
                os.fsync(index)
                os.fsync(pending)
            except BaseException:
                if metadata_fd is not None:
                    os.close(metadata_fd)
                    metadata_fd = None
                if created and not committed:
                    os.unlink(identity + ".json", dir_fd=pending)
                raise
    except BaseException:
        # Once renamed, retain BOTH record and blob even on a directory-fsync
        # error; deleting only one would destroy committed custody on retry.
        if not committed:
            os.unlink(identity, dir_fd=files)
        raise
    return {"status": "ok", "file": public(item), "already_registered": False}


def source_identity(info, path):
    return {"path": path, "bytes": info.st_size, "mtime_ns": str(info.st_mtime_ns),
            "ctime_ns": str(info.st_ctime_ns), "ino": str(info.st_ino)}


@contextlib.contextmanager
def reference_source(ws, area, parts, api):
    # Validate every absolute component, then bind that root to the workspace API.
    checked = full_root(ws.area_path(area), api, strict=True)
    opened = []
    try:
        root = ws.open_area(area)
        opened.append(root)
        if stamp(os.fstat(checked)) != stamp(os.fstat(root)):
            fail(api, "FILE_CHANGED")
        parent = root
        for part in parts[:-1]:
            parent = os.open(part, DIR_FLAGS, dir_fd=parent)
            opened.append(parent)
            info = os.fstat(parent)
            if info.st_uid != os.getuid() or info.st_mode & 0o022:
                fail(api, "PATH_INVALID")
        fd, info = api.open_regular(parent, [parts[-1]])
        opened.append(fd)
        check_file(info, api)
        yield fd, info
    finally:
        for fd in reversed(opened):
            os.close(fd)
        os.close(checked)


def registered_reference(ws, path, digest, api):
    # Never authorize from origin_id, or from an unregistered file merely in inputs/.
    root = full_root(ws.root / ".silo-migrate/named", api, strict=True)
    try:
        fd, info = api.open_regular(root, ["state.json"])
    finally:
        os.close(root)
    try:
        check_file(info, api)
        with os.fdopen(os.dup(fd), "rb") as stream:
            state = json.load(stream)
        if stamp(info) != stamp(os.fstat(fd)):
            fail(api, "FILE_CHANGED")
    finally:
        os.close(fd)
    inputs = state.get("inputs") if isinstance(state, dict) else None
    if not isinstance(inputs, dict):
        fail(api, "INPUT_NOT_REGISTERED")
    matches = []
    for identity, record in inputs.items():
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            continue
        try:
            decoded = base64.b64decode(record["path"], validate=True).decode("utf-8", "strict")
        except (ValueError, UnicodeError):
            continue
        if decoded == "inputs/" + path:
            if (not re.fullmatch(r"input-[0-9a-f]{32}", identity)
                    or record.get("sha256") != digest):
                fail(api, "CHECKSUM_MISMATCH")
            matches.append({"input_id": identity, "sha256": digest})
    if len(matches) != 1:
        fail(api, "INPUT_NOT_REGISTERED")
    return matches[0]


def hash_checked(fd, api):
    before = os.fstat(fd)
    check_file(before, api)
    digest, count = hashlib.sha256(), 0
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            break
        count += len(chunk)
        if count > MAX_FILE:
            fail(api, "LIMIT")
        digest.update(chunk)
    if stamp(before) != stamp(os.fstat(fd)) or count != before.st_size:
        fail(api, "FILE_CHANGED")
    return digest.hexdigest()


def admit_reference(ws, request, api):
    """Engineer role-handler only; caller MUST hold ws.lock(). Never a chat op.

    area/path identify a confined source; intake requires its exact drop identity.
    inputs requires a registered decoded inputs/path plus the expected sha256.
    origin_id is a stable role-registry file ID, NOT authority to open a path.
    This copies bytes only; it does not alter named state, deliveries, or originals.
    """
    try:
        if ws.chat:
            api.refuse("STANDARD_DATA_OPERATION_REFUSED")
        area, path = request.get("area"), request.get("path")
        parts = reference_parts(path)
        origin, by = request.get("origin_id"), request.get("by")
        if (area not in ("intake", "inputs") or not parts
                or not isinstance(origin, str) or not ORIGIN_ID.fullmatch(origin) or not actor(by)):
            fail(api, "ARGUMENTS_INVALID")
        expected = request.get("identity")
        if ((area == "intake" or expected is not None) and not valid_identity(expected, path)):
            fail(api, "IDENTITY_INVALID")
        digest = request.get("sha256")
        if area == "inputs" and not checksum(digest):
            fail(api, "CHECKSUM_MISMATCH")
        ws.require(standard=False)
        registered = registered_reference(ws, path, digest, api) if area == "inputs" else None
        with reference_source(ws, area, parts, api) as (fd, info), store(ws, api) as (_, index, files):
            actual = source_identity(info, path)
            if expected is not None and actual != expected:
                fail(api, "FILE_CHANGED")
            source = {"area": area, "path": path, "identity": actual, "registered": registered}
            items = records(index, api)
            old = next((item for item in items if item.get("origin_id") == origin), None)
            if old:
                if old["source"] != source or hash_checked(fd, api) != old["sha256"]:
                    fail(api, "REFERENCE_CONFLICT")
                # Re-open the original path: holding an inode is not proof it is still there.
                with reference_source(ws, area, parts, api) as (_, current):
                    if stamp(info) != stamp(current):
                        fail(api, "FILE_CHANGED")
                if area == "inputs" and registered_reference(ws, path, digest, api) != registered:
                    fail(api, "FILE_CHANGED")
                return {"status": "ok", "file": public(old), "already_registered": True}
            capacity(index, files, items, api, info.st_size, 1)
            identity = "support-" + secrets.token_hex(16)
            count, actual_digest = copy_checked(fd, identity, api, dir_fd=files)
            try:
                if count != info.st_size or stamp(info) != stamp(os.fstat(fd)):
                    fail(api, "FILE_CHANGED")
                capacity(index, files, items, api)
                if area == "inputs" and actual_digest != digest:
                    fail(api, "CHECKSUM_MISMATCH")
                with reference_source(ws, area, parts, api) as (_, current):
                    if stamp(info) != stamp(current):
                        fail(api, "FILE_CHANGED")
                if area == "inputs" and registered_reference(ws, path, digest, api) != registered:
                    fail(api, "FILE_CHANGED")
            except BaseException:
                os.unlink(identity, dir_fd=files)
                raise
            item = {"id": identity, "filename": parts[-1], "size_bytes": count,
                    "sha256": actual_digest, "imported_at": int(time.time()),
                    "provenance": "engineer-file-reference", "origin_id": origin,
                    "actor": by, "source": source}
            return publish(item, index, files, api)
    except (OSError, ValueError, TypeError, UnicodeError) as error:
        if isinstance(error, ValueError) and str(error).startswith("STANDARD_"):
            raise
        fail(api, "IO")


@contextlib.contextmanager
def asset_source(ws, origin, api):
    # origin has already passed ASSET_ID; neither root nor relative path is supplied.
    root = full_root(ws.data_dir(), api, strict=True)
    parent = fd = None
    try:
        parent = os.open("file-role-assets", DIR_FLAGS, dir_fd=root)
        info = os.fstat(parent)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            fail(api, "PATH_INVALID")
        fd, info = api.open_regular(parent, [origin])
        check_file(info, api, 0o400)
        yield fd, info
    finally:
        for opened in (fd, parent, root):
            if opened is not None:
                os.close(opened)


def admit_asset_reference(ws, request, api):
    """Engineer only, caller holds ws.lock() and validates role/preview membership.

    Copy ONLY data/file-role-assets/<file-ID>; no intake, inputs, or host paths.
    Request keys are exactly origin_id, filename, sha256, by. Original custody
    bytes and role metadata are never changed. Returns the standard file payload.
    """
    try:
        if ws.chat:
            api.refuse("STANDARD_DATA_OPERATION_REFUSED")
        origin, filename = request.get("origin_id"), request.get("filename")
        digest, by = request.get("sha256"), request.get("by")
        if (set(request) != {"origin_id", "filename", "sha256", "by"}
                or not isinstance(origin, str) or not ASSET_ID.fullmatch(origin)
                or not safe_name(filename) or not actor(by)):
            fail(api, "ARGUMENTS_INVALID")
        if not checksum(digest):
            fail(api, "CHECKSUM_MISMATCH")
        ws.require(standard=False)
        with asset_source(ws, origin, api) as (fd, info), store(ws, api) as (_, index, files):
            blob = "file-role-assets/" + origin
            source = {"blob": blob, "identity": source_identity(info, blob), "device": str(info.st_dev)}
            items = records(index, api)
            old = next((item for item in items if item.get("origin_id") == origin), None)
            if old:
                if (old["provenance"] != "engineer-asset-reference" or old["source"] != source
                        or old["filename"] != filename or old["sha256"] != digest):
                    fail(api, "REFERENCE_CONFLICT")
                if hash_checked(fd, api) != digest:
                    fail(api, "CHECKSUM_MISMATCH")
                with asset_source(ws, origin, api) as (_, current):
                    if stamp(info) != stamp(current):
                        fail(api, "FILE_CHANGED")
                return {"status": "ok", "file": public(old), "already_registered": True}
            capacity(index, files, items, api, info.st_size, 1)
            identity = "support-" + secrets.token_hex(16)
            count, actual_digest = copy_checked(fd, identity, api,
                                              {"size_bytes": info.st_size, "sha256": digest}, dir_fd=files)
            try:
                if count != info.st_size or stamp(info) != stamp(os.fstat(fd)):
                    fail(api, "FILE_CHANGED")
                capacity(index, files, items, api)
                with asset_source(ws, origin, api) as (_, current):
                    if stamp(info) != stamp(current):
                        fail(api, "FILE_CHANGED")
            except BaseException:
                os.unlink(identity, dir_fd=files)
                raise
            item = {"id": identity, "filename": filename, "size_bytes": count,
                    "sha256": actual_digest, "imported_at": int(time.time()),
                    "provenance": "engineer-asset-reference", "origin_id": origin,
                    "actor": by, "source": source}
            return publish(item, index, files, api)
    except (OSError, ValueError, TypeError, UnicodeError) as error:
        if isinstance(error, ValueError) and str(error).startswith("STANDARD_"):
            raise
        fail(api, "IO")


class ReaderWorkspace:
    """Keep optional gem-cache mounts out of the reference-only sandbox."""
    def __init__(self, ws):
        self.ws = ws
        self.values = {key: value for key, value in ws.values.items() if key != "SILO_CONTROL_GEMS"}

    def __getattr__(self, name):
        return getattr(self.ws, name)


def read_options(request, api, modes, default):
    mode = request.get("mode", default)
    offset, limit, columns = request.get("offset", 0), request.get("limit", 20), request.get("columns", 20)
    sheet = request.get("sheet")
    if (mode not in modes or type(offset) is not int or not 0 <= offset < 500000
            or type(limit) is not int or not 1 <= limit <= 100
            or type(columns) is not int or not 1 <= columns <= 50
            or (sheet is not None and (not isinstance(sheet, str) or not 0 < len(sheet) <= 128
                                      or any(ord(c) < 32 or ord(c) == 127 for c in sheet)))):
        fail(api, "ARGUMENTS_INVALID")
    return mode, offset, limit, columns, sheet


def parser_read(ws, request, api, snapshot, out, format):
    mode, offset, limit, columns, sheet = read_options(request, api, ("sheets", "rows"), "sheets")
    command = ["-s", "KILL", "40", "python3", "-I", "-B", "/silo/bin/supporting_reader.py",
               "--format", format, "--mode", mode, "--offset", str(offset), "--limit", str(limit),
               "--columns", str(columns)]
    if sheet is not None:
        command += ["--sheet=" + sheet]
    command += ["/reference/input"]
    name = "silo-support-" + secrets.token_hex(16)
    argv = api.sandbox_argv(ReaderWorkspace(ws), name, out, [(snapshot, "/reference/input")], command, inputs=[])
    # Only remove the known detached run flag, not arbitrary argument values.
    if argv[:2] != ["run", "-d"]:
        fail(api, "SANDBOX_INVALID")
    argv = ["run", "--rm", *argv[2:]]
    result = None
    try:
        try:
            result = api.docker(argv, timeout=45)
        except Exception:
            fail(api, "PARSER_FAILED")
    finally:
        # A failed/timeout run may leave a container. Never guess at another name.
        try:
            api.docker(["rm", "-f", name], timeout=10)
            check = api.docker(["ps", "-aq", "--filter", "name=^/" + name + "$"], timeout=10)
            if check.returncode or check.stdout.strip():
                fail(api, "CLEANUP_FAILED")
        except Exception:
            fail(api, "CLEANUP_FAILED")
    if len(result.stdout) > MAX_OUTPUT:
        fail(api, "OUTPUT_LIMIT")
    try:
        value = json.loads(result.stdout)
    except (ValueError, UnicodeError):
        fail(api, "PARSER_FAILED")
    if isinstance(value, dict) and value.get("status") == "error":
        code = value.get("error")
        if (isinstance(code, str) and len(code) <= 80
                and re.fullmatch(r"STANDARD_SUPPORTING_[A-Z_]+", code) and code in PARSER_ERRORS):
            api.refuse(code)
        fail(api, "PARSER_FAILED")
    if result.returncode or not isinstance(value, dict) or value.get("status") != "ok":
        fail(api, "PARSER_FAILED")
    return bounded(value, api)


def read(ws, request, api, files, items):
    identity = request.get("id")
    if not isinstance(identity, str) or not SUPPORT_ID.fullmatch(identity):
        fail(api, "ID_INVALID")
    item = next((item for item in items if item["id"] == identity), None)
    if item is None:
        fail(api, "NOT_FOUND")
    if not reference_active(identity, api):
        fail(api, "INACTIVE")
    fd, info = api.open_regular(files, [identity])
    try:
        check_file(info, api, 0o400)
        with tempfile.TemporaryDirectory(prefix="support-read-", dir=ws.data_dir()) as temporary:
            temporary = Path(temporary)
            snapshot = temporary / "input"
            copy_checked(fd, snapshot, api, item)
            suffix = Path(item["filename"]).suffix.lower().lstrip(".")
            if suffix in ("csv", "tsv", "xlsx"):
                out = temporary / "out"
                out.mkdir(mode=0o700)
                return parser_read(ws, request, api, snapshot, out, "csv" if suffix == "tsv" else suffix)
            if suffix not in ("txt", "json", "yaml", "yml", "md") or request.get("mode", "text") != "text":
                fail(api, "UNSUPPORTED")
            read_options(request, api, ("text",), "text")
            with snapshot.open("rb") as stream:
                data = stream.read(16 * 1024 + 1)
            try:
                text = data[:16 * 1024].decode("utf-8", "strict")
            except UnicodeError:
                # A valid multibyte sequence may straddle the bounded head.
                try:
                    import codecs
                    text = codecs.getincrementaldecoder("utf-8")().decode(data[:16 * 1024], final=len(data) <= 16 * 1024)
                except UnicodeError:
                    fail(api, "UNSUPPORTED")
            if "\x00" in text:
                fail(api, "UNSUPPORTED")
            return bounded({"status": "ok", "mode": "text", "text": text,
                            "truncated": len(data) > 16 * 1024}, api)
    finally:
        os.close(fd)


def handle(ws, request, api):
    """Dispatch supporting_list/take/read; errors are fixed parent refusal codes.

    request.op is the operation. take uses ref; read uses id. List returns
    files (active project references), available_refs (current chat only), and
    has_more. Optional api.reference_active(id) is internal role authority; it
    never relaxes native context checks and is never taken from request JSON.
    """
    try:
        op = request.get("op")
        if op == "supporting_read":
            # Reading a registered reference needs the protected session, not upload provenance.
            session, uploads = session_context(request, api), []
        else:
            session, uploads = trusted_context(request, api)
        if op not in ("supporting_list", "supporting_take", "supporting_read"):
            fail(api, "OPERATION_INVALID")
        ws.require(standard=False)
        with ws.lock(), store(ws, api) as (root, index, files):
            items = records(index, api)
            if op == "supporting_take":
                return bounded(take(ws, request, api, root, index, files, items, session, uploads), api)
            if op == "supporting_read":
                return read(ws, request, api, files, items)
            result = {"status": "ok", "files": [], "available_refs": [], "has_more": False}
            refs = [{"id": item["id"], "filename": item["filename"], "size_bytes": item["size_bytes"]} for item in uploads]
            active = [public(item) for item in items if reference_active(item["id"], api)]
            for key, entries in (("available_refs", refs), ("files", active)):
                for item in entries:
                    result[key].append(item)
                    if len(encoded(result)) > MAX_OUTPUT:
                        result[key].pop()
                        result["has_more"] = True
                        break
            return bounded(result, api)
    except (OSError, ValueError, TypeError, UnicodeError) as error:
        # Preserve parent's fixed refusals, but never leak filesystem/parser errors.
        if isinstance(error, ValueError) and str(error).startswith("STANDARD_"):
            raise
        fail(api, "IO")
