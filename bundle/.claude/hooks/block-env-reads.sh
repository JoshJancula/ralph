#!/usr/bin/env bash
# Pre-tool-use hook: block reads of .env files by any agent tool
#
# Claude Code passes tool input as JSON on stdin.
# This script inspects the input and exits 1 (blocking the tool call)
# if the tool is attempting to read a file matching .env patterns.
#
# Blocked patterns: .env, .env.local, .env.development, .env.production,
# .env.staging, .env.test, .env.*.local, and any other .env* variant.
#
# Fast path (no set/source/jq): allow when the payload cannot contain an
# .env* basename. Otherwise one jq call extracts path/file_path/filename
# and checks the basename.

INPUT=
IFS= read -r -d '' INPUT || true

# Cheap reject: payloads with no ".env" substring cannot name an .env* file.
case "$INPUT" in
  *".env"*) ;;
  *) exit 0 ;;
esac

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  # Fail open without jq: cannot reliably parse tool input.
  exit 0
fi

# Single jq: path candidate + whether basename starts with .env.
# Handles top-level and tool_input shapes: path / file_path / filename.
_RALPH_BLOCK_ENV_TSV="$(
  jq -r '
    (
      .tool_input.file_path // .tool_input.path // .tool_input.filename //
      .file_path // .path // .filename // ""
    ) as $p
    | ($p | split("/") | last) as $base
    | [
        $p,
        (if ($p | length) > 0 and ($base | startswith(".env")) then "1" else "0" end)
      ]
    | @tsv
  ' <<<"$INPUT" 2>/dev/null
)" || exit 0

IFS=$'\t' read -r FILE_PATH _ralph_block_env_match <<<"$_RALPH_BLOCK_ENV_TSV" || exit 0

if [[ "${_ralph_block_env_match:-0}" != "1" ]]; then
  exit 0
fi

echo "BLOCKED: Agent attempted to read '$FILE_PATH'. Reading .env files is not permitted." >&2
exit 1
