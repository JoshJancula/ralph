#!/usr/bin/env bash
# Delete Ralph plan logs and artifacts scoped to one namespace.
#
# Usage:
#   .ralph/cleanup-plan.sh <artifact-namespace> [workspace]
#     Removes `.agents/logs/<namespace>/plan-runner-*` files and `.agents/artifacts/<namespace>/`.
#     Defaults to `$RALPH_ARTIFACT_NS` if the namespace argument is empty.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${1:-${RALPH_ARTIFACT_NS:-}}"
shift || true

if [[ -z "$NAMESPACE" ]]; then
  echo "Usage: $0 <artifact-namespace> [workspace]" >&2
  exit 1
fi

if [[ $# -ge 1 ]]; then
  WORKSPACE_ROOT="$(cd "$1" && pwd)"
else
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../" && pwd)"
fi

LOG_DIR="$WORKSPACE_ROOT/.agents/logs/$NAMESPACE"
ARTIFACT_DIR="$WORKSPACE_ROOT/.agents/artifacts/$NAMESPACE"

if [[ -d "$LOG_DIR" ]]; then
  find "$LOG_DIR" -maxdepth 1 -type f -name 'plan-runner-*' -delete
  find "$LOG_DIR" -maxdepth 1 -type f -name '.plan-runner-exit.*' -delete
  echo "Cleaned logs in $LOG_DIR"
else
  echo "Log directory does not exist: $LOG_DIR" >&2
fi

if [[ -d "$ARTIFACT_DIR" ]]; then
  rm -rf "$ARTIFACT_DIR"
  echo "Removed artifacts in $ARTIFACT_DIR"
else
  echo "Artifact directory does not exist: $ARTIFACT_DIR" >&2
fi
