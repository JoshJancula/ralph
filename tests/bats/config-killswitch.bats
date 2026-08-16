#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

KILLSWITCH_CORE="$REPO_ROOT/bundle/.ralph/bash-lib/killswitch/killswitch-core.sh"

setup() {
  RH="$(mktemp -d)"
  WS="$(mktemp -d)"
  mkdir -p "$RH/bundle/.ralph/bash-lib/config"
  cp "$REPO_ROOT/bundle/.ralph/killswitch.json" "$RH/bundle/.ralph/killswitch.json"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/config/killswitch-cli.sh" \
    "$RH/bundle/.ralph/bash-lib/config/killswitch-cli.sh"

  SHIM="$RH/ralph"
  awk "/cat > \"\\\$tmp\" <<'SHIM'/{f=1;next} /^SHIM\$/{f=0} f" "$REPO_ROOT/install.sh" > "$SHIM"
  chmod +x "$SHIM"
}

teardown() {
  rm -rf "$RH" "$WS"
}

write_workspace_killswitch() {
  mkdir -p "$WS/.ralph-workspace"
  cat >"$WS/.ralph-workspace/killswitch.json"
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
    source "$KILLSWITCH_CORE"
    "$@"
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

run_killswitch_cli() {
  (
    cd "$WS" || exit 1
    RALPH_HOME="$RH" bash "$RH/bundle/.ralph/bash-lib/config/killswitch-cli.sh" "$@"
  )
}

@test "ralph --bundle-path prints bundled .ralph directory" {
  run run_ralph --bundle-path
  [ "$status" -eq 0 ]
  [ "$output" = "$RH/bundle/.ralph" ]
}

@test "ralph config killswitch status shows bundle default when no overrides" {
  run run_ralph config killswitch
  [ "$status" -eq 0 ]
  [[ "$output" == *"Active source: bundle"* ]]
  [[ "$output" == *"$RH/bundle/.ralph/killswitch.json"* ]]
  [[ "$output" == *"not present"* ]]
}

@test "ralph config killswitch init creates workspace config" {
  run run_ralph config killswitch init
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created"* ]]
  [ -f "$WS/.ralph-workspace/killswitch.json" ]

  run run_ralph config killswitch
  [ "$status" -eq 0 ]
  [[ "$output" == *"Active source: workspace"* ]]
  [[ "$output" == *"$WS/.ralph-workspace/killswitch.json"* ]]
}

@test "ralph config killswitch init --global creates global config" {
  run run_ralph config killswitch init --global
  [ "$status" -eq 0 ]
  [ -f "$RH/killswitch.json" ]

  run run_ralph config killswitch
  [ "$status" -eq 0 ]
  [[ "$output" == *"Active source: global"* ]]
}

@test "workspace config takes precedence over global config" {
  run run_ralph config killswitch init --both
  [ "$status" -eq 0 ]

  run run_ralph config killswitch
  [ "$status" -eq 0 ]
  [[ "$output" == *"Active source: workspace"* ]]
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

@test "ralph config killswitch init refuses overwrite without --force" {
  run run_ralph config killswitch init
  [ "$status" -eq 0 ]

  run run_ralph config killswitch init
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "ralph config killswitch init --force overwrites workspace config" {
  run run_ralph config killswitch init
  [ "$status" -eq 0 ]
  printf '{"schema_version":99}\n' >"$WS/.ralph-workspace/killswitch.json"

  run run_ralph config killswitch init --force
  [ "$status" -eq 0 ]
  grep -q '"schema_version": 2' "$WS/.ralph-workspace/killswitch.json"
}

@test "ralph config killswitch edit errors when config missing" {
  run run_killswitch_cli edit
  [ "$status" -ne 0 ]
  [[ "$output" == *"config not found"* ]]
}

@test "ralph config --help lists killswitch subcommand" {
  run run_ralph config --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"killswitch"* ]]
}

@test "evaluator allows a benign P10 event" {
  write_workspace_killswitch <<'EOF'
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
  "deniedArgumentPatterns": [
    {"tool": "ralph_proxy_read", "pattern": "/etc/passwd"}
  ],
  "banned_paths": [],
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
  "tools": {"deny": ["ralph_write_file"]},
  "arguments": {
    "denyPatterns": [
      {"tool": "ralph_run_plan", "argument": "plan_path", "pattern": "^/tmp/"}
    ]
  },
  "banned_paths": [],
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
  "toolDenylist": ["Bash"],
  "banned_tools": [],
  "banned_paths": [],
  "custom_rules": []
}
EOF

  run run_killswitch_core killswitch_evaluate '{"schemaVersion":1,"source":"native-hook","runtime":"claude","tool":"Bash","action":"execute","effect":"write","resource":"","arguments":"rm -rf /"}'
  [ "$status" -eq 0 ]
  [ "$output" = "allow" ]
}

@test "malformed events are deny not fatal" {
  write_workspace_killswitch <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "banned_tools": [],
  "banned_paths": [],
  "custom_rules": []
}
EOF

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
  "tool_denylist": ["Bash"],
  "banned_tools": [],
  "banned_paths": [],
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
  write_workspace_killswitch <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "banned_tools": [],
  "banned_paths": [],
  "custom_rules": []
}
EOF

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
