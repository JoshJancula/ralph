# shellcheck shell=bash
# Pure shell-command rewriter (no file I/O in the rewriter layer).
# Dispatches to bundle/.ralph/python/shell-command-rewrite.py.

ralph_command_rewriter_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    local link_dir
    link_dir="$(cd "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$link_dir/$src"
  done
  cd "$(dirname "$src")" && pwd
}

ralph_shell_command_rewrite_py() {
  local lib_dir
  lib_dir="$(ralph_command_rewriter_script_dir)"
  printf '%s/../python/shell-command-rewrite.py\n' "$lib_dir"
}

# Rewrite a shell command string (pure; no execution or filesystem access).
# Usage: ralph_rewrite_shell_command <command>
# Prints one JSON line: command, rewritten_command, rewritten, rule_id, status.
ralph_rewrite_shell_command() {
  local command="${1-}"
  local py_script payload

  if ! command -v python3 >/dev/null 2>&1; then
    jq -n \
      --arg command "$command" \
      '{
        command: $command,
        rewritten_command: $command,
        rewritten: false,
        rule_id: null,
        status: "unchanged"
      }'
    return 0
  fi

  py_script="$(ralph_shell_command_rewrite_py)"
  payload="$(jq -n --arg command "$command" '{command: $command}')"
  printf '%s\n' "$payload" | python3 "$py_script" rewrite
}

# Return 0 when a rewrite was applied, 1 when status is "unchanged".
ralph_rewrite_shell_command_applied() {
  local json_line="${1-}"
  [[ "$(jq -r '.rewritten // false' <<<"$json_line")" == "true" ]]
}

# Enrich rewriter JSON with telemetry fields (command hashes, reason, rewrite_applied).
# rewrite_applied: true when the caller replaced the command; false for suggest-only audit rows.
ralph_rewrite_shell_command_with_telemetry() {
  local rewrite_json="${1-}" rewrite_applied="${2:-true}"
  local lib_dir="${BASH_SOURCE[0]}"
  while [[ -L "$lib_dir" ]]; do
    local link_dir
    link_dir="$(cd "$(dirname "$lib_dir")" && pwd)"
    lib_dir="$(readlink "$lib_dir")"
    [[ "$lib_dir" != /* ]] && lib_dir="$link_dir/$lib_dir"
  done
  lib_dir="$(cd "$(dirname "$lib_dir")" && pwd)"
  # shellcheck source=/dev/null
  source "${lib_dir}/hook-telemetry.sh"

  local original_command rewritten_command rule_id
  local original_hash rewritten_hash applied_json

  original_command="$(jq -r '.command // ""' <<<"$rewrite_json")"
  rewritten_command="$(jq -r '.rewritten_command // ""' <<<"$rewrite_json")"
  rule_id="$(jq -r '.rule_id // empty' <<<"$rewrite_json")"
  original_hash="$(ralph_hook_telemetry_sha256 "$original_command")"
  rewritten_hash="$(ralph_hook_telemetry_sha256 "$rewritten_command")"
  if [[ "$rewrite_applied" == "1" || "$rewrite_applied" == "true" ]]; then
    applied_json="true"
  else
    applied_json="false"
  fi

  jq -c \
    --arg originalCommandHash "$original_hash" \
    --arg rewrittenCommandHash "$rewritten_hash" \
    --argjson rewriteApplied "$applied_json" \
    --arg reason "$rule_id" \
    '. + {
      original_command_hash: $originalCommandHash,
      rewritten_command_hash: $rewrittenCommandHash,
      reason: (if $reason == "" then null else $reason end),
      rewrite_applied: $rewriteApplied
    }' <<<"$rewrite_json"
}
