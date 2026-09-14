#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

KILLSWITCH_CORE="$REPO_ROOT/bundle/.ralph/bash-lib/killswitch/killswitch-core.sh"

setup() {
  RH="$(mktemp -d)"
  WS="$(mktemp -d)"
  mkdir -p "$RH/bundle/.ralph/bash-lib/config"
  mkdir -p "$RH/bundle/.ralph/bash-lib/killswitch"
  mkdir -p "$RH/bundle/.ralph/python"
  cp "$REPO_ROOT/bundle/.ralph/killswitch.json" "$RH/bundle/.ralph/killswitch.json"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/config/safety-cli.sh" \
    "$RH/bundle/.ralph/bash-lib/config/safety-cli.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/help-render.sh" \
    "$RH/bundle/.ralph/bash-lib/help-render.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/killswitch/killswitch-config.sh" \
    "$RH/bundle/.ralph/bash-lib/killswitch/killswitch-config.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/killswitch/killswitch-validator.sh" \
    "$RH/bundle/.ralph/bash-lib/killswitch/killswitch-validator.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/killswitch/killswitch-evaluate.sh" \
    "$RH/bundle/.ralph/bash-lib/killswitch/killswitch-evaluate.sh"
  cp "$REPO_ROOT/bundle/.ralph/python/killswitch_config.py" \
    "$RH/bundle/.ralph/python/killswitch_config.py"

  SHIM="$RH/ralph"
  awk "/cat > \"\\\$tmp\" <<'SHIM'/{f=1;next} /^SHIM\$/{f=0} f" "$REPO_ROOT/install.sh" > "$SHIM"
  chmod +x "$SHIM"
  # Last in setup(): teardown() in these files dereferences variables setup
  # creates, so skipping before they exist fails teardown under `set -u` and
  # bats drops the test with no TAP line at all instead of reporting a skip.
  bats_skip_known_ci_flakes
}

teardown() {
  rm -rf "$RH" "$WS"
}

write_workspace_killswitch() {
  mkdir -p "$WS/.ralph-workspace"
  cat >"$WS/.ralph-workspace/killswitch.json"
}

# Minimal schema-v2 killswitch body (caller may append override fields via sed/rewrite).
minimal_valid_killswitch_json() {
  cat <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "banned_tools": [],
  "tool_denylist": [],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF
}

run_killswitch_core() {
  (
    cd "$WS" || exit 1
    export WORKSPACE="$WS"
    export RALPH_HOME="$RH"
    export RALPH_PROJECT_ROOT="$WS"
    export RALPH_PLAN_WORKSPACE_ROOT="$WS/.ralph-workspace"
    export RALPH_AGENT_WORKSPACE="$WS"
    export RALPH_PLAN_KEY="${RALPH_PLAN_KEY:-ks-core}"
    export KILLSWITCH_RUNNER_PID=""
    # Fail closed: invalid/unreadable config must abort before any follow-on call.
    source "$KILLSWITCH_CORE" || exit $?
    "$@"
  )
}

# Source loader only (no auto merge/export) for isolated load tests.
# Usage: run_killswitch_loader 'shell script...'
run_killswitch_loader() {
  local script="${1:-}"
  (
    cd "$WS" || exit 1
    export WORKSPACE="$WS"
    export RALPH_HOME="$RH"
    export RALPH_PROJECT_ROOT="$WS"
    export RALPH_PLAN_WORKSPACE_ROOT="${RALPH_PLAN_WORKSPACE_ROOT:-$WS/.ralph-workspace}"
    export RALPH_AGENT_WORKSPACE="$WS"
    # Reset load guards so repeated bats cases re-enter the library.
    unset RALPH_KILLSWITCH_CONFIG_LOADED RALPH_KILLSWITCH_CORE_LOADED
    unset RALPH_KILLSWITCH_CORE_LOAD_STATUS
    unset RALPH_KILLSWITCH_EVALUATE_LOADED RALPH_KILLSWITCH_VALIDATOR_LOADED
    unset RALPH_KILLSWITCH_KILLER_LOADED
    # shellcheck source=/dev/null
    source "$REPO_ROOT/bundle/.ralph/bash-lib/killswitch/killswitch-config.sh"
    eval "$script"
  )
}

killswitch_eval_then_apply() {
  killswitch_evaluate "$1" >/dev/null
  printf 'EVAL=%s\n' "$KILLSWITCH_DECISION"
  killswitch_apply_decision "$KILLSWITCH_DECISION"
}

killswitch_report_sentinel_freshness() {
  export KILLSWITCH_RUN_START_TS="$1"
  local stale_label="$2"
  local fresh_label="$3"
  local sentinel
  sentinel="$(killswitch_sentinel_path)"
  if killswitch_sentinel_is_stale "$sentinel"; then
    printf '%s\n' "$stale_label"
  else
    printf '%s\n' "$fresh_label"
  fi
  if killswitch_sentinel_should_abort "$sentinel"; then
    printf 'abort\n'
  else
    printf 'ignore\n'
  fi
}

run_ralph() {
  (
    cd "$WS" || exit 1
    RALPH_HOME="$RH" bash "$SHIM" "$@"
  )
}

run_safety_cli() {
  (
    cd "$WS" || exit 1
    RALPH_HOME="$RH" bash "$RH/bundle/.ralph/bash-lib/config/safety-cli.sh" "$@"
  )
}

@test "ralph --bundle-path prints bundled .ralph directory" {
  run run_ralph --bundle-path
  [ "$status" -eq 0 ]
  [ "$output" = "$RH/bundle/.ralph" ]
}

@test "ralph --help lists top-level safety command" {
  run run_ralph --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"safety"* ]]
}

@test "ralph safety --help lists status and validate" {
  run run_ralph safety --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"validate"* ]]
  [[ "$output" == *"check"* ]]
  [[ "$output" == *"init"* ]]
  [[ "$output" == *"edit"* ]]
}

@test "old route: ralph config killswitch exits 2 with exact replacement" {
  run run_ralph config killswitch
  [ "$status" -eq 2 ]
  [ "$output" = "Use: ralph safety <status|validate|check|init|edit>" ]
}

@test "old route: ralph config killswitch status is rejected" {
  run run_ralph config killswitch status
  [ "$status" -eq 2 ]
  [ "$output" = "Use: ralph safety <status|validate|check|init|edit>" ]
}

@test "ralph safety status shows bundle source and precedence" {
  run run_ralph safety status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Winning source: bundle"* ]]
  [[ "$output" == *"$RH/bundle/.ralph/killswitch.json"* ]]
  [[ "$output" == *"Precedence"* ]]
  [[ "$output" == *"enabled:"* ]]
  [[ "$output" == *"dryRun:"* ]]
  [[ "$output" == *"Counts:"* ]]
}

@test "ralph safety status JSON has exact schema fields and stable keys" {
  run run_ralph safety status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .schemaVersion == 1
    and (.enabled | type) == "boolean"
    and (.dryRun | type) == "boolean"
    and .source == "bundle"
    and (.path | type) == "string"
    and (.precedence | type) == "array"
    and (.precedence | length) == 4
    and .precedence[0].source == "override"
    and .precedence[1].source == "project"
    and .precedence[2].source == "global"
    and .precedence[3].source == "bundle"
    and .precedence[3].selected == true
    and (.environmentOverrides | type) == "object"
    and (.environmentOverrides | has("RALPH_BANNED_TOOLS"))
    and (.environmentOverrides | has("RALPH_KILLSWITCH_DISABLED"))
    and (.counts | type) == "object"
    and (.counts | has("bannedTools"))
    and (.counts | has("customRules"))
    and (.warnings | type) == "array"
  '
  # Key order is stable: top-level keys in fixed contract order.
  local keys
  keys="$(echo "$output" | jq -r 'keys_unsorted | join(",")')"
  [ "$keys" = "schemaVersion,enabled,dryRun,source,path,precedence,environmentOverrides,counts,warnings" ]
}

@test "ralph safety status JSON source precedence: project wins over global" {
  mkdir -p "$WS/.ralph-workspace"
  write_workspace_killswitch < <(minimal_valid_killswitch_json)
  cp "$REPO_ROOT/bundle/.ralph/killswitch.json" "$RH/killswitch.json"

  run run_ralph safety status --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.source')" = "project" ]
  [ "$(echo "$output" | jq -r '.path')" = "$WS/.ralph-workspace/killswitch.json" ]
  [ "$(echo "$output" | jq -r '.precedence[] | select(.source=="project") | .selected')" = "true" ]
  [ "$(echo "$output" | jq -r '.precedence[] | select(.source=="global") | .selected')" = "false" ]
}

@test "ralph safety status JSON reports environmentOverrides when set" {
  write_workspace_killswitch < <(minimal_valid_killswitch_json)
  run bash -c '
    cd "$1" || exit 1
    export RALPH_HOME="$2"
    export RALPH_BANNED_TOOLS="EnvTool"
    bash "$3" safety status --json
  ' _ "$WS" "$RH" "$SHIM"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.environmentOverrides.RALPH_BANNED_TOOLS')" = "EnvTool" ]
  [ "$(echo "$output" | jq -r '.counts.bannedTools')" = "1" ]
}

@test "ralph safety validate --project accepts valid config" {
  write_workspace_killswitch < <(minimal_valid_killswitch_json)
  run run_ralph safety validate --project
  [ "$status" -eq 0 ]
  [[ "$output" == *"Valid:"* ]]
  [[ "$output" == *"$WS/.ralph-workspace/killswitch.json"* ]]
}

@test "ralph safety validate --global accepts valid config" {
  cp "$REPO_ROOT/bundle/.ralph/killswitch.json" "$RH/killswitch.json"
  run run_ralph safety validate --global
  [ "$status" -eq 0 ]
  [[ "$output" == *"Valid:"* ]]
  [[ "$output" == *"$RH/killswitch.json"* ]]
}

@test "ralph safety validate --file rejects invalid config" {
  cat >"$WS/bad-killswitch.json" <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "dryRun": true,
  "banned_tools": [],
  "tool_denylist": [],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF
  run run_ralph safety validate --file "$WS/bad-killswitch.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate alias"* ]]
}

@test "ralph safety validate --project missing file exits 1 with no mutation" {
  rm -rf "$WS/.ralph-workspace"
  run run_ralph safety validate --project
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
  [ ! -e "$WS/.ralph-workspace" ]
  [ ! -e "$WS/.ralph-workspace/killswitch.json" ]
}

@test "ralph safety status and validate make no mutation" {
  local before after
  before="$(find "$WS" "$RH" -type f 2>/dev/null | LC_ALL=C sort | cksum)"
  run run_ralph safety status
  [ "$status" -eq 0 ]
  run run_ralph safety status --json
  [ "$status" -eq 0 ]
  run run_ralph safety validate
  [ "$status" -eq 0 ]
  run run_ralph safety validate --file "$RH/bundle/.ralph/killswitch.json"
  [ "$status" -eq 0 ]
  after="$(find "$WS" "$RH" -type f 2>/dev/null | LC_ALL=C sort | cksum)"
  [ "$before" = "$after" ]
  [ ! -e "$WS/.ralph-workspace/killswitch.json" ]
}

@test "ralph safety check denies matched rule via production evaluator" {
  run run_ralph safety check --command 'sudo ls /tmp'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Outcome: deny"* ]]
  [[ "$output" == *"Matched rule: no_sudo"* ]]
  [[ "$output" == *"Winning source: bundle"* ]]
  [[ "$output" == *"Precedence"* ]]
  [[ "$output" == *"Dry-run:"* ]]
  [[ "$output" == *"effect:"* ]]
}

@test "ralph safety check no match allows with null matchedRule JSON" {
  run run_ralph safety check --command 'echo hello' --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.outcome')" = "allow" ]
  [ "$(echo "$output" | jq -r '.matchedRule')" = "null" ]
  echo "$output" | jq -e '.matchedRule == null'
}

@test "ralph safety check JSON has exact schema fields and stable nulls" {
  run run_ralph safety check --command 'git push --force origin main' --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .schemaVersion == 1
    and .outcome == "deny"
    and .matchedRule == "no_force_push"
    and .source == "bundle"
    and (.precedence | type) == "array"
    and (.precedence | length) == 4
    and (.dryRun | type) == "boolean"
  '
  local keys
  keys="$(echo "$output" | jq -r 'keys_unsorted | join(",")')"
  [ "$keys" = "schemaVersion,outcome,source,matchedRule,precedence,dryRun" ]
}

@test "ralph safety check does not execute command with shell metacharacters" {
  local sentinel="$WS/safety-check-metachar-sentinel"
  rm -f "$sentinel"
  # If this text were passed to a shell, the sentinel file would be created.
  run run_ralph safety check --command "touch '$sentinel'; echo hi; rm -rf /"
  [ "$status" -eq 0 ]
  [ ! -e "$sentinel" ]
  # Classify-only: no killswitch sentinel either.
  [ -z "$(find "$WS" -path '*/security/kill-switch*' 2>/dev/null)" ]
}

@test "ralph safety check invalid source exits 1 fail closed" {
  mkdir -p "$WS/.ralph-workspace"
  cat >"$WS/.ralph-workspace/killswitch.json" <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "dryRun": true,
  "banned_tools": [],
  "tool_denylist": [],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF
  run run_ralph safety check --command 'echo ok'
  [ "$status" -eq 1 ]
  [[ "$output" == *"fail closed"* || "$output" == *"duplicate"* || "$output" == *"failed validation"* ]]
}

@test "ralph safety check evaluator failure exits 1" {
  cat >"$RH/bundle/.ralph/bash-lib/killswitch/killswitch-evaluate.sh" <<'EOF'
#!/usr/bin/env bash
# Test stub: force classify-only evaluator failure after successful config load.
killswitch_classify_command() {
  echo "simulated evaluator failure" >&2
  return 1
}
EOF
  run run_ralph safety check --command 'echo ok'
  [ "$status" -eq 1 ]
  [[ "$output" == *"evaluator failure"* ]]
}

@test "ralph safety check missing --command exits 2" {
  run run_ralph safety check
  [ "$status" -eq 2 ]
  [[ "$output" == *"--command"* ]]
}

@test "ralph safety check duplicate --command exits 2" {
  run run_ralph safety check --command 'echo a' --command 'echo b'
  [ "$status" -eq 2 ]
  [[ "$output" == *"more than once"* ]]
}

@test "ralph safety check unknown flag exits 2" {
  run run_ralph safety check --command 'echo ok' --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown check option"* ]]
}

@test "session override allows a blocked command in killswitch checks" {
  mkdir -p "$WS/.ralph-workspace"
  cat >"$WS/.ralph-workspace/killswitch.json" <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "banned_tools": [],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "custom_rules": [
    {"name": "no_force_push", "match": "git push --force", "target": "command"}
  ]
}
EOF
  cat >"$WS/.ralph-workspace/killswitch-override.json" <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "banned_tools": [],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": ["git push --force origin main"],
  "allowed_patterns": [],
  "custom_rules": [
    {"name": "no_force_push", "match": "git push --force", "target": "command"}
  ]
}
EOF

  run bash -c '
    set -euo pipefail
    export WORKSPACE="$1"
    export RALPH_HOME="$2"
    export RALPH_KILLSWITCH_OVERRIDE_FILE="$3"
    source "$4"
    killswitch_command_matches_rule "git push --force origin main"
  ' _ "$WS" "$RH" "$WS/.ralph-workspace/killswitch-override.json" "$KILLSWITCH_CORE"

  [ "$status" -eq 1 ]
}

@test "evaluator allows a benign P10 event" {
  write_workspace_killswitch < <(minimal_valid_killswitch_json)

  run run_killswitch_core killswitch_evaluate '{"schemaVersion":1,"source":"mcp","runtime":"claude","tool":"ralph_plan_status","action":"execute","effect":"read","resource":"PLAN.md","arguments":"status"}'
  [ "$status" -eq 0 ]
  [ "$output" = "allow" ]
}

@test "legacy toolDenylist and deniedArgumentPatterns are fatal" {
  write_workspace_killswitch <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dryRun": false,
  "banned_tools": [],
  "toolDenylist": ["Bash"],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "deniedArgumentPatterns": [
    {"tool": "ralph_proxy_read", "pattern": "/etc/passwd"}
  ],
  "custom_rules": []
}
EOF

  run run_killswitch_core killswitch_evaluate '{"schemaVersion":1,"source":"native-hook","runtime":"claude","tool":"Bash","action":"execute","effect":"write","resource":"","arguments":"echo hi"}'
  [ "$status" -eq 0 ]
  [ "$output" = "fatal" ]

  run run_killswitch_core killswitch_evaluate '{"schemaVersion":1,"source":"mcp","runtime":"claude","tool":"ralph_proxy_read","action":"execute","effect":"read","resource":"/etc/passwd","arguments":"path=/etc/passwd"}'
  [ "$status" -eq 0 ]
  [ "$output" = "fatal" ]
}

@test "legacy tools.deny and arguments.denyPatterns aliases are fatal" {
  write_workspace_killswitch <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "banned_tools": [],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "tools": {"deny": ["ralph_write_file"]},
  "arguments": {
    "denyPatterns": [
      {"tool": "ralph_run_plan", "argument": "plan_path", "pattern": "^/tmp/"}
    ]
  },
  "custom_rules": []
}
EOF

  run run_killswitch_core killswitch_evaluate '{"schemaVersion":1,"source":"mcp","runtime":"claude","tool":"ralph_write_file","action":"execute","effect":"write","resource":"out.md","arguments":"{}"}'
  [ "$status" -eq 0 ]
  [ "$output" = "fatal" ]

  run run_killswitch_core killswitch_evaluate '{"schemaVersion":1,"source":"mcp","runtime":"claude","tool":"ralph_run_plan","action":"execute","effect":"write","resource":"","arguments":"plan_path=/tmp/evil.md"}'
  [ "$status" -eq 0 ]
  [ "$output" = "fatal" ]

  run run_killswitch_core killswitch_evaluate '{"schemaVersion":1,"source":"mcp","runtime":"claude","tool":"ralph_run_plan","action":"execute","effect":"write","resource":"","arguments":"plan_path=docs/ok.md"}'
  [ "$status" -eq 0 ]
  [ "$output" = "allow" ]
}

@test "disabled killswitch allows denylisted tools" {
  write_workspace_killswitch <<'EOF'
{
  "schema_version": 2,
  "enabled": false,
  "dry_run": false,
  "banned_tools": [],
  "toolDenylist": ["Bash"],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF

  run run_killswitch_core killswitch_evaluate '{"schemaVersion":1,"source":"native-hook","runtime":"claude","tool":"Bash","action":"execute","effect":"write","resource":"","arguments":"rm -rf /"}'
  [ "$status" -eq 0 ]
  [ "$output" = "allow" ]
}

@test "malformed events are deny not fatal" {
  write_workspace_killswitch < <(minimal_valid_killswitch_json)

  run run_killswitch_core killswitch_evaluate 'not-json'
  [ "$status" -eq 0 ]
  [ "$output" = "deny" ]
}

@test "dry-run trigger writes sentinel JSON contract and does not kill" {
  write_workspace_killswitch <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": true,
  "banned_tools": [],
  "tool_denylist": ["Bash"],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF

  run run_killswitch_core killswitch_eval_then_apply '{"schemaVersion":1,"source":"native-hook","runtime":"claude","tool":"Bash","action":"execute","effect":"write","resource":"","arguments":"echo hi"}'
  [ "$status" -eq 77 ]
  [[ "$output" == *"EVAL=fatal"* ]]

  local sentinel_path
  sentinel_path="$WS/.ralph-workspace/security/kill-switch.ks-core.json"
  [ -f "$sentinel_path" ]
  jq -e '.timestamp and .workspace and .plan_key == "ks-core" and .tool == "Bash" and .category == "tool" and .reason == "tool denylist"' "$sentinel_path"
  jq -e '.project_root == "'"$WS"'"' "$sentinel_path"
  jq -e '.agent_workspace == "'"$WS"'"' "$sentinel_path"
  jq -e '.plan_workspace_root == "'"$WS"'/.ralph-workspace"' "$sentinel_path"
  local summary hash
  summary="$(jq -r '.arguments.summary' "$sentinel_path")"
  [[ "$summary" == *"echo hi"* ]]
  hash="$(jq -r '.arguments.hash' "$sentinel_path")"
  [ "${#hash}" -eq 64 ]
}

@test "stale sentinels are ignored and current sentinels abort" {
  write_workspace_killswitch < <(minimal_valid_killswitch_json)

  mkdir -p "$WS/.ralph-workspace/security"
  local sentinel_path="$WS/.ralph-workspace/security/kill-switch.ks-core.json"
  printf '{"tool":"old","reason":"previous run"}\n' >"$sentinel_path"
  touch -t 202001010000 "$sentinel_path"

  run run_killswitch_core killswitch_report_sentinel_freshness "$(date +%s)" stale not-stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale"* ]]
  [[ "$output" == *"ignore"* ]]

  printf '{"tool":"now","reason":"current run"}\n' >"$sentinel_path"
  run run_killswitch_core killswitch_report_sentinel_freshness "$(( $(date +%s) - 5 ))" stale current
  [ "$status" -eq 0 ]
  [[ "$output" == *"current"* ]]
  [[ "$output" == *"abort"* ]]
}

KILLSWITCH_CONFIG_PY="$REPO_ROOT/bundle/.ralph/python/killswitch_config.py"

@test "normalizer command contract: validate accepts bundle default silently" {
  run python3 "$KILLSWITCH_CONFIG_PY" validate "$REPO_ROOT/bundle/.ralph/killswitch.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "normalizer command contract: normalize prints deterministic canonical JSON" {
  run python3 "$KILLSWITCH_CONFIG_PY" normalize "$REPO_ROOT/bundle/.ralph/killswitch.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"schema_version": 2'* ]]
  [[ "$output" == *'"allowed_commands": []'* ]]
  run python3 "$KILLSWITCH_CONFIG_PY" normalize "$REPO_ROOT/bundle/.ralph/killswitch.json"
  local second="$output"
  run python3 "$KILLSWITCH_CONFIG_PY" normalize "$REPO_ROOT/bundle/.ralph/killswitch.json"
  [ "$output" = "$second" ]
}

@test "normalizer command contract: validate rejects duplicate alias with source and JSON path on stderr" {
  cat >"$WS/bad-killswitch.json" <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "dryRun": true,
  "banned_tools": [],
  "tool_denylist": [],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF
  run python3 "$KILLSWITCH_CONFIG_PY" validate "$WS/bad-killswitch.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$WS/bad-killswitch.json"* ]]
  [[ "$output" == *"$.dry_run"* ]]
  [[ "$output" == *"$.dryRun"* ]]
  [[ "$output" == *"duplicate alias"* ]]
}

@test "normalizer command contract: validate rejects unreadable source on stderr" {
  run python3 "$KILLSWITCH_CONFIG_PY" validate "$WS/missing-killswitch.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$WS/missing-killswitch.json"* ]]
  [[ "$output" == *"unreadable"* ]]
}

@test "fail closed: invalid configured source returns nonzero before runtime/MCP sentinels" {
  write_workspace_killswitch <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "dryRun": true,
  "banned_tools": [],
  "tool_denylist": [],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF
  # Valid lower-precedence global must not be used when project source is invalid.
  cp "$REPO_ROOT/bundle/.ralph/killswitch.json" "$RH/killswitch.json"

  run bash -c '
    set +e
    export WORKSPACE="$1"
    export RALPH_HOME="$2"
    export RALPH_PLAN_WORKSPACE_ROOT="$1/.ralph-workspace"
    unset RALPH_KILLSWITCH_CONFIG_LOADED RALPH_KILLSWITCH_CORE_LOADED RALPH_KILLSWITCH_CORE_LOAD_STATUS
    unset RALPH_KILLSWITCH_EVALUATE_LOADED RALPH_KILLSWITCH_VALIDATOR_LOADED RALPH_KILLSWITCH_KILLER_LOADED
    runtime_sentinel() { printf "RUNTIME_INVOKED\n"; }
    mcp_sentinel() { printf "MCP_INVOKED\n"; }
    source "$3" 2>"$1/.ralph-workspace/load.err" || load_ec=$?
    load_ec="${load_ec:-0}"
    if [[ "$load_ec" -eq 0 ]]; then
      runtime_sentinel
      mcp_sentinel
      killswitch_evaluate "{\"schemaVersion\":1,\"source\":\"mcp\",\"runtime\":\"claude\",\"tool\":\"Bash\",\"action\":\"execute\",\"effect\":\"write\",\"resource\":\"\",\"arguments\":\"echo hi\"}"
    fi
    printf "LOAD_EC=%s\n" "$load_ec"
    printf "SOURCE=%s\n" "${_KILLSWITCH_CONFIG_SOURCE:-}"
    printf "LOAD_OK=%s\n" "${_KILLSWITCH_LOAD_OK:-}"
    if grep -q "duplicate alias" "$1/.ralph-workspace/load.err" 2>/dev/null; then
      printf "DUP_ALIAS=1\n"
    fi
    exit "$load_ec"
  ' _ "$WS" "$RH" "$KILLSWITCH_CORE"

  [ "$status" -ne 0 ]
  [[ "$output" == *"LOAD_EC=1"* ]]
  [[ "$output" != *"RUNTIME_INVOKED"* ]]
  [[ "$output" != *"MCP_INVOKED"* ]]
  [[ "$output" == *"SOURCE=project"* ]]
  [[ "$output" == *"LOAD_OK=0"* ]]
  [[ "$output" == *"DUP_ALIAS=1"* ]]
}

@test "fail closed: unreadable configured source returns nonzero before runtime/MCP sentinels" {
  write_workspace_killswitch < <(minimal_valid_killswitch_json)
  chmod 000 "$WS/.ralph-workspace/killswitch.json"
  cp "$REPO_ROOT/bundle/.ralph/killswitch.json" "$RH/killswitch.json"

  run bash -c '
    set +e
    export WORKSPACE="$1"
    export RALPH_HOME="$2"
    export RALPH_PLAN_WORKSPACE_ROOT="$1/.ralph-workspace"
    unset RALPH_KILLSWITCH_CONFIG_LOADED RALPH_KILLSWITCH_CORE_LOADED RALPH_KILLSWITCH_CORE_LOAD_STATUS
    unset RALPH_KILLSWITCH_EVALUATE_LOADED RALPH_KILLSWITCH_VALIDATOR_LOADED RALPH_KILLSWITCH_KILLER_LOADED
    runtime_sentinel() { printf "RUNTIME_INVOKED\n"; }
    mcp_sentinel() { printf "MCP_INVOKED\n"; }
    source "$3" 2>"$1/.ralph-workspace/load.err" || load_ec=$?
    load_ec="${load_ec:-0}"
    if [[ "$load_ec" -eq 0 ]]; then
      runtime_sentinel
      mcp_sentinel
    fi
    printf "LOAD_EC=%s\n" "$load_ec"
    printf "SOURCE=%s\n" "${_KILLSWITCH_CONFIG_SOURCE:-}"
    if grep -Eiq "unreadable|permission" "$1/.ralph-workspace/load.err" 2>/dev/null; then
      printf "UNREADABLE_ERR=1\n"
    fi
    exit "$load_ec"
  ' _ "$WS" "$RH" "$KILLSWITCH_CORE"

  chmod u+rw "$WS/.ralph-workspace/killswitch.json" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"LOAD_EC=1"* ]]
  [[ "$output" != *"RUNTIME_INVOKED"* ]]
  [[ "$output" != *"MCP_INVOKED"* ]]
  [[ "$output" == *"SOURCE=project"* ]]
  [[ "$output" == *"UNREADABLE_ERR=1"* ]]
}

@test "source precedence: override wins over project and records provenance" {
  write_workspace_killswitch < <(minimal_valid_killswitch_json)
  cp "$REPO_ROOT/bundle/.ralph/killswitch.json" "$RH/killswitch.json"
  cat >"$WS/.ralph-workspace/killswitch-override.json" <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": true,
  "banned_tools": ["OverrideTool"],
  "tool_denylist": [],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF

  run run_killswitch_loader "
    export RALPH_KILLSWITCH_OVERRIDE_FILE=\"$WS/.ralph-workspace/killswitch-override.json\"
    killswitch_load_config || exit 1
    printf 'SOURCE=%s\n' \"\$(killswitch_config_source)\"
    printf 'PATH=%s\n' \"\$(killswitch_config_path)\"
    printf 'DRY=%s\n' \"\$_KILLSWITCH_DRY_RUN\"
    printf 'BANNED=%s\n' \"\${_KILLSWITCH_BANNED_TOOLS[*]}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCE=override"* ]]
  [[ "$output" == *"killswitch-override.json"* ]]
  [[ "$output" == *"DRY=true"* ]]
  [[ "$output" == *"BANNED=OverrideTool"* ]]
}

@test "source precedence: missing project falls through to global" {
  rm -f "$WS/.ralph-workspace/killswitch.json"
  cat >"$RH/killswitch.json" <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "banned_tools": ["GlobalOnly"],
  "tool_denylist": [],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF

  run run_killswitch_loader '
    killswitch_load_config || exit 1
    printf "SOURCE=%s\n" "$(killswitch_config_source)"
    printf "PATH=%s\n" "$(killswitch_config_path)"
    printf "BANNED=%s\n" "${_KILLSWITCH_BANNED_TOOLS[*]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCE=global"* ]]
  [[ "$output" == *"$RH/killswitch.json"* ]]
  [[ "$output" == *"BANNED=GlobalOnly"* ]]
}

@test "source precedence: missing optional sources fall through to bundle default" {
  rm -f "$WS/.ralph-workspace/killswitch.json" "$RH/killswitch.json"

  run run_killswitch_loader '
    killswitch_load_config || exit 1
    printf "SOURCE=%s\n" "$(killswitch_config_source)"
    printf "PATH=%s\n" "$(killswitch_config_path)"
    printf "LOAD_OK=%s\n" "$_KILLSWITCH_LOAD_OK"
    printf "ENABLED=%s\n" "$_KILLSWITCH_ENABLED"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCE=bundle"* ]]
  [[ "$output" == *"/killswitch.json"* ]]
  [[ "$output" == *"LOAD_OK=1"* ]]
  [[ "$output" == *"ENABLED=true"* ]]
}

@test "environment overrides merge after validation" {
  write_workspace_killswitch <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "banned_tools": ["FromFile"],
  "tool_denylist": [],
  "allowed_tools": [],
  "banned_paths": ["/from-file"],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF

  run run_killswitch_loader '
    export RALPH_BANNED_TOOLS="EnvTool"
    export RALPH_BANNED_PATHS="/from-env"
    export RALPH_MCP_TOOL_DENYLIST="EnvDeny"
    killswitch_load_config || exit 1
    # Env must not be applied during validate/load — only after.
    printf "AFTER_LOAD_TOOLS=%s\n" "${_KILLSWITCH_BANNED_TOOLS[*]}"
    killswitch_merge_env_overrides
    printf "AFTER_MERGE_TOOLS=%s\n" "${_KILLSWITCH_BANNED_TOOLS[*]}"
    printf "AFTER_MERGE_PATHS=%s\n" "${_KILLSWITCH_BANNED_PATHS[*]}"
    printf "AFTER_MERGE_DENY=%s\n" "${_KILLSWITCH_TOOL_DENYLIST[*]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"AFTER_LOAD_TOOLS=FromFile"* ]]
  [[ "$output" != *"AFTER_LOAD_TOOLS=FromFile EnvTool"* ]]
  [[ "$output" == *"AFTER_MERGE_TOOLS=FromFile EnvTool"* ]]
  [[ "$output" == *"AFTER_MERGE_PATHS=/from-file /from-env"* ]]
  [[ "$output" == *"AFTER_MERGE_DENY=EnvDeny"* ]]
}

@test "valid evaluation preserves allow and fatal decisions after fail-closed load" {
  write_workspace_killswitch <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "banned_tools": [],
  "tool_denylist": ["Bash"],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF

  run run_killswitch_core eval '
    printf "SOURCE=%s\n" "$(killswitch_config_source)"
    allow_out="$(killswitch_evaluate "{\"schemaVersion\":1,\"source\":\"mcp\",\"runtime\":\"claude\",\"tool\":\"ralph_plan_status\",\"action\":\"execute\",\"effect\":\"read\",\"resource\":\"PLAN.md\",\"arguments\":\"status\"}")"
    fatal_out="$(killswitch_evaluate "{\"schemaVersion\":1,\"source\":\"native-hook\",\"runtime\":\"claude\",\"tool\":\"Bash\",\"action\":\"execute\",\"effect\":\"write\",\"resource\":\"\",\"arguments\":\"echo hi\"}")"
    printf "ALLOW=%s\n" "$allow_out"
    printf "FATAL=%s\n" "$fatal_out"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCE=project"* ]]
  [[ "$output" == *"ALLOW=allow"* ]]
  [[ "$output" == *"FATAL=fatal"* ]]
}

# --- safety init / edit / removed config route --------------------------------
# Contracts: agents/rules/test-design.md, agents/rules/testing-workflow.md,
# contracts.md (Safety CLI). Public argv, absolute targets, preview/confirm,
# atomic editor, symlink/race refusal, byte-exact preserve, no --force.

write_safety_editor() {
  local path="$1"
  cat >"$path"
  chmod +x "$path"
}

normalized_bundle_default() {
  RALPH_HOME="$RH" python3 "$RH/bundle/.ralph/python/killswitch_config.py" normalize \
    "$RH/bundle/.ralph/killswitch.json"
}

@test "removed config: ralph config --help does not advertise killswitch" {
  run run_ralph config --help
  [ "$status" -eq 0 ]
  [[ "$output" != *"killswitch"* ]]
  [[ "$output" != *"config killswitch"* ]]
  [[ "$output" == *"ralph safety"* ]]
}

@test "removed config: ralph config killswitch still exits 2 with exact replacement" {
  run run_ralph config killswitch
  [ "$status" -eq 2 ]
  [ "$output" = "Use: ralph safety <status|validate|check|init|edit>" ]
}

@test "safety init project target creates state-root killswitch after --yes" {
  [ ! -e "$WS/.ralph-workspace" ]
  run run_ralph safety init --project --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"scope:  project"* ]]
  [[ "$output" == *"target: $WS/.ralph-workspace/killswitch.json"* ]]
  [[ "$output" == *"Preview (normalized bundle default):"* ]]
  [[ "$output" == *"Confirmed non-interactively (--yes)"* ]]
  [[ "$output" == *"Created project safety config: $WS/.ralph-workspace/killswitch.json"* ]]
  [ -f "$WS/.ralph-workspace/killswitch.json" ]
  [ "$(cat "$WS/.ralph-workspace/killswitch.json")" = "$(normalized_bundle_default)" ]
}

@test "safety init global target creates RALPH_HOME killswitch after --yes" {
  [ ! -e "$RH/killswitch.json" ]
  run run_ralph safety init --global --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"scope:  global"* ]]
  [[ "$output" == *"target: $RH/killswitch.json"* ]]
  [[ "$output" == *"Created global safety config: $RH/killswitch.json"* ]]
  [ -f "$RH/killswitch.json" ]
  [ "$(cat "$RH/killswitch.json")" = "$(normalized_bundle_default)" ]
}

@test "safety init preview without --yes on non-TTY refuses and creates no directories" {
  [ ! -e "$WS/.ralph-workspace" ]
  run run_ralph safety init --project
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --yes"* ]]
  [[ "$output" == *"Preview (normalized bundle default):"* ]]
  [ ! -e "$WS/.ralph-workspace" ]
  [ ! -e "$WS/.ralph-workspace/killswitch.json" ]
}

@test "safety init confirmation cancel via closed stdin creates no directories" {
  [ ! -e "$WS/.ralph-workspace" ]
  # Force interactive path with a fake TTY is hard in bats; non-TTY without --yes
  # already covers cancel-before-mkdir. Interactive cancel is covered by piping no.
  run bash -c "cd '$WS' && printf 'no\n' | RALPH_HOME='$RH' bash '$SHIM' safety init --project </dev/null"
  [ "$status" -ne 0 ]
  [ ! -e "$WS/.ralph-workspace" ]
}

@test "safety init refuses --force and keeps existing project target" {
  mkdir -p "$WS/.ralph-workspace"
  printf '%s\n' '{"keep":true}' >"$WS/.ralph-workspace/killswitch.json"
  local before
  before="$(cat "$WS/.ralph-workspace/killswitch.json")"
  run run_ralph safety init --project --force --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"--force is not supported"* ]]
  [ "$(cat "$WS/.ralph-workspace/killswitch.json")" = "$before" ]
}

@test "safety init replacement confirmation with --yes overwrites existing project target" {
  mkdir -p "$WS/.ralph-workspace"
  write_workspace_killswitch <<'EOF'
{
  "schema_version": 2,
  "enabled": false,
  "dry_run": true,
  "banned_tools": ["Old"],
  "tool_denylist": [],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF
  run run_ralph safety init --project --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"target already exists"* ]]
  [[ "$output" == *"Replaced project safety config:"* ]]
  [ "$(cat "$WS/.ralph-workspace/killswitch.json")" = "$(normalized_bundle_default)" ]
}

@test "safety edit project target updates JSON atomically" {
  run run_ralph safety init --project --yes
  [ "$status" -eq 0 ]
  local target="$WS/.ralph-workspace/killswitch.json"
  local dir
  dir="$(dirname "$target")"

  write_safety_editor "$RH/ok-editor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["enabled"] = False
data["dry_run"] = True
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
EOF

  run bash -c "cd '$WS' && RALPH_HOME='$RH' VISUAL='$RH/ok-editor.sh' \
    bash '$SHIM' safety edit --project --yes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scope:  project"* ]]
  [[ "$output" == *"target: $target"* ]]
  [[ "$output" == *"Edited project safety config: $target"* ]]
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["enabled"] is False and d["dry_run"] is True' "$target"
  [ "$status" -eq 0 ]
  [ "$(find "$dir" -name '.safety-edit-*' | wc -l | tr -d ' ')" = "0" ]
}

@test "safety edit global target updates JSON atomically" {
  run run_ralph safety init --global --yes
  [ "$status" -eq 0 ]
  local target="$RH/killswitch.json"

  write_safety_editor "$RH/g-ok-editor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["banned_tools"] = ["EditedGlobal"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
EOF

  run bash -c "cd '$WS' && RALPH_HOME='$RH' VISUAL='$RH/g-ok-editor.sh' \
    bash '$SHIM' safety edit --global --yes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Edited global safety config: $target"* ]]
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["banned_tools"]==["EditedGlobal"]' "$target"
  [ "$status" -eq 0 ]
}

@test "safety edit editor order prefers VISUAL then EDITOR then nano over vi" {
  run run_ralph safety init --project --yes
  [ "$status" -eq 0 ]
  mkdir -p "$RH/bin"
  write_safety_editor "$RH/bin/visual-ed" <<'EOF'
#!/usr/bin/env bash
printf 'visual\n' >"${EDIT_MARKER:?}"
exit 0
EOF
  write_safety_editor "$RH/bin/editor-ed" <<'EOF'
#!/usr/bin/env bash
printf 'editor\n' >"${EDIT_MARKER:?}"
exit 0
EOF
  # Shadows real nano earlier in PATH; a real vi may also exist on PATH, but
  # the stubbed nano must still win since nano is now preferred over vi.
  write_safety_editor "$RH/bin/nano" <<'EOF'
#!/usr/bin/env bash
printf 'nano\n' >"${EDIT_MARKER:?}"
exit 0
EOF

  local marker="$RH/editor-used.txt"
  rm -f "$marker"

  run env RALPH_HOME="$RH" EDIT_MARKER="$marker" \
    VISUAL="$RH/bin/visual-ed" EDITOR="$RH/bin/editor-ed" PATH="$RH/bin:$PATH" \
    bash -c "cd '$WS' && bash '$SHIM' safety edit --project --yes"
  [ "$status" -eq 0 ]
  [ "$(cat "$marker")" = "visual" ]

  rm -f "$marker"
  run env -u VISUAL RALPH_HOME="$RH" EDIT_MARKER="$marker" \
    EDITOR="$RH/bin/editor-ed" PATH="$RH/bin:$PATH" \
    bash -c "cd '$WS' && bash '$SHIM' safety edit --project --yes"
  [ "$status" -eq 0 ]
  [ "$(cat "$marker")" = "editor" ]

  rm -f "$marker"
  run env -u VISUAL -u EDITOR RALPH_HOME="$RH" EDIT_MARKER="$marker" PATH="$RH/bin:$PATH" \
    bash -c "cd '$WS' && bash '$SHIM' safety edit --project --yes"
  [ "$status" -eq 0 ]
  [ "$(cat "$marker")" = "nano" ]
}

@test "safety edit editor failure preserves the original config" {
  run run_ralph safety init --project --yes
  [ "$status" -eq 0 ]
  local target="$WS/.ralph-workspace/killswitch.json"
  local before
  before="$(cat "$target")"

  write_safety_editor "$RH/fail-editor.sh" <<'EOF'
#!/usr/bin/env bash
echo "mutated-by-failed-editor" >>"$1"
exit 7
EOF

  run bash -c "cd '$WS' && RALPH_HOME='$RH' VISUAL='$RH/fail-editor.sh' \
    bash '$SHIM' safety edit --project --yes"
  [ "$status" -eq 1 ]
  [[ "$output" == *"editor failed"* ]]
  [ "$(cat "$target")" = "$before" ]
  [ "$(find "$(dirname "$target")" -name '.safety-edit-*' | wc -l | tr -d ' ')" = "0" ]
}

@test "safety edit invalid JSON is refused and original is preserved" {
  run run_ralph safety init --project --yes
  [ "$status" -eq 0 ]
  local target="$WS/.ralph-workspace/killswitch.json"
  local before
  before="$(cat "$target")"

  write_safety_editor "$RH/bad-editor.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"schema_version":2,"enabled":"nope"}' >"$1"
EOF

  run bash -c "cd '$WS' && RALPH_HOME='$RH' VISUAL='$RH/bad-editor.sh' \
    bash '$SHIM' safety edit --project --yes"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed validation"* ]]
  [ "$(cat "$target")" = "$before" ]
}

@test "safety edit symlink target is refused and referent preserved" {
  run run_ralph safety init --global --yes
  [ "$status" -eq 0 ]
  local global="$RH/killswitch.json"
  local project_dir="$WS/.ralph-workspace"
  local project="$project_dir/killswitch.json"
  local before
  before="$(cat "$global")"
  mkdir -p "$project_dir"
  ln -s "$global" "$project"
  [ -L "$project" ]

  write_safety_editor "$RH/symlink-editor.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"schema_version":2,"enabled":false}' >"$1"
exit 0
EOF

  run bash -c "cd '$WS' && RALPH_HOME='$RH' VISUAL='$RH/symlink-editor.sh' \
    bash '$SHIM' safety edit --project --yes"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink"* ]]
  [ -L "$project" ]
  [ "$(cat "$global")" = "$before" ]
}

@test "safety edit target race refuses overwrite and keeps concurrent file" {
  run run_ralph safety init --project --yes
  [ "$status" -eq 0 ]
  local target="$WS/.ralph-workspace/killswitch.json"
  local raced="$RH/raced-killswitch.json"
  python3 - "$target" "$raced" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    data = json.load(f)
data["banned_tools"] = ["ConcurrentWinner"]
with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

  write_safety_editor "$RH/race-editor.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cp -f '$raced' '$target'
python3 - "\$1" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["banned_tools"] = ["LosingEdit"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
EOF

  run bash -c "cd '$WS' && RALPH_HOME='$RH' VISUAL='$RH/race-editor.sh' \
    bash '$SHIM' safety edit --project --yes"
  [ "$status" -eq 1 ]
  [[ "$output" == *"race"* ]]
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["banned_tools"]==["ConcurrentWinner"]' "$target"
  [ "$status" -eq 0 ]
}

@test "safety edit atomic publish leaves no temps after success or invalid edit" {
  run run_ralph safety init --project --yes
  [ "$status" -eq 0 ]
  local target="$WS/.ralph-workspace/killswitch.json"
  local dir
  dir="$(dirname "$target")"

  write_safety_editor "$RH/atomic-ok.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["dry_run"] = True
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
EOF

  run bash -c "cd '$WS' && RALPH_HOME='$RH' VISUAL='$RH/atomic-ok.sh' \
    bash '$SHIM' safety edit --project --yes"
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["dry_run"] is True' "$target"
  [ "$status" -eq 0 ]
  [ "$(find "$dir" -name '.safety-edit-*' | wc -l | tr -d ' ')" = "0" ]

  write_safety_editor "$RH/atomic-bad.sh" <<'EOF'
#!/usr/bin/env bash
printf 'not-json\n' >"$1"
EOF

  run bash -c "cd '$WS' && RALPH_HOME='$RH' VISUAL='$RH/atomic-bad.sh' \
    bash '$SHIM' safety edit --project --yes"
  [ "$status" -eq 1 ]
  run python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["dry_run"] is True' "$target"
  [ "$status" -eq 0 ]
  [ "$(find "$dir" -name '.safety-edit-*' | wc -l | tr -d ' ')" = "0" ]
}

@test "safety init symlink target is refused" {
  mkdir -p "$WS/.ralph-workspace"
  ln -s "$RH/bundle/.ralph/killswitch.json" "$WS/.ralph-workspace/killswitch.json"
  local before
  before="$(cat "$RH/bundle/.ralph/killswitch.json")"
  run run_ralph safety init --project --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink"* ]]
  [ -L "$WS/.ralph-workspace/killswitch.json" ]
  [ "$(cat "$RH/bundle/.ralph/killswitch.json")" = "$before" ]
}
