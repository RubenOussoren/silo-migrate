#!/usr/bin/env -S python3 -I
"""Stable cross-engine image identity. Invoke with python3 -I."""
import argparse
import hashlib
import json
import subprocess


def content_id(inspect):
    if isinstance(inspect, list):
        if len(inspect) != 1:
            raise ValueError("expected exactly one image")
        inspect = inspect[0]
    config = inspect.get("Config") or {}
    obj = {"architecture": inspect["Architecture"], "os": inspect["Os"],
           "diff_ids": (inspect.get("RootFS") or {}).get("Layers") or [],
           "config": {k: config.get(k) or ([] if k in ("Cmd", "Entrypoint", "Env") else "")
                      for k in ("Cmd", "Entrypoint", "Env", "User", "WorkingDir")}}
    return "sha256:" + hashlib.sha256(json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ref", nargs="?")
    parser.add_argument("--inspect-json")
    args = parser.parse_args()
    if args.inspect_json:
        with open(args.inspect_json, encoding="utf-8") as stream:
            inspect = json.load(stream)
    elif args.ref:
        inspect = json.loads(subprocess.check_output(["docker", "image", "inspect", args.ref], stderr=subprocess.DEVNULL))
    else:
        parser.error("REF or --inspect-json required")
    print(content_id(inspect))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, AttributeError, KeyError, subprocess.SubprocessError):
        raise SystemExit("IMAGE_IDENTITY_FAILED: inspect one valid image; raw Docker output suppressed")
