#!/usr/bin/env python3
"""Compatibility alias for plan-yaml-frontmatter-op.py (legacy plan-format name)."""
import runpy
import sys
from pathlib import Path

_target = Path(__file__).with_name("plan-yaml-frontmatter-op.py")
sys.argv[0] = str(_target)
runpy.run_path(str(_target), run_name="__main__")
