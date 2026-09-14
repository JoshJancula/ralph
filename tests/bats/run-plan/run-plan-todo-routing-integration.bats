#!/usr/bin/env bats
# Cross-runner acceptance: final runtime argv + runtime-scoped session files
# across successive fresh TODO invocations.
#
# Cost justification (acceptance tier): the contract is only observable at the
# real run-plan -> stub CLI boundary across a multi-TODO sequence. Two runner
# invocations on one shared workspace cover standalone
# (TODO > CLI > plan header > saved/native) and generated workflow-plan
# (TODO > stage > invocation/default > saved/native) with immutable source
# vs mutable control. RALPH_WAIT_SCALE=0; no network or real model.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"
MODELS_SH="$REPO_ROOT/bundle/.ralph/models.sh"

setup_file() {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
}

setup() {
  bats_skip_known_ci_flakes
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  TRI_TMP="$(mktemp -d)"
  TRI_WS="$TRI_TMP/workspace"
  TRI_BIN="$TRI_TMP/bin"
  TRI_SESSIONS="$TRI_TMP/sessions"
  TRI_CONFIG="$TRI_TMP/ralph-config"
  TRI_CURSOR_LOG="$TRI_TMP/cursor.record"
  TRI_CLAUDE_LOG="$TRI_TMP/claude.record"
  TRI_REGISTRY="$TRI_TMP/registry"
  mkdir -p "$TRI_WS" "$TRI_BIN" "$TRI_SESSIONS" "$TRI_CONFIG" "$TRI_TMP/home"
  mkdir -p "$TRI_WS/.cursor" "$TRI_WS/.claude" "$TRI_WS/.codex" "$TRI_WS/.opencode" "$TRI_WS/.agents"
  : >"$TRI_CURSOR_LOG"
  : >"$TRI_CLAUDE_LOG"
  : >"$TRI_REGISTRY"

  tri_write_stub_cli "$TRI_BIN/cursor-agent" cursor "$TRI_CURSOR_LOG"
  tri_write_stub_cli "$TRI_BIN/claude" claude "$TRI_CLAUDE_LOG"
  RALPH_CONFIG_HOME="$TRI_CONFIG" bash "$MODELS_SH" add claude claude-saved-model
}

teardown() {
  [[ -n "${TRI_TMP:-}" ]] && ralph_test_rm_workspace "$TRI_TMP"
  return 0
}

tri_write_stub_cli() {
  local exe_path="$1"
  local runtime_label="$2"
  local record_file="$3"

  cat >"$exe_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

runtime_label="$runtime_label"
record_file="$record_file"

if [[ "\${1:-}" == "exec" && "\${2:-}" == "--help" ]]; then
  printf '%s\n' "Usage: codex exec" "  --config <key=value>"
  exit 0
fi
if [[ "\${1:-}" == "--help" || "\${1:-}" == "-h" ]]; then
  printf '%s\n' "Usage: \$runtime_label"
  exit 0
fi

model=""
resume=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --model)
      model="\${2:-}"
      shift 2
      ;;
    --resume)
      if [[ -n "\${2:-}" && "\${2:-}" != --* ]]; then
        resume="--resume:\${2}"
        shift 2
      else
        resume="--resume"
        shift
      fi
      ;;
    --continue|--last|--session-id)
      resume="\${resume:+\$resume }\$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s|%s|%s|%s\n' "\$runtime_label" "\${SESSION_ID_FILE:-}" "\$resume" "\$model" >>"\$record_file"

plan_path="\${RALPH_CURRENT_PLAN_PATH:-}"
if [[ -n "\$plan_path" && -f "\$plan_path" ]]; then
  python3 - "\$plan_path" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
for old, new in (
    ("status: pending", "status: completed"),
    ("status: open", "status: completed"),
    ("- [ ]", "- [x]"),
):
    if old in text:
        path.write_text(text.replace(old, new, 1))
        break
PY
fi

printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: SKIPPED"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
EOF
  chmod +x "$exe_path"
}

tri_run_plan() {
  local plan_rel="$1"
  shift
  local env_assignments=()
  local plan_args=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      *=*) env_assignments+=("$arg") ;;
      *) plan_args+=("$arg") ;;
    esac
  done
  env -i \
    PATH="$TRI_BIN:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
    HOME="$TRI_TMP/home" \
    RALPH_CONFIG_HOME="$TRI_CONFIG" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    RALPH_PLAN_SESSION_HOME="$TRI_SESSIONS" \
    RALPH_PLAN_NO_CAFFEINATE=1 \
    RALPH_LAUNCHER_PID=$$ \
    RALPH_WORKSPACES_FILE="$TRI_REGISTRY" \
    RALPH_WAIT_SCALE=0 \
    "${env_assignments[@]}" \
    bash "$RUN_PLAN_SH" --plan "$plan_rel" --non-interactive --workspace "$TRI_WS" \
    "${plan_args[@]}"
}

tri_record_lines() {
  local file="$1"
  if [[ -s "$file" ]]; then
    cat "$file"
  fi
}

tri_assert_line() {
  local line="$1"
  local want_runtime="$2"
  local want_model="$3"
  local runtime session resume model
  IFS='|' read -r runtime session resume model <<<"$line"
  [ "$runtime" = "$want_runtime" ]
  [ "$model" = "$want_model" ]
  [ "$resume" = "" ]
  [[ "$session" == *"/session-id.${want_runtime}.txt" ]]
}

@test "standalone TODO > CLI > plan header > saved/native across fresh invocations" {
  # One run-plan invocation: CLI baseline beats header; TODO beats CLI;
  # runtime-only uses switched runtime saved/native; paired pins both;
  # following unpinned restores CLI baseline. Header remains below CLI.
  cat >"$TRI_WS/standalone.plan.md" <<'EOF'
---
name: standalone-routing
overview: Standalone precedence across successive TODOs
runtime: cursor
model: header-model
sessionStrategy: fresh
todos:
  - id: baseline
    content: Unpinned TODO uses CLI model over plan header.
    verification: true
    status: pending
  - id: model-only
    model: todo-model
    content: Model-only TODO inherits baseline runtime.
    verification: true
    status: pending
  - id: runtime-only
    runtime: claude
    content: Runtime-only TODO uses switched runtime saved model.
    verification: true
    status: pending
  - id: paired
    runtime: claude
    model: paired-model
    content: Paired runtime and model TODO.
    verification: true
    status: pending
  - id: restore
    content: Unpinned TODO restores CLI baseline runtime and model.
    verification: true
    status: pending
---
EOF

  run tri_run_plan standalone.plan.md --runtime cursor --model cli-model
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&2
  fi
  [ "$status" -eq 0 ]

  local cursor_lines=() claude_lines=()
  while IFS= read -r line; do
    cursor_lines+=("$line")
  done < <(tri_record_lines "$TRI_CURSOR_LOG")
  while IFS= read -r line; do
    claude_lines+=("$line")
  done < <(tri_record_lines "$TRI_CLAUDE_LOG")

  [ "${#cursor_lines[@]}" -eq 3 ]
  [ "${#claude_lines[@]}" -eq 2 ]

  tri_assert_line "${cursor_lines[0]}" cursor cli-model
  tri_assert_line "${cursor_lines[1]}" cursor todo-model
  tri_assert_line "${claude_lines[0]}" claude claude-saved-model
  tri_assert_line "${claude_lines[1]}" claude paired-model
  tri_assert_line "${cursor_lines[2]}" cursor cli-model

  run grep -c 'status: completed' "$TRI_WS/standalone.plan.md"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "generated workflow-plan TODO > stage > invocation/default > saved/native with immutable source" {
  # One run-plan invocation on the mutable control copy under staged scope.
  # PLAN_STAGE_MODEL is the already-resolved stage/invocation/default pin at
  # the run-plan boundary; TODO overrides beat it; runtime-only uses saved;
  # unpinned restores the staged baseline. Immutable source bytes stay fixed.
  local source_dir control_dir source_plan control_plan before_sha after_sha
  source_dir="$TRI_WS/.ralph-workspace/workflow-runs/tri-gen/plans/implement"
  control_dir="$source_dir/attempt-1"
  mkdir -p "$control_dir"
  source_plan="$source_dir/source.plan.md"
  control_plan="$control_dir/control.plan.md"

  cat >"$source_plan" <<'EOF'
---
name: generated-routing
overview: Generated workflow-plan control advances without mutating source
runtime: cursor
model: stage-baseline-model
sessionStrategy: fresh
todos:
  - id: baseline
    content: Unpinned TODO uses staged baseline model.
    verification: true
    status: pending
  - id: model-only
    model: gen-todo-model
    content: Model-only TODO inherits baseline runtime.
    verification: true
    status: pending
  - id: runtime-only
    runtime: claude
    content: Runtime-only TODO uses switched runtime saved model.
    verification: true
    status: pending
  - id: paired
    runtime: claude
    model: gen-paired-model
    content: Paired runtime and model TODO.
    verification: true
    status: pending
  - id: restore
    content: Unpinned TODO restores staged baseline runtime and model.
    verification: true
    status: pending
---
EOF
  cp "$source_plan" "$control_plan"
  chmod a-w "$source_plan"
  before_sha="$(shasum -a 256 "$source_plan" | awk '{print $1}')"

  run tri_run_plan \
    ".ralph-workspace/workflow-runs/tri-gen/plans/implement/attempt-1/control.plan.md" \
    RALPH_MODEL_SCOPE=staged \
    PLAN_STAGE_MODEL=stage-baseline-model \
    --runtime cursor
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&2
  fi
  [ "$status" -eq 0 ]

  after_sha="$(shasum -a 256 "$source_plan" | awk '{print $1}')"
  [ "$after_sha" = "$before_sha" ]
  [ "$(grep -c 'status: pending' "$source_plan" || true)" -eq 5 ]
  [ "$(grep -c 'status: completed' "$control_plan")" -eq 5 ]

  local cursor_lines=() claude_lines=()
  while IFS= read -r line; do
    cursor_lines+=("$line")
  done < <(tri_record_lines "$TRI_CURSOR_LOG")
  while IFS= read -r line; do
    claude_lines+=("$line")
  done < <(tri_record_lines "$TRI_CLAUDE_LOG")

  [ "${#cursor_lines[@]}" -eq 3 ]
  [ "${#claude_lines[@]}" -eq 2 ]

  tri_assert_line "${cursor_lines[0]}" cursor stage-baseline-model
  tri_assert_line "${cursor_lines[1]}" cursor gen-todo-model
  tri_assert_line "${claude_lines[0]}" claude claude-saved-model
  tri_assert_line "${claude_lines[1]}" claude gen-paired-model
  tri_assert_line "${cursor_lines[2]}" cursor stage-baseline-model
}
