import json
import os
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PY_DIR = os.path.join(REPO_ROOT, "bundle", ".ralph", "python")
sys.path.insert(0, PY_DIR)

import rubric_contract as rc  # noqa: E402
import rubric_grader as rg  # noqa: E402


def _write(tmp, name, content):
    path = os.path.join(tmp, name)
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)
    return path


def _sample_rubric(*extra_criteria):
    criteria = [
        {
            "id": "doc-exists",
            "description": "artifact exists",
            "required": True,
            "check": {"type": "file_exists", "path": "target.md"},
        }
    ]
    criteria.extend(extra_criteria)
    return {"id": "test-rubric", "description": "test", "criteria": criteria}


class RubricLoadTests(unittest.TestCase):
    def test_valid_rubric_loads(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(tmp, "rubric.json", json.dumps(_sample_rubric()))
            rubric = rg.load_rubric(path)
            self.assertEqual(rubric["id"], "test-rubric")

    def test_missing_criterion_check_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = {"id": "x", "criteria": [{"id": "a", "description": "d", "required": True}]}
            path = _write(tmp, "bad.json", json.dumps(bad))
            with self.assertRaises(rg.RubricGraderError):
                rg.load_rubric(path)


class RubricDeterministicTests(unittest.TestCase):
    def test_file_exists_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            _write(tmp, "target.md", "hello")
            rubric = _sample_rubric()
            outcomes = rg.run_deterministic_checks(rubric, tmp)
            self.assertEqual(len(outcomes), 1)
            self.assertTrue(outcomes[0].satisfied)

    def test_file_exists_fails_when_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            rubric = _sample_rubric()
            outcomes = rg.run_deterministic_checks(rubric, tmp)
            self.assertFalse(outcomes[0].satisfied)

    def test_regex_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            _write(tmp, "target.md", "# Title\nbody")
            rubric = {
                "id": "r",
                "criteria": [
                    {
                        "id": "title",
                        "description": "has title",
                        "required": True,
                        "check": {
                            "type": "regex",
                            "path": "target.md",
                            "pattern": "^# ",
                        },
                    }
                ],
            }
            outcomes = rg.run_deterministic_checks(rubric, tmp)
            self.assertTrue(outcomes[0].satisfied)

    def test_json_pointer_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            _write(tmp, "data.json", '{"status":"ok"}')
            rubric = {
                "id": "r",
                "criteria": [
                    {
                        "id": "status-field",
                        "description": "status present",
                        "required": True,
                        "check": {
                            "type": "json_pointer",
                            "path": "data.json",
                            "pointer": "/status",
                        },
                    }
                ],
            }
            outcomes = rg.run_deterministic_checks(rubric, tmp)
            self.assertTrue(outcomes[0].satisfied)

    def test_command_check_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            rubric = {
                "id": "r",
                "criteria": [
                    {
                        "id": "cmd",
                        "description": "true exits 0",
                        "required": True,
                        "check": {"type": "command", "command": "true"},
                    }
                ],
            }
            outcomes = rg.run_deterministic_checks(rubric, tmp, timeout_secs=5)
            self.assertTrue(outcomes[0].satisfied)

    def test_command_check_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            rubric = {
                "id": "r",
                "criteria": [
                    {
                        "id": "cmd",
                        "description": "false exits non-zero",
                        "required": True,
                        "check": {"type": "command", "command": "false"},
                    }
                ],
            }
            outcomes = rg.run_deterministic_checks(rubric, tmp, timeout_secs=5)
            self.assertFalse(outcomes[0].satisfied)


class RubricMergeTests(unittest.TestCase):
    def _det_outcomes(self, rubric, tmp):
        return rg.run_deterministic_checks(rubric, tmp)

    def test_required_deterministic_failure_forces_changes_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            rubric = _sample_rubric()
            det = self._det_outcomes(rubric, tmp)
            model = {
                "status": "approved",
                "criteria": [{"id": "doc-exists", "satisfied": True}],
                "feedback": [],
            }
            merged = rg.merge_results(rubric, det, model)
            self.assertEqual(merged["status"], "changes-required")
            self.assertTrue(any("doc-exists" in item for item in merged["feedback"]))

    def test_every_criterion_has_explicit_result(self):
        with tempfile.TemporaryDirectory() as tmp:
            _write(tmp, "target.md", "ok")
            rubric = _sample_rubric(
                {
                    "id": "quality",
                    "description": "subjective",
                    "required": False,
                    "check": {
                        "type": "model_judgment",
                        "prompt": "Is it good?",
                    },
                }
            )
            det = self._det_outcomes(rubric, tmp)
            model = {
                "status": "approved",
                "criteria": [
                    {"id": "doc-exists", "satisfied": True},
                    {"id": "quality", "satisfied": True},
                ],
                "feedback": [],
            }
            merged = rg.merge_results(rubric, det, model)
            ids = {item["id"] for item in merged["criteria"]}
            self.assertEqual(ids, {"doc-exists", "quality"})

    def test_deterministic_results_not_overridden_by_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            rubric = _sample_rubric()
            det = self._det_outcomes(rubric, tmp)
            model = {
                "status": "approved",
                "criteria": [{"id": "doc-exists", "satisfied": True}],
                "feedback": [],
            }
            merged = rg.merge_results(rubric, det, model)
            entry = next(item for item in merged["criteria"] if item["id"] == "doc-exists")
            self.assertFalse(entry["satisfied"])


class RubricContractTests(unittest.TestCase):
    def test_changes_required_requires_feedback(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = _write(
                tmp,
                "result.json",
                json.dumps(
                    {
                        "status": "changes-required",
                        "criteria": [{"id": "a", "satisfied": False}],
                        "feedback": [],
                    }
                ),
            )
            with self.assertRaises(rc.RubricContractError):
                rc.load_contract(path)

    def test_feedback_block_includes_criteria(self):
        contract = {
            "status": "changes-required",
            "criteria": [{"id": "a", "satisfied": False, "notes": "missing file"}],
            "feedback": ["fix it"],
        }
        block = rc.render_feedback_block(contract, "grade", "1", "artifacts/grade.json")
        self.assertIn("a", block)
        self.assertIn("not satisfied", block)
        self.assertIn("fix it", block)


if __name__ == "__main__":
    unittest.main()
