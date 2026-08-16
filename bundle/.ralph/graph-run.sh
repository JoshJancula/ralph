#!/usr/bin/env bash
# Graph mode entrypoint (`ralph graph <verb>`): compile, preflight, run, resume,
# status, render, actions, logs, attach, tui, recover, and successor. compile
# lints and visualizes an existing pipeline plan's implicit artifact DAG without
# running anything; preflight compiles a plan and prints the read-only
# capability report; run invokes that same preflight before creating a ledger
# or spawning a model; render produces a standalone mermaid/dot/ascii view of
# the compiled graph shape; status reports the live/finished state of a run;
# actions list pending operator requests, record a decision with actions
# respond, and list or revoke project approvals; logs prints a ledger-owned
# attempt stream and may --follow it; attach is a read-only live view of
# status and events; tui launches the interactive viewer or falls back to
# concise streaming status; recover is the explicit operator path into the
# recovery module; successor dry-runs reuse against a predecessor and creates
# a linked run only when asked. Status and attach never recover. This script
# never touches the loop execution path in run-plan.sh or orchestrator.sh.
#
# Phase 3 ledger note: each attempt entry must record the resolved stage
# subagents value (inherit|on|off). Omitting it would hide an unaccounted
# token source and corrupt savings/usage comparisons.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_BASH_LIB="$SCRIPT_DIR/bash-lib"

# shellcheck source=bash-lib/graph/graph-compile.sh
source "$RALPH_BASH_LIB/graph/graph-compile.sh"
# shellcheck source=bash-lib/graph/graph-schedule.sh
source "$RALPH_BASH_LIB/graph/graph-schedule.sh"
# shellcheck source=bash-lib/graph/graph-status.sh
source "$RALPH_BASH_LIB/graph/graph-status.sh"
# shellcheck source=bash-lib/graph/graph-run-base.sh
source "$RALPH_BASH_LIB/graph/graph-run-base.sh"
# shellcheck source=bash-lib/graph/graph-publish.sh
source "$RALPH_BASH_LIB/graph/graph-publish.sh"
# shellcheck source=bash-lib/graph/graph-operator-records.sh
source "$RALPH_BASH_LIB/graph/graph-operator-records.sh"
# shellcheck source=bash-lib/graph/graph-approval-policy.sh
source "$RALPH_BASH_LIB/graph/graph-approval-policy.sh"
# shellcheck source=bash-lib/graph/graph-logs.sh
source "$RALPH_BASH_LIB/graph/graph-logs.sh"
# shellcheck source=bash-lib/graph/graph-recovery.sh
source "$RALPH_BASH_LIB/graph/graph-recovery.sh"
# shellcheck source=bash-lib/graph/graph-preflight.sh
source "$RALPH_BASH_LIB/graph/graph-preflight.sh"
# shellcheck source=bash-lib/graph/graph-successor.sh
source "$RALPH_BASH_LIB/graph/graph-successor.sh"

graph_run_usage() {
  cat <<'EOF' >&2
Usage: graph-run.sh <verb> [options]

Verbs:
  compile <plan-path> [--render mermaid|dot|ascii] [--out <path>] [--force]
      Compile a graph-mode plan into .graph.json, validate it, and cache the
      result beside the plan. See `graph-run.sh compile --help`.

  preflight <plan-path> [--json] [--workspace <dir>]
      Compile a graph plan into a temporary frozen graph and print the
      read-only preflight report. --json emits the report object; omit it
      for the concise table. Hard failures exit non-zero. Warnings do not;
      they require only the acknowledgements already declared on the graph.

  run <plan-path> [--namespace <ns>] [--max-parallel <n>] [--workspace <dir>]
      [--tui|--no-tui]
      Compile and run a graph plan to completion, recording the durable
      run-state ledger under .ralph-workspace/graph-runs/<namespace>/.
      The same preflight as `preflight --json` runs first. Hard failures
      stop before a run is created or a model is invoked. Warnings proceed
      when the graph already carries the required acknowledgements.
      --tui optionally launches the interactive viewer after the run is
      created; when Python, curses, or a suitable TTY is unavailable it
      falls back to concise streaming status. --no-tui keeps the headless
      scheduler in the foreground.

  resume <plan-path> --namespace <ns> --run <run-id|latest>
      [--accept-graph-change]
      Resume a graph run. Recompiles the plan and compares graphSha; refuses
      when the graph changed unless --accept-graph-change is supplied, in
      which case affected nodes are invalidated. Succeeded nodes are skipped;
      an orphaned in-flight node is adopted when its StageOutcomeReport is
      present, otherwise reset to pending; failed/cancelled/blocked nodes
      reset to pending.

  status --namespace <ns> --run <run-id|latest> [--workspace <dir>]
      [--details] [--mermaid]
      Display the current state of a graph run.  Read-only; safe to call
      against a live in-progress run.  By default outputs the run summary
      plus a table (node, type, runtime, state, unique attempt count,
      duration). --details adds verbose per-node/per-attempt metadata
      (workspace mode, write scopes, gate outcome, consensus per-voter
      provenance and confidence, brokered children, native subagent
      events). --mermaid adds a flowchart with per-state class definitions.

  render <plan-path> [--format mermaid|dot|ascii] [--out <path>]
      Render a compiled graph as mermaid, dot, or ascii.  This is a
      pre-run static view of the graph shape, not the live run state.

  actions list --namespace <ns> --run <run-id|latest> [--workspace <dir>]
      [--json]
      List pending operator requests for one run. Namespace and run
      selectors are required. Prints request ID, node, runtime, action,
      resource, effect, and choices as concise text, or JSON with --json.

  actions respond <request-id> --decision allow-once|allow-run|allow-always|deny
      [--namespace <ns>] [--run <run-id|latest>] [--workspace <dir>]
      [--confirm-rule <rule-id>] [--json]
      Record an operator decision. Namespace and run selectors are required
      when the request id matches more than one run. allow-always requires
      --confirm-rule with the exact normalized rule id.

  actions approvals list [--workspace <dir>] [--json]
      List project allow-always rules for the selected workspace. Prints
      exact normalized scope (runtime, action, resource, effect) and
      revocation state. Never edits runtime-global configuration.

  actions approvals revoke --runtime <rt> --action <name> --resource <path>
      --effect <effect> [--workspace <dir>] [--json]
      Revoke one exact project allow-always rule. Repeating the same
      revoke is idempotent. Never edits runtime-global configuration.

  logs --namespace <ns> --run <run-id|latest> --node <id> [--workspace <dir>]
      [--attempt <id>] [--stream runner|agent|usage] [--tail N] [--follow]
      Print one attempt log stream. Paths come from the node ledger
      logPaths and are resolved only when contained in the run-dir.
      A missing v2 file may fall back to a historical v1 namespace
      file. Default stream is agent. --follow waits for new bytes,
      handles rotation/truncation, and exits when the attempt is
      terminal or on SIGINT/SIGTERM. Missing logs are explicit but
      nonfatal for an active attempt. Read-only.

  attach --namespace <ns> --run <run-id|latest> [--workspace <dir>]
      Read-only live view of run status and the event journal. Detaching
      (SIGINT/SIGTERM) never cancels the supervisor or mutates the
      ledger. Missing events are explicit but nonfatal for an active run.
      Never recovers a run.

  tui --namespace <ns> --run <run-id|latest> [--workspace <dir>] [--no-tui]
      Launch the interactive TUI for one run. Falls back to concise
      streaming status when python3, curses, or a suitable TTY is
      unavailable. Restores terminal settings on normal exit, exception,
      SIGINT, and SIGTERM. --no-tui forces the streaming-status path.

  recover --namespace <ns> --run <run-id|latest> [--workspace <dir>]
      Recover a stale or orphaned graph run. Namespace and run selectors
      are required. Delegates to the recovery module, prints that
      module's refusal reason when recovery is not allowed, and never
      runs as a side effect of status or attach.

  successor --from <run> --plan <path> [--namespace <ns>] [--workspace <dir>]
      [--create] [--run-id <id>] [--json]
      Compare a predecessor run with a newly compiled plan. Default is a
      read-only dry-run reuse report. --create writes a new successor
      run and copies only reusable evidence. The predecessor is never
      mutated. --from latest and a run id present in more than one
      namespace require --namespace.
EOF
}

main() {
  if [[ $# -eq 0 ]]; then
    graph_run_usage
    exit 1
  fi

  local verb="$1"
  shift

  case "$verb" in
    compile)
      graph_compile_cli "$@"
      ;;
    preflight)
      graph_run_preflight_cli "$@"
      ;;
    run)
      graph_run_run_cli "$@"
      ;;
    resume)
      graph_run_resume_cli "$@"
      ;;
    status)
      graph_status_cli "$@"
      ;;
    render)
      # render is the pre-run static graph shape view; status is the live run
      # state view.
      graph_render_cli "$@"
      ;;
    actions)
      graph_run_actions_cli "$@"
      ;;
    logs)
      graph_run_logs_cli "$@"
      ;;
    attach)
      graph_run_attach_cli "$@"
      ;;
    tui)
      graph_run_tui_cli "$@"
      ;;
    recover)
      graph_run_recover_cli "$@"
      ;;
    successor)
      graph_run_successor_cli "$@"
      ;;
    -h|--help)
      graph_run_usage
      exit 0
      ;;
    *)
      echo "Error: unknown graph verb '$verb'" >&2
      graph_run_usage
      exit 1
      ;;
  esac
}

graph_run_preflight_usage() {
  cat <<'EOF' >&2
Usage: graph-run.sh preflight <plan-path> [--json] [--workspace <dir>]
EOF
}

# graph_run_preflight_evaluate <graph-json> <project-root>
# Prints the preflight report JSON on stdout. Returns 0 for pass or warn,
# 1 when the report cannot be produced or any finding is a hard failure.
# Warnings do not require a new CLI acknowledgement; the frozen graph's
# existing acknowledgements (for example acknowledgeSharedMutationRisk)
# are the only ones consulted.
graph_run_preflight_evaluate() {
  local graph="${1:-}" project="${2:-}" report outcome
  report="$(graph_preflight_report "$graph" "$project")" || return 1
  printf '%s\n' "$report"
  outcome="$(printf '%s' "$report" | jq -r '.outcome // empty')"
  if [[ "$outcome" == "fail" ]]; then
    return 1
  fi
  return 0
}

# graph_run_preflight_refuse <report-json>
# Print a hard-failure refusal and the concise finding table on stderr.
graph_run_preflight_refuse() {
  local report="${1:-}"
  echo "Error: graph preflight failed; refusing to start a new run before model invocation" >&2
  if [[ -n "$report" ]] && printf '%s' "$report" | jq -e 'type == "object" and (.findings | type == "array")' >/dev/null 2>&1; then
    graph_preflight_format_table "$report" >&2
  elif [[ -n "$report" ]]; then
    printf '%s\n' "$report" >&2
  fi
}

# graph_run_preflight_cli <plan-path> [--json] [--workspace <dir>]
# Read-only: compile to a temp graph, print the same report `run` uses, and
# never create a ledger or start a model session.
graph_run_preflight_cli() {
  local plan_path="" json=0 workspace_opt=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      --workspace) workspace_opt="$2"; shift 2 ;;
      --workspace=*) workspace_opt="${1#--workspace=}"; shift ;;
      -h|--help)
        graph_run_preflight_usage
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; graph_run_preflight_usage; return 1 ;;
      *)
        if [[ -n "$plan_path" ]]; then
          echo "Error: unexpected extra argument '$1'" >&2
          graph_run_preflight_usage
          return 1
        fi
        plan_path="$1"
        shift
        ;;
    esac
  done
  if [[ -z "$plan_path" ]]; then
    echo "Error: graph preflight requires a plan path" >&2
    graph_run_preflight_usage
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for graph preflight" >&2
    return 1
  fi

  local invocation roots_json workspace state_root graph_json report rc=0
  invocation="${workspace_opt:-$(pwd)}"
  if [[ -n "$workspace_opt" ]]; then
    export RALPH_PROJECT_ROOT="$workspace_opt"
  fi
  roots_json="$(graph_run_base_resolve_roots "$invocation")" || return 1
  workspace="$(printf '%s' "$roots_json" | jq -r '.projectRoot')"
  state_root="$(printf '%s' "$roots_json" | jq -r '.stateRoot')"
  graph_json="$(mktemp "$state_root/graph-preflight.XXXXXX")" || return 1
  if ! graph_compile_plan "$plan_path" "$graph_json" 1 >/dev/null; then
    rm -f "$graph_json"
    return 1
  fi
  report="$(graph_run_preflight_evaluate "$graph_json" "$workspace")" || rc=$?
  rm -f "$graph_json"
  if [[ "$json" -eq 1 ]]; then
    [[ -n "$report" ]] && printf '%s\n' "$report"
  else
    if [[ -n "$report" ]] && printf '%s' "$report" | jq -e 'type == "object"' >/dev/null 2>&1; then
      graph_preflight_format_table "$report"
    elif [[ -n "$report" ]]; then
      printf '%s\n' "$report"
    fi
  fi
  return "$rc"
}

# graph_run_run_cli <plan-path> [--namespace <ns>] [--max-parallel <n>]
#   [--workspace <dir>] [--tui|--no-tui]
graph_run_run_cli() {
  local plan_path="" namespace="" max_parallel="" workspace_opt="" tui_mode=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --max-parallel) max_parallel="$2"; shift 2 ;;
      --max-parallel=*) max_parallel="${1#--max-parallel=}"; shift ;;
      --workspace) workspace_opt="$2"; shift 2 ;;
      --workspace=*) workspace_opt="${1#--workspace=}"; shift ;;
      --tui) tui_mode="tui"; shift ;;
      --no-tui) tui_mode="no-tui"; shift ;;
      -h|--help)
        cat <<'EOF' >&2
Usage: graph-run.sh run <plan-path> [--namespace <ns>] [--max-parallel <n>] [--workspace <dir>] [--tui|--no-tui]
EOF
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; return 1 ;;
      *)
        if [[ -n "$plan_path" ]]; then
          echo "Error: unexpected extra argument '$1'" >&2
          return 1
        fi
        plan_path="$1"
        shift
        ;;
    esac
  done
  if [[ -z "$plan_path" ]]; then
    echo "Error: graph run requires a plan path" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for graph run" >&2
    return 1
  fi

  local graph_json compile_graph_tmp workspace roots_json state_root agent_workspace modes_json
  local invocation preflight_json preflight_rc=0
  invocation="${workspace_opt:-$(pwd)}"
  if [[ -n "$workspace_opt" ]]; then
    export RALPH_PROJECT_ROOT="$workspace_opt"
  fi
  roots_json="$(graph_run_base_resolve_roots "$invocation")" || return 1
  workspace="$(printf '%s' "$roots_json" | jq -r '.projectRoot')"
  state_root="$(printf '%s' "$roots_json" | jq -r '.stateRoot')"
  agent_workspace="$(printf '%s' "$roots_json" | jq -r '.agentWorkspace')"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PROJECT_ROOT="$workspace"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  export RALPH_AGENT_WORKSPACE="$agent_workspace"
  # `run` must not leave a compile cache beside a plan in the caller checkout.
  # The durable ledger freezes its own graph.json immediately after compile.
  graph_json="$(mktemp "$state_root/graph-compile.XXXXXX")" || return 1
  compile_graph_tmp="$graph_json"
  if ! graph_compile_plan "$plan_path" "$graph_json" 1 >/dev/null; then
    rm -f "$graph_json"
    return 1
  fi
  if [[ -z "$namespace" ]]; then
    namespace="$(jq -r '.namespace // empty' "$graph_json")"
    if [[ -z "$namespace" ]]; then
      namespace="$(basename "$plan_path")"
      namespace="${namespace%.plan.md}"
      namespace="${namespace%.md}"
    fi
  fi
  if [[ "$(jq -r '.namespace // empty' "$graph_json")" != "$namespace" ]]; then
    local namespaced_graph
    namespaced_graph="$(mktemp "$state_root/graph-namespace.XXXXXX")" || { rm -f "$graph_json"; return 1; }
    jq --arg namespace "$namespace" '.namespace = $namespace' "$graph_json" >"$namespaced_graph" || {
      rm -f "$graph_json" "$namespaced_graph"
      return 1
    }
    mv -f "$namespaced_graph" "$graph_json"
  fi
  preflight_json="$(graph_run_preflight_evaluate "$graph_json" "$workspace")" || preflight_rc=$?
  if [[ "$preflight_rc" -ne 0 ]]; then
    graph_run_preflight_refuse "$preflight_json"
    rm -f "$graph_json"
    return 1
  fi
  local run_id
  run_id="$(graph_state_mint_run_id)"
  local max_p=2
  if [[ -n "$max_parallel" ]]; then
    max_p="$max_parallel"
  else
    max_p="$(jq -r '.maxParallel // 2' "$graph_json")"
  fi
  if ! graph_state_init_run "$workspace" "$namespace" "$run_id" "$plan_path" "$graph_json" "$max_p"; then
    rm -f "$graph_json"
    return 1
  fi
  local run_dir
  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")"
  graph_json="$run_dir/graph.json"
  rm -f "$compile_graph_tmp"
  modes_json="$(graph_run_base_modes_json "$graph_json")" || {
    graph_state_set_run_status "$workspace" "$namespace" "$run_id" "failed" 2>/dev/null || true
    return 1
  }
  if ! graph_run_base_prepare "$run_dir" "$roots_json" "$modes_json"; then
    graph_state_set_run_status "$workspace" "$namespace" "$run_id" "failed" 2>/dev/null || true
    return 1
  fi
  if ! graph_workspace_prepare_run "$run_dir" "$graph_json"; then
    graph_state_set_run_status "$workspace" "$namespace" "$run_id" "failed" 2>/dev/null || true
    return 1
  fi
  local schedule_rc=0 publish_rc=0
  if [[ "$tui_mode" == "tui" ]]; then
    graph_run_tui_with_schedule "$graph_json" "$run_id" "$workspace" "$run_dir" "$namespace" || schedule_rc=$?
  else
    graph_schedule_run "$graph_json" "$run_id" "$workspace" "$run_dir" || schedule_rc=$?
  fi
  graph_publish_finalize "$run_dir" "$graph_json" "$workspace" || publish_rc=$?
  if [[ "$schedule_rc" -eq 0 && "$publish_rc" -ne 0 ]]; then
    schedule_rc="$publish_rc"
  fi
  case "$(jq -r '.status // empty' "$run_dir/run.json")" in
    succeeded|failed|cancelled)
      if ! graph_publish_should_retain "$run_dir" "$graph_json"; then
        graph_workspace_cleanup_run "$run_dir" || {
          [[ "$schedule_rc" -ne 0 ]] || schedule_rc=1
        }
      fi
      ;;
  esac
  return "$schedule_rc"
}

# graph_run_resume_cli <plan-path> --namespace <ns> --run <run-id|latest>
#   [--accept-graph-change]
graph_run_resume_cli() {
  local plan_path="" namespace="" run_token="" accept_change=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --run) run_token="$2"; shift 2 ;;
      --run=*) run_token="${1#--run=}"; shift ;;
      --accept-graph-change) accept_change=1; shift ;;
      -h|--help)
        cat <<'EOF' >&2
Usage: graph-run.sh resume <plan-path> --namespace <ns> --run <run-id|latest> [--accept-graph-change]
EOF
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; return 1 ;;
      *)
        if [[ -n "$plan_path" ]]; then
          echo "Error: unexpected extra argument '$1'" >&2
          return 1
        fi
        plan_path="$1"
        shift
        ;;
    esac
  done
  if [[ -z "$plan_path" || -z "$namespace" || -z "$run_token" ]]; then
    echo "Error: graph resume requires <plan-path> --namespace <ns> --run <run-id|latest>" >&2
    return 1
  fi
  local extra=()
  if [[ "$accept_change" -eq 1 ]]; then
    extra+=(--accept-graph-change)
  fi
  local workspace roots_json state_root agent_workspace
  roots_json="$(graph_run_base_resolve_roots "$(pwd)")" || return 1
  workspace="$(printf '%s' "$roots_json" | jq -r '.projectRoot')"
  state_root="$(printf '%s' "$roots_json" | jq -r '.stateRoot')"
  agent_workspace="$(printf '%s' "$roots_json" | jq -r '.agentWorkspace')"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PROJECT_ROOT="$workspace"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  export RALPH_AGENT_WORKSPACE="$agent_workspace"
  local resolved_run_id resume_run_dir resume_rc=0 publish_rc=0 frozen_graph
  resolved_run_id="$(graph_state_resolve_run_id "$workspace" "$namespace" "$run_token")" || return 1
  resume_run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$resolved_run_id")"
  graph_schedule_resume "$workspace" "$namespace" "$run_token" "$plan_path" "${extra[@]}" || resume_rc=$?
  frozen_graph="$resume_run_dir/graph.json"
  if [[ -f "$resume_run_dir/run.json" && -f "$frozen_graph" ]]; then
    graph_publish_finalize "$resume_run_dir" "$frozen_graph" "$workspace" || publish_rc=$?
    if [[ "$resume_rc" -eq 0 && "$publish_rc" -ne 0 ]]; then
      resume_rc="$publish_rc"
    fi
  fi
  if [[ -f "$resume_run_dir/run.json" ]]; then
    case "$(jq -r '.status // empty' "$resume_run_dir/run.json")" in
      succeeded|failed|cancelled)
        if jq -e '.workspaceManager.schemaVersion == 1' "$resume_run_dir/run.json" >/dev/null 2>&1 \
          && ! graph_publish_should_retain "$resume_run_dir" "$frozen_graph"; then
          graph_workspace_cleanup_run "$resume_run_dir" || {
            [[ "$resume_rc" -ne 0 ]] || resume_rc=1
          }
        fi
        ;;
    esac
  fi
  return "$resume_rc"
}

graph_run_actions_usage() {
  cat <<'EOF' >&2
Usage: graph-run.sh actions list --namespace <ns> --run <run-id|latest> [--workspace <dir>] [--json]
       graph-run.sh actions respond <request-id> --decision allow-once|allow-run|allow-always|deny
           [--namespace <ns>] [--run <run-id|latest>] [--workspace <dir>]
           [--confirm-rule <rule-id>] [--json]
       graph-run.sh actions approvals list [--workspace <dir>] [--json]
       graph-run.sh actions approvals revoke --runtime <rt> --action <name>
           --resource <path> --effect <effect> [--workspace <dir>] [--json]
EOF
}

graph_run_actions_approvals_usage() {
  cat <<'EOF' >&2
Usage: graph-run.sh actions approvals list [--workspace <dir>] [--json]
       graph-run.sh actions approvals revoke --runtime <rt> --action <name>
           --resource <path> --effect <effect> [--workspace <dir>] [--json]
EOF
}

# graph_run_actions_cli <subcommand> [options]
graph_run_actions_cli() {
  if [[ $# -eq 0 ]]; then
    echo "Error: graph actions requires a subcommand" >&2
    graph_run_actions_usage
    return 1
  fi

  local sub="$1"
  shift

  case "$sub" in
    list)
      graph_run_actions_list_cli "$@"
      ;;
    respond)
      graph_run_actions_respond_cli "$@"
      ;;
    approvals)
      graph_run_actions_approvals_cli "$@"
      ;;
    -h|--help)
      graph_run_actions_usage
      return 0
      ;;
    *)
      echo "Error: unknown graph actions verb '$sub'" >&2
      graph_run_actions_usage
      return 1
      ;;
  esac
}

# graph_run_actions_pending_json <run-dir>
# Prints a JSON array of pending operator requests. A request is pending
# when its decision record is absent. Unreadable or escaped files are
# skipped with a warning and do not fail the list.
graph_run_actions_pending_json() {
  local run_dir="$1"
  local req_dir="" f request_id json tmp ec=0
  if [[ -z "$run_dir" ]]; then
    echo "Error: graph_run_actions_pending_json requires a run-dir" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph actions list" >&2
    return 1
  }

  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-actions.XXXXXX")" || return 1
  : >"$tmp"
  req_dir="$(graph_logs_resolve "$run_dir" "operator/requests" 2>/dev/null || true)"
  if [[ -n "$req_dir" && -d "$req_dir" && ! -L "$req_dir" ]]; then
    for f in "$req_dir"/*.json; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      request_id="$(basename "$f" .json)"
      if ! graph_operator_request_id_valid "$request_id" >/dev/null 2>&1; then
        echo "Warning: skipping unsafe operator request filename: $request_id" >&2
        continue
      fi
      if graph_operator_decision_read "$run_dir" "$request_id" >/dev/null 2>&1; then
        continue
      fi
      json="$(graph_operator_request_read "$run_dir" "$request_id" 2>/dev/null)" || {
        echo "Warning: skipping unreadable operator request: $request_id" >&2
        continue
      }
      if ! printf '%s' "$json" | jq -c '{
        requestId: ((.requestId // "") | tostring),
        nodeId: ((.nodeId // "") | tostring),
        runtime: ((.runtime // "") | tostring),
        action: ((.action // "") | tostring),
        resource: ((.resource // "") | tostring),
        effect: ((.effect // "") | tostring),
        choices: (if (.choices | type) == "array" then .choices else [] end)
      }' >>"$tmp"; then
        echo "Warning: skipping malformed operator request: $request_id" >&2
        continue
      fi
    done
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    printf '[]\n'
    return 0
  fi
  jq -s 'sort_by(.requestId)' "$tmp"
  ec=$?
  rm -f "$tmp"
  return "$ec"
}

# graph_run_actions_list_cli --namespace <ns> --run <run-id|latest>
#   [--workspace <dir>] [--json]
graph_run_actions_list_cli() {
  local namespace="" run_token="" workspace="" json=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --run) run_token="$2"; shift 2 ;;
      --run=*) run_token="${1#--run=}"; shift ;;
      --workspace) workspace="$2"; shift 2 ;;
      --workspace=*) workspace="${1#--workspace=}"; shift ;;
      --json) json=1; shift ;;
      -h|--help)
        graph_run_actions_usage
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; return 1 ;;
      *)
        echo "Error: unexpected argument '$1'" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$workspace" ]]; then
    workspace="$(pwd)"
  fi

  if [[ -z "$namespace" ]]; then
    echo "Error: graph actions list requires --namespace <ns>" >&2
    return 1
  fi
  if [[ -z "$run_token" ]]; then
    echo "Error: graph actions list requires --run <run-id|latest>" >&2
    return 1
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph actions list" >&2
    return 1
  }

  local run_id run_file run_dir rows count
  if ! run_id="$(graph_state_resolve_run_id "$workspace" "$namespace" "$run_token")"; then
    echo "Error: could not resolve run selector '$run_token' for namespace '$namespace'" >&2
    return 1
  fi
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")" || return 1
  if [[ ! -f "$run_file" ]]; then
    echo "Error: run not found: $run_file" >&2
    return 1
  fi
  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")" || return 1
  rows="$(graph_run_actions_pending_json "$run_dir")" || return 1

  if [[ "$json" -eq 1 ]]; then
    jq -n --arg namespace "$namespace" --arg runId "$run_id" --argjson requests "$rows" \
      '{namespace:$namespace, runId:$runId, requests:$requests}'
    return 0
  fi

  printf '# graph actions  run=%s  namespace=%s\n' "$run_id" "$namespace"
  count="$(printf '%s' "$rows" | jq 'length')"
  if [[ "$count" -eq 0 ]]; then
    printf 'no pending requests\n'
    return 0
  fi
  printf '%s' "$rows" | jq -r '.[] |
    "\(.requestId)  node=\(.nodeId)  runtime=\(.runtime)  action=\(.action)  resource=\(.resource)  effect=\(.effect)  choices=\(.choices | join(","))"'
}

# graph_run_actions_emit_match <namespace> <run-id> <run-dir>
graph_run_actions_emit_match() {
  jq -nc --arg namespace "$1" --arg runId "$2" --arg runDir "$3" \
    '{namespace:$namespace,runId:$runId,runDir:$runDir}'
}

# graph_run_actions_request_exists <run-dir> <request-id>
# Exit 0 when a contained request record is present.
graph_run_actions_request_exists() {
  local run_dir="$1" request_id="$2" path
  path="$(graph_operator_request_path "$run_dir" "$request_id" 2>/dev/null)" || return 1
  [[ -f "$path" && ! -L "$path" ]]
}

# graph_run_actions_find_request_matches <workspace> <request-id> [namespace] [run-token]
# Prints one JSON object per matching run. `latest` requires a namespace.
graph_run_actions_find_request_matches() {
  local workspace="$1" request_id="$2" namespace="${3:-}" run_token="${4:-}"
  local runs_root ns_dir ns run_id run_dir resolved

  if [[ -n "$run_token" && "$run_token" == "latest" && -z "$namespace" ]]; then
    echo "Error: --run latest requires --namespace to disambiguate the request" >&2
    return 1
  fi

  if [[ -n "$namespace" && -n "$run_token" ]]; then
    resolved="$(graph_state_resolve_run_id "$workspace" "$namespace" "$run_token")" || {
      echo "Error: could not resolve run selector '$run_token' for namespace '$namespace'" >&2
      return 1
    }
    run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$resolved")" || return 1
    if graph_run_actions_request_exists "$run_dir" "$request_id"; then
      graph_run_actions_emit_match "$namespace" "$resolved" "$run_dir"
    fi
    return 0
  fi

  runs_root="$(graph_state_runs_root "$workspace")" || return 1
  if [[ ! -d "$runs_root" ]]; then
    return 0
  fi

  if [[ -n "$namespace" ]]; then
    ns_dir="$(graph_state_runs_namespace_root "$workspace" "$namespace")" || return 1
    if [[ ! -d "$ns_dir" || -L "$ns_dir" ]]; then
      return 0
    fi
    while IFS= read -r run_id || [[ -n "$run_id" ]]; do
      [[ -n "$run_id" ]] || continue
      if [[ -n "$run_token" && "$run_id" != "$run_token" ]]; then
        continue
      fi
      run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")" || continue
      if graph_run_actions_request_exists "$run_dir" "$request_id"; then
        graph_run_actions_emit_match "$namespace" "$run_id" "$run_dir"
      fi
    done <<EOF
$(graph_state_list_runs "$workspace" "$namespace")
EOF
    return 0
  fi

  for ns_dir in "$runs_root"/*; do
    [[ -d "$ns_dir" && ! -L "$ns_dir" ]] || continue
    ns="$(basename "$ns_dir")"
    [[ -n "$ns" && "$ns" != "latest" ]] || continue
    while IFS= read -r run_id || [[ -n "$run_id" ]]; do
      [[ -n "$run_id" ]] || continue
      if [[ -n "$run_token" && "$run_id" != "$run_token" ]]; then
        continue
      fi
      run_dir="$(graph_state_run_dir "$workspace" "$ns" "$run_id")" || continue
      if graph_run_actions_request_exists "$run_dir" "$request_id"; then
        graph_run_actions_emit_match "$ns" "$run_id" "$run_dir"
      fi
    done <<EOF
$(graph_state_list_runs "$workspace" "$ns")
EOF
  done
  return 0
}

# graph_run_actions_respond_roots <workspace> <run-dir> <request-json>
# Prints {stateRoot,projectRoot}, falling back to the workspace roots.
graph_run_actions_respond_roots() {
  local workspace="$1" run_dir="$2" request_json="$3"
  local roots_json state_root project_root
  roots_json="$(graph_approval_resolve_roots "$run_dir" "$request_json")"
  state_root="$(printf '%s' "$roots_json" | jq -r '.stateRoot // empty')"
  project_root="$(printf '%s' "$roots_json" | jq -r '.projectRoot // empty')"
  if [[ -z "$state_root" || ! -d "$state_root" ]]; then
    state_root="$(graph_state_state_root "$workspace")" || return 1
  fi
  if [[ -z "$project_root" || ! -d "$project_root" ]]; then
    project_root="$workspace"
  fi
  jq -nc --arg stateRoot "$state_root" --arg projectRoot "$project_root" \
    '{stateRoot:$stateRoot,projectRoot:$projectRoot}'
}

# graph_run_actions_respond_cli <request-id> --decision <choice> [options]
graph_run_actions_respond_cli() {
  local request_id="" decision="" namespace="" run_token="" workspace=""
  local json=0 confirm_rule=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --decision) decision="$2"; shift 2 ;;
      --decision=*) decision="${1#--decision=}"; shift ;;
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --run) run_token="$2"; shift 2 ;;
      --run=*) run_token="${1#--run=}"; shift ;;
      --workspace) workspace="$2"; shift 2 ;;
      --workspace=*) workspace="${1#--workspace=}"; shift ;;
      --confirm-rule) confirm_rule="$2"; shift 2 ;;
      --confirm-rule=*) confirm_rule="${1#--confirm-rule=}"; shift ;;
      --json) json=1; shift ;;
      -h|--help)
        graph_run_actions_usage
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; return 1 ;;
      *)
        if [[ -z "$request_id" ]]; then
          request_id="$1"
          shift
        else
          echo "Error: unexpected argument '$1'" >&2
          return 1
        fi
        ;;
    esac
  done

  if [[ -z "$workspace" ]]; then
    workspace="$(pwd)"
  fi

  if [[ -z "$request_id" ]]; then
    echo "Error: graph actions respond requires <request-id>" >&2
    return 1
  fi
  graph_operator_request_id_valid "$request_id" || return 1

  if [[ -z "$decision" ]]; then
    echo "Error: graph actions respond requires --decision allow-once|allow-run|allow-always|deny" >&2
    return 1
  fi
  if ! graph_operator_token_in_list "$decision" "$GRAPH_OPERATOR_CHOICES"; then
    echo "Error: malformed operator decision choice: $decision" >&2
    return 1
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph actions respond" >&2
    return 1
  }

  local matches count match namespace_resolved run_id run_dir
  matches="$(graph_run_actions_find_request_matches "$workspace" "$request_id" "$namespace" "$run_token")" || return 1
  if [[ -z "$matches" ]]; then
    echo "Error: operator request not found: $request_id" >&2
    return 1
  fi
  count="$(printf '%s\n' "$matches" | jq -s 'length')"
  if [[ "$count" -gt 1 ]]; then
    echo "Error: request id '$request_id' is ambiguous; pass --namespace and --run" >&2
    printf '%s\n' "$matches" | jq -r '"  namespace=\(.namespace)  run=\(.runId)"' >&2
    return 1
  fi
  match="$(printf '%s\n' "$matches" | jq -s -c '.[0]')"
  namespace_resolved="$(printf '%s' "$match" | jq -r '.namespace')"
  run_id="$(printf '%s' "$match" | jq -r '.runId')"
  run_dir="$(printf '%s' "$match" | jq -r '.runDir')"

  local request_json nonce node_id runtime action resource effect choices_json
  request_json="$(graph_operator_request_read "$run_dir" "$request_id")" || return 1
  nonce="$(printf '%s' "$request_json" | jq -r '.nonce // empty')"
  node_id="$(printf '%s' "$request_json" | jq -r '.nodeId // empty')"
  runtime="$(printf '%s' "$request_json" | jq -r '.runtime // empty')"
  action="$(printf '%s' "$request_json" | jq -r '.action // empty')"
  resource="$(printf '%s' "$request_json" | jq -r '.resource // empty')"
  effect="$(printf '%s' "$request_json" | jq -r '.effect // empty')"
  choices_json="$(printf '%s' "$request_json" | jq -c '.choices // []')"

  local normalized rule_id roots_json state_root project_root
  local confirm_path="" rule_path="" decision_path
  local decision_json

  if [[ "$decision" == "allow-always" ]]; then
    normalized="$(graph_approval_normalize_rule "$runtime" "$action" "$resource" "$effect")" || return 1
    rule_id="$(graph_approval_rule_id \
      "$(printf '%s' "$normalized" | jq -r '.runtime')" \
      "$(printf '%s' "$normalized" | jq -r '.action')" \
      "$(printf '%s' "$normalized" | jq -r '.resource')" \
      "$(printf '%s' "$normalized" | jq -r '.effect')")" || return 1
    if [[ -z "$confirm_rule" || "$confirm_rule" != "$rule_id" ]]; then
      if [[ "$json" -eq 1 ]]; then
        jq -n \
          --arg namespace "$namespace_resolved" \
          --arg runId "$run_id" \
          --arg requestId "$request_id" \
          --arg decision "$decision" \
          --arg nodeId "$node_id" \
          --arg runtime "$runtime" \
          --arg action "$(printf '%s' "$normalized" | jq -r '.action')" \
          --arg resource "$(printf '%s' "$normalized" | jq -r '.resource')" \
          --arg effect "$(printf '%s' "$normalized" | jq -r '.effect')" \
          --arg confirmRule "$rule_id" \
          --argjson choices "$choices_json" \
          '{
            namespace:$namespace,
            runId:$runId,
            requestId:$requestId,
            decision:$decision,
            nodeId:$nodeId,
            runtime:$runtime,
            action:$action,
            resource:$resource,
            effect:$effect,
            choices:$choices,
            confirmRule:$confirmRule,
            needsConfirmation:true
          }'
      else
        printf 'allow-always requires confirmation\n' >&2
        printf '  requestId=%s  node=%s  runtime=%s  action=%s  resource=%s  effect=%s\n' \
          "$request_id" "$node_id" "$runtime" \
          "$(printf '%s' "$normalized" | jq -r '.action')" \
          "$(printf '%s' "$normalized" | jq -r '.resource')" \
          "$(printf '%s' "$normalized" | jq -r '.effect')" >&2
        printf '  confirmRule=%s\n' "$rule_id" >&2
        echo "Error: allow-always requires --confirm-rule $rule_id" >&2
      fi
      return 1
    fi
    roots_json="$(graph_run_actions_respond_roots "$workspace" "$run_dir" "$request_json")" || return 1
    state_root="$(printf '%s' "$roots_json" | jq -r '.stateRoot')"
    project_root="$(printf '%s' "$roots_json" | jq -r '.projectRoot')"
    mkdir -p "$state_root" || return 1
    confirm_path="$(graph_approval_project_confirm_write "$state_root" "$project_root" "$(jq -nc \
      --arg requestId "$request_id" \
      --arg runtime "$runtime" \
      --arg action "$action" \
      --arg resource "$resource" \
      --arg effect "$effect" \
      '{requestId:$requestId,runtime:$runtime,action:$action,resource:$resource,effect:$effect}')")" || return 1
    rule_path="$(graph_approval_project_rule_write "$state_root" "$project_root" "$(jq -nc \
      --arg requestId "$request_id" \
      --arg runtime "$runtime" \
      --arg action "$action" \
      --arg resource "$resource" \
      --arg effect "$effect" \
      --arg decision "allow-always" \
      '{requestId:$requestId,runtime:$runtime,action:$action,resource:$resource,effect:$effect,decision:$decision}')")" || return 1
  fi

  decision_json="$(jq -nc \
    --arg requestId "$request_id" \
    --arg nonce "$nonce" \
    --arg decision "$decision" \
    --arg actorSource "cli" \
    '{requestId:$requestId,nonce:$nonce,decision:$decision,actorSource:$actorSource}')"
  decision_path="$(graph_operator_decision_write "$run_dir" "$decision_json")" || return 1

  if [[ "$decision" == "allow-run" ]]; then
    rule_path="$(graph_approval_run_rule_write "$run_dir" "$(jq -nc \
      --arg requestId "$request_id" \
      --arg runtime "$runtime" \
      --arg action "$action" \
      --arg resource "$resource" \
      --arg effect "$effect" \
      --arg decision "allow-run" \
      '{requestId:$requestId,runtime:$runtime,action:$action,resource:$resource,effect:$effect,decision:$decision}')")" || return 1
  fi

  if [[ "$json" -eq 1 ]]; then
    jq -n \
      --arg namespace "$namespace_resolved" \
      --arg runId "$run_id" \
      --arg requestId "$request_id" \
      --arg decision "$decision" \
      --arg nodeId "$node_id" \
      --arg runtime "$runtime" \
      --arg action "$action" \
      --arg resource "$resource" \
      --arg effect "$effect" \
      --arg path "$decision_path" \
      --arg confirmPath "${confirm_path:-}" \
      --arg rulePath "${rule_path:-}" \
      '{
        namespace:$namespace,
        runId:$runId,
        requestId:$requestId,
        decision:$decision,
        nodeId:$nodeId,
        runtime:$runtime,
        action:$action,
        resource:$resource,
        effect:$effect,
        path:$path
      } + (if $confirmPath == "" then {} else {confirmPath:$confirmPath} end)
        + (if $rulePath == "" then {} else {rulePath:$rulePath} end)'
    return 0
  fi

  printf '# graph actions respond  run=%s  namespace=%s\n' "$run_id" "$namespace_resolved"
  printf '%s  decision=%s  node=%s  runtime=%s  action=%s  resource=%s  effect=%s\n' \
    "$request_id" "$decision" "$node_id" "$runtime" "$action" "$resource" "$effect"
}

# graph_run_actions_approvals_cli <list|revoke> [options]
graph_run_actions_approvals_cli() {
  if [[ $# -eq 0 ]]; then
    echo "Error: graph actions approvals requires a subcommand" >&2
    graph_run_actions_approvals_usage
    return 1
  fi

  local sub="$1"
  shift

  case "$sub" in
    list)
      graph_run_actions_approvals_list_cli "$@"
      ;;
    revoke)
      graph_run_actions_approvals_revoke_cli "$@"
      ;;
    -h|--help)
      graph_run_actions_approvals_usage
      return 0
      ;;
    *)
      echo "Error: unknown graph actions approvals verb '$sub'" >&2
      graph_run_actions_approvals_usage
      return 1
      ;;
  esac
}

# graph_run_actions_approvals_guard_store <abs>
# Refuse to read or write a runtime-global path. Policy helpers already
# enforce this; the CLI repeats the check so list/revoke never touch
# ~/.cursor, ~/.claude, ~/.codex, ~/.opencode, or ~/.agents.
graph_run_actions_approvals_guard_store() {
  local abs="$1"
  if [[ -z "$abs" ]]; then
    return 0
  fi
  if graph_approval_is_runtime_global_path "$abs"; then
    echo "Error: graph actions approvals refuse to edit runtime-global configuration: $abs" >&2
    return 1
  fi
  return 0
}

# graph_run_actions_approvals_row_json <rule-json>
# Prints one CLI row with exact normalized scope, rule id, and revocation
# state. Stored rules are already normalized; this re-normalizes so the
# operator always sees the exact key used for matching and revoke.
graph_run_actions_approvals_row_json() {
  local rule="$1" runtime action resource effect normalized rule_id
  if [[ -z "$rule" ]]; then
    echo "Error: graph_run_actions_approvals_row_json requires rule JSON" >&2
    return 1
  fi
  runtime="$(printf '%s' "$rule" | jq -r '.runtime // empty')"
  action="$(printf '%s' "$rule" | jq -r '.action // empty')"
  resource="$(printf '%s' "$rule" | jq -r '.resource // empty')"
  effect="$(printf '%s' "$rule" | jq -r '.effect // empty')"
  normalized="$(graph_approval_normalize_rule "$runtime" "$action" "$resource" "$effect")" || return 1
  runtime="$(printf '%s' "$normalized" | jq -r '.runtime')"
  action="$(printf '%s' "$normalized" | jq -r '.action')"
  resource="$(printf '%s' "$normalized" | jq -r '.resource')"
  effect="$(printf '%s' "$normalized" | jq -r '.effect')"
  rule_id="$(graph_approval_rule_id "$runtime" "$action" "$resource" "$effect")" || return 1
  printf '%s' "$rule" | jq -c \
    --arg ruleId "$rule_id" \
    --arg runtime "$runtime" \
    --arg action "$action" \
    --arg resource "$resource" \
    --arg effect "$effect" \
    '{
      ruleId: $ruleId,
      runtime: $runtime,
      action: $action,
      resource: $resource,
      effect: $effect,
      decision: ((.decision // "") | tostring),
      scope: ((.scope // "project") | tostring),
      requestId: ((.requestId // "") | tostring),
      createdAt: ((.createdAt // "") | tostring),
      revokedAt: (.revokedAt // null),
      revoked: ((.revokedAt // null) != null)
    }'
}

# graph_run_actions_approvals_rows_json <state-root> <project-root>
# Prints a JSON array of project approval rows, including revoked rules.
graph_run_actions_approvals_rows_json() {
  local state_root="$1" project_root="$2"
  local listed tmp count i rule row ec=0
  listed="$(graph_approval_project_rule_list "$state_root" "$project_root")" || return 1
  count="$(printf '%s' "$listed" | jq 'length')"
  if [[ "$count" -eq 0 ]]; then
    printf '[]\n'
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-approvals.XXXXXX")" || return 1
  : >"$tmp"
  i=0
  while [[ "$i" -lt "$count" ]]; do
    rule="$(printf '%s' "$listed" | jq -c --argjson i "$i" '.[$i]')" || {
      rm -f "$tmp"
      return 1
    }
    row="$(graph_run_actions_approvals_row_json "$rule")" || {
      echo "Warning: skipping unreadable project approval rule" >&2
      i=$((i + 1))
      continue
    }
    printf '%s\n' "$row" >>"$tmp"
    i=$((i + 1))
  done
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    printf '[]\n'
    return 0
  fi
  jq -s '.' "$tmp"
  ec=$?
  rm -f "$tmp"
  return "$ec"
}

# graph_run_actions_approvals_print_row <row-json>
graph_run_actions_approvals_print_row() {
  printf '%s' "$1" | jq -r '
    .ruleId
    + "  runtime=" + .runtime
    + "  action=" + .action
    + "  resource=" + .resource
    + "  effect=" + .effect
    + "  decision=" + .decision
    + "  revoked=" + (if .revoked then "yes" else "no" end)
    + (if .revokedAt == null then "" else "  revokedAt=" + (.revokedAt | tostring) end)
  '
}

# graph_run_actions_approvals_list_cli [--workspace <dir>] [--json]
graph_run_actions_approvals_list_cli() {
  local workspace="" json=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace) workspace="$2"; shift 2 ;;
      --workspace=*) workspace="${1#--workspace=}"; shift ;;
      --json) json=1; shift ;;
      -h|--help)
        graph_run_actions_approvals_usage
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; return 1 ;;
      *)
        echo "Error: unexpected argument '$1'" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$workspace" ]]; then
    workspace="$(pwd)"
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph actions approvals list" >&2
    return 1
  }

  local project_root state_root store_path="" project_id rows count
  project_root="$(graph_approval_project_canonical_root "$workspace")" || return 1
  state_root="$(graph_state_state_root "$workspace")" || return 1
  project_id="$(graph_approval_project_identity "$project_root")" || return 1

  if [[ -d "$state_root" ]]; then
    store_path="$(graph_approval_project_policy_path "$state_root")" || return 1
    graph_run_actions_approvals_guard_store "$store_path" || return 1
    rows="$(graph_run_actions_approvals_rows_json "$state_root" "$project_root")" || return 1
  else
    rows='[]'
  fi

  if [[ "$json" -eq 1 ]]; then
    jq -n \
      --arg projectRoot "$project_root" \
      --arg projectId "$project_id" \
      --arg stateRoot "$state_root" \
      --arg path "$store_path" \
      --argjson approvals "$rows" \
      '{
        projectRoot:$projectRoot,
        projectId:$projectId,
        stateRoot:$stateRoot,
        approvals:$approvals
      } + (if $path == "" then {} else {path:$path} end)'
    return 0
  fi

  printf '# graph actions approvals  project=%s\n' "$project_root"
  count="$(printf '%s' "$rows" | jq 'length')"
  if [[ "$count" -eq 0 ]]; then
    printf 'no project approvals\n'
    return 0
  fi
  local i row
  i=0
  while [[ "$i" -lt "$count" ]]; do
    row="$(printf '%s' "$rows" | jq -c --argjson i "$i" '.[$i]')"
    graph_run_actions_approvals_print_row "$row"
    i=$((i + 1))
  done
}

# graph_run_actions_approvals_revoke_cli --runtime <rt> --action <name>
#   --resource <path> --effect <effect> [--workspace <dir>] [--json]
graph_run_actions_approvals_revoke_cli() {
  local workspace="" json=0 runtime="" action="" resource="" effect=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace) workspace="$2"; shift 2 ;;
      --workspace=*) workspace="${1#--workspace=}"; shift ;;
      --runtime) runtime="$2"; shift 2 ;;
      --runtime=*) runtime="${1#--runtime=}"; shift ;;
      --action) action="$2"; shift 2 ;;
      --action=*) action="${1#--action=}"; shift ;;
      --resource) resource="$2"; shift 2 ;;
      --resource=*) resource="${1#--resource=}"; shift ;;
      --effect) effect="$2"; shift 2 ;;
      --effect=*) effect="${1#--effect=}"; shift ;;
      --json) json=1; shift ;;
      -h|--help)
        graph_run_actions_approvals_usage
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; return 1 ;;
      *)
        echo "Error: unexpected argument '$1'" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$workspace" ]]; then
    workspace="$(pwd)"
  fi

  if [[ -z "$runtime" || -z "$action" || -z "$resource" || -z "$effect" ]]; then
    echo "Error: graph actions approvals revoke requires --runtime --action --resource --effect" >&2
    return 1
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph actions approvals revoke" >&2
    return 1
  }

  local project_root state_root store_path project_id normalized rule_id listed row
  project_root="$(graph_approval_project_canonical_root "$workspace")" || return 1
  state_root="$(graph_state_state_root "$workspace")" || return 1
  project_id="$(graph_approval_project_identity "$project_root")" || return 1
  if [[ ! -d "$state_root" ]]; then
    echo "Error: approval project rule not found" >&2
    return 1
  fi
  store_path="$(graph_approval_project_policy_path "$state_root")" || return 1
  graph_run_actions_approvals_guard_store "$store_path" || return 1

  normalized="$(graph_approval_normalize_rule "$runtime" "$action" "$resource" "$effect")" || return 1
  runtime="$(printf '%s' "$normalized" | jq -r '.runtime')"
  action="$(printf '%s' "$normalized" | jq -r '.action')"
  resource="$(printf '%s' "$normalized" | jq -r '.resource')"
  effect="$(printf '%s' "$normalized" | jq -r '.effect')"
  rule_id="$(graph_approval_rule_id "$runtime" "$action" "$resource" "$effect")" || return 1

  store_path="$(graph_approval_project_rule_revoke \
    "$state_root" "$project_root" "$runtime" "$action" "$resource" "$effect")" || return 1
  graph_run_actions_approvals_guard_store "$store_path" || return 1

  listed="$(graph_approval_project_rule_list "$state_root" "$project_root")" || return 1
  row="$(printf '%s' "$listed" | jq -c --argjson key "$normalized" '
    ((.[] | select(
      .runtime == $key.runtime
      and .action == $key.action
      and .resource == $key.resource
      and .effect == $key.effect
    )) // empty)
  ')"
  if [[ -z "$row" ]]; then
    echo "Error: approval project rule not found after revoke" >&2
    return 1
  fi
  row="$(graph_run_actions_approvals_row_json "$row")" || return 1

  if [[ "$json" -eq 1 ]]; then
    printf '%s' "$row" | jq -c \
      --arg projectRoot "$project_root" \
      --arg projectId "$project_id" \
      --arg stateRoot "$state_root" \
      --arg path "$store_path" \
      '. + {
        projectRoot:$projectRoot,
        projectId:$projectId,
        stateRoot:$stateRoot,
        path:$path
      }'
    return 0
  fi

  printf '# graph actions approvals revoke  project=%s\n' "$project_root"
  graph_run_actions_approvals_print_row "$row"
}

graph_run_logs_usage() {
  cat <<'EOF' >&2
Usage: graph-run.sh logs --namespace <ns> --run <run-id|latest> --node <id>
       [--workspace <dir>] [--attempt <id>] [--stream runner|agent|usage]
       [--tail N] [--follow]
EOF
}

graph_run_attach_usage() {
  cat <<'EOF' >&2
Usage: graph-run.sh attach --namespace <ns> --run <run-id|latest> [--workspace <dir>]
EOF
}

graph_run_recover_usage() {
  cat <<'EOF' >&2
Usage: graph-run.sh recover --namespace <ns> --run <run-id|latest> [--workspace <dir>]
EOF
}

# graph_run_follow_interval
# Poll interval in seconds. Zero/empty is rejected so follow cannot busy-loop.
graph_run_follow_interval() {
  local raw="${RALPH_GRAPH_FOLLOW_INTERVAL:-1}"
  case "$raw" in
    ''|0|0.0|0.00|0.000)
      printf '1\n'
      ;;
    *)
      printf '%s\n' "$raw"
      ;;
  esac
}

# graph_run_follow_sleep
# Sleep one follow interval. Interrupted sleep is nonfatal.
graph_run_follow_sleep() {
  sleep "$(graph_run_follow_interval)" || true
}

# graph_run_follow_file_size <path>
graph_run_follow_file_size() {
  local path="$1" size=""
  [[ -n "$path" && -f "$path" ]] || return 1
  size="$(stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null || true)"
  if [[ ! "$size" =~ ^[0-9]+$ ]]; then
    size="$(wc -c <"$path" 2>/dev/null | tr -d '[:space:]')"
  fi
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$size"
}

# graph_run_follow_file_inode <path>
graph_run_follow_file_inode() {
  local path="$1" inode=""
  [[ -n "$path" && -e "$path" ]] || return 1
  inode="$(stat -c '%i' "$path" 2>/dev/null || stat -f '%i' "$path" 2>/dev/null || true)"
  [[ -n "$inode" ]] || return 1
  printf '%s\n' "$inode"
}

# graph_run_logs_attempt_is_active <node_json> <attempt_id>
# Active when the attempt has no terminal outcome and the node is not in a
# finished state. Used to treat a missing log as explicit but nonfatal.
graph_run_logs_attempt_is_active() {
  local node_json="$1" attempt_id="$2" status="" outcome=""
  [[ -n "$node_json" && -n "$attempt_id" ]] || return 1
  status="$(printf '%s' "$node_json" | jq -r '.status // empty' 2>/dev/null || true)"
  outcome="$(printf '%s' "$node_json" | jq -r --arg aid "$attempt_id" '
    (.attempts // []) | map(select(.attemptId == $aid)) | last | .outcome // empty
  ' 2>/dev/null || true)"
  case "$outcome" in
    succeeded|failed|cancelled) return 1 ;;
  esac
  case "$status" in
    succeeded|failed|cancelled|skipped) return 1 ;;
  esac
  return 0
}

# graph_run_is_terminal_status <status>
graph_run_is_terminal_status() {
  case "${1:-}" in
    succeeded|failed|cancelled) return 0 ;;
    *) return 1 ;;
  esac
}

# graph_run_follow_emit <path> <tail_n>
# Print newly appeared bytes. Rotation (inode change) and truncation
# (size < offset) reset the offset so we do not replay another file as
# this stream. First observation honors --tail.
graph_run_follow_emit() {
  local path="$1" tail_n="${2:-}"
  local size="" inode=""
  [[ -n "$path" && -f "$path" && ! -L "$path" ]] || return 0
  size="$(graph_run_follow_file_size "$path" 2>/dev/null || true)"
  inode="$(graph_run_follow_file_inode "$path" 2>/dev/null || true)"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0

  if [[ -n "$inode" && -n "${GRAPH_RUN_FOLLOW_INODE:-}" && "$inode" != "$GRAPH_RUN_FOLLOW_INODE" ]]; then
    GRAPH_RUN_FOLLOW_OFFSET=0
    GRAPH_RUN_FOLLOW_SEEN=0
  fi
  if [[ "${GRAPH_RUN_FOLLOW_OFFSET:-0}" -gt "$size" ]]; then
    GRAPH_RUN_FOLLOW_OFFSET=0
    GRAPH_RUN_FOLLOW_SEEN=0
  fi

  if [[ "${GRAPH_RUN_FOLLOW_SEEN:-0}" -eq 0 ]]; then
    if [[ -n "$tail_n" ]]; then
      tail -n "$tail_n" "$path" || true
    elif [[ "$size" -gt 0 ]]; then
      cat "$path" || true
    fi
    GRAPH_RUN_FOLLOW_OFFSET="$size"
    GRAPH_RUN_FOLLOW_SEEN=1
    GRAPH_RUN_FOLLOW_INODE="$inode"
    return 0
  fi

  if [[ "$size" -gt "${GRAPH_RUN_FOLLOW_OFFSET:-0}" ]]; then
    tail -c +"$((GRAPH_RUN_FOLLOW_OFFSET + 1))" "$path" || true
    GRAPH_RUN_FOLLOW_OFFSET="$size"
  fi
  GRAPH_RUN_FOLLOW_INODE="$inode"
}

# graph_run_follow_on_signal
graph_run_follow_on_signal() {
  GRAPH_RUN_FOLLOW_INTERRUPTED=1
}

# graph_run_follow_loop <kind> <workspace> <namespace> <run_id> <run_dir>
#   [node_id] [attempt_id] [stream] [state_root] [tail_n]
# kind is "attempt" (logs --follow) or "run" (attach events). Read-only.
# Exits when the attempt/run is terminal, on interrupt, or at max polls.
graph_run_follow_loop() {
  local kind="$1" workspace="$2" namespace="$3" run_id="$4" run_dir="$5"
  local node_id="${6:-}" attempt_id="${7:-}" stream="${8:-}" state_root="${9:-}"
  local tail_n="${10:-}"
  local polls=0 max_polls="${RALPH_GRAPH_FOLLOW_MAX_POLLS:-}"
  local missing_noted=0 node_json="" abs="" run_json="" run_status=""
  local events_rel=""

  GRAPH_RUN_FOLLOW_INTERRUPTED=0
  GRAPH_RUN_FOLLOW_OFFSET=0
  GRAPH_RUN_FOLLOW_SEEN=0
  GRAPH_RUN_FOLLOW_INODE=""
  trap 'graph_run_follow_on_signal' INT TERM

  if [[ "$kind" == "run" ]]; then
    events_rel="$(graph_events_rel 2>/dev/null || printf 'events.jsonl\n')"
  fi

  while [[ "${GRAPH_RUN_FOLLOW_INTERRUPTED:-0}" -eq 0 ]]; do
    if [[ "$kind" == "attempt" ]]; then
      node_json="$(graph_state_read_node_v2 "$workspace" "$namespace" "$run_id" "$node_id" 2>/dev/null || true)"
      if [[ -z "$node_json" ]]; then
        echo "Error: graph logs could not read node '$node_id'" >&2
        trap - INT TERM
        return 1
      fi
      abs="$(graph_logs_select "$run_dir" "$node_json" "$attempt_id" "$stream" \
        "$state_root" "$namespace" "$node_id" 2>/dev/null || true)"
      if [[ -n "$abs" ]]; then
        graph_run_follow_emit "$abs" "$tail_n"
        missing_noted=0
      elif graph_run_logs_attempt_is_active "$node_json" "$attempt_id"; then
        if [[ "$missing_noted" -eq 0 ]]; then
          echo "graph log not found for stream '$stream' (attempt is still active)" >&2
          missing_noted=1
        fi
      else
        trap - INT TERM
        return 0
      fi
      if ! graph_run_logs_attempt_is_active "$node_json" "$attempt_id"; then
        trap - INT TERM
        return 0
      fi
    else
      run_json="$(graph_state_read_run "$workspace" "$namespace" "$run_id" 2>/dev/null || true)"
      if [[ -z "$run_json" ]]; then
        echo "Error: graph attach could not read run '$run_id'" >&2
        trap - INT TERM
        return 1
      fi
      run_status="$(printf '%s' "$run_json" | jq -r '.status // empty' 2>/dev/null || true)"
      abs="$(graph_logs_resolve "$run_dir" "$events_rel" 2>/dev/null || true)"
      if [[ -n "$abs" && -f "$abs" && ! -L "$abs" ]]; then
        graph_run_follow_emit "$abs" ""
        missing_noted=0
      elif ! graph_run_is_terminal_status "$run_status"; then
        if [[ "$missing_noted" -eq 0 ]]; then
          echo "event journal not found (run is still active)" >&2
          missing_noted=1
        fi
      fi
      if graph_run_is_terminal_status "$run_status"; then
        trap - INT TERM
        return 0
      fi
    fi

    polls=$((polls + 1))
    if [[ -n "$max_polls" && "$max_polls" =~ ^[1-9][0-9]*$ && "$polls" -ge "$max_polls" ]]; then
      trap - INT TERM
      return 0
    fi
    graph_run_follow_sleep
  done

  trap - INT TERM
  return 0
}

# graph_run_logs_cli [options]
# Read-only log selection. Resolves only ledger-owned contained paths and
# supports v1 namespace reads when the v2 file is absent. --follow waits
# for new bytes until the attempt is terminal or interrupted.
graph_run_logs_cli() {
  local namespace="" run_token="" workspace="" node_id="" attempt_id="" stream="agent" tail_n=""
  local follow=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --run) run_token="$2"; shift 2 ;;
      --run=*) run_token="${1#--run=}"; shift ;;
      --workspace) workspace="$2"; shift 2 ;;
      --workspace=*) workspace="${1#--workspace=}"; shift ;;
      --node) node_id="$2"; shift 2 ;;
      --node=*) node_id="${1#--node=}"; shift ;;
      --attempt) attempt_id="$2"; shift 2 ;;
      --attempt=*) attempt_id="${1#--attempt=}"; shift ;;
      --stream) stream="$2"; shift 2 ;;
      --stream=*) stream="${1#--stream=}"; shift ;;
      --tail) tail_n="$2"; shift 2 ;;
      --tail=*) tail_n="${1#--tail=}"; shift ;;
      --follow) follow=1; shift ;;
      -h|--help)
        graph_run_logs_usage
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; return 1 ;;
      *)
        echo "Error: unexpected argument '$1'" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$workspace" ]]; then
    workspace="$(pwd)"
  fi

  if [[ -z "$namespace" ]]; then
    echo "Error: graph logs requires --namespace <ns>" >&2
    return 1
  fi
  if [[ -z "$run_token" ]]; then
    echo "Error: graph logs requires --run <run-id|latest>" >&2
    return 1
  fi
  if [[ -z "$node_id" ]]; then
    echo "Error: graph logs requires --node <id>" >&2
    return 1
  fi
  if [[ -n "$tail_n" && ! "$tail_n" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: graph logs --tail requires a positive integer" >&2
    return 1
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph logs" >&2
    return 1
  }

  local run_id run_dir node_json state_root abs resolved_attempt errf select_err=""
  if ! run_id="$(graph_state_resolve_run_id "$workspace" "$namespace" "$run_token")"; then
    echo "Error: could not resolve run selector '$run_token' for namespace '$namespace'" >&2
    return 1
  fi
  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")" || return 1
  if ! node_json="$(graph_state_read_node_v2 "$workspace" "$namespace" "$run_id" "$node_id")"; then
    echo "Error: graph logs could not read node '$node_id'" >&2
    return 1
  fi
  state_root="$(graph_state_state_root "$workspace")" || return 1
  resolved_attempt="$(graph_logs_ledger_attempt_id "$node_json" "$attempt_id")" || return 1

  errf="$(mktemp "${TMPDIR:-/tmp}/graph-logs.XXXXXX")" || return 1
  abs=""
  if abs="$(graph_logs_select "$run_dir" "$node_json" "$resolved_attempt" "$stream" \
    "$state_root" "$namespace" "$node_id" 2>"$errf")"; then
    rm -f "$errf"
  else
    select_err="$(cat "$errf" 2>/dev/null || true)"
    rm -f "$errf"
    if [[ "$select_err" == *"not found"* ]] && \
      graph_run_logs_attempt_is_active "$node_json" "$resolved_attempt"; then
      abs=""
      if [[ "$follow" -eq 0 ]]; then
        echo "graph log not found for stream '$stream' (attempt is still active)" >&2
        return 0
      fi
    else
      if [[ -n "$select_err" ]]; then
        printf '%s\n' "$select_err" >&2
      fi
      return 1
    fi
  fi

  if [[ "$follow" -eq 0 ]]; then
    graph_logs_print_file "$abs" "$tail_n"
    return $?
  fi

  if [[ -n "$abs" ]] && ! graph_run_logs_attempt_is_active "$node_json" "$resolved_attempt"; then
    graph_logs_print_file "$abs" "$tail_n"
    return $?
  fi

  graph_run_follow_loop "attempt" "$workspace" "$namespace" "$run_id" "$run_dir" \
    "$node_id" "$resolved_attempt" "$stream" "$state_root" "$tail_n"
}

# graph_run_attach_cli [options]
# Read-only attach: print current status, then follow the event journal
# until the run is terminal or the operator detaches. Never mutates state.
graph_run_attach_cli() {
  local namespace="" run_token="" workspace=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --run) run_token="$2"; shift 2 ;;
      --run=*) run_token="${1#--run=}"; shift ;;
      --workspace) workspace="$2"; shift 2 ;;
      --workspace=*) workspace="${1#--workspace=}"; shift ;;
      -h|--help)
        graph_run_attach_usage
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; return 1 ;;
      *)
        echo "Error: unexpected argument '$1'" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$workspace" ]]; then
    workspace="$(pwd)"
  fi
  if [[ -z "$namespace" ]]; then
    echo "Error: graph attach requires --namespace <ns>" >&2
    return 1
  fi
  if [[ -z "$run_token" ]]; then
    echo "Error: graph attach requires --run <run-id|latest>" >&2
    return 1
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph attach" >&2
    return 1
  }

  local run_id run_dir run_json run_status events_rel events_abs
  if ! run_id="$(graph_state_resolve_run_id "$workspace" "$namespace" "$run_token")"; then
    echo "Error: could not resolve run selector '$run_token' for namespace '$namespace'" >&2
    return 1
  fi
  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")" || return 1
  run_json="$(graph_state_read_run "$workspace" "$namespace" "$run_id")" || {
    echo "Error: graph attach could not read run '$run_id'" >&2
    return 1
  }
  run_status="$(printf '%s' "$run_json" | jq -r '.status // empty' 2>/dev/null || true)"

  graph_status_run "$workspace" "$namespace" "$run_id" || return 1

  events_rel="$(graph_events_rel 2>/dev/null || printf 'events.jsonl\n')"
  events_abs="$(graph_logs_resolve "$run_dir" "$events_rel" 2>/dev/null || true)"
  if [[ -z "$events_abs" || ! -f "$events_abs" || -L "$events_abs" ]]; then
    if graph_run_is_terminal_status "$run_status"; then
      echo "event journal not found" >&2
      return 0
    fi
  elif graph_run_is_terminal_status "$run_status"; then
    graph_logs_print_file "$events_abs" ""
    return 0
  fi

  graph_run_follow_loop "run" "$workspace" "$namespace" "$run_id" "$run_dir"
}

# graph_run_recover_cli [options]
# Explicit recover: require namespace/run selectors, resolve the run, and
# delegate to graph_recovery_attempt_run. Prints that module's refusal
# reasons unchanged. Status and attach never call this path.
graph_run_recover_cli() {
  local namespace="" run_token="" workspace=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --run) run_token="$2"; shift 2 ;;
      --run=*) run_token="${1#--run=}"; shift ;;
      --workspace) workspace="$2"; shift 2 ;;
      --workspace=*) workspace="${1#--workspace=}"; shift ;;
      -h|--help)
        graph_run_recover_usage
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; return 1 ;;
      *)
        echo "Error: unexpected argument '$1'" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$workspace" ]]; then
    workspace="$(pwd)"
  fi
  if [[ -z "$namespace" ]]; then
    echo "Error: graph recover requires --namespace <ns>" >&2
    return 1
  fi
  if [[ -z "$run_token" ]]; then
    echo "Error: graph recover requires --run <run-id|latest>" >&2
    return 1
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph recover" >&2
    return 1
  }

  local run_id
  if ! run_id="$(graph_state_resolve_run_id "$workspace" "$namespace" "$run_token")"; then
    echo "Error: could not resolve run selector '$run_token' for namespace '$namespace'" >&2
    return 1
  fi

  graph_recovery_attempt_run "$workspace" "$namespace" "$run_id"
}

graph_run_successor_usage() {
  cat <<'EOF' >&2
Usage: graph-run.sh successor --from <run> --plan <path> [--namespace <ns>] [--workspace <dir>] [--create] [--run-id <id>] [--json]
EOF
}

# graph_run_successor_emit_match <namespace> <run-id> <run-dir>
graph_run_successor_emit_match() {
  jq -nc --arg namespace "$1" --arg runId "$2" --arg runDir "$3" \
    '{namespace:$namespace,runId:$runId,runDir:$runDir}'
}

# graph_run_successor_run_exists <workspace> <namespace> <run-id>
# Exit 0 when the run has both a ledger and a frozen graph.
graph_run_successor_run_exists() {
  local workspace="$1" namespace="$2" run_id="$3" run_file graph_file
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")" || return 1
  graph_file="$(graph_state_graph_file "$workspace" "$namespace" "$run_id")" || return 1
  [[ -f "$run_file" && ! -L "$run_file" && -f "$graph_file" && ! -L "$graph_file" ]]
}

# graph_run_successor_find_matches <workspace> <from-token> [namespace]
# Prints one JSON object per matching predecessor. `latest` requires a
# namespace. A run id present in more than one namespace is left for the
# caller to refuse as ambiguous.
graph_run_successor_find_matches() {
  local workspace="$1" from_token="$2" namespace="${3:-}"
  local runs_root ns_dir ns run_id run_dir resolved

  if [[ -z "$from_token" ]]; then
    echo "Error: graph successor requires --from <run>" >&2
    return 1
  fi

  if [[ "$from_token" == "latest" && -z "$namespace" ]]; then
    echo "Error: --from latest is ambiguous; pass --namespace" >&2
    return 1
  fi

  if [[ -n "$namespace" ]]; then
    resolved="$(graph_state_resolve_run_id "$workspace" "$namespace" "$from_token")" || {
      echo "Error: could not resolve --from '$from_token' for namespace '$namespace'" >&2
      return 1
    }
    run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$resolved")" || return 1
    if graph_run_successor_run_exists "$workspace" "$namespace" "$resolved"; then
      graph_run_successor_emit_match "$namespace" "$resolved" "$run_dir"
    fi
    return 0
  fi

  runs_root="$(graph_state_runs_root "$workspace")" || return 1
  if [[ ! -d "$runs_root" ]]; then
    return 0
  fi

  for ns_dir in "$runs_root"/*; do
    [[ -d "$ns_dir" && ! -L "$ns_dir" ]] || continue
    ns="$(basename "$ns_dir")"
    [[ -n "$ns" && "$ns" != "latest" ]] || continue
    run_id="$from_token"
    if ! graph_run_successor_run_exists "$workspace" "$ns" "$run_id"; then
      continue
    fi
    run_dir="$(graph_state_run_dir "$workspace" "$ns" "$run_id")" || continue
    graph_run_successor_emit_match "$ns" "$run_id" "$run_dir"
  done
  return 0
}

# graph_run_successor_cli --from <run> --plan <path> [options]
# Default is a read-only dry-run reuse report. --create writes a new
# successor run. Never mutates the predecessor. Refuses ambiguous --from
# selectors, including `latest` without --namespace.
graph_run_successor_cli() {
  local from_token="" plan_path="" namespace="" workspace_opt="" create=0 dry_run=0
  local new_run_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from_token="$2"; shift 2 ;;
      --from=*) from_token="${1#--from=}"; shift ;;
      --plan) plan_path="$2"; shift 2 ;;
      --plan=*) plan_path="${1#--plan=}"; shift ;;
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --workspace) workspace_opt="$2"; shift 2 ;;
      --workspace=*) workspace_opt="${1#--workspace=}"; shift ;;
      --run-id) new_run_id="$2"; shift 2 ;;
      --run-id=*) new_run_id="${1#--run-id=}"; shift ;;
      --create) create=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      --json) shift ;;
      -h|--help)
        graph_run_successor_usage
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; graph_run_successor_usage; return 1 ;;
      *)
        echo "Error: unexpected argument '$1'" >&2
        graph_run_successor_usage
        return 1
        ;;
    esac
  done

  if [[ -z "$from_token" ]]; then
    echo "Error: graph successor requires --from <run>" >&2
    graph_run_successor_usage
    return 1
  fi
  if [[ -z "$plan_path" ]]; then
    echo "Error: graph successor requires --plan <path>" >&2
    graph_run_successor_usage
    return 1
  fi
  if [[ "$create" -eq 1 && "$dry_run" -eq 1 ]]; then
    echo "Error: graph successor refuses --create together with --dry-run" >&2
    return 1
  fi
  if [[ -n "$new_run_id" && "$create" -ne 1 ]]; then
    echo "Error: graph successor --run-id requires --create" >&2
    return 1
  fi
  if [[ ! -f "$plan_path" ]]; then
    echo "Error: plan file not found: $plan_path" >&2
    return 1
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph successor" >&2
    return 1
  }

  local invocation roots_json workspace state_root
  invocation="${workspace_opt:-$(pwd)}"
  if [[ -n "$workspace_opt" ]]; then
    export RALPH_PROJECT_ROOT="$workspace_opt"
  fi
  roots_json="$(graph_run_base_resolve_roots "$invocation")" || return 1
  workspace="$(printf '%s' "$roots_json" | jq -r '.projectRoot')"
  state_root="$(printf '%s' "$roots_json" | jq -r '.stateRoot')"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PROJECT_ROOT="$workspace"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"

  local matches count match pred_namespace pred_run_id
  matches="$(graph_run_successor_find_matches "$workspace" "$from_token" "$namespace")" || return 1
  if [[ -z "$matches" ]]; then
    echo "Error: predecessor run not found: $from_token" >&2
    return 1
  fi
  count="$(printf '%s\n' "$matches" | jq -s 'length')"
  if [[ "$count" -gt 1 ]]; then
    echo "Error: --from '$from_token' is ambiguous; pass --namespace" >&2
    printf '%s\n' "$matches" | jq -r '"  namespace=\(.namespace)  run=\(.runId)"' >&2
    return 1
  fi
  match="$(printf '%s\n' "$matches" | jq -s -c '.[0]')"
  pred_namespace="$(printf '%s' "$match" | jq -r '.namespace')"
  pred_run_id="$(printf '%s' "$match" | jq -r '.runId')"

  if [[ -n "$new_run_id" && "$new_run_id" == "$pred_run_id" ]]; then
    echo "Error: successor run id must differ from predecessor $pred_run_id" >&2
    return 1
  fi

  local graph_json report result
  graph_json="$(mktemp "$state_root/graph-successor.XXXXXX")" || return 1
  if ! graph_compile_plan "$plan_path" "$graph_json" 1 >/dev/null; then
    rm -f "$graph_json"
    return 1
  fi

  if [[ "$create" -ne 1 ]]; then
    report="$(graph_successor_reuse_report \
      "$(graph_state_graph_file "$workspace" "$pred_namespace" "$pred_run_id")" \
      "$graph_json" "$workspace" "$pred_namespace" "$pred_run_id")" || {
      rm -f "$graph_json"
      echo "Error: graph successor failed to compute reuse report" >&2
      return 1
    }
    rm -f "$graph_json"
    result="$(jq -nS --argjson report "$report" \
      '$report + {dryRun: true, create: false}')" || return 1
    printf '%s\n' "$result"
    return 0
  fi

  result="$(graph_successor_create "$workspace" "$pred_namespace" "$pred_run_id" \
    "$graph_json" "$plan_path" "${new_run_id:-}")" || {
    rm -f "$graph_json"
    return 1
  }
  rm -f "$graph_json"
  result="$(jq -nS --argjson result "$result" \
    '$result + {dryRun: false, create: true}')" || return 1
  printf '%s\n' "$result"
}

graph_run_tui_usage() {
  cat <<'EOF' >&2
Usage: graph-run.sh tui --namespace <ns> --run <run-id|latest> [--workspace <dir>] [--no-tui]
EOF
}

# graph_run_tui_script
# Path to the standard-library TUI module shipped beside this entrypoint.
graph_run_tui_script() {
  printf '%s\n' "$SCRIPT_DIR/python/graph_tui.py"
}

# graph_run_tui_python_ok
graph_run_tui_python_ok() {
  command -v python3 >/dev/null 2>&1
}

# graph_run_tui_curses_ok
graph_run_tui_curses_ok() {
  graph_run_tui_python_ok || return 1
  python3 -c 'import importlib; importlib.import_module("curses")' >/dev/null 2>&1
}

# graph_run_tui_tty_ok
# A suitable TTY is stdin+stdout, a usable TERM, and no CI/plain/screen-reader
# override. Narrow terminals remain eligible; the renderer truncates safely.
graph_run_tui_tty_ok() {
  [[ -t 0 && -t 1 ]] || return 1
  case "${TERM:-}" in
    ""|dumb) return 1 ;;
  esac
  case "${CI:-}" in
    1|true|TRUE|yes|YES|on|ON) return 1 ;;
  esac
  case "${RALPH_GRAPH_PLAIN:-}" in
    1|true|TRUE|yes|YES|on|ON) return 1 ;;
  esac
  case "${RALPH_GRAPH_NO_TUI:-}" in
    1|true|TRUE|yes|YES|on|ON) return 1 ;;
  esac
  case "${RALPH_GRAPH_SCREEN_READER:-}${ACCESSIBILITY_SCREEN_READER:-}" in
    1*|true*|TRUE*|yes*|YES*|on*|ON*) return 1 ;;
  esac
  return 0
}

# graph_run_tui_should_launch <mode>
# mode is auto|tui|no-tui. Returns 0 when the curses viewer should start.
graph_run_tui_should_launch() {
  local mode="${1:-auto}"
  [[ "$mode" == "no-tui" ]] && return 1
  graph_run_tui_python_ok || return 1
  graph_run_tui_curses_ok || return 1
  graph_run_tui_tty_ok || return 1
  return 0
}

# graph_run_tui_stream_status_bash <workspace> <namespace> <run-id> <run-dir>
# Last-resort concise status when python3 itself is missing.
graph_run_tui_stream_status_bash() {
  local workspace="$1" namespace="$2" run_id="$3" run_dir="$4"
  local run_json run_status
  echo "graph tui: falling back to concise streaming status (python unavailable)" >&2
  graph_status_run "$workspace" "$namespace" "$run_id" || return 1
  run_json="$(graph_state_read_run "$workspace" "$namespace" "$run_id" 2>/dev/null || true)"
  run_status="$(printf '%s' "$run_json" | jq -r '.status // empty' 2>/dev/null || true)"
  if graph_run_is_terminal_status "$run_status"; then
    return 0
  fi
  graph_run_follow_loop "run" "$workspace" "$namespace" "$run_id" "$run_dir"
}

# graph_run_tui_launch <run-dir> <workspace> <mode> [namespace] [run-id]
# Launch curses when available; otherwise stream concise status. Python
# restores terminal settings; this wrapper keeps SIGINT/SIGTERM from
# cancelling a headless supervisor started by --tui.
graph_run_tui_launch() {
  local run_dir="$1" workspace="$2" mode="${3:-auto}"
  local namespace="${4:-}" run_id="${5:-}"
  local script rc=0
  script="$(graph_run_tui_script)"
  if [[ ! -f "$script" ]]; then
    echo "Error: graph tui module not found: $script" >&2
    return 1
  fi
  if graph_run_tui_python_ok; then
    python3 "$script" \
      --run-dir "$run_dir" \
      --workspace "$workspace" \
      --graph-run "$SCRIPT_DIR/graph-run.sh" \
      --mode "$mode" || rc=$?
    return "$rc"
  fi
  if [[ -n "$namespace" && -n "$run_id" ]]; then
    graph_run_tui_stream_status_bash "$workspace" "$namespace" "$run_id" "$run_dir"
    return $?
  fi
  echo "graph tui: falling back to concise streaming status (python unavailable)" >&2
  return 1
}

# graph_run_tui_with_schedule <graph-json> <run-id> <workspace> <run-dir> <namespace>
# Optional interactive launch: keep the supervisor headless in the background
# so detaching the TUI does not stop execution.
graph_run_tui_with_schedule() {
  local graph_json="$1" run_id="$2" workspace="$3" run_dir="$4" namespace="$5"
  local log_rel log_abs schedule_pid=0 schedule_rc=0
  log_rel="$(graph_logs_supervisor_rel 2>/dev/null || printf 'logs/supervisor.log\n')"
  mkdir -p "$run_dir/logs"
  log_abs="$run_dir/$log_rel"
  trap '' INT TERM
  graph_schedule_run "$graph_json" "$run_id" "$workspace" "$run_dir" >>"$log_abs" 2>&1 &
  schedule_pid=$!
  graph_run_tui_launch "$run_dir" "$workspace" "tui" "$namespace" "$run_id" || true
  wait "$schedule_pid" || schedule_rc=$?
  trap - INT TERM
  return "$schedule_rc"
}

# graph_run_tui_cli --namespace <ns> --run <run-id|latest> [--workspace <dir>]
#   [--no-tui]
graph_run_tui_cli() {
  local namespace="" run_token="" workspace="" mode="auto"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --run) run_token="$2"; shift 2 ;;
      --run=*) run_token="${1#--run=}"; shift ;;
      --workspace) workspace="$2"; shift 2 ;;
      --workspace=*) workspace="${1#--workspace=}"; shift ;;
      --tui) mode="tui"; shift ;;
      --no-tui) mode="no-tui"; shift ;;
      -h|--help)
        graph_run_tui_usage
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; graph_run_tui_usage; return 1 ;;
      *)
        echo "Error: unexpected argument '$1'" >&2
        graph_run_tui_usage
        return 1
        ;;
    esac
  done

  if [[ -z "$workspace" ]]; then
    workspace="$(pwd)"
  fi
  if [[ -z "$namespace" ]]; then
    echo "Error: graph tui requires --namespace <ns>" >&2
    graph_run_tui_usage
    return 1
  fi
  if [[ -z "$run_token" ]]; then
    echo "Error: graph tui requires --run <run-id|latest>" >&2
    graph_run_tui_usage
    return 1
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph tui" >&2
    return 1
  }

  local run_id run_dir
  if ! run_id="$(graph_state_resolve_run_id "$workspace" "$namespace" "$run_token")"; then
    echo "Error: could not resolve run selector '$run_token' for namespace '$namespace'" >&2
    return 1
  fi
  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")" || return 1
  graph_run_tui_launch "$run_dir" "$workspace" "$mode" "$namespace" "$run_id"
}

main "$@"
