#!/usr/bin/env python3
"""Unit tests for progressive rule/skill context disclosure."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PY_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
sys.path.insert(0, str(PY_DIR))

import context_metadata as cm  # noqa: E402
import progressive_context as pc  # noqa: E402


class ContextMetadataTests(unittest.TestCase):
    def test_parse_rule_frontmatter(self) -> None:
        text = """---
name: test-rule
description: A test rule about emojis
globs: ["**/*"]
alwaysApply: true
---

# Body
Do not use emojis.
"""
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write(text)
            path = Path(handle.name)
        try:
            meta = cm.parse_rule_or_skill_file(path, kind="rule", rel_path=".cursor/rules/test.md")
        finally:
            path.unlink(missing_ok=True)
        self.assertTrue(meta.metadata_complete)
        self.assertEqual(meta.name, "test-rule")
        self.assertEqual(meta.always_apply, True)
        self.assertIn("Do not use emojis", meta.body_without_frontmatter)

    def _parse_rule(self, text: str) -> "cm.RuleSkillMetadata":
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write(text)
            path = Path(handle.name)
        try:
            return cm.parse_rule_or_skill_file(path, kind="rule", rel_path="rules/x.md")
        finally:
            path.unlink(missing_ok=True)

    def test_claude_paths_block_scoped(self) -> None:
        meta = self._parse_rule(
            """---
name: bash-style
description: Shell scripts must use set -euo pipefail
paths:
  - "**/*.sh"
  - "**/*.bats"
---

# Body
""",
        )
        self.assertTrue(meta.metadata_complete)
        self.assertEqual(meta.warnings, [])
        self.assertEqual(meta.always_apply, False)
        self.assertEqual(meta.globs, ["**/*.sh", "**/*.bats"])

    def test_claude_no_paths_is_always_apply(self) -> None:
        meta = self._parse_rule(
            """---
name: no-emoji
description: Do not use emojis in any project artifact
---

# Body
""",
        )
        self.assertTrue(meta.metadata_complete)
        self.assertEqual(meta.warnings, [])
        self.assertEqual(meta.always_apply, True)
        self.assertEqual(meta.globs, [])

    def test_antigravity_trigger_always_on(self) -> None:
        meta = self._parse_rule(
            """---
name: docs-hygiene
description: Documentation must describe current behavior only
trigger: always_on
---

# Body
""",
        )
        self.assertTrue(meta.metadata_complete)
        self.assertEqual(meta.warnings, [])
        self.assertEqual(meta.always_apply, True)

    def test_antigravity_trigger_glob_scoped(self) -> None:
        meta = self._parse_rule(
            """---
name: bash-style
description: Shell scripts must use set -euo pipefail
trigger: glob
globs:
  - "**/*.sh"
  - "**/*.bats"
---

# Body
""",
        )
        self.assertTrue(meta.metadata_complete)
        self.assertEqual(meta.warnings, [])
        self.assertEqual(meta.always_apply, False)
        self.assertEqual(meta.globs, ["**/*.sh", "**/*.bats"])

    def test_missing_frontmatter_falls_back_to_full_body(self) -> None:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write("# No frontmatter\nKeep everything.\n")
            path = Path(handle.name)
        try:
            meta = cm.parse_rule_or_skill_file(path, kind="rule", rel_path="rules/plain.md")
        finally:
            path.unlink(missing_ok=True)
        self.assertFalse(meta.metadata_complete)
        self.assertTrue(meta.warnings)
        self.assertIn("Keep everything", meta.body)


class ProgressiveSelectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.rules_dir = self.root / ".cursor" / "rules"
        self.skills_dir = self.root / ".cursor" / "skills" / "ralph-testing"
        self.rules_dir.mkdir(parents=True)
        self.skills_dir.mkdir(parents=True)

        (self.rules_dir / "always-on.md").write_text(
            """---
name: always-on
description: Always applied safety rule
alwaysApply: true
---

Always on body.
""",
            encoding="utf-8",
        )
        (self.rules_dir / "optional-testing.md").write_text(
            """---
name: optional-testing
description: Bats testing workflow guidance
alwaysApply: false
---

Optional testing body with many details about bats tests.
""",
            encoding="utf-8",
        )
        (self.skills_dir / "SKILL.md").write_text(
            """---
name: ralph-testing
description: How to run filter and write Bats tests for Ralph
---

Skill body about bats testing.
""",
            encoding="utf-8",
        )

        self.config = self.root / "agent" / "demo" / "config.json"
        self.config.parent.mkdir(parents=True)
        self.config.write_text(
            json.dumps(
                {
                    "name": "demo",
                    "model": "test",
                    "description": "Demo agent for progressive context",
                    "rules": [
                        ".cursor/rules/always-on.md",
                        ".cursor/rules/optional-testing.md",
                    ],
                    "skills": [".cursor/skills/ralph-testing/SKILL.md"],
                    "output_artifacts": [],
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_always_apply_never_filtered(self) -> None:
        os.environ["RALPH_PROGRESSIVE_CONTEXT"] = "1"
        os.environ["RALPH_MODE"] = "ralph"
        os.environ["RALPH_PROGRESSIVE_CONTEXT_THRESHOLD"] = "999"
        try:
            result = pc.assemble_context(
                {
                    "workspace": str(self.root),
                    "config_path": str(self.config),
                    "agents_root": str(self.root / "agent"),
                    "todo_text": "Unrelated todo about documentation only",
                    "part": "all",
                }
            )
        finally:
            os.environ.pop("RALPH_PROGRESSIVE_CONTEXT", None)
            os.environ.pop("RALPH_MODE", None)
            os.environ.pop("RALPH_PROGRESSIVE_CONTEXT_THRESHOLD", None)

        self.assertTrue(result["progressive"])
        self.assertIn("Always on body", result["stable"])
        self.assertNotIn("Optional testing body", result["stable"])

    def test_explicit_todo_mention_loads_full_body(self) -> None:
        os.environ["RALPH_PROGRESSIVE_CONTEXT"] = "1"
        os.environ["RALPH_MODE"] = "ralph"
        os.environ["RALPH_PROGRESSIVE_CONTEXT_THRESHOLD"] = "999"
        try:
            result = pc.assemble_context(
                {
                    "workspace": str(self.root),
                    "config_path": str(self.config),
                    "agents_root": str(self.root / "agent"),
                    "todo_text": "Follow optional-testing rule and run bats tests",
                    "part": "all",
                }
            )
        finally:
            os.environ.pop("RALPH_PROGRESSIVE_CONTEXT", None)
            os.environ.pop("RALPH_MODE", None)
            os.environ.pop("RALPH_PROGRESSIVE_CONTEXT_THRESHOLD", None)

        combined = result["stable"] + "\n" + result["volatile"]
        self.assertIn("Optional testing body", combined)

    def test_irrelevant_optional_bodies_omitted(self) -> None:
        os.environ["RALPH_PROGRESSIVE_CONTEXT"] = "1"
        os.environ["RALPH_MODE"] = "ralph"
        os.environ["RALPH_PROGRESSIVE_CONTEXT_THRESHOLD"] = "999"
        try:
            result = pc.assemble_context(
                {
                    "workspace": str(self.root),
                    "config_path": str(self.config),
                    "agents_root": str(self.root / "agent"),
                    "todo_text": "Write documentation about deployment",
                    "part": "all",
                }
            )
        finally:
            os.environ.pop("RALPH_PROGRESSIVE_CONTEXT", None)
            os.environ.pop("RALPH_MODE", None)
            os.environ.pop("RALPH_PROGRESSIVE_CONTEXT_THRESHOLD", None)

        combined = result["stable"] + "\n" + result["volatile"]
        self.assertIn("Tier 1 metadata", result["stable"])
        self.assertNotIn("Optional testing body", combined)
        self.assertNotIn("Skill body about bats", combined)

    def test_legacy_full_loading_when_disabled(self) -> None:
        result = pc.assemble_context(
            {
                "workspace": str(self.root),
                "config_path": str(self.config),
                "agents_root": str(self.root / "agent"),
                "todo_text": "anything",
                "progressive_context": "0",
                "ralph_mode": "ralph",
                "compact_mode": "0",
                "part": "all",
            }
        )
        self.assertFalse(result["progressive"])
        self.assertIn("Optional testing body", result["stable"])
        self.assertIn(".cursor/skills/ralph-testing/SKILL.md", result["stable"])

    def test_gate_defaults(self) -> None:
        self.assertFalse(pc.progressive_context_enabled(explicit=None, ralph_mode="no"))
        self.assertTrue(pc.progressive_context_enabled(explicit=None, ralph_mode="ralph"))
        self.assertTrue(pc.progressive_context_enabled(explicit="1", ralph_mode="no"))
        self.assertFalse(pc.progressive_context_enabled(explicit="0", ralph_mode="ralph"))


if __name__ == "__main__":
    unittest.main()
