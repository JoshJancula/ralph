## Bash Runtime Audit Findings

### 1. `plan-usage-summary.json` writers are susceptible to unescaped user data (ASVS V6.5.2, V10.6)
- `run-plan-core.sh` writes JSON via a here-doc that interpolates `PLAN_PATH`, `RALPH_PLAN_KEY`, `SELECTED_MODEL`, etc., directly into the document without escaping. A plan path containing quotes or newline characters would break the file and could be mis-parsed by downstream tooling that consumes `plan-usage-summary.json` (e.g., dashboard metrics). Use `jq -n` or Python `json.dumps` to guarantee valid JSON.

### 2. Debug logging to `.cursor/debug-*.log` exposes token usage to anyone with filesystem access (ASVS V6.5.2)
- When the repo contains `.cursor`, `_ralph_write_plan_usage_summary` appends raw token metrics to a fixed debug log path (`bundle/.ralph/bash-lib/run-plan-core.sh` lines 681‑685). The log line includes `SELECTED_MODEL`, invocation timing, and token counts. If that directory is readable by other users/processes, it becomes a persistent leakage point for plan metadata. Gate this logging behind a `RALPH_DEBUG_LOGGING` flag or drop the hardcoded path entirely.

### 3. MCP server defaults to unauthenticated operation unless `RALPH_MCP_AUTH_TOKEN` is set (ASVS V1.1, V1.7)
- `mcp-server.sh` prints “accepting requests without auth tokens” when `RALPH_MCP_AUTH_TOKEN` is empty and proceeds to serve any JSON-RPC request (`bundle/.ralph/mcp-server.sh` lines 770‑812). Attackers that can reach stdin (e.g., via an automation pipeline or malicious script) can enumerate or run the `ralph_run_plan` tool. Require a token by default or bind the server to a Unix socket/IPC channel that enforces the same-origin policy.

### 4. `run-plan-invoke-common` uses `eval` to append flags (ASVS V5.1.1)
- Helpers such as `run_plan_invoke_common_add_model_flag` and `run_plan_invoke_common_add_cli_resume_flags` append flags to a named array via `eval "$args_name+=(...)”` (`bundle/.ralph/bash-lib/run-plan-invoke-common.sh` lines 14‑50). While the current callers pass fixed array names, this pattern becomes dangerous if a future change allows user-controlled array names or flag strings. Replace `eval` with explicit array manipulation (pass array references or use `declare -n`) to eliminate this code injection surface.

### 5. `plan_normalize_path` accepts absolute paths without canonicalization (ASVS V4.1.1, V4.4.2)
- When a plan path begins with `/`, `plan_normalize_path` immediately prints it (`bundle/.ralph/bash-lib/plan-todo.sh` lines 17‑35). Downstream logic assumes the plan lives within the workspace (e.g., `run-plan-core.sh` line 214), but no lightweight check enforces that. A malicious local user could run `./run-plan.sh --plan /etc/passwd`, which might allow the runner to read or write files outside the workspace, especially when combined with the orchestration tooling. Canonicalize the path against the workspace root (using `realpath`) and reject paths outside of it.

### Recommended Tests
- Extend `tests/bats/mcp-server.bats` to verify the server rejects requests when `RALPH_MCP_AUTH_TOKEN` is unset by default (assert `handle_call_tool` fails if auth token missing) and to ensure `resolve_plan_path` forbids absolute/`..` plans.
- Add unit tests that run `_ralph_write_plan_usage_summary` against plan paths containing quotes/whitespace to ensure the generated JSON parses with `jq` or `python -m json.tool`.
- Create a regression test that inspects the `.cursor/debug-*.log` line only when `RALPH_DEBUG_TOKEN_LOG=1` to prove logging is optional.

### Next Steps
1. Replace the inlined JSON writers with a safe JSON serializer (`python -c 'import json, sys; print(json.dumps(...))'` or `jq -n`).
2. Introduce a `RALPH_DEFAULT_MCP_TOKEN_REQUIRED=1` gate or fail fast when `RALPH_MCP_AUTH_TOKEN` is not set.
3. Refactor the array append helpers to avoid `eval` while preserving CLI resume behavior.
4. Normalize plan paths with `realpath --relative-to` and reject outside-workspace values before arguments reach the runner binaries.
