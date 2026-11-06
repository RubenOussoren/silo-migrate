#!/usr/bin/env -S python3 -I
"""Fixed mapping from term-llm custom tools to `silo-migrate standard agent`.

Arguments are validated here and never reach a shell. There is deliberately no
mapping to approve, reset, release or private-path commands.
"""
import json
import os
import re
import subprocess
import sys
import time

WORKSPACE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\Z")
PATTERNS = {
    "dataset_id": re.compile(r"dataset-[0-9a-f]{32}\Z"),
    "plan_id": re.compile(r"plan-[0-9a-f]{32}\Z"),
    "run_id": re.compile(r"run-[0-9a-f]{32}\Z"),
    "finding_id": re.compile(r"finding-[0-9a-f]{32}\Z"),
    "baseline": re.compile(r"(seed|baseline-[0-9a-f]{16})\Z"),
}
MAX_OUTPUT = 256 * 1024


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


def argument(args, name, required=True):
    value = args.get(name)
    if value is None and not required:
        return None
    pattern = WORKSPACE if name == "workspace" else PATTERNS[name]
    if not isinstance(value, str) or not pattern.match(value):
        raise ValueError(name)
    return value


def run(argv, detach=False):
    command = [control_path()] + (["--detach"] if detach else []) + ["standard", "agent"] + argv
    return subprocess.run(command, capture_output=True, text=True, timeout=55, env=control_env())


def emit(result):
    if result.returncode == 0 or result.stdout.strip():
        print(result.stdout[:MAX_OUTPUT])
        return 0
    match = re.search(r"Error: ([A-Z_]+)", result.stderr)
    return fail(match.group(1) if match else "STANDARD_OPERATION_FAILED")


def main():
    tool = os.environ.get("TERM_LLM_TOOL_NAME", "")
    try:
        args = json.load(sys.stdin)
        workspace = argument(args, "workspace")
        if tool == "migration_status":
            return emit(run(["status", workspace]))
        if tool == "migration_plan_propose":
            argv = ["plan-propose", workspace, "--dataset", argument(args, "dataset_id")]
            baseline = argument(args, "baseline", required=False)
            if baseline:
                argv += ["--baseline", baseline]
            return emit(run(argv))
        if tool == "migration_plan_show":
            return emit(run(["plan-show", workspace, argument(args, "plan_id")]))
        if tool == "migration_run_request":
            plan_id = argument(args, "plan_id")
            shown = run(["plan-show", workspace, plan_id])
            if shown.returncode != 0:
                return emit(shown)
            status = json.loads(shown.stdout).get("status")
            if status != "approved":
                return fail("STANDARD_NOT_APPROVED" if status == "proposed" else "STANDARD_PLAN_NOT_RUNNABLE")
            # Claim in the foreground so a refusal is reported truthfully; nothing has
            # changed at that point. Then execute in the background.
            claimed = run(["run-claim", workspace, plan_id])
            if claimed.returncode != 0:
                return emit(claimed)
            run_id = json.loads(claimed.stdout).get("run_id")
            if not isinstance(run_id, str) or not PATTERNS["run_id"].match(run_id):
                return fail("STANDARD_OPERATION_FAILED")
            started = run(["run-execute", workspace, run_id], detach=True)
            if started.returncode != 0:
                return fail("STANDARD_RUN_NOT_STARTED")
            # "started" would overstate it until the executor has actually picked it up.
            deadline = time.monotonic() + float(os.environ.get("SILO_TOOL_START_WAIT", "15"))
            status = "claimed"
            while status == "claimed" and time.monotonic() < deadline:
                time.sleep(float(os.environ.get("SILO_TOOL_START_POLL", "2")))
                shown = run(["run-show", workspace, run_id])
                if shown.returncode == 0:
                    status = json.loads(shown.stdout).get("status", status)
            print(json.dumps({"version": 1, "plan_id": plan_id, "run_id": run_id, "status": status}))
            return 0
        if tool == "migration_run_show":
            return emit(run(["run-show", workspace, argument(args, "run_id")]))
        if tool == "migration_findings":
            return emit(run(["findings", workspace]))
        if tool == "migration_finding_show":
            return emit(run(["finding-show", workspace, argument(args, "finding_id")]))
        return fail("STANDARD_TOOL_UNKNOWN")
    except (ValueError, KeyError, TypeError, json.JSONDecodeError):
        return fail("STANDARD_ARGUMENTS_INVALID")
    except subprocess.TimeoutExpired:
        return fail("STANDARD_OPERATION_TIMEOUT")


if __name__ == "__main__":
    sys.exit(main())
