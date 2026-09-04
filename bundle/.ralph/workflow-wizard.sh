#!/usr/bin/env bash
# Public entry for `ralph create workflow`.
# Accepts --mode sequential|dependency and --global. When --mode is absent,
# runs the shared Sequential/Dependency mode prompt, then hands off to the
# shared wizard engine. --mode only preselects scheduling; remaining authoring
# stays interactive. Closed stdin exits 1 with an interactive-terminal explanation.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "$script_dir/.." && pwd)"

# shellcheck source=bash-lib/error-handling.sh
source "$bundle_root/.ralph/bash-lib/error-handling.sh"
# shellcheck source=bash-lib/help-render.sh
source "$bundle_root/.ralph/bash-lib/help-render.sh"
# shellcheck source=bash-lib/menu-select.sh
source "$bundle_root/.ralph/bash-lib/menu-select.sh"
# shellcheck source=bash-lib/ui-prompt.sh
source "$bundle_root/.ralph/bash-lib/ui-prompt.sh"
# shellcheck source=bash-lib/wizard/wizard-prompts.sh
source "$bundle_root/.ralph/bash-lib/wizard/wizard-prompts.sh"

mode=""
global="0"

workflow_wizard_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph create workflow [--mode sequential|dependency] [--global]

Options:
  --mode <sequential|dependency>
                      Preselect scheduling mode. When omitted, the shared mode
                      prompt asks interactively (default: sequential). All other
                      authoring remains interactive.
  --global            Write under $RALPH_HOME/workflows/ (project state root
                      is the default).
  -h, --help          Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ -n "${2:-}" ]] || ralph_die "missing value for --mode" 2
      mode="$2"
      shift 2
      ;;
    --mode=*)
      mode="${1#--mode=}"
      [[ -n "$mode" ]] || ralph_die "missing value for --mode" 2
      shift
      ;;
    --global)
      global="1"
      shift
      ;;
    -h|--help)
      workflow_wizard_usage
      exit 0
      ;;
    *)
      ralph_die "unknown option: $1" 2
      ;;
  esac
done

# Validate an explicit --mode before any interactive requirement so invalid
# values fail fast with exit 2 regardless of stdin state.
case "$mode" in
  ""|sequential|dependency) ;;
  *)
    ralph_die "invalid --mode: $mode (must be sequential or dependency)" 2
    ;;
esac

# Refuse closed stdin before mode prompt or engine handoff.
wizard_workflow_require_interactive_stdin

if [[ -z "$mode" ]]; then
  mode="$(ralph_menu_select --prompt "Select a workflow mode:" --default 1 \
    --desc "Ordered stages; maps to the Sequential engine." \
    --desc "Dependency-driven DAG; maps to the Dependency engine." \
    -- "sequential" "dependency")" || ralph_die "mode selection required (pass --mode sequential|dependency)" 2
fi

case "$mode" in
  sequential|dependency) ;;
  *)
    ralph_die "invalid --mode: $mode (must be sequential or dependency)" 2
    ;;
esac

export RALPH_CREATE_WORKFLOW_MODE="$mode"
export RALPH_CREATE_WORKFLOW_GLOBAL="$global"

# Forward the public mode directly. --global is carried via env for dest resolution.
exec bash "$script_dir/pipeline-wizard.sh" --mode "$mode"
