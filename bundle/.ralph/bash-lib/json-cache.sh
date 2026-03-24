#!/usr/bin/env bash

if [[ -n "${RALPH_JSON_CACHE_LOADED:-}" ]]; then
  return
fi
RALPH_JSON_CACHE_LOADED=1

# Public interface:
#   ralph_json_cache_ensure_dir -- sets and exports RALPH_JSON_CACHE_DIR (temp dir for cache files).
#   ralph_json_cache_file_mtime, ralph_json_cache_hash, ralph_json_cache_query -- file mtime, sha256 key, jq-backed read.

# Ensure there is a directory for memoized JSON lookups.
ralph_json_cache_ensure_dir() {
  if [[ -n "${RALPH_JSON_CACHE_DIR:-}" ]]; then
    return 0
  fi

  local tmpdir
  if tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-json-cache-XXXXXX" 2>/dev/null)"; then
    :
  elif tmpdir="$(mktemp -d -t ralph-json-cache 2>/dev/null)"; then
    :
  else
    tmpdir="$(mktemp -d "/tmp/ralph-json-cache-XXXXXX")"
  fi

  RALPH_JSON_CACHE_DIR="$tmpdir"
  # Temp directory path for JSON parse cache files; subprocesses may reuse the same dir.
  export RALPH_JSON_CACHE_DIR
}

# Read the modification time (epoch seconds) for a file using whichever stat flavor is
# available. Returns 1 if the file does not exist or the stat call fails.
ralph_json_cache_file_mtime() {
  local file="$1"
  local mtime

  if [[ ! -e "$file" ]]; then
    return 1
  fi

  if mtime="$(stat -c %Y "$file" 2>/dev/null)"; then
    printf '%s' "$mtime"
    return 0
  fi

  if mtime="$(stat -f %m "$file" 2>/dev/null)"; then
    printf '%s' "$mtime"
    return 0
  fi

  return 1
}

# Compute a stable cache key from a source path and descriptive field name.
ralph_json_cache_hash() {
  local file="$1"
  local field="$2"
  local hash

  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s\0%s' "$file" "$field" | sha256sum | cut -d ' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s\0%s' "$file" "$field" | shasum -a 256 | cut -d ' ' -f1)"
  elif command -v python3 >/dev/null 2>&1; then
    hash="$(printf '%s\0%s' "$file" "$field" | python3 - <<'PY'
import hashlib, sys
sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
PY
)"
  elif command -v python >/dev/null 2>&1; then
    hash="$(printf '%s\0%s' "$file" "$field" | python - <<'PY'
import hashlib, sys
sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
PY
)"
  elif command -v openssl >/dev/null 2>&1; then
    hash="$(printf '%s\0%s' "$file" "$field" | openssl dgst -sha256 | awk '{print $NF}')"
  else
    hash="$(printf '%s\0%s' "$file" "$field" | cksum | awk '{printf("%08x", $1)}')"
  fi

  printf '%s' "$hash"
}

# Query a JSON file through jq and memoize the result per (file, field) pair.
# Arguments:
#   $1 - path to a JSON file
#   $2 - descriptive field name used as part of the cache key
#   $3.. - jq arguments (flag + filter pairs) that would normally precede the JSON path
# Returns the jq output on stdout.
ralph_json_cache_query() {
  local json_file="$1"
  local field_key="$2"
  shift 2
  local jq_args=("$@")
  local mtime

  [[ -n "$json_file" && -n "$field_key" && "${#jq_args[@]}" -gt 0 ]] || return 1
  if [[ ! -f "$json_file" ]]; then
    return 1
  fi

  ralph_json_cache_ensure_dir
  if ! mtime="$(ralph_json_cache_file_mtime "$json_file")"; then
    return 1
  fi

  local cache_key
  cache_key="$(ralph_json_cache_hash "$json_file" "$field_key")"
  local cache_value="$RALPH_JSON_CACHE_DIR/${cache_key}.value"
  local cache_mtime="$RALPH_JSON_CACHE_DIR/${cache_key}.mtime"

  if [[ -f "$cache_value" && -f "$cache_mtime" ]]; then
    if [[ "$(<"$cache_mtime")" == "$mtime" ]]; then
      cat "$cache_value"
      return 0
    fi
  fi

  local output
  if ! output="$(jq "${jq_args[@]}" "$json_file")"; then
    return 1
  fi

  printf '%s' "$mtime" > "$cache_mtime"
  printf '%s' "$output" > "$cache_value"
  printf '%s' "$output"
}
