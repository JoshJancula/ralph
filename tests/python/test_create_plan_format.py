#!/usr/bin/env python3
"""Tests for create-plan --format canonical name and backward-compat aliases."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
CREATE_PLAN = REPO_ROOT / "bundle" / ".ralph" / "create-plan.sh"


def _run_create_plan(workspace: Path, plan_format: str, plan_name: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "bash",
            str(CREATE_PLAN),
            "--format",
            plan_format,
            "--name",
            plan_name,
            "--workspace",
            str(workspace),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def _plan_path(workspace: Path, plan_name: str) -> Path:
    return workspace / ".ralph-workspace" / "plans" / f"{plan_name}.plan.md"


class TestCreatePlanFormat(unittest.TestCase):
  """create-plan.sh accepts yaml as canonical and legacy format tokens as aliases."""

  def setUp(self) -> None:
    self.workspace = Path(tempfile.mkdtemp())
    self.addCleanup(lambda: _rmtree(self.workspace))

  def test_yaml_is_canonical(self) -> None:
    result = _run_create_plan(self.workspace, "yaml", "canonical-yaml")
    self.assertEqual(result.returncode, 0, msg=result.stderr or result.stdout)

    plan_file = _plan_path(self.workspace, "canonical-yaml")
    self.assertTrue(plan_file.is_file())
    content = plan_file.read_text(encoding="utf-8")
    self.assertTrue(content.startswith("---\n"))
    self.assertIn("todos:", content)
    self.assertIn("mode: standard", content)

  def test_legacy_format_aliases_still_work(self) -> None:
    aliases = ("standard", "structured", "pipeline", "cursor")
    for alias in aliases:
      with self.subTest(alias=alias):
        plan_name = f"alias-{alias}"
        result = _run_create_plan(self.workspace, alias, plan_name)
        self.assertEqual(result.returncode, 0, msg=result.stderr or result.stdout)

        plan_file = _plan_path(self.workspace, plan_name)
        self.assertTrue(plan_file.is_file())
        content = plan_file.read_text(encoding="utf-8")
        self.assertTrue(content.startswith("---\n"))
        self.assertIn("todos:", content)

  def test_invalid_format_is_rejected(self) -> None:
    result = _run_create_plan(self.workspace, "not-a-format", "bad")
    self.assertNotEqual(result.returncode, 0)
    combined = f"{result.stdout}\n{result.stderr}"
    self.assertIn("invalid --format", combined)


def _rmtree(path: Path) -> None:
  import shutil

  shutil.rmtree(path, ignore_errors=True)


if __name__ == "__main__":
  unittest.main()
