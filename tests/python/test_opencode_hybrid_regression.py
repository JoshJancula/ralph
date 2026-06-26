#!/usr/bin/env python3
"""PLAN54-style regression for OpenCode hybrid native exploration compaction.

Models a hybrid invocation with many native reads/greps/globs, repeated read
targets, and a mix of Ralph proxy tools. Asserts MCP-proxy compaction (the
authoritative path per opencode-hook-revalidation) windowed native output and
records result_windowing telemetry instead of retaining multi-megabyte payloads.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any

from ralph_script_loader import load_ralph_script

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "opencode-hybrid-regression"
FIXTURE_PATH = FIXTURE_DIR / "plan54-tool-stream.jsonl"
CLI = REPO_ROOT / "bundle" / ".ralph" / "bash-lib" / "native-hook" / "native-result-compact-cli.sh"
DEMUX = load_ralph_script("run-plan-cli-json-demux")
OVERLAY = load_ralph_script("ralph_overlay_usage_fields")

# Scaled PLAN54 OpenCode tool-mix ratios from opencode-hybrid-baseline.md.
PLAN54_READ_CALLS = 20
PLAN54_REPEATED_READ_TARGET = "src/core/handler.py"
PLAN54_REPEATED_READ_COUNT = 8
PLAN54_GREP_CALLS = 10
PLAN54_GLOB_CALLS = 4
PLAN54_BASH_CALLS = 5
PLAN54_RALPH_PROXY_READ_CALLS = 3
PLAN54_RALPH_PROXY_GREP_CALLS = 2


def _tool_part_event(
    *,
    part_id: str,
    call_id: str,
    tool: str,
    tool_input: dict[str, Any] | None = None,
) -> dict[str, Any]:
    state: dict[str, Any] = {"status": "completed"}
    if tool_input:
        state["input"] = tool_input
    return {
        "type": "message.part.updated",
        "properties": {
            "part": {
                "id": part_id,
                "type": "tool",
                "callID": call_id,
                "tool": tool,
                "state": state,
            }
        },
    }


def build_plan54_tool_stream() -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    seq = 0

    def add(tool: str, tool_input: dict[str, Any] | None = None) -> None:
        nonlocal seq
        seq += 1
        events.append(
            _tool_part_event(
                part_id=f"part_{tool}_{seq}",
                call_id=f"call_{tool}_{seq}",
                tool=tool,
                tool_input=tool_input,
            )
        )

    for i in range(PLAN54_REPEATED_READ_COUNT):
        add("read", {"path": PLAN54_REPEATED_READ_TARGET})
    for i in range(PLAN54_READ_CALLS - PLAN54_REPEATED_READ_COUNT):
        add("read", {"path": f"src/module/file{i + 1}.ts"})
    for i in range(PLAN54_GREP_CALLS):
        add("grep", {"pattern": f"handler-{i % 3}"})
    for i in range(PLAN54_GLOB_CALLS):
        add("glob", {"glob_pattern": f"**/*module{i}.ts"})
    for i in range(PLAN54_BASH_CALLS):
        add("bash", {"command": f"npm test -- --filter test-{i}"})
    for i in range(PLAN54_RALPH_PROXY_READ_CALLS):
        add("ralph_proxy_read", {"path": f"bundle/.ralph/lib{i}.sh"})
    for i in range(PLAN54_RALPH_PROXY_GREP_CALLS):
        add("ralph_proxy_grep", {"pattern": f"ralph_proxy_{i}"})
    add("edit", {"path": "src/core/handler.py"})

    events.append(
        {
            "type": "step_finish",
            "part": {
                "tokens": {"input": 120000, "output": 900, "cache": {"read": 1260150, "write": 0}},
            },
        }
    )
    return events


def write_plan54_fixture(path: Path = FIXTURE_PATH) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        for event in build_plan54_tool_stream():
            fh.write(json.dumps(event, separators=(",", ":")) + "\n")
    return path


def large_read_payload() -> str:
    return "\n".join(f"line {i}: payload from repeated native read" for i in range(1200))


@unittest.skipUnless(shutil.which("bash"), "bash required")
@unittest.skipUnless(shutil.which("jq"), "jq required")
class OpencodeHybridRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        write_plan54_fixture()

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self.tmp.name)
        self.state_root = self.workspace / ".ralph-workspace"
        self.runtime_state = self.state_root / "runtime-config" / "plan54-hybrid-regression"
        self.runtime_state.mkdir(parents=True, exist_ok=True)
        self.window_log = self.runtime_state / "result-windowing.jsonl"
        bash_lib = REPO_ROOT / "bundle" / ".ralph" / "bash-lib"
        (self.workspace / ".ralph").mkdir(parents=True, exist_ok=True)
        (self.workspace / ".ralph" / "bash-lib").symlink_to(bash_lib, target_is_directory=True)
        self.env = os.environ.copy()
        self.env.update(
            {
                "RALPH_NATIVE_RESULT_COMPACT": "1",
                "RALPH_PROXY_SHELL_COMPACT": "1",
                "RALPH_NATIVE_RESULT_PREVIEW_MAX_BYTES": "500",
                "RALPH_MCP_WORKSPACE": str(self.workspace),
                "RALPH_PLAN_KEY": "plan54-hybrid-regression",
                "RALPH_PLAN_WORKSPACE_ROOT": str(self.state_root),
                "RALPH_RESULT_WINDOWING_LOG": str(self.window_log),
                "WORKSPACE": str(self.workspace),
            }
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _invoke_cli(self, tool_name: str, text: str, **extra: Any) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "tool_name": tool_name,
            "text": text,
            "workspace": str(self.workspace),
            "plan_key": "plan54-hybrid-regression",
        }
        payload.update(extra)
        proc = subprocess.run(
            ["bash", str(CLI)],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            env=self.env,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = [line for line in proc.stdout.splitlines() if line.strip()]
        if not lines:
            return {}
        return json.loads(lines[-1])

    def _demux_fixture(self) -> dict[str, Any]:
        with open(FIXTURE_PATH, encoding="utf-8") as fh:
            stdin_data = fh.read().encode()
        usage_file = self.workspace / "demux.usage.json"
        proc = subprocess.run(
            [os.environ.get("PYTHON", "python3"), str(REPO_ROOT / "bundle/.ralph/python/run-plan-cli-json-demux.py"), "opencode", "", str(usage_file)],
            input=stdin_data,
            capture_output=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        return json.loads(usage_file.read_text(encoding="utf-8"))

    def test_plan54_fixture_demux_counts_native_and_ralph_tools(self) -> None:
        usage = self._demux_fixture()
        expected_total = (
            PLAN54_READ_CALLS
            + PLAN54_GREP_CALLS
            + PLAN54_GLOB_CALLS
            + PLAN54_BASH_CALLS
            + PLAN54_RALPH_PROXY_READ_CALLS
            + PLAN54_RALPH_PROXY_GREP_CALLS
            + 1
        )
        self.assertEqual(usage["tool_calls_total"], expected_total, usage)
        self.assertEqual(usage["native_read_compatibility_calls"], PLAN54_READ_CALLS)
        self.assertEqual(usage["native_search_calls"], PLAN54_GREP_CALLS + PLAN54_GLOB_CALLS)
        self.assertEqual(usage["native_shell_calls"], PLAN54_BASH_CALLS)
        self.assertEqual(usage["ralph_proxy_calls"], PLAN54_RALPH_PROXY_READ_CALLS + PLAN54_RALPH_PROXY_GREP_CALLS)
        self.assertGreater(usage["native_read_like_calls"], 0)
        self.assertGreater(usage["ralph_mcp_calls"], 0)
        self.assertGreaterEqual(usage["repeated_read_targets"], 1)
        self.assertGreaterEqual(usage["repeated_read_extra_calls"], PLAN54_REPEATED_READ_COUNT - 1)
        self.assertEqual(usage["cache_read_input_tokens"], 1260150)
        self.assertEqual(usage["opencode_cache_fields_seen"], 1)

    def test_mcp_proxy_compaction_windows_repeated_native_reads(self) -> None:
        payload = large_read_payload()
        original_bytes = len(payload.encode("utf-8"))
        returned_bytes_total = 0
        for i in range(PLAN54_REPEATED_READ_COUNT):
            result = self._invoke_cli(
                "read",
                f"{payload}\n# iteration {i}",
                path=PLAN54_REPEATED_READ_TARGET,
                title=f"read {PLAN54_REPEATED_READ_TARGET}",
            )
            self.assertTrue(result.get("applied"), result)
            envelope = json.loads(result["compacted"])
            self.assertTrue(envelope.get("truncated"))
            self.assertIn("resultId", envelope)
            returned_bytes_total += int(envelope.get("returnedBytes") or len(result["compacted"]))

        self.assertLess(returned_bytes_total, original_bytes * PLAN54_REPEATED_READ_COUNT / 2)
        self.assertTrue(self.window_log.is_file())
        savings = OVERLAY.aggregate_byte_savings_by_path(str(self.runtime_state))
        window_bucket = savings["result_windowing"]
        self.assertGreater(window_bucket["saved_bytes"], 0)
        self.assertGreaterEqual(window_bucket["count"], PLAN54_REPEATED_READ_COUNT)

    def test_compaction_disabled_preserves_old_unbounded_behavior(self) -> None:
        env = {
            "PATH": self.env.get("PATH", os.environ.get("PATH", "")),
            "RALPH_MCP_WORKSPACE": str(self.workspace),
            "RALPH_PLAN_KEY": "plan54-hybrid-regression",
            "RALPH_PLAN_WORKSPACE_ROOT": str(self.state_root),
            "WORKSPACE": str(self.workspace),
            "RALPH_NATIVE_RESULT_COMPACT": "0",
            "RALPH_PROXY_SHELL_COMPACT": "0",
            "RALPH_BASH_COMPACT": "0",
        }
        payload = {
            "tool_name": "read",
            "text": large_read_payload(),
            "workspace": str(self.workspace),
            "plan_key": "plan54-hybrid-regression",
            "path": PLAN54_REPEATED_READ_TARGET,
        }
        proc = subprocess.run(
            ["bash", str(CLI)],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")
        self.assertFalse(self.window_log.exists())

    def test_hybrid_fixture_includes_both_native_and_ralph_proxy_tools(self) -> None:
        usage = self._demux_fixture()
        native_exploration = (
            usage["native_read_compatibility_calls"]
            + usage["native_search_calls"]
            + usage["native_shell_calls"]
        )
        self.assertGreater(native_exploration, PLAN54_READ_CALLS)
        self.assertGreater(usage["ralph_proxy_calls"], 0)
        self.assertIn("read", usage["tool_calls_by_tool"])
        self.assertIn("ralph_proxy_read", usage["tool_calls_by_tool"])


if __name__ == "__main__":
    unittest.main()
