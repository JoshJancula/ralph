#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RALPH_LIB_ROOT="$REPO_ROOT/.ralph/bash-lib"
export RALPH_LIB_ROOT
export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
