#!/usr/bin/env python3
"""List Cursor model ids known to the local Cursor CLI config.

Used as a fallback when `cursor-agent --list-models` cannot reach the service
(commonly an auth failure). Prints one model id per line, most recently used
first. Prints nothing when the config is missing or unreadable.
"""

import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        with open(sys.argv[1], encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return 0
    if not isinstance(data, dict):
        return 0

    seen = set()
    models = []

    def add(name):
        if isinstance(name, str) and name and name != "default" and name not in seen:
            seen.add(name)
            models.append(name)

    history = data.get("modelSelectionHistory")
    if isinstance(history, list):
        for name in history:
            add(name)

    params = data.get("modelParameters")
    if isinstance(params, dict):
        for name in params:
            add(name)

    for name in models:
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
