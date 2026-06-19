#!/usr/bin/env python3
"""Unit tests for compactor-dsl-rules.py.

Tests covering valid DSL rule loading, invalid schema and regex errors,
command matcher variants, replacements, keep/remove filters, head/tail/max_lines
behavior, and on_empty behavior.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

# Add the tests/python directory to the path for importing ralph_script_loader
sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

# Load the compactor-dsl-rules module
cdr = load_ralph_script("compactor-dsl-rules")


class TestDslLineFilterRule(unittest.TestCase):
    """Tests for DslLineFilterRule dataclass."""

    def test_create_minimal_rule(self) -> None:
        """A minimal rule with just rule_id and command_matcher should validate."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
        )
        errors = rule.validate()
        self.assertEqual(errors, [])

    def test_create_rule_with_all_fields(self) -> None:
        """A rule with all fields should validate."""
        rule = cdr.DslLineFilterRule(
            rule_id="full-rule",
            command_matcher=["npm", "yarn"],
            strip_ansi=True,
            remove_lines=["^DEBUG:"],
            keep_lines=["^ERROR:"],
            replacements=[{"pattern": "foo", "replacement": "bar"}],
            head=10,
            tail=5,
            max_lines=100,
            output_header="=== Output ===",
            on_empty="header",
        )
        errors = rule.validate()
        self.assertEqual(errors, [])

    def test_empty_rule_id_error(self) -> None:
        """Empty rule_id should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="",
            command_matcher="ls",
        )
        errors = rule.validate()
        self.assertIn("rule_id must not be empty", errors)

    def test_empty_string_command_matcher_error(self) -> None:
        """Empty string command_matcher should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="   ",
        )
        errors = rule.validate()
        self.assertIn("command_matcher must not be empty string", errors)

    def test_empty_list_command_matcher_error(self) -> None:
        """Empty list command_matcher should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher=[],
        )
        errors = rule.validate()
        self.assertIn("command_matcher list must not be empty", errors)

    def test_invalid_command_matcher_type_error(self) -> None:
        """Non-string, non-list command_matcher should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher=123,  # type: ignore[arg-type]
        )
        errors = rule.validate()
        self.assertTrue(
            any("command_matcher must be string or list of strings" in e for e in errors)
        )

    def test_invalid_command_matcher_list_item_error(self) -> None:
        """Non-string items in command_matcher list should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher=["ls", 123, "cat"],  # type: ignore[list-item]
        )
        errors = rule.validate()
        self.assertTrue(
            any("command_matcher list items must be strings" in e for e in errors)
        )


class TestValidationRegexErrors(unittest.TestCase):
    """Tests for regex validation errors in DslLineFilterRule."""

    def test_invalid_remove_lines_pattern(self) -> None:
        """Invalid regex in remove_lines should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            remove_lines=["[invalid("],
        )
        errors = rule.validate()
        self.assertTrue(
            any("remove_lines pattern invalid" in e for e in errors)
        )

    def test_invalid_keep_lines_pattern(self) -> None:
        """Invalid regex in keep_lines should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            keep_lines=["(?P<invalid"],
        )
        errors = rule.validate()
        self.assertTrue(
            any("keep_lines pattern invalid" in e for e in errors)
        )

    def test_invalid_replacements_pattern(self) -> None:
        """Invalid regex in replacements should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            replacements=[{"pattern": "[bad", "replacement": "good"}],
        )
        errors = rule.validate()
        self.assertTrue(
            any("replacements pattern invalid" in e for e in errors)
        )

    def test_replacement_missing_pattern_field(self) -> None:
        """Replacement missing 'pattern' field should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            replacements=[{"replacement": "bar"}],
        )
        errors = rule.validate()
        self.assertIn("replacements item missing required 'pattern' field", errors)

    def test_replacement_missing_replacement_field(self) -> None:
        """Replacement missing 'replacement' field should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            replacements=[{"pattern": "foo"}],
        )
        errors = rule.validate()
        self.assertIn("replacements item missing required 'replacement' field", errors)

    def test_replacement_non_dict_item(self) -> None:
        """Non-dict item in replacements should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            replacements=["not a dict"],  # type: ignore[list-item]
        )
        errors = rule.validate()
        self.assertIn("replacements items must be dicts, got str", errors)

    def test_valid_regex_patterns_pass(self) -> None:
        """Valid regex patterns should not produce validation errors."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            remove_lines=["^DEBUG:", "^INFO:"],
            keep_lines=["^ERROR:", "^CRITICAL:"],
            replacements=[
                {"pattern": "foo", "replacement": "bar"},
                {"pattern": r"\d+", "replacement": "[NUM]"},
            ],
        )
        errors = rule.validate()
        self.assertEqual(errors, [])


class TestValidationNumericFields(unittest.TestCase):
    """Tests for numeric field validation in DslLineFilterRule."""

    def test_head_must_be_non_negative(self) -> None:
        """head must be non-negative."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            head=-1,
        )
        errors = rule.validate()
        self.assertIn("head must be non-negative", errors)

    def test_tail_must_be_non_negative(self) -> None:
        """tail must be non-negative."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            tail=-1,
        )
        errors = rule.validate()
        self.assertIn("tail must be non-negative", errors)

    def test_max_lines_must_be_non_negative(self) -> None:
        """max_lines must be non-negative."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            max_lines=-1,
        )
        errors = rule.validate()
        self.assertIn("max_lines must be non-negative", errors)


class TestValidationOnEmpty(unittest.TestCase):
    """Tests for on_empty field validation."""

    def test_on_empty_passthrough_valid(self) -> None:
        """on_empty='passthrough' should be valid."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            on_empty="passthrough",
        )
        errors = rule.validate()
        self.assertNotIn("on_empty must be one of", " ".join(errors))

    def test_on_empty_empty_valid(self) -> None:
        """on_empty='empty' should be valid."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            on_empty="empty",
        )
        errors = rule.validate()
        self.assertNotIn("on_empty must be one of", " ".join(errors))

    def test_on_empty_header_valid(self) -> None:
        """on_empty='header' should be valid."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            on_empty="header",
        )
        errors = rule.validate()
        self.assertNotIn("on_empty must be one of", " ".join(errors))

    def test_on_empty_invalid_value_error(self) -> None:
        """Invalid on_empty value should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            on_empty="invalid",
        )
        errors = rule.validate()
        self.assertIn(
            "on_empty must be one of 'passthrough', 'empty', 'header', got 'invalid'",
            errors
        )


class TestLoadDslRules(unittest.TestCase):
    """Tests for load_dsl_rules function."""

    def test_load_single_valid_rule(self) -> None:
        """Loading a single valid rule should succeed."""
        json_text = '''
        {
            "rules": [
                {
                    "rule_id": "rule-1",
                    "command_matcher": "ls"
                }
            ]
        }
        '''
        rules, errors = cdr.load_dsl_rules(json_text)
        self.assertEqual(len(rules), 1)
        self.assertEqual(rules[0].rule_id, "rule-1")
        self.assertEqual(errors, [])

    def test_load_multiple_rules(self) -> None:
        """Loading multiple valid rules should succeed."""
        json_text = '''
        {
            "rules": [
                {"rule_id": "rule-1", "command_matcher": "ls"},
                {"rule_id": "rule-2", "command_matcher": ["npm", "yarn"]}
            ]
        }
        '''
        rules, errors = cdr.load_dsl_rules(json_text)
        self.assertEqual(len(rules), 2)
        self.assertEqual(rules[0].rule_id, "rule-1")
        self.assertEqual(rules[1].rule_id, "rule-2")
        self.assertEqual(errors, [])

    def test_invalid_json_error(self) -> None:
        """Invalid JSON should produce parse error."""
        json_text = "not valid json"
        rules, errors = cdr.load_dsl_rules(json_text)
        self.assertEqual(len(rules), 0)
        self.assertTrue(any("JSON parse error" in e for e in errors))

    def test_non_object_root_error(self) -> None:
        """Non-object root should produce error."""
        json_text = "[]"
        rules, errors = cdr.load_dsl_rules(json_text)
        self.assertEqual(len(rules), 0)
        self.assertIn("Root must be a JSON object", errors)

    def test_non_list_rules_error(self) -> None:
        """Non-list 'rules' field should produce error."""
        json_text = '{"rules": "not a list"}'
        rules, errors = cdr.load_dsl_rules(json_text)
        self.assertEqual(len(rules), 0)
        self.assertIn("'rules' field must be a list", errors)

    def test_missing_rule_id_error(self) -> None:
        """Rule missing rule_id should produce error."""
        json_text = '''
        {
            "rules": [
                {"command_matcher": "ls"}
            ]
        }
        '''
        rules, errors = cdr.load_dsl_rules(json_text)
        self.assertEqual(len(rules), 0)
        self.assertTrue(any("Missing required field 'rule_id'" in e for e in errors))

    def test_missing_command_matcher_error(self) -> None:
        """Rule missing command_matcher should produce error."""
        json_text = '''
        {
            "rules": [
                {"rule_id": "rule-1"}
            ]
        }
        '''
        rules, errors = cdr.load_dsl_rules(json_text)
        self.assertEqual(len(rules), 0)
        self.assertTrue(
            any("Missing required field 'command_matcher'" in e for e in errors)
        )

    def test_invalid_rule_skipped_with_valid_rules_loaded(self) -> None:
        """Invalid rule should be skipped but valid rules should still load."""
        json_text = '''
        {
            "rules": [
                {"rule_id": "rule-1", "command_matcher": "ls"},
                {"rule_id": "", "command_matcher": "cat"},
                {"rule_id": "rule-3", "command_matcher": ["npm"]}
            ]
        }
        '''
        rules, errors = cdr.load_dsl_rules(json_text)
        self.assertEqual(len(rules), 2)
        self.assertEqual(rules[0].rule_id, "rule-1")
        self.assertEqual(rules[1].rule_id, "rule-3")
        # When rule_id is empty, _parse_rule_dict raises ValueError for missing/invalid rule_id
        self.assertTrue(
            any("Missing required field 'rule_id'" in e for e in errors),
            f"errors: {errors}"
        )

    def test_non_object_rule_error(self) -> None:
        """Non-object in rules list should produce error."""
        json_text = '''
        {
            "rules": ["not an object"]
        }
        '''
        rules, errors = cdr.load_dsl_rules(json_text)
        self.assertEqual(len(rules), 0)
        self.assertTrue(any("must be an object, got str" in e for e in errors))

    def test_unknown_fields_error(self) -> None:
        """Unknown fields in rule should produce error."""
        json_text = '''
        {
            "rules": [
                {
                    "rule_id": "rule-1",
                    "command_matcher": "ls",
                    "unknown_field": "value"
                }
            ]
        }
        '''
        rules, errors = cdr.load_dsl_rules(json_text)
        self.assertEqual(len(rules), 0)
        self.assertTrue(any("Unknown fields" in e for e in errors))


class TestCommandMatcherVariants(unittest.TestCase):
    """Tests for compile_rule_matcher function with various matcher types."""

    def test_string_matcher_exact_command(self) -> None:
        """String matcher should match exact command name."""
        matcher = cdr.compile_rule_matcher("ls")
        self.assertTrue(matcher("ls"))
        self.assertTrue(matcher("/bin/ls"))
        self.assertTrue(matcher("/usr/bin/ls"))
        # Note: "ls -la" will match because the matcher extracts "ls" from the first token
        # and compares it to the matcher string "ls"
        self.assertTrue(matcher("ls -la"))
        self.assertFalse(matcher("cat"))

    def test_string_matcher_prefix(self) -> None:
        """String matcher with trailing space should match prefix."""
        matcher = cdr.compile_rule_matcher("npm ")
        self.assertTrue(matcher("npm test"))
        self.assertTrue(matcher("npm install"))
        self.assertTrue(matcher("npm  test"))  # Multiple spaces
        self.assertFalse(matcher("npm"))  # No arguments

    def test_string_matcher_regex(self) -> None:
        """String matcher starting and ending with / should be treated as regex."""
        matcher = cdr.compile_rule_matcher("/^git .*status$/")
        self.assertTrue(matcher("git status"))
        self.assertTrue(matcher("git  status"))
        self.assertFalse(matcher("git commit"))
        self.assertFalse(matcher("git status extra"))

    def test_list_matcher_any_match(self) -> None:
        """List matcher should match if any item matches."""
        matcher = cdr.compile_rule_matcher(["npm", "yarn"])
        self.assertTrue(matcher("npm test"))
        self.assertTrue(matcher("yarn install"))
        self.assertTrue(matcher("/usr/bin/npm"))
        self.assertFalse(matcher("pnpm"))

    def test_list_matcher_with_prefix(self) -> None:
        """List matcher with prefix patterns should work."""
        matcher = cdr.compile_rule_matcher(["npm ", "yarn "])
        self.assertTrue(matcher("npm test"))
        self.assertTrue(matcher("yarn add"))
        self.assertFalse(matcher("npm"))
        self.assertFalse(matcher("yarn"))

    def test_empty_matcher_no_match(self) -> None:
        """Empty matcher should not match anything."""
        matcher = cdr.compile_rule_matcher("")
        self.assertFalse(matcher("ls"))
        self.assertFalse(matcher(""))

    def test_empty_command_no_match(self) -> None:
        """Empty command should not match."""
        matcher = cdr.compile_rule_matcher("ls")
        self.assertFalse(matcher(""))

    def test_regex_invalid_pattern_returns_false(self) -> None:
        """Invalid regex should return False rather than raise."""
        matcher = cdr.compile_rule_matcher("/[/")
        self.assertFalse(matcher("test"))


class TestApplyLineFilterKeepRemove(unittest.TestCase):
    """Tests for apply_line_filter_rule with keep/remove filters."""

    def test_keep_lines_filter(self) -> None:
        """keep_lines should only keep matching lines."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            keep_lines=["ERROR", "CRITICAL"],
        )
        text = "INFO: starting\nERROR: something failed\nDEBUG: details\nCRITICAL: abort"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "ERROR: something failed\nCRITICAL: abort")

    def test_remove_lines_filter(self) -> None:
        """remove_lines should remove matching lines."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            remove_lines=["^DEBUG:", "^INFO:"],
        )
        text = "INFO: starting\nERROR: failed\nDEBUG: details"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "ERROR: failed")

    def test_keep_and_remove_combined(self) -> None:
        """keep and remove filters should work together."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            keep_lines=["ERROR", "WARN"],
            remove_lines=["DEBUG"],
        )
        text = "ERROR: failed\nWARN: caution\nDEBUG error"  # DEBUG error has ERROR in it
        result = cdr.apply_line_filter_rule(rule, text)
        # First keep filters to ERROR and WARN lines
        # Then remove filters out lines containing DEBUG
        # "ERROR: failed" is kept (no DEBUG), "WARN: caution" is kept
        self.assertEqual(result, "ERROR: failed\nWARN: caution")

    def test_regex_keep_filter(self) -> None:
        """keep_lines with regex patterns should work."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            keep_lines=[r"^\d{4}-\d{2}-\d{2}"],  # Date pattern
        )
        text = "2024-01-15 event\nno date here\n2024-02-20 another event"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "2024-01-15 event\n2024-02-20 another event")


class TestApplyLineFilterReplacements(unittest.TestCase):
    """Tests for apply_line_filter_rule with replacements."""

    def test_simple_replacement(self) -> None:
        """Simple pattern replacement should work."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            replacements=[{"pattern": "foo", "replacement": "bar"}],
        )
        text = "foo is here\nfoo and foo"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "bar is here\nbar and bar")

    def test_regex_replacement(self) -> None:
        """Regex pattern replacement should work."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            replacements=[{"pattern": r"\d+", "replacement": "[NUM]"}],
        )
        text = "line 1\nline 23\nno numbers"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "line [NUM]\nline [NUM]\nno numbers")

    def test_multiple_replacements(self) -> None:
        """Multiple replacements should apply in order."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            replacements=[
                {"pattern": "foo", "replacement": "bar"},
                {"pattern": "baz", "replacement": "qux"},
            ],
        )
        text = "foo and baz"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "bar and qux")

    def test_invalid_replacement_pattern_ignored(self) -> None:
        """Invalid regex in replacement should be silently ignored."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            replacements=[{"pattern": "[invalid", "replacement": "test"}],
        )
        text = "some text"
        result = cdr.apply_line_filter_rule(rule, text)
        # Invalid pattern should be skipped, text unchanged
        self.assertEqual(result, "some text")


class TestApplyLineFilterHeadTailMaxLines(unittest.TestCase):
    """Tests for apply_line_filter_rule with head/tail/max_lines."""

    def test_head_only(self) -> None:
        """head should limit to first N lines."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            head=2,
        )
        text = "line 1\nline 2\nline 3\nline 4"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "line 1\nline 2")

    def test_tail_only(self) -> None:
        """tail should limit to last N lines."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            tail=2,
        )
        text = "line 1\nline 2\nline 3\nline 4"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "line 3\nline 4")

    def test_head_and_tail_combined(self) -> None:
        """head and tail combined should apply head first, then tail."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            head=3,
            tail=2,
        )
        text = "line 1\nline 2\nline 3\nline 4\nline 5"
        # First head=3: line 1, line 2, line 3
        # Then tail=2 from those: line 2, line 3
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "line 2\nline 3")

    def test_max_lines_only(self) -> None:
        """max_lines should limit total lines."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            max_lines=2,
        )
        text = "line 1\nline 2\nline 3\nline 4"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "line 1\nline 2")

    def test_head_tail_max_lines_order(self) -> None:
        """head, tail, max_lines should apply in order."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            head=4,
            tail=3,
            max_lines=2,
        )
        text = "a\nb\nc\nd\ne\nf"
        # head=4: a, b, c, d
        # tail=3: b, c, d
        # max_lines=2: b, c
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "b\nc")

    def test_zero_tail_returns_empty_with_on_empty_empty(self) -> None:
        """tail=0 should return empty when on_empty is set to 'empty'."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            tail=0,
            on_empty="empty",
        )
        text = "line 1\nline 2"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "")


class TestApplyLineFilterStripAnsi(unittest.TestCase):
    """Tests for apply_line_filter_rule with strip_ansi."""

    def test_strip_ansi_colors(self) -> None:
        """strip_ansi should remove ANSI color codes."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            strip_ansi=True,
        )
        text = "\x1b[31mred text\x1b[0m\n\x1b[32mgreen text\x1b[0m"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "red text\ngreen text")

    def test_strip_ansi_formatting_codes(self) -> None:
        """strip_ansi should remove various ANSI formatting codes."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            strip_ansi=True,
        )
        text = "\x1b[1mbold\x1b[0m \x1b[4munderline\x1b[0m"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "bold underline")

    def test_no_strip_ansi_preserves_codes(self) -> None:
        """strip_ansi=False should preserve ANSI codes."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            strip_ansi=False,
        )
        text = "\x1b[31mred\x1b[0m"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, text)


class TestApplyLineFilterOnEmpty(unittest.TestCase):
    """Tests for apply_line_filter_rule on_empty behavior."""

    def test_on_empty_passthrough(self) -> None:
        """on_empty='passthrough' should return original text."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            remove_lines=[".*"],  # Remove everything
            on_empty="passthrough",
        )
        text = "some text here"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, text)

    def test_on_empty_empty_string(self) -> None:
        """on_empty='empty' should return empty string."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            remove_lines=[".*"],  # Remove everything
            on_empty="empty",
        )
        text = "some text here"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "")

    def test_on_empty_header_with_header(self) -> None:
        """on_empty='header' should return header when set."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            remove_lines=[".*"],  # Remove everything
            output_header="=== Header ===",
            on_empty="header",
        )
        text = "some text here"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "=== Header ===")

    def test_on_empty_header_no_header(self) -> None:
        """on_empty='header' with no output_header should return empty."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            remove_lines=[".*"],  # Remove everything
            output_header=None,
            on_empty="header",
        )
        text = "some text here"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "")

    def test_not_empty_returns_filtered_content(self) -> None:
        """Non-empty result should return filtered content, not trigger on_empty."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            keep_lines=["keep"],
            on_empty="empty",  # Would return empty if triggered
        )
        text = "keep this\nremove that"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "keep this")


class TestApplyLineFilterOutputHeader(unittest.TestCase):
    """Tests for apply_line_filter_rule with output_header."""

    def test_output_header_prepended(self) -> None:
        """output_header should be prepended to result."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            output_header="=== HEADER ===",
        )
        text = "line 1\nline 2"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "=== HEADER ===\nline 1\nline 2")

    def test_output_header_only_no_content(self) -> None:
        """Header alone with no content should still appear."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            head=0,
            output_header="=== HEADER ===",
        )
        text = "line 1\nline 2"
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, "=== HEADER ===")


class TestApplyLineFilterEmptyInput(unittest.TestCase):
    """Tests for apply_line_filter_rule with empty/None input."""

    def test_empty_string_input(self) -> None:
        """Empty string input should trigger on_empty behavior."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            on_empty="empty",
        )
        result = cdr.apply_line_filter_rule(rule, "")
        self.assertEqual(result, "")

    def test_only_whitespace_triggers_on_empty(self) -> None:
        """Whitespace-only result should trigger on_empty."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            on_empty="passthrough",
        )
        text = "   \n\t\n   "
        result = cdr.apply_line_filter_rule(rule, text)
        self.assertEqual(result, text)  # passthrough returns original


class TestPrivateFunctions(unittest.TestCase):
    """Tests for private helper functions."""

    def test_strip_ansi_removes_codes(self) -> None:
        """_strip_ansi should remove ANSI escape codes."""
        text = "\x1b[31mred\x1b[0m \x1b[32mgreen\x1b[0m"
        result = cdr._strip_ansi(text)
        self.assertEqual(result, "red green")

    def test_strip_ansi_no_codes_unchanged(self) -> None:
        """_strip_ansi should leave text without codes unchanged."""
        text = "plain text"
        result = cdr._strip_ansi(text)
        self.assertEqual(result, "plain text")

    def test_match_command_string_exact(self) -> None:
        """_match_command_string should match command names (with or without args)."""
        self.assertTrue(cdr._match_command_string("ls", "ls"))
        self.assertTrue(cdr._match_command_string("/bin/ls", "ls"))
        # Command with args still matches because only the first token is compared
        self.assertTrue(cdr._match_command_string("ls -la", "ls"))

    def test_match_command_string_empty_inputs(self) -> None:
        """_match_command_string should handle empty inputs."""
        self.assertFalse(cdr._match_command_string("", "ls"))
        self.assertFalse(cdr._match_command_string("ls", ""))
        self.assertFalse(cdr._match_command_string("", ""))


class TestExitStatusAwareFields(unittest.TestCase):
    """Tests for exit-status-aware fields (backward compatible)."""

    def test_only_on_exit_code_matches(self) -> None:
        """Rule with only_on_exit_code should apply when exit code matches."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            keep_lines=["ERROR"],
            only_on_exit_code=1,
        )
        text = "INFO: starting\nERROR: failed\nDEBUG: details"
        result = cdr.apply_line_filter_rule(rule, text, exit_status=1)
        self.assertEqual(result, "ERROR: failed")

    def test_only_on_exit_code_no_match(self) -> None:
        """Rule with only_on_exit_code should not apply when exit code differs."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            keep_lines=["ERROR"],
            only_on_exit_code=1,
        )
        text = "INFO: starting\nERROR: failed\nDEBUG: details"
        result = cdr.apply_line_filter_rule(rule, text, exit_status=0)
        self.assertEqual(result, text)

    def test_skip_on_exit_code_matches_zero(self) -> None:
        """Rule with skip_on_exit_code should apply when exit code differs."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            keep_lines=["ERROR"],
            skip_on_exit_code=0,
        )
        text = "INFO: starting\nERROR: failed\nDEBUG: details"
        result = cdr.apply_line_filter_rule(rule, text, exit_status=1)
        self.assertEqual(result, "ERROR: failed")

    def test_skip_on_exit_code_no_match(self) -> None:
        """Rule with skip_on_exit_code should not apply when exit code matches."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            keep_lines=["ERROR"],
            skip_on_exit_code=0,
        )
        text = "INFO: starting\nERROR: failed\nDEBUG: details"
        result = cdr.apply_line_filter_rule(rule, text, exit_status=0)
        self.assertEqual(result, text)

    def test_backward_compatible_no_exit_conditions(self) -> None:
        """Rule without exit-status conditions should always apply (backward compatible)."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            keep_lines=["ERROR"],
        )
        text = "INFO: starting\nERROR: failed\nDEBUG: details"
        result_exit_0 = cdr.apply_line_filter_rule(rule, text, exit_status=0)
        result_exit_1 = cdr.apply_line_filter_rule(rule, text, exit_status=1)
        self.assertEqual(result_exit_0, "ERROR: failed")
        self.assertEqual(result_exit_1, "ERROR: failed")

    def test_only_on_exit_code_validation_error(self) -> None:
        """Invalid only_on_exit_code type should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            only_on_exit_code="not an int",  # type: ignore[arg-type]
        )
        errors = rule.validate()
        self.assertTrue(any("only_on_exit_code must be int or null" in e for e in errors))

    def test_skip_on_exit_code_validation_error(self) -> None:
        """Invalid skip_on_exit_code type should produce validation error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            skip_on_exit_code=[1],  # type: ignore[arg-type]
        )
        errors = rule.validate()
        self.assertTrue(any("skip_on_exit_code must be int or null" in e for e in errors))

    def test_conflicting_exit_code_fields_validation_error(self) -> None:
        """Setting both only_on_exit_code and skip_on_exit_code should error."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            only_on_exit_code=0,
            skip_on_exit_code=1,
        )
        errors = rule.validate()
        self.assertIn("only_on_exit_code and skip_on_exit_code cannot both be set", errors)

    def test_should_apply_only_on_exit_code(self) -> None:
        """should_apply should return True only when exit code matches."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            only_on_exit_code=2,
        )
        self.assertFalse(rule.should_apply(0))
        self.assertFalse(rule.should_apply(1))
        self.assertTrue(rule.should_apply(2))

    def test_should_apply_skip_on_exit_code(self) -> None:
        """should_apply should return True when exit code does NOT match skip_on_exit_code."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
            skip_on_exit_code=0,
        )
        self.assertFalse(rule.should_apply(0))
        self.assertTrue(rule.should_apply(1))
        self.assertTrue(rule.should_apply(2))

    def test_should_apply_no_conditions(self) -> None:
        """should_apply should always return True when no exit-status conditions set."""
        rule = cdr.DslLineFilterRule(
            rule_id="test-rule",
            command_matcher="ls",
        )
        self.assertTrue(rule.should_apply(0))
        self.assertTrue(rule.should_apply(1))
        self.assertTrue(rule.should_apply(127))


class TestComplexScenarios(unittest.TestCase):
    """Complex integration scenarios."""

    def test_full_filter_chain(self) -> None:
        """A full filter chain with multiple operations."""
        rule = cdr.DslLineFilterRule(
            rule_id="complex-rule",
            command_matcher="test",
            strip_ansi=True,
            keep_lines=["INFO", "WARN", "ERROR"],
            remove_lines=["DEBUG"],
            replacements=[{"pattern": r"\d+", "replacement": "[N]"}],
            head=10,
            on_empty="passthrough",
        )
        text = """\x1b[31mERROR: 123 failed\x1b[0m
DEBUG: info 456
INFO: step 789 complete
WARN: check 321
DEBUG: skip this"""
        result = cdr.apply_line_filter_rule(rule, text)
        # After strip_ansi: plain text
        # After keep: lines with INFO, WARN, or ERROR (not DEBUG-only line)
        # After remove: remove lines containing DEBUG
        # After replace: numbers replaced with [N]
        expected = "ERROR: [N] failed\nINFO: step [N] complete\nWARN: check [N]"
        self.assertEqual(result, expected)

    def test_json_loading_and_application(self) -> None:
        """Load rules from JSON and apply them."""
        # Build JSON using json.dumps to ensure proper escaping
        import json
        data = {
            "rules": [
                {
                    "rule_id": "git-status",
                    "command_matcher": ["git status", "/^git .*status$/"],
                    "remove_lines": [r"^\s*\(use", r"^\s*modified:"],
                    "head": 20,
                    "on_empty": "empty"
                }
            ]
        }
        json_text = json.dumps(data)
        rules, errors = cdr.load_dsl_rules(json_text)
        self.assertEqual(len(rules), 1, f"Expected 1 rule, got {len(rules)}, errors: {errors}")
        self.assertEqual(errors, [])

        rule = rules[0]
        self.assertEqual(rule.rule_id, "git-status")
        self.assertEqual(rule.command_matcher, ["git status", "/^git .*status$/"])

        # Test the matcher
        matcher = cdr.compile_rule_matcher(rule.command_matcher)
        self.assertTrue(matcher("git status"))
        self.assertTrue(matcher("git -C /path status"))

        # Test filtering
        text = """On branch main
  (use "git push" to publish)
  modified: file.txt
Changes ready"""
        result = cdr.apply_line_filter_rule(rule, text)
        expected = "On branch main\nChanges ready"
        self.assertEqual(result, expected)

    def test_json_loading_with_exit_status_fields(self) -> None:
        """Load and apply rules with new exit-status-aware fields from JSON."""
        import json
        data = {
            "rules": [
                {
                    "rule_id": "failure-handler",
                    "command_matcher": "test ",
                    "keep_lines": ["ERROR", "FAIL"],
                    "only_on_exit_code": 1
                },
                {
                    "rule_id": "success-handler",
                    "command_matcher": "test ",
                    "keep_lines": ["PASS"],
                    "skip_on_exit_code": 0
                }
            ]
        }
        json_text = json.dumps(data)
        rules, errors = cdr.load_dsl_rules(json_text)
        self.assertEqual(len(rules), 2, f"Expected 2 rules, got {len(rules)}, errors: {errors}")
        self.assertEqual(errors, [])

        failure_rule = rules[0]
        self.assertEqual(failure_rule.rule_id, "failure-handler")
        self.assertEqual(failure_rule.only_on_exit_code, 1)

        success_rule = rules[1]
        self.assertEqual(success_rule.rule_id, "success-handler")
        self.assertEqual(success_rule.skip_on_exit_code, 0)

        # Test failure rule with exit_status=1
        text = "INFO: starting\nERROR: process failed\nDEBUG: details"
        result = cdr.apply_line_filter_rule(failure_rule, text, exit_status=1)
        self.assertEqual(result, "ERROR: process failed")

        # Test failure rule with exit_status=0 (should not apply)
        result = cdr.apply_line_filter_rule(failure_rule, text, exit_status=0)
        self.assertEqual(result, text)

        # Test success rule with exit_status=0 (should not apply due to skip_on_exit_code=0)
        text_success = "INFO: starting\nPASS: all tests\nDEBUG: details"
        result = cdr.apply_line_filter_rule(success_rule, text_success, exit_status=0)
        self.assertEqual(result, text_success)

        # Test success rule with exit_status=1 (should apply due to skip_on_exit_code=0)
        result = cdr.apply_line_filter_rule(success_rule, text_success, exit_status=1)
        self.assertEqual(result, "PASS: all tests")


if __name__ == "__main__":
    unittest.main()
