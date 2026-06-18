import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PLAN_SPLIT = REPO_ROOT / "bundle" / ".ralph" / "python" / "plan-split.py"


def post_verify_command(todo_text: str) -> subprocess.CompletedProcess:
    # plan-split.py has a hyphen in its name and is invoked as a script, so it is
    # exercised through its CLI rather than imported.
    return subprocess.run(
        [sys.executable, str(PLAN_SPLIT), "post-verify-command", "--todo", todo_text],
        capture_output=True,
        text=True,
    )


class PostVerifyCommandGuardedTests(unittest.TestCase):
    def test_prose_only_verification_yields_no_command(self) -> None:
        # Regression for the savings-feature stall: descriptive prose with
        # parentheses must NOT be returned as a runnable command.
        todo = (
            "Add the /api/savings endpoint.\n"
            "Verification: Build/start the dashboard server and hit /api/savings; "
            "confirm it returns a savings payload (e.g. npm run build or the "
            "project's existing check) and confirm it passes."
        )
        result = post_verify_command(todo)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")

    def test_strict_verify_command_is_emitted(self) -> None:
        todo = (
            "Add tests.\n"
            "Verification: Run the regression checks and confirm they pass.\n"
            "Verify: bash scripts/run-python-unit-tests.sh"
        )
        result = post_verify_command(todo)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "bash scripts/run-python-unit-tests.sh")

    def test_backticks_in_prose_do_not_emit_partial_command(self) -> None:
        todo = (
            "Finish the usage panel.\n"
            "Verification: Run the UI checks and confirm the page looks correct; "
            "for example `bats -T tests/bats/run-plan/run-plan-verify-gate.bats` "
            "should not be scraped out of this prose."
        )
        result = post_verify_command(todo)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")

    def test_invalid_strict_verify_fragment_is_not_returned(self) -> None:
        todo = "Sync state.\nVerify: bats -T"
        result = post_verify_command(todo)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")

    def test_blocked_command_is_not_returned(self) -> None:
        todo = "Sync state.\nVerify: git push origin main"
        result = post_verify_command(todo)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
