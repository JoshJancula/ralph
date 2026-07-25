#!/usr/bin/env python3
"""End-to-end offline integration for Tier 1 through Tier 3 cookbook features."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "cookbook-roadmap" / "offline-e2e"
MANIFEST = FIXTURE_DIR / "manifest.json"
RANK_SCRIPT = REPO_ROOT / "bundle" / ".ralph" / "python" / "mcp-proxy-search-rank.py"

sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))
sys.path.insert(0, str(REPO_ROOT / "tests" / "python"))

import artifact_json_schema as ajs  # noqa: E402
import continuation_summary as cs  # noqa: E402
import evaluator_contract as ec  # noqa: E402
import retrieval_eval as reval  # noqa: E402
from ralph_script_loader import load_ralph_script  # noqa: E402

tool_search_rank = load_ralph_script("mcp-proxy-tool-search-rank")


def _load_manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


class TestCookbookOfflineE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = _load_manifest()

    def test_stable_prompt_ordering_matches_fixture(self) -> None:
        spec = self.manifest["prompt_order"]
        todo = spec["volatile_todo"].replace("'", "'\\''")
        stable = spec["stable_block"].replace("'", "'\\''")
        script = (
            "set -euo pipefail\n"
            "export RALPH_MODE=ralph\n"
            "export RALPH_RUN_PLAN_LIBRARY_ONLY=1\n"
            "source bundle/.ralph/bash-lib/run-plan/run-plan-core.sh\n"
            "unset RALPH_RUN_PLAN_LIBRARY_ONLY\n"
            f'RUNTIME="{spec["runtime"]}"\n'
            f"PROMPT='{todo}'\n"
            f"PROMPT_STATIC='{stable}'\n"
            'ralph_run_plan_merge_prompt "$RUNTIME"\n'
            'printf "%s" "$PROMPT"\n'
        )
        proc = subprocess.run(
            ["bash", "-c", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(
            proc.returncode,
            0,
            msg=f"merge script failed: stdout={proc.stdout!r} stderr={proc.stderr!r}",
        )
        merged = proc.stdout
        expected = f"{spec['stable_block']}\n\n{spec['volatile_todo']}"
        self.assertEqual(merged, expected)
        if spec.get("expect_stable_first"):
            prefix = merged.split("**TODO", 1)[0]
            self.assertIn(spec["stable_block"], prefix)

    def test_continuation_summary_rebuild_from_seed(self) -> None:
        spec = self.manifest["continuation"]
        seed = json.loads((FIXTURE_DIR / spec["seed_state_path"]).read_text(encoding="utf-8"))
        migrated = cs.migrate_state(seed)
        rendered = cs.rebuild_markdown(migrated)
        for needle in spec["expect_markdown_contains"]:
            self.assertIn(needle, rendered, msg=f"missing {needle!r} in continuation block")

    def test_compact_tool_search_ranks_expected_tool(self) -> None:
        spec = self.manifest["compact_tool_search"]
        catalog = [
            {
                "name": "ralph_proxy_glob",
                "description": "Find files by glob pattern.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"glob_pattern": {"type": "string"}},
                    "required": ["glob_pattern"],
                },
            },
            {
                "name": "ralph_proxy_read",
                "description": "Read file with line limits.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                },
            },
        ]
        ranked = tool_search_rank.rank_tools(catalog, spec["query"], max_results=3)
        self.assertGreaterEqual(len(ranked), 1)
        self.assertEqual(ranked[0]["name"], spec["expect_top_tool"])

    def test_contextual_retrieval_ranks_workspace_hit(self) -> None:
        workspace = REPO_ROOT / self.manifest["workspace_root"]
        handler = workspace / "lib" / "handler.py"
        rel = handler.relative_to(REPO_ROOT).as_posix()
        line = handler.read_text(encoding="utf-8").splitlines()[2]
        candidates = f"{rel}:3:{line}\n"
        ranked = reval.rank_candidates(
            "handle_request validates input",
            candidates,
            max_results=5,
            rank_script=RANK_SCRIPT,
            project_root=REPO_ROOT,
            contextual=True,
        )
        self.assertEqual(ranked, [f"{rel}:3"])

    def test_evaluator_schema_validation_and_loopback_block(self) -> None:
        spec = self.manifest["evaluator_loopback"]
        artifact_path = FIXTURE_DIR / spec["artifact_path"]
        schema_path = REPO_ROOT / spec["schema_path"]
        schema = ajs.load_schema_document(str(schema_path))
        raw = artifact_path.read_text(encoding="utf-8")
        ajs.validate_json_text(raw, schema)
        contract = ec.load_contract(str(artifact_path))
        block = ec.render_feedback_block(
            contract,
            spec["source_stage"],
            spec["iteration"],
            f"artifacts/{artifact_path.name}",
        )
        self.assertIn("<!-- RALPH_EVALUATOR_FEEDBACK: START -->", block)
        positions = [block.index(item) for item in spec["expect_feedback_order"]]
        self.assertEqual(positions, sorted(positions))


if __name__ == "__main__":
    unittest.main()
