#!/usr/bin/env python3
"""Verify that the target path is within the workspace."""
import os, sys

workspace = os.path.abspath(sys.argv[1])
target = os.path.abspath(sys.argv[2])
if workspace == "" or target == "":
    sys.exit(1)
common = os.path.commonpath([workspace, target])
if common != workspace and target != workspace:
    sys.exit(2)
