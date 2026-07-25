#!/usr/bin/env bash
# PLAN39 baseline: full-suite wall times at -j 4/8 and junit-derived rankings.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/bats-suite-lib.sh
source "$SCRIPT_DIR/bats-suite-lib.sh"
TIMING_DIR="$REPO_ROOT/.ralph-workspace/logs/bats-timing"
ARTIFACT="$REPO_ROOT/.ralph-workspace/artifacts/PLAN39/bats-runtime-baseline.md"

mkdir -p "$TIMING_DIR" "$(dirname "$ARTIFACT")"
cd "$REPO_ROOT"
export RALPH_USAGE_RISKS_ACKNOWLEDGED="${RALPH_USAGE_RISKS_ACKNOWLEDGED:-1}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
SUMMARY_JSON="$TIMING_DIR/baseline-${stamp}.json"

BATS_ARGS=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  BATS_ARGS+=("$line")
done < <(ralph_bats_suite_files "$REPO_ROOT")

if ! command -v parallel &>/dev/null && ! command -v rush &>/dev/null; then
  echo "capture-bats-timing-baseline: GNU parallel or rush required for -j runs" >&2
  exit 1
fi

bash scripts/setup-test-fixtures.sh

run_suite() {
  local jobs="$1"
  local outdir="$TIMING_DIR/junit-j${jobs}-${stamp}"
  local wall_file="$TIMING_DIR/wall-j${jobs}-${stamp}.txt"
  local start end elapsed
  rm -rf "$outdir"
  mkdir -p "$outdir"
  start="$(date +%s)"
  echo "Running full suite with -j ${jobs} (junit -> ${outdir})" >&2
  set +e
  bats -j "$jobs" --report-formatter junit -o "$outdir" "${BATS_ARGS[@]}" >/dev/null
  local rc=$?
  set -e
  end="$(date +%s)"
  elapsed=$((end - start))
  printf '%s\n' "$elapsed" >"$wall_file"
  echo "${outdir}/report.xml|${wall_file}|${elapsed}|${rc}"
}

suite_j4="$(run_suite 4)"
suite_j8="$(run_suite 8)"

IFS='|' read -r report_j4 wall_j4 elapsed_j4 rc_j4 <<<"$suite_j4"
IFS='|' read -r report_j8 wall_j8 elapsed_j8 rc_j8 <<<"$suite_j8"

python3 - "$report_j4" "$report_j8" "$SUMMARY_JSON" "$ARTIFACT" \
  "$elapsed_j4" "$elapsed_j8" "$stamp" "$rc_j4" "$rc_j8" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

report_j4, report_j8, summary_json, artifact = sys.argv[1:5]
elapsed_j4, elapsed_j8, stamp = int(sys.argv[5]), int(sys.argv[6]), sys.argv[7]
rc_j4, rc_j8 = int(sys.argv[8]), int(sys.argv[9])

def load_report(path: str) -> tuple[list[dict], list[dict]]:
    root = ET.parse(path).getroot()
    tests: list[dict] = []
    files: list[dict] = []
    for suite in root.findall("testsuite"):
        file_name = suite.get("name", "unknown")
        try:
            file_sec = float(suite.get("time", "0") or 0)
        except ValueError:
            file_sec = 0.0
        files.append(
            {
                "file": file_name,
                "seconds": round(file_sec, 3),
                "tests": int(suite.get("tests", "0") or 0),
            }
        )
        for case in suite.findall("testcase"):
            name = case.get("name", "")
            try:
                sec = float(case.get("time", "0") or 0)
            except ValueError:
                sec = 0.0
            tests.append(
                {
                    "file": file_name,
                    "name": name,
                    "seconds": round(sec, 3),
                }
            )
    tests.sort(key=lambda r: r["seconds"], reverse=True)
    files.sort(key=lambda r: r["seconds"], reverse=True)
    return tests, files

tests_j8, files_j8 = load_report(report_j8)
tests_j4, files_j4 = load_report(report_j4)

summary = {
    "captured_at_utc": stamp,
    "suite_wall_seconds": {"j4": elapsed_j4, "j8": elapsed_j8},
    "exit_codes": {"j4": rc_j4, "j8": rc_j8},
    "reports": {"j4": report_j4, "j8": report_j8},
    "slowest_files_j8": files_j8[:25],
    "slowest_tests_j8": tests_j8[:25],
    "slowest_tests_j4": tests_j4[:25],
}
Path(summary_json).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

def table(rows: list[dict], col: str, label: str) -> str:
    lines = [f"| {label} | seconds |", "| --- | ---: |"]
    for r in rows:
        lines.append(f"| `{r[col]}` | {r['seconds']} |")
    return "\n".join(lines) + "\n"

def test_table(rows: list[dict]) -> str:
    lines = ["| test | file | seconds |", "| --- | --- | ---: |"]
    for r in rows:
        lines.append(f"| `{r['name']}` | `{r['file']}` | {r['seconds']} |")
    return "\n".join(lines) + "\n"

top_f = files_j8[:15]
top_t = tests_j8[:15]
bullets = []
for r in top_f:
    bullets.append(f"- `{r['file']}` — {r['seconds']}s file total (junit testsuite time)")
for r in top_t:
    bullets.append(f"- `{r['file']}` :: `{r['name']}` — {r['seconds']}s")

md = f"""# Bats runtime baseline (PLAN39)

Captured: `{stamp}` (UTC)

## Full-suite wall time

| Parallel jobs (`-j`) | Wall seconds | Exit code | JUnit report |
| ---: | ---: | ---: | --- |
| 4 | {elapsed_j4} | {rc_j4} | `{report_j4}` |
| 8 | {elapsed_j8} | {rc_j8} | `{report_j8}` |

Commands:

```bash
bash scripts/setup-test-fixtures.sh
bash scripts/run-bats.sh -j 4
bash scripts/run-bats.sh -j 8
```

Or: `bash scripts/capture-bats-timing-baseline.sh`

Machine-readable summary: `{summary_json}`

## Slowest test files (junit testsuite `time`, `-j 8` run)

{table(top_f, "file", "file")}

## Slowest individual tests (`-j 8` run)

{test_table(top_t)}

## Slowest individual tests (`-j 4` run)

{test_table(tests_j4[:15])}

## Major cost centers

Measured top offenders from this capture:

{chr(10).join(bullets)}

Representative slow areas after the suite audit:

- **MCP / proxy:** `smoke-core.bats`, `mcp-setup.bats`, `mcp-proxy-policy.bats`, `mcp-proxy-batch.bats`
- **Run-plan integration:** `run-plan-unified.bats`, `run-plan-invoke.bats`, and related `run-plan-*.bats`
- **Orchestration:** `orchestrator.bats`, `orchestration-handoffs.bats`
"""
Path(artifact).write_text(md, encoding="utf-8")
print(artifact)
PY

ln -sf "$(basename "$SUMMARY_JSON")" "$TIMING_DIR/latest.json"
cp "$ARTIFACT" "$TIMING_DIR/latest-baseline.md"
echo "Wrote $ARTIFACT (j4 rc=${rc_j4}, j8 rc=${rc_j8})" >&2
