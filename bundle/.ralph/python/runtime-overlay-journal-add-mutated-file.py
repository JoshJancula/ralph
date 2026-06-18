#!/usr/bin/env python3
"""Build a mutated-file journal entry."""
import json, sys
print(json.dumps({"path": sys.argv[1], "backup": sys.argv[2], "restored": False}))
