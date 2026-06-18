#!/usr/bin/env python3
"""Unit tests for ralph-tool-access-breakdown.py warning emission."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BREAKDOWN = REPO_ROOT / "bundle" / ".ralph" / "python" / "ralph-tool-access-breakdown.py"
PYTHON_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"


class TestRalphToolAccessBreakdown(unittest.TestCase):
    def _run(self, payload: dict, env: dict | None = None) -> subprocess.CompletedProcess[str]:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(payload, fh)
            usage_path = fh.name
        self.addCleanup(lambda: os.path.exists(usage_path) and os.unlink(usage_path))

        run_env = os.environ.copy()
        if env:
            run_env.update(env)
        return subprocess.run(
            [sys.executable, str(BREAKDOWN), usage_path],
            capture_output=True,
            text=True,
            env=run_env,
            cwd=str(PYTHON_DIR),
            check=False,
        )

    def test_mixed_native_search_emits_warning(self) -> None:
        proc = self._run(
            {
                "tool_calls_by_tool": {
                    "ralph_proxy_read": 3,
                    "grepToolCall": 2,
                    "readToolCall": 1,
                }
            },
            {"RALPH_AGENT_TOOL_ACCESS": "ralph"},
        )
        self.assertEqual(proc.returncode, 0)
        self.assertIn(
            "WARNING: ralph mode active but agent used mixed native and proxy tools without compaction",
            proc.stdout,
        )

    def test_proxy_plus_native_read_only_emits_note(self) -> None:
        proc = self._run(
            {
                "tool_calls_by_tool": {
                    "ralph_proxy_read": 3,
                    "readToolCall": 1,
                }
            },
            {"RALPH_AGENT_TOOL_ACCESS": "ralph"},
        )
        self.assertEqual(proc.returncode, 0)
        self.assertIn("NOTE: ralph mode active; agent used native reads near edits", proc.stdout)
        self.assertNotIn("WARNING: ralph mode active but agent used mixed native and proxy tools", proc.stdout)

    def test_high_native_read_with_proxy_emits_warning(self) -> None:
        proc = self._run(
            {
                "tool_calls_by_tool": {
                    "ralph_proxy_read": 5,
                    "readToolCall": 8,
                    "editToolCall": 2,
                }
            },
            {"RALPH_AGENT_TOOL_ACCESS": "ralph"},
        )
        self.assertEqual(proc.returncode, 0)
        self.assertIn(
            "WARNING: ralph mode active but agent used mixed native and proxy tools without compaction",
            proc.stdout,
        )
        self.assertNotIn("NOTE: ralph mode active; agent used native reads near edits", proc.stdout)


if __name__ == "__main__":
    unittest.main()
