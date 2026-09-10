#!/usr/bin/env python3
"""Run a command in a pseudo-terminal and submit one confirmation line."""

from __future__ import annotations

import errno
import os
import pty
import sys


def main() -> int:
    if len(sys.argv) < 3:
        raise SystemExit("usage: pty-confirm.py <answer> <command> [args...]")
    answer = sys.argv[1]
    argv = sys.argv[2:]
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, os.environ.copy())

    os.write(fd, (answer + "\n").encode())
    while True:
        try:
            chunk = os.read(fd, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        os.write(sys.stdout.fileno(), chunk)
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    raise SystemExit(main())
