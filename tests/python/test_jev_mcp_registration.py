#!/usr/bin/env python3
"""ralph-jev must register without an exported key, and never fail a run.

Regression coverage for a defect that aborted plan runs: the ralph-jev server
definition carried headers.Authorization = "${TYPESAFE_API_KEY}", so the
resolver refused to launch unless that variable was exported. ralph-jev speaks
stdio - headers never reach a request - and the server resolves the key itself
through the key-resolution chain, so the env-ref was a pure pre-launch gate that
defeated four of the five supported backends (.env, keychain, command, file).
It also made an optional advisory server fatal for the whole run.

Second half of the same defect: an unresolvable server script raised
McpResolveError, aborting MCP setup for every runtime rather than dropping the
one optional server.
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

REPO_ROOT = Path(__file__).resolve().parents[2]
RALPH_DIR = REPO_ROOT / "bundle" / ".ralph"
RALPH_SERVER = RALPH_DIR / "mcp-server.sh"
JEV_SERVER = RALPH_DIR / "jev-mcp-server.sh"

mcp = load_ralph_script("runtime-config-mcp.py")


class JevMcpRegistrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self._env = mock.patch.dict(
            os.environ,
            {"RALPH_JEV": "1", "RALPH_JEV_MCP": "1", "RALPH_DIR": str(RALPH_DIR)},
            clear=False,
        )
        self._env.start()
        self.addCleanup(self._env.stop)
        # The whole point: no exported key.
        os.environ.pop("TYPESAFE_API_KEY", None)

    def _request(self, **extra: object) -> dict:
        request = {
            "runtime": "claude",
            "project_root": str(REPO_ROOT),
            "workspace": str(REPO_ROOT),
            "ralph_server_script": str(RALPH_SERVER),
            "jev_server_script": str(JEV_SERVER),
        }
        request.update(extra)
        return request

    def test_registers_with_no_exported_key(self) -> None:
        result = mcp.resolve_effective_mcp(self._request())
        self.assertTrue(result.get("ok"), result)
        self.assertIn("ralph-jev", result["summary"]["mcp_effective_names"])

    def test_definition_carries_no_key_env_reference(self) -> None:
        definition = mcp._jev_server_definition(str(JEV_SERVER), str(REPO_ROOT))
        self.assertEqual(definition.get("headers"), {})
        blob = repr(definition)
        self.assertNotIn("TYPESAFE_API_KEY", blob)
        self.assertNotIn("${", blob)

    def test_missing_server_script_omits_the_server_instead_of_failing(self) -> None:
        result = mcp.resolve_effective_mcp(
            self._request(jev_server_script="/nonexistent/jev-mcp-server.sh")
        )
        self.assertTrue(result.get("ok"), result)
        self.assertNotIn("ralph-jev", result["summary"]["mcp_effective_names"])
        self.assertTrue(
            any(
                "ralph-jev" in decision and "omitted" in decision
                for decision in result["summary"]["mcp_override_decisions"]
            ),
            result["summary"]["mcp_override_decisions"],
        )

    def test_unresolvable_script_path_returns_empty_rather_than_raising(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("RALPH_DIR", None)
            self.assertEqual(mcp._jev_server_script_from_request({}), "")

    def test_jev_disabled_leaves_the_catalog_untouched(self) -> None:
        with mock.patch.dict(os.environ, {"RALPH_JEV_MCP": "0"}, clear=False):
            result = mcp.resolve_effective_mcp(self._request())
        self.assertTrue(result.get("ok"), result)
        self.assertNotIn("ralph-jev", result["summary"]["mcp_effective_names"])


if __name__ == "__main__":
    unittest.main()
