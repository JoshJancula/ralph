#!/usr/bin/env python3
"""Unit tests for failure-aware shell output compaction."""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
_REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_REPO_ROOT / "bundle" / ".ralph" / "python"))

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


def _build_large_unknown_failure() -> str:
    """Unknown-family failure large enough for the Jev compaction tier."""
    filler = "detail chunk padding " + ("x" * 80)
    lines = [f"{filler} seq={index}" for index in range(120)]
    lines.insert(60, "ERROR: deliberate preserve-line signal at src/core.rs:9")
    lines.append("SUMMARY: build failed with 1 error")
    text = "\n".join(lines)
    # Ensure we are above the generic/Jev size threshold.
    while len(text.encode("utf-8")) <= soc._generic_fallback_threshold_bytes():
        lines.append(f"{filler} pad={len(lines)}")
        text = "\n".join(lines)
    return text


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
        self._prior_jev_compact = os.environ.get("RALPH_JEV_COMPACT")
        os.environ.pop("RALPH_JEV_COMPACT", None)

    def tearDown(self) -> None:
        if self._prior_opt_out is None:
            os.environ.pop("RALPH_COMPACT_FAILURE", None)
        else:
            os.environ["RALPH_COMPACT_FAILURE"] = self._prior_opt_out
        if self._prior_jev_compact is None:
            os.environ.pop("RALPH_JEV_COMPACT", None)
        else:
            os.environ["RALPH_JEV_COMPACT"] = self._prior_jev_compact

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


class TestJevAdvisoryValidation(unittest.TestCase):
    """Jev candidates are advisory: local gates reject bad output."""

    PRESERVE_LINE = "ERROR: deliberate preserve-line signal at src/core.rs:9"

    def setUp(self) -> None:
        self._prior = {
            key: os.environ.get(key)
            for key in (
                "RALPH_JEV_COMPACT",
                "RALPH_COMPACT_FAILURE",
                "RALPH_COMPACT_GENERIC_FALLBACK",
            )
        }
        os.environ["RALPH_JEV_COMPACT"] = "1"
        os.environ.pop("RALPH_COMPACT_FAILURE", None)
        os.environ.pop("RALPH_COMPACT_GENERIC_FALLBACK", None)
        self._fake_jev = types.SimpleNamespace(available=lambda: True)
        self._modules_patcher = mock.patch.dict(
            sys.modules, {"jev_client": self._fake_jev}
        )
        self._modules_patcher.start()

    def tearDown(self) -> None:
        self._modules_patcher.stop()
        for key, value in self._prior.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _run_with_jev_body(self, stdout: str, body: str, exit_status: int = 1):
        rankings = {"L000": 0.9}
        with mock.patch.object(
            soc, "_jev_rank_surviving_lines", return_value=rankings
        ), mock.patch.object(
            soc, "_format_jev_ranked_output", return_value=body
        ):
            return soc.compact_shell_output("make -j8 all", stdout, "", exit_status)

    def test_jev_candidate_missing_preserve_line_falls_back_to_deterministic(
        self,
    ) -> None:
        stdout = _build_large_unknown_failure()
        self.assertIn(self.PRESERVE_LINE, stdout)
        # Smaller than original but deliberately omits the preserve-line.
        bad_body = "\n".join(
            [
                "jev ranked (exit 1): advisory candidate missing preserve-line",
                "noise head",
                "noise middle",
                "noise tail",
            ]
        )
        self.assertNotIn(self.PRESERVE_LINE, bad_body)
        self.assertLess(len(bad_body.encode("utf-8")), len(stdout.encode("utf-8")))

        result = self._run_with_jev_body(stdout, bad_body, exit_status=1)

        self.assertNotEqual(result.family, soc.FAMILY_JEV_RANKED)
        self.assertEqual(result.status, "compacted")
        self.assertEqual(result.family, soc.FAMILY_FAILURE_AWARE)
        self.assertIn(self.PRESERVE_LINE, result.stdout)

    def test_jev_candidate_larger_than_original_is_rejected(self) -> None:
        stdout = _build_large_unknown_failure()
        larger_body = stdout + "\n" + ("extra padding " * 40)
        self.assertGreater(
            len(larger_body.encode("utf-8")), len(stdout.encode("utf-8"))
        )

        result = self._run_with_jev_body(stdout, larger_body, exit_status=1)

        self.assertNotEqual(result.family, soc.FAMILY_JEV_RANKED)
        self.assertEqual(result.family, soc.FAMILY_FAILURE_AWARE)
        self.assertIn(self.PRESERVE_LINE, result.stdout)

    def test_empty_jev_candidate_is_rejected(self) -> None:
        stdout = _build_large_unknown_failure()

        result = self._run_with_jev_body(stdout, "", exit_status=1)

        self.assertNotEqual(result.family, soc.FAMILY_JEV_RANKED)
        self.assertEqual(result.family, soc.FAMILY_FAILURE_AWARE)
        self.assertIn(self.PRESERVE_LINE, result.stdout)


class TestJevSourceExclusions(unittest.TestCase):
    """SOURCE_OUTPUT_FAMILIES and denylist stay hard passthrough under Jev."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.mkdtemp(prefix="ralph-jev-source-excl.")
        self.addCleanup(shutil.rmtree, self._tmpdir, ignore_errors=True)
        self._prior = {
            key: os.environ.get(key)
            for key in (
                "RALPH_JEV_COMPACT",
                "RALPH_JEV",
                "JEV_TRANSPORT",
                "JEV_FIXTURE_DIR",
                "TYPESAFE_API_KEY",
                "RALPH_JEV_STATE_DIR",
                "RALPH_COMPACT_FAILURE",
                "RALPH_COMPACT_GENERIC_FALLBACK",
            )
        }
        os.environ["RALPH_JEV_COMPACT"] = "1"
        os.environ["RALPH_JEV"] = "1"
        os.environ["JEV_TRANSPORT"] = "fixture"
        os.environ["JEV_FIXTURE_DIR"] = str(_REPO_ROOT / "tests" / "fixtures" / "jev")
        os.environ["TYPESAFE_API_KEY"] = "test-key-for-fixture-transport"
        os.environ["RALPH_JEV_STATE_DIR"] = os.path.join(self._tmpdir, "jev-state")
        os.makedirs(os.environ["RALPH_JEV_STATE_DIR"], exist_ok=True)
        os.environ.pop("RALPH_COMPACT_FAILURE", None)
        os.environ.pop("RALPH_COMPACT_GENERIC_FALLBACK", None)

        # Real jev_client with fixture transport must report available.
        import jev_client as _jev_client

        self.assertTrue(
            _jev_client.available(),
            f"fixture transport unavailable: {_jev_client.unavailable_reason()}",
        )

    def tearDown(self) -> None:
        for key, value in self._prior.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    @staticmethod
    def _large_git_diff_stdout() -> str:
        lines = [
            "diff --git a/bundle/.ralph/python/shell-output-compact.py "
            "b/bundle/.ralph/python/shell-output-compact.py",
            "index 1111111..2222222 100644",
            "--- a/bundle/.ralph/python/shell-output-compact.py",
            "+++ b/bundle/.ralph/python/shell-output-compact.py",
        ]
        for index in range(200):
            lines.append(f"@@ -{index},3 +{index},4 @@")
            lines.append(f" context line {index}")
            lines.append(f"-removed line {index}")
            lines.append(f"+added line {index} with payload padding {'x' * 40}")
        text = "\n".join(lines)
        while len(text.encode("utf-8")) <= soc._generic_fallback_threshold_bytes():
            lines.append(f"+pad {len(lines)} {'y' * 60}")
            text = "\n".join(lines)
        return text

    @staticmethod
    def _large_grep_stdout() -> str:
        lines = [
            f"bundle/.ralph/bash-lib/foo.sh:{index}:match proxy pattern {index} "
            f"{'z' * 40}"
            for index in range(200)
        ]
        text = "\n".join(lines)
        while len(text.encode("utf-8")) <= soc._generic_fallback_threshold_bytes():
            lines.append(
                f"bundle/.ralph/bash-lib/bar.sh:{len(lines)}:proxy pad {'w' * 60}"
            )
            text = "\n".join(lines)
        return text

    def test_git_diff_byte_identical_with_jev_fixture_transport(self) -> None:
        stdout = self._large_git_diff_stdout()
        with mock.patch.object(
            soc,
            "_jev_rank_surviving_lines",
            side_effect=AssertionError("Jev consulted"),
        ):
            result = soc.compact_shell_output("git diff HEAD~1", stdout, "", 0)

        self.assertEqual(result.stdout, stdout)
        self.assertEqual(result.stderr, "")
        self.assertFalse(result.compacted)
        self.assertEqual(result.status, "not compacted")
        self.assertEqual(result.family, soc.FAMILY_GIT_DIFF)
        self.assertEqual(result.stdout.encode("utf-8"), stdout.encode("utf-8"))

    def test_grep_byte_identical_with_jev_fixture_transport(self) -> None:
        stdout = self._large_grep_stdout()
        with mock.patch.object(
            soc,
            "_jev_rank_surviving_lines",
            side_effect=AssertionError("Jev consulted"),
        ):
            result = soc.compact_shell_output(
                "grep -rn proxy bundle/.ralph/bash-lib", stdout, "", 0
            )

        self.assertEqual(result.stdout, stdout)
        self.assertEqual(result.stderr, "")
        self.assertFalse(result.compacted)
        self.assertEqual(result.status, "not compacted")
        self.assertEqual(result.family, soc.FAMILY_GREP)
        self.assertEqual(result.stdout.encode("utf-8"), stdout.encode("utf-8"))


if __name__ == "__main__":
    unittest.main()
