# shellcheck shell=bash
# Pure shell-output compactors (no file I/O in the compactor layer).
# Dispatches to bundle/.ralph/python/shell-output-compact.py.

ralph_compactors_script_dir() {
  # Allow explicit override for subprocess/test contexts where BASH_SOURCE[0] may not resolve correctly
  if [[ -n "${RALPH_COMPACTORS_LIB_DIR:-}" ]]; then
    printf '%s\n' "$RALPH_COMPACTORS_LIB_DIR"
    return
  fi

  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    local link_dir
    link_dir="$(cd "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$link_dir/$src"
  done
  cd "$(dirname "$src")" && pwd
}

ralph_shell_output_compact_py() {
  local lib_dir
  lib_dir="$(ralph_compactors_script_dir)"
  printf '%s/../python/shell-output-compact.py\n' "$lib_dir"
}

# Compact command output passed as data (no filesystem reads in the compactor).
# Usage: ralph_compact_shell_output <command> <exit_status>
# Input streams: RALPH_COMPACT_STDOUT, RALPH_COMPACT_STDERR (optional, default empty).
# Prints one JSON line: stdout, stderr, compacted, stdout_compacted, stderr_compacted,
# family, status ("compacted" | "not compacted"), exit_status.
#
# Non-zero exit_status: failure-aware compaction keeps error/assertion/summary lines
# and drops repetitive noise when family rules decline (family failure_aware).
# Opt out with RALPH_COMPACT_FAILURE=0 to pass raw failure output through unchanged.
ralph_compact_shell_output() {
  local command="${1-}"
  local exit_status="${2:-0}"
  local py_script

  # Large captured streams must not remain exported while helper processes
  # start. Linux counts exported values against execve(2)'s argument/environment
  # limit, which can make even dirname or jq fail with E2BIG.
  export -n RALPH_COMPACT_STDOUT RALPH_COMPACT_STDERR 2>/dev/null || true

  if ! command -v python3 >/dev/null 2>&1; then
    jq -n \
      --rawfile command <(printf '%s' "$command") \
      --rawfile stdout <(printf '%s' "${RALPH_COMPACT_STDOUT-}") \
      --rawfile stderr <(printf '%s' "${RALPH_COMPACT_STDERR-}") \
      --argjson exit_status "$exit_status" \
      '{
        stdout: $stdout,
        stderr: $stderr,
        compacted: false,
        stdout_compacted: false,
        stderr_compacted: false,
        family: null,
        status: "not compacted",
        exit_status: $exit_status
      }'
    return $?
  fi

  py_script="$(ralph_shell_output_compact_py)"
  jq -n \
    --rawfile command <(printf '%s' "$command") \
    --rawfile stdout <(printf '%s' "${RALPH_COMPACT_STDOUT-}") \
    --rawfile stderr <(printf '%s' "${RALPH_COMPACT_STDERR-}") \
    --argjson exit_status "$exit_status" \
    '{command: $command, stdout: $stdout, stderr: $stderr, exit_status: $exit_status}' \
    | python3 "$py_script" compact
  return $?
}

# Return 0 when compaction applied, 1 when status is "not compacted".
ralph_compact_shell_output_applied() {
  local json_line="${1-}"
  [[ "$(jq -r '.status // ""' <<<"$json_line")" == "compacted" ]]
}

# UTF-8 byte count for combined stdout/stderr (telemetry; no file I/O).
ralph_compact_shell_output_byte_count() {
  local stdout="${1-}" stderr="${2-}"
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
  local combined
  combined="$(ralph_hook_telemetry_combine_streams "$stdout" "$stderr")"
  ralph_hook_telemetry_utf8_byte_count "$combined"
}

# Enrich compactor JSON with telemetry fields (command_hash, byte counts, compaction_skipped).
# Requires hook-telemetry.sh and jq. storage_path may be empty.
ralph_compact_shell_output_with_telemetry() {
  local command="${1-}" compact_json="${2-}" original_stdout="${3-}" original_stderr="${4-}"
  local storage_path="${5-}"
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

  local original_bytes compacted_bytes command_hash compaction_skipped
  local compact_stdout compact_stderr compact_combined
  local original_tokens compacted_tokens token_telemetry='{}'

  original_bytes="$(ralph_compact_shell_output_byte_count "$original_stdout" "$original_stderr")"
  command_hash="$(ralph_hook_telemetry_sha256 "$command")"
  compact_stdout="$(jq -r '.stdout // ""' <<<"$compact_json")"
  compact_stderr="$(jq -r '.stderr // ""' <<<"$compact_json")"
  compact_combined="$(ralph_hook_telemetry_combine_streams "$compact_stdout" "$compact_stderr")"
  compacted_bytes="$(ralph_hook_telemetry_utf8_byte_count "$compact_combined")"
  if ralph_compact_shell_output_applied "$compact_json"; then
    compaction_skipped="false"
  else
    compaction_skipped="true"
  fi

  if [[ -z "${RALPH_TOKEN_ESTIMATE_LOADED:-}" ]]; then
    # shellcheck source=/dev/null
    source "${lib_dir}/token-estimate.sh" 2>/dev/null || true
  fi
  if declare -F ralph_token_estimate_text >/dev/null 2>&1; then
    local original_combined
    original_combined="$(ralph_hook_telemetry_combine_streams "$original_stdout" "$original_stderr")"
    original_tokens="$(ralph_token_estimate_text "$original_combined" 2>/dev/null || true)"
    compacted_tokens="$(ralph_token_estimate_text "$compact_combined" 2>/dev/null || true)"
    if [[ "$original_tokens" =~ ^[0-9]+$ ]] && [[ "$compacted_tokens" =~ ^[0-9]+$ ]]; then
      token_telemetry="$(jq -nc \
        --argjson originalTokens "$original_tokens" \
        --argjson compactedTokens "$compacted_tokens" \
        '{originalTokens: $originalTokens, compactedTokens: $compactedTokens}')"
    fi
  fi

  jq -c \
    --arg commandHash "$command_hash" \
    --argjson originalBytes "$original_bytes" \
    --argjson compactedBytes "$compacted_bytes" \
    --arg storagePath "$storage_path" \
    --argjson compactionSkipped "$compaction_skipped" \
    --argjson tokenTelemetry "$token_telemetry" \
    '. + {
      command_hash: $commandHash,
      original_bytes: $originalBytes,
      compacted_bytes: $compactedBytes,
      storage_path: (if $storagePath == "" then null else $storagePath end),
      compaction_skipped: $compactionSkipped
    }
    | if ($tokenTelemetry | type) == "object" and ($tokenTelemetry | length) > 0 then
        . + $tokenTelemetry
      else
        .
      end' <<<"$compact_json"
}
