#!/usr/bin/env python3
"""Tests for the SOURCE_OUTPUT_FAMILIES frozenset in shell-output-compact.py."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

soc = load_ralph_script("shell-output-compact.py")

_MODULE_PATH = (
    Path(__file__).resolve().parents[2]
    / "bundle"
    / ".ralph"
    / "python"
    / "shell-output-compact.py"
)


def test_source_output_families_contents():
    assert soc.SOURCE_OUTPUT_FAMILIES == frozenset(
        {"find", "ls", "tree", "grep", "git_diff", "git_show", "git_log"}
    )


def test_source_output_families_is_frozenset():
    assert isinstance(soc.SOURCE_OUTPUT_FAMILIES, frozenset)


def test_no_environment_variable_reenables_source_family_compaction(monkeypatch):
    # No env var exists to turn source-family compaction back on. Setting
    # plausible candidate names must not change the frozenset contents.
    candidate_env_vars = [
        "RALPH_COMPACT_SOURCE_FAMILIES",
        "RALPH_ENABLE_SOURCE_COMPACT",
        "RALPH_SOURCE_OUTPUT_COMPACT",
        "RALPH_ALLOW_SOURCE_COMPACT",
    ]
    for var in candidate_env_vars:
        monkeypatch.setenv(var, "1")

    reloaded = load_ralph_script("shell-output-compact.py")
    assert reloaded.SOURCE_OUTPUT_FAMILIES == frozenset(
        {"find", "ls", "tree", "grep", "git_diff", "git_show", "git_log"}
    )


def test_module_source_has_no_source_family_env_var():
    source = _MODULE_PATH.read_text(encoding="utf-8")
    assert "RALPH_COMPACT_SOURCE_FAMILIES" not in source
