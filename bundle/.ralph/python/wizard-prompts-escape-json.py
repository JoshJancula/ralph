#!/usr/bin/env python3
"""JSON-escape a string value."""
import json, sys
print(json.dumps(sys.argv[1]))
