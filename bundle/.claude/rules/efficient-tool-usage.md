---
name: efficient-tool-usage
description: Redirect large command output to Ralph artifact logs; report compact exit status before details.
---
<!-- GENERATED from bundle/.ralph/rules/efficient-tool-usage.md by scripts/sync-runtime-assets.sh - edit the canonical file -->

# Efficient command output

## Large shell commands

- Commands that may emit large output (build, test, lint, migrations, full-repo searches) must not stream full logs into context. Redirect stdout and stderr to a Ralph-owned artifact log under `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/` (use `RALPH_ARTIFACT_NS`, or `RALPH_PLAN_KEY` when unset). Use descriptive filenames such as `npm-test.log` or `build-release.log`.
- Report a compact exit status in the tool result before any detailed output: exit code, a one-line outcome, and the log path. Example:

  ```bash
  ns="${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-plan}}"
  log=".ralph-workspace/artifacts/${ns}/npm-test.log"
  mkdir -p "$(dirname "$log")"
  npm test >"$log" 2>&1; ec=$?
  printf 'exit=%s log=%s\n' "$ec" "$log"
  tail -n 30 "$log"
  ```

- After redirecting output, do not paste the full log into context. For follow-up inspection, use `grep`, `head`, or `tail` on the artifact log, or read a narrow line range with the file tool.

## Long-running commands

- For commands that may outlive a tool timeout or produce large output, use the runtime's own background facility when one exists. Redirect the command's stdout and stderr to a Ralph-owned artifact log:

  ```bash
  ns="${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-plan}}"
  log=".ralph-workspace/artifacts/${ns}/build-release.log"
  mkdir -p "$(dirname "$log")"
  long_command >"$log" 2>&1
  ```

  Then inspect the log with `grep`, `head`, or `tail` rather than re-reading the whole stream.

- Claude Code provides a native background shell: `Bash` with `run_in_background: true` plus the `BashOutput` tool. Even when using that facility, redirect the output to a Ralph artifact log so it can be inspected with `grep`/`head`/`tail`.

- Cursor, Codex, OpenCode, and Antigravity do not expose a proven native background shell mode in the current Ralph builds. Use `ralph_proxy_shell_start` followed by a blocking `ralph_proxy_shell_wait` for manually monitored jobs, or use Ralph's own background path (`RALPH_BG_JOBS=1` plus `.ralph/ralph-bg.sh`).

- Do not poll `ralph_proxy_shell_status` in a loop to ask whether a command has finished. Each poll re-sends the full context and wastes a turn. Prefer a single blocking call or runner-owned `verify:` for completion.

- `ralph_proxy_shell_start`, `ralph_proxy_shell_status`, `ralph_proxy_shell_read`, `ralph_proxy_shell_wait`, and `ralph_proxy_shell_cancel` remain available as a fallback for runtimes with no native background support, and are not deprecated.

## Targeted file reads

- Prefer reading specific line ranges over full files. For files longer than 500 lines, use offset/limit or grep to locate the section first. Large file reads (>50 KB) are a primary driver of context bloat.
- Use Grep to locate relevant code, then Read a small window (for example, 20 lines before and after). Avoid reading entire files to search for a symbol.
- When debugging test failures, read only the failing test file and the function under test, not the entire suite or source tree.
