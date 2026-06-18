#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

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
