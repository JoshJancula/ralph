# Ralph (OpenCode stack)

OpenCode support for the unified plan loop: **`.ralph/run-plan.sh --runtime opencode --plan <path>`** drives one unchecked TODO per OpenCode invocation until the plan checklist is complete (same contract as Cursor and Claude runtimes).

## Prerequisites

- Bash (for `select-model.sh` and the OpenCode prompt wrapper)
- OpenCode CLI on PATH (`opencode`), authenticated and ready to use
- Git repository (recommended for context)

## Usage

From repo root:

```bash
.ralph/run-plan.sh --runtime opencode --non-interactive --agent implementation --plan PATH/to/plan.md
```

Logs: `.ralph-workspace/logs/<artifact-namespace>/plan-runner-<plan-basename>.log` and `-output.log`.

## Env (summary)

| Variable | Role |
|----------|------|
| `OPENCODE_PLAN_CLI` | Path to `opencode` binary (defaults to `opencode` on PATH) |
| `OPENCODE_PLAN_MODEL` / `CURSOR_PLAN_MODEL` | Optional `--model` (falls back to `select-model.sh` default; skip if unset) |
| `OPENCODE_PLAN_VERBOSE` | `1` mirrors script log lines to stderr |
| `OPENCODE_PLAN_LOG` / `OPENCODE_PLAN_OUTPUT_LOG` | Override log paths |
| `RALPH_ARTIFACT_NS`, `RALPH_PLAN_KEY`, `RALPH_ORCH_FILE` | Same as other Ralph runners (set by orchestrator) |

Orchestrator: **`.ralph/orchestrator.sh`** with `"runtime": "opencode"` per stage.

## CLI session resume

OpenCode runs can continue a previous CLI session by storing the assistant's session ID and passing it to the next invocation. Enable the feature by setting `RALPH_PLAN_CLI_RESUME=1`, passing `--cli-resume`, or answering **yes** when the interactive prompt appears while running `.ralph/run-plan.sh` in a TTY. The runner writes the session ID to `.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.opencode.txt` and reruns with the session resume flag, using the JSON demux helper (`.ralph/bash-lib/run-plan-cli-json-demux.py`), which requires Python 3; without Python 3 present the runner warns and skips the resume attempt.

For environments where you want to resume without the stored file (for example trusted CI jobs), set `RALPH_PLAN_ALLOW_UNSAFE_RESUME=1` or pass `--allow-unsafe-resume`. This lets the CLI retry without an existing session ID but may attach to an active session on shared workstations, so use it only when you control the environment.

## Stage plan templates

`.opencode/ralph/templates` matches **`.cursor/ralph/templates`** and **`.codex/ralph/templates`** (same per-role plan templates). Root task plans can start from **`.ralph/plan.template`**.
