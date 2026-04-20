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
      cat <<'EOF' >"$case_dir/bin/date"
#!/usr/bin/env bash
printf "%s\n" "1700000000"
EOF
      chmod +x "$case_dir/bin/date"

      case "$mode" in
        uuidgen)
          cat <<EOF >"$case_dir/bin/uuidgen"
#!/usr/bin/env bash
printf "%s\n" "11111111-1111-4111-8111-111111111111"
EOF
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
          cat <<EOF >"$case_dir/bin/python3"
#!/usr/bin/env bash
printf "%s\n" "33333333-3333-4333-8333-333333333333"
EOF
          chmod +x "$case_dir/bin/python3"
          ;;
      esac

      local old_path="$PATH"
      local actual=""
      PATH="$case_dir/bin:/bin"
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
