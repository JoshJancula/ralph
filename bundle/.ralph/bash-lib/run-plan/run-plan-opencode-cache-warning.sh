#!/usr/bin/env bash
# OpenCode provider/cache warnings from observed invocation usage metrics.
# Source from run-plan-core.sh; do not execute directly.

if [[ -n "${RALPH_OPENCODE_CACHE_WARNING_LOADED:-}" ]]; then
  return
fi
RALPH_OPENCODE_CACHE_WARNING_LOADED=1

ralph_opencode_cache_warn_enabled() {
  case "${RALPH_OPENCODE_CACHE_WARN:-1}" in
    0|false|no|off) return 1 ;;
  esac
  return 0
}

ralph_opencode_cache_warn_min_invocations() {
  local min="${RALPH_OPENCODE_CACHE_WARN_MIN_INVOCATIONS:-2}"
  if [[ ! "$min" =~ ^[0-9]+$ ]] || [[ "$min" -lt 1 ]]; then
    min=2
  fi
  printf '%s' "$min"
}

ralph_opencode_cache_warn_min_avg_input() {
  local min="${RALPH_OPENCODE_CACHE_WARN_MIN_AVG_INPUT:-8000}"
  if [[ ! "$min" =~ ^[0-9]+$ ]]; then
    min=8000
  fi
  printf '%s' "$min"
}

ralph_opencode_cache_warn_action() {
  local action="${RALPH_OPENCODE_CACHE_WARN_ACTION:-warn}"
  case "$action" in
    warn|stop)
      printf '%s' "$action"
      return 0
      ;;
  esac
  printf 'warn'
  return 0
}

ralph_opencode_cache_warning_yesno() {
  case "$1" in
    1|true|yes|on)
      printf 'yes'
      ;;
    *)
      printf 'no'
      ;;
  esac
}

# Exit 0 when usage history indicates the provider/model may not support caching.
ralph_opencode_cache_warning_should_warn() {
  local usage_file="${1:-}"
  if [[ -z "$usage_file" || ! -f "$usage_file" ]]; then
    return 1
  fi
  if ! command -v python3 &>/dev/null; then
    return 1
  fi
  local script_dir helper_py
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  helper_py="$script_dir/../../python/opencode_cache_estimate.py"

  RALPH_OPENCODE_CACHE_ESTIMATE_HELPER_PATH="$helper_py" \
    python3 - "$usage_file" <<'PY'
import json
import os
import sys

usage_file = sys.argv[1]
min_invocations = int(os.environ.get("RALPH_OPENCODE_CACHE_WARN_MIN_INVOCATIONS", "2"))
min_avg_input = int(os.environ.get("RALPH_OPENCODE_CACHE_WARN_MIN_AVG_INPUT", "8000"))
if min_invocations < 1:
    min_invocations = 2
if min_avg_input < 0:
    min_avg_input = 8000

with open(usage_file, "r", encoding="utf-8") as fh:
    doc = json.load(fh)

invocations = doc.get("invocations") if isinstance(doc, dict) else []
if not isinstance(invocations, list):
    sys.exit(1)

opencode = [item for item in invocations if isinstance(item, dict) and item.get("runtime") == "opencode"]
if len(opencode) < min_invocations:
    sys.exit(1)

total_cache_read = sum(int(item.get("cache_read_input_tokens") or 0) for item in opencode)
total_cache_creation = sum(int(item.get("cache_creation_input_tokens") or 0) for item in opencode)
if total_cache_read > 0:
    sys.exit(1)

total_input = sum(int(item.get("input_tokens") or 0) for item in opencode)
avg_input = total_input // len(opencode) if opencode else 0
if avg_input < min_avg_input:
    sys.exit(1)

cache_fields_known = False
cache_fields_detected = False
for item in opencode:
    if "opencode_cache_fields_seen" in item:
        cache_fields_known = True
        if bool(item.get("opencode_cache_fields_seen")):
            cache_fields_detected = True

if cache_fields_known:
    cache_fields_status = 1 if cache_fields_detected else 0
else:
    cache_fields_status = -1

estimated_cache_read = 0
try:
    helper_path = os.environ.get("RALPH_OPENCODE_CACHE_ESTIMATE_HELPER_PATH")
    if helper_path and os.path.isfile(helper_path):
        helper_dir = os.path.dirname(helper_path)
        if helper_dir not in sys.path:
            sys.path.insert(0, helper_dir)
        from opencode_cache_estimate import estimate_opencode_cache_read

        est = estimate_opencode_cache_read(invocations)
        estimated_cache_read = int(est.get("estimated") or 0)
except Exception:
    estimated_cache_read = 0

print(len(opencode))
print(avg_input)
print(cache_fields_status)
print(total_cache_read)
print(total_cache_creation)
print(estimated_cache_read)
PY
}

ralph_opencode_cache_warning_message() {
  local reason="$1"
  local model="${2:-unknown}"
  local invocation_count="${3:-0}"
  local avg_input="${4:-0}"
  local config_source="${5:-unknown}"
  local ambient_cache="${6:-0}"
  local final_cache="${7:-0}"
  local cache_fields_status="${8:--1}"
  local cache_read="${9:-0}"
  local cache_creation="${10:-0}"
  local cache_read_estimated="${11:-0}"

  local reason_text
  local prefix="Warning:"
  case "$reason" in
    cache-enabled-not-reported)
      prefix="Note:"
      reason_text="OpenCode emitted no tokens.cache fields for provider/model ($model); Ollama Cloud does not yet report cached-token counts."
      ;;
    cache-estimated-unreported)
      prefix="Note:"
      reason_text="OpenCode emitted no tokens.cache fields for provider/model ($model); Ollama Cloud does not yet report cached-token counts, but Ralph best-guess indicates about ${cache_read_estimated} cached-token input tokens read (prefix-stability)."
      ;;
    stream-cache-missing)
      reason_text="OpenCode emitted no tokens.cache fields for provider/model ($model); the tokens.cache diagnostics were absent from the stream."
      ;;
    config-cache-dropped)
      reason_text="Cache-capable provider/model ($model) was configured but Ralph-generated OPENCODE_CONFIG appears to have dropped cache settings."
      ;;
    *)
      reason_text="Provider/model ($model) may not support caching or explicitly omits cache diagnostics."
      ;;
  esac
  local ambient_text
  ambient_text="$(ralph_opencode_cache_warning_yesno "$ambient_cache")"
  local final_text
  final_text="$(ralph_opencode_cache_warning_yesno "$final_cache")"
  local cache_fields_text="unknown"
  case "$cache_fields_status" in
    1) cache_fields_text="yes" ;;
    0) cache_fields_text="no" ;;
  esac
  printf '%s OpenCode cache diagnostics triggered after %s invocations with large input (avg=%s tokens). %s Selected model: %s; Config source: %s; Cache settings detected (ambient=%s final=%s); tokens.cache fields observed=%s; tokens.cache read tokens=%s write tokens=%s. Ralph will not switch providers automatically.' \
    "$prefix" "$invocation_count" "$avg_input" "$reason_text" "$model" "$config_source" "$ambient_text" "$final_text" "$cache_fields_text" "$cache_read" "$cache_creation"
}

# Log at most once per plan run when usage metrics indicate missing cache support.
# Exit 0 if warning triggered and action is warn (continue).
# Exit 1 if warning triggered and action is stop (hard stop requested).
# Exit 0 if warning did not trigger (continue).
ralph_opencode_cache_warning_truthy() {
  case "$1" in
    1|true|yes|on)
      return 0
      ;;
  esac
  return 1
}

ralph_opencode_cache_warning_maybe_emit() {
  local usage_file="${1:-}"
  local model="${2:-}"
  local config_source="${3:-unknown}"
  local ambient_cache_settings="${4:-0}"
  local final_cache_settings="${5:-0}"
  if [[ "${_ralph_opencode_cache_warn_emitted:-0}" == "1" ]]; then
    return 0
  fi
  if ! ralph_opencode_cache_warn_enabled; then
    return 0
  fi
  local stats
  if ! stats="$(ralph_opencode_cache_warning_should_warn "$usage_file")"; then
    return 0
  fi
  local invocation_count avg_input cache_fields_status cache_read_total cache_creation_total cache_read_estimated_total action reason message
  local -a stats_lines=()
  mapfile -t stats_lines <<<"$stats"
  invocation_count="${stats_lines[0]:-0}"
  avg_input="${stats_lines[1]:-0}"
  cache_fields_status="${stats_lines[2]:--1}"
  cache_read_total="${stats_lines[3]:-0}"
  cache_creation_total="${stats_lines[4]:-0}"
  cache_read_estimated_total="${stats_lines[5]:-0}"
  local ambient_cache_bool=0
  if ralph_opencode_cache_warning_truthy "${ambient_cache_settings:-0}"; then
    ambient_cache_bool=1
  fi
  local final_cache_bool=0
  if ralph_opencode_cache_warning_truthy "${final_cache_settings:-0}"; then
    final_cache_bool=1
  fi
  if [[ "$final_cache_bool" -eq 0 ]]; then
    if ralph_opencode_cache_warning_truthy "${RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED:-0}"; then
      final_cache_bool=1
    fi
  fi
  if [[ "$final_cache_bool" -eq 0 ]]; then
    if ralph_opencode_cache_warning_truthy "${RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS:-0}"; then
      final_cache_bool=1
    fi
  fi
  local cache_settings_present="$final_cache_bool"
  if [[ "$cache_settings_present" -eq 0 ]]; then
    if ralph_opencode_cache_warning_truthy "${RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED:-0}" \
      || ralph_opencode_cache_warning_truthy "${RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS:-0}"; then
      cache_settings_present=1
    fi
  fi
  local is_note=0
  if [[ "$cache_settings_present" -eq 1 && "$cache_fields_status" != "1" && "${cache_read_estimated_total:-0}" -gt 0 ]]; then
    reason="cache-estimated-unreported"
    is_note=1
  elif [[ "$cache_settings_present" -eq 1 && "$cache_fields_status" != "1" ]]; then
    reason="cache-enabled-not-reported"
    is_note=1
  elif [[ "$ambient_cache_bool" -eq 1 && "$cache_settings_present" -eq 0 ]]; then
    reason="config-cache-dropped"
  elif [[ "$cache_fields_status" == "0" ]]; then
    reason="provider-no-cache"
  else
    reason="provider-no-cache"
  fi
  message="$(
    ralph_opencode_cache_warning_message \
    "$reason" \
      "${model:-unknown}" \
      "$invocation_count" \
      "$avg_input" \
      "${config_source:-unknown}" \
      "$ambient_cache_bool" \
      "$final_cache_bool" \
      "$cache_fields_status" \
      "$cache_read_total" \
      "$cache_creation_total" \
      "$cache_read_estimated_total"
  )"
  echo "$message" >&2
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    local log_action="warning"
    if [[ "$is_note" -eq 1 ]]; then
      log_action="note"
    else
      log_action="$(ralph_opencode_cache_warn_action)"
    fi
    ralph_run_plan_log "opencode cache warning: reason=${reason} model=${model:-unknown} config_source=${config_source:-unknown} ambient_cache=${ambient_cache_settings:-0} final_cache=${final_cache_settings:-0} cache_fields_status=${cache_fields_status:-unknown} cache_read=${cache_read_total} cache_create=${cache_creation_total} action=${log_action}"
  fi
  _ralph_opencode_cache_warn_emitted=1
  if [[ "$is_note" -eq 1 ]]; then
    return 0
  fi
  action="$(ralph_opencode_cache_warn_action)"
  if [[ "$action" == "stop" ]]; then
    return 1
  fi
  return 0
}
