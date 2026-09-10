#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

MODEL_STORE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/select-model/model-store.sh"
MODELS_SH="$REPO_ROOT/bundle/.ralph/models.sh"
SELECT_MODEL_COMMON="$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-common.sh"
SELECT_MODEL_CLAUDE="$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-claude.sh"
SELECT_MODEL_CODEX="$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-codex.sh"
RUN_PLAN_AGENT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-agent.sh"
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
  [ "$output" = $'claude-test-1\nhaiku\nsonnet\nopus\nfable' ]

  run bash "$MODELS_SH" remove claude claude-test-1
  [ "$status" -eq 0 ]

  run bash "$MODELS_SH" list claude
  [ "$status" -eq 0 ]
  [ "$output" = $'haiku\nsonnet\nopus\nfable' ]
}

@test "models.sh refuses removing Claude built-in default aliases and leaves catalog unchanged" {
  local store_path before_json alias_id
  store_path="$RALPH_CONFIG_HOME/models.json"

  # Seed all four protected aliases plus a custom Claude model and a Codex model.
  run bash "$MODELS_SH" add claude haiku
  [ "$status" -eq 0 ]
  run bash "$MODELS_SH" add claude sonnet
  [ "$status" -eq 0 ]
  run bash "$MODELS_SH" add claude opus
  [ "$status" -eq 0 ]
  run bash "$MODELS_SH" add claude fable
  [ "$status" -eq 0 ]
  run bash "$MODELS_SH" add claude claude-custom-keep
  [ "$status" -eq 0 ]
  run bash "$MODELS_SH" add codex codex-custom-keep
  [ "$status" -eq 0 ]

  before_json="$(cat "$store_path")"

  for alias_id in haiku sonnet opus fable; do
    run bash "$MODELS_SH" remove claude "$alias_id"
    [ "$status" -ne 0 ]
    [[ "$output" == *"built-in Claude default aliases cannot be removed"* ]]
    [[ "$output" == *"$alias_id"* ]]
    # Byte-equivalent saved catalog after each refused remove.
    [ "$(cat "$store_path")" = "$before_json" ]
  done

  # Custom Claude IDs (including similarly named ones) remain removable.
  run bash "$MODELS_SH" add claude claude-haiku-4-5
  [ "$status" -eq 0 ]
  run bash "$MODELS_SH" remove claude claude-haiku-4-5
  [ "$status" -eq 0 ]
  run bash "$MODELS_SH" remove claude claude-custom-keep
  [ "$status" -eq 0 ]

  # Codex models with the same short names are not protected.
  run bash "$MODELS_SH" add codex haiku
  [ "$status" -eq 0 ]
  run bash "$MODELS_SH" remove codex haiku
  [ "$status" -eq 0 ]
  run bash "$MODELS_SH" remove codex codex-custom-keep
  [ "$status" -eq 0 ]

  # Protected aliases remain in the saved Claude catalog (assert via store JSON;
  # list merge already covers empty/partial catalogs elsewhere).
  run jq -e '
    .claude == ["fable","opus","sonnet","haiku"]
    and .codex == []
  ' "$store_path"
  [ "$status" -eq 0 ]

  # List still exposes the four built-in aliases for an empty Claude catalog.
  printf '%s\n' '{"schema_version":1,"claude":[],"codex":[]}' > "$store_path"
  run bash "$MODELS_SH" list claude
  [ "$status" -eq 0 ]
  [ "$output" = $'haiku\nsonnet\nopus\nfable' ]
}

@test "models.sh list claude uses built-in aliases for an empty isolated store" {
  run bash "$MODELS_SH" list claude
  [ "$status" -eq 0 ]
  [ "$output" = $'haiku\nsonnet\nopus\nfable' ]
}

@test "models.sh list claude keeps saved ids first and appends missing aliases once" {
  printf '%s\n' '{"schema_version":1,"claude":["claude-sonnet-4-6","claude-haiku-4-5","opus"],"codex":[]}' \
    > "$RALPH_CONFIG_HOME/models.json"

  run bash "$MODELS_SH" list claude
  [ "$status" -eq 0 ]
  [ "$output" = $'claude-sonnet-4-6\nclaude-haiku-4-5\nopus\nhaiku\nsonnet\nfable' ]

  run bash "$MODELS_SH" list codex
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "models.sh rejects invalid runtime and missing arguments" {
  run bash "$MODELS_SH" list bogus-runtime
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid runtime"* ]]

  run bash "$MODELS_SH" add cursor some-model
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid runtime"* ]]

  run bash "$MODELS_SH" remove opencode some-model
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid runtime"* ]]

  run bash "$MODELS_SH" add antigravity some-model
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid runtime"* ]]

  run bash "$MODELS_SH" add claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires <runtime> and <model-id>"* ]]

  run bash "$MODELS_SH" bogus claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "models.sh list cursor discovers via stubbed cursor-agent without writing models.json" {
  local stub_dir
  stub_dir="$(mktemp -d)"
  trap 'rm -rf "${stub_dir:-}"' RETURN

  cat <<'EOF' > "$stub_dir/cursor-agent"
#!/usr/bin/env bash
if [[ "$1" == "--list-models" ]]; then
  cat <<'MODELS'
auto - auto chooser
foo-bar - foo chooser
Tip: Try the tutorials
MODELS
  exit 0
fi
printf '%s\n' "unexpected args: $*" >&2
exit 1
EOF
  chmod +x "$stub_dir/cursor-agent"

  run env PATH="$stub_dir:$PATH" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" \
    bash "$MODELS_SH" list cursor
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto"* ]]
  [[ "$output" == *"foo-bar"* ]]
  [[ "$output" != *"Tip:"* ]]
  [ ! -f "$RALPH_CONFIG_HOME/models.json" ]
}

@test "models.sh list opencode discovers via stubbed opencode without writing models.json" {
  local stub_dir
  stub_dir="$(mktemp -d)"
  trap 'rm -rf "${stub_dir:-}"' RETURN

  cat <<'EOF' > "$stub_dir/opencode"
#!/usr/bin/env bash
if [[ "$1" == "models" ]]; then
  cat <<'MODELS'
ollama-cloud/kimi-k2.5
opencode/gpt-5-nano
MODELS
  exit 0
fi
printf '%s\n' "unexpected args: $*" >&2
exit 1
EOF
  chmod +x "$stub_dir/opencode"

  run env PATH="$stub_dir:$PATH" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" \
    bash "$MODELS_SH" list opencode
  [ "$status" -eq 0 ]
  [[ "$output" == *"ollama-cloud/kimi-k2.5"* ]]
  [[ "$output" == *"opencode/gpt-5-nano"* ]]
  [ ! -f "$RALPH_CONFIG_HOME/models.json" ]
}

@test "models.sh list antigravity preserves exact agy display strings without writing models.json" {
  local stub_dir
  stub_dir="$(mktemp -d)"
  trap 'rm -rf "${stub_dir:-}"' RETURN

  cat <<'EOF' > "$stub_dir/agy"
#!/usr/bin/env bash
if [[ "$1" == "models" ]]; then
  cat <<'MODELS'
Claude Sonnet 4.6 (thinking)
Gemini 3.1 Pro (high)
MODELS
  exit 0
fi
printf '%s\n' "unexpected args: $*" >&2
exit 1
EOF
  chmod +x "$stub_dir/agy"

  run env PATH="$stub_dir:$PATH" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" \
    bash "$MODELS_SH" list antigravity
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude Sonnet 4.6 (thinking)"* ]]
  [[ "$output" == *"Gemini 3.1 Pro (high)"* ]]
  [ ! -f "$RALPH_CONFIG_HOME/models.json" ]
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

@test "claude selector offers default alias menu when no saved models exist" {
  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    mkdir -p "$RALPH_CONFIG_HOME"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    choices_file="$RALPH_CONFIG_HOME/menu-choices"
    ralph_menu_select() {
      shift 4
      shift
      printf "%s" "$*" >"$choices_file"
      printf "opus"
    }
    export choices_file
    select_model_claude --interactive 2>/dev/null
    [ "$(cat "$choices_file")" = "haiku sonnet opus fable Enter custom model id" ]
  ' _ "$RALPH_CONFIG_HOME" "$SELECT_MODEL_COMMON" "$SELECT_MODEL_CLAUDE"
  [ "$status" -eq 0 ]
  [ "$output" = "opus" ]
}

@test "claude selector prompts for manual entry via custom placeholder when no saved models exist" {
  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    mkdir -p "$RALPH_CONFIG_HOME"
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    ralph_menu_select() { printf "Enter custom model id"; }
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

@test "claude codex resolution chain honors cli todo and saved default order" {
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
    # Neither *_PLAN_MODEL env nor a profile model is a resolution rung; the
    # saved default is the next one after CLI and TODO.
    export CLAUDE_PLAN_MODEL=env-model NON_INTERACTIVE_FLAG=1
    ralph_resolve_claude_codex_plan_model claude agent-model
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "chain-saved" ]

  run env -i PATH="$PATH" HOME="$HOME" RALPH_CONFIG_HOME="$RALPH_CONFIG_HOME" bash --noprofile --norc -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL CODEX_PLAN_MODEL
    # shellcheck source=/dev/null
    source "$3"
    # The legacy second argument (profile model) is ignored entirely.
    export NON_INTERACTIVE_FLAG=1
    ralph_resolve_claude_codex_plan_model claude agent-model
  ' _ "$RALPH_CONFIG_HOME" "$MODEL_STORE_LIB" "$SELECT_MODEL_COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "chain-saved" ]

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

@test "non-interactive claude resolution falls back to the runtime-native default" {
  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    unset PLAN_MODEL_CLI CLAUDE_PLAN_MODEL CURSOR_PLAN_MODEL
    export NON_INTERACTIVE_FLAG=1
    ralph_resolve_claude_codex_plan_model claude ""
  ' _ "$RALPH_CONFIG_HOME" "$SELECT_MODEL_COMMON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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

@test "run-plan staged non-interactive preflight accepts cursor stage model" {
  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    NON_INTERACTIVE_FLAG=1
    RUNTIME=cursor
    RALPH_MODEL_SCOPE=staged
    PLAN_STAGE_MODEL=auto
    unset PLAN_MODEL_CLI CURSOR_PLAN_MODEL
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    ralph_run_plan_non_interactive_model_preflight_ok
  ' _ "$RALPH_CONFIG_HOME" "$SELECT_MODEL_COMMON" "$RUN_PLAN_AGENT_LIB"
  [ "$status" -eq 0 ]
}

@test "run-plan staged non-interactive preflight accepts cursor native default" {
  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    NON_INTERACTIVE_FLAG=1
    RUNTIME=cursor
    RALPH_MODEL_SCOPE=staged
    PLAN_STAGE_MODEL=""
    unset PLAN_MODEL_CLI CURSOR_PLAN_MODEL
    # shellcheck source=/dev/null
    source "$2"
    # shellcheck source=/dev/null
    source "$3"
    ralph_run_plan_non_interactive_model_preflight_ok
  ' _ "$RALPH_CONFIG_HOME" "$SELECT_MODEL_COMMON" "$RUN_PLAN_AGENT_LIB"
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

# The agent-config-tool and its empty-model validation were removed with the
# agent-profile surface; roles never carry a model, which
# tests/bats/role-resource.bats asserts for every bundled role.
