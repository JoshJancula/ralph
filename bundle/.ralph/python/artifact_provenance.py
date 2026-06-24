#!/usr/bin/env python3
"""Ralph stdlib provenance checker for handoff and review artifacts."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any

from artifact_json_schema import expand_artifact_tokens, resolve_project_path

PROVENANCE_MODES = frozenset({"required", "optional", "none"})
DEFAULT_PROVENANCE = "optional"

PARENT_TRAVERSAL_RE = re.compile(r"(^|/)\.\.(/|$)")

# Markdown: "- cite: path:line" or "- cite: path:line \"excerpt\""
# Also accepts inline `cite:path:line` or `cite:path:line "excerpt"`
MD_CITE_LINE_RE = re.compile(
    r"^\s*-\s+cite:\s+(?P<ref>.+?)\s*$",
    re.IGNORECASE,
)
MD_CITE_INLINE_RE = re.compile(
    r"cite:(?P<ref>[^\s`]+(?:\s+\"[^\"\\]*(?:\\.[^\"\\]*)*\")?)",
    re.IGNORECASE,
)

FILE_CITE_RE = re.compile(
    r"^(?P<path>[^:]+):(?P<line>\d+)(?:\s+\"(?P<excerpt>(?:[^\"\\]|\\.)*)\")?$"
)
ARTIFACT_HEADING_CITE_RE = re.compile(
    r"^(?P<path>[^#]+)#(?P<heading>.+)$"
)
ARTIFACT_POINTER_CITE_RE = re.compile(
    r"^(?P<path>[^#]+)#(?P<pointer>/.*)$"
)

ARTIFACT_LIST_FIELDS = ("artifacts", "outputArtifacts")


class ProvenanceError(Exception):
    def __init__(self, message: str, *, location: str = "") -> None:
        super().__init__(message)
        self.message = message
        self.location = location


def normalize_text(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip())


def default_provenance_mode(raw: Any) -> str:
    if raw is None:
        return DEFAULT_PROVENANCE
    mode = str(raw).strip().lower()
    if mode not in PROVENANCE_MODES:
        raise ProvenanceError(f"invalid provenance mode: {raw}")
    return mode


def resolve_citation_path(workspace: str, rel_path: str) -> str:
    if PARENT_TRAVERSAL_RE.search(rel_path):
        raise ProvenanceError(f"citation path traversal rejected: {rel_path}")
    return resolve_project_path(workspace, rel_path)


def read_file_lines(abs_path: str) -> list[str]:
    with open(abs_path, encoding="utf-8") as handle:
        return handle.read().splitlines()


def validate_file_line_citation(
    workspace: str,
    ref: str,
    *,
    location: str = "",
) -> None:
    match = FILE_CITE_RE.match(ref.strip())
    if not match:
        raise ProvenanceError(f"invalid file citation: {ref}", location=location)
    rel_path = match.group("path").strip()
    line_no = int(match.group("line"))
    excerpt = match.group("excerpt")
    if excerpt is not None:
        excerpt = bytes(excerpt, "utf-8").decode("unicode_escape")

    if line_no < 1:
        raise ProvenanceError(
            f"citation line out of range: {rel_path}:{line_no}", location=location
        )

    abs_path = resolve_citation_path(workspace, rel_path)
    if not os.path.isfile(abs_path):
        raise ProvenanceError(f"citation file not found: {rel_path}", location=location)

    lines = read_file_lines(abs_path)
    if line_no > len(lines):
        raise ProvenanceError(
            f"citation line out of range: {rel_path}:{line_no}", location=location
        )

    if excerpt is not None:
        line_text = normalize_text(lines[line_no - 1])
        expected = normalize_text(excerpt)
        if expected not in line_text:
            raise ProvenanceError(
                f"citation excerpt mismatch: {rel_path}:{line_no}",
                location=location,
            )


def _slugify_heading(text: str) -> str:
    slug = normalize_text(text).lower()
    slug = re.sub(r"[^\w\s-]", "", slug)
    slug = re.sub(r"[\s_]+", "-", slug).strip("-")
    return slug


def _markdown_heading_exists(text: str, heading: str) -> bool:
    target = normalize_text(heading).lower()
    target_slug = _slugify_heading(heading)
    for line in text.splitlines():
        if not line.startswith("#"):
            continue
        title = normalize_text(line.lstrip("#"))
        if title.lower() == target or _slugify_heading(title) == target_slug:
            return True
    return False


def _json_pointer_exists(document: Any, pointer: str) -> bool:
    if not pointer.startswith("/"):
        raise ProvenanceError(f"invalid JSON pointer: {pointer}")
    if pointer == "/":
        return True
    current: Any = document
    for part in pointer.lstrip("/").split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        if isinstance(current, dict):
            if part not in current:
                return False
            current = current[part]
        elif isinstance(current, list):
            if not part.isdigit():
                return False
            index = int(part)
            if index < 0 or index >= len(current):
                return False
            current = current[index]
        else:
            return False
    return True


def validate_artifact_citation(
    workspace: str,
    ref: str,
    *,
    location: str = "",
) -> None:
    ref = ref.strip()
    pointer_match = ARTIFACT_POINTER_CITE_RE.match(ref)
    if pointer_match:
        rel_path = pointer_match.group("path").strip()
        pointer = pointer_match.group("pointer")
        abs_path = resolve_citation_path(workspace, rel_path)
        if not os.path.isfile(abs_path):
            raise ProvenanceError(
                f"citation artifact not found: {rel_path}", location=location
            )
        with open(abs_path, encoding="utf-8") as handle:
            try:
                document = json.load(handle)
            except json.JSONDecodeError as exc:
                raise ProvenanceError(
                    f"citation artifact is not valid JSON: {rel_path}",
                    location=location,
                ) from exc
        if not _json_pointer_exists(document, pointer):
            raise ProvenanceError(
                f"citation JSON pointer not found: {rel_path}{pointer}",
                location=location,
            )
        return

    heading_match = ARTIFACT_HEADING_CITE_RE.match(ref)
    if heading_match:
        rel_path = heading_match.group("path").strip()
        heading = heading_match.group("heading").strip()
        abs_path = resolve_citation_path(workspace, rel_path)
        if not os.path.isfile(abs_path):
            raise ProvenanceError(
                f"citation artifact not found: {rel_path}", location=location
            )
        with open(abs_path, encoding="utf-8") as handle:
            text = handle.read()
        if not _markdown_heading_exists(text, heading):
            raise ProvenanceError(
                f"citation heading not found: {rel_path}#{heading}",
                location=location,
            )
        return

    validate_file_line_citation(workspace, ref, location=location)


def parse_markdown_citations(text: str) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    seen: set[str] = set()
    for line_no, line in enumerate(text.splitlines(), start=1):
        line_match = MD_CITE_LINE_RE.match(line)
        if line_match:
            ref = line_match.group("ref").strip()
            key = ref
            if key not in seen:
                seen.add(key)
                found.append((ref, f"line {line_no}"))
            continue
        for inline_match in MD_CITE_INLINE_RE.finditer(line):
            ref = inline_match.group("ref").strip()
            if ref not in seen:
                seen.add(ref)
                found.append((ref, f"line {line_no}"))
    return found


def validate_markdown_provenance(
    workspace: str,
    text: str,
    mode: str,
    *,
    artifact_rel: str = "",
) -> None:
    citations = parse_markdown_citations(text)
    if mode == "none":
        return
    if mode == "required" and not citations:
        raise ProvenanceError(
            f"provenance required but no citations found in {artifact_rel or 'markdown artifact'}"
        )
    for ref, location in citations:
        try:
            validate_artifact_citation(workspace, ref, location=location)
        except ProvenanceError as exc:
            if not exc.location:
                exc.location = location
            prefix = artifact_rel or "markdown artifact"
            raise ProvenanceError(f"{prefix}: {exc.message}", location=exc.location) from exc


def validate_json_citation_entry(
    workspace: str,
    entry: Any,
    *,
    index: int,
    artifact_rel: str,
) -> None:
    location = f"/citations/{index}"
    if not isinstance(entry, dict):
        raise ProvenanceError("citation entry must be an object", location=location)
    ref = entry.get("ref")
    if not isinstance(ref, str) or not ref.strip():
        raise ProvenanceError("citation ref must be a non-empty string", location=location)
    excerpt = entry.get("excerpt")
    if excerpt is not None and not isinstance(excerpt, str):
        raise ProvenanceError("citation excerpt must be a string", location=location)

    ref_text = ref.strip()
    if excerpt:
        ref_text = f'{ref_text} "{excerpt}"'
    try:
        validate_artifact_citation(workspace, ref_text, location=location)
    except ProvenanceError as exc:
        raise ProvenanceError(
            f"{artifact_rel}: {exc.message}", location=location
        ) from exc


def validate_json_provenance(
    workspace: str,
    document: dict[str, Any],
    mode: str,
    *,
    artifact_rel: str = "",
) -> None:
    if mode == "none":
        return
    citations = document.get("citations")
    if citations is None:
        if mode == "required":
            raise ProvenanceError(
                f"provenance required but citations array missing in {artifact_rel or 'json artifact'}"
            )
        return
    if not isinstance(citations, list):
        raise ProvenanceError(
            f"citations must be an array in {artifact_rel or 'json artifact'}",
            location="/citations",
        )
    if mode == "required" and len(citations) == 0:
        raise ProvenanceError(
            f"provenance required but citations array is empty in {artifact_rel or 'json artifact'}",
            location="/citations",
        )
    for index, entry in enumerate(citations):
        validate_json_citation_entry(
            workspace, entry, index=index, artifact_rel=artifact_rel
        )


def validate_artifact_provenance_file(
    workspace: str,
    artifact_rel: str,
    mode: str,
) -> None:
    if mode == "none":
        return
    abs_path = resolve_citation_path(workspace, artifact_rel)
    if not os.path.isfile(abs_path):
        raise ProvenanceError(f"artifact file not found: {artifact_rel}")
    if os.path.getsize(abs_path) == 0:
        raise ProvenanceError(f"artifact file is empty: {artifact_rel}")

    with open(abs_path, encoding="utf-8") as handle:
        text = handle.read()

    if artifact_rel.endswith(".json"):
        try:
            document = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ProvenanceError(
                f"artifact is not valid JSON: {artifact_rel}"
            ) from exc
        if not isinstance(document, dict):
            raise ProvenanceError(f"json artifact must be an object: {artifact_rel}")
        validate_json_provenance(
            workspace, document, mode, artifact_rel=artifact_rel
        )
        return

    validate_markdown_provenance(
        workspace, text, mode, artifact_rel=artifact_rel
    )


def collect_produced_provenance_entries(stage: dict[str, Any]) -> list[dict[str, str]]:
    produced: list[dict[str, str]] = []
    seen: set[str] = set()
    for field in ARTIFACT_LIST_FIELDS:
        for item in stage.get(field, []) or []:
            if not isinstance(item, dict):
                continue
            path = str(item.get("path", "") or "")
            if not path:
                continue
            mode = default_provenance_mode(item.get("provenance"))
            if mode == "none":
                continue
            key = f"{field}:{path}"
            if key in seen:
                continue
            seen.add(key)
            produced.append(
                {
                    "artifact_path": path,
                    "provenance": mode,
                }
            )
    return produced


def verify_stage_artifact_provenance(
    workspace: str,
    stage: dict[str, Any],
    *,
    stage_id: str,
    artifact_ns: str = "",
    plan_key: str = "",
) -> None:
    plan_key = plan_key or artifact_ns
    for entry in collect_produced_provenance_entries(stage):
        artifact_rel = expand_artifact_tokens(
            entry["artifact_path"],
            artifact_ns=artifact_ns,
            plan_key=plan_key,
            stage_id=stage_id,
        )
        validate_artifact_provenance_file(
            workspace, artifact_rel, entry["provenance"]
        )


def _cmd_verify_stage(args: argparse.Namespace) -> int:
    stage = json.loads(args.stage_json)
    stage_id = args.stage_id or str(stage.get("id", "") or "")
    artifact_ns = args.artifact_ns
    plan_key = args.plan_key or artifact_ns
    try:
        verify_stage_artifact_provenance(
            workspace=args.workspace,
            stage=stage,
            stage_id=stage_id,
            artifact_ns=artifact_ns,
            plan_key=plan_key,
        )
    except ProvenanceError as exc:
        location = f" location={exc.location}" if exc.location else ""
        print(f"{exc.message}{location}", file=sys.stderr)
        return 1
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ralph artifact provenance tools")
    subparsers = parser.add_subparsers(dest="command", required=True)

    verify_stage = subparsers.add_parser(
        "verify-stage",
        help="Validate provenance for produced artifacts in one orchestration stage",
    )
    verify_stage.add_argument("--workspace", required=True)
    verify_stage.add_argument("--stage-json", required=True)
    verify_stage.add_argument("--stage-id", default="")
    verify_stage.add_argument("--artifact-ns", default="")
    verify_stage.add_argument("--plan-key", default="")
    verify_stage.set_defaults(func=_cmd_verify_stage)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
