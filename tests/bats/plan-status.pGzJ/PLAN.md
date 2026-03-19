- [ ] foo
- [x] bar
- [?] maybe
EOF
output=$(env RALPH_MCP_WORKSPACE="$PWD" bash .ralph/mcp-server.sh 2>/tmp/mcp-stderr <<EOF
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ralph_plan_status","arguments":{"workspace":".","plan_path":"${plan_dir#$PWD/}/PLAN.md"}}}
{"jsonrpc":"2.0","id":2,"method":"exit"}
EOF
)
rm -rf "$plan_dir"
printf Captured:n%sn "$output"
