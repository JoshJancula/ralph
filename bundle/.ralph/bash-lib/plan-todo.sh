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
#   get_next_todo -- default markdown: "file_line|full block" for first open "- [ ]" task, where file_line is the checkbox line; yaml frontmatter: "ordinal|id|content" (id empty when absent).
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
    in_frontmatter && in_todos && /^[[:space:]]+(runtime|agent|model|sessionStrategy|contextBudget|subagents):[[:space:]]/ {
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
import os
import re
import sys

plan_path = sys.argv[1]
target = sys.argv[2]
mode = sys.argv[3]

ALLOWED_RUNTIMES = {"cursor", "claude", "codex", "opencode"}
RALPH_MODES = {"no", "native", "ralph", "hybrid"}
ALLOWED_SESSION_STRATEGIES = {"fresh", "resume", "reset", "compact"}
ALLOWED_CONTEXT_BUDGETS = {"full", "standard", "lean"}
# subagents: inherit keeps today's tool surface (no Task/dispatch tool unless an
# agent profile adds it). on adds the runtime subagent dispatch tool; off strips
# it. Prefer a graph node when work must be resumable, inspectable, attributable,
# or run on a different provider; prefer a subagent for throwaway fan-out where
# only the answer matters and losing it costs nothing but time. Subagent output
# is not checkpointed, so a node that dies redoes all of it. Phase 3 ledger
# attempts must record the resolved value for usage/savings comparisons.
ALLOWED_SUBAGENTS = {"inherit", "on", "off"}
BLOCK_INDICATORS = {"|", "|-", "|+"}
STAGE_ID_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


def fail(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)


def warn(message: str) -> None:
    print(f"Warning: {message}", file=sys.stderr)


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


def strict_keys_enabled(execution: str) -> bool:
    import os

    value = os.environ.get("RALPH_PLAN_STRICT_KEYS", "")
    if value:
        return value.lower() not in {"0", "false", "no", "off"}
    return execution in {"orchestration", "graph"}


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
        if key not in {"path", "required", "schema"}:
            fail(f"unsupported artifact field {key!r}")
        if key == "path":
            value = parse_scalar_text(raw)
            if not value:
                fail("artifact path must not be empty")
            item["path"] = value
        elif key == "schema":
            value = parse_scalar_text(raw)
            if not value:
                fail("artifact schema must not be empty")
            item["schema"] = value
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
        if key not in {"path", "required", "schema"}:
            fail(f"unsupported artifact field {key!r}")
        if key == "path":
            value = parse_scalar_text(raw)
            if not value:
                fail("artifact path must not be empty")
            item["path"] = value
        elif key == "schema":
            value = parse_scalar_text(raw)
            if not value:
                fail("artifact schema must not be empty")
            item["schema"] = value
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


def _scan_bracket_content(text: str, field_name: str) -> str:
    """Return the content between the outermost balanced brackets in text.

    Fails with a named error if the brackets are missing or unbalanced.
    This is the same depth-first scanner used by parse_parallel_stages_inline,
    factored out so parse_string_list can reuse it.
    """
    depth = 0
    start = None
    for i, ch in enumerate(text):
        if ch == "[":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "]":
            if depth == 0:
                fail(f"{field_name}: unbalanced brackets")
            depth -= 1
            if depth == 0:
                return text[start + 1 : i]
    if depth != 0 or start is None:
        fail(f"{field_name}: unbalanced brackets")
    return text[start + 1 :]


def parse_string_list(text: str, lines: list[str], start_idx: int, parent_indent: int, field_name: str) -> tuple[list[str], int]:
    """Parse a list of strings in either inline bracketed form or block dash form.

    Inline form: [a, b, c]
    Block form:
      - a
      - b
      - c

    Empty inline: [] or an empty block both yield an empty list.
    Reuses the bracket scanner already present in parse_parallel_stages_inline.
    """
    value = text.strip()
    if value == "[]":
        return [], start_idx
    if value.startswith("["):
        inner = _scan_bracket_content(value, field_name).strip()
        if not inner:
            return [], start_idx
        return [part.strip() for part in inner.split(",") if part.strip()], start_idx

    items = []
    idx = next_significant(lines, start_idx)
    first_item_indent = None
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if first_item_indent is None:
            if current_indent <= parent_indent:
                break
            if not line[current_indent:].lstrip().startswith("-"):
                break
            first_item_indent = current_indent
        else:
            if current_indent < first_item_indent:
                break
            if current_indent == first_item_indent and not line[current_indent:].lstrip().startswith("-"):
                break
        payload = line[first_item_indent:].lstrip()
        if not payload.startswith("-"):
            break
        fragment = payload[1:].strip()
        if fragment:
            items.append(fragment)
        idx += 1
    return items, idx


def parse_dep_list(text: str, lines: list[str], start_idx: int, parent_indent: int, field_name: str) -> tuple[list, int]:
    """Parse a dependsOn list where each entry is either a plain string or a dict with 'id' and optional 'condition'.

    Block dict form (conditional edge):
      - id: some-stage
        condition: passed

    Block plain form (unconditional edge):
      - some-stage

    Inline form (strings only): [a, b, c]
    """
    value = text.strip()
    if value == "[]":
        return [], start_idx
    if value.startswith("["):
        # Inline form: only simple strings are supported.
        inner = _scan_bracket_content(value, field_name).strip()
        if not inner:
            return [], start_idx
        return [part.strip() for part in inner.split(",") if part.strip()], start_idx

    items: list = []
    idx = next_significant(lines, start_idx)
    first_item_indent = None
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if first_item_indent is None:
            if current_indent <= parent_indent:
                break
            if not line[current_indent:].lstrip().startswith("-"):
                break
            first_item_indent = current_indent
        else:
            if current_indent < first_item_indent:
                break
            if current_indent == first_item_indent and not line[current_indent:].lstrip().startswith("-"):
                break
        payload = line[first_item_indent:].lstrip()
        if not payload.startswith("-"):
            break
        fragment = payload[1:].strip()
        idx += 1
        if not fragment:
            continue
        # Check if this item starts with "id:" making it a dict-form entry.
        kv_key, kv_raw = split_key_value(fragment)
        if kv_key == "id":
            dep_id = parse_scalar_text(kv_raw)
            dep_entry: dict = {"id": dep_id}
            # Consume sub-keys (condition, etc.) at higher indentation.
            while idx < len(lines):
                sub_line = lines[idx]
                if is_blank_or_comment(sub_line):
                    idx += 1
                    continue
                sub_indent = indent_of(sub_line)
                if sub_indent <= first_item_indent:
                    break
                sub_key, sub_raw = split_key_value(sub_line.strip())
                if sub_key == "condition":
                    dep_entry["condition"] = parse_scalar_text(sub_raw)
                # Unknown sub-keys are silently skipped for forward compatibility.
                idx += 1
            items.append(dep_entry)
        else:
            # Plain string entry.
            items.append(fragment)
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
        if key in ("path", "schema"):
            value = parse_scalar_text(raw)
            if value:
                obj[key] = value
        idx += 1
    return obj, idx


def parse_router_block(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    router = {}
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
        if key in ("allowedTargets", "terminalOutcomes"):
            value, next_idx = parse_string_list(raw, lines, idx + 1, current_indent, f"router {key}")
            router[key] = value
            idx = next_idx
            continue
        if key in ("defaultTarget", "onInvalid"):
            value = parse_scalar_text(raw)
            if value:
                router[key] = value
        idx += 1
    return router, idx


def parse_delegation_block(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    """Parse the deliberately small v1 delegation contract.

    This parser does not use a general YAML mapping on purpose: graph plans have
    strict keys, and accepting arbitrary child-policy fields would make the
    frozen policy impossible to audit.
    """
    delegation = {}
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
        if key == "maxChildren":
            delegation[key] = parse_int_text(parse_scalar_text(raw) or "0")
            idx += 1
            continue
        if key not in {"native", "crossRuntime"}:
            fail(f"delegation: unknown field {key!r}")
        if raw.strip() not in {"", "{}"}:
            fail(f"delegation.{key}: must use mapping syntax")
        child = {}
        idx = next_significant(lines, idx + 1)
        while idx < len(lines):
            child_line = lines[idx]
            if is_blank_or_comment(child_line):
                idx += 1
                continue
            child_indent = indent_of(child_line)
            if child_indent <= current_indent:
                break
            child_key, child_raw = split_key_value(child_line.strip())
            if child_key in {"allowedAgents", "allowedRuntimes"}:
                child[child_key], idx = parse_string_list(child_raw, lines, idx + 1, child_indent, f"delegation.{key}.{child_key}")
                continue
            if child_key == "maxParallel":
                child[child_key] = parse_int_text(parse_scalar_text(child_raw) or "0")
            elif child_key == "mode":
                child[child_key] = parse_scalar_text(child_raw)
            else:
                fail(f"delegation.{key}: unknown field {child_key!r}")
            idx += 1
        delegation[key] = child
    return delegation, idx


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
    if key in {"quorum", "minRuntimes"}:
        value = parse_scalar_text(raw)
        if not value:
            fail(f"{key} must not be empty")
        return idx + 1, parse_int_text(value)
    if key in {"required", "acknowledgeSharedMutationRisk"}:
        return idx + 1, parse_bool_text(raw)
    if key == "grader":
        return idx + 1, parse_bool_text(raw)
    return idx + 1, parse_scalar_text(raw)


def parse_list_item(lines: list[str], start_idx: int, item_indent: int, kind: str, execution: str) -> tuple[dict, int]:
    line = lines[start_idx]
    payload = line[item_indent:].lstrip()
    if not payload.startswith("-"):
        fail(f"{kind} item missing '-' prefix")
    fragment = payload[1:].lstrip()
    item = {}
    idx = start_idx + 1

    def consume_field(key: str, raw: str, line_idx: int, line_indent: int) -> tuple[int, object]:
        if key in {"content", "verification", "status", "id", "stage", "runtime", "agent", "model", "sessionStrategy", "contextBudget", "subagents", "type", "policy", "onVoterError", "verdictSchema", "quorum", "minRuntimes", "loopBackTo", "onExhausted", "planFile", "grader", "rubric", "workspaceMode", "setupProfile", "agentGitAccess", "parallelMutation", "acknowledgeSharedMutationRisk", "profile", "overlapOwner", "ownershipRole"}:
            return parse_scalar_field(lines, line_idx, line_indent, raw, key)
        if key == "maxIterations":
            return parse_scalar_field(lines, line_idx, line_indent, raw, key)
        if key == "requires" or key == "produces":
            if raw.strip() not in {"", "[]"}:
                item[f"__{key}_shorthand"] = raw.strip()
                return line_idx + 1, []
            value, next_idx = parse_artifact_list(lines, line_idx + 1, line_indent)
            return next_idx, value
        if key == "dependsOn":
            value, next_idx = parse_dep_list(raw, lines, line_idx + 1, line_indent, f"{kind} dependsOn")
            return next_idx, value
        if key == "writeScopes":
            value, next_idx = parse_string_list(raw, lines, line_idx + 1, line_indent, f"{kind} writeScopes")
            return next_idx, value
        if key == "voters":
            if raw.strip() not in {"", "[]"}:
                fail(f"{kind} voters must use list syntax")
            value, next_idx = parse_items(lines, line_idx + 1, line_indent, "voter", execution)
            return next_idx, value
        if key == "loopCheck":
            if raw.strip() not in {"", "{}"}:
                fail(f"{kind} loopCheck must use mapping syntax")
            value, next_idx = parse_loop_check(lines, line_idx + 1, line_indent)
            return next_idx, value
        if key == "router":
            if raw.strip() not in {"", "{}"}:
                fail(f"{kind} router must use mapping syntax")
            value, next_idx = parse_router_block(lines, line_idx + 1, line_indent)
            return next_idx, value
        if key == "delegation":
            if raw.strip() not in {"", "{}"}:
                fail(f"{kind} delegation must use mapping syntax")
            value, next_idx = parse_delegation_block(lines, line_idx + 1, line_indent)
            return next_idx, value
        if key == "ralphMode":
            owner = item.get("id") or f"{kind} item"
            fail(
                f"ralphMode is not allowed on {kind} {owner}. Tool exposure applies "
                "to the whole run -- declare pipeline.ralphMode once instead"
            )
        if strict_keys_enabled(execution):
            owner = item.get("id") or f"{kind} item"
            fail(f"unknown {kind} field {key!r} on {owner}")
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


def parse_items(lines: list[str], start_idx: int, parent_indent: int, kind: str, execution: str) -> tuple[list[dict], int]:
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
        item, idx = parse_list_item(lines, idx, current_indent, kind, execution)
        items.append(item)
    return items, idx


# Hard ceiling on pipeline.repairRounds.rounds. This is a fixed constant, not
# an authorable field: version 1 defaults to two rounds and operators may
# raise it for a given plan, but never past this bound. Keep the bounded
# repair-epoch macro genuinely bounded rather than trusting authoring input.
REPAIR_ROUNDS_HARD_MAX = 5


def parse_repair_phase_block(lines: list[str], start_idx: int, parent_indent: int, phase_name: str) -> tuple[dict, int]:
    """Parse a singular repairRounds phase mapping (integrate/gate/diagnose/
    reintegrate). Deliberately small field set mirroring the ordinary stage
    fields that matter for a model-free or ordinary-agent graph node."""
    obj: dict = {}
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
        if key in {"runtime", "agent", "model", "content", "verification", "profile", "workspaceMode", "agentGitAccess", "setupProfile"}:
            idx, value = parse_scalar_field(lines, idx, current_indent, raw, key)
            if value not in (None, ""):
                obj[key] = value
            continue
        if key in {"requires", "produces"}:
            if raw.strip() not in {"", "[]"}:
                fail(f"repairRounds.{phase_name}.{key} must use list syntax")
            obj[key], idx = parse_artifact_list(lines, idx + 1, current_indent)
            continue
        fail(f"repairRounds.{phase_name}: unknown field {key!r}")
    return obj, idx


def parse_repair_rounds_block(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    """Parse the pipeline.repairRounds compile-time authoring macro (v2-repair-epochs).

    Expands (elsewhere, at graph-compile time) into a bounded acyclic sequence:
    integrate, gate, then rounds many repeats of diagnose/repair-lanes/
    reintegrate/regate. This parser only captures the authored templates; the
    expansion itself lives in expand_repair_rounds_nodes.
    """
    rr: dict = {"lanes": []}
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
        if key == "id":
            value = parse_scalar_text(raw)
            if value:
                rr["id"] = value
            idx += 1
            continue
        if key == "rounds":
            value = parse_scalar_text(raw)
            rr["rounds"] = parse_int_text(value) if value else 2
            idx += 1
            continue
        if key == "dependsOn":
            rr["dependsOn"], idx = parse_dep_list(raw, lines, idx + 1, current_indent, "repairRounds dependsOn")
            continue
        if key in {"integrate", "gate", "diagnose", "reintegrate"}:
            if raw.strip() not in {"", "{}"}:
                fail(f"repairRounds.{key} must use mapping syntax")
            rr[key], idx = parse_repair_phase_block(lines, idx + 1, current_indent, key)
            continue
        if key == "lanes":
            if raw.strip() not in {"", "[]"}:
                fail("repairRounds.lanes must use list syntax")
            rr["lanes"], idx = parse_items(lines, idx + 1, current_indent, "repair-lane", "graph")
            continue
        fail(f"unknown repairRounds field {key!r}")
    rr.setdefault("rounds", 2)
    return rr, idx


def parse_verification_step(lines: list[str], start_idx: int, item_indent: int) -> tuple[dict, int]:
    """Parse one operator-authored, model-free verification-profile step."""
    line = lines[start_idx]
    payload = line[item_indent:].lstrip()
    if not payload.startswith("-"):
        fail("verificationProfiles step missing '-' prefix")
    fragment = payload[1:].lstrip()
    step: dict = {}
    idx = start_idx + 1

    def consume(key: str, raw: str, line_idx: int, line_indent: int) -> int:
        if key in {"name", "command", "resourceClass"}:
            next_idx, value = parse_scalar_field(lines, line_idx, line_indent, raw, key)
            step[key] = value
            return next_idx
        if key == "timeout":
            value = parse_scalar_text(raw)
            step[key] = parse_int_text(value) if value else 300
            return line_idx + 1
        if key == "continueOnFailure":
            step[key] = parse_bool_text(raw)
            return line_idx + 1
        if key == "requiredArtifacts":
            step[key], next_idx = parse_string_list(
                raw, lines, line_idx + 1, line_indent,
                "verificationProfiles step requiredArtifacts",
            )
            return next_idx
        fail(f"verificationProfiles step: unknown field {key!r}")

    if fragment:
        key, raw = split_key_value(fragment)
        idx = consume(key, raw, start_idx, item_indent)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= item_indent:
            break
        key, raw = split_key_value(line.strip())
        idx = consume(key, raw, idx, current_indent)
    return step, idx


def parse_verification_steps(lines: list[str], start_idx: int, parent_indent: int) -> tuple[list[dict], int]:
    steps: list[dict] = []
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
        step, idx = parse_verification_step(lines, idx, current_indent)
        steps.append(step)
    return steps, idx


def parse_verification_profiles(lines: list[str], start_idx: int, parent_indent: int) -> tuple[list[dict], int]:
    """Parse pipeline.verificationProfiles without requiring a YAML dependency."""
    profiles: list[dict] = []
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        item_indent = indent_of(line)
        if item_indent <= parent_indent:
            break
        payload = line[item_indent:].lstrip()
        if not payload.startswith("-"):
            break
        fragment = payload[1:].lstrip()
        profile: dict = {"steps": []}
        if fragment:
            key, raw = split_key_value(fragment)
            if key != "name":
                fail("verificationProfiles entries must start with name")
            profile["name"] = parse_scalar_text(raw)
        idx += 1
        while idx < len(lines):
            nested = lines[idx]
            if is_blank_or_comment(nested):
                idx += 1
                continue
            current_indent = indent_of(nested)
            if current_indent <= item_indent:
                break
            key, raw = split_key_value(nested.strip())
            if key == "name":
                profile["name"] = parse_scalar_text(raw)
                idx += 1
                continue
            if key == "steps":
                if raw.strip() not in {"", "[]"}:
                    fail("verificationProfiles steps must use list syntax")
                profile["steps"], idx = parse_verification_steps(lines, idx + 1, current_indent)
                continue
            fail(f"verificationProfiles entry: unknown field {key!r}")
        profiles.append(profile)
    return profiles, idx


def parse_pipeline(lines: list[str], start_idx: int, parent_indent: int, execution: str) -> tuple[dict, int]:
    pipeline = {"stages": [], "parallelStages": []}
    if execution == "graph":
        pipeline.update({"maxParallel": 2, "edgeDerivation": "both", "failurePolicy": "drain", "publishMode": "manual"})
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
            pipeline["stages"], idx = parse_items(lines, idx + 1, current_indent, "stage", execution)
            continue
        if key == "parallelStages":
            if raw.strip():
                pipeline["parallelStages"] = parse_parallel_stages_inline(raw)
                idx += 1
            else:
                pipeline["parallelStages"], idx = parse_parallel_stages_block(lines, idx + 1, current_indent)
            continue
        if execution == "graph" and key == "maxParallel":
            value = parse_scalar_text(raw)
            pipeline["maxParallel"] = parse_int_text(value or "2")
            idx += 1
            continue
        if execution == "graph" and key == "edgeDerivation":
            value = parse_scalar_text(raw) or "both"
            if value not in {"declared", "artifacts", "both"}:
                fail("invalid edgeDerivation value")
            pipeline["edgeDerivation"] = value
            idx += 1
            continue
        if execution == "graph" and key == "failurePolicy":
            value = parse_scalar_text(raw) or "drain"
            if value not in {"drain", "cancel"}:
                fail("invalid failurePolicy value")
            pipeline["failurePolicy"] = value
            idx += 1
            continue
        if execution == "graph" and key == "publishMode":
            value = parse_scalar_text(raw) or "manual"
            if value not in {"manual", "on-verified"}:
                fail("invalid publishMode value")
            pipeline["publishMode"] = value
            idx += 1
            continue
        if execution == "graph" and key == "strictEdges":
            pipeline["strictEdges"] = parse_bool_text(raw)
            idx += 1
            continue
        # Tool exposure is a property of the whole run, not of one stage.
        # Mixing modes across stages of a single run means the same repo is
        # brokered two different ways at once, so this is deliberately not a
        # per-stage field. See validate_stage, which rejects it there.
        if key == "ralphMode":
            value = parse_scalar_text(raw) or ""
            if value not in RALPH_MODES:
                fail(
                    "invalid ralphMode value "
                    f"{value!r} (expected one of: {', '.join(sorted(RALPH_MODES))})"
                )
            pipeline["ralphMode"] = value
            idx += 1
            continue
        if execution == "graph" and key == "verificationProfiles":
            if raw.strip() not in {"", "[]"}:
                fail("pipeline.verificationProfiles must use list syntax")
            pipeline["verificationProfiles"], idx = parse_verification_profiles(lines, idx + 1, current_indent)
            continue
        if execution == "graph" and key == "repairRounds":
            if raw.strip() not in {"", "{}"}:
                fail("pipeline.repairRounds must use mapping syntax")
            pipeline["repairRounds"], idx = parse_repair_rounds_block(lines, idx + 1, current_indent)
            continue
        if strict_keys_enabled(execution):
            fail(f"unknown pipeline field {key!r}")
        idx += 1
    return pipeline, idx


def parse_todos(lines: list[str], start_idx: int, parent_indent: int, execution: str) -> tuple[list[dict], int]:
    return parse_items(lines, start_idx, parent_indent, "todo", execution)


def parse_frontmatter(lines: list[str]) -> dict:
    data = {"name": "", "overview": "", "namespace": "", "instructions": "", "isProject": False, "execution": "", "pipeline": {"stages": [], "parallelStages": []}, "todos": [], "_pipeline_present": False}
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
        if key in {"name", "overview", "namespace", "instructions"}:
            data[key] = parse_scalar_text(raw)
            idx += 1
            continue
        if key == "isProject":
            data[key] = parse_bool_text(raw)
            idx += 1
            continue
        if key == "execution":
            value = parse_scalar_text(raw)
            if value and value not in {"simple", "standard", "structured", "orchestration", "graph"}:
                fail(f"invalid execution value {value!r}")
            data["execution"] = value
            idx += 1
            continue
        if key == "pipeline":
            if raw.strip() not in {"", "{}"}:
                fail("pipeline must use mapping syntax")
            data["_pipeline_present"] = True
            data["pipeline"], idx = parse_pipeline(lines, idx + 1, 0, data["execution"])
            continue
        if key == "todos":
            if raw.strip() not in {"", "[]"}:
                fail("todos must use list syntax")
            data["todos"], idx = parse_todos(lines, idx + 1, 0, data["execution"])
            continue
        if strict_keys_enabled(data["execution"]):
            fail(f"unknown frontmatter field {key!r}")
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
    result = []
    for item in items:
        entry = {"path": item["path"], "required": bool(item.get("required", True))}
        schema = as_text(item.get("schema", ""))
        if schema:
            entry["schema"] = schema
        result.append(entry)
    return result


def normalize_loop_check(obj: dict) -> dict:
    path = parse_scalar_text(str(obj.get("path", ""))) if obj.get("path") is not None else ""
    schema = parse_scalar_text(str(obj.get("schema", ""))) if obj.get("schema") is not None else ""
    result = {}
    if path:
        result["path"] = path
    if schema:
        result["schema"] = schema
    return result


def substitute_voter_id_in_artifacts(items: list, voter_id: str) -> list:
    """Return a copy of an artifact list with {{VOTER_ID}} substituted in every path."""
    result = []
    for item in items:
        path = as_text(item.get("path", ""))
        if "{{VOTER_ID}}" in path:
            item = {**item, "path": path.replace("{{VOTER_ID}}", voter_id)}
        result.append(item)
    return result


def graph_stage_producer_id(stage: dict, voter_id: str = "") -> str:
    stage_id = as_text(stage.get("id", ""))
    if voter_id:
        return f"{stage_id}:{voter_id}"
    return stage_id


def build_graph_artifact_maps(stages: list[dict], todos: list[dict]) -> tuple[dict, list[dict]]:
    producers = {}
    external_preconditions = []

    def register_producer(path: str, producer_id: str, context: str) -> None:
        existing = producers.get(path)
        if existing and existing != producer_id:
            fail(f"{context}: duplicate producer for {path!r} from {existing} and {producer_id}")
        producers[path] = producer_id

    for stage in stages:
        stage_id = as_text(stage.get("id", ""))
        for item in stage.get("produces", []):
            path = as_text(item.get("path", ""))
            if not path:
                continue
            register_producer(path, graph_stage_producer_id(stage), f"stage {stage_id}")
        for item in stage.get("requires", []):
            path = as_text(item.get("path", ""))
            if not path or path in producers:
                continue
            external_preconditions.append({"path": path, "consumer": stage_id})

        if as_text(stage.get("type", "")) == "consensus":
            for voter in stage.get("voters", []):
                voter_id = as_text(voter.get("id", ""))
                if not voter_id:
                    continue
                for item in stage.get("produces", []):
                    path = as_text(item.get("path", ""))
                    if not path:
                        continue
                    if "{{VOTER_ID}}" in path:
                        register_producer(
                            path.replace("{{VOTER_ID}}", voter_id),
                            graph_stage_producer_id(stage, voter_id),
                            f"stage {stage_id}",
                        )

    for todo in todos:
        todo_id = as_text(todo.get("id", ""))
        stage_id = as_text(todo.get("stage", ""))
        # Staged TODO produces belong to the stage node; only unstaged TODOs
        # register as their own producer ids.
        producer_id = stage_id or todo_id or f"todo:{todo.get('ordinal', 0)}"
        producer_ctx = f"stage {stage_id}" if stage_id else f"todo {todo_id or todo.get('ordinal', 0)}"
        consumer_id = stage_id or todo_id or f"todo:{todo.get('ordinal', 0)}"
        for item in todo.get("produces", []):
            path = as_text(item.get("path", ""))
            if not path:
                continue
            register_producer(path, producer_id, producer_ctx)
        for item in todo.get("requires", []):
            path = as_text(item.get("path", ""))
            if not path or path in producers:
                continue
            external_preconditions.append({"path": path, "consumer": consumer_id})

    return producers, external_preconditions


VALID_EDGE_CONDITIONS = {"passed", "changes-required", "error"}


def _parse_dep_entry(dep) -> tuple:
    """Parse a dependsOn entry into (dep_id, condition). condition is empty for unconditional edges."""
    if isinstance(dep, dict):
        dep_id = as_text(dep.get("id", ""))
        condition = as_text(dep.get("condition", ""))
        if condition and condition not in VALID_EDGE_CONDITIONS:
            fail(f"invalid edge condition '{condition}' for dependsOn entry {dep_id!r}; must be one of passed, changes-required, error")
        return dep_id, condition
    return as_text(dep), ""


def build_graph_edges(stages: list, todos: list, producers: dict, edge_derivation: str, strict_edges: bool) -> list:
    nodes = []
    node_index = {}
    node_kinds = {}
    declared_by_key = {}
    derived_by_key = {}

    def add_node(node_id: str, kind: str) -> None:
        if not node_id or node_id in node_index:
            return
        node_index[node_id] = len(nodes)
        nodes.append(node_id)
        node_kinds[node_id] = kind

    def edge_key(source: str, target: str, condition: str = "") -> str:
        return f"{source}\0{target}\0{condition}"

    def add_edge(store: dict, source: str, target: str, reason: str, condition: str = "") -> None:
        if not source or not target:
            return
        key = edge_key(source, target, condition)
        edge = store.get(key)
        if edge is None:
            edge = {"from": source, "to": target, "reasons": [], "condition": condition}
            store[key] = edge
        if reason not in edge["reasons"]:
            edge["reasons"].append(reason)

    def add_declared_edge(source: str, target: str, condition: str = "") -> None:
        if edge_derivation == "artifacts":
            return
        add_edge(declared_by_key, source, target, "declared", condition)

    def add_derived_edge(source: str, target: str, path: str) -> None:
        if edge_derivation == "declared":
            return
        add_edge(derived_by_key, source, target, f"artifact:{path}")

    for stage in stages:
        add_node(as_text(stage.get("id", "")), "stage")
    for todo in todos:
        add_node(as_text(todo.get("id", "")), "todo")

    for stage in stages:
        stage_id = as_text(stage.get("id", ""))
        for dep in stage.get("dependsOn", []):
            dep_id, dep_condition = _parse_dep_entry(dep)
            if dep_id:
                add_declared_edge(dep_id, stage_id, dep_condition)
        for item in stage.get("requires", []):
            path = as_text(item.get("path", ""))
            producer_id = as_text(producers.get(path, ""))
            if producer_id:
                add_derived_edge(producer_id, stage_id, path)

    for todo in todos:
        todo_id = as_text(todo.get("id", ""))
        for dep in todo.get("dependsOn", []):
            dep_id, dep_condition = _parse_dep_entry(dep)
            if dep_id:
                add_declared_edge(dep_id, todo_id, dep_condition)
        for item in todo.get("requires", []):
            path = as_text(item.get("path", ""))
            producer_id = as_text(producers.get(path, ""))
            if producer_id:
                add_derived_edge(producer_id, todo_id, path)

    if edge_derivation == "both":
        for key, edge in derived_by_key.items():
            if key in declared_by_key:
                for reason in edge["reasons"]:
                    if reason not in declared_by_key[key]["reasons"]:
                        declared_by_key[key]["reasons"].append(reason)
        edges_by_key = declared_by_key
        for key, edge in derived_by_key.items():
            if key not in edges_by_key:
                edges_by_key[key] = edge
    elif edge_derivation == "declared":
        edges_by_key = declared_by_key
    else:
        edges_by_key = derived_by_key

    adjacency = {node_id: [] for node_id in nodes}
    indegree = {node_id: 0 for node_id in nodes}
    for edge in edges_by_key.values():
        src = edge["from"]
        dst = edge["to"]
        if src not in adjacency:
            adjacency[src] = []
            indegree[src] = 0
            node_index[src] = len(nodes)
            nodes.append(src)
            node_kinds[src] = "unknown"
        if dst not in adjacency:
            adjacency[dst] = []
            indegree[dst] = 0
            node_index[dst] = len(nodes)
            nodes.append(dst)
            node_kinds[dst] = "unknown"
        adjacency[src].append(dst)
        indegree[dst] = indegree.get(dst, 0) + 1

    zero_inbound_nodes = [
        node_id
        for node_id in nodes
        if node_kinds.get(node_id) == "stage" and indegree.get(node_id, 0) == 0
    ]
    if len(zero_inbound_nodes) > 1:
        zero_inbound_text = ", ".join(zero_inbound_nodes)
        if strict_edges:
            fail("zero-inbound nodes: " + zero_inbound_text)
        warn("zero-inbound nodes: " + zero_inbound_text)

    queue = [node_id for node_id in nodes if indegree.get(node_id, 0) == 0]
    # Do not add a hidden sequential fallback edge for zero-inbound nodes; the
    # graph must stay inspectable so operators can see that multiple nodes start
    # together instead of being silently serialized.
    processed = []
    while queue:
        node_id = queue.pop(0)
        processed.append(node_id)
        for nxt in adjacency.get(node_id, []):
            indegree[nxt] -= 1
            if indegree[nxt] == 0:
                queue.append(nxt)

    if len(processed) != len(nodes):
        remaining = [node_id for node_id in nodes if indegree.get(node_id, 0) > 0]
        remaining_set = set(remaining)
        visiting = set()
        visited = set()
        stack = []

        def dfs(node_id: str):
            visiting.add(node_id)
            stack.append(node_id)
            for nxt in adjacency.get(node_id, []):
                if nxt not in remaining_set:
                    continue
                if nxt in visiting:
                    cycle_start = stack.index(nxt)
                    return stack[cycle_start:] + [nxt]
                if nxt not in visited:
                    result = dfs(nxt)
                    if result:
                        return result
            stack.pop()
            visiting.remove(node_id)
            visited.add(node_id)
            return None

        for node_id in remaining:
            if node_id in visited:
                continue
            cycle = dfs(node_id)
            if cycle:
                fail("cycle detected: " + " -> ".join(cycle))
        fail("cycle detected")

    edges = list(edges_by_key.values())
    # Remove the condition key from unconditional edges before output so the
    # schema remains backward-compatible with consumers that do not expect it.
    for _e in edges:
        if not _e.get("condition", ""):
            _e.pop("condition", None)
    edges.sort(key=lambda item: (node_index.get(item["from"], 0), node_index.get(item["to"], 0), item["from"], item["to"], item.get("condition", "")))
    return edges


def as_text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return str(value)

ARTIFACT_TOKEN_RE = re.compile(r"\{\{([^{}]+)\}\}")
ABSOLUTE_ARTIFACT_PATH_RE = re.compile(r"(^/|^~|^[A-Za-z]:[\\/]|^\\\\)")
PARENT_TRAVERSAL_ARTIFACT_PATH_RE = re.compile(r"(^|/)\.\.(/|$)")
ALLOWED_ARTIFACT_TOKENS = {"ARTIFACT_NS", "PLAN_KEY", "STAGE_ID", "VOTER_ID"}


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
        if "schema" in item:
            schema = as_text(item.get("schema", ""))
            if not schema:
                fail(f"{item_prefix}.schema: must be a non-empty string")
            validate_artifact_path(f"{item_prefix}.schema", schema)


def delegation_enabled(policy: dict) -> bool:
    return bool(policy and (
        as_text((policy.get("native") or {}).get("mode", "off")) != "off"
        or as_text((policy.get("crossRuntime") or {}).get("mode", "off")) != "off"
    ))


def validate_delegation(stage: dict, prefix: str, stage_type: str) -> None:
    policy = stage.get("delegation")
    legacy = as_text(stage.get("subagents", ""))
    if policy in (None, "", {}):
        return
    if not isinstance(policy, dict):
        fail(f"{prefix} delegation: must be an object")
    unknown = set(policy) - {"native", "crossRuntime", "maxChildren"}
    if unknown:
        fail(f"{prefix} delegation: unknown fields: {', '.join(sorted(unknown))}")
    max_children = policy.get("maxChildren")
    if not isinstance(max_children, int) or max_children <= 0:
        fail(f"{prefix} delegation.maxChildren: must be a positive integer")
    native = policy.get("native", {"mode": "off"})
    cross = policy.get("crossRuntime", {"mode": "off"})
    if not isinstance(native, dict) or not isinstance(cross, dict):
        fail(f"{prefix} delegation: native and crossRuntime must be objects")
    native_mode = as_text(native.get("mode", "off"))
    cross_mode = as_text(cross.get("mode", "off"))
    if native_mode not in {"off", "read-only"}:
        fail(f"{prefix} delegation.native.mode: must be off or read-only")
    if cross_mode not in {"off", "read-only", "changeset"}:
        fail(f"{prefix} delegation.crossRuntime.mode: must be off, read-only, or changeset")
    for label, value, allowed in (("native", native, {"mode", "allowedAgents", "maxParallel"}), ("crossRuntime", cross, {"mode", "allowedRuntimes", "allowedAgents", "maxParallel"})):
        extra = set(value) - allowed
        if extra:
            fail(f"{prefix} delegation.{label}: unknown fields: {', '.join(sorted(extra))}")
        mode = as_text(value.get("mode", "off"))
        for field in ("allowedAgents", "allowedRuntimes"):
            if field not in value:
                continue
            entries = value[field]
            if not isinstance(entries, list) or not entries or any(not as_text(x) or as_text(x).strip("\"'") == "*" for x in entries):
                fail(f"{prefix} delegation.{label}.{field}: must be a non-empty array without wildcards")
        if mode != "off":
            if not isinstance(value.get("allowedAgents"), list) or not value["allowedAgents"]:
                fail(f"{prefix} delegation.{label}.allowedAgents: required when mode is enabled")
            if not isinstance(value.get("maxParallel"), int) or value["maxParallel"] <= 0:
                fail(f"{prefix} delegation.{label}.maxParallel: must be a positive integer when mode is enabled")
    if cross_mode != "off":
        runtimes = cross.get("allowedRuntimes")
        parent_runtime = as_text(stage.get("runtime", ""))
        if not isinstance(runtimes, list) or not runtimes:
            fail(f"{prefix} delegation.crossRuntime.allowedRuntimes: required when mode is enabled")
        if any(as_text(rt) not in ALLOWED_RUNTIMES for rt in runtimes):
            fail(f"{prefix} delegation.crossRuntime.allowedRuntimes: contains an invalid runtime")
        if parent_runtime and parent_runtime in [as_text(rt) for rt in runtimes]:
            fail(f"{prefix} delegation.crossRuntime.allowedRuntimes: must not include parent runtime {parent_runtime!r}")
        if cross_mode == "changeset" and as_text(stage.get("workspaceMode", "shared") or "shared") not in {"snapshot", "worktree"}:
            fail(f"{prefix} delegation.crossRuntime.mode: changeset requires workspaceMode snapshot or worktree")
    if native_mode != "off" and legacy and legacy not in {"on", "inherit"}:
        fail(f"{prefix} delegation.native: conflicts with legacy subagents {legacy!r}; use subagents: on, inherit, or omit it")
    if legacy == "on" and native_mode == "off":
        fail(f"{prefix} delegation.native: conflicts with legacy subagents: on")
    special = stage_type in {"consensus", "join", "router", "checkpoint", "gate", "integrate", "adjudicator"} or stage.get("grader") is True
    if special and delegation_enabled(policy):
        fail(f"{prefix} delegation: special stages cannot enable delegation")


def resolved_delegation(stage: dict) -> dict:
    """Return the frozen v1 policy; maxDepth is intentionally not authorable."""
    policy = stage.get("delegation") or {}
    native = dict(policy.get("native") or {"mode": "off"})
    cross = dict(policy.get("crossRuntime") or {"mode": "off"})
    if as_text(stage.get("subagents", "")) == "on" and not policy:
        native = {"mode": "read-only"}
    return {"maxDepth": 1, "maxChildren": policy.get("maxChildren", 0), "native": native, "crossRuntime": cross}


def validate_stage(stage: dict, ordinal: int) -> None:
    stage_id = as_text(stage.get("id", ""))
    prefix = stage_prefix(stage, ordinal)
    if not stage_id:
        fail(f"{prefix} id: missing stage id")
    if not STAGE_ID_RE.fullmatch(stage_id):
        fail(f"{prefix} id: invalid stage id format")
    stage_type = as_text(stage.get("type", ""))
    if stage_type and stage_type not in {"agent", "consensus", "join", "router", "checkpoint", "gate", "integrate", "adjudicator"}:
        fail(f"{prefix} type: invalid stage type {stage_type!r}")
    if "ralphMode" in stage:
        fail(
            f"{prefix} ralphMode: not allowed on a stage. Tool exposure applies to "
            "the whole run -- declare pipeline.ralphMode once instead"
        )
    plan_file = as_text(stage.get("planFile", ""))
    if plan_file:
        validate_artifact_path(f"{prefix} planFile", plan_file)
        runtime = as_text(stage.get("runtime", ""))
        if runtime and runtime not in ALLOWED_RUNTIMES:
            fail(f"{prefix} runtime: invalid runtime {runtime!r}")
    else:
        runtime = as_text(stage.get("runtime", ""))
        if stage_type in {"", "agent"} and not runtime:
            fail(f"{prefix} runtime: missing runtime")
        if runtime and runtime not in ALLOWED_RUNTIMES:
            fail(f"{prefix} runtime: invalid runtime {runtime!r}")
        agent = as_text(stage.get("agent", ""))
        model = as_text(stage.get("model", ""))
        if stage_type in {"", "agent"} and not (agent or model):
            fail(f"{prefix} routing: must declare agent or model (or planFile for stage plan delegation)")
    session_strategy = as_text(stage.get("sessionStrategy", ""))
    if session_strategy and session_strategy not in ALLOWED_SESSION_STRATEGIES:
        fail(f"{prefix} sessionStrategy: invalid sessionStrategy {session_strategy!r}")
    grader = stage.get("grader", False)
    rubric = as_text(stage.get("rubric", ""))
    if grader not in (True, False, "", None):
        fail(f"{prefix} grader: must be a boolean")
    if grader is True:
        if not rubric:
            fail(f"{prefix} rubric: required when grader is true")
        validate_artifact_path(f"{prefix} rubric", rubric)
        if session_strategy and session_strategy != "fresh":
            fail(f"{prefix} sessionStrategy: grader stages require fresh")
        if stage.get("sessionResume") is True:
            fail(f"{prefix} sessionResume: grader stages cannot resume writer session")
    elif rubric:
        fail(f"{prefix} rubric: requires grader: true")
    router = stage.get("router")
    if router not in (None, "", {}):
        if not isinstance(router, dict):
            fail(f"{prefix} router: must be an object")
        allowed = router.get("allowedTargets")
        if not isinstance(allowed, list) or not allowed:
            fail(f"{prefix} router.allowedTargets: must be a non-empty array")
        if any(not as_text(item) for item in allowed):
            fail(f"{prefix} router.allowedTargets: entries must be non-empty strings")
        default_target = as_text(router.get("defaultTarget", ""))
        if not default_target:
            fail(f"{prefix} router.defaultTarget: required")
        terminal = router.get("terminalOutcomes") or []
        if terminal not in (None, []):
            if not isinstance(terminal, list):
                fail(f"{prefix} router.terminalOutcomes: must be an array")
            if any(not as_text(item) for item in terminal):
                fail(f"{prefix} router.terminalOutcomes: entries must be non-empty strings")
        on_invalid = as_text(router.get("onInvalid", "fail")) or "fail"
        if on_invalid not in {"fail", "default"}:
            fail(f"{prefix} router.onInvalid: must be fail or default")
        valid_targets = {as_text(item) for item in allowed} | {as_text(item) for item in terminal}
        if default_target not in valid_targets:
            fail(f"{prefix} router.defaultTarget: must appear in allowedTargets or terminalOutcomes")
        overlap = {as_text(item) for item in allowed} & {as_text(item) for item in terminal}
        if overlap:
            fail(f"{prefix} router: allowedTargets and terminalOutcomes must not overlap")
    context_budget = as_text(stage.get("contextBudget", ""))
    if context_budget and context_budget not in ALLOWED_CONTEXT_BUDGETS:
        fail(f"{prefix} contextBudget: invalid contextBudget {context_budget!r}")
    subagents = as_text(stage.get("subagents", ""))
    if subagents and subagents not in ALLOWED_SUBAGENTS:
        fail(f"{prefix} subagents: invalid subagents {subagents!r}")
    workspace_mode = as_text(stage.get("workspaceMode", ""))
    if workspace_mode and workspace_mode not in {"shared", "snapshot", "worktree"}:
        fail(f"{prefix} workspaceMode: must be shared, snapshot, or worktree")
    effective_workspace_mode = workspace_mode or "shared"
    if stage_type == "integrate" and effective_workspace_mode not in {"snapshot", "worktree"}:
        fail(f"{prefix} workspaceMode: integrate nodes require snapshot or worktree")
    git_access = as_text(stage.get("agentGitAccess", ""))
    if git_access and git_access not in {"inherit", "off", "on"}:
        fail(f"{prefix} agentGitAccess: must be inherit, off, or on")
    if git_access == "on" and os.environ.get("RALPH_GRAPH_GIT_SANDBOX_PROVEN", "") != "1":
        fail(f"{prefix} agentGitAccess: on requires a proved runtime sandbox boundary")
    parallel_mutation = as_text(stage.get("parallelMutation", ""))
    if parallel_mutation and parallel_mutation not in {"allow", "deny"}:
        fail(f"{prefix} parallelMutation: must be allow or deny")
    acknowledge_shared = stage.get("acknowledgeSharedMutationRisk", False)
    if acknowledge_shared not in (True, False, "", None):
        fail(f"{prefix} acknowledgeSharedMutationRisk: must be a boolean")
    write_scopes = stage.get("writeScopes", [])
    if write_scopes in (None, ""):
        write_scopes = []
    if not isinstance(write_scopes, list) or any(not as_text(item) for item in write_scopes):
        fail(f"{prefix} writeScopes: must be an array of non-empty project-relative globs")
    for scope in write_scopes:
        scope = as_text(scope)
        parts = scope.split("/")
        if scope.startswith("/") or "\\" in scope or ".." in parts or scope in {".", ""}:
            fail(f"{prefix} writeScopes: unsafe project-relative glob {scope!r}")
        if parts[0] in {".git", ".ralph", ".ralph-workspace"}:
            fail(f"{prefix} writeScopes: Ralph control and Git paths cannot be writable ({scope!r})")
    if effective_workspace_mode in {"snapshot", "worktree"} and not write_scopes and stage_type in {"", "agent", "stage"}:
        # An isolated stage without scopes is a read-only node. This is valid;
        # only nodes that opt into mutation by declaring scopes emit changesets.
        pass
    if effective_workspace_mode == "shared" and write_scopes:
        if parallel_mutation != "allow" or acknowledge_shared is not True:
            fail(f"{prefix} shared mutation requires parallelMutation: allow and acknowledgeSharedMutationRisk: true")
    if stage_type == "integrate" and write_scopes:
        fail(f"{prefix} writeScopes: integrate nodes are scheduler-owned and do not accept agent scopes")
    overlap_owner = as_text(stage.get("overlapOwner", ""))
    ownership_role = as_text(stage.get("ownershipRole", ""))
    if ownership_role and ownership_role not in {"integration", "repair"}:
        fail(f"{prefix} ownershipRole: must be integration or repair")
    if stage_type == "integrate" and ownership_role == "repair":
        fail(f"{prefix} ownershipRole: integrate nodes cannot declare the repair role")
    if overlap_owner and not write_scopes:
        fail(f"{prefix} overlapOwner: requires writeScopes")
    effective_git_access = git_access or ("off" if effective_workspace_mode == "worktree" else "inherit")
    if (effective_workspace_mode == "worktree" and write_scopes and
            effective_git_access == "off" and
            os.environ.get("RALPH_GRAPH_GIT_SANDBOX_PROVEN", "") != "1"):
        fail(f"{prefix} agentGitAccess: off for a mutating worktree requires a proved runtime sandbox boundary")
    setup_profile = as_text(stage.get("setupProfile", ""))
    if setup_profile and not re.fullmatch(r"[A-Za-z0-9._-]+", setup_profile):
        fail(f"{prefix} setupProfile: must contain only letters, digits, dot, underscore, or hyphen")
    validate_delegation(stage, prefix, stage_type)
    if "maxIterations" in stage and stage["maxIterations"] != "":
        max_iterations = stage["maxIterations"]
        if not isinstance(max_iterations, int) or max_iterations <= 0:
            fail(f"{prefix} maxIterations: must be a positive integer")
    quorum = stage.get("quorum", "")
    if quorum != "":
        if not isinstance(quorum, int) or quorum <= 0:
            fail(f"{prefix} quorum: must be a positive integer")
        # Research published in 2026 found correlated errors across AI providers
        # and an agreement-to-correctness Spearman correlation of only 0.20-0.59.
        # Three voters on the same runtime are really one voter. quorum without
        # minRuntimes of distinct providers gives a false sense of consensus.
        warn(
            f"{prefix} quorum: correlated-error research (2026, Spearman r=0.20-0.59) "
            f"shows agreement does not reliably predict correctness. "
            f"quorum requires minRuntimes of N distinct providers to provide independent signal; "
            f"same-runtime voters are correlated and do not count as independent evidence."
        )
        min_runtimes_val = stage.get("minRuntimes", "")
        if min_runtimes_val == "":
            fail(
                f"{prefix} quorum: minRuntimes is required when using quorum policy. "
                f"Three voters on the same runtime are effectively one voter. "
                f"Specify minRuntimes: N to require N distinct runtime providers."
            )
    min_runtimes = stage.get("minRuntimes", "")
    if min_runtimes != "":
        if not isinstance(min_runtimes, int) or min_runtimes <= 0:
            fail(f"{prefix} minRuntimes: must be a positive integer")
    if stage.get("voters") not in (None, ""):
        voters = stage.get("voters", [])
        if not isinstance(voters, list) or not voters:
            fail(f"{prefix} voters: must be a non-empty array")
        # A consensus node with fewer than two voters is a tautology: there is
        # nothing to compare, and the entire value of cross-provider consensus
        # comes from independent disagreement between at least two distinct
        # reviewers.
        if len(voters) < 2:
            fail(f"{prefix} voters: consensus nodes require at least two voters, got {len(voters)}")
        seen_voter_ids: set[str] = set()
        for voter_idx, voter in enumerate(voters, start=1):
            voter_prefix = f"{prefix} voters[{voter_idx}]"
            if not isinstance(voter, dict):
                fail(f"{voter_prefix}: must be an object")
            voter_id = as_text(voter.get("id", ""))
            if not voter_id:
                fail(f"{voter_prefix}.id: missing voter id")
            # Duplicate voter ids would produce two synthetic stages with
            # identical ids, which breaks the artifact map and the ledger.
            if voter_id in seen_voter_ids:
                fail(f"{prefix} voters: duplicate voter id {voter_id!r}")
            seen_voter_ids.add(voter_id)
            for key in ("runtime", "agent", "model", "sessionStrategy", "contextBudget", "subagents"):
                if key in voter and not as_text(voter.get(key, "")):
                    fail(f"{voter_prefix}.{key}: must not be empty")
            voter_subagents = as_text(voter.get("subagents", ""))
            if voter_subagents and voter_subagents not in ALLOWED_SUBAGENTS:
                fail(f"{voter_prefix}.subagents: invalid subagents {voter_subagents!r}")
            validate_delegation({**stage, **voter}, voter_prefix, "consensus")
            # Voters must not delegate to subagents. The consensus result schema
            # records each voter's runtime, agent, and model as provenance, and
            # the entire value of the jury rests on those being an accurate
            # description of what produced the verdict. A voter that delegates to
            # subagents makes that provenance false: the recorded model is not
            # what did the work. Subagent fan-out also adds variance to the one
            # measurement that must be a clean independent sample. Authors who
            # need delegation should use a separate node. This restriction applies
            # only to voters; join nodes and adjudicator stages are ordinary agent
            # nodes and are not covered.
            if voter_subagents == "on":
                fail(
                    f"{prefix} voters[{voter_id}].subagents: voters must not declare subagents on; "
                    f"subagent delegation makes the recorded provenance (runtime, agent, model) "
                    f"inaccurate because the subagent, not the declared model, does the work. "
                    f"Use a separate node for delegation."
                )
        # Validate that quorum policy has at least minRuntimes distinct runtime
        # providers across the voter set.  Three claude voters are really one
        # voter; the correlated-error protection only holds when voters run on
        # independently-implemented model providers.
        if quorum != "" and min_runtimes != "":
            distinct_runtimes: set[str] = set()
            for voter in voters:
                rt = as_text(voter.get("runtime", ""))
                if rt:
                    distinct_runtimes.add(rt)
            if len(distinct_runtimes) < int(min_runtimes):
                fail(
                    f"{prefix} quorum: minRuntimes={min_runtimes} requires at least "
                    f"{min_runtimes} distinct runtime providers, but the voter set only "
                    f"has {len(distinct_runtimes)} distinct runtime(s): "
                    f"{', '.join(sorted(distinct_runtimes))}. "
                    f"Same-runtime voters are correlated and do not provide independent evidence."
                )
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
    subagents = as_text(todo.get("subagents", ""))
    routing_fields = [runtime, agent, model, session_strategy, context_budget, subagents]
    prefix = todo_prefix(todo, ordinal)
    if runtime and runtime not in ALLOWED_RUNTIMES:
        fail(f"{prefix} runtime: invalid runtime {runtime!r}")
    if session_strategy and session_strategy not in ALLOWED_SESSION_STRATEGIES:
        fail(f"{prefix} sessionStrategy: invalid sessionStrategy {session_strategy!r}")
    if context_budget and context_budget not in ALLOWED_CONTEXT_BUDGETS:
        fail(f"{prefix} contextBudget: invalid contextBudget {context_budget!r}")
    if subagents and subagents not in ALLOWED_SUBAGENTS:
        fail(f"{prefix} subagents: invalid subagents {subagents!r}")
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

    on_exhausted = as_text(stage.get("onExhausted", ""))

    if loop_check.get("path"):
        validate_artifact_path(f"{prefix} loopCheck.path", loop_check["path"])
    if loop_check.get("schema"):
        validate_artifact_path(f"{prefix} loopCheck.schema", loop_check["schema"])

    if loop_back:
        if loop_back not in stages_by_id:
            fail(f"{prefix} loopBackTo: unknown stage {loop_back!r}")
        if not loop_check.get("path"):
            fail(f"{prefix} loopCheck.path: required when loopBackTo is set")
        if not isinstance(max_iterations, int) or max_iterations <= 0:
            fail(f"{prefix} maxIterations: must be a positive integer")
        if on_exhausted and on_exhausted not in ("proceed", "fail"):
            fail(f"{prefix} onExhausted: must be 'proceed' or 'fail'")
    else:
        if max_iterations != "":
            fail(f"{prefix} maxIterations: requires loopBackTo")
        if loop_check.get("path"):
            fail(f"{prefix} loopCheck.path: requires loopBackTo")
        if loop_check.get("schema"):
            fail(f"{prefix} loopCheck.schema: requires loopBackTo")
        if on_exhausted:
            fail(f"{prefix} onExhausted: requires loopBackTo")

    if loop_check.get("path"):
        required_paths = {
            item["path"]
            for item in stage_effective_produces.get(stage_id, [])
            if item.get("required", True)
        }
        if loop_check["path"] not in required_paths:
            fail(f"{prefix} loopCheck.path: missing from required effective produces")


def validate_write_scope_conflicts(stages: list[dict]) -> None:
    """Reject unordered overlaps unless one downstream integration/repair owner is explicit."""
    stages_by_id = {as_text(stage.get("id", "")): stage for stage in stages}
    dependencies = {
        as_text(stage.get("id", "")): {
            _parse_dep_entry(item)[0] for item in (stage.get("dependsOn") or []) if _parse_dep_entry(item)[0]
        }
        for stage in stages
    }

    def reaches(start: str, target: str, seen=None) -> bool:
        seen = set() if seen is None else seen
        if start in seen:
            return False
        seen.add(start)
        direct = dependencies.get(start, set())
        return target in direct or any(reaches(item, target, seen) for item in direct)

    def static_prefix(pattern: str) -> str:
        positions = [pattern.find(char) for char in "*?[" if char in pattern]
        end = min(positions) if positions else len(pattern)
        return pattern[:end].rstrip("/")

    def overlaps(left: str, right: str) -> bool:
        a, b = static_prefix(left), static_prefix(right)
        if not a or not b:
            return True
        return a == b or a.startswith(b + "/") or b.startswith(a + "/")

    mutating = [stage for stage in stages if stage.get("writeScopes")]
    for index, left in enumerate(mutating):
        left_id = as_text(left.get("id", ""))
        for right in mutating[index + 1:]:
            right_id = as_text(right.get("id", ""))
            if reaches(left_id, right_id) or reaches(right_id, left_id):
                continue
            for left_scope in left.get("writeScopes", []):
                for right_scope in right.get("writeScopes", []):
                    if overlaps(as_text(left_scope), as_text(right_scope)):
                        owner_id = as_text(left.get("overlapOwner", ""))
                        if owner_id and owner_id == as_text(right.get("overlapOwner", "")):
                            owner = stages_by_id.get(owner_id)
                            role = as_text((owner or {}).get("ownershipRole", ""))
                            owner_type = as_text((owner or {}).get("type", "")) or "agent"
                            owner_is_explicit = role in {"integration", "repair"}
                            owner_matches_type = (
                                (role == "integration" and owner_type == "integrate") or
                                (role == "repair" and owner_type in {"agent", "stage"})
                            )
                            if owner_is_explicit and owner_matches_type and reaches(owner_id, left_id) and reaches(owner_id, right_id):
                                continue
                        fail(
                            f"graph writeScopes overlap on unordered nodes {left_id!r} and {right_id!r}: "
                            f"{left_scope!r} vs {right_scope!r}; assign both to one downstream "
                            "overlapOwner whose ownershipRole is integration or repair"
                        )


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

    profiles = pipeline.get("verificationProfiles", []) or []
    profile_names: set[str] = set()
    for profile_idx, profile in enumerate(profiles, start=1):
        name = as_text(profile.get("name", ""))
        if not name:
            fail(f"pipeline.verificationProfiles[{profile_idx}].name: required")
        if name in profile_names:
            fail(f"pipeline.verificationProfiles: duplicate profile name {name!r}")
        profile_names.add(name)
        steps = profile.get("steps", [])
        if not isinstance(steps, list) or not steps:
            fail(f"pipeline.verificationProfiles[{name}].steps: must be a non-empty array")
        for step_idx, step in enumerate(steps, start=1):
            step_name = as_text(step.get("name", ""))
            command = as_text(step.get("command", ""))
            timeout = step.get("timeout", 300)
            if not step_name or not command:
                fail(f"pipeline.verificationProfiles[{name}].steps[{step_idx}]: name and command are required")
            if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout <= 0:
                fail(f"pipeline.verificationProfiles[{name}].steps[{step_idx}].timeout: must be a positive integer")

    for stage_id, stage in stages_by_id.items():
        owner = as_text(stage.get("overlapOwner", ""))
        if owner and owner not in stages_by_id:
            fail(f"stage {stage_id} overlapOwner: unknown stage {owner!r}")
        if as_text(stage.get("type", "")) == "gate":
            profile = as_text(stage.get("profile", ""))
            if profile and profile not in profile_names:
                fail(f"stage {stage_id} profile: unknown verification profile {profile!r}")

    repair_rounds = pipeline.get("repairRounds") or {}
    for phase_name in ("gate",):
        phase = repair_rounds.get(phase_name) or {}
        if phase:
            profile = as_text(phase.get("profile", ""))
            if profile and profile not in profile_names:
                fail(f"repairRounds.{phase_name}.profile: unknown verification profile {profile!r}")

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

    if frontmatter.get("execution") == "graph":
        validate_write_scope_conflicts(stages)

    frontmatter["_graph_artifact_producers"], frontmatter["_graph_external_preconditions"] = build_graph_artifact_maps(
        stages, todos or []
    )


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
        "subagents": as_text(todo.get("subagents", "")),
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
    subagents = first_non_empty(todo.get("subagents", ""), (stage or {}).get("subagents", "")) or "inherit"
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
        "subagents": subagents,
        "requires": requires,
        "produces": produces,
        "loopBackTo": as_text((stage or {}).get("loopBackTo", "")),
        "maxIterations": (stage or {}).get("maxIterations", ""),
        "loopCheck": normalize_loop_check((stage or {}).get("loopCheck", {})),
        "onExhausted": as_text((stage or {}).get("onExhausted", "")),
        "planFile": plan_file,
    }


def build_orch_stage(stage: dict, stage_todos: list) -> dict:
    """Map a pipeline stage (+ its inline todos) to the .orch.json stage shape
    that orchestrator.sh consumes. A stage either delegates to a planFile (-> plan)
    or carries inline todos (-> _inlineTodos for the caller to materialize)."""
    out = {"id": as_text(stage.get("id", ""))}
    for key in ("runtime", "agent", "model", "sessionStrategy", "contextBudget", "subagents", "agentGitAccess", "parallelMutation", "profile", "overlapOwner", "ownershipRole"):
        value = as_text(stage.get(key, ""))
        if value:
            out[key] = value
    # Keep legacy .orch.json characterization byte-identical: delegation is
    # graph-only policy metadata, not an orchestrator v1 surface.
    if as_text(stage.get("workspaceMode", "")):
        out["workspaceMode"] = as_text(stage.get("workspaceMode", ""))
        if as_text(stage.get("workspaceMode", "")) == "worktree" and "agentGitAccess" not in out:
            out["agentGitAccess"] = "off"
    if as_text(stage.get("setupProfile", "")):
        out["setupProfile"] = as_text(stage.get("setupProfile", ""))
    write_scopes = stage.get("writeScopes", [])
    if isinstance(write_scopes, list) and write_scopes:
        out["writeScopes"] = [as_text(item) for item in write_scopes if as_text(item)]
    if stage.get("acknowledgeSharedMutationRisk") is True:
        out["acknowledgeSharedMutationRisk"] = True
    for key in ("type", "policy", "onVoterError", "verdictSchema"):
        value = as_text(stage.get(key, ""))
        if value:
            out[key] = value
    for key in ("quorum", "minRuntimes"):
        value = stage.get(key, "")
        if value != "":
            out[key] = value
    voters = stage.get("voters", [])
    if isinstance(voters, list) and voters:
        out["voters"] = [
            {
                key: value
                for key, value in {
                    "id": as_text(voter.get("id", "")),
                    "runtime": as_text(voter.get("runtime", "")),
                    "agent": as_text(voter.get("agent", "")),
                    "model": as_text(voter.get("model", "")),
                    "sessionStrategy": as_text(voter.get("sessionStrategy", "")),
                    "contextBudget": as_text(voter.get("contextBudget", "")),
                    "subagents": as_text(voter.get("subagents", "")),
                }.items()
                if value
            }
            for voter in voters
        ]
    depends_on = stage.get("dependsOn")
    if isinstance(depends_on, list) and depends_on:
        out["dependsOn"] = [_parse_dep_entry(item)[0] for item in depends_on if _parse_dep_entry(item)[0]]
    if stage.get("grader") is True:
        out["grader"] = True
        rubric = as_text(stage.get("rubric", ""))
        if rubric:
            out["rubric"] = rubric
    router = stage.get("router")
    if isinstance(router, dict) and router:
        out_router = {}
        allowed = [as_text(item) for item in router.get("allowedTargets", []) if as_text(item)]
        if allowed:
            out_router["allowedTargets"] = allowed
        terminal = [as_text(item) for item in router.get("terminalOutcomes", []) if as_text(item)]
        if terminal:
            out_router["terminalOutcomes"] = terminal
        default_target = as_text(router.get("defaultTarget", ""))
        if default_target:
            out_router["defaultTarget"] = default_target
        on_invalid = as_text(router.get("onInvalid", ""))
        if on_invalid:
            out_router["onInvalid"] = on_invalid
        if out_router:
            out["router"] = out_router
    produces = raw_artifacts(stage.get("produces", []))
    if produces:
        out["outputArtifacts"] = produces
        out["artifacts"] = produces
    requires = raw_artifacts(stage.get("requires", []))
    if requires:
        out["inputArtifacts"] = [
            {key: value for key, value in item.items() if key in {"path", "schema", "required"}}
            for item in requires
        ]
    loop_back = as_text(stage.get("loopBackTo", ""))
    if loop_back:
        loop_control = {"loopBackTo": loop_back}
        max_iterations = stage.get("maxIterations", "")
        if isinstance(max_iterations, int):
            loop_control["maxIterations"] = max_iterations
        loop_check = normalize_loop_check(stage.get("loopCheck", {}))
        if loop_check.get("schema"):
            loop_control["evaluatorSchema"] = loop_check["schema"]
        on_exhausted = as_text(stage.get("onExhausted", ""))
        if on_exhausted:
            loop_control["onExhausted"] = on_exhausted
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
    for key in ("maxParallel", "edgeDerivation", "failurePolicy", "publishMode"):
        value = stage.get(key)
        if value not in (None, ""):
            out[key] = value
    return out


def get_ralph_version() -> str:
    import os
    from pathlib import Path
    import subprocess

    env_version = os.environ.get("RALPH_VERSION", "").strip()
    if env_version:
        return env_version

    repo_root = Path(os.getcwd()).resolve()
    for candidate in (
        repo_root / "bundle" / ".ralph" / "VERSION",
        repo_root / "bundle" / ".ralph" / "version",
        repo_root / "VERSION",
    ):
        if candidate.is_file():
            value = candidate.read_text(encoding="utf-8").strip()
            if value:
                return value

    try:
        value = subprocess.check_output(
            ["git", "-C", str(repo_root), "describe", "--tags", "--always", "--dirty"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if value:
            return value
    except Exception:
        pass

    return "1.0.0"


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
    graph_producers, graph_external_preconditions = build_graph_artifact_maps(stages, todos)
    if frontmatter.get("execution") == "graph":
        result["artifactProducers"] = graph_producers
        if graph_external_preconditions:
            result["externalPreconditions"] = graph_external_preconditions
            warn(
                "external preconditions: "
                + ", ".join(
                    f"{item['path']} (consumer {item['consumer']})" for item in graph_external_preconditions
                )
            )
        result["graphEdges"] = build_graph_edges(
            stages,
            todos,
            graph_producers,
            as_text(frontmatter["pipeline"].get("edgeDerivation", "both")) or "both",
            bool(frontmatter["pipeline"].get("strictEdges", False)),
        )
    for key in ("maxParallel", "edgeDerivation", "failurePolicy", "publishMode", "strictEdges", "ralphMode"):
        value = frontmatter["pipeline"].get(key)
        if value not in (None, ""):
            result[key] = value
    waves = frontmatter["pipeline"].get("parallelStages", [])
    if waves:
        result["parallelStages"] = waves
    print(json.dumps(result, separators=(",", ":"), ensure_ascii=False))
    raise SystemExit(0)


def expand_repair_rounds_nodes(rr: dict) -> tuple[list, list]:
    """Expand a pipeline.repairRounds authoring macro (v2-repair-epochs) into
    synthetic graph nodes + edges, in the same shape build_graph_edges/the
    stage-compile loop emit. Purely additive: never mutates pipeline.stages.

    Bounded acyclic sequence per compiled graph, regardless of the configured
    round count (unused rounds stay in the compiled graph but are unreachable
    and skip-cascade at runtime, never mutated in): an entry integrate + gate,
    then `rounds` repeats of diagnose -> repair lanes (parallel) -> reintegrate
    -> regate. Every regate's passed branch converges on a single "<id>-passed"
    join node so downstream stages have one stable success id regardless of
    which round exits. Only the final round's regate omits a changes-required
    edge, so an exhausted repair epoch fails closed (via the existing
    gate-changes-required-no-edge scheduler path) rather than silently
    succeeding.
    """
    epoch_id = as_text(rr.get("id", "")) or "repair"
    rounds = rr.get("rounds", 2)
    if not isinstance(rounds, int) or isinstance(rounds, bool) or rounds < 0 or rounds > REPAIR_ROUNDS_HARD_MAX:
        fail(f"repairRounds.rounds must be an integer between 0 and {REPAIR_ROUNDS_HARD_MAX}")
    lanes = rr.get("lanes", [])
    if rounds > 0 and not lanes:
        fail("repairRounds.lanes must declare at least one repair lane when rounds > 0")
    lane_ids: list = []
    for lane in lanes:
        lane_id = as_text(lane.get("id", ""))
        if not lane_id:
            fail("repairRounds lane missing id")
        if lane_id in lane_ids:
            fail(f"repairRounds lane id {lane_id!r} is duplicated")
        lane_ids.append(lane_id)

    depends_on = [_parse_dep_entry(item)[0] for item in rr.get("dependsOn", []) if _parse_dep_entry(item)[0]]

    nodes: list = []
    edges: list = []

    def _mk_phase_stage(phase_key: str, node_id: str) -> dict:
        base = dict(rr.get(phase_key, {}) or {})
        base.pop("content", None)
        base.pop("verification", None)
        base["id"] = node_id
        return base

    def _add_edge(src: str, dst: str, condition: str = "") -> None:
        edge = {"from": src, "to": dst, "reasons": ["repair-epoch"]}
        if condition:
            edge["condition"] = condition
        edges.append(edge)

    integrate_id = f"{epoch_id}-integrate"
    gate_id = f"{epoch_id}-gate"
    passed_id = f"{epoch_id}-passed"

    integrate_stage = _mk_phase_stage("integrate", integrate_id)
    integrate_compiled = build_orch_stage(integrate_stage, [])
    integrate_compiled["delegation"] = resolved_delegation(integrate_stage)
    nodes.append({"id": integrate_id, "type": "integrate", "dependsOn": list(depends_on), "derivedFrom": "repair-epoch", "stage": integrate_compiled})
    for dep in depends_on:
        _add_edge(dep, integrate_id)

    gate_stage = _mk_phase_stage("gate", gate_id)
    gate_compiled = build_orch_stage(gate_stage, [])
    gate_compiled["delegation"] = resolved_delegation(gate_stage)
    nodes.append({"id": gate_id, "type": "gate", "dependsOn": [integrate_id], "derivedFrom": "repair-epoch", "stage": gate_compiled})
    _add_edge(integrate_id, gate_id)

    join_stage = build_orch_stage({"id": passed_id, "type": "join"}, [])
    join_stage["delegation"] = resolved_delegation({"id": passed_id})
    nodes.append({"id": passed_id, "type": "join", "dependsOn": [], "derivedFrom": "repair-epoch", "stage": join_stage})
    _add_edge(gate_id, passed_id, "passed")

    prev_gate_id = gate_id
    for n in range(1, rounds + 1):
        diagnose_id = f"{epoch_id}-r{n}-diagnose"
        # Deterministic path convention (v2-feedback-routing): both artifacts
        # live at ids fixed by this compile, so a repair plan can be pointed
        # at their exact paths even though the run-scoped {{ARTIFACT_NS}}
        # token only resolves at dispatch time.
        gate_result_ref = f"artifacts/{{{{ARTIFACT_NS}}}}/gate/{prev_gate_id}/gate-result.json"
        diagnosis_ref = f"artifacts/{{{{ARTIFACT_NS}}}}/diagnose/{diagnose_id}/diagnosis.json"
        diag_stage = _mk_phase_stage("diagnose", diagnose_id)
        if not as_text(diag_stage.get("runtime", "")) or not as_text(diag_stage.get("agent", "")):
            fail("repairRounds.diagnose must declare runtime and agent when rounds > 0")
        diag_content = as_text((rr.get("diagnose", {}) or {}).get("content", "")) or (
            f"Diagnose gate failures from {prev_gate_id} for round {n} of repair epoch {epoch_id!r}. "
            "Run the deterministic path-ownership analyzer first (graph_diagnose.sh / graph_diagnose.py "
            f"analyze against {gate_result_ref}): it maps each failure to its owning write scope and "
            f"repair lane by matching implicated files against declared writeScopes, writing {diagnosis_ref}. "
            "Only reason about a finding yourself when the analyzer marks it ambiguous (its files match more "
            "than one lane's writeScopes); you may then assign it to one of that finding's own candidate "
            "lanes, never to a lane outside its declared write scope. Do not paste raw unbounded log output "
            "into your response -- use the analyzer's bounded failureSummary."
        )
        diag_todo = {"id": f"{diagnose_id}-1", "content": diag_content, "verification": as_text((rr.get("diagnose", {}) or {}).get("verification", "")), "status": "pending"}
        diag_compiled = build_orch_stage(diag_stage, [diag_todo])
        diag_compiled["delegation"] = resolved_delegation(diag_stage)
        nodes.append({"id": diagnose_id, "type": "agent", "dependsOn": [prev_gate_id], "derivedFrom": "repair-epoch", "stage": diag_compiled})
        _add_edge(prev_gate_id, diagnose_id, "changes-required")

        lane_node_ids: list = []
        for lane in lanes:
            lane_id = as_text(lane.get("id", ""))
            if not as_text(lane.get("runtime", "")) or not as_text(lane.get("agent", "")):
                fail(f"repairRounds lane {lane_id!r} must declare runtime and agent")
            lane_content = as_text(lane.get("content", ""))
            if not lane_content:
                fail(f"repairRounds lane {lane_id!r} must declare content: it is the TODO the lane keeps fixing")
            lane_node_id = f"{epoch_id}-r{n}-repair-{lane_id}"
            # Inject the diagnosis and exact gate artifact paths into the
            # reopened repair plan so the lane sees the integrated failing
            # state (via the gate result) plus its own owning findings (via
            # the diagnosis laneAssignments for this exact node id), without
            # widening its declared repair scope.
            lane_content = (
                f"{lane_content}\n\n"
                f"Diagnosis: {diagnosis_ref} (see laneAssignments[{lane_node_id!r}] for the findings you own)\n"
                f"Gate result: {gate_result_ref}\n"
                "You may only change files within your declared writeScopes."
            )
            lane_stage = dict(lane)
            lane_stage.pop("content", None)
            lane_stage.pop("verification", None)
            lane_stage["id"] = lane_node_id
            lane_todo = {"id": f"{lane_node_id}-1", "content": lane_content, "verification": as_text(lane.get("verification", "")), "status": "pending"}
            lane_compiled = build_orch_stage(lane_stage, [lane_todo])
            lane_compiled["delegation"] = resolved_delegation(lane_stage)
            nodes.append({"id": lane_node_id, "type": "agent", "dependsOn": [diagnose_id], "derivedFrom": "repair-epoch", "stage": lane_compiled})
            _add_edge(diagnose_id, lane_node_id)
            lane_node_ids.append(lane_node_id)

        reintegrate_id = f"{epoch_id}-r{n}-reintegrate"
        reint_stage = _mk_phase_stage("reintegrate", reintegrate_id)
        reint_compiled = build_orch_stage(reint_stage, [])
        reint_compiled["delegation"] = resolved_delegation(reint_stage)
        nodes.append({"id": reintegrate_id, "type": "integrate", "dependsOn": list(lane_node_ids), "derivedFrom": "repair-epoch", "stage": reint_compiled})
        for lane_node_id in lane_node_ids:
            _add_edge(lane_node_id, reintegrate_id)

        regate_id = f"{epoch_id}-r{n}-regate"
        regate_stage = _mk_phase_stage("gate", regate_id)
        regate_compiled = build_orch_stage(regate_stage, [])
        regate_compiled["delegation"] = resolved_delegation(regate_stage)
        nodes.append({"id": regate_id, "type": "gate", "dependsOn": [reintegrate_id], "derivedFrom": "repair-epoch", "stage": regate_compiled})
        _add_edge(reintegrate_id, regate_id)
        _add_edge(regate_id, passed_id, "passed")
        # Only the last round omits a changes-required edge out of regate: an
        # exhausted repair epoch fails closed via the scheduler's existing
        # gate-changes-required-no-edge path (see graph-schedule.sh), never a
        # silent success. Earlier rounds route changes-required to the next
        # round's diagnose node.
        if n < rounds:
            prev_gate_id = regate_id

    return nodes, edges


if mode == "graph":
    if not frontmatter.get("_pipeline_present"):
        fail("graph mode requires a pipeline block")
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

    graph_producers, _graph_external_preconditions = build_graph_artifact_maps(stages, todos)
    # Map of consensus stage id -> list of voter ids. Populated below during
    # node expansion and consumed afterwards to rewrite edges that reference
    # the bare consensus root id (which is not a real node after expansion).
    consensus_voter_map: dict = {}
    graph_nodes = []
    for stage in stages:
        stage_id = as_text(stage.get("id", ""))
        stage_type = as_text(stage.get("type", "")) or "agent"
        if stage_type == "consensus":
            voters = stage.get("voters", [])
            voter_id_list = [as_text(v.get("id", "")) for v in voters if as_text(v.get("id", ""))]
            consensus_voter_map[stage_id] = voter_id_list
            for voter in voters:
                voter_id = as_text(voter.get("id", ""))
                if not voter_id:
                    continue
                # Force sessionStrategy=fresh on every voter. A voter that can
                # see another voter's session is not an independent reviewer;
                # the entire value of cross-provider consensus comes from
                # isolation. This mirrors the grader precedent which already
                # requires fresh and forbids resuming the writer session. Do not
                # relax this for symmetry with other node types: the isolation
                # invariant is load-bearing for the correctness of the jury.
                #
                # Force subagents=off on every voter. Subagent delegation makes
                # the recorded provenance (runtime, agent, model) inaccurate
                # because the subagent, not the declared model, does the work,
                # and adds variance to the one measurement that must be a clean
                # independent sample. Validate_stage already rejects subagents=on
                # at parse time; this forced-off here is the defense-in-depth
                # expansion-time guarantee. Do not relax this for symmetry with
                # other node types: voters are not covered by the general
                # subagents field semantics.
                voter_stage = {
                    **stage,
                    "id": f"{stage_id}:{voter_id}",
                    "runtime": as_text(voter.get("runtime", "")) or as_text(stage.get("runtime", "")),
                    "agent": as_text(voter.get("agent", "")) or as_text(stage.get("agent", "")),
                    "model": as_text(voter.get("model", "")) or as_text(stage.get("model", "")),
                    "sessionStrategy": "fresh",
                    "contextBudget": as_text(voter.get("contextBudget", "")) or as_text(stage.get("contextBudget", "")),
                    "subagents": "off",
                    "delegation": {"maxChildren": 0, "native": {"mode": "off"}, "crossRuntime": {"mode": "off"}},
                    "produces": substitute_voter_id_in_artifacts(
                        stage.get("produces", []) or [], voter_id
                    ),
                    "requires": substitute_voter_id_in_artifacts(
                        stage.get("requires", []) or [], voter_id
                    ),
                }
                compiled_voter_stage = build_orch_stage(voter_stage, todos_by_stage.get(stage_id, []))
                compiled_voter_stage["delegation"] = resolved_delegation(voter_stage)
                graph_nodes.append(
                    {
                        "id": f"{stage_id}:{voter_id}",
                        "type": "consensus-voter",
                        "dependsOn": [stage_id],
                        "derivedFrom": "consensus",
                        "stage": compiled_voter_stage,
                    }
                )
            graph_nodes.append(
                {
                    "id": f"{stage_id}:barrier",
                    "type": "consensus-barrier",
                    "dependsOn": [f"{stage_id}:{as_text(voter.get('id', ''))}" for voter in voters if as_text(voter.get("id", ""))],
                    "derivedFrom": "consensus",
                    "stage": build_orch_stage(
                        {
                            **stage,
                            "id": f"{stage_id}:barrier",
                            "type": "join",
                            # Strip voter-specific artifact paths from the barrier.
                            # Each voter node owns its own per-voter produces; the
                            # barrier is a synchronization join and must not claim
                            # to produce artifacts that carry an unresolvable
                            # {{VOTER_ID}} token.
                            "produces": [
                                item
                                for item in (stage.get("produces", []) or [])
                                if "{{VOTER_ID}}" not in as_text(item.get("path", ""))
                            ],
                            "requires": [
                                item
                                for item in (stage.get("requires", []) or [])
                                if "{{VOTER_ID}}" not in as_text(item.get("path", ""))
                            ],
                        },
                        todos_by_stage.get(stage_id, []),
                    ),
                }
            )
            continue
        compiled_stage = build_orch_stage(stage, todos_by_stage.get(stage_id, []))
        compiled_stage["delegation"] = resolved_delegation(stage)
        node = {
            "id": stage_id,
            "type": stage_type,
            "dependsOn": [_parse_dep_entry(item)[0] for item in stage.get("dependsOn", []) if _parse_dep_entry(item)[0]],
            "derivedFrom": "stage",
            "stage": compiled_stage,
        }
        graph_nodes.append(node)

    # Expand the v2-repair-epochs compile-time macro, if declared, into its
    # bounded acyclic node/edge sequence. This never mutates pipeline.stages
    # or the nodes/edges above; it is purely additive.
    repair_rounds_cfg = frontmatter["pipeline"].get("repairRounds")
    repair_epoch_edges: list = []
    if repair_rounds_cfg:
        repair_epoch_nodes, repair_epoch_edges = expand_repair_rounds_nodes(repair_rounds_cfg)
        graph_nodes.extend(repair_epoch_nodes)

    # Every graph node carries a concrete, audit-ready policy in the frozen
    # graph/ledger, including nodes whose source omitted delegation entirely.
    for _node in graph_nodes:
        _node["stage"].setdefault("delegation", resolved_delegation(_node["stage"]))
    graph_nodes.sort(key=lambda item: item["id"])

    raw_edges = build_graph_edges(
        stages,
        todos,
        graph_producers,
        as_text(frontmatter["pipeline"].get("edgeDerivation", "both")) or "both",
        bool(frontmatter["pipeline"].get("strictEdges", False)),
    )
    raw_edges.extend(repair_epoch_edges)
    # Inject synthetic voter->barrier edges for every consensus stage.
    # build_graph_edges only processes the original pipeline.stages list and has
    # no knowledge of the synthetic voter/barrier nodes created during consensus
    # expansion, so these edges are never emitted by the normal edge-builder.
    # Without them the barrier's indegree in the scheduler is 0, causing it to
    # be dispatched immediately (concurrently with its voters) instead of after
    # all voters succeed.
    for _cstage_id, _voter_ids in consensus_voter_map.items():
        for _vid in _voter_ids:
            raw_edges.append(
                {"from": f"{_cstage_id}:{_vid}", "to": f"{_cstage_id}:barrier", "reasons": ["consensus-barrier"]}
            )
    # Rewrite any edge that references a bare consensus root id.
    # - edge.to == consensus root id  -> redirect to <root>:barrier
    # - edge.from == consensus root id -> fan out to each <root>:<voter_id>
    # Both rewrites can apply simultaneously when both endpoints are consensus
    # root ids. Dedup uses the same reason-merging pattern as build_graph_edges.
    rewritten: dict = {}

    def _rewrite_add(src: str, dst: str, reasons: list, condition: str = "") -> None:
        key = f"{src}\0{dst}\0{condition}"
        if key not in rewritten:
            rewritten[key] = {"from": src, "to": dst, "reasons": list(reasons), "condition": condition}
        else:
            for r in reasons:
                if r not in rewritten[key]["reasons"]:
                    rewritten[key]["reasons"].append(r)

    for _edge in raw_edges:
        _src = _edge["from"]
        _dst = _edge["to"]
        _reasons = _edge.get("reasons", [])
        _condition = _edge.get("condition", "")
        # from=consensus_root means the group is upstream; the downstream node
        # must wait for the group's terminal barrier node, not each individual
        # voter. Redirect: consensus_root -> X  becomes  consensus_root:barrier -> X.
        _effective_srcs = [f"{_src}:barrier"] if _src in consensus_voter_map else [_src]
        # to=consensus_root means the group is downstream; each voter individually
        # needs the upstream input before it can run. Fan out:
        # X -> consensus_root  becomes  X -> consensus_root:voter for each voter.
        _effective_dsts = (
            [f"{_dst}:{_vid}" for _vid in consensus_voter_map[_dst]]
            if _dst in consensus_voter_map
            else [_dst]
        )
        for _esrc in _effective_srcs:
            for _edst in _effective_dsts:
                _rewrite_add(_esrc, _edst, _reasons, _condition)

    rewritten_edges = list(rewritten.values())
    # Strip empty condition field from edges before output (backward compat).
    for _re in rewritten_edges:
        if not _re.get("condition", ""):
            _re.pop("condition", None)

    result = {
        "schemaVersion": 1,
        "ralphVersion": get_ralph_version(),
        "name": name,
        "namespace": namespace,
        "maxParallel": frontmatter["pipeline"].get("maxParallel", 2),
        "failurePolicy": frontmatter["pipeline"].get("failurePolicy", "drain"),
        "publishMode": frontmatter["pipeline"].get("publishMode", "manual"),
        "nodes": graph_nodes,
        "edges": rewritten_edges,
    }
    ralph_mode = frontmatter["pipeline"].get("ralphMode", "")
    if ralph_mode:
        result["ralphMode"] = ralph_mode
    verification_profiles = frontmatter["pipeline"].get("verificationProfiles", [])
    if verification_profiles:
        result["verificationProfiles"] = verification_profiles
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

plan_pipeline_graph_json() {
  _plan_pipeline_metadata_json "$1" "__graph__" "graph"
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
    local start_line=0
    local line next_line
    while IFS= read -r line || [[ -n "$line" ]]; do
      line_num=$((line_num + 1))
      if [[ "$capturing" == "0" ]]; then
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]* ]]; then
          block="$line"
          start_line="$line_num"
          capturing=1
        fi
        continue
      fi

      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]* ]] || [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[x\][[:space:]]* ]] || [[ "$line" =~ ^#{1,6}[[:space:]] ]] || [[ "$line" =~ ^---[[:space:]]*$ ]]; then
        printf '%s|%s\n' "$start_line" "$block"
        return 0
      fi

      if [[ -n "${line//[[:space:]]/}" ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
        printf '%s|%s\n' "$start_line" "$block"
        return 0
      fi

      block+=$'\n'"$line"
    done < "$plan_path"
    if [[ "$capturing" == "1" ]]; then
      printf '%s|%s\n' "$start_line" "$block"
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
