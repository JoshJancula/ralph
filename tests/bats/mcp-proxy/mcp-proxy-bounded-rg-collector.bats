#!/usr/bin/env bats
# Coverage for the streaming bounded search collector (PLAN15).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"

setup() {
  command -v rg >/dev/null 2>&1 || skip "rg required"
  _tmp="$(mktemp -d)"
  source "$POLICY_LIB"
  source "$TOOLS_LIB"
  export RALPH_PROXY_SEARCH_SYNC_TIMEOUT_SECONDS=2
}

teardown() {
  rm -rf "$_tmp"
  unset RALPH_PROXY_SEARCH_SYNC_TIMEOUT_SECONDS
}

@test "no match: status no_match, zero lines, not capped" {
  printf 'nothing to see here\n' > "$_tmp/f.txt"
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_bounded_search_collect "$out" 65536 100 4096 -- \
    rg --line-number --no-heading --color=never "NEEDLE_NOT_PRESENT" "$_tmp"
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "no_match" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_CAPPED" = "0" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_LINES" = "0" ]
  [ ! -s "$out" ]
}

@test "exact limit: line count equal to cap is not marked capped" {
  local i
  for i in $(seq 1 10); do printf 'match NEEDLE %d\n' "$i" >> "$_tmp/f.txt"; done
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_bounded_search_collect "$out" 65536 10 4096 -- \
    rg --line-number --no-heading --color=never "NEEDLE" "$_tmp/f.txt"
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "ok" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_CAPPED" = "0" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_LINES" = "10" ]
  run wc -l < "$out"
  [ "$(tr -d ' ' <<<"$output")" = "10" ]
}

@test "limit plus one: exactly one over the line cap is reported capped" {
  local i
  for i in $(seq 1 11); do printf 'match NEEDLE %d\n' "$i" >> "$_tmp/f.txt"; done
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_bounded_search_collect "$out" 65536 10 4096 -- \
    rg --line-number --no-heading --color=never "NEEDLE" "$_tmp/f.txt"
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "ok" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_CAPPED" = "1" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON" = "line_cap" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_LINES" = "10" ]
  run wc -l < "$out"
  [ "$(tr -d ' ' <<<"$output")" = "10" ]
}

@test "genuine rg error (invalid regex) is reported as error, not a cap" {
  printf 'text\n' > "$_tmp/f.txt"
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_bounded_search_collect "$out" 65536 100 4096 -- \
    rg --line-number --no-heading --color=never "(unterminated[" "$_tmp/f.txt" || true
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "error" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_CAPPED" = "0" ]
}

@test "timeout: long-running search is reported as timeout status" {
  command -v timeout >/dev/null 2>&1 || skip "timeout binary required"
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_bounded_search_collect "$out" 65536 100 4096 -- \
    bash -c 'sleep 5; echo done' || true
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "timeout" ]
}

@test "many short lines: capture bounded by byte cap, temp file never exceeds it" {
  awk 'BEGIN { for (i=0;i<50000;i++) printf "line %d NEEDLE marker text\n", i }' > "$_tmp/f.txt"
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_bounded_search_collect "$out" 8192 100000 4096 -- \
    rg --line-number --no-heading --color=never "NEEDLE" "$_tmp/f.txt"
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "ok" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_CAPPED" = "1" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON" = "byte_cap" ]
  run wc -c < "$out"
  [ "$(tr -d ' ' <<<"$output")" -le 8192 ]
}

@test "one huge line: per-line width is enforced and reported" {
  awk 'BEGIN {
    line = "NEEDLE "
    chunk = "abcdefghijklmnopqrstuvwxyz0123456789"
    while (length(line) < 200000) line = line chunk
    print line
  }' > "$_tmp/f.txt"
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_bounded_search_collect "$out" 65536 100 4096 -- \
    rg --line-number --no-heading --color=never "NEEDLE" "$_tmp/f.txt"
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "ok" ]
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_ANY_LINE_TRUNCATED" = "1" ]
  run wc -c < "$out"
  # 4096 content bytes + 1 newline
  [ "$(tr -d ' ' <<<"$output")" -le 4097 ]
}

@test "valid UTF-8 at the per-line boundary does not corrupt the temp file" {
  python3 -c "
import sys
prefix = 'f.txt:1:NEEDLE '
pad = 'a' * (4096 - len(prefix) - 4)
line = prefix + pad + 'é日本😀'
open('$_tmp/f.txt', 'w', encoding='utf-8').write(line + '\n')
" 2>/dev/null || skip "python3 required for UTF-8 fixture generation"
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_bounded_search_collect "$out" 65536 100 4096 -- \
    rg --line-number --no-heading --color=never "NEEDLE" "$_tmp/f.txt"
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_STATUS" = "ok" ]
  run wc -c < "$out"
  [ "$(tr -d ' ' <<<"$output")" -ge 1 ]
}

@test "bounded temp file never exceeds byteCap across a large adversarial corpus" {
  awk 'BEGIN {
    for (i = 0; i < 3; i++) {
      line = "NEEDLE "
      chunk = "abcdefghijklmnopqrstuvwxyz0123456789"
      while (length(line) < 500000) line = line chunk
      print line
    }
    for (i = 0; i < 50000; i++) printf "short %d NEEDLE\n", i
  }' > "$_tmp/f.txt"
  local out="$_tmp/out.txt"
  ralph_mcp_proxy_bounded_search_collect "$out" 65536 100000 4096 -- \
    rg --line-number --no-heading --color=never "NEEDLE" "$_tmp/f.txt"
  [ "$RALPH_MCP_PROXY_GREP_COLLECT_CAPPED" = "1" ]
  run wc -c < "$out"
  [ "$(tr -d ' ' <<<"$output")" -le 65536 ]
}
