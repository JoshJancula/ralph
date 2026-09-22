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

# graph_preflight_runtime_label <normalized-runtime>
# Human label aligned with ralph-dashboard RUNTIME_PROBES / Runtimes page.
graph_preflight_runtime_label() {
  case "${1:-}" in
    claude) printf 'Claude (Anthropic)\n' ;;
    codex) printf 'Codex (OpenAI)\n' ;;
    antigravity) printf 'Antigravity (Google)\n' ;;
    cursor) printf 'Cursor Agent\n' ;;
    opencode) printf 'OpenCode\n' ;;
    *) printf '%s\n' "${1:-}" ;;
  esac
}

# graph_preflight_runtime_status_argv <normalized-runtime>
# Status probe argv aligned with ralph-dashboard/src/server/runtime-status.ts.
# Prints one flag/subcommand per line. Returns 1 when unknown.
graph_preflight_runtime_status_argv() {
  case "${1:-}" in
    cursor)
      printf '%s\n' status
      ;;
    claude)
      printf '%s\n' auth
      printf '%s\n' status
      ;;
    codex)
      printf '%s\n' login
      printf '%s\n' status
      ;;
    opencode)
      printf '%s\n' auth
      printf '%s\n' list
      ;;
    antigravity)
      printf '%s\n' models
      ;;
    *)
      return 1
      ;;
  esac
}

# graph_preflight_runtime_signed_out <normalized-runtime> <probe-output>
# Returns 0 when output indicates the runtime is not signed in (dashboard signedOut).
graph_preflight_runtime_signed_out() {
  local runtime="$1" text
  text="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
  case "$runtime" in
    cursor | claude | codex)
      [[ "$text" == *"not logged"* || "$text" == *"logged out"* || "$text" == *"not authenticated"* ]]
      ;;
    opencode)
      [[ "$text" == *"no credentials"* || "$text" == *"not logged"* || "$text" == *"logged out"* ]]
      ;;
    antigravity)
      [[ "$text" == *"not signed in"* || "$text" == *"sign in"* || \
         "$text" == *"select login method"* || "$text" == *"authentication required"* ]]
      ;;
    *)
      return 1
      ;;
  esac
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
  "$cli" "${args[@]}" 2>&1
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

# graph_preflight_table_style_init
# Sets PREFLIGHT_TBL_* color variables when stdout/stderr is a TTY.
graph_preflight_table_style_init() {
  PREFLIGHT_TBL_RST=""
  PREFLIGHT_TBL_BOLD=""
  PREFLIGHT_TBL_DIM=""
  PREFLIGHT_TBL_CYAN=""
  PREFLIGHT_TBL_PASS=""
  PREFLIGHT_TBL_WARN=""
  PREFLIGHT_TBL_FAIL=""
  if { [[ -t 1 ]] || [[ -t 2 ]]; } \
    && [[ "${NO_COLOR+x}" == x ]] \
    && [[ "${RALPH_INSTALL_NO_COLOR:-0}" != "1" ]]; then
    PREFLIGHT_TBL_RST=$'\033[0m'
    PREFLIGHT_TBL_BOLD=$'\033[1m'
    PREFLIGHT_TBL_DIM=$'\033[2m'
    PREFLIGHT_TBL_CYAN=$'\033[36m'
    PREFLIGHT_TBL_PASS=$'\033[32m'
    PREFLIGHT_TBL_WARN=$'\033[33m'
    PREFLIGHT_TBL_FAIL=$'\033[31m'
  fi
}

graph_preflight_table_repeat() {
  local ch="$1" count="$2" out="" i
  for ((i = 0; i < count; i++)); do
    out+="$ch"
  done
  printf '%s' "$out"
}

graph_preflight_table_status_color() {
  case "$1" in
    pass) printf '%s' "$PREFLIGHT_TBL_PASS" ;;
    warn) printf '%s' "$PREFLIGHT_TBL_WARN" ;;
    fail) printf '%s' "$PREFLIGHT_TBL_FAIL" ;;
    *) printf '%s' "" ;;
  esac
}

# graph_preflight_table_next_chunk <text> <max-len>
# Sets PREFLIGHT_TBL_CHUNK and PREFLIGHT_TBL_WRAP_REST (no subshell-safe stdout).
graph_preflight_table_next_chunk() {
  local text="$1" max="$2" chunk="" break_at
  PREFLIGHT_TBL_CHUNK=""
  PREFLIGHT_TBL_WRAP_REST=""
  [[ -n "$text" ]] || return 0
  if ((${#text} <= max)); then
    PREFLIGHT_TBL_CHUNK="$text"
    return 0
  fi
  chunk="${text:0:max}"
  if [[ "$chunk" == *"; "* ]]; then
    break_at="${chunk%%; *}"
    if ((${#break_at} > 12)); then
      PREFLIGHT_TBL_CHUNK="$break_at"
      PREFLIGHT_TBL_WRAP_REST="${text:${#break_at}}"
      PREFLIGHT_TBL_WRAP_REST="${PREFLIGHT_TBL_WRAP_REST#; }"
      return 0
    fi
  fi
  if [[ "$chunk" == *"/"* ]]; then
    break_at="${chunk%/*}"
    if ((${#break_at} > 8)); then
      PREFLIGHT_TBL_CHUNK="$break_at/"
      PREFLIGHT_TBL_WRAP_REST="${text:${#break_at}}"
      PREFLIGHT_TBL_WRAP_REST="${PREFLIGHT_TBL_WRAP_REST#/}"
      return 0
    fi
  fi
  if [[ "$chunk" == *" "* ]]; then
    break_at="${chunk% *}"
    if ((${#break_at} > 8)); then
      PREFLIGHT_TBL_CHUNK="$break_at"
      PREFLIGHT_TBL_WRAP_REST="${text:${#break_at}}"
      PREFLIGHT_TBL_WRAP_REST="${PREFLIGHT_TBL_WRAP_REST# }"
      return 0
    fi
  fi
  PREFLIGHT_TBL_CHUNK="$chunk"
  PREFLIGHT_TBL_WRAP_REST="${text:max}"
}

graph_preflight_table_rule() {
  local c_w="$1" s_w="$2" d_w="$3"
  printf '  +%s+%s+%s+\n' \
    "$(graph_preflight_table_repeat '-' "$((c_w + 2))")" \
    "$(graph_preflight_table_repeat '-' "$((s_w + 2))")" \
    "$(graph_preflight_table_repeat '-' "$((d_w + 2))")"
}

graph_preflight_table_print_row() {
  local c_w="$1" s_w="$2" d_w="$3" check="$4" internal_status="$5" display_status="$6" detail="$7"
  local rest chunk sc evidence fix=""
  [[ -n "$display_status" ]] || display_status="$internal_status"
  if [[ "$detail" == *" | fix: "* ]]; then
    evidence="${detail%% | fix: *}"
    fix="${detail#* | fix: }"
  else
    evidence="$detail"
  fi
  rest="$evidence"
  while :; do
    graph_preflight_table_next_chunk "$rest" "$d_w"
    chunk="$PREFLIGHT_TBL_CHUNK"
    rest="${PREFLIGHT_TBL_WRAP_REST:-}"
    if [[ -n "$check" || -n "$internal_status" ]]; then
      sc="$(graph_preflight_table_status_color "$internal_status")"
      printf '  | %-*s | %s%-*s%s | %-*s |\n' \
        "$c_w" "$check" "$sc" "$s_w" "$display_status" "$PREFLIGHT_TBL_RST" "$d_w" "$chunk"
      check=""
      internal_status=""
      display_status=""
    else
      printf '  | %-*s | %-*s | %-*s |\n' "$c_w" "" "$s_w" "" "$d_w" "$chunk"
    fi
    [[ -n "$rest" ]] || break
  done
  if [[ -n "$fix" ]]; then
    rest="fix: $fix"
    while :; do
      graph_preflight_table_next_chunk "$rest" "$d_w"
      chunk="$PREFLIGHT_TBL_CHUNK"
      rest="${PREFLIGHT_TBL_WRAP_REST:-}"
      printf '  | %-*s | %-*s | %-*s |\n' "$c_w" "" "$s_w" "" "$d_w" "$chunk"
      [[ -n "$rest" ]] || break
    done
  fi
}

graph_preflight_table_section() {
  local json="$1" section="$2" title="$3" c_w="$4" s_w="$5" d_w="$6"
  local rows row check internal_status display_status detail count=0
  local col_check="Check"

  if [[ "$section" == "runtime" ]]; then
    col_check="Runtime"
    rows="$(jq -c '
      def runtime_label($r):
        if $r == "claude" then "Claude (Anthropic)"
        elif $r == "codex" then "Codex (OpenAI)"
        elif $r == "antigravity" then "Antigravity (Google)"
        elif $r == "cursor" then "Cursor Agent"
        elif $r == "opencode" then "OpenCode"
        else $r end;
      def runtime_order($r):
        (["claude","codex","antigravity","cursor","opencode"] | index($r)) // 99;
      [.findings[]
        | select((.id | startswith("runtime:")) and (.id | endswith(":auth") | not))
        | .runtime as $r
        | {
            check: runtime_label($r),
            status: .status,
            statusLabel: (
              if .status == "pass" then "Connected"
              elif (.evidence // "") == "CLI not found on PATH" then "Not installed"
              else "Not connected" end
            ),
            detail: (
              (.evidence // .summary // "") as $e
              | (.repair // "") as $r
              | if $r == "" then $e
                elif $e == "" then ("fix: " + $r)
                else ($e + " | fix: " + $r)
                end
            ),
            sortKey: runtime_order($r)
          }
      ]
      | sort_by(.sortKey)
    ' <<<"$json")"
  else
    rows="$(jq -c --arg sec "$section" '
      [.findings[]
        | select(
            if $sec == "host" then .id != "dashboard" and (.id | startswith("host:"))
            elif $sec == "dashboard" then .id == "dashboard"
            else (.id != "dashboard" and (.id | startswith("host:") | not) and (.id | startswith("runtime:") | not))
            end
          )
        | {
            check: .id,
            status: .status,
            statusLabel: .status,
            detail: (
              (.evidence // .summary // "") as $e
              | (.repair // "") as $r
              | if $r == "" then $e
                elif $e == "" then ("fix: " + $r)
                else ($e + " | fix: " + $r)
                end
            )
          }
      ]
    ' <<<"$json")"
  fi

  count="$(jq 'length' <<<"$rows")"
  [[ "$count" -gt 0 ]] || return 0

  printf '\n  %s%s%s\n' "$PREFLIGHT_TBL_CYAN$PREFLIGHT_TBL_BOLD" "$title" "$PREFLIGHT_TBL_RST"
  graph_preflight_table_rule "$c_w" "$s_w" "$d_w"
  printf '  | %-*s | %-*s | %-*s |\n' "$c_w" "$col_check" "$s_w" "Status" "$d_w" "Details"
  graph_preflight_table_rule "$c_w" "$s_w" "$d_w"

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    check="$(jq -r '.check' <<<"$row")"
    internal_status="$(jq -r '.status' <<<"$row")"
    display_status="$(jq -r '.statusLabel' <<<"$row")"
    detail="$(jq -r '.detail' <<<"$row")"
    graph_preflight_table_print_row "$c_w" "$s_w" "$d_w" "$check" "$internal_status" "$display_status" "$detail"
  done < <(jq -c '.[]' <<<"$rows")

  graph_preflight_table_rule "$c_w" "$s_w" "$d_w"
}

# graph_preflight_format_table <report-json>
# Grouped bordered readiness tables with a short summary line.
graph_preflight_format_table() {
  local json="${1:-}" term_w c_w s_w d_w pass warn fail outcome
  local max_id rid rt label_len

  term_w="${COLUMNS:-80}"
  if [[ "$term_w" -lt 72 ]]; then
    term_w=72
  elif [[ "$term_w" -gt 132 ]]; then
    term_w=132
  fi

  graph_preflight_table_style_init

  if ! jq -e 'type == "object" and (.findings | type == "array")' <<<"$json" >/dev/null 2>&1; then
    printf '%s\n' "$json"
    return 0
  fi

  pass="$(jq '[.findings[] | select(.status == "pass")] | length' <<<"$json")"
  warn="$(jq '[.findings[] | select(.status == "warn")] | length' <<<"$json")"
  fail="$(jq '[.findings[] | select(.status == "fail")] | length' <<<"$json")"
  outcome="$(jq -r '.outcome // "pass"' <<<"$json")"
  max_id="$(jq -r '[.findings[].id] | max_by(length) | length' <<<"$json")"
  c_w="$max_id"
  while IFS= read -r rid; do
    [[ "$rid" == runtime:* ]] || continue
    rt="${rid#runtime:}"
    rt="${rt%%:auth}"
    label_len="$(graph_preflight_runtime_label "$rt" | wc -c | tr -d ' ')"
    label_len=$((label_len - 1))
    ((label_len > c_w)) && c_w="$label_len"
  done < <(jq -r '.findings[].id' <<<"$json")

  ((c_w < 10)) && c_w=10
  ((c_w > 24)) && c_w=24
  s_w=14
  d_w=$((term_w - c_w - s_w - 11))
  ((d_w < 28)) && d_w=28

  printf '\n'
  printf '  %sSummary:%s  ' "$PREFLIGHT_TBL_BOLD" "$PREFLIGHT_TBL_RST"
  printf '%s%d passed%s' "$PREFLIGHT_TBL_PASS" "$pass" "$PREFLIGHT_TBL_RST"
  if [[ "$warn" -gt 0 ]]; then
    printf ', %s%d warnings%s' "$PREFLIGHT_TBL_WARN" "$warn" "$PREFLIGHT_TBL_RST"
  fi
  if [[ "$fail" -gt 0 ]]; then
    printf ', %s%d failed%s' "$PREFLIGHT_TBL_FAIL" "$fail" "$PREFLIGHT_TBL_RST"
  fi
  printf '\n  %sOverall:%s  ' "$PREFLIGHT_TBL_DIM" "$PREFLIGHT_TBL_RST"
  case "$outcome" in
    pass)
      printf '%sready%s\n' "$PREFLIGHT_TBL_PASS" "$PREFLIGHT_TBL_RST"
      ;;
    warn)
      printf '%sready with warnings%s' "$PREFLIGHT_TBL_WARN" "$PREFLIGHT_TBL_RST"
      printf ' %s(soft checks only; exit 0)%s\n' "$PREFLIGHT_TBL_DIM" "$PREFLIGHT_TBL_RST"
      ;;
    fail)
      printf '%snot ready%s\n' "$PREFLIGHT_TBL_FAIL" "$PREFLIGHT_TBL_RST"
      ;;
    *)
      printf '%s\n' "$outcome"
      ;;
  esac

  graph_preflight_table_section "$json" host "Host environment" "$c_w" "$s_w" "$d_w"
  graph_preflight_table_section "$json" dashboard "Dashboard" "$c_w" "$s_w" "$d_w"
  graph_preflight_table_section "$json" runtime "Runtimes" "$c_w" "$s_w" "$d_w"
  graph_preflight_table_section "$json" other "Other checks" "$c_w" "$s_w" "$d_w"
  printf '\n'
}
