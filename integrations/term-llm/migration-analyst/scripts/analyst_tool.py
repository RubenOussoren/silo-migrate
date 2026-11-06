#!/usr/bin/env -S python3 -I
"""Trusted analyst tools. Runs only in the separate Frontier-only analyst session."""
import json
import os
import re
import subprocess
import sys

WORKSPACE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\Z")
RUN = re.compile(r"run-[0-9a-f]{32}\Z")
# term-llm 0.9.93 cuts custom tool output at 50 KiB (DefaultOutputLimits.MaxBytes) without
# regard for JSON. `standard analyst evidence` budgets its document at 40 KiB; anything
# larger is refused here rather than handed to the model as truncated JSON.
MAX_OUTPUT_BYTES = 48 * 1024


# script/metal installs agents as <prefix>/releases/<commit>/integrations/term-llm/<agent>,
# reached through ~/.config/term-llm/agents links. The stock service does not pass
# extra environment to tools, so locate the prefix's configured control shim here.
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
    # Tool processes may get a minimal environment; the shim needs python3/docker on PATH.
    env = dict(os.environ)
    env.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin")
    return env


def fail(code):
    print(json.dumps({"version": 1, "error": code}))
    return 0


def emit(result):
    if result.returncode != 0 or not result.stdout.strip():
        match = re.search(r"Error: ([A-Z_]+)", result.stderr)
        return fail(match.group(1) if match else "STANDARD_OPERATION_FAILED")
    if len(result.stdout.encode("utf-8")) > MAX_OUTPUT_BYTES:
        return fail("STANDARD_EVIDENCE_TOO_LARGE")
    try:
        json.loads(result.stdout)
    except ValueError:
        return fail("STANDARD_OPERATION_FAILED")
    sys.stdout.write(result.stdout)
    return 0


def main():
    tool = os.environ.get("TERM_LLM_TOOL_NAME", "")
    try:
        args = json.load(sys.stdin)
    except ValueError:
        return fail("STANDARD_ARGUMENTS_INVALID")
    if not isinstance(args, dict):
        return fail("STANDARD_ARGUMENTS_INVALID")
    workspace, run_id = args.get("workspace"), args.get("run_id")
    if not (isinstance(workspace, str) and WORKSPACE.match(workspace) and isinstance(run_id, str) and RUN.match(run_id)):
        return fail("STANDARD_ARGUMENTS_INVALID")
    try:
        if tool == "analyst_run_evidence":
            result = subprocess.run([control_path(), "standard", "analyst", "evidence", workspace, run_id], capture_output=True, text=True, timeout=55, env=control_env())
        elif tool == "analyst_propose_finding":
            text = args.get("text")
            if not isinstance(text, str) or not text.strip():
                return fail("STANDARD_ARGUMENTS_INVALID")
            result = subprocess.run([control_path(), "standard", "finding", "propose", workspace, "--run", run_id, "--file", "-"], input=text, capture_output=True, text=True, timeout=55, env=control_env())
        else:
            return fail("STANDARD_TOOL_UNKNOWN")
    except subprocess.TimeoutExpired:
        return fail("STANDARD_OPERATION_TIMEOUT")
    return emit(result)


if __name__ == "__main__":
    sys.exit(main())
