#!/usr/bin/env python3
"""Unit tests for mcp_proxy_result_reduce.py."""

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

import mcp_proxy_result_reduce as rr  # noqa: E402


class ResultReduceGateTests(unittest.TestCase):
    def test_enabled_in_hybrid_by_default(self) -> None:
        self.assertTrue(rr.result_reduce_enabled(ralph_mode="hybrid"))

    def test_disabled_in_native_by_default(self) -> None:
        self.assertFalse(rr.result_reduce_enabled(ralph_mode="native"))

    def test_explicit_opt_in_native(self) -> None:
        self.assertTrue(rr.result_reduce_enabled(explicit="1", ralph_mode="native"))

    def test_explicit_opt_out_hybrid(self) -> None:
        self.assertFalse(rr.result_reduce_enabled(explicit="0", ralph_mode="hybrid"))


class ResultReduceValidationTests(unittest.TestCase):
    def test_jq_rejects_system(self) -> None:
        with self.assertRaises(rr.ReduceError):
            rr.validate_jq_expression('map(select(. > 0)) | system("id")')

    def test_awk_rejects_getline(self) -> None:
        with self.assertRaises(rr.ReduceError):
            rr.validate_awk_program("getline < \"/etc/passwd\"")

    def test_grep_rejects_multiline_pattern(self) -> None:
        with self.assertRaises(rr.ReduceError):
            rr.validate_grep_pattern("line1\nline2")


class ResultReduceExecutionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.input_path = Path(self.tmp.name) / "input.txt"
        self.input_path.write_text(
            "\n".join(
                [
                    '{"items":[{"name":"alpha"},{"name":"beta"}]}',
                    "ERROR: something failed",
                    "INFO: ok",
                ]
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _request(self, **overrides: object) -> dict:
        base = {
            "inputPath": str(self.input_path),
            "reducer": "grep",
            "expression": "ERROR",
            "grep": {"lineNumber": True},
            "limits": {
                "timeoutSeconds": 5,
                "maxOutputBytes": 4096,
                "maxOutputLines": 100,
                "maxInputBytes": 1_000_000,
            },
        }
        base.update(overrides)
        return base

    @unittest.skipUnless(os.environ.get("PATH") and __import__("shutil").which("jq"), "jq required")
    def test_jq_reduction(self) -> None:
        self.input_path.write_text(
            json.dumps({"items": [{"name": "alpha"}, {"name": "beta"}]}),
            encoding="utf-8",
        )
        result = rr.reduce_text(
            self._request(
                reducer="jq",
                expression=".items[].name",
            )
        )
        self.assertIn("alpha", result["output"])
        self.assertIn("beta", result["output"])
        self.assertFalse(result["truncated"])

    @unittest.skipUnless(__import__("shutil").which("grep"), "grep required")
    def test_grep_reduction(self) -> None:
        result = rr.reduce_text(self._request(reducer="grep", expression="ERROR", grep={"lineNumber": True}))
        self.assertIn("ERROR", result["output"])
        self.assertNotIn("INFO", result["output"])

    @unittest.skipUnless(__import__("shutil").which("awk"), "awk required")
    def test_safe_awk_reduction(self) -> None:
        result = rr.reduce_text(
            self._request(
                reducer="awk",
                expression='/^INFO/ { print $2 }',
            )
        )
        self.assertIn("ok", result["output"])

    def test_jq_injection_rejected(self) -> None:
        with self.assertRaises(rr.ReduceError):
            rr.reduce_text(self._request(reducer="jq", expression='@include "secret"'))

    def test_awk_file_access_rejected(self) -> None:
        with self.assertRaises(rr.ReduceError):
            rr.reduce_text(self._request(reducer="awk", expression='{ while ((getline line < "/etc/passwd") > 0) print line }'))

    def test_output_line_limit(self) -> None:
        many_lines = "\n".join(f"line-{i}" for i in range(20))
        self.input_path.write_text(many_lines, encoding="utf-8")
        result = rr.reduce_text(
            self._request(
                reducer="grep",
                expression="line",
                limits={
                    "timeoutSeconds": 5,
                    "maxOutputBytes": 4096,
                    "maxOutputLines": 3,
                    "maxInputBytes": 1_000_000,
                },
            )
        )
        self.assertTrue(result["truncated"])
        self.assertLessEqual(len(result["output"].splitlines()), 3)


if __name__ == "__main__":
    unittest.main()
