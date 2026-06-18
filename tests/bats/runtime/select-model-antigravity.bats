#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

@test "antigravity model discovery preserves exact agy models strings" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-antigravity.sh" ] || skip "antigravity select-model missing"

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

  run bash -c '
    set -euo pipefail
    source "$1"
    PATH="$2:$PATH"
    export PATH
    RALPH_SM_ANTIGRAVITY_CLI="agy"
    _antigravity_list_models
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-antigravity.sh" "$stub_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude Sonnet 4.6 (thinking)"* ]]
  [[ "$output" == *"Gemini 3.1 Pro (high)"* ]]
}

@test "select_model_antigravity --no-interactive preserves ANTIGRAVITY_PLAN_MODEL byte-for-byte" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-antigravity.sh" ] || skip "antigravity select-model missing"

  run bash -c '
    set -euo pipefail
    source "$1"
    ANTIGRAVITY_PLAN_MODEL="Exact Model Name (preview)" select_model_antigravity --no-interactive
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-antigravity.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "Exact Model Name (preview)" ]
}
