#!/usr/bin/env python3
"""Unit tests for failure-aware shell output compaction."""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

soc = load_ralph_script("shell-output-compact.py")


def _build_noisy_build_failure() -> str:
    lines = [
        f"Compiling module chunk {index} ..."
        for index in range(60)
    ]
    lines.extend(
        [
            "ERROR: mismatched types at src/main.rs:42:9",
            "expected `i32`, found `&str`",
            "assertion `left == right` failed",
        ]
    )
    lines.extend(
        f"Compiling dependency crate-{index} ..."
        for index in range(60, 100)
    )
    lines.append("SUMMARY: build failed with 1 error")
    return "\n".join(lines)


def _build_npm_failure_without_fail_marker() -> str:
    lines = [f"PASS test/{index}.js" for index in range(50)]
    lines.extend(
        [
            "Error: Cannot find module 'foo'",
            "    at Object.<anonymous> (test/bar.js:10:5)",
        ]
    )
    lines.extend(f"PASS test/{index}.js" for index in range(50, 80))
    return "\n".join(lines)


class TestFailureAwareCompaction(unittest.TestCase):
    """Failure path compacts noisy output while preserving error lines."""

    def test_unwrap_native_shell_wrapper_command_for_classification(self) -> None:
        wrapped = (
            "bash .ralph/bash-lib/native-hook/native-shell-wrapper.sh "
            "--command 'bash scripts/run-bats.sh tests/bats/foo.bats'"
        )
        self.assertEqual(
            soc.classify_command(wrapped),
            soc.classify_command("bash scripts/run-bats.sh tests/bats/foo.bats"),
        )

    def setUp(self) -> None:
        self._prior_opt_out = os.environ.get("RALPH_COMPACT_FAILURE")
        os.environ.pop("RALPH_COMPACT_FAILURE", None)

    def tearDown(self) -> None:
        if self._prior_opt_out is None:
            os.environ.pop("RALPH_COMPACT_FAILURE", None)
        else:
            os.environ["RALPH_COMPACT_FAILURE"] = self._prior_opt_out

    def test_unknown_build_failure_compacts_below_generic_threshold(self) -> None:
        stdout = _build_noisy_build_failure()
        original_bytes = len(stdout.encode("utf-8"))
        self.assertLess(original_bytes, soc._generic_fallback_threshold_bytes())

        result = soc.compact_shell_output("make -j8 all", stdout, "", 1)

        self.assertEqual(result.status, "compacted")
        self.assertEqual(result.family, soc.FAMILY_FAILURE_AWARE)
        self.assertTrue(result.compacted)
        self.assertIn("ERROR: mismatched types at src/main.rs:42:9", result.stdout)
        self.assertIn("SUMMARY: build failed with 1 error", result.stdout)
        self.assertLess(len(result.stdout.encode("utf-8")), original_bytes)

    def test_family_decline_still_compacts_with_error_signal(self) -> None:
        stdout = _build_npm_failure_without_fail_marker()
        original_bytes = len(stdout.encode("utf-8"))

        result = soc.compact_shell_output("npm test", stdout, "", 1)

        self.assertEqual(result.status, "compacted")
        self.assertEqual(result.family, soc.FAMILY_FAILURE_AWARE)
        self.assertIn("Error: Cannot find module 'foo'", result.stdout)
        self.assertLess(len(result.stdout.encode("utf-8")), original_bytes)

    def test_opt_out_passes_raw_failure_output(self) -> None:
        stdout = _build_noisy_build_failure()
        os.environ["RALPH_COMPACT_FAILURE"] = "0"

        result = soc.compact_shell_output("make -j8 all", stdout, "", 1)

        self.assertEqual(result.status, "not compacted")
        self.assertFalse(result.compacted)
        self.assertEqual(result.stdout, stdout)


if __name__ == "__main__":
    unittest.main()
