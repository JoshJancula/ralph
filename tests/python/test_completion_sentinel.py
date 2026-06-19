import json
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))

from completion_sentinel import (  # noqa: E402
    line_has_completion_sentinel,
    object_has_assistant_completion_sentinel,
    text_has_completion_sentinel,
)


class CompletionSentinelTests(unittest.TestCase):
    def test_exact_line_matches(self) -> None:
        self.assertTrue(line_has_completion_sentinel("AGENT_INVOCATION_COMPLETE"))
        self.assertTrue(line_has_completion_sentinel("* AGENT_INVOCATION_COMPLETE"))
        self.assertTrue(line_has_completion_sentinel("TODO_COMPLETION: COMPLETE"))
        self.assertTrue(line_has_completion_sentinel("  - TODO_COMPLETION: COMPLETE"))

    def test_glued_suffix_does_not_match(self) -> None:
        self.assertFalse(
            line_has_completion_sentinel("AGENT_INVOCATION_COMPLETEEarlier note")
        )
        self.assertFalse(
            line_has_completion_sentinel("* AGENT_INVOCATION_COMPLETEEarlier note")
        )
        self.assertFalse(line_has_completion_sentinel("TODO_COMPLETION: COMPLETEEarlier note"))

    def test_substring_in_prose_does_not_match(self) -> None:
        text = "Docs mention AGENT_INVOCATION_COMPLETE in passing."
        self.assertFalse(text_has_completion_sentinel(text))

    def test_assistant_text_counts_but_tool_result_does_not(self) -> None:
        assistant = {
            "type": "assistant",
            "message": {
                "content": [
                    {
                        "type": "text",
                        "text": "Done.\nAGENT_INVOCATION_COMPLETE\n",
                    }
                ]
            },
        }
        tool_result = {
            "type": "user",
            "message": {
                "content": [
                    {
                        "type": "tool_result",
                        "content": "AGENT_INVOCATION_COMPLETE\n",
                    }
                ]
            },
        }
        self.assertTrue(object_has_assistant_completion_sentinel(assistant, "claude"))
        self.assertFalse(object_has_assistant_completion_sentinel(tool_result, "claude"))

    def test_result_payload_matches(self) -> None:
        payload = {
            "type": "result",
            "result": "done\nTODO_COMPLETION: COMPLETE\n",
        }
        self.assertTrue(object_has_assistant_completion_sentinel(payload, "cursor"))


if __name__ == "__main__":
    unittest.main()
