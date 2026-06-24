#!/usr/bin/env python3
"""Cross-runtime tool evaluation harness (offline fake-runtime + opt-in live mode).

Offline mode replays checked-in traces to validate scoring, telemetry reuse, and
catalog/discovery failure detection without model calls. Live mode is opt-in via
RALPH_TOOL_EVAL=live and writes results only under the state root.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Mapping, Sequence

_MODULE_DIR = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_TASKS = "tests/fixtures/tool-eval/tasks.json"
_DEFAULT_TRACES = "tests/fixtures/tool-eval/offline-traces.json"
_DEFAULT_ERGONOMICS_SCHEMA = os.path.normpath(
    os.path.join(_MODULE_DIR, "..", "schemas", "tool-eval-ergonomics.schema.json")
)

SUPPORTED_RUNTIMES = ("cursor", "claude", "codex", "opencode", "antigravity")

_REQUIRED_PROXY_TOOLS = (
    "ralph_proxy_read",
    "ralph_proxy_grep",
    "ralph_proxy_glob",
    "ralph_proxy_shell",
    "ralph_proxy_search",
    "ralph_proxy_batch",
)

_BATCHABLE_PROXY_TOOLS = frozenset(
    {
        "ralph_proxy_read",
        "ralph_proxy_grep",
        "ralph_proxy_glob",
        "ralph_proxy_search",
        "ralph_proxy_result_read",
        "ralph_proxy_result_search",
        "ralph_proxy_result_summary",
    }
)

_REQUIRED_TASK_FIELDS = (
    "id",
    "prompt",
    "fixture",
    "expected",
    "max_tool_calls",
    "timeout_seconds",
    "scoring_method",
    "mutation_permitted",
)

sys.path.insert(0, _MODULE_DIR)

import artifact_json_schema as ajs  # noqa: E402
from tool_call_target_telemetry import (  # noqa: E402
    count_sequence_antipatterns,
    finalize_tool_target_telemetry,
    init_tool_target_telemetry,
    record_tool_target,
    scan_sequence_antipatterns,
)
from tool_call_target_telemetry import _shell_status_poll_count  # noqa: E402


def _load_discover_report_module():
    script_path = os.path.join(_MODULE_DIR, "ralph-discover-report.py")
    spec = importlib.util.spec_from_file_location("ralph_discover_report", script_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"unable to load {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_DISCOVER_REPORT = _load_discover_report_module()
build_discover_report = _DISCOVER_REPORT.build_discover_report


class ToolEvalError(Exception):
    """Raised when harness input or configuration is invalid."""


@dataclass
class TaskScore:
    task_id: str
    category: str
    scoring_method: str
    completed: bool
    accuracy: float
    tool_calls: int
    duplicate_reads: int
    batchable_serial_calls: int
    duration_ms: int
    per_tool_duration_ms: dict[str, int] = field(default_factory=dict)
    catalog_discovery_failures: list[str] = field(default_factory=list)
    within_tool_call_budget: bool = True
    ergonomics_valid: bool | None = None
    discover_pattern_ids: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["accuracy"] = round(self.accuracy, 6)
        return payload


def _lower_label(value: Any) -> str:
    return str(value or "").strip().lower()


def is_live_mode_enabled() -> bool:
    return os.environ.get("RALPH_TOOL_EVAL", "").strip().lower() == "live"


def is_ci_environment() -> bool:
    for var in ("CI", "GITHUB_ACTIONS", "GITLAB_CI"):
        if os.environ.get(var, "").strip().lower() in ("1", "true", "yes"):
            return True
    return False


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ToolEvalError(f"file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ToolEvalError(f"invalid JSON in {path}: {exc}") from exc


def validate_task(task: Mapping[str, Any]) -> None:
    missing = [key for key in _REQUIRED_TASK_FIELDS if key not in task]
    if missing:
        raise ToolEvalError(f"task {task.get('id')!r} missing fields: {', '.join(missing)}")
    scoring = str(task.get("scoring_method") or "")
    if scoring not in ("deterministic_match", "detection_only"):
        raise ToolEvalError(f"task {task.get('id')!r} has unsupported scoring_method: {scoring}")


def load_tasks(tasks_path: Path) -> list[dict[str, Any]]:
    payload = load_json(tasks_path)
    tasks = payload.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        raise ToolEvalError(f"no tasks in {tasks_path}")
    for task in tasks:
        if not isinstance(task, dict):
            raise ToolEvalError(f"invalid task entry in {tasks_path}")
        validate_task(task)
    return tasks


def load_offline_traces(traces_path: Path) -> dict[str, dict[str, Any]]:
    payload = load_json(traces_path)
    traces = payload.get("traces")
    if not isinstance(traces, dict) or not traces:
        raise ToolEvalError(f"no offline traces in {traces_path}")
    return {str(key): value for key, value in traces.items() if isinstance(value, dict)}


def validate_ergonomics(
    data: Mapping[str, Any] | None,
    schema_path: str | None = None,
) -> bool:
    if data is None:
        return True
    if not isinstance(data, Mapping):
        return False
    schema_file = schema_path or _DEFAULT_ERGONOMICS_SCHEMA
    try:
        schema = ajs.load_schema_document(schema_file)
        ajs.assert_supported_schema(schema, "$")
        ajs.validate_json_text(json.dumps(data), schema)
    except (ValueError, ajs.SchemaValidationError, ajs.UnsupportedSchemaKeywordError):
        return False
    return True


def validate_mcp_tools_list(tools_result: Mapping[str, Any]) -> list[str]:
    failures: list[str] = []
    tools = tools_result.get("tools")
    if not isinstance(tools, list) or len(tools) == 0:
        failures.append("missing_tool_catalog")
        return failures

    if "nextCursor" in tools_result and tools_result.get("nextCursor") is None:
        failures.append("next_cursor_null_tool_drop")

    names = {
        str(item.get("name") or "").strip()
        for item in tools
        if isinstance(item, Mapping) and str(item.get("name") or "").strip()
    }
    for required in _REQUIRED_PROXY_TOOLS:
        if required not in names:
            failures.append(f"missing_required_tool:{required}")
    return failures


def detect_discovery_dispatch_failures(events: Sequence[Mapping[str, Any]] | None) -> list[str]:
    failures: list[str] = []
    if not events:
        return failures
    for event in events:
        if not isinstance(event, Mapping):
            continue
        if str(event.get("event") or "") != "tool_search_invoke":
            continue
        dispatched = event.get("dispatched_tool")
        if dispatched is None or not str(dispatched).strip():
            failures.append("failed_discovery_dispatch")
    return failures


def count_batchable_serial_proxy_calls(sequence: Sequence[Any]) -> int:
    labels = [_lower_label(item) for item in sequence if _lower_label(item)]
    count = 0
    for idx in range(len(labels) - 1):
        left, right = labels[idx], labels[idx + 1]
        if left == "ralph_proxy_batch":
            continue
        if left in _BATCHABLE_PROXY_TOOLS and right in _BATCHABLE_PROXY_TOOLS:
            count += 1
    return count


def _telemetry_from_trace(trace: Mapping[str, Any]) -> dict[str, Any]:
    acc = init_tool_target_telemetry()
    for entry in trace.get("tool_call_targets") or []:
        if not isinstance(entry, Mapping):
            continue
        tool = str(entry.get("tool") or "unknown")
        target = str(entry.get("target") or "")
        record_tool_target(acc, tool, {"path": target} if target else None)
    finalize_tool_target_telemetry(acc)

    usage = {
        "tool_calls_sequence": list(trace.get("tool_calls_sequence") or []),
        "tool_calls_by_tool": dict(trace.get("tool_calls_by_tool") or {}),
        "tool_calls_total": int(trace.get("tool_calls_total") or 0),
        "adjacent_duplicate_tool_calls": int(acc.get("adjacent_duplicate_tool_calls") or 0),
        "repeated_read_targets": int(acc.get("repeated_read_targets") or 0),
        "repeated_read_extra_calls": int(acc.get("repeated_read_extra_calls") or 0),
        "plan_file_read_calls": int(acc.get("plan_file_read_calls") or 0),
        "stored_result_readbacks": trace.get("stored_result_readbacks"),
        "compaction_telemetry": trace.get("compaction_telemetry") or [],
        "runtime": str(trace.get("runtime") or "offline"),
        "agent_tool_access": str(trace.get("agent_tool_access") or "ralph"),
    }
    return usage


def invocation_record_from_trace(trace: Mapping[str, Any], task_id: str) -> dict[str, Any]:
    usage = _telemetry_from_trace(trace)
    usage.update(
        {
            "iteration": 1,
            "todo_ordinal": 1,
            "plan_key": f"tool-eval-{task_id}",
            "tool_calls_total": int(trace.get("tool_calls_total") or 0),
            "started_at": trace.get("started_at") or "2026-01-01T00:00:00Z",
            "ended_at": trace.get("ended_at") or "2026-01-01T00:00:01Z",
            "native_read_like_calls": 0,
            "ralph_proxy_calls": sum(
                count
                for name, count in (trace.get("tool_calls_by_tool") or {}).items()
                if "ralph_proxy" in _lower_label(name)
            ),
            "other_mcp_calls": 0,
            "native_write_like_calls": 0,
        }
    )
    return usage


def collect_catalog_discovery_failures(trace: Mapping[str, Any], usage: Mapping[str, Any]) -> list[str]:
    failures: list[str] = []
    catalog_probe = trace.get("catalog_probe")
    if isinstance(catalog_probe, Mapping):
        failures.extend(validate_mcp_tools_list(catalog_probe))

    failures.extend(detect_discovery_dispatch_failures(trace.get("discovery_events")))

    if _shell_status_poll_count(usage) > 0:
        failures.append("excessive_shell_status_polling")

    # Deduplicate while preserving order.
    seen: set[str] = set()
    ordered: list[str] = []
    for item in failures:
        if item not in seen:
            seen.add(item)
            ordered.append(item)
    return ordered


def score_accuracy(task: Mapping[str, Any], trace: Mapping[str, Any]) -> float:
    scoring = str(task.get("scoring_method") or "deterministic_match")
    if scoring == "detection_only":
        expected = set(task.get("expected_failures") or [])
        detected = set(collect_catalog_discovery_failures(trace, _telemetry_from_trace(trace)))
        if not expected:
            return 1.0
        return len(expected & detected) / len(expected)

    expected = task.get("expected") or {}
    checks: list[bool] = []
    output = str(trace.get("output") or "")

    for needle in expected.get("output_contains") or []:
        checks.append(str(needle) in output)

    accessed = {
        str(entry.get("target") or "")
        for entry in (trace.get("tool_call_targets") or [])
        if isinstance(entry, Mapping)
    }
    for rel_path in expected.get("files") or []:
        rel = str(rel_path)
        checks.append(any(rel in target for target in accessed) or rel in output)

    for symbol in expected.get("symbols") or []:
        sym = str(symbol)
        checks.append(sym in output or any(sym in target for target in accessed))

    used_tools = {_lower_label(name) for name in (trace.get("tool_calls_by_tool") or {})}
    for tool in expected.get("tools") or []:
        lower = _lower_label(tool)
        checks.append(lower in used_tools or any(lower in name for name in used_tools))

    if not checks:
        return 1.0 if trace.get("completed") else 0.0
    return sum(1 for ok in checks if ok) / len(checks)


def score_task(task: Mapping[str, Any], trace: Mapping[str, Any]) -> TaskScore:
    usage = _telemetry_from_trace(trace)
    catalog_failures = collect_catalog_discovery_failures(trace, usage)
    invocation = invocation_record_from_trace(trace, str(task.get("id") or ""))
    discover = build_discover_report({"invocations": [invocation]})
    pattern_ids = sorted(
        {
            str(item.get("pattern_id") or "")
            for item in (discover.get("sequence_findings") or [])
            if isinstance(item, Mapping) and item.get("pattern_id")
        }
    )
    antipattern_counts = count_sequence_antipatterns(usage.get("tool_calls_sequence") or [])
    batchable = count_batchable_serial_proxy_calls(usage.get("tool_calls_sequence") or [])
    batchable += int(antipattern_counts.get("repeated_native_read_like") or 0)
    batchable += int(antipattern_counts.get("native_read_after_grep") or 0)

    ergonomics = trace.get("ergonomics")
    ergonomics_valid: bool | None
    if ergonomics is None:
        ergonomics_valid = None
    else:
        ergonomics_valid = validate_ergonomics(ergonomics)

    tool_calls = int(trace.get("tool_calls_total") or 0)
    max_calls = int(task.get("max_tool_calls") or 0)
    return TaskScore(
        task_id=str(task.get("id") or ""),
        category=str(task.get("category") or ""),
        scoring_method=str(task.get("scoring_method") or ""),
        completed=bool(trace.get("completed")),
        accuracy=score_accuracy(task, trace),
        tool_calls=tool_calls,
        duplicate_reads=int(usage.get("repeated_read_extra_calls") or 0),
        batchable_serial_calls=batchable,
        duration_ms=int(trace.get("duration_ms") or 0),
        per_tool_duration_ms={
            str(key): int(value)
            for key, value in (trace.get("tool_durations_ms") or {}).items()
        },
        catalog_discovery_failures=catalog_failures,
        within_tool_call_budget=(tool_calls <= max_calls if max_calls > 0 else True),
        ergonomics_valid=ergonomics_valid,
        discover_pattern_ids=pattern_ids,
    )


def aggregate_scores(scores: Sequence[TaskScore]) -> dict[str, Any]:
    if not scores:
        return {
            "task_count": 0,
            "mean_accuracy": 0.0,
            "completion_rate": 0.0,
            "mean_tool_calls": 0.0,
            "total_duplicate_reads": 0,
            "total_batchable_serial_calls": 0,
            "mean_duration_ms": 0.0,
            "catalog_failure_tasks": 0,
        }
    count = len(scores)
    return {
        "task_count": count,
        "mean_accuracy": round(sum(item.accuracy for item in scores) / count, 6),
        "completion_rate": round(sum(1 for item in scores if item.completed) / count, 6),
        "mean_tool_calls": round(sum(item.tool_calls for item in scores) / count, 6),
        "total_duplicate_reads": sum(item.duplicate_reads for item in scores),
        "total_batchable_serial_calls": sum(item.batchable_serial_calls for item in scores),
        "mean_duration_ms": round(sum(item.duration_ms for item in scores) / count, 6),
        "catalog_failure_tasks": sum(1 for item in scores if item.catalog_discovery_failures),
    }


def emit_json_report(
    scores: Sequence[TaskScore],
    *,
    mode: str,
    runtimes: Sequence[str] | None = None,
) -> str:
    payload = {
        "schema_version": 1,
        "kind": "tool_eval_report",
        "mode": mode,
        "runtimes": list(runtimes or []),
        "aggregate": aggregate_scores(scores),
        "per_task": {score.task_id: score.as_dict() for score in scores},
    }
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def run_offline_evaluation(
    project_root: Path,
    tasks_path: Path,
    traces_path: Path,
) -> list[TaskScore]:
    tasks = load_tasks(tasks_path)
    traces = load_offline_traces(traces_path)
    scores: list[TaskScore] = []
    for task in tasks:
        task_id = str(task.get("id") or "")
        if task_id not in traces:
            raise ToolEvalError(f"missing offline trace for task {task_id!r}")
        fixture = str(task.get("fixture") or "")
        fixture_path = (project_root / fixture).resolve()
        if not fixture_path.is_dir():
            raise ToolEvalError(f"fixture workspace missing for {task_id}: {fixture_path}")
        scores.append(score_task(task, traces[task_id]))
    return scores


def _state_root(project_root: Path) -> Path:
    raw = os.environ.get("RALPH_PLAN_WORKSPACE_ROOT", "").strip()
    if raw:
        root = Path(raw)
        if not root.is_absolute():
            root = project_root / root
        return root.resolve()
    return (project_root / ".ralph-workspace").resolve()


def _tool_eval_output_dir(project_root: Path) -> Path:
    return _state_root(project_root) / "tool-eval"


def _write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def _selected_runtimes(requested: Sequence[str] | None) -> list[str]:
    if not requested:
        return list(SUPPORTED_RUNTIMES)
    selected = []
    for runtime in requested:
        lower = runtime.strip().lower()
        if lower not in SUPPORTED_RUNTIMES:
            raise ToolEvalError(f"unsupported runtime: {runtime}")
        if lower not in selected:
            selected.append(lower)
    return selected


def _build_live_plan(task: Mapping[str, Any], plan_dir: Path) -> Path:
    plan_dir.mkdir(parents=True, exist_ok=True)
    task_id = str(task.get("id") or "task")
    plan_path = plan_dir / f"{task_id}.plan.md"
    mutation = "yes" if task.get("mutation_permitted") else "no"
    body = (
        f"# Tool eval: {task_id}\n\n"
        f"- [ ] {task.get('prompt')}\n\n"
        f"Constraints: mutation_permitted={mutation}; "
        f"max_tool_calls={task.get('max_tool_calls')}; "
        f"timeout_seconds={task.get('timeout_seconds')}.\n"
    )
    plan_path.write_text(body, encoding="utf-8")
    return plan_path


def run_live_evaluation(
    project_root: Path,
    tasks_path: Path,
    *,
    runtimes: Sequence[str] | None = None,
    task_ids: Sequence[str] | None = None,
) -> list[TaskScore]:
    if is_ci_environment() and os.environ.get("RALPH_TOOL_EVAL_FORCE_LIVE", "").strip() not in (
        "1",
        "true",
        "yes",
    ):
        raise ToolEvalError(
            "live mode is disabled in CI; set RALPH_TOOL_EVAL_FORCE_LIVE=1 to override"
        )
    if not is_live_mode_enabled():
        raise ToolEvalError("live mode requires RALPH_TOOL_EVAL=live")

    tasks = load_tasks(tasks_path)
    if task_ids:
        wanted = {str(item) for item in task_ids}
        tasks = [task for task in tasks if str(task.get("id") or "") in wanted]
        if not tasks:
            raise ToolEvalError("no tasks matched --task filter")

    output_dir = _tool_eval_output_dir(project_root)
    plan_dir = output_dir / "plans"
    run_plan = (project_root / ".ralph" / "run-plan.sh").resolve()
    if not run_plan.is_file():
        raise ToolEvalError(f"run-plan.sh not found: {run_plan}")

    scores: list[TaskScore] = []
    for runtime in _selected_runtimes(runtimes):
        for task in tasks:
            task_id = str(task.get("id") or "")
            plan_path = _build_live_plan(task, plan_dir / runtime)
            fixture = str(task.get("fixture") or "")
            agent_workspace = (project_root / fixture).resolve()
            started = time.time()
            proc = subprocess.run(
                [
                    "bash",
                    str(run_plan),
                    "--runtime",
                    runtime,
                    "--plan",
                    str(plan_path),
                    "--workspace",
                    str(project_root),
                    "--agent-workspace",
                    str(agent_workspace),
                ],
                cwd=str(project_root),
                capture_output=True,
                text=True,
                check=False,
            )
            duration_ms = int((time.time() - started) * 1000)
            runtime_dir = output_dir / runtime / task_id
            runtime_dir.mkdir(parents=True, exist_ok=True)
            _write_text(runtime_dir / "stdout.log", proc.stdout or "")
            _write_text(runtime_dir / "stderr.log", proc.stderr or "")
            _write_text(
                runtime_dir / "exit.json",
                json.dumps({"exit_code": proc.returncode, "duration_ms": duration_ms}, indent=2)
                + "\n",
            )

            usage_path = _state_root(project_root) / "logs" / f"tool-eval-{task_id}" / "invocation-usage.json"
            if not usage_path.is_file():
                # Fallback: newest invocation log under state root.
                candidates = sorted(
                    _state_root(project_root).rglob("invocation-usage.json"),
                    key=lambda path: path.stat().st_mtime,
                    reverse=True,
                )
                usage_path = candidates[0] if candidates else usage_path

            trace: dict[str, Any] = {
                "completed": proc.returncode == 0,
                "output": (proc.stdout or "")[-4000:],
                "duration_ms": duration_ms,
                "runtime": runtime,
                "tool_calls_total": 0,
                "tool_calls_sequence": [],
                "tool_calls_by_tool": {},
                "tool_durations_ms": {},
                "tool_call_targets": [],
            }
            if usage_path.is_file():
                usage_doc = load_json(usage_path)
                invocations = usage_doc.get("invocations") or []
                if isinstance(invocations, list) and invocations:
                    last = invocations[-1]
                    if isinstance(last, Mapping):
                        trace.update(
                            {
                                "tool_calls_total": int(last.get("tool_calls_total") or 0),
                                "tool_calls_sequence": list(last.get("tool_calls_sequence") or []),
                                "tool_calls_by_tool": dict(last.get("tool_calls_by_tool") or {}),
                                "compaction_telemetry": list(
                                    last.get("compaction_telemetry") or []
                                ),
                            }
                        )
            scores.append(score_task(task, trace))
    return scores


def compare_to_baseline(
    scores: Sequence[TaskScore],
    baseline: Mapping[str, Any],
) -> list[str]:
    failures: list[str] = []
    per_task = baseline.get("per_task") or {}
    by_id = {score.task_id: score for score in scores}
    for task_id, expected in per_task.items():
        if task_id not in by_id:
            failures.append(f"missing task score: {task_id}")
            continue
        if not isinstance(expected, Mapping):
            continue
        actual = by_id[task_id]
        for key in ("accuracy", "completed", "tool_calls", "duplicate_reads", "batchable_serial_calls"):
            if key not in expected:
                continue
            if actual.as_dict().get(key) != expected.get(key):
                failures.append(
                    f"{task_id}.{key}: expected={expected.get(key)!r} actual={actual.as_dict().get(key)!r}"
                )
        expected_failures = expected.get("catalog_discovery_failures")
        if isinstance(expected_failures, list):
            if actual.catalog_discovery_failures != expected_failures:
                failures.append(
                    f"{task_id}.catalog_discovery_failures: "
                    f"expected={expected_failures!r} actual={actual.catalog_discovery_failures!r}"
                )
    agg_expected = baseline.get("aggregate") or {}
    agg_actual = aggregate_scores(scores)
    for key in ("mean_accuracy", "completion_rate", "catalog_failure_tasks"):
        if key in agg_expected and agg_actual.get(key) != agg_expected.get(key):
            failures.append(
                f"aggregate.{key}: expected={agg_expected.get(key)!r} actual={agg_actual.get(key)!r}"
            )
    return failures


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ralph cross-runtime tool evaluation harness")
    parser.add_argument(
        "--project-root",
        default=".",
        help="Project root (default: current directory)",
    )
    parser.add_argument(
        "--tasks",
        default=_DEFAULT_TASKS,
        help="Path to tool_eval tasks JSON",
    )
    parser.add_argument(
        "--traces",
        default=_DEFAULT_TRACES,
        help="Path to offline traces JSON (offline mode only)",
    )
    parser.add_argument(
        "--mode",
        choices=("offline", "live"),
        default="offline",
        help="offline replays traces; live invokes runtimes (opt-in)",
    )
    parser.add_argument(
        "--runtime",
        action="append",
        dest="runtimes",
        help="Live mode runtime filter (repeatable)",
    )
    parser.add_argument(
        "--task",
        action="append",
        dest="task_ids",
        help="Restrict to specific task ids",
    )
    parser.add_argument(
        "--output",
        default="",
        help="Write JSON report to this path",
    )
    parser.add_argument(
        "--baseline",
        default="",
        help="Compare results to a baseline JSON and exit non-zero on drift",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    project_root = Path(args.project_root).resolve()
    tasks_path = (project_root / args.tasks).resolve()
    traces_path = (project_root / args.traces).resolve()

    try:
        if args.mode == "live":
            scores = run_live_evaluation(
                project_root,
                tasks_path,
                runtimes=args.runtimes,
                task_ids=args.task_ids,
            )
            mode = "live"
            runtimes = _selected_runtimes(args.runtimes)
        else:
            scores = run_offline_evaluation(project_root, tasks_path, traces_path)
            if args.task_ids:
                wanted = {str(item) for item in args.task_ids}
                scores = [score for score in scores if score.task_id in wanted]
            mode = "offline"
            runtimes = []
    except ToolEvalError as exc:
        sys.stderr.write(f"tool_eval failed: {exc}\n")
        return 1

    report = emit_json_report(scores, mode=mode, runtimes=runtimes)
    if args.output:
        out_path = Path(args.output)
        if not out_path.is_absolute():
            out_path = project_root / out_path
        _write_text(out_path, report)
    else:
        sys.stdout.write(report)

    if args.baseline:
        baseline_path = Path(args.baseline)
        if not baseline_path.is_absolute():
            baseline_path = project_root / baseline_path
        baseline = load_json(baseline_path)
        failures = compare_to_baseline(scores, baseline)
        if failures:
            sys.stderr.write("tool_eval baseline drift:\n")
            for line in failures:
                sys.stderr.write(f"- {line}\n")
            return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
