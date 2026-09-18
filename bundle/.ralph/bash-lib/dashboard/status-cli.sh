#!/usr/bin/env bash

# Shared dashboard endpoint status source for `ralph dashboard status` and doctor.

dashboard_status_endpoint_path() {
  local config_home="${XDG_CONFIG_HOME:-}"
  if [[ -z "$config_home" ]]; then
    config_home="${HOME:-}/.config"
  fi
  printf '%s\n' "${config_home%/}/ralph/dashboard/endpoint.json"
}

dashboard_status_epoch() {
  local timestamp="$1" epoch timestamp_base
  timestamp_base="${timestamp%%.*}Z"
  if epoch="$(date -u -d "$timestamp_base" +%s 2>/dev/null)" && [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi
  if epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp_base" +%s 2>/dev/null)" && [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi
  return 1
}

dashboard_status_json() {
  local endpoint_path="$(dashboard_status_endpoint_path)"
  local raw host port pid started_at now started_epoch uptime

  if [[ ! -f "$endpoint_path" ]] || ! raw="$(cat "$endpoint_path" 2>/dev/null)" || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw"; then
    jq -nc --arg endpoint "$endpoint_path" '{running: false, endpoint: $endpoint, reason: "missing-or-invalid"}'
    return 1
  fi

  host="$(jq -r '.host // empty' <<<"$raw")"
  port="$(jq -r '.port // empty' <<<"$raw")"
  pid="$(jq -r '.pid // empty' <<<"$raw")"
  started_at="$(jq -r '.startedAt // empty' <<<"$raw")"
  if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ "$pid" -le 0 ]] || ! kill -0 "$pid" 2>/dev/null; then
    jq -nc --arg endpoint "$endpoint_path" --arg host "$host" --arg port "$port" --arg pid "$pid" --arg startedAt "$started_at" \
      '{running: false, endpoint: $endpoint, host: $host, port: ($port | tonumber? // null), pid: ($pid | tonumber? // null), startedAt: ($startedAt | if . == "" then null else . end), reason: "not-running"}'
    return 1
  fi

  now="$(date +%s)"
  uptime=""
  if started_epoch="$(dashboard_status_epoch "$started_at")"; then
    uptime=$((now - started_epoch))
    (( uptime < 0 )) && uptime=0
  fi
  jq -nc --arg endpoint "$endpoint_path" --arg host "$host" --arg port "$port" --arg pid "$pid" --arg startedAt "$started_at" --arg uptime "$uptime" \
    '{running: true, endpoint: $endpoint, host: $host, port: ($port | tonumber? // null), pid: ($pid | tonumber? // null), startedAt: $startedAt, uptimeSeconds: ($uptime | tonumber? // null)}'
  return 0
}

dashboard_status_human() {
  local status_json="$1"
  if [[ "$(jq -r '.running' <<<"$status_json")" != "true" ]]; then
    printf 'Dashboard: not running\n'
    return 1
  fi
  printf 'Dashboard: running\n'
  printf '  Host: %s\n' "$(jq -r '.host // "unknown"' <<<"$status_json")"
  printf '  Port: %s\n' "$(jq -r '.port // "unknown"' <<<"$status_json")"
  printf '  PID: %s\n' "$(jq -r '.pid // "unknown"' <<<"$status_json")"
  printf '  Uptime: %ss\n' "$(jq -r '.uptimeSeconds // "unknown"' <<<"$status_json")"
  return 0
}

dashboard_status_cli() {
  local json=0 arg status_json status_rc
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      -h|--help|help)
        printf 'Usage: ralph dashboard status [--json]\n'
        return 0
        ;;
      *)
        echo "Error: unknown argument for ralph dashboard status: $arg" >&2
        return 2
        ;;
    esac
  done

  status_json="$(dashboard_status_json)" || status_rc=$?
  status_rc="${status_rc:-0}"
  if [[ "$json" -eq 1 ]]; then
    printf '%s\n' "$status_json"
  else
    dashboard_status_human "$status_json" || true
  fi
  return "$status_rc"
}
