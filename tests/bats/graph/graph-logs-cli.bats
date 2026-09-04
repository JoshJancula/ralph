#!/usr/bin/env bats
# Graph logs CLI: select a ledger-owned contained attempt stream, with
# v1 namespace fallback when the v2 file is absent.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
bats_require_minimum_version 1.5.0

GRAPH_RUN_SH="$REPO_ROOT/bundle/.ralph/graph-run.sh"

setup() {
  TMPD="$(mktemp -d)"
  WORKSPACE="$TMPD/ws"
  mkdir -p "$WORKSPACE"
  NAMESPACE="logs-ns"
  RUN_ID="run-001"
  GRAPH_JSON="$TMPD/graph.json"
  PLAN_FILE="$WORKSPACE/logs.plan.md"
  printf '# logs select fixture\n' >"$PLAN_FILE"
  jq -n '{
    schemaVersion: 1,
    ralphVersion: "test",
    name: "logs-select",
    namespace: "logs-ns",
    maxParallel: 1,
    failurePolicy: "cancel",
    nodes: [
      {
        id: "impl",
        type: "agent",
        dependsOn: [],
        derivedFrom: "stage",
        stage: {
          id: "impl",
          runtime: "cursor",
          role: "implementation",
          workspaceMode: "snapshot"
        }
      }
    ],
    edges: []
  }' >"$GRAPH_JSON"
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 1
  RUN_DIR="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  STATE_ROOT="$(graph_state_state_root "$WORKSPACE")"
}

teardown() {
  if [[ -n "${FOLLOW_PID:-}" ]]; then
    kill -TERM "$FOLLOW_PID" 2>/dev/null || true
    sleep 0.05
    kill -KILL "$FOLLOW_PID" 2>/dev/null || true
    wait "$FOLLOW_PID" 2>/dev/null || true
    FOLLOW_PID=""
  fi
  unset RALPH_GRAPH_FOLLOW_INTERVAL RALPH_GRAPH_FOLLOW_MAX_POLLS 2>/dev/null || true
  rm -rf "$TMPD"
}

logs_cmd() {
  bash "$GRAPH_RUN_SH" logs "$@" --workspace "$WORKSPACE"
}

write_attempt_logs() {
  local node_id="$1" attempt_id="$2"
  local log_dir="$RUN_DIR/logs/nodes/${node_id}/${attempt_id}"
  mkdir -p "$log_dir" "$RUN_DIR/nodes"
  printf 'runner-%s-1\nrunner-%s-2\nrunner-%s-3\n' "$attempt_id" "$attempt_id" "$attempt_id" \
    >"$log_dir/runner.log"
  printf 'agent-%s-1\nagent-%s-2\n' "$attempt_id" "$attempt_id" >"$log_dir/agent.log"
  printf '{"attempt":"%s"}\n' "$attempt_id" >"$log_dir/usage.json"
  jq -nc \
    --arg nodeId "$node_id" \
    --arg attemptId "$attempt_id" \
    --arg runner "logs/nodes/${node_id}/${attempt_id}/runner.log" \
    --arg agent "logs/nodes/${node_id}/${attempt_id}/agent.log" \
    --arg usage "logs/nodes/${node_id}/${attempt_id}/usage.json" \
    '{
      schemaVersion: 3,
      nodeId: $nodeId,
      status: "succeeded",
      lastAttemptId: $attemptId,
      attempts: [{
        attemptId: $attemptId,
        logPaths: {runner:$runner, agent:$agent, usage:$usage}
      }]
    }' >"$RUN_DIR/nodes/${node_id}.json"
}

@test "logs cli select --help exits 0" {
  run bash "$GRAPH_RUN_SH" logs --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -- '--node'
  printf '%s\n' "$output" | grep -q -- '--stream'
  printf '%s\n' "$output" | grep -q -- '--tail'
}

@test "logs cli select errors without --namespace" {
  run logs_cmd --run "$RUN_ID" --node impl
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'namespace'
}

@test "logs cli select errors without --run" {
  run logs_cmd --namespace "$NAMESPACE" --node impl
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'run'
}

@test "logs cli select errors without --node" {
  run logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'node'
}

@test "logs cli select defaults to last-attempt agent stream" {
  write_attempt_logs impl impl-1
  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl
  [ "$status" -eq 0 ]
  [ "$output" = $'agent-impl-1-1\nagent-impl-1-2' ]
  printf '%s\n' "$stderr" | grep -q '# graph logs'
}

@test "logs cli select --attempt reads that attempt not the latest" {
  local aid1="impl-1" aid2="impl-2"
  mkdir -p "$RUN_DIR/logs/nodes/impl/$aid1" "$RUN_DIR/logs/nodes/impl/$aid2" "$RUN_DIR/nodes"
  printf 'agent-%s-1\nagent-%s-2\n' "$aid1" "$aid1" >"$RUN_DIR/logs/nodes/impl/$aid1/agent.log"
  printf 'agent-%s-1\nagent-%s-2\n' "$aid2" "$aid2" >"$RUN_DIR/logs/nodes/impl/$aid2/agent.log"
  jq -n \
    --arg a1 "$aid1" --arg a2 "$aid2" \
    '{
      schemaVersion: 3,
      nodeId: "impl",
      status: "succeeded",
      lastAttemptId: $a2,
      attempts: [
        {attemptId:$a1, logPaths:{agent:("logs/nodes/impl/"+$a1+"/agent.log")}},
        {attemptId:$a2, logPaths:{agent:("logs/nodes/impl/"+$a2+"/agent.log")}}
      ]
    }' >"$RUN_DIR/nodes/impl.json"

  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl \
    --attempt impl-1 --stream agent
  [ "$status" -eq 0 ]
  [ "$output" = $'agent-impl-1-1\nagent-impl-1-2' ]

  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream agent
  [ "$status" -eq 0 ]
  [ "$output" = $'agent-impl-2-1\nagent-impl-2-2' ]
}

@test "logs cli select --stream runner prints the runner log" {
  write_attempt_logs impl impl-1
  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream runner
  [ "$status" -eq 0 ]
  [ "$output" = $'runner-impl-1-1\nrunner-impl-1-2\nrunner-impl-1-3' ]
}

@test "logs cli select --stream usage prints usage json" {
  write_attempt_logs impl impl-1
  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream usage
  [ "$status" -eq 0 ]
  [ "$output" = '{"attempt":"impl-1"}' ]
}

@test "logs cli select --tail N prints only the last N lines" {
  write_attempt_logs impl impl-1
  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl \
    --stream runner --tail 2
  [ "$status" -eq 0 ]
  [ "$output" = $'runner-impl-1-2\nrunner-impl-1-3' ]
}

@test "logs cli select defaults to a bounded recent tail" {
  local log_dir index
  log_dir="$RUN_DIR/logs/nodes/impl/impl-1"
  mkdir -p "$log_dir" "$RUN_DIR/nodes"
  for index in $(seq 1 100); do
    printf 'agent-line-%s\n' "$index"
  done >"$log_dir/agent.log"
  jq -nc ' {
    schemaVersion: 3,
    nodeId: "impl",
    status: "succeeded",
    lastAttemptId: "impl-1",
    attempts: [{attemptId:"impl-1",logPaths:{agent:"logs/nodes/impl/impl-1/agent.log"}}]
  }' >"$RUN_DIR/nodes/impl.json"

  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q '^agent-line-1$'
  printf '%s\n' "$output" | grep -q '^agent-line-21$'
  printf '%s\n' "$output" | grep -q '^agent-line-100$'
}

@test "logs cli select rejects an unknown stream" {
  write_attempt_logs impl impl-1
  run logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream stderr
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'stream'
}

@test "logs cli select rejects an unknown attempt" {
  write_attempt_logs impl impl-1
  run logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --attempt missing-9
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'attempt'
}

@test "logs cli select rejects a missing node" {
  run logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node missing
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'node'
}

@test "logs cli select rejects absolute ledger logPaths" {
  mkdir -p "$RUN_DIR/nodes" "$TMPD/outside"
  printf 'secret\n' >"$TMPD/outside/stolen.log"
  jq -nc --arg abs "$TMPD/outside/stolen.log" '{
    schemaVersion: 3,
    nodeId: "impl",
    status: "succeeded",
    lastAttemptId: "impl-1",
    attempts: [{attemptId:"impl-1",logPaths:{runner:$abs,agent:$abs,usage:$abs}}]
  }' >"$RUN_DIR/nodes/impl.json"
  run logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream runner
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'contained'
  printf '%s\n' "$output" | grep -qv 'secret'
}

@test "logs cli select rejects dot-dot ledger logPaths" {
  mkdir -p "$RUN_DIR/nodes" "$TMPD/outside"
  printf 'secret\n' >"$TMPD/outside/stolen.log"
  jq -n '{
    schemaVersion: 3,
    nodeId: "impl",
    status: "succeeded",
    lastAttemptId: "impl-1",
    attempts: [{
      attemptId: "impl-1",
      logPaths: {runner:"logs/../../../outside/stolen.log"}
    }]
  }' >"$RUN_DIR/nodes/impl.json"
  run logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream runner
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'contained'
  printf '%s\n' "$output" | grep -qv 'secret'
}

@test "logs cli select rejects a symlink-escape ledger path" {
  mkdir -p "$RUN_DIR/nodes" "$RUN_DIR/logs/nodes/impl/impl-1" "$TMPD/outside"
  printf 'secret\n' >"$TMPD/outside/stolen.log"
  ln -s "$TMPD/outside/stolen.log" "$RUN_DIR/logs/nodes/impl/impl-1/runner.log"
  jq -n '{
    schemaVersion: 3,
    nodeId: "impl",
    status: "succeeded",
    lastAttemptId: "impl-1",
    attempts: [{
      attemptId: "impl-1",
      logPaths: {runner:"logs/nodes/impl/impl-1/runner.log"}
    }]
  }' >"$RUN_DIR/nodes/impl.json"
  run logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream runner
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qv 'secret'
}

@test "logs cli select does not read an undeclared on-disk log file" {
  mkdir -p "$RUN_DIR/logs/nodes/impl/impl-1" "$RUN_DIR/nodes"
  printf 'undeclared\n' >"$RUN_DIR/logs/nodes/impl/impl-1/runner.log"
  jq -n '{
    schemaVersion: 3,
    nodeId: "impl",
    status: "succeeded",
    lastAttemptId: "impl-1",
    attempts: [{attemptId:"impl-1"}]
  }' >"$RUN_DIR/nodes/impl.json"
  run logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream runner
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qv 'undeclared'
}

@test "logs cli select prefers ledger-owned v2 files over a v1 decoy" {
  write_attempt_logs impl impl-1
  mkdir -p "$STATE_ROOT/logs/$NAMESPACE/nodes/impl"
  printf 'v1-decoy\n' >"$STATE_ROOT/logs/$NAMESPACE/nodes/impl/impl-1.log"
  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream runner
  [ "$status" -eq 0 ]
  [ "$output" = $'runner-impl-1-1\nrunner-impl-1-2\nrunner-impl-1-3' ]
  printf '%s\n' "$output" | grep -qv 'v1-decoy'
}

@test "logs cli refuses an unowned namespace log when the run-owned log is missing" {
  mkdir -p "$RUN_DIR/nodes" "$STATE_ROOT/logs/$NAMESPACE/nodes/impl"
  jq -n '{
    schemaVersion: 3,
    nodeId: "impl",
    status: "succeeded",
    lastAttemptId: "impl-1",
    attempts: [{
      attemptId: "impl-1",
      logPaths: {
        runner: "logs/nodes/impl/impl-1/runner.log",
        agent: "logs/nodes/impl/impl-1/agent.log",
        usage: "logs/nodes/impl/impl-1/usage.json"
      }
    }]
  }' >"$RUN_DIR/nodes/impl.json"
  printf 'v1-runner\n' >"$STATE_ROOT/logs/$NAMESPACE/nodes/impl/impl-1.log"
  printf 'v1-agent\n' >"$STATE_ROOT/logs/$NAMESPACE/nodes/impl/agent.log"
  printf '{"v1":true}\n' >"$STATE_ROOT/logs/$NAMESPACE/nodes/impl/plan-usage-summary.json"

  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream runner
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"graph log not found"* ]]

  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream agent
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"graph log not found"* ]]

  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream usage
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"graph log not found"* ]]
}

@test "logs cli rejects a prior node ledger rather than reading an unowned namespace log" {
  mkdir -p "$RUN_DIR/nodes" "$STATE_ROOT/logs/$NAMESPACE/nodes/impl"
  local node_file="$RUN_DIR/nodes/impl.json"
  printf '%s\n' '{"schemaVersion":1,"nodeId":"impl","status":"succeeded","lastAttemptId":"impl-1","attempts":[{"attemptId":"impl-1","outcome":"succeeded"}]}' \
    >"$node_file"
  local before
  before="$(cat "$node_file")"
  printf 'historical-agent\n' >"$STATE_ROOT/logs/$NAMESPACE/nodes/impl/agent.log"

  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream agent
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"requires schemaVersion 3"* ]]
  [ "$(cat "$node_file")" = "$before" ]
  [ "$(jq -r '.schemaVersion' "$node_file")" = "1" ]
}

@test "logs cli select is read-only on the v2 ledger" {
  write_attempt_logs impl impl-1
  local node_file="$RUN_DIR/nodes/impl.json"
  local before
  before="$(cat "$node_file")"
  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream runner --tail 1
  [ "$status" -eq 0 ]
  [ "$output" = "runner-impl-1-3" ]
  [ "$(cat "$node_file")" = "$before" ]
}

write_running_attempt() {
  local node_id="$1" attempt_id="$2" create_files="${3:-1}"
  local log_dir="$RUN_DIR/logs/nodes/${node_id}/${attempt_id}"
  mkdir -p "$log_dir" "$RUN_DIR/nodes"
  if [[ "$create_files" == "1" ]]; then
    printf 'runner-%s-1\n' "$attempt_id" >"$log_dir/runner.log"
    printf 'agent-%s-1\n' "$attempt_id" >"$log_dir/agent.log"
    printf '{"attempt":"%s"}\n' "$attempt_id" >"$log_dir/usage.json"
  fi
  jq -nc \
    --arg nodeId "$node_id" \
    --arg attemptId "$attempt_id" \
    --arg runner "logs/nodes/${node_id}/${attempt_id}/runner.log" \
    --arg agent "logs/nodes/${node_id}/${attempt_id}/agent.log" \
    --arg usage "logs/nodes/${node_id}/${attempt_id}/usage.json" \
    '{
      schemaVersion: 3,
      nodeId: $nodeId,
      status: "running",
      lastAttemptId: $attemptId,
      attempts: [{
        attemptId: $attemptId,
        logPaths: {runner:$runner, agent:$agent, usage:$usage}
      }]
    }' >"$RUN_DIR/nodes/${node_id}.json"
}

mark_attempt_terminal() {
  local node_id="$1" attempt_id="$2" outcome="${3:-succeeded}"
  local node_file="$RUN_DIR/nodes/${node_id}.json"
  jq --arg aid "$attempt_id" --arg outcome "$outcome" \
    '.status = $outcome
     | .attempts = [(.attempts[] | if .attemptId == $aid then . + {outcome:$outcome} else . end)]' \
    "$node_file" >"${node_file}.tmp"
  mv "${node_file}.tmp" "$node_file"
}

# Poll budgets are deliberately generous. run-bats runs 8 files concurrently,
# and under that load a follow subprocess can take well over the old 2s budget
# just to get scheduled and flush its first line. The assertion is unchanged --
# the helper still waits for exactly the same condition -- so a wider budget
# only removes a timing flake, it does not weaken the test.
wait_for_file_match() {
  local file="$1" pattern="$2" attempts="${3:-200}"
  local i=0
  while [[ "$i" -lt "$attempts" ]]; do
    if grep -q -- "$pattern" "$file" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

wait_pid_exit() {
  local pid="$1" attempts="${2:-400}"
  local i=0 st=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
    if [[ "$i" -ge "$attempts" ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 1
    fi
  done
  wait "$pid" || st=$?
  return "$st"
}

attach_cmd() {
  bash "$GRAPH_RUN_SH" attach "$@" --workspace "$WORKSPACE"
}

@test "logs cli follow --help mentions --follow and attach" {
  run bash "$GRAPH_RUN_SH" logs --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -- '--follow'
  run bash "$GRAPH_RUN_SH" attach --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -- 'attach'
  run bash "$GRAPH_RUN_SH" --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -- 'attach'
}

@test "logs cli follow on a terminal attempt prints and exits" {
  write_attempt_logs impl impl-1
  run --separate-stderr logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --follow --stream agent
  [ "$status" -eq 0 ]
  [ "$output" = $'agent-impl-1-1\nagent-impl-1-2' ]
}

@test "logs cli follows a running attempt by default" {
  write_running_attempt impl impl-1
  local out="$TMPD/default-follow.out" log_file="$RUN_DIR/logs/nodes/impl/impl-1/agent.log"
  export RALPH_GRAPH_FOLLOW_INTERVAL=0.05
  export RALPH_GRAPH_FOLLOW_MAX_POLLS=80
  bash "$GRAPH_RUN_SH" logs --namespace "$NAMESPACE" --run "$RUN_ID" --node impl \
    --stream agent --workspace "$WORKSPACE" >"$out" 2>/dev/null &
  FOLLOW_PID=$!
  wait_for_file_match "$out" 'agent-impl-1-1'
  printf 'agent-impl-1-live\n' >>"$log_file"
  wait_for_file_match "$out" 'agent-impl-1-live'
  mark_attempt_terminal impl impl-1 succeeded
  wait_pid_exit "$FOLLOW_PID"
  FOLLOW_PID=""
}

@test "logs cli follow missing log is explicit but nonfatal for an active attempt" {
  write_running_attempt impl impl-1 0
  run logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream agent
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'not found'
  printf '%s\n' "$output" | grep -q 'active'
}

@test "logs cli follow missing log stays fatal for a terminal attempt" {
  write_attempt_logs impl impl-1
  rm -f "$RUN_DIR/logs/nodes/impl/impl-1/agent.log"
  run logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --stream agent --follow
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'not found'
}

@test "logs cli follow prints existing then new lines and exits when the attempt is terminal" {
  write_running_attempt impl impl-1
  local out="$TMPD/follow.out" err="$TMPD/follow.err"
  local log_file="$RUN_DIR/logs/nodes/impl/impl-1/agent.log"
  export RALPH_GRAPH_FOLLOW_INTERVAL=0.05
  export RALPH_GRAPH_FOLLOW_MAX_POLLS=80
  bash "$GRAPH_RUN_SH" logs --namespace "$NAMESPACE" --run "$RUN_ID" --node impl \
    --stream agent --follow --workspace "$WORKSPACE" >"$out" 2>"$err" &
  FOLLOW_PID=$!
  wait_for_file_match "$out" 'agent-impl-1-1'
  printf 'agent-impl-1-2\n' >>"$log_file"
  wait_for_file_match "$out" 'agent-impl-1-2'
  mark_attempt_terminal impl impl-1 succeeded
  wait_pid_exit "$FOLLOW_PID"
  local st=$?
  FOLLOW_PID=""
  [ "$st" -eq 0 ]
  grep -q 'agent-impl-1-1' "$out"
  grep -q 'agent-impl-1-2' "$out"
}

@test "logs cli follow handles truncation and rotation without busy-looping" {
  write_running_attempt impl impl-1
  local out="$TMPD/follow.out" err="$TMPD/follow.err"
  local log_file="$RUN_DIR/logs/nodes/impl/impl-1/agent.log"
  printf 'keep-me\nrotate-src\n' >"$log_file"
  export RALPH_GRAPH_FOLLOW_INTERVAL=0.05
  export RALPH_GRAPH_FOLLOW_MAX_POLLS=80
  bash "$GRAPH_RUN_SH" logs --namespace "$NAMESPACE" --run "$RUN_ID" --node impl \
    --stream agent --follow --workspace "$WORKSPACE" >"$out" 2>"$err" &
  FOLLOW_PID=$!
  wait_for_file_match "$out" 'rotate-src'
  printf 'after-trunc\n' >"$log_file"
  wait_for_file_match "$out" 'after-trunc'
  rm -f "$log_file"
  printf 'after-rotate\n' >"$log_file"
  wait_for_file_match "$out" 'after-rotate'
  mark_attempt_terminal impl impl-1 succeeded
  wait_pid_exit "$FOLLOW_PID"
  local st=$?
  FOLLOW_PID=""
  [ "$st" -eq 0 ]
  grep -q 'keep-me' "$out"
  grep -q 'after-trunc' "$out"
  grep -q 'after-rotate' "$out"
}

@test "logs cli follow sleeps between polls" {
  write_running_attempt impl impl-1
  export RALPH_GRAPH_FOLLOW_INTERVAL=1
  export RALPH_GRAPH_FOLLOW_MAX_POLLS=2
  local start end
  start="$(date +%s)"
  run logs_cmd --namespace "$NAMESPACE" --run "$RUN_ID" --node impl --follow --stream agent
  end="$(date +%s)"
  [ "$status" -eq 0 ]
  [ $((end - start)) -ge 1 ]
}

@test "logs cli follow is interruptible and does not mutate the ledger" {
  write_running_attempt impl impl-1
  local out="$TMPD/follow.out" err="$TMPD/follow.err"
  local node_file="$RUN_DIR/nodes/impl.json" run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  local before_node before_run
  before_node="$(cat "$node_file")"
  before_run="$(cat "$run_file")"
  export RALPH_GRAPH_FOLLOW_INTERVAL=0.05
  export RALPH_GRAPH_FOLLOW_MAX_POLLS=20
  bash "$GRAPH_RUN_SH" logs --namespace "$NAMESPACE" --run "$RUN_ID" --node impl \
    --stream agent --follow --workspace "$WORKSPACE" >"$out" 2>"$err" &
  FOLLOW_PID=$!
  wait_for_file_match "$out" 'agent-impl-1-1'
  # Background bash ignores terminal SIGINT; SIGTERM is the explicit detach signal.
  kill -TERM "$FOLLOW_PID"
  wait_pid_exit "$FOLLOW_PID" || true
  FOLLOW_PID=""
  [ "$(cat "$node_file")" = "$before_node" ]
  [ "$(cat "$run_file")" = "$before_run" ]
}

@test "logs cli follow attach prints status and is read-only" {
  write_attempt_logs impl impl-1
  graph_state_set_run_status "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "succeeded"
  local run_file node_file before_run before_node
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  node_file="$RUN_DIR/nodes/impl.json"
  before_run="$(cat "$run_file")"
  before_node="$(cat "$node_file")"
  run attach_cmd --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'graph status'
  printf '%s\n' "$output" | grep -q "$RUN_ID"
  [ "$(cat "$run_file")" = "$before_run" ]
  [ "$(cat "$node_file")" = "$before_node" ]
}

@test "logs cli follow attach missing events are explicit but nonfatal for an active run" {
  write_running_attempt impl impl-1
  export RALPH_GRAPH_FOLLOW_INTERVAL=0.05
  export RALPH_GRAPH_FOLLOW_MAX_POLLS=2
  local run_file before_run
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  before_run="$(cat "$run_file")"
  run attach_cmd --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'event journal not found'
  printf '%s\n' "$output" | grep -q 'active'
  [ "$(cat "$run_file")" = "$before_run" ]
}

@test "logs cli follow attach exits when the run is terminal and follows new events" {
  write_running_attempt impl impl-1
  local out="$TMPD/attach.out" err="$TMPD/attach.err"
  local events="$RUN_DIR/events.jsonl"
  printf '%s\n' '{"schemaVersion":1,"sequence":1,"event":"run-started","runId":"run-001"}' >"$events"
  export RALPH_GRAPH_FOLLOW_INTERVAL=0.05
  export RALPH_GRAPH_FOLLOW_MAX_POLLS=80
  bash "$GRAPH_RUN_SH" attach --namespace "$NAMESPACE" --run "$RUN_ID" \
    --workspace "$WORKSPACE" >"$out" 2>"$err" &
  FOLLOW_PID=$!
  wait_for_file_match "$out" 'run-started'
  printf '%s\n' '{"schemaVersion":1,"sequence":2,"event":"node-spawn","runId":"run-001","nodeId":"impl"}' >>"$events"
  wait_for_file_match "$out" 'node-spawn'
  graph_state_set_run_status "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "succeeded"
  wait_pid_exit "$FOLLOW_PID"
  local st=$?
  FOLLOW_PID=""
  [ "$st" -eq 0 ]
  grep -q 'graph status' "$out"
  grep -q 'run-started' "$out"
  grep -q 'node-spawn' "$out"
}
