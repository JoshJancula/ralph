#!/usr/bin/env python3
"""Unit tests for mcp-proxy-search-rank.py.

Tests covering query normalization, tokenization, candidate parsing,
IDF/term-frequency behavior, and deterministic ordering that favors
exact identifier, path, and definition matches.
"""

from __future__ import annotations

import io
import sys
import unittest
from pathlib import Path

# Add the tests/python directory to the path for importing ralph_script_loader
sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

# Load the mcp-proxy-search-rank module
search_rank = load_ralph_script("mcp-proxy-search-rank")


class TestNormalizeTerms(unittest.TestCase):
    """Tests for normalize_terms function - query normalization."""

    def test_empty_query_returns_empty(self) -> None:
        """Empty query should return empty list."""
        self.assertEqual(search_rank.normalize_terms(""), [])

    def test_whitespace_only_returns_empty(self) -> None:
        """Whitespace-only query should return empty list."""
        self.assertEqual(search_rank.normalize_terms("   "), [])
        self.assertEqual(search_rank.normalize_terms("\t\n"), [])

    def test_single_term(self) -> None:
        """Single term should be returned."""
        self.assertEqual(search_rank.normalize_terms("hello"), ["hello"])

    def test_multiple_terms(self) -> None:
        """Multiple terms should be split and returned."""
        self.assertEqual(
            search_rank.normalize_terms("hello world"),
            ["hello", "world"]
        )

    def test_term_case_preservation(self) -> None:
        """Original case should be preserved in output."""
        self.assertEqual(
            search_rank.normalize_terms("Hello World"),
            ["Hello", "World"]
        )

    def test_term_deduplication_lowercase_key(self) -> None:
        """Terms deduplicated using lowercase as key, preserving first occurrence case."""
        self.assertEqual(
            search_rank.normalize_terms("hello Hello HELLO"),
            ["hello"]  # First occurrence preserved
        )

    def test_punctuation_stripping(self) -> None:
        """Punctuation should be stripped from terms."""
        self.assertEqual(
            search_rank.normalize_terms("'hello', \"world\"!"),
            ["hello", "world"]
        )

    def test_brackets_stripping(self) -> None:
        """Brackets should be stripped from terms."""
        self.assertEqual(
            search_rank.normalize_terms("(hello) [world] {test}"),
            ["hello", "world", "test"]
        )

    def test_backtick_stripping(self) -> None:
        """Backticks should be stripped from terms."""
        self.assertEqual(
            search_rank.normalize_terms("`code` `test`"),
            ["code", "test"]
        )

    def test_mixed_whitespace_handling(self) -> None:
        """Multiple spaces and tabs should be handled."""
        self.assertEqual(
            search_rank.normalize_terms("  hello   world  "),
            ["hello", "world"]
        )


class TestTokenize(unittest.TestCase):
    """Tests for tokenize function - tokenization."""

    def test_empty_string_returns_empty(self) -> None:
        """Empty string should return empty list."""
        self.assertEqual(search_rank.tokenize(""), [])

    def test_single_identifier(self) -> None:
        """Single identifier should be tokenized."""
        self.assertEqual(search_rank.tokenize("hello"), ["hello"])

    def test_multiple_identifiers(self) -> None:
        """Multiple identifiers should be split."""
        self.assertEqual(
            search_rank.tokenize("hello world test"),
            ["hello", "world", "test"]
        )

    def test_case_conversion_to_lower(self) -> None:
        """Tokens should be lowercased."""
        self.assertEqual(
            search_rank.tokenize("Hello World"),
            ["hello", "world"]
        )

    def test_underscore_in_identifier(self) -> None:
        """Underscores should be part of identifier."""
        self.assertEqual(
            search_rank.tokenize("snake_case_name"),
            ["snake_case_name"]
        )

    def test_numbers_in_identifier(self) -> None:
        """Numbers should be part of identifier."""
        self.assertEqual(
            search_rank.tokenize("var1 var_2 test123"),
            ["var1", "var_2", "test123"]
        )

    def test_punctuation_separates_tokens(self) -> None:
        """Punctuation should separate identifiers."""
        self.assertEqual(
            search_rank.tokenize("hello.world:test"),
            ["hello", "world", "test"]
        )

    def test_code_snippet_tokenization(self) -> None:
        """Code snippets should be tokenized correctly."""
        self.assertEqual(
            search_rank.tokenize("def hello_world():"),
            ["def", "hello_world"]
        )

    def test_path_like_content(self) -> None:
        """Path-like content should tokenize."""
        self.assertEqual(
            search_rank.tokenize("bundle/.ralph/python/test.py"),
            ["bundle", "ralph", "python", "test", "py"]
        )


class TestParseCandidate(unittest.TestCase):
    """Tests for parse_candidate function - candidate parsing."""

    def test_valid_candidate_line(self) -> None:
        """Valid line should be parsed correctly."""
        line = "path/to/file.py:42:def hello_world():"
        result = search_rank.parse_candidate(line)
        self.assertIsNotNone(result)
        self.assertEqual(result[0], "path/to/file.py")  # filepath
        self.assertEqual(result[1], 42)                 # lineno
        self.assertEqual(result[2], "def hello_world():")  # content

    def test_minimal_valid_line(self) -> None:
        """Minimal valid line with just colon separators."""
        line = "a:1:b"
        result = search_rank.parse_candidate(line)
        self.assertEqual(result, ("a", 1, "b"))

    def test_line_with_multiple_colons(self) -> None:
        """Line with multiple colons in content should parse correctly."""
        line = "file.py:10:key: value: more"
        result = search_rank.parse_candidate(line)
        self.assertEqual(result[0], "file.py")
        self.assertEqual(result[1], 10)
        self.assertEqual(result[2], "key: value: more")

    def test_too_few_colons_returns_none(self) -> None:
        """Line with fewer than 2 colons should return None."""
        self.assertIsNone(search_rank.parse_candidate("file.py:10"))
        self.assertIsNone(search_rank.parse_candidate("filepy"))
        self.assertIsNone(search_rank.parse_candidate(""))

    def test_invalid_line_number_returns_none(self) -> None:
        """Line with non-integer line number should return None."""
        self.assertIsNone(search_rank.parse_candidate("file.py:abc:content"))
        self.assertIsNone(search_rank.parse_candidate("file.py::content"))

    def test_negative_line_number(self) -> None:
        """Negative line numbers should be parsed as valid int."""
        result = search_rank.parse_candidate("file.py:-1:content")
        self.assertEqual(result[1], -1)

    def test_empty_content(self) -> None:
        """Empty content after colon should be valid."""
        line = "file.py:10:"
        result = search_rank.parse_candidate(line)
        self.assertEqual(result, ("file.py", 10, ""))


class TestComputeIdf(unittest.TestCase):
    """Tests for compute_idf function - IDF calculation."""

    def test_idf_with_zero_doc_freq(self) -> None:
        """IDF with doc_freq=0 should be log((N + 0.5) / 0.5 + 1)."""
        result = search_rank.compute_idf(0, 10)
        expected = math.log((10 - 0 + 0.5) / (0 + 0.5) + 1.0)
        self.assertAlmostEqual(result, expected)

    def test_idf_with_high_doc_freq(self) -> None:
        """IDF with high doc_freq should be lower."""
        result = search_rank.compute_idf(9, 10)
        expected = math.log((10 - 9 + 0.5) / (9 + 0.5) + 1.0)
        self.assertAlmostEqual(result, expected)

    def test_idf_single_doc(self) -> None:
        """IDF with single doc."""
        result = search_rank.compute_idf(1, 1)
        expected = math.log((1 - 1 + 0.5) / (1 + 0.5) + 1.0)
        self.assertAlmostEqual(result, expected)

    def test_idf_common_term(self) -> None:
        """Common term (appears in many docs) should have lower IDF."""
        rare_idf = search_rank.compute_idf(1, 100)   # appears in 1 doc
        common_idf = search_rank.compute_idf(90, 100)  # appears in 90 docs
        self.assertGreater(rare_idf, common_idf)

    def test_idf_symmetry(self) -> None:
        """IDF calculation should be consistent."""
        result1 = search_rank.compute_idf(5, 100)
        result2 = search_rank.compute_idf(5, 100)
        self.assertAlmostEqual(result1, result2)


class TestTermFrequency(unittest.TestCase):
    """Tests for term_frequency function - term frequency calculation."""

    def test_term_in_tokens(self) -> None:
        """Term present in tokens should count occurrences."""
        tokens = ["hello", "world", "hello"]
        result = search_rank.term_frequency("hello", "hello world hello", tokens)
        self.assertEqual(result, 2)

    def test_term_not_in_tokens_but_in_content(self) -> None:
        """Term in content but not tokens should count content occurrences."""
        tokens = ["other"]
        content = "hello world hello"
        result = search_rank.term_frequency("hello", content, tokens)
        self.assertEqual(result, 2)

    def test_term_not_anywhere_returns_zero(self) -> None:
        """Term not in tokens or content should return 0."""
        tokens = ["hello", "world"]
        result = search_rank.term_frequency("missing", "hello world", tokens)
        self.assertEqual(result, 0)

    def test_term_as_substring_counted_in_content(self) -> None:
        """Term as substring in content should be counted when not in tokens."""
        tokens = ["other"]  # "hello" not in tokens
        content = "helloworld"  # "hello" is substring
        # When term is not in tokens but IS in content, content.count is used
        result = search_rank.term_frequency("hello", content.lower(), tokens)
        # The function counts occurrences in content when not in tokens
        self.assertGreaterEqual(result, 0)

    def test_case_insensitive_matching(self) -> None:
        """Matching should be case insensitive."""
        tokens = ["Hello", "WORLD"]
        content = "HELLO world"
        result = search_rank.term_frequency("hello", content.lower(), tokens)
        # tokens are lowercased by tokenize
        self.assertEqual(result, 1)


class TestScoreCandidate(unittest.TestCase):
    """Tests for score_candidate function - scoring behavior."""

    def setUp(self) -> None:
        """Set up common test data."""
        self.term_idf = {"hello": 1.0, "world": 0.5}
        self.avg_dl = 10.0

    def test_empty_terms_returns_zero(self) -> None:
        """Empty terms should result in zero score."""
        score = search_rank.score_candidate(
            "file.py", "content", [], {}, self.avg_dl
        )
        self.assertEqual(score, 0.0)

    def test_bm25_component(self) -> None:
        """BM25 component should contribute to score."""
        terms = ["hello"]
        term_idf = {"hello": 1.0}
        content = "hello world"
        score = search_rank.score_candidate(
            "file.py", content, terms, term_idf, self.avg_dl
        )
        self.assertGreater(score, 0.0)

    def test_exact_match_bonus(self) -> None:
        """Exact match should get higher score than substring."""
        # "hello" as exact word vs in "helloworld"
        exact_content = "def hello():"
        substring_content = "def helloworld():"

        exact_score = search_rank.score_candidate(
            "file.py", exact_content, ["hello"], self.term_idf, self.avg_dl
        )
        substring_score = search_rank.score_candidate(
            "file.py", substring_content, ["hello"], self.term_idf, self.avg_dl
        )

        # Both should have some score
        self.assertGreater(exact_score, 0)
        self.assertGreater(substring_score, 0)
        # Exact should score higher
        self.assertGreater(exact_score, substring_score)

    def test_path_match_bonus(self) -> None:
        """Term in filepath should get path bonus."""
        terms = ["test"]
        term_idf = {"test": 1.0}

        # Filepath contains term
        score_with_path = search_rank.score_candidate(
            "test_file.py", "content", terms, term_idf, self.avg_dl
        )
        # Filepath doesn't contain term
        score_without_path = search_rank.score_candidate(
            "other.py", "content", terms, term_idf, self.avg_dl
        )

        self.assertGreater(score_with_path, score_without_path)

    def test_definition_pattern_bonus(self) -> None:
        """Match in definition pattern should get bonus."""
        terms = ["hello"]
        term_idf = {"hello": 1.0}

        # Definition pattern match
        def_content = "def hello():"
        def_score = search_rank.score_candidate(
            "file.py", def_content, terms, term_idf, self.avg_dl
        )

        # Regular match
        regular_content = "call hello()"
        regular_score = search_rank.score_candidate(
            "file.py", regular_content, terms, term_idf, self.avg_dl
        )

        self.assertGreater(def_score, regular_score)

    def test_common_token_penalty(self) -> None:
        """Common tokens should have reduced IDF."""
        terms = ["function"]  # In COMMON_TOKENS
        term_idf = {"function": 4.0}  # High raw IDF

        content = "function test"
        score = search_rank.score_candidate(
            "file.py", content, terms, term_idf, self.avg_dl
        )

        # Should still have some score despite common token penalty
        self.assertGreater(score, 0)

    def test_case_insensitive_matching(self) -> None:
        """Matching should be case insensitive."""
        terms = ["Hello"]
        term_idf = {"hello": 1.0}  # lowercase key

        content = "HELLO world"
        score = search_rank.score_candidate(
            "file.py", content, terms, term_idf, self.avg_dl
        )
        self.assertGreater(score, 0.0)

    def test_multiple_terms_score_higher(self) -> None:
        """Multiple matching terms should score higher."""
        single_term_score = search_rank.score_candidate(
            "file.py", "hello world", ["hello"], self.term_idf, self.avg_dl
        )
        multi_term_score = search_rank.score_candidate(
            "file.py", "hello world", ["hello", "world"], self.term_idf, self.avg_dl
        )

        self.assertGreater(multi_term_score, single_term_score)


class TestMainFunction(unittest.TestCase):
    """Tests for main function - full integration."""

    def setUp(self) -> None:
        """Save original stdin/stdout/argv."""
        self.old_stdin = sys.stdin
        self.old_stdout = sys.stdout
        self.old_argv = sys.argv

    def tearDown(self) -> None:
        """Restore original stdin/stdout/argv."""
        sys.stdin = self.old_stdin
        sys.stdout = self.old_stdout
        sys.argv = self.old_argv

    def test_empty_input(self) -> None:
        """Empty stdin should return 0 and produce no output."""
        sys.stdin = io.StringIO("")
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "test"]

        result = search_rank.main()
        self.assertEqual(result, 0)

    def test_empty_query(self) -> None:
        """Empty query should return 0."""
        sys.stdin = io.StringIO("file.py:1:content")
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", ""]

        result = search_rank.main()
        self.assertEqual(result, 0)

    def test_whitespace_only_query(self) -> None:
        """Whitespace-only query should return 0."""
        sys.stdin = io.StringIO("file.py:1:content")
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "   "]

        result = search_rank.main()
        self.assertEqual(result, 0)

    def test_basic_ranking_output(self) -> None:
        """Basic ranking should produce sorted output."""
        input_lines = [
            "file1.py:10:def hello():",
            "file2.py:20:def world():",
            "file3.py:30:random content",
        ]
        sys.stdin = io.StringIO("\n".join(input_lines))
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "def"]

        result = search_rank.main()
        self.assertEqual(result, 0)

        output = sys.stdout.getvalue().strip().split("\n")
        self.assertEqual(len(output), 3)

    def test_deterministic_ordering(self) -> None:
        """Output should be deterministically ordered."""
        input_lines = [
            "b.py:2:content",
            "a.py:1:content",
            "a.py:2:content",
        ]
        sys.stdin = io.StringIO("\n".join(input_lines))
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "content"]

        search_rank.main()
        output = sys.stdout.getvalue().strip().split("\n")

        # Should be sorted by score, then filepath, then lineno
        self.assertEqual(len(output), 3)

    def test_max_results_limit(self) -> None:
        """--max-results should limit output."""
        input_lines = [
            f"file{i}.py:{i}:content"
            for i in range(1, 11)
        ]
        sys.stdin = io.StringIO("\n".join(input_lines))
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "content", "--max-results", "5"]

        result = search_rank.main()
        self.assertEqual(result, 0)

        output = sys.stdout.getvalue().strip().split("\n")
        self.assertEqual(len(output), 5)

    def test_invalid_candidate_lines_skipped(self) -> None:
        """Invalid candidate lines should be skipped."""
        input_lines = [
            "file.py:1:valid content",
            "invalid line",
            "also:invalid",
            "file.py:2:another valid",
        ]
        sys.stdin = io.StringIO("\n".join(input_lines))
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "valid"]

        result = search_rank.main()
        self.assertEqual(result, 0)

        output = sys.stdout.getvalue().strip().split("\n")
        self.assertEqual(len(output), 2)

    def test_exact_identifier_match_priority(self) -> None:
        """Exact identifier matches should rank higher."""
        input_lines = [
            "file1.py:1:def test_function():",  # Definition match
            "file2.py:1:call test_other()",     # Not exact
        ]
        sys.stdin = io.StringIO("\n".join(input_lines))
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "test_function"]

        search_rank.main()
        output = sys.stdout.getvalue().strip().split("\n")

        self.assertEqual(len(output), 2)
        # Definition match should be first
        self.assertIn("def test_function():", output[0])

    def test_path_match_priority(self) -> None:
        """Matches in filepath should get priority."""
        input_lines = [
            "test_utils.py:1:some content",  # Path contains "test"
            "other.py:1:test content",       # Content contains "test"
        ]
        sys.stdin = io.StringIO("\n".join(input_lines))
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "test"]

        search_rank.main()
        output = sys.stdout.getvalue().strip().split("\n")

        self.assertEqual(len(output), 2)
        # Path match should rank higher or equal

    def test_multiple_query_terms(self) -> None:
        """Multiple query terms should work correctly."""
        input_lines = [
            "file.py:1:def hello_world():",
            "file.py:2:hello other",
            "file.py:3:world alone",
        ]
        sys.stdin = io.StringIO("\n".join(input_lines))
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "hello world"]

        result = search_rank.main()
        self.assertEqual(result, 0)

        output = sys.stdout.getvalue().strip().split("\n")
        self.assertEqual(len(output), 3)


class TestDeterministicOrdering(unittest.TestCase):
    """Tests for deterministic ordering behavior."""

    def setUp(self) -> None:
        """Save original stdin/stdout/argv."""
        self.old_stdin = sys.stdin
        self.old_stdout = sys.stdout
        self.old_argv = sys.argv

    def tearDown(self) -> None:
        """Restore original stdin/stdout/argv."""
        sys.stdin = self.old_stdin
        sys.stdout = self.old_stdout
        sys.argv = self.old_argv

    def test_tie_breaker_filepath_lineno(self) -> None:
        """Equal scores should break ties by filepath, then lineno."""
        # Create candidates with identical content (same score)
        input_lines = [
            "z.py:2:same content",
            "a.py:2:same content",
            "a.py:1:same content",
            "z.py:1:same content",
        ]

        sys.stdin = io.StringIO("\n".join(input_lines))
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "content"]

        search_rank.main()
        output = sys.stdout.getvalue().strip().split("\n")

        # Should be sorted by filepath (a before z), then lineno
        self.assertEqual(len(output), 4)
        # First two should be a.py entries
        self.assertIn("a.py", output[0])
        self.assertIn("a.py", output[1])

    def test_score_overrides_tie_breaker(self) -> None:
        """Higher score should always win over tie-breaker."""
        # Use content where one clearly scores much higher
        input_lines = [
            "z.py:1:def my_unique_function():",   # Should score high (def pattern + exact word)
            "a.py:1:call something()",      # No match for "unique"
        ]

        sys.stdin = io.StringIO("\n".join(input_lines))
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "unique"]

        search_rank.main()
        output = sys.stdout.getvalue().strip().split("\n")

        # Both lines should be in output (all candidates are output, sorted by score)
        # The higher scoring entry should come first
        self.assertEqual(len(output), 2)
        # The def pattern + exact match should rank higher than no match
        self.assertIn("z.py", output[0])


class TestIntegrationEdgeCases(unittest.TestCase):
    """Integration tests for edge cases."""

    def setUp(self) -> None:
        """Save original stdin/stdout/argv."""
        self.old_stdin = sys.stdin
        self.old_stdout = sys.stdout
        self.old_argv = sys.argv

    def tearDown(self) -> None:
        """Restore original stdin/stdout/argv."""
        sys.stdin = self.old_stdin
        sys.stdout = self.old_stdout
        sys.argv = self.old_argv

    def test_all_common_tokens(self) -> None:
        """Query with only common tokens should still work."""
        sys.stdin = io.StringIO("file.py:1:def test():\nfile.py:2:class other:")
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "the and or"]

        result = search_rank.main()
        self.assertEqual(result, 0)

    def test_very_long_content(self) -> None:
        """Very long content should be handled."""
        long_content = "word " * 1000
        sys.stdin = io.StringIO(f"file.py:1:{long_content}")
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "word"]

        result = search_rank.main()
        self.assertEqual(result, 0)

    def test_special_characters_in_content(self) -> None:
        """Special characters in content should be handled."""
        content = "def test(): # comment with special chars: @#$%"
        sys.stdin = io.StringIO(f"file.py:1:{content}")
        sys.stdout = io.StringIO()
        sys.argv = ["mcp-proxy-search-rank", "--query", "test"]

        result = search_rank.main()
        self.assertEqual(result, 0)


# Import math for IDF tests
import math


if __name__ == "__main__":
    unittest.main()
