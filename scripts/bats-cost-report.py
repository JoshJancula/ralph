#!/usr/bin/env python3
"""Build the Bats cost baseline from a JUnit report and audit the fast tier.

Kept as its own file rather than a heredoc so the parser, the report and the
audit can be exercised against a tiny fixture JUnit XML instead of the
repository suite.

Exit status is 1 when the fast tier violates its cost budget, so the capture
job fails loudly rather than quietly recording an over-budget tier.
"""
import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def _seconds(node, attr="time"):
    try:
        return round(float(node.get(attr, "0") or 0), 3)
    except (TypeError, ValueError):
        return 0.0


def normalize(name, repo_root):
    """JUnit records absolute paths; the tier manifest and the fast list are
    repo-relative. Normalize so the two can be compared and the checked-in
    baseline stays portable across checkouts."""
    if not name:
        return name
    if repo_root and name.startswith(repo_root.rstrip("/") + "/"):
        return name[len(repo_root.rstrip("/")) + 1:]
    idx = name.find("tests/bats/")
    if idx != -1:
        return name[idx:]
    # Bats sometimes reports a suite as a bare basename. Resolve it against the
    # suite tree so the entry can still be matched to a tier; an ambiguous
    # basename is left alone rather than guessed at.
    if "/" not in name and repo_root:
        matches = sorted(Path(repo_root, "tests", "bats").rglob(name))
        if len(matches) == 1:
            return str(matches[0].relative_to(repo_root))
    return name


def parse_junit(path, repo_root=""):
    """Return (tests, files) from a Bats JUnit report.

    tests: [{file, name, seconds}]  files: [{file, seconds, tests}]
    A file's cost is the sum of its tests, not the suite's own wall time: under
    parallelism the suite attribute includes time the file spent waiting.
    """
    root = ET.parse(path).getroot()
    suites = root.findall(".//testsuite")
    tests, files = [], []
    for suite in suites:
        name = normalize(suite.get("name", "unknown"), repo_root)
        cases = suite.findall("testcase")
        for case in cases:
            tests.append({
                "file": name,
                "name": case.get("name", ""),
                "seconds": _seconds(case),
            })
        files.append({
            "file": name,
            "seconds": round(sum(_seconds(c) for c in cases), 3),
            "tests": len(cases),
        })
    tests.sort(key=lambda r: r["seconds"], reverse=True)
    files.sort(key=lambda r: r["seconds"], reverse=True)
    return tests, files


def load_fast_set(path):
    if not path or not Path(path).exists():
        return None
    entries = [l.strip() for l in Path(path).read_text().splitlines() if l.strip()]
    return set(entries)


def is_fast(file_name, fast_set):
    """A JUnit suite name may be a bare basename or a repo-relative path."""
    if fast_set is None:
        return False
    if file_name in fast_set:
        return True
    base = os.path.basename(file_name)
    return any(os.path.basename(f) == base for f in fast_set)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--junit", required=True)
    ap.add_argument("--repo-root", default="")
    ap.add_argument("--fast-files")
    ap.add_argument("--out-json", required=True)
    ap.add_argument("--out-md", required=True)
    ap.add_argument("--run-json")
    ap.add_argument("--stamp", default="")
    ap.add_argument("--wall-seconds", type=int, default=0)
    ap.add_argument("--exit-code", type=int, default=0)
    ap.add_argument("--test-budget", type=float, default=60.0)
    ap.add_argument("--file-budget", type=float, default=60.0)
    ap.add_argument("--report-floor", type=float, default=10.0)
    args = ap.parse_args()

    tests, files = parse_junit(args.junit, args.repo_root)
    fast_set = load_fast_set(args.fast_files)

    for row in tests:
        row["tier"] = "fast" if is_fast(row["file"], fast_set) else "exempt"
    for row in files:
        row["tier"] = "fast" if is_fast(row["file"], fast_set) else "exempt"

    # Every test at or above the reporting floor, not just a top-N slice.
    over_floor = [t for t in tests if t["seconds"] >= args.report_floor]
    # Files whose aggregate cost reaches the one-minute threshold.
    over_file_budget = [f for f in files if f["seconds"] >= args.file_budget]

    # Audit: the fast tier may not hold an over-budget test or file.
    bad_tests = [t for t in tests
                 if t["tier"] == "fast" and t["seconds"] >= args.test_budget]
    bad_files = [f for f in files
                 if f["tier"] == "fast" and f["seconds"] >= args.file_budget]
    violations = {"tests": bad_tests, "files": bad_files}
    ok = not bad_tests and not bad_files

    baseline = {
        "capturedAtUtc": args.stamp,
        "wallSeconds": args.wall_seconds,
        "batsSeconds": round(sum(t["seconds"] for t in tests), 3),
        "suiteExitCode": args.exit_code,
        "totalTests": len(tests),
        "totalFiles": len(files),
        "budget": {
            "testBudgetSeconds": args.test_budget,
            "fileBudgetSeconds": args.file_budget,
            "reportFloorSeconds": args.report_floor,
        },
        "auditPassed": ok,
        "violations": violations,
        "testsAtOrAboveFloor": over_floor,
        "filesAtOrAboveFileBudget": over_file_budget,
        "files": files,
        "tests": tests,
    }
    Path(args.out_json).write_text(json.dumps(baseline, indent=2) + "\n", encoding="utf-8")
    if args.run_json:
        Path(args.run_json).write_text(json.dumps(baseline, indent=2) + "\n", encoding="utf-8")

    def table(rows, cols, fmt):
        out = ["| " + " | ".join(c[0] for c in cols) + " |",
               "| " + " | ".join(c[1] for c in cols) + " |"]
        out += [fmt(r) for r in rows]
        return "\n".join(out) + "\n"

    lines = [
        "# Bats cost baseline\n",
        f"Captured: `{args.stamp}` (UTC) | wall {args.wall_seconds}s | "
        f"suite exit {args.exit_code}\n",
        f"Budget: a `fast` test must stay under **{args.test_budget:g}s**, and a "
        f"`fast` file under **{args.file_budget:g}s** aggregate. "
        f"Files and tests at or above those belong in `slow` or `acceptance`.\n",
        f"- Total tests: {len(tests)} across {len(files)} files",
        f"- Bats-reported time: {baseline['batsSeconds']}s",
        f"- Audit: **{'PASS' if ok else 'FAIL'}**\n",
    ]

    if not ok:
        lines.append("## Budget violations (fast tier)\n")
        if bad_tests:
            lines.append(f"### Tests at or above {args.test_budget:g}s\n")
            lines.append(table(bad_tests, [("test", "---"), ("file", "---"), ("seconds", "---:")],
                               lambda r: f"| `{r['name']}` | `{r['file']}` | {r['seconds']} |"))
        if bad_files:
            lines.append(f"### Files at or above {args.file_budget:g}s aggregate\n")
            lines.append(table(bad_files, [("file", "---"), ("seconds", "---:"), ("tests", "---:")],
                               lambda r: f"| `{r['file']}` | {r['seconds']} | {r['tests']} |"))

    lines.append(f"## Every test at or above {args.report_floor:g}s ({len(over_floor)})\n")
    lines.append(table(over_floor,
                       [("test", "---"), ("file", "---"), ("seconds", "---:"), ("tier", "---")],
                       lambda r: f"| `{r['name']}` | `{r['file']}` | {r['seconds']} | {r['tier']} |")
                 if over_floor else "_None._\n")

    lines.append(f"\n## Files at or above {args.file_budget:g}s aggregate ({len(over_file_budget)})\n")
    lines.append(table(over_file_budget,
                       [("file", "---"), ("seconds", "---:"), ("tests", "---:"), ("tier", "---")],
                       lambda r: f"| `{r['file']}` | {r['seconds']} | {r['tests']} | {r['tier']} |")
                 if over_file_budget else "_None._\n")

    Path(args.out_md).write_text("\n".join(lines), encoding="utf-8")

    if not ok:
        print(f"bats-cost-report: fast tier over budget "
              f"({len(bad_tests)} test(s), {len(bad_files)} file(s))", file=sys.stderr)
        for t in bad_tests:
            print(f"  test {t['seconds']}s >= {args.test_budget:g}s: "
                  f"{t['file']} :: {t['name']}", file=sys.stderr)
        for f in bad_files:
            print(f"  file {f['seconds']}s >= {args.file_budget:g}s: {f['file']}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
