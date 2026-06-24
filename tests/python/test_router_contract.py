#!/usr/bin/env python3
"""Tests for router_contract.py."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
import sys

sys.path.insert(0, str(REPO_ROOT / "bundle/.ralph/python"))

import router_contract as rc  # noqa: E402


class RouterContractTests(unittest.TestCase):
    def test_validate_orchestration_accepts_forward_targets(self) -> None:
        orchestration = {
            "stages": [
                {
                    "id": "router",
                    "router": {
                        "allowedTargets": ["branch-a", "branch-b"],
                        "terminalOutcomes": ["done"],
                        "defaultTarget": "branch-a",
                        "onInvalid": "fail",
                    },
                },
                {"id": "branch-a"},
                {"id": "branch-b"},
                {"id": "tail"},
            ]
        }
        rc.validate_orchestration(orchestration)

    def test_validate_orchestration_rejects_backward_target(self) -> None:
        orchestration = {
            "stages": [
                {"id": "branch-a"},
                {
                    "id": "router",
                    "router": {
                        "allowedTargets": ["branch-a"],
                        "defaultTarget": "branch-a",
                    },
                },
            ]
        }
        with self.assertRaises(rc.RouterContractError):
            rc.validate_orchestration(orchestration)

    def test_resolve_runtime_target_uses_default_on_invalid(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp) / "route.json"
            artifact.write_text(
                json.dumps({"target": "unknown", "reason": "bad", "confidence": 0.2}),
                encoding="utf-8",
            )
            router = {
                "allowedTargets": ["branch-a", "branch-b"],
                "defaultTarget": "branch-b",
                "onInvalid": "default",
            }
            target, kind = rc.resolve_runtime_target(
                {"target": "unknown", "reason": "bad", "confidence": 0.2},
                router,
                stage_index=0,
                all_ids=["router", "branch-a", "branch-b"],
                waves=[],
            )
            self.assertEqual(target, "branch-b")
            self.assertEqual(kind, "default-stage")


if __name__ == "__main__":
    unittest.main()
