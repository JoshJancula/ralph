#!/usr/bin/env python3
"""Run a command while holding an exclusive flock on lock_file."""
import fcntl
import os
import subprocess
import sys

lock_file = sys.argv[1]
cmd = sys.argv[2:]
lock_dir = os.path.dirname(lock_file)
if lock_dir:
    os.makedirs(lock_dir, exist_ok=True)
with open(lock_file, "a+", encoding="utf-8") as lock_fh:
    fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
    try:
        completed = subprocess.run(cmd, check=False)
        raise SystemExit(completed.returncode)
    finally:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
