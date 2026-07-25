#!/usr/bin/env python3
"""Unit tests for Ralph skill package validation."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PY_DIR = REPO_ROOT / "bundle" / ".ralph" / "python"
sys.path.insert(0, str(PY_DIR))

import skill_package as sp  # noqa: E402


class SkillPackageValidationTests(unittest.TestCase):
    def test_valid_skill_without_version(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            package = Path(tmp) / "repo-context"
            package.mkdir()
            (package / "SKILL.md").write_text(
                """---
name: repo-context
description: Valid skill package
---

Body
""",
                encoding="utf-8",
            )
            meta = sp.validate_skill_package(package, "repo-context")
            self.assertEqual(meta["name"], "repo-context")
            self.assertNotIn("version", meta)

    def test_invalid_name_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            package = Path(tmp) / "Bad_Name"
            package.mkdir()
            (package / "SKILL.md").write_text(
                """---
name: Bad_Name
description: Invalid
---
""",
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                sp.validate_skill_package(package, "Bad_Name")

    def test_invalid_version_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            package = Path(tmp) / "demo"
            package.mkdir()
            (package / "SKILL.md").write_text(
                """---
name: demo
description: Invalid version
version: not-a-version
---
""",
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                sp.validate_skill_package(package, "demo")

    def test_env_file_in_resources_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            package = Path(tmp) / "demo"
            resources = package / "resources"
            resources.mkdir(parents=True)
            (package / "SKILL.md").write_text(
                """---
name: demo
description: Secret resource
---
""",
                encoding="utf-8",
            )
            (resources / ".env").write_text("SECRET=1\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                sp.validate_skill_package(package, "demo")

    def test_escaping_symlink_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            package = Path(tmp) / "demo"
            scripts = package / "scripts"
            scripts.mkdir(parents=True)
            outside = Path(tmp) / "outside.txt"
            outside.write_text("nope\n", encoding="utf-8")
            os.symlink(outside, scripts / "escape.sh")
            (package / "SKILL.md").write_text(
                """---
name: demo
description: Escaping symlink
---
""",
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                sp.validate_skill_package(package, "demo")

    def test_resources_list_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            package = Path(tmp) / "demo"
            (package / "scripts").mkdir(parents=True)
            (package / "resources").mkdir(parents=True)
            (package / "scripts" / "b.sh").write_text("#!/bin/sh\n", encoding="utf-8")
            (package / "scripts" / "a.sh").write_text("#!/bin/sh\n", encoding="utf-8")
            (package / "resources" / "note.md").write_text("note\n", encoding="utf-8")
            (package / "SKILL.md").write_text(
                """---
name: demo
description: Resource listing
---
""",
                encoding="utf-8",
            )
            self.assertEqual(
                sp.list_package_resources(package),
                ["resources/note.md", "scripts/a.sh", "scripts/b.sh"],
            )


if __name__ == "__main__":
    unittest.main()
