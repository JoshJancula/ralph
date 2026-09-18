#!/usr/bin/env bash
# Public CLI for read-only host/runtime environment preflight (ralph doctor).
#
# Hard prerequisite failures (command errors): missing supported Bash, or jq.
# Absent optional tools and unavailable runtime CLIs are reportable table
# conditions only — they must not make this command exit non-zero.
#
# Never mutates workspace, ledger, killswitch, install state, or ambient
# runtime config. Probe helpers are list/status/help only.
set -euo pipefail

_doctor_cli_dir="${BASH_SOURCE[0]%/*}"
[[ "$_doctor_cli_dir" == "${BASH_SOURCE[0]}" ]] && _doctor_cli_dir="."
# shellcheck source=../help-render.sh
source "$_doctor_cli_dir/../help-render.sh"
# shellcheck source=./preflight-host.sh
source "$_doctor_cli_dir/preflight-host.sh"
# shellcheck source=../dashboard/status-cli.sh
source "$_doctor_cli_dir/../dashboard/status-cli.sh"

RALPH_HOME="${RALPH_HOME:-${HOME:-}/.ralph}"
DOCTOR_CLI_SCHEMA_VERSION=1

doctor_cli_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph doctor [options]

Read-only host and runtime environment preflight. Prints one readiness table
and exits without writing Ralph state, configs, or install artifacts.

Hard prerequisites (command errors when missing):
  Bash 3.2+ capability
  jq

Optional tools and runtime CLIs (cursor, claude, codex, opencode, antigravity)
appear as table rows when absent or unauthenticated; they do not fail the
command.

Options:
  -h, --help   Show this help

Examples:
  ralph doctor
USAGE
}

# doctor_cli_require_bash
# Fail closed when the interpreter is not a supported Bash.
doctor_cli_require_bash() {
  local major minor
  if [[ -z "${BASH_VERSINFO[0]:-}" ]]; then
    echo "Error: ralph doctor requires Bash 3.2 or newer." >&2
    return 1
  fi
  major="${BASH_VERSINFO[0]}"
  minor="${BASH_VERSINFO[1]:-0}"
  if [[ "$major" -lt 3 ]] || { [[ "$major" -eq 3 ]] && [[ "$minor" -lt 2 ]]; }; then
    echo "Error: ralph doctor requires Bash 3.2 or newer (found ${BASH_VERSION:-unknown})." >&2
    return 1
  fi
  return 0
}

# doctor_cli_require_jq
# Hard gate before any jq-backed report rendering.
doctor_cli_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: ralph doctor requires jq." >&2
    return 1
  fi
  if ! graph_preflight_cmd_available jq; then
    echo "Error: ralph doctor requires jq." >&2
    return 1
  fi
  return 0
}

# doctor_cli_tool_version <cmd>
# Best-effort first-line --version text; falls back to "present".
doctor_cli_tool_version() {
  local cmd="$1" out
  out="$("$cmd" --version 2>/dev/null | head -n 1)" || true
  out="${out#"${out%%[![:space:]]*}"}"
  out="${out%"${out##*[![:space:]]}"}"
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"
  else
    printf 'present\n'
  fi
}

# doctor_cli_append_optional_cmd <findings> <id> <cmd>
# Soft presence/version row. Missing optional tools are warn, never hard fail.
doctor_cli_append_optional_cmd() {
  local findings="$1" id="$2" cmd="$3"
  local path ver

  if command -v "$cmd" >/dev/null 2>&1 && graph_preflight_cmd_available "$cmd"; then
    path="$(command -v "$cmd")"
    ver="$(doctor_cli_tool_version "$cmd")"
    graph_preflight_append "$findings" "$id" host pass \
      "${cmd} is available" \
      "${cmd}=${ver}; path=${path}" ""
  else
    graph_preflight_append "$findings" "$id" host warn \
      "${cmd} is not available" \
      "${cmd} missing" \
      "install ${cmd} if you need this optional capability"
  fi
}

# doctor_cli_append_hash_tool <findings>
# One row for sha256sum or shasum (either satisfies the optional hash probe).
doctor_cli_append_hash_tool() {
  local findings="$1"
  local path ver

  if command -v sha256sum >/dev/null 2>&1 && graph_preflight_cmd_available sha256sum; then
    path="$(command -v sha256sum)"
    ver="$(doctor_cli_tool_version sha256sum)"
    graph_preflight_append "$findings" "host:sha256" host pass \
      "sha256sum is available" \
      "sha256sum=${ver}; path=${path}" ""
  elif command -v shasum >/dev/null 2>&1 && graph_preflight_cmd_available shasum; then
    path="$(command -v shasum)"
    ver="$(doctor_cli_tool_version shasum)"
    graph_preflight_append "$findings" "host:sha256" host pass \
      "shasum is available" \
      "shasum=${ver}; path=${path}" ""
  else
    graph_preflight_append "$findings" "host:sha256" host warn \
      "neither sha256sum nor shasum is available" \
      "sha256sum/shasum missing" \
      "install sha256sum or shasum if you need checksum probes"
  fi
}

# doctor_cli_append_runtime <findings> <normalized-runtime>
# CLI resolution plus existing auth-probe behavior (list/status only).
doctor_cli_append_runtime() {
  local findings="$1" runtime="$2"
  local cli auth_out probe_rc

  cli="$(graph_preflight_resolve_cli "$runtime")"
  if ! graph_preflight_cli_exists "$cli"; then
    graph_preflight_append "$findings" "runtime:${runtime}" runtime fail \
      "runtime CLI is not available" \
      "cli=${cli:-none}" \
      "install the ${runtime} CLI or set the runtime CLI override" "" "$runtime"
    return 0
  fi

  if graph_preflight_auth_argv "$runtime" >/dev/null; then
    auth_out=""
    probe_rc=0
    auth_out="$(graph_preflight_auth_argv "$runtime" | graph_preflight_run_probe "$cli")" || probe_rc=$?
    if [[ "$probe_rc" -ne 0 ]] || graph_preflight_auth_indicates_missing "$auth_out"; then
      graph_preflight_append "$findings" "runtime:${runtime}" runtime fail \
        "runtime authentication is missing" \
        "cli=$cli exit=$probe_rc" \
        "log in to ${runtime} with its documented auth command" "" "$runtime"
      return 0
    fi
    graph_preflight_append "$findings" "runtime:${runtime}" runtime pass \
      "runtime CLI is present and authenticated" \
      "cli=$cli" "" "" "$runtime"
    return 0
  fi

  graph_preflight_append "$findings" "runtime:${runtime}:auth" runtime warn \
    "runtime has no non-billable auth status command" \
    "cli=$cli authProbe=unsupported" \
    "confirm ${runtime} auth before runs" "" "$runtime"
  graph_preflight_append "$findings" "runtime:${runtime}" runtime pass \
    "runtime CLI is present" \
    "cli=$cli" "" "" "$runtime"
}

doctor_cli_append_dashboard() {
  local findings="$1" status_json status_rc=0
  status_json="$(dashboard_status_json)" || status_rc=$?
  if [[ "$(jq -r '.running' <<<"$status_json")" == "true" ]]; then
    graph_preflight_append "$findings" "dashboard" host pass \
      "dashboard is running" \
      "host=$(jq -r '.host' <<<"$status_json"); port=$(jq -r '.port' <<<"$status_json"); pid=$(jq -r '.pid' <<<"$status_json")" ""
  else
    graph_preflight_append "$findings" "dashboard" host warn \
      "dashboard is not running" \
      "endpoint=$(jq -r '.endpoint' <<<"$status_json")" \
      "start it with ralph dashboard"
  fi
}

# doctor_cli_build_findings <findings-jsonl-path>
# Emit one readiness table's findings: hard host rows, optional tools, and
# runtime CLI/auth probes. Soft conditions stay table-only (exit zero).
doctor_cli_build_findings() {
  local findings="$1"
  local bash_ver="${BASH_VERSION:-unknown}"
  local jq_ver jq_path runtime

  graph_preflight_append "$findings" "host:bash" host pass \
    "supported Bash capability is available" \
    "bash=$bash_ver" ""

  jq_path="$(command -v jq)"
  jq_ver="$(doctor_cli_tool_version jq)"
  graph_preflight_append "$findings" "host:jq" host pass \
    "jq is available" \
    "jq=${jq_ver}; path=${jq_path}" ""

  doctor_cli_append_optional_cmd "$findings" "host:python3" python3
  doctor_cli_append_optional_cmd "$findings" "host:rg" rg
  doctor_cli_append_optional_cmd "$findings" "host:ctags" ctags
  doctor_cli_append_optional_cmd "$findings" "host:timeout" timeout
  doctor_cli_append_optional_cmd "$findings" "host:flock" flock
  doctor_cli_append_optional_cmd "$findings" "host:setsid" setsid
  doctor_cli_append_hash_tool "$findings"
  doctor_cli_append_dashboard "$findings"

  for runtime in cursor claude codex opencode antigravity; do
    doctor_cli_append_runtime "$findings" "$runtime"
  done
}

# doctor_cli_render
# Build the report JSON, print the shared table, always exit 0 after hard
# gates have already passed (soft findings never fail the command).
doctor_cli_render() {
  local findings findings_json report outcome
  findings="$(mktemp "${TMPDIR:-/tmp}/ralph-doctor.XXXXXX")" || return 1

  : >"$findings"
  doctor_cli_build_findings "$findings"

  outcome="$(graph_preflight_worst "$findings")"
  if [[ -s "$findings" ]]; then
    findings_json="$(jq -s '.' "$findings")"
  else
    findings_json='[]'
  fi
  rm -f "$findings"

  report="$(jq -nc \
    --argjson schema "$DOCTOR_CLI_SCHEMA_VERSION" \
    --arg outcome "$outcome" \
    --argjson findings "$findings_json" \
    '{
      schemaVersion: $schema,
      readOnly: true,
      outcome: $outcome,
      findings: $findings
    }')"

  printf 'Ralph doctor (read-only)\n'
  graph_preflight_format_table "$report"
  return 0
}

doctor_cli_main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help|help)
        doctor_cli_usage
        return 0
        ;;
      *)
        echo "Error: unknown argument for ralph doctor: $arg" >&2
        doctor_cli_usage >&2
        return 2
        ;;
    esac
  done

  doctor_cli_require_bash || return 1
  doctor_cli_require_jq || return 1
  doctor_cli_render
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  doctor_cli_main "$@"
fi
