#!/usr/bin/env -S python3 -I
"""Fixed mapping from term-llm custom tools to `silo-migrate-control converter dev`.

The adapter serves converter-developer; the role comes from
the agent directory this copy lives in, and converter_dev enforces it again. There
is no mapping to the engineer's push approval, to clone/update, or to any path
outside the workspace's converter checkout. Arguments never reach a shell.
"""
import json
import os
import pwd
import re
import subprocess
import sys

WORKSPACE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\Z")
FINDING = re.compile(r"finding-[0-9a-f]{32}\Z")
# term-llm 0.9.93 cuts custom tool output at 50 KiB; refuse rather than pass on cut JSON.
MAX_OUTPUT_BYTES = 48 * 1024
# tool -> (converter dev op, allowed request keys)
TOOLS = {
    "dev_list": ("list", {"path"}),
    "dev_read": ("read", {"path", "start_line"}),
    "dev_search": ("search", {"pattern", "path", "fixed", "ignore_case"}),
    "dev_status": ("status", set()),
    "dev_diff": ("diff", {"scope", "path"}),
    "dev_test": ("test", {"suite", "file"}),
    "dev_push_show": ("push-show", set()),
    "dev_write": ("write", {"path", "content"}),
    "dev_edit": ("edit", {"path", "old_text", "new_text", "replace_all"}),
    "dev_delete": ("delete", {"path"}),
    "dev_branch": ("branch", {"topic", "new_pr"}),
    "dev_format": ("format", {"path"}),
    "dev_commit": ("commit", {"message"}),
    "dev_push_propose": ("push-propose", {"title", "body", "base", "findings"}),
    "dev_branch_resolve": ("branch-resolve", {"link"}),
    "dev_branches": ("branches", {"fetch"}),
    "dev_branch_diff": ("branch-diff", {"branch", "base", "path"}),
    "dev_branch_read": ("branch-read", {"branch", "path", "start_line"}),
}
READ_ONLY = {"dev_list", "dev_read", "dev_search", "dev_status", "dev_diff", "dev_test", "dev_push_show", "dev_findings", "dev_finding_show"}
INSTALLED_AGENT = re.compile(r"(/.+)/releases/[0-9a-f]{40}/integrations/term-llm/[a-z][a-z-]*")


def agent_dir():
    return os.path.realpath(os.environ.get("TERM_LLM_AGENT_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def role():
    name = os.path.basename(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
    return {"converter-developer": "developer", "converter-reviewer": "reviewer"}.get(name, "reviewer")


def control_path():
    override = os.environ.get("SILO_CONTROL")
    if override:
        return override
    installed = INSTALLED_AGENT.fullmatch(agent_dir())
    if installed:
        shim = os.path.join(installed[1], "bin", "silo-migrate-control")
        if os.path.isfile(shim):
            return shim
    return os.path.normpath(os.path.join(agent_dir(), "..", "..", "..", "bin", "silo-migrate-control"))


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


def emit(result, detail=False):
    # Bytes throughout: the size check and the output don't depend on the locale.
    if result.returncode != 0 or not result.stdout.strip():
        # Only converter_dev's own refusals keep their detail (branch names, a build step): this
        # agent is on the code side, so nothing from another path may add text here.
        match = re.search(rb"(?m)^Error: ((?:STANDARD|NAMED)_[A-Z_]+(?:: [^\n]{1,200})?)" if detail else rb"Error: ([A-Z_]+)", result.stderr)
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
    if tool not in TOOLS and tool not in ("dev_findings", "dev_finding_show"):
        return fail("STANDARD_TOOL_UNKNOWN")
    if role() != "developer" and tool not in READ_ONLY:
        return fail("STANDARD_DEV_OPERATION_REFUSED")
    try:
        args = json.load(sys.stdin)
    except ValueError:
        return fail("STANDARD_ARGUMENTS_INVALID")
    if not isinstance(args, dict):
        return fail("STANDARD_ARGUMENTS_INVALID")
    # The chat's web UI project decides the workspace. A spawned reviewer runs in its parent's
    # project; the model can't name another one.
    workspace = chat_project()
    if workspace is None or not WORKSPACE.match(workspace):
        return fail("STANDARD_CHAT_NOT_IN_PROJECT")
    timeout = 290 if tool in ("dev_test", "dev_format") else 85 if tool in ("dev_branches", "dev_branch_resolve") else 55
    try:
        if tool == "dev_findings":
            result = subprocess.run([control_path(), "standard", "agent", "findings", workspace], capture_output=True, timeout=timeout, env=control_env())
        elif tool == "dev_finding_show":
            finding = args.get("finding_id")
            if not isinstance(finding, str) or not FINDING.match(finding):
                return fail("STANDARD_ARGUMENTS_INVALID")
            result = subprocess.run([control_path(), "standard", "agent", "finding-show", workspace, finding], capture_output=True, timeout=timeout, env=control_env())
        else:
            op, keys = TOOLS[tool]
            request = {"op": op, **{key: value for key, value in args.items() if key in keys and value is not None}}
            result = subprocess.run([control_path(), "converter", "dev", workspace, "--role", role()], input=json.dumps(request).encode("utf-8"),
                                    capture_output=True, timeout=timeout, env=control_env())
    except subprocess.TimeoutExpired:
        return fail("STANDARD_OPERATION_TIMEOUT")
    return emit(result, detail=tool in TOOLS)


if __name__ == "__main__":
    sys.exit(main())
