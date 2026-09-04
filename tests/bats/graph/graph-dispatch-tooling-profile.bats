#!/usr/bin/env bats
# Per-node toolingProfile env overlay at graph dispatch: graph_dispatch_build_argv
# must append ralph_tooling_profile_env lines to the child env prefix without
# exporting into the scheduler process or overwriting supervisor-owned G12 roots.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/error-handling.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-dispatch.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/tooling-profile.sh"

PROFILE_ENV_KEYS='RALPH_MODE
RALPH_PROXY_SHELL_COMPACT
RALPH_COMPACT_GENERIC_FALLBACK
RALPH_COMPACT_GENERIC_THRESHOLD_BYTES
RALPH_NATIVE_RESULT_COMPACT
RALPH_TOOLING_PROFILE
RALPH_TOOLING_PROFILE_DEGRADED'

setup() {
  TMPD="$(mktemp -d)"
  PROJECT="$TMPD/project"
  STATE="$TMPD/state"
  AGENTWS="$TMPD/agent-snapshot"
  mkdir -p "$PROJECT" "$STATE" "$AGENTWS"
}

teardown() {
  rm -rf "$TMPD" 2>/dev/null || true
}

_write_two_profile_orch() {
  ORCH_JSON="$TMPD/two-profile.orch.json"
  jq -n '{
    name: "tooling-dispatch",
    namespace: "tooling-dispatch",
    stages: [
      {
        id: "node-a",
        runtime: "cursor",
        role: "alpha",
        toolingProfile: "ralph-read-heavy",
        plan: "plan-a.md"
      },
      {
        id: "node-b",
        runtime: "cursor",
        role: "alpha",
        toolingProfile: "ralph-aggressive",
        plan: "plan-b.md"
      }
    ]
  }' >"$ORCH_JSON"
}

_capture_scheduler_tooling_env() {
  { env | grep -E '^(RALPH_MODE|RALPH_PROXY_SHELL_COMPACT|RALPH_COMPACT_GENERIC_FALLBACK|RALPH_COMPACT_GENERIC_THRESHOLD_BYTES|RALPH_NATIVE_RESULT_COMPACT|RALPH_TOOLING_PROFILE|RALPH_TOOLING_PROFILE_DEGRADED)=' || true; } | sort
}

_assert_argv_contains_exact_profile_env() {
  local profile="$1" runtime="$2"
  local expected_lines=() line key found

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    expected_lines+=("$line")
  done < <(ralph_tooling_profile_env "$profile" "$runtime")

  for line in "${expected_lines[@]}"; do
    found=0
    for arg in "${GRAPH_DISPATCH_ARGV[@]}"; do
      if [[ "$arg" == "$line" ]]; then
        found=1
        break
      fi
    done
    [ "$found" -eq 1 ] || fail "missing profile env line '$line' in GRAPH_DISPATCH_ARGV for $profile/$runtime"
  done

  for arg in "${GRAPH_DISPATCH_ARGV[@]}"; do
    [[ "$arg" == *=* ]] || continue
    key="${arg%%=*}"
    printf '%s\n' "$PROFILE_ENV_KEYS" | grep -qxF "$key" || continue
    found=0
    for line in "${expected_lines[@]}"; do
      if [[ "$arg" == "$line" ]]; then
        found=1
        break
      fi
    done
    [ "$found" -eq 1 ] || fail "unexpected profile env entry '$arg' in GRAPH_DISPATCH_ARGV for $profile/$runtime"
  done
}

@test "graph_dispatch_build_argv applies per-node toolingProfile env without mutating scheduler env" {
  _write_two_profile_orch

  local before after

  # Seed ambient values the profile should override in the child prefix only.
  export RALPH_MODE=no
  export RALPH_NATIVE_RESULT_COMPACT=0
  before="$(_capture_scheduler_tooling_env)"

  RALPH_PROJECT_ROOT="$PROJECT" RALPH_AGENT_WORKSPACE="$AGENTWS" \
    graph_dispatch_build_argv "$ORCH_JSON" node-a run1 attempt-a "$AGENTWS" "$STATE"
  [ "${#GRAPH_DISPATCH_ARGV[@]}" -gt 0 ]
  _assert_argv_contains_exact_profile_env ralph-read-heavy cursor
  printf '%s\n' "${GRAPH_DISPATCH_ARGV[@]}" | grep -qxF "RALPH_MODE=ralph"
  printf '%s\n' "${GRAPH_DISPATCH_ARGV[@]}" | grep -qxF "RALPH_NATIVE_RESULT_COMPACT=0"

  RALPH_PROJECT_ROOT="$PROJECT" RALPH_AGENT_WORKSPACE="$AGENTWS" \
    graph_dispatch_build_argv "$ORCH_JSON" node-b run1 attempt-b "$AGENTWS" "$STATE"
  [ "${#GRAPH_DISPATCH_ARGV[@]}" -gt 0 ]
  _assert_argv_contains_exact_profile_env ralph-aggressive cursor
  printf '%s\n' "${GRAPH_DISPATCH_ARGV[@]}" | grep -qxF "RALPH_MODE=ralph"
  printf '%s\n' "${GRAPH_DISPATCH_ARGV[@]}" | grep -qxF "RALPH_NATIVE_RESULT_COMPACT=1"

  after="$(_capture_scheduler_tooling_env)"
  [ "$before" = "$after" ]
  [ "$RALPH_MODE" = "no" ]
  [ "$RALPH_NATIVE_RESULT_COMPACT" = "0" ]
}

@test "graph_dispatch_build_argv unsets retired RALPH_AGENT_TOOL_ACCESS so nested parents cannot poison children" {
  _write_two_profile_orch

  export RALPH_AGENT_TOOL_ACCESS=native
  export RALPH_NATIVE_HOOKS=auto

  RALPH_PROJECT_ROOT="$PROJECT" RALPH_AGENT_WORKSPACE="$AGENTWS" \
    graph_dispatch_build_argv "$ORCH_JSON" node-a run1 attempt-a "$AGENTWS" "$STATE"

  local i=0 found_access=0 found_hooks=0
  for ((i = 0; i < ${#GRAPH_DISPATCH_ARGV[@]}; i++)); do
    if [[ "${GRAPH_DISPATCH_ARGV[$i]}" == "-u" ]]; then
      case "${GRAPH_DISPATCH_ARGV[$((i + 1))]:-}" in
        RALPH_AGENT_TOOL_ACCESS) found_access=1 ;;
        RALPH_NATIVE_HOOKS) found_hooks=1 ;;
      esac
    fi
  done
  [ "$found_access" -eq 1 ]
  [ "$found_hooks" -eq 1 ]

  # Collect only the env(1) prefix (flags + KEY=VALUE), stopping before bash.
  local prefix=()
  for ((i = 1; i < ${#GRAPH_DISPATCH_ARGV[@]}; i++)); do
    [[ "${GRAPH_DISPATCH_ARGV[$i]}" == "bash" ]] && break
    prefix+=("${GRAPH_DISPATCH_ARGV[$i]}")
  done
  run env "${prefix[@]}" bash -c 'printf "%s\n" "ACCESS=${RALPH_AGENT_TOOL_ACCESS-<unset>}" "HOOKS=${RALPH_NATIVE_HOOKS-<unset>}" "MODE=${RALPH_MODE-<unset>}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACCESS=<unset>"* ]]
  [[ "$output" == *"HOOKS=<unset>"* ]]
  [[ "$output" == *"MODE=ralph"* ]]
}

@test "graph_dispatch_build_argv adds no tooling overlay when stage omits toolingProfile" {
  ORCH_JSON="$TMPD/no-profile.orch.json"
  jq -n '{
    name: "no-tooling",
    namespace: "no-tooling",
    stages: [{id: "plain", runtime: "cursor", agent: "alpha", plan: "plan.md"}]
  }' >"$ORCH_JSON"

  graph_dispatch_build_argv "$ORCH_JSON" plain run1 attempt1 "$AGENTWS" "$STATE"

  local arg key
  for arg in "${GRAPH_DISPATCH_ARGV[@]}"; do
    [[ "$arg" == *=* ]] || continue
    key="${arg%%=*}"
    printf '%s\n' "$PROFILE_ENV_KEYS" | grep -qxF "$key" \
      && fail "unexpected profile env key '$key' when toolingProfile is absent"
  done
}
