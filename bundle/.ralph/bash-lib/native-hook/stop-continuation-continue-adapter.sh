#!/usr/bin/env bash
# Shared Antigravity Stop hook serialization: neutral core -> decision:continue + reason.

ralph_bg_stop_continue_adapter_run_core() {
  local core_script="${1:-}"
  local hook_input="${2:-}"
  [[ -n "$core_script" && -f "$core_script" ]] || return 1
  # shellcheck source=/dev/null
  source "$core_script"
  ralph_bg_stop_hook_main "$hook_input"
}

ralph_bg_stop_continue_adapter_build_reason() {
  local neutral_json="${1:-}"
  # Not "${neutral_json:-{}}" at the heredoc below: bash closes that expansion
  # one brace early, so a populated payload arrives with a stray trailing "}"
  # and jq rejects the whole record.
  local _neutral_json_safe="$neutral_json"
  [[ -n "$_neutral_json_safe" ]] || _neutral_json_safe='{}'
  jq -r '
    def line($label; $value):
      if ($value | type) == "null" or ($value | tostring) == "" then empty
      else "\($label): \($value)\n" end;
    .continuation as $c |
    "Background job finished. Continue this TODO from the result below; do not redo it from scratch.\n\n" +
    line("Job"; $c.jobId) +
    line("Command"; $c.commandSummary) +
    line("Status"; $c.status) +
    (if ($c.exitCode | type) == "number" then line("Exit code"; ($c.exitCode | tostring)) else "" end) +
    line("Elapsed"; (if ($c.elapsedSeconds | type) == "number" then "\($c.elapsedSeconds)s" else null end)) +
    (if ($c.resultId | type) == "string" and ($c.resultId | length) > 0
      then line("Result id"; $c.resultId) else "" end) +
    (if ($c.preview | type) == "string" and ($c.preview | length) > 0
      then "\nPreview:\n\($c.preview)\n" else "" end)
  ' <<<"$_neutral_json_safe"
}

ralph_bg_stop_continue_adapter_emit_continue() {
  local neutral_json="${1:-}"
  local reason
  reason="$(ralph_bg_stop_continue_adapter_build_reason "$neutral_json")"
  jq -nc --arg reason "$reason" '{decision:"continue",reason:$reason}'
}

ralph_bg_stop_continue_adapter_main() {
  local core_script hook_input neutral decision
  core_script="${RALPH_BG_STOP_CORE_SCRIPT:-}"
  hook_input="$(cat)" || hook_input="{}"

  if [[ -z "$core_script" || ! -f "$core_script" ]]; then
    exit 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    exit 0
  fi

  neutral="$(ralph_bg_stop_continue_adapter_run_core "$core_script" "$hook_input")" || exit 0
  [[ -n "$neutral" ]] || exit 0

  decision="$(jq -r '.decision // empty' <<<"$neutral" 2>/dev/null || true)"
  if [[ "$decision" == "continue" ]]; then
    ralph_bg_stop_continue_adapter_emit_continue "$neutral"
  fi
  exit 0
}
