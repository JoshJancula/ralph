#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

PLAN_NAMESPACE="PLAN54"
PLAN_ARTIFACT_DIR="$REPO_ROOT/.ralph-workspace/artifacts/$PLAN_NAMESPACE"
SMOKE_LOG="$PLAN_ARTIFACT_DIR/opencode-cache-smoke.log"
SMOKE_CONFIG="$PLAN_ARTIFACT_DIR/opencode-cache-smoke.config.json"
MODEL="ollama-cloud/glm-5.1"
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

@test "OpenCode real cache smoke (opt-in RALPH_OPENCODE_REAL_CACHE_SMOKE=1)" {
  if [[ "${RALPH_OPENCODE_REAL_CACHE_SMOKE:-0}" != "1" ]]; then
    skip "set RALPH_OPENCODE_REAL_CACHE_SMOKE=1 to run the real OpenCode cache smoke"
  fi

  command -v opencode >/dev/null || skip "opencode CLI not found"
  command -v jq >/dev/null || skip "jq required"

  mkdir -p "$PLAN_ARTIFACT_DIR"
  rm -f "$SMOKE_LOG" "$SMOKE_CONFIG"

  cat <<'EOF' >"$SMOKE_CONFIG"
{
  "$schema": "https://opencode.ai/config.json",
  "model": "ollama-cloud/glm-5.1",
  "provider": {
    "ollama": {
      "options": {
        "setCacheKey": true
      }
    }
  }
}
EOF

  local first_run="$TEST_TMPDIR/opencode-cache-smoke-1.json"
  local second_run="$TEST_TMPDIR/opencode-cache-smoke-2.json"
  local run_cmd=(opencode run --format json --model "$MODEL" "$PROMPT")

  export OPENCODE_CONFIG="$SMOKE_CONFIG"

  if ! "${run_cmd[@]}" >"$first_run"; then
    skip "first OpenCode invocation failed; ensure CLI, network, and authentication are available"
  fi

  if ! "${run_cmd[@]}" >"$second_run"; then
    skip "second OpenCode invocation failed; ensure CLI, network, and authentication are available"
  fi

  unset OPENCODE_CONFIG

  cat "$first_run" >"$SMOKE_LOG"
  printf '\n' >>"$SMOKE_LOG"
  cat "$second_run" >>"$SMOKE_LOG"

  [ -s "$second_run" ] || skip "second OpenCode invocation produced no output"

  local cache_total
  cache_total="$(cache_tokens_total "$second_run")"
  cache_total="${cache_total:-0}"

  if [ "$cache_total" -le 0 ]; then
    printf 'OpenCode cache smoke failed: expected cache read/write tokens >0 but saw %s\nConfig snapshot: %s\nRaw events: %s\n' "$cache_total" "$SMOKE_CONFIG" "$SMOKE_LOG" >&2
    return 1
  fi
}
