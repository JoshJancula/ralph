#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"
ROUTING_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-routing.sh"

write_agent_fixture() {
  local workspace="$1"
  local runtime="$2"
  local agent="$3"
  local model="$4"
  local rule_name="$5"
  local skill_name="$6"

  mkdir -p \
    "$workspace/.$runtime/agents/$agent" \
    "$workspace/.$runtime/rules" \
    "$workspace/.$runtime/skills/$skill_name"

  printf '%s\n' "${runtime} rule for ${agent}" >"$workspace/.$runtime/rules/$rule_name"
  printf '%s\n' "${runtime} skill for ${agent}" >"$workspace/.$runtime/skills/$skill_name/SKILL.md"

  cat >"$workspace/.$runtime/agents/$agent/config.json" <<EOF
{
  "name": "$agent",
  "model": "$model",
  "description": "$runtime agent for routing tests",
  "rules": [
    ".${runtime}/rules/$rule_name"
  ],
  "skills": [
    ".${runtime}/skills/$skill_name/SKILL.md"
  ],
  "output_artifacts": [
    {
      "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$agent.md",
      "required": true
    }
  ]
}
EOF
}

write_orch_fixture() {
  local orch_file="$1"
  cat >"$orch_file" <<'EOF'
{
  "stages": [
    {
      "id": "alpha",
      "inputArtifacts": [],
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/alpha.md",
          "required": true
        }
      ],
      "plan": "alpha.plan.md"
    },
    {
      "id": "beta",
      "inputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/alpha.md",
          "required": true
        }
      ],
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/beta.md",
          "required": true
        }
      ],
      "plan": "beta.plan.md"
    }
  ]
}
EOF
}

write_stub_cli() {
  local bin_dir="$1"
  local exe_name="$2"
  local runtime_label="$3"
  local record_file="$4"
  local plan_file="$5"

  cat >"$bin_dir/$exe_name" <<EOF
#!/usr/bin/env bash
set -euo pipefail

runtime_label="$runtime_label"
record_file="$record_file"
plan_file="$plan_file"

# The real Codex CLI advertises exec --config; Ralph probes for it before it
# will enforce nativeSubagents=off.
if [[ "\${1:-}" == "exec" && "\${2:-}" == "--help" ]]; then
  printf '%s\n' "Usage: codex exec" "  --config <key=value>"
  exit 0
fi

prompt="\${!#}"
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
    resume)
      if [[ -n "\${2:-}" && "\${2:-}" != --* ]]; then
        resume="resume:\${2}"
        shift 2
      else
        resume="resume"
        shift
      fi
      ;;
    --last|--continue|--session-id)
      resume="\${resume:+\$resume }\$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

prompt_has_codex=0
prompt_has_cursor=0
prompt_has_stage=0
case "\$prompt" in
  *".codex/rules/"*) prompt_has_codex=1 ;;
esac
case "\$prompt" in
  *".cursor/rules/"*) prompt_has_cursor=1 ;;
esac
case "\$prompt" in
  *"- Stage ID:"*) prompt_has_stage=1 ;;
esac
prompt_has_wsi=0
prompt_wsi_before_todo=0
case "\$prompt" in
  *"WORKFLOW_STAGE_INSTRUCTIONS: START"*) prompt_has_wsi=1 ;;
esac
if [[ "\$prompt_has_wsi" -eq 1 ]]; then
  wsi_idx="\${prompt%%<!-- WORKFLOW_STAGE_INSTRUCTIONS: START -->*}"
  todo_idx="\${prompt%%Complete exactly this TODO*}"
  if [[ "\${#wsi_idx}" -lt "\${#todo_idx}" ]]; then
    prompt_wsi_before_todo=1
  fi
fi

printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "\$runtime_label" "\${SESSION_ID_FILE:-}" "\$resume" "\$model" "\$prompt_has_codex" "\$prompt_has_cursor" "\$prompt_has_stage" "\$prompt_has_wsi" "\$prompt_wsi_before_todo" >>"\$record_file"

python3 - "\$plan_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
if "status: open" in text:
    path.write_text(text.replace("status: open", "status: completed", 1))
elif "- [ ]" in text:
    path.write_text(text.replace("- [ ]", "- [x]", 1))
PY

printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: SKIPPED"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"

exit 0
EOF
  chmod +x "$bin_dir/$exe_name"
}

write_prompt_gated_stub_cli() {
  local bin_dir="$1"
  local exe_name="$2"
  local runtime_label="$3"
  local record_file="$4"
  local plan_file="$5"

  cat >"$bin_dir/$exe_name" <<EOF
#!/usr/bin/env bash
set -euo pipefail

runtime_label="$runtime_label"
record_file="$record_file"
plan_file="$plan_file"
prompt="\${!#}"
model=""

while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --model)
      model="\${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s|%s\n' "\$runtime_label" "\$model" >>"\$record_file"

if [[ "\$prompt" == *"Complete exactly this TODO"* ]]; then
  python3 - "\$plan_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
if "status: open" in text:
    path.write_text(text.replace("status: open", "status: completed", 1))
PY

  printf '%s\n' "TODO_COMPLETION: COMPLETE"
  printf '%s\n' "TODO_VERIFICATION: SKIPPED"
  printf '%s\n' "AGENT_INVOCATION_COMPLETE"
else
  printf '%s\n' "preflight"
fi

exit 0
EOF
  chmod +x "$bin_dir/$exe_name"
}

extract_log_lines() {
  local file="$1"
  if [[ -s "$file" ]]; then
    cat "$file"
  fi
}

setup() {
  bats_skip_known_ci_flakes
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -f "$ROUTING_LIB" ] || skip "routing helper missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
}

@test "routing switches runtime, model, agent context, and runtime-scoped session files" {
  local workspace bin_dir session_home plan_codex plan_cursor cursor_log_codex codex_log_codex cursor_log_cursor codex_log_cursor registry_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"

  write_agent_fixture "$workspace" cursor alpha cursor-base-model cursor-rule alpha
  write_agent_fixture "$workspace" codex alpha codex-base-model codex-rule alpha

  plan_codex="$workspace/PLAN-codex.md"
  cat >"$plan_codex" <<'EOF'
---
execution: orchestration
pipeline:
  stages:
    - id: alpha
      runtime: cursor
      model: cursor-base-model
      sessionStrategy: fresh
      contextBudget: standard
    - id: beta
      runtime: cursor
      model: cursor-base-model
      sessionStrategy: fresh
      contextBudget: standard
todos:
  - id: first
    stage: alpha
    runtime: codex
    model: codex-override-model
    status: open
    content: First routed TODO
---
EOF

  cursor_log_codex="$workspace/cursor-codex.log"
  codex_log_codex="$workspace/codex-codex.log"
  write_stub_cli "$bin_dir" cursor-agent cursor "$cursor_log_codex" "$plan_codex"
  write_stub_cli "$bin_dir" codex codex "$codex_log_codex" "$plan_codex"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export RALPH_WORKSPACES_FILE="$5"
    export CURSOR_PLAN_MODEL="cursor-base-model"
    unset CODEX_PLAN_MODEL CLAUDE_PLAN_MODEL OPENCODE_PLAN_MODEL
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS
    "$4" --runtime cursor --plan PLAN-codex.md --non-interactive
  ' _ "$workspace" "$bin_dir" "$session_home" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]

  codex_lines=()
  while IFS= read -r line; do
    codex_lines+=("$line")
  done < <(extract_log_lines "$codex_log_codex")
  [ "${#codex_lines[@]}" -ge 1 ]

  codex_last_index=$(( ${#codex_lines[@]} - 1 ))
  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx wsi_ctx wsi_before <<< "${codex_lines[$codex_last_index]}"
  [ "$runtime" = "codex" ]
  [[ "$session_file" == *"/session-id.codex.txt" ]]
  [ "$resume" = "" ]
  [ "$model" = "codex-override-model" ]
  # Native runtime configuration owns rules and skills; Ralph never inlines
  # their paths into the prompt. External Ralph roles are gone; stage
  # instructions are injected only when the orchestrator sets the env.
  [ "$codex_rule" = "0" ]
  [ "$cursor_rule" = "0" ]
  [ "$stage_ctx" = "0" ]
  [ "$wsi_ctx" = "0" ]

  plan_cursor="$workspace/PLAN-cursor.md"
  cat >"$plan_cursor" <<'EOF'
---
execution: orchestration
pipeline:
  stages:
    - id: beta
      runtime: cursor
      model: cursor-base-model
      sessionStrategy: fresh
      contextBudget: standard
todos:
  - id: second
    stage: beta
    runtime: cursor
    status: open
    content: Second routed TODO
---
EOF

  cursor_log_cursor="$workspace/cursor-cursor.log"
  codex_log_cursor="$workspace/codex-cursor.log"
  write_stub_cli "$bin_dir" cursor-agent cursor "$cursor_log_cursor" "$plan_cursor"
  write_stub_cli "$bin_dir" codex codex "$codex_log_cursor" "$plan_cursor"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export RALPH_WORKSPACES_FILE="$5"
    export CURSOR_PLAN_MODEL="cursor-base-model"
    unset CODEX_PLAN_MODEL CLAUDE_PLAN_MODEL OPENCODE_PLAN_MODEL
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS
    "$4" --runtime cursor --plan PLAN-cursor.md --non-interactive
  ' _ "$workspace" "$bin_dir" "$session_home" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]

  cursor_lines=()
  while IFS= read -r line; do
    cursor_lines+=("$line")
  done < <(extract_log_lines "$cursor_log_cursor")
  [ "${#cursor_lines[@]}" -ge 1 ]

  cursor_last_index=$(( ${#cursor_lines[@]} - 1 ))
  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx wsi_ctx wsi_before <<< "${cursor_lines[$cursor_last_index]}"
  [ "$runtime" = "cursor" ]
  [[ "$session_file" == *"/session-id.cursor.txt" ]]
  [ "$resume" = "" ]
  [ "$model" = "cursor-base-model" ]
  [ "$codex_rule" = "0" ]
  [ "$cursor_rule" = "0" ]
  [ "$stage_ctx" = "0" ]
  [ "$wsi_ctx" = "0" ]

  ralph_test_rm_workspace "$workspace"
}

@test "subagents routing resolves TODO over stage and restores baseline between TODOs" {
  local plan_file
  plan_file="$(mktemp)"
  cat >"$plan_file" <<'EOF'
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: claude
      subagents: off
    - id: implement
      runtime: codex
      subagents: off
todos:
  - id: review-1
    stage: review
    subagents: on
    content: review
    status: pending
  - id: implement-1
    stage: implement
    content: implement
    status: pending
---
EOF
  run bash -c '
    source "$1/bundle/.ralph/bash-lib/plan-todo.sh"
    source "$1/bundle/.ralph/bash-lib/run-plan/run-plan-routing.sh"
    fields="$(ralph_run_plan_routing_effective_metadata_fields "$2" review-1)"
    IFS="$(printf "\\037")" read -r _ _ _ _ _ mode _ <<< "$fields"
    [ "$mode" = on ]
    ralph_run_plan_routing_resolve_current_context() { :; }
    ralph_run_plan_routing_set_session_context() { :; }
    ralph_run_plan_log() { :; }
    RUNTIME=cursor
    RALPH_PLAN_SUBAGENTS=inherit
    ralph_run_plan_routing_capture_baseline
    ralph_run_plan_routing_apply_effective_todo_context "$2" yaml 1 review-1 review-1
    [ "$RUNTIME" = claude ]
    [ "$RALPH_PLAN_SUBAGENTS" = on ]
    ralph_run_plan_routing_apply_effective_todo_context "$2" yaml 2 implement-1 implement-1
    [ "$RUNTIME" = codex ]
    [ "$RALPH_PLAN_SUBAGENTS" = off ]
    ralph_run_plan_routing_restore_baseline
    [ "$RUNTIME" = cursor ]
    [ "$RALPH_PLAN_SUBAGENTS" = inherit ]
  ' _ "$REPO_ROOT" "$plan_file"
  [ "$status" -eq 0 ]
  rm "$plan_file"
}

@test "yaml todo routing bootstraps non-interactive runs without a global model" {
  local workspace bin_dir session_home plan_file cursor_log codex_log registry_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"

  plan_file="$workspace/PLAN.md"
  cat >"$plan_file" <<'EOF'
---
name: yaml-routing-bootstrap
todos:
  - id: first
    runtime: codex
    model: codex-override-model
    status: open
    content: First routed TODO
  - id: second
    runtime: cursor
    model: cursor-override-model
    status: open
    content: Second routed TODO
---
EOF

  cursor_log="$workspace/cursor.log"
  codex_log="$workspace/codex.log"
  write_prompt_gated_stub_cli "$bin_dir" cursor-agent cursor "$cursor_log" "$plan_file"
  write_prompt_gated_stub_cli "$bin_dir" codex codex "$codex_log" "$plan_file"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export RALPH_WORKSPACES_FILE="$5"
    unset CURSOR_PLAN_MODEL CODEX_PLAN_MODEL CLAUDE_PLAN_MODEL OPENCODE_PLAN_MODEL
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS
    "$4" --runtime cursor --plan PLAN.md --non-interactive
  ' _ "$workspace" "$bin_dir" "$session_home" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]

  codex_lines=()
  while IFS= read -r line; do
    codex_lines+=("$line")
  done < <(extract_log_lines "$codex_log")
  [ "${#codex_lines[@]}" -ge 1 ]
  IFS='|' read -r runtime model <<< "${codex_lines[$(( ${#codex_lines[@]} - 1 ))]}"
  [ "$runtime" = "codex" ]
  [ "$model" = "codex-override-model" ]

  cursor_lines=()
  while IFS= read -r line; do
    cursor_lines+=("$line")
  done < <(extract_log_lines "$cursor_log")
  [ "${#cursor_lines[@]}" -ge 1 ]
  IFS='|' read -r runtime model <<< "${cursor_lines[$(( ${#cursor_lines[@]} - 1 ))]}"
  [ "$runtime" = "cursor" ]
  [ "$model" = "cursor-override-model" ]

  run grep -c "status: completed" "$plan_file"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]

  ralph_test_rm_workspace "$workspace"
}

@test "routing sessionStrategy override changes resume behavior for one TODO only" {
  local workspace bin_dir session_home plan_file cursor_log registry_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"

  write_agent_fixture "$workspace" cursor alpha cursor-base-model cursor-rule alpha

  plan_file="$workspace/PLAN.md"
  cat >"$plan_file" <<'EOF'
---
execution: orchestration
pipeline:
  stages:
    - id: alpha
      runtime: cursor
      model: cursor-base-model
      sessionStrategy: fresh
      contextBudget: standard
todos:
  - id: first
    stage: alpha
    sessionStrategy: resume
    status: open
    content: Resume once
  - id: second
    stage: alpha
    status: open
    content: Fresh on the next TODO
---
EOF

  cursor_log="$workspace/cursor.log"
  write_stub_cli "$bin_dir" cursor-agent cursor "$cursor_log" "$plan_file"
  mkdir -p "$session_home/PLAN"
  printf '%s\n' "cursor-session-1" >"$session_home/PLAN/session-id.cursor.txt"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export RALPH_WORKSPACES_FILE="$5"
    export CURSOR_PLAN_MODEL="cursor-base-model"
    unset CODEX_PLAN_MODEL CLAUDE_PLAN_MODEL OPENCODE_PLAN_MODEL
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS
    "$4" --runtime cursor --plan PLAN.md --non-interactive
  ' _ "$workspace" "$bin_dir" "$session_home" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]

  cursor_lines=()
  while IFS= read -r line; do
    cursor_lines+=("$line")
  done < <(extract_log_lines "$cursor_log")
  [ "${#cursor_lines[@]}" -eq 2 ]

  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx wsi_ctx wsi_before <<< "${cursor_lines[0]}"
  [ "$runtime" = "cursor" ]
  [[ "$session_file" == *"/session-id.cursor.txt" ]]
  [[ "$resume" == "--resume:cursor-session-1" ]]
  [ "$model" = "cursor-base-model" ]
  [ "$stage_ctx" = "0" ]

  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx wsi_ctx wsi_before <<< "${cursor_lines[1]}"
  [ "$runtime" = "cursor" ]
  [[ "$session_file" == *"/session-id.cursor.txt" ]]
  [ "$resume" = "" ]
  [ "$model" = "cursor-base-model" ]
  [ "$stage_ctx" = "0" ]

  ralph_test_rm_workspace "$workspace"
}

@test "routing contextBudget override changes prompt context for one TODO only" {
  local workspace bin_dir session_home plan_file cursor_log orch_file plan_log registry_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"

  write_agent_fixture "$workspace" cursor alpha cursor-base-model cursor-rule alpha
  orch_file="$workspace/pipeline.orch.json"
  write_orch_fixture "$orch_file"
  plan_log="$workspace/plan.log"

  plan_file="$workspace/PLAN.md"
  cat >"$plan_file" <<'EOF'
---
execution: orchestration
pipeline:
  stages:
    - id: alpha
      runtime: cursor
      model: cursor-base-model
      sessionStrategy: fresh
      contextBudget: standard
todos:
  - id: first
    stage: alpha
    contextBudget: lean
    status: open
    content: Lean prompt for the first TODO
  - id: second
    stage: alpha
    status: open
    content: Standard prompt for the second TODO
---
EOF

  cursor_log="$workspace/cursor.log"
  write_stub_cli "$bin_dir" cursor-agent cursor "$cursor_log" "$plan_file"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export CURSOR_PLAN_LOG="$5"
    export RALPH_WORKSPACES_FILE="$7"
    export CURSOR_PLAN_MODEL="cursor-base-model"
    export RALPH_ORCH_FILE="$4"
    unset CODEX_PLAN_MODEL CLAUDE_PLAN_MODEL OPENCODE_PLAN_MODEL
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS
    "$6" --runtime cursor --plan PLAN.md --non-interactive
  ' _ "$workspace" "$bin_dir" "$session_home" "$orch_file" "$plan_log" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]

  cursor_lines=()
  while IFS= read -r line; do
    cursor_lines+=("$line")
  done < <(extract_log_lines "$cursor_log")
  [ "${#cursor_lines[@]}" -eq 2 ]

  context_lines=()
  while IFS= read -r line; do
    context_lines+=("$line")
  done < <(extract_log_lines "$plan_log" | grep -F "context footprint:")
  [ "${#context_lines[@]}" -eq 2 ]

  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx wsi_ctx wsi_before <<< "${cursor_lines[0]}"
  [ "$runtime" = "cursor" ]
  [[ "$session_file" == *"/session-id.cursor.txt" ]]
  [[ "${context_lines[0]}" == *"context_budget=lean"* ]]

  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx wsi_ctx wsi_before <<< "${cursor_lines[1]}"
  [ "$runtime" = "cursor" ]
  [[ "$session_file" == *"/session-id.cursor.txt" ]]
  [[ "${context_lines[1]}" == *"context_budget=standard"* ]]

  ralph_test_rm_workspace "$workspace"
}

@test "run-plan-routing.sh has a source guard and no set -euo pipefail" {
  [ -f "$ROUTING_LIB" ] || skip "routing helper missing"

  run grep -n 'RALPH_RUN_PLAN_ROUTING_LOADED' "$ROUTING_LIB"
  [ "$status" -eq 0 ]

  run grep -n 'set -euo pipefail' "$ROUTING_LIB"
  [ "$status" -ne 0 ]
}

@test "plan header runtime and model are used when --runtime and --model are not passed" {
  local workspace bin_dir session_home plan_file cursor_log registry_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"

  plan_file="$workspace/PLAN.md"
  cat >"$plan_file" <<'EOF'
---
name: header-defaults
runtime: cursor
model: header-model
todos:
  - id: first
    content: First task
    status: open
  - id: second
    content: Second task
    status: open
---
EOF

  cursor_log="$workspace/cursor.log"
  write_stub_cli "$bin_dir" cursor-agent cursor "$cursor_log" "$plan_file"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export RALPH_WORKSPACES_FILE="$5"
    export CURSOR_PLAN_MODEL="header-model"
    unset CODEX_PLAN_MODEL CLAUDE_PLAN_MODEL OPENCODE_PLAN_MODEL
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS
    "$4" --plan PLAN.md --non-interactive
  ' _ "$workspace" "$bin_dir" "$session_home" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]

  cursor_lines=()
  while IFS= read -r line; do
    cursor_lines+=("$line")
  done < <(extract_log_lines "$cursor_log")
  [ "${#cursor_lines[@]}" -eq 2 ]

  IFS='|' read -r runtime _session _resume model _cr _cur _stage <<< "${cursor_lines[0]}"
  [ "$runtime" = "cursor" ]
  [ "$model" = "header-model" ]

  IFS='|' read -r runtime _session _resume model _cr _cur _stage <<< "${cursor_lines[1]}"
  [ "$runtime" = "cursor" ]
  [ "$model" = "header-model" ]

  ralph_test_rm_workspace "$workspace"
}

@test "plan header model is overridden by --model flag" {
  local workspace bin_dir session_home plan_file cursor_log registry_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"

  plan_file="$workspace/PLAN.md"
  cat >"$plan_file" <<'EOF'
---
name: header-override
runtime: cursor
model: header-model
todos:
  - id: first
    content: First task
    status: open
---
EOF

  cursor_log="$workspace/cursor.log"
  write_stub_cli "$bin_dir" cursor-agent cursor "$cursor_log" "$plan_file"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export RALPH_WORKSPACES_FILE="$5"
    unset CODEX_PLAN_MODEL CLAUDE_PLAN_MODEL OPENCODE_PLAN_MODEL CURSOR_PLAN_MODEL
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS
    "$4" --runtime cursor --plan PLAN.md --model cli-model --non-interactive
  ' _ "$workspace" "$bin_dir" "$session_home" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]

  cursor_lines=()
  while IFS= read -r line; do
    cursor_lines+=("$line")
  done < <(extract_log_lines "$cursor_log")
  [ "${#cursor_lines[@]}" -eq 1 ]

  IFS='|' read -r runtime _session _resume model _cr _cur _stage <<< "${cursor_lines[0]}"
  [ "$runtime" = "cursor" ]
  [ "$model" = "cli-model" ]

  ralph_test_rm_workspace "$workspace"
}

@test "routing injects workflow stage instructions before TODO content" {
  local workspace bin_dir session_home plan_file cursor_log registry_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  registry_file="$(mktemp)"
  mkdir -p "$bin_dir" "$session_home"

  plan_file="$workspace/PLAN.md"
  cat >"$plan_file" <<'EOF'
---
name: stage-instructions-order
runtime: cursor
model: cursor-base-model
todos:
  - id: only
    content: First routed TODO
    status: open
---
EOF

  cursor_log="$workspace/cursor.log"
  write_stub_cli "$bin_dir" cursor-agent cursor "$cursor_log" "$plan_file"

  run bash -c '
    set -euo pipefail
    cd "$1"
    export PATH="$2:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$3"
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    export RALPH_WORKSPACES_FILE="$5"
    export CURSOR_PLAN_MODEL="cursor-base-model"
    export RALPH_WORKFLOW_STAGE_INSTRUCTIONS="Investigate before editing."
    unset CODEX_PLAN_MODEL CLAUDE_PLAN_MODEL OPENCODE_PLAN_MODEL
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS
    "$4" --runtime cursor --plan PLAN.md --non-interactive
  ' _ "$workspace" "$bin_dir" "$session_home" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]

  cursor_lines=()
  while IFS= read -r line; do
    cursor_lines+=("$line")
  done < <(extract_log_lines "$cursor_log")
  [ "${#cursor_lines[@]}" -ge 1 ]

  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx wsi_ctx wsi_before <<< "${cursor_lines[$(( ${#cursor_lines[@]} - 1 ))]}"
  [ "$runtime" = "cursor" ]
  [ "$wsi_ctx" = "1" ]
  [ "$wsi_before" = "1" ]

  ralph_test_rm_workspace "$workspace"
}
