#!/usr/bin/env python3
"""Unit tests for tool_call_classification.py.

Tests covering Ralph proxy calls, other MCP calls, native read/search/shell/write
buckets, hook rewrite and compaction buckets, unknown tools, invalid inputs,
and numeric coercion edge cases.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

# Add the tests/python directory to the path for importing ralph_script_loader
sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

# Load the tool_call_classification module
tcc = load_ralph_script("tool_call_classification")


class TestClassifyToolCalls(unittest.TestCase):
    """Tests for classify_tool_calls function."""

    def test_empty_mapping_returns_zeroed_counts(self) -> None:
        """Empty mapping should return zeroed counts for all keys."""
        result = tcc.classify_tool_calls({})
        self.assertEqual(result["ralph_proxy_calls"], 0)
        self.assertEqual(result["other_mcp_calls"], 0)
        self.assertEqual(result["native_file_read_calls"], 0)
        self.assertEqual(result["native_write_like_calls"], 0)
        self.assertEqual(result["runtime_hook_rewrite_calls"], 0)
        self.assertEqual(result["runtime_hook_compaction_calls"], 0)
        self.assertEqual(result["unknown_tool_calls"], 0)

    def test_none_input_returns_zeroed_counts(self) -> None:
        """None input should return zeroed counts."""
        result = tcc.classify_tool_calls(None)
        self.assertEqual(result["ralph_proxy_calls"], 0)

    def test_ralph_proxy_calls_detected(self) -> None:
        """Tools containing 'ralph_proxy' should be classified as ralph_proxy_calls."""
        result = tcc.classify_tool_calls({"ralph_proxy_read": 5, "ralph_proxy_shell": 3})
        self.assertEqual(result["ralph_proxy_calls"], 8)
        # Also verify ralph_mcp_calls is derived from ralph_proxy_calls
        self.assertEqual(result["ralph_mcp_calls"], 8)

    def test_ralph_proxy_calls_variants(self) -> None:
        """Various ralph_proxy tool name formats should be detected."""
        test_cases = {
            "ralph_proxy": 1,
            "ralph_proxy_read": 2,
            "ralph_proxy_shell": 3,
            "ralph_proxy_grep": 4,
            "my_ralph_proxy_tool": 5,
        }
        result = tcc.classify_tool_calls(test_cases)
        self.assertEqual(result["ralph_proxy_calls"], 15)

    def test_other_mcp_calls_detected(self) -> None:
        """Tools starting with 'mcp__' should be classified as other_mcp_calls."""
        result = tcc.classify_tool_calls({
            "mcp__brave_search": 2,
            "mcp__filesystem": 3,
        })
        self.assertEqual(result["other_mcp_calls"], 5)

    def test_other_mcp_calls_variants(self) -> None:
        """Various MCP tool name formats should be detected."""
        test_cases = {
            "mcp__brave": 1,
            "mcp__tool": 2,
            "mcp__": 3,
            "mcp__something_else": 4,
        }
        result = tcc.classify_tool_calls(test_cases)
        self.assertEqual(result["other_mcp_calls"], 10)

    def test_mcp_prefix_not_other_mcp(self) -> None:
        """Tools with 'mcp' but not 'mcp__' prefix should not be other_mcp_calls."""
        result = tcc.classify_tool_calls({
            "mcp_tool": 1,  # no double underscore
            "mcpread": 2,   # no underscore
        })
        self.assertEqual(result["other_mcp_calls"], 0)

    def test_native_file_read_calls(self) -> None:
        """Native file read tools should be classified correctly."""
        test_cases = {
            "read_file": 1,
            "readfile": 2,
            "read_file_v2": 3,
            "resources/read": 4,
            "reader": 6,  # prefix match
            "view": 7,
            "view_file": 8,
            "notebookread": 9,
            "notebookread_v2": 10,
        }
        result = tcc.classify_tool_calls(test_cases)
        self.assertEqual(result["native_file_read_calls"], 50)

    def test_native_read_compatibility_calls(self) -> None:
        """Exact 'read' tool should be classified as native_read_compatibility_calls."""
        result = tcc.classify_tool_calls({"read": 5})
        self.assertEqual(result["native_read_compatibility_calls"], 5)
        # 'read' counts toward native_read_like_calls aggregate
        self.assertEqual(result["native_read_like_calls"], 5)

    def test_native_search_calls(self) -> None:
        """Native search tools should be classified correctly."""
        test_cases = {
            "codebase_search": 1,
            "semanticsearch": 2,
            "semsearch": 3,
            "file_search": 4,
            "list_dir": 5,
            "listdir": 6,
            "ls": 7,
            "grep": 8,
            "grep_pattern": 9,
            "glob": 10,
            "glob_files": 11,
            "search": 12,
            "search_code": 13,
            "find": 14,
            "find_files": 15,
            "rg": 16,
            "ripgrep": 17,
        }
        result = tcc.classify_tool_calls(test_cases)
        self.assertEqual(result["native_search_calls"], 153)

    def test_native_shell_calls(self) -> None:
        """Native shell tools should be classified correctly."""
        test_cases = {
            "run_terminal_cmd": 1,
            "run_command": 2,
            "execute_command": 3,
            "shell_command": 4,
            "command": 5,
            "bash": 6,
            "bash_command": 7,
            "shell": 8,
            "shell_exec": 9,
            "exec": 10,
            "exec_script": 11,
            "command_execution": 12,
            "run_terminal": 13,
            "terminal": 14,
            "terminal_cmd": 15,
            "subprocess": 16,
            "subprocess_run": 17,
        }
        result = tcc.classify_tool_calls(test_cases)
        self.assertEqual(result["native_shell_calls"], 153)

    def test_native_write_calls(self) -> None:
        """Native write tools should be classified correctly."""
        test_cases = {
            "write": 1,
            "write_file": 2,
            "edit": 3,
            "edit_file": 4,
            "save": 5,
            "save_file": 6,
            "append": 7,
            "append_file": 8,
            "apply_patch": 9,
            "applypatch": 10,
            "str_replace": 11,
            "strreplace": 12,
        }
        result = tcc.classify_tool_calls(test_cases)
        self.assertEqual(result["native_write_like_calls"], 78)

    def test_hook_rewrite_calls(self) -> None:
        """Hook rewrite tools should be classified correctly."""
        test_cases = {
            "rewrite-bash": 1,
            "rewrite_bash": 2,
            "bash_rewrite": 3,
            "hook_rewrite": 4,
            "pre-tool-bash": 5,
            "shell-command-rewrite": 6,
            "ralph_hook_rewrite": 7,
        }
        result = tcc.classify_tool_calls(test_cases)
        self.assertEqual(result["runtime_hook_rewrite_calls"], 28)

    def test_hook_compaction_calls(self) -> None:
        """Hook compaction tools should be classified correctly."""
        test_cases = {
            "compact-bash": 1,
            "compact_bash": 2,
            "bash_compact": 3,
            "hook_compact": 4,
            "post-tool-bash": 5,
            "shell-output-compact": 6,
            "ralph_hook_compact": 7,
            "ralph_bash_compact": 8,
        }
        result = tcc.classify_tool_calls(test_cases)
        self.assertEqual(result["runtime_hook_compaction_calls"], 36)

    def test_unknown_tool_calls(self) -> None:
        """Unknown tools should be classified as unknown_tool_calls."""
        test_cases = {
            "custom_tool": 1,
            "my_utility": 2,
            "another_unknown": 3,
        }
        result = tcc.classify_tool_calls(test_cases)
        self.assertEqual(result["unknown_tool_calls"], 6)

    def test_empty_label_skipped(self) -> None:
        """Empty or whitespace-only labels should be skipped."""
        result = tcc.classify_tool_calls({
            "": 5,
            "   ": 3,
            "read_file": 10,
        })
        self.assertEqual(result["native_file_read_calls"], 10)

    def test_negative_and_zero_values_skipped(self) -> None:
        """Negative and zero values should be skipped."""
        result = tcc.classify_tool_calls({
            "read": 0,  # goes to native_read_compatibility_calls
            "write": -1,
            "grep": 10,
        })
        self.assertEqual(result["native_read_compatibility_calls"], 0)
        self.assertEqual(result["native_write_like_calls"], 0)
        self.assertEqual(result["native_search_calls"], 10)

    def test_case_insensitive_matching(self) -> None:
        """Tool names should be matched case-insensitively."""
        result = tcc.classify_tool_calls({
            "READ_FILE": 1,  # matches native file read
            "Read_File": 2,  # matches native file read
            "read_file": 3,  # matches native file read
            "GREP": 4,       # matches native search
            "Write": 5,      # matches native write
        })
        self.assertEqual(result["native_file_read_calls"], 6)
        self.assertEqual(result["native_search_calls"], 4)
        self.assertEqual(result["native_write_like_calls"], 5)


class TestNumericCoercion(unittest.TestCase):
    """Tests for numeric coercion edge cases."""

    def test_string_numbers_coerced(self) -> None:
        """String representations of numbers should be coerced to int."""
        result = tcc.classify_tool_calls({
            "read_file": "5",
            "write": "10",
        })
        self.assertEqual(result["native_file_read_calls"], 5)
        self.assertEqual(result["native_write_like_calls"], 10)

    def test_float_values_coerced(self) -> None:
        """Float values should be coerced to int."""
        result = tcc.classify_tool_calls({
            "read_file": 5.7,
            "write": 10.2,
        })
        self.assertEqual(result["native_file_read_calls"], 5)
        self.assertEqual(result["native_write_like_calls"], 10)

    def test_string_floats_coerced(self) -> None:
        """String float representations should be coerced to int."""
        result = tcc.classify_tool_calls({
            "read_file": "5.7",
            "write": "10.9",
        })
        self.assertEqual(result["native_file_read_calls"], 5)
        self.assertEqual(result["native_write_like_calls"], 10)

    def test_none_value_treated_as_zero(self) -> None:
        """None values should be treated as zero and skipped."""
        result = tcc.classify_tool_calls({
            "read_file": None,
            "write": 5,
        })
        self.assertEqual(result["native_file_read_calls"], 0)
        self.assertEqual(result["native_write_like_calls"], 5)

    def test_invalid_string_defaults_to_zero(self) -> None:
        """Invalid string values should default to zero and be skipped."""
        result = tcc.classify_tool_calls({
            "read_file": "not_a_number",
            "write": 5,
        })
        self.assertEqual(result["native_file_read_calls"], 0)
        self.assertEqual(result["native_write_like_calls"], 5)

    def test_empty_string_defaults_to_zero(self) -> None:
        """Empty string values should default to zero and be skipped."""
        result = tcc.classify_tool_calls({
            "read_file": "",
            "write": 5,
        })
        self.assertEqual(result["native_file_read_calls"], 0)
        self.assertEqual(result["native_write_like_calls"], 5)

    def test_complex_coercion_scenarios(self) -> None:
        """Test complex mixed-type scenarios."""
        result = tcc.classify_tool_calls({
            "read_file": "5",        # string int
            "write": 3.7,            # float
            "grep": "2.5",           # string float
            "shell": None,           # None
            "unknown": "abc",        # invalid string
            "edit": 0,               # zero
            "apply_patch": -1,       # negative
            "ralph_proxy": "10",     # string int
        })
        self.assertEqual(result["native_file_read_calls"], 5)
        self.assertEqual(result["native_write_like_calls"], 3)  # edit ignored (<=0)
        self.assertEqual(result["native_search_calls"], 2)
        self.assertEqual(result["native_shell_calls"], 0)
        self.assertEqual(result["unknown_tool_calls"], 0)
        self.assertEqual(result["ralph_proxy_calls"], 10)


class TestLegacyAccounting(unittest.TestCase):
    """Tests for legacy accounting key calculations."""

    def test_native_read_like_calls_aggregation(self) -> None:
        """native_read_like_calls should aggregate file read, search, shell, and compatibility calls."""
        result = tcc.classify_tool_calls({
            "read": 1,              # compatibility bucket
            "grep": 2,
            "bash": 3,
        })
        self.assertEqual(result["native_read_compatibility_calls"], 1)
        self.assertEqual(result["native_search_calls"], 2)
        self.assertEqual(result["native_shell_calls"], 3)
        self.assertEqual(result["native_read_like_calls"], 6)

    def test_legacy_keys_present(self) -> None:
        """All legacy keys should be present in the result."""
        result = tcc.classify_tool_calls({})
        self.assertIn("ralph_proxy_calls", result)
        self.assertIn("other_mcp_calls", result)
        self.assertIn("native_read_like_calls", result)
        self.assertIn("native_write_like_calls", result)

    def test_granular_keys_present(self) -> None:
        """All granular keys should be present in the result."""
        result = tcc.classify_tool_calls({})
        for key in tcc._GRANULAR_ACCOUNTING_KEYS:
            self.assertIn(key, result)


class TestSavingsBucket(unittest.TestCase):
    """Tests for savings bucket functions."""

    def test_empty_savings_bucket_defaults(self) -> None:
        """empty_savings_bucket should return zeroed values."""
        bucket = tcc.empty_savings_bucket()
        self.assertEqual(bucket["pre_optimization_bytes"], 0)
        self.assertEqual(bucket["post_optimization_bytes"], 0)
        self.assertEqual(bucket["saved_bytes"], 0)
        self.assertEqual(bucket["count"], 0)
        self.assertEqual(bucket["pre_optimization_tokens"], 0)
        self.assertEqual(bucket["post_optimization_tokens"], 0)
        self.assertEqual(bucket["saved_tokens"], 0)
        self.assertEqual(bucket["token_cap_triggers"], 0)

    def test_empty_savings_bucket_with_hidden(self) -> None:
        """empty_savings_bucket with include_hidden should include hidden fields."""
        bucket = tcc.empty_savings_bucket(include_hidden=True)
        self.assertEqual(bucket["hidden_from_context"], 0)
        self.assertEqual(bucket["hidden_from_context_tokens"], 0)

    def test_finalize_savings_bucket_percent_calculation(self) -> None:
        """finalize_savings_bucket should calculate percentages correctly."""
        bucket = {
            "pre_optimization_bytes": 1000,
            "saved_bytes": 250,
            "pre_optimization_tokens": 200,
            "saved_tokens": 50,
        }
        tcc.finalize_savings_bucket(bucket)
        self.assertEqual(bucket["savings_percent"], 25.0)
        self.assertEqual(bucket["savings_percent_tokens"], 25.0)

    def test_finalize_savings_bucket_zero_pre(self) -> None:
        """finalize_savings_bucket should not add percent fields when pre is 0."""
        bucket = {
            "pre_optimization_bytes": 0,
            "saved_bytes": 100,
        }
        tcc.finalize_savings_bucket(bucket)
        self.assertNotIn("savings_percent", bucket)


class TestAccumulateSavings(unittest.TestCase):
    """Tests for accumulate_savings_event function."""

    def test_accumulate_single_event(self) -> None:
        """accumulate_savings_event should correctly add a single event."""
        bucket = tcc.empty_savings_bucket()
        tcc.accumulate_savings_event(
            bucket,
            pre_bytes=1000,
            post_bytes=750,
            pre_tokens=100,
            post_tokens=75,
        )
        self.assertEqual(bucket["pre_optimization_bytes"], 1000)
        self.assertEqual(bucket["post_optimization_bytes"], 750)
        self.assertEqual(bucket["saved_bytes"], 250)
        self.assertEqual(bucket["pre_optimization_tokens"], 100)
        self.assertEqual(bucket["post_optimization_tokens"], 75)
        self.assertEqual(bucket["saved_tokens"], 25)
        self.assertEqual(bucket["count"], 1)

    def test_accumulate_multiple_events(self) -> None:
        """accumulate_savings_event should correctly accumulate multiple events."""
        bucket = tcc.empty_savings_bucket()
        tcc.accumulate_savings_event(bucket, pre_bytes=1000, post_bytes=900)
        tcc.accumulate_savings_event(bucket, pre_bytes=2000, post_bytes=1500)
        self.assertEqual(bucket["pre_optimization_bytes"], 3000)
        self.assertEqual(bucket["post_optimization_bytes"], 2400)
        self.assertEqual(bucket["saved_bytes"], 600)
        self.assertEqual(bucket["count"], 2)

    def test_accumulate_with_token_cap_trigger(self) -> None:
        """accumulate_savings_event should increment token_cap_triggers when flagged."""
        bucket = tcc.empty_savings_bucket()
        tcc.accumulate_savings_event(
            bucket,
            pre_bytes=100,
            post_bytes=50,
            token_cap_trigger=True,
        )
        self.assertEqual(bucket["token_cap_triggers"], 1)

    def test_accumulate_with_hidden_from_context(self) -> None:
        """accumulate_savings_event should handle hidden_from_context when present."""
        bucket = tcc.empty_savings_bucket(include_hidden=True)
        tcc.accumulate_savings_event(
            bucket,
            pre_bytes=1000,
            post_bytes=500,
            pre_tokens=100,
            post_tokens=50,
            hidden_from_context=True,
        )
        self.assertEqual(bucket["hidden_from_context"], 500)
        self.assertEqual(bucket["hidden_from_context_tokens"], 50)


class TestCoerceInt(unittest.TestCase):
    """Tests for _coerce_int helper function."""

    def test_coerce_int_with_int(self) -> None:
        """_coerce_int should return int for int input."""
        self.assertEqual(tcc._coerce_int(42), 42)

    def test_coerce_int_with_float(self) -> None:
        """_coerce_int should convert float to int."""
        self.assertEqual(tcc._coerce_int(42.7), 42)

    def test_coerce_int_with_string_int(self) -> None:
        """_coerce_int should parse string int."""
        self.assertEqual(tcc._coerce_int("42"), 42)

    def test_coerce_int_with_string_float(self) -> None:
        """_coerce_int should parse string float and convert to int."""
        self.assertEqual(tcc._coerce_int("42.7"), 42)

    def test_coerce_int_with_none(self) -> None:
        """_coerce_int should return default for None."""
        self.assertEqual(tcc._coerce_int(None), 0)

    def test_coerce_int_with_empty_string(self) -> None:
        """_coerce_int should return default for empty string."""
        self.assertEqual(tcc._coerce_int(""), 0)

    def test_coerce_int_with_invalid_string(self) -> None:
        """_coerce_int should return default for invalid string."""
        self.assertEqual(tcc._coerce_int("not_a_number"), 0)

    def test_coerce_int_with_custom_default(self) -> None:
        """_coerce_int should use custom default when provided."""
        self.assertEqual(tcc._coerce_int("invalid", default=-1), -1)


class TestCoerceBool(unittest.TestCase):
    """Tests for _coerce_bool helper function."""

    def test_coerce_bool_with_bool(self) -> None:
        """_coerce_bool should return bool for bool input."""
        self.assertTrue(tcc._coerce_bool(True))
        self.assertFalse(tcc._coerce_bool(False))

    def test_coerce_bool_with_true_strings(self) -> None:
        """_coerce_bool should recognize true-like strings."""
        self.assertTrue(tcc._coerce_bool("1"))
        self.assertTrue(tcc._coerce_bool("true"))
        self.assertTrue(tcc._coerce_bool("True"))
        self.assertTrue(tcc._coerce_bool("TRUE"))
        self.assertTrue(tcc._coerce_bool("yes"))
        self.assertTrue(tcc._coerce_bool("Yes"))
        self.assertTrue(tcc._coerce_bool("on"))
        self.assertTrue(tcc._coerce_bool("On"))

    def test_coerce_bool_with_false_values(self) -> None:
        """_coerce_bool should return False for non-true values."""
        self.assertFalse(tcc._coerce_bool("0"))
        self.assertFalse(tcc._coerce_bool("false"))
        self.assertFalse(tcc._coerce_bool("no"))
        self.assertFalse(tcc._coerce_bool("off"))
        self.assertFalse(tcc._coerce_bool(""))
        self.assertFalse(tcc._coerce_bool(None))


class TestMergeSavingsBuckets(unittest.TestCase):
    """Tests for merge_savings_buckets function."""

    def test_merge_single_bucket(self) -> None:
        """merge_savings_buckets should correctly merge a single bucket."""
        target = {
            "path1": tcc.empty_savings_bucket(),
        }
        target["path1"]["saved_bytes"] = 100

        source = {
            "path1": tcc.empty_savings_bucket(),
        }
        source["path1"]["saved_bytes"] = 50

        tcc.merge_savings_buckets(target, source)
        self.assertEqual(target["path1"]["saved_bytes"], 150)

    def test_merge_missing_bucket_skipped(self) -> None:
        """merge_savings_buckets should skip missing buckets."""
        target = {}
        source = {
            "path1": tcc.empty_savings_bucket(),
        }
        source["path1"]["saved_bytes"] = 50

        tcc.merge_savings_buckets(target, source)
        # path1 not in target, so nothing should happen
        self.assertEqual(target, {})


class TestSavingsFromPathData(unittest.TestCase):
    """Tests for savings_from_path_data function."""

    def test_empty_mapping_returns_empty_bucket(self) -> None:
        """None or empty mapping should return empty bucket."""
        result = tcc.savings_from_path_data(None)
        self.assertEqual(result["saved_bytes"], 0)
        self.assertEqual(result["count"], 0)

    def test_valid_path_data_extracted(self) -> None:
        """Valid path data should be extracted into bucket."""
        path_data = {
            "saved_bytes": 100,
            "count": 5,
        }
        result = tcc.savings_from_path_data(path_data)
        self.assertEqual(result["saved_bytes"], 100)
        self.assertEqual(result["count"], 5)

    def test_percentage_fields_not_copied_from_path_data(self) -> None:
        """Percentage fields are computed by finalize_savings_bucket, not copied from path_data.

        The savings_from_path_data function only copies fields present in empty_savings_bucket().
        Percentage fields (savings_percent, savings_percent_tokens) are computed dynamically
        by finalize_savings_bucket when pre_optimization_bytes/pre_optimization_tokens > 0.
        """
        path_data = {
            "savings_percent": "25.5",
            "savings_percent_tokens": "50.0",
        }
        result = tcc.savings_from_path_data(path_data)
        # Percentage fields are NOT in the base bucket and are NOT copied
        self.assertNotIn("savings_percent", result)
        self.assertNotIn("savings_percent_tokens", result)

    def test_finalize_creates_percent_fields(self) -> None:
        """finalize_savings_bucket creates percentage fields when pre values are present."""
        bucket = tcc.savings_from_path_data({
            "pre_optimization_bytes": 1000,
            "saved_bytes": 250,
            "pre_optimization_tokens": 200,
            "saved_tokens": 50,
        })
        tcc.finalize_savings_bucket(bucket)
        self.assertEqual(bucket["savings_percent"], 25.0)
        self.assertEqual(bucket["savings_percent_tokens"], 25.0)


class TestTokenFieldsFromRecord(unittest.TestCase):
    """Tests for token_fields_from_record function."""

    def test_camel_case_fields(self) -> None:
        """Should extract tokens from camelCase fields."""
        record = {
            "originalTokens": 100,
            "compactedTokens": 75,
        }
        original, compacted, token_cap = tcc.token_fields_from_record(record)
        self.assertEqual(original, 100)
        self.assertEqual(compacted, 75)
        self.assertFalse(token_cap)

    def test_snake_case_fields(self) -> None:
        """Should extract tokens from snake_case fields."""
        record = {
            "original_tokens": 100,
            "compacted_tokens": 75,
        }
        original, compacted, token_cap = tcc.token_fields_from_record(record)
        self.assertEqual(original, 100)
        self.assertEqual(compacted, 75)

    def test_returned_tokens_fallback(self) -> None:
        """Should fall back to returnedTokens when compactedTokens is 0."""
        record = {
            "originalTokens": 100,
            "compactedTokens": 0,
            "returnedTokens": 80,
        }
        original, compacted, token_cap = tcc.token_fields_from_record(record)
        self.assertEqual(original, 100)
        self.assertEqual(compacted, 80)

    def test_token_cap_triggered(self) -> None:
        """Should detect tokenCapTriggered flag."""
        record = {
            "originalTokens": 100,
            "compactedTokens": 50,
            "tokenCapTriggered": True,
        }
        original, compacted, token_cap = tcc.token_fields_from_record(record)
        self.assertTrue(token_cap)

    def test_token_cap_triggered_snake_case(self) -> None:
        """Should detect token_cap_triggered flag."""
        record = {
            "original_tokens": 100,
            "compacted_tokens": 50,
            "token_cap_triggered": "true",
        }
        original, compacted, token_cap = tcc.token_fields_from_record(record)
        self.assertTrue(token_cap)


if __name__ == "__main__":
    unittest.main()
