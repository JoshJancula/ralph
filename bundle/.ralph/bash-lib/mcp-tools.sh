# Tool execution and parameter-validation helpers for the MCP server.

readonly MAX_TOOL_TAIL_BYTES=32768

contains_shell_metacharacters() {
  local candidate="$1"
  local pattern='[;&|<>$`"'\''(){}\[\]\\]'
  if [[ "$candidate" =~ $pattern ]]; then
    return 0
  fi
  return 1
}

ensure_safe_argument() {
  local value="$1"
  local label="$2"
  local id_present="$3"
  local id_raw="$4"
  if contains_shell_metacharacters "$value"; then
    send_error "$id_present" "$id_raw" "-32602" "$label contains shell metacharacters: $value"
    return 1
  fi
  return 0
}

# Tail a command output file safely and signal whether the text was truncated.
tail_text() {
  local file="$1"
  local limit="$2"
  local out_var="$3"
  local truncated_var="$4"
  local size
  size="$(wc -c < "$file" 2>/dev/null || echo 0)"
  local truncated="false"
  if [[ "$size" -gt "$limit" ]]; then
    truncated="true"
  fi
  local content=""
  if [[ "$size" -gt 0 ]]; then
    content="$(tail -c "$limit" "$file" 2>/dev/null || cat "$file")"
  fi
  printf -v "$out_var" "%s" "$content"
  printf -v "$truncated_var" "%s" "$truncated"
}

# Execute the provided command while capturing stdout/stderr tails for reporting.
execute_tool_command() {
  local command=("$@")
  local stdout_file stderr_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  local start_time end_time
  start_time="$(date +%s.%N)"
  set +e
  "${command[@]}" >"$stdout_file" 2>"$stderr_file"
  local exit_code=$?
  set -e
  end_time="$(date +%s.%N)"
  local duration_value
  duration_value="$(awk "BEGIN {printf \"%.3f\", $end_time - $start_time}")"
  local stdout_value stderr_value
  local stdout_trunc_value stderr_trunc_value
  tail_text "$stdout_file" "$MAX_TOOL_TAIL_BYTES" stdout_value stdout_trunc_value
  tail_text "$stderr_file" "$MAX_TOOL_TAIL_BYTES" stderr_value stderr_trunc_value
  rm -f "$stdout_file" "$stderr_file"
  EXECUTE_TOOL_COMMAND_EXIT_CODE="$exit_code"
  EXECUTE_TOOL_COMMAND_DURATION_SECONDS="$duration_value"
  EXECUTE_TOOL_COMMAND_STDOUT_TAIL="$stdout_value"
  EXECUTE_TOOL_COMMAND_STDERR_TAIL="$stderr_value"
  EXECUTE_TOOL_COMMAND_STDOUT_TRUNCATED="$stdout_trunc_value"
  EXECUTE_TOOL_COMMAND_STDERR_TRUNCATED="$stderr_trunc_value"
}
