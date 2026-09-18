#!/usr/bin/env bats
# Optional stage.execImage / stage.execWorkspaceWrite schema validation and
# containerized verification dispatch. Without execImage, verification stays
# on the host (no Docker). With execImage, only the declared verification
# command is wrapped; agent argv from graph_dispatch_build_argv stays host-side.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/validate-graph-schema.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-dispatch.sh"

VALIDATE_GRAPH_SCHEMA_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/validate-graph-schema.sh"
GRAPH_SCHEMA="$BATS_TEST_DIRNAME/../../../bundle/.ralph/schemas/graph.schema.json"
ARTIFACT_SCHEMA_PY="$BATS_TEST_DIRNAME/../../../bundle/.ralph/python/artifact_json_schema.py"
FIXTURE_DIR="$BATS_TEST_DIRNAME/../../fixtures/graph"
GRAPH_DISPATCH_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-dispatch.sh"

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPD" 2>/dev/null || true
}

@test "validate-graph-schema.sh accepts valid execImage fixtures" {
  local fixture
  for fixture in \
    graph-exec-image-valid.graph.json \
    graph-exec-image-writable.graph.json \
    graph-exec-image-default-write.graph.json \
    graph-exec-image-host-default.graph.json
  do
    run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$FIXTURE_DIR/$fixture"
    [ "$status" -eq 0 ]
  done
}

@test "graph.schema.json accepts valid execImage fixtures" {
  command -v python3 >/dev/null || skip "python3 required"
  local fixture
  for fixture in \
    graph-exec-image-valid.graph.json \
    graph-exec-image-writable.graph.json \
    graph-exec-image-default-write.graph.json \
    graph-exec-image-host-default.graph.json
  do
    run python3 "$ARTIFACT_SCHEMA_PY" validate-final-output \
      --schema "$GRAPH_SCHEMA" \
      --artifact "$FIXTURE_DIR/$fixture"
    [ "$status" -eq 0 ]
  done
}

@test "validate-graph-schema.sh rejects invalid execImage values" {
  local fixture
  for fixture in \
    graph-exec-image-invalid-empty.graph.json \
    graph-exec-image-invalid-type.graph.json \
    graph-exec-image-invalid-unsafe.graph.json \
    graph-exec-image-invalid-write-only.graph.json \
    graph-exec-image-invalid-write-enum.graph.json
  do
    run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$FIXTURE_DIR/$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exec"* ]]
  done
}

@test "graph_schema_parse_node_exec defaults write policy to readonly and host path to null" {
  run graph_schema_parse_node_exec '{}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .)" = '{"execImage":null,"execWorkspaceWrite":null}' ]

  run graph_schema_parse_node_exec '{"execImage":"python:3.12-slim"}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.execImage')" = "python:3.12-slim" ]
  [ "$(printf '%s' "$output" | jq -r '.execWorkspaceWrite')" = "readonly" ]

  run graph_schema_parse_node_exec '{"execImage":"python:3.12-slim","execWorkspaceWrite":"writable"}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.execWorkspaceWrite')" = "writable" ]
}

@test "node without execImage creates no Docker invocation on validate or dispatch argv" {
  local graph_file="$FIXTURE_DIR/graph-exec-image-host-default.graph.json"
  local orch_file="$TMPD/host-default.orch.json"
  local docker_log="$TMPD/docker-invoked.log"
  local project="$TMPD/project"
  local agentws="$TMPD/agent"
  mkdir -p "$TMPD/bin" "$project" "$agentws"
  cat >"$TMPD/bin/docker" <<EOF
#!/bin/sh
echo "invoked: \$*" >>"$docker_log"
exit 99
EOF
  chmod +x "$TMPD/bin/docker"
  export PATH="$TMPD/bin:$PATH"

  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
  [ "$status" -eq 0 ]
  [ ! -f "$docker_log" ]

  jq -n '{
    name: "host-default",
    namespace: "host-default",
    stages: [{id: "verify", runtime: "cursor", plan: "plan.md"}]
  }' >"$orch_file"

  run graph_dispatch_build_argv "$orch_file" "verify" "run-1" "attempt-1" "$agentws" "$TMPD/state"
  [ "$status" -eq 0 ]
  [ ! -f "$docker_log" ]

  local arg
  for arg in "${GRAPH_DISPATCH_ARGV[@]}"; do
    [[ "$arg" != *docker* ]] || fail "unexpected docker token in GRAPH_DISPATCH_ARGV: $arg"
  done
}

@test "graph_dispatch_exec_container_workspace documents host-to-container path" {
  run graph_dispatch_exec_container_workspace
  [ "$status" -eq 0 ]
  [ "$output" = "/ralph/workspace" ]
  [ "$GRAPH_DISPATCH_EXEC_CONTAINER_WORKSPACE" = "/ralph/workspace" ]
}

@test "graph_dispatch_build_verification_argv mounts workspace uid workdir and image" {
  local workspace="$TMPD/ws"
  local docker_log="$TMPD/docker-argv.log"
  local joined="" arg rc
  mkdir -p "$TMPD/bin" "$workspace"
  cat >"$TMPD/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"${DOCKER_ARGV_LOG:?}"
exit 0
EOF
  chmod +x "$TMPD/bin/docker"
  export PATH="$TMPD/bin:$PATH"
  export DOCKER_ARGV_LOG="$docker_log"

  # Do not use bats `run` here: argv is filled via side effect in this shell.
  rc=0
  graph_dispatch_build_verification_argv \
    "$workspace" "python:3.12-slim" "readonly" "pytest -q" || rc=$?
  [ "$rc" -eq 0 ]

  joined=""
  for arg in "${GRAPH_DISPATCH_VERIFICATION_ARGV[@]}"; do
    joined="${joined}${joined:+ }${arg}"
  done
  [[ "$joined" == *"--user $(id -u):$(id -g)"* ]]
  [[ "$joined" == *"--workdir /ralph/workspace"* ]]
  [[ "$joined" == *"-v ${workspace}:/ralph/workspace:ro"* ]]
  [[ "$joined" == *"python:3.12-slim"* ]]
  [[ "$joined" == *"--entrypoint sh"* ]]
  [[ "$joined" == *"pytest -q"* ]]
  [[ "$joined" == *"--name ralph-gexec-"* ]]
  [[ -n "${GRAPH_DISPATCH_EXEC_CONTAINER_NAME:-}" ]]
  [[ "$joined" == *"--name ${GRAPH_DISPATCH_EXEC_CONTAINER_NAME}"* ]]
  # Agent/Ralph argv stays separate and empty of docker for host stages.
  [[ "$joined" != *".cursor"* ]]
  [[ "$joined" != *".claude"* ]]
  [[ "$joined" != *".codex"* ]]

  rc=0
  graph_dispatch_build_verification_argv \
    "$workspace" "ghcr.io/example/verify:1" "writable" "true" || rc=$?
  [ "$rc" -eq 0 ]
  joined=""
  for arg in "${GRAPH_DISPATCH_VERIFICATION_ARGV[@]}"; do
    joined="${joined}${joined:+ }${arg}"
  done
  [[ "$joined" == *"-v ${workspace}:/ralph/workspace"* ]]
  [[ "$joined" != *":/ralph/workspace:ro"* ]]
}

@test "graph_dispatch_build_verification_argv secured mounts exclude credential dirs" {
  local workspace="$TMPD/ws-secure"
  local home_fake="$TMPD/fake-home"
  local arg v_count=0 mount_args=()
  mkdir -p "$workspace" "$home_fake/.cursor" "$home_fake/.claude" \
    "$home_fake/.codex" "$home_fake/.opencode" "$home_fake/.agents" "$TMPD/bin"
  cat >"$TMPD/bin/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMPD/bin/docker"
  export PATH="$TMPD/bin:$PATH"
  export HOME="$home_fake"

  graph_dispatch_build_verification_argv \
    "$workspace" "python:3.12-slim" "readonly" "true" || fail "build argv failed"

  local i=0
  while [[ "$i" -lt "${#GRAPH_DISPATCH_VERIFICATION_ARGV[@]}" ]]; do
    arg="${GRAPH_DISPATCH_VERIFICATION_ARGV[$i]}"
    if [[ "$arg" == "-v" ]]; then
      v_count=$((v_count + 1))
      i=$((i + 1))
      mount_args+=("${GRAPH_DISPATCH_VERIFICATION_ARGV[$i]}")
    fi
    # Also catch combined -v=path forms if ever introduced.
    if [[ "$arg" == -v=* ]]; then
      v_count=$((v_count + 1))
      mount_args+=("${arg#-v=}")
    fi
    i=$((i + 1))
  done

  [ "$v_count" -eq 1 ]
  [ "${#mount_args[@]}" -eq 1 ]
  [ "${mount_args[0]}" = "${workspace}:/ralph/workspace:ro" ]

  local joined=""
  for arg in "${GRAPH_DISPATCH_VERIFICATION_ARGV[@]}"; do
    joined="${joined}${joined:+ }${arg}"
  done
  [[ "$joined" != *"$home_fake"* ]]
  [[ "$joined" != *"/.cursor"* ]]
  [[ "$joined" != *"/.claude"* ]]
  [[ "$joined" != *"/.codex"* ]]
  [[ "$joined" != *"/.opencode"* ]]
  [[ "$joined" != *"/.agents"* ]]
  [[ "$joined" != *".ralph"* ]]
  [[ "$joined" == *"--workdir /ralph/workspace"* ]]
}

@test "graph_dispatch_run_verification propagates docker exit status" {
  local workspace="$TMPD/ws"
  mkdir -p "$TMPD/bin" "$workspace"
  cat >"$TMPD/bin/docker" <<'EOF'
#!/bin/sh
# Last argv word after -c is the command; echo argv for assertions then exit 42.
echo "run-argv: $*" >&2
exit 42
EOF
  chmod +x "$TMPD/bin/docker"
  export PATH="$TMPD/bin:$PATH"

  run graph_dispatch_run_verification \
    "$workspace" "python:3.12-slim" "readonly" "false"
  [ "$status" -eq 42 ]
  [[ "$output" == *"--user $(id -u):$(id -g)"* ]]
  [[ "$output" == *"--workdir /ralph/workspace"* ]]
  [[ "$output" == *"-v ${workspace}:/ralph/workspace:ro"* ]]
}

@test "graph_dispatch_build_verification_argv fails clearly when docker is unavailable" {
  local workspace="$TMPD/ws"
  local saved_path="$PATH"
  mkdir -p "$workspace" "$TMPD/empty-bin"
  # Strip docker from PATH entirely.
  export PATH="$TMPD/empty-bin"

  run graph_dispatch_build_verification_argv \
    "$workspace" "python:3.12-slim" "readonly" "true"
  export PATH="$saved_path"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Docker is required for containerized graph verification"* ]]
  [[ "$output" == *"execImage=python:3.12-slim"* ]]
  [[ "$output" == *"remove stage.execImage"* ]]
}

@test "graph_dispatch_build_argv never containerizes agents even when stage has execImage" {
  local orch_file="$TMPD/with-exec.orch.json"
  local agentws="$TMPD/agent"
  local arg rc
  mkdir -p "$agentws" "$TMPD/bin"
  cat >"$TMPD/bin/docker" <<'EOF'
#!/bin/sh
echo "docker-should-not-run" >&2
exit 99
EOF
  chmod +x "$TMPD/bin/docker"
  export PATH="$TMPD/bin:$PATH"

  jq -n '{
    name: "with-exec",
    namespace: "with-exec",
    stages: [{
      id: "verify",
      runtime: "cursor",
      plan: "plan.md",
      execImage: "python:3.12-slim",
      execWorkspaceWrite: "readonly"
    }]
  }' >"$orch_file"

  rc=0
  graph_dispatch_build_argv "$orch_file" "verify" "run-1" "attempt-1" "$agentws" "$TMPD/state" || rc=$?
  [ "$rc" -eq 0 ]
  for arg in "${GRAPH_DISPATCH_ARGV[@]}"; do
    [[ "$arg" != *docker* ]] || fail "agent argv must not include docker: $arg"
  done
  [[ "${GRAPH_DISPATCH_ARGV[*]}" == *orchestrator* ]]
}

@test "process-group teardown removes a registered container through Docker without a live engine" {
  local name="ralph-gexec-teardown-$$-$RANDOM"
  local reg="$TMPD/exec-registry"
  local docker_log="$TMPD/docker.log"
  mkdir -p "$reg" "$TMPD/bin"
  export RALPH_EXEC_CONTAINER_REGISTRY_DIR="$reg"
  export DOCKER_LOG="$docker_log"
  cat >"$TMPD/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$DOCKER_LOG"
EOF
  chmod +x "$TMPD/bin/docker"
  export PATH="$TMPD/bin:$PATH"

  # This cannot name a real process group, so ralph_kill_process_group reaches
  # its registered-container cleanup path without signalling a test process.
  local missing_pgid=99999999
  ralph_exec_container_register "$name" "$missing_pgid"
  [ -f "$reg/$name" ]
  ralph_kill_process_group "$missing_pgid" 0

  [ ! -f "$reg/$name" ]
  grep -Fxq "rm -f $name" "$docker_log"
}

@test "graph gate tears down a failed containerized verification with a Docker stub" {
  local workspace="$TMPD/gate-workspace"
  local reg="$TMPD/gate-registry"
  local docker_log="$TMPD/gate-docker.log"
  local output_file="$TMPD/gate-output.log"
  mkdir -p "$workspace" "$reg" "$TMPD/bin"
  export RALPH_EXEC_CONTAINER_REGISTRY_DIR="$reg"
  export DOCKER_LOG="$docker_log"
  cat >"$TMPD/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$DOCKER_LOG"
case "$1" in
  run) exit 42 ;;
esac
EOF
  chmod +x "$TMPD/bin/docker"
  export PATH="$TMPD/bin:$PATH"
  # shellcheck source=../../../bundle/.ralph/bash-lib/graph/graph-gate.sh
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-gate.sh"

  run graph_gate_run_step \
    "verify" "false" 5 "$output_file" "$workspace" "example/verify:1" "readonly"
  [ "$status" -eq 42 ]
  grep -Fq "run --rm" "$docker_log"
  grep -Eq '^rm -f ralph-gexec-' "$docker_log"
  shopt -s nullglob
  local leftovers=( "$reg"/* )
  shopt -u nullglob
  [ "${#leftovers[@]}" -eq 0 ]
}

@test "writable verification passes caller identity and host changesets remain capturable" {
  command -v python3 >/dev/null || skip "python3 required"
  local workspace="$TMPD/ws-writable"
  local baseline="$TMPD/baseline.json"
  local changeset="$TMPD/changeset.json"
  local changeset_helper="$BATS_TEST_DIRNAME/../../../bundle/.ralph/python/graph_changeset.py"
  local joined="" arg
  mkdir -p "$workspace/src" "$TMPD/bin"
  printf 'base\n' >"$workspace/src/seed.txt"
  cat >"$TMPD/bin/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMPD/bin/docker"
  export PATH="$TMPD/bin:$PATH"

  python3 "$changeset_helper" baseline --workspace "$workspace" --output "$baseline" >/dev/null
  graph_dispatch_build_verification_argv \
    "$workspace" "example/verify:1" "writable" "write-test" || fail "build argv failed"
  for arg in "${GRAPH_DISPATCH_VERIFICATION_ARGV[@]}"; do
    joined="${joined}${joined:+ }${arg}"
  done
  [[ "$joined" == *"--user $(id -u):$(id -g)"* ]]
  [[ "$joined" == *"-v ${workspace}:/ralph/workspace"* ]]
  [[ "$joined" != *":/ralph/workspace:ro"* ]]

  # The caller identity above is the ownership contract. Capture is host-side
  # and needs no Docker daemon or image to prove it observes workspace writes.
  printf 'from-verification\n' >"$workspace/src/written.txt"
  run python3 "$changeset_helper" capture \
    --workspace "$workspace" \
    --baseline "$baseline" \
    --output "$changeset" \
    --node-id verify \
    --attempt-id a1 \
    --workspace-mode snapshot \
    --base-identity base-one \
    --write-scopes-json '["src/**"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.changes[] | select(.path == "src/written.txt") | .operation' "$changeset")" = "added" ]
}
