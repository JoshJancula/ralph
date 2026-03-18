#!/usr/bin/env bash
# Pre-tool-use hook: block reads of .env files by any agent tool
#
# Claude Code passes tool input as JSON on stdin.
# This script inspects the input and exits 1 (blocking the tool call)
# if the tool is attempting to read a file matching .env patterns.
#
# Blocked patterns: .env, .env.local, .env.development, .env.production,
# .env.staging, .env.test, .env.*.local, and any other .env* variant.

set -euo pipefail

INPUT=$(cat)

# Extract the file path from common tool input shapes.
# Handles: {"path": "..."}, {"file_path": "..."}, {"filename": "..."}
FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [[ -z "$FILE_PATH" ]]; then
  FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi
if [[ -z "$FILE_PATH" ]]; then
  FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"filename"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi

if [[ -z "$FILE_PATH" ]]; then
  # No file path found in input — allow the tool call through
  exit 0
fi

# Normalise to basename for pattern matching
BASENAME=$(basename "$FILE_PATH")

# Block any file whose name starts with .env
if [[ "$BASENAME" == .env* ]]; then
  echo "BLOCKED: Agent attempted to read '$FILE_PATH'. Reading .env files is not permitted." >&2
  exit 1
fi

exit 0
