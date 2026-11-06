#!/usr/bin/env -S python3 -I
"""Read-only, path-limited file tools for the server-support agent.

term-llm runs custom tools without an approval prompt, so every limit is enforced
here: only allow-listed files under the allowed roots, never migration workspaces or
the service temp directory (customer data), never credential files, and
secret-looking values are redacted. Edits are not offered here; the agent uses
term-llm's built-in edit_file/write_file, which prompt the engineer for every write.

Trust boundary: the service account itself can change these files (and this script)
through an approved write. Hard links, bind mounts and same-account races between
resolving and opening a path are inside that boundary.
"""
import json
import os
import pwd
import re
import stat
import sys

# Installed as <prefix>/releases/<commit>/integrations/term-llm/server-support.
INSTALLED_AGENT = re.compile(r"(/.+)/releases/[0-9a-f]{40}/integrations/term-llm/[a-z][a-z-]*")
# term-llm 0.9.93 cuts custom tool output at 50 KiB; stay well under it.
MAX_TEXT_BYTES = 32 * 1024
MAX_LINES = 2000
MAX_LINE_CHARS = 4096
READ_CHUNK = 16 * 1024
SCAN_LIMIT = 16 * 1024 * 1024
# Credential stores and secret-named files. term-llm 0.9.93 keeps ChatGPT OAuth in
# chatgpt_oauth.json and service secrets (web bearer token, Hub token) under
# services/<kind>/credentials/.
SECRET_COMPONENT = re.compile(
    r"(?i)(^credentials?$|oauth|token|secret|passw|private|cookie|session|"
    r"\.env$|\.pem$|\.key$|\.p12$|\.pfx$|^id_(rsa|ecdsa|ed25519)|^auth\.json$|^web-auth$|keyring|\.sqlite3?$|\.db$)")
SECRET_KEY = (r"[\w.-]*(?:api[_-]?key|apikey|token|secret|passw(?:or)?d|passphrase|bearer|authorization|credential"
              r"|private[_-]?key|access[_-]?key|session[_-]?key)[\w.-]*")
KEY_VALUE = re.compile(
    r"(?i)(?P<lead>(?:^|[\s{,;(\[])(?:export\s+)?)(?P<q>[\"']?)(?P<key>" + SECRET_KEY + r")(?P=q)(?P<sep>\s*[:=]\s*)"
    r"(?P<value>\"(?:[^\"\\]|\\.)*\"|'[^']*'|[^\s,;}\]][^,;}\]\r\n]*)?")
FLAG = re.compile(r"(?i)(?P<flag>(?<![\w-])--?" + SECRET_KEY + r")(?P<sep>=|[ \t]+)(?P<value>\"[^\"]*\"|'[^']*'|[^\s\"',\]]+)")
FLAG_JSON = re.compile(r"(?i)(?P<flag>\"--?" + SECRET_KEY + r"\"\s*,\s*)(?P<value>\"(?:[^\"\\]|\\.)*\")")
FLAG_JSON_TRAILING = re.compile(r"(?i)\"--?" + SECRET_KEY + r"\"\s*,?\s*$")
SECRET_INLINE = [
    re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),
    re.compile(r"\b(sk|pk|rk|ghp|gho|ghs|ghu|github_pat|xox[abpr])[-_][A-Za-z0-9_-]{16,}"),
    re.compile(r"(?i)\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@"),
]
PEM_BEGIN = re.compile(r"-----BEGIN [A-Z0-9 ]*(PRIVATE KEY|CERTIFICATE REQUEST|OPENSSH PRIVATE KEY)-----")
PEM_END = re.compile(r"-----END [A-Z0-9 ]*-----")
NOT_SECRET = re.compile(r"(?i)(|null|~|none|true|false|-?\d+(\.\d+)?|\[REDACTED\])\Z")
REFERENCE = re.compile(r"(\$\(|\$\{|\$[A-Za-z_]|op://)")


class Refusal(Exception):
    pass


def installed_prefix():
    agent_dir = os.path.realpath(os.environ.get("TERM_LLM_AGENT_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    installed = INSTALLED_AGENT.fullmatch(agent_dir)
    return installed[1] if installed else None


def prefix():
    # SILO_SUPPORT_PREFIX/HOME serve development checkouts and tests only; an installed
    # release derives both from its own location and the account.
    return installed_prefix() or os.environ.get("SILO_SUPPORT_PREFIX")


def home():
    if installed_prefix() is None and os.environ.get("SILO_SUPPORT_HOME"):
        return os.environ["SILO_SUPPORT_HOME"]
    return pwd.getpwuid(os.getuid()).pw_dir


def real(path):
    return os.path.realpath(path)


def configured_workspaces(root):
    """The control config's workspaces base. None (fail closed) if unreadable or absent."""
    try:
        with open(os.path.join(root, "etc", "silo-control.env"), encoding="utf-8") as config:
            for line in config:
                line = line.strip()
                if line.startswith("export "):
                    line = line[len("export "):].lstrip()
                key, _, value = line.partition("=")
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                if key.strip() == "SILO_MIGRATE_BASE_PATH":
                    return [value] if value.startswith("/") else None
    except (OSError, UnicodeDecodeError):
        return None
    return None


# Which entries of a root are readable. term-llm's config directory also holds MCP
# config, images, backups and caches, so only the files that matter for support.
def term_llm_rule(relative, is_dir):
    if is_dir:
        return relative in (".", "agents", "skills", "services") or bool(re.match(r"(agents|skills)/", relative)) \
            or bool(re.fullmatch(r"services/[^/]+", relative))
    return relative == "config.yaml" or bool(re.match(r"(agents|skills)/", relative)) \
        or bool(re.fullmatch(r"services/[^/]+/service\.json", relative))


def op_cache_rule(relative, is_dir):
    return relative == "." if is_dir else relative == "config.yaml"


def any_rule(_relative, _is_dir):
    return True


def boundaries():
    base = home()
    allowed = [(real(os.path.join(base, ".config", "term-llm")), term_llm_rule),
               (real(os.path.join(base, ".config", "op-cache")), op_cache_rule)]
    denied, exceptions = [], set()
    if os.environ.get("SILO_MIGRATE_BASE_PATH", "").startswith("/"):
        denied.append(os.environ["SILO_MIGRATE_BASE_PATH"])
    root = prefix()
    if root:
        denied += [os.path.join(root, "workspaces"), os.path.join(root, "state", "tmp")]
        workspaces = configured_workspaces(root)
        if workspaces is not None:
            denied += workspaces
            allowed += [(real(os.path.join(root, name)), any_rule) for name in ("etc", "state", "current")]
            control_env = os.path.join(root, "etc", "silo-control.env")
            if not os.path.islink(control_env):
                exceptions.add(real(control_env))
    return allowed, [real(path) for path in denied], exceptions


def inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def resolve(raw):
    if not isinstance(raw, str) or not raw or len(raw) > 4096 or "\x00" in raw:
        raise Refusal("SUPPORT_ARGUMENTS_INVALID")
    if raw == "~" or raw.startswith("~/"):
        raw = home() + raw[1:]
    if not os.path.isabs(raw):
        raise Refusal("SUPPORT_PATH_NOT_ABSOLUTE")
    allowed, denied, exceptions = boundaries()
    resolved = real(raw)
    if any(inside(resolved, root) for root in denied):
        raise Refusal("SUPPORT_PATH_REFUSED_CUSTOMER_DATA")
    match = next(((root, rule) for root, rule in allowed if inside(resolved, root)), None)
    if match is None:
        raise Refusal("SUPPORT_PATH_NOT_ALLOWED")
    root, rule = match
    relative = os.path.relpath(resolved, root)
    if resolved not in exceptions and relative != "." and any(SECRET_COMPONENT.search(part) for part in relative.split("/")):
        raise Refusal("SUPPORT_PATH_REFUSED_SECRET")
    if not rule(relative, os.path.isdir(resolved)):
        raise Refusal("SUPPORT_PATH_NOT_ALLOWED")
    return resolved


def indentation(line):
    return len(line) - len(line.lstrip(" \t"))


def redact_line(line, state):
    """Redact one line; `state` carries PEM blocks, YAML block values and split flags."""
    newline = "\n" if line.endswith("\n") else ""
    if state["pem"]:
        if PEM_END.search(line):
            state["pem"] = False
        return "[REDACTED]" + newline, 1
    if state["block"] is not None:
        if not line.strip():
            return line, 0
        if indentation(line) > state["block"]:
            return " " * indentation(line) + "[REDACTED]" + newline, 1
        state["block"] = None
    if PEM_BEGIN.search(line):
        state["pem"] = not PEM_END.search(line)
        return "[REDACTED PRIVATE BLOCK]" + newline, 1
    count = 0
    if state["flag"]:
        state["flag"] = False
        line, replaced = re.subn(r"\"(?:[^\"\\]|\\.)*\"", "\"[REDACTED]\"", line, count=1)
        count += replaced

    def key_value(match):
        nonlocal count
        value = match.group("value")
        # A YAML block scalar (`key: |`) or nested value (`key:`): redact the
        # deeper-indented lines that follow.
        if value is None:
            if not line[match.end():].strip():
                state["block"] = indentation(line)
            return match.group(0)
        if re.fullmatch(r"[|>][-+0-9]*\s*", value):
            state["block"] = indentation(line)
            return match.group(0)
        bare = value.strip().strip("\"'")
        if NOT_SECRET.match(bare) or REFERENCE.match(bare):
            return match.group(0)
        count += 1
        quote = value[0] if value[0] in "\"'" else ""
        return match.group("lead") + match.group("q") + match.group("key") + match.group("q") + match.group("sep") + quote + "[REDACTED]" + quote

    line = KEY_VALUE.sub(key_value, line)

    def flag(match):
        nonlocal count
        bare = match.group("value").strip("\"'")
        if NOT_SECRET.match(bare) or REFERENCE.match(bare):
            return match.group(0)
        count += 1
        return match.group("flag") + match.group("sep") + "[REDACTED]"

    line = FLAG.sub(flag, line)
    line = FLAG_JSON.sub(lambda match: match.group("flag") + "\"[REDACTED]\"", line)
    if FLAG_JSON_TRAILING.search(line):
        state["flag"] = True
    for pattern in SECRET_INLINE:
        line, replaced = pattern.subn("[REDACTED]", line)
        count += replaced
    return line, count


def open_regular(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0))
    info = os.fstat(descriptor)
    try:
        current = os.stat(path, follow_symlinks=False)
    except OSError:
        current = None
    if not stat.S_ISREG(info.st_mode) or current is None or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        os.close(descriptor)
        raise Refusal("SUPPORT_NOT_A_FILE")
    return os.fdopen(descriptor, "rb"), info


def lines_of(stream):
    """Yield (text, truncated, bytes_scanned) per line, reading at most READ_CHUNK of a long line."""
    while True:
        chunk = stream.readline(READ_CHUNK)
        if not chunk:
            return
        scanned = len(chunk)
        truncated = False
        if not chunk.endswith(b"\n") and len(chunk) == READ_CHUNK:
            truncated = True
            while True:
                rest = stream.readline(READ_CHUNK * 4)
                scanned += len(rest)
                if not rest or rest.endswith(b"\n") or scanned > SCAN_LIMIT:
                    break
        yield chunk.decode("utf-8", "replace"), truncated, scanned


def read_file(args):
    path = resolve(args.get("path"))
    start = args.get("start_line", 1)
    if not isinstance(start, int) or isinstance(start, bool) or start < 1:
        raise Refusal("SUPPORT_ARGUMENTS_INVALID")
    try:
        stream, info = open_regular(path)
    except FileNotFoundError:
        raise Refusal("SUPPORT_NOT_FOUND")
    except PermissionError:
        raise Refusal("SUPPORT_PERMISSION_DENIED")
    except OSError:
        raise Refusal("SUPPORT_NOT_A_FILE")
    with stream:
        if b"\x00" in stream.read(8192):
            return {"version": 1, "path": path, "bytes": info.st_size, "binary": True}
        stream.seek(0)
        state = {"pem": False, "block": None, "flag": False}
        lines, used, redactions, next_line, scanned, scan_limited = [], 0, 0, None, 0, False
        for number, (text, truncated, size) in enumerate(lines_of(stream), 1):
            scanned += size
            text, count = redact_line(text, state)
            if number >= start:
                if len(text) > MAX_LINE_CHARS or truncated:
                    text = text[:MAX_LINE_CHARS].rstrip("\n") + " …[line truncated]\n"
                cost = len(json.dumps(text).encode("utf-8"))
                if len(lines) >= MAX_LINES or used + cost > MAX_TEXT_BYTES:
                    next_line = number
                    break
                redactions += count
                lines.append(text)
                used += cost
            if scanned > SCAN_LIMIT:
                scan_limited = True
                next_line = number + 1
                break
    result = {"version": 1, "path": path, "bytes": info.st_size, "start_line": start, "lines": len(lines),
              "next_line": next_line, "redactions": redactions, "text": "".join(lines)}
    if scan_limited:
        result["scan_limit_reached"] = "stopped after 16 MiB; ask the engineer to approve a bounded shell command such as tail"
    return result


def list_dir(args):
    path = resolve(args.get("path"))
    if not os.path.isdir(path):
        raise Refusal("SUPPORT_NOT_A_DIRECTORY")
    try:
        names = sorted(os.listdir(path))
    except PermissionError:
        raise Refusal("SUPPORT_PERMISSION_DENIED")
    entries, used, truncated = [], 0, False
    for name in names:
        child = os.path.join(path, name)
        try:
            info = os.lstat(child)
        except OSError:
            continue
        kind = "symlink" if stat.S_ISLNK(info.st_mode) else "dir" if stat.S_ISDIR(info.st_mode) else "file" if stat.S_ISREG(info.st_mode) else "other"
        entry = {"name": name, "type": kind, "mode": oct(info.st_mode & 0o7777)}
        if kind == "file":
            entry["bytes"] = info.st_size
        try:
            resolve(child)
        except Refusal as refusal:
            entry["refused"] = str(refusal)
        cost = len(json.dumps(entry).encode("utf-8")) + 2
        if used + cost > MAX_TEXT_BYTES:
            truncated = True
            break
        entries.append(entry)
        used += cost
    return {"version": 1, "path": path, "entries": entries, "total": len(names), "truncated": truncated}


def roots(_args):
    allowed, denied, _exceptions = boundaries()
    return {"version": 1, "allowed": sorted(root for root, _rule in allowed), "refused": sorted(denied),
            "within_allowed": "~/.config/term-llm: config.yaml, agents/, skills/, services/*/service.json; ~/.config/op-cache: config.yaml",
            "also_refused": "credential stores and secret-named files; secret-looking values are redacted"}


TOOLS = {"support_read_file": read_file, "support_list_dir": list_dir, "support_allowed_paths": roots}


def main():
    tool = TOOLS.get(os.environ.get("TERM_LLM_TOOL_NAME", ""))
    try:
        if tool is None:
            raise Refusal("SUPPORT_TOOL_UNKNOWN")
        try:
            args = json.load(sys.stdin)
        except ValueError:
            raise Refusal("SUPPORT_ARGUMENTS_INVALID")
        if not isinstance(args, dict):
            raise Refusal("SUPPORT_ARGUMENTS_INVALID")
        result = tool(args)
    except Refusal as refusal:
        result = {"version": 1, "error": str(refusal)}
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
