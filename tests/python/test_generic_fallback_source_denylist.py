#!/usr/bin/env python3
"""Generic fallback must not truncate source-output shell commands.

With RALPH_COMPACT_GENERIC_FALLBACK enabled, cat/sed/git-diff/grep|head answers
must stay byte-identical. Unknown noise commands remain eligible for truncation.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

soc = load_ralph_script("shell-output-compact.py")

_REPO_ROOT = Path(__file__).resolve().parents[2]
_COMPACT_SCRIPT = _REPO_ROOT / "bundle" / ".ralph" / "python" / "shell-output-compact.py"
_MCP_SERVER = _REPO_ROOT / "bundle" / ".ralph" / "mcp-server.sh"


def _run_compact_cli(command: str, stdout: str, *, exit_status: int = 0) -> dict:
    env = os.environ.copy()
    env["RALPH_COMPACT_GENERIC_FALLBACK"] = "1"
    env["RALPH_COMPACT_GENERIC_THRESHOLD_BYTES"] = "1024"
    payload = {
        "command": command,
        "stdout": stdout,
        "stderr": "",
        "exit_status": exit_status,
    }
    proc = subprocess.run(
        [sys.executable, str(_COMPACT_SCRIPT), "compact"],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        cwd=str(_REPO_ROOT),
        check=False,
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"compact CLI failed (exit {proc.returncode}): {proc.stderr}"
        )
    return json.loads(proc.stdout)


def _large_noise_text() -> str:
    lines = [f"building artifact chunk-{index} ..." for index in range(200)]
    lines.append("SUMMARY: build finished")
    return "\n".join(lines)


class TestGenericFallbackSourceDenylist(unittest.TestCase):
    def test_gate_denies_source_binaries_and_prefixes(self) -> None:
        self.assertFalse(soc._command_allows_generic_shape_fallback("cat file.txt"))
        self.assertFalse(
            soc._command_allows_generic_shape_fallback("sudo sed -n 1,10p file.txt")
        )
        self.assertFalse(
            soc._command_allows_generic_shape_fallback("cd /tmp && cat file.txt")
        )
        self.assertFalse(
            soc._command_allows_generic_shape_fallback("time git diff HEAD~1")
        )
        self.assertFalse(
            soc._command_allows_generic_shape_fallback(
                "grep -rn proxy bundle/.ralph/bash-lib | head -200"
            )
        )

    def test_gate_keeps_unknown_commands_eligible(self) -> None:
        self.assertTrue(
            soc._command_allows_generic_shape_fallback("./scripts/custom-build.sh")
        )
        self.assertTrue(soc._command_allows_generic_shape_fallback("make -j8 all"))

    def test_cli_cat_is_byte_identical(self) -> None:
        content = _MCP_SERVER.read_text(encoding="utf-8")
        self.assertGreater(len(content.encode("utf-8")), 1024)
        result = _run_compact_cli("cat bundle/.ralph/mcp-server.sh", content)
        self.assertEqual(result["stdout"], content)
        self.assertFalse(result["compacted"])
        self.assertEqual(result["status"], "not compacted")

    def test_cli_sed_is_byte_identical(self) -> None:
        lines = _MCP_SERVER.read_text(encoding="utf-8").splitlines(keepends=True)
        content = "".join(lines[:400])
        self.assertGreater(len(content.encode("utf-8")), 1024)
        result = _run_compact_cli(
            "sed -n 1,400p bundle/.ralph/mcp-server.sh", content
        )
        self.assertEqual(result["stdout"], content)
        self.assertFalse(result["compacted"])

    def test_cli_git_diff_is_byte_identical(self) -> None:
        proc = subprocess.run(
            ["git", "diff", "HEAD~3"],
            capture_output=True,
            text=True,
            cwd=str(_REPO_ROOT),
            check=False,
        )
        content = proc.stdout
        if len(content.encode("utf-8")) <= 1024:
            content = content + ("\n+noise line for threshold\n" * 80)
        result = _run_compact_cli("git diff HEAD~3", content)
        self.assertEqual(result["stdout"], content)
        self.assertFalse(result["compacted"])

    def test_cli_grep_pipeline_is_byte_identical(self) -> None:
        proc = subprocess.run(
            [
                "bash",
                "-lc",
                "grep -rn proxy bundle/.ralph/bash-lib | head -200",
            ],
            capture_output=True,
            text=True,
            cwd=str(_REPO_ROOT),
            check=False,
        )
        content = proc.stdout
        if len(content.encode("utf-8")) <= 1024:
            content = content + ("\nbundle/.ralph/bash-lib/x.sh:1:proxy noise\n" * 80)
        result = _run_compact_cli(
            "grep -rn proxy bundle/.ralph/bash-lib | head -200", content
        )
        self.assertEqual(result["stdout"], content)
        self.assertFalse(result["compacted"])

    def test_cli_unknown_noise_command_still_compacts(self) -> None:
        content = _large_noise_text()
        self.assertGreater(len(content.encode("utf-8")), 1024)
        result = _run_compact_cli("./scripts/custom-build.sh", content)
        self.assertTrue(result["compacted"])
        self.assertEqual(result["family"], "generic_large")
        self.assertNotEqual(result["stdout"], content)


if __name__ == "__main__":
    unittest.main()
