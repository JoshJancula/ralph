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

_run_plan_invoke_opencode_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_run_plan_invoke_opencode_dir/run-plan-cli-helpers.sh"
# shellcheck source=/dev/null
source "$_run_plan_invoke_opencode_dir/run-plan-invoke-common.sh"
# shellcheck source=/dev/null
source "$_run_plan_invoke_opencode_dir/../mcp/mcp-setup.sh"
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
  local ambient_config="${OPENCODE_CONFIG:-}"
  local ambient_config_json="$ambient_config"
  local ambient_config_json_temp=""
  local config_source_desc=""

  if [[ -z "$ambient_config" ]]; then
    ambient_config="$(_run_plan_invoke_opencode_default_config_path || true)"
    ambient_config_json="$ambient_config"
  fi

  if [[ -n "$ambient_config" ]]; then
    config_source_desc="$ambient_config"
  else
    config_source_desc="generated empty config"
  fi

  if [[ -z "$ambient_config" ]]; then
    ambient_config_json="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-base-XXXXXX")"
    printf '{}\n' >"$ambient_config_json"
    ralph_mcp_overlay_record_temp_file "$ambient_config_json"
    RALPH_OPENCODE_CONFIG_SOURCE_DESC="$config_source_desc"
    export RALPH_OPENCODE_CONFIG_SOURCE_DESC
    printf '%s' "$ambient_config_json"
    return 0
  fi

  if [[ ! -f "$ambient_config" ]]; then
    echo "Error: OPENCODE_CONFIG is set but the file was not found: $ambient_config" >&2
    return 1
  fi
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required to merge OpenCode config." >&2
    return 1
  fi
  if ! jq empty "$ambient_config" >/dev/null 2>&1; then
    ambient_config_json_temp="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-jsonc-XXXXXX")"
    if ! ralph_run_plan_opencode_jsonc_to_json "$ambient_config" "$ambient_config_json_temp"; then
      ralph_mcp_cleanup_config "$ambient_config_json_temp"
      echo "Error: existing OpenCode config is invalid JSON: $ambient_config" >&2
      return 1
    fi
    if ! jq empty "$ambient_config_json_temp" >/dev/null 2>&1; then
      ralph_mcp_cleanup_config "$ambient_config_json_temp"
      echo "Error: converted OpenCode config is invalid JSON: $ambient_config" >&2
      return 1
    fi
    ralph_mcp_overlay_record_temp_file "$ambient_config_json_temp"
    ambient_config_json="$ambient_config_json_temp"
  fi
  RALPH_OPENCODE_CONFIG_SOURCE_DESC="$config_source_desc"
  export RALPH_OPENCODE_CONFIG_SOURCE_DESC
  printf '%s' "$ambient_config_json"
}

run_plan_invoke_opencode_config_prepare() {
  local workspace="${WORKSPACE:-}"
  local need_mcp=0
  local need_hooks=0
  local want_cache_key=0
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

  local provider_id
  provider_id="$(ralph_opencode_provider_id_from_selected_model "$selected_model")"
  if [[ -n "$provider_id" && "${RALPH_OPENCODE_SET_CACHE_KEY:-1}" != "0" ]]; then
    want_cache_key=1
  fi

  if [[ "$need_mcp" -eq 0 && "$need_hooks" -eq 0 && "$want_cache_key" -eq 0 ]]; then
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

  local working_config
  working_config="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-config-XXXXXX")"
  cp "$ambient_config_json" "$working_config"
  ralph_mcp_overlay_record_temp_file "$working_config"

  if [[ "$want_cache_key" -eq 1 ]]; then
    local provider_field_type jq_err
    provider_field_type="$(jq -r '.provider | type' "$working_config" 2>/dev/null || true)"
    if [[ "$provider_field_type" != "null" && "$provider_field_type" != "object" ]]; then
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "OpenCode setCacheKey: skipping injection (ambient provider field type is ${provider_field_type}, expected null or object)"
      fi
    else
      local provider_has_set_cache_key="0"
      provider_has_set_cache_key="$(ralph_opencode_provider_set_cache_key_present "$working_config" "$provider_id" 2>/dev/null || true)"
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
        else
          echo "Warning: OpenCode setCacheKey jq merge failed: $jq_err" >&2
          ralph_mcp_cleanup_config "$cache_key_config"
        fi
      fi

      local should_inject_prompt_cache_key=0
      if [[ -n "$selected_model_model_id" && " $prompt_cache_passthrough_providers " == *" $provider_id "* ]]; then
        should_inject_prompt_cache_key=1
      fi
      if [[ "$should_inject_prompt_cache_key" -eq 1 ]]; then
        local prompt_cache_present="0"
        prompt_cache_present="$(ralph_opencode_model_prompt_cache_key_present "$working_config" "$provider_id" "$selected_model_model_id" 2>/dev/null || true)"
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
          else
            echo "Warning: OpenCode prompt_cache_key jq merge failed: $jq_err" >&2
            ralph_mcp_cleanup_config "$prompt_cache_config"
          fi
        fi
      fi
    fi
  fi

  if [[ "$need_mcp" -eq 1 ]]; then
    local ralph_config
    ralph_config="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-mcp-XXXXXX")"
    if ! ralph_mcp_generate_config opencode "$ralph_config" "$workspace"; then
      ralph_mcp_cleanup_config "$ralph_config"
      ralph_mcp_cleanup_config "$working_config"
      echo "Error: failed to generate OpenCode MCP config." >&2
      return 1
    fi
    ralph_mcp_overlay_record_temp_file "$ralph_config"
    local merged_mcp
    merged_mcp="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-mcp-merged-XXXXXX")"
    if ! jq -c --slurpfile ralph "$ralph_config" \
      '.mcp = ((.mcp // {}) + {ralph: $ralph[0].mcp.ralph})' \
      "$working_config" > "$merged_mcp" 2>/dev/null; then
      ralph_mcp_cleanup_config "$ralph_config"
      ralph_mcp_cleanup_config "$working_config"
      ralph_mcp_cleanup_config "$merged_mcp"
      echo "Error: failed to merge Ralph MCP config into OPENCODE_CONFIG." >&2
      return 1
    fi
    ralph_mcp_cleanup_config "$ralph_config"
    ralph_mcp_cleanup_config "$working_config"
    working_config="$merged_mcp"
    ralph_mcp_overlay_record_temp_file "$working_config"
    config_modified=1
  fi

  local final_cache_settings
  final_cache_settings="$(ralph_opencode_detect_cache_settings_in_config "$working_config" 2>/dev/null || true)"
  if [[ "${RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED:-0}" == "1" || "${RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS:-0}" == "1" ]]; then
    final_cache_settings="1"
  fi
  RALPH_OPENCODE_FINAL_CACHE_SETTINGS="${final_cache_settings:-0}"
  export RALPH_OPENCODE_FINAL_CACHE_SETTINGS
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
      (cd "$agent_ws" && OPENCODE_CONFIG="$opencode_config_path" "$cli" "${args[@]}")
    else
      (cd "$agent_ws" && "$cli" "${args[@]}")
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
