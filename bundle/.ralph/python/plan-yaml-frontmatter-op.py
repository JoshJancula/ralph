#!/usr/bin/env python3
"""Operate on a yaml-format plan frontmatter: get_next, count, progress, set_status."""
import json
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
            "id": "",
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
            elif key == "id":
                current["id"] = value
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
        elif key == "id":
            current["id"] = value
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

if operation == "progress":
    # Live plan progress for an in-flight stage: how far the control plan has
    # actually got, and which todo is next. Emitted as JSON so callers merge it
    # without reparsing positional text.
    done = sum(1 for item in todo_items if item.get("status") == "completed")
    current_id = ""
    for item in todo_items:
        if item.get("status") != "completed":
            current_id = item.get("id", "")
            break
    print(json.dumps({
        "completedTodos": done,
        "totalTodos": len(todo_items),
        "currentTodoId": current_id or None,
    }))
    raise SystemExit(0)

if operation == "set_status":
    changed = False
    for item in todo_items:
        if item.get("content") == target_content:
            status_line = item.get("status_line")
            if status_line is None:
                if current["end"] == current["start"]:
                    current["end"] = current["start"]
                insert_line = current["end"] + 1
                indent = "      "
                fm_lines.insert(insert_line, f"{indent}status: {target_status}")
                changed = True
            else:
                fm_lines[status_line] = re.sub(
                    r"^(\s*status:\s*).*",
                    lambda m: m.group(1) + target_status,
                    fm_lines[status_line],
                )
                changed = True
            break
    if not changed:
        raise SystemExit(1)
    new_fm = "\n".join(fm_lines)
    new_text = f"---\n{new_fm}\n---{body}"
    with open(plan_path, "w", encoding="utf-8") as fh:
        fh.write(new_text)
    raise SystemExit(0)

raise SystemExit(1)
