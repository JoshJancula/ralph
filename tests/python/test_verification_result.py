import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))

from verification_result import (  # noqa: E402
    line_verification_result,
    text_verification_result,
)


class VerificationResultTests(unittest.TestCase):
    def test_pass_verdict(self) -> None:
        status, reason = text_verification_result(
            "ran the steps\nVERIFICATION_RESULT: PASS\nAGENT_INVOCATION_COMPLETE"
        )
        self.assertEqual(status, "pass")
        self.assertEqual(reason, "")

    def test_todo_verdict_pass(self) -> None:
        status, reason = text_verification_result("TODO_VERIFICATION: PASS")
        self.assertEqual(status, "pass")
        self.assertEqual(reason, "")

    def test_status_verdict_allows_optional_tool_result_ids(self) -> None:
        status, reason = text_verification_result(
            "VERIFICATION STATUS: PASS tool_result_ids=res-123,res-456"
        )
        self.assertEqual(status, "pass")
        self.assertEqual(reason, "tool_result_ids=res-123,res-456")

    def test_fail_verdict_with_reason(self) -> None:
        status, reason = text_verification_result(
            "VERIFICATION_RESULT: FAIL: tsc errored on line 12"
        )
        self.assertEqual(status, "fail")
        self.assertEqual(reason, "tsc errored on line 12")

    def test_todo_verdict_fail_with_reason(self) -> None:
        status, reason = text_verification_result("TODO_VERIFICATION: FAIL: flaky test")
        self.assertEqual(status, "fail")
        self.assertEqual(reason, "flaky test")

    def test_todo_verdict_skipped(self) -> None:
        status, reason = text_verification_result("TODO_VERIFICATION: SKIPPED")
        self.assertEqual(status, "skip")
        self.assertEqual(reason, "")

    def test_no_verdict_is_none(self) -> None:
        status, reason = text_verification_result("did some work, all good")
        self.assertEqual(status, "none")
        self.assertEqual(reason, "")

    def test_last_verdict_wins(self) -> None:
        # An agent that fails, fixes, and re-verifies within one invocation
        # should be reported by its final verdict.
        status, _ = text_verification_result(
            "VERIFICATION_RESULT: FAIL: first try\nfixed it\nVERIFICATION_RESULT: PASS"
        )
        self.assertEqual(status, "pass")

    def test_tolerates_leading_bullet_and_case(self) -> None:
        self.assertEqual(line_verification_result("- verification_result: pass"), ("pass", ""))
        self.assertEqual(line_verification_result("  * VERIFICATION STATUS : FAIL"), ("fail", ""))

    def test_non_matching_line_returns_none(self) -> None:
        self.assertIsNone(line_verification_result("VERIFICATION_RESULT: MAYBE"))
        self.assertIsNone(line_verification_result("the VERIFICATION STATUS: PASS was printed"))

    def test_last_marker_wins_across_both_spellings(self) -> None:
        status, _ = text_verification_result(
            "VERIFICATION STATUS: FAIL: first try\nfixed it\nVERIFICATION_RESULT: PASS"
        )
        self.assertEqual(status, "pass")


if __name__ == "__main__":
    unittest.main()
