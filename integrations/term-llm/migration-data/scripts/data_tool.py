#!/usr/bin/env -S python3 -I
"""Fixed mapping from migration-data's term-llm tools to `silo-migrate-control data WS`.

Runs only in the Frontier-only migration-data agent: the one agent that handles customer
data. Every tool requires the native host's protected-session context (see
session_context); without it nothing reaches the backend.

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
    "data_plan_propose": ("plan_propose", {"source", "settings", "reconciliation", "charset", "from_run", "base_site", "fresh_site",
                                           "run_inputs", "preparation"}, 290),
    "data_master_lists_propose": ("master_lists_propose", {"source", "settings", "list", "charset", "run_inputs"}, 290),
    "data_merge_propose": ("merge_propose", {"source", "base_site", "settings", "ignore_global_pins", "separate_same_named_groups",
                                             "preparation"}, 290),
    "data_notes": ("notes", set(), 60),
    "data_notes_write": ("notes_write", {"text"}, 60),
    "data_decide": ("decide", {"topic", "decision", "basis"}, 60),
    "data_decisions": ("decisions", set(), 60),
    "data_supporting_list": ("supporting_list", set(), 60),
    "data_supporting_take": ("supporting_take", {"ref"}, 60),
    "data_supporting_read": ("supporting_read", {"id", "mode", "sheet", "offset", "limit", "columns"}, 90),
    "data_supporting_prepare": ("supporting_prepare", {"id", "sheet", "header_row", "max_rows", "columns", "format", "shape",
                                                       "name", "into", "delivery"}, 90),
}
# Native protected-session context, by need. Upload provenance (the admitted-upload
# manifest) goes only to listing/taking chat uploads; reading, listing registered
# references, preparing or citing an already-registered reference (including one the
# engineer admitted from intake) needs the protected session alone. No marker, a bad
# session ID or a malformed manifest fails closed before any backend call.
UPLOAD_CONTEXT_TOOLS = {"data_supporting_list", "data_supporting_take"}
SESSION_CONTEXT_TOOLS = {"data_supporting_read", "data_supporting_prepare"}
# Only when these arguments are present: otherwise the tool is unchanged.
SESSION_CONTEXT_ARGUMENTS = {"data_script": {"references"}, "data_plan_propose": {"preparation", "run_inputs"},
                             "data_merge_propose": {"preparation"}, "data_master_lists_propose": {"run_inputs"}}
SESSION = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
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
    # Native upload capabilities go only in the fixed supporting operation's
    # stdin, not the environment of unrelated control/Git/Docker subprocesses.
    for key in ("TERM_LLM_UPLOADS_JSON", "TERM_LLM_PRIVATE_SESSION", "TERM_LLM_SESSION_ID"):
        env.pop(key, None)
    env.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin")
    return env


def session_context():
    """The protected-session proof: TERM_LLM_PRIVATE_SESSION=1 and a valid session ID.

    Set by a separately approved native host (capabilities session_scope_lock=1 and
    custom_tool_session_context=1) only after durable scope admission, from its trusted
    context, stripping inherited and per-tool values first. Stock 0.9.99 never sets the marker, so every caller
    of this refuses there before any backend call. Never taken from model JSON."""
    session_id = os.environ.get("TERM_LLM_SESSION_ID", "")
    if os.environ.get("TERM_LLM_PRIVATE_SESSION") != "1" or not SESSION.fullmatch(session_id):
        return None
    return {"_private_session": True, "_session_id": session_id}


MALFORMED = object()


def upload_manifest():
    """Admitted chat uploads: None when the host supplied no manifest, MALFORMED when
    it supplied something unexpected (fail closed), else the bounded list."""
    raw = os.environ.get("TERM_LLM_UPLOADS_JSON")
    if raw is None:
        return None
    if not raw or len(raw.encode("utf-8")) > 64 * 1024:
        return MALFORMED
    try:
        uploads = json.loads(raw)
    except ValueError:
        return MALFORMED
    if not isinstance(uploads, list) or len(uploads) > 32:
        return MALFORMED
    return uploads


def supporting_context(need_uploads=False):
    """Session context, plus the upload manifest only where uploads are the subject.

    Reading, listing registered references, preparing and citing need the protected
    session, not upload provenance. A present-but-malformed manifest still refuses
    (unexpected host format). Taking an upload requires a valid manifest."""
    context = session_context()
    uploads = upload_manifest()
    if context is None or uploads is MALFORMED or (need_uploads and uploads is None):
        return None
    if need_uploads is not None:
        context["_uploads"] = uploads or []
    return context


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
    request = {"op": op, **{key: value for key, value in args.items() if key in keys and value is not None}, "via": "chat"}
    # Uniform gate: every tool of this customer-data agent needs the host's protected
    # session, checked here before any backend call. A host that cannot prove it
    # (stock term-llm, an unlocked/foreign chat) gets no customer data at all.
    # take needs the upload manifest; list shows it when present; nothing else receives it.
    context = supporting_context(need_uploads=True if tool == "data_supporting_take" else
                                 (False if tool == "data_supporting_list" else None))
    if context is None:
        return fail("STANDARD_SUPPORTING_NODE_UPDATE_REQUIRED")
    # The backend rechecks the context where references/preparation are involved.
    if tool in UPLOAD_CONTEXT_TOOLS or tool in SESSION_CONTEXT_TOOLS or SESSION_CONTEXT_ARGUMENTS.get(tool, set()) & set(request):
        request.update(context)
    try:
        result = subprocess.run([control_path(), "data", project], input=json.dumps(request).encode("utf-8"),
                                capture_output=True, timeout=timeout, env=control_env())
    except subprocess.TimeoutExpired:
        return fail("STANDARD_OPERATION_TIMEOUT")
    return emit(result)


if __name__ == "__main__":
    sys.exit(main())
