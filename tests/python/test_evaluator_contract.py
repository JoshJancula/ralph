import json
import os
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PY_DIR = os.path.join(REPO_ROOT, "bundle", ".ralph", "python")
sys.path.insert(0, PY_DIR)

import evaluator_contract as ec  # noqa: E402


def _write(tmp, name, content):
    path = os.path.join(tmp, name)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)
    return path


class EvaluatorContractLoadTests(unittest.TestCase):
    def test_approved_with_empty_feedback_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(tmp, "ok.json", '{"status":"approved","feedback":[]}')
            contract = ec.load_contract(path)
            self.assertEqual(contract["status"], "approved")
            self.assertEqual(contract["feedback"], [])

    def test_changes_required_with_feedback_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(
                tmp, "cr.json", '{"status":"changes-required","feedback":["fix a","fix b"]}'
            )
            contract = ec.load_contract(path)
            self.assertEqual(contract["status"], "changes-required")
            self.assertEqual(contract["feedback"], ["fix a", "fix b"])

    def test_changes_required_without_feedback_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(tmp, "bad.json", '{"status":"changes-required","feedback":[]}')
            with self.assertRaises(ec.EvaluatorContractError):
                ec.load_contract(path)

    def test_changes_required_with_blank_feedback_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(tmp, "bad.json", '{"status":"changes-required","feedback":["   "]}')
            with self.assertRaises(ec.EvaluatorContractError):
                ec.load_contract(path)

    def test_unknown_status_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(tmp, "bad.json", '{"status":"maybe","feedback":[]}')
            with self.assertRaises(ec.EvaluatorContractError):
                ec.load_contract(path)

    def test_missing_feedback_key_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(tmp, "bad.json", '{"status":"approved"}')
            with self.assertRaises(ec.EvaluatorContractError):
                ec.load_contract(path)

    def test_unknown_property_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(
                tmp, "bad.json", '{"status":"approved","feedback":[],"extra":1}'
            )
            with self.assertRaises(ec.EvaluatorContractError):
                ec.load_contract(path)

    def test_malformed_json_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(tmp, "bad.json", "{not json")
            with self.assertRaises(ec.EvaluatorContractError):
                ec.load_contract(path)

    def test_empty_artifact_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(tmp, "bad.json", "   \n")
            with self.assertRaises(ec.EvaluatorContractError):
                ec.load_contract(path)

    def test_missing_artifact_fails(self):
        with self.assertRaises(ec.EvaluatorContractError):
            ec.load_contract("/nonexistent/evaluator.json")


class EvaluatorFeedbackRenderTests(unittest.TestCase):
    def test_feedback_block_is_byte_preserving_and_ordered(self):
        contract = {"status": "changes-required", "feedback": ["first item", "second item"]}
        block = ec.render_feedback_block(contract, "code-review", "2", "artifacts/cr.json")
        self.assertIn("<!-- RALPH_EVALUATOR_FEEDBACK: START -->", block)
        self.assertIn("<!-- RALPH_EVALUATOR_FEEDBACK: END -->", block)
        self.assertIn("Source stage: `code-review`", block)
        self.assertIn("Iteration: `2`", block)
        self.assertIn("first item", block)
        self.assertIn("second item", block)
        self.assertLess(block.index("first item"), block.index("second item"))

    def test_fence_grows_to_avoid_backtick_breakout(self):
        contract = {"status": "changes-required", "feedback": ["```python\nx=1\n```"]}
        block = ec.render_feedback_block(contract, "s", "1", "a.json")
        # A fence longer than the 3-backtick run inside the feedback must be used.
        self.assertIn("````", block)
        self.assertIn("```python\nx=1\n```", block)

    def test_control_characters_rejected(self):
        contract = {"status": "changes-required", "feedback": ["bad\x00null"]}
        with self.assertRaises(ec.EvaluatorContractError):
            ec.render_feedback_block(contract, "s", "1", "a.json")

    def test_newline_and_tab_preserved(self):
        contract = {"status": "changes-required", "feedback": ["line1\n\tline2"]}
        block = ec.render_feedback_block(contract, "s", "1", "a.json")
        self.assertIn("line1\n\tline2", block)


class EvaluatorContractCliTests(unittest.TestCase):
    def test_status_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(tmp, "cr.json", '{"status":"changes-required","feedback":["x"]}')
            rc = ec.main(["status", "--artifact", path])
            self.assertEqual(rc, 0)

    def test_status_command_invalid_returns_nonzero(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(tmp, "bad.json", '{"status":"changes-required","feedback":[]}')
            rc = ec.main(["status", "--artifact", path])
            self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
