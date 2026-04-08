# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code), Cursor (cursor-agent), Codex and any AI agents when working with code in this repository.

## Overview

Ralph is a framework for organizing AI coding assistant workflows. It provides:
- **Plan-first loop:** Markdown todo lists executed by AI assistants (Cursor, Claude Code, or Codex)
- **Orchestration:** Multi-stage pipelines (research → design → implementation → review) with artifact handoffs
- **Agents:** Prebuilt agent profiles for specialized work (research, architect, implementation, code-review, qa, security)
- **Dashboard:** Optional Node UI for monitoring plan execution and artifact generation

Ralph is installed into projects via `./install.sh`. The installer copies shared scripts to `.ralph/`, runtime-specific runners to `.cursor/ralph`, `.claude/ralph`, `.codex/ralph`, `.opencode/ralph`, and agents/rules/skills to `.cursor/agents`, `.claude/agents`, `.opencode/agents`, etc.

> **Symlink note (this repo only):** `.cursor`, `.claude`, `.codex`, and `.opencode` at the repo root are symlinks to `bundle/.cursor`, `bundle/.claude`, `bundle/.codex`, and `bundle/.opencode`. Editing files under `bundle/.cursor/` (or `bundle/.claude/`, `bundle/.codex/`, `bundle/.opencode/`) automatically updates the symlinked paths — no manual copy or sync is needed. Similarly, `.ralph/` files are hardlinked to `bundle/.ralph/`, so edits there are also immediately reflected.

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

Submodule, subtree, partial installs, and cleanup: [docs/INSTALL.md](docs/INSTALL.md).

### Run a plan (`run-plan.sh`)

Invoke **`.ralph/run-plan.sh`** with **`--plan`** (required). Pass **`--runtime`** unless **`RALPH_PLAN_RUNTIME`** is set or you rely on the interactive runtime prompt (TTY). Pass **`--workspace <path>`** for an explicit repo root; if omitted, the workspace defaults to the current working directory. The parser in `bundle/.ralph/bash-lib/run-plan-args.sh` rejects unknown arguments and does not accept positional workspace or plan paths. See [README.md](README.md) for typical commands and canonical examples.

### Ralph Dashboard (Node UI)

In this repository, develop and test from **`ralph-dashboard/`** at the repo root:

```bash
cd ralph-dashboard
npm install
npm run build
npm start
```

Use **`PORT=8124 npm start`** instead of **`npm start`** when you need a different port.

After **`install.sh`** copies Ralph into another project, the dashboard lives at **`.ralph/ralph-dashboard/`**. From that project root run **`cd .ralph/ralph-dashboard && npm install`**, then **`npm run build`** and **`npm start`** (use **`PORT=8124 npm start`** to override the port).

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
  .opencode/
    ralph/            # Opencode-specific runner thin wrapper
    agents/           # Opencode agent profiles (same 6 agents)
    rules/
      no-emoji.md
    skills/
      repo-context/SKILL.md
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
- **output_artifacts:** Default deliverable paths (supports `{{ARTIFACT_NS}}`, `{{PLAN_KEY}}`, and `{{STAGE_ID}}` templates). These are only used as a fallback when the orchestration stage does not define its own `artifacts` or `outputArtifacts`. When the stage declares its own required artifacts, the agent config `output_artifacts` are ignored entirely for that run.

Validation schema is in `bundle/.claude/agents/README.md` (applies to all runtimes).

### How plans and orchestration work

1. **Single plan:** User writes a `.md` file with tasks like `- [ ] Do this` and `- [x] Done`. The runner picks the next open task, invokes the CLI assistant (Cursor/Claude/Codex), updates the plan, repeats until done.

2. **Orchestration:** A `.orch.json` file defines stages (research → architect → implementation → code-review → qa → security or custom). Each stage has:
   - `id`: stage identifier
   - `runtime`: "cursor" | "claude" | "codex" | "opencode"
   - `agent`: agent name to load
   - `plan`: path to that stage's plan file
   - `artifacts`: required outputs for this stage (array of `{ "path": "...", "required": true }`). This is the primary artifact declaration and overrides the agent config's `output_artifacts` entirely. Paths support `{{ARTIFACT_NS}}`, `{{PLAN_KEY}}`, and `{{STAGE_ID}}` tokens.
   - `outputArtifacts`: alternative/additional artifact declarations (same format; merged with `artifacts`). Wizard-generated files use `artifacts`; use `outputArtifacts` for documentation or legacy compatibility.
   - `inputArtifacts`: paths to artifacts from earlier stages that this stage should read (not verified, only provided as context). Array of `{ "path": "..." }`.
   - `model`: optional model override for this stage; sets `CURSOR_PLAN_MODEL` / `CLAUDE_PLAN_MODEL` / `CODEX_PLAN_MODEL` for the runner invocation.
   - `sessionResume`: boolean; forwards `--cli-resume` or `--no-cli-resume` to `run-plan.sh`.

   The orchestrator runs stages sequentially, verifying artifacts exist before advancing. If a stage defines no `artifacts` and no `outputArtifacts`, the agent config's `output_artifacts` are used as a fallback.

3. **Session resume:** With `--cli-resume` or `RALPH_PLAN_CLI_RESUME=1`, the runner stores a `session-id.txt` (and related human-interaction files) under `RALPH_PLAN_SESSION_HOME/<RALPH_PLAN_KEY>/` and reuses the same CLI session on future runs (skips context setup, continues where the assistant left off). When `RALPH_PLAN_SESSION_HOME` is unset, the session root is `${RALPH_PLAN_WORKSPACE_ROOT:-<workspace>/.ralph-workspace}/sessions` (see `bundle/.ralph/bash-lib/run-plan-session.sh`), so files resolve under `<workspace>/.ralph-workspace/sessions/<plan-key>` by default. Set `RALPH_PLAN_SESSION_HOME` explicitly to use a different directory.

### Key environment variables

- `RALPH_USAGE_RISKS_ACKNOWLEDGED=1` -- Skip the one-time usage risk prompt (set in CI)
- `RALPH_PLAN_WORKSPACE_ROOT` -- Override `.ralph-workspace/` location
- `RALPH_PLAN_CLI_RESUME=1` -- Enable CLI session resume
- `RALPH_ARTIFACT_NS` -- Override artifact namespace (defaults to plan file basename)
- `RALPH_PLAN_KEY` -- Explicit plan namespace (defaults to plan file basename)
- `RALPH_PLAN_SESSION_HOME` -- Directory that holds `session-id.txt`, `pending-human.txt`, and the rest of the session artifacts. When unset, defaults to `${RALPH_PLAN_WORKSPACE_ROOT:-<workspace>/.ralph-workspace}/sessions` (workspace-local). Set explicitly to override (for example `${XDG_STATE_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/ralph/sessions` if you prefer the user config area).
- `RALPH_HUMAN_POLL_INTERVAL=2` -- Poll interval (seconds) when waiting for offline human input
- `ORCHESTRATOR_VERBOSE=1` -- Log each orchestrator step to stderr
- `ORCHESTRATOR_DRY_RUN=1` -- Print orchestration steps without running
- `RALPH_PLAN_ALLOW_UNSAFE_RESUME=1` -- Allow CLI resume without an existing session-id.txt; use only in isolated environments to avoid session mix-ups.
- `RALPH_MCP_AUTH_TOKEN` -- When set, the MCP server rejects JSON-RPC tool calls missing the matching `authToken` field (code `-32001`).
- `RALPH_MCP_ALLOWLIST` -- Comma-separated workspace/orchestration path prefixes that the MCP server will accept; requests referencing other locations are rejected.

### Human interaction flow

When the runner needs human input:
- **TTY attached:** Prompt interactively on `/dev/tty` and continue
- **Non-TTY (orchestrator, CI):** Write `pending-human.txt` under `${RALPH_PLAN_SESSION_HOME}/${RALPH_PLAN_KEY}/` (when `RALPH_PLAN_SESSION_HOME` is unset, this is under `<workspace>/.ralph-workspace/sessions/<RALPH_PLAN_KEY>` by default), poll until the operator edits `operator-response.txt`, then continue

All Q&A is logged to `human-replies.md` in the session directory for auditing.

### Session storage choices
- **Default location:** When `RALPH_PLAN_SESSION_HOME` is unset, Ralph stores `session-id.txt`, `pending-human.txt`, `operator-response.txt`, and `human-replies.md` under `${RALPH_PLAN_WORKSPACE_ROOT:-<workspace>/.ralph-workspace}/sessions/<plan-key>`. Keeping the default under `.ralph-workspace/sessions/` makes session files reachable from Codex and other sandboxes without relying on home-directory access.
- **Python 3 dependency:** CLI resume relies on the JSON demux helper which is written in Python; if Python 3 is missing the runtime logs `Warning: RALPH_PLAN_CLI_RESUME needs python3 ... running without it.` (see `bundle/.ralph/bash-lib/run-plan-invoke-*.sh`) and continues without resuming the previous session.
- **Override:** Set `RALPH_PLAN_SESSION_HOME` to a directory of your choice (for example `${XDG_STATE_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/ralph/sessions`) when you want session files outside the workspace tree. If you use Codex with a custom session home, ensure the sandbox can read that path.
- **Codex-specific note:** `bundle/.codex/ralph/codex-exec-prompt.sh` invokes `codex exec --full-auto` with `--sandbox workspace-write` and, for non-resume runs, `--add-dir` on the workspace `.ralph-workspace/` directory so material under that tree (including `.ralph-workspace/sessions/`) is visible. Resume invocations use `codex exec resume` (with a stored session id, or `--last` when `RALPH_PLAN_ALLOW_UNSAFE_RESUME=1` and bare resume applies) and do not add that extra directory flag; prefer a workspace-visible `RALPH_PLAN_SESSION_HOME` if the resume flow must read session files from inside the Codex process.

## Important patterns

### Adding a new agent

Run `bash .ralph/new-agent.sh` to scaffold a new agent (prompts for name, model, description, rules, skills). This creates:
- `.<runtime>/agents/<agent-id>/config.json`
- `.<runtime>/agents/<agent-id>/<agent-id>.md`
- Rule and skill skeleton directories

Keep config.json and the .md file in sync when editing agent metadata.

### Artifact namespace placeholders

Use these tokens in `artifacts`, `outputArtifacts`, and agent `output_artifacts` paths:

| Token | Env var | Example value | Typical use |
|-------|---------|---------------|-------------|
| `{{ARTIFACT_NS}}` | `RALPH_ARTIFACT_NS` | `code-review` | Namespace from the orchestration JSON or plan basename |
| `{{PLAN_KEY}}` | `RALPH_PLAN_KEY` | `code-review-01-cr1` | Plan namespace from `RALPH_PLAN_KEY` (falls back to `{{ARTIFACT_NS}}` when unset) |
| `{{STAGE_ID}}` | `RALPH_STAGE_ID` | `cr1` | Sanitized stage `id` from the orchestration JSON |

Examples:
- `".ralph-workspace/artifacts/{{ARTIFACT_NS}}/architecture.md"` → `".ralph-workspace/artifacts/my-feature/architecture.md"`
- `".ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}.md"` → `".ralph-workspace/artifacts/code-review/cr1.md"` (when run as stage `cr1`)

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
| `.ralph/bash-lib/run-plan-invoke-*.sh` | Runtime-specific invoke logic (cursor, claude, codex, opencode) |
| `.ralph/agent-config-tool.sh` | Agent config validation and context building |
| `.ralph/orchestration.template.json` | Starter orchestration plan template |
| `.ralph/plan.template` | Starter plan template |
| `.claude/agents/README.md` | Agent configuration schema documentation |
| `.ralph/ralph-dashboard/` (installed) or `ralph-dashboard/` (this repo) | Dashboard package; `cd` there, then `npm install`, `npm run build`, and `npm start` |
| `scripts/setup-test-fixtures.sh` | Test fixture generator (creates `.ralph-workspace/`) |
| `tests/bats/*.bats` | Bats test files |

## Rules and conventions

- **Agent naming:** Lowercase with hyphens (e.g., `code-review`), no underscores or spaces
- **No emojis:** The `.claude/rules/no-emoji.md` rule (and equivalents in `.cursor`, `.codex`, `.opencode`) forbids emoji in code, comments, and logs
- **Output artifacts:** Every agent should declare at least one output artifact so orchestration can verify completion
- **Session resumption:** Safe only in isolated environments; bare resume (without stored session ID) requires `RALPH_PLAN_ALLOW_UNSAFE_RESUME=1` to prevent session mix-up on shared machines
