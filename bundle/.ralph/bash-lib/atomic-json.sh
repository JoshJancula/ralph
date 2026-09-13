#!/usr/bin/env bash
# Shared atomic JSON write helpers.
#
# ralph_fsync_path: best-effort durable flush of a single file. Prefers a real
#   per-file fsync via python3; falls back to sync(1) when present. Never fails
#   the caller. Extracted from orchestrator.sh orch_fsync_path so the graph
#   state writer and the single-stage report writer reuse one implementation
#   instead of forking a second copy.
#
# ralph_atomic_write_json: atomically write jq output to <target_path> via the
#   mktemp-in-dest-dir -> jq -> fsync -> rename sequence. All jq arguments
#   after the filter are forwarded verbatim, so callers pass the filter first
#   followed by --arg/--argjson flags exactly as they would to jq -n.
#
# Usage:
#   ralph_atomic_write_json <target_path> <jq_filter> [jq_args...]
#
# On success returns 0 and the file at <target_path> holds the jq result. On
# failure returns 1 and removes the temp file. The caller is responsible for
# mkdir -p of the destination directory before calling.
#
# These helpers are jq-required but python3-optional: ralph_fsync_path stays
# correct without python3 by falling back to sync.

ralph_fsync_path() {
  local target="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$target" <<'PY' 2>/dev/null || true
import os, sys
p = sys.argv[1]
try:
    fd = os.open(p, os.O_RDONLY)
except OSError:
    sys.exit(0)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
  elif command -v sync >/dev/null 2>&1; then
    sync 2>/dev/null || true
  fi
}

# ralph_atomic_write_json <target_path> <jq_filter> [jq_args...]
#
# Writes the result of `jq -n <jq_filter> [jq_args...]` atomically to
# <target_path>. The temp file is created in the same directory as the target
# so the rename is atomic on POSIX filesystems. fsync is applied to the temp
# file before rename and to the target directory after rename.
ralph_atomic_write_json() {
  local target_path="$1"; shift
  local jq_filter="$1"; shift
  local target_dir tmp_file
  command -v jq >/dev/null 2>&1 || return 1
  target_dir="$(dirname "$target_path")"
  tmp_file="$(mktemp "$target_dir/.atomic-json-XXXXXX" 2>/dev/null)" || return 1
  if ! jq -n "$jq_filter" "$@" > "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
  ralph_fsync_path "$tmp_file"
  if ! mv -f "$tmp_file" "$target_path" 2>/dev/null; then
    rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
  ralph_fsync_path "$target_dir"
  return 0
}