#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

@test "select-model uses cursor-agent list models when available" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-cursor.sh" ] || skip "cursor select-model missing"

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

  run bash -c '
    set -euo pipefail
    source "$1"
    PATH="$2:$PATH"
    export PATH
    _cursor_list_models
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-cursor.sh" "$stub_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"auto"* ]]
  [[ "$output" == *"foo-bar"* ]]
  [[ "$output" != *"Tip:"* ]]
}

@test "opencode model discovery only reflects opencode models output" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-opencode.sh" ] || skip "opencode select-model missing"

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

  run bash -c '
    set -euo pipefail
    source "$1"
    PATH="$2:$PATH"
    export PATH
    _opencode_list_models_from_cli
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-opencode.sh" "$stub_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ollama-cloud/kimi-k2.5"* ]]
  [[ "$output" == *"opencode/gpt-5-nano"* ]]
  [[ "$output" != *"anthropic/claude-sonnet-4-6"* ]]
}

@test "cursor model menu falls back to local config when the CLI cannot list models" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-cursor.sh" ] || skip "cursor select-model missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required for the config fallback"

  local stub_dir
  stub_dir="$(mktemp -d)"
  trap 'rm -rf "${stub_dir:-}"' RETURN

  # Reproduces the real failure: the CLI is installed but --list-models is
  # rejected, so nothing is enumerated and stderr carries the reason.
  cat <<'EOF' > "$stub_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "Error: Authentication required." >&2
exit 1
EOF
  chmod +x "$stub_dir/cursor-agent"

  cat <<'EOF' > "$stub_dir/cli-config.json"
{
  "modelSelectionHistory": ["default", "composer-2.5"],
  "modelParameters": {"claude-sonnet-5": [], "default": []}
}
EOF

  run bash -c '
    set -euo pipefail
    source "$1"
    PATH="$2:$PATH"
    export PATH
    export CURSOR_CLI_CONFIG="$3"
    ralph_menu_select() {
      while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
      shift
      printf "MENU:%s\n" "$@" >&2
      printf "%s\n" "$1"
    }
    _cursor_select_model_interactive >/dev/null
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-cursor.sh" \
      "$stub_dir" "$stub_dir/cli-config.json"

  [ "$status" -eq 0 ]
  # Models come from the local Cursor config, not a stale hardcoded list.
  [[ "$output" == *"MENU:composer-2.5"* ]]
  [[ "$output" == *"MENU:claude-sonnet-5"* ]]
  [[ "$output" != *"MENU:default"* ]]
  # The auth failure is surfaced as the root cause, with the fix.
  [[ "$output" == *"Cursor CLI is not authenticated"* ]]
  [[ "$output" == *"Authentication required"* ]]
  [[ "$output" == *"cursor-agent login"* ]]
}

@test "cursor model menu reports a non-auth listing failure without the login hint" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-cursor.sh" ] || skip "cursor select-model missing"

  local stub_dir
  stub_dir="$(mktemp -d)"
  trap 'rm -rf "${stub_dir:-}"' RETURN

  cat <<'EOF' > "$stub_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "Error: network unreachable" >&2
exit 1
EOF
  chmod +x "$stub_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    source "$1"
    PATH="$2:$PATH"
    export PATH
    export CURSOR_CLI_CONFIG=/nonexistent
    ralph_menu_select() {
      while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
      shift
      printf "MENU:%s\n" "$@" >&2
      printf "%s\n" "$1"
    }
    _cursor_select_model_interactive >/dev/null
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-cursor.sh" "$stub_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not list Cursor models"* ]]
  [[ "$output" == *"network unreachable"* ]]
  [[ "$output" != *"not authenticated"* ]]
}
