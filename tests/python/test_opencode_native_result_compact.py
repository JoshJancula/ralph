#!/usr/bin/env python3
"""Tests for OpenCode native exploration result compaction via native-result-compact-cli."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
CLI = REPO_ROOT / "bundle" / ".ralph" / "bash-lib" / "native-hook" / "native-result-compact-cli.sh"

SUPPORTED_TOOLS = ("read", "grep", "glob", "search", "bash")


def envelope_preview(compacted_text: str) -> str:
    try:
        envelope = json.loads(compacted_text)
        preview = envelope.get("preview")
        if isinstance(preview, str) and preview:
            return preview
    except json.JSONDecodeError:
        pass
    return compacted_text


def apply_compacted_carriers(
    output: dict[str, Any],
    compacted_text: str,
    tool: str,
) -> None:
    """Mirror bundle/.opencode/plugins/ralph-runtime-hooks.ts carrier mutation."""
    output["output"] = compacted_text
    preview = envelope_preview(compacted_text)
    title_seed = output.get("title") if isinstance(output.get("title"), str) and output.get("title") else tool
    output["title"] = f"{preview[:120]}..." if len(preview) > 120 else preview or title_seed
    metadata = output.get("metadata")
    base_meta = dict(metadata) if isinstance(metadata, dict) else {}
    base_meta["output"] = compacted_text
    base_meta["ralph_compacted"] = True
    output["metadata"] = base_meta


def large_payload(tool: str) -> str:
    if tool == "grep":
        return "\n".join(f"path/file{i}.txt:{i + 1}:match-{i}" for i in range(2000))
    if tool == "glob":
        return "\n".join(f"src/module/file{i}.ts" for i in range(2000))
    if tool == "search":
        return "\n".join(
            f"src/module{i % 50}/chunk.ts:{i}:semantic hit module chunk {i}" for i in range(2000)
        )
    if tool == "bash":
        return "\n".join(f"build line {i}" for i in range(2000))
    return "x" * 20_000


def read_payload() -> str:
    return "\n".join(f"line {i}" for i in range(800))


@unittest.skipUnless(shutil.which("bash"), "bash required")
@unittest.skipUnless(shutil.which("jq"), "jq required")
class NativeResultCompactCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self.tmp.name)
        self.state_root = self.workspace / ".ralph-workspace"
        self.state_root.mkdir(parents=True, exist_ok=True)
        self.env = os.environ.copy()
        self.env.update(
            {
                "RALPH_NATIVE_RESULT_COMPACT": "1",
                "RALPH_NATIVE_RESULT_PREVIEW_MAX_BYTES": "500",
                "RALPH_MCP_WORKSPACE": str(self.workspace),
                "RALPH_PLAN_KEY": "opencode-native-result-test",
                "RALPH_PLAN_WORKSPACE_ROOT": str(self.state_root),
                "WORKSPACE": str(self.workspace),
            }
        )
        bash_lib = REPO_ROOT / "bundle" / ".ralph" / "bash-lib"
        (self.workspace / ".ralph").mkdir(parents=True, exist_ok=True)
        (self.workspace / ".ralph" / "bash-lib").symlink_to(bash_lib, target_is_directory=True)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _invoke_cli(self, tool_name: str, text: str, **extra: Any) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "tool_name": tool_name,
            "text": text,
            "workspace": str(self.workspace),
            "plan_key": "opencode-native-result-test",
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

    def test_each_supported_tool_returns_envelope_with_result_id(self) -> None:
        for tool in SUPPORTED_TOOLS:
            with self.subTest(tool=tool):
                extra: dict[str, Any] = {}
                if tool == "read":
                    extra = {"path": "src/target.ts", "title": "read src/target.ts"}
                elif tool == "grep":
                    extra = {"tool_args": {"pattern": "match"}}
                elif tool == "glob":
                    extra = {"tool_args": {"glob_pattern": "**/*.ts"}}
                elif tool == "search":
                    extra = {"tool_args": {"query": "semantic module chunk"}}
                result = self._invoke_cli(tool, large_payload(tool), **extra)
                self.assertTrue(result.get("applied"), result)
                compacted = result.get("compacted")
                self.assertIsInstance(compacted, str)
                envelope = json.loads(compacted)
                self.assertTrue(envelope.get("truncated"))
                self.assertIn("resultId", envelope)
                self.assertGreater(envelope.get("originalBytes", 0), envelope.get("returnedBytes", 0))
                self.assertTrue(envelope.get("preview"))
                self.assertTrue(envelope.get("breakpoints"))
                self.assertTrue(envelope.get("nextActions"))

    def test_read_preview_includes_path_and_counts(self) -> None:
        result = self._invoke_cli(
            "read",
            read_payload(),
            path="src/target.ts",
            title="read src/target.ts",
        )
        envelope = json.loads(result["compacted"])
        preview = envelope["preview"]
        self.assertIn("src/target.ts", preview)
        self.assertIn("lines:", preview)
        self.assertIn("bytes:", preview)

    def test_grep_collapses_duplicates_and_caps_preview(self) -> None:
        dup_lines = "\n".join(
            [
                "alpha/file.txt:10:match",
                "alpha/file.txt:10:match",
                "beta/file.txt:20:other",
            ]
            + [f"gamma/file.txt:{i + 1}:hit-{i}" for i in range(2000)]
        )
        result = self._invoke_cli("grep", dup_lines, tool_args={"pattern": "match"})
        envelope = json.loads(result["compacted"])
        result_id = envelope["resultId"]
        raw_path = (
            self.state_root
            / "tool-results/opencode-native-result-test/results"
            / f"{result_id}.txt"
        )
        stored = raw_path.read_text(encoding="utf-8")
        self.assertEqual(stored.count("alpha/file.txt:10:match"), 1)
        self.assertLess(len(envelope["preview"].splitlines()), 200)
        action_tools = {action["tool"] for action in envelope.get("nextActions", [])}
        self.assertIn("ralph_proxy_result_search", action_tools)
        self.assertIn("ralph_proxy_result_read", action_tools)

    def test_glob_preview_summarizes_large_sets(self) -> None:
        result = self._invoke_cli(
            "glob",
            large_payload("glob"),
            tool_args={"glob_pattern": "**/*.ts"},
        )
        envelope = json.loads(result["compacted"])
        self.assertIn("glob:", envelope["preview"])
        self.assertIn("path(s)", envelope["preview"])
        result_id = envelope["resultId"]
        stored = self.state_root / "tool-results/opencode-native-result-test/results" / f"{result_id}.txt"
        self.assertTrue(stored.is_file())
        stored_lines = stored.read_text(encoding="utf-8").splitlines()
        self.assertGreaterEqual(len(stored_lines), 2000)

    def test_search_preview_uses_ranking_when_query_present(self) -> None:
        result = self._invoke_cli(
            "search",
            large_payload("search"),
            tool_args={"query": "semantic module chunk"},
        )
        envelope = json.loads(result["compacted"])
        preview_lines = [line for line in envelope["preview"].splitlines() if line.strip()]
        self.assertLess(len(preview_lines), 200)
        self.assertTrue(any("module" in line for line in preview_lines))
        result_id = envelope["resultId"]
        raw_path = self.state_root / "tool-results/opencode-native-result-test/results" / f"{result_id}.txt"
        self.assertTrue(raw_path.is_file())
        self.assertGreater(len(raw_path.read_text(encoding="utf-8")), len(envelope["preview"]))

    def test_small_payload_skips_compaction(self) -> None:
        result = self._invoke_cli("read", "short")
        self.assertEqual(result, {})


class OpencodeOutputCarrierTests(unittest.TestCase):
    def test_carriers_receive_compacted_envelope(self) -> None:
        envelope = {
            "truncated": True,
            "preview": "alpha" * 40,
            "originalBytes": 5000,
            "returnedBytes": 200,
            "resultId": "abc123",
        }
        compacted_text = json.dumps(envelope)
        output = {
            "title": "read target.txt",
            "output": "x" * 5000,
            "metadata": {"path": "target.txt"},
        }
        apply_compacted_carriers(output, compacted_text, "read")
        self.assertEqual(output["output"], compacted_text)
        self.assertEqual(output["metadata"]["output"], compacted_text)
        self.assertTrue(output["metadata"]["ralph_compacted"])
        self.assertIn("alpha", output["title"])

    def test_title_truncates_long_preview(self) -> None:
        envelope = {"preview": "z" * 200, "resultId": "rid"}
        output = {"title": "grep", "output": "", "metadata": {}}
        apply_compacted_carriers(output, json.dumps(envelope), "grep")
        self.assertTrue(output["title"].endswith("..."))
        self.assertLessEqual(len(output["title"]), 123)

    def test_metadata_output_carrier_for_non_object_metadata(self) -> None:
        envelope = {"preview": "ok", "resultId": "rid"}
        output = {"title": "glob", "output": "raw", "metadata": None}
        apply_compacted_carriers(output, json.dumps(envelope), "glob")
        self.assertEqual(output["metadata"]["output"], json.dumps(envelope))


if __name__ == "__main__":
    unittest.main()
