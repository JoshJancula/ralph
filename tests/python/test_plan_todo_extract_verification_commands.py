import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))

from plan_todo_extract_verification_commands import (  # noqa: E402
    extract_verification_commands,
    verify_to_complete_command,
)


class PlanTodoExtractVerificationCommandsTests(unittest.TestCase):
    def test_extracts_bash_commands_from_verification_prose(self) -> None:
        text = (
            "Wire savings into CLI.\n"
            "Verification: Run bash bundle/.ralph/usage-report.sh --workspace . "
            "and confirm text output; run bash bundle/.ralph/usage-report.sh "
            "--workspace . --format json and confirm json output."
        )
        commands = extract_verification_commands(text)
        self.assertEqual(
            commands,
            [
                "bash bundle/.ralph/usage-report.sh --workspace .",
                "bash bundle/.ralph/usage-report.sh --workspace . --format json",
            ],
        )
        self.assertEqual(
            verify_to_complete_command(text),
            " && ".join(commands),
        )

    def test_backtick_command_is_allowed(self) -> None:
        text = "Add tests.\nVerification: `bats tests/bats/usage/usage-report.bats`"
        self.assertEqual(
            verify_to_complete_command(text),
            "bats tests/bats/usage/usage-report.bats",
        )


if __name__ == "__main__":
    unittest.main()
