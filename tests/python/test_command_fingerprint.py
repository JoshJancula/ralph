#!/usr/bin/env python3
"""Unit tests for command_fingerprint.py."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

cf = load_ralph_script("command_fingerprint")


class TestFingerprintMatch(unittest.TestCase):
    """Identical and env-only-differing commands share a fingerprint."""

    def test_identical_commands_match(self) -> None:
        a = cf.fingerprint("bash scripts/run-bats.sh")
        b = cf.fingerprint("bash scripts/run-bats.sh")
        self.assertIsNotNone(a)
        self.assertEqual(a, b)
        self.assertEqual(len(a), 64)

    def test_leading_env_assignments_match(self) -> None:
        a = cf.fingerprint("bash scripts/run-bats.sh")
        b = cf.fingerprint("FOO=1 bash scripts/run-bats.sh")
        c = cf.fingerprint("FOO=1 BAR=2 bash scripts/run-bats.sh")
        self.assertIsNotNone(a)
        self.assertEqual(a, b)
        self.assertEqual(a, c)

    def test_wrapper_env_prefix_match(self) -> None:
        a = cf.fingerprint("pytest tests")
        b = cf.fingerprint("env FOO=1 pytest tests")
        self.assertIsNotNone(a)
        self.assertEqual(a, b)


class TestFingerprintGranularity(unittest.TestCase):
    """Arguments are part of the key (locked granularity decision)."""

    def test_differing_args_do_not_match(self) -> None:
        a = cf.fingerprint("bash scripts/run-bats.sh")
        b = cf.fingerprint("bash scripts/run-bats.sh --filter tooling-profile")
        c = cf.fingerprint("bash scripts/run-bats.sh --filter x")
        self.assertIsNotNone(a)
        self.assertIsNotNone(b)
        self.assertIsNotNone(c)
        self.assertNotEqual(a, b)
        self.assertNotEqual(a, c)
        self.assertNotEqual(b, c)


class TestFingerprintBailShapes(unittest.TestCase):
    """Bail-shaped commands are not fingerprintable."""

    def test_compound_and_returns_none(self) -> None:
        self.assertIsNone(cf.fingerprint("a && b"))
        self.assertIsNone(cf.fingerprint("git status && git log"))

    def test_pipeline_returns_none(self) -> None:
        self.assertIsNone(cf.fingerprint("ls | wc -l"))
        self.assertIsNone(cf.fingerprint("git status | cat"))

    def test_or_and_semicolon_return_none(self) -> None:
        self.assertIsNone(cf.fingerprint("git status || echo failed"))
        self.assertIsNone(cf.fingerprint("git status; git log"))

    def test_background_returns_none(self) -> None:
        self.assertIsNone(cf.fingerprint("sleep 10 &"))
        self.assertIsNone(cf.fingerprint("git status &"))

    def test_subshell_and_substitution_return_none(self) -> None:
        self.assertIsNone(cf.fingerprint("echo $(git status)"))
        self.assertIsNone(cf.fingerprint("echo `git status`"))
        self.assertIsNone(cf.fingerprint("cat <(echo test)"))

    def test_function_definition_returns_none(self) -> None:
        self.assertIsNone(cf.fingerprint("function test() { echo hi; }"))
        self.assertIsNone(cf.fingerprint("test() { echo hi; }"))

    def test_heredoc_returns_none(self) -> None:
        self.assertIsNone(cf.fingerprint("cat <<EOF\ncontent\nEOF"))
        self.assertIsNone(cf.fingerprint("cat <<<string"))

    def test_unsafe_redirect_returns_none(self) -> None:
        self.assertIsNone(cf.fingerprint("echo hi > /tmp/out.txt"))

    def test_empty_and_none_return_none(self) -> None:
        self.assertIsNone(cf.fingerprint(""))
        self.assertIsNone(cf.fingerprint("   "))
        self.assertIsNone(cf.fingerprint(None))  # type: ignore[arg-type]


if __name__ == "__main__":
    unittest.main()
