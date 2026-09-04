#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "run-bats expands a directory target and executes every contained test" {
  local suite_dir
  suite_dir="$(mktemp -d)"
  mkdir -p "$suite_dir/nested"

  printf '%s\n' '#!/usr/bin/env bats' '@test "first" { true; }' >"$suite_dir/first.bats"
  printf '%s\n' '#!/usr/bin/env bats' '@test "second" { true; }' >"$suite_dir/nested/second.bats"

  run bash "$REPO_ROOT/scripts/run-bats.sh" --no-setup-fixtures -j 2 "$suite_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1..2"* ]]
  [[ "$output" != *"1..0"* ]]
}

# --- Cost tiers -------------------------------------------------------------
#
# The fast and slow tiers must partition the suite exactly. A file that falls
# out of both tiers is a file CI silently stops running, which is the failure
# mode tests/bats/tiers.json exists to prevent.

@test "run-bats tiers partition the suite with no file lost or duplicated" {
  local all fast slow acceptance
  all="$(bash "$REPO_ROOT/scripts/run-bats.sh" --list-suite --tier all)"
  fast="$(bash "$REPO_ROOT/scripts/run-bats.sh" --list-suite --tier fast)"
  slow="$(bash "$REPO_ROOT/scripts/run-bats.sh" --list-suite --tier slow)"
  acceptance="$(bash "$REPO_ROOT/scripts/run-bats.sh" --list-suite --tier acceptance)"

  [ -n "$all" ]
  [ -n "$fast" ]
  [ -n "$slow" ]
  [ -n "$acceptance" ]

  local n_all n_fast n_slow n_acc
  n_all="$(printf '%s\n' "$all" | wc -l | tr -d ' ')"
  n_fast="$(printf '%s\n' "$fast" | wc -l | tr -d ' ')"
  n_slow="$(printf '%s\n' "$slow" | wc -l | tr -d ' ')"
  n_acc="$(printf '%s\n' "$acceptance" | wc -l | tr -d ' ')"
  [ "$n_all" -eq "$((n_fast + n_slow + n_acc))" ]

  # Recombining the tiers must reproduce the full suite exactly.
  local combined
  combined="$(printf '%s\n%s\n%s\n' "$fast" "$slow" "$acceptance" | LC_ALL=C sort)"
  [ "$combined" = "$(printf '%s\n' "$all" | LC_ALL=C sort)" ]
}

@test "the acceptance tier holds no file the slow or fast tier also runs" {
  local slow acceptance fast overlap
  fast="$(bash "$REPO_ROOT/scripts/run-bats.sh" --list-suite --tier fast | LC_ALL=C sort)"
  slow="$(bash "$REPO_ROOT/scripts/run-bats.sh" --list-suite --tier slow | LC_ALL=C sort)"
  acceptance="$(bash "$REPO_ROOT/scripts/run-bats.sh" --list-suite --tier acceptance | LC_ALL=C sort)"

  overlap="$(LC_ALL=C comm -12 <(printf '%s\n' "$acceptance") <(printf '%s\n' "$slow"))"
  [ -z "$overlap" ]
  overlap="$(LC_ALL=C comm -12 <(printf '%s\n' "$acceptance") <(printf '%s\n' "$fast"))"
  [ -z "$overlap" ]
}

@test "run-bats tier defaults to the fast suite" {
  # agents/rules/testing-workflow.md: the bare command runs the fast tier, which
  # is the set CI gates every push on. --tier all is the opt-in superset.
  local default_suite fast all
  default_suite="$(bash "$REPO_ROOT/scripts/run-bats.sh" --list-suite)"
  fast="$(bash "$REPO_ROOT/scripts/run-bats.sh" --list-suite --tier fast)"
  all="$(bash "$REPO_ROOT/scripts/run-bats.sh" --list-suite --tier all)"
  [ "$default_suite" = "$fast" ]
  [ "$default_suite" != "$all" ]
}

@test "every file named in tiers.json still exists on disk" {
  # A renamed or deleted test file left in the manifest would silently shrink
  # the slow tier without shrinking the fast tier, hiding lost coverage.
  local f missing=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ ! -f "$REPO_ROOT/$f" ]]; then
      echo "tiers.json names a missing file: $f" >&2
      missing=1
    fi
  done < <(sed -n 's/.*"file"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/tests/bats/tiers.json")
  [ "$missing" -eq 0 ]
}

@test "run-bats acceptance tier is not empty and holds only heavy files" {
  # The acceptance tier exists to keep multi-minute end-to-end replays out of
  # every routine run. If it empties out, they have leaked back in.
  local acceptance
  acceptance="$(bash "$REPO_ROOT/scripts/run-bats.sh" --list-suite --tier acceptance)"
  [ -n "$acceptance" ]
  [[ "$acceptance" == *"workflow-plan-runs.bats"* ]]
}

@test "run-bats rejects an unknown tier" {
  run bash "$REPO_ROOT/scripts/run-bats.sh" --no-setup-fixtures --tier bogus --list-suite
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown tier"* ]]
}

@test "run-bats rejects --tier combined with explicit paths" {
  run bash "$REPO_ROOT/scripts/run-bats.sh" --no-setup-fixtures --tier fast tests/bats/run-bats-runner.bats
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be combined with explicit test paths"* ]]
}

# --- Fast-tier cost budget --------------------------------------------------
#
# The fast tier is what CI gates every push on, so a file the checked-in timing
# baseline records as expensive must not sit in it. These exercise the parser,
# the report and the manifest contract against tiny fixtures -- never against
# the repository suite, which would cost more than the budget being protected.

# A throwaway repo root holding just the two scripts under test and a fixture
# manifest, so run-bats.sh resolves REPO_ROOT to the fixture.
_budget_fixture_root() {
  local root="$1" measured="$2"
  mkdir -p "$root/scripts" "$root/tests/bats"
  cp "$REPO_ROOT/scripts/run-bats.sh" "$REPO_ROOT/scripts/bats-suite-lib.sh" "$root/scripts/"
  printf '%s\n' '#!/usr/bin/env bats' '@test "cheap" { true; }' >"$root/tests/bats/cheap.bats"
  printf '%s\n' '#!/usr/bin/env bats' '@test "heavy" { true; }' >"$root/tests/bats/heavy.bats"
  cat >"$root/tests/bats/tiers.json" <<EOF
{
  "schemaVersion": 3,
  "thresholdMinutes": 1,
  "fastBudget": {
    "testSeconds": 60,
    "fileSeconds": 60
  },
  "measured": [
$measured
  ],
  "acceptance": [
  ],
  "slow": [
$3
  ]
}
EOF
}

@test "fast-tier budget flags a file whose slowest test reaches the test budget" {
  local root; root="$(mktemp -d)"
  _budget_fixture_root "$root" \
    '    { "file": "tests/bats/heavy.bats", "seconds": 65.0, "maxTestSeconds": 61.0 },
    { "file": "tests/bats/cheap.bats", "seconds": 2.0, "maxTestSeconds": 1.0 }' \
    ''
  source "$REPO_ROOT/scripts/bats-suite-lib.sh"
  local out; out="$(ralph_bats_fast_budget_violations "$root")"
  [[ "$out" == *"tests/bats/heavy.bats"* ]]
  [[ "$out" == *"test 61.0s >= 60s"* ]]
  [[ "$out" != *"cheap.bats"* ]]
  rm -rf "$root"
}

@test "fast-tier budget flags a file whose aggregate reaches the file budget" {
  local root; root="$(mktemp -d)"
  # No single test is over budget; the file total is.
  _budget_fixture_root "$root" \
    '    { "file": "tests/bats/heavy.bats", "seconds": 75.0, "maxTestSeconds": 10.0 },
    { "file": "tests/bats/cheap.bats", "seconds": 2.0, "maxTestSeconds": 1.0 }' \
    ''
  source "$REPO_ROOT/scripts/bats-suite-lib.sh"
  local out; out="$(ralph_bats_fast_budget_violations "$root")"
  [[ "$out" == *"tests/bats/heavy.bats"* ]]
  [[ "$out" == *"aggregate budget"* ]]
  rm -rf "$root"
}

@test "listing an over-budget file as slow is the sanctioned exemption" {
  local root; root="$(mktemp -d)"
  _budget_fixture_root "$root" \
    '    { "file": "tests/bats/heavy.bats", "seconds": 75.0, "maxTestSeconds": 61.0 }' \
    '    { "file": "tests/bats/heavy.bats", "baselineMinutes": 1.25 }'
  source "$REPO_ROOT/scripts/bats-suite-lib.sh"
  # The exemption works by removing the file from the fast tier entirely.
  local fast; fast="$(ralph_bats_tier_files "$root" fast)"
  [[ "$fast" != *"heavy.bats"* ]]
  [ -z "$(ralph_bats_fast_budget_violations "$root")" ]
  rm -rf "$root"
}

@test "an unmeasured file is not enforced against" {
  # Absent baseline data must not be read as a violation, or adding a new test
  # file would break --tier fast until someone re-ran the timing capture.
  local root; root="$(mktemp -d)"
  _budget_fixture_root "$root" '' ''
  source "$REPO_ROOT/scripts/bats-suite-lib.sh"
  [ -z "$(ralph_bats_fast_budget_violations "$root")" ]
  rm -rf "$root"
}

@test "run-bats --tier fast refuses a manifest recorded over budget" {
  local root; root="$(mktemp -d)"
  _budget_fixture_root "$root" \
    '    { "file": "tests/bats/heavy.bats", "seconds": 65.0, "maxTestSeconds": 61.0 }' \
    ''
  run bash "$root/scripts/run-bats.sh" --no-setup-fixtures --tier fast --list-suite
  [ "$status" -ne 0 ]
  [[ "$output" == *"over budget"* ]]
  [[ "$output" == *"tests/bats/heavy.bats"* ]]
  [[ "$output" == *"slow"* ]]
  rm -rf "$root"
}

# --- Cost baseline report ---------------------------------------------------

_write_fixture_junit() {
  cat >"$1" <<'XML'
<testsuites>
  <testsuite name="tests/bats/cheap.bats" tests="2">
    <testcase name="quick one" time="0.5"/>
    <testcase name="quick two" time="1.25"/>
  </testsuite>
  <testsuite name="tests/bats/mid.bats" tests="2">
    <testcase name="twelve second test" time="12.0"/>
    <testcase name="short" time="2.0"/>
  </testsuite>
  <testsuite name="tests/bats/heavy.bats" tests="2">
    <testcase name="over budget test" time="61.5"/>
    <testcase name="filler" time="5.0"/>
  </testsuite>
  <testsuite name="tests/bats/exempted.bats" tests="1">
    <testcase name="slow but exempt" time="120.0"/>
  </testsuite>
</testsuites>
XML
}

_run_cost_report() {
  local dir="$1" fast_list="$2"
  printf '%s\n' $fast_list >"$dir/fast.txt"
  run python3 "$REPO_ROOT/scripts/bats-cost-report.py" \
    --junit "$dir/report.xml" --fast-files "$dir/fast.txt" \
    --out-json "$dir/out.json" --out-md "$dir/out.md" \
    --stamp FIXTURE --test-budget 60 --file-budget 60 --report-floor 10
}

@test "cost report lists every test at or above the reporting floor" {
  local d; d="$(mktemp -d)"; _write_fixture_junit "$d/report.xml"
  _run_cost_report "$d" "tests/bats/cheap.bats tests/bats/mid.bats"

  # Every test >= 10s, not a top-N slice: the 12s fast test and the 120s
  # exempt one both appear; nothing under the floor does.
  local names
  names="$(python3 -c "
import json;d=json.load(open('$d/out.json'))
print(' | '.join(t['name'] for t in d['testsAtOrAboveFloor']))")"
  [[ "$names" == *"twelve second test"* ]]
  [[ "$names" == *"slow but exempt"* ]]
  [[ "$names" != *"quick one"* ]]
  [[ "$names" != *"short"* ]]
  rm -rf "$d"
}

@test "cost report fails the audit when a fast test reaches the budget" {
  local d; d="$(mktemp -d)"; _write_fixture_junit "$d/report.xml"
  _run_cost_report "$d" "tests/bats/cheap.bats tests/bats/mid.bats tests/bats/heavy.bats"

  [ "$status" -ne 0 ]
  [[ "$output" == *"over budget"* ]]
  [[ "$output" == *"over budget test"* ]]
  python3 -c "
import json,sys;d=json.load(open('$d/out.json'))
sys.exit(0 if d['auditPassed'] is False else 1)"
  grep -q 'FAIL' "$d/out.md"
  rm -rf "$d"
}

@test "cost report does not fault an over-budget file that is tier-exempt" {
  # exempted.bats is 120s but is not in the fast list, so it is reported as a
  # heavy file without failing the audit. Otherwise the slow tier could never
  # hold anything.
  local d; d="$(mktemp -d)"; _write_fixture_junit "$d/report.xml"
  _run_cost_report "$d" "tests/bats/cheap.bats tests/bats/mid.bats"

  [ "$status" -eq 0 ]
  python3 -c "
import json,sys
d=json.load(open('$d/out.json'))
over=[f['file'] for f in d['filesAtOrAboveFileBudget']]
assert 'tests/bats/exempted.bats' in over, over
assert d['auditPassed'] is True
assert d['violations']['tests'] == [] and d['violations']['files'] == []"
  rm -rf "$d"
}

@test "cost report identifies files at or above the aggregate budget" {
  local d; d="$(mktemp -d)"; _write_fixture_junit "$d/report.xml"
  _run_cost_report "$d" "tests/bats/cheap.bats tests/bats/mid.bats"

  # heavy.bats totals 66.5s across two tests; mid.bats totals 14s and must not
  # be listed. File cost is the sum of its tests, not the suite wall time.
  python3 -c "
import json
d=json.load(open('$d/out.json'))
over={f['file']: f['seconds'] for f in d['filesAtOrAboveFileBudget']}
assert over.get('tests/bats/heavy.bats') == 66.5, over
assert 'tests/bats/mid.bats' not in over, over"
  rm -rf "$d"
}
