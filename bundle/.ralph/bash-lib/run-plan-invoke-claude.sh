#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_CLAUDE_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_CLAUDE_LOADED=1

# Public interface:
#   run_plan_invoke_claude_session_resume_args / run_plan_invoke_claude_bare_resume_args -- build argv fragments.
#   run_plan_invoke_claude_bare_resume_warn -- stderr warning when bare resume is not allowed.
#   ralph_run_plan_invoke_claude -- run Claude headless with model, tools, resume; exports log/session paths for demux.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-plan-invoke-common.sh"

run_plan_invoke_claude_session_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--resume \"\${RALPH_RUN_PLAN_RESUME_SESSION_ID}\")"
}

run_plan_invoke_claude_bare_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--resume)"
}

run_plan_invoke_claude_bare_resume_warn() {
  echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; omitting bare --resume." >&2
}

ralph_run_plan_invoke_claude() {
  # Paths and flags the Python demux / tee pipeline expects in the environment.
  export OUTPUT_LOG EXIT_CODE_FILE SESSION_ID_FILE

  local cli="${CLAUDE_PLAN_CLI:-}"

  if [[ -z "$cli" ]] && command -v claude &>/dev/null; then
    cli="claude"
  fi

  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    echo "Error: Claude CLI not found (set CLAUDE_PLAN_CLI or install claude)." >&2
    return 1
  fi

  local -a args=(-p)
  run_plan_invoke_common_add_model_flag args --model

  if [[ "${RALPH_CLAUDE_EXCLUDE_DYNAMIC_SYSTEM_PROMPT_SECTIONS:-1}" == "1" ]]; then
    args+=(--exclude-dynamic-system-prompt-sections)
  fi

  local budget=""
  if [[ -n "${RALPH_CLAUDE_MAX_BUDGET_USD:-}" ]]; then
    budget="$RALPH_CLAUDE_MAX_BUDGET_USD"
  elif [[ -n "${RALPH_AGENT_MAX_BUDGET:-}" ]]; then
    budget="$RALPH_AGENT_MAX_BUDGET"
  else
    case "${PREBUILT_AGENT:-}" in
      research)     budget="0.50" ;;
      code-review)  budget="1.00" ;;
      security)     budget="1.00" ;;
      architect)    budget="2.00" ;;
      qa)           budget="2.00" ;;
      implementation) budget="5.00" ;;
      *)            budget="3.00" ;;
    esac
  fi
  if [[ -n "$budget" ]]; then
    args+=(--max-budget-usd "$budget")
  fi

  local tools_use
  if [[ "${CLAUDE_PLAN_NO_ALLOWED_TOOLS:-0}" == "1" ]]; then
    tools_use=""
  elif [[ "${CLAUDE_PLAN_ALLOWED_TOOLS+set}" == "set" ]]; then
    tools_use="$CLAUDE_PLAN_ALLOWED_TOOLS"
  elif [[ -n "${CLAUDE_TOOLS_FROM_AGENT:-}" ]]; then
    tools_use="$CLAUDE_TOOLS_FROM_AGENT"
  else
    tools_use="Bash,Read,Edit,Write"
  fi

  if [[ -n "$tools_use" ]]; then
    args+=(--allowedTools "$tools_use")
  fi

  run_plan_invoke_common_add_resume_args \
    args \
    run_plan_invoke_claude_session_resume_args \
    run_plan_invoke_claude_bare_resume_args \
    run_plan_invoke_claude_bare_resume_warn
  run_plan_invoke_common_add_cli_resume_flags args --verbose --output-format stream-json

  # Use --system-prompt with the stable agent context for prompt caching when available.
  # The dynamic user turn (PROMPT) excludes the agent context in this case (set by run-plan-core.sh).
  if [[ -n "${PROMPT_STATIC:-}" ]]; then
    args+=(--system-prompt "$PROMPT_STATIC")
  fi

  #region agent log
  if [[ -d "/Users/joshuajancula/Documents/projects/ralph/.cursor" ]]; then
    _dbg_ts=$(( $(date +%s) * 1000 ))
    _dbg_has_resume_flag=0
    _dbg_has_system_prompt_flag=0
    _dbg_has_exclude_dynamic_sections_flag=0
    local _dbg_arg=""
    for _dbg_arg in "${args[@]}"; do
      [[ "$_dbg_arg" == "--resume" ]] && _dbg_has_resume_flag=1
      [[ "$_dbg_arg" == "--system-prompt" ]] && _dbg_has_system_prompt_flag=1
      [[ "$_dbg_arg" == "--exclude-dynamic-system-prompt-sections" ]] && _dbg_has_exclude_dynamic_sections_flag=1
    done
    printf '%s\n' "{\"sessionId\":\"91b133\",\"id\":\"log_${_dbg_ts}_claude_args_$$\",\"timestamp\":${_dbg_ts},\"location\":\"bundle/.ralph/bash-lib/run-plan-invoke-claude.sh:ralph_run_plan_invoke_claude\",\"message\":\"claude invoke args prepared\",\"data\":{\"has_resume_flag\":${_dbg_has_resume_flag},\"has_system_prompt_flag\":${_dbg_has_system_prompt_flag},\"has_exclude_dynamic_sections_flag\":${_dbg_has_exclude_dynamic_sections_flag},\"prompt_len\":${#PROMPT},\"prompt_static_len\":${#PROMPT_STATIC},\"context_budget\":\"${RALPH_PLAN_CONTEXT_BUDGET:-standard}\",\"runtime\":\"claude\"},\"runId\":\"initial\",\"hypothesisId\":\"H4\"}" >> "/Users/joshuajancula/Documents/projects/ralph/.cursor/debug-91b133.log" || true
  fi
  #endregion agent log

  run_plan_invoke_claude_cli() {
    printf '%s' "$PROMPT" | "$cli" "${args[@]}"
  }

  run_plan_invoke_common_execute \
    run_plan_invoke_claude_cli \
    claude \
    "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse stream-json and update session-id.txt; running without it."
}
