#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_OPENCODE_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_OPENCODE_LOADED=1

# Public interface:
#   run_plan_invoke_opencode_session_resume_args / run_plan_invoke_opencode_bare_resume_args -- build argv fragments.
#   run_plan_invoke_opencode_bare_resume_warn -- stderr warning when bare resume is not allowed.
#   run_plan_invoke_opencode_config_prepare / run_plan_invoke_opencode_config_cleanup -- ephemeral OPENCODE_CONFIG for ralph MCP and/or native hooks.
#   run_plan_invoke_opencode_native_hooks_prepare / run_plan_invoke_opencode_native_hooks_cleanup -- Ralph plugin overlay metadata.
#   ralph_run_plan_invoke_opencode -- run `opencode run` (non-interactive) with model, resume; exports log/session paths for demux.
#   run_plan_invoke_opencode_serve_supported -- graph-only feature-detect of `opencode serve` via help (no model call).
#   run_plan_invoke_opencode_serve_capture_request -- parse one permission.asked event into session/request/effect.
#   run_plan_invoke_opencode_serve_capture_from_command -- start `opencode serve` on 127.0.0.1 plus an ephemeral port, consume ordered permission events, then stop.
#   run_plan_invoke_opencode_serve_map_decision -- map once/run/project/deny onto an OpenCode permission reply without converting read to write.
#   run_plan_invoke_opencode_serve_session_start -- start serve, capture the first permission, and keep the server alive.
#   run_plan_invoke_opencode_serve_respond -- POST one mapped decision to the documented permission reply endpoint.
#   run_plan_invoke_opencode_serve_reconnect -- re-attach to the existing loopback SSE stream without enabling auto mode.
#   run_plan_invoke_opencode_serve_close / run_plan_invoke_opencode_serve_cleanup -- dispose the server on completion, cancellation, or supervisor cleanup.
#   run_plan_invoke_opencode_serve_start_or_fallback -- feature-detect, then start or return a safe overlay fallback.

_run_plan_invoke_opencode_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_run_plan_invoke_opencode_dir/run-plan-cli-helpers.sh"
# shellcheck source=/dev/null
source "$_run_plan_invoke_opencode_dir/run-plan-invoke-common.sh"
# shellcheck source=/dev/null
source "$_run_plan_invoke_opencode_dir/../mcp/mcp-setup.sh"
# shellcheck source=/dev/null
source "$_run_plan_invoke_opencode_dir/../runtime-config/runtime-config-mcp.sh"
# shellcheck source=/dev/null
source "$_run_plan_invoke_opencode_dir/../runtime-overlay/runtime-overlay-opencode.sh"
unset _run_plan_invoke_opencode_dir

run_plan_invoke_opencode_session_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--session \"\${RALPH_RUN_PLAN_RESUME_SESSION_ID}\")"
}

run_plan_invoke_opencode_session_new_args() {
  :
}

run_plan_invoke_opencode_bare_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--continue)"
}

run_plan_invoke_opencode_bare_resume_warn() {
  echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; omitting bare opencode run --continue." >&2
}

ralph_opencode_provider_id_from_selected_model() {
  local selected_model="${1:-${SELECTED_MODEL:-}}"
  if [[ -z "$selected_model" || "$selected_model" != */* ]]; then
    return 0
  fi
  printf '%s' "${selected_model%%/*}"
}

ralph_opencode_detect_cache_settings_in_config() {
  local config_path="$1"
  if [[ -z "$config_path" ]]; then
    printf '0'
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    printf '0'
    return 0
  fi
  python3 - "$config_path" <<'PY'
import json
import sys

PROMPT_CACHE_KEYS = {"prompt_cache_key", "promptcachekey", "promptcache_key", "prompt_cachekey"}
CACHE_KEY_KEYWORDS = {"setcachekey", "cachekey", "enablecache", "cacheenabled", "usecache"}


def truthy(value):
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    text = str(value).strip().lower()
    if not text:
        return False
    return text in ("1", "true", "yes", "on")


def has_prompt_cache_key(value):
    if not isinstance(value, dict):
        return False
    for key, entry in value.items():
        key_lower = str(key).strip().lower()
        if key_lower in PROMPT_CACHE_KEYS:
            if isinstance(entry, str):
                if entry.strip():
                    return True
            elif entry is not None:
                return True
    return False


def check_node(node):
    if not isinstance(node, dict):
        return False
    if has_prompt_cache_key(node):
        return True
    for key, value in node.items():
        key_lower = str(key).strip().lower()
        if key_lower in CACHE_KEY_KEYWORDS and truthy(value):
            return True
        if key_lower == "cache" and isinstance(value, dict):
            for sub in value.values():
                if truthy(sub):
                    return True
    return False


def inspect_options(node):
    if isinstance(node, dict):
        for key in ("options", "providerOptions"):
            nested = node.get(key)
            if isinstance(nested, dict) and (check_node(nested) or has_prompt_cache_key(nested)):
                return True
    return False


path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("0")
    sys.exit(0)

if check_node(data) or inspect_options(data):
    print("1")
    sys.exit(0)

models = data.get("models")
if isinstance(models, dict):
    for nested_model in models.values():
        if not isinstance(nested_model, dict):
            continue
        if inspect_options(nested_model) or check_node(nested_model):
            print("1")
            sys.exit(0)

provider = data.get("provider")
if isinstance(provider, dict):
    for node in provider.values():
        if not isinstance(node, dict):
            continue
        if inspect_options(node):
            print("1")
            sys.exit(0)
        models = node.get("models")
        if isinstance(models, dict):
            for nested_model in models.values():
                if not isinstance(nested_model, dict):
                    continue
                if inspect_options(nested_model) or check_node(nested_model):
                    print("1")
                    sys.exit(0)
        if check_node(node):
            print("1")
            sys.exit(0)

print("0")
PY
}

ralph_opencode_model_prompt_cache_key_present() {
  local config_path="$1"
  local provider_id="$2"
  local model_id="$3"
  if [[ -z "$config_path" || -z "$provider_id" || -z "$model_id" ]]; then
    printf '0'
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    printf '0'
    return 0
  fi
  python3 - "$config_path" "$provider_id" "$model_id" <<'PY'
import json
import sys

path, provider_id, model_id = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("0")
    sys.exit(0)

provider = data.get("provider", {})
node = provider.get(provider_id, {})
models = node.get("models", {})
model = models.get(model_id, {})

def has_prompt(container):
    if not isinstance(container, dict):
        return False
    for key in ("prompt_cache_key", "promptCacheKey"):
        if key in container and container[key] is not None:
            return True
    return False

if has_prompt(model.get("options")) or has_prompt(model.get("providerOptions")) or has_prompt(model):
    print("1")
    sys.exit(0)
print("0")
PY
}

ralph_opencode_provider_set_cache_key_present() {
  local config_path="$1"
  local provider_id="$2"
  if [[ -z "$config_path" || -z "$provider_id" ]]; then
    printf '0'
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    printf '0'
    return 0
  fi
  python3 - "$config_path" "$provider_id" <<'PY'
import json
import sys

path, provider_id = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("0")
    sys.exit(0)

def truthy(value):
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    text = str(value).strip().lower()
    if not text:
        return False
    return text in ("1", "true", "yes", "on")

def has_set_cache_key(container):
    if not isinstance(container, dict):
        return False
    for key in ("setCacheKey", "setcachekey"):
        if key in container and truthy(container[key]):
            return True
    return False

provider = data.get("provider", {})
node = provider.get(provider_id, {}) if isinstance(provider, dict) else {}

if has_set_cache_key(node):
    print("1")
    sys.exit(0)

for key in ("options", "providerOptions"):
    nested = node.get(key)
    if has_set_cache_key(nested):
        print("1")
        sys.exit(0)

print("0")
PY
}

ralph_run_plan_opencode_jsonc_to_json() {
  local input_path="$1"
  local output_path="$2"
  if [[ -z "$input_path" || -z "$output_path" ]]; then
    echo "Error: source and destination paths are required for JSONC conversion." >&2
    return 1
  fi
  if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required to convert JSONC OpenCode configs." >&2
    return 1
  fi

  python3 - "$input_path" "$output_path" <<'PY'
import json
import re
import sys
from pathlib import Path

if len(sys.argv) != 3:
    print("Error: ralph_run_plan_opencode_jsonc_to_json requires two arguments.", file=sys.stderr)
    sys.exit(1)

src = Path(sys.argv[1])
dest = Path(sys.argv[2])

if not src.is_file():
    print(f"Error: OpenCode config not found: {src}", file=sys.stderr)
    sys.exit(1)

text = src.read_text()
if text.startswith("\ufeff"):
    text = text.lstrip("\ufeff")

def strip_jsonc(value):
    result = []
    i = 0
    length = len(value)
    in_string = False
    escape = False
    while i < length:
        ch = value[i]
        if in_string:
            result.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue

        if ch == '"':
            result.append(ch)
            in_string = True
            i += 1
            continue

        if ch == "/" and i + 1 < length:
            nxt = value[i + 1]
            if nxt == "/":
                i += 2
                while i < length and value[i] not in "\r\n":
                    i += 1
                continue
            if nxt == "*":
                i += 2
                while i + 1 < length:
                    if value[i] == "*" and value[i + 1] == "/":
                        i += 2
                        break
                    i += 1
                else:
                    raise ValueError("unterminated /* comment")
                continue

        result.append(ch)
        i += 1

    cleaned = "".join(result)
    trailing = re.compile(r",\s*(?=[\]}])")
    while True:
        updated = trailing.sub("", cleaned)
        if updated == cleaned:
            break
        cleaned = updated
    return cleaned

try:
    cleaned = strip_jsonc(text)
    parsed = json.loads(cleaned)
except (json.JSONDecodeError, ValueError) as exc:
    print(f"Error: failed to convert JSONC OpenCode config {src}: {exc}", file=sys.stderr)
    sys.exit(1)

dest.write_text(json.dumps(parsed, indent=2) + "\n")
PY
}

# OpenCode loads user config from $XDG_CONFIG_HOME/opencode/{config,opencode}.{json,jsonc}. Try those files before falling back to '{}'.
_run_plan_invoke_opencode_default_config_path() {
  local config_home="${XDG_CONFIG_HOME:-${HOME:-$PWD}/.config}"
  local candidate
  local search_dir="${config_home%/}/opencode"

  for candidate in \
    config.json \
    config.jsonc \
    opencode.json \
    opencode.jsonc; do
    local candidate_path="$search_dir/$candidate"
    if [[ -f "$candidate_path" ]]; then
      printf '%s\n' "$candidate_path"
      return 0
    fi
  done

  return 1
}

# Enumerate OpenCode configuration layers in documented precedence order
# (remote, global, custom, project, directory). Later layers override earlier
# ones. Outputs lines as "<layer>:<path>" for existing files only; callers
# must filter for existence.
_run_plan_invoke_opencode_config_layer_paths() {
  local project_root="${1:-${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}}"
  local xdg="${2:-${XDG_CONFIG_HOME:-${HOME:-$PWD}/.config}}"
  local custom="${OPENCODE_CONFIG:-}"
  local directory="${OPENCODE_DIRECTORY_CONFIG:-}"
  local remote="${OPENCODE_REMOTE_CONFIG:-}"

  if [[ -n "$remote" ]]; then
    printf 'remote:%s\n' "$remote"
  fi
  printf 'global:%s\n' "$xdg/opencode/config.json"
  printf 'global:%s\n' "$xdg/opencode/config.jsonc"
  printf 'global:%s\n' "$xdg/opencode/opencode.json"
  printf 'global:%s\n' "$xdg/opencode/opencode.jsonc"
  if [[ -n "$custom" ]]; then
    printf 'custom:%s\n' "$custom"
  fi
  printf 'project:%s\n' "$project_root/opencode.json"
  printf 'project:%s\n' "$project_root/opencode.jsonc"
  printf 'project:%s\n' "$project_root/.opencode/opencode.json"
  printf 'project:%s\n' "$project_root/.opencode/opencode.jsonc"
  if [[ -n "$directory" ]]; then
    printf 'directory:%s\n' "$directory"
  fi
}

# Merge OpenCode configuration layers into a single JSON file. Preserves every
# unrelated key using jq's recursive merge (*). JSONC sources are converted to
# JSON first. Sets RALPH_OPENCODE_CONFIG_SOURCE_DESC to a comma-separated list
# of the layers actually merged. Prints the merged JSON file path.
_run_plan_invoke_opencode_merge_config_layers() {
  local project_root="${1:-${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}}"
  local xdg="${2:-${XDG_CONFIG_HOME:-${HOME:-$PWD}/.config}}"
  local -a json_sources=()
  local -a source_descs=()
  local line layer path converted
  local -A seen_paths=()

  while IFS=':' read -r layer path; do
    [[ -n "$path" ]] || continue
    [[ -f "$path" ]] || continue
    if [[ -n "${seen_paths[$path]:-}" ]]; then
      continue
    fi
    seen_paths[$path]=1
    if jq empty "$path" >/dev/null 2>&1; then
      json_sources+=("$path")
      source_descs+=("${layer}:${path}")
    else
      converted="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-jsonc-XXXXXX")"
      if ralph_run_plan_opencode_jsonc_to_json "$path" "$converted"; then
        ralph_mcp_overlay_record_temp_file "$converted"
        json_sources+=("$converted")
        source_descs+=("${layer}:${path}")
      else
        ralph_mcp_cleanup_config "$converted"
        echo "Error: invalid JSONC in OpenCode ${layer} config: $path" >&2
        return 1
      fi
    fi
  done < <(_run_plan_invoke_opencode_config_layer_paths "$project_root" "$xdg")

  local merged_json
  merged_json="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-merged-XXXXXX")"
  if [[ ${#json_sources[@]} -eq 0 ]]; then
    printf '{}\n' >"$merged_json"
    RALPH_OPENCODE_CONFIG_SOURCE_DESC="generated empty config"
  else
    if ! jq -s 'reduce .[] as $item ({}; . * $item)' "${json_sources[@]}" >"$merged_json" 2>/dev/null; then
      ralph_mcp_cleanup_config "$merged_json"
      echo "Error: failed to merge OpenCode configuration layers." >&2
      return 1
    fi
    local desc
    desc="$(printf '%s\n' "${source_descs[@]}" | paste -sd ', ' -)"
    RALPH_OPENCODE_CONFIG_SOURCE_DESC="$desc"
  fi
  ralph_mcp_overlay_record_temp_file "$merged_json"
  export RALPH_OPENCODE_CONFIG_SOURCE_DESC
  printf '%s' "$merged_json"
}

run_plan_invoke_opencode_config_cleanup() {
  if [[ -n "${OPENCODE_PLAN_MCP_CONFIG_PATH:-}" ]]; then
    ralph_mcp_cleanup_config "$OPENCODE_PLAN_MCP_CONFIG_PATH"
  fi
  unset OPENCODE_PLAN_MCP_CONFIG_PATH
  run_plan_invoke_opencode_native_hooks_cleanup
}

run_plan_invoke_opencode_mcp_config_cleanup() {
  run_plan_invoke_opencode_config_cleanup
}

_run_plan_invoke_opencode_load_ambient_config_json() {
  local merged_json
  if ! merged_json="$(_run_plan_invoke_opencode_merge_config_layers)"; then
    return 1
  fi
  printf '%s' "$merged_json"
}

run_plan_invoke_opencode_config_prepare() {
  local workspace="${WORKSPACE:-}"
  local need_mcp=0
  local need_hooks=0
  local want_cache_key=0
  local plan_external_pattern=""
  local config_modified=0

  RALPH_OPENCODE_CACHE_KEY_INJECTED="0"
  RALPH_OPENCODE_CACHE_KEY_PROVIDER_ID=""
  RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED="0"
  export RALPH_OPENCODE_CACHE_KEY_INJECTED RALPH_OPENCODE_CACHE_KEY_PROVIDER_ID RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED

  local prompt_cache_passthrough_providers="ollama-cloud"
  local selected_model="${SELECTED_MODEL:-}"
  local selected_model_model_id=""
  if [[ "$selected_model" == */* ]]; then
    selected_model_model_id="${selected_model#*/}"
  fi

  # Use RALPH_MODE and RALPH_AGENT_TOOL_ACCESS to determine MCP injection behavior
  local _ralph_mode="${RALPH_MODE:-no}"
  if [[ "$_ralph_mode" == "ralph" || "$_ralph_mode" == "hybrid" || "${RALPH_AGENT_TOOL_ACCESS:-}" == "ralph" ]]; then
    need_mcp=1
  fi
  if [[ "${OPENCODE_PLAN_NATIVE_HOOKS_ACTIVE:-0}" == "1" ]]; then
    need_hooks=1
  fi
  if [[ -n "${PLAN_PATH:-}" && -n "$workspace" ]]; then
    case "$PLAN_PATH" in
      "$workspace"/*) ;;
      *) plan_external_pattern="$(dirname "$PLAN_PATH")/**" ;;
    esac
  fi

  local provider_id
  provider_id="$(ralph_opencode_provider_id_from_selected_model "$selected_model")"
  if [[ -n "$provider_id" && "${RALPH_OPENCODE_SET_CACHE_KEY:-1}" != "0" ]]; then
    want_cache_key=1
  fi

  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "OpenCode config prepare: selected_model=${selected_model:-none} provider_id=${provider_id:-none} want_cache_key=${want_cache_key} need_mcp=${need_mcp} need_hooks=${need_hooks}"
  fi

  if [[ "$need_mcp" -eq 0 && "$need_hooks" -eq 0 && "$want_cache_key" -eq 0 && -z "$plan_external_pattern" ]]; then
    return 0
  fi

  if [[ "$need_mcp" -eq 1 && -z "$workspace" ]]; then
    echo "Error: WORKSPACE is required for OpenCode config injection." >&2
    return 1
  fi

  local ambient_config_json
  if ! ambient_config_json="$(_run_plan_invoke_opencode_load_ambient_config_json)"; then
    return 1
  fi

  local ambient_cache_settings
  ambient_cache_settings="$(ralph_opencode_detect_cache_settings_in_config "$ambient_config_json" 2>/dev/null || true)"
  RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS="${ambient_cache_settings:-0}"
  export RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "OpenCode ambient config detected: cache_settings=${RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS} config_source=${RALPH_OPENCODE_CONFIG_SOURCE_DESC:-unknown}"
  fi

  local working_config
  working_config="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-config-XXXXXX")"
  cp "$ambient_config_json" "$working_config"
  ralph_mcp_overlay_record_temp_file "$working_config"

  if [[ -n "${OPENCODE_PLAN_PERMISSION_CONFIG_PATH:-}" ]] && [[ -f "${OPENCODE_PLAN_PERMISSION_CONFIG_PATH:-}" ]]; then
    local permission_overlay perm_merge_err
    permission_overlay="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-permission-merged-XXXXXX")"
    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "OpenCode permission overlay: merging from ${OPENCODE_PLAN_PERMISSION_CONFIG_PATH}"
    fi
    perm_merge_err="$(jq -c --slurpfile perm "$OPENCODE_PLAN_PERMISSION_CONFIG_PATH" \
      '.permission = ((.permission // {}) + ($perm[0].permission // {}))' \
      "$working_config" > "$permission_overlay" 2>&1)"
    if [[ "$?" -ne 0 ]]; then
      ralph_mcp_cleanup_config "$permission_overlay"
      ralph_mcp_cleanup_config "$working_config"
      echo "Error: failed to merge OpenCode permission overlay into OPENCODE_CONFIG." >&2
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "OpenCode permission merge failed: stderr=${perm_merge_err}"
      fi
      return 1
    fi
    ralph_mcp_cleanup_config "$working_config"
    working_config="$permission_overlay"
    ralph_mcp_overlay_record_temp_file "$working_config"
    config_modified=1
    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "OpenCode permission overlay merged successfully"
    fi
  fi

  if [[ -n "$plan_external_pattern" ]]; then
    local control_permission_overlay
    control_permission_overlay="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-control-permission-XXXXXX")"
    if ! jq -c --arg pattern "$plan_external_pattern" '
      .permission = (if ((.permission // {}) | type) == "object" then (.permission // {}) else {} end)
      | .permission.external_directory =
          (if ((.permission.external_directory // {}) | type) == "object"
           then ((.permission.external_directory // {}) + {($pattern): "allow"})
           else {($pattern): "allow"}
           end)
    ' "$working_config" >"$control_permission_overlay"; then
      ralph_mcp_cleanup_config "$control_permission_overlay"
      ralph_mcp_cleanup_config "$working_config"
      echo "Error: failed to authorize Ralph-owned OpenCode control-plan reads." >&2
      return 1
    fi
    ralph_mcp_cleanup_config "$working_config"
    working_config="$control_permission_overlay"
    ralph_mcp_overlay_record_temp_file "$working_config"
    config_modified=1
    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "OpenCode permission overlay: allowed Ralph-owned control path $plan_external_pattern"
    fi
  fi

  if [[ "$want_cache_key" -eq 1 ]]; then
    local provider_field_type jq_err
    provider_field_type="$(jq -r '.provider | type' "$working_config" 2>/dev/null || true)"
    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "OpenCode setCacheKey check: provider_field_type=${provider_field_type:-unknown} provider_id=${provider_id}"
    fi
    if [[ "$provider_field_type" != "null" && "$provider_field_type" != "object" ]]; then
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "OpenCode setCacheKey: skipping injection (ambient provider field type is ${provider_field_type}, expected null or object)"
      fi
    else
      local provider_has_set_cache_key="0"
      provider_has_set_cache_key="$(ralph_opencode_provider_set_cache_key_present "$working_config" "$provider_id" 2>/dev/null || true)"
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "OpenCode setCacheKey detection: provider_has_set_cache_key=${provider_has_set_cache_key}"
      fi
      if [[ "$provider_has_set_cache_key" == "0" ]]; then
        local cache_key_config
        cache_key_config="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-cache-key-XXXXXX")"
        jq_err="$(jq -c --arg provider_id "$provider_id" '.provider = ((.provider // {}) * {($provider_id): {options: {setCacheKey: true}}})' "$working_config" 2>&1 > "$cache_key_config")"
        if [[ "$?" -eq 0 ]]; then
          ralph_mcp_cleanup_config "$working_config"
          working_config="$cache_key_config"
          ralph_mcp_overlay_record_temp_file "$working_config"
          RALPH_OPENCODE_CACHE_KEY_INJECTED="1"
          RALPH_OPENCODE_CACHE_KEY_PROVIDER_ID="$provider_id"
          export RALPH_OPENCODE_CACHE_KEY_INJECTED RALPH_OPENCODE_CACHE_KEY_PROVIDER_ID
          config_modified=1
          if declare -F ralph_run_plan_log >/dev/null 2>&1; then
            ralph_run_plan_log "OpenCode setCacheKey injected successfully for provider=${provider_id}"
          fi
        else
          echo "Warning: OpenCode setCacheKey jq merge failed: $jq_err" >&2
          if declare -F ralph_run_plan_log >/dev/null 2>&1; then
            ralph_run_plan_log "OpenCode setCacheKey jq merge failed: exit_code=$? stderr=${jq_err}"
          fi
          ralph_mcp_cleanup_config "$cache_key_config"
        fi
      fi

      local should_inject_prompt_cache_key=0
      if [[ -n "$selected_model_model_id" && " $prompt_cache_passthrough_providers " == *" $provider_id "* ]]; then
        should_inject_prompt_cache_key=1
      fi
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "OpenCode prompt_cache_key check: should_inject=${should_inject_prompt_cache_key} model_id=${selected_model_model_id:-none} provider_id=${provider_id}"
      fi
      if [[ "$should_inject_prompt_cache_key" -eq 1 ]]; then
        local prompt_cache_present="0"
        prompt_cache_present="$(ralph_opencode_model_prompt_cache_key_present "$working_config" "$provider_id" "$selected_model_model_id" 2>/dev/null || true)"
        if declare -F ralph_run_plan_log >/dev/null 2>&1; then
          ralph_run_plan_log "OpenCode prompt_cache_key detection: prompt_cache_present=${prompt_cache_present}"
        fi
        if [[ "$prompt_cache_present" == "0" ]]; then
          local prompt_cache_config prompt_cache_plan_slug prompt_cache_key_value
          prompt_cache_plan_slug="${RALPH_PLAN_KEY:-}"
          prompt_cache_plan_slug="${prompt_cache_plan_slug//[^A-Za-z0-9._-]/_}"
          prompt_cache_plan_slug="${prompt_cache_plan_slug//../_}"
          if [[ -z "$prompt_cache_plan_slug" ]]; then
            prompt_cache_plan_slug="plan"
          fi
          prompt_cache_key_value="ralph-${prompt_cache_plan_slug}"
          prompt_cache_config="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-prompt-cache-key-XXXXXX")"
          if declare -F ralph_run_plan_log >/dev/null 2>&1; then
            ralph_run_plan_log "OpenCode prompt_cache_key injecting: key_value=${prompt_cache_key_value} model_id=${selected_model_model_id} provider_id=${provider_id}"
          fi
          jq_err="$(
            jq -c --arg provider_id "$provider_id" --arg model_id "$selected_model_model_id" --arg prompt_cache_key "$prompt_cache_key_value" '
              .provider = ((.provider // {}) * {($provider_id): ((.provider[$provider_id] // {}) * {models: ((.provider[$provider_id].models // {}) * {($model_id): ((.provider[$provider_id].models[$model_id] // {}) * {options: ((.provider[$provider_id].models[$model_id].options // {}) * {prompt_cache_key: $prompt_cache_key})})})})})
            ' "$working_config" 2>&1 > "$prompt_cache_config"
          )"
          if [[ "$?" -eq 0 ]]; then
            ralph_mcp_cleanup_config "$working_config"
            working_config="$prompt_cache_config"
            ralph_mcp_overlay_record_temp_file "$working_config"
            RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED="1"
            export RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED
            config_modified=1
            if declare -F ralph_run_plan_log >/dev/null 2>&1; then
              ralph_run_plan_log "OpenCode prompt_cache_key injected successfully"
            fi
          else
            echo "Warning: OpenCode prompt_cache_key jq merge failed: $jq_err" >&2
            if declare -F ralph_run_plan_log >/dev/null 2>&1; then
              ralph_run_plan_log "OpenCode prompt_cache_key jq merge failed: exit_code=$? stderr=${jq_err}"
            fi
            ralph_mcp_cleanup_config "$prompt_cache_config"
          fi
        fi
      fi
    fi
  fi

  if [[ "$need_mcp" -eq 1 ]]; then
    local mcp_overlay_json
    mcp_overlay_json="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-mcp-XXXXXX")"
    if [[ -n "${RALPH_RUNTIME_MCP_RESOLVE_PATH:-}" && -f "$RALPH_RUNTIME_MCP_RESOLVE_PATH" ]]; then
      # Shared resolver already produced the effective catalog (ambient user/project
      # servers + selected-agent overrides + Ralph's protected server). Preserve its
      # native OpenCode shape.
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "OpenCode MCP config: using resolver path=${RALPH_RUNTIME_MCP_RESOLVE_PATH}"
      fi
      jq -c '.mcp // {}' "$RALPH_RUNTIME_MCP_RESOLVE_PATH" > "$mcp_overlay_json"
    else
      # Fallback when the resolver is not available (e.g. direct helper tests): use the
      # Ralph-only generator.
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "OpenCode MCP config: using fallback generator"
      fi
      if ! ralph_mcp_generate_config opencode "$mcp_overlay_json" "$workspace"; then
        ralph_mcp_cleanup_config "$mcp_overlay_json"
        ralph_mcp_cleanup_config "$working_config"
        echo "Error: failed to generate OpenCode MCP config." >&2
        if declare -F ralph_run_plan_log >/dev/null 2>&1; then
          ralph_run_plan_log "OpenCode MCP config generation failed"
        fi
        return 1
      fi
    fi
    ralph_mcp_overlay_record_temp_file "$mcp_overlay_json"
    local merged_mcp
    merged_mcp="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-mcp-merged-XXXXXX")"
    local mcp_merge_err
    mcp_merge_err="$(jq -c --slurpfile mcp "$mcp_overlay_json" \
      '.mcp = ((.mcp // {}) * ($mcp[0].mcp // {}))' \
      "$working_config" > "$merged_mcp" 2>&1)"
    if [[ "$?" -ne 0 ]]; then
      ralph_mcp_cleanup_config "$mcp_overlay_json"
      ralph_mcp_cleanup_config "$working_config"
      ralph_mcp_cleanup_config "$merged_mcp"
      echo "Error: failed to merge Ralph MCP config into OPENCODE_CONFIG." >&2
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "OpenCode MCP merge failed: stderr=${mcp_merge_err}"
      fi
      return 1
    fi
    ralph_mcp_cleanup_config "$mcp_overlay_json"
    ralph_mcp_cleanup_config "$working_config"
    working_config="$merged_mcp"
    ralph_mcp_overlay_record_temp_file "$working_config"
    config_modified=1
    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "OpenCode MCP config merged successfully"
    fi
  fi

  local final_cache_settings
  final_cache_settings="$(ralph_opencode_detect_cache_settings_in_config "$working_config" 2>/dev/null || true)"
  if [[ "${RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED:-0}" == "1" || "${RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS:-0}" == "1" ]]; then
    final_cache_settings="1"
  fi
  RALPH_OPENCODE_FINAL_CACHE_SETTINGS="${final_cache_settings:-0}"
  export RALPH_OPENCODE_FINAL_CACHE_SETTINGS
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "OpenCode config final state: cache_key_injected=${RALPH_OPENCODE_CACHE_KEY_INJECTED} prompt_cache_injected=${RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED} final_cache_settings=${RALPH_OPENCODE_FINAL_CACHE_SETTINGS}"
  fi
  if declare -F run_plan_invoke_opencode_cache_key_injection_record >/dev/null 2>&1; then
    run_plan_invoke_opencode_cache_key_injection_record
  fi

  if [[ "$need_hooks" -eq 1 ]]; then
    if [[ -z "${OPENCODE_PLAN_STAGED_PLUGIN_PATH:-}" ]]; then
      ralph_mcp_cleanup_config "$working_config"
      echo "Error: Ralph OpenCode plugin staging path is not set." >&2
      return 1
    fi
  fi

  if [[ "$config_modified" -eq 0 && "$need_hooks" -eq 0 ]]; then
    ralph_mcp_cleanup_config "$working_config"
    return 0
  fi

  OPENCODE_PLAN_MCP_CONFIG_PATH="$working_config"
  export OPENCODE_PLAN_MCP_CONFIG_PATH
  ralph_mcp_overlay_register_runtime_cleanup run_plan_invoke_opencode_config_cleanup
  return 0
}

run_plan_invoke_opencode_mcp_config_prepare() {
  run_plan_invoke_opencode_config_prepare
}

ralph_run_plan_invoke_opencode() {
  ralph_run_plan_sync_mode_knobs
  ralph_run_plan_subagents_log_contract opencode || return 1
  ralph_run_plan_subagents_require_runtime_capability opencode || return 1
  ralph_run_plan_native_subagent_verify_runtime opencode || return 1
  RALPH_OPENCODE_CONFIG_SOURCE_DESC=""
  RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS="0"
  RALPH_OPENCODE_FINAL_CACHE_SETTINGS="0"
  # Paths and flags the Python demux / tee pipeline expects in the environment.
  export OUTPUT_LOG EXIT_CODE_FILE SESSION_ID_FILE

  # Resolve CLI before nvm use because nvm may change PATH and break the resolved path.
  local cli="${OPENCODE_PLAN_CLI:-}"

  if [[ -z "$cli" ]]; then
    if cli="$(ralph_resolve_opencode_cli)"; then
      : # resolved
    else
      echo "Error: OpenCode CLI not found (set OPENCODE_PLAN_CLI or install opencode)." >&2
      return 1
    fi
  fi

  if ! command -v "$cli" &>/dev/null; then
    echo "Error: OpenCode CLI not found at '$cli'." >&2
    return 1
  fi

  # Store absolute path before nvm use potentially changes PATH.
  cli="$(command -v "$cli")"

  # Ensure node v22 is active so the correct opencode binary is found and used.
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh" --no-use 2>/dev/null
    nvm use 22 --silent 2>/dev/null || true
  fi

  if ! command -v "$cli" &>/dev/null; then
    echo "Error: OpenCode CLI not found at '$cli'." >&2
    return 1
  fi

  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export RALPH_BASH_LIB_DIR="$lib_dir"
  if [[ -n "${WORKSPACE:-}" ]]; then
    export WORKSPACE
  fi
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    export RALPH_PLAN_KEY
  fi

  run_plan_invoke_opencode_package_metadata_prepare || return 1
  if declare -F ralph_mcp_overlay_register_runtime_cleanup >/dev/null 2>&1; then
    ralph_mcp_overlay_register_runtime_cleanup run_plan_invoke_opencode_package_metadata_cleanup
  fi
  run_plan_invoke_opencode_native_hooks_prepare

  local opencode_config_path=""
  if ! run_plan_invoke_opencode_config_prepare; then
    return 1
  fi
  if [[ -n "${OPENCODE_PLAN_MCP_CONFIG_PATH:-}" ]]; then
    opencode_config_path="$OPENCODE_PLAN_MCP_CONFIG_PATH"
    if declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
      if [[ "${RALPH_AGENT_TOOL_ACCESS:-native}" == "ralph" ]]; then
        runtime_overlay_set_mcp_effective "true"
      else
        runtime_overlay_set_mcp_effective "false"
      fi
    fi
  elif declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
    runtime_overlay_set_mcp_effective "false"
  fi

  # `opencode` with no subcommand starts the TUI; headless automation uses `opencode run` (see https://opencode.ai/docs/cli).
  local -a args=(run --agent build)
  run_plan_invoke_common_add_model_flag args --model
  run_plan_invoke_common_add_reasoning_effort_flag args opencode "${OPENCODE_PLAN_CLI:-opencode}"

  run_plan_invoke_common_add_resume_args \
    args \
    run_plan_invoke_opencode_session_resume_args \
    run_plan_invoke_opencode_session_new_args \
    run_plan_invoke_opencode_bare_resume_args \
    run_plan_invoke_opencode_bare_resume_warn
  run_plan_invoke_common_add_cli_resume_flags args --format json

  # `opencode run [message..]` accepts the prompt as positional message text.
  # Passing a temp-file path makes the model try to read that path through
  # OpenCode's permission system, which can auto-reject paths outside the repo.
  args+=("$PROMPT")

  if [[ -n "$opencode_config_path" ]] && command -v jq &>/dev/null; then
    local opencode_mcp_enabled=""
    opencode_mcp_enabled="$(jq -r '.mcp.ralph.enabled // empty' "$opencode_config_path" 2>/dev/null || true)"
    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "OpenCode MCP: ralph.enabled=${opencode_mcp_enabled:-unknown}"
    fi
  fi

  run_plan_invoke_opencode_cli() {
    local agent_ws="${RALPH_AGENT_WORKSPACE:-$(pwd)}"
    if [[ -n "$opencode_config_path" ]]; then
      (
        cd "$agent_ws" || exit 1
        run_plan_invoke_common_launch_cli opencode env OPENCODE_CONFIG="$opencode_config_path" "$cli" "${args[@]}"
      )
    else
      (
        cd "$agent_ws" || exit 1
        run_plan_invoke_common_launch_cli opencode "$cli" "${args[@]}"
      )
    fi
  }

  run_plan_invoke_common_execute \
    run_plan_invoke_opencode_cli \
    opencode \
    "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse JSON and update session-id.opencode.txt; running without it."

  if [[ -n "$opencode_config_path" ]]; then
    run_plan_invoke_opencode_config_cleanup
  else
    run_plan_invoke_opencode_native_hooks_cleanup
  fi

  if declare -F runtime_overlay_write_summary >/dev/null 2>&1; then
    runtime_overlay_write_summary || true
  fi
}

# Graph-only OpenCode serve approval transport (request capture).
# Starts `opencode serve` bound to 127.0.0.1 on an ephemeral port, consumes
# the SSE event stream in order, and captures session/request identity plus
# the underlying read/edit/shell effect. `external_directory` is never the
# effect. Normal non-graph `ralph_run_plan_invoke_opencode` does not call these
# helpers and never enables OpenCode auto mode.

run_plan_invoke_opencode_serve_graph_enabled() {
  case "${RALPH_GRAPH_APPROVAL:-}" in
    1|true|yes|on)
      return 0
      ;;
  esac
  [[ -n "${RALPH_GRAPH_NODE_ID:-}" ]]
}

_run_plan_invoke_opencode_serve_timeout() {
  local timeout_raw="${RALPH_OPENCODE_SERVE_CAPTURE_TIMEOUT:-5}"
  if [[ "$timeout_raw" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$timeout_raw"
  else
    printf '5'
  fi
}

_run_plan_invoke_opencode_serve_registry_path() {
  printf '%s' "${RALPH_OPENCODE_SERVE_REGISTRY:-${TMPDIR:-/tmp}/ralph-opencode-serve.sessions}"
}

_run_plan_invoke_opencode_serve_registry_add() {
  local pid="${1:-}"
  local registry
  [[ -n "$pid" ]] || return 0
  registry="$(_run_plan_invoke_opencode_serve_registry_path)"
  mkdir -p "$(dirname "$registry")" 2>/dev/null || true
  printf '%s\n' "$pid" >>"$registry"
}

_run_plan_invoke_opencode_serve_registry_remove() {
  local pid="${1:-}"
  local registry tmp
  registry="$(_run_plan_invoke_opencode_serve_registry_path)"
  [[ -f "$registry" && -n "$pid" ]] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-serve-reg.XXXXXX")" || return 0
  grep -v "^${pid}$" "$registry" >"$tmp" 2>/dev/null || true
  mv "$tmp" "$registry" 2>/dev/null || rm -f "$tmp"
}

_run_plan_invoke_opencode_serve_session_registry_path() {
  printf '%s.dirs' "$(_run_plan_invoke_opencode_serve_registry_path)"
}

_run_plan_invoke_opencode_serve_session_registry_add() {
  local session_dir="${1:-}"
  local registry
  [[ -n "$session_dir" ]] || return 0
  registry="$(_run_plan_invoke_opencode_serve_session_registry_path)"
  mkdir -p "$(dirname "$registry")" 2>/dev/null || true
  printf '%s\n' "$session_dir" >>"$registry"
}

_run_plan_invoke_opencode_serve_session_registry_remove() {
  local session_dir="${1:-}"
  local registry tmp
  registry="$(_run_plan_invoke_opencode_serve_session_registry_path)"
  [[ -f "$registry" && -n "$session_dir" ]] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-serve-sess.XXXXXX")" || return 0
  grep -Fxv -- "$session_dir" "$registry" >"$tmp" 2>/dev/null || true
  mv "$tmp" "$registry" 2>/dev/null || rm -f "$tmp"
}

_run_plan_invoke_opencode_serve_reap() {
  local target="$1" waited=0
  [[ -n "$target" ]] || return 0
  kill "$target" 2>/dev/null || true
  while (( waited < 20 )); do
    kill -0 "$target" 2>/dev/null || return 0
    sleep 0.05
    waited=$((waited + 1))
  done
  kill -9 "$target" 2>/dev/null || true
}

run_plan_invoke_opencode_serve_cleanup() {
  local registry session_dir pid
  local -a sessions=()
  registry="$(_run_plan_invoke_opencode_serve_session_registry_path)"
  if [[ -f "$registry" ]]; then
    while IFS= read -r session_dir; do
      [[ -n "$session_dir" ]] || continue
      sessions+=("$session_dir")
    done <"$registry"
    for session_dir in "${sessions[@]}"; do
      run_plan_invoke_opencode_serve_close "$session_dir" supervisor >/dev/null 2>&1 || true
    done
    rm -f "$registry"
  fi
  registry="$(_run_plan_invoke_opencode_serve_registry_path)"
  [[ -f "$registry" ]] || return 0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    _run_plan_invoke_opencode_serve_reap "$pid"
    wait "$pid" 2>/dev/null || true
  done <"$registry"
  rm -f "$registry"
}

_run_plan_invoke_opencode_serve_capability_missing() {
  local cli_name="${1:-opencode}"
  local serve_help
  local -a missing=()

  if ! command -v "$cli_name" >/dev/null 2>&1; then
    printf '%s\n' "opencode cli"
    return 0
  fi

  if ! serve_help="$("$cli_name" serve --help 2>/dev/null)"; then
    missing+=("opencode serve")
    printf '%s\n' "${missing[@]}"
    return 0
  fi

  if [[ "$serve_help" != *"serve"* && "$serve_help" != *"hostname"* && "$serve_help" != *"--port"* && "$serve_help" != *"/event"* && "$serve_help" != *"SSE"* && "$serve_help" != *"event stream"* ]]; then
    missing+=("opencode serve protocol")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s\n' "${missing[@]}"
  fi
}

run_plan_invoke_opencode_serve_supported() {
  local cli_name="${1:-${OPENCODE_PLAN_CLI:-${OPENCODE_CLI:-opencode}}}"
  local missing
  missing="$(_run_plan_invoke_opencode_serve_capability_missing "$cli_name")"
  [[ -z "$missing" ]]
}

run_plan_invoke_opencode_serve_is_permission_event() {
  local raw="${1:-}"
  local kind
  [[ -n "$raw" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  kind="$(printf '%s' "$raw" | jq -r '
    def event:
      if type != "object" then empty
      elif (.payload | type) == "object" then .payload
      else . end;
    event | .type // empty
  ' 2>/dev/null)" || return 1
  [[ "$kind" == "permission.asked" ]]
}

# run_plan_invoke_opencode_serve_capture_request <permission-event-or-request-json>
# Prints one compact JSON object with session, requestId, permission, effect,
# and resource. Fail-closed on missing identity. `external_directory` is the
# permission kind, never the underlying read/edit/shell effect.
run_plan_invoke_opencode_serve_capture_request() {
  local raw="${1:-}"
  local captured

  if [[ -z "$raw" ]]; then
    echo "Error: OpenCode serve approval capture requires a permission event" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for OpenCode serve approval capture" >&2
    return 1
  fi

  captured="$(printf '%s' "$raw" | jq -ce '
    def str($v):
      if $v == null then ""
      elif ($v | type) == "string" then $v
      elif ($v | type) == "number" then ($v | tostring)
      elif ($v | type) == "array" then ($v | map(tostring) | join(" "))
      else "" end;
    def lower($v):
      str($v) | ascii_downcase;
    def event:
      if type != "object" then
        error("OpenCode serve approval capture requires a JSON object")
      elif (.payload | type) == "object" then .payload
      else . end;
    def request:
      event as $e
      | if ($e.type // "") == "permission.asked" then ($e.properties // {})
        elif ($e.type | type) == "string" then
          error("OpenCode serve message is not a permission request: \($e.type)")
        elif ($e.sessionID != null or $e.id != null or $e.permission != null) then $e
        else
          error("OpenCode serve message is not a permission request")
        end;
    def tool_name($req):
      ($req.metadata // {}) as $m
      | (if ($m.tool | type) == "object" then ($m.tool.name // $m.tool.id // "")
         else ($m.tool // $m.action // $m.permission // $req.tool.name // "") end)
      | lower(.);
    def map_effect($name):
      if $name == "read" or $name == "glob" or $name == "grep" then "read"
      elif $name == "edit" or $name == "write" or $name == "patch" then "edit"
      elif $name == "bash" or $name == "shell" then "shell"
      elif $name == "webfetch" or $name == "websearch" then "network"
      else "" end;
    request as $req
    | (str($req.sessionID // $req.sessionId // $req.session)) as $session
    | (str($req.id // $req.requestID // $req.requestId)) as $request_id
    | (lower($req.permission // $req.type // "")) as $permission
    | (tool_name($req)) as $tool
    | (if $permission == "external_directory" then map_effect($tool)
       else
         (map_effect($permission) | if . != "" then . else map_effect($tool) end)
       end) as $effect
    | (if ($req.patterns | type) == "array" then $req.patterns else [] end) as $patterns
    | (if ($req.always | type) == "array" then $req.always else [] end) as $always
    | (if $patterns | length > 0 then str($patterns[0])
       else str($req.metadata.filepath // $req.metadata.path // $req.metadata.command // $req.metadata.url // "")
       end) as $resource
    | if $session == "" or $request_id == "" then
        error("OpenCode serve approval request is missing session or request identity")
      elif $permission == "" then
        error("OpenCode serve approval request is missing permission")
      elif $effect == "" then
        error("OpenCode serve approval request is missing an underlying read/edit/shell effect")
      elif $permission == "external_directory" and $effect == "edit" and ($tool == "read" or $tool == "glob" or $tool == "grep") then
        error("OpenCode serve approval capture must not convert a read request into an edit effect")
      else
        {
          schemaVersion: 1,
          runtime: "opencode",
          session: $session,
          requestId: $request_id,
          permission: $permission,
          effect: $effect,
          resource: $resource,
          patterns: $patterns,
          always: $always
        }
        + (if ($req.metadata | type) == "object" then {metadata: $req.metadata} else {} end)
        + (if ($req.tool | type) == "object" then {tool: $req.tool} else {} end)
      end
  ' 2>/dev/null)" || {
    echo "Error: OpenCode serve approval capture failed" >&2
    return 1
  }

  printf '%s\n' "$captured"
}

_run_plan_invoke_opencode_serve_ephemeral_port() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket; s=socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
    return
  fi
  echo "Error: python3 is required to allocate an ephemeral loopback port for opencode serve" >&2
  return 1
}

_run_plan_invoke_opencode_serve_wait_ready() {
  local host="$1" port="$2" timeout="$3" pid="${4:-}"
  local start now
  start="$(date +%s)"
  while true; do
    if command -v python3 >/dev/null 2>&1; then
      if python3 - "$host" "$port" <<'PY' >/dev/null 2>&1
import sys
import urllib.request
host, port = sys.argv[1], sys.argv[2]
urllib.request.urlopen("http://%s:%s/global/health" % (host, port), timeout=0.2)
PY
      then
        return 0
      fi
    elif command -v curl >/dev/null 2>&1; then
      if curl -sS --max-time 1 "http://${host}:${port}/global/health" >/dev/null 2>&1; then
        return 0
      fi
    fi
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      echo "Error: opencode serve exited before becoming ready" >&2
      return 1
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      echo "Error: opencode serve did not become ready on ${host}:${port}" >&2
      return 1
    fi
    sleep 0.05
  done
}

_run_plan_invoke_opencode_serve_read_sse() {
  local host="$1" port="$2" path="${3:-/event}" timeout="$4"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$host" "$port" "$path" "$timeout" <<'PY'
import sys
import urllib.error
import urllib.request

host, port, path, timeout_s = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
url = "http://%s:%s%s" % (host, port, path)
req = urllib.request.Request(
    url,
    headers={
        "Accept": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
    },
)
try:
    resp = urllib.request.urlopen(req, timeout=timeout_s)
except Exception as exc:
    sys.stderr.write("Error: OpenCode serve event stream failed: %s\n" % exc)
    raise SystemExit(1)
try:
    while True:
        line = resp.readline()
        if not line:
            break
        text = line.decode("utf-8", "replace").rstrip("\r\n")
        if text.startswith("data:"):
            payload = text[5:].lstrip()
            if payload and payload != "[DONE]":
                sys.stdout.write(payload + "\n")
                sys.stdout.flush()
except Exception:
    pass
PY
    return
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -sS -N --max-time "$timeout" -H "Accept: text/event-stream" "http://${host}:${port}${path}" \
      | awk '/^data:/{sub(/^data:[[:space:]]*/, ""); if ($0 != "" && $0 != "[DONE]") print}'
    return
  fi
  echo "Error: python3 or curl is required to consume the OpenCode serve event stream" >&2
  return 1
}

# run_plan_invoke_opencode_serve_consume_events <host> <port> [path]
# Reads the SSE stream in order and prints a JSON array of captured permission
# requests. Non-permission events are ignored.
run_plan_invoke_opencode_serve_consume_events() {
  local host="${1:-}"
  local port="${2:-}"
  local path="${3:-/event}"
  local timeout line captured
  local -a items=()

  if [[ -z "$host" || -z "$port" ]]; then
    echo "Error: OpenCode serve event consume requires host and port" >&2
    return 1
  fi
  if [[ "$host" != "127.0.0.1" && "$host" != "localhost" ]]; then
    echo "Error: OpenCode serve approval capture is loopback-only" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for OpenCode serve approval capture" >&2
    return 1
  fi

  timeout="$(_run_plan_invoke_opencode_serve_timeout)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if ! printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1; then
      continue
    fi
    if ! run_plan_invoke_opencode_serve_is_permission_event "$line"; then
      continue
    fi
    captured="$(run_plan_invoke_opencode_serve_capture_request "$line")" || return 1
    items[${#items[@]}]="$captured"
  done < <(_run_plan_invoke_opencode_serve_read_sse "$host" "$port" "$path" "$timeout")

  if [[ ${#items[@]} -eq 0 ]]; then
    echo "Error: OpenCode serve did not emit a permission request" >&2
    return 1
  fi
  printf '%s\n' "${items[@]}" | jq -s -c '.'
}

# run_plan_invoke_opencode_serve_capture_from_command <command> [args...]
# Graph-only. Starts `<command> serve --hostname 127.0.0.1 --port <ephemeral>`,
# consumes ordered permission events, then stops the server. Extra args are
# appended after the bind flags and must not include --auto.
run_plan_invoke_opencode_serve_capture_from_command() {
  local cmd="${1:-}"
  shift || true
  local extra
  for extra in "$@"; do
    case "$extra" in
      --auto|auto|--dangerously-skip-permissions)
        echo "Error: OpenCode serve approval capture rejects auto mode" >&2
        return 1
        ;;
    esac
  done
  local host="127.0.0.1" port pid="" rc=0 captured="" timeout tmpdir stdout_log stderr_log

  if [[ -z "$cmd" ]]; then
    echo "Error: OpenCode serve capture requires a serve command" >&2
    return 1
  fi
  if ! run_plan_invoke_opencode_serve_graph_enabled; then
    echo "Error: OpenCode serve approval capture is graph-only" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for OpenCode serve approval capture" >&2
    return 1
  fi
  if [[ ! -x "$cmd" ]] && ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: OpenCode serve command not found: $cmd" >&2
    return 1
  fi

  timeout="$(_run_plan_invoke_opencode_serve_timeout)"
  port="$(_run_plan_invoke_opencode_serve_ephemeral_port)" || return 1
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-opencode-serve.XXXXXX")" || {
    echo "Error: failed to create OpenCode serve capture temp dir" >&2
    return 1
  }
  stdout_log="$tmpdir/stdout.log"
  stderr_log="$tmpdir/stderr.log"

  "$cmd" serve --hostname "$host" --port "$port" "$@" >"$stdout_log" 2>"$stderr_log" &
  pid=$!
  _run_plan_invoke_opencode_serve_registry_add "$pid"

  if ! _run_plan_invoke_opencode_serve_wait_ready "$host" "$port" "$timeout" "$pid"; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    _run_plan_invoke_opencode_serve_registry_remove "$pid"
    rm -rf "$tmpdir"
    return 1
  fi

  captured="$(run_plan_invoke_opencode_serve_consume_events "$host" "$port" /event)" || rc=$?

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  _run_plan_invoke_opencode_serve_registry_remove "$pid"
  rm -rf "$tmpdir"

  if [[ "$rc" -ne 0 || -z "$captured" ]]; then
    [[ "$rc" -ne 0 ]] || echo "Error: OpenCode serve did not emit a permission request" >&2
    return 1
  fi
  printf '%s\n' "$captured"
}

_run_plan_invoke_opencode_serve_normalize_ralph_decision() {
  local raw
  raw="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  case "$raw" in
    once|allow-once) printf 'once' ;;
    run|allow-run|session) printf 'run' ;;
    project|always|always-policy|allow-always) printf 'project' ;;
    deny|reject) printf 'deny' ;;
    auto|force|yolo|dangerously-skip-permissions|--auto)
      echo "Error: OpenCode serve approval rejects auto mode" >&2
      return 1
      ;;
    *) return 1 ;;
  esac
}

# run_plan_invoke_opencode_serve_fallback [reason]
# Safe overlay-fallback object when serve or a native reply is unsupported.
run_plan_invoke_opencode_serve_fallback() {
  local reason="${1:-unsupported}"
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "{\"schemaVersion\":1,\"runtime\":\"opencode\",\"fallback\":true,\"reason\":\"${reason}\",\"path\":\"overlay\"}"
    return 0
  fi
  jq -nc --arg reason "$reason" '{
    schemaVersion: 1,
    runtime: "opencode",
    fallback: true,
    reason: $reason,
    path: "overlay"
  }'
}

# run_plan_invoke_opencode_serve_merge_permission_overlay <base-config> <overlay-json-or-file>
# Applies the same shallow `.permission` merge used by config_prepare
# (`+`, later keys override). Does not write ambient user or project files.
# Prints the merged temp file path.
run_plan_invoke_opencode_serve_merge_permission_overlay() {
  local base="${1:-}"
  local overlay_in="${2:-}"
  local overlay_file merged perm_merge_err

  if [[ -z "$base" || ! -f "$base" ]]; then
    echo "Error: OpenCode permission overlay merge requires a base config file" >&2
    return 1
  fi
  if [[ -z "$overlay_in" ]]; then
    echo "Error: OpenCode permission overlay merge requires overlay JSON" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required to merge an OpenCode permission overlay" >&2
    return 1
  fi

  overlay_file="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-perm-overlay.XXXXXX")" || return 1
  if [[ -f "$overlay_in" ]]; then
    if ! jq -e 'type == "object"' "$overlay_in" >/dev/null 2>&1; then
      rm -f "$overlay_file"
      echo "Error: OpenCode permission overlay must be a JSON object" >&2
      return 1
    fi
    cp "$overlay_in" "$overlay_file"
  else
    if ! printf '%s' "$overlay_in" | jq -e 'type == "object"' >/dev/null 2>&1; then
      rm -f "$overlay_file"
      echo "Error: OpenCode permission overlay must be a JSON object" >&2
      return 1
    fi
    printf '%s\n' "$overlay_in" >"$overlay_file"
  fi

  merged="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-perm-merged.XXXXXX")" || {
    rm -f "$overlay_file"
    return 1
  }
  perm_merge_err="$(jq -c --slurpfile perm "$overlay_file" \
    '.permission = ((.permission // {}) + ($perm[0].permission // {}))' \
    "$base" >"$merged" 2>&1)" || {
    rm -f "$overlay_file" "$merged"
    echo "Error: failed to merge OpenCode permission overlay into OPENCODE_CONFIG." >&2
    return 1
  }
  rm -f "$overlay_file"
  unset perm_merge_err
  printf '%s' "$merged"
}

# run_plan_invoke_opencode_serve_map_decision <captured-or-raw-json> <ralph-decision> [extra-json]
# Maps once->once, run->always (run lifetime), project->always (project
# lifetime), deny->reject. Overlay grants use the captured effect only; a
# read request never becomes an edit/write grant, including when the
# permission kind is external_directory.
run_plan_invoke_opencode_serve_map_decision() {
  local raw="${1:-}"
  local decision_raw="${2:-}"
  local extra="${3:-}"
  local captured ralph native lifetime overlay_wanted mapped

  if [[ -z "$raw" ]]; then
    echo "Error: OpenCode serve decision mapping requires a captured request" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for OpenCode serve decision mapping" >&2
    return 1
  fi
  if ! ralph="$(_run_plan_invoke_opencode_serve_normalize_ralph_decision "$decision_raw")"; then
    echo "Error: OpenCode serve decision is unsupported: ${decision_raw:-<empty>}" >&2
    return 1
  fi
  if [[ -n "$extra" ]] && ! printf '%s' "$extra" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: OpenCode serve decision extra must be a JSON object" >&2
    return 1
  fi
  [[ -n "$extra" ]] || extra='{}'

  if printf '%s' "$raw" | jq -e 'has("requestId") and has("effect") and has("session")' >/dev/null 2>&1; then
    captured="$raw"
  else
    captured="$(run_plan_invoke_opencode_serve_capture_request "$raw")" || return 1
  fi

  case "$ralph" in
    once)
      native="once"
      lifetime="once"
      overlay_wanted=0
      ;;
    run)
      native="always"
      lifetime="run"
      overlay_wanted=1
      ;;
    project)
      native="always"
      lifetime="project"
      overlay_wanted=1
      ;;
    deny)
      native="reject"
      lifetime="deny"
      overlay_wanted=0
      ;;
  esac

  mapped="$(
    printf '%s' "$captured" | jq -c \
      --arg ralph "$ralph" \
      --arg native "$native" \
      --arg lifetime "$lifetime" \
      --argjson overlay_wanted "$overlay_wanted" \
      --argjson extra "$extra" '
      def str($v):
        if $v == null then ""
        elif ($v | type) == "string" then $v
        elif ($v | type) == "number" then ($v | tostring)
        else "" end;
      def overlay_key($effect):
        if $effect == "read" then "read"
        elif $effect == "edit" then "edit"
        elif $effect == "shell" then "bash"
        elif $effect == "network" then "webfetch"
        else $effect end;
      . as $req
      | ($req.effect // "") as $effect
      | ($req.permission // "") as $permission
      | (if ($req.resource // "") != "" then str($req.resource)
         elif (($req.patterns // []) | type) == "array" and (($req.patterns // []) | length) > 0 then str($req.patterns[0])
         else "" end) as $resource
      | (if $overlay_wanted == 1 then
           if $resource == "" then
             error("OpenCode serve approval overlay requires a resource")
           else
             {permission: {(overlay_key($effect)): {($resource): "allow"}}}
           end
         else null end) as $built
      | (if ($extra.overlay | type) == "object" then $extra.overlay
         elif ($extra.permission | type) == "object" then {permission: $extra.permission}
         else $built end) as $overlay
      | if $effect == "read" and ($overlay | type) == "object" and
           (($overlay.permission // {}) | keys | any(. == "edit" or . == "write" or . == "*" or . == "external_directory")) then
          error("OpenCode serve approval must not convert a read request into a write grant")
        elif $effect == "read" and ($overlay | type) == "object" and
             (($overlay.permission // {}) | keys | length) > 1 then
          error("OpenCode serve approval must not convert a read request into a write grant")
        else . end
      | {
          schemaVersion: 1,
          runtime: "opencode",
          fallback: false,
          ralphDecision: $ralph,
          native: $native,
          lifetime: $lifetime,
          effect: $effect,
          permission: $permission,
          session: $req.session,
          requestId: $req.requestId,
          resource: $resource,
          endpoint: ("/permission/" + $req.requestId + "/reply"),
          method: "POST",
          response: {reply: $native},
          overlay: $overlay
        }
    '
  )" || {
    echo "Error: OpenCode serve approval must not convert a read request into a write grant" >&2
    return 1
  }

  printf '%s\n' "$mapped"
}

_run_plan_invoke_opencode_serve_post_reply() {
  local host="$1" port="$2" path="$3" body="$4" timeout="$5"
  if [[ "$host" != "127.0.0.1" && "$host" != "localhost" ]]; then
    echo "Error: OpenCode serve approval reply is loopback-only" >&2
    return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$host" "$port" "$path" "$timeout" "$body" <<'PY'
import sys
import urllib.error
import urllib.request

host, port, path, timeout_s, body = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5]
url = "http://%s:%s%s" % (host, port, path)
req = urllib.request.Request(
    url,
    data=body.encode("utf-8"),
    method="POST",
    headers={"Content-Type": "application/json", "Accept": "application/json"},
)
try:
    resp = urllib.request.urlopen(req, timeout=timeout_s)
except urllib.error.HTTPError as exc:
    sys.stderr.write("Error: OpenCode serve permission reply failed: %s\n" % exc)
    raise SystemExit(1)
except Exception as exc:
    sys.stderr.write("Error: OpenCode serve permission reply failed: %s\n" % exc)
    raise SystemExit(1)
sys.stdout.write(resp.read().decode("utf-8", "replace"))
PY
    return
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -sS --max-time "$timeout" -X POST \
      -H "Content-Type: application/json" \
      --data "$body" \
      "http://${host}:${port}${path}"
    return
  fi
  echo "Error: python3 or curl is required to reply to an OpenCode permission request" >&2
  return 1
}

_run_plan_invoke_opencode_serve_write_overlay() {
  local session_dir="$1"
  local mapped="$2"
  local overlay dest existing merged

  overlay="$(printf '%s' "$mapped" | jq -c '.overlay // empty')"
  [[ -n "$overlay" && "$overlay" != "null" ]] || return 0

  dest="${session_dir}/opencode-permission-override.json"
  if [[ -n "${OPENCODE_PLAN_PERMISSION_CONFIG_PATH:-}" ]]; then
    dest="$OPENCODE_PLAN_PERMISSION_CONFIG_PATH"
  fi
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  if [[ -f "$dest" ]]; then
    existing="$dest"
    merged="$(run_plan_invoke_opencode_serve_merge_permission_overlay "$existing" "$overlay")" || return 1
    mv "$merged" "$dest"
  else
    printf '%s\n' "$overlay" >"$dest"
  fi
  printf '%s\n' "$dest" >"$session_dir/overlay.path"
}

run_plan_invoke_opencode_serve_session_alive() {
  local session_dir="${1:-}"
  local pid
  [[ -n "$session_dir" && -d "$session_dir" ]] || return 1
  [[ -f "$session_dir/state" ]] || return 1
  case "$(cat "$session_dir/state" 2>/dev/null || true)" in
    closed|failed) return 1 ;;
  esac
  pid="$(cat "$session_dir/pid" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# run_plan_invoke_opencode_serve_session_start <command> [args...]
# Graph-only. Starts `<command> serve --hostname 127.0.0.1 --port <ephemeral>`,
# captures the first permission request, and keeps the server alive until close.
run_plan_invoke_opencode_serve_session_start() {
  local cmd="${1:-}"
  shift || true
  local extra
  for extra in "$@"; do
    case "$extra" in
      --auto|auto|--dangerously-skip-permissions)
        echo "Error: OpenCode serve approval capture rejects auto mode" >&2
        return 1
        ;;
    esac
  done
  local host="127.0.0.1" port pid="" rc=0 captured="" timeout session_dir stdout_log stderr_log first

  if [[ -z "$cmd" ]]; then
    echo "Error: OpenCode serve session requires a serve command" >&2
    return 1
  fi
  if ! run_plan_invoke_opencode_serve_graph_enabled; then
    echo "Error: OpenCode serve approval capture is graph-only" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for OpenCode serve approval capture" >&2
    return 1
  fi
  if [[ ! -x "$cmd" ]] && ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: OpenCode serve command not found: $cmd" >&2
    return 1
  fi

  timeout="$(_run_plan_invoke_opencode_serve_timeout)"
  port="$(_run_plan_invoke_opencode_serve_ephemeral_port)" || return 1
  session_dir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-opencode-serve-session.XXXXXX")" || {
    echo "Error: failed to create OpenCode serve session dir" >&2
    return 1
  }
  stdout_log="$session_dir/stdout.log"
  stderr_log="$session_dir/stderr.log"
  printf '%s\n' "$host" >"$session_dir/host"
  printf '%s\n' "$port" >"$session_dir/port"
  printf '%s\n' "starting" >"$session_dir/state"

  "$cmd" serve --hostname "$host" --port "$port" "$@" >"$stdout_log" 2>"$stderr_log" &
  pid=$!
  printf '%s\n' "$pid" >"$session_dir/pid"
  _run_plan_invoke_opencode_serve_registry_add "$pid"
  _run_plan_invoke_opencode_serve_session_registry_add "$session_dir"

  if ! _run_plan_invoke_opencode_serve_wait_ready "$host" "$port" "$timeout" "$pid"; then
    run_plan_invoke_opencode_serve_close "$session_dir" supervisor >/dev/null 2>&1 || true
    return 1
  fi

  captured="$(run_plan_invoke_opencode_serve_consume_events "$host" "$port" /event)" || rc=$?
  if [[ "$rc" -ne 0 || -z "$captured" ]]; then
    run_plan_invoke_opencode_serve_close "$session_dir" supervisor >/dev/null 2>&1 || true
    echo "Error: OpenCode serve did not emit a permission request" >&2
    return 1
  fi

  first="$(printf '%s' "$captured" | jq -c 'if type == "array" then .[0] else . end')"
  printf '%s\n' "$first" >"$session_dir/request.json"
  printf '%s\n' "$captured" >"$session_dir/requests.json"
  printf '%s\n' "waiting" >"$session_dir/state"

  jq -nc \
    --arg dir "$session_dir" \
    --arg host "$host" \
    --arg port "$port" \
    --argjson request "$first" \
    --arg pid "$pid" '{
      schemaVersion: 1,
      runtime: "opencode",
      fallback: false,
      sessionDir: $dir,
      host: $host,
      port: ($port | tonumber),
      pid: ($pid | tonumber),
      alive: true,
      request: $request
    }'
}

# run_plan_invoke_opencode_serve_respond <session-dir> <ralph-decision-or-mapped-json> [extra-json]
run_plan_invoke_opencode_serve_respond() {
  local session_dir="${1:-}"
  local decision="${2:-}"
  local extra="${3:-}"
  local mapped response_json host port request_id session_id path timeout reply_out

  if [[ -z "$session_dir" || ! -d "$session_dir" ]]; then
    echo "Error: OpenCode serve respond requires a live session dir" >&2
    return 1
  fi
  if [[ -z "$decision" ]]; then
    echo "Error: OpenCode serve respond requires a decision" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for OpenCode serve respond" >&2
    return 1
  fi

  if [[ "$(cat "$session_dir/state" 2>/dev/null || true)" == "closed" ]]; then
    echo "Error: OpenCode serve session is closed" >&2
    return 1
  fi
  if [[ -f "$session_dir/response.sent.json" ]]; then
    jq -nc \
      --arg dir "$session_dir" \
      --argjson sent "$(cat "$session_dir/response.sent.json")" '{
        schemaVersion: 1,
        runtime: "opencode",
        sessionDir: $dir,
        duplicate: true,
        resolved: true,
        reason: "already-resolved",
        response: $sent
      }'
    return 0
  fi

  if printf '%s' "$decision" | jq -e 'type == "object" and has("response")' >/dev/null 2>&1; then
    mapped="$decision"
  else
    if [[ ! -f "$session_dir/request.json" ]]; then
      echo "Error: OpenCode serve session is missing a captured request" >&2
      return 1
    fi
    mapped="$(run_plan_invoke_opencode_serve_map_decision "$(cat "$session_dir/request.json")" "$decision" "$extra")" || return 1
  fi
  if printf '%s' "$mapped" | jq -e '.fallback == true' >/dev/null 2>&1; then
    printf '%s\n' "$mapped"
    return 2
  fi
  if printf '%s' "$mapped" | jq -e '.effect == "read" and ((.overlay.permission.edit // .overlay.permission.write // null) != null)' >/dev/null 2>&1; then
    echo "Error: OpenCode serve approval must not convert a read request into a write grant" >&2
    return 1
  fi

  host="$(cat "$session_dir/host" 2>/dev/null || true)"
  port="$(cat "$session_dir/port" 2>/dev/null || true)"
  request_id="$(printf '%s' "$mapped" | jq -r '.requestId')"
  session_id="$(printf '%s' "$mapped" | jq -r '.session')"
  response_json="$(printf '%s' "$mapped" | jq -c '.response')"
  path="$(printf '%s' "$mapped" | jq -r '.endpoint')"
  timeout="$(_run_plan_invoke_opencode_serve_timeout)"

  if ! reply_out="$(_run_plan_invoke_opencode_serve_post_reply "$host" "$port" "$path" "$response_json" "$timeout")"; then
    path="/session/${session_id}/permission/${request_id}/reply"
    reply_out="$(_run_plan_invoke_opencode_serve_post_reply "$host" "$port" "$path" "$response_json" "$timeout")" || {
      echo "Error: OpenCode serve did not accept a permission reply" >&2
      return 1
    }
  fi

  printf '%s\n' "$response_json" >"$session_dir/response.sent.json"
  printf '%s\n' "$mapped" >"$session_dir/mapped.json"
  printf '%s\n' "${reply_out:-true}" >"$session_dir/reply.http"
  printf '%s\n' "responded" >"$session_dir/state"
  _run_plan_invoke_opencode_serve_write_overlay "$session_dir" "$mapped" || true

  jq -nc \
    --arg dir "$session_dir" \
    --argjson mapped "$mapped" '{
      schemaVersion: 1,
      runtime: "opencode",
      sessionDir: $dir,
      fallback: false,
      duplicate: false,
      resolved: true,
      ralphDecision: $mapped.ralphDecision,
      native: $mapped.native,
      lifetime: $mapped.lifetime,
      effect: $mapped.effect,
      permission: $mapped.permission,
      response: $mapped.response,
      overlay: $mapped.overlay
    }'
}

# run_plan_invoke_opencode_serve_reconnect <session-dir>
# Re-attaches to the existing loopback event stream. Never starts a new
# server and never enables auto mode.
run_plan_invoke_opencode_serve_reconnect() {
  local session_dir="${1:-}"
  local host port captured first rc=0

  if [[ -z "$session_dir" || ! -d "$session_dir" ]]; then
    echo "Error: OpenCode serve reconnect requires a live session dir" >&2
    return 1
  fi
  if ! run_plan_invoke_opencode_serve_session_alive "$session_dir"; then
    echo "Error: OpenCode serve reconnect requires a live loopback server" >&2
    return 1
  fi
  host="$(cat "$session_dir/host")"
  port="$(cat "$session_dir/port")"
  if [[ "$host" != "127.0.0.1" && "$host" != "localhost" ]]; then
    echo "Error: OpenCode serve approval capture is loopback-only" >&2
    return 1
  fi

  captured="$(run_plan_invoke_opencode_serve_consume_events "$host" "$port" /event)" || rc=$?
  if [[ "$rc" -eq 0 && -n "$captured" ]]; then
    first="$(printf '%s' "$captured" | jq -c 'if type == "array" then .[0] else . end')"
    printf '%s\n' "$first" >"$session_dir/request.json"
    printf '%s\n' "$captured" >"$session_dir/requests.json"
  elif [[ -f "$session_dir/request.json" ]]; then
    first="$(cat "$session_dir/request.json")"
  else
    echo "Error: OpenCode serve reconnect did not recover a permission request" >&2
    return 1
  fi
  printf '%s\n' "waiting" >"$session_dir/state"

  jq -nc \
    --arg dir "$session_dir" \
    --arg host "$host" \
    --arg port "$port" \
    --argjson request "$first" '{
      schemaVersion: 1,
      runtime: "opencode",
      sessionDir: $dir,
      host: $host,
      port: ($port | tonumber),
      reconnected: true,
      auto: false,
      request: $request
    }'
}

# run_plan_invoke_opencode_serve_close <session-dir> [reason]
# reason: completion | cancellation | supervisor. Idempotent. Disposes the
# server on every terminal path and never enables auto mode.
run_plan_invoke_opencode_serve_close() {
  local session_dir="${1:-}"
  local reason="${2:-completion}"
  local pid host port mapped

  if [[ -z "$session_dir" || ! -d "$session_dir" ]]; then
    jq -nc --arg reason "$reason" '{schemaVersion:1,runtime:"opencode",closed:true,reason:$reason,duplicate:true}'
    return 0
  fi

  if [[ "$(cat "$session_dir/state" 2>/dev/null || true)" != "closed" && "$reason" == "cancellation" && -f "$session_dir/request.json" && ! -f "$session_dir/response.sent.json" ]]; then
    mapped="$(run_plan_invoke_opencode_serve_map_decision "$(cat "$session_dir/request.json")" deny 2>/dev/null || true)"
    host="$(cat "$session_dir/host" 2>/dev/null || true)"
    port="$(cat "$session_dir/port" 2>/dev/null || true)"
    if [[ -n "$mapped" && -n "$host" && -n "$port" ]]; then
      _run_plan_invoke_opencode_serve_post_reply \
        "$host" "$port" \
        "$(printf '%s' "$mapped" | jq -r '.endpoint')" \
        "$(printf '%s' "$mapped" | jq -c '.response')" \
        1 >/dev/null 2>&1 || true
    fi
  fi

  printf '%s\n' "$reason" >"$session_dir/close.reason"
  pid="$(cat "$session_dir/pid" 2>/dev/null || true)"
  _run_plan_invoke_opencode_serve_reap "$pid"
  wait "$pid" 2>/dev/null || true
  _run_plan_invoke_opencode_serve_registry_remove "$pid"
  _run_plan_invoke_opencode_serve_session_registry_remove "$session_dir"
  printf '%s\n' "closed" >"$session_dir/state"

  jq -nc --arg dir "$session_dir" --arg reason "$reason" '{
    schemaVersion: 1,
    runtime: "opencode",
    sessionDir: $dir,
    closed: true,
    reason: $reason
  }'
}

# run_plan_invoke_opencode_serve_start_or_fallback [cli] [serve-args...]
# Feature-detect without a model call. Unsupported protocol returns overlay fallback.
run_plan_invoke_opencode_serve_start_or_fallback() {
  local cli="${1:-${OPENCODE_PLAN_CLI:-${OPENCODE_CLI:-opencode}}}"
  shift || true
  local extra
  for extra in "$@"; do
    case "$extra" in
      --auto|auto|--dangerously-skip-permissions)
        echo "Error: OpenCode serve approval capture rejects auto mode" >&2
        return 1
        ;;
    esac
  done
  if ! run_plan_invoke_opencode_serve_graph_enabled; then
    echo "Error: OpenCode serve approval capture is graph-only" >&2
    return 1
  fi
  if ! run_plan_invoke_opencode_serve_supported "$cli"; then
    run_plan_invoke_opencode_serve_fallback "unsupported"
    return 2
  fi
  run_plan_invoke_opencode_serve_session_start "$cli" "$@"
}
