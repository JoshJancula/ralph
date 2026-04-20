#!/usr/bin/env bats
# shellcheck shell=bash

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

RUN_PLAN_SESSION_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-session.sh"

@test "ralph_session_generate_uuid uses uuidgen, proc, and python3 in order" {
  [ -f "$RUN_PLAN_SESSION_FILE" ] || skip "run-plan session helper missing"

  run bash -c '
    set -euo pipefail
    source "$1"

    run_case() {
      local mode="$1"
      local expected="$2"
      local case_dir
      case_dir="$(mktemp -d)"
      mkdir -p "$case_dir/bin"
      # Narrow PATH must still resolve core utilities (helpers use cat for /proc fallback). Do not prepend /bin or
      # /usr/bin wholesale on Linux merged-usr: that exposes system uuidgen and breaks proc/python cases.
      if command -v cat >/dev/null 2>&1; then
        cp "$(command -v cat)" "$case_dir/bin/cat"
        chmod +x "$case_dir/bin/cat"
      fi

      case "$mode" in
        uuidgen)
          cat <<H_STUB_UUIDGEN >"$case_dir/bin/uuidgen"
#!/bin/sh
printf "%s\n" "11111111-1111-4111-8111-111111111111"
H_STUB_UUIDGEN
          chmod +x "$case_dir/bin/uuidgen"
          ;;
        proc)
          ralph_session_generate_uuid_from_proc() {
            printf "%s\n" "22222222-2222-4222-8222-222222222222"
          }
          ;;
        python)
          ralph_session_generate_uuid_from_proc() {
            return 1
          }
          cat <<H_STUB_PY >"$case_dir/bin/python3"
#!/bin/sh
printf "%s\n" "33333333-3333-4333-8333-333333333333"
H_STUB_PY
          chmod +x "$case_dir/bin/python3"
          ;;
      esac

      local old_path="$PATH"
      local actual=""
      # Only expose our stub binaries. On merged-usr Linux, /bin/uuidgen can exist; including /bin in PATH
      # makes the "proc" and "python" cases accidentally invoke the real uuidgen and fail the test.
      PATH="$case_dir/bin"
      actual="$(ralph_session_generate_uuid)"
      PATH="$old_path"

      [ "$actual" = "$expected" ]
      rm -rf "$case_dir"
      unset -f ralph_session_generate_uuid_from_proc 2>/dev/null || true
    }

    run_case uuidgen 11111111-1111-4111-8111-111111111111
    run_case proc 22222222-2222-4222-8222-222222222222
    run_case python 33333333-3333-4333-8333-333333333333
  ' _ "$RUN_PLAN_SESSION_FILE"

  [ "$status" -eq 0 ]
}
