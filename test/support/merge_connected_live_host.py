#!/usr/bin/env python3
"""Run the unchanged installed launcher, refusing runtime-preparation job spawn.

The live fixture permits cached runtime use, never implicit preparation/downloads.
This guard supplies NO ready result and does not intercept service lifecycle calls.
A missing launcher cache remains a real fixed-code refusal, not fixture success.
"""
from pathlib import Path
import runpy
import sys


def refuse_runtime_worker(event, args):
    if event != 'subprocess.Popen':
        return
    argv = args[1]
    if isinstance(argv, (tuple, list)) and any(
            isinstance(v, str) and Path(v).name == 'review_runtime_job.py' for v in argv):
        raise PermissionError('connected fixture refuses runtime preparation; cached-only admission required')


if __name__ == '__main__':
    launcher = sys.argv.pop(1)
    sys.argv[0] = launcher
    sys.addaudithook(refuse_runtime_worker)
    runpy.run_path(launcher, run_name='__main__')
