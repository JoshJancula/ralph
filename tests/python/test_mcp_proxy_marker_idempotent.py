#!/usr/bin/env python3
"""Idempotency of mcp-proxy text shaping (single truncation marker)."""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
POLICY_LIB = REPO_ROOT / "bundle" / ".ralph" / "bash-lib" / "mcp-proxy" / "mcp-proxy-policy.sh"
RESULT_LIB = REPO_ROOT / "bundle" / ".ralph" / "bash-lib" / "mcp-proxy" / "mcp-proxy-result.sh"
TOOLS_LIB = REPO_ROOT / "bundle" / ".ralph" / "bash-lib" / "mcp-proxy" / "mcp-proxy-tools.sh"
MARKER = "...[truncated]"


def shape_text_twice(text: str, byte_cap: int) -> str:
    """Pipe text through ralph_mcp_proxy_shape_one_text twice via bash."""
    script = r"""
set -euo pipefail
source "$1"
source "$2"
source "$3"
text=$(cat)
byte_cap="$4"
once="$(ralph_mcp_proxy_shape_one_text "$text" "$byte_cap" 0 "" "" "ralph_proxy_read" "tools/call" 0)"
twice="$(ralph_mcp_proxy_shape_one_text "$once" "$byte_cap" 0 "" "" "ralph_proxy_read" "tools/call" 0)"
printf '%s' "$twice"
"""
    proc = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "_",
            str(POLICY_LIB),
            str(RESULT_LIB),
            str(TOOLS_LIB),
            str(byte_cap),
        ],
        input=text,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"shape_one_text failed (rc={proc.returncode}):\n"
            f"stderr={proc.stderr!r}\nstdout={proc.stdout!r}"
        )
    return proc.stdout


class MarkerIdempotentTests(unittest.TestCase):
    def test_double_shape_yields_exactly_one_marker(self) -> None:
        body = "".join(f"line-{i:04d}\n" for i in range(500))
        byte_cap = 200
        self.assertGreater(len(body), byte_cap)

        shaped = shape_text_twice(body, byte_cap)
        self.assertEqual(
            shaped.count(MARKER),
            1,
            f"expected one {MARKER!r}, got {shaped.count(MARKER)} in {shaped!r}",
        )
        self.assertTrue(
            shaped.rstrip("\n").endswith(MARKER),
            f"shaped text should end with marker: {shaped[-80:]!r}",
        )


if __name__ == "__main__":
    unittest.main()
