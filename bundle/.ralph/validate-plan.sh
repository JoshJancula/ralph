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

execution="$(awk '
  BEGIN { in_frontmatter = 0; seen_open = 0 }
  NR == 1 && $0 == "---" { in_frontmatter = 1; seen_open = 1; next }
  in_frontmatter && $0 == "---" { exit }
  in_frontmatter && $1 == "execution:" { print $2; exit }
  # mode: is the public alias for execution: (AGENTS.md); map it the same way.
  in_frontmatter && $1 == "mode:" && $2 == "dependency" { print "graph"; exit }
  in_frontmatter && $1 == "mode:" && $2 == "sequential" { print "orchestration"; exit }
  in_frontmatter && $1 == "mode:" && $2 == "standard" { print "standard"; exit }
' "$plan_path" 2>/dev/null || true)"

if [[ "$execution" == "graph" ]]; then
  # The X's must be the last characters of the template: BSD mktemp (macOS)
  # ignores a trailing suffix and creates the literal path instead of a random
  # one, so ".XXXXXX.json" made every run reuse /tmp/ralph-graph.XXXXXX.json and
  # any second concurrent validation failed with "File exists".
  graph_tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-json.XXXXXX")"
  trap 'rm -f "$graph_tmp"' EXIT
  if ! plan_pipeline_graph_json "$plan_path" >"$graph_tmp"; then
    exit 1
  fi
  if ! bash "$bundle_root/.ralph/bash-lib/graph/validate-graph-schema.sh" "$graph_tmp"; then
    exit 1
  fi
  exit 0
fi

if ! plan_pipeline_validate_plan "$plan_path"; then
  exit 1
fi
