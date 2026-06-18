---
name: efficient-tool-usage
description: Redirect large command output to Ralph artifact logs; report compact exit status before details.
globs: ["**/*"]
alwaysApply: true
---

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

## Targeted file reads

- Prefer reading specific line ranges over full files. For files longer than 500 lines, use offset/limit or grep to locate the section first. Large file reads (>50 KB) are a primary driver of context bloat.
- Use Grep to locate relevant code, then Read a small window (for example, 20 lines before and after). Avoid reading entire files to search for a symbol.
- When debugging test failures, read only the failing test file and the function under test, not the entire suite or source tree.
