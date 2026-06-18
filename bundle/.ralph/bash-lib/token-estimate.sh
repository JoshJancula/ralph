#!/usr/bin/env bash
# Dependency-free token estimator (python3 stdlib when present, awk fallback).
#
# Public interface when sourced:
#   ralph_token_estimate_backend
#   ralph_token_estimate_text
#   ralph_token_estimate_file
#   ralph_token_estimate_stdin
#
# CLI: token-estimate.sh [file]   (stdin when no file)

if [[ -n "${RALPH_TOKEN_ESTIMATE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_TOKEN_ESTIMATE_LOADED=1

_TOKEN_ESTIMATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TOKEN_ESTIMATE_PY="$_TOKEN_ESTIMATE_LIB_DIR/../python/token_estimate.py"

ralph_token_estimate_backend() {
  local forced="${RALPH_TOKEN_ESTIMATE_BACKEND:-auto}"
  case "$forced" in
    python)
      if command -v python3 >/dev/null 2>&1 && [[ -f "$_TOKEN_ESTIMATE_PY" ]]; then
        printf '%s\n' "python"
        return 0
      fi
      return 1
      ;;
    awk)
      if command -v awk >/dev/null 2>&1; then
        printf '%s\n' "awk"
        return 0
      fi
      return 1
      ;;
    auto)
      if command -v python3 >/dev/null 2>&1 && [[ -f "$_TOKEN_ESTIMATE_PY" ]]; then
        printf '%s\n' "python"
        return 0
      fi
      if command -v awk >/dev/null 2>&1; then
        printf '%s\n' "awk"
        return 0
      fi
      return 1
      ;;
    *)
      printf 'ralph_token_estimate_backend: invalid RALPH_TOKEN_ESTIMATE_BACKEND=%s\n' "$forced" >&2
      return 1
      ;;
  esac
}

ralph_token_estimate_run_awk() {
  awk '
  function ralph_estimate_tokens(text,    i, c, n, total, j, word_len, w) {
    total = 0
    n = length(text)
    for (i = 1; i <= n; i++) {
      c = substr(text, i, 1)
      if (c ~ /[[:space:]]/) {
        continue
      }
      if (c ~ /[A-Za-z0-9_]/) {
        j = i + 1
        while (j <= n && substr(text, j, 1) ~ /[A-Za-z0-9_]/) {
          j++
        }
        word_len = j - i
        w = int((word_len + 3) / 4)
        if (w < 1) {
          w = 1
        }
        total += w
        i = j - 1
        continue
      }
      total += 1
    }
    return total
  }
  {
    if (NR > 1) {
      buffer = buffer "\n" $0
    } else {
      buffer = $0
    }
  }
  END {
    if (buffer == "") {
      print 0
      exit 0
    }
    print ralph_estimate_tokens(buffer)
  }'
}

ralph_token_estimate_text_python() {
  python3 "$_TOKEN_ESTIMATE_PY" <<< "$1"
}

ralph_token_estimate_text_awk() {
  printf '%s' "$1" | ralph_token_estimate_run_awk
}

ralph_token_estimate_text() {
  local text="${1-}"
  local backend

  backend="$(ralph_token_estimate_backend)" || {
    printf 'ralph_token_estimate_text: no token estimator backend available\n' >&2
    return 1
  }

  case "$backend" in
    python)
      ralph_token_estimate_text_python "$text"
      ;;
    awk)
      ralph_token_estimate_text_awk "$text"
      ;;
    *)
      printf 'ralph_token_estimate_text: unknown backend %s\n' "$backend" >&2
      return 1
      ;;
  esac
}

ralph_token_estimate_stdin() {
  local backend

  backend="$(ralph_token_estimate_backend)" || {
    printf 'ralph_token_estimate_stdin: no token estimator backend available\n' >&2
    return 1
  }

  case "$backend" in
    python)
      python3 "$_TOKEN_ESTIMATE_PY"
      ;;
    awk)
      ralph_token_estimate_run_awk
      ;;
    *)
      printf 'ralph_token_estimate_stdin: unknown backend %s\n' "$backend" >&2
      return 1
      ;;
  esac
}

ralph_token_estimate_file() {
  local path="${1:-}"
  [[ -n "$path" ]] || {
    printf 'ralph_token_estimate_file: path required\n' >&2
    return 1
  }
  [[ -f "$path" ]] || {
    printf 'ralph_token_estimate_file: not a file: %s\n' "$path" >&2
    return 1
  }

  ralph_token_estimate_stdin < "$path"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: token-estimate.sh [file]

Estimate tokens for file contents or stdin using a dependency-free heuristic.
Prefers python3 (stdlib token_estimate.py) and falls back to awk.
EOF
    exit 0
  fi

  if [[ $# -gt 0 ]]; then
    ralph_token_estimate_file "$1"
  else
    ralph_token_estimate_stdin
  fi
fi
