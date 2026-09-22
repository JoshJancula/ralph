#!/usr/bin/env bash
# Jev redaction helpers. Source only.
#
# Public interface:
#   jev_redact_state              stdin -> stdout. PRESERVES newlines. 0 | 1
#   jev_redact_secrets_inline <text>  -> stdout single line, for logs. 0 | 1
#
# FAIL CLOSED: on failure return 1 and emit NOTHING on stdout. Callers must
# abort rather than send raw text. Pattern set mirrors
# ralph_human_recovery_redact_text but never collapses newlines in
# jev_redact_state (that helper's tr step would destroy line structure).

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_JEV_REDACT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_JEV_REDACT_PY="${_JEV_REDACT_LIB_DIR}/../../python/jev_redact.py"

# Escape a literal string for use as a sed pattern with '|' as the s/// delimiter.
_jev_redact_sed_escape_pattern() {
  printf '%s' "$1" | sed -e 's/[\\.*^$()[\]+?{|]/\\&/g' -e 's/|/\\|/g'
}

# Sed fallback for multi-line (newline-preserving) redaction. Reads stdin.
_jev_redact_via_sed() {
  local home_pat key_pat sed_script
  local -a sed_args=()

  if [ -n "${TYPESAFE_API_KEY:-}" ]; then
    key_pat="$(_jev_redact_sed_escape_pattern "$TYPESAFE_API_KEY")"
    sed_args+=(-e "s|${key_pat}|[REDACTED]|g")
  fi

  # Credential-assignment patterns (same keyword set as ralph_human_recovery_redact_text).
  sed_args+=(
    -e 's/(password|passwd|secret|token|api[_-]?key|api_key|api-key|private[_-]?key|bearer|authorization|credential)[[:space:]]*[=:][[:space:]]*[^[:space:]]+/[REDACTED]/g'
    -e 's/sk-[A-Za-z0-9_-]{8,}/[REDACTED]/g'
    -e 's/AKIA[0-9A-Z]{8,}/[REDACTED]/g'
    -e 's/ghp_[A-Za-z0-9]{20,}/[REDACTED]/g'
    -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED]/g'
    # Env-dump UPPER_SNAKE=value (catches bare declare -x dumps).
    -e 's/(^|[^A-Za-z0-9_])([A-Z][A-Z0-9_]*)=[^[:space:]]+/\1\2=[REDACTED]/g'
  )

  if [ -n "${HOME:-}" ]; then
    home_pat="$(_jev_redact_sed_escape_pattern "$HOME")"
    sed_args+=(-e "s|${home_pat}|~|g")
  fi

  sed -E "${sed_args[@]}"
}

# Run redaction on a temp input file into a temp output file. Returns 0 only when
# a backend succeeds; never writes to the caller's stdout.
_jev_redact_file() {
  local in_file="${1:-}" out_file="${2:-}"

  [ -n "$in_file" ] && [ -n "$out_file" ] || return 1

  if command -v python3 >/dev/null 2>&1 && [ -f "$_JEV_REDACT_PY" ]; then
    if python3 "$_JEV_REDACT_PY" <"$in_file" >"$out_file" 2>/dev/null; then
      return 0
    fi
  fi

  if command -v sed >/dev/null 2>&1; then
    if _jev_redact_via_sed <"$in_file" >"$out_file" 2>/dev/null; then
      return 0
    fi
  fi

  return 1
}

# jev_redact_state
# Reads stdin, writes redacted stdout, PRESERVES newlines exactly.
# Returns 0 on success, 1 on failure with empty stdout (fail closed).
jev_redact_state() {
  local in_tmp out_tmp

  in_tmp="$(mktemp "${TMPDIR:-/tmp}/jev-redact-in.XXXXXX")" || return 1
  out_tmp="$(mktemp "${TMPDIR:-/tmp}/jev-redact-out.XXXXXX")" || {
    rm -f "$in_tmp"
    return 1
  }

  # Buffer stdin so a failing python path can still fall back to sed.
  if ! cat >"$in_tmp"; then
    rm -f "$in_tmp" "$out_tmp"
    return 1
  fi

  if ! _jev_redact_file "$in_tmp" "$out_tmp"; then
    rm -f "$in_tmp" "$out_tmp"
    return 1
  fi

  # Emit only after success so failure never leaks partial or raw text.
  if ! cat "$out_tmp"; then
    rm -f "$in_tmp" "$out_tmp"
    return 1
  fi

  rm -f "$in_tmp" "$out_tmp"
  return 0
}

# jev_redact_secrets_inline <text>
# Single-line variant for log and summary lines. Collapsing newlines is correct.
# Returns 0 on success, 1 on failure with empty stdout (fail closed).
jev_redact_secrets_inline() {
  local text="${1:-}" collapsed out

  collapsed="$(printf '%s' "$text" | tr '\n\r\t' ' ' | tr -s ' ')"
  collapsed="${collapsed# }"
  collapsed="${collapsed% }"

  out="$(printf '%s' "$collapsed" | jev_redact_state)" || return 1
  # Collapse again in case redaction left only spaces from multi-token replacements.
  out="$(printf '%s' "$out" | tr '\n\r\t' ' ' | tr -s ' ')"
  out="${out# }"
  out="${out% }"
  printf '%s\n' "$out"
  return 0
}
