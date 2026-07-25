#!/usr/bin/env python3
"""Read agent config.json and return the configured model."""
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
print(c.get("model", ""))
