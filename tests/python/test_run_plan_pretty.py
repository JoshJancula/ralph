#!/usr/bin/env python3
"""Unit tests for run_plan_pretty overflow storage and pointers."""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
sys.path.insert(0, str(PYTHON_DIR))

import pretty_result_store  # noqa: E402


def _load_run_plan_pretty():
    path = PYTHON_DIR / "run_plan_pretty.py"
    spec = importlib.util.spec_from_file_location("run_plan_pretty", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestPrettyResultStore(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.workspace = Path(self._tmp.name)
        os.environ["RALPH_MCP_WORKSPACE"] = str(self.workspace)
        os.environ["RALPH_PLAN_WORKSPACE_ROOT"] = str(self.workspace / ".ralph-workspace")
        os.environ["RALPH_PLAN_KEY"] = "pretty-test"

    def test_write_and_read_back(self) -> None:
        body = "\n".join(f"line {index:02d}" for index in range(1, 31))
        stored = pretty_result_store.resolve_or_store(body)
        self.assertIsNotNone(stored)
        plan, result_id = stored
        self.assertEqual(plan, "pretty-test")
        result_path = (
            self.workspace
            / ".ralph-workspace"
            / "tool-results"
            / plan
            / "results"
            / f"{result_id}.txt"
        )
        self.assertTrue(result_path.is_file())
        self.assertEqual(result_path.read_text(encoding="utf-8"), body)

    def test_write_result_stores_compact_sibling_for_large_shell_output(self) -> None:
        lines = [f"context-line-{index}" for index in range(1, 6)]
        lines.extend(f"middle-{index}" for index in range(6, 50))
        lines.append("ERROR: build failed")
        lines.extend(f"tail-line-{index}" for index in range(50, 60))
        body = "\n".join(lines) + "\n"
        result_id = pretty_result_store.write_result(body, tool_name="ralph_proxy_shell")
        self.assertIsNotNone(result_id)
        plan = "pretty-test"
        raw_path = (
            self.workspace
            / ".ralph-workspace"
            / "tool-results"
            / plan
            / "results"
            / f"{result_id}.txt"
        )
        compact_path = (
            self.workspace
            / ".ralph-workspace"
            / "tool-results"
            / plan
            / "results"
            / f"{result_id}.compact.txt"
        )
        self.assertTrue(raw_path.is_file())
        self.assertTrue(compact_path.is_file())
        compact_text = compact_path.read_text(encoding="utf-8")
        self.assertIn("ERROR: build failed", compact_text)
        self.assertIn("lines omitted", compact_text)

    def test_reuse_existing_result_id(self) -> None:
        envelope = (
            '{"preview":"short","resultId":"aa8ca820ca5eb25a",'
            '"truncated":true,"originalBytes":100}'
        )
        first = pretty_result_store.resolve_or_store(envelope)
        second = pretty_result_store.resolve_or_store(envelope)
        self.assertEqual(first, ("pretty-test", "aa8ca820ca5eb25a"))
        self.assertEqual(second, first)
        store_dir = self.workspace / ".ralph-workspace" / "tool-results" / "pretty-test" / "results"
        self.assertFalse(any(store_dir.glob("*.txt")))

    def test_unique_ids_for_same_content(self) -> None:
        body = "repeatable output\nsecond line\n"
        first = pretty_result_store.write_result(body)
        second = pretty_result_store.write_result(body)
        self.assertIsNotNone(first)
        self.assertIsNotNone(second)
        self.assertNotEqual(first, second)


class TestPrettyRendererOverflow(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.workspace = Path(self._tmp.name)
        os.environ["RALPH_MCP_WORKSPACE"] = str(self.workspace)
        os.environ["RALPH_PLAN_WORKSPACE_ROOT"] = str(self.workspace / ".ralph-workspace")
        os.environ["RALPH_PLAN_KEY"] = "renderer-test"
        self.module = _load_run_plan_pretty()
        self.renderer = self.module.PrettyRenderer(
            "claude",
            color=False,
            ascii_only=True,
            log_path="/tmp/should-not-be-used.log",
        )

    def test_truncation_pointer_targets_result_store(self) -> None:
        body = "\n".join(f"line {index:02d}" for index in range(1, 31))
        lines, stored = self.renderer._render_result_body(body, is_error=False, store_text=body)
        joined = "\n".join(lines)
        self.assertIn(".ralph-workspace/tool-results/renderer-test/results/", joined)
        self.assertIn("ralph_proxy_result_read resultId=", joined)
        self.assertIn("full output:", joined)
        self.assertIn("more lines", joined)
        self.assertIsNotNone(stored)
        plan, result_id = stored
        dual_links = self.renderer._dual_view_link_lines(plan, result_id)
        dual_joined = "\n".join(dual_links)
        self.assertIn("compacted view:", dual_joined)
        self.assertIn("view=compacted", dual_joined)
        self.assertIn("full output:", dual_joined)
        self.assertNotIn("/tmp/should-not-be-used.log", joined)
        stored = list(
            (self.workspace / ".ralph-workspace" / "tool-results" / "renderer-test" / "results").glob(
                "*.txt"
            )
        )
        self.assertEqual(len(stored), 1)
        self.assertEqual(stored[0].read_text(encoding="utf-8"), body)

    def test_proxy_envelope_link_does_not_duplicate_store(self) -> None:
        envelope = (
            '{"preview":"1..390","resultId":"aa8ca820ca5eb25a",'
            '"truncated":true,"originalBytes":15728,"returnedBytes":5,'
            '"breakpoints":[],"nextActions":[]}'
        )
        lines = self.renderer._render_tool_output(envelope)
        joined = "\n".join(lines)
        self.assertIn("aa8ca820ca5eb25a", joined)
        self.assertIn("compacted view:", joined)
        self.assertIn("view=compacted", joined)
        self.assertIn("full output:", joined)
        store_dir = self.workspace / ".ralph-workspace" / "tool-results" / "renderer-test" / "results"
        self.assertFalse(any(store_dir.glob("*.txt")))

    def test_cursor_tool_output_without_result_id_gets_stored_link(self) -> None:
        lines = self.renderer._render_tool_output("hello from read", tool_name="ralph_proxy_read")
        joined = "\n".join(lines)
        self.assertIn("hello from read", joined)
        self.assertIn(".ralph-workspace/tool-results/renderer-test/results/", joined)
        self.assertIn("ralph_proxy_result_read resultId=", joined)
        store_dir = self.workspace / ".ralph-workspace" / "tool-results" / "renderer-test" / "results"
        stored = list(store_dir.glob("*.txt"))
        self.assertEqual(len(stored), 1)
        self.assertEqual(stored[0].read_text(encoding="utf-8"), "hello from read")

    def _large_proxy_envelope(self, result_id: str = "efeec2df9f877019") -> str:
        import json

        preview = "\n".join(f"stored line {index:02d}" for index in range(1, 31))
        return json.dumps(
            {
                "truncated": True,
                "preview": preview,
                "originalBytes": 120000,
                "returnedBytes": len(preview.encode()),
                "resultId": result_id,
                "breakpoints": [{"kind": "start", "byteStart": 0, "byteEnd": 16384}],
                "nextActions": [
                    {
                        "tool": "ralph_proxy_result_read",
                        "arguments": {"resultId": result_id, "byteStart": 0, "byteEnd": 16384},
                    }
                ],
            }
        )

    def test_proxy_result_read_envelope_renders_truncated_preview(self) -> None:
        envelope = self._large_proxy_envelope()
        lines = self.renderer._render_tool_output(envelope)
        joined = "\n".join(lines)
        self.assertIn("stored line 01", joined)
        self.assertNotIn("stored line 30", joined)
        self.assertIn("ralph_proxy_result_read resultId=efeec2df9f877019", joined)
        self.assertIn("compacted view:", joined)
        self.assertIn("view=compacted", joined)
        self.assertIn("full output:", joined)
        self.assertNotIn("breakpoints", joined)
        self.assertNotIn("nextActions", joined)
        self.assertNotIn("originalBytes", joined)

    def test_proxy_result_read_envelope_mcp_content_list_renders_preview(self) -> None:
        envelope = self._large_proxy_envelope()
        payload = {"success": {"content": [{"type": "text", "text": envelope}]}}
        lines = self.renderer._render_cursor_completion({"result": payload})
        joined = "\n".join(lines)
        self.assertIn("stored line 01", joined)
        self.assertNotIn("stored line 30", joined)
        self.assertIn(".ralph-workspace/tool-results/renderer-test/results/efeec2df9f877019.txt", joined)
        self.assertNotIn("/tmp/should-not-be-used.log", joined)

    def test_proxy_result_read_envelope_does_not_duplicate_store(self) -> None:
        envelope = self._large_proxy_envelope()
        self.renderer._render_tool_output(envelope)
        store_dir = self.workspace / ".ralph-workspace" / "tool-results" / "renderer-test" / "results"
        self.assertFalse(any(store_dir.glob("*.txt")))

    def test_truncated_shell_status_payload_renders_compact_summary(self) -> None:
        truncated = (
            '{"jobId":"abc123","status":"running","elapsedSeconds":12,'
            '"combinedBytes":4096,"preview":"building...\\nstill going trunc'
        )
        lines = self.renderer._render_tool_output(truncated)
        joined = "\n".join(lines)
        self.assertIn("job abc123", joined)
        self.assertIn("running", joined)
        self.assertIn("12s elapsed", joined)
        self.assertIn("building...", joined)
        self.assertNotIn('"jobId"', joined)
        self.assertNotIn('"combinedBytes"', joined)


class TestPromptEchoCollapse(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.workspace = Path(self._tmp.name)
        os.environ["RALPH_MCP_WORKSPACE"] = str(self.workspace)
        os.environ["RALPH_PLAN_WORKSPACE_ROOT"] = str(self.workspace / ".ralph-workspace")
        os.environ["RALPH_PLAN_KEY"] = "echo-test"
        self.module = _load_run_plan_pretty()
        self.renderer = self.module.PrettyRenderer(
            "claude",
            color=False,
            ascii_only=True,
            log_path="/tmp/echo-test.log",
        )

    def test_prompt_echo_collapses_to_pointer_line(self) -> None:
        prompt = (
            "Complete exactly this TODO and nothing else:\n\n"
            "**TODO (line 6):** Reduce the duplicated TODO output.\n\n"
            "Rules:\n"
            "- Use the repo toolchain\n"
        )
        collapsed = self.renderer._truncate_prompt_echo(prompt)
        self.assertIn("prompt rules omitted", collapsed)
        self.assertIn("ralph_proxy_result_read resultId=", collapsed)
        self.assertIn("Reduce the duplicated TODO output", collapsed)
        self.assertNotIn("Use the repo toolchain", collapsed)
        self.assertNotIn("Complete exactly this TODO", collapsed)

    def test_non_prompt_echo_text_is_unchanged(self) -> None:
        text = "Hello, this is normal assistant output.\n"
        self.assertEqual(self.renderer._truncate_prompt_echo(text), text)


class TestOpenCodePlainPromptEcho(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.workspace = Path(self._tmp.name)
        os.environ["RALPH_MCP_WORKSPACE"] = str(self.workspace)
        os.environ["RALPH_PLAN_WORKSPACE_ROOT"] = str(self.workspace / ".ralph-workspace")
        os.environ["RALPH_PLAN_KEY"] = "opencode-plain-echo"
        self.module = _load_run_plan_pretty()
        self.renderer = self.module.PrettyRenderer(
            "opencode",
            color=False,
            ascii_only=True,
            log_path="/tmp/opencode-plain-echo.log",
        )

    def test_render_plain_collapses_multiline_prompt_stream(self) -> None:
        lines = [
            "Complete exactly this TODO and nothing else:",
            "",
            "**TODO (line 8):** Make opencode runs as quiet as cursor/codex.",
            "Rules:",
            "- Use the repo toolchain",
            "## Ralph Mode (hybrid)",
            "- Prefer ralph_proxy_read",
            "Assistant reply starts here.",
        ]
        rendered: list[str] = []
        for line in lines:
            rendered.extend(self.renderer.render_plain(line) or [])
        rendered.extend(self.renderer.flush())
        joined = "\n".join(rendered)
        self.assertIn("prompt rules omitted", joined)
        self.assertIn("ralph_proxy_result_read resultId=", joined)
        self.assertIn("Make opencode runs as quiet", joined)
        self.assertNotIn("Use the repo toolchain", joined)
        self.assertIn("Assistant reply starts here.", joined)

    def test_render_event_suppresses_system_init(self) -> None:
        event = {"type": "system", "subtype": "init", "session_id": "oc-session-1"}
        self.assertEqual(self.renderer.render_event(event), [])


class TestResultBodyBudget(unittest.TestCase):
    """Verify the early cutoff behavior for large and normal result bodies."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        workspace = Path(self._tmp.name)
        os.environ["RALPH_MCP_WORKSPACE"] = str(workspace)
        os.environ["RALPH_PLAN_WORKSPACE_ROOT"] = str(workspace / ".ralph-workspace")
        os.environ["RALPH_PLAN_KEY"] = "budget-test"
        self.module = _load_run_plan_pretty()
        self.renderer = self.module.PrettyRenderer(
            "claude",
            color=False,
            ascii_only=True,
            log_path="/tmp/budget-test.log",
        )

    def _body(self, n: int) -> str:
        return "\n".join(f"result line {i:02d}" for i in range(1, n + 1))

    def test_large_body_uses_small_head_preview(self) -> None:
        # A body with more lines than the large threshold must be cut to the
        # large budget (default 2) with an overflow pointer.
        body = self._body(30)
        lines, _stored = self.renderer._render_result_body(body, is_error=False, store_text=body)
        joined = "\n".join(lines)
        self.assertIn("result line 01", joined)
        self.assertNotIn("result line 05", joined)
        self.assertIn("more lines", joined)

    def test_large_body_overflow_count_matches_budget(self) -> None:
        # 30 lines with the default large budget of 2 yields 28 hidden.
        body = self._body(30)
        large_budget = self.module._RESULT_BODY_LARGE_BUDGET
        lines, _stored = self.renderer._render_result_body(body, is_error=False, store_text=body)
        joined = "\n".join(lines)
        expected_hidden = 30 - large_budget
        self.assertIn(f"+{expected_hidden} more lines", joined)

    def test_normal_body_uses_standard_budget(self) -> None:
        # A body at or below the threshold uses the normal 4-line budget.
        body = self._body(6)
        lines, _stored = self.renderer._render_result_body(body, is_error=False, store_text=body)
        joined = "\n".join(lines)
        # All 6 lines fit within the normal 4-line budget: 4 shown, 2 hidden.
        self.assertIn("result line 01", joined)
        self.assertIn("result line 04", joined)
        self.assertIn("+2 more lines", joined)

    def test_small_body_no_overflow(self) -> None:
        # A body shorter than the normal budget shows every line with no pointer.
        body = self._body(3)
        lines, _stored = self.renderer._render_result_body(body, is_error=False, store_text=body)
        joined = "\n".join(lines)
        self.assertIn("result line 01", joined)
        self.assertIn("result line 03", joined)
        self.assertNotIn("more lines", joined)

    def test_env_var_overrides_large_budget(self) -> None:
        # RALPH_PRETTY_RESULT_BODY_LINES is read at module import time so we
        # verify the constant is honoured by patching it directly.
        original = self.module._RESULT_BODY_LARGE_BUDGET
        try:
            self.module._RESULT_BODY_LARGE_BUDGET = 3
            body = self._body(30)
            lines, _stored = self.renderer._render_result_body(body, is_error=False, store_text=body)
            joined = "\n".join(lines)
            self.assertIn("result line 03", joined)
            self.assertNotIn("result line 04", joined)
            self.assertIn("+27 more lines", joined)
        finally:
            self.module._RESULT_BODY_LARGE_BUDGET = original


class TestToolLineDedup(unittest.TestCase):
    def setUp(self) -> None:
        self.module = _load_run_plan_pretty()
        self.renderer = self.module.PrettyRenderer(
            "claude",
            color=False,
            ascii_only=True,
            log_path="/tmp/tool-dedup-test.log",
        )

    def _assistant_tool_use(self, name: str, tool_input: dict) -> dict:
        return {
            "type": "assistant",
            "message": {
                "content": [
                    {"type": "tool_use", "name": name, "input": tool_input},
                ],
            },
        }

    def test_consecutive_identical_tool_calls_collapse_to_count(self) -> None:
        event = self._assistant_tool_use(
            "ralph_proxy_result_read",
            {"resultId": "abc123def456"},
        )
        lines: list[str] = []
        for _ in range(4):
            lines.extend(self.renderer.render_event(event) or [])
        lines.extend(self.renderer.flush())
        joined = "\n".join(lines)
        self.assertEqual(joined.count("ralph_proxy_result_read"), 1)
        self.assertIn("(x4)", joined)
        self.assertNotIn("(x1)", joined)

    def test_distinct_tool_calls_are_not_collapsed(self) -> None:
        events = [
            self._assistant_tool_use("ralph_proxy_read", {"path": "a.py"}),
            self._assistant_tool_use("ralph_proxy_grep", {"pattern": "foo"}),
        ]
        lines: list[str] = []
        for event in events:
            lines.extend(self.renderer.render_event(event) or [])
        lines.extend(self.renderer.flush())
        joined = "\n".join(lines)
        self.assertIn("ralph_proxy_read", joined)
        self.assertIn("ralph_proxy_grep", joined)
        self.assertNotIn("(x", joined)


class TestCodexShellFailureRendering(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.workspace = Path(self._tmp.name)
        os.environ["RALPH_MCP_WORKSPACE"] = str(self.workspace)
        os.environ["RALPH_PLAN_WORKSPACE_ROOT"] = str(self.workspace / ".ralph-workspace")
        os.environ["RALPH_PLAN_KEY"] = "codex-shell-failure"
        self.module = _load_run_plan_pretty()
        self.renderer = self.module.PrettyRenderer(
            "codex",
            color=False,
            ascii_only=True,
            log_path="/tmp/codex-shell-failure.log",
        )

    def test_failed_shell_with_exit_and_aggregated_output_shows_error_not_command(self) -> None:
        event = {
            "type": "item.completed",
            "item": {
                "id": "ce_fail",
                "type": "command_execution",
                "command": "false",
                "status": "failed",
                "exit_code": 1,
                "aggregated_output": "bash: false: command not found\n",
            },
        }
        lines = self.renderer.render_event(event) or []
        lines.extend(self.renderer.flush())
        joined = "\n".join(lines)
        self.assertIn("Error (exit 1): bash: false: command not found", joined)
        self.assertIn("command_execution(false)", joined)
        self.assertNotRegex(joined, r"- false$")

    def test_failed_shell_with_stderr_uses_exit_and_first_stderr_line(self) -> None:
        event = {
            "type": "item.completed",
            "item": {
                "id": "ce_stderr",
                "type": "command_execution",
                "command": "npm test",
                "status": "failed",
                "exit_code": 2,
                "stderr": "FAIL tests/example.test.js\n",
            },
        }
        lines = self.renderer.render_event(event) or []
        lines.extend(self.renderer.flush())
        joined = "\n".join(lines)
        self.assertIn("Error (exit 2): FAIL tests/example.test.js", joined)
        self.assertNotIn("- npm test", joined)

    def test_failed_shell_without_output_labels_command_failed(self) -> None:
        event = {
            "type": "item.completed",
            "item": {
                "id": "ce_cmd_only",
                "type": "command_execution",
                "command": "false",
                "status": "failed",
            },
        }
        lines = self.renderer.render_event(event) or []
        lines.extend(self.renderer.flush())
        joined = "\n".join(lines)
        self.assertIn("command failed: false", joined)
        self.assertNotIn("Error (exit", joined)

    def test_failed_shell_does_not_echo_command_as_output_line(self) -> None:
        event = {
            "type": "item.completed",
            "item": {
                "id": "ce_output_cmd",
                "type": "command_execution",
                "command": "false",
                "status": "failed",
                "output": "false",
            },
        }
        lines = self.renderer.render_event(event) or []
        lines.extend(self.renderer.flush())
        joined = "\n".join(lines)
        self.assertIn("command failed: false", joined)
        self.assertNotRegex(joined, r"- false$")


class TestVerificationResultColorizing(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.workspace = Path(self._tmp.name)
        os.environ["RALPH_MCP_WORKSPACE"] = str(self.workspace)
        os.environ["RALPH_PLAN_WORKSPACE_ROOT"] = str(self.workspace / ".ralph-workspace")
        os.environ["RALPH_PLAN_KEY"] = "verdict-test"
        self.module = _load_run_plan_pretty()

    def _renderer(self):
        return self.module.PrettyRenderer(
            "claude",
            color=True,
            ascii_only=True,
            log_path="/tmp/should-not-be-used.log",
        )

    def test_fail_verdict_renders_red(self) -> None:
        renderer = self._renderer()
        lines = renderer._emit_text_line("VERIFICATION_RESULT: FAIL: tsc errored")
        joined = "\n".join(lines)
        self.assertIn("\033[31m", joined)  # red
        self.assertNotIn("\033[32m", joined)  # not green

    def test_pass_verdict_renders_green(self) -> None:
        renderer = self._renderer()
        lines = renderer._emit_text_line("VERIFICATION_RESULT: PASS")
        joined = "\n".join(lines)
        self.assertIn("\033[32m", joined)  # green
        self.assertNotIn("\033[31m", joined)  # not red

    def test_status_verdict_renders_green(self) -> None:
        renderer = self._renderer()
        lines = renderer._emit_text_line("VERIFICATION STATUS: PASS")
        joined = "\n".join(lines)
        self.assertIn("\033[32m", joined)  # green
        self.assertNotIn("\033[31m", joined)  # not red

    def test_fail_verdict_wrapped_reason_stays_red(self) -> None:
        renderer = self._renderer()
        renderer.width = 24
        reason = "VERIFICATION_RESULT: FAIL: " + ("word " * 20).strip()
        lines = renderer._emit_text_line(reason)
        self.assertGreater(len(lines), 1)
        for piece in lines:
            self.assertIn("\033[31m", piece)

    def test_plain_text_line_is_not_colored_as_verdict(self) -> None:
        renderer = self._renderer()
        lines = renderer._emit_text_line("ran the verification steps")
        joined = "\n".join(lines)
        self.assertNotIn("\033[31m", joined)
        self.assertNotIn("\033[32m", joined)


class TestSyntaxHighlight(unittest.TestCase):
    def setUp(self) -> None:
        self.module = _load_run_plan_pretty()
        self.palette = {
            "kw": "\033[38;5;176m", "str": "\033[38;5;150m",
            "num": "\033[38;5;179m", "comment": "\033[38;5;245m",
            "func": "\033[38;5;81m", "type": "\033[38;5;115m",
            "reset": "\033[39m",
        }

    def test_python_keyword_string_comment_colored(self) -> None:
        out = self.module.highlight_code_line(
            'def foo():  # note', "python", self.palette
        )
        self.assertIn(self.palette["kw"], out)  # def
        self.assertIn(self.palette["comment"], out)  # # note
        self.assertIn("\033[39m", out)  # soft fg reset, not full reset

    def test_shell_comment_colored(self) -> None:
        out = self.module.highlight_code_line('echo "hi" # x', "shell", self.palette)
        self.assertIn(self.palette["str"], out)
        self.assertIn(self.palette["comment"], out)

    def test_no_lang_returns_input_unchanged(self) -> None:
        text = "def foo()"
        self.assertEqual(self.module.highlight_code_line(text, None, self.palette), text)

    def test_no_palette_returns_input_unchanged(self) -> None:
        text = "def foo()"
        self.assertEqual(self.module.highlight_code_line(text, "python", None), text)

    def test_lang_for_path(self) -> None:
        self.assertEqual(self.module._lang_for_path("a/b/c.tsx"), "cjs")
        self.assertEqual(self.module._lang_for_path("x.sh"), "shell")
        self.assertIsNone(self.module._lang_for_path("README"))

    def test_visible_len_ignores_escapes(self) -> None:
        self.assertEqual(self.module._visible_len("\033[32mhi\033[0m there"), 8)

    def test_no_highlight_opt_out(self) -> None:
        text = "def foo():"
        original = self.module._NO_HIGHLIGHT
        self.module._NO_HIGHLIGHT = True
        try:
            self.assertEqual(
                self.module.highlight_code_line(text, "python", self.palette), text
            )
        finally:
            self.module._NO_HIGHLIGHT = original


class TestDiffRendering(unittest.TestCase):
    def setUp(self) -> None:
        self.module = _load_run_plan_pretty()

    def _renderer(self, color_depth: int, ascii_only: bool = False):
        return self.module.PrettyRenderer(
            "claude",
            color=color_depth > 0,
            ascii_only=ascii_only,
            log_path="/tmp/x.log",
            color_depth=color_depth,
        )

    def test_256_diff_has_background_and_gutter(self) -> None:
        renderer = self._renderer(256)
        lines = renderer._render_unified_diff_lines("a = 1", "a = 2", "python")
        joined = "\n".join(lines)
        self.assertIn("48;5;52", joined)  # delete background
        self.assertIn("48;5;22", joined)  # add background
        self.assertIn("   1", joined)  # right-aligned line-number gutter

    def test_ascii_diff_uses_legacy_plain_form(self) -> None:
        renderer = self._renderer(0, ascii_only=True)
        lines = renderer._render_unified_diff_lines("a = 1", "a = 2", "python")
        self.assertTrue(any(line.startswith("- a = 1") for line in lines))
        self.assertTrue(any(line.startswith("+ a = 2") for line in lines))
        for line in lines:
            self.assertNotIn("48;5;", line)  # no backgrounds

    def test_16_color_diff_has_no_background_block(self) -> None:
        renderer = self._renderer(16)
        lines = renderer._render_unified_diff_lines("a = 1", "a = 2", "python")
        joined = "\n".join(lines)
        self.assertNotIn("48;5;", joined)  # backgrounds are 256-only
        self.assertIn("\033[32m", joined)  # basic green marker

    def test_color_depth_resolution(self) -> None:
        self.assertEqual(self._renderer(256).color_depth, 256)
        self.assertEqual(self._renderer(16).color_depth, 16)
        self.assertEqual(self._renderer(0, ascii_only=True).color_depth, 0)

    def test_c_helper_picks_depth(self) -> None:
        self.assertEqual(self._renderer(256)._c("32", "38;5;71"), "\033[38;5;71m")
        self.assertEqual(self._renderer(16)._c("32", "38;5;71"), "\033[32m")
        self.assertEqual(self._renderer(0, ascii_only=True)._c("32", "38;5;71"), "")


if __name__ == "__main__":
    unittest.main()
