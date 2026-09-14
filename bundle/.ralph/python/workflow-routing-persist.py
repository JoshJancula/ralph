#!/usr/bin/env python3
"""Persist routing selections into a workflow source's YAML frontmatter.

Two modes, both line-based edits that preserve the rest of the file byte for
byte (no YAML library -- Ralph core stays dependency free):

  defaults <runtime> [model]
      Write or replace the top-level ``defaults:`` block.

  stages <stage-id>=<runtime>[,<model>] ...
      Write or replace ``runtime:``/``model:`` keys on the named stages inside
      ``pipeline.stages``.

Both modes are idempotent: an existing key at the same indent is replaced in
place rather than duplicated.

Usage: workflow-routing-persist.py <workflow-path> <out-path> <mode> [args...]
"""
import sys


def die(message: str) -> "None":
    sys.stderr.write("Error: %s\n" % message)
    raise SystemExit(1)


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def is_blank_or_comment(line: str) -> bool:
    stripped = line.strip()
    return not stripped or stripped.startswith("#")


def split_frontmatter(text: str) -> "tuple[list[str], str, str]":
    """Return (frontmatter lines, line ending, body-including-closing-fence)."""
    newline = "\r\n" if "\r\n" in text.split("\n", 1)[0] + "\n" else "\n"
    if not text.startswith("---"):
        die("workflow source has no YAML frontmatter")
    lines = text.split("\n")
    end = None
    for idx in range(1, len(lines)):
        if lines[idx].rstrip("\r") == "---":
            end = idx
            break
    if end is None:
        die("workflow source frontmatter is not terminated")
    fm = [line.rstrip("\r") for line in lines[1:end]]
    rest = "\n".join(lines[end:])
    return fm, newline, rest


def block_end(fm: "list[str]", start: int, parent_indent: int) -> int:
    """Index just past the nested block opened at ``start``."""
    idx = start + 1
    last = start + 1
    while idx < len(fm):
        line = fm[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        if indent_of(line) <= parent_indent:
            break
        idx += 1
        last = idx
    return last


def set_defaults(fm: "list[str]", runtime: str, model: str) -> "list[str]":
    out = list(fm)
    start = None
    for idx, line in enumerate(out):
        if indent_of(line) == 0 and line.strip() == "defaults:":
            start = idx
            break
    block = ["defaults:", "  runtime: %s" % runtime]
    if model:
        block.append("  model: %s" % model)
    if start is None:
        # Insert after kind:/mode: when present so the block reads naturally,
        # else at the top of the frontmatter.
        anchor = 0
        for idx, line in enumerate(out):
            if indent_of(line) == 0 and line.split(":", 1)[0].strip() in ("kind", "mode", "name", "overview"):
                anchor = idx + 1
        return out[:anchor] + block + out[anchor:]
    return out[:start] + block + out[block_end(out, start, 0):]


def find_stage_entries(fm: "list[str]") -> "dict[str, tuple[int, int, int]]":
    """Map stage id -> (entry start index, entry end index, key indent)."""
    stages_idx = None
    stages_indent = 0
    pipeline_idx = None
    for idx, line in enumerate(fm):
        stripped = line.strip()
        if indent_of(line) == 0 and stripped == "pipeline:":
            pipeline_idx = idx
            continue
        if pipeline_idx is not None and stripped == "stages:" and indent_of(line) > 0:
            stages_idx = idx
            stages_indent = indent_of(line)
            break
    if stages_idx is None:
        die("workflow source has no pipeline.stages block")

    entries = {}
    starts = []
    idx = stages_idx + 1
    while idx < len(fm):
        line = fm[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        if indent_of(line) <= stages_indent:
            break
        if line.lstrip(" ").startswith("- "):
            starts.append(idx)
        idx += 1
    limit = idx

    for pos, start in enumerate(starts):
        end = starts[pos + 1] if pos + 1 < len(starts) else limit
        dash_indent = indent_of(fm[start])
        key_indent = dash_indent + 2
        stage_id = ""
        first = fm[start].lstrip(" ")[2:].strip()
        if first.startswith("id:"):
            stage_id = first.split(":", 1)[1].strip().strip("'\"")
        else:
            for probe in range(start, end):
                probe_line = fm[probe].strip()
                if probe_line.startswith("id:") and indent_of(fm[probe]) == key_indent:
                    stage_id = probe_line.split(":", 1)[1].strip().strip("'\"")
                    break
        if stage_id:
            entries[stage_id] = (start, end, key_indent)
    return entries


def set_stage_keys(fm: "list[str]", stage_id: str, runtime: str, model: str) -> "list[str]":
    entries = find_stage_entries(fm)
    if stage_id not in entries:
        die("stage %r not found in pipeline.stages" % stage_id)
    start, end, key_indent = entries[stage_id]
    pad = " " * key_indent

    # Drop any existing runtime:/model: keys at this stage's key indent, along
    # with a nested block they may have opened.
    kept = []
    idx = start
    while idx < end:
        line = fm[idx]
        if indent_of(line) == key_indent and line.strip().split(":", 1)[0] in ("runtime", "model"):
            idx = block_end(fm, idx, key_indent)
            continue
        kept.append(line)
        idx += 1

    inject = ["%sruntime: %s" % (pad, runtime)]
    if model:
        inject.append("%smodel: %s" % (pad, model))
    # Insert right after the entry's id: line so routing sits at the top of the
    # stage, ahead of long instructions blocks.
    at = 1
    for pos, line in enumerate(kept):
        if line.strip().startswith("id:") or (pos == 0 and line.lstrip(" ").startswith("- id:")):
            at = pos + 1
            break
    kept = kept[:at] + inject + kept[at:]
    return fm[:start] + kept + fm[end:]


def main() -> None:
    if len(sys.argv) < 4:
        die("usage: workflow-routing-persist.py <workflow> <out> <defaults|stages> [args...]")
    src, out_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
    args = sys.argv[4:]

    with open(src, encoding="utf-8") as handle:
        text = handle.read()
    fm, newline, rest = split_frontmatter(text)

    if mode == "defaults":
        if not args:
            die("defaults mode requires a runtime")
        fm = set_defaults(fm, args[0], args[1] if len(args) > 1 else "")
    elif mode == "stages":
        if not args:
            die("stages mode requires at least one <stage-id>=<runtime>[,<model>]")
        for spec in args:
            if "=" not in spec:
                die("stage spec %r must be <stage-id>=<runtime>[,<model>]" % spec)
            stage_id, _, value = spec.partition("=")
            runtime, _, model = value.partition(",")
            if not stage_id or not runtime:
                die("stage spec %r must name a stage id and a runtime" % spec)
            fm = set_stage_keys(fm, stage_id, runtime, model)
    else:
        die("unknown mode %r; expected defaults or stages" % mode)

    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(newline.join(["---"] + fm + rest.split("\n")))


if __name__ == "__main__":
    main()
