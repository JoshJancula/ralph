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
GRAPH_COMPILE_BUNDLE_ROOT="$(cd "$GRAPH_COMPILE_RALPH_ROOT/.." && pwd)"
GRAPH_COMPILE_REPO_ROOT="$(cd "$GRAPH_COMPILE_BUNDLE_ROOT/.." && pwd)"
GRAPH_COMPILE_VALIDATE_SCHEMA_SH="$GRAPH_COMPILE_REPO_ROOT/scripts/validate-graph-schema.sh"

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
# Argument parsing and reporting for `ralph graph compile`.
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
