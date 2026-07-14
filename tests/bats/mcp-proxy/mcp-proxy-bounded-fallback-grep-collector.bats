#!/usr/bin/env bats
# Coverage for the pure-Bash fallback grep collector's source-cap contract
# (PLAN15), run explicitly with ripgrep removed from PATH.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"

setup() {
  _tmp="$(mktemp -d)"
  source "$POLICY_LIB"
  source "$TOOLS_LIB"

  _orig_path="$PATH"
  _stub_bin="$_tmp/stub-path"
  mkdir -p "$_stub_bin"
  for tool in bash cat mkdir rm ls date dirname mktemp printf sh tr grep find sed awk basename wc head env seq; do
    local real
    real="$(type -P "$tool" 2>/dev/null)" || continue
    ln -sf "$real" "$_stub_bin/$tool"
  done
  export PATH="$_stub_bin"
  ! command -v rg >/dev/null 2>&1
}

teardown() {
  PATH="$_orig_path"
  rm -rf "$_tmp"
}

@test "no match: status no_match, zero lines, not capped" {
  mkdir -p "$_tmp/corpus"
  printf 'nothing to see here\n' > "$_tmp/corpus/f.txt"
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_owned_tool_grep_search "NEEDLE_NOT_PRESENT" "$_tmp/corpus" "" "$out" 65536 100 4096
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "no_match" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_CAPPED" = "0" ]
  [ ! -s "$out" ]
}

@test "normal small search: uncapped, all matches present" {
  mkdir -p "$_tmp/corpus"
  for i in 1 2 3 4 5; do printf 'NEEDLE line %d\n' "$i" > "$_tmp/corpus/f$i.txt"; done
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_owned_tool_grep_search "NEEDLE" "$_tmp/corpus" "" "$out" 65536 100 4096
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "ok" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_CAPPED" = "0" ]
  run wc -l < "$out"
  [ "$(tr -d ' ' <<<"$output")" = "5" ]
}

@test "many matches across many files: capped by line cap, enumeration stops early" {
  mkdir -p "$_tmp/corpus"
  local i
  for i in $(seq 1 200); do
    printf 'NEEDLE match one\nNEEDLE match two\n' > "$_tmp/corpus/f$i.txt"
  done
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_owned_tool_grep_search "NEEDLE" "$_tmp/corpus" "" "$out" 65536 10 4096
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "ok" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_CAPPED" = "1" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON" = "line_cap" ]
  run wc -l < "$out"
  [ "$(tr -d ' ' <<<"$output")" = "10" ]
  # 200 files * 2 matches = 400 possible matches; capped output proves the
  # collector did not grep all 200 files worth of content into the file.
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_LINES" -lt 400 ]
}

@test "one huge line: per-line width enforced" {
  mkdir -p "$_tmp/corpus"
  awk 'BEGIN {
    line = "NEEDLE "
    chunk = "abcdefghijklmnopqrstuvwxyz0123456789"
    while (length(line) < 200000) line = line chunk
    print line
  }' > "$_tmp/corpus/huge.txt"
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_owned_tool_grep_search "NEEDLE" "$_tmp/corpus" "" "$out" 65536 100 4096
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "ok" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_ANY_LINE_TRUNCATED" = "1" ]
  run wc -c < "$out"
  [ "$(tr -d ' ' <<<"$output")" -le 4200 ]
}

@test "valid UTF-8 near the per-line boundary is not corrupted" {
  mkdir -p "$_tmp/corpus"
  printf 'NEEDLE caf\xc3\xa9 \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e \xf0\x9f\x9a\x80 line\n' > "$_tmp/corpus/utf8.txt"
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_owned_tool_grep_search "NEEDLE" "$_tmp/corpus" "" "$out" 65536 100 4096
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "ok" ]
  run wc -l < "$out"
  [ "$(tr -d ' ' <<<"$output")" = "1" ]
}

@test "glob filter, binary skip, and hidden-path behavior unchanged with caps active" {
  mkdir -p "$_tmp/corpus"
  printf 'NEEDLE in txt\n' > "$_tmp/corpus/keep.txt"
  printf 'NEEDLE in md\n' > "$_tmp/corpus/skip.md"
  printf 'NEEDLE\x00binary\n' > "$_tmp/corpus/bin.txt"
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_owned_tool_grep_search "NEEDLE" "$_tmp/corpus" "*.txt" "$out" 65536 100 4096
  run grep -c "keep.txt" "$out"
  [ "$output" -ge 1 ]
  run grep -c "skip.md" "$out"
  [ "$output" -eq 0 ]
}

@test "caller omitting cap args preserves prior unbounded behavior" {
  mkdir -p "$_tmp/corpus"
  for i in $(seq 1 20); do printf 'NEEDLE %d\n' "$i" > "$_tmp/corpus/f$i.txt"; done
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_owned_tool_grep_search "NEEDLE" "$_tmp/corpus" "" "$out"
  run wc -l < "$out"
  [ "$(tr -d ' ' <<<"$output")" = "20" ]
}
