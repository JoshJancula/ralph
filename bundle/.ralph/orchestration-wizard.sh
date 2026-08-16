#!/usr/bin/env bash
# Thin shim: `ralph create orc` pre-selects orchestration mode on the shared
# wizard engine. See pipeline-wizard.sh for the actual flow.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$script_dir/pipeline-wizard.sh" --mode orchestration "$@"
