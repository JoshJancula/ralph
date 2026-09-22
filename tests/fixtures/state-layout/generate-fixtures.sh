#!/usr/bin/env bash
set -euo pipefail

target="${1:?usage: generate-fixtures.sh <target-dir>}"
rm -rf "$target"

# --- Layout 1 (legacy top-level homes) --------------------------------------
mkdir -p \
  "$target/v1/logs/demo/runs/plan-1" \
  "$target/v1/logs/demo/runs/child-1" \
  "$target/v1/graph-runs/demo/graph-1" \
  "$target/v1/workflow-runs/wf-1" \
  "$target/v1/sessions/demo" \
  "$target/v1/artifacts/demo" \
  "$target/v1/mystery"
printf 'abc\n' >"$target/v1/logs/demo/runs/plan-1/output.log"
printf '{"run_id":"plan-1","plan_key":"demo","status":"done","plan_path":"","parent":{"workflow_run_id":null,"graph_run_id":null,"stage_id":null},"paths":{"artifacts_dir":"artifacts/demo"}}\n' \
  >"$target/v1/logs/demo/runs/plan-1/run-manifest.json"
printf '{"run_id":"child-1","plan_key":"demo","status":"done","plan_path":"","parent":{"workflow_run_id":"wf-1","graph_run_id":null,"stage_id":"build"},"paths":{"artifacts_dir":"artifacts/demo"}}\n' \
  >"$target/v1/logs/demo/runs/child-1/run-manifest.json"
printf 'index\n' >"$target/v1/logs/demo/runs/index.jsonl"
printf '{"run_id":"legacy","plan_key":"demo","status":"legacy"}\n' \
  >"$target/v1/logs/demo/plan-usage-summary.json"
printf '{"runId":"graph-1","status":"succeeded","schemaVersion":3}\n' \
  >"$target/v1/graph-runs/demo/graph-1/run.json"
printf '{"runId":"wf-1","state":"succeeded","workflowId":"demo"}\n' \
  >"$target/v1/workflow-runs/wf-1/run.json"
mkdir -p "$target/v1/delegated-runs"
printf 'session\n' >"$target/v1/sessions/demo/session-id.txt"
printf 'artifact\n' >"$target/v1/artifacts/demo/handoff.md"
printf 'unknown\n' >"$target/v1/mystery/retained.txt"

# --- Mixed layout (v2 catalog + shared dirs; still readable as layout 1 for
#     any path that lacks a layoutVersion:2 catalog) -------------------------
mkdir -p \
  "$target/mixed/runs/run-2/stages/plan/attempts/run-2" \
  "$target/mixed/runs/run-2/stages/build/attempts/child-2" \
  "$target/mixed/runs/run-2/engine/workflow" \
  "$target/mixed/runs/run-2/engine/graph" \
  "$target/mixed/runs/run-2/inputs" \
  "$target/mixed/cache/tool-results/demo" \
  "$target/mixed/cache/indexes" \
  "$target/mixed/internal/sessions/demo" \
  "$target/mixed/artifacts/demo" \
  "$target/mixed/odd"
printf '{"kind":"ralph_run_catalog","layoutVersion":2,"runKind":"workflow","runId":"run-2","parent":null,"status":"running","artifactNamespace":"demo","task":"ship it","stages":[{"stageId":"build","attemptId":"child-2","status":"done"}]}\n' \
  >"$target/mixed/runs/run-2/run.json"
printf 'attempt\n' >"$target/mixed/runs/run-2/stages/plan/attempts/run-2/output.log"
printf '{"run_id":"child-2","plan_key":"demo","status":"done","plan_path":"","parent":{"workflow_run_id":"run-2","graph_run_id":null,"stage_id":"build"},"paths":{"artifacts_dir":"artifacts/demo"}}\n' \
  >"$target/mixed/runs/run-2/stages/build/attempts/child-2/run-manifest.json"
# Dangling symlink for expired-evidence coverage (not counted by find -type f).
ln -s "/nonexistent/ralph-expired-target" \
  "$target/mixed/runs/run-2/stages/build/attempts/child-2/expired-link"
printf 'workflow\n' >"$target/mixed/runs/run-2/engine/workflow/run.json"
printf 'graph\n' >"$target/mixed/runs/run-2/engine/graph/run.json"
printf 'index\n' >"$target/mixed/cache/indexes/runs.jsonl"
printf 'result\n' >"$target/mixed/cache/tool-results/demo/result.txt"
printf 'session\n' >"$target/mixed/internal/sessions/demo/id.txt"
printf 'artifact\n' >"$target/mixed/artifacts/demo/output.md"
printf 'odd\n' >"$target/mixed/odd/file.txt"
ln -s "$target/v1" "$target/mixed/external-v1-link"
