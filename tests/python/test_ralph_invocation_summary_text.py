#!/usr/bin/env python3
"""Unit tests for ralph-invocation-summary-text.py.

Tests covering table column widths, color-off ascii-only output (no ESC bytes,
ascii box glyphs only), and classify_tool_calls family rows in tool detail tables.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

inv_summary = load_ralph_script("ralph-invocation-summary-text")

_UNICODE_BOX_CHARS = set("┌┐└┘─│├┤")
_ASCII_BOX_CHARS = set("+-|")
_ESC_RE = re.compile(rb"\x1b")


def _sample_usage_json() -> str:
    return json.dumps(
        {
            "tool_calls_by_tool": {
                "read": 2,
                "grep": 1,
                "write": 1,
                "ralph_proxy_read": 3,
                "mcp__brave": 1,
                "rewrite-bash": 1,
                "compact-bash": 2,
                "custom_tool": 1,
            }
        }
    )


def _render_plain(**overrides: object) -> str:
    kwargs = {
        "iteration": "1",
        "runtime": "cursor",
        "model": "composer-2.5",
        "input_tokens": "1000",
        "output_tokens": "500",
        "tool_calls": "8",
        "cache_create": "100",
        "cache_read": "200",
        "cache_hit": "75",
        "rate_limit_status": "none",
        "usage_json": _sample_usage_json(),
        "todo_ordinal": "1",
        "todo_line": "4",
        "todos_done": "1",
        "todos_total": "3",
        "elapsed": "3",
        "color": False,
        "ascii_only": True,
    }
    kwargs.update(overrides)
    return inv_summary.render_invocation_summary(**kwargs)


class TestTableColumnWidths(unittest.TestCase):
    """Tests for InvocationSummaryRenderer table width behavior."""

    def test_render_table_lines_share_visible_width(self) -> None:
        renderer = inv_summary.InvocationSummaryRenderer(color=False, ascii_only=True)
        lines = renderer.render_table(
            "Title",
            ["Family", "Tool", "Count"],
            [["native", "read", "2"], ["ralph", "ralph_proxy_read", "3"]],
            inner_width=50,
            flex_col=1,
        )
        widths = {inv_summary.visible_len(line) for line in lines}
        self.assertEqual(len(widths), 1)
        self.assertGreaterEqual(next(iter(widths)), 50)

    def test_inner_width_expands_flex_column(self) -> None:
        renderer = inv_summary.InvocationSummaryRenderer(color=False, ascii_only=True)
        narrow = renderer.render_table("T", ["A", "B"], [["x", "1"]])
        wide = renderer.render_table(
            "T",
            ["A", "B"],
            [["x", "1"]],
            inner_width=40,
            flex_col=1,
        )
        self.assertGreater(
            inv_summary.visible_len(wide[3]),
            inv_summary.visible_len(narrow[3]),
        )

    def test_join_side_by_side_aligns_left_block(self) -> None:
        renderer = inv_summary.InvocationSummaryRenderer(color=False, ascii_only=True)
        left = renderer.render_table("Left", ["K", "V"], [["a", "1"]])
        right = renderer.render_table("Right", ["K", "V"], [["b", "2"]])
        combined = renderer.join_side_by_side(left, right)
        left_width = inv_summary.visible_len(left[0])
        for line in combined:
            self.assertGreaterEqual(inv_summary.visible_len(line), left_width)


class TestColorOffAsciiOnlyOutput(unittest.TestCase):
    """Tests that plain ascii rendering has no ANSI escapes or unicode box glyphs."""

    def test_no_esc_bytes(self) -> None:
        text = _render_plain()
        encoded = text.encode("ascii", "backslashreplace")
        self.assertIsNone(_ESC_RE.search(encoded))

    def test_ascii_box_glyphs_only(self) -> None:
        text = _render_plain()
        box_chars = {ch for ch in text if ch in _UNICODE_BOX_CHARS or ch in _ASCII_BOX_CHARS}
        self.assertTrue(box_chars.issubset(_ASCII_BOX_CHARS))
        self.assertFalse(any(ch in _UNICODE_BOX_CHARS for ch in text))


class TestEmitBytePath(unittest.TestCase):
    """Tests that emit() writes real UTF-8 box glyphs, not escaped sequences."""

    def _capture_emit(self, line: str) -> bytes:
        import io
        import unittest.mock
        buf = io.BytesIO()
        mock_stdout = unittest.mock.MagicMock()
        mock_stdout.buffer = buf
        with unittest.mock.patch.object(inv_summary.sys, "stdout", mock_stdout):
            inv_summary.emit(line)
        return buf.getvalue()

    def test_emit_utf8_box_glyph_bytes(self) -> None:
        emitted = self._capture_emit("│ test │")
        self.assertIn("│".encode("utf-8"), emitted)
        self.assertNotIn(b"\\u2502", emitted)

    def test_main_without_ascii_only_emits_utf8_box_glyphs(self) -> None:
        import subprocess
        script = str(Path(__file__).parent.parent.parent / "bundle" / ".ralph" / "python" / "ralph-invocation-summary-text.py")
        result = subprocess.run(
            [
                sys.executable, script,
                "--color",
                "1", "cursor", "gpt-5", "1000", "200", "5",
                "0", "0", "0", "0", "0", "0",
                "none", "{}", "1", "6", "5", "9",
            ],
            capture_output=True,
        )
        emitted = result.stdout
        self.assertIn("│".encode("utf-8"), emitted)
        self.assertNotIn(b"\\u2502", emitted)


class TestClassifyToolCallsFamilyRows(unittest.TestCase):
    """Tests that tool detail rows include classify_tool_calls family labels."""

    def test_all_families_render(self) -> None:
        text = _render_plain()
        for family in ("native", "ralph", "mcp", "hooks", "unknown"):
            self.assertIn(family, text, msg=f"missing family row: {family}")

    def test_tool_names_and_counts_present(self) -> None:
        text = _render_plain()
        self.assertIn("ralph_proxy_read", text)
        self.assertIn("mcp__brave", text)
        self.assertIn("custom_tool", text)
        self.assertIn("compact-bash", text)
        self.assertIn("|     3 |", text)

    def test_display_tool_family_mapping(self) -> None:
        self.assertEqual(inv_summary.display_tool_family("ralph_proxy_read"), "ralph")
        self.assertEqual(inv_summary.display_tool_family("mcp__brave"), "mcp")
        self.assertEqual(inv_summary.display_tool_family("rewrite-bash"), "hooks")
        self.assertEqual(inv_summary.display_tool_family("read"), "native")
        self.assertEqual(inv_summary.display_tool_family("custom_tool"), "unknown")


class TestUsageUnsupportedRendering(unittest.TestCase):
    """Antigravity records mark usage_unsupported: token/cache cells render n/a."""

    def test_unsupported_usage_shows_na(self) -> None:
        usage_json = json.dumps(
            {"usage_unsupported": True, "tool_calls_by_tool": {"ralph_proxy_glob": 2}}
        )
        text = _render_plain(
            runtime="antigravity",
            model="antigravity/test-model",
            input_tokens="0",
            output_tokens="0",
            tool_calls="2",
            cache_create="0",
            cache_read="0",
            cache_hit="0",
            usage_json=usage_json,
        )
        self.assertIn("n/a", text)
        input_line = next(line for line in text.splitlines() if "Input" in line)
        self.assertIn("n/a", input_line)
        output_line = next(line for line in text.splitlines() if "Output" in line)
        self.assertIn("n/a", output_line)
        cache_read_line = next(line for line in text.splitlines() if "Cache Read" in line)
        self.assertIn("n/a", cache_read_line)
        cache_write_line = next(line for line in text.splitlines() if "Cache Write" in line)
        self.assertIn("n/a", cache_write_line)
        cache_hit_line = next(line for line in text.splitlines() if "Cache Hit" in line)
        self.assertIn("n/a", cache_hit_line)
        tool_calls_line = next(line for line in text.splitlines() if "Tool Calls" in line)
        self.assertIn("2", tool_calls_line)

    def test_supported_usage_unaffected(self) -> None:
        text = _render_plain()
        input_line = next(line for line in text.splitlines() if "Input" in line)
        self.assertNotIn("n/a", input_line)


if __name__ == "__main__":
    unittest.main()
