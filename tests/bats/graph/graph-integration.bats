#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

CHANGESET_HELPER="$REPO_ROOT/bundle/.ralph/python/graph_changeset.py"
INTEGRATE_HELPER="$REPO_ROOT/bundle/.ralph/python/graph_integrate.py"

make_changeset() {
  local workspace="$1" baseline="$2" output="$3" node="$4" scopes="$5"
  python3 "$CHANGESET_HELPER" capture --workspace "$workspace" --baseline "$baseline" \
    --output "$output" --node-id "$node" --attempt-id "$node-attempt" \
    --workspace-mode snapshot --base-identity frozen-base --write-scopes-json "$scopes" >/dev/null
}

@test "integrator applies disjoint backend-neutral changesets in declared order and resumes idempotently" {
  local tmpd base baseline left right third fourth integration out conflict first_identity
  tmpd="$(mktemp -d)"
  base="$tmpd/base"
  mkdir -p "$base/src"
  printf 'base-a\n' >"$base/src/a.txt"
  printf 'base-b\n' >"$base/src/b.txt"
  printf 'base-c\n' >"$base/src/c.txt"
  printf 'base-d\n' >"$base/src/d.txt"
  baseline="$tmpd/baseline.json"
  python3 "$CHANGESET_HELPER" baseline --workspace "$base" --output "$baseline" >/dev/null
  cp -R "$base" "$tmpd/left"
  cp -R "$base" "$tmpd/right"
  cp -R "$base" "$tmpd/third"
  cp -R "$base" "$tmpd/fourth"
  printf 'left\n' >"$tmpd/left/src/a.txt"
  printf 'right\n' >"$tmpd/right/src/b.txt"
  printf 'third\n' >"$tmpd/third/src/c.txt"
  printf 'fourth\n' >"$tmpd/fourth/src/d.txt"
  left="$tmpd/manifests/left.json"
  right="$tmpd/manifests/right.json"
  third="$tmpd/manifests/third.json"
  fourth="$tmpd/manifests/fourth.json"
  make_changeset "$tmpd/left" "$baseline" "$left" left '["src/a.txt"]'
  make_changeset "$tmpd/right" "$baseline" "$right" right '["src/b.txt"]'
  make_changeset "$tmpd/third" "$baseline" "$third" third '["src/c.txt"]'
  make_changeset "$tmpd/fourth" "$baseline" "$fourth" fourth '["src/d.txt"]'
  cp -R "$base" "$tmpd/integration"
  integration="$tmpd/integration"
  out="$tmpd/integration.json"
  conflict="$tmpd/conflict.json"

  run env RALPH_GRAPH_INTEGRATION_TEST_INTERRUPT_AFTER=1 python3 "$INTEGRATE_HELPER" \
    --workspace "$integration" --output "$out" --conflict-output "$conflict" \
    --node-id integrate --base-identity frozen-base \
    --manifest "$right" --manifest "$left" --manifest "$third" --manifest "$fourth"
  [ "$status" -ne 0 ]
  [ ! -e "$out" ]

  python3 "$INTEGRATE_HELPER" --workspace "$integration" --output "$out" \
    --conflict-output "$conflict" --node-id integrate --base-identity frozen-base \
    --manifest "$right" --manifest "$left" --manifest "$third" --manifest "$fourth" >/dev/null
  [ "$(cat "$integration/src/a.txt")" = "left" ]
  [ "$(cat "$integration/src/b.txt")" = "right" ]
  [ "$(cat "$integration/src/c.txt")" = "third" ]
  [ "$(cat "$integration/src/d.txt")" = "fourth" ]
  [ "$(jq -c '.appliedOrder' "$out")" = '["right","left","third","fourth"]' ]
  [ ! -e "$conflict" ]
  first_identity="$(jq -r '.resultIdentity' "$out")"

  # Reapplying after a simulated scheduler restart is idempotent.
  python3 "$INTEGRATE_HELPER" --workspace "$integration" --output "$out" \
    --conflict-output "$conflict" --node-id integrate --base-identity frozen-base \
    --manifest "$right" --manifest "$left" --manifest "$third" --manifest "$fourth" >/dev/null
  [ "$(jq -r '.resultIdentity' "$out")" = "$first_identity" ]
}

@test "integrator accepts identical edits and emits structured overlap conflicts without partial success" {
  local tmpd base baseline one same other rename rename2 delete bin1 bin2 integration out conflict
  tmpd="$(mktemp -d)"
  base="$tmpd/base"
  mkdir -p "$base/src"
  printf 'base\n' >"$base/src/value.txt"
  printf 'rename\n' >"$base/src/old.txt"
  printf '\0base\n' >"$base/src/data.bin"
  baseline="$tmpd/baseline.json"
  python3 "$CHANGESET_HELPER" baseline --workspace "$base" --output "$baseline" >/dev/null
  for lane in one same other rename rename2 delete bin1 bin2; do cp -R "$base" "$tmpd/$lane"; done
  printf 'identical\n' >"$tmpd/one/src/value.txt"
  printf 'identical\n' >"$tmpd/same/src/value.txt"
  printf 'divergent\n' >"$tmpd/other/src/value.txt"
  mv "$tmpd/rename/src/old.txt" "$tmpd/rename/src/new.txt"
  mv "$tmpd/rename2/src/old.txt" "$tmpd/rename2/src/alternate.txt"
  rm "$tmpd/delete/src/value.txt"
  printf '\0one\n' >"$tmpd/bin1/src/data.bin"
  printf '\0two\n' >"$tmpd/bin2/src/data.bin"
  one="$tmpd/manifests/one.json"; same="$tmpd/manifests/same.json"
  other="$tmpd/manifests/other.json"; rename="$tmpd/manifests/rename.json"
  rename2="$tmpd/manifests/rename2.json"; delete="$tmpd/manifests/delete.json"
  bin1="$tmpd/manifests/bin1.json"; bin2="$tmpd/manifests/bin2.json"
  make_changeset "$tmpd/one" "$baseline" "$one" one '["src/value.txt"]'
  make_changeset "$tmpd/same" "$baseline" "$same" same '["src/value.txt"]'
  make_changeset "$tmpd/other" "$baseline" "$other" other '["src/value.txt"]'
  make_changeset "$tmpd/rename" "$baseline" "$rename" rename '["src/**"]'
  make_changeset "$tmpd/rename2" "$baseline" "$rename2" rename2 '["src/**"]'
  make_changeset "$tmpd/delete" "$baseline" "$delete" delete '["src/value.txt"]'
  make_changeset "$tmpd/bin1" "$baseline" "$bin1" bin1 '["src/data.bin"]'
  make_changeset "$tmpd/bin2" "$baseline" "$bin2" bin2 '["src/data.bin"]'
  cp -R "$base" "$tmpd/integration"
  integration="$tmpd/integration"; out="$tmpd/out.json"; conflict="$tmpd/conflict.json"

  python3 "$INTEGRATE_HELPER" --workspace "$integration" --output "$out" \
    --conflict-output "$conflict" --node-id integrate --base-identity frozen-base \
    --manifest "$one" --manifest "$same" --manifest "$rename" >/dev/null
  [ "$(cat "$integration/src/value.txt")" = "identical" ]
  [ -f "$integration/src/new.txt" ]

  cp -R "$base" "$tmpd/conflicting"
  run python3 "$INTEGRATE_HELPER" --workspace "$tmpd/conflicting" --output "$tmpd/no-success.json" \
    --conflict-output "$conflict" --node-id integrate --base-identity frozen-base \
    --manifest "$one" --manifest "$other"
  [ "$status" -ne 0 ]
  [ ! -e "$tmpd/no-success.json" ]
  [ -f "$conflict" ]
  [ "$(jq -r '.kind' "$conflict")" = "integration-conflict" ]
  [ "$(jq -r '.conflicts[0].path' "$conflict")" = "src/value.txt" ]
  [ "$(jq '.conflicts[0].hunks | length' "$conflict")" -gt 0 ]
  [ -n "$(jq -r '.conflicts[0].firstChangeset' "$conflict")" ]
  [ "$(cat "$tmpd/conflicting/src/value.txt")" = "base" ]

  run python3 "$INTEGRATE_HELPER" --workspace "$tmpd/conflicting" --output "$tmpd/no-rename.json" \
    --conflict-output "$tmpd/rename-conflict.json" --node-id integrate --base-identity frozen-base \
    --manifest "$rename" --manifest "$rename2"
  [ "$status" -ne 0 ]
  [ "$(jq -r '.conflicts[0].path' "$tmpd/rename-conflict.json")" = "src/old.txt" ]

  run python3 "$INTEGRATE_HELPER" --workspace "$tmpd/conflicting" --output "$tmpd/no-delete.json" \
    --conflict-output "$tmpd/delete-conflict.json" --node-id integrate --base-identity frozen-base \
    --manifest "$one" --manifest "$delete"
  [ "$status" -ne 0 ]
  [ "$(jq -r '.conflicts[0].path' "$tmpd/delete-conflict.json")" = "src/value.txt" ]

  run python3 "$INTEGRATE_HELPER" --workspace "$tmpd/conflicting" --output "$tmpd/no-binary.json" \
    --conflict-output "$tmpd/binary-conflict.json" --node-id integrate --base-identity frozen-base \
    --manifest "$bin1" --manifest "$bin2"
  [ "$status" -ne 0 ]
  [ "$(jq -r '.conflicts[0].path' "$tmpd/binary-conflict.json")" = "src/data.bin" ]
}

@test "integrator rejects wrong-base and compiler requires an isolated integrate node" {
  local tmpd base baseline lane manifest plan payload
  tmpd="$(mktemp -d)"
  base="$tmpd/base"; lane="$tmpd/lane"
  mkdir -p "$base/src"
  printf 'base\n' >"$base/src/a.txt"
  baseline="$tmpd/baseline.json"
  python3 "$CHANGESET_HELPER" baseline --workspace "$base" --output "$baseline" >/dev/null
  cp -R "$base" "$lane"
  printf 'changed\n' >"$lane/src/a.txt"
  manifest="$tmpd/manifest.json"
  make_changeset "$lane" "$baseline" "$manifest" lane '["src/**"]'
  run python3 "$INTEGRATE_HELPER" --workspace "$base" --output "$tmpd/out.json" \
    --conflict-output "$tmpd/conflict.json" --node-id integrate --base-identity wrong \
    --manifest "$manifest"
  [ "$status" -ne 0 ]
  [[ "$output" = *"wrong-base"* ]]
  run python3 "$INTEGRATE_HELPER" --workspace "$base" --output "$tmpd/missing-out.json" \
    --conflict-output "$tmpd/missing-conflict.json" --node-id integrate --base-identity frozen-base \
    --manifest "$tmpd/does-not-exist.json"
  [ "$status" -ne 0 ]
  [[ "$output" = *"predecessor changeset missing"* ]]

  plan="$tmpd/integrate.plan.md"
  cat >"$plan" <<'PLAN'
---
execution: graph
pipeline:
  stages:
    - id: build
      runtime: cursor
      agent: implementation
      workspaceMode: snapshot
      writeScopes: [src/**]
    - id: merge
      type: integrate
      workspaceMode: snapshot
      dependsOn: [build]
todos:
  - id: build-1
    stage: build
    content: build
    status: pending
---
PLAN
  run plan_pipeline_graph_json "$plan"
  [ "$status" -eq 0 ]
  payload="$(printf '%s\n' "$output" | awk 'END { print }')"
  [ "$(printf '%s' "$payload" | jq -r '.nodes[] | select(.id == "merge") | .type')" = "integrate" ]
  sed -i.bak '/id: merge/,/dependsOn/ s/workspaceMode: snapshot/workspaceMode: shared/' "$plan"
  run plan_pipeline_graph_json "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" = *"integrate nodes require snapshot or worktree"* ]]
}
