#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

setup() {
  export TMPDIR="$(mktemp -d)"
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "session home defaults to workspace .ralph-workspace/sessions in local install" {
  local workspace="$TMPDIR/project"
  mkdir -p "$workspace"

  unset RALPH_PLAN_SESSION_HOME
  unset RALPH_HOME

  bash -c "
    source '$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-session.sh'
    RALPH_PLAN_KEY='test-plan'
    RALPH_SESSION_DIR=''
    ralph_session_init '$workspace' ''
    echo \"\$RALPH_PLAN_SESSION_HOME\"
  " | grep -q "\.ralph-workspace/sessions"
}

@test "session home uses XDG_STATE_HOME in global install without project .ralph" {
  local workspace="$TMPDIR/project"
  mkdir -p "$workspace"

  export RALPH_HOME="$TMPDIR/.ralph"
  mkdir -p "$RALPH_HOME"
  unset RALPH_PLAN_SESSION_HOME
  unset XDG_STATE_HOME

  local result
  result="$(bash -c "
    source '$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-session.sh'
    RALPH_PLAN_KEY='test-plan'
    RALPH_SESSION_DIR=''
    ralph_session_init '$workspace' ''
    echo \"\$RALPH_PLAN_SESSION_HOME\"
  ")"

  [[ "$result" == "$HOME/.local/state/ralph/sessions" ]]
}

@test "session home uses project .ralph-workspace when project-local .ralph exists (even with RALPH_HOME)" {
  local workspace="$TMPDIR/project"
  mkdir -p "$workspace/.ralph"

  export RALPH_HOME="$TMPDIR/.ralph"
  mkdir -p "$RALPH_HOME"
  unset RALPH_PLAN_SESSION_HOME

  local result
  result="$(bash -c "
    source '$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-session.sh'
    RALPH_PLAN_KEY='test-plan'
    RALPH_SESSION_DIR=''
    ralph_session_init '$workspace' ''
    echo \"\$RALPH_PLAN_SESSION_HOME\"
  ")"

  [[ "$result" == "$workspace/.ralph-workspace/sessions" ]]
}

@test "explicit RALPH_PLAN_SESSION_HOME always wins over defaults" {
  local workspace="$TMPDIR/project"
  mkdir -p "$workspace"
  local custom_home="$TMPDIR/custom-sessions"
  mkdir -p "$custom_home"

  export RALPH_HOME="$TMPDIR/.ralph"
  mkdir -p "$RALPH_HOME"
  export RALPH_PLAN_SESSION_HOME="$custom_home"

  local result
  result="$(bash -c "
    source '$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-session.sh'
    RALPH_PLAN_KEY='test-plan'
    RALPH_SESSION_DIR=''
    ralph_session_init '$workspace' ''
    echo \"\$RALPH_PLAN_SESSION_HOME\"
  ")"

  [[ "$result" == "$custom_home" ]]
}

@test "session home respects custom XDG_STATE_HOME in global install" {
  local workspace="$TMPDIR/project"
  mkdir -p "$workspace"

  export RALPH_HOME="$TMPDIR/.ralph"
  mkdir -p "$RALPH_HOME"
  export XDG_STATE_HOME="$TMPDIR/custom-state"
  unset RALPH_PLAN_SESSION_HOME

  local result
  result="$(bash -c "
    source '$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-session.sh'
    RALPH_PLAN_KEY='test-plan'
    RALPH_SESSION_DIR=''
    ralph_session_init '$workspace' ''
    echo \"\$RALPH_PLAN_SESSION_HOME\"
  ")"

  [[ "$result" == "$TMPDIR/custom-state/ralph/sessions" ]]
}

@test "session directory is created and has correct permissions in global install" {
  local workspace="$TMPDIR/project"
  mkdir -p "$workspace"

  export RALPH_HOME="$TMPDIR/.ralph"
  mkdir -p "$RALPH_HOME"
  unset RALPH_PLAN_SESSION_HOME
  unset XDG_STATE_HOME

  bash -c "
    source '$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-session.sh'
    RALPH_PLAN_KEY='test-plan'
    RALPH_SESSION_DIR=''
    ralph_session_init '$workspace' ''
    test -d \"\$RALPH_SESSION_DIR\" || exit 1
    ls -ld \"\$RALPH_SESSION_DIR\" | awk '{print \$1}' | grep -q 'rwx------'
  "
}

@test "session directory is created and has correct permissions in local install" {
  local workspace="$TMPDIR/project"
  mkdir -p "$workspace"

  unset RALPH_HOME
  unset RALPH_PLAN_SESSION_HOME

  bash -c "
    source '$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-session.sh'
    RALPH_PLAN_KEY='test-plan'
    RALPH_SESSION_DIR=''
    ralph_session_init '$workspace' ''
    test -d \"\$RALPH_SESSION_DIR\" || exit 1
    ls -ld \"\$RALPH_SESSION_DIR\" | awk '{print \$1}' | grep -q 'rwx------'
  "
}
