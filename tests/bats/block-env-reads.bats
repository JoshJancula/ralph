#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

BLOCK_ENV_READS="$REPO_ROOT/bundle/.claude/hooks/block-env-reads.sh"

send_input_to_script() {
  local payload=$1
  run bash -c "cat <<'EOF' | \"\$1\"
$payload
EOF" _ "$BLOCK_ENV_READS"
}

@test "block-env-reads allows when no file path is provided" {
  send_input_to_script '{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "block-env-reads allows reading safe files" {
  send_input_to_script '{"path":"docs/guide.md"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "block-env-reads blocks .env paths" {
  send_input_to_script '{"path":".env"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED: Agent attempted to read"* ]]
}

@test "block-env-reads blocks env files via filename key" {
  send_input_to_script '{"filename":".env.production"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED: Agent attempted to read"* ]]
}
