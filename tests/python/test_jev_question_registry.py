#!/usr/bin/env python3
"""Shape enforcement for bundle/.ralph/jev/questions.registry.json.

bundle/.ralph/schemas/jev-question-set.schema.json cannot express the per-type
criteria shape: Ralph's homegrown validator (artifact_json_schema.py) supports
only a small keyword subset, and allOf/if/then are not in it. That constraint
lives here instead, so dropping it from the schema loses no coverage.

SystemOne's own contract, which these assertions mirror:
  choice -> criteria is an object of option id -> description
  score  -> criteria is a legend: an array of at least two labels
  noul   -> criteria is optional; when present it holds only true/false labels

A choice set may declare an EMPTY criteria object on purpose: its options are
supplied at call time (router allowedTargets, tagged compaction line ids).
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
REGISTRY = REPO_ROOT / "bundle" / ".ralph" / "jev" / "questions.registry.json"

VALID_TYPES = {"noul", "choice", "score"}


def _registry() -> dict:
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


class JevQuestionRegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.data = _registry()
        self.sets = self.data.get("questionSets") or {}
        self.assertIsInstance(self.sets, dict)
        self.assertTrue(self.sets, "registry declares no question sets")

    def test_registry_version_is_a_string(self) -> None:
        self.assertIsInstance(self.data.get("registryVersion"), str)

    def test_every_set_key_matches_its_id(self) -> None:
        for key, qset in self.sets.items():
            with self.subTest(question_set=key):
                self.assertEqual(qset.get("id"), key)

    def test_primary_question_exists_in_the_set(self) -> None:
        for key, qset in self.sets.items():
            with self.subTest(question_set=key):
                primary = qset.get("policy", {}).get("primaryQuestion")
                self.assertIn(primary, qset.get("questions", {}))

    def test_act_threshold_is_above_escalate_threshold(self) -> None:
        for key, qset in self.sets.items():
            with self.subTest(question_set=key):
                policy = qset.get("policy", {})
                self.assertGreater(policy["actThreshold"], policy["escalateThreshold"])

    def test_criteria_shape_matches_the_question_type(self) -> None:
        for key, qset in self.sets.items():
            for qid, qdef in (qset.get("questions") or {}).items():
                with self.subTest(question_set=key, question=qid):
                    qtype = qdef.get("type")
                    self.assertIn(qtype, VALID_TYPES)
                    self.assertIsInstance(qdef.get("instructions"), str)
                    criteria = qdef.get("criteria")

                    if qtype == "choice":
                        self.assertIsInstance(
                            criteria, dict, "choice criteria must be an object"
                        )
                        # Empty is legal: options are supplied at call time.
                        for opt, desc in criteria.items():
                            self.assertIsInstance(opt, str)
                            self.assertTrue(opt, "choice option id must be non-empty")
                            self.assertIsInstance(desc, str)
                        self.assertLessEqual(
                            len(criteria), 255, "choice caps at 255 options per request"
                        )
                    elif qtype == "score":
                        self.assertIsInstance(
                            criteria, list, "score criteria must be a legend array"
                        )
                        self.assertGreaterEqual(len(criteria), 2)
                        for label in criteria:
                            self.assertIsInstance(label, str)
                    else:  # noul
                        if criteria is not None:
                            self.assertIsInstance(criteria, dict)
                            self.assertLessEqual(set(criteria), {"true", "false"})
                            for label in criteria.values():
                                self.assertIsInstance(label, str)

    def test_a_call_time_choice_set_is_reachable_only_with_supplied_options(self) -> None:
        """A choice with empty criteria must be filled before it can be sent.

        SystemOne rejects a choice question carrying zero options, so any set in
        this state is one whose caller is required to supply them.
        """
        for key, qset in self.sets.items():
            primary = qset.get("policy", {}).get("primaryQuestion")
            qdef = (qset.get("questions") or {}).get(primary) or {}
            if qdef.get("type") != "choice":
                continue
            if qdef.get("criteria"):
                continue
            with self.subTest(question_set=key):
                self.assertEqual(
                    qdef.get("criteria"),
                    {},
                    "a call-time choice set must declare criteria as {}, not omit it",
                )


if __name__ == "__main__":
    unittest.main()
