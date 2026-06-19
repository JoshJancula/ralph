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
      "plan": "alpha.plan.md",
      "planTemplate": "alpha.template.md"
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
      "plan": "beta.plan.md",
      "planTemplate": "beta.template.md"
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

printf '%s|%s|%s|%s|%s|%s|%s\n' "\$runtime_label" "\${SESSION_ID_FILE:-}" "\$resume" "\$model" "\$prompt_has_codex" "\$prompt_has_cursor" "\$prompt_has_stage" >>"\$record_file"

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

extract_log_lines() {
  local file="$1"
  if [[ -s "$file" ]]; then
    cat "$file"
  fi
}

setup() {
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
      agent: alpha
      model: cursor-base-model
      sessionStrategy: fresh
      contextBudget: standard
    - id: beta
      runtime: cursor
      agent: alpha
      model: cursor-base-model
      sessionStrategy: fresh
      contextBudget: standard
todos:
  - id: first
    stage: alpha
    runtime: codex
    agent: alpha
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
    "$4" --runtime cursor --plan PLAN-codex.md --agent alpha --non-interactive
  ' _ "$workspace" "$bin_dir" "$session_home" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]

  codex_lines=()
  while IFS= read -r line; do
    codex_lines+=("$line")
  done < <(extract_log_lines "$codex_log_codex")
  [ "${#codex_lines[@]}" -ge 1 ]

  codex_last_index=$(( ${#codex_lines[@]} - 1 ))
  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx <<< "${codex_lines[$codex_last_index]}"
  [ "$runtime" = "codex" ]
  [[ "$session_file" == *"/session-id.codex.txt" ]]
  [ "$resume" = "" ]
  [ "$model" = "codex-override-model" ]
  [ "$codex_rule" = "1" ]
  [ "$cursor_rule" = "0" ]
  [ "$stage_ctx" = "0" ]

  plan_cursor="$workspace/PLAN-cursor.md"
  cat >"$plan_cursor" <<'EOF'
---
execution: orchestration
pipeline:
  stages:
    - id: beta
      runtime: cursor
      agent: alpha
      model: cursor-base-model
      sessionStrategy: fresh
      contextBudget: standard
todos:
  - id: second
    stage: beta
    runtime: cursor
    agent: alpha
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
    "$4" --runtime cursor --plan PLAN-cursor.md --agent alpha --non-interactive
  ' _ "$workspace" "$bin_dir" "$session_home" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]

  cursor_lines=()
  while IFS= read -r line; do
    cursor_lines+=("$line")
  done < <(extract_log_lines "$cursor_log_cursor")
  [ "${#cursor_lines[@]}" -ge 1 ]

  cursor_last_index=$(( ${#cursor_lines[@]} - 1 ))
  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx <<< "${cursor_lines[$cursor_last_index]}"
  [ "$runtime" = "cursor" ]
  [[ "$session_file" == *"/session-id.cursor.txt" ]]
  [ "$resume" = "" ]
  [ "$model" = "cursor-base-model" ]
  [ "$codex_rule" = "0" ]
  [ "$cursor_rule" = "1" ]
  [ "$stage_ctx" = "0" ]

  rm -rf "$workspace"
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
      agent: alpha
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
    "$4" --runtime cursor --plan PLAN.md --agent alpha --non-interactive
  ' _ "$workspace" "$bin_dir" "$session_home" "$RUN_PLAN_SH" "$registry_file"

  [ "$status" -eq 0 ]

  cursor_lines=()
  while IFS= read -r line; do
    cursor_lines+=("$line")
  done < <(extract_log_lines "$cursor_log")
  [ "${#cursor_lines[@]}" -eq 2 ]

  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx <<< "${cursor_lines[0]}"
  [ "$runtime" = "cursor" ]
  [[ "$session_file" == *"/session-id.cursor.txt" ]]
  [[ "$resume" == "--resume:cursor-session-1" ]]
  [ "$model" = "cursor-base-model" ]
  [ "$stage_ctx" = "0" ]

  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx <<< "${cursor_lines[1]}"
  [ "$runtime" = "cursor" ]
  [[ "$session_file" == *"/session-id.cursor.txt" ]]
  [ "$resume" = "" ]
  [ "$model" = "cursor-base-model" ]
  [ "$stage_ctx" = "0" ]

  rm -rf "$workspace"
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
      agent: alpha
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
    "$6" --runtime cursor --plan PLAN.md --agent alpha --non-interactive
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

  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx <<< "${cursor_lines[0]}"
  [ "$runtime" = "cursor" ]
  [[ "$session_file" == *"/session-id.cursor.txt" ]]
  [[ "${context_lines[0]}" == *"context_budget=lean"* ]]

  IFS='|' read -r runtime session_file resume model codex_rule cursor_rule stage_ctx <<< "${cursor_lines[1]}"
  [ "$runtime" = "cursor" ]
  [[ "$session_file" == *"/session-id.cursor.txt" ]]
  [[ "${context_lines[1]}" == *"context_budget=standard"* ]]

  rm -rf "$workspace"
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

  rm -rf "$workspace"
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

  rm -rf "$workspace"
}
