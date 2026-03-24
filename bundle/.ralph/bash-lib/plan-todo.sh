#!/usr/bin/env bash

if [[ -n "${RALPH_PLAN_TODO_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_PLAN_TODO_LIB_LOADED=1

# Public interface:
#   plan_normalize_path, plan_log_basename -- path and safe log-stem helpers.
#   plan_open_todo_body -- strip markdown checkbox prefix from an open task line.
#   get_next_todo -- first open "- [ ]" line as "line|full line".
#   count_todos -- prints "done total" counts.
#   plan_todo_ordinal_at_line -- 1-based checklist index at a given file line.
#   plan_todo_implies_operator_dialog -- true when wording should block on operator (pending-human).
#   plan_reopen_todo_at_line -- flip [x] back to [ ] at a line.

plan_normalize_path() {
  local path="$1"
  local workspace="$2"

  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
    return
  fi

  if [[ "$path" == ~* ]]; then
    printf '%s\n' "${path/#\~/$HOME}"
    return
  fi

  if [[ -n "$workspace" ]]; then
    printf '%s\n' "$workspace/$path"
  else
    printf '%s\n' "$path"
  fi
}

plan_log_basename() {
  local path="$1"
  local base
  base="$(basename "$path" | sed 's/\.[^.]*$//')"
  printf '%s\n' "$base" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

# Open tasks must use "- [ ]" (space inside brackets). Plain "- []" is not matched so
# list lines that mention empty arrays / [] in prose are not mistaken for todos.
plan_open_todo_body() {
  local line="$1"
  printf '%s\n' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

get_next_todo() {
  local plan_path="$1"
  local line_num=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]* ]]; then
      printf '%s|%s\n' "$line_num" "$line"
      return 0
    fi
  done < "$plan_path"
  return 1
}

count_todos() {
  local plan_path="$1"
  local total=0
  local done=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]* ]]; then
      total=$((total + 1))
    elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[x\][[:space:]] ]]; then
      total=$((total + 1))
      done=$((done + 1))
    fi
  done < "$plan_path"
  printf '%s %s\n' "$done" "$total"
}

# 1-based index of the checklist item at plan_path line plan_line (counts both open and done
# items in file order through that line). The current open TODO line from get_next_todo always matches.
plan_todo_ordinal_at_line() {
  local plan_path="$1"
  local plan_line="$2"
  awk -v ln="$plan_line" '
    NR > ln { exit }
    /^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*/ { c++; next }
    /^[[:space:]]*-[[:space:]]+\[x\][[:space:]]/ { c++; next }
    END { print c + 0 }
  ' "$plan_path"
}

# True when TODO wording means the operator should be consulted via the runner (pending-human),
# not only via assistant chat (which the runner does not treat as blocking).
plan_todo_implies_operator_dialog() {
  local t="$1"
  # "Tell the user ..." is usually a one-way message via assistant output; do not require a gate.
  [[ "$t" =~ [Aa]sk[[:space:]]+the[[:space:]]+user ]] && return 0
  return 1
}

# Reopen the checklist item at 1-based plan_line (change [x] to [ ]). Returns 0 if a line was changed.
plan_reopen_todo_at_line() {
  local plan_path="$1"
  local plan_line="$2"
  local tmp line_nr=0 changed=0 line

  [[ -f "$plan_path" ]] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-plan-reopen.XXXXXX")" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_nr=$((line_nr + 1))
    if (( line_nr == plan_line )) && [[ "$line" =~ ^([[:space:]]*-[[:space:]]+)\[[xX]\]([[:space:]]*)(.*)$ ]]; then
      printf '%s[ ]%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >>"$tmp"
      changed=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$plan_path"
  if (( changed == 0 )); then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$plan_path"
  return 0
}
