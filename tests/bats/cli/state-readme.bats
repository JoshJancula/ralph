#!/usr/bin/env bats
source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

STATE_PATHS="$REPO_ROOT/bundle/.ralph/bash-lib/state-paths.sh"
STATE_README="$REPO_ROOT/bundle/.ralph/bash-lib/state-readme.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  root="$(mktemp -d)"
}

teardown() { rm -rf "$root"; }

@test "managed READMEs generate at catalog admission with marker and relative run links" {
  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    root="$3"
    export RALPH_STATE_LAYOUT=2
    mkdir -p "$root/artifacts" "$root/cache" "$root/internal" "$root/plans"
    ralph_state_catalog_update "$root" run-a \
      ".runKind = \"plan\" | .status = \"running\" | .task = \"ship it\" | .artifactNamespace = \"demo\" | .stages = [{stageId:\"plan\",attemptId:\"run-a\",status:\"running\"}]"
    [[ -f "$root/README.md" ]]
    IFS= read -r first <"$root/README.md"
    [[ "$first" == "<!-- ralph-managed: do not edit; regenerated -->" ]]
    [[ -f "$root/runs/run-a/README.md" ]]
    grep -q "runs/run-a/README.md" "$root/README.md"
    grep -q "Task: ship it" "$root/runs/run-a/README.md"
    grep -q "Status: running" "$root/runs/run-a/README.md"
    # Absolute paths must not appear in either README.
    ! grep -E "/tmp/|/var/|/Users/|$root" "$root/README.md"
    ! grep -E "/tmp/|/var/|/Users/|$root" "$root/runs/run-a/README.md"
  ' _ "$STATE_PATHS" "$STATE_README" "$root"
  [ "$status" -eq 0 ]
}

@test "unmanaged README.md is preserved; Ralph writes README.ralph.md instead" {
  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    root="$3"
    export RALPH_STATE_LAYOUT=2
    printf "operator notes\nkeep me\n" >"$root/README.md"
    mkdir -p "$root/runs/run-b"
    printf "hand-written run notes\n" >"$root/runs/run-b/README.md"
    ralph_state_catalog_update "$root" run-b \
      ".runKind = \"workflow\" | .status = \"succeeded\" | .task = \"done\""
    # Originals untouched.
    grep -q "operator notes" "$root/README.md"
    grep -q "hand-written run notes" "$root/runs/run-b/README.md"
    # Managed sidecars created.
    [[ -f "$root/README.ralph.md" ]]
    [[ -f "$root/runs/run-b/README.ralph.md" ]]
    IFS= read -r first <"$root/README.ralph.md"
    [[ "$first" == "<!-- ralph-managed: do not edit; regenerated -->" ]]
    grep -q "run-b" "$root/README.ralph.md"
    grep -q "Task: done" "$root/runs/run-b/README.ralph.md"
  ' _ "$STATE_PATHS" "$STATE_README" "$root"
  [ "$status" -eq 0 ]
}

@test "external state root READMEs use relative links only" {
  external="$root/external state root"
  mkdir -p "$external"
  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    root="$3"
    export RALPH_STATE_LAYOUT=2
    mkdir -p "$root/artifacts/demo" "$root/runs"
    printf "out\n" >"$root/artifacts/demo/handoff.md"
    ralph_state_catalog_update "$root" run-ext \
      ".runKind = \"plan\" | .status = \"running\" | .artifactNamespace = \"demo\" | .task = \"external\" | .stages = [{stageId:\"plan\",attemptId:\"run-ext\",status:\"running\"}]"
    root_readme="$root/README.md"
    run_readme="$root/runs/run-ext/README.md"
    [[ -f "$root_readme" && -f "$run_readme" ]]
    # Links stay relative (no scheme, no leading slash to absolute roots).
    ! grep -E "\]\(/|\]\([A-Za-z]:|\]\(file:" "$root_readme"
    ! grep -E "\]\(/|\]\([A-Za-z]:|\]\(file:" "$run_readme"
    grep -q "](runs/run-ext/README.md)" "$root_readme"
    grep -q "](../../artifacts/demo)" "$run_readme"
    # The absolute external path itself must not appear.
    ! grep -F "$root" "$root_readme"
    ! grep -F "$root" "$run_readme"
  ' _ "$STATE_PATHS" "$STATE_README" "$external"
  [ "$status" -eq 0 ]
}

@test "missing evidence is rendered as missing without omitting sections" {
  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    root="$3"
    export RALPH_STATE_LAYOUT=2
    ralph_state_catalog_update "$root" run-miss \
      ".runKind = \"plan\" | .status = \"failed\" | .task = null | .artifactNamespace = \"gone\" | .stages = [{stageId:\"plan\",attemptId:\"run-miss\",status:\"failed\"}]"
    body="$(cat "$root/runs/run-miss/README.md")"
    printf "%s\n" "$body" | grep -q "Task: missing"
    printf "%s\n" "$body" | grep -q "artifacts/gone"
    printf "%s\n" "$body" | grep -q ": missing"
    printf "%s\n" "$body" | grep -q "## Inputs"
    printf "%s\n" "$body" | grep -q "## Outputs"
    printf "%s\n" "$body" | grep -q "## Decisions"
    printf "%s\n" "$body" | grep -q "## Verification"
    # Must not contain approval payloads or env dumps.
    ! printf "%s\n" "$body" | grep -qiE "decisionPayload|RALPH_|lease|APPROVAL_SECRET"
  ' _ "$STATE_PATHS" "$STATE_README" "$root"
  [ "$status" -eq 0 ]
}

@test "status change regenerates managed run README" {
  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    root="$3"
    export RALPH_STATE_LAYOUT=2
    ralph_state_catalog_update "$root" run-s \
      ".runKind = \"workflow\" | .status = \"running\" | .task = \"t\""
    grep -q "Status: running" "$root/runs/run-s/README.md"
    ralph_state_catalog_update "$root" run-s ".status = \"succeeded\""
    grep -q "Status: succeeded" "$root/runs/run-s/README.md"
  ' _ "$STATE_PATHS" "$STATE_README" "$root"
  [ "$status" -eq 0 ]
}
