#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

USAGE_RISK_ACK="$REPO_ROOT/bundle/.ralph/bash-lib/usage-risk-ack.sh"

@test "ralph_require_usage_risk_acknowledgment accepts existing marker file" {
  export XDG_CONFIG_HOME="${BATS_TMPDIR}/config"
  mkdir -p "$XDG_CONFIG_HOME/ralph"
  cat <<'MARKER' >"$XDG_CONFIG_HOME/ralph/usage-risk-acknowledgment"
RALPH_USAGE_RISK_ACK_VERSION=1
MARKER

  run bash -c 'unset RALPH_USAGE_RISKS_ACKNOWLEDGED; source "$1"; ralph_require_usage_risk_acknowledgment' _ "$USAGE_RISK_ACK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
