#!/usr/bin/env bats
# G01: `ralph graph --help` delegates to graph-run.sh's own usage text
# instead of install.sh maintaining a second, hand-written verb list.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

GRAPH_RUN_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/graph-run.sh"

# Build a throwaway global RALPH_HOME with just enough of the bundle for the
# installed shim to exec graph-run.sh, without running the full installer.
_graph_help_fake_ralph_home() {
  local home="$1"
  mkdir -p "$home/bundle/.ralph"
  cp -R "$BATS_TEST_DIRNAME/../../../bundle/.ralph/." "$home/bundle/.ralph/"
}

# Extract the body of install.sh's here-doc-generated shim so it can be run
# standalone with an arbitrary RALPH_HOME, the same way install.sh writes it.
_graph_help_extract_shim() {
  local out="$1"
  awk '
    /^  cat > "\$tmp" <<.SHIM.$/ { flag = 1; next }
    /^SHIM$/ { flag = 0 }
    flag { print }
  ' "$REPO_ROOT/install.sh" > "$out"
}

@test "graph-run.sh --help names all eleven verbs including operator surfaces" {
  run bash "$GRAPH_RUN_SH" --help
  [ "$status" -eq 0 ]
  for verb in compile preflight run resume status render actions logs attach tui recover successor; do
    [[ "$output" == *"$verb"* ]]
  done
}

@test "graph-run.sh --help groups read-only versus mutating verbs" {
  run bash "$GRAPH_RUN_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read-only verbs"* ]]
  [[ "$output" == *"Run-state mutation verbs"* ]]
  [[ "$output" == *"Project-policy mutation verb"* ]]
  [[ "$output" == *"Viewer verb"* ]]
  # preflight/status/render/logs/attach must be listed under the read-only
  # heading block, not only somewhere else in the file.
  read_only_block="$(printf '%s\n' "$output" | awk '/Read-only verbs/{flag=1} flag{print} /^$/{if(flag)exit}')"
  for verb in compile preflight status render logs attach; do
    [[ "$read_only_block" == *"$verb"* ]]
  done
  mutating_block="$(printf '%s\n' "$output" | awk '/Run-state mutation verbs/{flag=1} flag{print} /^$/{if(flag)exit}')"
  for verb in run resume recover; do
    [[ "$mutating_block" == *"$verb"* ]]
  done
}

@test "graph-run.sh --help marks itself an internal engine entrypoint" {
  run bash "$GRAPH_RUN_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Internal engine entrypoint"* ]]
  [[ "$output" == *"operators use ralph workflow verbs"* ]]
}

@test "graph-run.sh --help shows one copyable create-to-run example on public verbs" {
  run bash "$GRAPH_RUN_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Example"* ]]
  [[ "$output" == *"ralph create workflow"* ]]
  [[ "$output" == *"ralph workflow start"* ]]
  # The removed public graph route must not be advertised.
  [[ "$output" != *"ralph graph "* ]]
}

@test "graph-run.sh rejects an unknown verb and suggests the nearest valid command" {
  run bash "$GRAPH_RUN_SH" attch
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown graph verb"* ]]
  [[ "$output" == *"Did you mean: attach?"* ]]

  run bash "$GRAPH_RUN_SH" sttus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Did you mean: status?"* ]]

  run bash "$GRAPH_RUN_SH" recovr
  [ "$status" -ne 0 ]
  [[ "$output" == *"Did you mean: recover?"* ]]
}




@test "installed ralph graph is refused as a removed public route" {
  home="$(mktemp -d)"
  _graph_help_fake_ralph_home "$home"
  shim="$(mktemp)"
  _graph_help_extract_shim "$shim"

  run env RALPH_HOME="$home" bash "$shim" graph --help
  [ "$status" -eq 2 ]
  [[ "$output" == *"'ralph graph' was removed"* ]]
  [[ "$output" == *"ralph workflow start --file"* ]]

  rm -rf "$home" "$shim"
}
