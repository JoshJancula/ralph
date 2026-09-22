"""Rework TODO synthesis from the defect ledger."""

import os
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_PY_DIR = os.path.normpath(os.path.join(_HERE, "..", "..", "bundle", ".ralph", "python"))
sys.path.insert(0, _PY_DIR)

import evaluator_contract as ec  # noqa: E402
import rework_todos as rt  # noqa: E402

YAML_PLAN = """---
name: demo
execution: standard
todos:
  - id: original
    content: |
      Do the original thing.
    verification: |
      true
    status: completed
---

Body prose stays put.
"""

CLASSIC_PLAN = "# Plan\n\n- [ ] Original task\n"


def _ledger(tmp, findings, iteration=1, stage="review"):
    path = os.path.join(tmp, "ledger.json")
    contract = {"status": "changes-required",
                "findings": ec.normalize_findings({"findings": findings})}
    merged = ec.merge_verdict_into_ledger(ec._empty_ledger(), contract, iteration, stage)
    ec.write_ledger(path, merged)
    return path


def _blocking(fid, **kw):
    base = {"id": fid, "severity": "blocking", "summary": f"{fid} summary",
            "requiredFix": f"fix {fid}"}
    base.update(kw)
    return base


class SyncYamlPlanTests(unittest.TestCase):
    def test_adds_pending_todo_per_open_blocking_finding(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = os.path.join(tmp, "control.plan.md")
            with open(plan, "w", encoding="utf-8") as fh:
                fh.write(YAML_PLAN)
            ledger = _ledger(tmp, [_blocking("F1", verification="bats a.bats"),
                                   _blocking("F2")])
            added = rt.sync_plan(plan, ledger)
            self.assertEqual(added, ["rework-F1", "rework-F2"])
            content = open(plan, encoding="utf-8").read()
            self.assertIn("- id: rework-F1", content)
            self.assertIn("addressesFinding: F1", content)
            self.assertIn("bats a.bats", content)
            self.assertIn("status: pending", content)
            # The original completed TODO and the body are untouched.
            self.assertIn("status: completed", content)
            self.assertIn("Body prose stays put.", content)

    def test_synthesis_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = os.path.join(tmp, "control.plan.md")
            with open(plan, "w", encoding="utf-8") as fh:
                fh.write(YAML_PLAN)
            ledger = _ledger(tmp, [_blocking("F1")])
            self.assertEqual(rt.sync_plan(plan, ledger), ["rework-F1"])
            self.assertEqual(rt.sync_plan(plan, ledger), [])
            content = open(plan, encoding="utf-8").read()
            self.assertEqual(content.count("- id: rework-F1"), 1)

    def test_finding_without_verification_gets_a_checkable_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = os.path.join(tmp, "control.plan.md")
            with open(plan, "w", encoding="utf-8") as fh:
                fh.write(YAML_PLAN)
            ledger = _ledger(tmp, [_blocking("F1")])
            rt.sync_plan(plan, ledger)
            content = open(plan, encoding="utf-8").read()
            self.assertIn("assert-closed", content)

    def test_advisory_findings_do_not_become_todos(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = os.path.join(tmp, "control.plan.md")
            with open(plan, "w", encoding="utf-8") as fh:
                fh.write(YAML_PLAN)
            ledger = _ledger(tmp, [{"id": "A1", "severity": "advisory", "summary": "nit"}])
            self.assertEqual(rt.sync_plan(plan, ledger), [])

    def test_aged_finding_carries_the_do_not_repeat_warning(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = os.path.join(tmp, "control.plan.md")
            with open(plan, "w", encoding="utf-8") as fh:
                fh.write(YAML_PLAN)
            path = os.path.join(tmp, "ledger.json")
            contract = {"status": "changes-required",
                        "findings": ec.normalize_findings({"findings": [_blocking("F1")]})}
            led = ec.merge_verdict_into_ledger(ec._empty_ledger(), contract, 1, "review")
            led = ec.merge_verdict_into_ledger(led, contract, 2, "review-r1")
            ec.write_ledger(path, led)
            rt.sync_plan(plan, path)
            content = open(plan, encoding="utf-8").read()
            self.assertIn("open for 2 rounds", content)


class SyncClassicPlanTests(unittest.TestCase):
    def test_appends_checkbox_todos(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = os.path.join(tmp, "classic.plan.md")
            with open(plan, "w", encoding="utf-8") as fh:
                fh.write(CLASSIC_PLAN)
            ledger = _ledger(tmp, [_blocking("F1", verification="bats a.bats")])
            self.assertEqual(rt.sync_plan(plan, ledger), ["rework-F1"])
            content = open(plan, encoding="utf-8").read()
            self.assertIn("- [ ] Resolve reviewer finding F1.", content)
            self.assertIn("Verification: bats a.bats", content)
            self.assertIn("- [ ] Original task", content)


class ConvergenceCheckTests(unittest.TestCase):
    def test_unresolved_lists_findings_whose_todo_is_not_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = os.path.join(tmp, "control.plan.md")
            with open(plan, "w", encoding="utf-8") as fh:
                fh.write(YAML_PLAN)
            ledger = _ledger(tmp, [_blocking("F1"), _blocking("F2")])
            rt.sync_plan(plan, ledger)
            self.assertEqual(rt.unresolved_findings(ledger, plan), ["F1", "F2"])

            # Mark only F1's TODO complete.
            content = open(plan, encoding="utf-8").read()
            head, _, tail = content.partition("- id: rework-F1")
            tail = tail.replace("status: pending", "status: completed", 1)
            with open(plan, "w", encoding="utf-8") as fh:
                fh.write(head + "- id: rework-F1" + tail)
            self.assertEqual(rt.unresolved_findings(ledger, plan), ["F2"])

    def test_no_open_findings_means_converged(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = os.path.join(tmp, "control.plan.md")
            with open(plan, "w", encoding="utf-8") as fh:
                fh.write(YAML_PLAN)
            path = os.path.join(tmp, "ledger.json")
            ec.write_ledger(path, ec._empty_ledger())
            self.assertEqual(rt.unresolved_findings(path, plan), [])

    def test_assert_closed_reflects_disposition(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = _ledger(tmp, [_blocking("F1")])
            self.assertFalse(rt.assert_closed(ledger, "F1"))
            self.assertFalse(rt.assert_closed(ledger, "nope"))
            led = ec.load_ledger(ledger)
            led["findings"][0]["disposition"] = "fixed"
            ec.write_ledger(ledger, led)
            self.assertTrue(rt.assert_closed(ledger, "F1"))

    def test_missing_plan_reports_every_open_finding(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = _ledger(tmp, [_blocking("F1")])
            self.assertEqual(
                rt.unresolved_findings(ledger, os.path.join(tmp, "absent.md")), ["F1"]
            )

    def test_missing_plan_is_an_error_for_sync(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = _ledger(tmp, [_blocking("F1")])
            with self.assertRaises(rt.ReworkSynthesisError):
                rt.sync_plan(os.path.join(tmp, "absent.md"), ledger)


if __name__ == "__main__":
    unittest.main()
