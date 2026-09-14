#!/usr/bin/env bash
#
# Shared mutation journal for ralph setup --remove.
#
# Before each mutation, copy the original into
# <state-root>/setup-journal/<operation-id>/ and append a JSON journal entry.
# Restore entries in reverse order on error or signal. --dry-run creates no journal.
#
# Public interface:
#   setup_journal_begin <state-root> [operation-id]
#   setup_journal_record <target-path>
#   setup_journal_recover
#   setup_journal_commit
#   setup_journal_clear_traps

set -euo pipefail

if [[ -n "${RALPH_SETUP_JOURNAL_LOADED:-}" ]]; then
  return 0
fi
RALPH_SETUP_JOURNAL_LOADED=1

SETUP_JOURNAL_DIR=""
SETUP_JOURNAL_ID=""
SETUP_JOURNAL_SEQ=0
SETUP_JOURNAL_FILE=""

setup_journal_json_line() {
  local seq="$1"
  local kind="$2"
  local path="$3"
  local backup="${4:-}"

  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps({"seq":int(sys.argv[1]),"kind":sys.argv[2],"path":sys.argv[3],"backup":sys.argv[4]}))' \
      "$seq" "$kind" "$path" "$backup"
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -nc --argjson seq "$seq" --arg kind "$kind" --arg path "$path" --arg backup "$backup" \
      '{seq:$seq,kind:$kind,path:$path,backup:$backup}'
    return 0
  fi
  printf '{"seq":%s,"kind":"%s","path":"%s","backup":"%s"}\n' "$seq" "$kind" "$path" "$backup"
}

setup_journal_clear_traps() {
  trap - INT TERM HUP EXIT
}

setup_journal_on_exit() {
  local rc=$?
  if [[ -n "${SETUP_JOURNAL_FILE:-}" && -f "$SETUP_JOURNAL_FILE" ]]; then
    setup_journal_recover || true
  fi
  return "$rc"
}

setup_journal_on_signal() {
  setup_journal_recover || true
  setup_journal_clear_traps
  exit 1
}

setup_journal_install_traps() {
  trap 'setup_journal_on_signal' INT TERM HUP
  trap 'setup_journal_on_exit' EXIT
}

setup_journal_begin() {
  local state_root="${1:-}"
  local operation_id="${2:-}"

  SETUP_JOURNAL_DIR=""
  SETUP_JOURNAL_ID=""
  SETUP_JOURNAL_SEQ=0
  SETUP_JOURNAL_FILE=""

  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    return 0
  fi
  if [[ -z "$state_root" ]]; then
    printf 'Error: setup_journal_begin requires a state-root\n' >&2
    return 1
  fi
  if [[ -z "$operation_id" ]]; then
    operation_id="remove-$$-$(date +%Y%m%dT%H%M%S)"
  fi

  SETUP_JOURNAL_ID="$operation_id"
  SETUP_JOURNAL_DIR="${state_root%/}/setup-journal/${operation_id}"
  SETUP_JOURNAL_FILE="$SETUP_JOURNAL_DIR/journal.jsonl"
  mkdir -p "$SETUP_JOURNAL_DIR"
  : >"$SETUP_JOURNAL_FILE"
  setup_journal_install_traps
}

setup_journal_record() {
  local target="${1:-}"
  local seq backup kind

  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    return 0
  fi
  if [[ -z "$target" ]]; then
    printf 'Error: setup_journal_record requires a target path\n' >&2
    return 1
  fi
  if [[ -z "${SETUP_JOURNAL_DIR:-}" || -z "${SETUP_JOURNAL_FILE:-}" ]]; then
    printf 'Error: setup journal is not active\n' >&2
    return 1
  fi

  seq="$SETUP_JOURNAL_SEQ"
  SETUP_JOURNAL_SEQ=$((SETUP_JOURNAL_SEQ + 1))
  backup="$SETUP_JOURNAL_DIR/$seq"
  if [[ -e "$target" || -L "$target" ]]; then
    cp -p "$target" "$backup"
    kind="file"
  else
    kind="absent"
    backup=""
  fi
  setup_journal_json_line "$seq" "$kind" "$target" "$backup" >>"$SETUP_JOURNAL_FILE"
}

setup_journal_restore_entry() {
  local line="$1"
  local kind path backup

  if command -v python3 >/dev/null 2>&1; then
    eval "$(python3 -c 'import json,shlex,sys
e=json.loads(sys.argv[1])
print("kind="+shlex.quote(e.get("kind","")))
print("path="+shlex.quote(e.get("path","")))
print("backup="+shlex.quote(e.get("backup","")))' "$line")"
  elif command -v jq >/dev/null 2>&1; then
    kind="$(printf '%s' "$line" | jq -r '.kind // empty')"
    path="$(printf '%s' "$line" | jq -r '.path // empty')"
    backup="$(printf '%s' "$line" | jq -r '.backup // empty')"
  else
    printf 'Error: python3 or jq is required to recover the setup journal\n' >&2
    return 1
  fi

  [[ -n "$path" ]] || return 0
  if [[ "$kind" == "file" ]]; then
    cp -p "$backup" "$path" || return 1
  elif [[ "$kind" == "absent" ]]; then
    rm -f "$path" || true
  fi
}

setup_journal_recover() {
  local reversed line
  [[ -n "${SETUP_JOURNAL_FILE:-}" && -f "$SETUP_JOURNAL_FILE" ]] || return 0
  reversed="$(awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' "$SETUP_JOURNAL_FILE")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    setup_journal_restore_entry "$line" || true
  done <<<"$reversed"
}

setup_journal_commit() {
  setup_journal_clear_traps
  if [[ -n "${SETUP_JOURNAL_DIR:-}" && -d "$SETUP_JOURNAL_DIR" ]]; then
    rm -rf "$SETUP_JOURNAL_DIR"
  fi
  SETUP_JOURNAL_DIR=""
  SETUP_JOURNAL_ID=""
  SETUP_JOURNAL_FILE=""
  SETUP_JOURNAL_SEQ=0
}
