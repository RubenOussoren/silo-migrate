"""Preflight Docker/OCI image archives without granting them daemon authority."""
import contextlib
import gzip
import hashlib
import json
import tarfile


def validate(path, expected, identity):
    def require(ok):
        if not ok:
            raise ValueError("image archive identity/tag/structure refused")

    with tarfile.open(path, "r:*") as archive:
        members = archive.getmembers()
        for member in members:
            require(not member.name.startswith("/") and ".." not in member.name.split("/")
                    and (member.isfile() or member.isdir()))
        names = [m.name for m in members]
        require(len(names) == len(set(names)))
        table = {m.name: m for m in members}

        def data(name):
            require(isinstance(name, str) and name in table and table[name].isfile())
            require(not name.startswith("/") and ".." not in name.split("/"))
            return archive.extractfile(table[name])

        def blob_stream(descriptor):
            digest = descriptor["digest"]
            require(digest.startswith("sha256:") and len(digest) == 71)
            name = "blobs/sha256/" + digest[7:]
            require(table[name].size == descriptor["size"])
            with data(name) as stream:
                h = hashlib.sha256()
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    h.update(block)
            require(h.hexdigest() == digest[7:])
            return data(name)

        def blob(descriptor):
            require(descriptor["size"] <= 16 * 1024 * 1024)
            with blob_stream(descriptor) as stream:
                return stream.read()

        def check(config_raw, layers, config_digest):
            require(hashlib.sha256(config_raw).hexdigest() == config_digest)
            config = json.loads(config_raw)
            diffs = config["rootfs"]["diff_ids"]
            require(len(diffs) == len(layers))
            for diff, layer in zip(diffs, layers):
                with layer() as stream:
                    h = hashlib.sha256()
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        h.update(block)
                require(diff == "sha256:" + h.hexdigest())
            document = {"Architecture": config.get("architecture"), "Os": config.get("os"),
                        "Config": config.get("config"), "RootFS": {"Layers": diffs}}
            require(identity.content_id(document) == expected["content_id"])
            return "sha256:" + config_digest

        ids = []
        if "manifest.json" in table:
            manifest = json.load(data("manifest.json"))
            require(isinstance(manifest, list) and len(manifest) == 1)
            image = manifest[0]
            require(image.get("RepoTags") in ([], [expected["ref"]]))
            config_name = image["Config"]
            config_digest = config_name.removesuffix(".json").split("/")[-1]
            ids.append(check(data(config_name).read(), [lambda n=n: data(n) for n in image["Layers"]], config_digest))
        if "index.json" in table:
            index = json.load(data("index.json"))
            require(len(index["manifests"]) == 1)
            descriptor = index["manifests"][0]
            # OCI ref annotations are tags too. Never allow a foreign ref.
            for item in (index, descriptor):
                annotations = item.get("annotations", {})
                for key in ("org.opencontainers.image.ref.name", "io.containerd.image.name"):
                    require(key not in annotations or annotations[key] == expected["ref"])
            manifest = json.loads(blob(descriptor))
            config = manifest["config"]
            layers = []
            for layer in manifest["layers"]:
                with blob_stream(layer):
                    pass
                @contextlib.contextmanager
                def layer_stream(layer=layer):
                    stream = data("blobs/sha256/" + layer["digest"][7:])
                    if layer["mediaType"].endswith("+gzip") or layer["mediaType"].endswith(".gzip"):
                        with stream, gzip.GzipFile(fileobj=stream) as inflated:
                            yield inflated
                    else:
                        with stream:
                            yield stream
                layers.append(layer_stream)
            ids.append(check(blob(config), layers, config["digest"][7:]))
        require(ids and len(set(ids)) == 1)
        return ids[0]
