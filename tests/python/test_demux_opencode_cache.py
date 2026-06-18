#!/usr/bin/env python3
"""Unit tests for opencode cache-read extraction in run-plan-cli-json-demux.py.

OpenAI-compatible passthrough providers (ollama-cloud) report cached prompt
tokens under usage.prompt_tokens_details.cached_tokens rather than the native
tokens.cache.read field. The demux must surface those so cache reads are not
silently reported as zero.
"""

from __future__ import annotations

import unittest

import os

from ralph_script_loader import load_ralph_script


DEMUX = load_ralph_script("run-plan-cli-json-demux")


def _fresh_acc() -> dict:
    return {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_input_tokens": 0,
        "cache_read_input_tokens_estimated": 0,
        "cache_read_estimate_method": "none",
        "cache_creation_input_tokens": 0,
        "tool_turns": 0,
        "max_turn_total_tokens": 0,
        "opencode_cache_fields_seen": 0,
        "_opencode_cache_invocations": [],
    }


class TestOpencodeCacheExtraction(unittest.TestCase):
    def test_native_cache_read_used_directly(self) -> None:
        acc = _fresh_acc()
        event = {
            "type": "step_finish",
            "part": {"tokens": {"input": 80, "output": 20, "cache": {"read": 30, "write": 5}}},
        }
        DEMUX.extract_usage(event, "opencode", acc)
        self.assertEqual(acc["cache_read_input_tokens"], 30)
        self.assertEqual(acc["cache_creation_input_tokens"], 5)
        self.assertEqual(acc["opencode_cache_fields_seen"], 1)

    def test_alternate_prompt_tokens_details_cached(self) -> None:
        acc = _fresh_acc()
        event = {
            "type": "step_finish",
            "part": {
                "tokens": {"input": 80, "output": 20, "cache": {"read": 0, "write": 0}},
                "usage": {"prompt_tokens_details": {"cached_tokens": 55}},
            },
        }
        DEMUX.extract_usage(event, "opencode", acc)
        self.assertEqual(acc["cache_read_input_tokens"], 55)
        self.assertEqual(acc["opencode_cache_fields_seen"], 1)

    def test_native_field_takes_precedence_over_alternate(self) -> None:
        acc = _fresh_acc()
        event = {
            "type": "step_finish",
            "part": {
                "tokens": {"input": 80, "output": 20, "cache": {"read": 30, "write": 0}},
                "usage": {"prompt_tokens_details": {"cached_tokens": 55}},
            },
        }
        DEMUX.extract_usage(event, "opencode", acc)
        self.assertEqual(acc["cache_read_input_tokens"], 30)

    def test_flat_cached_tokens_variant(self) -> None:
        acc = _fresh_acc()
        event = {"tokens": {"input": 10, "output": 5}, "usage": {"cached_tokens": 7}}
        DEMUX.extract_usage(event, "opencode", acc)
        self.assertEqual(acc["cache_read_input_tokens"], 7)

    def test_no_cache_data_stays_zero(self) -> None:
        acc = _fresh_acc()
        event = {"type": "step_finish", "part": {"tokens": {"input": 10, "output": 5}}}
        DEMUX.extract_usage(event, "opencode", acc)
        self.assertEqual(acc["cache_read_input_tokens"], 0)

    def test_event_has_usage_detection(self) -> None:
        self.assertTrue(DEMUX._opencode_event_has_usage({"part": {"tokens": {"input": 1}}}))
        self.assertTrue(DEMUX._opencode_event_has_usage({"usage": {"cached_tokens": 1}}))
        self.assertFalse(DEMUX._opencode_event_has_usage({"type": "text", "text": "hi"}))

    def test_cache_estimate_emitted_under_env_gate(self) -> None:
        old_prompt = os.environ.get("RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED")
        old_ambient = os.environ.get("RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS")
        try:
            os.environ["RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED"] = "1"
            os.environ["RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS"] = "0"

            acc = _fresh_acc()
            for input_tokens in (12000, 10000, 11000):
                event = {
                    "type": "step_finish",
                    "part": {
                        "tokens": {
                            "input": input_tokens,
                            "output": 0,
                            "cache": {"read": 0, "write": 0},
                        }
                    },
                }
                DEMUX.extract_usage(event, "opencode", acc)

            self.assertEqual(acc["cache_read_input_tokens"], 0)
            DEMUX.finalize_usage(acc, "opencode")
            self.assertEqual(acc["cache_read_input_tokens_estimated"], 20000)
            self.assertEqual(acc["cache_read_estimate_method"], "prefix-stability")
        finally:
            if old_prompt is None:
                os.environ.pop("RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED", None)
            else:
                os.environ["RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED"] = old_prompt
            if old_ambient is None:
                os.environ.pop("RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS", None)
            else:
                os.environ["RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS"] = old_ambient

    def test_cache_estimate_suppressed_when_cache_is_reported(self) -> None:
        old_prompt = os.environ.get("RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED")
        old_ambient = os.environ.get("RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS")
        try:
            os.environ["RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED"] = "1"
            os.environ["RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS"] = "0"

            acc = _fresh_acc()
            events = [
                {
                    "type": "step_finish",
                    "part": {"tokens": {"input": 10000, "output": 0, "cache": {"read": 0, "write": 0}}},
                },
                {
                    "type": "step_finish",
                    "part": {"tokens": {"input": 9000, "output": 0, "cache": {"read": 5, "write": 0}}},
                },
                {
                    "type": "step_finish",
                    "part": {"tokens": {"input": 8000, "output": 0, "cache": {"read": 0, "write": 0}}},
                },
            ]
            for event in events:
                DEMUX.extract_usage(event, "opencode", acc)

            self.assertGreater(acc["cache_read_input_tokens"], 0)
            DEMUX.finalize_usage(acc, "opencode")
            self.assertEqual(acc["cache_read_input_tokens_estimated"], 0)
            self.assertEqual(acc["cache_read_estimate_method"], "none")
        finally:
            if old_prompt is None:
                os.environ.pop("RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED", None)
            else:
                os.environ["RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED"] = old_prompt
            if old_ambient is None:
                os.environ.pop("RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS", None)
            else:
                os.environ["RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS"] = old_ambient


if __name__ == "__main__":
    unittest.main()
