#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$WORKSPACE/.ralph/ralph-env-safety.sh"
