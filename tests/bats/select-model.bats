#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "select-model uses cursor-agent list models when available" {
  [ -f "$REPO_ROOT/bundle/.cursor/ralph/select-model.sh" ] || skip "cursor select-model missing"

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
  ' _ "$REPO_ROOT/bundle/.cursor/ralph/select-model.sh" "$stub_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"auto"* ]]
  [[ "$output" == *"foo-bar"* ]]
  [[ "$output" != *"Tip:"* ]]
}
