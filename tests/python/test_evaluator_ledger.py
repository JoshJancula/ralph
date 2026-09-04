"""Defect-ledger accumulation across rework rounds.

The behaviour under test is the fix for the observed failure mode where a
reviewer's finding vanished between rework rounds because only the most recent
verdict was ever shown to the implementer.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_PY_DIR = os.path.normpath(os.path.join(_HERE, "..", "..", "bundle", ".ralph", "python"))
sys.path.insert(0, _PY_DIR)

import evaluator_contract as ec  # noqa: E402

_MODULE = os.path.join(_PY_DIR, "evaluator_contract.py")


def _blocking(fid, **kw):
    base = {"id": fid, "severity": "blocking", "summary": f"{fid} summary",
            "requiredFix": f"fix {fid}"}
    base.update(kw)
    return base


def _merge(ledger, status, findings, iteration, stage):
    contract = {"status": status, "findings": ec.normalize_findings({"findings": findings})}
    return ec.merge_verdict_into_ledger(ledger, contract, iteration, stage)


class NormalizeFindingsTests(unittest.TestCase):
    def test_legacy_feedback_becomes_blocking_findings(self):
        findings = ec.normalize_findings({"feedback": ["fix a", "  ", "fix b"]})
        self.assertEqual(len(findings), 2)
        self.assertTrue(all(f["severity"] == "blocking" for f in findings))
        self.assertEqual(findings[0]["requiredFix"], "fix a")

    def test_legacy_ids_are_content_derived_and_position_independent(self):
        first = ec.normalize_findings({"feedback": ["fix a", "fix b"]})
        # Same text at a different index keeps the same identity, so carry-forward
        # tracks the defect rather than the slot it happened to occupy.
        second = ec.normalize_findings({"feedback": ["fix b", "fix a"]})
        self.assertEqual({f["id"] for f in first}, {f["id"] for f in second})
        self.assertNotEqual(first[0]["id"], first[1]["id"])

    def test_legacy_duplicate_entries_collapse_to_one_finding(self):
        findings = ec.normalize_findings({"feedback": ["same", "same"]})
        self.assertEqual(len(findings), 1)

    def test_duplicate_ids_rejected(self):
        with self.assertRaises(ec.EvaluatorContractError):
            ec.normalize_findings({"findings": [_blocking("F1"), _blocking("F1")]})

    def test_open_blocking_without_required_fix_rejected(self):
        bad = {"id": "F1", "severity": "blocking", "summary": "s"}
        with self.assertRaises(ec.EvaluatorContractError):
            ec.normalize_findings({"findings": [bad]})

    def test_closed_blocking_without_required_fix_allowed(self):
        closed = {"id": "F1", "severity": "blocking", "summary": "s", "disposition": "fixed"}
        self.assertEqual(len(ec.normalize_findings({"findings": [closed]})), 1)


class LedgerMergeTests(unittest.TestCase):
    def test_unraised_blocking_finding_carries_forward(self):
        ledger = _merge(ec._empty_ledger(), "changes-required",
                        [_blocking("F1"), _blocking("F2")], 1, "review")
        # Round two resolves F1 and never mentions F2 -- F2 must survive.
        ledger = _merge(ledger, "changes-required",
                        [dict(_blocking("F1"), disposition="fixed")], 2, "review-r1")
        by_id = {f["id"]: f for f in ledger["findings"]}
        self.assertEqual(by_id["F1"]["disposition"], "fixed")
        self.assertEqual(by_id["F2"]["disposition"], "open")
        self.assertEqual(by_id["F2"]["roundsOpen"], 2)
        self.assertTrue(by_id["F2"]["carriedForward"])
        self.assertEqual([f["id"] for f in ec.open_blocking(ledger)], ["F2"])

    def test_unraised_advisory_auto_closes(self):
        ledger = _merge(ec._empty_ledger(), "changes-required",
                        [_blocking("F1"),
                         {"id": "A1", "severity": "advisory", "summary": "nit"}], 1, "review")
        ledger = _merge(ledger, "changes-required", [_blocking("F1")], 2, "review-r1")
        by_id = {f["id"]: f for f in ledger["findings"]}
        self.assertEqual(by_id["A1"]["disposition"], "wontfix")
        self.assertEqual(by_id["A1"]["closedBy"], "unraised-advisory")

    def test_approval_blocked_while_blocking_finding_open(self):
        ledger = _merge(ec._empty_ledger(), "changes-required", [_blocking("F1")], 1, "review")
        with self.assertRaises(ec.EvaluatorContractError) as ctx:
            _merge(ledger, "approved", [], 2, "review-r1")
        self.assertIn("F1", str(ctx.exception))

    def test_approval_allowed_once_every_finding_dispositioned(self):
        ledger = _merge(ec._empty_ledger(), "changes-required",
                        [_blocking("F1"), _blocking("F2")], 1, "review")
        ledger = _merge(ledger, "approved",
                        [dict(_blocking("F1"), disposition="fixed"),
                         dict(_blocking("F2"), disposition="wontfix")], 2, "review-r1")
        self.assertEqual(ec.open_blocking(ledger), [])
        self.assertEqual(ledger["rounds"][-1]["status"], "approved")

    def test_prior_finding_id_links_a_renumbered_finding(self):
        ledger = _merge(ec._empty_ledger(), "changes-required", [_blocking("F1")], 1, "review")
        ledger = _merge(ledger, "changes-required",
                        [_blocking("F9", priorFindingId="F1")], 2, "review-r1")
        self.assertEqual(len(ledger["findings"]), 1)
        self.assertEqual(ledger["findings"][0]["roundsOpen"], 2)

    def test_rounds_history_is_appended(self):
        ledger = _merge(ec._empty_ledger(), "changes-required", [_blocking("F1")], 1, "review")
        ledger = _merge(ledger, "changes-required", [_blocking("F1")], 2, "review-r1")
        self.assertEqual([r["iteration"] for r in ledger["rounds"]], [1, 2])
        self.assertEqual(ledger["rounds"][0]["sourceStage"], "review")


class LedgerRenderTests(unittest.TestCase):
    def test_block_flags_a_repeatedly_unfixed_finding(self):
        ledger = _merge(ec._empty_ledger(), "changes-required", [_blocking("F1")], 1, "review")
        ledger = _merge(ledger, "changes-required", [_blocking("F1")], 2, "review-r1")
        block = ec.render_ledger_feedback_block(ledger, "review-r1", "2", "a/v.json")
        self.assertIn("OPEN FOR 2 ROUNDS", block)
        self.assertIn("Open blocking findings: `1`", block)
        self.assertTrue(block.startswith("<!-- RALPH_EVALUATOR_FEEDBACK: START -->"))
        self.assertIn("<!-- RALPH_EVALUATOR_FEEDBACK: END -->", block)

    def test_block_escapes_backtick_runs_in_reviewer_text(self):
        ledger = _merge(ec._empty_ledger(), "changes-required",
                        [_blocking("F1", summary="use ``` fenced ``` code")], 1, "review")
        block = ec.render_ledger_feedback_block(ledger, "review", "1", "a/v.json")
        self.assertIn("````", block)

    def test_block_rejects_control_characters(self):
        ledger = _merge(ec._empty_ledger(), "changes-required",
                        [_blocking("F1", summary="bad\x07bell")], 1, "review")
        with self.assertRaises(ec.EvaluatorContractError):
            ec.render_ledger_feedback_block(ledger, "review", "1", "a/v.json")


class LedgerCliTests(unittest.TestCase):
    def _run(self, *args):
        return subprocess.run([sys.executable, _MODULE, *args],
                              capture_output=True, text=True)

    def test_cli_merge_block_and_open_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = os.path.join(tmp, "ledger.json")
            v1 = os.path.join(tmp, "v1.json")
            with open(v1, "w", encoding="utf-8") as fh:
                json.dump({"status": "changes-required",
                           "findings": [_blocking("F1", verification="bats x.bats")]}, fh)
            out = self._run("ledger-merge", "--ledger", ledger, "--artifact", v1,
                            "--iteration", "1", "--source-stage", "review")
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertEqual(out.stdout.strip(), "1")
            self.assertTrue(os.path.exists(ledger))

            out = self._run("ledger-open", "--ledger", ledger)
            self.assertEqual(out.returncode, 0, out.stderr)
            record = json.loads(out.stdout.strip())
            self.assertEqual(record["id"], "F1")
            self.assertEqual(record["verification"], "bats x.bats")

            out = self._run("ledger-block", "--ledger", ledger, "--source-stage", "review",
                            "--iteration", "1", "--artifact-path", "a/v.json")
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertIn("Finding `F1`", out.stdout)

    def test_cli_merge_rejects_premature_approval(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = os.path.join(tmp, "ledger.json")
            v1, v2 = os.path.join(tmp, "v1.json"), os.path.join(tmp, "v2.json")
            with open(v1, "w", encoding="utf-8") as fh:
                json.dump({"status": "changes-required", "findings": [_blocking("F1")]}, fh)
            with open(v2, "w", encoding="utf-8") as fh:
                json.dump({"status": "approved"}, fh)
            self._run("ledger-merge", "--ledger", ledger, "--artifact", v1,
                      "--iteration", "1", "--source-stage", "review")
            out = self._run("ledger-merge", "--ledger", ledger, "--artifact", v2,
                            "--iteration", "2", "--source-stage", "review-r1")
            self.assertEqual(out.returncode, 1)
            self.assertIn("F1", out.stderr)

    def test_cli_merge_on_missing_ledger_starts_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = os.path.join(tmp, "nested", "ledger.json")
            v1 = os.path.join(tmp, "v1.json")
            with open(v1, "w", encoding="utf-8") as fh:
                json.dump({"status": "approved"}, fh)
            out = self._run("ledger-merge", "--ledger", ledger, "--artifact", v1,
                            "--iteration", "1", "--source-stage", "review")
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertEqual(out.stdout.strip(), "0")

    def test_malformed_ledger_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = os.path.join(tmp, "ledger.json")
            with open(ledger, "w", encoding="utf-8") as fh:
                fh.write("[]")
            with self.assertRaises(ec.EvaluatorContractError):
                ec.load_ledger(ledger)


if __name__ == "__main__":
    unittest.main()


class LedgerIdempotencyTests(unittest.TestCase):
    def test_repeat_merge_of_same_round_does_not_inflate_age(self):
        ledger = _merge(ec._empty_ledger(), "changes-required", [_blocking("F1")], 1, "review")
        again = _merge(ledger, "changes-required", [_blocking("F1")], 1, "review")
        self.assertEqual(again["findings"][0]["roundsOpen"], 1)
        self.assertEqual(len(again["rounds"]), 1)

    def test_rereview_in_same_round_with_new_findings_is_merged(self):
        # A retried review that produced genuinely different output must not be
        # swallowed by the idempotency guard.
        ledger = _merge(ec._empty_ledger(), "changes-required", [_blocking("F1")], 1, "review")
        ledger = _merge(ledger, "changes-required", [_blocking("F2")], 1, "review")
        self.assertEqual({f["id"] for f in ledger["findings"]}, {"F1", "F2"})
        self.assertEqual(len(ledger["rounds"]), 2)

    def test_distinct_rounds_still_accumulate(self):
        ledger = _merge(ec._empty_ledger(), "changes-required", [_blocking("F1")], 1, "review")
        ledger = _merge(ledger, "changes-required", [_blocking("F1")], 2, "review-r1")
        self.assertEqual(ledger["findings"][0]["roundsOpen"], 2)
