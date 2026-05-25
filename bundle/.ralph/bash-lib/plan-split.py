#!/usr/bin/env python3
"""Classify and normalize Ralph executable Markdown TODO blocks."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional


CHECK_RE = re.compile(r"^(\s*)-\s+\[([ xX])\]\s*(.*)$")
HEADING_RE = re.compile(r"^#{1,6}\s+")
FILE_RE = re.compile(r"(?:^|[\s`'\"(])([A-Za-z0-9_./-]+\.[A-Za-z0-9][A-Za-z0-9_.-]*)")


@dataclass
class Todo:
    start: int
    end: int
    checked: bool
    line: str
    block: List[str]

    @property
    def text(self) -> str:
        first = CHECK_RE.sub(r"\3", self.block[0]).strip()
        rest = [line.strip() for line in self.block[1:] if line.strip()]
        return "\n".join([first] + rest)

    @property
    def continuation_lines(self) -> int:
        return sum(1 for line in self.block[1:] if line.strip())

    @property
    def bytes(self) -> int:
        return len("\n".join(self.block).encode("utf-8"))


def parse_markdown(lines: List[str]) -> List[Todo]:
    todos: List[Todo] = []
    current: Optional[Todo] = None

    for idx, line in enumerate(lines):
        m = CHECK_RE.match(line)
        starts_boundary = bool(m or HEADING_RE.match(line) or re.match(r"^---\s*$", line))
        if current is not None and starts_boundary:
            current.end = idx
            todos.append(current)
            current = None
        if m:
            current = Todo(start=idx, end=idx + 1, checked=m.group(2).lower() == "x", line=line, block=[line])
            continue
        if current is not None:
            if line.strip() and not line.startswith((" ", "\t")):
                current.end = idx
                todos.append(current)
                current = None
            else:
                current.block.append(line)

    if current is not None:
        current.end = len(lines)
        todos.append(current)
    return todos


def file_refs(text: str) -> List[str]:
    refs: List[str] = []
    seen = set()
    for match in FILE_RE.finditer(text):
        ref = match.group(1).strip(".,:;)")
        if ref not in seen and "/" in ref or ref.endswith((".sh", ".py", ".ts", ".tsx", ".js", ".json", ".md")):
            seen.add(ref)
            refs.append(ref)
    return refs


def extract_commands(text: str) -> List[str]:
    commands: List[str] = []
    for line in text.splitlines():
        m = re.match(r"^\s*(?:Verification|Run|Command|Check)\s*:\s*(.+\S)\s*$", line, re.I)
        if m:
            commands.append(m.group(1).strip())
    for candidate in re.findall(r"`([^`]+)`", text):
        if looks_like_command(candidate):
            commands.append(candidate.strip())
    deduped: List[str] = []
    seen = set()
    for command in commands:
        if command not in seen:
            seen.add(command)
            deduped.append(command)
    return deduped


def looks_like_command(command: str) -> bool:
    command = command.strip()
    if not command:
        return False
    first = command.split(None, 1)[0]
    return first in {
        "bash",
        "bats",
        "npm",
        "npx",
        "pnpm",
        "yarn",
        "make",
        "pytest",
        "cargo",
        "go",
        "node",
        "python",
        "python3",
        "uv",
    } or first.startswith("./")


def direct_allowed(command: str) -> bool:
    try:
        parts = shlex.split(command)
    except ValueError:
        return False
    if not parts:
        return False
    joined = " ".join(parts)
    blocked = {"rm", "mv", "cp", "curl", "wget", "ssh", "scp", "docker", "kubectl", "git"}
    if parts[0] in blocked or any(token in joined for token in (";", "&&", "||", "|", ">", "<", "$(", "`")):
        return False
    if parts[0] == "npm" and len(parts) >= 2:
        if parts[1] == "test":
            return True
        if parts[1] == "run":
            return any(word in joined for word in ("test", "build", "check", "lint", "tsc", "vitest", "jest"))
        return False
    if parts[0] in {"bats", "pytest", "cargo", "go", "make", "npx", "pnpm", "yarn", "node", "python", "python3", "uv"}:
        return any(word in joined for word in ("test", "bats", "build", "check", "lint", "tsc", "vitest", "jest", "pytest"))
    if parts[0] == "bash":
        return any(word in joined for word in ("test", "bats", "validate", "check", "build"))
    if parts[0].startswith("./"):
        return any(word in joined for word in ("test", "bats", "validate", "check", "build"))
    return False


def classify(todo: Todo, max_bytes: int, max_cont: int, max_refs: int) -> dict:
    text = todo.text
    refs = file_refs(text)
    commands = extract_commands(text)
    lower = text.lower()
    implementation = bool(re.search(r"\b(add|update|implement|fix|create|modify|refactor|wire|remove|replace)\b", lower))
    verification_words = bool(re.search(r"\b(test|build|check|lint|verify|validate|bats|pytest|vitest|jest)\b", lower))
    command_only = bool(commands) and not implementation and verification_words

    status = "ok"
    reasons: List[str] = []
    if command_only and all(direct_allowed(command) for command in commands):
        status = "verification_only"
    elif todo.bytes > max_bytes or todo.continuation_lines > max_cont or len(refs) > max_refs:
        status = "too_broad"
        if todo.bytes > max_bytes:
            reasons.append(f"bytes>{max_bytes}")
        if todo.continuation_lines > max_cont:
            reasons.append(f"continuation_lines>{max_cont}")
        if len(refs) > max_refs:
            reasons.append(f"file_refs>{max_refs}")
    elif todo.continuation_lines == 0 and len(refs) <= 1 and commands:
        status = "too_small"

    return {
        "line": todo.start + 1,
        "status": status,
        "bytes": todo.bytes,
        "continuation_lines": todo.continuation_lines,
        "file_refs": refs,
        "commands": commands,
        "reasons": reasons,
        "text": text,
    }


def split_children(todo: Todo) -> List[str]:
    parent = CHECK_RE.sub(r"\3", todo.block[0]).strip()
    parent_id = f"line-{todo.start + 1}"
    children: List[str] = []
    verification = ""
    for line in todo.block[1:]:
        stripped = re.sub(r"^[-*]\s+", "", line.strip())
        if re.match(r"^(Verification|Run|Check):", stripped, re.I):
            verification = stripped
            break
    raw_items: List[str] = []
    for line in todo.block[1:]:
        stripped = re.sub(r"^[-*]\s+", "", line.strip())
        stripped = re.sub(r"^\d+[.)]\s+", "", stripped)
        if not stripped or stripped == verification:
            continue
        if len(stripped) < 6:
            continue
        raw_items.append(stripped)
    for offset in range(0, len(raw_items), 3):
        group = raw_items[offset : offset + 3]
        if len(group) == 1:
            objective = group[0]
        else:
            objective = "Complete this coherent slice: " + "; ".join(group)
        child = f"- [ ] {objective}"
        meta = f"  - Ralph split parent: {parent_id} - {parent}"
        if verification:
            child += "\n" + meta + "\n  - " + verification
        else:
            child += "\n" + meta
        children.append(child)
    if len(children) < 2:
        summary = parent
        if verification:
            summary = f"{summary}. {verification}"
        return [f"- [ ] {summary}\n  - Ralph split parent: {parent_id} - {parent}"]
    return children


def normalize(lines: List[str], infos: List[dict], todos: List[Todo]) -> List[str]:
    broad_lines = {info["line"] for info in infos if info["status"] == "too_broad"}
    if not broad_lines:
        return lines
    out: List[str] = []
    cursor = 0
    by_line = {todo.start + 1: todo for todo in todos}
    for line_no in sorted(broad_lines):
        todo = by_line[line_no]
        out.extend(lines[cursor : todo.start])
        out.extend(split_children(todo))
        cursor = todo.end
    out.extend(lines[cursor:])
    return out


def command_direct(todo_text: str) -> int:
    dummy = Todo(0, 1, False, f"- [ ] {todo_text}", [f"- [ ] {todo_text}"])
    info = classify(dummy, int(os.getenv("RALPH_PLAN_MAX_TODO_BYTES", "1800")), int(os.getenv("RALPH_PLAN_MAX_TODO_CONTINUATION_LINES", "6")), int(os.getenv("RALPH_PLAN_MAX_FILE_REFS_PER_TODO", "5")))
    if info["status"] != "verification_only":
        return 1
    for command in info["commands"]:
        if direct_allowed(command):
            print(command)
            return 0
    return 1


def load_plan(path: str) -> List[str]:
    return Path(path).read_text(encoding="utf-8").splitlines()


def classify_plan(path: str) -> tuple[List[str], List[Todo], List[dict]]:
    lines = load_plan(path)
    todos = parse_markdown(lines)
    max_bytes = int(os.getenv("RALPH_PLAN_MAX_TODO_BYTES", "1800"))
    max_cont = int(os.getenv("RALPH_PLAN_MAX_TODO_CONTINUATION_LINES", "6"))
    max_refs = int(os.getenv("RALPH_PLAN_MAX_FILE_REFS_PER_TODO", "5"))
    infos = [classify(todo, max_bytes, max_cont, max_refs) for todo in todos if not todo.checked]
    return lines, todos, infos


def do_preflight(args: argparse.Namespace) -> int:
    lines, todos, infos = classify_plan(args.plan)
    broad = [info for info in infos if info["status"] == "too_broad"]
    verify = [info for info in infos if info["status"] == "verification_only"]
    for info in broad:
        print(
            f"Ralph plan preflight: line {info['line']} is too_broad "
            f"(bytes={info['bytes']} continuation_lines={info['continuation_lines']} file_refs={len(info['file_refs'])}; "
            f"reasons={','.join(info['reasons']) or 'heuristic'}).",
            file=sys.stderr,
        )
    for info in verify:
        print(f"Ralph plan preflight: line {info['line']} is verification_only.", file=sys.stderr)
    if args.mode == "fail" and broad:
        return 2
    if args.mode == "rewrite" and broad:
        new_lines = normalize(lines, infos, todos)
        target = Path(args.out or args.plan)
        target.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
        print(f"Ralph plan preflight: rewrote {len(broad)} broad TODO(s) in {target}.", file=sys.stderr)
    return 0


def do_split(args: argparse.Namespace) -> int:
    lines, todos, infos = classify_plan(args.plan)
    if args.json:
        print(json.dumps({"plan": args.plan, "todos": infos}, indent=2))
        return 0
    new_lines = normalize(lines, infos, todos)
    rendered = "\n".join(new_lines) + "\n"
    if args.in_place:
        Path(args.plan).write_text(rendered, encoding="utf-8")
    elif args.out:
        Path(args.out).write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    pre = sub.add_parser("preflight")
    pre.add_argument("--plan", required=True)
    pre.add_argument("--mode", choices=["warn", "rewrite", "fail"], default="warn")
    pre.add_argument("--out")
    split = sub.add_parser("split")
    split.add_argument("--plan", required=True)
    split.add_argument("--out")
    split.add_argument("--in-place", action="store_true")
    split.add_argument("--json", action="store_true")
    direct = sub.add_parser("direct-command")
    direct.add_argument("--todo", required=True)
    args = parser.parse_args(argv)
    if args.cmd == "preflight":
        return do_preflight(args)
    if args.cmd == "split":
        return do_split(args)
    if args.cmd == "direct-command":
        return command_direct(args.todo)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
