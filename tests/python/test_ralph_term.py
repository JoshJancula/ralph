#!/usr/bin/env python3
"""Tests for ralph_term shared terminal primitives.

Coverage: no-color, 16-color, 256-color, ASCII fallback, clipping with ANSI
awareness, and environment-based capability detection.
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))

import ralph_term as rt  # noqa: E402


class TestStyleColorDepths(unittest.TestCase):
    def test_no_color_emits_no_sequences(self) -> None:
        style = rt.Style(rt.NO_COLOR)
        for role in rt.SEMANTIC_ROLES:
            self.assertEqual(style(role), "", msg=role)
        self.assertEqual(style.wrap("success", "ok"), "ok")
        self.assertEqual(style.bold, "")
        self.assertEqual(style.soft_fg_reset, "")

    def test_16_color_uses_basic_sgr(self) -> None:
        style = rt.Style(rt.ANSI_16)
        self.assertEqual(style("success"), "\033[32m")
        self.assertEqual(style("failure"), "\033[31m")
        self.assertEqual(style("reset"), "\033[0m")
        self.assertEqual(style.bold, "\033[1m")
        self.assertEqual(style.soft_fg_reset, "\033[39m")

    def test_256_color_uses_extended_palette(self) -> None:
        style = rt.Style(rt.ANSI_256)
        self.assertIn("38;5;", style("success"))
        self.assertIn("38;5;", style("failure"))
        self.assertIn("38;5;", style("path"))
        self.assertEqual(style("reset"), "\033[0m")

    def test_256_bg_codes_supported(self) -> None:
        seq = rt.resolve_color_code(rt.ANSI_256, "", "48;5;22")
        self.assertIn("48;5;22", seq)

    def test_wrap_applies_and_resets(self) -> None:
        style = rt.Style(rt.ANSI_16)
        wrapped = style.wrap("success", "ok")
        self.assertIn("\033[32m", wrapped)
        self.assertIn("\033[0m", wrapped)

    def test_custom_palette_overrides_default(self) -> None:
        style = rt.Style(rt.ANSI_16, palette={"success": ("34", "38;5;69")})
        self.assertEqual(style("success"), "\033[34m")
        style256 = rt.Style(rt.ANSI_256, palette={"success": ("34", "38;5;69")})
        self.assertEqual(style256("success"), "\033[38;5;69m")

    def test_depth_zero_overrides_even_with_palette(self) -> None:
        style = rt.Style(rt.NO_COLOR, palette={"success": ("34", "38;5;69")})
        self.assertEqual(style("success"), "")


class TestSymbols(unittest.TestCase):
    def test_ascii_symbols(self) -> None:
        sym = rt.Symbols(ascii_only=True)
        self.assertEqual(sym.bullet, "*")
        self.assertEqual(sym.branch, "-")
        self.assertEqual(sym.vbar, "|")
        self.assertEqual(sym.spinner, "~")
        self.assertEqual(sym.rule, "-")

    def test_unicode_symbols(self) -> None:
        sym = rt.Symbols(ascii_only=False)
        self.assertEqual(sym.bullet, "●")
        self.assertEqual(sym.branch, "└")
        self.assertEqual(sym.vbar, "│")
        self.assertEqual(sym.spinner, "⟳")
        self.assertEqual(sym.rule, "─")


class TestClipping(unittest.TestCase):
    def test_clip_no_ansi(self) -> None:
        self.assertEqual(rt.clip_text("hello world", 8), "hello...")
        self.assertEqual(rt.clip_text("hi", 8, pad=True), "hi      ")
        self.assertEqual(rt.clip_text("hello", 0), "")
        self.assertEqual(rt.clip_text("hello", 1), "h")
        self.assertEqual(rt.clip_text("hello", 3), "hel")
        self.assertEqual(rt.clip_text("a\tb\nc", 5), "a b c")
        self.assertEqual(rt.clip_text("", 4, pad=True), "    ")

    def test_clip_with_ansi_preserves_sequences(self) -> None:
        text = "\033[32mhello world\033[0m"
        clipped = rt.clip_text(text, 8)
        # Must contain the color open and reset and the truncated visible text.
        self.assertIn("\033[32m", clipped)
        self.assertIn("\033[0m", clipped)
        self.assertIn("hello", clipped)
        self.assertIn("...", clipped)
        self.assertEqual(rt.visible_len(clipped), 8)

    def test_pad_line_exact_width(self) -> None:
        self.assertEqual(rt.pad_line("hi", 8), "hi      ")
        self.assertEqual(rt.pad_line("very long string", 8), "very ...")

    def test_truncate_helper(self) -> None:
        self.assertEqual(rt.truncate("  hello world  ", 8), "hello...")

    def test_visible_len_and_strip_ansi(self) -> None:
        text = "\033[32mhi\033[0m there"
        self.assertEqual(rt.visible_len(text), 8)
        self.assertTrue(rt.has_ansi(text))
        self.assertEqual(rt.strip_ansi(text), "hi there")


class TestCapabilityDetection(unittest.TestCase):
    def test_no_color_env_returns_zero(self) -> None:
        caps = rt.probe_capabilities(environ={"NO_COLOR": "1"}, stdout_isatty=True)
        self.assertEqual(caps.depth, rt.NO_COLOR)
        self.assertTrue(caps.color_disabled_by_env)

    def test_dumb_term_returns_zero(self) -> None:
        caps = rt.probe_capabilities(environ={"TERM": "dumb"}, stdout_isatty=True)
        self.assertEqual(caps.depth, rt.NO_COLOR)

    def test_non_tty_returns_zero(self) -> None:
        caps = rt.probe_capabilities(stdout_isatty=False)
        self.assertEqual(caps.depth, rt.NO_COLOR)

    def test_256_color_advertised(self) -> None:
        caps = rt.probe_capabilities(
            environ={"TERM": "xterm-256color"},
            stdout_isatty=True,
        )
        self.assertEqual(caps.depth, rt.ANSI_256)
        self.assertTrue(caps.color)

    def test_basic_color_when_no_256_advertised(self) -> None:
        caps = rt.probe_capabilities(
            environ={"TERM": "xterm"},
            stdout_isatty=True,
        )
        self.assertEqual(caps.depth, rt.ANSI_16)

    def test_ascii_only_when_locale_c(self) -> None:
        caps = rt.probe_capabilities(environ={"LC_ALL": "C"}, stdout_isatty=True)
        self.assertTrue(caps.ascii_only)

    def test_ascii_override(self) -> None:
        caps = rt.probe_capabilities(
            environ={"TERM": "xterm-256color"},
            stdout_isatty=True,
            ascii_only=True,
        )
        self.assertTrue(caps.ascii_only)
        self.assertEqual(caps.depth, rt.ANSI_256)


class TestConvenienceFactories(unittest.TestCase):
    def test_plain_style_is_colorless_and_ascii(self) -> None:
        style, sym = rt.plain_style()
        self.assertEqual(style.depth, rt.NO_COLOR)
        self.assertTrue(sym.ascii_only)
        self.assertEqual(style("success"), "")

    def test_auto_style_detects_env(self) -> None:
        style, sym, caps = rt.auto_style(env={"NO_COLOR": "1"})
        self.assertEqual(style.depth, rt.NO_COLOR)
        self.assertTrue(caps.color_disabled_by_env)


class TestSplitAware(unittest.TestCase):
    def test_split_respects_visible_width(self) -> None:
        chunks = rt.split_aware("abcdefghij", 3)
        self.assertEqual(chunks, ["abc", "def", "ghi", "j"])

    def test_split_preserves_newlines(self) -> None:
        chunks = rt.split_aware("ab\ncd", 10)
        self.assertEqual(chunks, ["ab", "cd"])


if __name__ == "__main__":
    unittest.main()
