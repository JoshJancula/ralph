#!/usr/bin/env bash
# Batch-only exploration ops for ralph_proxy_batch.
#
# ralph_proxy_read / _grep / _glob are not advertised in tools/list and are not
# callable as standalone MCP tools. Batch sets RALPH_MCP_PROXY_BATCH_DISPATCH=1
# and dispatches these implementations server-side so one MCP round-trip can
# multiplex several reads. Native Read/Grep/Glob remain the agent-facing
# exploration path outside the batch tool.

if [[ -n "${RALPH_MCP_PROXY_BATCH_OPS_LOADED:-}" ]]; then
  return 0
fi
RALPH_MCP_PROXY_BATCH_OPS_LOADED=1

# without touching the filesystem (no symlink resolution, no existence check).
# Callers must guard against '..' separately; this helper assumes the input has
# already passed the parent-traversal check. Used to tell "path does not exist
# yet but would be inside the workspace" apart from "path escapes the workspace".
ralph_mcp_proxy_lexical_path() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || return 1
  if [[ "$raw" == "~" ]]; then
    raw="$HOME"
  elif [[ "$raw" == ~/* ]]; then
    raw="$HOME/${raw#~/}"
  fi
  local seg result=""
  local IFS=/
  for seg in $raw; do
    case "$seg" in
      ''|.) continue ;;
      *) result+="/$seg" ;;
    esac
  done
  printf '%s\n' "${result:-/}"
}

# Transport-safe time cap for the synchronous read-only search tools

ralph_mcp_proxy_builtin_read_only_roots() {
  printf '%s\n' "$HOME/.cursor/plans" "$HOME/.claude/plans"
}

ralph_mcp_proxy_resolve_read_only_root() {
  local root="${1:-}"
  root="$(ralph_mcp_proxy_expand_home_path "$root")"
  root="${root%/}"
  local root_real
  if root_real="$(cd "$root" 2>/dev/null && pwd -P)"; then
    printf '%s\n' "$root_real"
  elif [[ "$root" == /* ]]; then
    printf '%s\n' "$root"
  else
    return 1
  fi
}

ralph_mcp_proxy_path_under_root() {
  local path="${1:-}"
  local root="${2:-}"
  path="${path%/}"
  root="${root%/}"
  [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

ralph_mcp_proxy_path_is_allowed() {
  local user_path="${1:-}"
  local require_exists="${2:-1}"
  local canonical candidate
  local canonical_ok=0
  local -a allowed_roots=()

  ralph_mcp_proxy_add_allowed_root() {
    local resolved_root="${1:-}"
    local existing
    [[ -n "$resolved_root" ]] || return 0
    for existing in "${allowed_roots[@]}"; do
      if [[ "$existing" == "$resolved_root" ]]; then
        return 0
      fi
    done
    allowed_roots+=("$resolved_root")
  }

  if [[ -z "$user_path" ]]; then
    return 3
  fi

  if [[ "$user_path" =~ (^|/)\.\.(/|$) ]]; then
    return 1
  fi

  local mcp_workspace="${RALPH_MCP_WORKSPACE:-}"
  local agent_workspace="${RALPH_AGENT_WORKSPACE:-}"
  local plan_workspace_root="${RALPH_PLAN_WORKSPACE_ROOT:-}"

  if [[ -n "$mcp_workspace" ]]; then
    ralph_mcp_proxy_add_allowed_root "$mcp_workspace"
  fi
  if [[ -n "$agent_workspace" && "$agent_workspace" != "$mcp_workspace" ]]; then
    ralph_mcp_proxy_add_allowed_root "$agent_workspace"
  fi
  if [[ -n "$plan_workspace_root" && "$plan_workspace_root" != "$mcp_workspace" && "$plan_workspace_root" != "$agent_workspace" ]]; then
    ralph_mcp_proxy_add_allowed_root "$plan_workspace_root"
  fi

  local tmp_root tmp_root_resolved
  while IFS= read -r tmp_root; do
    if tmp_root_resolved="$(ralph_mcp_proxy_resolve_allowed_root "$tmp_root" 2>/dev/null)"; then
      ralph_mcp_proxy_add_allowed_root "$tmp_root_resolved"
    fi
  done < <(ralph_mcp_proxy_builtin_writable_roots)

  local raw_allowlist="${RALPH_MCP_ALLOWLIST:-}"
  if [[ -n "$raw_allowlist" ]]; then
    local normalized entry
    normalized="$(printf '%s\n' "$raw_allowlist" | tr ',;:' '\n')"
    while IFS= read -r entry; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      if [[ -z "${entry//[[:space:]]/}" ]]; then
        continue
      fi
      local resolved="$entry"
      if [[ "$resolved" == ~* ]]; then
        resolved="${resolved/#\~/$HOME}"
      elif [[ "$resolved" != /* && -n "$mcp_workspace" ]]; then
        resolved="$mcp_workspace/$resolved"
      fi
      if resolved="$(ralph_mcp_proxy_resolve_allowed_root "$resolved" 2>/dev/null)"; then
        ralph_mcp_proxy_add_allowed_root "$resolved"
      fi
    done <<< "$normalized"
  fi

  if [[ ${#allowed_roots[@]} -eq 0 ]]; then
    return 1
  fi

  if [[ "$user_path" == "~/"* ]]; then
    candidate="$HOME/${user_path:2}"
  elif [[ "$user_path" == "~" ]]; then
    candidate="$HOME"
  elif [[ "$user_path" == /* ]]; then
    candidate="$user_path"
  else
    candidate="${mcp_workspace:-${allowed_roots[0]}}/$user_path"
  fi

  canonical=""
  if canonical="$(ralph_mcp_proxy_canonicalize_path "$candidate" 2>/dev/null)"; then
    canonical_ok=1
  fi

  if [[ "$canonical_ok" -eq 1 ]] && ralph_mcp_proxy_path_is_hidden_debug_log "$canonical"; then
    return 4
  fi

  local is_under_allowed=0
  local is_under_read_only=0
  local resolved_path=""

  if [[ "$canonical_ok" -eq 1 ]]; then
    for root in "${allowed_roots[@]}"; do
      local root_real
      root_real="$(ralph_mcp_proxy_resolve_allowed_root "$root" 2>/dev/null)" || continue
      root_real="${root_real%/}"
      if [[ "$canonical" == "$root_real" || "$canonical" == "$root_real/"* ]]; then
        is_under_allowed=1
        resolved_path="$canonical"
        break
      fi
    done
  fi

  if [[ "$is_under_allowed" -eq 0 ]]; then
    local check_path="${canonical:-$candidate}"
    local ro_raw ro_root
    while IFS= read -r ro_raw; do
      ro_root="$(ralph_mcp_proxy_resolve_read_only_root "$ro_raw")" || continue
      if ralph_mcp_proxy_path_under_root "$check_path" "$ro_root"; then
        is_under_read_only=1
        resolved_path="$check_path"
        break
      fi
    done < <(ralph_mcp_proxy_builtin_read_only_roots)
  fi

  if [[ "$is_under_allowed" -eq 0 && "$is_under_read_only" -eq 0 ]]; then
    if [[ -n "${RALPH_MCP_PROXY_CURRENT_TOOL:-}" && -n "${RALPH_MCP_PROXY_CURRENT_ARGS_JSON:-}" ]]; then
      if declare -F ralph_mcp_proxy_scoped_approval_allows >/dev/null 2>&1; then
        if ralph_mcp_proxy_scoped_approval_allows "$RALPH_MCP_PROXY_CURRENT_TOOL" "boundary" "$RALPH_MCP_PROXY_CURRENT_ARGS_JSON"; then
          resolved_path="${canonical:-$candidate}"
          if [[ "$require_exists" == "1" && ! -e "$resolved_path" ]]; then
            return 2
          fi
          printf '%s\n' "$resolved_path"
          return 0
        fi
      fi
    fi
    # Canonicalization can fail for a path whose parent directory does not exist
    # (e.g. a relative path with a wrong prefix). Such a path is a mistake, not a
    # boundary escape. If the lexical (filesystem-free) form would still fall
    # under an allowed root, report "does not exist" (2) instead of "outside the
    # workspace" (1) so callers can return a recoverable error rather than a
    # fatal violation that kills the server.
    if [[ "$canonical_ok" -eq 0 ]]; then
      local lexical
      lexical="$(ralph_mcp_proxy_lexical_path "$candidate" 2>/dev/null || true)"
      if [[ -n "$lexical" ]]; then
        local root root_real root_lex
        for root in "${allowed_roots[@]}"; do
          root_real="$(ralph_mcp_proxy_resolve_allowed_root "$root" 2>/dev/null)" || root_real=""
          root_real="${root_real%/}"
          root_lex="$(ralph_mcp_proxy_lexical_path "$root" 2>/dev/null || true)"
          root_lex="${root_lex%/}"
          if [[ -n "$root_real" && ( "$lexical" == "$root_real" || "$lexical" == "$root_real/"* ) ]]; then
            return 2
          fi
          if [[ -n "$root_lex" && ( "$lexical" == "$root_lex" || "$lexical" == "$root_lex/"* ) ]]; then
            return 2
          fi
        done
      fi
    fi
    return 1
  fi

  if [[ "$require_exists" == "1" && ! -e "$resolved_path" ]]; then
    return 2
  fi

  printf '%s\n' "$resolved_path"
}

# ---------------------------------------------------------------------------
# Slim batch-internal exploration tools (no standalone catalog entries).
# ---------------------------------------------------------------------------

ralph_mcp_proxy_batch_ops_dispatch_allowed() {
  [[ "${RALPH_MCP_PROXY_BATCH_DISPATCH:-0}" == "1" ]]
}

ralph_mcp_proxy_owned_tool_read() {
  local workspace="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local rel_path offset limit max_bytes max_lines
  local resolved byte_count=0 line_count=0 output="" truncated=0
  local applied_limit=0 limit_policy_cap=0
  local path_check_result=0

  rel_path="$(jq -r '.path // empty' <<< "$args_json")"
  offset="$(jq -r '.offset // 1' <<< "$args_json")"
  limit="$(jq -r '.limit // empty' <<< "$args_json")"
  max_bytes="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_READ_BYTES:-65536}"
  max_lines="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_READ_LINES:-500}"

  if [[ -z "$rel_path" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_read requires path"
    return 0
  fi

  resolved="$(ralph_mcp_proxy_path_is_allowed "$rel_path" 0)" || path_check_result=$?

  if [[ "$path_check_result" -eq 3 ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_read requires path"
    return 0
  fi
  if [[ "$path_check_result" -eq 4 ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_read: path is hidden debug output"
    return 0
  fi
  if [[ "$path_check_result" -eq 1 ]]; then
    local candidate resolved_display
    candidate="$rel_path"
    if [[ "$candidate" != /* && -n "${RALPH_MCP_WORKSPACE:-}" ]]; then
      candidate="$RALPH_MCP_WORKSPACE/$candidate"
    fi
    resolved_display="$(ralph_mcp_proxy_canonicalize_path "$candidate" 2>/dev/null || printf '%s' "$candidate")"
    ralph_mcp_proxy_signal_fatal_violation \
      "ralph_proxy_read" \
      "ralph_proxy_read: path is outside the workspace" \
      "path=$rel_path"
    ralph_mcp_proxy_tool_error_json \
      "Plan ${RALPH_CURRENT_PLAN_PATH:-} Todo line ${RALPH_CURRENT_TODO_LINE:-}; Permission requested: external_directory (${resolved_display})"
    return 0
  fi
  if [[ "$path_check_result" -eq 2 ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_read: path does not exist"
    return 0
  fi
  if [[ -z "$resolved" || ! -e "$resolved" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_read: path does not exist"
    return 0
  fi
  if [[ ! -f "$resolved" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_read: not a regular file"
    return 0
  fi

  if [[ ! "$offset" =~ ^[0-9]+$ ]] || [[ "$offset" -lt 1 ]]; then
    offset=1
  fi
  if [[ -n "$limit" && "$limit" =~ ^[0-9]+$ ]] && [[ "$limit" -gt 0 ]]; then
    applied_limit="$limit"
    if [[ "$limit" -gt "$max_lines" ]]; then
      applied_limit="$max_lines"
      limit_policy_cap=1
    fi
  else
    applied_limit="$max_lines"
    limit_policy_cap=1
  fi

  local stored_line_end=0 filling_window=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_count=$((line_count + 1))
    if [[ "$line_count" -lt "$offset" ]]; then
      continue
    fi
    if [[ "$filling_window" -eq 0 ]]; then
      continue
    fi
    local window=$((line_count - offset + 1))
    if [[ "$window" -gt "$applied_limit" ]]; then
      if [[ "$limit_policy_cap" -eq 1 ]]; then
        truncated=1
      fi
      filling_window=0
      continue
    fi
    local line_bytes=${#line}
    if [[ $((byte_count + line_bytes + 1)) -gt "$max_bytes" ]]; then
      truncated=1
      filling_window=0
      continue
    fi
    output+="$line"$'\n'
    byte_count=$((byte_count + line_bytes + 1))
    stored_line_end=$line_count
  done <"$resolved"

  if [[ "$stored_line_end" -le 0 ]]; then
    if [[ "$offset" -gt 0 ]]; then
      stored_line_end=$((offset - 1))
    else
      stored_line_end=0
    fi
  fi

  local metadata_json
  metadata_json="$(
    jq -nc \
      --argjson lineStart "$offset" \
      --argjson lineEnd "$stored_line_end" \
      --argjson lineLimit "$applied_limit" \
      --argjson lineCount "$line_count" \
      --argjson byteCount "$byte_count" \
      --arg policyLimited "$limit_policy_cap" \
      '{
        storageLayout: "window",
        window: {
          lineStart: $lineStart,
          lineEnd: $lineEnd,
          lineLimit: $lineLimit,
          lineCount: $lineCount,
          byteCount: $byteCount,
          policyLimited: ($policyLimited == 1)
        }
      }'
  )"
  ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "ralph_proxy_read" \
    "$output" \
    "$truncated" \
    "" \
    "" \
    "" \
    "" \
    "$metadata_json"
}

ralph_mcp_proxy_owned_tool_grep() {
  local workspace="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local pattern rel_path glob_filter head_limit max_matches search_path
  local full_text preview_text match_count return_limit truncated=0
  local path_check_result=0 tmp_out

  pattern="$(jq -r '.pattern // empty' <<< "$args_json")"
  rel_path="$(jq -r '.path // "."' <<< "$args_json")"
  glob_filter="$(jq -r '.glob // empty' <<< "$args_json")"
  head_limit="$(jq -r '.head_limit // empty' <<< "$args_json")"
  max_matches="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_GREP_MATCHES:-100}"

  if [[ -z "$pattern" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_grep requires pattern"
    return 0
  fi
  if [[ "$pattern" == *$'\n'* ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_grep: multiline patterns are not supported"
    return 0
  fi

  if [[ "$rel_path" == "." ]]; then
    if ! search_path="$(ralph_mcp_proxy_workspace_realpath "$workspace")"; then
      ralph_mcp_proxy_signal_fatal_violation \
        "ralph_proxy_grep" \
        "ralph_proxy_grep: workspace not available" \
        "workspace=$workspace"
      ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_grep workspace denied}"
      return 0
    fi
  else
    search_path="$(ralph_mcp_proxy_path_is_allowed "$rel_path" 0)" || path_check_result=$?
    if [[ "$path_check_result" -eq 1 ]]; then
      ralph_mcp_proxy_signal_fatal_violation \
        "ralph_proxy_grep" \
        "ralph_proxy_grep: path is outside the workspace" \
        "path=$rel_path"
      ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_grep path denied}"
      return 0
    fi
    if [[ "$path_check_result" -eq 2 || "$path_check_result" -eq 3 || -z "$search_path" || ! -e "$search_path" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_grep: path does not exist"
      return 0
    fi
    if [[ "$path_check_result" -eq 4 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_grep: path is hidden debug output"
      return 0
    fi
  fi

  return_limit="$max_matches"
  if [[ -n "$head_limit" && "$head_limit" =~ ^[0-9]+$ && "$head_limit" -lt "$return_limit" ]]; then
    return_limit="$head_limit"
  fi

  tmp_out="$(mktemp)"
  if command -v rg >/dev/null 2>&1; then
    local -a rg_args=(--line-number --no-heading --color=never --max-count "$return_limit")
    if [[ -n "$glob_filter" ]]; then
      rg_args+=(--glob "$glob_filter")
    fi
    rg "${rg_args[@]}" -- "$pattern" "$search_path" >"$tmp_out" 2>/dev/null || true
  elif [[ -f "$search_path" ]]; then
    grep -n -E -- "$pattern" "$search_path" >"$tmp_out" 2>/dev/null || true
  else
    grep -R -n -E --include="${glob_filter:-*}" -- "$pattern" "$search_path" >"$tmp_out" 2>/dev/null || true
  fi

  full_text="$(<"$tmp_out")"
  rm -f "$tmp_out"
  match_count="$(ralph_mcp_proxy_owned_tool_grep_count_lines "$full_text")"
  preview_text="$full_text"
  if [[ "$match_count" -gt "$return_limit" ]]; then
    truncated=1
    preview_text="$(ralph_mcp_proxy_owned_tool_grep_head_lines "$full_text" "$return_limit")"
  fi

  ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "ralph_proxy_grep" \
    "$preview_text" \
    "$truncated"
}

ralph_mcp_proxy_owned_tool_glob() {
  local workspace="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local glob_pattern target_dir search_root path_check_result=0
  local full_text preview_text result_count return_limit truncated=0
  local max_results="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_GLOB_RESULTS:-100}"

  glob_pattern="$(jq -r '.glob_pattern // empty' <<< "$args_json")"
  target_dir="$(jq -r '.target_directory // "."' <<< "$args_json")"

  if [[ -z "$glob_pattern" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_glob requires glob_pattern"
    return 0
  fi
  if [[ "$glob_pattern" == /* ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_glob: absolute glob patterns are not allowed"
    return 0
  fi

  if [[ "$target_dir" == "." ]]; then
    if ! search_root="$(ralph_mcp_proxy_workspace_realpath "$workspace")"; then
      ralph_mcp_proxy_signal_fatal_violation \
        "ralph_proxy_glob" \
        "ralph_proxy_glob: workspace not available" \
        "workspace=$workspace"
      ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_glob workspace denied}"
      return 0
    fi
  else
    search_root="$(ralph_mcp_proxy_path_is_allowed "$target_dir" 0)" || path_check_result=$?
    if [[ "$path_check_result" -eq 1 ]]; then
      ralph_mcp_proxy_signal_fatal_violation \
        "ralph_proxy_glob" \
        "ralph_proxy_glob: target_directory is outside the workspace" \
        "target_directory=$target_dir"
      ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_glob target denied}"
      return 0
    fi
    if [[ "$path_check_result" -eq 2 || "$path_check_result" -eq 3 || -z "$search_root" || ! -e "$search_root" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_glob: target_directory does not exist"
      return 0
    fi
    if [[ ! -d "$search_root" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_glob: target_directory is not a directory"
      return 0
    fi
  fi

  return_limit="$max_results"
  full_text="$(
    (
      cd "$search_root" || exit 0
      # shellcheck disable=SC2086
      compgen -G "$glob_pattern" 2>/dev/null || true
      find . -type f \( -name "$glob_pattern" -o -path "./$glob_pattern" \) 2>/dev/null \
        | sed 's|^\./||' \
        | head -n "$((return_limit + 5))"
    ) | awk 'NF && !seen[$0]++' | head -n "$((return_limit + 1))"
  )"

  result_count="$(ralph_mcp_proxy_owned_tool_glob_count_paths "$full_text")"
  preview_text="$full_text"
  if [[ "$result_count" -gt "$return_limit" ]]; then
    truncated=1
    preview_text="$(ralph_mcp_proxy_owned_tool_grep_head_lines "$full_text" "$return_limit")"
  fi

  ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "ralph_proxy_glob" \
    "$preview_text" \
    "$truncated"
}

