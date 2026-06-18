#!/usr/bin/env bash
#
# Token expansion for artifact paths (sourced by agent-config-tool.sh).
#
# Public interface:
#   resolve_artifact_path_template -- substitute {{ARTIFACT_NS}}, {{PLAN_KEY}}, {{STAGE_ID}} from env.

_resolve_paths_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$_resolve_paths_dir/artifacts.sh"
unset _resolve_paths_dir
