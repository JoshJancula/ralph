#!/usr/bin/env python3
"""Collapse adjacent trivially related Ralph TODOs."""

from __future__ import annotations

import datetime as _dt
import re
import sys
from pathlib import Path

try:
    import yaml
except Exception:
    yaml = None


OPEN_RE = re.compile(r"^(\s*-\s+\[\s\]\s*)(.*?)(\r?\n?)$")
CHECKED_RE = re.compile(r"^\s*-\s+\[[xX]\]\s+")
TASK_RE = re.compile(
    r"^(Edit|Update|Modify|Change|Adjust|Refactor|Document|Test)\s+(.+?)\s+to\s+(.+)$",
    re.IGNORECASE,
)


def log(log_path: Path, message: str) -> None:
    if str(log_path) == "/dev/null":
        return
    log_path.parent.mkdir(parents=True, exist_ok=True)
    stamp = _dt.datetime.now().isoformat(timespec="seconds")
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(f"{stamp}: {message}\n")


def parse_merge_key(text: str) -> tuple[str, str, str] | None:
    match = TASK_RE.match(text.strip())
    if not match:
        return None
    verb, noun, action = match.groups()
    key = f"{verb.lower()} {re.sub(r'\s+', ' ', noun.strip()).lower()}"
    lead = f"{verb} {noun.strip()}"
    return key, lead, action.strip()


def merge_items(items: list[tuple[str, str, str]]) -> tuple[list[str], int]:
    merged: list[str] = []
    merge_count = 0
    index = 0

    while index < len(items):
        prefix, body, newline = items[index]
        parsed = parse_merge_key(body)
        if parsed is None:
            merged.append(f"{prefix}{body}{newline}")
            index += 1
            continue

        key, lead, action = parsed
        group = [(prefix, body, newline, lead, action)]
        cursor = index + 1
        while cursor < len(items) and len(group) < 3:
            next_prefix, next_body, next_newline = items[cursor]
            next_parsed = parse_merge_key(next_body)
            if next_parsed is None or next_parsed[0] != key:
                break
            group.append((next_prefix, next_body, next_newline, next_parsed[1], next_parsed[2]))
            cursor += 1

        if len(group) == 1:
            merged.append(f"{prefix}{body}{newline}")
            index += 1
            continue

        first_prefix, _, first_newline, first_lead, first_action = group[0]
        actions = [first_action] + [entry[4] for entry in group[1:]]
        merged.append(f"{first_prefix}{first_lead}: {'; '.join(actions)}{first_newline}")
        merge_count += 1
        index += len(group)

    return merged, merge_count


def consolidate_markdown(content: str) -> tuple[str, int]:
    lines = content.splitlines(keepends=True)
    output: list[str] = []
    pending: list[tuple[str, str, str]] = []
    total_merges = 0

    def flush_pending() -> None:
        nonlocal total_merges
        merged, count = merge_items(pending)
        output.extend(merged)
        total_merges += count
        pending.clear()

    for line in lines:
        open_match = OPEN_RE.match(line)
        if open_match:
            pending.append((open_match.group(1), open_match.group(2), open_match.group(3)))
            continue

        if pending:
            flush_pending()
        output.append(line)

    if pending:
        flush_pending()

    return "".join(output), total_merges


def consolidate_cursor(content: str) -> tuple[str, int]:
    if not content.startswith("---"):
        return consolidate_markdown(content)

    parts = content.split("---", 2)
    if len(parts) < 3:
        return content, 0

    frontmatter = parts[1]
    body = parts[2]
    try:
        data = yaml.safe_load(frontmatter)
    except Exception:
        return content, 0

    todos = data.get("todos") if isinstance(data, dict) else None
    if not isinstance(todos, list):
        return content, 0

    total_merges = 0
    new_todos: list[object] = []
    pending: list[dict] = []

    def flush_pending() -> None:
        nonlocal total_merges
        index = 0
        while index < len(pending):
            todo = pending[index]
            content_value = str(todo.get("content", ""))
            parsed = parse_merge_key(content_value)
            if parsed is None:
                new_todos.append(todo)
                index += 1
                continue
            key, lead, action = parsed
            group = [(todo, lead, action)]
            cursor = index + 1
            while cursor < len(pending) and len(group) < 3:
                next_todo = pending[cursor]
                next_parsed = parse_merge_key(str(next_todo.get("content", "")))
                if next_parsed is None or next_parsed[0] != key:
                    break
                group.append((next_todo, next_parsed[1], next_parsed[2]))
                cursor += 1
            if len(group) == 1:
                new_todos.append(todo)
                index += 1
                continue
            merged_todo = dict(group[0][0])
            merged_todo["content"] = f"{group[0][1]}: {'; '.join(item[2] for item in group)}"
            new_todos.append(merged_todo)
            total_merges += 1
            index += len(group)
        pending.clear()

    for todo in todos:
        if isinstance(todo, dict) and todo.get("status") != "completed":
            pending.append(todo)
            continue
        flush_pending()
        new_todos.append(todo)
    flush_pending()

    if total_merges == 0:
        return content, 0

    data["todos"] = new_todos
    return "---\n" + yaml.safe_dump(data, sort_keys=False, width=2048) + "---" + body, total_merges


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: plan-todo-consolidate.py <plan-path> <log-path>", file=sys.stderr)
        return 2

    plan_path = Path(sys.argv[1])
    log_path = Path(sys.argv[2])

    if yaml is None:
        print("Warning: todo consolidation requires PyYAML (missing); skipping", file=sys.stderr)
        log(log_path, "PyYAML not found, consolidation skipped")
        return 0

    original = plan_path.read_text(encoding="utf-8")
    if original.startswith("---") and re.search(r"(?m)^\s*todos:", original.split("---", 2)[1] if len(original.split("---", 2)) > 1 else ""):
        updated, merge_count = consolidate_cursor(original)
    else:
        updated, merge_count = consolidate_markdown(original)

    if updated != original:
        plan_path.write_text(updated, encoding="utf-8")

    log(log_path, f"todo consolidation complete: merged {merge_count} group(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
