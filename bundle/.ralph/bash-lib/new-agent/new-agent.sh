#!/usr/bin/env bash
set -euo pipefail
#
# Small helpers for .ralph/new-agent.sh (sourced by the entry script).
#
# Public interface:
#   new_agent_is_valid_id -- true when the agent id matches allowed hyphenated pattern.
#   new_agent_workspace_path -- resolve a path under workspace via Python (rejects escapes).

new_agent_is_valid_id() {
  local candidate="${1:-}"
  [[ -n "$candidate" ]] && [[ "$candidate" =~ ^[a-z0-9-]+$ ]]
}

new_agent_workspace_path() {
  local workspace_root="${1:-}"
  shift || true
  python3 - "$workspace_root" "$@" <<'PY'
import os
import sys

root = os.path.abspath(sys.argv[1])
parts = sys.argv[2:]
target = os.path.normpath(os.path.join(root, *parts))

if os.path.commonpath([root, target]) != root:
    sys.stderr.write("new-agent workspace path escapes root\n")
    sys.exit(1)

print(target)
PY
}
