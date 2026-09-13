#!/usr/bin/env bash
# Thin ralph-compatible front-end for the workflow viewer Python boundary.
# Accepts the public argv shape: <this> workflow <verb> ...
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "workflow" ]]; then
  shift
fi
exec bash "$script_dir/workflow-cli.sh" "$@"
