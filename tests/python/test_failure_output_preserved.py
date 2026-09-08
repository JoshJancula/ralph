#!/usr/bin/env python3
"""Failing test/build output must never lose a distinct failure identifier.

These fixtures mirror real pytest, bats, and tsc failure output. Each
asserts that every distinct failing test name or error code present in the
raw output is still present after compaction, covering both the dedicated
family compactors (_compact_pytest, _compact_bats, _compact_tsc) and the
generic failure-aware fallback that guards unmatched commands.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

soc = load_ralph_script("shell-output-compact.py")


def _build_pytest_failure(num_failures: int = 3) -> str:
    lines = ["============================= test session starts =============================="]
    lines.extend(f"tests/test_module.py::test_pass_{i} PASSED" for i in range(20))
    lines.append("=================================== FAILURES ===================================")
    for i in range(num_failures):
        lines.append(f"________________________________ test_case_{i} _________________________________")
        lines.append(f"    assert {i} == {i + 1}")
        lines.append(f"AssertionError: assert {i} == {i + 1}")
    lines.append("=========================== short test summary info ============================")
    for i in range(num_failures):
        lines.append(
            f"FAILED tests/test_module.py::test_case_{i} - AssertionError: assert {i} == {i + 1}"
        )
    lines.append(f"===================== {num_failures} failed, 20 passed in 1.23s ======================")
    return "\n".join(lines)


def _build_bats_failure() -> str:
    lines = ["1..4"]
    lines.append("ok 1 first passing test")
    lines.append("not ok 2 second test explodes")
    lines.append("# (in test file tests/bats/foo.bats, line 12)")
    lines.append("#   `run bad_command' failed with status 1")
    lines.append("ok 3 third passing test")
    lines.append("not ok 4 fourth test explodes too")
    lines.append("# (in test file tests/bats/foo.bats, line 30)")
    lines.append("#   `run other_bad_command' failed with status 2")
    return "\n".join(lines)


def _build_tsc_failure() -> str:
    lines = ["Version 5.4.2"]
    lines.append("src/foo.ts(10,5): error TS2322: Type 'string' is not assignable to type 'number'.")
    lines.append("src/bar.ts(22,14): error TS2554: Expected 1 arguments, but got 2.")
    lines.append("src/baz.ts(3,1): error TS2307: Cannot find module './missing'.")
    lines.append("Found 3 errors.")
    return "\n".join(lines)


class TestPytestFailureIdentifiersPreserved(unittest.TestCase):
    def test_all_failing_test_names_survive_compaction(self) -> None:
        raw = _build_pytest_failure(num_failures=3)
        stdout_out, _stderr_out, did = soc._compact_pytest("python3 -m pytest -q", raw, "", 1)
        self.assertTrue(did)
        for i in range(3):
            identifier = f"tests/test_module.py::test_case_{i}"
            self.assertIn(
                identifier,
                stdout_out,
                f"missing failing test identifier {identifier!r} in compacted output",
            )

    def test_large_failure_count_is_not_truncated(self) -> None:
        # Regression guard: the compactor previously capped failed test
        # lines at 30 and dropped the remainder behind a "... N more" note.
        raw = _build_pytest_failure(num_failures=45)
        stdout_out, _stderr_out, did = soc._compact_pytest("python3 -m pytest -q", raw, "", 1)
        self.assertTrue(did)
        for i in range(45):
            identifier = f"tests/test_module.py::test_case_{i}"
            self.assertIn(identifier, stdout_out)
        self.assertNotIn("more failed test(s)", stdout_out)


class TestBatsFailureIdentifiersPreserved(unittest.TestCase):
    def test_all_failing_test_names_survive_compaction(self) -> None:
        raw = _build_bats_failure()
        stdout_out, _stderr_out, did = soc._compact_bats("bats tests/bats/foo.bats", raw, "", 1)
        self.assertTrue(did)
        self.assertIn("not ok 2 second test explodes", stdout_out)
        self.assertIn("not ok 4 fourth test explodes too", stdout_out)


class TestTscFailureIdentifiersPreserved(unittest.TestCase):
    def test_all_error_codes_survive_compaction(self) -> None:
        raw = _build_tsc_failure()
        stdout_out, _stderr_out, did = soc._compact_tsc("npx tsc --noEmit", raw, "", 1)
        self.assertTrue(did)
        for code in ("TS2322", "TS2554", "TS2307"):
            self.assertIn(code, stdout_out, f"missing tsc error code {code!r}")

    def test_large_error_count_is_not_truncated(self) -> None:
        # Regression guard: the compactor previously capped error lines at
        # 20 and dropped the remainder behind a "... N more" note.
        lines = ["Version 5.4.2"]
        for i in range(35):
            lines.append(
                f"src/file{i}.ts({i},1): error TS9{i:03d}: synthetic error {i}."
            )
        lines.append("Found 35 errors.")
        raw = "\n".join(lines)
        stdout_out, _stderr_out, did = soc._compact_tsc("npx tsc --noEmit", raw, "", 1)
        self.assertTrue(did)
        for i in range(35):
            self.assertIn(f"TS9{i:03d}", stdout_out)
        self.assertNotIn("more error(s)", stdout_out)


class TestCompactShellOutputEndToEnd(unittest.TestCase):
    """Exercise the same fixtures through the public dispatch entry point."""

    def test_pytest_via_compact_shell_output(self) -> None:
        raw = _build_pytest_failure(num_failures=3)
        result = soc.compact_shell_output("pytest -q", raw, "", 1)
        for i in range(3):
            self.assertIn(f"test_case_{i}", result.stdout)

    def test_bats_via_compact_shell_output(self) -> None:
        raw = _build_bats_failure()
        result = soc.compact_shell_output("bats tests/bats/foo.bats", raw, "", 1)
        self.assertIn("not ok 2 second test explodes", result.stdout)
        self.assertIn("not ok 4 fourth test explodes too", result.stdout)

    def test_tsc_via_compact_shell_output(self) -> None:
        raw = _build_tsc_failure()
        result = soc.compact_shell_output("tsc --noEmit", raw, "", 1)
        for code in ("TS2322", "TS2554", "TS2307"):
            self.assertIn(code, result.stdout)


if __name__ == "__main__":
    unittest.main()
