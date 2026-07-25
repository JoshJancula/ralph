#!/usr/bin/env bash
# Conservative read-only result cache for the Ralph MCP proxy.
#
# - ralph_proxy_read: keyed by workspace path, args, and source file mtime
# - ralph_proxy_grep / ralph_proxy_glob: short TTL entries
# - ralph_proxy_shell: only allowlisted read-only commands, short TTL
# - JSON-RPC methods listed in policy cache.rules (for example resources/read): short TTL
#
# Never caches Edit/Write, build/destructive shell, write upstream tools, or other
# side-effecting operations. Does not implement JSON-RPC id dedup or re-run/compare.

if [[ -n "${RALPH_MCP_PROXY_CACHE_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_CACHE_LOADED=1

ralph_mcp_proxy_cache_grep_ttl_sec() {
  printf '%s\n' "${RALPH_MCP_PROXY_CACHE_GREP_TTL_SEC:-5}"
}

ralph_mcp_proxy_cache_glob_ttl_sec() {
  printf '%s\n' "${RALPH_MCP_PROXY_CACHE_GLOB_TTL_SEC:-5}"
}

ralph_mcp_proxy_cache_shell_ttl_sec() {
  printf '%s\n' "${RALPH_MCP_PROXY_CACHE_SHELL_TTL_SEC:-5}"
}

ralph_mcp_proxy_cache_method_ttl_sec() {
  printf '%s\n' "${RALPH_MCP_PROXY_CACHE_METHOD_TTL_SEC:-30}"
}

ralph_mcp_proxy_cache_dir() {
  if [[ -n "${RALPH_MCP_PROXY_CACHE_DIR:-}" ]]; then
    printf '%s\n' "$RALPH_MCP_PROXY_CACHE_DIR"
    return 0
  fi
  local workspace="${WORKSPACE_ROOT:-${RALPH_MCP_WORKSPACE:-}}"
  if [[ -n "$workspace" ]]; then
    printf '%s\n' "$workspace/.ralph-workspace/cache/mcp-proxy"
    return 0
  fi
  printf '%s\n' "${TMPDIR:-/tmp}/ralph-mcp-proxy-cache"
}

ralph_mcp_proxy_cache_init() {
  local dir
  dir="$(ralph_mcp_proxy_cache_dir)"
  mkdir -p "$dir" 2>/dev/null || return 1
  return 0
}

ralph_mcp_proxy_cache_sha256() {
  local input="${1:-}"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha256sum | awk '{print $1}'
  else
    # Fallback: not cryptographically strong; sufficient for cache filenames in tests.
    printf '%s' "$input" | cksum | awk '{print $1}'
  fi
}

ralph_mcp_proxy_cache_entry_path() {
  local key_hash="${1:-}"
  printf '%s/%s.json\n' "$(ralph_mcp_proxy_cache_dir)" "$key_hash"
}

ralph_mcp_proxy_cache_never_tool_names() {
  printf '%s\n' \
    "Edit" \
    "Write" \
    "ralph_write_file" \
    "ralph_append_file" \
    "ralph_edit_file" \
    "ralph_run_plan" \
    "${RALPH_PROXY_TOOL_PREFIX:-ralph_proxy_}edit" \
    "${RALPH_PROXY_TOOL_PREFIX:-ralph_proxy_}write"
}

ralph_mcp_proxy_cache_tool_is_never_cacheable() {
  local tool_name="${1:-}"
  local entry
  if [[ -z "$tool_name" ]]; then
    return 1
  fi
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "$tool_name" == "$entry" ]]; then
      return 0
    fi
  done < <(ralph_mcp_proxy_cache_never_tool_names)
  if [[ "$tool_name" =~ ^(ralph_proxy_)?(edit|write)$ ]]; then
    return 0
  fi
  return 1
}

ralph_mcp_proxy_cache_shell_command_destructive() {
  local command="${1:-}"
  if [[ -z "$command" ]]; then
    return 0
  fi
  if [[ "$command" =~ (^|[[:space:]])(rm|mv|cp|chmod|chown|make|npm|yarn|pnpm|cargo|go[[:space:]]+build|docker|kubectl|terraform|ansible-playbook|pip[[:space:]]+install|brew[[:space:]]+install)([[:space:]]|$) ]]; then
    return 0
  fi
  if [[ "$command" =~ [\|\&\;\`\$\<\>] ]]; then
    return 0
  fi
  return 1
}

ralph_mcp_proxy_cache_rule_listed() {
  local method="${1:-}"
  local tool_name="${2:-}"
  local rules_json="${RALPH_MCP_PROXY_POLICY_CACHE_RULES_JSON:-[]}"
  if [[ "$(jq -r 'length' <<< "$rules_json")" -eq 0 ]]; then
    return 1
  fi
  if [[ -n "$method" ]] && jq -e --arg m "$method" '. | index($m) != null' <<< "$rules_json" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -n "$tool_name" ]] && jq -e --arg t "$tool_name" '. | index($t) != null' <<< "$rules_json" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

ralph_mcp_proxy_cache_owned_tool_strategy() {
  local tool_name="${1:-}"
  case "$tool_name" in
    ralph_proxy_read) printf '%s\n' "mtime" ;;
    ralph_proxy_grep) printf '%s\n' "ttl:$(ralph_mcp_proxy_cache_grep_ttl_sec)" ;;
    ralph_proxy_glob) printf '%s\n' "ttl:$(ralph_mcp_proxy_cache_glob_ttl_sec)" ;;
    ralph_proxy_shell) printf '%s\n' "ttl:$(ralph_mcp_proxy_cache_shell_ttl_sec)" ;;
    *) return 1 ;;
  esac
}

ralph_mcp_proxy_cache_strategy_for() {
  local method="${1:-}"
  local tool_name="${2:-}"
  local owned_strategy

  if [[ -n "$tool_name" ]] && owned_strategy="$(ralph_mcp_proxy_cache_owned_tool_strategy "$tool_name" 2>/dev/null)"; then
    printf '%s\n' "$owned_strategy"
    return 0
  fi
  if [[ "$method" == "resources/read" || "$method" == "tools/list" ]]; then
    printf '%s\n' "ttl:$(ralph_mcp_proxy_cache_method_ttl_sec)"
    return 0
  fi
  if [[ -n "$tool_name" ]] && ralph_mcp_proxy_cache_rule_listed "$method" "$tool_name"; then
    printf '%s\n' "ttl:$(ralph_mcp_proxy_cache_method_ttl_sec)"
    return 0
  fi
  if ralph_mcp_proxy_cache_rule_listed "$method" ""; then
    printf '%s\n' "ttl:$(ralph_mcp_proxy_cache_method_ttl_sec)"
    return 0
  fi
  return 1
}
