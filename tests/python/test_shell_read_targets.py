#!/usr/bin/env python3
"""Tests for read-only shell file-access extraction.

Capable models inspect files with shell commands rather than read-family tools.
Ralph hashes shell commands, so those reads were invisible to the read-waste
counters -- an invocation reading one file ten times via `cat` scored identically
to one reading ten different files. Measured opus runs did 100% of their file
access this way, which made read-waste unmeasurable for them.

The extraction is deliberately conservative: it returns paths only for an
allowlist of read-only commands, and returns nothing when it cannot prove a read.
A missed read understates waste; a false one would invent it.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script  # noqa: F401  (path setup)

# This module imports its siblings by plain name, so the bundle python dir must be
# importable directly rather than loaded by path.
sys.path.insert(
    0, str(Path(__file__).resolve().parents[2] / "bundle" / ".ralph" / "python")
)
import tool_call_target_telemetry as telemetry
extract = telemetry.extract_shell_read_paths


class ShellReadExtractionTest(unittest.TestCase):
    def test_path_argument_commands(self) -> None:
        self.assertEqual(extract("cat bundle/a.py"), ["bundle/a.py"])
        self.assertEqual(extract("cat a.py b.py"), ["a.py", "b.py"])
        self.assertEqual(extract("wc -l a.py"), ["a.py"])
        self.assertEqual(extract("head -50 a.py"), ["a.py"])

    def test_pattern_first_commands_skip_the_pattern(self) -> None:
        self.assertEqual(extract("grep -n foo bundle/x.sh"), ["bundle/x.sh"])
        self.assertEqual(extract("rg pattern src/main.py"), ["src/main.py"])

    def test_absolute_and_env_prefixed_commands(self) -> None:
        self.assertEqual(extract("/bin/cat a.py"), ["a.py"])
        self.assertEqual(extract("PYTHONPATH=x cat a.py"), ["a.py"])

    def test_pipeline_stages_are_examined_separately(self) -> None:
        self.assertEqual(extract("head -50 a.py | grep foo"), ["a.py"])
        self.assertEqual(extract("cat a.py; cat b.py"), ["a.py", "b.py"])

    def test_repeated_path_in_one_command_is_recorded_once(self) -> None:
        self.assertEqual(extract("cat a.py; cat a.py"), ["a.py"])


class ShellReadRejectionTest(unittest.TestCase):
    """Rejections matter more than happy paths: a false read invents waste."""

    def test_redirect_is_a_write_not_a_read(self) -> None:
        self.assertEqual(extract("cat a.py > b.py"), [])

    def test_sed_in_place_is_a_write(self) -> None:
        self.assertEqual(extract("sed -i s/a/b/ a.py"), [])
        self.assertEqual(extract("sed --in-place=.bak s/a/b/ a.py"), [])

    def test_non_allowlisted_commands_yield_nothing(self) -> None:
        self.assertEqual(extract("rm -rf a.py"), [])
        self.assertEqual(extract("npm test"), [])
        self.assertEqual(extract("python3 script.py"), [])

    def test_pattern_without_a_path_is_not_a_path(self) -> None:
        self.assertEqual(extract("grep -rn TODO"), [])

    def test_unparseable_quoting_is_skipped(self) -> None:
        self.assertEqual(extract('echo "unclosed'), [])

    def test_empty_input(self) -> None:
        self.assertEqual(extract(""), [])
        self.assertEqual(extract("   "), [])

    def test_glob_is_not_treated_as_a_concrete_path(self) -> None:
        self.assertEqual(extract("cat src/*.py"), [])


class ShellReadWindowTest(unittest.TestCase):
    """Paging through a big file is not a redundant read; Read tools already
    distinguish windows via _read_window_suffix and shell reads must match."""

    def test_sed_ranges_produce_distinct_targets(self) -> None:
        first = extract("sed -n '1,50p' a.sh")
        second = extract("sed -n '200,260p' a.sh")
        self.assertEqual(first, ["a.sh:offset=1:limit=50"])
        self.assertNotEqual(first, second)

    def test_whole_file_reads_collide_with_each_other(self) -> None:
        self.assertEqual(extract("cat a.sh"), extract("cat a.sh"))
        self.assertEqual(extract("grep -n x a.sh"), ["a.sh"])


class ShellReadTelemetryIntegrationTest(unittest.TestCase):
    def _record(self, commands: list[str], env_off: bool = False) -> dict:
        acc: dict = telemetry.init_tool_target_telemetry()
        for command in commands:
            telemetry.record_tool_target(acc, "Bash", {"command": command})
        telemetry.finalize_tool_target_telemetry(acc)
        return acc

    def test_shell_rereads_are_counted_as_repeated_reads(self) -> None:
        acc = self._record(
            [
                "cat bundle/core.sh",
                "grep -n usage bundle/core.sh",
                "npm test",
            ]
        )
        self.assertEqual(acc["repeated_read_targets"], 1)
        self.assertEqual(acc["repeated_read_extra_calls"], 1)

    def test_distinct_files_are_not_waste(self) -> None:
        acc = self._record(["cat a.py", "cat b.py"])
        self.assertEqual(acc["repeated_read_extra_calls"], 0)

    def test_command_text_is_never_recorded(self) -> None:
        secret = "cat /etc/passwd && export TOKEN=supersecretvalue"
        acc = self._record([secret])
        blob = str(acc["tool_call_targets"])
        self.assertNotIn("supersecretvalue", blob)
        self.assertNotIn("export TOKEN", blob)

    def test_shell_entry_keeps_its_hash_alongside_the_path(self) -> None:
        acc = self._record(["cat bundle/core.sh"])
        families = [t["family"] for t in acc["tool_call_targets"]]
        self.assertIn("shell", families)
        self.assertIn("read", families)
        shell_target = next(
            t["target"] for t in acc["tool_call_targets"] if t["family"] == "shell"
        )
        self.assertTrue(shell_target.startswith("sha256:"))

    def test_opt_out_disables_extraction(self) -> None:
        import os

        os.environ["RALPH_SHELL_READ_TARGETS"] = "0"
        try:
            acc = self._record(["cat a.py", "cat a.py"])
        finally:
            os.environ.pop("RALPH_SHELL_READ_TARGETS", None)
        self.assertEqual(acc["repeated_read_extra_calls"], 0)
        self.assertNotIn("read", [t["family"] for t in acc["tool_call_targets"]])


if __name__ == "__main__":
    unittest.main()
