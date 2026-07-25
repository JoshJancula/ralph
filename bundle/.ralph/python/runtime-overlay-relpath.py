#!/usr/bin/env python3
"""Compute relative path from workspace to target."""
import os, sys

workspace = os.path.abspath(sys.argv[1])
target = os.path.abspath(sys.argv[2])
print(os.path.relpath(target, workspace))
