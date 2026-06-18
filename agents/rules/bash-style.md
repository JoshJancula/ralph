---
name: bash-style
description: Shell scripts must use set -euo pipefail, subsystem-prefixed function names, source guards, optional-tool guards, and bash-4 compatibility unless guarded.
globs: ["**/*.sh", "**/*.bats"]
alwaysApply: false
---

# Bash style for Ralph scripts

## Every executable script

- **Set `set -euo pipefail`** immediately after the shebang. No exceptions.
- If the script uses undefined variables intentionally, disable `u` for that specific command and re-enable it immediately after.
- Use `IFS=$'\n\t'` when splitting lines, never rely on the default `IFS` for loops that read filenames or paths.

## Function naming

- Prefix every function with its subsystem to avoid collisions in sourced environments.
  - `run_plan_*` for plan-runner helpers
  - `install_ops_*` for install logic
  - `agent_config_*` for agent configuration helpers
  - `sync_assets_*` for runtime-asset sync logic
  - `validate_*` for schema and input validators
- Keep function names lowercase with underscores.

## Sourced libraries

- Files under `bash-lib/` or any file intended to be `source`d rather than executed directly must include a **source-guard**:

  ```bash
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "This file is meant to be sourced, not executed." >&2
    exit 1
  fi
  ```

- Sourced files should not call `set -euo pipefail` themselves unless they are the top-level entry point; they inherit the caller's shell options.

## Python Usage
When adding / invoking python scripts in bash DO NOT code full python scripts in bash. Create a .py for that, it is an awful code smell to see lots of python scripts as strings in bash. One - two liners of python in a string is accepatable, 10 is a sin.

## Optional tools

- Guard every invocation of an optional tool with `command -v <tool>` and provide a clear fallback or error message.
  - `python3` — optional for session helpers and CLI resume; print a helpful message when missing.
  - `rg` (ripgrep) — optional for fast search; fall back to `grep` or `find`.
  - `ctags` — optional for symbol indexing; skip indexing if absent.
  - `fzf` — optional for interactive menus; skip the interactive step if absent.
- `jq` is acceptable **only where the codebase already requires it** (for example agent-config parsing in `bundle/.ralph/bash-lib/agent-config/`). Do not introduce new `jq` dependencies in scripts that currently work without it.

## Bash version compatibility

- Do not use bash-5-only features (for example `nameref` with `declare -n`, `mapfile` with `-d`, or `shopt` options added in 5.0) without an explicit version guard:

  ```bash
  if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
    echo "This feature requires bash 5+." >&2
    exit 1
  fi
  ```

- Prefer POSIX-compatible constructs when they are equally readable (`printf` over `echo -e`, `[` over `[[` for simple tests).
- Test all shell changes with the default bats suite (`bash scripts/run-bats.sh`) before submitting.
