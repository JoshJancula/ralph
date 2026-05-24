#!/usr/bin/env bash
#
# Safe inlining of rule file contents into agent context (sourced by agent-config-tool.sh).
#
# Public interface:
#   inline_rule_file -- print file body or placeholder; blocks .env* and caps size.

MAX_RULE_INLINE_BYTES=65536

inline_rule_file() {
  local workspace="$1" rel="$2"
  local agents_root="${3:-}"
  local p="$workspace/${rel#/}"
  if [[ ! -f "$p" && -n "$agents_root" ]]; then
    local runtime_root runtime_dir rel_without_runtime alt
    runtime_root="$(cd "$(dirname "$agents_root")" 2>/dev/null && pwd || true)"
    runtime_dir="$(basename "$runtime_root")"
    rel_without_runtime="${rel#"$runtime_dir"/}"
    alt="$runtime_root/${rel_without_runtime#/}"
    [[ -f "$alt" ]] && p="$alt"
  fi
  local base="${p##*/}"
  if is_env_secret_basename "$base"; then
    echo "(blocked: Ralph does not inline .env* files; use a non-secret rules path.)"
    return 0
  fi
  if [[ ! -f "$p" ]]; then
    echo "(file not found at repo path \`$rel\`; follow project conventions if path differs)"
    return 0
  fi
  local size
  size="$(wc -c < "$p" | tr -d ' ')"
  if (( size > MAX_RULE_INLINE_BYTES )); then
    dd if="$p" bs=1 count="$MAX_RULE_INLINE_BYTES" 2>/dev/null
    echo ""
    echo "[Truncated after $MAX_RULE_INLINE_BYTES bytes]"
    return 0
  fi
  sed -n '1,$p' "$p"
}
