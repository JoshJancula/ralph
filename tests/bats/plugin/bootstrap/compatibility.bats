#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

BOOTSTRAP="$REPO_ROOT/bundle/.ralph/plugin-inputs/shared/ralph-plugin-bootstrap.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  FAKE_BIN="$TEST_TMPDIR/bin"
  FAKE_BUNDLE="$TEST_TMPDIR/bundle/.ralph"
  RECORD="$TEST_TMPDIR/ralph-invocations.log"
  mkdir -p "$FAKE_BIN" "$FAKE_BUNDLE"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

install_fake_ralph() {
  local mode="$1"
  cat >"$FAKE_BIN/ralph" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$RECORD"
mode="$mode"
bundle="$FAKE_BUNDLE"
case "\$1" in
  --help)
    if [[ "\$mode" == "missing-verbs" ]]; then
      cat <<'HELP'
Usage: ralph <command> [args]

Commands:
  run          Run a plan
  create       Create scaffolding

Options:
  --bundle-path  Print the bundled .ralph directory (for scripts)
HELP
      exit 0
    fi
    cat <<'HELP'
Usage: ralph <command> [args]

Commands:
  run          Run a plan
  create       Create scaffolding
  graph        Graph-mode plans
  agent        Manage agent profiles

Options:
  --bundle-path  Print the bundled .ralph directory (for scripts)
HELP
    exit 0
    ;;
  --bundle-path)
    if [[ "\$mode" == "legacy" ]]; then
      printf '%s\n' "unknown option" >&2
      exit 2
    fi
    printf '%s\n' "\$bundle"
    exit 0
    ;;
  doctor|capabilities|hook)
    printf '%s\n' "forbidden verb invoked: \$1" >&2
    exit 99
    ;;
  *)
    printf '%s\n' "unexpected ralph invocation: \$*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$FAKE_BIN/ralph"
}

write_abi() {
  printf '%s\n' "$1" >"$FAKE_BUNDLE/plugin-api-version"
}

run_probe() {
  env PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash "$BOOTSTRAP" probe --json
}

assert_outcome() {
  local expected=$1
  local status=$2
  local output=$3
  local actual
  actual="$(printf '%s\n' "$output" | jq -r '.outcome')"
  [ "$actual" = "$expected" ]
  case "$expected" in
    usable|newer) [ "$status" -eq 0 ] ;;
    *) [ "$status" -ne 0 ] ;;
  esac
}

assert_no_forbidden_verbs() {
  [[ -f "$RECORD" ]] || return 0
  ! grep -Eq '(^|[[:space:]])(doctor|capabilities|hook)([[:space:]]|$)' "$RECORD"
  ! grep -Eq 'hook[[:space:]]+run' "$RECORD"
}

@test "probe reports missing when ralph is not on PATH" {
  run run_probe
  assert_outcome missing "$status" "$output"
  [ ! -f "$RECORD" ]
}

@test "probe reports legacy when ralph --bundle-path fails" {
  install_fake_ralph legacy
  run run_probe
  assert_outcome legacy "$status" "$output"
  assert_no_forbidden_verbs
  grep -qx -- '--help' "$RECORD"
  grep -qx -- '--bundle-path' "$RECORD"
}

@test "probe reports too-old when plugin-api-version is missing or less than 1" {
  install_fake_ralph current
  run run_probe
  assert_outcome too-old "$status" "$output"
  assert_no_forbidden_verbs

  write_abi 0
  run run_probe
  assert_outcome too-old "$status" "$output"
  assert_no_forbidden_verbs
}

@test "probe reports usable when plugin-api-version equals 1" {
  install_fake_ralph current
  write_abi 1
  run run_probe
  assert_outcome usable "$status" "$output"
  [ "$(printf '%s\n' "$output" | jq -r '.pluginApi')" = "1" ]
  [ "$(printf '%s\n' "$output" | jq -r '.bundlePath')" = "$FAKE_BUNDLE" ]
  assert_no_forbidden_verbs
}

@test "probe reports newer when plugin-api-version is greater than 1" {
  install_fake_ralph current
  write_abi 2
  run run_probe
  assert_outcome newer "$status" "$output"
  [ "$(printf '%s\n' "$output" | jq -r '.pluginApi')" = "2" ]
  [ "$(printf '%s\n' "$output" | jq -r '.expectedPluginApi')" = "1" ]
  assert_no_forbidden_verbs
}

@test "probe blocks a newer ABI when required command verbs are absent" {
  install_fake_ralph missing-verbs
  write_abi 2
  run run_probe
  assert_outcome incompatible "$status" "$output"
  [ "$(printf '%s\n' "$output" | jq -r '.missingVerbs | sort | join(",")')" = "agent,graph" ]
  [[ "$output" == *"required command help is missing"* ]]
  assert_no_forbidden_verbs
}

@test "probe reports incompatible when plugin-api-version is malformed" {
  install_fake_ralph current
  write_abi 'not-an-integer'
  run run_probe
  assert_outcome incompatible "$status" "$output"
  [ "$(printf '%s\n' "$output" | jq -r '.pluginApiPath')" = "$FAKE_BUNDLE/plugin-api-version" ]
  [ "$(printf '%s\n' "$output" | jq -r '.pluginApiValue')" = "not-an-integer" ]
  [[ "$output" == *"$FAKE_BUNDLE/plugin-api-version"* ]]
  [[ "$output" == *"not-an-integer"* ]]
  assert_no_forbidden_verbs
}

@test "probe never invokes doctor, capabilities, or hook-run" {
  install_fake_ralph current
  write_abi 1
  run run_probe
  [ "$status" -eq 0 ]
  assert_no_forbidden_verbs
  # Only the documented discovery flags are invoked.
  while IFS= read -r line; do
    case "$line" in
      --help|--bundle-path) ;;
      *) echo "unexpected recorded invocation: $line" >&2; return 1 ;;
    esac
  done <"$RECORD"
}
