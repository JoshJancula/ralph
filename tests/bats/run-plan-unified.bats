#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"

@test "unified runner entrypoint exists (bundle)" {
  [ -f "$RUN_PLAN_SH" ]
}

@test "missing runtime without TTY fails fast with guidance" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  # Bats inherits a TTY when run from an interactive terminal; force non-TTY stdin
  # so we exercise the fast-fail branch instead of blocking on the runtime menu.
  unset RALPH_PLAN_RUNTIME
  run "$RUN_PLAN_SH" --plan "$REPO_ROOT/PLAN.md" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: runtime must be provided via --runtime or RALPH_PLAN_RUNTIME when stdin is not a terminal."* ]]
}

@test "missing runtime with non-interactive still requires explicit runtime" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run "$RUN_PLAN_SH" --non-interactive --plan "$REPO_ROOT/PLAN.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: runtime must be provided via --runtime or RALPH_PLAN_RUNTIME (cursor, claude, or codex)."* ]]
}

@test "invalid runtime value fails fast with guidance" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run "$RUN_PLAN_SH" --runtime invalid --plan "$REPO_ROOT/PLAN.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: --runtime must be one of cursor, claude, or codex."* ]]
}

@test "--help and unknown flag exit quickly" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run /usr/bin/env bash "$RUN_PLAN_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]

  run /usr/bin/env bash "$RUN_PLAN_SH" --invalid-flag
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "non-interactive gate includes --model (PLAN_MODEL_CLI)" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  grep -Fq 'PLAN_MODEL_CLI' "$RUN_PLAN_SH"
  run grep -F 'Non-interactive mode requires a prebuilt agent' "$RUN_PLAN_SH"
  [[ "$output" == *"--model <id>"* ]]
}

@test "--model requires a value" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run /usr/bin/env bash "$RUN_PLAN_SH" --runtime cursor --plan "$REPO_ROOT/PLAN.md" --model
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: --model requires a model id string."* ]]
}

@test "non-interactive run-plan stops with stubbed CLI" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir cursor_record claude_record codex_record
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  mkdir -p "$bin_dir"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Non-interactive stub plan
- [ ] stub non-interactive invocation
EOF

  local select_model_dir
  select_model_dir="$workspace/.cursor/ralph"
  mkdir -p "$select_model_dir"
  cat <<'EOF' > "$select_model_dir/select-model.sh"
#!/usr/bin/env bash
select_model_cursor() {
  if [[ "$1" == "--batch" ]]; then
    shift
  fi
  printf '%s\n' "stub-model"
}
export -f select_model_cursor >/dev/null 2>&1 || true
EOF
  chmod +x "$select_model_dir/select-model.sh"

  local agent_tool_dir
  agent_tool_dir="$workspace/.ralph"
  mkdir -p "$agent_tool_dir"
  cat <<'EOF' > "$agent_tool_dir/agent-config-tool.sh"
#!/usr/bin/env bash
case "$1" in
  list|validate|model|context|allowed-tools|downstream-stages)
    ;;
  *)
    ;;
esac
exit 0
EOF
  chmod +x "$agent_tool_dir/agent-config-tool.sh"

  cursor_record="$workspace/cursor.args"
  claude_record="$workspace/claude.args"
  codex_record="$workspace/codex.args"

  cat <<EOF > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$cursor_record"
if [[ -n "\$STUB_PLAN_PATH" && -f "\$STUB_PLAN_PATH" ]]; then
  if command -v python3 &>/dev/null; then
    python3 - <<'PY'
import os, pathlib
path = pathlib.Path(os.environ["STUB_PLAN_PATH"])
text = path.read_text()
target = "- [ ]"
if target in text:
    path.write_text(text.replace(target, "- [x]", 1))
PY
  fi
fi
exit 0
EOF

  cat <<EOF > "$bin_dir/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$claude_record"
exit 0
EOF

  cat <<EOF > "$bin_dir/codex"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$codex_record"
exit 0
EOF

  chmod +x "$bin_dir/cursor-agent" "$bin_dir/claude" "$bin_dir/codex"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export STUB_PLAN_PATH="$4"
    "$3" --runtime cursor --plan PLAN.md --non-interactive --model stub-model
  ' _ "$workspace" "$bin_dir" "$RUN_PLAN_SH" "$plan_file"

  [ "$status" -eq 0 ]
  grep -Fq -- "--model" "$cursor_record"
  grep -Fq -- "stub-model" "$cursor_record"
  grep -Fq -- "- [x]" "$plan_file"

  rm -rf "$workspace"
}

@test "bundle run-plan.sh is valid bash" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run bash -n "$RUN_PLAN_SH"
  [ "$status" -eq 0 ]
}

@test "run-plan sources menu-select helper for prebuilt agent TTY menu" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  grep -Fq 'bash-lib/menu-select.sh' "$RUN_PLAN_SH"
}

@test "menu-select library defines ralph_menu_select" {
  local lib="$REPO_ROOT/bundle/.ralph/bash-lib/menu-select.sh"
  [ -f "$lib" ] || skip "menu-select lib missing"
  run bash -c 'source "$1"; type -t ralph_menu_select' _ "$lib"
  [ "$status" -eq 0 ]
  [[ "$output" == function ]]
}

@test "run-plan fails early when shared layout is missing" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  local bad_layout
  bad_layout="$(mktemp -d)"
  cp "$RUN_PLAN_SH" "$bad_layout/run-plan.sh"
  chmod +x "$bad_layout/run-plan.sh"

  run bash "$bad_layout/run-plan.sh" --runtime cursor --plan "$REPO_ROOT/PLAN.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bash-lib/run-plan-env.sh: No such file or directory"* ]]

  rm -rf "$bad_layout"
}
