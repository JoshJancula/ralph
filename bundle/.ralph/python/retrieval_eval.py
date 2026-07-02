#!/usr/bin/env python3
"""Offline retrieval evaluation harness for ralph_proxy_search (stdlib only).

Uses the same candidate gathering (rg or grep fallback) and BM25 ranking
(mcp-proxy-search-rank.py) as the MCP proxy search path. Paths in results are
always project-relative for machine-independent comparison.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

DEFAULT_MAX_CANDIDATES = 800
EVAL_TOP_K = 10
RANK_MAX_RESULTS = 50

BINARY_SUFFIXES = frozenset(
    {
        ".png",
        ".jpg",
        ".jpeg",
        ".gif",
        ".webp",
        ".ico",
        ".pdf",
        ".zip",
        ".gz",
        ".tar",
        ".bin",
        ".woff",
        ".woff2",
        ".ttf",
        ".eot",
        ".mp4",
        ".mp3",
        ".sqlite",
        ".db",
    }
)

SKIP_DIR_NAMES = frozenset(
    {
        ".git",
        ".ralph-workspace",
        "node_modules",
        "dist",
        "build",
        "target",
        ".next",
        ".cache",
        "vendor",
    }
)

# Eval fixture labels duplicate query strings; exclude from gathering so rankings
# reflect repository sources rather than the harness fixture itself.
SKIP_PATH_PREFIXES = (
    "tests/fixtures/retrieval-eval/",
)


def _load_search_rank_module(script_dir: Path):
    rank_path = script_dir / "mcp-proxy-search-rank.py"
    spec = importlib.util.spec_from_file_location("mcp_proxy_search_rank", rank_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"unable to load {rank_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_or_pattern(query: str, normalize_terms) -> str | None:
    terms = normalize_terms(query)
    if not terms:
        return None
    return "|".join(re.escape(term) for term in terms)


def _is_binary_file(path: Path) -> bool:
    if path.suffix.lower() in BINARY_SUFFIXES:
        return True
    try:
        with path.open("rb") as handle:
            chunk = handle.read(8192)
    except OSError:
        return True
    return b"\x00" in chunk


def _should_skip_relpath(relpath: str) -> bool:
    norm = relpath.replace("\\", "/")
    if any(norm.startswith(prefix) for prefix in SKIP_PATH_PREFIXES):
        return True
    parts = norm.split("/")
    return any(part in SKIP_DIR_NAMES for part in parts)


def to_project_relative(filepath: str, project_root: Path) -> str:
    path = Path(filepath)
    try:
        rel = path.resolve().relative_to(project_root.resolve())
        return str(rel).replace("\\", "/")
    except ValueError:
        return path.name.replace("\\", "/")


def _format_candidate(relpath: str, lineno: str, content: str) -> str:
    return f"{relpath}:{lineno}:{content}"


def gather_candidates_rg(
    or_pattern: str,
    search_root: Path,
    glob_filter: str,
    project_root: Path,
) -> list[str]:
    rg_args = [
        "rg",
        "--line-number",
        "--no-heading",
        "--color=never",
        "-i",
        "-e",
        or_pattern,
    ]
    if glob_filter:
        rg_args.extend(["--glob", glob_filter])

    search_root = search_root.resolve()
    if search_root.is_file():
        if _is_binary_file(search_root):
            return []
        proc = subprocess.run(
            rg_args + [str(search_root)],
            capture_output=True,
            text=True,
            check=False,
        )
        lines: list[str] = []
        relpath = to_project_relative(str(search_root), project_root)
        for raw in proc.stdout.splitlines():
            if not raw.strip():
                continue
            lineno, _, content = raw.partition(":")
            lines.append(_format_candidate(relpath, lineno, content))
        return lines

    proc = subprocess.run(
        rg_args + [str(search_root)],
        capture_output=True,
        text=True,
        check=False,
    )
    lines = []
    root_str = str(search_root)
    for raw in proc.stdout.splitlines():
        if not raw.strip():
            continue
        filepath, _, rest = raw.partition(":")
        lineno, _, content = rest.partition(":")
        relpath = to_project_relative(filepath, project_root)
        if _should_skip_relpath(relpath):
            continue
        lines.append(_format_candidate(relpath, lineno, content))
    return lines


def _git_ls_files(search_root: Path) -> list[str]:
    proc = subprocess.run(
        ["git", "-C", str(search_root), "ls-files", "-co", "--exclude-standard", "-z"],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return []
    entries: list[str] = []
    for raw in proc.stdout.split(b"\0"):
        if not raw:
            continue
        rel = raw.decode("utf-8", errors="replace")
        if _should_skip_relpath(rel):
            continue
        abs_path = search_root / rel
        if abs_path.is_file() and not _is_binary_file(abs_path):
            entries.append(rel.replace("\\", "/"))
    return sorted(entries)


def _walk_eligible_files(search_root: Path) -> list[str]:
    entries: list[str] = []
    search_root = search_root.resolve()
    for dirpath, dirnames, filenames in os.walk(search_root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_NAMES]
        for name in filenames:
            abs_path = Path(dirpath) / name
            try:
                relpath = abs_path.relative_to(search_root).as_posix()
            except ValueError:
                continue
            if _should_skip_relpath(relpath):
                continue
            if not _is_binary_file(abs_path):
                entries.append(relpath)
    return sorted(entries)


def enumerate_eligible_files(search_root: Path) -> list[str]:
    if subprocess.run(["git", "-C", str(search_root), "rev-parse", "--is-inside-work-tree"],
                      capture_output=True, check=False).returncode == 0:
        files = _git_ls_files(search_root)
        if files:
            return files
    return _walk_eligible_files(search_root)


def gather_candidates_fallback(
    or_pattern: str,
    search_root: Path,
    glob_filter: str,
    project_root: Path,
) -> list[str]:
    lines: list[str] = []
    search_root = search_root.resolve()

    if search_root.is_file():
        if _is_binary_file(search_root):
            return []
        proc = subprocess.run(
            ["grep", "-Ein", "--", or_pattern, str(search_root)],
            capture_output=True,
            text=True,
            check=False,
        )
        relpath = to_project_relative(str(search_root), project_root)
        for raw in proc.stdout.splitlines():
            if not raw.strip():
                continue
            lineno, _, content = raw.partition(":")
            lines.append(_format_candidate(relpath, lineno, content))
        return lines

    for relpath in enumerate_eligible_files(search_root):
        if glob_filter and not Path(relpath).match(glob_filter):
            continue
        abs_path = search_root / relpath
        if not abs_path.is_file():
            continue
        proc = subprocess.run(
            ["grep", "-Ein", "--", or_pattern, str(abs_path)],
            capture_output=True,
            text=True,
            check=False,
        )
        for raw in proc.stdout.splitlines():
            if not raw.strip():
                continue
            lineno, _, content = raw.partition(":")
            lines.append(_format_candidate(relpath, lineno, content))
    return lines


def gather_candidates(
    query: str,
    project_root: Path,
    search_path: str,
    glob_filter: str,
    max_candidates: int,
    normalize_terms,
) -> str:
    or_pattern = build_or_pattern(query, normalize_terms)
    if not or_pattern:
        return ""

    root = project_root.resolve()
    if search_path in (".", ""):
        search_root = root
    else:
        search_root = (root / search_path).resolve()

    lines: list[str] = []
    if shutil.which("rg"):
        lines = gather_candidates_rg(or_pattern, search_root, glob_filter, root)
    if not lines:
        lines = gather_candidates_fallback(or_pattern, search_root, glob_filter, root)
    if lines:
        lines = sorted(
            lines,
            key=lambda raw: (
                raw.split(":", 2)[0],
                int(raw.split(":", 2)[1]) if raw.split(":", 2)[1].isdigit() else 0,
                raw,
            ),
        )[:max_candidates]
    return "\n".join(lines) + ("\n" if lines else "")


def rank_candidates(
    query: str,
    candidates: str,
    max_results: int,
    rank_script: Path,
    *,
    project_root: Path | None = None,
    state_root: Path | None = None,
    contextual: bool = False,
) -> list[str]:
    if not candidates.strip():
        return []
    cmd = [sys.executable, str(rank_script), "--query", query, "--max-results", str(max_results)]
    if contextual:
        cmd.extend(["--contextual", "1"])
        if project_root is not None:
            cmd.extend(["--project-root", str(project_root)])
        if state_root is not None:
            cmd.extend(["--state-root", str(state_root)])
    else:
        cmd.extend(["--contextual", "0"])
    proc = subprocess.run(
        cmd,
        input=candidates,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return []
    results: list[str] = []
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(":", 2)
        if len(parts) < 2:
            continue
        results.append(f"{parts[0]}:{parts[1]}")
    return results


def _normalize_path(path: str) -> str:
    return path.replace("\\", "/").lstrip("./")


def is_relevant_hit(path_line: str, entry: dict[str, Any]) -> bool:
    parts = path_line.split(":", 1)
    if not parts:
        return False
    hit_path = _normalize_path(parts[0])
    relevant_paths = [_normalize_path(p) for p in (entry.get("relevant_paths") or [])]
    return hit_path in relevant_paths


def preferred_hit(path_line: str, entry: dict[str, Any]) -> bool:
    """True when a hit matches optional line or symbol hints (for safety gates)."""
    if not is_relevant_hit(path_line, entry):
        return False
    line_hints = entry.get("line_hints") or []
    if line_hints:
        try:
            hit_line = int(path_line.split(":", 1)[1])
        except (ValueError, IndexError):
            return False
        if hit_line not in line_hints:
            return False
    return True


def precision_at_k(top: list[str], entry: dict[str, Any], k: int) -> float:
    if k <= 0:
        return 0.0
    hits = top[:k]
    if not hits:
        return 0.0
    relevant = sum(1 for h in hits if is_relevant_hit(h, entry))
    return relevant / k


def recall_at_k(top: list[str], entry: dict[str, Any], k: int) -> float:
    relevant_paths = entry.get("relevant_paths") or []
    if not relevant_paths:
        return 0.0
    hits = top[:k]
    found = {
        _normalize_path(h.split(":", 1)[0])
        for h in hits
        if is_relevant_hit(h, entry)
    }
    target = {_normalize_path(p) for p in relevant_paths}
    return len(found & target) / len(target)


def reciprocal_rank(top: list[str], entry: dict[str, Any], max_rank: int = EVAL_TOP_K) -> float:
    for idx, hit in enumerate(top[:max_rank], start=1):
        if is_relevant_hit(hit, entry):
            return 1.0 / idx
    return 0.0


def first_relevant_rank(top: list[str], entry: dict[str, Any], max_rank: int = EVAL_TOP_K) -> int | None:
    for idx, hit in enumerate(top[:max_rank], start=1):
        if is_relevant_hit(hit, entry):
            return idx
    return None


@dataclass
class QueryEvalResult:
    query_id: str
    query: str
    top_results: list[str] = field(default_factory=list)
    precision_at_5: float = 0.0
    recall_at_5: float = 0.0
    recall_at_10: float = 0.0
    reciprocal_rank: float = 0.0
    has_relevant_top10: bool = False
    first_relevant_rank: int | None = None


@dataclass
class AggregateMetrics:
    precision_at_5: float
    recall_at_5: float
    recall_at_10: float
    mrr: float
    queries_no_relevant_top10: int
    query_count: int

    def as_dict(self) -> dict[str, Any]:
        return {
            "precision_at_5": round(self.precision_at_5, 6),
            "recall_at_5": round(self.recall_at_5, 6),
            "recall_at_10": round(self.recall_at_10, 6),
            "mrr": round(self.mrr, 6),
            "queries_no_relevant_top10": self.queries_no_relevant_top10,
            "query_count": self.query_count,
        }


def evaluate_query(
    entry: dict[str, Any],
    project_root: Path,
    rank_script: Path,
    normalize_terms,
    max_candidates: int = DEFAULT_MAX_CANDIDATES,
    *,
    state_root: Path | None = None,
    contextual: bool = False,
    expand_terms=None,
) -> QueryEvalResult:
    query_id = str(entry.get("id") or "")
    query = str(entry.get("query") or "")
    search_path = str(entry.get("search_path") or ".")
    glob_filter = str(entry.get("glob") or "")

    candidates = gather_candidates(
        query, project_root, search_path, glob_filter, max_candidates, normalize_terms
    )
    if not candidates.strip() and expand_terms is not None:
        candidates = gather_candidates(
            query, project_root, search_path, glob_filter, max_candidates, expand_terms
        )
    ranked = rank_candidates(
        query,
        candidates,
        RANK_MAX_RESULTS,
        rank_script,
        project_root=project_root,
        state_root=state_root,
        contextual=contextual,
    )
    top = ranked[:EVAL_TOP_K]

    result = QueryEvalResult(
        query_id=query_id,
        query=query,
        top_results=top,
        precision_at_5=precision_at_k(ranked, entry, 5),
        recall_at_5=recall_at_k(ranked, entry, 5),
        recall_at_10=recall_at_k(ranked, entry, 10),
        reciprocal_rank=reciprocal_rank(ranked, entry),
        has_relevant_top10=first_relevant_rank(ranked, entry) is not None,
        first_relevant_rank=first_relevant_rank(ranked, entry),
    )
    return result


def aggregate_results(results: list[QueryEvalResult]) -> AggregateMetrics:
    if not results:
        return AggregateMetrics(0.0, 0.0, 0.0, 0.0, 0, 0)
    n = len(results)
    return AggregateMetrics(
        precision_at_5=sum(r.precision_at_5 for r in results) / n,
        recall_at_5=sum(r.recall_at_5 for r in results) / n,
        recall_at_10=sum(r.recall_at_10 for r in results) / n,
        mrr=sum(r.reciprocal_rank for r in results) / n,
        queries_no_relevant_top10=sum(1 for r in results if not r.has_relevant_top10),
        query_count=n,
    )


def run_evaluation(
    project_root: Path,
    queries_path: Path,
    rank_script: Path | None = None,
    *,
    state_root: Path | None = None,
    contextual: bool = False,
) -> tuple[list[QueryEvalResult], AggregateMetrics]:
    script_dir = project_root / "bundle" / ".ralph" / "python"
    if rank_script is None:
        rank_script = script_dir / "mcp-proxy-search-rank.py"
    search_rank = _load_search_rank_module(script_dir)
    if state_root is None:
        state_root = project_root / ".ralph-workspace"

    # Mirror the production gather exactly: gather with literal terms, and only
    # when that pool is empty (cross-morphology query) fall back to identifier
    # subtokens. Unconditional expansion floods the pool and regresses quality.
    expand = getattr(search_rank, "expand_query_terms", None)
    expand_terms = (lambda query: expand(query)[0]) if expand is not None else None

    payload = json.loads(queries_path.read_text(encoding="utf-8"))
    queries = payload.get("queries") or []
    results = [
        evaluate_query(
            entry,
            project_root,
            rank_script,
            search_rank.normalize_terms,
            state_root=state_root,
            contextual=contextual,
            expand_terms=expand_terms,
        )
        for entry in queries
    ]
    return results, aggregate_results(results)


def result_to_dict(result: QueryEvalResult) -> dict[str, Any]:
    return {
        "query_id": result.query_id,
        "query": result.query,
        "top_results": result.top_results,
        "precision_at_5": round(result.precision_at_5, 6),
        "recall_at_5": round(result.recall_at_5, 6),
        "recall_at_10": round(result.recall_at_10, 6),
        "reciprocal_rank": round(result.reciprocal_rank, 6),
        "has_relevant_top10": result.has_relevant_top10,
        "first_relevant_rank": result.first_relevant_rank,
    }


def emit_json_report(
    results: list[QueryEvalResult],
    aggregate: AggregateMetrics,
    ranker: str,
) -> str:
    payload = {
        "schema_version": 1,
        "kind": "retrieval_eval_report",
        "ranker": ranker,
        "aggregate": aggregate.as_dict(),
        "per_query": {r.query_id: result_to_dict(r) for r in results},
    }
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def format_failure_report(
    results: list[QueryEvalResult],
    aggregate: AggregateMetrics,
    baseline: dict[str, Any],
    tolerance: dict[str, float],
) -> str:
    lines = ["Retrieval evaluation failure report", "================================"]
    base_agg = baseline.get("aggregate") or {}
    tol = baseline.get("tolerance") or tolerance

    def check_metric(name: str, current: float, base_key: str) -> None:
        base_val = base_agg.get(base_key)
        if base_val is None:
            return
        limit = float(tol.get(base_key, 0.0))
        if current + limit < float(base_val):
            lines.append(
                f"- REGRESSION {name}: current={current:.6f} baseline={float(base_val):.6f} "
                f"tolerance={limit:.6f}"
            )

    check_metric("precision@5", aggregate.precision_at_5, "precision_at_5")
    check_metric("recall@5", aggregate.recall_at_5, "recall_at_5")
    check_metric("recall@10", aggregate.recall_at_10, "recall_at_10")
    check_metric("MRR", aggregate.mrr, "mrr")

    base_no_hit = base_agg.get("queries_no_relevant_top10")
    max_delta = int(tol.get("queries_no_relevant_top10_max_delta", 0))
    if base_no_hit is not None and aggregate.queries_no_relevant_top10 > int(base_no_hit) + max_delta:
        lines.append(
            f"- REGRESSION no-relevant-top10: current={aggregate.queries_no_relevant_top10} "
            f"baseline={base_no_hit} max_delta={max_delta}"
        )

    per_base = baseline.get("per_query") or {}
    for result in results:
        entry = per_base.get(result.query_id) or {}
        safety = entry.get("safety_top10") or []
        if not safety:
            continue
        # Safety anchors are project-relative paths, not path:line, so they
        # survive edits that shift line numbers within a ranked file. Legacy
        # path:line baselines are tolerated by comparing on the path component.
        top_paths = {_normalize_path(h.split(":", 1)[0]) for h in result.top_results}
        for required in safety:
            required_path = _normalize_path(required.split(":", 1)[0])
            if required_path not in top_paths:
                lines.append(
                    f"- SAFETY GATE {result.query_id}: missing required top-10 path {required_path!r}"
                )

    no_hit_queries = [r.query_id for r in results if not r.has_relevant_top10]
    if no_hit_queries:
        lines.append("")
        lines.append("Queries with no relevant top-10 result:")
        for qid in no_hit_queries:
            lines.append(f"  - {qid}")

    if len(lines) == 2:
        lines.append("- (no failures detected)")
    return "\n".join(lines) + "\n"


def compare_to_baseline(
    aggregate: AggregateMetrics,
    results: list[QueryEvalResult],
    baseline: dict[str, Any],
) -> list[str]:
    report = format_failure_report(results, aggregate, baseline, baseline.get("tolerance") or {})
    failures = [line for line in report.splitlines() if line.startswith("- REGRESSION") or line.startswith("- SAFETY")]
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description="Offline retrieval evaluation harness")
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--queries",
        type=Path,
        default=Path("tests/fixtures/retrieval-eval/queries.json"),
    )
    parser.add_argument("--baseline", type=Path, default=None)
    parser.add_argument("--json-out", type=Path, default=None)
    parser.add_argument("--report-out", type=Path, default=None)
    parser.add_argument("--ranker", default="pre-contextual-bm25")
    parser.add_argument(
        "--contextual",
        choices=("0", "1", "auto"),
        default="auto",
        help="Use contextual BM25 (1), baseline path-only content BM25 (0), or follow RALPH_MCP_CONTEXTUAL_SEARCH (auto).",
    )
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    queries_path = args.queries if args.queries.is_absolute() else project_root / args.queries

    contextual = False
    if args.contextual == "1":
        contextual = True
    elif args.contextual == "auto":
        try:
            import search_context as sc  # noqa: WPS433

            contextual = sc.contextual_search_enabled()
        except ImportError:
            contextual = False

    results, aggregate = run_evaluation(
        project_root,
        queries_path,
        contextual=contextual,
    )
    ranker = args.ranker if not contextual else "contextual-bm25"

    json_text = emit_json_report(results, aggregate, ranker)
    if args.json_out:
        args.json_out.write_text(json_text, encoding="utf-8")
    else:
        sys.stdout.write(json_text)

    if args.baseline:
        baseline_path = args.baseline if args.baseline.is_absolute() else project_root / args.baseline
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
        report = format_failure_report(results, aggregate, baseline, baseline.get("tolerance") or {})
        if args.report_out:
            args.report_out.write_text(report, encoding="utf-8")
        failures = compare_to_baseline(aggregate, results, baseline)
        if failures:
            if not args.report_out:
                sys.stderr.write(report)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
