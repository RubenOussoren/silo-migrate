#!/usr/bin/env -S python3 -I
"""Read-only, path-limited file tools for the server-support agent.

term-llm runs custom tools without an approval prompt, so every limit is enforced
here: only the allowed roots, never migration workspaces or the service temp
directory (customer data), never credential files, and secret-looking values are
redacted. Edits are not offered here; the agent uses term-llm's built-in
edit_file/write_file, which prompt the engineer for every write.
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
MAX_ENTRIES = 500
# Credential stores and secret-named files. term-llm keeps ChatGPT OAuth in
# chatgpt_oauth.json and service secrets (web bearer token, Hub token) under
# services/<kind>/credentials/.
SECRET_COMPONENT = re.compile(
    r"(?i)(^credentials?$|oauth|token|secret|passw|private|cookie|session|"
    r"\.env$|\.pem$|\.key$|\.p12$|\.pfx$|^id_(rsa|ecdsa|ed25519)|^auth\.json$|^web-auth$|keyring|\.sqlite3?$|\.db$)")
SECRET_ASSIGNMENT = re.compile(
    r"(?i)^(\s*[-\w.\"']*(api[_-]?key|token|secret|passw(or)?d|bearer|authorization|credential|private[_-]?key|client[_-]?secret)[\w.\"']*\s*[:=]\s*)(.*?)\s*$")
SECRET_INLINE = [
    re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),
    re.compile(r"\b(sk|pk|rk|ghp|gho|ghs|ghu|github_pat|xox[abpr])[-_][A-Za-z0-9_-]{16,}"),
    re.compile(r"(?i)\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@"),
]
PEM_BEGIN = re.compile(r"-----BEGIN [A-Z0-9 ]*(PRIVATE KEY|CERTIFICATE REQUEST|OPENSSH PRIVATE KEY)-----")
PEM_END = re.compile(r"-----END [A-Z0-9 ]*-----")


class Refusal(Exception):
    pass


def home():
    return os.environ.get("SILO_SUPPORT_HOME") or pwd.getpwuid(os.getuid()).pw_dir


def prefix():
    override = os.environ.get("SILO_SUPPORT_PREFIX")
    if override:
        return override
    agent_dir = os.path.realpath(os.environ.get("TERM_LLM_AGENT_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    installed = INSTALLED_AGENT.fullmatch(agent_dir)
    return installed[1] if installed else None


def real(path):
    return os.path.realpath(path)


def configured_workspaces(root):
    # The control config names the workspaces base; it may live outside the prefix.
    try:
        with open(os.path.join(root, "etc", "silo-control.env"), encoding="utf-8") as config:
            for line in config:
                key, _, value = line.strip().partition("=")
                if key == "SILO_MIGRATE_BASE_PATH" and value.startswith("/"):
                    return [value]
    except OSError:
        pass
    return []


def boundaries():
    base = home()
    allowed = {real(os.path.join(base, ".config", "term-llm")): "term-llm config",
               real(os.path.join(base, ".config", "op-cache")): "op-cache config"}
    denied = []
    root = prefix()
    exceptions = set()
    if root:
        for name in ("etc", "state", "current"):
            allowed[real(os.path.join(root, name))] = "silo-migrate " + name
        denied += [os.path.join(root, "workspaces"), os.path.join(root, "state", "tmp")] + configured_workspaces(root)
        exceptions.add(real(os.path.join(root, "etc", "silo-control.env")))
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
    root = next((root for root in allowed if inside(resolved, root)), None)
    if root is None:
        raise Refusal("SUPPORT_PATH_NOT_ALLOWED")
    relative = os.path.relpath(resolved, root)
    if resolved not in exceptions and relative != "." and any(SECRET_COMPONENT.search(part) for part in relative.split("/")):
        raise Refusal("SUPPORT_PATH_REFUSED_SECRET")
    return resolved


def redact_line(line, state):
    if state["pem"]:
        if PEM_END.search(line):
            state["pem"] = False
        return "[REDACTED]\n" if line.endswith("\n") else "[REDACTED]", 1
    if PEM_BEGIN.search(line):
        state["pem"] = not PEM_END.search(line)
        return "[REDACTED PRIVATE BLOCK]\n", 1
    count = 0
    match = SECRET_ASSIGNMENT.match(line.rstrip("\n"))
    if match:
        value = match.group(4).strip().strip("\"'")
        # References are not secrets: $(command), ${VAR}, $VAR, op:// paths, empty/null.
        if value and value.lower() not in ("null", "~", "none", "false", "true") and not re.match(r"(\$\(|\$\{|\$[A-Z_]|op://)", value):
            line = match.group(1) + "[REDACTED]" + ("\n" if line.endswith("\n") else "")
            count += 1
    for pattern in SECRET_INLINE:
        line, replaced = pattern.subn("[REDACTED]", line)
        count += replaced
    return line, count


def open_regular(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0))
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode):
        os.close(descriptor)
        raise Refusal("SUPPORT_NOT_A_FILE")
    return os.fdopen(descriptor, "rb"), info


def read_file(args):
    path = resolve(args.get("path"))
    start = args.get("start_line", 1)
    if not isinstance(start, int) or isinstance(start, bool) or start < 1:
        raise Refusal("SUPPORT_ARGUMENTS_INVALID")
    try:
        stream, info = open_regular(path)
    except FileNotFoundError:
        raise Refusal("SUPPORT_NOT_FOUND")
    except IsADirectoryError:
        raise Refusal("SUPPORT_NOT_A_FILE")
    except PermissionError:
        raise Refusal("SUPPORT_PERMISSION_DENIED")
    except OSError:
        raise Refusal("SUPPORT_NOT_A_FILE")
    with stream:
        if b"\x00" in stream.read(8192):
            return {"version": 1, "path": path, "bytes": info.st_size, "binary": True}
        stream.seek(0)
        state = {"pem": False}
        lines, used, redactions, next_line = [], 0, 0, None
        for number, raw in enumerate(stream, 1):
            text = raw.decode("utf-8", "replace")
            text, count = redact_line(text, state)
            if number < start:
                continue
            redactions += count
            cost = len(json.dumps(text).encode("utf-8"))
            if len(lines) >= MAX_LINES or used + cost > MAX_TEXT_BYTES:
                next_line = number
                break
            lines.append(text)
            used += cost
    return {"version": 1, "path": path, "bytes": info.st_size, "start_line": start, "lines": len(lines),
            "next_line": next_line, "redactions": redactions, "text": "".join(lines)}


def list_dir(args):
    path = resolve(args.get("path"))
    if not os.path.isdir(path):
        raise Refusal("SUPPORT_NOT_A_DIRECTORY")
    try:
        names = sorted(os.listdir(path))
    except PermissionError:
        raise Refusal("SUPPORT_PERMISSION_DENIED")
    entries = []
    for name in names[:MAX_ENTRIES]:
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
        entries.append(entry)
    return {"version": 1, "path": path, "entries": entries, "truncated": len(names) > MAX_ENTRIES}


def roots(_args):
    allowed, denied, _exceptions = boundaries()
    return {"version": 1, "allowed": sorted(allowed), "refused": sorted(denied),
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
