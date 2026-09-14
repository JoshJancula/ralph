#!/usr/bin/env bash
# Compile-only surface for graph mode: invokes plan_pipeline_graph_json from
# plan-todo.sh, validates the result against the graph schema, and caches the
# emitted .graph.json beside the plan file. This lets an operator lint and
# visualize an existing pipeline plan's implicit artifact DAG without running
# anything. See bundle/.ralph/graph-run.sh for the CLI entrypoint that calls
# graph_compile_cli.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_COMPILE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_COMPILE_RALPH_ROOT="$(cd "$GRAPH_COMPILE_SCRIPT_DIR/../.." && pwd)"
GRAPH_COMPILE_VALIDATE_SCHEMA_SH="$GRAPH_COMPILE_SCRIPT_DIR/validate-graph-schema.sh"

# plan-todo.sh guards its own re-sourcing (RALPH_PLAN_TODO_LIB_LOADED), so it
# is safe to source unconditionally even when a caller (bats helpers,
# run-plan-core, etc.) already loaded it.
# shellcheck source=../plan-todo.sh
source "$GRAPH_COMPILE_RALPH_ROOT/bash-lib/plan-todo.sh"
if ! command -v graph_render_stub >/dev/null 2>&1; then
  # shellcheck source=graph-render.sh
  source "$GRAPH_COMPILE_SCRIPT_DIR/graph-render.sh"
fi

graph_compile_usage() {
  cat <<'EOF' >&2
Usage: graph-run.sh compile <plan-path> [options]

Compile a graph-mode plan's frontmatter into a .graph.json document, validate
it against the graph schema, and cache the result beside the plan file
(<plan>.graph.json, or <plan-without-.md>.graph.json). Fails with a named
cycle when the declared dependsOn and derived artifact edges are not a DAG.

Options:
  --render <mermaid|dot|ascii>   After a successful compile, invoke the
                                  render stub for the requested format. The
                                  stub is a placeholder until Phase 7 lands
                                  the real renderer; it always exits 0 for a
                                  recognized format.
  --out <path>                    Write the compiled graph to <path> instead
                                  of the default cache path.
  --force                         Recompile even if a cached .graph.json is
                                  newer than the plan file.
  -h, --help                      Show this help.
EOF
}

# graph_compile_freeze_planfrom_bindings <graph-json-path>
#
# Ordinary Dependency planFrom consumers (including bounded rework clones
# <target>-r<n>): freeze the authored planner-stage binding onto the compiled
# node, force sessionStrategy=fresh when absent, strip _inlineTodos/plan (plan
# is bound at dispatch from the registry control copy), and keep stage.planFrom
# as the frozen planner id. Rework clones inherit the original planner-stage
# relationship from the cloned stage.planFrom; the review/repair dependsOn is
# feedback only and never replaces the planner binding. Refuses planFrom stages
# that already carry a concrete plan path (invalid generated plan projection).
# Mutates the file in place. Prints the path on success.
graph_compile_freeze_planfrom_bindings() {
  local graph_path="${1:-}"
  local tmp bad
  [[ -n "$graph_path" && -f "$graph_path" ]] || {
    echo "Error: graph_compile_freeze_planfrom_bindings requires a graph json file" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph_compile_freeze_planfrom_bindings" >&2
    return 1
  }

  bad="$(jq -r '
    [.nodes[]?
      | select((.stage.planFrom // "") != "")
      | select((.stage.plan // "") != "")
      | .id] | .[]
    ' "$graph_path" 2>/dev/null)" || true
  if [[ -n "$bad" ]]; then
    echo "Error: invalid generated plan projection: planFrom node(s) already carry a plan path: $(printf '%s' "$bad" | tr '\n' ' ')" >&2
    return 1
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-planfrom.XXXXXX")" || return 1
  if ! jq -c '
    .nodes |= map(
      if ((.stage.planFrom // "") != "") then
        . as $n
        | .planFromBinding = {
            plannerStageId: .stage.planFrom,
            planSourceKind: "generated"
          }
        | .stage.planFrom = .stage.planFrom
        | .stage |= (
            del(._inlineTodos)
            | del(.plan)
            | if ((.sessionStrategy // "") == "") then
                .sessionStrategy = "fresh"
              else .
              end
          )
      else .
      end
    )
    ' "$graph_path" >"$tmp"; then
    rm -f "$tmp"
    echo "Error: failed to freeze planFrom planner bindings" >&2
    return 1
  fi
  mv -f "$tmp" "$graph_path" || {
    rm -f "$tmp"
    return 1
  }
  printf '%s\n' "$graph_path"
}

# graph_compile_freeze_provided_plan_bindings <graph-json-path> <plan-input-stage-id>
#
# Dependency plan-entry runs: freeze the exact planInput.stage (and its
# bounded rework clones <stage>-r<n>) with planSourceKind=provided and
# null planSourceStageId. Forces sessionStrategy=fresh when absent, strips
# _inlineTodos/plan, and clears authored planFrom on those nodes so the
# supplied-plan path wins for this run. Task-entry callers omit this step so
# generated planFrom bindings remain byte-compatible. Mutates in place.
graph_compile_freeze_provided_plan_bindings() {
  local graph_path="${1:-}" stage_id="${2:-}"
  local tmp bad missing
  [[ -n "$graph_path" && -f "$graph_path" && -n "$stage_id" ]] || {
    echo "Error: graph_compile_freeze_provided_plan_bindings requires a graph json file and planInput stage id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph_compile_freeze_provided_plan_bindings" >&2
    return 1
  }

  missing="$(jq -r --arg id "$stage_id" '
    if ([.nodes[]? | select(.id == $id)] | length) == 0 then $id else empty end
  ' "$graph_path" 2>/dev/null)"
  if [[ -n "$missing" ]]; then
    echo "Error: planInput.stage not found in compiled graph: $stage_id" >&2
    return 1
  fi

  bad="$(jq -r --arg id "$stage_id" '
    [.nodes[]?
      | select(.id == $id or (.id | test("^" + $id + "-r[0-9]+$")))
      | select((.stage.plan // "") != "")
      | .id] | .[]
    ' "$graph_path" 2>/dev/null)" || true
  if [[ -n "$bad" ]]; then
    echo "Error: invalid provided plan projection: planInput node(s) already carry a plan path: $(printf '%s' "$bad" | tr '\n' ' ')" >&2
    return 1
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-provided.XXXXXX")" || return 1
  if ! jq -c --arg id "$stage_id" '
    .nodes |= map(
      if (.id == $id or (.id | test("^" + $id + "-r[0-9]+$"))) then
        .planInputBinding = {
          planSourceKind: "provided",
          planSourceStageId: null
        }
        | del(.planFromBinding)
        | .stage |= (
            del(._inlineTodos)
            | del(.plan)
            | del(.planFrom)
            | if ((.sessionStrategy // "") == "") then
                .sessionStrategy = "fresh"
              else .
              end
          )
      else .
      end
    )
    ' "$graph_path" >"$tmp"; then
    rm -f "$tmp"
    echo "Error: failed to freeze provided-plan bindings" >&2
    return 1
  fi
  mv -f "$tmp" "$graph_path" || {
    rm -f "$tmp"
    return 1
  }
  printf '%s\n' "$graph_path"
}

# graph_compile_cache_path_for_plan <plan-path>
# Prints the default cache location for a plan's compiled graph: the plan
# path with a .plan.md or .md suffix replaced by .graph.json (or the suffix
# appended when neither is present).
graph_compile_cache_path_for_plan() {
  local plan_path="$1"
  case "$plan_path" in
    *.plan.md) printf '%s\n' "${plan_path%.plan.md}.graph.json" ;;
    *.md) printf '%s\n' "${plan_path%.md}.graph.json" ;;
    *) printf '%s\n' "${plan_path}.graph.json" ;;
  esac
}

# graph_compile_assert_approval_boundary <graph-json-path>
# Confirms every public Dependency approval node remains a frozen supervisor
# marker (type=approval) distinct from legacy checkpoint/file acknowledgement.
# Prints the path on success.
graph_compile_assert_approval_boundary() {
  local graph_path="${1:-}"
  local bad
  [[ -n "$graph_path" && -f "$graph_path" ]] || {
    echo "Error: graph_compile_assert_approval_boundary requires a graph json file" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph_compile_assert_approval_boundary" >&2
    return 1
  }

  bad="$(jq -r '
    [
      .nodes[]?
      | select((.type // "") == "approval" or ((.stage.type // "") == "approval"))
      | select(
          (.type // "") != "approval"
          or ((.stage.type // "") != "approval")
          or ((.stage.question // "") | length) == 0
          or ((.stage.changesTarget // "") | length) == 0
          or ((.dependsOn // []) | length) == 0
          or (
            ((.stage.inputArtifacts // []) | length) == 0
            and ((.stage.requires // []) | length) == 0
          )
          or (.stage | has("humanAck"))
          or ((.stage.runtime // null) != null)
          or ((.stage.model // null) != null)
          or ((.stage.agent // null) != null)
          or ((.stage.role // null) != null)
          or ((.stage.plan // null) != null)
          or ((.stage.planFile // null) != null)
          or ((.stage.planFrom // null) != null)
        )
      | .id
    ] | .[]
  ' "$graph_path" 2>/dev/null)" || true
  if [[ -n "$bad" ]]; then
    echo "Error: Dependency approval node(s) failed frozen supervisor boundary: $(printf '%s' "$bad" | tr '\n' ' ')" >&2
    return 1
  fi

  # Approval must never compile as checkpoint or carry ack-file vocabulary.
  bad="$(jq -r '
    [
      .nodes[]?
      | select((.stage.type // "") == "approval" or (.type // "") == "approval")
      | select((.type // "") == "checkpoint" or ((.stage.type // "") == "checkpoint"))
      | .id
    ] | .[]
  ' "$graph_path" 2>/dev/null)" || true
  if [[ -n "$bad" ]]; then
    echo "Error: approval must not compile as checkpoint: $(printf '%s' "$bad" | tr '\n' ' ')" >&2
    return 1
  fi
  if grep -qiE 'humanAck|ORCHESTRATOR_HUMAN_ACK|checkpoints/.+\.ack' "$graph_path" 2>/dev/null; then
    if jq -e '[.nodes[]? | select((.type // "") == "approval")] | length > 0' "$graph_path" >/dev/null 2>&1; then
      echo "Error: approval graph must not include legacy humanAck/checkpoint ack vocabulary" >&2
      return 1
    fi
  fi
  printf '%s\n' "$graph_path"
}

# graph_compile_plan <plan-path> [out-path] [force]
# Compiles plan_path to JSON, validates it, caches it at out-path (default:
# graph_compile_cache_path_for_plan), and prints the compiled JSON on stdout.
# Returns non-zero with a stderr message (e.g. a named cycle) on failure.
graph_compile_plan() {
  local plan_path="$1"
  local out_path="${2:-}"
  local force="${3:-0}"

  if [[ ! -f "$plan_path" ]]; then
    echo "Error: plan file not found: $plan_path" >&2
    return 1
  fi

  if [[ -z "$out_path" ]]; then
    out_path="$(graph_compile_cache_path_for_plan "$plan_path")"
  fi

  if [[ "$force" != "1" && -f "$out_path" && "$out_path" -nt "$plan_path" ]]; then
    cat "$out_path"
    return 0
  fi

  # Template must end in XXXXXX: macOS mktemp only replaces a trailing run of
  # X's, so a ".XXXXXX.json" suffix collapses to a fixed path and races under
  # parallel bats (-j N).
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-compile.XXXXXX")" || return 1

  # Capture compile status with `||` so a non-zero exit from
  # plan_pipeline_graph_json does not trip the caller's `set -e`, and so we
  # do not read $? inside an `if !` branch (where $? is always 0 because the
  # negated test succeeded). That bug previously made cycle failures look like
  # successful compiles.
  local compile_stderr="" compile_status=0
  compile_stderr="$(plan_pipeline_graph_json "$plan_path" 2>&1 1>"$tmp")" || compile_status=$?
  if [[ "$compile_status" -ne 0 ]]; then
    rm -f "$tmp"
    [[ -n "$compile_stderr" ]] && printf '%s\n' "$compile_stderr" >&2
    return "$compile_status"
  fi

  if ! graph_compile_freeze_planfrom_bindings "$tmp" >/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  # Plan-entry Dependency runs set RALPH_WORKFLOW_PLAN_INPUT_STAGE to the
  # exact planInput.stage id so provided bindings freeze at compile time.
  # Task-entry leaves it unset; generated planFrom bindings stay unchanged.
  if [[ -n "${RALPH_WORKFLOW_PLAN_INPUT_STAGE:-}" ]]; then
    if ! graph_compile_freeze_provided_plan_bindings "$tmp" "$RALPH_WORKFLOW_PLAN_INPUT_STAGE" >/dev/null; then
      rm -f "$tmp"
      return 1
    fi
  fi

  if ! graph_compile_assert_approval_boundary "$tmp" >/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  if [[ -f "$GRAPH_COMPILE_VALIDATE_SCHEMA_SH" ]]; then
    if ! bash "$GRAPH_COMPILE_VALIDATE_SCHEMA_SH" "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
  else
    echo "Warning: graph schema validator not found at $GRAPH_COMPILE_VALIDATE_SCHEMA_SH; skipping schema validation" >&2
  fi

  mkdir -p "$(dirname "$out_path")"
  mv "$tmp" "$out_path"
  cat "$out_path"
  return 0
}

# graph_compile_cli [--render mermaid|dot|ascii] [--out <path>] [--force] <plan-path>
# Argument parsing and reporting for `graph-run.sh compile`.
graph_compile_cli() {
  local plan_path=""
  local render_format=""
  local out_path=""
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --render)
        if [[ $# -lt 2 ]]; then
          echo "Error: --render requires a value" >&2
          graph_compile_usage
          return 1
        fi
        render_format="$2"
        shift 2
        ;;
      --render=*)
        render_format="${1#--render=}"
        shift
        ;;
      --out)
        if [[ $# -lt 2 ]]; then
          echo "Error: --out requires a value" >&2
          graph_compile_usage
          return 1
        fi
        out_path="$2"
        shift 2
        ;;
      --out=*)
        out_path="${1#--out=}"
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      -h|--help)
        graph_compile_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "Error: unknown option '$1'" >&2
        graph_compile_usage
        return 1
        ;;
      *)
        if [[ -n "$plan_path" ]]; then
          echo "Error: unexpected extra argument '$1'" >&2
          graph_compile_usage
          return 1
        fi
        plan_path="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$plan_path" ]]; then
    echo "Error: graph compile requires a plan path" >&2
    graph_compile_usage
    return 1
  fi

  if [[ -n "$render_format" ]]; then
    case "$render_format" in
      mermaid|dot|ascii) ;;
      *)
        echo "Error: --render must be mermaid, dot, or ascii" >&2
        return 1
        ;;
    esac
  fi

  local graph_json
  if ! graph_json="$(graph_compile_plan "$plan_path" "$out_path" "$force")"; then
    return 1
  fi

  printf '%s\n' "$graph_json"

  if [[ -n "$render_format" ]]; then
    local rendered_from="${out_path:-$(graph_compile_cache_path_for_plan "$plan_path")}"
    graph_render_stub "$rendered_from" "$render_format" || return 1
  fi

  return 0
}
