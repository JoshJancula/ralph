#!/usr/bin/env python3
"""Build a generated-file journal entry."""
import json, sys
print(json.dumps({"path": sys.argv[1], "cleaned": False}))
