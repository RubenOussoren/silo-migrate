"""Preflight Docker/OCI image archives without granting them daemon authority.

One forward pass over the (optionally gzipped) archive: each file is hashed as
stored and, when it is a gzip stream, as its uncompressed content, so compressed
OCI layers can be checked against the config's diff_ids without seeking back.
Only an archive holding exactly the bound image, tagged with nothing but the
bound reference (in any of Docker's spellings), is accepted.
"""
import hashlib
import json
import re
import tarfile
import zlib

CHUNK = 1024 * 1024
SMALL = 16 * 1024 * 1024        # largest file kept in memory (config/manifest/index)
KEPT_TOTAL = 64 * 1024 * 1024   # bound on all kept bytes
METADATA = ("index.json", "manifest.json", "oci-layout", "repositories")
GZIP_TYPES = ("application/vnd.oci.image.layer.v1.tar+gzip", "application/vnd.docker.image.rootfs.diff.tar.gzip")
TAR_TYPES = ("application/vnd.oci.image.layer.v1.tar", "application/vnd.docker.image.rootfs.diff.tar")
MANIFEST_TYPES = ("application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json")


def require(ok):
    if not ok:
        raise ValueError("image archive identity/tag/structure refused")


def spellings(ref):
    """Names Docker/containerd may record for ref: as given, fully normalized, tag only."""
    require(isinstance(ref, str) and re.fullmatch(r"[a-z0-9][a-z0-9._/:@-]*", ref or "") is not None)
    name, at, digest = ref.partition("@")
    tag = ""
    if ":" in name.rsplit("/", 1)[-1]:
        name, tag = name.rsplit(":", 1)
    first = name.split("/", 1)[0]
    if "/" not in name:
        full = "docker.io/library/" + name
    elif "." in first or ":" in first or first == "localhost":
        full = name
    else:
        full = "docker.io/" + name
    suffix = (":" + tag if tag else "") + (at + digest if at else "")
    names = {ref, full + suffix}
    if tag and not at:
        names.add(tag)
    return names


class _Inflater:
    """Incremental gzip (multi-member) digest of uncompressed bytes."""

    def __init__(self):
        self.digest = hashlib.sha256()
        self.state = zlib.decompressobj(31)

    def feed(self, data):
        while data:
            self.digest.update(self.state.decompress(data))
            if not self.state.eof:
                return
            data = self.state.unused_data
            if data:
                self.state = zlib.decompressobj(31)

    def finish(self):
        self.digest.update(self.state.flush())
        require(self.state.eof)
        return self.digest.hexdigest()


def _scan(path):
    files, kept = {}, 0
    with tarfile.open(path, "r|*") as archive:
        for member in archive:
            name = member.name.rstrip("/")
            parts = name.split("/")
            require(name and not member.name.startswith("/") and "." not in parts and ".." not in parts
                    and "" not in parts and (member.isfile() or member.isdir()) and name not in files)
            if member.isdir():
                files[name] = None
                continue
            stream = archive.extractfile(member)
            raw, inflater, buffer, first = hashlib.sha256(), None, None, True
            if member.size <= SMALL and kept + member.size <= KEPT_TOTAL:
                buffer = bytearray()
            for chunk in iter(lambda: stream.read(CHUNK), b""):
                if first:
                    inflater = _Inflater() if chunk[:2] == b"\x1f\x8b" else None
                    first = False
                raw.update(chunk)
                if inflater:
                    inflater.feed(chunk)
                if buffer is not None:
                    buffer += chunk
            if buffer is not None:
                kept += len(buffer)
            files[name] = dict(size=member.size, sha256=raw.hexdigest(),
                               gunzip=inflater.finish() if inflater else None,
                               data=bytes(buffer) if buffer is not None else None)
    return files


def validate(path, expected, identity):
    files = _scan(path)
    allowed = spellings(expected["ref"])
    referenced = set()

    def entry(name):
        require(isinstance(name, str) and isinstance(files.get(name), dict))
        referenced.add(name)
        return files[name]

    def content(name):
        data = entry(name)["data"]
        require(data is not None)
        return data

    def blob(descriptor):
        digest = descriptor.get("digest", "")
        require(isinstance(digest, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is not None)
        item = entry("blobs/sha256/" + digest[7:])
        require(item["sha256"] == digest[7:] and item["size"] == descriptor.get("size"))
        return item

    def check(config_raw, diffs, config_digest):
        require(hashlib.sha256(config_raw).hexdigest() == config_digest)
        config = json.loads(config_raw)
        require(config["rootfs"]["diff_ids"] == ["sha256:" + d for d in diffs])
        document = {"Architecture": config.get("architecture"), "Os": config.get("os"),
                    "Config": config.get("config"), "RootFS": {"Layers": config["rootfs"]["diff_ids"]}}
        require(identity.content_id(document) == expected["content_id"])
        return "sha256:" + config_digest

    for name in METADATA:
        if name in files:
            entry(name)
    if "oci-layout" in files:
        require(json.loads(content("oci-layout")).get("imageLayoutVersion") == "1.0.0")
    if "repositories" in files:
        repositories = json.loads(content("repositories"))
        require(isinstance(repositories, dict) and len(repositories) <= 1)
        for repo, tags in repositories.items():
            require(isinstance(tags, dict) and all(repo + ":" + tag in allowed for tag in tags))

    ids = []
    if "manifest.json" in files:
        manifest = json.loads(content("manifest.json"))
        require(isinstance(manifest, list) and len(manifest) == 1)
        image = manifest[0]
        require(set(image) <= {"Config", "RepoTags", "Layers", "LayerSources"})
        require(image.get("RepoTags") in (None, []) or (isinstance(image["RepoTags"], list) and len(image["RepoTags"]) == 1
                                                        and image["RepoTags"][0] in allowed))
        config_name = image["Config"]
        config_item = entry(config_name)
        config_digest = config_name.removesuffix(".json").split("/")[-1]
        require(config_item["sha256"] == config_digest)
        diffs = []
        for layer in image["Layers"]:
            item = entry(layer)
            diffs.append(item["gunzip"] or item["sha256"])
        ids.append(check(content(config_name), diffs, config_digest))
    if "index.json" in files:
        index = json.loads(content("index.json"))
        require(len(index["manifests"]) == 1)
        descriptor = index["manifests"][0]
        require(descriptor.get("mediaType") in MANIFEST_TYPES)
        # OCI ref annotations are tags too. Never allow a foreign ref.
        for item in (index, descriptor):
            annotations = item.get("annotations", {})
            for key in ("org.opencontainers.image.ref.name", "io.containerd.image.name"):
                require(key not in annotations or annotations[key] in allowed)
        manifest_item = blob(descriptor)
        manifest = json.loads(content("blobs/sha256/" + manifest_item["sha256"]))
        require(manifest.get("mediaType", descriptor["mediaType"]) in MANIFEST_TYPES)
        config_item = blob(manifest["config"])
        diffs = []
        for layer in manifest["layers"]:
            item = blob(layer)
            if layer.get("mediaType") in GZIP_TYPES:
                require(item["gunzip"] is not None)
                diffs.append(item["gunzip"])
            else:
                # zstd and unknown encodings are refused rather than guessed.
                require(layer.get("mediaType") in TAR_TYPES and item["gunzip"] is None)
                diffs.append(item["sha256"])
        ids.append(check(content("blobs/sha256/" + config_item["sha256"]), diffs, config_item["sha256"]))
    require(ids and len(set(ids)) == 1)
    # Anything not reachable from the single bound image could be another image.
    require({name for name, item in files.items() if item is not None} == referenced)
    return ids[0]
