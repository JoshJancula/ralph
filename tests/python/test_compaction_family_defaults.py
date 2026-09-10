#!/usr/bin/env python3
"""Characterization tests locking down current compaction family behavior.

For each family id represented in `_CORE_FAMILY_REGISTRY`, this feeds a small
representative stdout fixture through `compact_shell_output` (exit_status 0)
and asserts the resulting `family` and `status` against an explicit expected
table. These assertions capture *current, pre-change* behavior; they are a
deliberate tripwire so any later behavior change shows up as an intentional
diff to this file, not a silent regression.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

soc = load_ralph_script("shell-output-compact.py")


def _find_fixture() -> tuple[str, str]:
    command = "find . -name '*.py'"
    stdout = "\n".join(f"./src/file{i}.py" for i in range(30))
    return command, stdout


def _ls_fixture() -> tuple[str, str]:
    command = "ls -la"
    stdout = "\n".join(f"file{i}.txt" for i in range(30))
    return command, stdout


def _tree_fixture() -> tuple[str, str]:
    command = "tree"
    stdout = "\n".join(f"    file{i}.txt" for i in range(100))
    return command, stdout


def _git_status_fixture() -> tuple[str, str]:
    command = "git status"
    stdout = "\n".join(f" M src/file{i}.py" for i in range(100))
    return command, stdout


def _bats_fixture() -> tuple[str, str]:
    command = "bats tests/bats/foo.bats"
    stdout = "\n".join(f"ok {i} - test case {i}" for i in range(1, 30)) + "\n1..29"
    return command, stdout


def _pytest_fixture() -> tuple[str, str]:
    command = "pytest tests/python/test_foo.py -q"
    stdout = "collected 30 items\n" + ("=" * 10) + " 30 passed in 1.23s " + ("=" * 10)
    return command, stdout


def _npm_install_fixture() -> tuple[str, str]:
    command = "npm install"
    stdout = "\n".join(f"added package-{i}" for i in range(30)) + "\nadded 30 packages in 2s"
    return command, stdout


def _unclassified_fixture() -> tuple[str, str]:
    command = "echo hello world"
    stdout = "hello world\n"
    return command, stdout


# Explicit expected table: family_id (test label) -> (fixture builder, expected
# result.family, expected result.status). These values are the *current*
# behavior of compact_shell_output at exit_status 0 and must only change when
# a TODO deliberately updates them alongside a behavior change.
_EXPECTED_TABLE: dict[str, tuple[object, str | None, str]] = {
    "find": (_find_fixture, None, "not compacted"),
    "ls": (_ls_fixture, None, "not compacted"),
    "tree": (_tree_fixture, None, "not compacted"),
    "git_status": (_git_status_fixture, soc.FAMILY_GIT_STATUS, "compacted"),
    "bats": (_bats_fixture, soc.FAMILY_BATS, "compacted"),
    "pytest": (_pytest_fixture, soc.FAMILY_PYTEST, "compacted"),
    "npm_install": (_npm_install_fixture, soc.FAMILY_NPM_INSTALL, "compacted"),
    "unclassified": (_unclassified_fixture, None, "not compacted"),
}


class TestCompactionFamilyDefaults(unittest.TestCase):
    """Tripwire: current family/status outcomes for representative fixtures."""

    def test_family_ids_are_present_in_core_registry(self) -> None:
        core_family_ids = {entry.family_id for entry in soc._CORE_FAMILY_REGISTRY}
        for label, (_builder, expected_family, _status) in _EXPECTED_TABLE.items():
            if expected_family is None:
                continue
            self.assertIn(
                expected_family,
                core_family_ids,
                f"{label}: family {expected_family!r} missing from _CORE_FAMILY_REGISTRY",
            )

    def test_expected_family_and_status_per_fixture(self) -> None:
        for label, (builder, expected_family, expected_status) in _EXPECTED_TABLE.items():
            with self.subTest(label=label):
                command, stdout = builder()
                result = soc.compact_shell_output(command, stdout, "", 0)
                self.assertEqual(
                    result.family,
                    expected_family,
                    f"{label}: expected family {expected_family!r}, got {result.family!r}",
                )
                self.assertEqual(
                    result.status,
                    expected_status,
                    f"{label}: expected status {expected_status!r}, got {result.status!r}",
                )


if __name__ == "__main__":
    unittest.main()
