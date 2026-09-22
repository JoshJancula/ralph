#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/retention.sh"

@test "plan run retention keeps the newest ten and never removes a running run" {
  local root i
  root="$(mktemp -d)/runs"
  mkdir -p "$root"
  for i in $(seq 1 15); do
    mkdir -p "$root/run-$i"
    printf '{"kind":"ralph_run_manifest","status":"complete"}\n' >"$root/run-$i/run-manifest.json"
    touch -t "202501${i}0000" "$root/run-$i" 2>/dev/null || true
  done
  mkdir -p "$root/running"
  printf '{"kind":"ralph_run_manifest","status":"running"}\n' >"$root/running/run-manifest.json"
  RALPH_RETENTION_LOG_RUNS_MAX_COUNT=10 RALPH_RETENTION_LOG_RUNS_MAX_AGE_DAYS=0 \
    ralph_retention_prune_dirs "$root" 10 0 >/dev/null
  [ "$(find "$root" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 11 ]
  [ -d "$root/run-15" ]
  [ -d "$root/running" ]
}

@test "retention protects plan runs without a manifest and corrupt metadata" {
  local state root
  state="$(mktemp -d)"; root="$state/logs/key/runs"
  mkdir -p "$root/missing" "$root/corrupt"
  printf '{not json}\n' >"$root/corrupt/run-manifest.json"
  run ralph_retention_eligibility "$state" plan-run "$root/missing"
  [ "$status" -ne 0 ]; [ "$output" = "unknown-owner" ]
  run ralph_retention_eligibility "$state" plan-run "$root/corrupt"
  [ "$status" -ne 0 ]; [ "$output" = "corrupt-metadata" ]
}

@test "retention failure is isolated from the caller exit status" {
  run bash -c 'ralph_retention_auto_prune() { return 1; }; ralph_retention_auto_prune /tmp key ns || true; exit 7'
  [ "$status" -eq 7 ]
}
