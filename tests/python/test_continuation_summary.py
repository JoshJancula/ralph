import json
import os
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PY_DIR = os.path.join(REPO_ROOT, "bundle", ".ralph", "python")
sys.path.insert(0, PY_DIR)

import continuation_summary as cs  # noqa: E402


class ContinuationSummaryStateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.plan_path = os.path.join(self.tmp.name, "plan.md")
        with open(self.plan_path, "w", encoding="utf-8") as handle:
            handle.write("- [ ] First\n- [ ] Second\n")
        self.state_path = os.path.join(self.tmp.name, "continuation-summary.json")
        self._saved_env = {
            key: os.environ.get(key)
            for key in (
                "RALPH_MODE",
                "RALPH_CONTINUATION_SUMMARY_HIERARCHICAL",
                "RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT",
                "RALPH_CONTINUATION_SUMMARY_GROUP_WINDOW",
                "RALPH_CONTINUATION_SUMMARY_GROUP_BY",
                "RALPH_CONTINUATION_SUMMARY_MAX_RENDER_BYTES",
                "RALPH_CONTINUATION_SUMMARY_MAX_ERROR_BYTES_PER",
                "RALPH_CONTINUATION_SUMMARY_MAX_ERROR_BYTES_TOTAL",
            )
        }

    def tearDown(self):
        for key, value in self._saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.tmp.cleanup()

    def _disable_hierarchical(self):
        os.environ["RALPH_CONTINUATION_SUMMARY_HIERARCHICAL"] = "0"

    def _enable_hierarchical(self):
        os.environ["RALPH_MODE"] = "ralph"
        os.environ.pop("RALPH_CONTINUATION_SUMMARY_HIERARCHICAL", None)

    def _complete_todo(self, ordinal, line, todo_id, summary="done", verify_status="pass"):
        cs.update_state(
            self.state_path,
            {
                "plan_key": "plan-key",
                "plan_path": self.plan_path,
                "completed_todo": {
                    "id": todo_id,
                    "ordinal": ordinal,
                    "line": line,
                    "hash": f"hash-{todo_id}",
                    "content": f"Task content for {todo_id}",
                    "completion_summary": summary,
                },
                "verification": {
                    "status": verify_status,
                    "reason": "",
                    "artifact_path": f".ralph-workspace/artifacts/plan-key/{todo_id}.log",
                },
                "output_artifacts": [f".ralph-workspace/artifacts/plan-key/{todo_id}.md"],
            },
            enabled=True,
        )

    def test_empty_render_when_no_completed_todos(self):
        state = cs.ensure_plan_state(
            self.state_path, "plan-key", self.plan_path, enabled=True
        )
        self.assertEqual(cs.render_markdown(state), "")

    def test_update_and_render_is_deterministic(self):
        self._disable_hierarchical()
        payload = {
            "plan_key": "plan-key",
            "plan_path": self.plan_path,
            "completed_todo": {
                "id": "first",
                "ordinal": 1,
                "line": 1,
                "hash": "abc",
                "content": "Do the first thing",
                "completion_summary": "Implemented first thing",
            },
            "verification": {
                "status": "pass",
                "reason": "",
                "artifact_path": ".ralph-workspace/artifacts/plan-key/test.log",
            },
            "output_artifacts": [".ralph-workspace/artifacts/plan-key/out.md"],
            "next_todo": {
                "line": 2,
                "ordinal": 2,
                "id": "second",
                "content": "Do the second thing",
            },
        }
        cs.update_state(self.state_path, payload, enabled=True)
        state = cs._read_json(self.state_path)
        block_a = cs.render_markdown(state)
        block_b = cs.render_markdown(state)
        self.assertEqual(block_a, block_b)
        self.assertIn("Completed work", block_a)
        self.assertIn("Implemented first thing", block_a)
        self.assertIn("Verification outcomes", block_a)
        self.assertIn("Output artifacts", block_a)
        self.assertIn("Next action", block_a)
        self.assertIn("Do the second thing", block_a)

    def test_plan_fingerprint_change_clears_stale_state(self):
        self._disable_hierarchical()
        cs.update_state(
            self.state_path,
            {
                "plan_key": "plan-key",
                "plan_path": self.plan_path,
                "completed_todo": {
                    "id": "first",
                    "ordinal": 1,
                    "line": 1,
                    "hash": "abc",
                    "content": "Old task",
                    "completion_summary": "Done",
                },
            },
            enabled=True,
        )
        with open(self.plan_path, "a", encoding="utf-8") as handle:
            handle.write("- [ ] Third\n")
        fresh = cs.ensure_plan_state(
            self.state_path, "plan-key", self.plan_path, enabled=True
        )
        self.assertEqual(fresh.get("completed_todos"), [])

    def test_error_truncation_is_recorded(self):
        self._disable_hierarchical()
        os.environ["RALPH_CONTINUATION_SUMMARY_MAX_ERROR_BYTES_PER"] = "16"
        os.environ["RALPH_CONTINUATION_SUMMARY_MAX_ERROR_BYTES_TOTAL"] = "32"
        try:
            cs.update_state(
                self.state_path,
                {
                    "plan_key": "plan-key",
                    "plan_path": self.plan_path,
                    "record_error": {
                        "todo_line": 3,
                        "text": "x" * 40,
                        "source": "strict_verify",
                    },
                },
                enabled=True,
            )
            state = cs._read_json(self.state_path)
            self.assertEqual(len(state["recent_errors"]), 1)
            self.assertTrue(state["recent_errors"][0]["truncated"])
            self.assertGreater(state["stats"]["truncation_count"], 0)
        finally:
            os.environ.pop("RALPH_CONTINUATION_SUMMARY_MAX_ERROR_BYTES_PER", None)
            os.environ.pop("RALPH_CONTINUATION_SUMMARY_MAX_ERROR_BYTES_TOTAL", None)

    def test_disabled_update_writes_nothing(self):
        result = cs.update_state(
            self.state_path,
            {"plan_key": "plan-key", "plan_path": self.plan_path},
            enabled=False,
        )
        self.assertFalse(result["written"])
        self.assertFalse(os.path.isfile(self.state_path))

    def test_extract_completion_summary_from_structured_footer(self):
        text = """Implemented the widget fix.

TODO_COMPLETION: COMPLETE
TODO_VERIFICATION: PASS
"""
        summary = cs.extract_completion_summary(text, 512)
        self.assertIn("widget fix", summary)

    def test_metrics_from_state(self):
        self._disable_hierarchical()
        cs.update_state(
            self.state_path,
            {
                "plan_key": "plan-key",
                "plan_path": self.plan_path,
                "completed_todo": {
                    "id": "first",
                    "ordinal": 1,
                    "line": 1,
                    "hash": "abc",
                    "content": "Task",
                    "completion_summary": "Done",
                },
            },
            enabled=True,
        )
        state = cs._read_json(self.state_path)
        block = cs.render_markdown(state)
        metrics = cs.metrics_from_state(state, block)
        self.assertEqual(metrics["continuation_summary_entry_count"], 1)
        self.assertGreater(metrics["continuation_summary_bytes"], 0)

    def test_schema_migration_adds_summary_generation_version(self):
        legacy = {
            "schema_version": 1,
            "plan_key": "plan-key",
            "plan_path": self.plan_path,
            "plan_fingerprint": cs.plan_fingerprint(self.plan_path),
            "completed_todos": [],
            "verification_outcomes": [],
            "output_artifacts": [],
            "recent_errors": [],
            "human_decisions": [],
            "next_todo": None,
            "stats": {"truncation_count": 0, "completed_entry_count": 0},
        }
        migrated = cs.migrate_state(legacy)
        self.assertEqual(migrated["schema_version"], cs.SCHEMA_VERSION)
        self.assertEqual(migrated["summary_generation_version"], cs.SUMMARY_GENERATION_VERSION)

    def test_hierarchical_groups_older_todos_by_window(self):
        self._enable_hierarchical()
        os.environ["RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT"] = "2"
        os.environ["RALPH_CONTINUATION_SUMMARY_GROUP_WINDOW"] = "3"
        for ordinal in range(1, 8):
            self._complete_todo(ordinal, ordinal * 10, f"todo-{ordinal}", summary=f"summary-{ordinal}")
        state = cs._read_json(self.state_path)
        block = cs.render_markdown(state)
        self.assertIn("Consolidated earlier work", block)
        self.assertIn("TODOs #1-#3 (window)", block)
        self.assertIn("Recent completed work (detailed)", block)
        self.assertIn("todo-6", block)
        self.assertIn("todo-7", block)
        self.assertIn("summary-7", block)
        self.assertNotIn("summary-1", block)

    def test_unresolved_failures_survive_consolidation(self):
        self._enable_hierarchical()
        os.environ["RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT"] = "1"
        for ordinal in range(1, 6):
            status = "fail" if ordinal == 2 else "pass"
            reason = "tests failed" if ordinal == 2 else ""
            cs.update_state(
                self.state_path,
                {
                    "plan_key": "plan-key",
                    "plan_path": self.plan_path,
                    "completed_todo": {
                        "id": f"todo-{ordinal}",
                        "ordinal": ordinal,
                        "line": ordinal,
                        "hash": f"hash-{ordinal}",
                        "content": f"Task {ordinal}",
                        "completion_summary": f"summary-{ordinal}",
                    },
                    "verification": {
                        "status": status,
                        "reason": reason,
                        "artifact_path": f".ralph-workspace/artifacts/plan-key/{ordinal}.log",
                    },
                },
                enabled=True,
            )
        block = cs.render_markdown(cs._read_json(self.state_path))
        self.assertIn("Unresolved verification failures", block)
        self.assertIn("line 2: fail (tests failed)", block)

    def test_render_byte_limit_states_omissions(self):
        self._enable_hierarchical()
        os.environ["RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT"] = "2"
        os.environ["RALPH_CONTINUATION_SUMMARY_MAX_RENDER_BYTES"] = "600"
        for ordinal in range(1, 10):
            self._complete_todo(
                ordinal,
                ordinal,
                f"todo-{ordinal}",
                summary=f"summary-{ordinal}-" + ("x" * 80),
            )
        block = cs.render_markdown(cs._read_json(self.state_path))
        self.assertLessEqual(len(block.encode("utf-8")), 700)
        self.assertIn("Omitted from this summary (byte limit 600)", block)

    def test_rebuild_is_byte_identical_for_same_state(self):
        self._enable_hierarchical()
        for ordinal in range(1, 6):
            self._complete_todo(ordinal, ordinal, f"todo-{ordinal}")
        state = cs._read_json(self.state_path)
        first = cs.rebuild_markdown(state)
        second = cs.rebuild_markdown(state)
        self.assertEqual(first, second)

    def test_hierarchical_gate_follows_rollout_defaults(self):
        os.environ.pop("RALPH_CONTINUATION_SUMMARY_HIERARCHICAL", None)
        os.environ["RALPH_MODE"] = "ralph"
        self.assertTrue(cs.hierarchical_continuation_enabled())
        os.environ["RALPH_MODE"] = "no"
        self.assertFalse(cs.hierarchical_continuation_enabled())
        os.environ["RALPH_CONTINUATION_SUMMARY_HIERARCHICAL"] = "1"
        self.assertTrue(cs.hierarchical_continuation_enabled())
        os.environ["RALPH_CONTINUATION_SUMMARY_HIERARCHICAL"] = "0"
        self.assertFalse(cs.hierarchical_continuation_enabled())

    def test_stage_grouping_preserves_stage_metadata(self):
        self._enable_hierarchical()
        os.environ["RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT"] = "1"
        os.environ["RALPH_CONTINUATION_SUMMARY_GROUP_BY"] = "stage"
        for ordinal, stage in ((1, "alpha"), (2, "alpha"), (3, "beta")):
            cs.update_state(
                self.state_path,
                {
                    "plan_key": "plan-key",
                    "plan_path": self.plan_path,
                    "stage_id": stage,
                    "completed_todo": {
                        "id": f"todo-{ordinal}",
                        "ordinal": ordinal,
                        "line": ordinal,
                        "hash": f"hash-{ordinal}",
                        "content": f"Task {ordinal}",
                        "completion_summary": f"summary-{ordinal}",
                        "stage_id": stage,
                    },
                    "verification": {"status": "pass", "reason": "", "artifact_path": ""},
                },
                enabled=True,
            )
        block = cs.render_markdown(cs._read_json(self.state_path))
        self.assertIn("Consolidated stage alpha", block)
        self.assertIn("todo-1", block)
        self.assertIn("todo-2", block)


if __name__ == "__main__":
    unittest.main()
