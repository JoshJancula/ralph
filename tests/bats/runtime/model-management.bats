#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

MODEL_STORE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/select-model/model-store.sh"
MODELS_SH="$REPO_ROOT/bundle/.ralph/models.sh"
SELECT_MODEL_COMMON="$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-common.sh"
SELECT_MODEL_CLAUDE="$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-claude.sh"
SELECT_MODEL_CODEX="$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-codex.sh"
RUN_PLAN_AGENT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-agent.sh"
NEW_AGENT_HELPERS="$REPO_ROOT/bundle/.ralph/bash-lib/new-agent/new-agent-helpers.sh"
WIZARD_PROMPTS="$REPO_ROOT/bundle/.ralph/bash-lib/wizard/wizard-prompts.sh"

setup() {
  command -v jq >/dev/null || skip "jq required"
  TEST_TMPDIR="$(mktemp -d)"
  export RALPH_CONFIG_HOME="$TEST_TMPDIR/ralph-config"
  mkdir -p "$RALPH_CONFIG_HOME"
  unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CODEX_PLAN_MODEL CURSOR_PLAN_MODEL NON_INTERACTIVE_FLAG
}

teardown() {
  [[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
}

source_model_store() {
  # shellcheck source=/dev/null
  source "$MODEL_STORE_LIB"
}

@test "model store resolves config dir from RALPH_CONFIG_HOME" {
  source_model_store
  run ralph_model_store_config_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$RALPH_CONFIG_HOME" ]
}

@test "model store read returns defaults when models.json is missing" {
  source_model_store
  run jq -e '.schema_version == 1 and (.claude | length) == 0 and (.codex | length) == 0' <<< "$(ralph_model_store_read)"
  [ "$status" -eq 0 ]
}

@test "model store add prepends, deduplicates, and remove updates lists" {
  source_model_store
  ralph_model_store_add claude first-model
  ralph_model_store_add claude second-model
  ralph_model_store_add claude first-model

  run ralph_model_store_list claude
  [ "$status" -eq 0 ]
  [ "$output" = $'first-model\nsecond-model' ]

  run ralph_model_store_default claude
  [ "$status" -eq 0 ]
  [ "$output" = "first-model" ]

  ralph_model_store_remove claude first-model
  run ralph_model_store_list claude
  [ "$status" -eq 0 ]
  [ "$output" = "second-model" ]
}

@test "model store normalizes invalid on-disk JSON" {
  source_model_store
  printf '{"schema_version":99,"claude":["ok",1,""],"codex":null}\n' > "$(ralph_model_store_path)"
  run jq -e '.schema_version == 1 and .claude == ["ok"] and .codex == []' <<< "$(ralph_model_store_read)"
  [ "$status" -eq 0 ]
}

@test "models.sh list add and remove manage saved models" {
  run bash "$MODELS_SH" add claude claude-test-1
  [ "$status" -eq 0 ]

  run bash "$MODELS_SH" list claude
  [ "$status" -eq 0 ]
  [ "$output" = "claude-test-1" ]

  run bash "$MODELS_SH" remove claude claude-test-1
  [ "$status" -eq 0 ]

  run bash "$MODELS_SH" list claude
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "models.sh rejects invalid runtime and missing arguments" {
  run bash "$MODELS_SH" list cursor
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid runtime"* ]]

  run bash "$MODELS_SH" add claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires <runtime> and <model-id>"* ]]

  run bash "$MODELS_SH" bogus claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "ralph shim dispatches models subcommand to models.sh" {
  temp_home="$(mktemp -d)"
  ralph_home="$temp_home/global-ralph"
  xdg_config="$temp_home/config"
  xdg_state="$temp_home/state"
  shim="$temp_home/.local/bin/ralph"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" \
    bash "$REPO_ROOT/install.sh" --global --silent --no-dashboard
  [ "$status" -eq 0 ]

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" \
    "$shim" models --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"models.sh"* ]]

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" \
    bash "$MODELS_SH" add codex shim-model
  [ "$status" -eq 0 ]

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" \
    "$shim" models list codex
  [ "$status" -eq 0 ]
  [ "$output" = "shim-model" ]

  rm -rf "$temp_home"
}

@test "claude selector prompts for manual entry when no saved models exist" {
  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    mkdir -p "$RALPH_CONFIG_HOME"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    _select_model_read_rp() {
      local _var="$2"
      read -r "$_var"
    }
    export -f _select_model_read_rp
    printf "manual-claude-model\n" | select_model_claude --interactive 2>/dev/null
  ' _ "$RALPH_CONFIG_HOME" "$SELECT_MODEL_COMMON" "$SELECT_MODEL_CLAUDE"
  [ "$status" -eq 0 ]
  [ "$output" = "manual-claude-model" ]
}

@test "claude selector uses saved model menu when models exist" {
  bash "$MODELS_SH" add claude saved-alpha
  bash "$MODELS_SH" add claude saved-beta

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    # shellcheck source=/dev/null
    source "$4"
    select_model_claude --batch 1 "" ""
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON" "$SELECT_MODEL_CLAUDE"
  [ "$status" -eq 0 ]
  [ "$output" = "saved-beta" ]
}

@test "codex selector resolves saved default in batch non-interactive mode" {
  bash "$MODELS_SH" add codex codex-saved-default

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL CODEX_PLAN_MODEL
    # shellcheck source=/dev/null
    source "$3"
    # shellcheck source=/dev/null
    source "$4"
    select_model_codex --batch 1 "" ""
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON" "$SELECT_MODEL_CODEX"
  [ "$status" -eq 0 ]
  [ "$output" = "codex-saved-default" ]
}

@test "codex selector prompts for manual entry when no saved models exist" {
  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    mkdir -p "$RALPH_CONFIG_HOME"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    _select_model_read_rp() {
      local _var="$2"
      read -r "$_var"
    }
    printf "manual-codex-model\n" | select_model_codex --interactive 2>/dev/null
  ' _ "$RALPH_CONFIG_HOME" "$SELECT_MODEL_COMMON" "$SELECT_MODEL_CODEX"
  [ "$status" -eq 0 ]
  [ "$output" = "manual-codex-model" ]
}

@test "claude codex resolution chain honors cli env agent and saved default order" {
  bash "$MODELS_SH" add claude chain-saved

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL CODEX_PLAN_MODEL
    # shellcheck source=/dev/null
    source "$3"
    PLAN_MODEL_CLI=cli-model NON_INTERACTIVE_FLAG=1 \
      ralph_resolve_claude_codex_plan_model claude agent-model
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "cli-model" ]

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL CODEX_PLAN_MODEL
    # shellcheck source=/dev/null
    source "$3"
    export CLAUDE_PLAN_MODEL=env-model NON_INTERACTIVE_FLAG=1
    ralph_resolve_claude_codex_plan_model claude agent-model
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "env-model" ]

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL CODEX_PLAN_MODEL
    # shellcheck source=/dev/null
    source "$3"
    export NON_INTERACTIVE_FLAG=1
    ralph_resolve_claude_codex_plan_model claude agent-model
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "agent-model" ]

  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL CODEX_PLAN_MODEL
    # shellcheck source=/dev/null
    source "$3"
    export NON_INTERACTIVE_FLAG=1
    ralph_resolve_claude_codex_plan_model claude ""
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "chain-saved" ]
}

@test "non-interactive claude resolution fails when no model source is available" {
  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL
    export NON_INTERACTIVE_FLAG=1
    ralph_resolve_claude_codex_plan_model claude ""
  ' _ "$RALPH_CONFIG_HOME" "$SELECT_MODEL_COMMON"
  [ "$status" -ne 0 ]
}

@test "run-plan non-interactive preflight fails for claude without resolvable model" {
  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    NON_INTERACTIVE_FLAG=1
    RUNTIME=claude
    PREBUILT_AGENT=research
    WORKSPACE="$2"
    unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL CODEX_PLAN_MODEL
    # shellcheck source=/dev/null
    source "$3"
    # shellcheck source=/dev/null
    source "$4"
    # shellcheck source=/dev/null
    source "$5"
    read_prebuilt_agent_model() { printf ""; }
    ralph_run_plan_non_interactive_model_preflight_ok
  ' _ "$RALPH_CONFIG_HOME" "$REPO_ROOT" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON" "$RUN_PLAN_AGENT_LIB"
  [ "$status" -ne 0 ]
}

@test "run-plan non-interactive preflight passes for claude with saved default" {
  bash "$MODELS_SH" add claude preflight-saved

  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    NON_INTERACTIVE_FLAG=1
    RUNTIME=claude
    PREBUILT_AGENT=research
    WORKSPACE="$2"
    unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL CODEX_PLAN_MODEL
    # shellcheck source=/dev/null
    source "$3"
    # shellcheck source=/dev/null
    source "$4"
    # shellcheck source=/dev/null
    source "$5"
    read_prebuilt_agent_model() { printf ""; }
    ralph_run_plan_non_interactive_model_preflight_ok
  ' _ "$RALPH_CONFIG_HOME" "$REPO_ROOT" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON" "$RUN_PLAN_AGENT_LIB"
  [ "$status" -eq 0 ]
}

@test "run-plan die helper mentions ralph models add for unresolved claude model" {
  run bash -c '
    set -euo pipefail
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    ralph_run_plan_log() { printf "%s\n" "$*"; }
    # shellcheck source=/dev/null
    source "$1"
    ralph_run_plan_die_unresolved_claude_codex_model claude
  ' _ "$RUN_PLAN_AGENT_LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ralph models add claude"* ]]
}

@test "agent config validation accepts empty model string" {
  agents_root="$(mktemp -d)"
  agent_id="empty-model"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "empty-model",
  "model": "",
  "description": "Agent with empty bundled default model",
  "rules": [
    "rule-ok"
  ],
  "skills": [
    "skill-ok"
  ],
  "output_artifacts": [
    {
      "path": "artifacts/empty-model.txt",
      "required": true
    }
  ]
}
CONFIG

  run bash "$REPO_ROOT/bundle/.ralph/agent-config-tool.sh" validate "$agents_root" "$agent_id" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  rm -rf "$agents_root"
}

@test "bundle claude research agent validates with empty model" {
  run bash "$REPO_ROOT/bundle/.ralph/agent-config-tool.sh" \
    validate "$REPO_ROOT/bundle/.claude/agents" research "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "wizard select_model_override skips agent default when model is empty" {
  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    export RALPH_SKIP_FZF_HINT=1
    # shellcheck source=/dev/null
    source "$2/bundle/.ralph/bash-lib/error-handling.sh"
    # shellcheck source=/dev/null
    source "$2/bundle/.ralph/bash-lib/wizard/wizard-prompts.sh"
    pick_model_for_runtime() { printf "wizard-picked-model"; }
    select_model_override claude research ""
  ' _ "$RALPH_CONFIG_HOME" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "wizard-picked-model" ]
}

@test "new-agent select_models uses saved claude model in non-interactive mode" {
  bash "$MODELS_SH" add claude new-agent-saved

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    export RALPH_NEW_AGENT_CURSOR_ONLY=1
    SCAFFOLD_CLAUDE=1
    SCAFFOLD_CODEX=0
    SCAFFOLD_OPENCODE=0
    SCAFFOLD_ANTIGRAVITY=0
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    # shellcheck source=/dev/null
    source "$4"
    # shellcheck source=/dev/null
    source "$5"
    unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL CODEX_PLAN_MODEL
    select_model_cursor() {
      if [[ "${1:-}" == "--no-interactive" ]]; then
        printf "cursor-env-model"
        return
      fi
      printf "cursor-interactive"
    }
    select_models 1
    printf "cursor=%s claude=%s\n" "$MODEL_CURSOR" "$MODEL_CLAUDE"
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON" "$SELECT_MODEL_CLAUDE" "$NEW_AGENT_HELPERS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cursor=cursor-env-model"* ]]
  [[ "$output" == *"claude=new-agent-saved"* ]]
}
