#!/usr/bin/env bash

MAX_RULE_INLINE_BYTES=65536

inline_rule_file() {
  local workspace="$1" rel="$2"
  local p="$workspace/${rel#/}"
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
