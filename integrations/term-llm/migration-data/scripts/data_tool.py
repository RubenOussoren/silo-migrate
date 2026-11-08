#!/usr/bin/env -S python3 -I
"""Fixed mapping from migration-data's term-llm tools to `silo-migrate-control data WS`.

Runs only in the Frontier-only migration-data agent: the one agent that handles customer
data. Every tool is one operation of bin/data_tools.py, which confines paths to the
workspace's drop folder, inputs, work folders and converter checkout. Arguments never
reach a shell; only the listed request keys are passed on.
"""
import json
import os
import pwd
import re
import subprocess
import sys

WORKSPACE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\Z")
# term-llm 0.9.93 cuts custom tool output at 50 KiB; refuse rather than pass on cut JSON.
MAX_OUTPUT_BYTES = 48 * 1024
# tool -> (data op, allowed request keys, timeout seconds; term-llm allows at most 300)
TOOLS = {
    "data_status": ("status", set(), 60),
    "data_list": ("list", {"area", "path"}, 60),
    "data_peek": ("peek", {"area", "path", "mode", "offset", "bytes", "pattern", "regex", "ignore_case", "max_matches", "decompress"}, 60),
    "data_create": ("create", {"platform", "converter_branch"}, 290),
    "data_take": ("take", {"path", "type", "name"}, 290),
    "data_register": ("register", {"path", "type", "name"}, 290),
    "data_script": ("script", {"language", "code", "into", "timeout_minutes"}, 150),
    "data_extract": ("extract", {"path", "into", "timeout_minutes"}, 150),
    "data_job": ("job", {"job_id"}, 120),
    "data_db_up": ("db_up", {"engine"}, 200),
    "data_db_load": ("db_load", {"path", "charset", "stop_on_error", "timeout_minutes"}, 200),
    "data_db_status": ("db_status", set(), 90),
    "data_db_reset": ("db_reset", {"confirm"}, 200),
    "data_run_evidence": ("run_evidence", {"run_id"}, 60),
    "data_propose_finding": ("propose_finding", {"text", "run_id"}, 60),
    "data_plan_propose": ("plan_propose", {"source", "settings", "reconciliation", "charset", "from_run"}, 290),
    "data_notes": ("notes", set(), 60),
    "data_notes_write": ("notes_write", {"text"}, 60),
}
INSTALLED_AGENT = re.compile(r"(/.+)/releases/[0-9a-f]{40}/integrations/term-llm/[a-z][a-z-]*")


def control_path():
    override = os.environ.get("SILO_CONTROL")
    if override:
        return override
    agent_dir = os.path.realpath(os.environ.get("TERM_LLM_AGENT_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    installed = INSTALLED_AGENT.fullmatch(agent_dir)
    if installed:
        shim = os.path.join(installed[1], "bin", "silo-migrate-control")
        if os.path.isfile(shim):
            return shim
    return os.path.normpath(os.path.join(agent_dir, "..", "..", "..", "bin", "silo-migrate-control"))


def control_env():
    env = dict(os.environ)
    env.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin")
    return env


def fail(code):
    print(json.dumps({"version": 1, "error": code}))
    return 0


def chat_project():
    """The web UI project this chat belongs to, or None. term-llm runs a project chat's tools in
    the project's folder, ~/projects/<project> (silo intake creates it); the model can't change
    that. SILO_PROJECTS_ROOT applies only to the test suite (SILO_TESTING=1)."""
    root = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, "projects")
    if os.environ.get("SILO_TESTING") == "1" and os.environ.get("SILO_PROJECTS_ROOT"):
        root = os.environ["SILO_PROJECTS_ROOT"]
    try:
        cwd, root = os.path.realpath(os.getcwd()), os.path.realpath(root)
    except OSError:
        return None
    return cwd[len(root) + 1:].split(os.sep)[0] if cwd.startswith(root + os.sep) else None


def emit(result):
    if result.returncode != 0 or not result.stdout.strip():
        match = re.search(rb"Error: ([A-Z_]+)", result.stderr)
        return fail(match.group(1).decode() if match else "STANDARD_OPERATION_FAILED")
    if len(result.stdout) > MAX_OUTPUT_BYTES:
        return fail("STANDARD_OUTPUT_TOO_LARGE")
    try:
        json.loads(result.stdout.decode("utf-8"))
    except ValueError:
        return fail("STANDARD_OPERATION_FAILED")
    sys.stdout.buffer.write(result.stdout)
    return 0


def main():
    tool = os.environ.get("TERM_LLM_TOOL_NAME", "")
    if tool not in TOOLS:
        return fail("STANDARD_TOOL_UNKNOWN")
    try:
        args = json.load(sys.stdin)
    except ValueError:
        return fail("STANDARD_ARGUMENTS_INVALID")
    if not isinstance(args, dict) or not isinstance(args.get("workspace"), str) or not WORKSPACE.match(args["workspace"]):
        return fail("STANDARD_ARGUMENTS_INVALID")
    # One customer per chat: the chat's web UI project decides the workspace.
    project = chat_project()
    if project is None:
        return fail("STANDARD_CHAT_NOT_IN_PROJECT")
    if args["workspace"] != project:
        return fail("STANDARD_WORKSPACE_NOT_THIS_PROJECT")
    op, keys, timeout = TOOLS[tool]
    # "via": the host applies chat-only limits (a tool has 300 s); the agent can't set or drop it.
    request = {"op": op, **{key: value for key, value in args.items() if key in keys and value is not None}, "via": "chat"}
    try:
        result = subprocess.run([control_path(), "data", args["workspace"]], input=json.dumps(request).encode("utf-8"),
                                capture_output=True, timeout=timeout, env=control_env())
    except subprocess.TimeoutExpired:
        return fail("STANDARD_OPERATION_TIMEOUT")
    return emit(result)


if __name__ == "__main__":
    sys.exit(main())
