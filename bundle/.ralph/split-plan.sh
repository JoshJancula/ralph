#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/plan-todo.sh
source "$SCRIPT_DIR/bash-lib/plan-todo.sh"

usage() {
  cat <<'USAGE'
Usage: ralph split-plan --plan <path> [--out <path>|--in-place] [--json]

Preview or apply Ralph executable TODO normalization. Preview mode writes the
normalized plan to stdout and does not mutate the input plan.
USAGE
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

ralph_plan_split_cli "$@"
