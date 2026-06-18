#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "$script_dir/.." && pwd)"

# shellcheck source=bash-lib/error-handling.sh
source "$bundle_root/.ralph/bash-lib/error-handling.sh"
# shellcheck source=bash-lib/plan-todo.sh
source "$bundle_root/.ralph/bash-lib/plan-todo.sh"

usage() {
  local exit_code="${1:-1}"
  cat <<'EOF'
Usage: validate-plan.sh <plan-path>
Validate a single plan file.
EOF
  exit "$exit_code"
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
  usage 0
fi

if [[ $# -ne 1 ]]; then
  usage 1
fi

plan_path="$1"

if [[ "$plan_path" == --* ]]; then
  usage 1
fi

if [[ ! -f "$plan_path" ]]; then
  echo "Plan validation failed: file not found: $plan_path" >&2
  exit 1
fi

if ! plan_pipeline_validate_plan "$plan_path"; then
  exit 1
fi
