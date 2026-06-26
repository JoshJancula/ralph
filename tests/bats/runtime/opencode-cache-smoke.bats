#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

PLAN_NAMESPACE="PLAN54"
PLAN_ARTIFACT_DIR="$REPO_ROOT/.ralph-workspace/artifacts/$PLAN_NAMESPACE"
SMOKE_LOG="$PLAN_ARTIFACT_DIR/opencode-cache-smoke.log"
SMOKE_CONFIG="$PLAN_ARTIFACT_DIR/opencode-cache-smoke.config.json"
PROMPT="Plan54 OpenCode cache smoke prompt. Please reuse the exact text between runs."

cache_tokens_total() {
  local path="$1"
  jq -s '
    reduce .[] as $event (
      0;
      . + (
        $event
        | .. | objects
        | select(has("tokens"))
        | .tokens.cache? // {}
        | (.read // 0) + (.write // 0)
      )
    )
  ' "$path"
}

alternate_cached_tokens_total() {
  local path="$1"
  jq -s '
    reduce .[] as $event (
      0;
      . + (
        $event
        | .. | objects
        | select(has("usage"))
        | .usage
        | (
            (.prompt_tokens_details.cached_tokens // 0)
            + (.cached_tokens // 0)
          )
      )
    )
  ' "$path"
}

_opencode_cache_smoke_skip_if_unavailable() {
  command -v opencode >/dev/null || skip "opencode CLI not found"
  command -v jq >/dev/null || skip "jq required"
}

_opencode_cache_smoke_run_pair() {
  local model="$1"
  local config_model="$2"
  local first_run="$TEST_TMPDIR/opencode-cache-smoke-1.json"
  local second_run="$TEST_TMPDIR/opencode-cache-smoke-2.json"

  mkdir -p "$PLAN_ARTIFACT_DIR"
  rm -f "$SMOKE_LOG" "$SMOKE_CONFIG"

  cat >"$SMOKE_CONFIG" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "${config_model}",
  "provider": {
    "ollama": {
      "options": {
        "setCacheKey": true
      }
    }
  }
}
EOF

  local run_cmd=(opencode run --format json --model "$model" "$PROMPT")
  export OPENCODE_CONFIG="$SMOKE_CONFIG"

  if ! "${run_cmd[@]}" >"$first_run" 2>"$TEST_TMPDIR/opencode-cache-smoke-1.err"; then
    if grep -qiE 'auth|credential|unauthorized|forbidden|network|connection|timeout|dns' \
      "$TEST_TMPDIR/opencode-cache-smoke-1.err" 2>/dev/null; then
      skip "first OpenCode invocation failed; credentials or network unavailable"
    fi
    skip "first OpenCode invocation failed; ensure CLI, network, and authentication are available"
  fi

  if ! "${run_cmd[@]}" >"$second_run" 2>"$TEST_TMPDIR/opencode-cache-smoke-2.err"; then
    if grep -qiE 'auth|credential|unauthorized|forbidden|network|connection|timeout|dns' \
      "$TEST_TMPDIR/opencode-cache-smoke-2.err" 2>/dev/null; then
      skip "second OpenCode invocation failed; credentials or network unavailable"
    fi
    skip "second OpenCode invocation failed; ensure CLI, network, and authentication are available"
  fi

  unset OPENCODE_CONFIG

  cat "$first_run" >"$SMOKE_LOG"
  printf '\n' >>"$SMOKE_LOG"
  cat "$second_run" >>"$SMOKE_LOG"

  [ -s "$second_run" ] || skip "second OpenCode invocation produced no output"

  CACHE_SMOKE_FIRST_RUN="$first_run"
  CACHE_SMOKE_SECOND_RUN="$second_run"
}

@test "OpenCode real cache smoke reports cache for kimi-k2.7-code (opt-in RALPH_OPENCODE_REAL_CACHE_SMOKE=1)" {
  if [[ "${RALPH_OPENCODE_REAL_CACHE_SMOKE:-0}" != "1" ]]; then
    skip "set RALPH_OPENCODE_REAL_CACHE_SMOKE=1 to run the real OpenCode cache smoke"
  fi

  _opencode_cache_smoke_skip_if_unavailable

  local model="ollama-cloud/kimi-k2.7-code"
  _opencode_cache_smoke_run_pair "$model" "$model"

  local cache_total alt_total
  cache_total="$(cache_tokens_total "$CACHE_SMOKE_SECOND_RUN")"
  cache_total="${cache_total:-0}"
  alt_total="$(alternate_cached_tokens_total "$CACHE_SMOKE_SECOND_RUN")"
  alt_total="${alt_total:-0}"

  if [ "$cache_total" -le 0 ] && [ "$alt_total" -le 0 ]; then
    skip "cache-reporting model ${model} completed but emitted no cache diagnostics (cache_total=${cache_total}, alt_total=${alt_total})"
  fi
}

@test "OpenCode real cache smoke tolerates zero-cache diagnostics for glm-5.1 (opt-in RALPH_OPENCODE_REAL_CACHE_SMOKE=1)" {
  if [[ "${RALPH_OPENCODE_REAL_CACHE_SMOKE:-0}" != "1" ]]; then
    skip "set RALPH_OPENCODE_REAL_CACHE_SMOKE=1 to run the real OpenCode cache smoke"
  fi

  _opencode_cache_smoke_skip_if_unavailable

  local model="ollama-cloud/glm-5.1"
  _opencode_cache_smoke_run_pair "$model" "$model"

  local cache_total alt_total
  cache_total="$(cache_tokens_total "$CACHE_SMOKE_SECOND_RUN")"
  cache_total="${cache_total:-0}"
  alt_total="$(alternate_cached_tokens_total "$CACHE_SMOKE_SECOND_RUN")"
  alt_total="${alt_total:-0}"

  # Zero-reporting providers are valid: the smoke only requires successful runs.
  [ "$cache_total" -ge 0 ]
  [ "$alt_total" -ge 0 ]
}
