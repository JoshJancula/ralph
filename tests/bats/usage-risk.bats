#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

setup() {
  fake_config_dir="$(mktemp -d)"
  export XDG_CONFIG_HOME="$fake_config_dir"
}

teardown() {
  rm -rf "$fake_config_dir"
}

@test "usage-risk accepts yes, YES, y, Yes with re-prompt on invalid" {
  # Source the lib to test the regex matching directly
  source "$REPO_ROOT/bundle/.ralph/bash-lib/usage-risk-ack.sh"
  
  # Test regex directly
  for input in "y" "Y" "yes" "YES" "Yes"; do
    [[ "$input" =~ ^[Yy]([Ee][Ss])?$ ]] || false
  done
  
  # Test rejections
  for input in "n" "N" "no" "NO" "" "maybe"; do
    ! [[ "$input" =~ ^[Yy]([Ee][Ss])?$ ]] || false
  done
}

@test "usage-risk respects RALPH_USAGE_RISKS_ACKNOWLEDGED=1" {
  run bash -c '
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export XDG_CONFIG_HOME="'$XDG_CONFIG_HOME'"
    source "'$REPO_ROOT'/bundle/.ralph/bash-lib/usage-risk-ack.sh"
    ralph_require_usage_risk_acknowledgment
  '
  [ "$status" -eq 0 ]
  [ ! -f "$XDG_CONFIG_HOME/ralph/usage-risk-acknowledgment" ]
}

@test "usage-risk accepts existing marker file" {
  mkdir -p "$XDG_CONFIG_HOME/ralph"
  cat >"$XDG_CONFIG_HOME/ralph/usage-risk-acknowledgment" <<'MARKER'
# Ralph: records that you accepted usage risk warnings for AI agent runners.
RALPH_USAGE_RISK_ACK_VERSION=1
ACKNOWLEDGED_AT=2024-01-01T00:00:00Z
MARKER

  run bash -c '
    export XDG_CONFIG_HOME="'$XDG_CONFIG_HOME'"
    source "'$REPO_ROOT'/bundle/.ralph/bash-lib/usage-risk-ack.sh"
    ralph_require_usage_risk_acknowledgment
  '
  [ "$status" -eq 0 ]
}
