#!/usr/bin/env bash

if [[ -n "${RALPH_PLAN_TODO_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_PLAN_TODO_LIB_LOADED=1

# Public interface:
#   plan_normalize_path, plan_log_basename -- path and safe log-stem helpers.
#   plan_detect_format -- detect 'default' (markdown) or 'cursor' (YAML frontmatter) format.
#   plan_open_todo_body -- strip markdown checkbox prefix from an open task line.
#   get_next_todo -- first open "- [ ]" line as "line|full line" (or cursor equivalent).
#   count_todos -- prints "done total" counts.
#   plan_todo_ordinal_at_line -- 1-based checklist index at a given file line.
#   plan_todo_implies_operator_dialog -- true when wording should block on operator (pending-human).
#   plan_reopen_todo_at_line -- flip [x] back to [ ] at a line (or cursor equivalent).

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

plan_detect_format() {
  local plan_path="$1"
  local override="${RALPH_PLAN_TODO_STYLE:-}"

  if [[ -n "$override" && "$override" != "default" && "$override" != "cursor" ]]; then
    echo "Invalid RALPH_PLAN_TODO_STYLE: $override (must be 'default' or 'cursor')" >&2
    return 1
  fi

  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi

  if head -1 "$plan_path" | grep -q "^---"; then
    grep -q "^\s*todos:" "$plan_path" && printf 'cursor' || printf 'default'
  else
    printf 'default'
  fi
}

plan_mark_todo_done_cursor() {
  local plan_path="$1"
  local todo_content="$2"
  if command -v python3 &>/dev/null; then
    python3 - "$plan_path" "$todo_content" <<'PYTHON'
import yaml
import sys
with open(sys.argv[1]) as f:
  content = f.read()
if content.startswith('---'):
  parts = content.split('---', 2)
  if len(parts) >= 3:
    try:
      fm = yaml.safe_load(parts[1])
      if isinstance(fm, dict) and 'todos' in fm and isinstance(fm['todos'], list):
        for todo in fm['todos']:
          if isinstance(todo, dict) and todo.get('content') == sys.argv[2]:
            todo['status'] = 'completed'
        with open(sys.argv[1], 'w') as f:
          f.write('---\n' + yaml.dump(fm, default_flow_style=False) + '---\n' + parts[2])
        sys.exit(0)
    except: pass
sys.exit(1)
PYTHON
  else
    return 1
  fi
}

# Open tasks must use "- [ ]" (space inside brackets). Plain "- []" is not matched so
# list lines that mention empty arrays / [] in prose are not mistaken for todos.
plan_open_todo_body() {
  local line="$1"
  printf '%s\n' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

get_next_todo() {
  local plan_path="$1"
  local format
  format="$(plan_detect_format "$plan_path")" || return 1

  if [[ "$format" == "cursor" ]]; then
    local line_num=0
    local in_frontmatter=0
    local found_end_marker=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line_num=$((line_num + 1))
      if [[ $line_num -eq 1 && "$line" == "---" ]]; then
        in_frontmatter=1
        continue
      fi
      if (( in_frontmatter == 1 )) && [[ "$line" == "---" ]]; then
        found_end_marker=1
        break
      fi
    done < "$plan_path"

    if command -v python3 &>/dev/null; then
      python3 - "$plan_path" <<'PYTHON'
import yaml
import sys
with open(sys.argv[1]) as f:
  content = f.read()
if content.startswith('---'):
  parts = content.split('---', 2)
  if len(parts) >= 3:
    try:
      fm = yaml.safe_load(parts[1])
      if isinstance(fm, dict) and 'todos' in fm and isinstance(fm['todos'], list):
        for idx, todo in enumerate(fm['todos']):
          if isinstance(todo, dict) and todo.get('status') != 'completed':
            print(f"{idx + 1}|{todo.get('content', '')}")
            sys.exit(0)
    except: pass
sys.exit(1)
PYTHON
    fi
  else
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line_num=$((line_num + 1))
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]* ]]; then
        printf '%s|%s\n' "$line_num" "$line"
        return 0
      fi
    done < "$plan_path"
  fi
  return 1
}

count_todos() {
  local plan_path="$1"
  local format
  format="$(plan_detect_format "$plan_path")" || { printf '0 0\n'; return 1; }

  if [[ "$format" == "cursor" ]]; then
    if command -v python3 &>/dev/null; then
      python3 - "$plan_path" <<'PYTHON'
import yaml
import sys
with open(sys.argv[1]) as f:
  content = f.read()
if content.startswith('---'):
  parts = content.split('---', 2)
  if len(parts) >= 3:
    try:
      fm = yaml.safe_load(parts[1])
      if isinstance(fm, dict) and 'todos' in fm and isinstance(fm['todos'], list):
        done = sum(1 for t in fm['todos'] if isinstance(t, dict) and t.get('status') == 'completed')
        total = len(fm['todos'])
        print(f"{done} {total}")
        sys.exit(0)
    except: pass
sys.exit(0)
print("0 0")
PYTHON
    fi
  else
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
  fi
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
