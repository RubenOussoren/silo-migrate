#!/usr/bin/env -S python3 -I
"""Fixed mapping from migration-data's term-llm tools to `silo-migrate-control data WS`.

Runs only in the Frontier-only migration-data agent: the one agent that handles customer
data. It works on stock, unmodified term-llm: no tool needs a native session marker,
and any TERM_LLM_PRIVATE_SESSION / TERM_LLM_SESSION_ID / TERM_LLM_UPLOADS_JSON in the
environment is ignored and stripped (stock hosts let anything that sets the
environment spoof them). Chat-attached uploads are not taken: supporting references
arrive through Files intake only (data_supporting_take always refuses with
STANDARD_SUPPORTING_USE_INTAKE, before any backend call).

Boundary: this wrapper fixes "via": "chat", derives the workspace from the chat's
project folder and forwards only each tool's listed keys, so model JSON cannot pick
a workspace, a route or the context. The control backend trusts this JSON from the
host (same service account). That is a host/process convention, not OS isolation:
anything able to run commands as that account (e.g. an agent with a host shell)
is outside this boundary. Every tool is one operation of bin/data_tools.py, which confines paths to the
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
    "data_guide": ("guide", set(), 60),
    "data_status": ("status", set(), 60),
    "data_list": ("list", {"area", "path"}, 60),
    "data_peek": ("peek", {"area", "path", "mode", "offset", "bytes", "pattern", "regex", "ignore_case", "max_matches", "decompress"}, 60),
    "data_create": ("create", {"platform", "converter_branch"}, 290),
    "data_take": ("take", {"path", "type", "name"}, 290),
    "data_register": ("register", {"path", "type", "name"}, 290),
    "data_script": ("script", {"language", "code", "into", "timeout_minutes", "delivery", "references"}, 150),
    "data_extract": ("extract", {"path", "into", "timeout_minutes"}, 150),
    "data_job": ("job", {"job_id"}, 120),
    "data_db_up": ("db_up", {"engine"}, 200),
    "data_db_load": ("db_load", {"path", "charset", "stop_on_error", "timeout_minutes"}, 200),
    "data_db_status": ("db_status", set(), 90),
    "data_db_reset": ("db_reset", {"confirm"}, 200),
    "data_run_evidence": ("run_evidence", {"run_id"}, 60),
    "data_run_count": ("run_count", {"run_id", "side", "sql"}, 290),
    "data_propose_finding": ("propose_finding", {"text", "run_id"}, 60),
    "data_finding_proposal": ("finding_proposal", {"finding_id", "offset"}, 60),
    "data_revise_finding": ("revise_finding", {"finding_id", "text", "expected_proposal_sha256"}, 60),
    "data_plan_propose": ("plan_propose", {"source", "settings", "reconciliation", "charset", "from_run", "base_site", "fresh_site",
                                           "run_inputs", "preparation"}, 290),
    "data_master_lists_propose": ("master_lists_propose", {"source", "settings", "list", "charset", "run_inputs"}, 290),
    "data_merge_prepare": ("merge_prepare", {"source", "base_site"}, 290),
    "data_merge_inspection": ("merge_inspection", {"run_id", "generation", "side"}, 90),
    "data_merge_propose": ("merge_propose", {"source", "base_site", "settings", "ignore_global_pins", "separate_same_named_groups",
                                             "preparation", "prepared_from", "generation", "intent"}, 290),
    "data_notes": ("notes", set(), 60),
    "data_notes_write": ("notes_write", {"text"}, 60),
    "data_decide": ("decide", {"topic", "decision", "basis"}, 60),
    "data_decisions": ("decisions", set(), 60),
    "data_supporting_list": ("supporting_list", set(), 60),
    "data_supporting_read": ("supporting_read", {"id", "mode", "sheet", "offset", "limit", "columns"}, 90),
    "data_supporting_prepare": ("supporting_prepare", {"id", "sheet", "header_row", "max_rows", "columns", "format", "shape",
                                                       "name", "into", "delivery"}, 90),
}
# Taking a chat upload needs host-proved upload provenance that stock term-llm cannot give.
# Kept as a fixed refusal (not a backend call) so an old prompt or a spoofed environment
# cannot copy arbitrary host files into the registry.
USE_INTAKE_TOOLS = {"data_supporting_take"}
# Legacy fork context variables: never trusted, never forwarded (stock env is spoofable).
LEGACY_CONTEXT_ENV = ("TERM_LLM_UPLOADS_JSON", "TERM_LLM_PRIVATE_SESSION", "TERM_LLM_SESSION_ID")
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
    # Legacy context variables never reach control/Git/Docker subprocesses.
    for key in LEGACY_CONTEXT_ENV:
        env.pop(key, None)
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
        # The code and the short detail the host adds: this agent is on the customer-data side.
        match = re.search(rb"(?m)^Error: ((?:STANDARD|NAMED)_[A-Z_]+(?:: [^\n]{1,200})?)", result.stderr)
        return fail(match.group(1).decode("utf-8", "replace") if match else "STANDARD_OPERATION_FAILED")
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
    if tool in USE_INTAKE_TOOLS:
        return fail("STANDARD_SUPPORTING_USE_INTAKE")
    if tool not in TOOLS:
        return fail("STANDARD_TOOL_UNKNOWN")
    try:
        args = json.load(sys.stdin)
    except ValueError:
        return fail("STANDARD_ARGUMENTS_INVALID")
    if not isinstance(args, dict):
        return fail("STANDARD_ARGUMENTS_INVALID")
    # One customer per chat: the chat's web UI project decides the workspace, and the model has no say.
    project = chat_project()
    if project is None or not WORKSPACE.match(project):
        return fail("STANDARD_CHAT_NOT_IN_PROJECT")
    op, keys, timeout = TOOLS[tool]
    # "via": the host applies chat-only limits (a tool has 300 s); the agent can't set or drop it.
    # Only listed keys pass: model JSON can't add context keys (_private_session, _session_id,
    # _uploads), a workspace or a route.
    request = {"op": op, **{key: value for key, value in args.items() if key in keys and value is not None}, "via": "chat"}
    try:
        result = subprocess.run([control_path(), "data", project], input=json.dumps(request).encode("utf-8"),
                                capture_output=True, timeout=timeout, env=control_env())
    except subprocess.TimeoutExpired:
        return fail("STANDARD_OPERATION_TIMEOUT")
    return emit(result)


if __name__ == "__main__":
    sys.exit(main())
