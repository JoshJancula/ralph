#!/usr/bin/env python3
"""Unit/integration tests for the public workflow log pane."""

from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
FIXTURE_DIR = REPO_ROOT / "tests" / "bats" / "workflow" / "fixtures" / "status"
sys.path.insert(0, str(PYTHON_DIR))

import workflow_layout as wl  # noqa: E402
import workflow_logs as wlog  # noqa: E402
import workflow_tui as wt  # noqa: E402


def fixture_view(name: str = "sequential-task-running.json", *, selected: str | None = "implement") -> wt.WorkflowViewModel:
    payload = json.loads((FIXTURE_DIR / name).read_text(encoding="utf-8"))
    snapshot = wt.parse_status_snapshot(payload)
    return wt.view_from_snapshot(snapshot, selected)


def tree_fingerprint(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        digest.update(path.relative_to(root).as_posix().encode("utf-8"))
        digest.update(b"\0")
        if path.is_symlink():
            digest.update(b"symlink:")
            digest.update(os.readlink(path).encode("utf-8"))
        elif path.is_file():
            digest.update(path.read_bytes())
        elif path.is_dir():
            digest.update(b"directory")
        digest.update(b"\n")
    return digest.hexdigest()


class WorkflowLogPaneTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="ralph-workflow-logs-")
        self.root = Path(self._tmp.name) / "engine"
        self.root.mkdir(parents=True)
        self.view = fixture_view()
        self.stage = self.view.selected_stage
        assert self.stage is not None

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _write(self, rel: str, content: bytes | str) -> Path:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
        return path

    def _specs(self, *rels: str, labels: tuple[str, ...] = ()) -> tuple[wlog.LogPathSpec, ...]:
        out = []
        for index, rel in enumerate(rels):
            label = labels[index] if index < len(labels) else ""
            out.append(wlog.LogPathSpec(self.root, rel, label=label))
        return tuple(out)

    def _read(
        self,
        *,
        stream: str = "agent",
        follow: bool = False,
        paused: bool = False,
        path_specs: tuple[wlog.LogPathSpec, ...] | None = None,
        tail_lines: int = 10,
        state: wlog.WorkflowLogState | None = None,
        previous_pane: wlog.WorkflowLogPane | None = None,
        cli_fetcher=None,
    ):
        if state is None:
            state = wlog.initial_log_state(
                self.view,
                selected_stream=stream,
                follow=follow,
                paused=paused,
            )
        return wlog.read_log_pane(
            self.view,
            state,
            path_specs=path_specs,
            cli_fetcher=cli_fetcher,
            tail_lines=tail_lines,
            previous_pane=previous_pane,
        )

    def test_contained_agent_stream_reads_tail(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        self._write(rel, "a1\na2\na3\n")
        pane, state = self._read(path_specs=self._specs(rel), tail_lines=2)
        self.assertEqual(pane.stream, "agent")
        self.assertEqual(pane.lines, ("a2", "a3"))
        self.assertTrue(pane.exists)
        self.assertTrue(pane.omitted)
        self.assertEqual(pane.stage_id, self.stage.id)
        self.assertEqual(pane.attempt, self.stage.attempt)
        self.assertTrue(state.log_seen)
        self.assertEqual(state.log_offset, pane.size_bytes)

    def test_supervisor_and_combined_streams(self) -> None:
        agent_rel, = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")
        runner_rel, = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "supervisor")
        combined = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "combined")
        self._write(agent_rel, "agent-1\n")
        self._write(runner_rel, "runner-1\n")
        agent, _ = self._read(stream="agent", path_specs=self._specs(agent_rel))
        self.assertEqual(agent.lines, ("agent-1",))
        supervisor, _ = self._read(stream="supervisor", path_specs=self._specs(runner_rel))
        self.assertEqual(supervisor.stream, "supervisor")
        self.assertEqual(supervisor.lines, ("runner-1",))
        combined_pane, _ = self._read(
            stream="combined",
            path_specs=self._specs(*combined, labels=("supervisor", "agent")),
        )
        self.assertEqual(combined_pane.stream, "combined")
        self.assertEqual(
            combined_pane.lines,
            ("[supervisor] runner-1", "[agent] agent-1"),
        )
        self.assertEqual(combined, (runner_rel, agent_rel))

    def test_credentials_are_redacted(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        self._write(rel, "ok\npassword=super-secret-value\napi_key: abc123\n")
        pane, _ = self._read(path_specs=self._specs(rel))
        self.assertEqual(pane.lines[0], "ok")
        self.assertEqual(pane.lines[1], "[REDACTED]")
        self.assertEqual(pane.lines[2], "[REDACTED]")
        self.assertNotIn("super-secret", "\n".join(pane.lines))

    def test_long_lines_are_truncated(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        long_line = "x" * 600
        self._write(rel, long_line + "\n")
        pane, _ = self._read(path_specs=self._specs(rel))
        self.assertEqual(len(pane.lines), 1)
        self.assertTrue(pane.lines[0].endswith("...[truncated]"))
        self.assertEqual(len(pane.lines[0]), wlog.DEFAULT_LOG_LINE_MAX + len("...[truncated]"))

    def test_invalid_utf8_and_nul_are_replaced(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        self._write(rel, b"ok\n\xff\xfe\x00bin\n")
        pane, _ = self._read(path_specs=self._specs(rel))
        self.assertTrue(pane.replaced)
        self.assertEqual(pane.lines[0], "ok")
        self.assertIn(wlog._REPLACEMENT, pane.lines[1])
        self.assertNotIn("\x00", "".join(pane.lines))

    def test_truncation_without_trailing_newline(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        self._write(rel, b"keep-me\npartial")
        pane, _ = self._read(path_specs=self._specs(rel))
        self.assertEqual(pane.lines, ("keep-me", "partial"))
        self.assertTrue(pane.truncated)

    def test_rotation_resets_cursor(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        path = self._write(rel, "one\ntwo\n")
        specs = self._specs(rel)
        first, state = self._read(path_specs=specs, follow=True)
        self.assertEqual(first.lines, ("one", "two"))
        path.unlink()
        self._write(rel, "rotated\n")
        second, state = self._read(path_specs=specs, state=replace(state, follow=True))
        self.assertEqual(second.lines, ("rotated",))
        self.assertTrue(second.reset)
        self.assertNotIn("one", second.lines)

    def test_follow_truncation_resets(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        specs = self._specs(rel)
        self._write(rel, "one\ntwo\nthree\n")
        first, state = self._read(path_specs=specs, follow=True)
        self._write(rel, "after\n")
        second, _ = self._read(path_specs=specs, state=replace(state, follow=True))
        self.assertEqual(second.lines, ("after",))
        self.assertTrue(second.reset)
        self.assertTrue(second.truncated)

    def test_missing_file_is_nonfatal(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        pane, state = self._read(path_specs=self._specs(rel))
        self.assertTrue(pane.missing)
        self.assertFalse(pane.exists)
        self.assertEqual(pane.lines, ())
        self.assertFalse(state.log_seen)

    def test_traversal_attempt_is_not_read(self) -> None:
        outside = Path(self._tmp.name) / "outside" / "stolen.log"
        outside.parent.mkdir(parents=True)
        outside.write_text("secret\n", encoding="utf-8")
        pane, _ = self._read(path_specs=self._specs("logs/../../../outside/stolen.log"))
        self.assertTrue(pane.uncontained)
        self.assertEqual(pane.lines, ())
        self.assertNotIn("secret", "\n".join(pane.lines))
        self.assertIsNotNone(pane.error)
        self.assertIn("contained", (pane.error or "").lower())

    def test_absolute_path_spec_is_rejected(self) -> None:
        outside = Path(self._tmp.name) / "outside.log"
        outside.write_text("secret\n", encoding="utf-8")
        pane, _ = self._read(path_specs=(wlog.LogPathSpec(self.root, str(outside)),))
        self.assertTrue(pane.uncontained)
        self.assertNotIn("secret", "\n".join(pane.lines))

    def test_symlink_escape_is_not_read(self) -> None:
        outside = Path(self._tmp.name) / "outside" / "stolen.log"
        outside.parent.mkdir(parents=True)
        outside.write_text("secret\n", encoding="utf-8")
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        target = self.root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(outside)
        pane, _ = self._read(path_specs=self._specs(rel))
        self.assertTrue(pane.symlink)
        self.assertFalse(pane.exists)
        self.assertEqual(pane.lines, ())
        self.assertNotIn("secret", "\n".join(pane.lines))

    def test_stage_attempt_change_resets_cursor(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        self._write(rel, "line\n")
        pane, state = self._read(path_specs=self._specs(rel))
        self.assertGreater(state.log_offset, 0)
        other = fixture_view("sequential-task-running.json", selected="research")
        reconciled = wlog.reconcile_log_state(other, state)
        self.assertEqual(reconciled.log_offset, 0)
        self.assertFalse(reconciled.log_seen)
        self.assertIsNone(reconciled.log_inode)
        self.assertEqual(reconciled.stage_id, "research")
        # Attempt-only change also resets.
        bumped = fixture_view("sequential-task-running.json", selected="research")
        stage = bumped.selected_stage
        assert stage is not None
        # Simulate a higher attempt on the same stage id via a replaced stage tuple.
        new_stage = replace(stage, attempt=stage.attempt + 1)
        snapshot = bumped.snapshot
        assert snapshot is not None
        stages = tuple(new_stage if s.id == stage.id else s for s in snapshot.stages)
        bumped = replace(
            bumped,
            snapshot=replace(snapshot, stages=stages),
            selected_stage_id=stage.id,
        )
        after_attempt = wlog.reconcile_log_state(
            bumped,
            replace(reconciled, stage_id=stage.id, attempt=stage.attempt, log_offset=9, log_seen=True),
        )
        self.assertEqual(after_attempt.attempt, stage.attempt + 1)
        self.assertEqual(after_attempt.log_offset, 0)
        self.assertFalse(after_attempt.log_seen)

    def test_stream_cycle_and_pause_resume(self) -> None:
        state = wlog.initial_log_state(self.view)
        self.assertEqual(state.selected_stream, "agent")
        state = wlog.set_log_stream(state, "supervisor")
        self.assertEqual(state.selected_stream, "supervisor")
        self.assertFalse(state.log_seen)
        self.assertEqual(wlog.cycle_log_stream("supervisor"), "combined")
        self.assertEqual(wlog.cycle_log_stream("combined"), "agent")
        followed = wlog.toggle_follow(state)
        self.assertTrue(followed.follow)
        paused = wlog.toggle_pause(followed)
        self.assertTrue(paused.paused)
        resumed = wlog.toggle_pause(paused)
        self.assertFalse(resumed.paused)

    def test_pause_reuses_previous_pane_without_reread(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        specs = self._specs(rel)
        self._write(rel, "first\n")
        first, state = self._read(path_specs=specs)
        self._write(rel, "first\nsecond\n")
        paused_state = replace(state, paused=True)
        second, _ = self._read(
            path_specs=specs,
            state=paused_state,
            previous_pane=first,
        )
        self.assertTrue(second.paused)
        self.assertEqual(second.lines, ("first",))
        self.assertNotIn("second", second.lines)

    def test_cli_fetcher_path_and_combined_output(self) -> None:
        calls: list[tuple[str, ...]] = []

        def fetcher(argv, timeout=0):
            calls.append(tuple(argv))
            return 0, "cli-one\ncli-two\n", ""

        pane, state = self._read(stream="combined", cli_fetcher=fetcher, tail_lines=10)
        self.assertEqual(pane.lines, ("cli-one", "cli-two"))
        self.assertTrue(pane.exists)
        self.assertIn("--stream", calls[0])
        self.assertIn("combined", calls[0])
        self.assertIn("--no-follow", calls[0])
        self.assertTrue(state.log_seen)

    def test_cli_missing_and_unavailable(self) -> None:
        def missing(argv, timeout=0):
            return 1, "", "Error: workflow log not found for stream 'agent'"

        pane, _ = self._read(cli_fetcher=missing)
        self.assertTrue(pane.missing)
        self.assertFalse(pane.exists)

        def boom(argv, timeout=0):
            return 1, "", "Error: something else failed"

        pane, _ = self._read(cli_fetcher=boom)
        self.assertTrue(pane.unavailable)

    def test_status_json_paths_are_never_consulted(self) -> None:
        """Path fields must not appear on the public stage model used for logs."""

        stage = self.view.selected_stage
        assert stage is not None
        for attr in dir(stage):
            if "path" in attr.lower():
                value = getattr(stage, attr)
                if isinstance(value, str):
                    self.assertNotRegex(value, r"(^/|\\.\\./)")

    def test_read_leaves_log_and_ledger_files_byte_identical(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        self._write(rel, "keep\n")
        ledger = self.root / "nodes" / "implement.json"
        ledger.parent.mkdir(parents=True, exist_ok=True)
        ledger.write_text('{"nodeId":"implement","attempts":[]}\n', encoding="utf-8")
        before = tree_fingerprint(self.root)
        state = wlog.initial_log_state(self.view, follow=True)
        wlog.read_log_pane(self.view, state, path_specs=self._specs(rel), tail_lines=2)
        wlog.read_log_pane(
            self.view,
            replace(state, selected_stream="supervisor"),
            path_specs=self._specs(rel),
            tail_lines=2,
        )
        after = tree_fingerprint(self.root)
        self.assertEqual(before, after)

    def test_no_unbounded_in_memory_growth(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        self._write(rel, "".join(f"line-{i}\n" for i in range(5000)))
        pane, state = self._read(path_specs=self._specs(rel), tail_lines=20)
        self.assertEqual(len(pane.lines), 20)
        self.assertTrue(pane.omitted)
        # State stores cursor metadata only, not line history.
        self.assertFalse(hasattr(state, "lines"))
        self.assertLessEqual(len(pane.lines), 20)

    def test_wide_layout_shows_persistent_log_pane(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        self._write(rel, "wide-log-line\n")
        pane, _ = self._read(path_specs=self._specs(rel))
        frame = wl.render_primary_plain(
            self.view,
            *wl.WIDE_SIZE,
            log_pane=pane,
            log_focused=False,
        )
        self.assertIn("LOG  stream=agent", frame)
        self.assertIn("wide-log-line", frame)
        self.assertIn("Stages", frame)

    def test_compact_and_standard_use_focused_log_view(self) -> None:
        rel = wlog.sequential_stage_log_rel(self.stage.id, self.stage.attempt, "agent")[0]
        self._write(rel, "focus-log-line\n")
        pane, _ = self._read(path_specs=self._specs(rel))
        compact = wl.render_primary_plain(
            self.view,
            *wl.COMPACT_SIZE,
            log_pane=pane,
            log_focused=True,
        )
        self.assertIn("focus-log-line", compact)
        self.assertIn("LOG  stream=agent", compact)
        standard_hidden = wl.render_primary_plain(
            self.view,
            *wl.STANDARD_SIZE,
            log_pane=pane,
            log_focused=False,
        )
        self.assertNotIn("focus-log-line", standard_hidden)
        standard_focused = wl.render_primary_plain(
            self.view,
            *wl.STANDARD_SIZE,
            log_pane=pane,
            log_focused=True,
        )
        self.assertIn("focus-log-line", standard_focused)

    def test_logs_command_uses_public_selectors_only(self) -> None:
        argv = wlog.logs_command(
            "run-abc",
            stage_id="implement",
            attempt=1,
            stream="supervisor",
            tail_lines=12,
        )
        self.assertEqual(
            argv,
            (
                "ralph",
                "workflow",
                "logs",
                "run-abc",
                "--stage",
                "implement",
                "--attempt",
                "1",
                "--stream",
                "supervisor",
                "--tail",
                "12",
                "--no-follow",
            ),
        )
        self.assertNotIn("--namespace", argv)
        self.assertNotIn("--node", argv)


if __name__ == "__main__":
    unittest.main()
