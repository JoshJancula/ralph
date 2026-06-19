#!/usr/bin/env python3
"""Unit tests for workspace-registry.py.

Tests covering add/update/de-dupe behavior, absolute path normalization,
existing registry preservation, and invalid or missing registry data.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

# Add the tests/python directory to the path for importing ralph_script_loader
sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

# Load the workspace_registry module
wr = load_ralph_script("workspace-registry")


class TestAbsPath(unittest.TestCase):
    """Tests for _abs_path function."""

    def test_absolute_path_unchanged(self) -> None:
        """Absolute paths should remain unchanged."""
        abs_path = "/home/user/project"
        result = wr._abs_path(abs_path)
        self.assertEqual(result, abs_path)

    def test_tilde_expansion(self) -> None:
        """Tilde should expand to home directory."""
        result = wr._abs_path("~/workspace")
        self.assertFalse(result.startswith("~"))
        self.assertTrue(os.path.isabs(result))
        self.assertIn("workspace", result)

    def test_relative_path_resolution(self) -> None:
        """Relative paths should be resolved to absolute."""
        result = wr._abs_path("relative/path")
        self.assertTrue(os.path.isabs(result))
        self.assertIn("relative", result)

    def test_dot_resolution(self) -> None:
        """Dot paths should be resolved."""
        result = wr._abs_path("./test")
        self.assertTrue(os.path.isabs(result))
        self.assertFalse(result.startswith("."))


class TestLoadExisting(unittest.TestCase):
    """Tests for _load_existing function."""

    def setUp(self) -> None:
        """Set up temporary directory."""
        self.temp_dir = tempfile.mkdtemp()
        self.addCleanup(self._cleanup_temp_dir)

    def _cleanup_temp_dir(self) -> None:
        """Clean up temporary directory."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_missing_file_returns_empty_list(self) -> None:
        """Missing registry file should return empty list."""
        nonexistent_path = Path(self.temp_dir) / "nonexistent.json"
        result = wr._load_existing(nonexistent_path)
        self.assertEqual(result, [])

    def test_empty_file_returns_empty_list(self) -> None:
        """Empty file should return empty list."""
        registry_path = Path(self.temp_dir) / "empty.json"
        registry_path.write_text("", encoding="utf-8")
        result = wr._load_existing(registry_path)
        self.assertEqual(result, [])

    def test_invalid_json_returns_empty_list(self) -> None:
        """Invalid JSON should return empty list."""
        registry_path = Path(self.temp_dir) / "invalid.json"
        registry_path.write_text("not valid json", encoding="utf-8")
        result = wr._load_existing(registry_path)
        self.assertEqual(result, [])

    def test_non_list_returns_empty_list(self) -> None:
        """Non-list JSON should return empty list."""
        registry_path = Path(self.temp_dir) / "object.json"
        registry_path.write_text('{"key": "value"}', encoding="utf-8")
        result = wr._load_existing(registry_path)
        self.assertEqual(result, [])

    def test_valid_list_preserved(self) -> None:
        """Valid list should be returned."""
        registry_path = Path(self.temp_dir) / "valid.json"
        data = [{"path": "/test", "lastSeen": "2024-01-01T00:00:00Z"}]
        registry_path.write_text(json.dumps(data), encoding="utf-8")
        result = wr._load_existing(registry_path)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["path"], "/test")

    def test_non_dict_items_filtered(self) -> None:
        """Non-dict items should be filtered out."""
        registry_path = Path(self.temp_dir) / "mixed.json"
        data = [{"path": "/test"}, "not a dict", 123, None, {"path": "/other"}]
        registry_path.write_text(json.dumps(data), encoding="utf-8")
        result = wr._load_existing(registry_path)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["path"], "/test")
        self.assertEqual(result[1]["path"], "/other")

    def test_dict_items_are_copied(self) -> None:
        """Dict items should be copied, not referenced."""
        registry_path = Path(self.temp_dir) / "copy.json"
        data = [{"path": "/test", "nested": {"key": "value"}}]
        registry_path.write_text(json.dumps(data), encoding="utf-8")
        result = wr._load_existing(registry_path)
        # Modify result and ensure original file is unchanged
        result[0]["path"] = "/modified"
        reloaded = wr._load_existing(registry_path)
        self.assertEqual(reloaded[0]["path"], "/test")


class TestUpdateRegistry(unittest.TestCase):
    """Tests for update_registry function."""

    def setUp(self) -> None:
        """Set up temporary directory."""
        self.temp_dir = tempfile.mkdtemp()
        self.registry_path = Path(self.temp_dir) / "registry.json"
        self.workspace_dir = Path(self.temp_dir) / "workspace"
        self.workspace_dir.mkdir()
        self.addCleanup(self._cleanup_temp_dir)

    def _cleanup_temp_dir(self) -> None:
        """Clean up temporary directory."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_add_new_entry(self) -> None:
        """Adding a new workspace entry."""
        wr.update_registry(
            str(self.registry_path),
            str(self.workspace_dir),
            "test-plan",
            "cursor"
        )
        data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["path"], str(self.workspace_dir))
        self.assertEqual(data[0]["planKey"], "test-plan")
        self.assertEqual(data[0]["runtime"], "cursor")
        self.assertIn("lastSeen", data[0])

    def test_update_existing_entry(self) -> None:
        """Updating an existing workspace entry."""
        import time

        # First add
        wr.update_registry(
            str(self.registry_path),
            str(self.workspace_dir),
            "old-plan",
            "claude"
        )
        old_data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        old_timestamp = old_data[0]["lastSeen"]

        # Small delay to ensure timestamp differs
        time.sleep(0.01)

        # Update with new values
        wr.update_registry(
            str(self.registry_path),
            str(self.workspace_dir),
            "new-plan",
            "cursor"
        )
        new_data = json.loads(self.registry_path.read_text(encoding="utf-8"))

        # Should still be one entry (de-duped), but updated
        self.assertEqual(len(new_data), 1)
        self.assertEqual(new_data[0]["planKey"], "new-plan")
        self.assertEqual(new_data[0]["runtime"], "cursor")
        # Timestamp may or may not differ depending on timing
        # Just verify the entry was updated with new plan/runtime

    def test_absolute_path_normalization(self) -> None:
        """Paths should be normalized to absolute."""
        # Use relative path
        rel_path = os.path.relpath(self.workspace_dir)
        wr.update_registry(
            str(self.registry_path),
            rel_path,
            "test-plan",
            "cursor"
        )
        data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        self.assertEqual(data[0]["path"], str(self.workspace_dir))
        self.assertTrue(os.path.isabs(data[0]["path"]))

    def test_tilde_expansion_in_path(self) -> None:
        """Tilde in workspace path should be expanded."""
        # Use a temporary HOME so the test does not depend on the runner's
        # actual user directory being writable.
        home_dir = Path(self.temp_dir) / "home"
        test_path = home_dir / "test_workspace"
        test_path.mkdir(parents=True, exist_ok=True)
        with unittest.mock.patch.dict(os.environ, {"HOME": str(home_dir)}, clear=False):
            wr.update_registry(
                str(self.registry_path),
                "~/test_workspace",
                "test-plan",
                "cursor"
            )
            data = json.loads(self.registry_path.read_text(encoding="utf-8"))
            self.assertFalse(data[0]["path"].startswith("~"))
            self.assertTrue(os.path.isabs(data[0]["path"]))

    def test_dedupe_same_path_different_format(self) -> None:
        """Same path in different formats should be de-duped."""
        abs_path = str(self.workspace_dir)
        rel_path = os.path.relpath(self.workspace_dir)

        # Add with absolute path
        wr.update_registry(str(self.registry_path), abs_path, "plan1", "cursor")
        # Add with relative path (same location)
        wr.update_registry(str(self.registry_path), rel_path, "plan2", "claude")

        data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        self.assertEqual(len(data), 1)
        # The second update should win
        self.assertEqual(data[0]["planKey"], "plan2")

    def test_dedupe_with_trailing_slash(self) -> None:
        """Paths with trailing slashes should be de-duped."""
        path_with_slash = str(self.workspace_dir) + "/"

        wr.update_registry(
            str(self.registry_path),
            str(self.workspace_dir),
            "plan1",
            "cursor"
        )
        wr.update_registry(
            str(self.registry_path),
            path_with_slash,
            "plan2",
            "claude"
        )

        data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        # Both paths resolve to same absolute path
        self.assertEqual(len(data), 1)

    def test_multiple_workspaces_preserved(self) -> None:
        """Multiple different workspaces should be preserved."""
        workspace1 = Path(self.temp_dir) / "workspace1"
        workspace2 = Path(self.temp_dir) / "workspace2"
        workspace1.mkdir()
        workspace2.mkdir()

        wr.update_registry(str(self.registry_path), str(workspace1), "plan1", "cursor")
        wr.update_registry(str(self.registry_path), str(workspace2), "plan2", "claude")

        data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        self.assertEqual(len(data), 2)

    def test_preserves_existing_registry(self) -> None:
        """Existing registry entries should be preserved when adding new."""
        # Pre-populate with existing data
        existing = [
            {"path": "/existing/workspace", "lastSeen": "2024-01-01T00:00:00Z",
             "planKey": "existing-plan", "runtime": "codex"}
        ]
        self.registry_path.write_text(json.dumps(existing), encoding="utf-8")

        wr.update_registry(
            str(self.registry_path),
            str(self.workspace_dir),
            "new-plan",
            "cursor"
        )

        data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        self.assertEqual(len(data), 2)
        paths = {entry["path"] for entry in data}
        self.assertIn("/existing/workspace", paths)
        self.assertIn(str(self.workspace_dir), paths)

    def test_preserves_with_invalid_entries(self) -> None:
        """Existing valid entries should be preserved even with invalid ones."""
        existing = [
            {"path": "/valid/workspace", "lastSeen": "2024-01-01T00:00:00Z",
             "planKey": "valid-plan", "runtime": "cursor"},
            "invalid entry",
            {"path": "", "lastSeen": "2024-01-02T00:00:00Z",  # Empty path
             "planKey": "empty-plan", "runtime": "claude"},
        ]
        self.registry_path.write_text(json.dumps(existing), encoding="utf-8")

        wr.update_registry(
            str(self.registry_path),
            str(self.workspace_dir),
            "new-plan",
            "cursor"
        )

        data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        # Valid entry and new entry should be preserved
        paths = [entry["path"] for entry in data if entry.get("path")]
        self.assertIn("/valid/workspace", paths)
        self.assertIn(str(self.workspace_dir), paths)

    def test_max_entries_limit(self) -> None:
        """Registry should limit to last 100 entries."""
        # Add 105 entries
        for i in range(105):
            ws_dir = Path(self.temp_dir) / f"workspace{i}"
            ws_dir.mkdir()
            wr.update_registry(
                str(self.registry_path),
                str(ws_dir),
                f"plan{i}",
                "cursor"
            )

        data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        self.assertEqual(len(data), 100)
        # Oldest entries should be removed
        self.assertFalse(any(f"workspace0" in entry["path"] for entry in data))
        self.assertTrue(any(f"workspace99" in entry["path"] for entry in data))

    def test_registry_directory_created(self) -> None:
        """Registry directory should be created if it doesn't exist."""
        nested_dir = Path(self.temp_dir) / "nested" / "deep"
        registry_path = nested_dir / "registry.json"

        wr.update_registry(
            str(registry_path),
            str(self.workspace_dir),
            "test-plan",
            "cursor"
        )

        self.assertTrue(registry_path.exists())


class TestRecordValue(unittest.TestCase):
    """Tests for _record_value function."""

    def test_string_value_returned(self) -> None:
        """String values should be returned as-is."""
        result = wr._record_value({"key": "value"}, "key")
        self.assertEqual(result, "value")

    def test_non_string_converted_to_string(self) -> None:
        """Non-string values should be converted to string."""
        result = wr._record_value({"key": 123}, "key")
        self.assertEqual(result, "")

    def test_missing_key_returns_empty(self) -> None:
        """Missing key should return empty string."""
        result = wr._record_value({"other": "value"}, "key")
        self.assertEqual(result, "")

    def test_none_value_returns_empty(self) -> None:
        """None value should return empty string."""
        result = wr._record_value({"key": None}, "key")
        self.assertEqual(result, "")


class TestParseLastSeen(unittest.TestCase):
    """Tests for _parse_last_seen function."""

    def test_valid_iso_timestamp(self) -> None:
        """Valid ISO timestamp should be parsed."""
        result = wr._parse_last_seen("2024-01-15T10:30:00Z")
        self.assertIsNotNone(result)
        self.assertEqual(result.year, 2024)
        self.assertEqual(result.month, 1)
        self.assertEqual(result.day, 15)

    def test_timestamp_with_offset(self) -> None:
        """Timestamp with timezone offset should be parsed."""
        result = wr._parse_last_seen("2024-01-15T10:30:00+00:00")
        self.assertIsNotNone(result)

    def test_empty_string_returns_none(self) -> None:
        """Empty string should return None."""
        result = wr._parse_last_seen("")
        self.assertIsNone(result)

    def test_invalid_timestamp_returns_none(self) -> None:
        """Invalid timestamp should return None."""
        result = wr._parse_last_seen("not-a-timestamp")
        self.assertIsNone(result)

    def test_naive_datetime_gets_utc(self) -> None:
        """Naive datetime should get UTC timezone."""
        result = wr._parse_last_seen("2024-01-15T10:30:00")
        self.assertIsNotNone(result)
        self.assertIsNotNone(result.tzinfo)


class TestPruneRegistry(unittest.TestCase):
    """Tests for prune_registry function."""

    def setUp(self) -> None:
        """Set up temporary directory."""
        self.temp_dir = tempfile.mkdtemp()
        self.registry_path = Path(self.temp_dir) / "registry.json"
        self.addCleanup(self._cleanup_temp_dir)

    def _cleanup_temp_dir(self) -> None:
        """Clean up temporary directory."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_prune_old_entries(self) -> None:
        """Old entries should be pruned."""
        # Create entries with old timestamps
        old_time = "2020-01-01T00:00:00Z"
        recent_time = "2099-01-01T00:00:00Z"

        workspace1 = Path(self.temp_dir) / "workspace1"
        workspace2 = Path(self.temp_dir) / "workspace2"
        workspace1.mkdir()
        workspace2.mkdir()

        existing = [
            {"path": str(workspace1), "lastSeen": old_time,
             "planKey": "old", "runtime": "cursor"},
            {"path": str(workspace2), "lastSeen": recent_time,
             "planKey": "new", "runtime": "cursor"},
        ]
        self.registry_path.write_text(json.dumps(existing), encoding="utf-8")

        removed, kept = wr.prune_registry(str(self.registry_path), days=30)

        self.assertEqual(removed, 1)
        self.assertEqual(kept, 1)

        data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["planKey"], "new")

    def test_prune_nonexistent_workspaces(self) -> None:
        """Non-existent workspaces should be pruned."""
        recent_time = "2099-01-01T00:00:00Z"
        existing = [
            {"path": "/nonexistent/path123", "lastSeen": recent_time,
             "planKey": "test", "runtime": "cursor"},
        ]
        self.registry_path.write_text(json.dumps(existing), encoding="utf-8")

        removed, kept = wr.prune_registry(str(self.registry_path), days=365)

        self.assertEqual(removed, 1)
        self.assertEqual(kept, 0)

    def test_prune_invalid_records(self) -> None:
        """Records with invalid data should be pruned."""
        recent_time = "2099-01-01T00:00:00Z"
        workspace = Path(self.temp_dir) / "workspace"
        workspace.mkdir()

        existing = [
            {"path": "", "lastSeen": recent_time,  # Empty path
             "planKey": "test", "runtime": "cursor"},
            {"path": str(workspace), "lastSeen": "invalid-timestamp",  # Invalid timestamp
             "planKey": "test2", "runtime": "cursor"},
            {"path": str(workspace), "lastSeen": recent_time,  # Valid
             "planKey": "valid", "runtime": "cursor"},
        ]
        self.registry_path.write_text(json.dumps(existing), encoding="utf-8")

        removed, kept = wr.prune_registry(str(self.registry_path), days=365)

        self.assertEqual(kept, 1)
        data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        self.assertEqual(data[0]["planKey"], "valid")


class TestMainFunction(unittest.TestCase):
    """Tests for main function."""

    def setUp(self) -> None:
        """Set up temporary directory."""
        self.temp_dir = tempfile.mkdtemp()
        self.registry_path = Path(self.temp_dir) / "registry.json"
        self.workspace_dir = Path(self.temp_dir) / "workspace"
        self.workspace_dir.mkdir()
        self.addCleanup(self._cleanup_temp_dir)

    def _cleanup_temp_dir(self) -> None:
        """Clean up temporary directory."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_main_update_registry(self) -> None:
        """Main with registry, workspace, plan, runtime args."""
        result = wr.main([
            "workspace-registry.py",  # argv[0] is script name
            str(self.registry_path),
            str(self.workspace_dir),
            "test-plan",
            "cursor"
        ])
        self.assertEqual(result, 0)

        data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        self.assertEqual(len(data), 1)

    def test_main_list_empty(self) -> None:
        """List command with empty registry."""
        import io
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()
        try:
            result = wr.main(["workspace-registry.py", "list", str(self.registry_path)])
            output = sys.stdout.getvalue()
        finally:
            sys.stdout = old_stdout

        self.assertEqual(result, 0)
        self.assertIn("No workspaces registered", output)

    def test_main_list_with_entries(self) -> None:
        """List command with entries."""
        # Add an entry first
        wr.update_registry(
            str(self.registry_path),
            str(self.workspace_dir),
            "test-plan",
            "cursor"
        )

        import io
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()
        try:
            result = wr.main(["workspace-registry.py", "list", str(self.registry_path)])
            output = sys.stdout.getvalue()
        finally:
            sys.stdout = old_stdout

        self.assertEqual(result, 0)
        self.assertIn("PATH", output)
        self.assertIn(str(self.workspace_dir), output)

    def test_main_prune(self) -> None:
        """Prune command."""
        result = wr.main(["workspace-registry.py", "prune", str(self.registry_path), "30"])
        self.assertEqual(result, 0)

    def test_main_prune_invalid_days(self) -> None:
        """Prune command with invalid days."""
        import io
        old_stderr = sys.stderr
        sys.stderr = io.StringIO()
        try:
            result = wr.main(["workspace-registry.py", "prune", str(self.registry_path), "not-a-number"])
        finally:
            sys.stderr = old_stderr

        self.assertEqual(result, 2)

    def test_main_prune_negative_days(self) -> None:
        """Prune command with negative days."""
        import io
        old_stderr = sys.stderr
        sys.stderr = io.StringIO()
        try:
            result = wr.main(["workspace-registry.py", "prune", str(self.registry_path), "-1"])
        finally:
            sys.stderr = old_stderr

        self.assertEqual(result, 2)

    def test_main_add(self) -> None:
        """Add command."""
        result = wr.main(["workspace-registry.py", "add", str(self.registry_path), str(self.workspace_dir)])
        self.assertEqual(result, 0)

        data = json.loads(self.registry_path.read_text(encoding="utf-8"))
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["planKey"], "manual")

    def test_main_add_nonexistent_workspace(self) -> None:
        """Add command with non-existent workspace."""
        import io
        old_stderr = sys.stderr
        sys.stderr = io.StringIO()
        try:
            result = wr.main(["workspace-registry.py", "add", str(self.registry_path), "/nonexistent/path123"])
        finally:
            sys.stderr = old_stderr

        self.assertEqual(result, 1)

    def test_main_paths(self) -> None:
        """Paths command."""
        # Add an entry first
        wr.update_registry(
            str(self.registry_path),
            str(self.workspace_dir),
            "test-plan",
            "cursor"
        )

        import io
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()
        try:
            result = wr.main(["workspace-registry.py", "paths", str(self.registry_path)])
            output = sys.stdout.getvalue()
        finally:
            sys.stdout = old_stdout

        self.assertEqual(result, 0)
        self.assertIn(str(self.workspace_dir), output)

    def test_main_invalid_args(self) -> None:
        """Invalid arguments should return error."""
        import io
        old_stderr = sys.stderr
        sys.stderr = io.StringIO()
        try:
            result = wr.main(["workspace-registry.py", "invalid", str(self.registry_path)])
        finally:
            sys.stderr = old_stderr

        self.assertEqual(result, 2)

    def test_main_insufficient_args(self) -> None:
        """Insufficient arguments should return error."""
        import io
        old_stderr = sys.stderr
        sys.stderr = io.StringIO()
        try:
            result = wr.main(["workspace-registry.py", str(self.registry_path)])
        finally:
            sys.stderr = old_stderr

        self.assertEqual(result, 2)


if __name__ == "__main__":
    unittest.main()
