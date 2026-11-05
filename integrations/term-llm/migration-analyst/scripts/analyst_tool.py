#!/usr/bin/env -S python3 -I
"""Trusted analyst tools. Runs only in the separate Frontier-only analyst session."""
import json
import os
import re
import subprocess
import sys

WORKSPACE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\Z")
RUN = re.compile(r"run-[0-9a-f]{32}\Z")


def control_path():
    override = os.environ.get("SILO_CONTROL")
    if override:
        return override
    agent_dir = os.environ.get("TERM_LLM_AGENT_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.normpath(os.path.join(agent_dir, "..", "..", "..", "bin", "silo-migrate-control"))


def main():
    tool = os.environ.get("TERM_LLM_TOOL_NAME", "")
    args = json.load(sys.stdin)
    workspace, run_id = args.get("workspace"), args.get("run_id")
    if not (isinstance(workspace, str) and WORKSPACE.match(workspace) and isinstance(run_id, str) and RUN.match(run_id)):
        print(json.dumps({"version": 1, "error": "STANDARD_ARGUMENTS_INVALID"}))
        return 0
    if tool == "analyst_run_evidence":
        result = subprocess.run([control_path(), "standard", "analyst", "evidence", workspace, run_id], capture_output=True, text=True, timeout=55)
    elif tool == "analyst_propose_finding":
        text = args.get("text")
        if not isinstance(text, str) or not text.strip():
            print(json.dumps({"version": 1, "error": "STANDARD_ARGUMENTS_INVALID"}))
            return 0
        result = subprocess.run([control_path(), "standard", "finding", "propose", workspace, "--run", run_id, "--file", "-"], input=text, capture_output=True, text=True, timeout=55)
    else:
        print(json.dumps({"version": 1, "error": "STANDARD_TOOL_UNKNOWN"}))
        return 0
    print(result.stdout[:262144] if result.stdout.strip() else json.dumps({"version": 1, "error": (result.stderr.strip() or "STANDARD_OPERATION_FAILED")[:120]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
