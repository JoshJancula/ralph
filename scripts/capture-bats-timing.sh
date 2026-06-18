#!/usr/bin/env bash
# Record Bats timing for the full suite.
# Produces machine-readable JSON and human-readable summaries under
# .ralph-workspace/logs/bats-timing/.
#
# Usage:
#   bash scripts/capture-bats-timing.sh           # default -j
#   bash scripts/capture-bats-timing.sh -j 8
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BATS_BIN="$REPO_ROOT/bin/bats"
# shellcheck source=scripts/bats-suite-lib.sh
source "$SCRIPT_DIR/bats-suite-lib.sh"

TIMING_DIR="$REPO_ROOT/.ralph-workspace/logs/bats-timing"

JOBS=""
SETUP_FIXTURES=1
SUITE_FILTER="default"

usage() {
  cat <<'EOF'
Usage: bash scripts/capture-bats-timing.sh [options]

Options:
  -j N, --jobs N        Parallel workers (default: min(8, available CPUs))
  --suite MODE          Ignored (extended tier removed). Captures the full suite.
  --no-setup-fixtures   Skip scripts/setup-test-fixtures.sh
  -h, --help            Show this help

Outputs machine-readable JSON and human-readable Markdown summaries under
.ralph-workspace/logs/bats-timing/runs/<timestamp>/. Symlinks latest
pointers are updated after each successful capture.
EOF
}

has_parallel_runner() {
  command -v parallel &>/dev/null || command -v rush &>/dev/null
}

detect_cpu_count() {
  local n=1
  if command -v nproc &>/dev/null; then
    n="$(nproc)"
  elif [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] && command -v sysctl &>/dev/null; then
    n="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  elif command -v getconf &>/dev/null; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  fi
  if [[ ! "$n" =~ ^[1-9][0-9]*$ ]]; then
    n=1
  fi
  echo "$n"
}

default_parallel_jobs() {
  local cpus="$1"
  if [[ "$cpus" -gt 8 ]]; then
    echo 8
  else
    echo "$cpus"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -j | --jobs)
      if [[ $# -lt 2 ]]; then
        echo "capture-bats-timing: -j/--jobs requires an argument" >&2
        exit 1
      fi
      JOBS="$2"
      shift 2
      ;;
    --suite)
      if [[ $# -lt 2 ]]; then
        echo "capture-bats-timing: --suite requires default, extended, or both" >&2
        exit 1
      fi
      SUITE_FILTER="$2"
      if [[ "$SUITE_FILTER" != "default" && "$SUITE_FILTER" != "extended" && "$SUITE_FILTER" != "both" ]]; then
        echo "capture-bats-timing: --suite must be default, extended, or both" >&2
        exit 1
      fi
      shift 2
      ;;
    --no-setup-fixtures)
      SETUP_FIXTURES=0
      shift
      ;;
    *)
      echo "capture-bats-timing: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$JOBS" ]]; then
  if has_parallel_runner; then
    JOBS="$(default_parallel_jobs "$(detect_cpu_count)")"
  else
    JOBS=1
  fi
fi

cd "$REPO_ROOT"
export RALPH_USAGE_RISKS_ACKNOWLEDGED="${RALPH_USAGE_RISKS_ACKNOWLEDGED:-1}"

if [[ "$SETUP_FIXTURES" -eq 1 ]]; then
  bash scripts/setup-test-fixtures.sh
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$TIMING_DIR/runs/$stamp"
mkdir -p "$run_dir"

run_one_suite() {
  local mode="$1"
  local label="$2"
  local junit_dir="$run_dir/junit-${label}"
  local wall_file="$run_dir/wall-${label}.txt"
  local log_file="$run_dir/${label}.log"

  local -a files=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    files+=("$line")
  done < <(ralph_bats_suite_files "$REPO_ROOT")

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "capture-bats-timing: no test files found" >&2
    return 1
  fi

  rm -rf "$junit_dir"
  mkdir -p "$junit_dir"

  local start end elapsed
  start="$(date +%s)"
  echo "Running ${label} suite with -j ${JOBS} ..." >&2
  set +e
  if [[ "$JOBS" -eq 1 ]] || ! has_parallel_runner; then
    bats --report-formatter junit -o "$junit_dir" "${files[@]}" >"$log_file" 2>&1
  else
    bats -j "$JOBS" --report-formatter junit -o "$junit_dir" "${files[@]}" >"$log_file" 2>&1
  fi
  local rc=$?
  set -e
  end="$(date +%s)"
  elapsed=$((end - start))
  printf '%s\n' "$elapsed" >"$wall_file"
  echo "${junit_dir}/report.xml|${wall_file}|${elapsed}|${rc}|${label}"
}

run_python_summary() {
  local default_report="$1"
  local default_wall="$2"
  local default_elapsed="$3"
  local default_rc="$4"
  local extended_report="$5"
  local extended_wall="$6"
  local extended_elapsed="$7"
  local extended_rc="$8"
  local summary_json="$9"
  local summary_md="${10}"
  local stamp="${11}"

  python3 - \
    "$default_report" "$default_wall" "$default_elapsed" "$default_rc" \
    "$extended_report" "$extended_wall" "$extended_elapsed" "$extended_rc" \
    "$summary_json" "$summary_md" "$stamp" <<'PYEOF'
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

def load_report(path):
    if not path or not Path(path).exists():
        return [], []
    root = ET.parse(path).getroot()
    tests = []
    files = []
    for suite in root.findall("testsuite"):
        file_name = suite.get("name", "unknown")
        try:
            file_sec = float(suite.get("time", "0") or 0)
        except ValueError:
            file_sec = 0.0
        files.append({
            "file": file_name,
            "seconds": round(file_sec, 3),
            "tests": int(suite.get("tests", "0") or 0),
        })
        for case in suite.findall("testcase"):
            name = case.get("name", "")
            try:
                sec = float(case.get("time", "0") or 0)
            except ValueError:
                sec = 0.0
            tests.append({
                "file": file_name,
                "name": name,
                "seconds": round(sec, 3),
            })
    tests.sort(key=lambda r: r["seconds"], reverse=True)
    files.sort(key=lambda r: r["seconds"], reverse=True)
    return tests, files

default_report, default_wall, default_elapsed, default_rc = sys.argv[1:5]
extended_report, extended_wall, extended_elapsed, extended_rc = sys.argv[5:9]
summary_json, summary_md, stamp = sys.argv[9:12]

default_elapsed = int(default_elapsed)
default_rc = int(default_rc)
extended_elapsed = int(extended_elapsed)
extended_rc = int(extended_rc)

d_tests, d_files = load_report(default_report)
e_tests, e_files = load_report(extended_report)

summary = {
    "captured_at_utc": stamp,
    "default_suite": {
        "wall_seconds": default_elapsed,
        "bats_seconds": round(sum(t["seconds"] for t in d_tests), 3),
        "exit_code": default_rc,
        "total_tests": len(d_tests),
        "slowest_files": d_files[:25],
        "slowest_tests": d_tests[:25],
    },
    "extended_suite": {
        "wall_seconds": extended_elapsed,
        "bats_seconds": round(sum(t["seconds"] for t in e_tests), 3),
        "exit_code": extended_rc,
        "total_tests": len(e_tests),
        "slowest_files": e_files[:25],
        "slowest_tests": e_tests[:25],
    },
}

Path(summary_json).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

def fmt_file_table(rows, limit=15):
    lines = ["| file | seconds | tests |", "| --- | ---: | ---: |"]
    for r in rows[:limit]:
        lines.append(f"| `{r['file']}` | {r['seconds']} | {r['tests']} |")
    return "\n".join(lines) + "\n"

def fmt_test_table(rows, limit=15):
    lines = ["| test | file | seconds |", "| --- | --- | ---: |"]
    for r in rows[:limit]:
        lines.append(f"| `{r['name']}` | `{r['file']}` | {r['seconds']} |")
    return "\n".join(lines) + "\n"

def suite_section(label, elapsed, bats_sec, rc, files, tests):
    lines = [
        f"## {label} suite\n",
        f"- **Wall time:** {elapsed}s",
        f"- **Bats-reported time:** {bats_sec}s",
        f"- **Exit code:** {rc}",
        f"- **Total tests:** {len(tests)}\n",
        "### Slowest files\n",
        fmt_file_table(files),
        "### Slowest tests\n",
        fmt_test_table(tests),
    ]
    return "\n".join(lines)

md = f"""# Bats timing summary (PLAN39)

Captured: `{stamp}` (UTC)

{suite_section("Default", default_elapsed, summary["default_suite"]["bats_seconds"], default_rc, d_files, d_tests)}

{suite_section("Extended", extended_elapsed, summary["extended_suite"]["bats_seconds"], extended_rc, e_files, e_tests)}

## Commands

```bash
bash scripts/capture-bats-timing.sh --suite default
bash scripts/capture-bats-timing.sh --suite extended
bash scripts/capture-bats-timing.sh
```

Machine-readable summary: `{summary_json}`
"""

Path(summary_md).write_text(md, encoding="utf-8")
print(summary_json)
PYEOF
}

DEFAULT_REPORT=""
DEFAULT_WALL=""
DEFAULT_ELAPSED=0
DEFAULT_RC=0
EXTENDED_REPORT=""
EXTENDED_WALL=""
EXTENDED_ELAPSED=0
EXTENDED_RC=0

if [[ "$SUITE_FILTER" == "default" || "$SUITE_FILTER" == "both" || "$SUITE_FILTER" == "extended" ]]; then
  RESULT="$(run_one_suite default default)"
  IFS='|' read -r DEFAULT_REPORT DEFAULT_WALL DEFAULT_ELAPSED DEFAULT_RC _label <<<"$RESULT"
fi

EXTENDED_REPORT=""
EXTENDED_WALL=""
EXTENDED_ELAPSED=0
EXTENDED_RC=0

SUMMARY_JSON="$run_dir/summary.json"
SUMMARY_MD="$run_dir/summary.md"

run_python_summary \
  "$DEFAULT_REPORT" "$DEFAULT_WALL" "$DEFAULT_ELAPSED" "$DEFAULT_RC" \
  "$EXTENDED_REPORT" "$EXTENDED_WALL" "$EXTENDED_ELAPSED" "$EXTENDED_RC" \
  "$SUMMARY_JSON" "$SUMMARY_MD" "$stamp"

ln -sf "runs/$stamp/summary.json" "$TIMING_DIR/latest.json"
ln -sf "runs/$stamp/summary.md" "$TIMING_DIR/latest.txt"

echo "Wrote $SUMMARY_JSON" >&2
echo "Wrote $SUMMARY_MD" >&2