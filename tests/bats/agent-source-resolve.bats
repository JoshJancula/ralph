#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

resolve_source_lib="$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/resolve-source.sh"

setup() {
  _tmp="$(mktemp -d)"
  _ws="$_tmp/project"
  mkdir -p "$_ws/.ralph-workspace/agents"
  mkdir -p "$_ws/.ralph/agents"
  mkdir -p "$_ws/.cursor/agents/myagent"
  mkdir -p "$_ws/.claude/agents/myagent"
  mkdir -p "$_ws/.codex/agents/myagent"
  mkdir -p "$_ws/.opencode/agents/myagent"
  mkdir -p "$_ws/.agents/agents/myagent"
}

teardown() {
  rm -rf "$_tmp"
  unset RALPH_AGENT_SOURCE RALPH_AGENT_SOURCE_ORDER RALPH_HOME RALPH_DISABLE_GLOBAL_FALLBACK
}

@test "ralph-workspace probe wins in default precedence" {
  echo "# ws" > "$_ws/.ralph-workspace/agents/myagent.md"
  echo "# install" > "$_ws/.ralph/agents/myagent.md"
  echo "# native" > "$_ws/.cursor/agents/myagent.md"
  echo '{}' > "$_ws/.cursor/agents/myagent/config.json"

  source "$resolve_source_lib"
  run ralph_agent_resolve_source myagent cursor "$_ws"
  [ "$status" -eq 0 ]
  [ "$output" = "ralph-workspace	$_ws/.ralph-workspace/agents/myagent.md" ]
}

@test "ralph-install probe wins when ralph-workspace is empty" {
  echo "# install" > "$_ws/.ralph/agents/myagent.md"
  echo "# native" > "$_ws/.cursor/agents/myagent.md"

  source "$resolve_source_lib"
  run ralph_agent_resolve_source myagent cursor "$_ws"
  [ "$status" -eq 0 ]
  [ "$output" = "ralph-install	$_ws/.ralph/agents/myagent.md" ]
}

@test "ralph-install falls back to bundle when project .ralph/agents missing" {
  local ralph_home="$_tmp/home"
  mkdir -p "$ralph_home/bundle/.ralph/agents"
  echo "# bundle" > "$ralph_home/bundle/.ralph/agents/myagent.md"

  source "$resolve_source_lib"
  RALPH_HOME="$ralph_home" run ralph_agent_resolve_source myagent cursor "$_ws"
  [ "$status" -eq 0 ]
  [ "$output" = "ralph-install	$ralph_home/bundle/.ralph/agents/myagent.md" ]
}

@test "native-md probe wins when ralph-workspace and ralph-install are empty" {
  echo "# native" > "$_ws/.cursor/agents/myagent.md"

  source "$resolve_source_lib"
  run ralph_agent_resolve_source myagent cursor "$_ws"
  [ "$status" -eq 0 ]
  [ "$output" = "native-md	$_ws/.cursor/agents/myagent.md" ]
}

@test "classic-config probe wins when others are missing" {
  echo '{"name":"myagent"}' > "$_ws/.cursor/agents/myagent/config.json"

  source "$resolve_source_lib"
  run ralph_agent_resolve_source myagent cursor "$_ws"
  [ "$status" -eq 0 ]
  [ "$output" = "classic-config	$_ws/.cursor/agents/myagent/config.json" ]
}

@test "RALPH_AGENT_SOURCE_ORDER reorders probes" {
  echo "# native" > "$_ws/.cursor/agents/myagent.md"
  echo "# install" > "$_ws/.ralph/agents/myagent.md"

  source "$resolve_source_lib"
  RALPH_AGENT_SOURCE_ORDER="native-md,ralph-install" run ralph_agent_resolve_source myagent cursor "$_ws"
  [ "$status" -eq 0 ]
  [ "$output" = "native-md	$_ws/.cursor/agents/myagent.md" ]
}

@test "RALPH_AGENT_SOURCE_ORDER can skip probes" {
  echo '{"name":"myagent"}' > "$_ws/.cursor/agents/myagent/config.json"
  echo "# install" > "$_ws/.ralph/agents/myagent.md"

  source "$resolve_source_lib"
  RALPH_AGENT_SOURCE_ORDER="classic-config" run ralph_agent_resolve_source myagent cursor "$_ws"
  [ "$status" -eq 0 ]
  [ "$output" = "classic-config	$_ws/.cursor/agents/myagent/config.json" ]
}

@test "RALPH_AGENT_SOURCE override beats all probes" {
  local override="$_tmp/custom/override-agent.md"
  mkdir -p "$(dirname "$override")"
  echo "# override" > "$override"

  echo "# ws" > "$_ws/.ralph-workspace/agents/myagent.md"
  echo "# install" > "$_ws/.ralph/agents/myagent.md"
  echo "# native" > "$_ws/.cursor/agents/myagent.md"

  source "$resolve_source_lib"
  RALPH_AGENT_SOURCE="$override" run ralph_agent_resolve_source myagent cursor "$_ws"
  [ "$status" -eq 0 ]
  [ "$output" = "explicit	$override" ]
}

@test "RALPH_AGENT_SOURCE override that is not readable exits 1" {
  source "$resolve_source_lib"
  RALPH_AGENT_SOURCE="/nonexistent/path/agent.md" run ralph_agent_resolve_source myagent cursor "$_ws"
  [ "$status" -eq 1 ]
}

@test "all-missing exits non-zero" {
  source "$resolve_source_lib"
  run ralph_agent_resolve_source nonexistent cursor "$_ws"
  [ "$status" -eq 1 ]
}

@test "missing name argument exits 2" {
  source "$resolve_source_lib"
  run ralph_agent_resolve_source "" cursor "$_ws"
  [ "$status" -eq 2 ]
}

@test "missing runtime argument exits 2" {
  source "$resolve_source_lib"
  run ralph_agent_resolve_source myagent "" "$_ws"
  [ "$status" -eq 2 ]
}

@test "missing workspace argument exits 2" {
  source "$resolve_source_lib"
  run ralph_agent_resolve_source myagent cursor ""
  [ "$status" -eq 2 ]
}

@test "antigravity runtime uses .agents directory for native-md" {
  echo "# agy native" > "$_ws/.agents/agents/myagent.md"

  source "$resolve_source_lib"
  run ralph_agent_resolve_source myagent antigravity "$_ws"
  [ "$status" -eq 0 ]
  [ "$output" = "native-md	$_ws/.agents/agents/myagent.md" ]
}

@test "antigravity runtime uses .agents directory for classic-config" {
  mkdir -p "$_ws/.agents/agents/myagent"
  echo '{"name":"myagent"}' > "$_ws/.agents/agents/myagent/config.json"

  source "$resolve_source_lib"
  run ralph_agent_resolve_source myagent antigravity "$_ws"
  [ "$status" -eq 0 ]
  [ "$output" = "classic-config	$_ws/.agents/agents/myagent/config.json" ]
}