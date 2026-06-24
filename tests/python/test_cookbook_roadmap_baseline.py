#!/usr/bin/env python3
"""Offline regression checks for cookbook-roadmap baseline fixtures."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "cookbook-roadmap"
SEARCH_FIXTURE = REPO_ROOT / "tests" / "fixtures" / "mcp-proxy" / "search-ranking"

sys.path.insert(0, str(REPO_ROOT / "tests" / "python"))
sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))

from ralph_script_loader import load_ralph_script  # noqa: E402
from tool_call_classification import classify_tool_calls  # noqa: E402
from tool_call_target_telemetry import optimization_hint_line  # noqa: E402


def _load_fixture(name: str) -> dict:
    return json.loads((FIXTURE_DIR / name).read_text(encoding="utf-8"))


class TestCookbookRoadmapBaseline(unittest.TestCase):
    def test_prompt_byte_order_fixture_is_well_formed(self) -> None:
        data = _load_fixture("prompt-byte-order-baseline.json")
        self.assertEqual(data["kind"], "prompt_byte_order_baseline")
        for runtime in ("claude", "opencode", "cursor", "codex", "antigravity"):
            self.assertIn(runtime, data["runtimes"])

    def test_bm25_rankings_match_baseline(self) -> None:
        baseline = _load_fixture("bm25-rankings-baseline.json")
        rank_script = REPO_ROOT / "bundle" / ".ralph" / "python" / "mcp-proxy-search-rank.py"
        fixture_root = baseline["fixture_root"]
        for query, expected in baseline["queries"].items():
            proc = subprocess.run(
                ["rg", "-n", "--no-heading", "-S", query, str(REPO_ROOT / fixture_root)],
                capture_output=True,
                text=True,
                check=False,
            )
            rank_proc = subprocess.run(
                [sys.executable, str(rank_script), "--query", query, "--max-results", "10"],
                input=proc.stdout,
                capture_output=True,
                text=True,
                check=True,
            )
            ranked = []
            prefix = f"{fixture_root}/"
            abs_prefix = str((REPO_ROOT / fixture_root).resolve()) + "/"
            for line in rank_proc.stdout.splitlines():
                if not line.strip():
                    continue
                parts = line.split(":", 2)
                if len(parts) < 2:
                    continue
                path = parts[0]
                if path.startswith(abs_prefix):
                    path = path[len(abs_prefix) :]
                elif path.startswith(prefix):
                    path = path[len(prefix) :]
                ranked.append(f"{path}:{parts[1]}")
            self.assertEqual(ranked, expected["ranked_paths"], query)

    def test_tool_call_telemetry_matches_baseline(self) -> None:
        baseline = _load_fixture("tool-call-telemetry-baseline.json")
        by_tool = baseline["tool_calls_by_tool"]
        classification = classify_tool_calls(by_tool)
        hint = optimization_hint_line(
            {"tool_calls_sequence": baseline["sample_sequence"]}
        )
        self.assertEqual(classification, baseline["classification"])
        self.assertEqual(hint, baseline["optimization_hint"])

    def test_mcp_tools_list_baseline_metadata(self) -> None:
        baseline = _load_fixture("mcp-tools-list-baseline.json")
        self.assertEqual(baseline["tool_count"], len(baseline["tool_names"]))
        self.assertGreater(baseline["serialized_bytes"], 0)
        self.assertEqual(baseline["conditions"]["ralph_mode"], "hybrid")


if __name__ == "__main__":
    unittest.main()
