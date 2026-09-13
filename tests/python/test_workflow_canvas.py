#!/usr/bin/env python3
"""Tests for the backend-neutral workflow semantic cell canvas."""

from __future__ import annotations

import ast
import json
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
SNAPSHOT_DIR = Path(__file__).with_name("snapshots")
sys.path.insert(0, str(PYTHON_DIR))

import workflow_canvas as wc  # noqa: E402


def plain(spans: tuple[wc.StyledText, ...]) -> str:
    return "".join(span.text for span in spans)


def snapshot_canvas(width: int, height: int) -> wc.Canvas:
    canvas = wc.Canvas(width, height)
    inner = canvas.draw_box(
        wc.Rect(0, 0, width, height),
        title="Semantic workflow canvas",
        padding=(0, 1),
    )
    canvas.draw_text(inner.x, inner.y, inner.width, "Workflow UI · e\u0301 · 界", role="heading")
    canvas.write_spans(
        inner.x,
        inner.y + 1,
        wc.progress_spans(3, 8, inner.width, ascii_only=True),
        max_width=inner.width,
    )
    rows = (
        (False, "queued", "research", "muted"),
        (True, "running", "implement semantic canvas", "accent"),
        (False, "waiting", "operator approval", "warning"),
        (False, "succeeded", "schema contract", "success"),
    )
    for offset, (selected, state, label, role) in enumerate(rows):
        canvas.draw_row(
            wc.Rect(inner.x, inner.y + 3 + offset, inner.width, 1),
            (wc.StyledText(f" {state:<10}", role), wc.StyledText(label)),
            selected=selected,
        )

    allocation = wc.allocate_columns(
        inner.width,
        (wc.ColumnSpec(8, 1), wc.ColumnSpec(8, 2), wc.ColumnSpec(6, 1, 18)),
        gap=2,
    )
    positions = allocation.positions(inner.x)
    column_y = inner.y + 8
    for x, column_width, label, role in zip(
        positions,
        allocation.widths,
        ("STAGE", "CURRENT TODO", "STATE"),
        ("heading", "heading", "heading"),
    ):
        canvas.draw_text(x, column_y, column_width, label, role=role)

    if height >= 24:
        detail = wc.Rect(inner.x, inner.y + 10, inner.width, min(8, inner.bottom - inner.y - 11))
        detail_inner = canvas.draw_box(detail, title="Selected stage", padding=(0, 1))
        canvas.draw_text(
            detail_inner.x,
            detail_inner.y,
            detail_inner.width,
            "Implement text plus semantic roles without terminal escapes.",
            role="default",
        )
        canvas.draw_text(
            detail_inner.x,
            detail_inner.y + 2,
            detail_inner.width,
            "Next: run focused Python unit tests",
            role="command",
        )

    if width >= 120 and height >= 40:
        log_rect = wc.Rect(inner.x, inner.y + 20, inner.width, 10)
        log_inner = canvas.draw_box(log_rect, title="Plain snapshot", padding=(0, 1))
        for offset, line in enumerate(
            (
                "12:00:01 model loaded",
                "12:00:02 canvas composed overlapping cells",
                "12:00:03 wide and combining text verified",
                "12:00:04 no terminal escape sequences",
            )
        ):
            canvas.draw_text(log_inner.x, log_inner.y + offset, log_inner.width, line, role="muted")
    return canvas


class TestTextAndCells(unittest.TestCase):
    def test_cell_composition_and_semantic_spans(self) -> None:
        canvas = wc.Canvas(8, 2)
        canvas.write_spans(
            1,
            0,
            (wc.StyledText("ab", "accent"), wc.StyledText("cd", "success")),
        )
        self.assertEqual(canvas.render_plain_lines()[0], " abcd   ")
        spans = tuple(canvas.iter_spans())
        self.assertEqual(
            [(span.column, span.text, span.role, span.width) for span in spans[:4]],
            [
                (0, " ", "default", 1),
                (1, "ab", "accent", 2),
                (3, "cd", "success", 2),
                (5, "   ", "default", 3),
            ],
        )

    def test_overlapping_writes_clear_both_halves_of_wide_cells(self) -> None:
        canvas = wc.Canvas(6, 1)
        canvas.write(1, 0, "界", role="accent")
        self.assertTrue(canvas.cell(2, 0).continuation)
        canvas.write(2, 0, "x", role="failure")
        self.assertEqual(canvas.render_plain(), "  x   ")
        self.assertEqual(canvas.cell(1, 0), wc.Cell())
        canvas.write(1, 0, "好", role="success")
        self.assertEqual(canvas.render_plain(), " 好   ")
        self.assertTrue(canvas.cell(2, 0).continuation)

    def test_wide_and_combining_characters_use_display_columns(self) -> None:
        text = "A界e\u0301"
        self.assertEqual(wc.graphemes(text), ("A", "界", "e\u0301"))
        self.assertEqual(wc.display_width(text), 4)
        canvas = wc.Canvas(5, 1)
        canvas.write(0, 0, text, role="accent")
        self.assertEqual(canvas.render_plain(), text + " ")
        self.assertTrue(canvas.cell(2, 0).continuation)
        self.assertEqual(canvas.cell(3, 0).text, "e\u0301")
        self.assertEqual(sum(span.width for span in canvas.iter_spans()), 5)

    def test_clipping_never_draws_half_a_wide_character(self) -> None:
        canvas = wc.Canvas(4, 1)
        canvas.write(-1, 0, "abc", role="accent")
        canvas.write(3, 0, "界", role="failure")
        canvas.write(0, 9, "ignored")
        self.assertEqual(canvas.render_plain(), "bc  ")
        self.assertEqual(canvas.write(4, 0, "z"), 5)

    def test_ellipsis_respects_clusters_and_tiny_widths(self) -> None:
        self.assertEqual(wc.truncate_text("abcdef", 4), "abc…")
        self.assertEqual(wc.truncate_text("界界界", 5), "界界…")
        self.assertEqual(wc.truncate_text("e\u0301clair", 3), "e\u0301c…")
        self.assertEqual(wc.truncate_text("abcdef", 1, ellipsis="..."), ".")
        self.assertEqual(wc.truncate_text("abcdef", 0), "")


class TestLayoutPrimitives(unittest.TestCase):
    def test_borders_padding_and_tiny_canvases_are_safe(self) -> None:
        canvas = wc.Canvas(8, 5)
        inner = canvas.draw_box(wc.Rect(0, 0, 8, 5), padding=(1, 2), ascii_only=True)
        self.assertEqual(inner, wc.Rect(3, 2, 2, 1))
        self.assertEqual(
            canvas.render_plain(),
            "+------+\n|      |\n|      |\n|      |\n+------+",
        )
        for width, height in ((0, 0), (1, 1), (1, 3), (3, 1), (2, 2)):
            with self.subTest(size=(width, height)):
                tiny = wc.Canvas(width, height)
                tiny.draw_box(wc.Rect(0, 0, width, height), title="too long", padding=9)
                lines = tiny.render_plain_lines()
                self.assertEqual(len(lines), height)
                self.assertTrue(all(wc.display_width(line) == width for line in lines))

    def test_column_allocation_honors_weights_caps_and_tiny_sizes(self) -> None:
        specs = (wc.ColumnSpec(4, 1), wc.ColumnSpec(4, 2), wc.ColumnSpec(2, 1, 5))
        allocation = wc.allocate_columns(24, specs, gap=1)
        self.assertEqual(allocation.widths, (7, 10, 5))
        self.assertEqual(allocation.positions(2), (2, 10, 21))
        self.assertEqual(allocation.used, 24)
        tiny = wc.allocate_columns(4, specs, gap=1)
        self.assertEqual(tiny.widths, (1, 1, 0))
        self.assertEqual(tiny.used, 4)
        self.assertEqual(wc.allocate_columns(0, specs).used, 0)

    def test_selected_row_has_marker_and_focus_cells(self) -> None:
        canvas = wc.Canvas(12, 2)
        spans = (wc.StyledText(" running ", "accent"), wc.StyledText("build"))
        canvas.draw_row(wc.Rect(0, 0, 12, 1), spans, selected=True)
        canvas.draw_row(wc.Rect(0, 1, 12, 1), spans, selected=False)
        self.assertEqual(canvas.render_plain(), "> running b…\n  running b…")
        self.assertTrue(all(cell.role == "focus" for cell in canvas.cells[0]))
        self.assertEqual(canvas.cell(2, 1).role, "accent")

    def test_progress_zero_partial_complete_unknown_and_numeric_fallback(self) -> None:
        zero = wc.progress_spans(0, 10, 14, ascii_only=True)
        partial = wc.progress_spans(5, 10, 14, ascii_only=True)
        complete = wc.progress_spans(10, 10, 14, ascii_only=True)
        unknown = wc.progress_spans(3, None, 14, ascii_only=True)
        zero_total = wc.progress_spans(3, 0, 14, ascii_only=True)
        narrow = wc.progress_spans(3, 10, 4, ascii_only=True)
        self.assertEqual(plain(zero), "[-------] 0/10")
        self.assertEqual(plain(partial), "[####---] 5/10")
        self.assertEqual(plain(complete), "[######] 10/10")
        self.assertEqual(plain(unknown), "3/?           ")
        self.assertEqual(plain(zero_total), plain(unknown))
        self.assertEqual(plain(narrow), "3/10")
        self.assertEqual(complete[-1].role, "success")
        self.assertEqual(partial[1].role, "success")
        self.assertEqual(zero[2].role, "muted")


class TestPlainSnapshotsAndSafety(unittest.TestCase):
    def test_exact_plain_snapshots_at_responsive_sizes(self) -> None:
        for width, height in ((40, 12), (80, 24), (120, 40)):
            with self.subTest(size=(width, height)):
                canvas = snapshot_canvas(width, height)
                raw_lines = canvas.render_plain_lines()
                self.assertEqual(len(raw_lines), height)
                self.assertTrue(all(wc.display_width(line) == width for line in raw_lines))
                expected = json.loads(
                    (SNAPSHOT_DIR / f"workflow_canvas_{width}x{height}.json").read_text(
                        encoding="utf-8"
                    )
                )
                self.assertEqual(list(canvas.render_plain_lines(trim_trailing=True)), expected)

    def test_model_and_canvas_output_never_contains_ansi(self) -> None:
        styled = wc.StyledText("\x1b[31mfailed\x1b[0m", "failure")
        self.assertEqual(styled.text, "failed")
        cell = wc.Cell("\x1b[31mfailed\x1b[0m", "failure")
        span = wc.StyledSpan(0, 0, "\x1b[31mfailed\x1b[0m", "failure", 999)
        self.assertEqual((cell.text, span.text, span.width), ("failed", "failed", 6))
        canvas = wc.Canvas(12, 1)
        canvas.write_spans(0, 0, (styled, wc.StyledText("\x1b]0;title\x07 ok", "success")))
        outputs = [canvas.render_plain()]
        outputs.extend(cell.text + cell.role for row in canvas.cells for cell in row)
        outputs.extend(span.text + span.role for span in canvas.iter_spans())
        self.assertTrue(all("\x1b" not in output for output in outputs))
        with self.assertRaises(ValueError):
            wc.StyledText("text", "\x1b[31mfailure")

    def test_canvas_module_does_not_import_a_screen_backend(self) -> None:
        source_path = PYTHON_DIR / "workflow_canvas.py"
        tree = ast.parse(source_path.read_text(encoding="utf-8"))
        imports = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imports.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imports.add(node.module)
        self.assertNotIn("curses", imports)


if __name__ == "__main__":
    unittest.main()
