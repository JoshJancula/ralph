#!/usr/bin/env bash
# GENERATED from bundle/.ralph/plugin-inputs/shared/ralph-plugin-bootstrap.sh by scripts/sync-plugin-assets.sh - edit the canonical file
set -euo pipefail

# Shared plugin bootstrap.
# probe is read-only compatibility detection (P05 + P07 probe half).
# ensure is the P07 mutating half: consented repository install.sh --global only.

EXPECTED_PLUGIN_API=1
RALPH_COMMAND_NAME="ralph"
REQUIRED_VERBS=(run create workflow)
ENSURE_MODE=0
INSTALL_COMMAND=""
INSTALL_DESTINATION=""
INSTALL_CONSENT="not-offered"
INSTALL_RAN=0
PLAN_EXECUTED=0

usage() {
  cat <<'USAGE'
Usage: ralph-plugin-bootstrap.sh probe [--json]
       ralph-plugin-bootstrap.sh ensure [--yes] [--json]
USAGE
}

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_string_array() {
  local first=1 v
  printf '['
  for v in "$@"; do
    if [[ "$first" -eq 1 ]]; then
      first=0
    else
      printf ','
    fi
    printf '"%s"' "$(json_escape "$v")"
  done
  printf ']'
}

is_integer() {
  [[ "${1-}" =~ ^-?[0-9]+$ ]]
}

trim_ws() {
  local s=${1-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

first_line() {
  local s=${1-}
  printf '%s\n' "$s" | awk 'NR==1 {print; exit}'
}

discover_verbs_from_help() {
  local help_text=${1-}
  printf '%s\n' "$help_text" | awk '
    BEGIN { in_cmds = 0 }
    /^[[:space:]]*Commands:[[:space:]]*$/ { in_cmds = 1; next }
    in_cmds && /^[[:space:]]*Options:[[:space:]]*$/ { exit }
    in_cmds && /^[[:space:]]*$/ { if (seen) exit; next }
    in_cmds && /^[[:space:]]+[A-Za-z0-9][A-Za-z0-9_-]*/ {
      seen = 1
      line = $0
      sub(/^[[:space:]]+/, "", line)
      split(line, parts, /[[:space:]]+/)
      if (parts[1] != "") print parts[1]
    }
  '
}

verb_in_list() {
  local needle=$1
  shift
  local v
  for v in "$@"; do
    if [[ "$v" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

emit_report() {
  local want_json=$1
  local outcome=$2
  local resolved=$3
  local bundle_path=$4
  local api_path=$5
  local api_raw=$6
  local api_json=$7
  local remediation=$8
  shift 8
  local missing_verbs=("$@")

  if [[ "$want_json" -eq 1 ]]; then
    printf '{'
    printf '"bundlePath":"%s",' "$(json_escape "$bundle_path")"
    printf '"command":"%s",' "$(json_escape "$RALPH_COMMAND_NAME")"
    printf '"expectedPluginApi":%s,' "$EXPECTED_PLUGIN_API"
    printf '"missingVerbs":%s,' "$(json_string_array "${missing_verbs[@]+"${missing_verbs[@]}"}")"
    printf '"outcome":"%s",' "$(json_escape "$outcome")"
    if [[ "$api_json" == "null" ]]; then
      printf '"pluginApi":null,'
    else
      printf '"pluginApi":%s,' "$api_json"
    fi
    printf '"pluginApiPath":"%s",' "$(json_escape "$api_path")"
    printf '"pluginApiValue":"%s",' "$(json_escape "$api_raw")"
    printf '"remediation":"%s",' "$(json_escape "$remediation")"
    printf '"requiredVerbs":%s,' "$(json_string_array "${REQUIRED_VERBS[@]}")"
    printf '"resolvedCommand":"%s"' "$(json_escape "$resolved")"
    if [[ "$ENSURE_MODE" -eq 1 ]]; then
      printf ','
      printf '"installCommand":"%s",' "$(json_escape "$INSTALL_COMMAND")"
      printf '"installConsent":"%s",' "$(json_escape "$INSTALL_CONSENT")"
      printf '"installDestination":"%s",' "$(json_escape "$INSTALL_DESTINATION")"
      if [[ "$INSTALL_RAN" -eq 1 ]]; then
        printf '"installRan":true,'
      else
        printf '"installRan":false,'
      fi
      printf '"planExecuted":false'
    fi
    printf '}\n'
  else
    printf 'outcome: %s\n' "$outcome"
    printf 'command: %s\n' "$RALPH_COMMAND_NAME"
    if [[ -n "$resolved" ]]; then
      printf 'resolvedCommand: %s\n' "$resolved"
    fi
    if [[ -n "$bundle_path" ]]; then
      printf 'bundlePath: %s\n' "$bundle_path"
    fi
    if [[ -n "$api_path" ]]; then
      printf 'pluginApiPath: %s\n' "$api_path"
    fi
    if [[ -n "$api_raw" ]]; then
      printf 'pluginApiValue: %s\n' "$api_raw"
    fi
    if [[ "$api_json" != "null" ]]; then
      printf 'pluginApi: %s\n' "$api_json"
    fi
    printf 'expectedPluginApi: %s\n' "$EXPECTED_PLUGIN_API"
    if [[ "$outcome" == "newer" ]]; then
      printf 'warning: installed plugin ABI is newer than expected %s; required verbs were verified from ralph --help\n' \
        "$EXPECTED_PLUGIN_API"
    fi
    if [[ ${#missing_verbs[@]} -gt 0 ]]; then
      printf 'missingVerbs: %s\n' "${missing_verbs[*]}"
    fi
    if [[ -n "$remediation" ]]; then
      printf 'remediation: %s\n' "$remediation"
    fi
    if [[ "$ENSURE_MODE" -eq 1 ]]; then
      printf 'installConsent: %s\n' "$INSTALL_CONSENT"
      if [[ -n "$INSTALL_COMMAND" ]]; then
        printf 'installCommand: %s\n' "$INSTALL_COMMAND"
      fi
      if [[ -n "$INSTALL_DESTINATION" ]]; then
        printf 'installDestination: %s\n' "$INSTALL_DESTINATION"
      fi
      if [[ "$INSTALL_RAN" -eq 1 ]]; then
        printf 'installRan: true\n'
      else
        printf 'installRan: false\n'
      fi
      printf 'planExecuted: false\n'
    fi
  fi
}

continue_exit() {
  case "$1" in
    usable|newer) return 0 ;;
    *) return 1 ;;
  esac
}

stdin_is_pipe() {
  [[ -p /dev/fd/0 || -p /dev/stdin ]]
}

resolve_install_sh() {
  if [[ -n "${RALPH_PLUGIN_INSTALL_SH:-}" ]]; then
    printf '%s\n' "$RALPH_PLUGIN_INSTALL_SH"
    return 0
  fi
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if [[ -f "$dir/install.sh" && -d "$dir/bundle/.ralph" ]]; then
      printf '%s\n' "$dir/install.sh"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

resolve_install_destination() {
  local dest="${RALPH_HOME:-${HOME}/.ralph}"
  local parent base
  parent="$(dirname "$dest")"
  base="$(basename "$dest")"
  if [[ -d "$parent" ]]; then
    (cd "$parent" && printf '%s/%s\n' "$(pwd)" "$base")
  else
    printf '%s\n' "$dest"
  fi
}

format_install_command() {
  local install_sh=$1
  local assume_yes=$2
  if [[ "$assume_yes" -eq 1 ]]; then
    printf 'bash %s --global --yes' "$install_sh"
  else
    printf 'bash %s --global' "$install_sh"
  fi
}

normalize_consent_answer() {
  local raw
  raw="$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')"
  raw="$(trim_ws "$raw")"
  printf '%s' "$raw"
}

read_install_consent() {
  local assume_yes=$1
  local answer=""
  if [[ "$assume_yes" -eq 1 ]]; then
    INSTALL_CONSENT="accepted"
    return 0
  fi
  if stdin_is_pipe || [[ -t 0 && -t 1 ]]; then
    printf 'Install Ralph with the command and destination above? Type yes or no:\n' >&2
    IFS= read -r answer || answer=""
    answer="$(normalize_consent_answer "$answer")"
    case "$answer" in
      yes|y)
        INSTALL_CONSENT="accepted"
        return 0
        ;;
      no|n)
        INSTALL_CONSENT="declined"
        return 1
        ;;
      "")
        INSTALL_CONSENT="blocked-noninteractive"
        return 1
        ;;
      *)
        INSTALL_CONSENT="declined"
        return 1
        ;;
    esac
  fi
  INSTALL_CONSENT="blocked-noninteractive"
  return 1
}

noninteractive_remediation() {
  printf '%s' "Closed stdin or no TTY requires --yes. Re-run from a terminal and type yes or no, or pass --yes. Installation consent does not authorize plan execution."
}

emit_probe() {
  local want_json=$1
  emit_report "$want_json" "$PROBE_OUTCOME" "$PROBE_RESOLVED" "$PROBE_BUNDLE" \
    "$PROBE_API_PATH" "$PROBE_API_RAW" "$PROBE_API_JSON" "$PROBE_REMEDIATION" \
    "${PROBE_MISSING_VERBS[@]+"${PROBE_MISSING_VERBS[@]}"}"
}

run_repo_install() {
  local install_sh=$1
  local assume_yes=$2
  if [[ "$assume_yes" -eq 1 ]]; then
    bash "$install_sh" --global --yes
  else
    bash "$install_sh" --global
  fi
}

show_install_offer() {
  printf 'command: %s\n' "$INSTALL_COMMAND" >&2
  printf 'destination: %s\n' "$INSTALL_DESTINATION" >&2
  printf 'note: Installation consent does not authorize plan execution.\n' >&2
}

ensure_ralph() {
  local want_json=$1
  local assume_yes=$2
  local install_sh=""
  local install_ec=0
  local local_bin="${HOME}/.local/bin"

  ENSURE_MODE=1
  PLAN_EXECUTED=0
  INSTALL_RAN=0
  INSTALL_CONSENT="not-offered"
  INSTALL_COMMAND=""
  INSTALL_DESTINATION=""

  probe_collect || true
  case "$PROBE_OUTCOME" in
    usable|newer)
      emit_probe "$want_json"
      return 0
      ;;
    incompatible)
      emit_probe "$want_json"
      return 1
      ;;
    missing|legacy|too-old)
      ;;
    *)
      emit_probe "$want_json"
      return 1
      ;;
  esac

  if ! install_sh="$(resolve_install_sh)"; then
    PROBE_REMEDIATION="Could not locate this repository's install.sh. Clone Ralph and run ./install.sh --global. Installation consent does not authorize plan execution."
    emit_probe "$want_json"
    return 1
  fi

  INSTALL_DESTINATION="$(resolve_install_destination)"
  INSTALL_COMMAND="$(format_install_command "$install_sh" "$assume_yes")"
  show_install_offer

  if ! read_install_consent "$assume_yes"; then
    INSTALL_RAN=0
    if [[ "$INSTALL_CONSENT" == "blocked-noninteractive" ]]; then
      PROBE_REMEDIATION="$(noninteractive_remediation)"
    else
      PROBE_REMEDIATION="Installation declined; nothing was mutated. Installation consent does not authorize plan execution."
    fi
    emit_probe "$want_json"
    return 1
  fi

  INSTALL_RAN=1
  set +e
  run_repo_install "$install_sh" "$assume_yes"
  install_ec=$?
  set -e
  if [[ "$install_ec" -ne 0 ]]; then
    PROBE_REMEDIATION="install.sh --global failed with exit ${install_ec}. Installation consent does not authorize plan execution."
    emit_probe "$want_json"
    return 1
  fi

  if [[ -x "$local_bin/ralph" ]]; then
    PATH="$local_bin:$PATH"
    export PATH
  fi

  probe_collect || true
  emit_probe "$want_json"
  continue_exit "$PROBE_OUTCOME"
}

probe_collect() {
  local resolved="" bundle_path="" api_path="" api_raw="" api_json="null"
  local outcome remediation=""
  local help_text="" bundle_text="" bundle_ec=0
  local discovered=() missing_verbs=() verb

  PROBE_OUTCOME=""
  PROBE_RESOLVED=""
  PROBE_BUNDLE=""
  PROBE_API_PATH=""
  PROBE_API_RAW=""
  PROBE_API_JSON="null"
  PROBE_REMEDIATION=""
  PROBE_MISSING_VERBS=()

  if ! resolved="$(command -v "$RALPH_COMMAND_NAME" 2>/dev/null)"; then
    outcome="missing"
    remediation="Install Ralph with this repository's ./install.sh --global"
    PROBE_OUTCOME="$outcome"
    PROBE_RESOLVED="$resolved"
    PROBE_REMEDIATION="$remediation"
    return 1
  fi

  # Discover verbs from existing help. Do not invent or call extra CLI verbs.
  help_text="$("$resolved" --help 2>/dev/null)" || help_text=""

  bundle_text="$("$resolved" --bundle-path 2>/dev/null)" || bundle_ec=$?
  bundle_path="$(trim_ws "$(first_line "$bundle_text")")"
  if [[ "$bundle_ec" -ne 0 || -z "$bundle_path" ]]; then
    outcome="legacy"
    remediation="Upgrade Ralph with this repository's ./install.sh --global (current CLI is too old: ralph --bundle-path failed)"
    PROBE_OUTCOME="$outcome"
    PROBE_RESOLVED="$resolved"
    PROBE_BUNDLE="$bundle_path"
    PROBE_REMEDIATION="$remediation"
    return 1
  fi

  api_path="${bundle_path%/}/plugin-api-version"
  if [[ ! -f "$api_path" ]]; then
    outcome="too-old"
    remediation="Upgrade Ralph with this repository's ./install.sh --global (plugin-api-version is missing)"
    PROBE_OUTCOME="$outcome"
    PROBE_RESOLVED="$resolved"
    PROBE_BUNDLE="$bundle_path"
    PROBE_API_PATH="$api_path"
    PROBE_REMEDIATION="$remediation"
    return 1
  fi

  api_raw="$(trim_ws "$(tr -d '\r' <"$api_path")")"
  if ! is_integer "$api_raw"; then
    outcome="incompatible"
    remediation="Installed plugin-api-version is malformed; blocking. path=${api_path} value=${api_raw}"
    PROBE_OUTCOME="$outcome"
    PROBE_RESOLVED="$resolved"
    PROBE_BUNDLE="$bundle_path"
    PROBE_API_PATH="$api_path"
    PROBE_API_RAW="$api_raw"
    PROBE_REMEDIATION="$remediation"
    return 1
  fi

  api_json="$api_raw"
  if ((api_raw < EXPECTED_PLUGIN_API)); then
    outcome="too-old"
    remediation="Upgrade Ralph with this repository's ./install.sh --global (plugin ABI ${api_raw} is older than ${EXPECTED_PLUGIN_API})"
    PROBE_OUTCOME="$outcome"
    PROBE_RESOLVED="$resolved"
    PROBE_BUNDLE="$bundle_path"
    PROBE_API_PATH="$api_path"
    PROBE_API_RAW="$api_raw"
    PROBE_API_JSON="$api_json"
    PROBE_REMEDIATION="$remediation"
    return 1
  fi

  while IFS= read -r verb; do
    [[ -n "$verb" ]] && discovered+=("$verb")
  done < <(discover_verbs_from_help "$help_text")

  missing_verbs=()
  for verb in "${REQUIRED_VERBS[@]}"; do
    if ! verb_in_list "$verb" "${discovered[@]+"${discovered[@]}"}"; then
      missing_verbs+=("$verb")
    fi
  done

  if ((api_raw == EXPECTED_PLUGIN_API)); then
    outcome="usable"
    remediation=""
  elif [[ ${#missing_verbs[@]} -gt 0 ]]; then
    outcome="incompatible"
    remediation="Installed plugin ABI ${api_raw} is newer than ${EXPECTED_PLUGIN_API}, but required command help is missing: ${missing_verbs[*]}"
  else
    outcome="newer"
    remediation=""
  fi

  PROBE_OUTCOME="$outcome"
  PROBE_RESOLVED="$resolved"
  PROBE_BUNDLE="$bundle_path"
  PROBE_API_PATH="$api_path"
  PROBE_API_RAW="$api_raw"
  PROBE_API_JSON="$api_json"
  PROBE_REMEDIATION="$remediation"
  PROBE_MISSING_VERBS=("${missing_verbs[@]+"${missing_verbs[@]}"}")
  continue_exit "$outcome"
}

probe_ralph() {
  local want_json=$1
  probe_collect || true
  emit_probe "$want_json"
  continue_exit "$PROBE_OUTCOME"
}

cmd=""
want_json=0
assume_yes=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --json)
      want_json=1
      shift
      ;;
    --yes)
      assume_yes=1
      shift
      ;;
    probe|ensure)
      if [[ -n "$cmd" ]]; then
        usage >&2
        exit 2
      fi
      cmd=$1
      shift
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

case "$cmd" in
  probe)
    if [[ "$assume_yes" -eq 1 ]]; then
      usage >&2
      exit 2
    fi
    probe_ralph "$want_json"
    ;;
  ensure)
    ensure_ralph "$want_json" "$assume_yes"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
