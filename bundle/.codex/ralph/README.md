# Codex Ralph runner

Codex support for the unified plan loop: **`.ralph/run-plan.sh --runtime codex --plan <path>`** drives one unchecked TODO per `codex exec` invocation until the plan checklist is complete (same contract as Cursor and Claude runtimes).

## Prerequisites

- Bash (for `codex-exec-prompt.sh`, which passes the prompt safely to the CLI)
- Codex CLI on PATH (`codex`), authenticated (`codex login` or `CODEX_API_KEY` for exec)
- Git repository (Codex expects a git working tree unless you override in your environment)

## Usage

From repo root:

```bash
.ralph/run-plan.sh --runtime codex --non-interactive --agent implementation --plan PATH/to/plan.md
```

Logs: `.ralph-workspace/logs/<artifact-namespace>/plan-runner-<plan-basename>.log` and `-output.log`.

## Env (summary)

| Variable | Role |
|----------|------|
| `CODEX_PLAN_CLI` | Path to `codex` binary |
| `CODEX_PLAN_SANDBOX` | `codex exec --sandbox` value (default `workspace-write`) |
| `CODEX_PLAN_NO_ADD_AGENTS_DIR` | Set to `1` to omit `codex exec --add-dir <workspace>/.ralph-workspace` (default adds `.ralph-workspace` on non-resume runs for orchestration artifacts; plan human/session files live under **`.ralph-workspace/`** and stay writable under `workspace-write`) |
| `CODEX_PLAN_MODEL` / `CURSOR_PLAN_MODEL` | Optional `--model` (skip if unset or `auto`) |
| `CODEX_PLAN_VERBOSE` | `1` mirrors script log lines to stderr |
| `CODEX_PLAN_LOG` / `CODEX_PLAN_OUTPUT_LOG` | Override log paths |
| `RALPH_ARTIFACT_NS`, `RALPH_PLAN_KEY`, `RALPH_ORCH_FILE` | Same as other Ralph runners (set by orchestrator) |

Orchestrator: **`.ralph/orchestrator.sh`** with `"runtime": "codex"` per stage. Sample: `.ralph-workspace/orchestration-plans/codex-ralph-support/codex-ralph-support-codex.orch.json`.

## Stage plan templates

`.codex/ralph/templates` matches **`.cursor/ralph/templates`** (same per-role plan templates). If you maintain both runtimes, you can replace this directory with a symlink to `.cursor/ralph/templates` to avoid duplication. Root task plans can start from **`.ralph/plan.template`**.

## New prebuilt agent

From repo root:

```bash
.codex/ralph/new-agent.sh
```

Creates `.codex/agents/<id>/` with `config.json`, `rules/README.md`, and `skills/README.md` (aligned with existing Codex agent layout).
