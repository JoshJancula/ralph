---
name: no-new-dependencies
description: Ralph is dependency-free by design. Do not introduce new pip, npm, or system packages without explicit instruction.
globs: ["**/*"]
alwaysApply: true
---

# No new dependencies

Ralph's core must run with only standard POSIX tools and `bash`. This is a hard constraint, not a preference.

## Rules

- **Do not** run `pip install`, `pip3 install`, or add anything to `requirements.txt` (includes `tiktoken` and similar).
- **Do not** add new `npm` or `yarn` packages to the dashboard without explicit instruction.
- **Do not** assume `brew install` or other system-level installs are available in CI or user environments.
- **python3** is optional-if-present. Use it only for features that already have a homegrown or `awk` fallback.
- **`rg` (ripgrep)**, **`ctags`**, **`fzf`** are optional-if-present. Guard with `command -v rg` before calling.
- **`jq`** is the one runtime dependency for the MCP server. Use it only where already required.
- Shell scripts must remain POSIX-compatible bash. Avoid bashisms that require bash 5+ without a version guard.

## Pattern for optional tools

```bash
if command -v python3 >/dev/null 2>&1; then
  python3 helper.py ...
else
  awk '...' ...  # fallback
fi
```
