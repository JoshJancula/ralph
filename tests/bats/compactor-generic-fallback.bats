#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

COMPACTORS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/compactors.sh"

load_compactors() {
  # shellcheck source=/dev/null
  source "$COMPACTORS_LIB"
}

build_large_generic_stdout() {
  local filler_line i stdout
  # Avoid grep-style file:line shapes so shape detection does not preempt generic_large.
  filler_line="detail chunk padding lorem ipsum dolor sit amet consectetur $(printf 'x%.0s' {1..60})"
  stdout=""
  for i in $(seq 1 50); do
    stdout+="${filler_line} seq=${i}"$'\n'
  done
  stdout+="middle filler before error"$'\n'
  stdout+="ERROR: module xyz failed to compile"$'\n'
  stdout+="middle filler after error"$'\n'
  for i in $(seq 51 80); do
    stdout+="${filler_line} seq=${i}"$'\n'
  done
  stdout+="FINAL SUMMARY: build complete with warnings"
  printf '%s' "$stdout"
}

path_without_python3() {
  local entry result=""
  local IFS=:
  for entry in $PATH; do
    if [ -x "$entry/python3" ] || [ -x "$entry/python" ]; then
      continue
    fi
    result+="${entry}:"
  done
  printf '%s' "${result%:}"
}

@test "generic_large fallback: output below threshold is not compacted" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  load_compactors
  export RALPH_COMPACT_STDOUT="small output for unknown command"
  export RALPH_COMPACT_STDERR=""
  local result
  result="$(ralph_compact_shell_output "custom-build-tool --verbose" 0)"

  printf '%s\n' "$result" | jq -e '
    .status == "not compacted"
    and .compacted == false
    and .family == null
    and .stdout == "small output for unknown command"
  '
}

@test "generic_large fallback: output above threshold compacts with family generic_large" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  load_compactors
  local stdout result
  stdout="$(build_large_generic_stdout)"
  export RALPH_COMPACT_STDOUT="$stdout"
  export RALPH_COMPACT_STDERR=""
  export RALPH_COMPACT_GENERIC_THRESHOLD_BYTES=200
  result="$(ralph_compact_shell_output "custom-build-tool --verbose" 1)"

  printf '%s\n' "$result" | jq -e '
    .family == "generic_large"
    and .status == "compacted"
    and .compacted == true
    and (.stdout | test("\\.\\.\\. \\([0-9]+ line\\(s\\) omitted\\) \\.\\.\\."))
  '
}

@test "generic_large fallback: extracts error lines from omitted middle region" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  load_compactors
  local stdout result compacted_text
  stdout="$(build_large_generic_stdout)"
  export RALPH_COMPACT_STDOUT="$stdout"
  export RALPH_COMPACT_STDERR=""
  export RALPH_COMPACT_GENERIC_THRESHOLD_BYTES=200
  result="$(ralph_compact_shell_output "custom-build-tool --verbose" 1)"
  compacted_text="$(printf '%s' "$result" | jq -r '.stdout')"

  [[ "$compacted_text" == *"important line(s) extracted from omitted region:"* ]]
  [[ "$compacted_text" == *"ERROR: module xyz failed to compile"* ]]
  [[ "$compacted_text" == *"FINAL SUMMARY: build complete with warnings"* ]]
}

@test "generic_large fallback: fail-open passes raw output through when python3 is absent" {
  command -v jq >/dev/null || skip "jq required"

  local fake_bin no_python_path stdout result jq_path
  fake_bin="$(mktemp -d)/bin"
  mkdir -p "$fake_bin"
  jq_path="$(command -v jq)"
  ln -s "$jq_path" "$fake_bin/jq"
  no_python_path="$(path_without_python3)"
  [ -n "$no_python_path" ] || skip "could not build PATH without python3"
  PATH="$fake_bin:$no_python_path" command -v python3 >/dev/null && skip "python3 still visible after PATH filter"

  stdout="$(build_large_generic_stdout)"
  result="$(
    env PATH="$fake_bin:$no_python_path" \
      RALPH_COMPACTORS_LIB_DIR="$REPO_ROOT/bundle/.ralph/bash-lib" \
      RALPH_COMPACT_STDOUT="$stdout" \
      RALPH_COMPACT_STDERR="" \
      RALPH_COMPACT_GENERIC_THRESHOLD_BYTES=200 \
      bash -c '
        # shellcheck source=/dev/null
        source "$1"
        ralph_compact_shell_output "custom-build-tool --verbose" 1
      ' _ "$COMPACTORS_LIB"
  )"

  printf '%s\n' "$result" | jq -e '
    .status == "not compacted"
    and .compacted == false
    and .family == null
    and .stdout == $original
  ' --arg original "$stdout"

  rm -rf "$(dirname "$fake_bin")"
}

@test "failure_aware: non-zero exit compacts below generic threshold with error preserved" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  load_compactors
  local stdout result compacted_text
  stdout="$(build_large_generic_stdout)"
  export RALPH_COMPACT_STDOUT="$stdout"
  export RALPH_COMPACT_STDERR=""
  export RALPH_COMPACT_GENERIC_THRESHOLD_BYTES=999999
  result="$(ralph_compact_shell_output "custom-build-tool --verbose" 1)"
  compacted_text="$(printf '%s' "$result" | jq -r '.stdout')"

  printf '%s\n' "$result" | jq -e '
    .family == "failure_aware"
    and .status == "compacted"
    and .compacted == true
    and .exit_status == 1
  '
  [[ "$compacted_text" == *"ERROR: module xyz failed to compile"* ]]
  [[ "${#compacted_text}" -lt "${#stdout}" ]]
}

@test "failure_aware: RALPH_COMPACT_FAILURE=0 passes raw output through" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  load_compactors
  local stdout result
  stdout="$(build_large_generic_stdout)"
  export RALPH_COMPACT_STDOUT="$stdout"
  export RALPH_COMPACT_STDERR=""
  export RALPH_COMPACT_GENERIC_THRESHOLD_BYTES=999999
  export RALPH_COMPACT_FAILURE=0
  result="$(ralph_compact_shell_output "custom-build-tool --verbose" 1)"

  printf '%s\n' "$result" | jq -e '
    .status == "not compacted"
    and .compacted == false
    and .stdout == $original
  ' --arg original "$stdout"
}
