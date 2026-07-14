#!/usr/bin/env python3
"""Unit tests for aggregate_hook_config_by_runtime in ralph_overlay_usage_fields.py.

Aggregates hooks-config.jsonl snapshots (PLAN15) into a per-runtime,
per-channel enabled/disabled/mixed/unknown status with all distinct reasons.
"""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any

from ralph_script_loader import load_ralph_script


OVERLAY = load_ralph_script("ralph_overlay_usage_fields")


class TestHookConfigByRuntime(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp_dir, ignore_errors=True)

    def _write_snapshots(self, records: list[dict[str, Any]]) -> str:
        path = self.tmp_dir / "hooks-config.jsonl"
        with open(path, "w", encoding="utf-8") as fh:
            for record in records:
                fh.write(json.dumps(record) + "\n")
        return str(path)

    def _channel_record(self, channel: str, enabled: bool, reason: str) -> dict[str, Any]:
        return {"channel": channel, "runtime": "claude", "requestedGate": "on" if enabled else "off",
                "requestedSource": "mode_default", "enabled": enabled, "effective": enabled, "reason": reason}

    def test_enabled_then_disabled_produces_mixed(self) -> None:
        path = self._write_snapshots([
            {"timestamp": "t1", "planKey": "p", "iteration": "1", "runtime": "claude",
             "channels": [self._channel_record("bash_compact", True, "proven_channel:mode_default")]},
            {"timestamp": "t2", "planKey": "p", "iteration": "2", "runtime": "claude",
             "channels": [self._channel_record("bash_compact", False, "gate_disabled")]},
        ])
        result = OVERLAY.aggregate_hook_config_by_runtime(path)
        self.assertEqual(result["claude"]["bash_compact"]["status"], "mixed")
        self.assertIn("gate_disabled", result["claude"]["bash_compact"]["reasons"])
        self.assertIn("proven_channel:mode_default", result["claude"]["bash_compact"]["reasons"])

    def test_single_disabled_run_preserves_its_reason(self) -> None:
        path = self._write_snapshots([
            {"timestamp": "t1", "planKey": "p", "iteration": "1", "runtime": "cursor",
             "channels": [self._channel_record("native_result_compact", False, "runtime_cannot_mutate_output")]},
        ])
        result = OVERLAY.aggregate_hook_config_by_runtime(path)
        self.assertEqual(result["cursor"]["native_result_compact"]["status"], "disabled")
        self.assertEqual(result["cursor"]["native_result_compact"]["reasons"], ["runtime_cannot_mutate_output"])

    def test_all_enabled_across_invocations_is_enabled(self) -> None:
        path = self._write_snapshots([
            {"timestamp": "t1", "planKey": "p", "iteration": "1", "runtime": "claude",
             "channels": [self._channel_record("proxy_shell_compact", True, "proven_channel:mode_default")]},
            {"timestamp": "t2", "planKey": "p", "iteration": "2", "runtime": "claude",
             "channels": [self._channel_record("proxy_shell_compact", True, "proven_channel:mode_default")]},
        ])
        result = OVERLAY.aggregate_hook_config_by_runtime(path)
        self.assertEqual(result["claude"]["proxy_shell_compact"]["status"], "enabled")

    def test_legacy_run_without_snapshots_produces_empty_dict(self) -> None:
        missing_path = str(self.tmp_dir / "does-not-exist.jsonl")
        result = OVERLAY.aggregate_hook_config_by_runtime(missing_path)
        self.assertEqual(result, {})

    def test_plan_key_filter_excludes_other_plans(self) -> None:
        path = self._write_snapshots([
            {"timestamp": "t1", "planKey": "plan-a", "iteration": "1", "runtime": "claude",
             "channels": [self._channel_record("bash_compact", True, "proven_channel:mode_default")]},
            {"timestamp": "t2", "planKey": "plan-b", "iteration": "1", "runtime": "claude",
             "channels": [self._channel_record("bash_compact", False, "gate_disabled")]},
        ])
        result = OVERLAY.aggregate_hook_config_by_runtime(path, plan_key="plan-a")
        self.assertEqual(result["claude"]["bash_compact"]["status"], "enabled")

    def test_two_runtimes_are_kept_separate(self) -> None:
        path = self._write_snapshots([
            {"timestamp": "t1", "planKey": "p", "iteration": "1", "runtime": "claude",
             "channels": [self._channel_record("proxy_shell_compact", True, "proven_channel:mode_default")]},
            {"timestamp": "t2", "planKey": "p", "iteration": "2", "runtime": "opencode",
             "channels": [{"channel": "proxy_shell_compact", "runtime": "opencode", "requestedGate": "on",
                            "requestedSource": "mode_default", "enabled": True, "effective": True,
                            "reason": "proven_channel:mode_default"}]},
        ])
        result = OVERLAY.aggregate_hook_config_by_runtime(path)
        self.assertIn("claude", result)
        self.assertIn("opencode", result)
        self.assertEqual(result["claude"]["proxy_shell_compact"]["status"], "enabled")
        self.assertEqual(result["opencode"]["proxy_shell_compact"]["status"], "enabled")

    def test_malformed_lines_are_skipped_without_raising(self) -> None:
        path = self.tmp_dir / "hooks-config.jsonl"
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("not json\n")
            fh.write(json.dumps({
                "timestamp": "t1", "planKey": "p", "iteration": "1", "runtime": "claude",
                "channels": [self._channel_record("bash_compact", True, "proven_channel:mode_default")],
            }) + "\n")
        result = OVERLAY.aggregate_hook_config_by_runtime(str(path))
        self.assertEqual(result["claude"]["bash_compact"]["status"], "enabled")


if __name__ == "__main__":
    unittest.main()
