#!/usr/bin/env python3
"""Return SHA-256 hex digest of the given text argument."""
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
