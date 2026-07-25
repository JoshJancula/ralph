---
name: plan-and-runner
description: Correct plan checkbox syntax and run-plan.sh CLI rules. Wrong checkbox format silently stalls a plan; unknown CLI args hard-fail.
globs: ["**/*.md", "**/*.bats", "**/run-plan*.sh", "**/bash-lib/**"]
alwaysApply: false
---

# Plan syntax and run-plan.sh rules

## Plan file syntax

- Open tasks: `- [ ]` — **space before `]` is required**.
- Completed tasks: `- [x]`.
- `- []` (no space) is silently ignored by the runner. The plan stalls with no error.
- Section headings and prose are allowed between tasks.

## run-plan.sh CLI

`--plan <path>` is required on every invocation. There are no positional arguments.

```bash
# Correct
.ralph/run-plan.sh --runtime cursor --plan PLAN.md --workspace .

# Wrong — parser rejects unknown/positional args
.ralph/run-plan.sh PLAN.md cursor
.ralph/run-plan.sh --runtime cursor PLAN.md
```

Documented flags (do not invent others):

| Flag | Required | Notes |
|------|----------|-------|
| `--plan <path>` | Yes | Markdown plan file |
| `--runtime <cursor\|claude\|codex\|opencode>` | Yes | CLI assistant to invoke |
| `--workspace <dir>` | No | Project root (default: cwd) |
| `--workspace-root <dir>` | No | Where `.ralph-workspace/` lives (default: `<workspace>/.ralph-workspace`) |
| `--agent <name>` | No | Specific agent profile |
| `--model <id>` | No | Override agent model |
| `--session-strategy <fresh\|resume\|reset\|compact>` | No | |
| `--cli-resume` | No | Reuse CLI session ID between todos |
| `--timeout <duration>` | No | Per-invocation timeout (default 30m) |
| `--tool-access <native\|ralph>` | No | MCP proxy mode |
| `--native-hooks <auto\|on\|off>` | No | Runtime overlay hooks |

## Project root vs workspace root

- **Project root:** Directory with `.ralph/` and plan files. Pass via `--workspace`.
- **Workspace root:** Where `.ralph-workspace/` (logs, artifacts, sessions) lives. Pass via `--workspace-root`.
- Default: workspace root = `<project-root>/.ralph-workspace`.
- Do not conflate them — plans resolve from project root, artifacts from workspace root.
