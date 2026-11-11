"""Conservative public Discourse versions; see test/fixtures/discourse-versions.json.

parse returns canonical/track/release/numeric, or None. numeric is a comparable
key (within a track), not a core revision. backup returns discourse_version and
schema_version, or None. Legacy schema-only backups parse with version None but
cannot resolve an automatic runtime. dev/custom suffixes are intentionally refused.
Import this module by file path when running Python with -I.
"""
import re

# Release components reject leading zeros; suffix counters may be zero-padded
# historically and are normalized. Every decimal conversion is at most 4 digits.
_NUMBER = r"(?:0|[1-9][0-9]{0,3})"
_MONTH = r"(?:0|[1-9][0-9]?)"
_RELEASE = _NUMBER + r"\." + _MONTH + r"\." + _NUMBER
_SUFFIX = r"(?:-latest(?:[.-][0-9]{1,4})?|[.-](?:beta|rc)[0-9]{1,4}(?:[.-][0-9]{1,4})*)?"
_VERSION = re.compile(r"(" + _RELEASE + r")(" + _SUFFIX + r")\Z")
_FILE_VERSION = _NUMBER + "-" + _MONTH + "-" + _NUMBER + _SUFFIX


def backup_pattern(extension="sql.gz"):
    """Compatibility search regex: groups 1/2 remain raw version/schema."""
    return re.compile(r"-v(?:((?:" + _FILE_VERSION + r"))-)?([0-9]{14})\." + re.escape(extension) + r"\Z")


def parse(value):
    if not isinstance(value, str) or len(value) > 128:
        return None
    match = _VERSION.fullmatch(value)
    if not match:
        return None
    release, suffix = match.groups()
    release = ".".join(str(int(part)) for part in release.split("."))
    if suffix.startswith("-latest"):
        track, rank = "latest", 1
        numbers = [int(suffix[8:])] if len(suffix) > 7 else []
        canonical_suffix = "-latest" + ("." + str(numbers[0]) if numbers else "")
    elif suffix:
        track = "tests-passed"
        label = "beta" if suffix[1:].startswith("beta") else "rc"
        rank = 0 if label == "beta" else 2
        numbers = [int(part) for part in re.split(r"[.-]", suffix[1 + len(label):])]
        canonical_suffix = "." + label + ".".join(str(part) for part in numbers)
    else:
        track, rank, numbers, canonical_suffix = "stable", 3, [], ""
    # Gem::Version treats trailing numeric zero segments as equivalent.
    while numbers and numbers[-1] == 0:
        numbers.pop()
    return {"canonical": release + canonical_suffix, "track": track, "release": release,
            "numeric": (tuple(int(part) for part in release.split(".")), rank, tuple(numbers))}


def backup(name, extension="sql.gz"):
    if not isinstance(name, str):
        return None
    match = backup_pattern(extension).search(name.rsplit("/", 1)[-1])
    if not match:
        return None
    version = parse(match[1].replace("-", ".", 2)) if match[1] else None
    if match[1] and not version:
        return None
    return {"discourse_version": version["canonical"] if version else None, "schema_version": match[2]}
