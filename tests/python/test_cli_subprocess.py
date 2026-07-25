#!/usr/bin/env python3
"""Subprocess-based unit tests for thin CLI scripts.

These scripts read sys.argv at import time, so they must be tested
via subprocess rather than direct import.

Scripts tested:
- plan-todo-risk-classify.py
- mcp-result-store-generate-breakpoints.py
- runtime-overlay-abs-path.py
- runtime-overlay-relpath.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


# Determine the project root (tests/python -> tests -> project root)
PROJECT_ROOT = Path(__file__).parent.parent.parent
PYTHON_DIR = PROJECT_ROOT / "bundle" / ".ralph" / "python"


def run_script(script_name: str, args: list[str]) -> subprocess.CompletedProcess:
    """Run a Python script with the given arguments via subprocess.

    Args:
        script_name: The script filename (with or without .py extension).
        args: List of arguments to pass to the script.

    Returns:
        CompletedProcess with stdout, stderr, and return code.
    """
    if not script_name.endswith(".py"):
        script_name += ".py"

    script_path = PYTHON_DIR / script_name
    cmd = [sys.executable, str(script_path)] + args

    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )


class TestPlanTodoRiskClassify(unittest.TestCase):
    """Tests for plan-todo-risk-classify.py CLI script."""

    def test_manual_gate_patterns(self) -> None:
        """Test manual gate pattern detection."""
        test_cases = [
            ("Run manual smoke test", "manual_gate"),
            ("Verify the golden path", "manual_gate"),
            ("This is not run in this session", "manual_gate"),
            ("Ask the user for confirmation", "manual_gate"),
        ]
        for text, expected in test_cases:
            with self.subTest(text=text):
                result = run_script("plan-todo-risk-classify", [text])
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), expected)

    def test_destructive_gate_patterns(self) -> None:
        """Test destructive gate pattern detection."""
        test_cases = [
            ("Delete the old records", "destructive_gate"),
            ("Drop the table", "destructive_gate"),
            ("Destroy the resources", "destructive_gate"),
            ("Purge the cache", "destructive_gate"),
            ("Truncate the logs", "destructive_gate"),
            ("Wipe the data", "destructive_gate"),
            ("Rollback the migration", "destructive_gate"),
            ("Run migrate down", "destructive_gate"),
            ("Execute down-migrate", "destructive_gate"),
            ("Remove old files", "destructive_gate"),
        ]
        for text, expected in test_cases:
            with self.subTest(text=text):
                result = run_script("plan-todo-risk-classify", [text])
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), expected)

    def test_verification_gate_patterns(self) -> None:
        """Test verification gate pattern detection.

        Verification hints come from:
        - Backtick-quoted commands like `git status`
        - Commands starting with ./ or / in backticks
        - Presence of &&, ||, or ; operators
        - Lines starting with "verification:" or "verify:" (case insensitive)
        """
        test_cases = [
            # Backtick-quoted commands trigger verification
            ("Run `git status` to verify", "verification_gate"),
            ("Execute `./script.sh` for testing", "verification_gate"),
            ("Use `npm test` to check", "verification_gate"),
            # Shell operators trigger verification
            ("Run pytest && echo done", "verification_gate"),
            ("git status || echo failed", "verification_gate"),
            ("cmd1; cmd2", "verification_gate"),
            # Verification prefix triggers verification
            ("Verification: run the tests", "verification_gate"),
            ("verification: check output", "verification_gate"),
            ("Verify: bash scripts/test.sh", "verification_gate"),
        ]
        for text, expected in test_cases:
            with self.subTest(text=text):
                result = run_script("plan-todo-risk-classify", [text])
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), expected)

    def test_non_verification_patterns(self) -> None:
        """Test that certain patterns do NOT trigger verification gate.

        Commands without backticks or shell operators don't trigger verification.
        These are documentation-style descriptions without verification hints.
        """
        test_cases = [
            # Plain text without backticks - normal patterns
            ("Execute ./script.sh for testing", "normal"),
            ("Use npm test to check", "normal"),
            # Documentation patterns (not code) - review/read/explain are normal
            ("Read the documentation", "normal"),
            ("Review the pull request", "normal"),
            ("Explain how the module works", "normal"),
        ]
        for text, expected in test_cases:
            with self.subTest(text=text):
                result = run_script("plan-todo-risk-classify", [text])
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), expected)

    def test_implementation_gate_patterns(self) -> None:
        """Test implementation gate pattern detection."""
        test_cases = [
            ("Implement the new feature", "implementation_gate"),
            ("Add a new module", "implementation_gate"),
            ("Update the configuration", "implementation_gate"),
            ("Fix the bug in parser", "implementation_gate"),
            ("Create a new file", "implementation_gate"),
            ("Refactor the code", "implementation_gate"),
        ]
        for text, expected in test_cases:
            with self.subTest(text=text):
                result = run_script("plan-todo-risk-classify", [text])
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), expected)

    def test_normal_patterns(self) -> None:
        """Test normal classification patterns."""
        test_cases = [
            ("Read the documentation", "normal"),
            ("Review the code changes", "normal"),
            ("Run analysis on the data", "normal"),
            ("Summarize the findings", "normal"),
        ]
        for text, expected in test_cases:
            with self.subTest(text=text):
                result = run_script("plan-todo-risk-classify", [text])
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), expected)

    def test_implementation_vs_normal_precedence(self) -> None:
        """Test that normal patterns take precedence over implementation."""
        # "Update docs" has "update" (implementation) but also "docs" (normal)
        result = run_script("plan-todo-risk-classify", ["Update the docs"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "normal")

    def test_manual_over_destructive_precedence(self) -> None:
        """Test that manual gate takes precedence over destructive."""
        # "manual delete" has both manual and destructive patterns
        result = run_script("plan-todo-risk-classify", ["Manual delete operation"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "manual_gate")

    def test_empty_input(self) -> None:
        """Test classification of empty string."""
        result = run_script("plan-todo-risk-classify", [""])
        self.assertEqual(result.returncode, 0)
        # Empty string falls through to normal
        self.assertEqual(result.stdout.strip(), "normal")


class TestMcpResultStoreGenerateBreakpoints(unittest.TestCase):
    """Tests for mcp-result-store-generate-breakpoints.py CLI script."""

    def setUp(self) -> None:
        """Set up test fixtures."""
        self.temp_dir = tempfile.mkdtemp()
        self.addCleanup(self._cleanup_temp_dir)

    def _cleanup_temp_dir(self) -> None:
        """Clean up temporary directory."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _create_test_result_file(self, content: str) -> Path:
        """Create a test result file with given content."""
        temp_path = Path(self.temp_dir) / "test_result.txt"
        temp_path.write_text(content, encoding="utf-8")
        return temp_path

    def test_basic_breakpoint_generation(self) -> None:
        """Test basic breakpoint JSON generation."""
        result_path = self._create_test_result_file("line1\nline2\nline3\n")
        original_s = "100"
        returned_s = "50"
        cap_s = "1000"
        match_json = json.dumps([1, 3])

        result = run_script(
            "mcp-result-store-generate-breakpoints",
            [str(result_path), original_s, returned_s, cap_s, match_json]
        )

        self.assertEqual(result.returncode, 0)
        breakpoints = json.loads(result.stdout)

        # Should have at least start and end (matches may be in middle)
        self.assertGreaterEqual(len(breakpoints), 2)
        self.assertEqual(breakpoints[0]["kind"], "start")
        # The last breakpoint is always "end"
        end_breakpoints = [b for b in breakpoints if b.get("kind") == "end"]
        self.assertEqual(len(end_breakpoints), 1)

    def test_match_cluster_breakpoints(self) -> None:
        """Test breakpoint generation with match clusters."""
        result_path = self._create_test_result_file(
            "first line\nsecond line\nthird line\nfourth line\nfifth line\n"
        )
        original_s = "100"
        returned_s = "50"
        cap_s = "1000"
        # Match cluster from line 2 to line 4
        match_json = json.dumps([{"lineStart": 2, "lineEnd": 4}])

        result = run_script(
            "mcp-result-store-generate-breakpoints",
            [str(result_path), original_s, returned_s, cap_s, match_json]
        )

        self.assertEqual(result.returncode, 0)
        breakpoints = json.loads(result.stdout)

        # Should have matchCluster entry
        cluster_breakpoints = [b for b in breakpoints if b.get("kind") == "matchCluster"]
        self.assertEqual(len(cluster_breakpoints), 1)
        self.assertEqual(cluster_breakpoints[0]["lineStart"], 1)  # 2 - context_lines
        self.assertEqual(cluster_breakpoints[0]["lineEnd"], 5)   # 4 + context_lines

    def test_empty_result_file(self) -> None:
        """Test with empty result file."""
        result_path = self._create_test_result_file("")
        original_s = "0"
        returned_s = "0"
        cap_s = "1000"
        match_json = json.dumps([])

        result = run_script(
            "mcp-result-store-generate-breakpoints",
            [str(result_path), original_s, returned_s, cap_s, match_json]
        )

        self.assertEqual(result.returncode, 0)
        breakpoints = json.loads(result.stdout)
        self.assertGreaterEqual(len(breakpoints), 2)

    def test_invalid_match_entry_skipped(self) -> None:
        """Test that invalid match entries are skipped."""
        result_path = self._create_test_result_file("line1\nline2\n")
        original_s = "50"
        returned_s = "25"
        cap_s = "1000"
        # Include invalid entries
        match_json = json.dumps([
            {"lineStart": 1, "lineEnd": 2},  # valid
            {"lineStart": -1, "lineEnd": 0},  # invalid (negative)
            "not_a_number",  # invalid
            None,  # invalid
        ])

        result = run_script(
            "mcp-result-store-generate-breakpoints",
            [str(result_path), original_s, returned_s, cap_s, match_json]
        )

        self.assertEqual(result.returncode, 0)
        breakpoints = json.loads(result.stdout)
        # Should still work with just the valid entry
        match_breakpoints = [b for b in breakpoints if "match" in b.get("kind", "")]
        self.assertEqual(len(match_breakpoints), 1)

    def test_duplicate_matches_deduplicated(self) -> None:
        """Test that duplicate matches are deduplicated."""
        result_path = self._create_test_result_file("line1\nline2\nline3\n")
        original_s = "50"
        returned_s = "25"
        cap_s = "1000"
        # Duplicate line entries
        match_json = json.dumps([1, 1, 2, 2, 2])

        result = run_script(
            "mcp-result-store-generate-breakpoints",
            [str(result_path), original_s, returned_s, cap_s, match_json]
        )

        self.assertEqual(result.returncode, 0)
        breakpoints = json.loads(result.stdout)
        match_breakpoints = [b for b in breakpoints if b.get("kind") == "match"]
        # Should have only 2 unique matches
        self.assertEqual(len(match_breakpoints), 2)


class TestRuntimeOverlayAbsPath(unittest.TestCase):
    """Tests for runtime-overlay-abs-path.py CLI script."""

    def test_relative_path_converted_to_absolute(self) -> None:
        """Test that relative path is converted to absolute."""
        result = run_script("runtime-overlay-abs-path", ["some/relative/path"])
        self.assertEqual(result.returncode, 0)
        output = result.stdout.strip()
        # Result should be absolute (start with / on Unix)
        self.assertTrue(os.path.isabs(output))
        self.assertIn("some", output)
        self.assertIn("relative", output)
        self.assertIn("path", output)

    def test_already_absolute_path_unchanged(self) -> None:
        """Test that already absolute path is returned as-is."""
        abs_path = "/tmp/test/path"
        result = run_script("runtime-overlay-abs-path", [abs_path])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), abs_path)

    def test_single_dot_path(self) -> None:
        """Test path with single dot."""
        result = run_script("runtime-overlay-abs-path", ["./file.txt"])
        self.assertEqual(result.returncode, 0)
        output = result.stdout.strip()
        self.assertTrue(os.path.isabs(output))
        self.assertTrue(output.endswith("file.txt"))

    def test_parent_directory_path(self) -> None:
        """Test path with parent directory reference."""
        result = run_script("runtime-overlay-abs-path", ["../some/file.txt"])
        self.assertEqual(result.returncode, 0)
        output = result.stdout.strip()
        self.assertTrue(os.path.isabs(output))
        self.assertIn("some", output)

    def test_current_directory(self) -> None:
        """Test current directory."""
        result = run_script("runtime-overlay-abs-path", ["."])
        self.assertEqual(result.returncode, 0)
        output = result.stdout.strip()
        self.assertTrue(os.path.isabs(output))


class TestRuntimeOverlayRelpath(unittest.TestCase):
    """Tests for runtime-overlay-relpath.py CLI script."""

    def test_compute_relative_path(self) -> None:
        """Test computing relative path between workspace and target."""
        workspace = "/home/user/project"
        target = "/home/user/project/src/main.py"
        result = run_script("runtime-overlay-relpath", [workspace, target])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "src/main.py")

    def test_target_is_workspace(self) -> None:
        """Test when target is the same as workspace."""
        workspace = "/home/user/project"
        target = "/home/user/project"
        result = run_script("runtime-overlay-relpath", [workspace, target])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), ".")

    def test_sibling_directories(self) -> None:
        """Test relative path between sibling directories."""
        workspace = "/home/user/project-a"
        target = "/home/user/project-b/file.txt"
        result = run_script("runtime-overlay-relpath", [workspace, target])
        self.assertEqual(result.returncode, 0)
        output = result.stdout.strip()
        # Should be ../project-b/file.txt
        self.assertTrue(output.startswith("../"))
        self.assertIn("project-b", output)

    def test_parent_directory(self) -> None:
        """Test relative path to parent directory."""
        workspace = "/home/user/project/src"
        target = "/home/user/project"
        result = run_script("runtime-overlay-relpath", [workspace, target])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "..")

    def test_relative_workspace_input(self) -> None:
        """Test with relative workspace path."""
        workspace = "./some/workspace"
        target = "/absolute/path/to/file.txt"
        result = run_script("runtime-overlay-relpath", [workspace, target])
        self.assertEqual(result.returncode, 0)
        output = result.stdout.strip()
        # Should still produce a valid relative path
        self.assertIsInstance(output, str)
        self.assertGreater(len(output), 0)

    def test_relative_target_input(self) -> None:
        """Test with relative target path."""
        workspace = "/absolute/workspace"
        target = "./some/relative/file.txt"
        result = run_script("runtime-overlay-relpath", [workspace, target])
        self.assertEqual(result.returncode, 0)
        output = result.stdout.strip()
        # Both get normalized to absolute first, then computed
        self.assertIsInstance(output, str)
        self.assertGreater(len(output), 0)


if __name__ == "__main__":
    unittest.main()
