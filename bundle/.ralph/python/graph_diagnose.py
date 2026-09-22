#!/usr/bin/env python3
"""Map gate failures to owning write scopes and repair lanes (v2-feedback-routing).

Two-stage diagnosis: deterministic path ownership first (matching a failing
step's implicated files against each repair lane's declared writeScopes),
optionally asking Jev (graph.lane-ownership) when a finding's files match more
than one lane, then falling back to a delegation-disabled router/diagnostic
agent only when ownership is still ambiguous. Never uses the carried
"confidence" field to decide ownership -- it is diagnostic metadata only.
Ladder confidence values are calibrated from the graph.lane-ownership
registry escalateThreshold so there is one place to tune them.

Reads gate-result.json (schemaVersion 1, produced by graph-gate.sh) and each
step's bounded log file, never the unbounded raw step output: log reads are
capped at LOG_READ_MAX_BYTES and the resulting failureSummary is capped again
at SUMMARY_MAX_CHARS, so a malicious or oversized log can never grow the
diagnosis artifact (or a later prompt built from it) without bound.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Dict, List, Optional, Sequence, Tuple

from graph_changeset import CaptureError, atomic_write, in_scope, validate_scopes
from graph_source_snapshot import canonical_json

SCHEMA_VERSION = 1
KIND = "graph-diagnosis"

# Defense in depth: read at most this many bytes of a step's log file before
# any sanitization/truncation, regardless of the file's actual size on disk.
LOG_READ_MAX_BYTES = 4000
# The failureSummary field embedded in diagnosis.json (and later injected
# into a repair lane's prompt) never exceeds this many characters.
SUMMARY_MAX_CHARS = 500
# Cap on how many candidate file paths a single finding can carry, so a log
# crafted to list thousands of paths cannot blow up the artifact.
MAX_FILES_PER_FINDING = 20

# Optional Jev question set for the ambiguous-ownership tier only.
_JEV_QUESTION_SET_ID = "graph.lane-ownership"
# Fallback when the registry is missing; matches current escalateThreshold.
_DEFAULT_ESCALATE_THRESHOLD = 0.6

# Conservative relative-path extraction: no leading '/', no '..' traversal,
# no whitespace, must contain a path separator and end in a plausible
# extension. This is intentionally narrow -- it is fine to miss files a
# human would recognize, but it must never manufacture a path outside the
# project (which would make ownership resolution meaningless or unsafe).
_FILE_PATTERN = re.compile(r"(?<![\w./-])([A-Za-z0-9_][\w./-]*/[\w.-]+\.[A-Za-z0-9]{1,8})(?![\w./-])")
_CONTROL_CHARS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


class DiagnoseError(Exception):
    pass


def _sanitize(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return _CONTROL_CHARS.sub("", text)


def _read_bounded_log(path: Optional[Path]) -> str:
    if path is None or not path.is_file():
        return ""
    with path.open("rb") as stream:
        raw = stream.read(LOG_READ_MAX_BYTES)
    return _sanitize(raw.decode("utf-8", errors="replace"))


def _summarize(bounded_text: str) -> str:
    text = bounded_text.strip()
    if len(text) <= SUMMARY_MAX_CHARS:
        return text
    return text[: SUMMARY_MAX_CHARS - len("...[truncated]")] + "...[truncated]"


def _extract_files(bounded_text: str) -> List[str]:
    found: List[str] = []
    seen = set()
    for match in _FILE_PATTERN.finditer(bounded_text):
        candidate = match.group(1)
        pure = PurePosixPath(candidate)
        if pure.is_absolute() or ".." in pure.parts:
            continue
        if candidate in seen:
            continue
        seen.add(candidate)
        found.append(candidate)
        if len(found) >= MAX_FILES_PER_FINDING:
            break
    return found


def _changesets_for_files(files: Sequence[str], changesets: Sequence[dict]) -> List[str]:
    ids: List[str] = []
    file_set = set(files)
    if not file_set:
        return ids
    for changeset in changesets:
        changed_paths = {
            str(change.get("path", "")) for change in changeset.get("changes", []) if change.get("path")
        }
        if changed_paths & file_set:
            node_id = changeset.get("nodeId", "")
            attempt_id = changeset.get("attemptId", "")
            ids.append(f"{node_id}#{attempt_id}" if attempt_id else str(node_id))
    return ids


def _lane_scopes(lanes: Sequence[dict]) -> Dict[str, List[str]]:
    resolved: Dict[str, List[str]] = {}
    for lane in lanes:
        lane_id = str(lane.get("id", ""))
        if not lane_id:
            raise DiagnoseError("repair lane missing id")
        scopes = lane.get("writeScopes")
        if not scopes:
            raise DiagnoseError(f"repair lane {lane_id!r} has no writeScopes to own findings with")
        resolved[lane_id] = validate_scopes(scopes)
    return resolved


def _candidate_lanes(files: Sequence[str], lane_scopes: Dict[str, List[str]]) -> List[str]:
    candidates = []
    for lane_id, scopes in lane_scopes.items():
        if any(in_scope(path, scopes) for path in files):
            candidates.append(lane_id)
    return sorted(candidates)


def _escalate_threshold() -> float:
    """Read graph.lane-ownership escalateThreshold; fall back to the historical default."""
    try:
        import jev_client as jev
    except ImportError:
        return _DEFAULT_ESCALATE_THRESHOLD
    try:
        value, code = jev.policy_threshold(_JEV_QUESTION_SET_ID, "escalate")
    except Exception:
        return _DEFAULT_ESCALATE_THRESHOLD
    if code != 0 or value is None:
        return _DEFAULT_ESCALATE_THRESHOLD
    return float(value)


def _ladder_confidence(kind: str) -> float:
    """Diagnostic confidence for the deterministic ownership ladder.

    Derived from registry escalateThreshold so calibration lives in one place.
    With the current placeholder escalateThreshold (0.6) this preserves the
    historical values: no-files 0.0, deterministic 0.6, zero-candidates 0.2,
    ambiguous 0.4.
    """
    esc = _escalate_threshold()
    if kind == "no-files":
        return 0.0
    if kind == "deterministic":
        return esc
    if kind == "zero-candidates":
        # Round so escalateThreshold 0.6 yields the historical exact 0.2
        # (raw 0.6/3 is a repeating float).
        return round(esc / 3.0, 1)
    if kind == "ambiguous":
        # Same rounding for historical exact 0.4 when escalateThreshold is 0.6.
        return round(esc * 2.0 / 3.0, 1)
    return 0.0


def _jev_lane_ownership_questions(
    base_questions: Dict[str, Any], candidates: Sequence[str]
) -> Dict[str, Any]:
    """Clone registry questions with owner.criteria filled from candidate lane IDs."""
    owner = dict(base_questions.get("owner") or {})
    owner["criteria"] = {
        lane_id: f"Candidate repair lane: {lane_id}" for lane_id in candidates
    }
    return {"owner": owner}


def _jev_ownership_state(
    command: str, files: Sequence[str], failure_summary: str, candidates: Sequence[str]
) -> str:
    """Bounded state text for graph.lane-ownership (never re-expands raw logs)."""
    parts = [
        f"command: {command}",
        f"files: {', '.join(files)}",
        f"candidates: {', '.join(candidates)}",
        f"summary: {failure_summary}",
    ]
    return _summarize("\n".join(parts))


def _try_jev_assign_owner(
    candidates: Sequence[str], state_text: str
) -> Optional[Tuple[str, float]]:
    """Ask graph.lane-ownership; return (owner, confidence) only on confident in-scope act.

    Unavailable / gather / fallback / shadow / out-of-candidate answers return None
    so the finding stays ambiguous for the existing router-agent path.
    """
    if len(candidates) < 2:
        return None
    try:
        import jev_client as jev
    except ImportError:
        return None
    try:
        if not jev.available():
            return None
        base_questions, q_code = jev.policy_questions(_JEV_QUESTION_SET_ID)
        if q_code != 0 or not isinstance(base_questions, dict):
            return None
        questions = _jev_lane_ownership_questions(base_questions, candidates)
        request, b_code = jev.build_request(state_text, questions)
        if b_code != 0 or request is None:
            return None
        request = dict(request)
        request["questionSetId"] = _JEV_QUESTION_SET_ID
        response, p_code = jev.post_systemone(request)
        if p_code != 0 or not isinstance(response, dict):
            return None
        answers = response.get("answers")
        if not isinstance(answers, dict):
            return None
        decision, d_code = jev.policy_decide(_JEV_QUESTION_SET_ID, answers)
        if d_code != 0 or not isinstance(decision, dict):
            return None
        if decision.get("decision") != "act":
            return None
        owner_ans = answers.get("owner")
        chosen = ""
        if isinstance(owner_ans, dict):
            chosen = str(owner_ans.get("choice") or "")
        if not chosen:
            chosen = str(decision.get("chosen") or "")
        # Defense in depth: registry criteria for this set are empty (filled at
        # call time), so policy_decide cannot enforce option-not-offered itself.
        if chosen not in candidates:
            return None
        conf_raw = decision.get("confidence")
        try:
            confidence = float(conf_raw) if conf_raw is not None else _ladder_confidence("ambiguous")
        except (TypeError, ValueError):
            confidence = _ladder_confidence("ambiguous")
        return chosen, confidence
    except Exception:
        return None


def analyze(
    gate_result: dict,
    lanes: Sequence[dict],
    changesets: Sequence[dict],
    log_root: Optional[Path],
) -> dict:
    if gate_result.get("schemaVersion") != 1:
        raise DiagnoseError("unsupported gate-result schemaVersion")
    lane_scopes = _lane_scopes(lanes)
    outcome = gate_result.get("outcome", "")
    findings: List[dict] = []

    if outcome == "error":
        # Infrastructure failure: not a code-ownership problem. One finding,
        # no owner, nothing routed to any lane.
        findings.append(
            {
                "command": "",
                "failureSummary": _summarize(str(gate_result.get("errorReason", "gate infrastructure error"))),
                "files": [],
                "changesets": [],
                "confidence": _ladder_confidence("no-files"),
                "owner": None,
                "ownerReason": "infrastructure-error",
            }
        )
    else:
        for step in gate_result.get("steps", []):
            step_outcome = step.get("outcome", "")
            if step_outcome == "passed":
                continue
            artifact_rel = step.get("artifactPath", "")
            log_path = None
            if artifact_rel and log_root is not None:
                candidate = (log_root / artifact_rel) if not artifact_rel.startswith("/") else Path(artifact_rel)
                log_path = candidate
            bounded_log = _read_bounded_log(log_path)
            files = _extract_files(bounded_log)
            candidates = _candidate_lanes(files, lane_scopes)
            failure_summary = _summarize(bounded_log)
            command = str(step.get("command", ""))

            if not files:
                owner, owner_reason = None, "no-owner"
                confidence = _ladder_confidence("no-files")
            elif len(candidates) == 1:
                owner, owner_reason = candidates[0], "deterministic-path-match"
                confidence = _ladder_confidence("deterministic")
            elif len(candidates) == 0:
                owner, owner_reason = None, "no-owner"
                confidence = _ladder_confidence("zero-candidates")
            else:
                # Ambiguous ladder tier: optional Jev choice over candidate lanes.
                # Confident in-scope act assigns the owner and skips router dispatch.
                owner, owner_reason = None, "ambiguous"
                confidence = _ladder_confidence("ambiguous")
                state_text = _jev_ownership_state(command, files, failure_summary, candidates)
                jev_hit = _try_jev_assign_owner(candidates, state_text)
                if jev_hit is not None:
                    owner, confidence = jev_hit
                    owner_reason = "jev"

            findings.append(
                {
                    "command": command,
                    "failureSummary": failure_summary,
                    "files": files,
                    "changesets": _changesets_for_files(files, changesets),
                    "confidence": confidence,
                    "owner": owner,
                    "ownerReason": owner_reason,
                    "candidateLanes": candidates,
                }
            )

    lane_assignments: Dict[str, List[int]] = {lane_id: [] for lane_id in lane_scopes}
    ambiguous: List[int] = []
    unassigned: List[int] = []
    for idx, finding in enumerate(findings):
        if finding["owner"]:
            lane_assignments.setdefault(finding["owner"], []).append(idx)
        elif finding["ownerReason"] == "ambiguous":
            ambiguous.append(idx)
        else:
            unassigned.append(idx)

    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND,
        "gateNodeId": gate_result.get("nodeId", ""),
        "gateOutcome": outcome,
        "findings": findings,
        "laneAssignments": lane_assignments,
        "ambiguous": ambiguous,
        "unassigned": unassigned,
    }


def apply_router_decision(diagnosis: dict, decision: dict, lane_scopes: Dict[str, List[str]]) -> dict:
    """Merge a delegation-disabled router/diagnostic agent's decision into an
    existing diagnosis. Only findings already marked "ambiguous" may be
    resolved, and only to a lane that was already a candidate owner for that
    finding's files -- the router breaks a tie between declared write scopes,
    it never grants a lane ownership of a path outside its own scope."""
    findings = diagnosis.get("findings", [])
    ambiguous = set(diagnosis.get("ambiguous", []))
    still_ambiguous: List[int] = []
    lane_assignments: Dict[str, List[int]] = {
        lane_id: list(indices) for lane_id, indices in diagnosis.get("laneAssignments", {}).items()
    }
    unassigned: List[int] = list(diagnosis.get("unassigned", []))

    assignments_by_index: Dict[int, dict] = {}
    for entry in decision.get("assignments", []):
        try:
            idx = int(entry.get("findingIndex"))
        except (TypeError, ValueError):
            continue
        assignments_by_index[idx] = entry

    for idx in sorted(ambiguous):
        finding = findings[idx]
        entry = assignments_by_index.get(idx)
        proposed = str(entry.get("owner", "")) if entry else ""
        candidates = finding.get("candidateLanes", [])
        if entry and proposed and proposed in candidates:
            finding["owner"] = proposed
            finding["ownerReason"] = "router-agent"
            lane_assignments.setdefault(proposed, []).append(idx)
        else:
            # No valid, in-scope decision: stays ambiguous rather than being
            # silently dropped or granted to an out-of-scope lane.
            still_ambiguous.append(idx)

    diagnosis["ambiguous"] = still_ambiguous
    diagnosis["unassigned"] = unassigned
    diagnosis["laneAssignments"] = lane_assignments
    return diagnosis


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def cmd_analyze(args: argparse.Namespace) -> int:
    gate_result = _load_json(Path(args.gate_result))
    lanes = json.loads(args.lanes_json)
    changesets = [
        _load_json(Path(p)) for p in (args.changeset_paths or []) if Path(p).is_file()
    ]
    log_root = Path(args.log_root).resolve() if args.log_root else None
    try:
        diagnosis = analyze(gate_result, lanes, changesets, log_root)
    except (DiagnoseError, CaptureError) as exc:
        print(f"graph-diagnose: {exc}", file=sys.stderr)
        return 1
    output = Path(args.output).resolve()
    atomic_write(output, diagnosis)
    print(canonical_json(diagnosis).decode("utf-8"))
    if diagnosis["ambiguous"]:
        return 2
    return 0


def cmd_apply_router(args: argparse.Namespace) -> int:
    diagnosis = _load_json(Path(args.diagnosis))
    decision = _load_json(Path(args.decision))
    lanes = json.loads(args.lanes_json)
    try:
        lane_scopes = _lane_scopes(lanes)
        merged = apply_router_decision(diagnosis, decision, lane_scopes)
    except (DiagnoseError, CaptureError) as exc:
        print(f"graph-diagnose: {exc}", file=sys.stderr)
        return 1
    output = Path(args.output).resolve()
    atomic_write(output, merged)
    print(canonical_json(merged).decode("utf-8"))
    if merged["ambiguous"]:
        return 2
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="graph_diagnose")
    sub = parser.add_subparsers(dest="command", required=True)

    analyze_parser = sub.add_parser("analyze")
    analyze_parser.add_argument("--gate-result", required=True)
    analyze_parser.add_argument("--lanes-json", required=True)
    analyze_parser.add_argument("--log-root", default="")
    analyze_parser.add_argument("--changeset-paths", nargs="*", default=[])
    analyze_parser.add_argument("--output", required=True)
    analyze_parser.set_defaults(func=cmd_analyze)

    router_parser = sub.add_parser("apply-router")
    router_parser.add_argument("--diagnosis", required=True)
    router_parser.add_argument("--decision", required=True)
    router_parser.add_argument("--lanes-json", required=True)
    router_parser.add_argument("--output", required=True)
    router_parser.set_defaults(func=cmd_apply_router)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except CaptureError as exc:
        print(f"graph-diagnose: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
