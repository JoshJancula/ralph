#!/usr/bin/env bash
# Regenerate tests/bats/tiers.json from a measured cost baseline.
#
# The tier split is a cost decision, so it is re-derived from real per-test
# timings rather than hand-maintained. The input is the JSON baseline written
# by scripts/capture-bats-timing.sh:
#
#   bash scripts/capture-bats-timing.sh -j 4
#   bash scripts/update-bats-tiers.sh .ralph-workspace/logs/bats-timing/latest/summary.json
#
# Files whose summed test time meets or exceeds the threshold go in the slow
# tier; everything else is fast. The regenerated manifest also carries the
# per-file "measured" baseline (including each file's slowest single test),
# which is what scripts/run-bats.sh enforces the fast-tier budget against.
#
# Usage:
#   bash scripts/update-bats-tiers.sh <baseline.json> [threshold-minutes]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/bats-suite-lib.sh
source "$SCRIPT_DIR/bats-suite-lib.sh"

BASELINE="${1:-}"
THRESHOLD="${2:-1}"
MANIFEST="$REPO_ROOT/tests/bats/tiers.json"

if [[ -z "$BASELINE" ]]; then
  echo "usage: bash scripts/update-bats-tiers.sh <baseline.json> [threshold-minutes]" >&2
  exit 1
fi
if [[ ! -f "$BASELINE" ]]; then
  echo "update-bats-tiers: no such baseline: $BASELINE" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "update-bats-tiers: python3 is required to read the JSON baseline" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ralph-bats-tiers.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The acceptance tier is a deliberate editorial choice, not a threshold result:
# these are heavy end-to-end replays that stay out of routine runs even if a
# future baseline happens to time them faster. Preserve the existing list so a
# regeneration can never silently promote one back into slow or fast.
ralph_bats_manifest_files "$REPO_ROOT" acceptance >"$WORK/acceptance.txt" || true

python3 - "$BASELINE" "$THRESHOLD" "$WORK/acceptance.txt" "$MANIFEST" "${BASELINE#"$REPO_ROOT"/}" <<'PY'
import json, sys
from pathlib import Path

baseline_path, threshold, acc_path, manifest_path, source_rel = sys.argv[1:6]
threshold = float(threshold)
data = json.loads(Path(baseline_path).read_text())

files = data.get("files") or []
tests = data.get("tests") or []
if not files:
    sys.exit("update-bats-tiers: baseline records no files")

max_test = {}
for t in tests:
    f = t.get("file")
    s = float(t.get("seconds") or 0)
    if f is not None and s > max_test.get(f, 0.0):
        max_test[f] = s

measured = sorted(
    ({"file": f["file"],
      "seconds": round(float(f.get("seconds") or 0), 3),
      "maxTestSeconds": round(max_test.get(f["file"], 0.0), 3)}
     for f in files),
    key=lambda r: r["file"])

acceptance = [l.strip() for l in Path(acc_path).read_text().splitlines() if l.strip()]
acc_set = set(acceptance)

minutes = {m["file"]: round(m["seconds"] / 60.0, 2) for m in measured}
slow = sorted(f for f, mins in minutes.items()
              if mins >= threshold and f not in acc_set)
if not slow:
    sys.exit(f"update-bats-tiers: threshold {threshold}m selected no files; "
             "refusing to empty the slow tier")

def obj_lines(rows, last_comma=False):
    out = []
    for i, line in enumerate(rows):
        sep = "" if i == len(rows) - 1 else ","
        out.append(f"    {line}{sep}")
    return out

# One object per line: scripts/bats-suite-lib.sh parses this manifest with awk
# so that tier selection never depends on jq or python3. Do not reformat.
L = ["{",
     '  "schemaVersion": 3,',
     f'  "thresholdMinutes": {threshold:g},',
     '  "fastBudget": {',
     '    "testSeconds": 60,',
     '    "fileSeconds": 60,',
     '    "note": "A fast-tier test must stay under testSeconds and a fast-tier file under fileSeconds aggregate. scripts/run-bats.sh refuses --tier fast when the measured baseline below records a fast file at or above either limit. The only exemption is listing the file in slow or acceptance."',
     '  },',
     '  "baseline": {',
     f'    "source": "{source_rel}",',
     '    "regeneratedBy": "scripts/update-bats-tiers.sh",',
     '    "note": "Per-file seconds and each file\'s slowest single test, measured from Bats JUnit timing at -j 4. Absolute values scale with the parallelism the baseline was captured at."',
     '  },',
     '  "measured": ['] + obj_lines(
        [f'{{ "file": "{m["file"]}", "seconds": {m["seconds"]}, "maxTestSeconds": {m["maxTestSeconds"]} }}'
         for m in measured]) + [
     '  ],',
     '  "acceptance": ['] + obj_lines(
        [f'{{ "file": "{f}", "baselineMinutes": {minutes.get(f, 0)} }}' for f in acceptance]) + [
     '  ],',
     '  "slow": ['] + obj_lines(
        [f'{{ "file": "{f}", "baselineMinutes": {minutes[f]} }}' for f in slow]) + [
     '  ]',
     '}']
Path(manifest_path).write_text("\n".join(L) + "\n", encoding="utf-8")

fast = len(measured) - len(slow) - len([a for a in acceptance if a in minutes])
print(f"update-bats-tiers: threshold={threshold:g}m measured={len(measured)} "
      f"acceptance={len(acceptance)} slow={len(slow)} fast={fast}")
PY
