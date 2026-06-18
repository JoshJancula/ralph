#!/usr/bin/env python3
"""Unit tests for token_estimate.py.

Tests covering empty input, known string estimates, punctuation/code-heavy samples,
stdin/file parity through main(), and help output behavior.
"""

from __future__ import annotations

import io
import sys
import tempfile
import unittest
from pathlib import Path

# Add the tests/python directory to the path for importing ralph_script_loader
sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

# Load the token_estimate module
token_estimate = load_ralph_script("token_estimate")


class TestEstimateTokens(unittest.TestCase):
    """Tests for estimate_tokens function."""

    def test_empty_string_returns_zero(self) -> None:
        """Empty input should return 0 tokens."""
        self.assertEqual(token_estimate.estimate_tokens(""), 0)

    def test_whitespace_only_returns_zero(self) -> None:
        """Whitespace-only input should return 0 tokens."""
        self.assertEqual(token_estimate.estimate_tokens("   "), 0)
        self.assertEqual(token_estimate.estimate_tokens("\t\n\r"), 0)

    def test_single_character_word(self) -> None:
        """Single character word should return 1 token."""
        self.assertEqual(token_estimate.estimate_tokens("a"), 1)
        self.assertEqual(token_estimate.estimate_tokens("x"), 1)

    def test_known_string_estimates(self) -> None:
        """Test known string estimates with expected token counts.

        Words are split into chunks of max 4 chars, each counting as 1 token.
        Punctuation counts as 1 token each.
        """
        # 4-char word = 1 token
        self.assertEqual(token_estimate.estimate_tokens("abcd"), 1)
        # 5-char word = 2 tokens (4+1)
        self.assertEqual(token_estimate.estimate_tokens("abcde"), 2)
        # 8-char word = 2 tokens
        self.assertEqual(token_estimate.estimate_tokens("abcdefgh"), 2)
        # 9-char word = 3 tokens (4+4+1)
        self.assertEqual(token_estimate.estimate_tokens("abcdefghi"), 3)

    def test_multiple_words(self) -> None:
        """Multiple words sum their token counts."""
        # "abcd" (1) + "efgh" (1) = 2
        self.assertEqual(token_estimate.estimate_tokens("abcd efgh"), 2)
        # "abc" (1) + "def" (1) + "ghi" (1) = 3
        self.assertEqual(token_estimate.estimate_tokens("abc def ghi"), 3)

    def test_underscore_treated_as_word_char(self) -> None:
        """Underscore should be treated as part of words."""
        # "snake_case" is 10 chars: (10 + 3) // 4 = 3 tokens
        self.assertEqual(token_estimate.estimate_tokens("snake_case"), 3)
        # "snake_case_name" is 15 chars: (15 + 3) // 4 = 4 tokens
        self.assertEqual(token_estimate.estimate_tokens("snake_case_name"), 4)

    def test_punctuation_counts_as_token(self) -> None:
        """Each punctuation symbol counts as one token."""
        self.assertEqual(token_estimate.estimate_tokens("."), 1)
        self.assertEqual(token_estimate.estimate_tokens(","), 1)
        self.assertEqual(token_estimate.estimate_tokens(";"), 1)
        self.assertEqual(token_estimate.estimate_tokens("!"), 1)
        self.assertEqual(token_estimate.estimate_tokens("?"), 1)

    def test_punctuation_code_heavy_samples(self) -> None:
        """Test punctuation and code-heavy samples."""
        # Python-like code: "def hello():"
        # "def" (1) + "hello" (2) + "(" (1) + ")" (1) + ":" (1) = 6
        self.assertEqual(token_estimate.estimate_tokens("def hello():"), 6)

        # JSON-like: '{"key": "value"}'
        # "{" (1) + "\" (1) + "key" (1) + "\" (1) + ":" (1) + "\" (1) + "value" (2) + "\" (1) + "}" (1) = 10
        self.assertEqual(token_estimate.estimate_tokens('{"key": "value"}'), 10)

        # Shell command: "git status"
        # "git" (1) + "status" (2) = 3
        self.assertEqual(token_estimate.estimate_tokens("git status"), 3)

        # More complex: "import os; print('hello')"
        # "import" (2) + "os" (1) + ";" (1) + "print" (2) + "(" (1) + "'" (1) + "hello" (2) + "'" (1) + ")" (1) = 12
        self.assertEqual(token_estimate.estimate_tokens("import os; print('hello')"), 12)

    def test_numbers_treated_as_word_chars(self) -> None:
        """Numbers should be treated as word characters."""
        self.assertEqual(token_estimate.estimate_tokens("1234"), 1)
        self.assertEqual(token_estimate.estimate_tokens("12345"), 2)  # 5 chars = 2 tokens
        # "version_2" is 9 chars: (9 + 3) // 4 = 3 tokens
        self.assertEqual(token_estimate.estimate_tokens("version_2"), 3)

    def test_mixed_content(self) -> None:
        """Test mixed alphanumeric and punctuation."""
        # "func(arg1, arg2)"
        # "func" (1) + "(" (1) + "arg1" (1) + "," (1) + "arg2" (1) + ")" (1) = 6
        self.assertEqual(token_estimate.estimate_tokens("func(arg1, arg2)"), 6)

    def test_various_whitespace(self) -> None:
        """Various whitespace should be ignored."""
        # Same content with different whitespace
        self.assertEqual(
            token_estimate.estimate_tokens("a b"),
            token_estimate.estimate_tokens("a\tb")
        )
        self.assertEqual(
            token_estimate.estimate_tokens("a b"),
            token_estimate.estimate_tokens("a\n\n  b")
        )


class TestReadAll(unittest.TestCase):
    """Tests for read_all function."""

    def test_read_from_textio(self) -> None:
        """Test reading from a TextIO stream."""
        stream = io.StringIO("test content")
        result = token_estimate.read_all(stream)
        self.assertEqual(result, "test content")

    def test_read_empty_stream(self) -> None:
        """Test reading from an empty stream."""
        stream = io.StringIO("")
        result = token_estimate.read_all(stream)
        self.assertEqual(result, "")


class TestMainFunction(unittest.TestCase):
    """Tests for main function."""

    def setUp(self) -> None:
        """Set up test fixtures."""
        self.temp_dir = tempfile.mkdtemp()
        self.addCleanup(self._cleanup_temp_dir)

    def _cleanup_temp_dir(self) -> None:
        """Clean up temporary directory."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _create_test_file(self, content: str) -> Path:
        """Create a test file with given content."""
        temp_path = Path(self.temp_dir) / "test_input.txt"
        temp_path.write_text(content, encoding="utf-8")
        return temp_path

    def test_main_help_flag(self) -> None:
        """Test --help flag outputs usage and returns 0."""
        # Capture stderr
        old_stderr = sys.stderr
        sys.stderr = io.StringIO()

        try:
            result = token_estimate.main(["--help"])
            output = sys.stderr.getvalue()

            self.assertEqual(result, 0)
            self.assertIn("Usage:", output)
            self.assertIn("token_estimate.py", output)
        finally:
            sys.stderr = old_stderr

    def test_main_short_help_flag(self) -> None:
        """Test -h flag outputs usage and returns 0."""
        old_stderr = sys.stderr
        sys.stderr = io.StringIO()

        try:
            result = token_estimate.main(["-h"])
            output = sys.stderr.getvalue()

            self.assertEqual(result, 0)
            self.assertIn("Usage:", output)
        finally:
            sys.stderr = old_stderr

    def test_main_with_file_argument(self) -> None:
        """Test main with a file argument."""
        test_file = self._create_test_file("hello world")

        # Capture stdout
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()

        try:
            result = token_estimate.main([str(test_file)])
            output = sys.stdout.getvalue().strip()

            self.assertEqual(result, 0)
            # "hello" (2) + "world" (2) = 4 tokens
            self.assertEqual(output, "4")
        finally:
            sys.stdout = old_stdout

    def test_main_stdin_file_parity(self) -> None:
        """Test stdin and file input produce same results."""
        content = "def hello():\n    pass"

        # File input
        test_file = self._create_test_file(content)

        old_stdout = sys.stdout
        old_stdin = sys.stdin

        try:
            # File result
            sys.stdout = io.StringIO()
            token_estimate.main([str(test_file)])
            file_result = sys.stdout.getvalue().strip()

            # Stdin result (simulate by replacing stdin)
            sys.stdout = io.StringIO()
            sys.stdin = io.StringIO(content)
            token_estimate.main([])
            stdin_result = sys.stdout.getvalue().strip()

            self.assertEqual(file_result, stdin_result)
            # "def" (1) + "hello" (2) + "(" (1) + ")" (1) + ":" (1) + "pass" (1) = 7
            self.assertEqual(file_result, "7")
        finally:
            sys.stdout = old_stdout
            sys.stdin = old_stdin

    def test_main_empty_file(self) -> None:
        """Test main with an empty file."""
        test_file = self._create_test_file("")

        old_stdout = sys.stdout
        sys.stdout = io.StringIO()

        try:
            result = token_estimate.main([str(test_file)])
            output = sys.stdout.getvalue().strip()

            self.assertEqual(result, 0)
            self.assertEqual(output, "0")
        finally:
            sys.stdout = old_stdout

    def test_main_with_code_heavy_content(self) -> None:
        """Test main with code-heavy content."""
        code = 'import json; data = {"key": "value"}'
        test_file = self._create_test_file(code)

        old_stdout = sys.stdout
        sys.stdout = io.StringIO()

        try:
            result = token_estimate.main([str(test_file)])
            output = sys.stdout.getvalue().strip()

            self.assertEqual(result, 0)
            # Verify it's a positive integer
            self.assertTrue(output.isdigit())
            self.assertGreater(int(output), 0)
        finally:
            sys.stdout = old_stdout


class TestEdgeCases(unittest.TestCase):
    """Edge case tests."""

    def test_unicode_characters(self) -> None:
        """Test handling of unicode characters."""
        # Unicode treated as punctuation (not alnum or underscore)
        result = token_estimate.estimate_tokens("café")
        # "caf" (1) + "é" (1) + "" (1?) - let's check: c,a,f are alnum, é is not alnum
        # Actually é is alnum in unicode
        self.assertGreater(result, 0)

    def test_special_characters_as_punctuation(self) -> None:
        """Test special characters treated as punctuation."""
        # Various brackets and symbols: [ ] { } | < >
        self.assertEqual(token_estimate.estimate_tokens("[]{}|<>"), 7)

    def test_very_long_word(self) -> None:
        """Test very long word token estimation."""
        long_word = "a" * 100
        # (100 + 3) // 4 = 25 tokens
        expected = (100 + 3) // 4
        self.assertEqual(token_estimate.estimate_tokens(long_word), expected)

    def test_only_punctuation(self) -> None:
        """Test string with only punctuation."""
        self.assertEqual(token_estimate.estimate_tokens("..."), 3)
        self.assertEqual(token_estimate.estimate_tokens("!!!"), 3)
        self.assertEqual(token_estimate.estimate_tokens("?!?"), 3)


if __name__ == "__main__":
    unittest.main()
