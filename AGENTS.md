# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code), Cursor (cursor-agent), Codex and any AI agents when working with code in this repository.

## Overview

Ralph is a framework for organizing AI coding assistant workflows. It provides:
- **Plan-first loop:** Markdown todo lists executed by AI assistants (Cursor, Claude Code, or Codex)
- **Orchestration:** Multi-stage pipelines (research → design → implementation → review) with artifact handoffs
- **Agents:** Prebuilt agent profiles for specialized work (research, architect, implementation, code-review, qa, security)
- **Dashboard:** Optional Python UI for monitoring plan execution and artifact generation

Ralph is installed into projects via `./install.sh`. The installer copies shared scripts to `.ralph/`, runtime-specific runners to `.cursor/ralph`, `.claude/ralph`, `.codex/ralph`, and agents/rules/skills to `.cursor/agents`, `.claude/agents`, etc.

## Key Commands

### Run tests (Bats shell test suite)

```bash
# Full test suite
bash scripts/setup-test-fixtures.sh
bats tests/bats/*.bats

# Run a specific test file
bats tests/bats/run-plan-invoke.bats

# Set required env var for all runs (suppresses usage risk prompt)
RALPH_USAGE_RISKS_ACKNOWLEDGED=1 bats tests/bats/run-plan-unified.bats
```

The test suite uses Bats (Bash Automated Testing System). Tests live in `tests/bats/` and cover:
- Installation and setup (`install.bats`, `install-lib.bats`)
- Plan execution (`run-plan-*.bats`)
- Orchestration (`orchestration-*.bats`)
- Human interaction (`human-interaction.bats`)
- MCP server (`mcp-server.bats`)
- Agent scaffolding (`new-agent.bats`, `bundle-new-agent-scripts.bats`)

### Run the installer

```bash
# Full install (all runtimes + dashboard)
./install.sh

# Install to a specific target repo
./install.sh /path/to/repo

# Claude and shared scripts only (no Cursor/Codex)
./install.sh --claude --shared

# Dry-run (print what would be copied)
./install.sh -n
```

### Ralph Dashboard (Python)

```bash
cd ralph-dashboard
python3 -m pip install -e ".[dev]"
python3 -m pytest tests/ -v --cov=ralph_dashboard --cov-fail-under=80
python3 server.py  # runs on http://127.0.0.1:8123
```

The dashboard reads plan state, logs, and artifacts from `.ralph-workspace/` and provides a UI for monitoring orchestration runs.

### Validate orchestration schema

```bash
bash scripts/validate-orchestration-schema.sh <orchestration-file.orch.json>
```

## Architecture

### Bundle structure

```
bundle/
  .ralph/              # Shared across all runtimes
    run-plan.sh       # Unified plan executor (required by all)
    orchestrator.sh   # Multi-stage orchestration runner
    orchestration-wizard.sh
    cleanup-plan.sh
    new-agent.sh
    bash-lib/         # Helpers: plan-todo, run-plan-env, run-plan-invoke-*.sh, install-ops.sh, etc.
    mcp-server.sh     # Bash MCP server
    agent-config-tool.sh
  .cursor/
    ralph/            # Cursor-specific runner thin wrapper
    agents/           # Cursor agent profiles
      research/
      architect/
      implementation/
      code-review/
      qa/
      security/
  .claude/
    ralph/            # Claude Code-specific runner thin wrapper
    agents/           # Claude agent profiles (same 6 agents)
    rules/
      no-emoji.md
    skills/
      repo-context/SKILL.md
  .codex/
    ralph/            # Codex-specific runner thin wrapper
    agents/           # Codex agent profiles (same 6 agents)
```

### Agent configuration

Each prebuilt agent (research, architect, implementation, code-review, qa, security) is defined by:
- `<agent-id>/config.json` -- Ralph/orchestrator uses this (fields: name, model, description, rules, skills, allowed_tools, output_artifacts)
- `<agent-id>/<agent-id>.md` -- Claude Code native sessions use this (YAML frontmatter + instructions)

Both must be kept in sync. Agents declare:
- **model:** The model id used when running with that agent
- **rules:** Paths to constraint files (e.g., `.claude/rules/no-emoji.md` prevents emoji in code/logs)
- **skills:** Paths to skill definitions (e.g., `.claude/skills/repo-context/SKILL.md` teaches the agent about the project structure)
- **allowed_tools:** (Claude headless only) Comma-separated tool names or JSON array
- **output_artifacts:** Declared deliverables (supports `{{ARTIFACT_NS}}` and `{{PLAN_KEY}}` templates)

Validation schema is in `bundle/.claude/agents/README.md` (applies to all runtimes).

### How plans and orchestration work

1. **Single plan:** User writes a `.md` file with tasks like `- [ ] Do this` and `- [x] Done`. The runner picks the next open task, invokes the CLI assistant (Cursor/Claude/Codex), updates the plan, repeats until done.

2. **Orchestration:** A `.orch.json` file defines stages (research → architect → implementation → code-review → qa → security or custom). Each stage has:
   - `id`: stage identifier
   - `runtime`: "cursor" | "claude" | "codex"
   - `agent`: agent name to load
   - `plan`: path to that stage's plan file
   - `outputArtifacts`: declared outputs (e.g., `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/architecture.md`)

   The orchestrator runs stages sequentially, verifying artifacts exist before advancing.

3. **Session resume:** With `--cli-resume` or `RALPH_PLAN_CLI_RESUME=1`, the runner stores a `session-id.txt` and reuses the same CLI session on future runs (skips context setup, continues where assistant left off).

### Key environment variables

- `RALPH_USAGE_RISKS_ACKNOWLEDGED=1` -- Skip the one-time usage risk prompt (set in CI)
- `RALPH_PLAN_WORKSPACE_ROOT` -- Override `.ralph-workspace/` location
- `RALPH_PLAN_CLI_RESUME=1` -- Enable CLI session resume
- `RALPH_ARTIFACT_NS` -- Override artifact namespace (defaults to plan file basename)
- `RALPH_PLAN_KEY` -- Explicit plan namespace (defaults to plan file basename)
- `RALPH_HUMAN_POLL_INTERVAL=2` -- Poll interval (seconds) when waiting for offline human input
- `ORCHESTRATOR_VERBOSE=1` -- Log each orchestrator step to stderr
- `ORCHESTRATOR_DRY_RUN=1` -- Print orchestration steps without running

### Human interaction flow

When the runner needs human input:
- **TTY attached:** Prompt interactively on `/dev/tty` and continue
- **Non-TTY (orchestrator, CI):** Write `pending-human.txt` under `.ralph-workspace/sessions/<RALPH_PLAN_KEY>/`, poll until the operator edits `operator-response.txt`, then continue

All Q&A is logged to `human-replies.md` in the session directory for auditing.

## Important patterns

### Adding a new agent

Run `bash .ralph/new-agent.sh` to scaffold a new agent (prompts for name, model, description, rules, skills). This creates:
- `.<runtime>/agents/<agent-id>/config.json`
- `.<runtime>/agents/<agent-id>/<agent-id>.md`
- Rule and skill skeleton directories

Keep config.json and the .md file in sync when editing agent metadata.

### Artifact namespace placeholders

Use `{{ARTIFACT_NS}}` and `{{PLAN_KEY}}` in agent output_artifacts and orchestration stage outputArtifacts:
- `{{ARTIFACT_NS}}` → resolves from `RALPH_ARTIFACT_NS` env var (or plan basename fallback)
- `{{PLAN_KEY}}` → resolves from `RALPH_PLAN_KEY` env var (or plan basename fallback)

Example: `".ralph-workspace/artifacts/{{ARTIFACT_NS}}/architecture.md"` becomes `".ralph-workspace/artifacts/my-feature/architecture.md"`.

### MCP server

The Bash MCP server (`bash .ralph/mcp-server.sh`) exposes plan state and orchestration history as resources, allowing Claude, Cursor, or other MCP clients to query Ralph state without direct file access.

```bash
RALPH_MCP_WORKSPACE="$PWD" bash .ralph/mcp-server.sh
```

Requires `jq` for JSON parsing.

### Validation and error handling

Key scripts to understand:
- `.ralph/bash-lib/install-ops.sh` -- Installer flag parsing and validation
- `.ralph/agent-config-tool.sh` -- Agent config validation and schema checking
- `scripts/validate-orchestration-schema.sh` -- Validates `.orch.json` format

The agent-config-tool is called by all runtimes to verify agents before starting a plan run.

## Testing notes

- **Bats framework:** Each `.bats` file is a standalone test; use `load 'test_helper'` to share helpers
- **Setup/teardown:** Bats provides `setup()` and `teardown()` functions per test
- **Test fixtures:** `scripts/setup-test-fixtures.sh` generates `.ralph-workspace/` stubs for offline testing
- **CI:** GitHub Actions runs `bats tests/bats/*.bats` with `RALPH_USAGE_RISKS_ACKNOWLEDGED=1`

### Running specific tests

```bash
# Run tests matching a pattern
bats tests/bats/run-plan*.bats

# Run one test function
bats tests/bats/orchestration-integration.bats --filter "integration test for multi-stage"
```

## Quick file reference

| File | Purpose |
|------|---------|
| `.ralph/run-plan.sh` | Main plan executor (unified across Cursor/Claude/Codex) |
| `.ralph/orchestrator.sh` | Multi-stage orchestration runner |
| `.ralph/bash-lib/run-plan-invoke-*.sh` | Runtime-specific invoke logic (cursor, claude, codex) |
| `.ralph/agent-config-tool.sh` | Agent config validation and context building |
| `.ralph/orchestration.template.json` | Starter orchestration plan template |
| `.ralph/plan.template` | Starter plan template |
| `.claude/agents/README.md` | Agent configuration schema documentation |
| `ralph-dashboard/server.py` | Dashboard entry point |
| `scripts/setup-test-fixtures.sh` | Test fixture generator (creates `.ralph-workspace/`) |
| `tests/bats/*.bats` | Bats test files |

## Rules and conventions

- **Agent naming:** Lowercase with hyphens (e.g., `code-review`), no underscores or spaces
- **No emojis:** The `.claude/rules/no-emoji.md` rule (and equivalents in `.cursor`, `.codex`) forbids emoji in code, comments, and logs
- **Output artifacts:** Every agent should declare at least one output artifact so orchestration can verify completion
- **Session resumption:** Safe only in isolated environments; bare resume (without stored session ID) requires `RALPH_PLAN_ALLOW_UNSAFE_RESUME=1` to prevent session mix-up on shared machines
