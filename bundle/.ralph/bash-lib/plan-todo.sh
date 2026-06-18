#!/usr/bin/env bash

if [[ -n "${RALPH_PLAN_TODO_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_PLAN_TODO_LIB_LOADED=1

# Public interface:
#   plan_normalize_path, plan_log_basename -- path and safe log-stem helpers.
#   plan_format_is_yaml -- true when format is YAML frontmatter ('yaml' or legacy alias 'cursor').
#   plan_format_display -- canonical plan-format label for logs and user-facing output.
#   plan_detect_format -- detect 'default' (markdown) or 'yaml' (YAML frontmatter) format.
#   plan_open_todo_body -- strip markdown checkbox prefix from an open task line.
#   get_next_todo -- default markdown: "file_line|full line" for first open "- [ ]" task; yaml frontmatter: "ordinal|id|content" (id empty when absent).
#   count_todos -- prints "done total" counts; yaml frontmatter plans treat completed/complete/done (case-insensitive) as done.
#   plan_todo_ordinal_at_line -- 1-based checklist index at a given file line (default markdown only).
#   plan_todo_ordinal_for_next -- 1-based task index for status UI: same as ordinal-at-line for default plans;
#     for yaml frontmatter plans, get_next_todo's first field is already the YAML todo ordinal.
#   plan_todo_implies_operator_dialog -- true when wording should block on operator (pending-human).
#   plan_todo_risk_classify -- classify a TODO as manual_gate, verification_gate, destructive_gate, implementation_gate, or normal.
#   plan_todo_extract_verification_commands -- emit command evidence candidates for verification-gate TODOs.
#   plan_todo_hash -- stable content hash used for manual ack scoping.
#   plan_todo_autonomous_evidence_present -- true when the current invocation already includes a structured autonomous verification signal.
#   plan_pipeline_todo_metadata_json -- pipeline-format raw TODO metadata JSON helper.
#   plan_pipeline_effective_metadata_json -- pipeline-format effective TODO metadata JSON helper.
#   plan_structured_todo_metadata_json -- compatibility wrapper for pipeline-format raw TODO metadata.
#   plan_structured_effective_metadata_json -- compatibility wrapper for pipeline-format effective TODO metadata.
#   plan_pipeline_validate_plan -- validates pipeline-format plans when pipeline metadata exists.
#   plan_reopen_todo_at_line -- flip [x] back to [ ] at a line.
#   plan_reopen_todo_yaml -- reopen a yaml frontmatter TODO by id or ordinal.
#   plan_reopen_todo_cursor -- compatibility alias for plan_reopen_todo_yaml.
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

plan_format_is_yaml() {
  local format="${1:-}"
  [[ "$format" == "yaml" || "$format" == "cursor" ]]
}

plan_format_display() {
  local format="${1:-}"
  if plan_format_is_yaml "$format"; then
    printf 'yaml\n'
  else
    printf '%s\n' "${format:-default}"
  fi
}

plan_detect_format() {
  local plan_path="$1"
  local override="${RALPH_PLAN_FORMAT:-}"

  if [[ -n "$override" && "$override" != "default" && "$override" != "yaml" && "$override" != "cursor" ]]; then
    echo "Invalid RALPH_PLAN_FORMAT: $override (must be 'default' or 'yaml')" >&2
    return 1
  fi

  if [[ -n "$override" ]]; then
    if [[ "$override" == "cursor" ]]; then
      printf 'yaml\n'
    else
      printf '%s\n' "$override"
    fi
    return 0
  fi

  if head -1 "$plan_path" | grep -q "^---"; then
    grep -Eq '^[[:space:]]*todos:' "$plan_path" && printf 'yaml' || printf 'default'
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

plan_yaml_frontmatter_op() {
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
    lines = fh.read().splitlines(True)

if not lines:
    raise SystemExit(1)

if lines[0].rstrip("\r\n") != "---":
    raise SystemExit(1)

closing_idx = None
for idx in range(1, len(lines)):
    if lines[idx].rstrip("\r\n") == "---":
        closing_idx = idx
        break
if closing_idx is None:
    raise SystemExit(1)

todo_items = []
in_todos = False
current = None
frontmatter_end = closing_idx


def line_indent(text: str) -> int:
    return len(text) - len(text.lstrip(" "))


def is_todo_item_line(line: str) -> bool:
    stripped = line.lstrip(" ")
    indent = len(line) - len(stripped)
    return indent <= 2 and stripped.startswith("- ")


def is_property_line(line: str) -> bool:
    return bool(re.match(r"^\s{4}[^:]+:\s*", line))


def status_is_done(status: str) -> bool:
    return status.strip().lower() in {"completed", "complete", "done"}


def consume_block_scalar(start_idx: int) -> tuple[str, int]:
    block_lines = []
    block_indent = None
    idx = start_idx + 1
    while idx < frontmatter_end:
        next_line = lines[idx]
        next_stripped = next_line.strip()
        next_indent = line_indent(next_line)
        if next_stripped != "" and (
            is_todo_item_line(next_line)
            or (is_property_line(next_line) and next_indent <= 4)
        ):
            break
        if next_stripped == "":
            block_lines.append("")
        else:
            if block_indent is None:
                block_indent = next_indent
            block_lines.append(next_line[block_indent:].rstrip("\r\n"))
        idx += 1
    return "\n".join(block_lines), idx


def resolve_target_item(target: str):
    if not target:
        raise SystemExit(1)

    id_matches = [item for item in todo_items if item.get("id", "") == target]
    if len(id_matches) > 1:
        raise SystemExit(1)
    if len(id_matches) == 1:
        return id_matches[0]

    if target.isdigit():
        ordinal = int(target)
        ordinal_matches = [item for item in todo_items if item.get("ordinal") == ordinal]
        if len(ordinal_matches) != 1:
            raise SystemExit(1)
        return ordinal_matches[0]

    raise SystemExit(1)


idx = 1
while idx < closing_idx:
    line = lines[idx]
    stripped = line.strip()
    if not in_todos:
        if stripped == "todos:":
            in_todos = True
        idx += 1
        continue

    if is_todo_item_line(line):
        if current is not None:
            todo_items.append(current)
        current = {
            "ordinal": len(todo_items) + 1,
            "start": idx,
            "content": "",
            "verification": "",
            "status": "",
            "id": "",
            "content_line": None,
            "verification_line": None,
            "status_line": None,
            "id_line": None,
        }
        m = re.match(r"^\s*-\s+([^:]+):\s*(.*)$", line)
        if m:
            key = m.group(1).strip()
            value = m.group(2).strip()
            line_idx = idx
            if value in {"|", "|-", "|+"}:
                value, idx = consume_block_scalar(idx)
            else:
                idx += 1
            if key == "content":
                current["content"] = value
                current["content_line"] = line_idx
            elif key == "verification":
                current["verification"] = value
                current["verification_line"] = line_idx
            elif key == "verify":
                current["verify"] = value
                current["verify_line"] = line_idx
            elif key == "status":
                current["status"] = value
                current["status_line"] = line_idx
            elif key == "id":
                current["id"] = value
                current["id_line"] = line_idx
            continue
        idx += 1
        continue

    if current is None:
        idx += 1
        continue

    if stripped == "":
        idx += 1
        continue

    m = re.match(r"^\s{4}([^:]+):\s*(.*)$", line)
    if m:
        key = m.group(1).strip()
        value = m.group(2).strip()
        line_idx = idx
        if value in {"|", "|-", "|+"}:
            value, idx = consume_block_scalar(idx)
        else:
            idx += 1
        if key == "content":
            current["content"] = value
            current["content_line"] = line_idx
        elif key == "verification":
            current["verification"] = value
            current["verification_line"] = line_idx
        elif key == "verify":
            current["verify"] = value
            current["verify_line"] = line_idx
        elif key == "status":
            current["status"] = value
            current["status_line"] = line_idx
        elif key == "id":
            current["id"] = value
            current["id_line"] = line_idx
        continue

    idx += 1

if current is not None:
    todo_items.append(current)

if operation == "get_next":
    for item in todo_items:
        if not status_is_done(str(item.get("status", ""))):
            print(f"{item.get('ordinal', '')}|{item.get('id', '')}|{item.get('content', '')}")
            raise SystemExit(0)
    raise SystemExit(1)

if operation == "count":
    done = sum(1 for item in todo_items if status_is_done(str(item.get("status", ""))))
    print(f"{done} {len(todo_items)}")
    raise SystemExit(0)

if operation == "get_verification":
    item = resolve_target_item(target_content)
    print(item.get("verification", ""))
    raise SystemExit(0)

if operation == "get_verify":
    item = resolve_target_item(target_content)
    print(item.get("verify", ""))
    raise SystemExit(0)

if operation == "set_status":
    item = resolve_target_item(target_content)
    status_line = item.get("status_line")
    if status_line is None:
        raise SystemExit(1)
    original_line = lines[status_line]
    stripped_line = original_line.rstrip("\r\n")
    newline = original_line[len(stripped_line) :]
    prefix_match = re.match(r"^(\s*status:\s*)", stripped_line)
    if prefix_match:
        prefix = prefix_match.group(1)
    else:
        indent_match = re.match(r"^(\s*)", stripped_line)
        prefix = f"{indent_match.group(1)}status: "
    lines[status_line] = f"{prefix}{target_status}{newline}"
    with open(plan_path, "w", encoding="utf-8", newline="") as fh:
        fh.write("".join(lines))
    raise SystemExit(0)

raise SystemExit(1)
PYTHON
  else
    return 1
  fi
}

plan_mark_todo_done_yaml() {
  local plan_path="$1"
  local todo_content="$2"
  plan_yaml_frontmatter_op "$plan_path" "set_status" "$todo_content" "completed"
}

plan_mark_todo_done_cursor() {
  plan_mark_todo_done_yaml "$@"
}

plan_yaml_update_todo_status() {
  local plan_path="$1"
  local todo_content="$2"
  local target_status="$3"
  plan_yaml_frontmatter_op "$plan_path" "set_status" "$todo_content" "$target_status"
}

plan_cursor_update_todo_status() {
  plan_yaml_update_todo_status "$@"
}

plan_cursor_frontmatter_op() {
  plan_yaml_frontmatter_op "$@"
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

plan_pipeline_has_metadata() {
  local plan_path="$1"

  awk '
    BEGIN {
      in_frontmatter = 0
      has_pipeline = 0
      saw_closing = 0
    }
    NR == 1 && $0 == "---" {
      in_frontmatter = 1
      next
    }
    in_frontmatter && $0 == "---" {
      saw_closing = 1
      in_frontmatter = 0
      next
    }
    in_frontmatter && $0 ~ /^[[:space:]]*pipeline:[[:space:]]*/ {
      has_pipeline = 1
    }
    END {
      exit((saw_closing && has_pipeline) ? 0 : 1)
    }
  ' "$plan_path"
}

plan_pipeline_any_todo_has_routing() {
  local plan_path="$1"

  awk '
    BEGIN {
      in_frontmatter = 0
      in_todos = 0
      found = 0
      saw_closing = 0
    }
    NR == 1 && $0 == "---" {
      in_frontmatter = 1
      next
    }
    in_frontmatter && $0 == "---" {
      saw_closing = 1
      in_frontmatter = 0
      next
    }
    in_frontmatter && /^todos:[[:space:]]*$/ {
      in_todos = 1
      next
    }
    in_frontmatter && in_todos && /^[a-zA-Z]/ {
      in_todos = 0
    }
    in_frontmatter && in_todos && /^[[:space:]]+(runtime|agent|model|sessionStrategy|contextBudget):[[:space:]]/ {
      found = 1
    }
    END {
      exit((saw_closing && found) ? 0 : 1)
    }
  ' "$plan_path"
}

plan_pipeline_validate_plan() {
  local plan_path="$1"

  if ! plan_pipeline_has_metadata "$plan_path"; then
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    echo "Error: pipeline-format plans require python3 for validation; classic markdown plans are the zero-dependency alternative." >&2
    return 1
  fi

  _plan_pipeline_metadata_json "$plan_path" "__validate__" "validate"
}

_plan_pipeline_metadata_json() {
  local plan_path="$1"
  local target="$2"
  local mode="$3"

  if ! command -v python3 &>/dev/null; then
    echo "Error: pipeline-format metadata helpers require python3." >&2
    return 1
  fi

  python3 - "$plan_path" "$target" "$mode" <<'PYTHON'
import json
import re
import sys

plan_path = sys.argv[1]
target = sys.argv[2]
mode = sys.argv[3]

ALLOWED_RUNTIMES = {"cursor", "claude", "codex", "opencode"}
ALLOWED_SESSION_STRATEGIES = {"fresh", "resume", "reset", "compact"}
ALLOWED_CONTEXT_BUDGETS = {"full", "standard", "lean"}
BLOCK_INDICATORS = {"|", "|-", "|+"}
STAGE_ID_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


def fail(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_lines(path: str) -> list[str]:
    with open(path, encoding="utf-8") as fh:
        return fh.read().splitlines()


def is_blank_or_comment(line: str) -> bool:
    stripped = line.strip()
    return stripped == "" or stripped.startswith("#")


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def next_significant(lines: list[str], idx: int) -> int:
    while idx < len(lines) and is_blank_or_comment(lines[idx]):
        idx += 1
    return idx


def split_key_value(text: str) -> tuple[str, str]:
    if ":" not in text:
        return text.strip(), ""
    key, raw = text.split(":", 1)
    return key.strip(), raw.lstrip()


def parse_scalar_text(text: str) -> str:
    value = text.strip()
    if not value:
        return ""
    if len(value) >= 2 and ((value[0] == value[-1] == "'") or (value[0] == value[-1] == '"')):
        return value[1:-1]
    return value


def parse_bool_text(text: str) -> bool:
    value = text.strip().lower()
    if value == "true":
        return True
    if value == "false":
        return False
    fail(f"invalid boolean value {text!r}")


def parse_int_text(text: str) -> int:
    value = text.strip()
    if not re.fullmatch(r"[0-9]+", value):
        fail(f"invalid integer value {text!r}")
    return int(value)


def parse_block_scalar(lines: list[str], start_idx: int, key_indent: int) -> tuple[str, int]:
    block_lines: list[str] = []
    block_indent = None
    idx = start_idx + 1
    while idx < len(lines):
        line = lines[idx]
        stripped = line.strip()
        current_indent = indent_of(line)
        if stripped != "" and current_indent <= key_indent:
            break
        if stripped == "":
            block_lines.append("")
        else:
            if block_indent is None:
                block_indent = current_indent
            block_lines.append(line[block_indent:].rstrip("\r\n"))
        idx += 1
    return "\n".join(block_lines), idx


def parse_artifact_item(lines: list[str], start_idx: int, item_indent: int) -> tuple[dict, int]:
    line = lines[start_idx]
    payload = line[item_indent:].lstrip()
    if not payload.startswith("-"):
        fail("artifact list item missing '-' prefix")
    item = {"required": True}
    consumed_idx = start_idx + 1

    fragment = payload[1:].lstrip()
    if fragment:
        if ":" not in fragment:
            item["__shorthand"] = fragment
            return item, consumed_idx
        key, raw = split_key_value(fragment)
        if key not in {"path", "required"}:
            fail(f"unsupported artifact field {key!r}")
        if key == "path":
            value = parse_scalar_text(raw)
            if not value:
                fail("artifact path must not be empty")
            item["path"] = value
        else:
            item["required"] = parse_bool_text(raw)

    idx = consumed_idx
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= item_indent:
            break
        key, raw = split_key_value(line.strip())
        if key not in {"path", "required"}:
            fail(f"unsupported artifact field {key!r}")
        if key == "path":
            value = parse_scalar_text(raw)
            if not value:
                fail("artifact path must not be empty")
            item["path"] = value
        else:
            item["required"] = parse_bool_text(raw)
        idx += 1

    if "path" not in item:
        fail("artifact entry missing path")
    return item, idx


def parse_artifact_list(lines: list[str], start_idx: int, parent_indent: int) -> tuple[list, int]:
    items = []
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        if not line[current_indent:].lstrip().startswith("-"):
            break
        item_indent = current_indent
        item, idx = parse_artifact_item(lines, idx, item_indent)
        items.append(item)
    return items, idx


def parse_loop_check(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    obj = {}
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        key, raw = split_key_value(line.strip())
        if key == "path":
            value = parse_scalar_text(raw)
            if value:
                obj["path"] = value
        idx += 1
    return obj, idx


def parse_parallel_wave(text: str) -> list[str]:
    value = text.strip()
    if not value:
        return []
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [part.strip() for part in inner.split(",") if part.strip()]
    return [part.strip() for part in value.split(",") if part.strip()]


def parse_parallel_stages_inline(text: str) -> list[list[str]]:
    value = text.strip()
    if value == "[]":
        return []
    if not (value.startswith("[") and value.endswith("]")):
        fail("pipeline.parallelStages: must use array-of-arrays syntax")
    waves = []
    depth = 0
    current = []
    for ch in value[1:-1]:
        if ch == "[":
            depth += 1
            if depth == 1:
                current = []
            else:
                current.append(ch)
        elif ch == "]":
            if depth == 0:
                fail("pipeline.parallelStages: has unbalanced brackets")
            depth -= 1
            if depth == 0:
                waves.append(parse_parallel_wave("".join(current)))
            else:
                current.append(ch)
        elif depth > 0:
            current.append(ch)
        else:
            if ch not in " \t,":
                fail("pipeline.parallelStages: must contain only nested stage-id arrays")
    if depth != 0:
        fail("pipeline.parallelStages: has unbalanced brackets")
    return waves


def parse_parallel_stages_block(lines: list[str], start_idx: int, parent_indent: int) -> tuple[list[list[str]], int]:
    waves = []
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        payload = line[current_indent:].lstrip()
        if not payload.startswith("-"):
            break
        fragment = payload[1:].strip()
        if fragment:
            waves.append(parse_parallel_wave(fragment))
            idx += 1
        else:
            nested_idx = next_significant(lines, idx + 1)
            if nested_idx >= len(lines) or indent_of(lines[nested_idx]) <= current_indent:
                waves.append([])
                idx += 1
            else:
                waves.append(parse_parallel_wave(lines[nested_idx].strip()))
                idx = nested_idx + 1
    return waves, idx


def parse_scalar_field(lines: list[str], idx: int, key_indent: int, raw: str, key: str) -> tuple[int, object]:
    if raw in BLOCK_INDICATORS:
        value, next_idx = parse_block_scalar(lines, idx, key_indent)
        return next_idx, value
    if key == "maxIterations":
        value = parse_scalar_text(raw)
        if not value:
            fail("maxIterations must not be empty")
        return idx + 1, parse_int_text(value)
    if key == "required":
        return idx + 1, parse_bool_text(raw)
    return idx + 1, parse_scalar_text(raw)


def parse_list_item(lines: list[str], start_idx: int, item_indent: int, kind: str) -> tuple[dict, int]:
    line = lines[start_idx]
    payload = line[item_indent:].lstrip()
    if not payload.startswith("-"):
        fail(f"{kind} item missing '-' prefix")
    fragment = payload[1:].lstrip()
    item = {}
    idx = start_idx + 1

    def consume_field(key: str, raw: str, line_idx: int, line_indent: int) -> tuple[int, object]:
        if key in {"content", "verification", "status", "id", "stage", "runtime", "agent", "model", "sessionStrategy", "contextBudget", "loopBackTo", "planFile"}:
            return parse_scalar_field(lines, line_idx, line_indent, raw, key)
        if key == "maxIterations":
            return parse_scalar_field(lines, line_idx, line_indent, raw, key)
        if key == "requires" or key == "produces":
            if raw.strip() not in {"", "[]"}:
                item[f"__{key}_shorthand"] = raw.strip()
                return line_idx + 1, []
            value, next_idx = parse_artifact_list(lines, line_idx + 1, line_indent)
            return next_idx, value
        if key == "loopCheck":
            if raw.strip() not in {"", "{}"}:
                fail(f"{kind} loopCheck must use mapping syntax")
            value, next_idx = parse_loop_check(lines, line_idx + 1, line_indent)
            return next_idx, value
        return line_idx + 1, None

    if fragment:
        key, raw = split_key_value(fragment)
        next_idx, value = consume_field(key, raw, start_idx, item_indent)
        if value is not None:
            item[key] = value
        idx = next_idx

    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= item_indent:
            break
        key, raw = split_key_value(line.strip())
        next_idx, value = consume_field(key, raw, idx, current_indent)
        if value is not None:
            item[key] = value
        idx = next_idx

    return item, idx


def parse_items(lines: list[str], start_idx: int, parent_indent: int, kind: str) -> tuple[list[dict], int]:
    items = []
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        payload = line[current_indent:].lstrip()
        if not payload.startswith("-"):
            break
        item, idx = parse_list_item(lines, idx, current_indent, kind)
        items.append(item)
    return items, idx


def parse_pipeline(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    pipeline = {"stages": [], "parallelStages": []}
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        key, raw = split_key_value(line.strip())
        if key == "stages":
            if raw.strip() not in {"", "[]"}:
                fail("pipeline.stages must use list syntax")
            pipeline["stages"], idx = parse_items(lines, idx + 1, current_indent, "stage")
            continue
        if key == "parallelStages":
            if raw.strip():
                pipeline["parallelStages"] = parse_parallel_stages_inline(raw)
                idx += 1
            else:
                pipeline["parallelStages"], idx = parse_parallel_stages_block(lines, idx + 1, current_indent)
            continue
        idx += 1
    return pipeline, idx


def parse_todos(lines: list[str], start_idx: int, parent_indent: int) -> tuple[list[dict], int]:
    return parse_items(lines, start_idx, parent_indent, "todo")


def parse_frontmatter(lines: list[str]) -> dict:
    data = {"name": "", "namespace": "", "execution": "", "pipeline": {"stages": [], "parallelStages": []}, "todos": [], "_pipeline_present": False}
    idx = 0
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        if indent_of(line) != 0:
            idx += 1
            continue
        key, raw = split_key_value(line.strip())
        if key in {"name", "namespace"}:
            data[key] = parse_scalar_text(raw)
            idx += 1
            continue
        if key == "execution":
            value = parse_scalar_text(raw)
            if value and value not in {"simple", "standard", "structured", "orchestration"}:
                fail(f"invalid execution value {value!r}")
            data["execution"] = value
            idx += 1
            continue
        if key == "pipeline":
            if raw.strip() not in {"", "{}"}:
                fail("pipeline must use mapping syntax")
            data["_pipeline_present"] = True
            data["pipeline"], idx = parse_pipeline(lines, idx + 1, 0)
            continue
        if key == "todos":
            if raw.strip() not in {"", "[]"}:
                fail("todos must use list syntax")
            data["todos"], idx = parse_todos(lines, idx + 1, 0)
            continue
        idx += 1
    return data


def normalize_artifacts(items: list[dict]) -> list[dict]:
    merged = []
    index = {}
    for item in items:
        path = item["path"]
        required = bool(item.get("required", True))
        if path in index:
            if required:
                merged[index[path]]["required"] = True
            continue
        index[path] = len(merged)
        merged.append({"path": path, "required": required})
    return merged


def raw_artifacts(items: list[dict]) -> list[dict]:
    return [{"path": item["path"], "required": bool(item.get("required", True))} for item in items]


def normalize_loop_check(obj: dict) -> dict:
    path = parse_scalar_text(str(obj.get("path", ""))) if obj.get("path") is not None else ""
    if path:
        return {"path": path}
    return {}


def as_text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return str(value)

ARTIFACT_TOKEN_RE = re.compile(r"\{\{([^{}]+)\}\}")
ABSOLUTE_ARTIFACT_PATH_RE = re.compile(r"(^/|^~|^[A-Za-z]:[\\/]|^\\\\)")
PARENT_TRAVERSAL_ARTIFACT_PATH_RE = re.compile(r"(^|/)\.\.(/|$)")
ALLOWED_ARTIFACT_TOKENS = {"ARTIFACT_NS", "PLAN_KEY", "STAGE_ID"}


def todo_prefix(todo: dict, ordinal=None) -> str:
    todo_id = as_text(todo.get("id", ""))
    if todo_id:
        return f"todo {todo_id}"
    if ordinal is None:
        ordinal = todo.get("ordinal", "")
    return f"todo {ordinal}"


def stage_prefix(stage: dict, ordinal=None) -> str:
    stage_id = as_text(stage.get("id", ""))
    if stage_id:
        return f"stage {stage_id}"
    if ordinal is None:
        ordinal = stage.get("ordinal", "")
    return f"stage[{ordinal}]"


def validate_artifact_path(context: str, path: str) -> None:
    if not path:
        fail(f"{context}: artifact path must not be empty")
    for token in ARTIFACT_TOKEN_RE.findall(path):
        if token not in ALLOWED_ARTIFACT_TOKENS:
            fail(f"{context}: unsupported token {{{{{token}}}}}")
    if ABSOLUTE_ARTIFACT_PATH_RE.search(path):
        fail(f"{context}: absolute paths are not portable")
    if PARENT_TRAVERSAL_ARTIFACT_PATH_RE.search(path):
        fail(f"{context}: parent traversal is not portable")


def validate_artifact_list(owner_prefix: str, owner: dict, field_name: str, items: list[dict]) -> None:
    if owner.get(f"__{field_name}_shorthand") is not None:
        fail(f"{owner_prefix} {field_name}: invalid artifact shorthand")
    for index, item in enumerate(items):
        item_prefix = f"{owner_prefix} {field_name}[{index}]"
        if item.get("__shorthand") is not None:
            fail(f"{item_prefix}: invalid artifact shorthand")
        path = as_text(item.get("path", ""))
        if not path:
            fail(f"{item_prefix}.path: missing path")
        validate_artifact_path(f"{item_prefix}.path", path)


def validate_stage(stage: dict, ordinal: int) -> None:
    stage_id = as_text(stage.get("id", ""))
    prefix = stage_prefix(stage, ordinal)
    if not stage_id:
        fail(f"{prefix} id: missing stage id")
    if not STAGE_ID_RE.fullmatch(stage_id):
        fail(f"{prefix} id: invalid stage id format")
    plan_file = as_text(stage.get("planFile", ""))
    if plan_file:
        validate_artifact_path(f"{prefix} planFile", plan_file)
        runtime = as_text(stage.get("runtime", ""))
        if runtime and runtime not in ALLOWED_RUNTIMES:
            fail(f"{prefix} runtime: invalid runtime {runtime!r}")
    else:
        runtime = as_text(stage.get("runtime", ""))
        if not runtime:
            fail(f"{prefix} runtime: missing runtime")
        if runtime not in ALLOWED_RUNTIMES:
            fail(f"{prefix} runtime: invalid runtime {runtime!r}")
        agent = as_text(stage.get("agent", ""))
        model = as_text(stage.get("model", ""))
        if not (agent or model):
            fail(f"{prefix} routing: must declare agent or model (or planFile for stage plan delegation)")
    session_strategy = as_text(stage.get("sessionStrategy", ""))
    if session_strategy and session_strategy not in ALLOWED_SESSION_STRATEGIES:
        fail(f"{prefix} sessionStrategy: invalid sessionStrategy {session_strategy!r}")
    context_budget = as_text(stage.get("contextBudget", ""))
    if context_budget and context_budget not in ALLOWED_CONTEXT_BUDGETS:
        fail(f"{prefix} contextBudget: invalid contextBudget {context_budget!r}")
    if "maxIterations" in stage and stage["maxIterations"] != "":
        max_iterations = stage["maxIterations"]
        if not isinstance(max_iterations, int) or max_iterations <= 0:
            fail(f"{prefix} maxIterations: must be a positive integer")
    validate_artifact_list(prefix, stage, "requires", stage.get("requires", []))
    validate_artifact_list(prefix, stage, "produces", stage.get("produces", []))
    loop_check = normalize_loop_check(stage.get("loopCheck", {}))
    if loop_check.get("path"):
        validate_artifact_path(f"{prefix} loopCheck.path", loop_check["path"])


def validate_todo(todo: dict, ordinal: int, stages_by_id: dict) -> None:
    stage = as_text(todo.get("stage", ""))
    runtime = as_text(todo.get("runtime", ""))
    agent = as_text(todo.get("agent", ""))
    model = as_text(todo.get("model", ""))
    session_strategy = as_text(todo.get("sessionStrategy", ""))
    context_budget = as_text(todo.get("contextBudget", ""))
    routing_fields = [runtime, agent, model, session_strategy, context_budget]
    prefix = todo_prefix(todo, ordinal)
    if runtime and runtime not in ALLOWED_RUNTIMES:
        fail(f"{prefix} runtime: invalid runtime {runtime!r}")
    if session_strategy and session_strategy not in ALLOWED_SESSION_STRATEGIES:
        fail(f"{prefix} sessionStrategy: invalid sessionStrategy {session_strategy!r}")
    if context_budget and context_budget not in ALLOWED_CONTEXT_BUDGETS:
        fail(f"{prefix} contextBudget: invalid contextBudget {context_budget!r}")
    if stage:
        if stage not in stages_by_id:
            fail(f"{prefix} stage: unknown stage {stage!r}")
        if runtime and not (agent or model):
            fail(f"{prefix} runtime: overriding a staged runtime requires agent or model")
    elif any(routing_fields):
        if not runtime or not (agent or model):
            fail(f"{prefix} routing: unstaged TODOs require runtime and agent or model")
    validate_artifact_list(prefix, todo, "requires", todo.get("requires", []))
    validate_artifact_list(prefix, todo, "produces", todo.get("produces", []))


def resolve_target(items: list[dict], target: str) -> dict:
    id_matches = [item for item in items if as_text(item.get("id", "")) == target]
    if len(id_matches) > 1:
        fail(f"duplicate todo id {target!r}")
    if len(id_matches) == 1:
        return id_matches[0]
    if target.isdigit():
        ordinal = int(target)
        ordinal_matches = [item for item in items if item.get("ordinal") == ordinal]
        if len(ordinal_matches) != 1:
            fail(f"todo ordinal {target!r} not found")
        return ordinal_matches[0]
    fail(f"todo {target!r} not found")


def resolve_stage_map(stages: list[dict]) -> dict:
    seen = {}
    for ordinal, stage in enumerate(stages, start=1):
        validate_stage(stage, ordinal)
        stage_id = as_text(stage.get("id", ""))
        if stage_id in seen:
            fail(f"{stage_prefix(stage, ordinal)} id: duplicate stage id")
        seen[stage_id] = stage
    return seen


def stage_defaults_for(todo: dict, stages_by_id: dict) -> dict:
    stage_id = as_text(todo.get("stage", ""))
    if not stage_id:
        return {}
    stage = stages_by_id.get(stage_id)
    if stage is None:
        fail(f"{todo_prefix(todo)} stage: unknown stage {stage_id!r}")
    return stage


def validate_parallel_stages(pipeline: dict, stages_by_id: dict) -> None:
    waves = pipeline.get("parallelStages", [])
    if waves is None:
        return
    if not isinstance(waves, list):
        fail("pipeline.parallelStages: must be an array of stage waves")
    seen_stage_ids = set()
    for wave_idx, wave in enumerate(waves, start=1):
        wave_prefix = f"pipeline.parallelStages[{wave_idx}]"
        if not isinstance(wave, list):
            fail(f"{wave_prefix}: must be an array of stage ids")
        for stage_idx, stage_id in enumerate(wave, start=1):
            stage_name = as_text(stage_id)
            if not stage_name:
                fail(f"{wave_prefix}[{stage_idx}]: empty stage id")
            if stage_name not in stages_by_id:
                fail(f"{wave_prefix}[{stage_idx}]: unknown stage {stage_name!r}")
            if stage_name in seen_stage_ids:
                fail(f"{wave_prefix}[{stage_idx}]: duplicate stage {stage_name!r} across parallel waves")
            seen_stage_ids.add(stage_name)


def validate_loop_rules(stage: dict, ordinal: int, stages_by_id: dict, stage_effective_produces: dict) -> None:
    prefix = stage_prefix(stage, ordinal)
    stage_id = as_text(stage.get("id", ""))
    loop_back = as_text(stage.get("loopBackTo", ""))
    max_iterations = stage.get("maxIterations", "")
    loop_check = normalize_loop_check(stage.get("loopCheck", {}))

    if loop_check.get("path"):
        validate_artifact_path(f"{prefix} loopCheck.path", loop_check["path"])

    if loop_back:
        if loop_back not in stages_by_id:
            fail(f"{prefix} loopBackTo: unknown stage {loop_back!r}")
        if not loop_check.get("path"):
            fail(f"{prefix} loopCheck.path: required when loopBackTo is set")
        if not isinstance(max_iterations, int) or max_iterations <= 0:
            fail(f"{prefix} maxIterations: must be a positive integer")
    else:
        if max_iterations != "":
            fail(f"{prefix} maxIterations: requires loopBackTo")
        if loop_check.get("path"):
            fail(f"{prefix} loopCheck.path: requires loopBackTo")

    if loop_check.get("path"):
        required_paths = {
            item["path"]
            for item in stage_effective_produces.get(stage_id, [])
            if item.get("required", True)
        }
        if loop_check["path"] not in required_paths:
            fail(f"{prefix} loopCheck.path: missing from required effective produces")


def validate_pipeline_plan(frontmatter: dict, stages_by_id=None, todos=None) -> None:
    if not frontmatter.get("_pipeline_present"):
        return

    pipeline = frontmatter.get("pipeline", {})
    stages = pipeline.get("stages", [])
    if not stages:
        fail("pipeline.stages: must define at least one stage")

    if stages_by_id is None:
        stages_by_id = resolve_stage_map(stages)
    else:
        for ordinal, stage in enumerate(stages, start=1):
            validate_stage(stage, ordinal)

    validate_parallel_stages(pipeline, stages_by_id)

    if todos is None:
        todos = frontmatter.get("todos", [])

    if todos is not None:
        for ordinal, todo in enumerate(todos, start=1):
            validate_todo(todo, ordinal, stages_by_id)

    stage_effective_produces = {
        as_text(stage.get("id", "")): normalize_artifacts(stage.get("produces", []))
        for stage in stages
    }
    for todo in todos or []:
        stage_id = as_text(todo.get("stage", ""))
        if stage_id:
            stage_effective_produces[stage_id] = normalize_artifacts(
                stage_effective_produces.get(stage_id, []) + todo.get("produces", [])
            )

    for ordinal, stage in enumerate(stages, start=1):
        validate_loop_rules(stage, ordinal, stages_by_id, stage_effective_produces)


def first_non_empty(*values: str) -> str:
    for value in values:
        if as_text(value):
            return as_text(value)
    return ""


def build_raw_metadata(todo: dict) -> dict:
    return {
        "todoId": as_text(todo.get("id", "")),
        "ordinal": todo.get("ordinal", 0),
        "stage": as_text(todo.get("stage", "")),
        "runtime": as_text(todo.get("runtime", "")),
        "agent": as_text(todo.get("agent", "")),
        "model": as_text(todo.get("model", "")),
        "sessionStrategy": as_text(todo.get("sessionStrategy", "")),
        "contextBudget": as_text(todo.get("contextBudget", "")),
        "requires": raw_artifacts(todo.get("requires", [])),
        "produces": raw_artifacts(todo.get("produces", [])),
        "content": as_text(todo.get("content", "")),
        "verification": as_text(todo.get("verification", "")),
        "status": as_text(todo.get("status", "")),
    }


def build_effective_metadata(todo: dict, stage: dict) -> dict:
    requires = normalize_artifacts((stage or {}).get("requires", []) + todo.get("requires", []))
    produces = normalize_artifacts((stage or {}).get("produces", []) + todo.get("produces", []))
    runtime = first_non_empty(todo.get("runtime", ""), (stage or {}).get("runtime", ""))
    agent = first_non_empty(todo.get("agent", ""), (stage or {}).get("agent", ""))
    model = first_non_empty(todo.get("model", ""), (stage or {}).get("model", ""))
    session_strategy = first_non_empty(todo.get("sessionStrategy", ""), (stage or {}).get("sessionStrategy", ""))
    context_budget = first_non_empty(todo.get("contextBudget", ""), (stage or {}).get("contextBudget", ""))
    plan_file = as_text((stage or {}).get("planFile", ""))
    if runtime and runtime not in ALLOWED_RUNTIMES:
        fail(f"todo {todo.get('id', '') or todo.get('ordinal', '')} invalid effective runtime {runtime!r}")
    return {
        "todoId": as_text(todo.get("id", "")),
        "ordinal": todo.get("ordinal", 0),
        "stage": as_text(todo.get("stage", "")),
        "runtime": runtime,
        "agent": agent,
        "model": model,
        "sessionStrategy": session_strategy,
        "contextBudget": context_budget,
        "requires": requires,
        "produces": produces,
        "loopBackTo": as_text((stage or {}).get("loopBackTo", "")),
        "maxIterations": (stage or {}).get("maxIterations", ""),
        "loopCheck": normalize_loop_check((stage or {}).get("loopCheck", {})),
        "planFile": plan_file,
    }


def build_orch_stage(stage: dict, stage_todos: list) -> dict:
    """Map a pipeline stage (+ its inline todos) to the .orch.json stage shape
    that orchestrator.sh consumes. A stage either delegates to a planFile (-> plan)
    or carries inline todos (-> _inlineTodos for the caller to materialize)."""
    out = {"id": as_text(stage.get("id", ""))}
    for key in ("runtime", "agent", "model", "sessionStrategy", "contextBudget"):
        value = as_text(stage.get(key, ""))
        if value:
            out[key] = value
    produces = raw_artifacts(stage.get("produces", []))
    if produces:
        out["outputArtifacts"] = [{"path": item["path"], "required": item["required"]} for item in produces]
        out["artifacts"] = [{"path": item["path"], "required": item["required"]} for item in produces]
    requires = raw_artifacts(stage.get("requires", []))
    if requires:
        out["inputArtifacts"] = [{"path": item["path"]} for item in requires]
    loop_back = as_text(stage.get("loopBackTo", ""))
    if loop_back:
        loop_control = {"loopBackTo": loop_back}
        max_iterations = stage.get("maxIterations", "")
        if isinstance(max_iterations, int):
            loop_control["maxIterations"] = max_iterations
        out["loopControl"] = loop_control
    plan_file = as_text(stage.get("planFile", ""))
    if plan_file:
        out["plan"] = plan_file
    else:
        out["_inlineTodos"] = [
            {
                "id": as_text(todo.get("id", "")),
                "content": as_text(todo.get("content", "")),
                "verification": as_text(todo.get("verification", "")),
                "status": as_text(todo.get("status", "")) or "pending",
            }
            for todo in stage_todos
        ]
    return out


def sanitize_namespace(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]", "_", value)


with open(plan_path, encoding="utf-8") as fh:
    all_lines = fh.read().splitlines()

if not all_lines or all_lines[0].strip() != "---":
    fail("pipeline metadata helpers require YAML frontmatter")

closing = None
for idx in range(1, len(all_lines)):
    if all_lines[idx].strip() == "---":
        closing = idx
        break

if closing is None:
    fail("pipeline metadata helpers require a closing frontmatter delimiter")

frontmatter = parse_frontmatter(all_lines[1:closing])
stages = frontmatter["pipeline"].get("stages", [])
todos = frontmatter.get("todos", [])
for ordinal, todo in enumerate(todos, start=1):
    todo["ordinal"] = ordinal

stages_by_id = resolve_stage_map(stages)
for todo in todos:
    validate_todo(todo, todo["ordinal"], stages_by_id)

if frontmatter.get("_pipeline_present"):
    validate_pipeline_plan(frontmatter, stages_by_id, todos)

if mode == "validate":
    raise SystemExit(0)

if mode == "orch":
    if not frontmatter.get("_pipeline_present"):
        fail("orch mode requires a pipeline block")
    import os
    base = os.path.basename(plan_path)
    for suffix in (".plan.md", ".md"):
        if base.endswith(suffix):
            base = base[: -len(suffix)]
            break
    name = frontmatter.get("name", "") or base
    namespace = frontmatter.get("namespace", "") or sanitize_namespace(base)
    todos_by_stage: dict = {}
    for item in todos:
        todos_by_stage.setdefault(as_text(item.get("stage", "")), []).append(item)
    orch_stages = [
        build_orch_stage(stage, todos_by_stage.get(as_text(stage.get("id", "")), []))
        for stage in stages
    ]
    result = {"name": name, "namespace": namespace, "stages": orch_stages}
    waves = frontmatter["pipeline"].get("parallelStages", [])
    if waves:
        result["parallelStages"] = waves
    print(json.dumps(result, separators=(",", ":"), ensure_ascii=False))
    raise SystemExit(0)

todo = resolve_target(todos, target)
stage = stage_defaults_for(todo, stages_by_id)

if mode == "raw":
    result = build_raw_metadata(todo)
elif mode == "effective":
    result = build_effective_metadata(todo, stage)
else:
    fail(f"unsupported mode {mode!r}")

print(json.dumps(result, separators=(",", ":"), ensure_ascii=False))
PYTHON
}

plan_pipeline_todo_metadata_json() {
  _plan_pipeline_metadata_json "$1" "$2" "raw"
}

plan_pipeline_effective_metadata_json() {
  _plan_pipeline_metadata_json "$1" "$2" "effective"
}

# Emit the full .orch.json-shaped document (name/namespace/stages[]/parallelStages[])
# for a structured orchestration plan. The target argument is ignored.
plan_pipeline_orch_json() {
  _plan_pipeline_metadata_json "$1" "__orch__" "orch"
}

plan_structured_todo_metadata_json() {
  plan_pipeline_todo_metadata_json "$@"
}

plan_structured_effective_metadata_json() {
  plan_pipeline_effective_metadata_json "$@"
}

get_next_todo() {
  local plan_path="$1"
  local format
  format="$(plan_detect_format "$plan_path")" || return 1

  if plan_format_is_yaml "$format"; then
    plan_yaml_frontmatter_op "$plan_path" "get_next"
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

  if plan_format_is_yaml "$format"; then
    plan_mark_todo_done_yaml "$plan_path" "$line_or_content"
  else
    plan_mark_todo_done_at_line "$plan_path" "$line_or_content"
  fi
}

count_todos() {
  local plan_path="$1"
  local format
  format="$(plan_detect_format "$plan_path")" || { printf '0 0\n'; return 1; }

  if plan_format_is_yaml "$format"; then
    plan_yaml_frontmatter_op "$plan_path" "count"
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
# YAML frontmatter plans do not use file-line semantics for get_next_todo's first field; use plan_todo_ordinal_for_next.
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

# plan_path, plan format ('default' or 'yaml'), first field from get_next_todo (line number or YAML ordinal).
plan_todo_ordinal_for_next() {
  local plan_path="$1"
  local format="${2:-default}"
  local next_first_field="$3"

  if plan_format_is_yaml "$format"; then
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

plan_reopen_todo_yaml() {
  local plan_path="$1"
  local todo_content="$2"
  plan_yaml_update_todo_status "$plan_path" "$todo_content" "pending"
}

plan_reopen_todo_cursor() {
  plan_reopen_todo_yaml "$@"
}

plan_reopen_todo_by_format() {
  local plan_path="$1"
  local format="${2:-}"
  local line_or_content="$3"

  if plan_format_is_yaml "$format"; then
    plan_reopen_todo_yaml "$plan_path" "$line_or_content"
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

_ralph_plan_verify_extract_script() {
  local base_dir
  base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$base_dir/../python/plan_todo_extract_verification_commands.py"
}

plan_todo_extract_verification_commands() {
  local todo_text="$1"
  local script
  script="$(_ralph_plan_verify_extract_script)"
  [[ -f "$script" ]] || return 1
  command -v python3 &>/dev/null || return 1
  python3 "$script" "$todo_text"
}

ralph_plan_verify_to_complete_command() {
  local todo_text="$1"
  local script
  script="$(_ralph_plan_verify_extract_script)"
  [[ -f "$script" ]] || return 1
  command -v python3 &>/dev/null || return 1
  python3 "$script" verify-to-complete "$todo_text"
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
  local script_path="$share_dir/../python/plan-todo-consolidate.py"

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
  printf '%s\n' "$base_dir/../python/plan-split.py"
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

ralph_plan_post_verification_command() {
  local todo_text="$1"
  local script
  script="$(_ralph_plan_split_script)"
  [[ -f "$script" ]] || return 1
  command -v python3 &>/dev/null || return 1
  python3 "$script" post-verify-command --todo "$todo_text"
}

plan_frontmatter_verify_command() {
  local plan_path="$1"
  local script
  script="$(_ralph_plan_split_script)"
  [[ -f "$script" ]] || return 1
  command -v python3 &>/dev/null || return 1
  python3 "$script" plan-verify-command --plan "$plan_path"
}
