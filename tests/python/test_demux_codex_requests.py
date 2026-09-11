"""Regression tests for Codex request counting in the JSON demux."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

# Pytest invoked from the repository root does not add this directory to
# sys.path; keep the focused test runnable with the TODO's exact command.
sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

DEMUX = load_ralph_script("run-plan-cli-json-demux")
FIXTURE = (
    Path(__file__).resolve().parents[1]
    / "fixtures"
    / "run-plan-cli-json-demux"
    / "codex-three-requests.jsonl"
)


def run_demux(lines: list[str]) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        usage_path = Path(tmp) / "usage.json"
        sid_path = Path(tmp) / "sid.txt"
        old = (sys.stdin, sys.stdout, sys.stderr, sys.argv)
        sys.stdin = io.StringIO("\n".join(lines) + "\n")
        sys.stdout = io.StringIO()
        sys.stderr = io.StringIO()
        sys.argv = ["demux", "codex", str(sid_path), str(usage_path)]
        try:
            DEMUX.main()
        finally:
            sys.stdin, sys.stdout, sys.stderr, sys.argv = old
        return json.loads(usage_path.read_text())


class CodexRequestCountTest(unittest.TestCase):
    def test_token_count_events_are_requests_not_turns(self) -> None:
        usage = run_demux(FIXTURE.read_text().splitlines())
        self.assertEqual(usage["tool_turns"], 3)
        self.assertEqual(usage["tool_calls_total"], 2)

    def test_item_fallback_counts_requests_without_token_count(self) -> None:
        lines = [
            json.dumps({"type": "item.completed", "item": {"type": "agent_message"}}),
            json.dumps({"type": "turn.completed", "usage": {"input_tokens": 1}}),
        ]
        self.assertEqual(run_demux(lines)["tool_turns"], 1)

    def test_counts_function_output_bytes_by_tool(self) -> None:
        lines = [
            json.dumps({"type": "item.completed", "item": {
                "id": "call-1", "type": "function_call", "name": "Read"
            }}),
            json.dumps({"type": "item.completed", "item": {
                "type": "function_call_output", "call_id": "call-1", "output": "hello"
            }}),
        ]
        usage = run_demux(lines)
        self.assertEqual(usage["tool_result_bytes_by_tool"], {"Read": 5})
        self.assertEqual(usage["tool_result_bytes_total"], 5)


if __name__ == "__main__":
    unittest.main()
