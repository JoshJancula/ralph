#!/usr/bin/env python3
"""Tests for graph_tui.py read model, renderer, navigation, log pane, actions, and lifecycle.

Read-model tests cover a side-effect-free snapshot. Render tests cover a
deterministic colorless frame. Navigation tests cover pure key-to-state
transitions. Log-pane tests cover the contained CLI log-selection contract.
Action tests cover pending-request display and CLI-bound decisions.
Lifecycle tests cover TUI launch decisions, streaming-status fallback, and
terminal restore on exit, exception, SIGINT, and SIGTERM.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))

import graph_tui as gt  # noqa: E402


def _write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _tree_fingerprint(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root).as_posix()
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        if path.is_symlink():
            digest.update(b"L")
            digest.update(os.readlink(path).encode("utf-8", errors="replace"))
        elif path.is_file():
            digest.update(b"F")
            digest.update(path.read_bytes())
        elif path.is_dir():
            digest.update(b"D")
        digest.update(b"\n")
    return digest.hexdigest()


def _event(sequence: int, name: str, **extra: object) -> Dict[str, object]:
    payload: Dict[str, object] = {
        "schemaVersion": 1,
        "sequence": sequence,
        "timestamp": "2026-08-13T00:00:00Z",
        "runId": "run-001",
        "event": name,
    }
    payload.update(extra)
    return payload


class _GraphTuiSampleMixin:
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.run_dir = Path(self._tmp.name) / "graph-runs" / "sample-graph" / "run-001"
        self.run_dir.mkdir(parents=True)
        self._write_run()
        self._write_graph(["impl", "review"])
        self._write_node(
            "impl",
            status="succeeded",
            last_attempt_id="impl-1",
            attempts=[
                {
                    "attemptId": "impl-1",
                    "outcome": "succeeded",
                    "startedAt": "2026-08-13T00:00:00Z",
                    "finishedAt": "2026-08-13T00:01:00Z",
                    "runtime": "cursor",
                    "usageReliable": True,
                    "usageSnapshot": {"totalTokens": 1200},
                    "logPaths": {
                        "runner": "logs/nodes/impl/impl-1/runner.log",
                        "agent": "logs/nodes/impl/impl-1/agent.log",
                        "usage": "logs/nodes/impl/impl-1/usage.json",
                    },
                }
            ],
        )
        self._write_node("review", status="pending", last_attempt_id=None, attempts=[])
        self._write_log("impl", "impl-1", "runner.log", "runner-1\nrunner-2\n")
        self._write_log("impl", "impl-1", "agent.log", "agent-1\n")
        self._write_log("impl", "impl-1", "usage.json", '{"attempt":"impl-1"}\n')

    def _write_run(self, **overrides: object) -> None:
        payload: Dict[str, object] = {
            "schemaVersion": 2,
            "ralphVersion": "test",
            "runId": "run-001",
            "planPath": "plans/sample.plan.md",
            "graphSha": "abc123",
            "startedAt": "2026-08-13T00:00:00Z",
            "status": "running",
            "maxParallel": 2,
            "supervisorPid": 4242,
            "ownerHostname": "tui-host",
            "ownerProcessStartId": "start-4242",
            "heartbeatAt": "2026-08-13T00:00:30Z",
        }
        payload.update(overrides)
        _write_json(self.run_dir / "run.json", payload)

    def _write_graph(self, node_ids: List[str]) -> None:
        nodes = [
            {
                "id": node_id,
                "type": "agent",
                "dependsOn": [],
                "derivedFrom": "stage",
                "stage": {
                    "id": node_id,
                    "runtime": "cursor" if node_id == "impl" else "claude",
                    "agent": "implementation" if node_id == "impl" else "code-review",
                    "workspaceMode": "snapshot",
                },
            }
            for node_id in node_ids
        ]
        _write_json(
            self.run_dir / "graph.json",
            {
                "schemaVersion": 1,
                "name": "sample-graph",
                "namespace": "sample-graph",
                "nodes": nodes,
                "edges": [],
            },
        )

    def _write_node(
        self,
        node_id: str,
        *,
        status: str,
        last_attempt_id: Optional[str],
        attempts: List[Dict[str, object]],
        schema_version: int = 2,
    ) -> None:
        _write_json(
            self.run_dir / "nodes" / f"{node_id}.json",
            {
                "schemaVersion": schema_version,
                "nodeId": node_id,
                "status": status,
                "lastAttemptId": last_attempt_id,
                "attempts": attempts,
                "workspaceMode": "snapshot",
            },
        )

    def _write_log(self, node_id: str, attempt_id: str, filename: str, content: str) -> None:
        path = self.run_dir / "logs" / "nodes" / node_id / attempt_id / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def _write_request(self, request_id: str, **overrides: object) -> None:
        payload: Dict[str, object] = {
            "schemaVersion": 1,
            "requestId": request_id,
            "nonce": "aabbccddeeff00112233445566778899",
            "namespace": "sample-graph",
            "runId": "run-001",
            "nodeId": "impl",
            "attemptId": "impl-1",
            "runtime": "cursor",
            "classification": "operator-permission",
            "action": "Bash",
            "resource": "src/app.ts",
            "effect": "write",
            "choices": ["allow-once", "allow-run", "allow-always", "deny"],
            "createdAt": "2026-08-13T00:00:00Z",
            "expiresAt": "2026-08-13T01:00:00Z",
        }
        payload.update(overrides)
        _write_json(self.run_dir / "operator" / "requests" / f"{request_id}.json", payload)

    def _write_decision(self, request_id: str) -> None:
        _write_json(
            self.run_dir / "operator" / "decisions" / f"{request_id}.json",
            {
                "schemaVersion": 1,
                "requestId": request_id,
                "decision": "allow-once",
                "actorSource": "cli",
                "decidedAt": "2026-08-13T00:02:00Z",
            },
        )

class GraphTuiReadModelTests(_GraphTuiSampleMixin, unittest.TestCase):
    def test_snapshot_loads_run_nodes_and_unique_attempts(self) -> None:
        snapshot = gt.load_snapshot(self.run_dir)
        self.assertEqual(snapshot.run.run_id, "run-001")
        self.assertEqual(snapshot.run.namespace, "sample-graph")
        self.assertEqual(snapshot.run.status, "running")
        self.assertEqual(snapshot.run.plan_path, "plans/sample.plan.md")
        self.assertEqual([node.node_id for node in snapshot.nodes], ["impl", "review"])
        self.assertEqual(snapshot.nodes[0].status, "succeeded")
        self.assertEqual(snapshot.nodes[0].runtime, "cursor")
        self.assertEqual(snapshot.nodes[0].attempt_count, 1)
        self.assertEqual(snapshot.nodes[1].status, "pending")
        self.assertEqual(snapshot.nodes[1].attempt_count, 0)
        self.assertEqual(len(snapshot.attempts), 1)
        self.assertEqual(snapshot.attempts[0].attempt_id, "impl-1")
        self.assertEqual(snapshot.attempts[0].node_id, "impl")

    def test_unique_attempts_collapse_v1_running_and_terminal_records(self) -> None:
        self._write_node(
            "impl",
            status="succeeded",
            last_attempt_id="impl-1",
            schema_version=1,
            attempts=[
                {
                    "attemptId": "impl-1",
                    "startedAt": "2026-08-13T00:00:00Z",
                    "runtime": "cursor",
                    "logPaths": {"runner": "logs/nodes/impl/impl-1/runner.log"},
                },
                {
                    "attemptId": "impl-1",
                    "outcome": "succeeded",
                    "finishedAt": "2026-08-13T00:01:00Z",
                    "runtime": "cursor",
                    "usageReliable": True,
                    "usageSnapshot": {"totalTokens": 9},
                },
            ],
        )
        snapshot = gt.load_snapshot(self.run_dir)
        self.assertEqual(snapshot.nodes[0].attempt_count, 1)
        attempt = snapshot.nodes[0].attempts[0]
        self.assertEqual(attempt.attempt_id, "impl-1")
        self.assertEqual(attempt.started_at, "2026-08-13T00:00:00Z")
        self.assertEqual(attempt.finished_at, "2026-08-13T00:01:00Z")
        self.assertEqual(attempt.outcome, "succeeded")
        self.assertEqual(attempt.log_paths["runner"], "logs/nodes/impl/impl-1/runner.log")
        self.assertEqual(len(snapshot.attempts), 1)

    def _heartbeat_epoch(self) -> int:
        epoch = gt._iso_to_epoch("2026-08-13T00:00:30Z")
        assert epoch is not None
        return epoch

    def test_health_is_healthy_when_heartbeat_is_fresh(self) -> None:
        snapshot = gt.load_snapshot(
            self.run_dir,
            now_epoch=self._heartbeat_epoch() + 10,
            heartbeat_ttl_seconds=60,
            process_lookup=lambda pid: ("dead", None),
        )
        self.assertEqual(snapshot.health, "healthy")

    def test_health_is_stale_when_heartbeat_expired_and_owner_is_dead(self) -> None:
        snapshot = gt.load_snapshot(
            self.run_dir,
            now_epoch=self._heartbeat_epoch() + 120,
            heartbeat_ttl_seconds=60,
            process_lookup=lambda pid: ("dead", None),
        )
        self.assertEqual(snapshot.health, "stale")

    def test_health_is_unknown_when_process_inspection_is_unavailable(self) -> None:
        snapshot = gt.load_snapshot(
            self.run_dir,
            now_epoch=self._heartbeat_epoch() + 120,
            heartbeat_ttl_seconds=60,
            process_lookup=lambda pid: ("unavailable", None),
        )
        self.assertEqual(snapshot.health, "unknown")

    def test_health_is_stale_on_pid_reuse(self) -> None:
        snapshot = gt.load_snapshot(
            self.run_dir,
            now_epoch=self._heartbeat_epoch() + 120,
            heartbeat_ttl_seconds=60,
            process_lookup=lambda pid: ("alive", "other-start"),
        )
        self.assertEqual(snapshot.health, "stale")

    def test_usage_reliability_marks_missing_as_unavailable_not_zero(self) -> None:
        self._write_node(
            "impl",
            status="succeeded",
            last_attempt_id="impl-2",
            attempts=[
                {
                    "attemptId": "impl-1",
                    "usageReliable": True,
                    "usageSnapshot": {"totalTokens": 1200},
                },
                {
                    "attemptId": "impl-2",
                    "usageReliable": False,
                    "usage": None,
                },
            ],
        )
        snapshot = gt.load_snapshot(self.run_dir)
        self.assertEqual(snapshot.nodes[0].attempt_count, 2)
        first, second = snapshot.nodes[0].attempts
        self.assertEqual(first.usage_reliability, "authoritative")
        self.assertEqual(first.usage_snapshot, {"totalTokens": 1200})
        self.assertEqual(second.usage_reliability, "unavailable")
        self.assertIsNone(second.usage_snapshot)
        self.assertNotEqual(second.usage_snapshot, {"totalTokens": 0})
        self.assertEqual(snapshot.usage_reliability, "mixed")

    def test_pending_actions_omit_resolved_requests(self) -> None:
        self._write_request("req-001")
        self._write_request(
            "req-002",
            nodeId="review",
            runtime="claude",
            action="Read",
            resource="docs/GRAPH.md",
            effect="read",
            choices=["allow-once", "deny"],
        )
        self._write_decision("req-001")
        snapshot = gt.load_snapshot(self.run_dir)
        self.assertEqual([action.request_id for action in snapshot.pending_actions], ["req-002"])
        action = snapshot.pending_actions[0]
        self.assertEqual(action.node_id, "review")
        self.assertEqual(action.runtime, "claude")
        self.assertEqual(action.action, "Read")
        self.assertEqual(action.resource, "docs/GRAPH.md")
        self.assertEqual(action.effect, "read")
        self.assertEqual(action.choices, ("allow-once", "deny"))

    def test_selected_log_metadata_uses_contained_path_and_size(self) -> None:
        snapshot = gt.load_snapshot(self.run_dir, selected_node_id="impl", selected_stream="runner")
        log = snapshot.selected_log
        self.assertEqual(log.stream, "runner")
        self.assertEqual(log.node_id, "impl")
        self.assertEqual(log.attempt_id, "impl-1")
        self.assertEqual(log.relative_path, "logs/nodes/impl/impl-1/runner.log")
        self.assertTrue(log.exists)
        self.assertFalse(log.missing)
        self.assertFalse(log.uncontained)
        self.assertFalse(log.truncated)
        self.assertEqual(log.size_bytes, len("runner-1\nrunner-2\n"))

    def test_selected_log_defaults_to_last_attempt_and_runner_stream(self) -> None:
        snapshot = gt.load_snapshot(self.run_dir)
        self.assertEqual(snapshot.selected_log.node_id, "impl")
        self.assertEqual(snapshot.selected_log.attempt_id, "impl-1")
        self.assertEqual(snapshot.selected_log.stream, "runner")

    def test_selected_log_missing_file_is_reported_without_content(self) -> None:
        (self.run_dir / "logs" / "nodes" / "impl" / "impl-1" / "agent.log").unlink()
        snapshot = gt.load_snapshot(self.run_dir, selected_node_id="impl", selected_stream="agent")
        self.assertTrue(snapshot.selected_log.missing)
        self.assertFalse(snapshot.selected_log.exists)
        self.assertEqual(snapshot.selected_log.relative_path, "logs/nodes/impl/impl-1/agent.log")

    def test_selected_log_rejects_uncontained_path(self) -> None:
        self._write_node(
            "impl",
            status="succeeded",
            last_attempt_id="impl-1",
            attempts=[
                {
                    "attemptId": "impl-1",
                    "logPaths": {"runner": "logs/../../../outside/stolen.log"},
                }
            ],
        )
        snapshot = gt.load_snapshot(self.run_dir, selected_node_id="impl")
        self.assertTrue(snapshot.selected_log.uncontained)
        self.assertFalse(snapshot.selected_log.exists)
        self.assertIsNotNone(snapshot.selected_log.error)

    def test_truncated_event_tail_is_ignored(self) -> None:
        events_path = self.run_dir / "events.jsonl"
        first = json.dumps(_event(1, "run-started"))
        second = json.dumps(_event(2, "node-spawn", nodeId="impl", attemptId="impl-1"))
        events_path.write_bytes((first + "\n" + second + "\n" + '{"event":"trun').encode("utf-8"))
        snapshot = gt.load_snapshot(self.run_dir)
        self.assertEqual([event["event"] for event in snapshot.events], ["run-started", "node-spawn"])
        self.assertEqual(snapshot.warnings, ())

    def test_malformed_interior_event_is_nonfatal_warning(self) -> None:
        events_path = self.run_dir / "events.jsonl"
        first = json.dumps(_event(1, "run-started"))
        third = json.dumps(_event(3, "run-status-changed"))
        events_path.write_text(first + "\nnot-json\n" + third + "\n", encoding="utf-8")
        snapshot = gt.load_snapshot(self.run_dir)
        self.assertEqual([event["event"] for event in snapshot.events], ["run-started"])
        self.assertTrue(any("malformed interior" in warning for warning in snapshot.warnings))

    def test_atomic_replacement_retries_empty_then_valid_json(self) -> None:
        path = self.run_dir / "run.json"
        empty_then_valid = {"n": 0}
        real_read = Path.read_bytes

        def patched_read(self_path: Path) -> bytes:
            if self_path == path:
                empty_then_valid["n"] += 1
                if empty_then_valid["n"] == 1:
                    return b""
                if empty_then_valid["n"] == 2:
                    raise FileNotFoundError(str(self_path))
            return real_read(self_path)

        with mock.patch.object(Path, "read_bytes", patched_read):
            snapshot = gt.load_snapshot(self.run_dir)
        self.assertEqual(snapshot.run.run_id, "run-001")
        self.assertGreaterEqual(empty_then_valid["n"], 2)

    def test_atomic_temp_files_are_ignored(self) -> None:
        _write_json(
            self.run_dir / "nodes" / ".atomic-json-XXXXXX",
            {"schemaVersion": 2, "nodeId": "ghost", "status": "running", "attempts": []},
        )
        snapshot = gt.load_snapshot(self.run_dir)
        self.assertEqual([node.node_id for node in snapshot.nodes], ["impl", "review"])

    def test_load_snapshot_is_side_effect_free(self) -> None:
        before = _tree_fingerprint(self.run_dir)
        gt.load_snapshot(self.run_dir)
        after = _tree_fingerprint(self.run_dir)
        self.assertEqual(before, after)

    def test_missing_run_json_raises(self) -> None:
        (self.run_dir / "run.json").unlink()
        with self.assertRaises(gt.GraphTuiError):
            gt.load_snapshot(self.run_dir)

    def test_missing_event_journal_is_nonfatal(self) -> None:
        snapshot = gt.load_snapshot(self.run_dir)
        self.assertEqual(snapshot.events, ())
        self.assertEqual(snapshot.warnings, ())


class GraphTuiRenderTests(_GraphTuiSampleMixin, unittest.TestCase):
    def _frame(
        self,
        *,
        width: int = 80,
        height: int = 24,
        selected_node_id: Optional[str] = None,
        selected_attempt_id: Optional[str] = None,
        snapshot: Optional[gt.GraphTuiSnapshot] = None,
    ) -> str:
        if snapshot is None:
            snapshot = gt.load_snapshot(
                self.run_dir,
                selected_node_id=selected_node_id,
                selected_attempt_id=selected_attempt_id,
                now_epoch=gt._iso_to_epoch("2026-08-13T00:00:30Z"),
                heartbeat_ttl_seconds=60,
                process_lookup=lambda pid: ("alive", "start-4242"),
            )
        return gt.render_frame(
            snapshot,
            width=width,
            height=height,
            selected_node_id=selected_node_id,
            selected_attempt_id=selected_attempt_id,
        )

    def _lines(self, frame: str) -> List[str]:
        return frame.split("\n") if frame else []

    def test_clip_text_truncates_without_raising(self) -> None:
        self.assertEqual(gt.clip_text("hello world", 8), "hello...")
        self.assertEqual(gt.clip_text("hi", 8, pad=True), "hi      ")
        self.assertEqual(gt.clip_text("hello", 0), "")
        self.assertEqual(gt.clip_text("hello", 1), "h")
        self.assertEqual(gt.clip_text("hello", 3), "hel")
        self.assertEqual(gt.clip_text("a\tb\nc", 5), "a b c")
        self.assertEqual(gt.clip_text("", 4, pad=True), "    ")

    def test_frame_contains_header_summary_table_detail_and_footer(self) -> None:
        frame = self._frame()
        lines = self._lines(frame)
        self.assertEqual(len(lines), 24)
        header = lines[0]
        self.assertIn("ralph graph", header)
        self.assertIn("run=run-001", header)
        self.assertIn("ns=sample-graph", header)
        self.assertIn("status=running", header)
        self.assertIn("health=", header)
        joined = "\n".join(lines)
        self.assertIn("plan=plans/sample.plan.md", joined)
        self.assertIn("usage=authoritative", joined)
        self.assertIn("NODE", joined)
        self.assertIn("STATE", joined)
        self.assertIn("impl", joined)
        self.assertIn("review", joined)
        self.assertIn("node=impl", joined)
        self.assertIn("attempt=impl-1", joined)
        self.assertTrue(lines[-1].startswith("q quit"))
        self.assertIn("pending=0", lines[-1])

    def test_frame_is_deterministic(self) -> None:
        first = self._frame()
        second = self._frame()
        self.assertEqual(first, second)

    def test_frame_lines_respect_width_and_height(self) -> None:
        frame = self._frame(width=72, height=18)
        lines = self._lines(frame)
        self.assertEqual(len(lines), 18)
        for line in lines:
            self.assertEqual(len(line), 72)

    def test_narrow_width_truncates_without_exception(self) -> None:
        for width in (0, 1, 2, 3, 5, 10, 20):
            frame = self._frame(width=width, height=12)
            lines = self._lines(frame)
            if width == 0:
                self.assertEqual(lines, [""] * 12)
                continue
            self.assertEqual(len(lines), 12)
            for line in lines:
                self.assertEqual(len(line), width)

    def test_tiny_height_does_not_raise(self) -> None:
        empty = self._frame(height=0)
        self.assertEqual(empty, "")
        one = self._lines(self._frame(height=1))
        self.assertEqual(len(one), 1)
        self.assertIn("ralph graph", one[0])
        two = self._lines(self._frame(height=2))
        self.assertEqual(len(two), 2)
        self.assertIn("ralph graph", two[0])
        self.assertTrue(two[1].startswith("q quit") or "quit" in two[1])

    def test_selected_node_is_marked_in_table(self) -> None:
        frame = self._frame(selected_node_id="review")
        marked = [line for line in self._lines(frame) if line.startswith(">")]
        self.assertEqual(len(marked), 1)
        self.assertIn("review", marked[0])
        self.assertIn("node=review", frame)
        self.assertIn("status=pending", frame)

    def test_default_selection_prefers_node_with_attempt(self) -> None:
        frame = self._frame()
        marked = [line for line in self._lines(frame) if line.startswith(">")]
        self.assertEqual(len(marked), 1)
        self.assertIn("impl", marked[0])
        self.assertIn("node=impl", frame)

    def test_duration_and_usage_render_from_attempt(self) -> None:
        frame = self._frame()
        self.assertIn("00:01:00", frame)
        self.assertIn("usage=authoritative", frame)
        self.assertNotIn("usage=0", frame)
        self.assertNotIn("totalTokens=0", frame)

    def test_missing_optional_fields_render_as_dash(self) -> None:
        self._write_run(planPath="", startedAt="", maxParallel=None)
        self._write_node("review", status="pending", last_attempt_id=None, attempts=[])
        frame = self._frame(selected_node_id="review")
        self.assertIn("plan=-", frame)
        self.assertIn("started=-", frame)
        self.assertIn("attempt=-", frame)
        self.assertIn("duration=-", frame)

    def test_long_values_are_truncated_on_narrow_width(self) -> None:
        long_id = "impl-with-a-very-long-node-identifier"
        self._write_graph([long_id, "review"])
        self._write_node(
            long_id,
            status="succeeded",
            last_attempt_id="impl-1",
            attempts=[
                {
                    "attemptId": "impl-1",
                    "outcome": "succeeded",
                    "startedAt": "2026-08-13T00:00:00Z",
                    "finishedAt": "2026-08-13T00:01:00Z",
                    "runtime": "cursor",
                    "logPaths": {"runner": "logs/nodes/impl/impl-1/runner.log"},
                }
            ],
        )
        frame = self._frame(width=24, height=16, selected_node_id=long_id)
        lines = self._lines(frame)
        self.assertEqual(len(lines), 16)
        for line in lines:
            self.assertEqual(len(line), 24)
        self.assertTrue(any("..." in line for line in lines))

    def test_selected_row_stays_visible_when_table_is_short(self) -> None:
        node_ids = [f"n{index:02d}" for index in range(20)]
        self._write_graph(node_ids)
        for node_id in node_ids:
            self._write_node(node_id, status="pending", last_attempt_id=None, attempts=[])
        frame = self._frame(width=80, height=12, selected_node_id="n19")
        self.assertIn("n19", frame)
        marked = [line for line in self._lines(frame) if line.startswith(">")]
        self.assertEqual(len(marked), 1)
        self.assertIn("n19", marked[0])
        self.assertIn("node=n19", frame)

    def test_render_is_colorless_and_does_not_import_curses(self) -> None:
        source = Path(gt.__file__).read_text(encoding="utf-8")
        self.assertNotIn("import curses", source)
        self.assertNotIn("from curses", source)
        frame = self._frame()
        self.assertNotIn("\x1b", frame)
        self.assertNotIn("\033", frame)

    def test_render_does_not_mutate_run_dir(self) -> None:
        before = _tree_fingerprint(self.run_dir)
        snapshot = gt.load_snapshot(self.run_dir)
        gt.render_frame(snapshot, width=80, height=24)
        after = _tree_fingerprint(self.run_dir)
        self.assertEqual(before, after)

    def test_pending_actions_appear_in_summary_and_footer(self) -> None:
        self._write_request("req-009")
        frame = self._frame()
        self.assertIn("pending=1", frame)
        self.assertTrue(self._lines(frame)[-1].startswith("q quit"))


class GraphTuiNavigationTests(_GraphTuiSampleMixin, unittest.TestCase):
    def _snapshot(self, **kwargs: object) -> gt.GraphTuiSnapshot:
        return gt.load_snapshot(
            self.run_dir,
            now_epoch=gt._iso_to_epoch("2026-08-13T00:00:30Z"),
            heartbeat_ttl_seconds=60,
            process_lookup=lambda pid: ("alive", "start-4242"),
            **kwargs,
        )

    def _nav(
        self,
        snapshot: Optional[gt.GraphTuiSnapshot] = None,
        **kwargs: object,
    ) -> tuple:
        if snapshot is None:
            snapshot = self._snapshot()
        return gt.initial_state(snapshot, **kwargs), snapshot

    def _write_named_nodes(self, node_ids: List[str]) -> None:
        self._write_graph(node_ids)
        for node_id in node_ids:
            self._write_node(node_id, status="pending", last_attempt_id=None, attempts=[])

    def test_initial_state_selects_node_with_attempt(self) -> None:
        state, snapshot = self._nav()
        self.assertEqual(state.selected_node_id, "impl")
        self.assertEqual(state.selected_attempt_id, "impl-1")
        self.assertEqual(state.selected_index, 0)
        self.assertEqual([node.node_id for node in gt.visible_nodes(snapshot, state)], ["impl", "review"])
        self.assertFalse(state.quit_requested)
        self.assertFalse(state.refresh_requested)
        self.assertFalse(state.filter_editing)
        self.assertEqual(state.filter_query, "")

    def test_j_and_k_move_selection(self) -> None:
        state, snapshot = self._nav()
        down = gt.apply_key(state, "j", snapshot)
        self.assertEqual(down.selected_node_id, "review")
        self.assertEqual(down.selected_index, 1)
        self.assertIsNone(down.selected_attempt_id)
        up = gt.apply_key(down, "k", snapshot)
        self.assertEqual(up.selected_node_id, "impl")
        self.assertEqual(up.selected_index, 0)
        self.assertEqual(up.selected_attempt_id, "impl-1")

    def test_up_down_aliases_and_curses_codes(self) -> None:
        state, snapshot = self._nav()
        for key in ("down", "KEY_DOWN", 258):
            moved = gt.apply_key(state, key, snapshot)
            self.assertEqual(moved.selected_node_id, "review", msg=key)
        state = gt.apply_key(state, "j", snapshot)
        for key in ("up", "KEY_UP", 259):
            moved = gt.apply_key(state, key, snapshot)
            self.assertEqual(moved.selected_node_id, "impl", msg=key)

    def test_selection_clamps_at_ends(self) -> None:
        state, snapshot = self._nav()
        self.assertEqual(gt.apply_key(state, "k", snapshot).selected_node_id, "impl")
        last = gt.apply_key(state, "j", snapshot)
        self.assertEqual(gt.apply_key(last, "j", snapshot).selected_node_id, "review")
        self.assertEqual(gt.apply_key(last, "page-down", snapshot).selected_node_id, "review")

    def test_page_down_and_page_up_move_by_page_size(self) -> None:
        node_ids = [f"n{index:02d}" for index in range(10)]
        self._write_named_nodes(node_ids)
        snapshot = self._snapshot()
        state = gt.initial_state(snapshot, page_size=3, selected_node_id="n00")
        self.assertEqual(state.selected_node_id, "n00")
        paged = gt.apply_key(state, "page-down", snapshot)
        self.assertEqual(paged.selected_node_id, "n03")
        self.assertEqual(paged.selected_index, 3)
        paged = gt.apply_key(paged, "KEY_NPAGE", snapshot)
        self.assertEqual(paged.selected_node_id, "n06")
        paged = gt.apply_key(paged, 338, snapshot)
        self.assertEqual(paged.selected_node_id, "n09")
        self.assertEqual(gt.apply_key(paged, "page-down", snapshot).selected_node_id, "n09")
        back = gt.apply_key(paged, "page-up", snapshot)
        self.assertEqual(back.selected_node_id, "n06")
        back = gt.apply_key(back, "KEY_PPAGE", snapshot)
        self.assertEqual(back.selected_node_id, "n03")
        back = gt.apply_key(back, 339, snapshot)
        self.assertEqual(back.selected_node_id, "n00")
        self.assertEqual(gt.apply_key(back, "page-up", snapshot).selected_node_id, "n00")

    def test_filter_narrows_visible_nodes_and_moves_selection(self) -> None:
        state, snapshot = self._nav()
        editing = gt.apply_key(state, "/", snapshot)
        self.assertTrue(editing.filter_editing)
        self.assertEqual(editing.filter_query, "")
        self.assertEqual(editing.filter_backup, "")
        filtered = gt.apply_keys(editing, list("rev"), snapshot)
        self.assertEqual(filtered.filter_query, "rev")
        self.assertEqual([node.node_id for node in gt.visible_nodes(snapshot, filtered)], ["review"])
        self.assertEqual(filtered.selected_node_id, "review")
        committed = gt.apply_key(filtered, "enter", snapshot)
        self.assertFalse(committed.filter_editing)
        self.assertEqual(committed.filter_query, "rev")
        self.assertEqual(committed.selected_node_id, "review")
        self.assertEqual(gt.apply_key(committed, "j", snapshot).selected_node_id, "review")

    def test_filter_is_case_insensitive_and_matches_status(self) -> None:
        state, snapshot = self._nav()
        filtered = gt.apply_keys(state, ["/", "P", "E", "N", "D"], snapshot)
        self.assertEqual([node.node_id for node in gt.visible_nodes(snapshot, filtered)], ["review"])
        self.assertEqual(filtered.selected_node_id, "review")

    def test_escape_restores_previous_filter(self) -> None:
        state, snapshot = self._nav()
        committed = gt.apply_keys(state, ["/", "r", "e", "v", "enter"], snapshot)
        self.assertEqual(committed.filter_query, "rev")
        restarted = gt.apply_key(committed, "/", snapshot)
        self.assertEqual(restarted.filter_backup, "rev")
        self.assertEqual(restarted.filter_query, "")
        typed = gt.apply_keys(restarted, list("zzz"), snapshot)
        self.assertEqual([node.node_id for node in gt.visible_nodes(snapshot, typed)], [])
        restored = gt.apply_key(typed, "esc", snapshot)
        self.assertFalse(restored.filter_editing)
        self.assertEqual(restored.filter_query, "rev")
        self.assertEqual(restored.selected_node_id, "review")

    def test_backspace_edits_filter(self) -> None:
        state, snapshot = self._nav()
        typed = gt.apply_keys(state, ["/", "r", "e", "v", "x"], snapshot)
        self.assertEqual(typed.filter_query, "revx")
        self.assertEqual(list(gt.visible_nodes(snapshot, typed)), [])
        trimmed = gt.apply_key(typed, "backspace", snapshot)
        self.assertEqual(trimmed.filter_query, "rev")
        self.assertEqual(trimmed.selected_node_id, "review")
        trimmed = gt.apply_key(trimmed, "\x7f", snapshot)
        self.assertEqual(trimmed.filter_query, "re")

    def test_filter_editing_does_not_quit_refresh_or_move(self) -> None:
        state, snapshot = self._nav()
        editing = gt.apply_key(state, "/", snapshot)
        typed = gt.apply_keys(editing, list("qrj"), snapshot)
        self.assertTrue(typed.filter_editing)
        self.assertEqual(typed.filter_query, "qrj")
        self.assertFalse(typed.quit_requested)
        self.assertFalse(typed.refresh_requested)
        self.assertEqual(typed.selected_node_id, "impl")

    def test_quit_is_sticky(self) -> None:
        state, snapshot = self._nav()
        quit_state = gt.apply_key(state, "q", snapshot)
        self.assertTrue(quit_state.quit_requested)
        self.assertEqual(quit_state.selected_node_id, "impl")
        moved = gt.apply_key(quit_state, "j", snapshot)
        self.assertTrue(moved.quit_requested)
        self.assertEqual(moved.selected_node_id, "review")
        self.assertTrue(gt.apply_key(state, "Q", snapshot).quit_requested)

    def test_refresh_sets_flag_until_snapshot_is_applied(self) -> None:
        state, snapshot = self._nav()
        flagged = gt.apply_key(state, "r", snapshot)
        self.assertTrue(flagged.refresh_requested)
        self.assertEqual(flagged.selected_node_id, "impl")
        moved = gt.apply_key(flagged, "j", snapshot)
        self.assertTrue(moved.refresh_requested)
        self.assertEqual(moved.selected_node_id, "review")
        filtered = gt.apply_keys(moved, ["/", "r", "e", "v"], snapshot)
        self.assertTrue(filtered.refresh_requested)
        self.assertEqual(filtered.filter_query, "rev")
        synced = gt.apply_snapshot(filtered, snapshot)
        self.assertFalse(synced.refresh_requested)
        self.assertEqual(synced.selected_node_id, "review")
        self.assertTrue(gt.apply_key(state, "R", snapshot).refresh_requested)

    def test_apply_snapshot_keeps_selection_when_nodes_reorder(self) -> None:
        state, _snapshot = self._nav()
        state = gt.apply_key(state, "j", _snapshot)
        self.assertEqual(state.selected_node_id, "review")
        self._write_graph(["review", "impl"])
        reordered = self._snapshot()
        self.assertEqual([node.node_id for node in reordered.nodes], ["review", "impl"])
        synced = gt.apply_snapshot(state, reordered)
        self.assertEqual(synced.selected_node_id, "review")
        self.assertEqual(synced.selected_index, 0)

    def test_apply_snapshot_clamps_when_selected_node_is_removed(self) -> None:
        node_ids = ["alpha", "bravo", "charlie"]
        self._write_named_nodes(node_ids)
        snapshot = self._snapshot()
        state = gt.initial_state(snapshot, selected_node_id="bravo")
        self.assertEqual(state.selected_index, 1)
        self._write_named_nodes(["alpha", "charlie"])
        reduced = self._snapshot()
        synced = gt.apply_snapshot(state, reduced)
        self.assertEqual(synced.selected_node_id, "charlie")
        self.assertEqual(synced.selected_index, 1)
        self.assertIn(synced.selected_node_id, [node.node_id for node in reduced.nodes])

    def test_apply_snapshot_selects_nothing_when_all_nodes_disappear(self) -> None:
        state, snapshot = self._nav()
        empty = replace(snapshot, nodes=(), attempts=())
        synced = gt.apply_snapshot(state, empty)
        self.assertIsNone(synced.selected_node_id)
        self.assertIsNone(synced.selected_attempt_id)
        self.assertEqual(synced.selected_index, 0)
        self.assertEqual(gt.visible_nodes(empty, synced), ())
        self.assertEqual(gt.apply_key(synced, "j", empty).selected_node_id, None)
        self.assertTrue(gt.apply_key(synced, "q", empty).quit_requested)

    def test_unknown_and_operator_keys_are_noop(self) -> None:
        state, snapshot = self._nav()
        for key in ("a", "d", "y", "n", "?", "tab", "x", "", None, 999):
            self.assertEqual(gt.apply_key(state, key, snapshot), state, msg=repr(key))

    def test_navigation_does_not_mutate_run_dir_or_snapshot(self) -> None:
        before = _tree_fingerprint(self.run_dir)
        snapshot = self._snapshot()
        state = gt.initial_state(snapshot)
        gt.apply_keys(state, ["j", "k", "/", "r", "e", "v", "enter", "page-down", "r", "q"], snapshot)
        gt.apply_snapshot(state, snapshot)
        after = _tree_fingerprint(self.run_dir)
        self.assertEqual(before, after)
        self.assertEqual([node.node_id for node in snapshot.nodes], ["impl", "review"])

    def test_navigation_does_not_import_curses(self) -> None:
        source = Path(gt.__file__).read_text(encoding="utf-8")
        self.assertNotIn("import curses", source)
        self.assertNotIn("from curses", source)


class GraphTuiLogPaneTests(_GraphTuiSampleMixin, unittest.TestCase):
    def _snapshot(self, **kwargs: object) -> gt.GraphTuiSnapshot:
        return gt.load_snapshot(
            self.run_dir,
            now_epoch=gt._iso_to_epoch("2026-08-13T00:00:30Z"),
            heartbeat_ttl_seconds=60,
            process_lookup=lambda pid: ("alive", "start-4242"),
            **kwargs,
        )

    def _state(self, snapshot: Optional[gt.GraphTuiSnapshot] = None, **kwargs: object) -> gt.GraphTuiState:
        if snapshot is None:
            snapshot = self._snapshot()
        return gt.initial_state(snapshot, **kwargs)

    def _read(
        self,
        *,
        snapshot: Optional[gt.GraphTuiSnapshot] = None,
        state: Optional[gt.GraphTuiState] = None,
        tail_lines: int = 10,
        **state_kwargs: object,
    ) -> tuple:
        if snapshot is None:
            snapshot = self._snapshot()
        if state is None:
            state = self._state(snapshot, **state_kwargs)
        return gt.read_log_pane(self.run_dir, snapshot, state, tail_lines=tail_lines)

    def _write_log_bytes(self, node_id: str, attempt_id: str, filename: str, content: bytes) -> Path:
        path = self.run_dir / "logs" / "nodes" / node_id / attempt_id / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def test_read_defaults_to_last_attempt_runner_stream(self) -> None:
        pane, state = self._read()
        self.assertEqual(pane.stream, "runner")
        self.assertEqual(pane.node_id, "impl")
        self.assertEqual(pane.attempt_id, "impl-1")
        self.assertEqual(pane.relative_path, "logs/nodes/impl/impl-1/runner.log")
        self.assertEqual(pane.lines, ("runner-1", "runner-2"))
        self.assertTrue(pane.exists)
        self.assertFalse(pane.missing)
        self.assertFalse(pane.uncontained)
        self.assertEqual(state.selected_stream, "runner")
        self.assertEqual(state.log_offset, pane.size_bytes)
        self.assertTrue(state.log_seen)

    def test_stream_switch_reads_runner_agent_and_usage(self) -> None:
        snapshot = self._snapshot()
        runner, state = self._read(snapshot=snapshot, selected_stream="runner")
        self.assertEqual(runner.lines, ("runner-1", "runner-2"))
        agent, state = self._read(snapshot=snapshot, state=replace(state, selected_stream="agent"))
        self.assertEqual(agent.stream, "agent")
        self.assertEqual(agent.lines, ("agent-1",))
        self.assertEqual(agent.relative_path, "logs/nodes/impl/impl-1/agent.log")
        usage, state = self._read(snapshot=snapshot, state=replace(state, selected_stream="usage"))
        self.assertEqual(usage.stream, "usage")
        self.assertEqual(usage.lines, ('{"attempt":"impl-1"}',))
        self.assertEqual(usage.relative_path, "logs/nodes/impl/impl-1/usage.json")

    def test_s_key_cycles_streams_and_resets_cursor(self) -> None:
        snapshot = self._snapshot()
        pane, state = self._read(snapshot=snapshot)
        self.assertGreater(state.log_offset, 0)
        cycled = gt.apply_key(state, "s", snapshot)
        self.assertEqual(cycled.selected_stream, "agent")
        self.assertEqual(cycled.log_offset, 0)
        self.assertFalse(cycled.log_seen)
        self.assertIsNone(cycled.log_inode)
        pane, state = self._read(snapshot=snapshot, state=cycled)
        self.assertEqual(pane.stream, "agent")
        self.assertEqual(pane.lines, ("agent-1",))
        cycled = gt.apply_key(state, "s", snapshot)
        self.assertEqual(cycled.selected_stream, "usage")
        cycled = gt.apply_key(cycled, "s", snapshot)
        self.assertEqual(cycled.selected_stream, "runner")

    def test_unknown_stream_falls_back_to_runner(self) -> None:
        snapshot = self._snapshot()
        state = replace(self._state(snapshot), selected_stream="stderr")
        pane, updated = self._read(snapshot=snapshot, state=state)
        self.assertEqual(pane.stream, "runner")
        self.assertEqual(updated.selected_stream, "runner")
        self.assertEqual(pane.lines, ("runner-1", "runner-2"))

    def test_bounded_tail_returns_only_last_n_lines(self) -> None:
        self._write_log("impl", "impl-1", "runner.log", "".join(f"line-{index}\n" for index in range(1, 8)))
        pane, _state = self._read(tail_lines=3)
        self.assertEqual(pane.lines, ("line-5", "line-6", "line-7"))
        self.assertTrue(pane.omitted)
        full, _state = self._read(tail_lines=20)
        self.assertEqual(full.lines, tuple(f"line-{index}" for index in range(1, 8)))
        self.assertFalse(full.omitted)

    def test_follow_refresh_picks_up_appended_lines(self) -> None:
        snapshot = self._snapshot()
        state = self._state(snapshot, log_follow=True)
        first, state = self._read(snapshot=snapshot, state=state, tail_lines=10)
        self.assertEqual(first.lines, ("runner-1", "runner-2"))
        self.assertTrue(first.follow)
        self.assertFalse(first.reset)
        log_path = self.run_dir / "logs" / "nodes" / "impl" / "impl-1" / "runner.log"
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write("runner-3\n")
        second, state = self._read(snapshot=snapshot, state=state, tail_lines=10)
        self.assertEqual(second.lines, ("runner-1", "runner-2", "runner-3"))
        self.assertFalse(second.reset)
        self.assertGreater(second.offset, first.offset)
        self.assertTrue(second.follow)

    def test_follow_refresh_resets_on_truncation(self) -> None:
        snapshot = self._snapshot()
        state = self._state(snapshot, log_follow=True)
        first, state = self._read(snapshot=snapshot, state=state, tail_lines=10)
        self.assertEqual(first.lines, ("runner-1", "runner-2"))
        self._write_log("impl", "impl-1", "runner.log", "after-trunc\n")
        second, state = self._read(snapshot=snapshot, state=state, tail_lines=10)
        self.assertEqual(second.lines, ("after-trunc",))
        self.assertNotIn("runner-1", second.lines)
        self.assertTrue(second.reset)
        self.assertTrue(second.truncated)
        self.assertEqual(state.log_offset, second.size_bytes)

    def test_follow_refresh_resets_on_file_replacement(self) -> None:
        snapshot = self._snapshot()
        state = self._state(snapshot, log_follow=True)
        first, state = self._read(snapshot=snapshot, state=state, tail_lines=10)
        log_path = self.run_dir / "logs" / "nodes" / "impl" / "impl-1" / "runner.log"
        first_inode = state.log_inode
        log_path.unlink()
        self._write_log("impl", "impl-1", "runner.log", "after-rotate\n")
        second, state = self._read(snapshot=snapshot, state=state, tail_lines=10)
        self.assertEqual(second.lines, ("after-rotate",))
        self.assertNotIn("runner-1", second.lines)
        self.assertTrue(second.reset)
        if first_inode is not None and state.log_inode is not None:
            self.assertTrue(second.reset)

    def test_missing_file_is_nonfatal_empty_pane(self) -> None:
        (self.run_dir / "logs" / "nodes" / "impl" / "impl-1" / "agent.log").unlink()
        pane, state = self._read(selected_stream="agent")
        self.assertTrue(pane.missing)
        self.assertFalse(pane.exists)
        self.assertEqual(pane.lines, ())
        self.assertEqual(pane.relative_path, "logs/nodes/impl/impl-1/agent.log")
        self.assertEqual(state.log_offset, 0)
        self.assertFalse(state.log_seen)

    def test_truncated_file_without_trailing_newline_is_readable(self) -> None:
        self._write_log_bytes("impl", "impl-1", "runner.log", b"keep-me\npartial")
        pane, _state = self._read(tail_lines=10)
        self.assertEqual(pane.lines, ("keep-me", "partial"))
        self.assertTrue(pane.truncated)
        self.assertFalse(pane.missing)

    def test_binary_bytes_are_replaced_not_raised(self) -> None:
        self._write_log_bytes("impl", "impl-1", "runner.log", b"ok\n\xff\xfe\x00bin\n")
        pane, _state = self._read(tail_lines=10)
        self.assertTrue(pane.replaced)
        self.assertEqual(len(pane.lines), 2)
        self.assertEqual(pane.lines[0], "ok")
        self.assertIn(gt._REPLACEMENT, pane.lines[1])
        self.assertNotIn("\x00", "".join(pane.lines))
        self.assertTrue(all(isinstance(line, str) for line in pane.lines))

    def test_uncontained_path_does_not_read_outside_content(self) -> None:
        outside = Path(self._tmp.name) / "outside" / "stolen.log"
        outside.parent.mkdir(parents=True)
        outside.write_text("secret\n", encoding="utf-8")
        self._write_node(
            "impl",
            status="succeeded",
            last_attempt_id="impl-1",
            attempts=[
                {
                    "attemptId": "impl-1",
                    "logPaths": {"runner": "logs/../../../outside/stolen.log"},
                }
            ],
        )
        pane, _state = self._read()
        self.assertTrue(pane.uncontained)
        self.assertFalse(pane.exists)
        self.assertEqual(pane.lines, ())
        self.assertNotIn("secret", "\n".join(pane.lines))
        self.assertIsNotNone(pane.error)
        self.assertIn("contained", pane.error or "")

    def test_symlink_escape_is_not_read(self) -> None:
        outside = Path(self._tmp.name) / "outside" / "stolen.log"
        outside.parent.mkdir(parents=True)
        outside.write_text("secret\n", encoding="utf-8")
        log_path = self.run_dir / "logs" / "nodes" / "impl" / "impl-1" / "runner.log"
        log_path.unlink()
        log_path.symlink_to(outside)
        pane, _state = self._read()
        self.assertTrue(pane.symlink)
        self.assertFalse(pane.exists)
        self.assertEqual(pane.lines, ())
        self.assertNotIn("secret", "\n".join(pane.lines))

    def test_undeclared_on_disk_log_is_not_read(self) -> None:
        self._write_node(
            "impl",
            status="succeeded",
            last_attempt_id="impl-1",
            attempts=[{"attemptId": "impl-1"}],
        )
        pane, _state = self._read()
        self.assertTrue(pane.missing)
        self.assertEqual(pane.lines, ())
        self.assertNotIn("runner-1", pane.lines)
        self.assertIsNone(pane.relative_path)

    def test_f_toggles_follow(self) -> None:
        snapshot = self._snapshot()
        state = self._state(snapshot)
        self.assertFalse(state.log_follow)
        enabled = gt.apply_key(state, "f", snapshot)
        self.assertTrue(enabled.log_follow)
        self.assertEqual(enabled.selected_stream, "runner")
        disabled = gt.apply_key(enabled, "f", snapshot)
        self.assertFalse(disabled.log_follow)

    def test_changing_node_resets_log_cursor(self) -> None:
        snapshot = self._snapshot()
        pane, state = self._read(snapshot=snapshot)
        self.assertGreater(state.log_offset, 0)
        moved = gt.apply_key(state, "j", snapshot)
        self.assertEqual(moved.selected_node_id, "review")
        self.assertEqual(moved.log_offset, 0)
        self.assertFalse(moved.log_seen)
        self.assertIsNone(moved.log_inode)

    def test_read_is_side_effect_free(self) -> None:
        before = _tree_fingerprint(self.run_dir)
        snapshot = self._snapshot()
        state = self._state(snapshot, log_follow=True)
        gt.read_log_pane(self.run_dir, snapshot, state, tail_lines=2)
        gt.apply_keys(state, ["s", "f", "s"], snapshot)
        after = _tree_fingerprint(self.run_dir)
        self.assertEqual(before, after)

    def test_render_includes_log_pane_and_stays_width_safe(self) -> None:
        snapshot = self._snapshot()
        pane, state = self._read(snapshot=snapshot, tail_lines=10, log_follow=True)
        frame = gt.render_frame(
            snapshot,
            width=72,
            height=24,
            selected_node_id=state.selected_node_id,
            log_pane=pane,
            state=state,
        )
        lines = frame.split("\n")
        self.assertEqual(len(lines), 24)
        for line in lines:
            self.assertEqual(len(line), 72)
        self.assertIn("runner-1", frame)
        self.assertIn("runner-2", frame)
        self.assertIn("stream=runner", frame)
        self.assertIn("follow=on", frame)
        self.assertTrue(lines[-1].startswith("q quit"))

    def test_log_pane_does_not_import_curses(self) -> None:
        source = Path(gt.__file__).read_text(encoding="utf-8")
        self.assertNotIn("import curses", source)
        self.assertNotIn("from curses", source)


class GraphTuiActionTests(_GraphTuiSampleMixin, unittest.TestCase):
    GRAPH_RUN = "/tmp/ralph-graph-run.sh"
    WORKSPACE = "/tmp/ralph-workspace"

    def _snapshot(self, **kwargs: object) -> gt.GraphTuiSnapshot:
        return gt.load_snapshot(
            self.run_dir,
            now_epoch=gt._iso_to_epoch("2026-08-13T00:00:30Z"),
            heartbeat_ttl_seconds=60,
            process_lookup=lambda pid: ("alive", "start-4242"),
            **kwargs,
        )

    def _stale_snapshot(self) -> gt.GraphTuiSnapshot:
        epoch = gt._iso_to_epoch("2026-08-13T00:00:30Z")
        assert epoch is not None
        return gt.load_snapshot(
            self.run_dir,
            now_epoch=epoch + 120,
            heartbeat_ttl_seconds=60,
            process_lookup=lambda pid: ("dead", None),
        )

    def _state(self, snapshot: Optional[gt.GraphTuiSnapshot] = None, **kwargs: object) -> gt.GraphTuiState:
        if snapshot is None:
            snapshot = self._snapshot()
        return gt.initial_state(snapshot, **kwargs)

    def _open(self, snapshot: Optional[gt.GraphTuiSnapshot] = None) -> tuple:
        if snapshot is None:
            snapshot = self._snapshot()
        state = gt.apply_key(self._state(snapshot), "a", snapshot)
        return state, snapshot

    def _frame(self, snapshot: Optional[gt.GraphTuiSnapshot] = None, state: Optional[gt.GraphTuiState] = None) -> str:
        if snapshot is None:
            snapshot = self._snapshot()
        if state is None:
            state = self._state(snapshot)
        return gt.render_frame(snapshot, width=100, height=28, state=state)

    def test_pending_requests_appear_with_identity_and_choices(self) -> None:
        self._write_request("req-002")
        snapshot = self._snapshot()
        frame = self._frame(snapshot)
        self.assertIn("pending requests", frame)
        self.assertIn("req-002", frame)
        self.assertIn("node=impl", frame)
        self.assertIn("runtime=cursor", frame)
        self.assertIn("action=Bash", frame)
        self.assertIn("resource=src/app.ts", frame)
        self.assertIn("effect=write", frame)
        self.assertIn("choices=allow-once,allow-run,allow-always,deny", frame)
        self.assertIn("a action", frame)
        self.assertIn("d deny", frame)
        self.assertTrue(frame.split("\n")[-1].startswith("q quit"))

    def test_default_decision_is_allow_once(self) -> None:
        self._write_request("req-002")
        state, snapshot = self._open()
        self.assertTrue(state.action_open)
        self.assertEqual(state.selected_request_id, "req-002")
        self.assertEqual(state.selected_decision, "allow-once")
        self.assertEqual(gt.default_decision(snapshot.pending_actions[0]), "allow-once")
        self.assertIn("[*]allow-once", self._frame(snapshot, state))
        self.assertIn("selected=allow-once", self._frame(snapshot, state))
        self.assertIn("default=allow-once", self._frame(snapshot, state))

    def test_keys_bind_allow_once_allow_run_allow_always_and_deny(self) -> None:
        self._write_request("req-002")
        state, snapshot = self._open()
        self.assertEqual(gt.apply_key(state, "2", snapshot).selected_decision, "allow-run")
        self.assertEqual(gt.apply_key(state, "3", snapshot).selected_decision, "allow-always")
        self.assertEqual(gt.apply_key(state, "4", snapshot).selected_decision, "deny")
        self.assertEqual(gt.apply_key(state, "1", snapshot).selected_decision, "allow-once")
        self.assertEqual(gt.apply_key(state, "o", snapshot).selected_decision, "allow-once")

    def test_unavailable_choices_are_not_selected(self) -> None:
        self._write_request("req-002", choices=["allow-once", "deny"])
        state, snapshot = self._open()
        self.assertEqual(state.selected_decision, "allow-once")
        self.assertEqual(gt.apply_key(state, "2", snapshot).selected_decision, "allow-once")
        self.assertEqual(gt.apply_key(state, "3", snapshot).selected_decision, "allow-once")
        self.assertEqual(gt.apply_key(state, "4", snapshot).selected_decision, "deny")

    def test_allow_once_command_uses_actions_respond_api(self) -> None:
        self._write_request("req-002")
        state, snapshot = self._open()
        submitted = gt.apply_key(state, "enter", snapshot)
        self.assertTrue(submitted.action_pending_submit)
        self.assertIsNone(submitted.confirm_kind)
        command = gt.build_action_command(
            snapshot,
            submitted,
            graph_run=self.GRAPH_RUN,
            workspace=self.WORKSPACE,
        )
        self.assertIsNotNone(command)
        assert command is not None
        self.assertEqual(command.kind, "respond")
        self.assertEqual(command.decision, "allow-once")
        self.assertEqual(
            command.argv,
            (
                "bash",
                self.GRAPH_RUN,
                "actions",
                "respond",
                "req-002",
                "--decision",
                "allow-once",
                "--namespace",
                "sample-graph",
                "--run",
                "run-001",
                "--json",
                "--workspace",
                self.WORKSPACE,
            ),
        )
        self.assertNotIn("--confirm-rule", command.argv)

    def test_allow_always_requires_confirmation_before_dispatch(self) -> None:
        self._write_request("req-002")
        runner = _RecordingRunner()
        state, snapshot = self._open()
        selected = gt.apply_key(state, "3", snapshot)
        self.assertEqual(selected.selected_decision, "allow-always")
        entered = gt.apply_action_key(
            selected,
            "enter",
            snapshot,
            runner=runner,
            graph_run=self.GRAPH_RUN,
            workspace=self.WORKSPACE,
        )
        self.assertEqual(entered.confirm_kind, "allow-always")
        self.assertFalse(entered.action_pending_submit)
        self.assertFalse(entered.refresh_requested)
        self.assertEqual(runner.calls, [])
        self.assertIn("y confirm  n cancel  allow-always", self._frame(snapshot, entered))
        self.assertIn("y confirm", self._frame(snapshot, entered))
        cancelled = gt.apply_action_key(
            entered,
            "n",
            snapshot,
            runner=runner,
            graph_run=self.GRAPH_RUN,
        )
        self.assertIsNone(cancelled.confirm_kind)
        self.assertEqual(runner.calls, [])

    def test_confirmed_allow_always_includes_confirm_rule(self) -> None:
        self._write_request("req-002")
        runner = _RecordingRunner()
        state, snapshot = self._open()
        action = snapshot.pending_actions[0]
        rule_id = gt.approval_rule_id(action.runtime, action.action, action.resource, action.effect)
        confirming = gt.apply_keys(state, ["3", "enter"], snapshot)
        self.assertEqual(confirming.confirm_rule, rule_id)
        dispatched = gt.apply_action_key(
            confirming,
            "y",
            snapshot,
            runner=runner,
            graph_run=self.GRAPH_RUN,
            workspace=self.WORKSPACE,
        )
        self.assertEqual(len(runner.calls), 1)
        argv = runner.calls[0]
        self.assertEqual(argv[3], "respond")
        self.assertIn("--decision", argv)
        self.assertEqual(argv[argv.index("--decision") + 1], "allow-always")
        self.assertIn("--confirm-rule", argv)
        self.assertEqual(argv[argv.index("--confirm-rule") + 1], rule_id)
        self.assertTrue(dispatched.refresh_requested)
        self.assertFalse(dispatched.action_open)
        self.assertIsNone(dispatched.confirm_kind)

    def test_deny_shortcut_dispatches_without_confirmation(self) -> None:
        self._write_request("req-002")
        runner = _RecordingRunner()
        snapshot = self._snapshot()
        state = self._state(snapshot)
        dispatched = gt.apply_action_key(
            state,
            "d",
            snapshot,
            runner=runner,
            graph_run=self.GRAPH_RUN,
            workspace=self.WORKSPACE,
        )
        self.assertEqual(len(runner.calls), 1)
        self.assertEqual(runner.calls[0][runner.calls[0].index("--decision") + 1], "deny")
        self.assertNotIn("--confirm-rule", runner.calls[0])
        self.assertTrue(dispatched.refresh_requested)

    def test_recovery_requires_confirmation_and_uses_recover_cli(self) -> None:
        runner = _RecordingRunner()
        snapshot = self._stale_snapshot()
        self.assertEqual(snapshot.health, "stale")
        state = self._state(snapshot)
        frame = self._frame(snapshot, state)
        self.assertIn("c recover", frame)
        confirming = gt.apply_action_key(
            state,
            "c",
            snapshot,
            runner=runner,
            graph_run=self.GRAPH_RUN,
            workspace=self.WORKSPACE,
        )
        self.assertEqual(confirming.confirm_kind, "recover")
        self.assertEqual(runner.calls, [])
        self.assertIn("confirm recover", self._frame(snapshot, confirming))
        cancelled = gt.apply_action_key(confirming, "n", snapshot, runner=runner, graph_run=self.GRAPH_RUN)
        self.assertIsNone(cancelled.confirm_kind)
        self.assertEqual(runner.calls, [])
        confirming = gt.apply_key(state, "c", snapshot)
        dispatched = gt.apply_action_key(
            confirming,
            "y",
            snapshot,
            runner=runner,
            graph_run=self.GRAPH_RUN,
            workspace=self.WORKSPACE,
        )
        self.assertEqual(
            runner.calls[-1],
            (
                "bash",
                self.GRAPH_RUN,
                "recover",
                "--namespace",
                "sample-graph",
                "--run",
                "run-001",
                "--workspace",
                self.WORKSPACE,
            ),
        )
        self.assertTrue(dispatched.refresh_requested)

    def test_recovery_key_is_noop_when_health_is_not_stale(self) -> None:
        snapshot = self._snapshot()
        state = self._state(snapshot)
        self.assertEqual(snapshot.health, "healthy")
        self.assertEqual(gt.apply_key(state, "c", snapshot), state)
        self.assertNotIn("c recover", self._frame(snapshot, state))

    def test_successful_decision_refreshes_and_drops_resolved_request(self) -> None:
        self._write_request("req-002")
        snapshot = self._snapshot()
        state = self._state(snapshot)

        def runner(argv: object) -> gt.GraphTuiCommandResult:
            self._write_decision("req-002")
            return gt.GraphTuiCommandResult(0, "", "", tuple(argv))  # type: ignore[arg-type]

        dispatched = gt.apply_action_key(
            state,
            "d",
            snapshot,
            runner=runner,
            graph_run=self.GRAPH_RUN,
            workspace=self.WORKSPACE,
        )
        self.assertTrue(dispatched.refresh_requested)
        refreshed = self._snapshot()
        synced = gt.apply_snapshot(dispatched, refreshed)
        self.assertEqual(refreshed.pending_actions, ())
        self.assertFalse(synced.action_open)
        self.assertIsNone(synced.selected_request_id)
        self.assertFalse(synced.refresh_requested)

    def test_actions_do_not_write_ledger_json_directly(self) -> None:
        self._write_request("req-002")
        before = _tree_fingerprint(self.run_dir)
        snapshot = self._snapshot()
        state = self._state(snapshot)
        gt.apply_keys(state, ["a", "2", "3", "enter", "n", "1", "enter"], snapshot)
        after_keys = _tree_fingerprint(self.run_dir)
        self.assertEqual(before, after_keys)
        runner = _RecordingRunner()
        gt.apply_action_key(
            gt.apply_key(state, "a", snapshot),
            "enter",
            snapshot,
            runner=runner,
            graph_run=self.GRAPH_RUN,
        )
        after_dispatch = _tree_fingerprint(self.run_dir)
        self.assertEqual(before, after_dispatch)
        self.assertTrue(runner.calls)
        self.assertFalse((self.run_dir / "operator" / "decisions" / "req-002.json").exists())

    def test_failed_command_does_not_refresh(self) -> None:
        self._write_request("req-002")
        runner = _RecordingRunner(returncode=2, stderr="Error: already resolved\n")
        state, snapshot = self._open()
        dispatched = gt.apply_action_key(
            state,
            "enter",
            snapshot,
            runner=runner,
            graph_run=self.GRAPH_RUN,
        )
        self.assertFalse(dispatched.refresh_requested)
        self.assertEqual(dispatched.last_action_error, "Error: already resolved")
        self.assertIn("error=Error: already resolved", self._frame(snapshot, dispatched))

    def test_j_k_cycle_pending_requests_while_action_is_open(self) -> None:
        self._write_request("req-001")
        self._write_request("req-002", nodeId="review", action="Read")
        snapshot = self._snapshot()
        state = gt.apply_key(self._state(snapshot), "a", snapshot)
        self.assertEqual(state.selected_request_id, "req-001")
        moved = gt.apply_key(state, "j", snapshot)
        self.assertEqual(moved.selected_request_id, "req-002")
        self.assertEqual(moved.selected_decision, "allow-once")
        self.assertEqual(gt.apply_key(moved, "k", snapshot).selected_request_id, "req-001")

    def test_action_keys_are_noop_without_pending_requests(self) -> None:
        snapshot = self._snapshot()
        state = self._state(snapshot)
        for key in ("a", "d", "y", "n", "1", "2", "3", "4"):
            self.assertEqual(gt.apply_key(state, key, snapshot), state, msg=repr(key))

    def test_actions_do_not_import_curses(self) -> None:
        source = Path(gt.__file__).read_text(encoding="utf-8")
        self.assertNotIn("import curses", source)
        self.assertNotIn("from curses", source)


class GraphTuiLifecycleTests(_GraphTuiSampleMixin, unittest.TestCase):
    def _caps(self, **kwargs: object) -> gt.TuiCapabilities:
        defaults: Dict[str, object] = {
            "stdin_isatty": True,
            "stdout_isatty": True,
            "term": "xterm",
            "environ": {},
            "curses_importer": lambda: object(),
        }
        defaults.update(kwargs)
        return gt.probe_tui_capabilities(**defaults)  # type: ignore[arg-type]

    def test_probe_available_when_curses_and_tty_are_usable(self) -> None:
        caps = self._caps()
        self.assertTrue(caps.available)
        self.assertTrue(caps.curses_ok)
        self.assertTrue(caps.tty_ok)
        self.assertIsNone(caps.reason)

    def test_probe_falls_back_when_curses_cannot_load(self) -> None:
        def importer() -> object:
            raise ImportError("no curses")

        caps = self._caps(curses_importer=importer)
        self.assertFalse(caps.available)
        self.assertEqual(caps.reason, "curses")

    def test_probe_falls_back_without_a_suitable_tty(self) -> None:
        caps = self._caps(stdin_isatty=False, stdout_isatty=True)
        self.assertFalse(caps.available)
        self.assertEqual(caps.reason, "tty")
        caps = self._caps(stdin_isatty=True, stdout_isatty=False)
        self.assertEqual(caps.reason, "tty")

    def test_probe_falls_back_for_dumb_term_ci_plain_and_screen_reader(self) -> None:
        self.assertEqual(self._caps(term="dumb").reason, "term")
        self.assertEqual(self._caps(term="").reason, "term")
        self.assertEqual(self._caps(environ={"CI": "true"}).reason, "ci")
        self.assertEqual(self._caps(environ={"RALPH_GRAPH_PLAIN": "1"}).reason, "plain")
        self.assertEqual(
            self._caps(environ={"RALPH_GRAPH_SCREEN_READER": "1"}).reason,
            "screen-reader",
        )

    def test_probe_missing_python_is_unavailable(self) -> None:
        caps = self._caps(python_ok=False)
        self.assertFalse(caps.available)
        self.assertEqual(caps.reason, "python")

    def test_auto_and_explicit_tui_fall_back_to_streaming_status(self) -> None:
        available = gt.TuiCapabilities(python_ok=True, curses_ok=True, tty_ok=True)
        missing = gt.TuiCapabilities(python_ok=True, curses_ok=False, tty_ok=True, reason="curses")
        self.assertEqual(gt.decide_tui_launch("auto", available).backend, "curses")
        fallback = gt.decide_tui_launch("auto", missing)
        self.assertEqual(fallback.backend, "status")
        self.assertTrue(fallback.fallback)
        self.assertIn("streaming status", fallback.message or "")
        forced = gt.decide_tui_launch("tui", missing)
        self.assertEqual(forced.backend, "status")
        self.assertTrue(forced.fallback)
        self.assertEqual(gt.decide_tui_launch("no-tui", available).backend, "status")
        self.assertFalse(gt.decide_tui_launch("no-tui", available).fallback)

    def test_streaming_status_is_concise_and_colorless(self) -> None:
        snapshot = gt.load_snapshot(self.run_dir)
        frame = gt.render_streaming_status(snapshot, width=72)
        self.assertIn("run=run-001", frame)
        self.assertIn("status=running", frame)
        self.assertNotIn("\x1b", frame)
        self.assertLessEqual(len(frame.split("\n")), gt.STREAMING_FRAME_HEIGHT)

    def test_streaming_status_stops_when_run_is_terminal(self) -> None:
        frames: List[str] = []
        self._write_run(status="succeeded")
        result = gt.run_streaming_status(
            self.run_dir,
            output=frames.append,
            sleep=lambda _seconds: None,
            max_frames=4,
        )
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.backend, "status")
        self.assertEqual(result.frames, 1)
        self.assertIn("status=succeeded", frames[0])
        self.assertNotIn(gt.STREAM_SEPARATOR, frames)

    def test_streaming_status_refreshes_until_bound_when_still_running(self) -> None:
        frames: List[str] = []
        sleeps: List[float] = []
        result = gt.run_streaming_status(
            self.run_dir,
            output=frames.append,
            sleep=sleeps.append,
            refresh_interval=0.25,
            max_frames=2,
        )
        self.assertEqual(result.frames, 2)
        self.assertEqual(sleeps, [0.25])
        self.assertIn(gt.STREAM_SEPARATOR, frames)

    def test_session_applies_keys_and_quits_without_curses(self) -> None:
        painted: List[str] = []
        result = gt.run_tui_session(
            self.run_dir,
            keys=("j", "q"),
            painter=painted.append,
            sleep=lambda _seconds: None,
        )
        self.assertEqual(result.exit_code, 0)
        self.assertTrue(result.quit_requested)
        self.assertGreaterEqual(result.frames, 2)
        self.assertTrue(any("run=run-001" in frame for frame in painted))
        self.assertNotIn("curses", sys.modules)

    def test_session_exits_when_run_becomes_terminal(self) -> None:
        result = gt.run_tui_session(
            self.run_dir,
            keys=(),
            sleep=lambda _seconds: self._write_run(status="failed"),
            max_frames=3,
        )
        self.assertEqual(result.exit_code, 0)
        self.assertFalse(result.quit_requested)

    def test_terminal_restorer_restores_on_normal_exit(self) -> None:
        termios = _FakeTermios()
        signal_mod = _FakeSignal()
        restorer = gt.TerminalRestorer(fd=0, termios_mod=termios, signal_mod=signal_mod)
        with restorer:
            self.assertEqual(termios.getattr_calls, 1)
            self.assertEqual(termios.setattr_calls, [])
        self.assertEqual(len(termios.setattr_calls), 1)
        self.assertEqual(termios.setattr_calls[0][2], termios.saved)
        self.assertEqual(signal_mod.current, signal_mod.original)

    def test_terminal_restorer_restores_on_exception(self) -> None:
        termios = _FakeTermios()
        restorer = gt.TerminalRestorer(fd=0, termios_mod=termios, signal_mod=_FakeSignal())
        with self.assertRaises(RuntimeError):
            with restorer:
                raise RuntimeError("paint failed")
        self.assertEqual(len(termios.setattr_calls), 1)

    def test_terminal_restorer_restores_on_sigint_and_sigterm(self) -> None:
        termios = _FakeTermios()
        signal_mod = _FakeSignal()
        restorer = gt.TerminalRestorer(fd=0, termios_mod=termios, signal_mod=signal_mod)
        restorer.install()
        handler = signal_mod.current[signal_mod.SIGINT]
        with self.assertRaises(KeyboardInterrupt):
            handler(signal_mod.SIGINT, None)
        self.assertEqual(len(termios.setattr_calls), 1)
        termios.setattr_calls.clear()
        restorer = gt.TerminalRestorer(fd=0, termios_mod=termios, signal_mod=signal_mod)
        restorer.install()
        handler = signal_mod.current[signal_mod.SIGTERM]
        with self.assertRaises(SystemExit) as raised:
            handler(signal_mod.SIGTERM, None)
        self.assertEqual(raised.exception.code, 128 + signal_mod.SIGTERM)
        self.assertEqual(len(termios.setattr_calls), 1)

    def test_terminal_restore_is_idempotent(self) -> None:
        termios = _FakeTermios()
        restorer = gt.TerminalRestorer(fd=0, termios_mod=termios, signal_mod=_FakeSignal())
        restorer.install()
        restorer.restore()
        restorer.restore()
        restorer.close()
        self.assertEqual(len(termios.setattr_calls), 1)

    def test_curses_session_uses_wrapper_and_restores(self) -> None:
        curses = _FakeCurses(keys=("q",))
        termios = _FakeTermios()
        restorer = gt.TerminalRestorer(
            fd=0,
            termios_mod=termios,
            signal_mod=_FakeSignal(),
            curses_mod=curses,
        )
        result = gt.run_curses_session(
            self.run_dir,
            curses_mod=curses,
            restorer=restorer,
            keys=("q",),
        )
        self.assertEqual(result.exit_code, 0)
        self.assertTrue(curses.wrapper_called)
        self.assertTrue(curses.endwin_called)
        self.assertEqual(len(termios.setattr_calls), 1)
        self.assertTrue(curses.stdscr.painted)

    def test_curses_session_restores_when_wrapper_raises(self) -> None:
        curses = _FakeCurses(fail=True)
        termios = _FakeTermios()
        restorer = gt.TerminalRestorer(
            fd=0,
            termios_mod=termios,
            signal_mod=_FakeSignal(),
            curses_mod=curses,
        )
        with self.assertRaises(RuntimeError):
            gt.run_curses_session(self.run_dir, curses_mod=curses, restorer=restorer)
        self.assertTrue(curses.endwin_called)
        self.assertEqual(len(termios.setattr_calls), 1)

    def test_main_probe_and_fallback_routing(self) -> None:
        printed: List[str] = []
        errors: List[str] = []
        missing = gt.TuiCapabilities(python_ok=True, curses_ok=False, tty_ok=True, reason="curses")
        probe_rc = gt.main(
            ["--probe"],
            capabilities=missing,
            output=printed.append,
            err=errors.append,
        )
        self.assertEqual(probe_rc, 2)
        self.assertIn('"available":false', printed[0].replace(" ", ""))
        printed.clear()
        errors.clear()
        rc = gt.main(
            ["--run-dir", str(self.run_dir), "--mode", "tui"],
            capabilities=missing,
            output=printed.append,
            err=errors.append,
            sleep=lambda _seconds: None,
            max_frames=1,
        )
        self.assertEqual(rc, 0)
        self.assertTrue(any("streaming status" in line for line in errors))
        self.assertTrue(any("run=run-001" in line for line in printed))

    def test_main_no_tui_skips_curses_even_when_available(self) -> None:
        curses = _FakeCurses(keys=("q",))
        available = gt.TuiCapabilities(python_ok=True, curses_ok=True, tty_ok=True)
        printed: List[str] = []
        rc = gt.main(
            ["--run-dir", str(self.run_dir), "--mode", "no-tui"],
            capabilities=available,
            curses_mod=curses,
            output=printed.append,
            sleep=lambda _seconds: None,
            max_frames=1,
        )
        self.assertEqual(rc, 0)
        self.assertFalse(curses.wrapper_called)
        self.assertTrue(printed)

    def test_parse_tui_argv_reads_selectors(self) -> None:
        parsed = gt.parse_tui_argv(
            [
                "--run-dir",
                "/tmp/run",
                "--workspace",
                "/tmp/ws",
                "--graph-run",
                "/tmp/graph-run.sh",
                "--mode",
                "tui",
                "--refresh-interval",
                "0.5",
            ]
        )
        self.assertEqual(parsed.run_dir, "/tmp/run")
        self.assertEqual(parsed.workspace, "/tmp/ws")
        self.assertEqual(parsed.graph_run, "/tmp/graph-run.sh")
        self.assertEqual(parsed.mode, "tui")
        self.assertEqual(parsed.refresh_interval, 0.5)

    def test_lifecycle_does_not_import_curses_at_module_load(self) -> None:
        self.assertNotIn("curses", sys.modules)
        source = Path(gt.__file__).read_text(encoding="utf-8")
        self.assertNotIn("import curses", source)
        self.assertNotIn("from curses", source)


class _FakeTermios:
    TCSANOW = 0

    def __init__(self) -> None:
        self.saved = ("iflag", "oflag", "cflag", "lflag", "cc")
        self.getattr_calls = 0
        self.setattr_calls: List[tuple] = []

    def tcgetattr(self, fd: int) -> tuple:
        self.getattr_calls += 1
        self.fd = fd
        return self.saved

    def tcsetattr(self, fd: int, when: int, attrs: object) -> None:
        self.setattr_calls.append((fd, when, attrs))


class _FakeSignal:
    SIGINT = 2
    SIGTERM = 15
    SIG_DFL = 0

    def __init__(self) -> None:
        self.original = {self.SIGINT: self.SIG_DFL, self.SIGTERM: self.SIG_DFL}
        self.current = dict(self.original)

    def signal(self, signum: int, handler: object) -> object:
        previous = self.current.get(signum, self.SIG_DFL)
        self.current[signum] = handler
        return previous


class _FakeStdscr:
    def __init__(self, keys: Sequence[object] = ()) -> None:
        self.keys = list(keys)
        self.painted = False
        self.lines: List[str] = []
        self.timeout_ms: Optional[int] = None

    def getmaxyx(self) -> tuple:
        return (24, 80)

    def timeout(self, ms: int) -> None:
        self.timeout_ms = ms

    def getch(self) -> int:
        if self.keys:
            key = self.keys.pop(0)
            return int(key) if isinstance(key, int) else -1
        return -1

    def erase(self) -> None:
        self.lines = []

    def addnstr(self, row: int, col: int, text: str, length: int) -> None:
        self.painted = True
        self.lines.append(text[:length])

    def refresh(self) -> None:
        self.painted = True


class _FakeCurses:
    error = type("error", (Exception,), {})

    def __init__(self, keys: Sequence[object] = (), fail: bool = False) -> None:
        self.stdscr = _FakeStdscr(keys)
        self.wrapper_called = False
        self.endwin_called = False
        self.fail = fail

    def wrapper(self, func: Callable) -> object:
        self.wrapper_called = True
        if self.fail:
            try:
                raise RuntimeError("wrapper failed")
            finally:
                self.endwin()
        try:
            return func(self.stdscr)
        finally:
            self.endwin()

    def initscr(self) -> _FakeStdscr:
        return self.stdscr

    def endwin(self) -> None:
        self.endwin_called = True


class _RecordingRunner:
    def __init__(self, returncode: int = 0, stdout: str = "", stderr: str = "") -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.calls: List[tuple] = []

    def __call__(self, argv: object) -> gt.GraphTuiCommandResult:
        recorded = tuple(argv)  # type: ignore[arg-type]
        self.calls.append(recorded)
        return gt.GraphTuiCommandResult(self.returncode, self.stdout, self.stderr, recorded)


if __name__ == "__main__":
    unittest.main()
