#!/usr/bin/env -S python3 -I
"""Extract one archive into a directory, inside the migration-data sandbox.

    python3 -I data_extract.py ARCHIVE OUTDIR

zip, tar (plain/gzip/bzip2/xz) or one gzip/bzip2/xz-compressed file. Only regular files
and directories are written; links, devices, absolute names and '..' are skipped and
counted. Files are created exclusively without following symlinks, so nothing outside
OUTDIR is touched. Limits: entries and total bytes. Prints one JSON summary line.
"""
import bz2
import gzip
import json
import lzma
import os
import sys
import tarfile
import zipfile

MAX_ENTRIES = 500_000
MAX_TOTAL = 512 * 1024 ** 3
CHUNK = 1024 * 1024
# Stop before the disk every service on the node shares runs low: a zip bomb, or simply a
# bigger export than the disk can hold, must not break the node.
RESERVE_MIN = 20 * 1024 ** 3
CHECK_EVERY = 64 * 1024 * 1024


def disk_low(root):
    info = os.statvfs(root)
    override = os.environ.get("SILO_DATA_RESERVE_BYTES")  # tests only; the sandbox never sets it
    reserve = int(override) if override and override.isdigit() else max(RESERVE_MIN, info.f_blocks * info.f_frsize // 10)
    return info.f_bavail * info.f_frsize < reserve


def safe_parts(name):
    name = name.replace("\\", "/")
    parts = [part for part in name.split("/") if part not in ("", ".")]
    if not parts or name.startswith("/") or any(part == ".." or "\x00" in part for part in parts):
        return None
    return parts


def ensure_dirs(root, parts):
    path = root
    for part in parts:
        path = os.path.join(path, part)
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            if os.path.islink(path) or not os.path.isdir(path):
                raise ValueError("not a directory: " + path)
    return path


def write_stream(root, parts, stream, totals):
    if disk_low(root):
        raise ValueError("stopped: the disk reached its free-space reserve")
    directory = ensure_dirs(root, parts[:-1])
    target = os.path.join(directory, parts[-1])
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as out:
        while True:
            chunk = stream.read(CHUNK)
            if not chunk:
                break
            before = totals["bytes"]
            totals["bytes"] += len(chunk)
            if totals["bytes"] > MAX_TOTAL:
                raise ValueError("total size limit reached")
            if before // CHECK_EVERY != totals["bytes"] // CHECK_EVERY and disk_low(root):
                raise ValueError("stopped: the disk reached its free-space reserve")
            out.write(chunk)
    totals["files"] += 1


def extract(archive, root):
    totals = {"files": 0, "dirs": 0, "skipped": 0, "bytes": 0, "skipped_names": []}

    def skip(name):
        totals["skipped"] += 1
        if len(totals["skipped_names"]) < 20:
            totals["skipped_names"].append(name[:200])

    if zipfile.is_zipfile(archive):
        kind = "zip"
        with zipfile.ZipFile(archive) as source:
            for count, item in enumerate(source.infolist()):
                if count >= MAX_ENTRIES:
                    raise ValueError("entry limit reached")
                parts = safe_parts(item.filename)
                mode = (item.external_attr >> 16) & 0o170000
                if parts is None or mode not in (0, 0o100000, 0o040000):
                    skip(item.filename)
                elif item.is_dir():
                    ensure_dirs(root, parts)
                    totals["dirs"] += 1
                else:
                    with source.open(item) as stream:
                        write_stream(root, parts, stream, totals)
        return kind, totals
    try:
        source = tarfile.open(archive, mode="r:*")
    except tarfile.TarError:
        source = None
    if source is not None:
        kind = "tar"
        with source:
            for count, item in enumerate(source):
                if count >= MAX_ENTRIES:
                    raise ValueError("entry limit reached")
                parts = safe_parts(item.name)
                if parts is None or not (item.isreg() or item.isdir()):
                    skip(item.name)
                elif item.isdir():
                    ensure_dirs(root, parts)
                    totals["dirs"] += 1
                else:
                    write_stream(root, parts, source.extractfile(item), totals)
        return kind, totals
    with open(archive, "rb") as handle:
        magic = handle.read(6)
    opener = gzip.open if magic[:2] == b"\x1f\x8b" else bz2.open if magic[:3] == b"BZh" else lzma.open if magic == b"\xfd7zXZ\x00" else None
    if opener is None:
        raise ValueError("not a supported archive (zip, tar, gzip, bzip2, xz)")
    name = os.path.basename(archive)
    for suffix in (".gz", ".bz2", ".xz", ".tgz"):
        if name.endswith(suffix) and len(name) > len(suffix):
            name = name[: -len(suffix)] + (".tar" if suffix == ".tgz" else "")
            break
    else:
        name += ".out"
    with opener(archive, "rb") as stream:
        write_stream(root, [name], stream, totals)
    return "compressed-file", totals


def main(argv):
    if len(argv) != 3:
        print("usage: data_extract.py ARCHIVE OUTDIR", file=sys.stderr)
        return 2
    try:
        kind, totals = extract(argv[1], argv[2])
    except (ValueError, OSError, EOFError, zipfile.BadZipFile, tarfile.TarError, lzma.LZMAError) as error:
        print(json.dumps({"status": "failed", "error": str(error)[:500]}))
        return 1
    print(json.dumps({"status": "extracted", "archive": kind, **totals}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
