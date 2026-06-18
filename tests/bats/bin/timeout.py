#!/usr/bin/env python3
"""Minimal timeout wrapper for Bats fixtures."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time


def parse_duration(raw: str) -> float:
    raw = raw.strip()
    if not raw:
        raise ValueError("empty timeout duration")
    units = {"s": 1, "m": 60, "h": 3600}
    if raw[-1] in units:
        return float(raw[:-1]) * units[raw[-1]]
    return float(raw)


def terminate_process(proc: subprocess.Popen[str]) -> None:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.time() + 1.0
    while time.time() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.05)
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        return


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: timeout DURATION COMMAND [ARG...]", file=sys.stderr)
        return 1

    duration = parse_duration(sys.argv[1])
    cmd = sys.argv[2:]
    proc = subprocess.Popen(cmd, preexec_fn=os.setsid)
    try:
        rc = proc.wait(timeout=duration)
    except subprocess.TimeoutExpired:
        terminate_process(proc)
        return 124
    return rc if rc is not None else 1


if __name__ == "__main__":
    raise SystemExit(main())
