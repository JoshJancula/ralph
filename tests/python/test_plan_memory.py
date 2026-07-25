#!/usr/bin/env python3
"""Unit tests for Ralph per-plan memory store."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PY_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
sys.path.insert(0, str(PY_DIR))

import plan_memory as pm  # noqa: E402


class PlanMemoryGateTests(unittest.TestCase):
    def test_enabled_in_hybrid_by_default(self) -> None:
        self.assertTrue(pm.plan_memory_enabled(ralph_mode="hybrid"))

    def test_disabled_in_native_by_default(self) -> None:
        self.assertFalse(pm.plan_memory_enabled(ralph_mode="native"))

    def test_explicit_opt_in_native(self) -> None:
        self.assertTrue(pm.plan_memory_enabled(explicit="1", ralph_mode="native"))

    def test_explicit_opt_out_hybrid(self) -> None:
        self.assertFalse(pm.plan_memory_enabled(explicit="0", ralph_mode="hybrid"))

    def test_invalid_gate_raises(self) -> None:
        with self.assertRaises(ValueError):
            pm.plan_memory_enabled(explicit="maybe", ralph_mode="hybrid")


class PlanMemoryKeyValidationTests(unittest.TestCase):
    def test_rejects_traversal(self) -> None:
        with self.assertRaises(pm.MemoryError):
            pm.validate_memory_key("../secret", 128)

    def test_rejects_absolute(self) -> None:
        with self.assertRaises(pm.MemoryError):
            pm.validate_memory_key("/etc/passwd", 128)

    def test_rejects_env_like(self) -> None:
        with self.assertRaises(pm.MemoryError):
            pm.validate_memory_key(".env", 128)

    def test_rejects_control_chars(self) -> None:
        with self.assertRaises(pm.MemoryError):
            pm.validate_memory_key("bad\x01key", 128)

    def test_rejects_reserved_metadata(self) -> None:
        with self.assertRaises(pm.MemoryError):
            pm.validate_memory_key("index.json", 128)


class PlanMemoryCrudTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self.tmp.name) / "project"
        self.workspace.mkdir()
        self.state_root = self.workspace / ".ralph-workspace"
        self.plan_key = "plan-a"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_crud_within_plan(self) -> None:
        write_result = pm.write_entry(
            self.state_root,
            self.plan_key,
            "note",
            "hello memory",
            source_todo="todo-1",
        )
        self.assertTrue(write_result["created"])
        self.assertEqual(write_result["byte_size"], 12)

        listed = pm.list_entries(self.state_root, self.plan_key)
        self.assertEqual(len(listed["entries"]), 1)
        self.assertEqual(listed["entries"][0]["key"], "note")

        read_back = pm.read_entry(self.state_root, self.plan_key, "note")
        self.assertEqual(read_back["content"], "hello memory")

        updated = pm.write_entry(
            self.state_root,
            self.plan_key,
            "note",
            "updated",
        )
        self.assertFalse(updated["created"])
        self.assertEqual(
            pm.read_entry(self.state_root, self.plan_key, "note")["content"],
            "updated",
        )

        deleted = pm.delete_entry(self.state_root, self.plan_key, "note")
        self.assertTrue(deleted["deleted"])
        self.assertEqual(pm.list_entries(self.state_root, self.plan_key)["entries"], [])

    def test_cross_plan_isolation(self) -> None:
        pm.write_entry(self.state_root, "plan-a", "shared-key", "plan-a-value")
        with self.assertRaises(pm.MemoryError):
            pm.read_entry(self.state_root, "plan-b", "shared-key")

    def test_disabled_mode_writes_no_directory_when_not_called(self) -> None:
        memory_dir = self.state_root / "memory" / "unused-plan"
        self.assertFalse(memory_dir.exists())

    def test_log_contains_hash_not_content(self) -> None:
        pm.write_entry(self.state_root, self.plan_key, "audit", "secret-content")
        log_path = self.state_root / "logs" / self.plan_key / "plan-memory.jsonl"
        self.assertTrue(log_path.is_file())
        lines = log_path.read_text(encoding="utf-8").strip().splitlines()
        self.assertTrue(lines)
        record = json.loads(lines[-1])
        self.assertEqual(record["key"], "audit")
        self.assertTrue(record["content_hash"])
        self.assertNotIn("secret-content", log_path.read_text(encoding="utf-8"))

    def test_entry_byte_limit(self) -> None:
        os.environ["RALPH_PLAN_MEMORY_MAX_BYTES_PER_ENTRY"] = "4"
        try:
            with self.assertRaises(pm.MemoryError):
                pm.write_entry(self.state_root, self.plan_key, "big", "12345")
        finally:
            os.environ.pop("RALPH_PLAN_MEMORY_MAX_BYTES_PER_ENTRY", None)

    def test_symlink_escape_rejected_on_read(self) -> None:
        root = pm.memory_root(self.state_root, self.plan_key)
        root.mkdir(parents=True)
        outside = self.workspace / "outside.txt"
        outside.write_text("outside", encoding="utf-8")
        entries_dir = root / "entries"
        entries_dir.mkdir()
        (entries_dir / "evil.txt").symlink_to(outside)
        index = {
            "schema_version": 1,
            "entries": [
                {
                    "key": "evil",
                    "content_path": "entries/evil.txt",
                    "byte_size": 7,
                    "created_at": "2020-01-01T00:00:00Z",
                    "updated_at": "2020-01-01T00:00:00Z",
                    "source_todo": "",
                    "source_stage": "",
                    "content_hash": "abc",
                }
            ],
        }
        (root / "index.json").write_text(json.dumps(index), encoding="utf-8")
        with self.assertRaises(pm.MemoryError):
            pm.read_entry(self.state_root, self.plan_key, "evil")


if __name__ == "__main__":
    unittest.main()
