#!/usr/bin/env bash
# Host/runtime preflight helpers shared by graph preflight and top-level
# `ralph doctor`. Probe and table-rendering logic lives here once; callers
# must not copy it.
#
# CLI probes are list/status/help only and never start a session or send a
# prompt. This module never writes graph, ledger, workspace, or ambient
# config files.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${PREFLIGHT_HOST_LOADED:-}" ]]; then
  return 0
fi
PREFLIGHT_HOST_LOADED=1

PREFLIGHT_HOST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# resolve_cli needs graph_runtime_cli_name; soft-source so doctor can load
# this module without pulling graph-gate or graph-preflight report code.
if ! declare -F graph_runtime_cli_name >/dev/null 2>&1; then
  # shellcheck source=../graph/graph-runtime-capabilities.sh
  source "$PREFLIGHT_HOST_SCRIPT_DIR/../graph/graph-runtime-capabilities.sh"
fi

# graph_preflight_cmd_available <name>
# Honors GRAPH_PREFLIGHT_UNAVAILABLE (comma-separated) so tests can force a miss.
graph_preflight_cmd_available() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1
  case ",${GRAPH_PREFLIGHT_UNAVAILABLE:-}," in
    *",$name,"*) return 1 ;;
  esac
  command -v "$name" >/dev/null 2>&1
}

# graph_preflight_cli_override_var <normalized-runtime>
graph_preflight_cli_override_var() {
  local runtime="$1"
  case "$runtime" in
    claude) printf 'GRAPH_PREFLIGHT_CLI_CLAUDE\n' ;;
    cursor) printf 'GRAPH_PREFLIGHT_CLI_CURSOR\n' ;;
    codex) printf 'GRAPH_PREFLIGHT_CLI_CODEX\n' ;;
    opencode) printf 'GRAPH_PREFLIGHT_CLI_OPENCODE\n' ;;
    antigravity) printf 'GRAPH_PREFLIGHT_CLI_ANTIGRAVITY\n' ;;
    *) printf 'GRAPH_PREFLIGHT_CLI_%s\n' "$(printf '%s' "$runtime" | tr '[:lower:]-' '[:upper:]_')" ;;
  esac
}

# graph_preflight_resolve_cli <normalized-runtime>
# Prints the CLI path or name. Empty when unknown. Never invokes the CLI.
graph_preflight_resolve_cli() {
  local runtime="$1" var override
  var="$(graph_preflight_cli_override_var "$runtime")"
  override=""
  if [[ -n "$var" ]]; then
    override="${!var-}"
  fi
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  graph_runtime_cli_name "$runtime"
}

# graph_preflight_cli_exists <cli>
graph_preflight_cli_exists() {
  local cli="${1:-}"
  [[ -n "$cli" ]] || return 1
  if [[ "$cli" == /* || "$cli" == ./* || "$cli" == ../* ]]; then
    [[ -x "$cli" ]]
    return
  fi
  graph_preflight_cmd_available "$cli"
}

# graph_preflight_auth_argv <normalized-runtime>
# Prints one flag/subcommand per line. Returns 1 when no auth probe exists.
graph_preflight_auth_argv() {
  case "${1:-}" in
    claude)
      printf '%s\n' auth status
      ;;
    codex)
      printf '%s\n' login status
      ;;
    *)
      return 1
      ;;
  esac
}

# graph_preflight_models_argv <normalized-runtime>
# Prints one flag/subcommand per line. Returns 1 when no list probe exists.
graph_preflight_models_argv() {
  case "${1:-}" in
    antigravity)
      printf '%s\n' models
      ;;
    cursor)
      printf '%s\n' --list-models
      ;;
    opencode)
      printf '%s\n' models
      ;;
    *)
      return 1
      ;;
  esac
}

# graph_preflight_auth_indicates_missing <text>
graph_preflight_auth_indicates_missing() {
  local text
  text="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$text" == *"not logged"* || "$text" == *"logged out"* || \
     "$text" == *"unauthenticated"* || "$text" == *"not authenticated"* || \
     "$text" == *"authentication required"* || "$text" == *"auth required"* || \
     "$text" == *"please log in"* || "$text" == *"please login"* ]]
}

# graph_preflight_run_probe <cli> <argv-lines>
# Runs a help/status/list probe. Never used for prompts. Prints stdout.
# Returns the CLI exit status.
graph_preflight_run_probe() {
  local cli="$1"
  local -a args=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    args+=("$line")
  done
  [[ ${#args[@]} -gt 0 ]] || return 1
  "$cli" "${args[@]}" 2>/dev/null
}

# graph_preflight_parse_model_list <normalized-runtime> <raw-text>
# Prints one catalog entry per line. Antigravity strings stay exact.
graph_preflight_parse_model_list() {
  local runtime="$1" raw="$2" line id
  case "$runtime" in
    antigravity)
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        printf '%s\n' "$line"
      done <<< "$raw"
      ;;
    cursor)
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == Tip:* ]] && break
        [[ "$line" == *" - "* ]] || continue
        id="${line%% - *}"
        id="${id#"${id%%[![:space:]]*}"}"
        id="${id%"${id##*[![:space:]]}"}"
        [[ -n "$id" ]] && printf '%s\n' "$id"
      done <<< "$raw"
      ;;
    opencode)
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[a-zA-Z0-9/._:-]+$ ]] || continue
        printf '%s\n' "$line"
      done <<< "$raw"
      ;;
  esac
}

# graph_preflight_model_in_catalog <model> <catalog-text>
# Exact string match. Does not lowercase or remap identifiers.
graph_preflight_model_in_catalog() {
  local model="$1" line
  [[ -n "$model" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$model" ]] && return 0
  done <<< "${2:-}"
  return 1
}

# graph_preflight_finding <id> <category> <status> <summary> [evidence] [repair] [nodeId] [runtime]
graph_preflight_finding() {
  local id="$1" category="$2" status="$3" summary="$4"
  local evidence="${5:-}" repair="${6:-}" node_id="${7:-}" runtime="${8:-}"
  jq -nc \
    --arg id "$id" \
    --arg category "$category" \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg evidence "$evidence" \
    --arg repair "$repair" \
    --arg nodeId "$node_id" \
    --arg runtime "$runtime" \
    '{
      id: $id,
      category: $category,
      status: $status,
      summary: $summary,
      evidence: (if $evidence == "" then null else $evidence end),
      repair: (if $repair == "" then null else $repair end),
      nodeId: (if $nodeId == "" then null else $nodeId end),
      runtime: (if $runtime == "" then null else $runtime end)
    }'
}

graph_preflight_append() {
  local file="$1"
  shift
  graph_preflight_finding "$@" >>"$file"
}

# graph_preflight_worst <findings-jsonl-file>
graph_preflight_worst() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    printf 'pass\n'
    return 0
  fi
  jq -s -r '
    if any(.[]; .status == "fail") then "fail"
    elif any(.[]; .status == "warn") then "warn"
    else "pass"
    end
  ' "$file"
}

# graph_preflight_format_table <report-json>
# Concise table: check ID, status, evidence, repair.
graph_preflight_format_table() {
  local json="${1:-}"
  printf '%s\n' "$json" | jq -r '
    ["ID","STATUS","EVIDENCE","REPAIR"],
    (.findings[] | [
      .id,
      .status,
      (.evidence // .summary),
      (.repair // "-")
    ])
    | @tsv
  ' | awk -F'\t' '
    BEGIN {
      w[1]=24; w[2]=6; w[3]=40; w[4]=32
    }
    {
      for (i=1;i<=4;i++) {
        s=$i
        if (length(s) > w[i]) s=substr(s,1,w[i]-1) ">"
        printf "%-*s%s", w[i], s, (i==4 ? "\n" : "  ")
      }
    }
  '
}
