#!/usr/bin/env bash

if [[ -n "${RALPH_PLAN_TODO_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_PLAN_TODO_LIB_LOADED=1

# Public interface:
#   plan_normalize_path, plan_log_basename -- path and safe log-stem helpers.
#   plan_detect_format -- detect 'default' (markdown) or 'cursor' (YAML frontmatter) format.
#   plan_open_todo_body -- strip markdown checkbox prefix from an open task line.
#   get_next_todo -- default markdown: "file_line|full line" for first open "- [ ]" task; cursor YAML: "1-based_todo_index|content".
#   count_todos -- prints "done total" counts.
#   plan_todo_ordinal_at_line -- 1-based checklist index at a given file line (default markdown only).
#   plan_todo_ordinal_for_next -- 1-based task index for status UI: same as ordinal-at-line for default plans;
#     for cursor plans, get_next_todo's first field is already the YAML todo ordinal (not a file line).
#   plan_todo_implies_operator_dialog -- true when wording should block on operator (pending-human).
#   plan_todo_risk_classify -- classify a TODO as manual_gate, verification_gate, destructive_gate, implementation_gate, or normal.
#   plan_todo_extract_verification_commands -- emit command evidence candidates for verification-gate TODOs.
#   plan_todo_hash -- stable content hash used for manual ack scoping.
#   plan_todo_autonomous_evidence_present -- true when the current invocation already includes a structured autonomous verification signal.
#   plan_reopen_todo_at_line -- flip [x] back to [ ] at a line.
#   plan_reopen_todo_cursor -- reopen a cursor frontmatter TODO by content.
#   plan_reopen_todo_by_format -- reopen a TODO using the detected plan format.
#   plan_consolidate_todos -- collapse adjacent unchecked todos sharing prefix verb/noun (pure transform).
#   ralph_plan_split_preflight -- classify executable TODO blocks and optionally rewrite broad items.
#   ralph_plan_direct_verification_command -- return an allowlisted command for command-only verification TODOs.

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
  local override="${RALPH_PLAN_FORMAT:-}"

  if [[ -n "$override" && "$override" != "default" && "$override" != "cursor" ]]; then
    echo "Invalid RALPH_PLAN_FORMAT: $override (must be 'default' or 'cursor')" >&2
    return 1
  fi

  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi

  if head -1 "$plan_path" | grep -q "^---"; then
    grep -Eq '^[[:space:]]*todos:' "$plan_path" && printf 'cursor' || printf 'default'
  else
    printf 'default'
  fi
}

plan_todo_hash() {
  local text="$1"
  if command -v python3 &>/dev/null; then
    python3 - "$text" <<'PYTHON'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PYTHON
  elif command -v shasum &>/dev/null; then
    printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum &>/dev/null; then
    printf '%s' "$text" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$text"
  fi
}

plan_cursor_frontmatter_op() {
  local plan_path="$1"
  local operation="$2"
  local target_content="${3:-}"
  local target_status="${4:-}"

  if command -v python3 &>/dev/null; then
    python3 - "$plan_path" "$operation" "$target_content" "$target_status" <<'PYTHON'
import re
import sys

plan_path = sys.argv[1]
operation = sys.argv[2]
target_content = sys.argv[3] if len(sys.argv) > 3 else ""
target_status = sys.argv[4] if len(sys.argv) > 4 else ""

with open(plan_path, encoding="utf-8") as fh:
    text = fh.read()

if not text.startswith("---"):
    raise SystemExit(1)

parts = text.split("---", 2)
if len(parts) < 3:
    raise SystemExit(1)

fm_lines = parts[1].splitlines()
body = parts[2]

todo_items = []
in_todos = False
current = None

for idx, line in enumerate(fm_lines):
    stripped = line.strip()
    if stripped == "todos:":
        in_todos = True
        continue
    if not in_todos:
        continue

    if re.match(r"^\s*-\s+", line):
        if current is not None:
            todo_items.append(current)
        current = {
            "start": idx,
            "end": idx,
            "content": "",
            "status": "",
            "content_line": None,
            "status_line": None,
        }
        m = re.match(r"^\s*-\s+([^:]+):\s*(.*)$", line)
        if m:
            key = m.group(1).strip()
            value = m.group(2).strip()
            if key == "content":
                current["content"] = value
                current["content_line"] = idx
            elif key == "status":
                current["status"] = value
                current["status_line"] = idx
        continue

    if current is None:
        continue

    if stripped == "":
        current["end"] = idx
        continue

    m = re.match(r"^\s{4}([^:]+):\s*(.*)$", line)
    if m:
        key = m.group(1).strip()
        value = m.group(2).strip()
        current["end"] = idx
        if key == "content":
            current["content"] = value
            current["content_line"] = idx
        elif key == "status":
            current["status"] = value
            current["status_line"] = idx
        continue

    current["end"] = idx

if current is not None:
    todo_items.append(current)

if operation == "get_next":
    for idx, item in enumerate(todo_items, start=1):
        if item.get("status") != "completed":
            print(f"{idx}|{item.get('content', '')}")
            raise SystemExit(0)
    raise SystemExit(1)

if operation == "count":
    done = sum(1 for item in todo_items if item.get("status") == "completed")
    print(f"{done} {len(todo_items)}")
    raise SystemExit(0)

if operation == "set_status":
    changed = False
    for item in todo_items:
        if item.get("content") == target_content:
            status_line = item.get("status_line")
            if status_line is None:
                raise SystemExit(1)
            indent = re.match(r"^(\s*)", fm_lines[status_line]).group(1)
            fm_lines[status_line] = f"{indent}status: {target_status}"
            changed = True
            break
    if not changed:
        raise SystemExit(1)
    with open(plan_path, "w", encoding="utf-8") as fh:
        fh.write("---\n" + "\n".join(fm_lines) + "\n---" + parts[2])
    raise SystemExit(0)

raise SystemExit(1)
PYTHON
  else
    return 1
  fi
}

plan_mark_todo_done_cursor() {
  local plan_path="$1"
  local todo_content="$2"
  plan_cursor_frontmatter_op "$plan_path" "set_status" "$todo_content" "completed"
}

plan_cursor_update_todo_status() {
  local plan_path="$1"
  local todo_content="$2"
  local target_status="$3"
  plan_cursor_frontmatter_op "$plan_path" "set_status" "$todo_content" "$target_status"
}

# Open tasks must use "- [ ]" (space inside brackets). Plain "- []" is not matched so
# list lines that mention empty arrays / [] in prose are not mistaken for todos.
plan_open_todo_body() {
  local line="$1"
  printf '%s\n' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

plan_todo_has_continuation_lines() {
  local todo_text="$1"
  [[ "$todo_text" == *$'\n'* ]]
}

get_next_todo() {
  local plan_path="$1"
  local format
  format="$(plan_detect_format "$plan_path")" || return 1

  if [[ "$format" == "cursor" ]]; then
    plan_cursor_frontmatter_op "$plan_path" "get_next"
    return $?
  else
    local line_num=0
    local block=""
    local capturing=0
    local line next_line
    while IFS= read -r line || [[ -n "$line" ]]; do
      line_num=$((line_num + 1))
      if [[ "$capturing" == "0" ]]; then
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]* ]]; then
          block="$line"
          capturing=1
        fi
        continue
      fi

      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]* ]] || [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[x\][[:space:]]* ]] || [[ "$line" =~ ^#{1,6}[[:space:]] ]] || [[ "$line" =~ ^---[[:space:]]*$ ]]; then
        printf '%s|%s\n' "$((line_num - 1))" "$block"
        return 0
      fi

      if [[ -n "${line//[[:space:]]/}" ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
        printf '%s|%s\n' "$((line_num - 1))" "$block"
        return 0
      fi

      block+=$'\n'"$line"
    done < "$plan_path"
    if [[ "$capturing" == "1" ]]; then
      printf '%s|%s\n' "$line_num" "$block"
      return 0
    fi
  fi
  return 1
}

plan_mark_todo_done_at_line() {
  local plan_path="$1"
  local plan_line="$2"
  local tmp line_nr=0 changed=0 line

  [[ -f "$plan_path" ]] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-plan-done.XXXXXX")" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_nr=$((line_nr + 1))
    if (( line_nr == plan_line )) && [[ "$line" =~ ^([[:space:]]*-[[:space:]]+)\[[[:space:]]\]([[:space:]]*)(.*)$ ]]; then
      printf '%s[x]%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >>"$tmp"
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

plan_mark_todo_done_by_format() {
  local plan_path="$1"
  local format="${2:-}"
  local line_or_content="$3"

  if [[ "$format" == "cursor" ]]; then
    plan_mark_todo_done_cursor "$plan_path" "$line_or_content"
  else
    plan_mark_todo_done_at_line "$plan_path" "$line_or_content"
  fi
}

count_todos() {
  local plan_path="$1"
  local format
  format="$(plan_detect_format "$plan_path")" || { printf '0 0\n'; return 1; }

  if [[ "$format" == "cursor" ]]; then
    plan_cursor_frontmatter_op "$plan_path" "count"
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
# items in file order through that line). For default markdown, the open TODO line from get_next_todo matches.
# Cursor YAML plans do not use file-line semantics for get_next_todo's first field; use plan_todo_ordinal_for_next.
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

# plan_path, plan format ('default' or 'cursor'), first field from get_next_todo (line number or YAML ordinal).
plan_todo_ordinal_for_next() {
  local plan_path="$1"
  local format="${2:-default}"
  local next_first_field="$3"

  if [[ "$format" == "cursor" ]]; then
    printf '%s\n' "$next_first_field"
  else
    plan_todo_ordinal_at_line "$plan_path" "$next_first_field"
  fi
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

plan_reopen_todo_cursor() {
  local plan_path="$1"
  local todo_content="$2"
  plan_cursor_update_todo_status "$plan_path" "$todo_content" "pending"
}

plan_reopen_todo_by_format() {
  local plan_path="$1"
  local format="${2:-}"
  local line_or_content="$3"

  if [[ "$format" == "cursor" ]]; then
    plan_reopen_todo_cursor "$plan_path" "$line_or_content"
  else
    plan_reopen_todo_at_line "$plan_path" "$line_or_content"
  fi
}

plan_todo_risk_classify() {
  local todo_text="$1"
  if command -v python3 &>/dev/null; then
    python3 - "$todo_text" <<'PYTHON'
import re
import sys

text = sys.argv[1]
lower = text.lower()

manual_patterns = [
    r'\bmanual\b',
    r'\bsmoke\b',
    r'\bgolden[ -]path\b',
    r'\bnot run in this session\b',
    r'\bask the user\b',
]
destructive_patterns = [
    r'\bdelete\b',
    r'\bdrop\b',
    r'\bdestroy\b',
    r'\bpurge\b',
    r'\btruncate\b',
    r'\bwipe\b',
    r'\brollback\b',
    r'\bmigrate down\b',
    r'\bdown-migrate\b',
    r'\bremove\b',
]
implementation_patterns = [
    r'\bimplement\b',
    r'\badd\b',
    r'\bupdate\b',
    r'\bfix\b',
    r'\bcreate\b',
    r'\bmodify\b',
    r'\bpatch\b',
    r'\bwire\b',
    r'\bintegrate\b',
    r'\brefactor\b',
    r'\bchange\b',
    r'\bchanges\b',
    r'\bchanged\b',
    r'\bmake\b.*\bchanges?\b',
    r'\bremove\b',
    r'\breplace\b',
    r'\bdelete\b',
    r'\binsert\b',
    r'\bwrap\b',
    r'\bdelete\b',
]
normal_patterns = [
    r'\bdocs?\b',
    r'\bdocumentation\b',
    r'\brunbook\b',
    r'\banalysis\b',
    r'\breview\b',
    r'\binvestigate\b',
    r'\bexplain\b',
    r'\bsummarize\b',
    r'\bread\b',
]

if any(re.search(pattern, lower) for pattern in manual_patterns):
    print("manual_gate")
elif any(re.search(pattern, lower) for pattern in destructive_patterns):
    print("destructive_gate")
else:
    command_prefixes = (
        "./",
        "/",
        "npm",
        "npx",
        "yarn",
        "pnpm",
        "git",
        "bash",
        "sh",
        "python",
        "python3",
        "pytest",
        "playwright",
        "node",
        "make",
        "go",
        "cargo",
        "bun",
        "deno",
        "grep",
        "rg",
        "sed",
        "awk",
        "find",
        "cat",
        "curl",
        "docker",
        "kubectl",
        "mvn",
        "gradle",
        "tsc",
        "eslint",
        "prettier",
        "vitest",
        "jest",
        "rspec",
        "bundle",
        "rake",
        "uv",
    )

    def looks_like_command(candidate: str) -> bool:
        candidate = candidate.strip()
        if not candidate:
            return False
        first = candidate.split(None, 1)[0]
        if first.startswith("./") or first.startswith("/"):
            return True
        return first in command_prefixes

    verification_hint = False
    if re.search(r'(^|\n)\s*verification\s*:', text, re.I):
        verification_hint = True
    else:
        for candidate in re.findall(r'`([^`]+)`', text):
            if looks_like_command(candidate):
                verification_hint = True
                break
        if not verification_hint and re.search(r'(^|\n).*(?:&&|\|\||;).+', text):
            verification_hint = True

    if verification_hint:
        print("verification_gate")
    elif any(re.search(pattern, lower) for pattern in implementation_patterns) and not any(re.search(pattern, lower) for pattern in normal_patterns):
        print("implementation_gate")
    else:
        print("normal")
PYTHON
  else
    printf 'normal\n'
  fi
}

plan_todo_extract_verification_commands() {
  local todo_text="$1"
  if command -v python3 &>/dev/null; then
    python3 - "$todo_text" <<'PYTHON'
import re
import sys

text = sys.argv[1]
commands = []

for line in text.splitlines():
    m = re.match(r'^\s*Verification:\s*(.+\S)\s*$', line, re.I)
    if m:
        commands.append(m.group(1).strip())

for candidate in re.findall(r'`([^`]+)`', text):
    candidate = candidate.strip()
    if not candidate:
        continue
    if any(ch in candidate for ch in (' ', '\t', '/', '&', '|', ';')) or candidate.startswith('./'):
        commands.append(candidate)

seen = set()
for command in commands:
    key = command.strip()
    if key and key not in seen:
        seen.add(key)
        print(key)
PYTHON
  else
    return 1
  fi
}

plan_todo_contains_suspicious_completion_phrase() {
  local text="$1"
  if command -v python3 &>/dev/null; then
    python3 - "$text" <<'PYTHON'
import re
import sys

text = sys.argv[1].lower()
patterns = [
    r'marked\s+.*complete',
    r'no\s+further\s+action',
    r'no\s+additional\s+steps',
    r'done\s+and\s+stop',
]
print("1" if any(re.search(pattern, text) for pattern in patterns) else "0")
PYTHON
  else
    case "$text" in
      *"marked "*complete*|*"no further action"*|*"no additional steps"*|*"done and stop"*)
        printf '1\n'
        ;;
      *)
        printf '0\n'
        ;;
    esac
  fi
}

plan_todo_autonomous_evidence_present() {
  local text="$1"
  if command -v python3 &>/dev/null; then
    python3 - "$text" <<'PYTHON'
import re
import sys

text = sys.argv[1].lower()
patterns = [
    r'\bverified\b',
    r'\bautovalidated\b',
    r'\bplaywright\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\bunit\s+test(s)?\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\btest(s)?\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\bcode\s+review\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\bautomated\s+check\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\bexit\s+0\b',
]
print("1" if any(re.search(pattern, text, re.I | re.S) for pattern in patterns) else "0")
PYTHON
  else
    case "$text" in
      *"VERIFIED:"*|*"AUTOVALIDATED:"*|*"PASS"*|*"PASSED"*)
        printf '1\n'
        ;;
      *)
        printf '0\n'
        ;;
    esac
  fi
}

# Consolidation implementation using Python when available, otherwise no-op with warning.
# Writes log to session dir if RALPH_SESSION_DIR is set.
ralph_run_plan_consolidate_todos() {
  local plan_path="$1"
  if [[ ! -f "$plan_path" ]]; then
    echo "Error: plan file not found for consolidation: $plan_path" >&2
    return 1
  fi

  local session_dir="${RALPH_SESSION_DIR:-}"
  local log_path
  if [[ -n "$session_dir" ]]; then
    log_path="$session_dir/consolidation-log.txt"
  else
    log_path="/dev/null"
  fi

  if ! command -v python3 &>/dev/null; then
    echo "Warning: todo consolidation requires Python 3 (missing); skipping" >&2
    if [[ -n "$session_dir" ]]; then
      echo "$(date): Python 3 not found, consolidation skipped" >> "$log_path"
    fi
    return 0
  fi

  local base_dir share_dir
  base_dir="$(dirname "${BASH_SOURCE[0]}")"
  share_dir="$(cd "$base_dir" && pwd)"
  local script_path="$share_dir/plan-todo-consolidate.py"

  if [[ ! -f "$script_path" ]]; then
    echo "Warning: consolidation script not found at $script_path; skipping" >&2
    if [[ -n "$session_dir" ]]; then
      echo "$(date): consolidation script not found, skipped" >> "$log_path"
    fi
    return 0
  fi

  python3 "$script_path" "$plan_path" "$log_path"
}

_ralph_plan_split_script() {
  local base_dir
  base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$base_dir/plan-split.py"
}

ralph_plan_split_preflight() {
  local plan_path="$1"
  local mode="${2:-warn}"
  local out_path="${3:-}"
  local script
  script="$(_ralph_plan_split_script)"
  [[ -f "$script" ]] || return 0
  command -v python3 &>/dev/null || {
    echo "Warning: python3 not found; skipping Ralph TODO preflight." >&2
    return 0
  }

  local args=(python3 "$script" preflight --plan "$plan_path" --mode "$mode")
  [[ -n "$out_path" ]] && args+=(--out "$out_path")
  RALPH_PLAN_MAX_TODO_BYTES="${RALPH_PLAN_MAX_TODO_BYTES:-1800}" \
  RALPH_PLAN_MAX_TODO_CONTINUATION_LINES="${RALPH_PLAN_MAX_TODO_CONTINUATION_LINES:-6}" \
  RALPH_PLAN_MAX_FILE_REFS_PER_TODO="${RALPH_PLAN_MAX_FILE_REFS_PER_TODO:-5}" \
    "${args[@]}"
}

ralph_plan_split_cli() {
  local script
  script="$(_ralph_plan_split_script)"
  [[ -f "$script" ]] || {
    echo "Error: split helper not found: $script" >&2
    return 1
  }
  command -v python3 &>/dev/null || {
    echo "Error: split-plan requires python3." >&2
    return 1
  }
  RALPH_PLAN_MAX_TODO_BYTES="${RALPH_PLAN_MAX_TODO_BYTES:-1800}" \
  RALPH_PLAN_MAX_TODO_CONTINUATION_LINES="${RALPH_PLAN_MAX_TODO_CONTINUATION_LINES:-6}" \
  RALPH_PLAN_MAX_FILE_REFS_PER_TODO="${RALPH_PLAN_MAX_FILE_REFS_PER_TODO:-5}" \
    python3 "$script" split "$@"
}

ralph_plan_direct_verification_command() {
  local todo_text="$1"
  local script
  script="$(_ralph_plan_split_script)"
  [[ -f "$script" ]] || return 1
  command -v python3 &>/dev/null || return 1
  python3 "$script" direct-command --todo "$todo_text"
}
