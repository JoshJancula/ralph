#!/usr/bin/env python3
"""Unit tests for mcp-proxy-tool-search-rank.py compact catalog ranker."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

tool_search_rank = load_ralph_script("mcp-proxy-tool-search-rank")


SAMPLE_CATALOG = [
    {
        "name": "ralph_proxy_glob",
        "description": "Find files by glob pattern.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "glob_pattern": {"type": "string", "description": "Glob pattern."},
                "target_directory": {"type": "string", "description": "Search directory."},
            },
            "required": ["glob_pattern"],
        },
    },
    {
        "name": "ralph_proxy_search",
        "description": "BM25-ranked lexical code search.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query."},
                "path": {"type": "string", "description": "File or directory path."},
            },
            "required": ["query"],
        },
    },
    {
        "name": "ralph_proxy_shell_start",
        "description": "Start a long-running allowlisted shell command.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "Allowlisted command."},
            },
            "required": ["command"],
        },
    },
]


class TestCompactSchemaSummary(unittest.TestCase):
    def test_summarizes_required_properties(self) -> None:
        summary = tool_search_rank.compact_schema_summary(SAMPLE_CATALOG[0]["inputSchema"])
        self.assertIn("glob_pattern*", summary)
        self.assertIn("target_directory", summary)

    def test_empty_schema_returns_empty(self) -> None:
        self.assertEqual(tool_search_rank.compact_schema_summary(None), "")


class TestRankTools(unittest.TestCase):
    def test_glob_query_ranks_glob_first(self) -> None:
        results = tool_search_rank.rank_tools(SAMPLE_CATALOG, "glob files pattern", max_results=5)
        self.assertGreaterEqual(len(results), 1)
        self.assertEqual(results[0]["name"], "ralph_proxy_glob")
        self.assertEqual(results[0]["rank"], 1)
        self.assertIn("schemaSummary", results[0])

    def test_search_query_ranks_code_search(self) -> None:
        results = tool_search_rank.rank_tools(SAMPLE_CATALOG, "lexical code search query", max_results=5)
        self.assertGreaterEqual(len(results), 1)
        self.assertEqual(results[0]["name"], "ralph_proxy_search")

    def test_async_shell_query(self) -> None:
        results = tool_search_rank.rank_tools(SAMPLE_CATALOG, "shell start async job", max_results=5)
        self.assertGreaterEqual(len(results), 1)
        self.assertEqual(results[0]["name"], "ralph_proxy_shell_start")

    def test_empty_query_returns_empty(self) -> None:
        self.assertEqual(tool_search_rank.rank_tools(SAMPLE_CATALOG, "   ", max_results=5), [])

    def test_max_results_respected(self) -> None:
        results = tool_search_rank.rank_tools(SAMPLE_CATALOG, "proxy", max_results=1)
        self.assertLessEqual(len(results), 1)


class TestCliIntegration(unittest.TestCase):
    def test_cli_reads_json_catalog_from_stdin(self) -> None:
        script = Path(__file__).resolve().parents[2] / "bundle/.ralph/python/mcp-proxy-tool-search-rank.py"
        proc = subprocess.run(
            [sys.executable, str(script), "--query", "glob pattern", "--max-results", "3"],
            input=json.dumps(SAMPLE_CATALOG),
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        payload = json.loads(proc.stdout)
        self.assertIsInstance(payload, list)
        self.assertGreaterEqual(len(payload), 1)
        self.assertEqual(payload[0]["name"], "ralph_proxy_glob")


if __name__ == "__main__":
    unittest.main()
