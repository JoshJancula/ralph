#!/usr/bin/env bash
# Jev key resolution and storage backends. Source only.
#
# Public interface (Section D):
#   jev_key_resolve        -> stdout the key. 0 | 1 if none / configured-backend failure.
#   jev_key_source         -> stdout source token: env|env-file|command|keychain|file|none
#   jev_key_set_command <command_string>  -> 0. Stores a command, never a secret.
#   jev_key_set_keychain   -> 0. Reads key from stdin into OS keychain.
#   jev_key_set_file       -> 0. Reads key from stdin into a 0600 plaintext file.
#   jev_key_clear          -> 0. Removes every stored backend.
#   jev_key_status         -> stdout human-readable provenance. NEVER prints the key.
#
# Resolution chain (Section G, first hit wins; never fall back after a hit):
#   (1) env       TYPESAFE_API_KEY already exported
#   (2) env-file  TYPESAFE_API_KEY parsed from the workspace dotenv file (carve-out)
#   (3) command   stored command stdout
#   (4) keychain  OS keychain (skipped silently when tooling absent)
#   (5) file      plaintext 0600 under Ralph global config dir (last resort)
#
# Config lives beside models.json via ralph_model_store_config_dir — NEVER under
# .ralph-workspace/ (that tree is snapshotted into run artifacts).

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${RALPH_JEV_KEY_STORE_LOADED:-}" ]]; then
  return 0
fi
RALPH_JEV_KEY_STORE_LOADED=1

_JEV_KEY_STORE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../select-model/model-store.sh
source "$_JEV_KEY_STORE_LIB_DIR/../select-model/model-store.sh"

JEV_KEY_STORE_SCHEMA_VERSION=1
JEV_KEYCHAIN_SERVICE="ralph.jev"
JEV_KEYCHAIN_ACCOUNT="TYPESAFE_API_KEY"

# ---------------------------------------------------------------------------
# Config paths and JSON shape (mirror model-store defaults/normalize)
# ---------------------------------------------------------------------------

jev_key_store_config_dir() {
  ralph_model_store_config_dir
}

jev_key_store_credentials_path() {
  printf '%s/jev-credentials.json\n' "$(jev_key_store_config_dir)"
}

jev_key_store_file_path() {
  printf '%s/jev-api-key\n' "$(jev_key_store_config_dir)"
}

jev_key_store_defaults_json() {
  jq -nc --argjson schema_version "$JEV_KEY_STORE_SCHEMA_VERSION" '{
    schema_version: $schema_version,
    command: "",
    keychain: false,
    file: false
  }'
}

jev_key_store_normalize_json() {
  local raw_json="${1:-}"
  local defaults
  defaults="$(jev_key_store_defaults_json)"

  jq -nc --argjson defaults "$defaults" --argjson raw "$raw_json" '
    {
      schema_version: $defaults.schema_version,
      command: (
        if ($raw.command | type) == "string" then $raw.command
        else ""
        end
      ),
      keychain: (
        if ($raw.keychain | type) == "boolean" then $raw.keychain
        else false
        end
      ),
      file: (
        if ($raw.file | type) == "boolean" then $raw.file
        else false
        end
      )
    }
  '
}

jev_key_store_read() {
  command -v jq >/dev/null 2>&1 || return 1

  local path defaults raw
  defaults="$(jev_key_store_defaults_json)"
  path="$(jev_key_store_credentials_path)"

  if [[ ! -f "$path" ]]; then
    printf '%s' "$defaults"
    return 0
  fi

  raw="$(jq -c '.' "$path" 2>/dev/null)" || {
    printf '%s' "$defaults"
    return 0
  }

  jev_key_store_normalize_json "$raw"
}

# Secure write: umask inside a subshell so it never leaks to the caller.
_jev_key_store_write_secure() {
  local path="$1"
  local contents="$2"
  local dir
  dir="$(dirname "$path")"
  mkdir -p "$dir" || return 1
  (
    umask 077
    { printf '%s' "$contents"; } >"$path"
  ) || return 1
  chmod 600 "$path" 2>/dev/null || true
  return 0
}

jev_key_store_write_json() {
  local json="${1:-}"
  command -v jq >/dev/null 2>&1 || return 1
  [[ -n "$json" ]] || return 1

  local normalized path
  normalized="$(jev_key_store_normalize_json "$json")" || return 1
  path="$(jev_key_store_credentials_path)"
  _jev_key_store_write_secure "$path" "$(jq -c '.' <<<"$normalized")"
}

_jev_key_workspace_root() {
  if [[ -n "${RALPH_PROJECT_ROOT:-}" ]]; then
    printf '%s\n' "${RALPH_PROJECT_ROOT%/}"
    return 0
  fi
  if [[ -n "${RALPH_MCP_WORKSPACE:-}" ]]; then
    printf '%s\n' "${RALPH_MCP_WORKSPACE%/}"
    return 0
  fi
  printf '%s\n' "${PWD%/}"
}

# ---------------------------------------------------------------------------
# Dotenv carve-out: PARSE only, never source/eval. Extract TYPESAFE_API_KEY only.
# Workspace dotenv path only (exactly <workspace>/.env). Honor RALPH_JEV_ENV_FILE=0.
# Never echo the value.
# ---------------------------------------------------------------------------

_jev_key_env_file_enabled() {
  [[ "${RALPH_JEV_ENV_FILE:-1}" != "0" ]]
}

_jev_key_env_file_path() {
  printf '%s/.env\n' "$(_jev_key_workspace_root)"
}

# Parse (not source) the workspace dotenv file for TYPESAFE_API_KEY. Prints value or returns 1.
# Values are treated as literals — quote stripping only; no expansion or execution.
_jev_key_parse_env_typesafe_key() {
  local path="$1"
  local line val

  [[ -f "$path" ]] || return 1
  [[ -r "$path" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    # Trim leading whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      ''|\#*) continue ;;
    esac
    # Optional "export " prefix; exact variable name only.
    if [[ "$line" == export[[:space:]]* ]]; then
      line="${line#export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi
    [[ "$line" == TYPESAFE_API_KEY=* ]] || continue
    val="${line#TYPESAFE_API_KEY=}"
    # Strip matching surrounding quotes only. Do not expand or evaluate.
    if [[ "$val" =~ ^\"(.*)\"[[:space:]]*$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "$val" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
      val="${BASH_REMATCH[1]}"
    else
      # Unquoted: trim trailing whitespace only.
      val="${val%"${val##*[![:space:]]}"}"
    fi
    [[ -n "$val" ]] || return 1
    printf '%s' "$val"
    return 0
  done <"$path"
  return 1
}

_jev_key_env_file_has_key() {
  local path val
  path="$(_jev_key_env_file_path)"
  val="$(_jev_key_parse_env_typesafe_key "$path" 2>/dev/null)" || return 1
  [[ -n "$val" ]]
}

# ---------------------------------------------------------------------------
# Keychain helpers (optional-if-present; skip silently when absent)
# ---------------------------------------------------------------------------

_jev_key_keychain_available() {
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      command -v security >/dev/null 2>&1
      ;;
    *)
      command -v secret-tool >/dev/null 2>&1
      ;;
  esac
}

_jev_key_keychain_set() {
  local key="$1"
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      # -U updates if present. Password via -w; never pass as a positional after --.
      security delete-generic-password -s "$JEV_KEYCHAIN_SERVICE" -a "$JEV_KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
      security add-generic-password -s "$JEV_KEYCHAIN_SERVICE" -a "$JEV_KEYCHAIN_ACCOUNT" -w "$key" >/dev/null 2>&1
      ;;
    *)
      printf '%s' "$key" | secret-tool store --label='Ralph Jev API key' \
        service "$JEV_KEYCHAIN_SERVICE" account "$JEV_KEYCHAIN_ACCOUNT" >/dev/null 2>&1
      ;;
  esac
}

_jev_key_keychain_get() {
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      security find-generic-password -s "$JEV_KEYCHAIN_SERVICE" -a "$JEV_KEYCHAIN_ACCOUNT" -w 2>/dev/null
      ;;
    *)
      secret-tool lookup service "$JEV_KEYCHAIN_SERVICE" account "$JEV_KEYCHAIN_ACCOUNT" 2>/dev/null
      ;;
  esac
}

_jev_key_keychain_clear() {
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      if command -v security >/dev/null 2>&1; then
        security delete-generic-password -s "$JEV_KEYCHAIN_SERVICE" -a "$JEV_KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
      fi
      ;;
    *)
      if command -v secret-tool >/dev/null 2>&1; then
        secret-tool clear service "$JEV_KEYCHAIN_SERVICE" account "$JEV_KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Command backend: execute stored command string with a timeout
# ---------------------------------------------------------------------------

_jev_key_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout'
  fi
}

_jev_key_command_timeout_secs() {
  local ms="${RALPH_JEV_TIMEOUT_MS:-4000}"
  local secs=$(( (ms + 999) / 1000 ))
  [[ "$secs" -lt 1 ]] && secs=1
  printf '%s\n' "$secs"
}

# Run stored command; stdout is the key. Non-zero exit or empty stdout = failure.
_jev_key_run_command() {
  local cmd="$1"
  local secs tbin out ec
  secs="$(_jev_key_command_timeout_secs)"
  tbin="$(_jev_key_timeout_bin)"

  if [[ -n "$tbin" ]]; then
    out="$("$tbin" "$secs" bash -c "$cmd" 2>/dev/null)"
    ec=$?
  else
    out="$(bash -c "$cmd" 2>/dev/null)"
    ec=$?
  fi

  # Strip a single trailing newline from command output.
  out="${out%$'\n'}"
  [[ "$ec" -eq 0 && -n "$out" ]] || return 1
  printf '%s' "$out"
  return 0
}

_jev_key_read_stdin_key() {
  local key
  # Preserve content; drop one trailing newline so `printf '%s\n' | set` works.
  key="$(cat)"
  key="${key%$'\n'}"
  [[ -n "$key" ]] || return 1
  printf '%s' "$key"
}

_jev_key_set_source() {
  RALPH_JEV_KEY_SOURCE="${1:-none}"
  export RALPH_JEV_KEY_SOURCE
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

jev_key_source() {
  local cfg cmd

  if [[ -n "${TYPESAFE_API_KEY:-}" ]]; then
    printf 'env\n'
    return 0
  fi

  if _jev_key_env_file_enabled && _jev_key_env_file_has_key; then
    printf 'env-file\n'
    return 0
  fi

  cfg="$(jev_key_store_read 2>/dev/null)" || cfg="$(jev_key_store_defaults_json 2>/dev/null || true)"
  if [[ -n "$cfg" ]]; then
    cmd="$(jq -r '.command // empty' <<<"$cfg" 2>/dev/null || true)"
    if [[ -n "$cmd" ]]; then
      printf 'command\n'
      return 0
    fi
    if [[ "$(jq -r '.keychain // false' <<<"$cfg" 2>/dev/null)" == "true" ]] && _jev_key_keychain_available; then
      printf 'keychain\n'
      return 0
    fi
    if [[ "$(jq -r '.file // false' <<<"$cfg" 2>/dev/null)" == "true" ]]; then
      printf 'file\n'
      return 0
    fi
  fi

  printf 'none\n'
  return 0
}

jev_key_resolve() {
  local cfg cmd path key val

  # 1. env
  if [[ -n "${TYPESAFE_API_KEY:-}" ]]; then
    _jev_key_set_source env
    printf '%s' "$TYPESAFE_API_KEY"
    return 0
  fi

  # 2. env-file (parse only; RALPH_JEV_ENV_FILE=0 opts out)
  if _jev_key_env_file_enabled; then
    path="$(_jev_key_env_file_path)"
    if [[ -f "$path" ]]; then
      if val="$(_jev_key_parse_env_typesafe_key "$path" 2>/dev/null)" && [[ -n "$val" ]]; then
        _jev_key_set_source env-file
        printf '%s' "$val"
        return 0
      fi
      # File present but no usable key: not a "hit"; continue the chain.
    fi
  fi

  cfg="$(jev_key_store_read 2>/dev/null)" || {
    _jev_key_set_source none
    return 1
  }

  # 3. command — configured means non-empty command; failure does not fall through.
  cmd="$(jq -r '.command // empty' <<<"$cfg" 2>/dev/null || true)"
  if [[ -n "$cmd" ]]; then
    _jev_key_set_source command
    if key="$(_jev_key_run_command "$cmd")" && [[ -n "$key" ]]; then
      printf '%s' "$key"
      return 0
    fi
    return 1
  fi

  # 4. keychain — skip silently when tooling absent; if configured+available, no fallback.
  if [[ "$(jq -r '.keychain // false' <<<"$cfg" 2>/dev/null)" == "true" ]]; then
    if _jev_key_keychain_available; then
      _jev_key_set_source keychain
      if key="$(_jev_key_keychain_get)" && [[ -n "$key" ]]; then
        key="${key%$'\n'}"
        printf '%s' "$key"
        return 0
      fi
      return 1
    fi
    # Tooling absent: skip silently to next backend.
  fi

  # 5. file — configured means credentials.file true; failure does not fall through.
  if [[ "$(jq -r '.file // false' <<<"$cfg" 2>/dev/null)" == "true" ]]; then
    _jev_key_set_source file
    path="$(jev_key_store_file_path)"
    if [[ -f "$path" && -r "$path" ]]; then
      key="$(cat "$path" 2>/dev/null || true)"
      key="${key%$'\n'}"
      if [[ -n "$key" ]]; then
        printf '%s' "$key"
        return 0
      fi
    fi
    return 1
  fi

  _jev_key_set_source none
  return 1
}

jev_key_set_command() {
  local cmd_string="${1:-}"
  local cfg

  if [[ -z "$cmd_string" ]]; then
    echo "Error: jev_key_set_command requires a non-empty command string." >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to store Jev credential config." >&2
    return 1
  }

  cfg="$(jev_key_store_read)" || return 1
  cfg="$(jq -c --arg cmd "$cmd_string" '.command = $cmd' <<<"$cfg")" || return 1
  jev_key_store_write_json "$cfg"
}

jev_key_set_keychain() {
  if [[ $# -gt 0 ]]; then
    echo "Error: pass the key on stdin, not as an argument (avoids process list and shell history)." >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to store Jev credential config." >&2
    return 1
  }
  if ! _jev_key_keychain_available; then
    echo "Error: no keychain backend available (macOS security or Linux secret-tool)." >&2
    return 1
  fi

  local key cfg
  key="$(_jev_key_read_stdin_key)" || {
    echo "Error: empty key on stdin." >&2
    return 1
  }
  _jev_key_keychain_set "$key" || {
    echo "Error: failed to store key in keychain." >&2
    return 1
  }

  cfg="$(jev_key_store_read)" || return 1
  cfg="$(jq -c '.keychain = true' <<<"$cfg")" || return 1
  jev_key_store_write_json "$cfg"
}

jev_key_set_file() {
  if [[ $# -gt 0 ]]; then
    echo "Error: pass the key on stdin, not as an argument (avoids process list and shell history)." >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to store Jev credential config." >&2
    return 1
  }

  local key path cfg
  key="$(_jev_key_read_stdin_key)" || {
    echo "Error: empty key on stdin." >&2
    return 1
  }
  path="$(jev_key_store_file_path)" || return 1
  _jev_key_store_write_secure "$path" "$key" || return 1

  echo "Warning: stored a plaintext API key at $path (mode 600). Prefer keychain or a credential command when available." >&2

  cfg="$(jev_key_store_read)" || return 1
  cfg="$(jq -c '.file = true' <<<"$cfg")" || return 1
  jev_key_store_write_json "$cfg"
}

jev_key_clear() {
  local cfg path
  command -v jq >/dev/null 2>&1 || return 1

  _jev_key_keychain_clear

  path="$(jev_key_store_file_path 2>/dev/null || true)"
  if [[ -n "$path" && -e "$path" ]]; then
    rm -f "$path" 2>/dev/null || true
  fi

  cfg="$(jev_key_store_defaults_json)" || return 1
  jev_key_store_write_json "$cfg" || return 1
  _jev_key_set_source none
  return 0
}

# NEVER print the key value itself — provenance and locations only.
jev_key_status() {
  local src cfg cmd path

  src="$(jev_key_source)"
  printf 'source: %s\n' "$src"

  case "$src" in
    env)
      printf 'location: TYPESAFE_API_KEY (environment)\n'
      ;;
    env-file)
      printf 'location: %s\n' "$(_jev_key_env_file_path)"
      ;;
    command)
      cfg="$(jev_key_store_read 2>/dev/null)" || true
      cmd="$(jq -r '.command // empty' <<<"$cfg" 2>/dev/null || true)"
      printf 'command: %s\n' "$cmd"
      ;;
    keychain)
      printf 'location: service=%s account=%s\n' "$JEV_KEYCHAIN_SERVICE" "$JEV_KEYCHAIN_ACCOUNT"
      ;;
    file)
      path="$(jev_key_store_file_path 2>/dev/null || true)"
      printf 'location: %s\n' "$path"
      ;;
    none)
      ;;
  esac
  return 0
}
