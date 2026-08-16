# AGENTS.md

**Audience:** This file is the agent contract for Claude Code, Cursor, Codex, OpenCode, Antigravity, and other AI assistants working in this repository. **Human operators** should use [README.md](README.md) and [docs/](docs/README.md). Open a docs page only when this file points you there.

## Overview

Ralph is a framework for organizing AI coding assistant workflows. It supports the Cursor, Claude, Codex, OpenCode, and Antigravity runtimes. It provides:

- **Plan-first loop:** `ralph create plan` is the main entry point. `--format classic` is the zero-dependency markdown checklist path; `--format yaml` is the YAML-frontmatter TODO queue path. For staged multi-agent work, use `ralph create orc`. Older format tokens (`standard`, `structured`, `pipeline`, `cursor`) are still accepted as aliases for `yaml`.
- **Orchestration:** Pipeline orchestration routes TODOs and stages by runtime, agent, and model across the supported runtimes (Cursor, Claude, Codex, OpenCode, Antigravity). It shares context through `produces` / `requires` artifact declarations and explicit artifact paths in TODO content so required inputs surface automatically in each stage's prompt.
- **Agents:** Prebuilt agent profiles for specialized work (research, architect, implementation, code-review, qa, security)
- **Dashboard:** Optional Node UI for monitoring plan execution and artifact generation

Ralph is installed into projects via `./install.sh`. See Reference map → [docs/INSTALL.md](docs/INSTALL.md).

> **Runtime roots (this repo):** `.cursor`, `.claude`, `.codex`, `.opencode`, and `.agents` at the repo root are **project-owned** directories for Ralph's own development workflow. `bundle/.cursor/`, `bundle/.claude/`, `bundle/.codex/`, `bundle/.opencode/`, and `bundle/.agents/` are installable framework defaults and templates for downstream projects; editing bundle paths does not change repo-root runtime config. `.ralph/` at the repo root is a symlink to `bundle/.ralph/` (shared scripts); edits under `bundle/.ralph/` are reflected there.

## Architecture

### Bundle structure

```
bundle/
  .ralph/              # Shared across all runtimes
    run-plan.sh        # Unified plan executor
    orchestrator.sh    # Multi-stage orchestration runner
    orchestration-wizard.sh
    cleanup-plan.sh
    new-agent.sh
    bash-lib/          # plan-todo, run-plan-env, run-plan-invoke-*.sh, install-ops.sh, ...
    mcp-server.sh
    agent-config-tool.sh
  .cursor/agents/      # research, architect, implementation, code-review, qa, security
  .claude/agents/      # Same six agents; config.json plus agent markdown
  .codex/agents/
  .opencode/agents/    # Same six agents; config.json plus agent markdown
  .agents/agents.md # Antigravity-native team/persona registry
  .agents/agents/ # Ralph-internal prebuilt agent metadata for Antigravity; config.json plus agent markdown; model contract: `agy models` lists models and Ralph invokes `agy --model "<exact model string from agy models>"`
```

Runtime state (logs, artifacts, sessions) lives under `.ralph-workspace/` at the **state root** (default: `<project-root>/.ralph-workspace`). The **agent workspace** defaults to the directory that invoked `run-plan.sh` and may differ from both the project and state roots. Orchestration plans often sit under `.ralph-workspace/orchestration-plans/`.

### Agent configuration and source resolver

Ralph agents are resolved by the **agent source resolver** at runtime, supporting two paths:

**Single-file canonical path (Ralph-native, default):** Use `ralph agent new <id>` to scaffold a single `.ralph/agents/<agent-id>.md` file. The resolver normalizes it without requiring `scripts/sync-runtime-assets.sh`. Probe order: `.ralph-workspace/agents/<name>.md` (override), `.ralph/agents/<name>.md` (install), native runtime `.md`, then classic `config.json`. Set `RALPH_AGENT_SOURCE_ORDER` to reorder probes or `RALPH_AGENT_SOURCE` to force an explicit path.

**Dual-file bundled-default path (with --all):** Use `ralph agent new <id> --all` to generate the full per-runtime artifact set. Then run `scripts/sync-runtime-assets.sh` to materialize:
- Canonical source: `agents/agents/<agent-id>.md` (Ralph-dev) or `bundle/.ralph/agents/<agent-id>.md` (downstream)
- Generated runtime metadata: `.<runtime>/agents/<agent-id>/config.json`
- Generated runtime native sessions: `.<runtime>/agents/<agent-id>/<agent-id>.md` or `.<runtime>/agents/<agent-id>/<agent-id>.toml`

**Claude native passthrough:** When `RALPH_AGENT_NATIVE_PASSTHROUGH=on` (auto-default) and a resolved agent is native-md for claude, the runner passes `--agent <name>` directly to the claude CLI instead of synthesizing a context block. Set `RALPH_AGENT_NATIVE_PASSTHROUGH=off` to force fallback to inlined context (useful when claude --agent support is unavailable or causes conflicts).

**CLI tools:** `ralph agent list` enumerates all agents across sources with shadowing annotations; `ralph agent show <id>` prints the resolved normalized profile. Schema: Reference map → [bundle/.claude/agents/README.md](bundle/.claude/agents/README.md).

Antigravity uses the same split: `.agents/agents.md` is generated from the canonical descriptions, while `.agents/agents/<agent-id>/config.json` is Ralph metadata used by `run-plan.sh --agent`, orchestration, MCP catalogs, output artifact validation, and model resolution.

### How plans and orchestration work

**Single plan:** A `.md` file with tasks like `- [ ] Do this` and `- [x] Done`. `.ralph/run-plan.sh --plan <path>` picks the next open task, invokes the CLI assistant, updates the plan, and repeats until done. **`--plan` is required.** The parser in `bundle/.ralph/bash-lib/run-plan/run-plan-args.sh` rejects unknown arguments and does not accept positional workspace or plan paths.

**Orchestration:** `ralph create orc` scaffolds a pipeline plan with a `pipeline:` block. Each stage declares `id`, `runtime` (`cursor` | `claude` | `codex` | `opencode` | `antigravity`), `agent`, and either inline todos or a `planFile:`. Common optional fields: `inputArtifacts`, `outputArtifacts`, `model`, `sessionResume`, `loopControl`. Stages run in order; the orchestrator verifies required artifacts exist and are non-empty before advancing. If a stage declares no `artifacts` and no `outputArtifacts`, agent `output_artifacts` are used as fallback.

Optional **`parallelStages`** groups stages into parallel waves with a sequential tail for unlisted stages. Wave syntax, failure semantics, and examples: [docs/orchestrated-ralph-example.md](docs/orchestrated-ralph-example.md).

**Session resume:** `--cli-resume` or `RALPH_PLAN_CLI_RESUME=1` reuses CLI context via `session-id.<runtime>.txt` under `.ralph-workspace/sessions/<plan-key>/`. See Reference map → [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) and [docs/README.md](docs/README.md#cli-session-resume).

**Graph mode (opt-in):** An additive, optional execution mode for DAG-structured multi-node runs. It is reached only via `execution: graph` in plan frontmatter or the `ralph graph` subcommand. No existing plan changes behavior: a plan without `execution: graph` never enters graph mode, there is no auto-upgrade, and there is no auto-derived graph when the execution field is absent. Human-facing setup, authoring, operation, and recovery guidance lives in [docs/GRAPH.md](docs/GRAPH.md), including when to pick graph over orchestration ([docs/GRAPH.md#graph-vs-orchestration](docs/GRAPH.md#graph-vs-orchestration)). `ralph create graph` / `ralph create orc` / `ralph create wizard` scaffold interactively; `ralph create plan --format graph --preset ...` is the non-interactive alternative.

**Outputs:** Plan logs under `.ralph-workspace/logs/`; generated files under `.ralph-workspace/artifacts/`. Path templates support `{{ARTIFACT_NS}}`, `{{PLAN_KEY}}`, and `{{STAGE_ID}}` (see table below).

### Graph implementation invariants

Keep these contracts intact when changing graph code. The operator-facing explanation and command reference are in [docs/GRAPH.md](docs/GRAPH.md).

- Routing is explicit: only `execution: graph` or `ralph graph` enters graph mode. Standard plans, orchestration plans, and `.orch.json` files retain their existing paths.
- An `agent` node with a `planFile` must continue to execute through the existing orchestrator stage and `run-plan.sh` loop. The graph controls work between nodes; the plan loop controls TODOs inside a node.
- The compiled graph is frozen for a run. Graph progress belongs to the ledger, while plan checkboxes remain node-local loop state. Do not mutate the live topology.
- A node is Ralph's resumable, attributable process boundary. Native runtime subagents are not ledger entries and cannot independently satisfy node completion; consensus voters always have subagent delegation disabled.
- Runtime admission, workspace creation, changeset capture, integration, verification, and publication are supervisor responsibilities. Agents must not bypass those boundaries with direct Git or publish operations.
- New graph presets select `snapshot` as the safe isolated default; omission must continue to mean `shared` for compatibility. `worktree` requires a proved sandbox boundary. Shared mutation must remain explicit, acknowledged, and serialized unless the graph declares the guarded parallel-mutation contract.
- Success requires supervisor evidence: required artifacts, scoped changesets, completion checks, gate outcomes, and publish-readiness checks as applicable. Model claims alone are not completion evidence.
- Delegation capability and threat-control details live in [bundle/.ralph/docs/DELEGATION.md](bundle/.ralph/docs/DELEGATION.md).

## Key commands

```bash
# Tests (default suite -- what CI runs)
bash scripts/run-bats.sh
bash scripts/run-bats.sh -j 8

# Install
./install.sh                          # see docs/INSTALL.md

# Plan and orchestration
.ralph/run-plan.sh --runtime cursor --plan PLAN.md
ralph run --plan path/to/pipeline.plan.md
```

Bats harness tiers, parallelism, and fixtures: [tests/README.md](tests/README.md). Dashboard development in this repo: `ralph-dashboard/` (after install: `.ralph/ralph-dashboard/`).

Recommended optional tools: `fzf` (interactive menus; `RALPH_SKIP_FZF_HINT=1` silences install hint), `python3` (CLI session resume / plan format helpers).

## Non-obvious patterns / gotchas

Rules that are easy to miss when skimming — read before running or editing Ralph.

### `run-plan.sh` CLI

- **Do** pass `--plan <path>` on every invocation; it is required.
- **Do** use only documented flags (`--runtime`, `--workspace`, `--workspace-root`, `--agent-workspace`, …).
- **Don't** pass positional plan or workspace paths. The parser in `bundle/.ralph/bash-lib/run-plan/run-plan-args.sh` rejects unknown arguments and does not accept positional paths.

### Three-root model

Ralph separates three directory roots. Do not conflate them.

| Root | Flag / env | Default | Resolves |
|------|------------|---------|----------|
| **Project root** | `--workspace` / `--project-root`; `RALPH_PROJECT_ROOT` (exported) | Current directory when cwd is the project | `.ralph/`, runtime agent configs, project-relative plan paths |
| **State root** | `--workspace-root`; `RALPH_PLAN_WORKSPACE_ROOT` | `<project-root>/.ralph-workspace` | Logs, artifacts, sessions, tool-results, security sentinels under `.ralph-workspace/` |
| **Agent workspace** | `--agent-workspace`; `RALPH_AGENT_WORKSPACE` | Directory that invoked `run-plan.sh` | Sandboxed work tree where the assistant reads/writes project files; runtime CLIs use this root |

- **Do** pass `--workspace <path>` (alias `--project-root`) when the shell cwd is not the project root.
- **Do** pass `--workspace-root <path>` (or set `RALPH_PLAN_WORKSPACE_ROOT`) when `.ralph-workspace/` must live outside the project folder.
- **Do** pass `--agent-workspace <path>` (or set `RALPH_AGENT_WORKSPACE`) when the model should work in a different tree than the invocation directory (for example a sibling checkout or monorepo package).
- **Don't** assume `--workspace` sets the agent sandbox; it only sets the Ralph project root.

**Compatibility:** `--workspace` and `--project-root` still mean the project root. `RALPH_MCP_WORKSPACE` remains the project root for MCP server startup; configs that set only `RALPH_MCP_WORKSPACE` (without the newer root env vars) continue to work.

**External plan directories:** `$HOME/.cursor/plans` and `$HOME/.claude/plans` are built-in read-only roots for Ralph MCP proxy read/search tools so agents can reference original plan files. Writes to those paths are rejected.

**Examples:**

```bash
# State root outside the project (logs/artifacts on a fast disk)
.ralph/run-plan.sh --runtime cursor --plan PLAN.md \
  --workspace /path/to/myproject \
  --workspace-root /fast-disk/ralph-state/myproject

# Agent workspace is a package inside a monorepo; project root is the monorepo root
cd /path/to/monorepo/packages/api
.ralph/run-plan.sh --runtime cursor --plan ../../PLAN.md \
  --workspace /path/to/monorepo \
  --agent-workspace /path/to/monorepo/packages/api
```

### Plan checkbox syntax

- **Do** write open tasks as `- [ ]` (space before `]`).
- **Do** mark completed tasks as `- [x]`.
- **Don't** use `- []` (no space) — the runner ignores it, so the plan can stall while lines still look like todos.

### Agent metadata

- **Single-file path:** Edit only `.ralph/agents/<agent-id>.md` (or `.ralph-workspace/agents/` for per-run overrides). Do not run sync; the source resolver adapts at runtime.
- **Dual-file path:** Edit the canonical frontmatter in `agents/agents/<agent-id>.md` or `bundle/.ralph/agents/<agent-id>.md`, then run `scripts/sync-runtime-assets.sh`.
- **Don't** hand-edit generated `config.json`, runtime agent markdown/toml, or `.agents/agents.md` (unless you are using single-file resolved agents, in which case these do not exist).
- **Do** keep `agents/agents/<agent-id>.md` and `bundle/.ralph/agents/<agent-id>.md` aligned if you are using the dual-file path for your dev/generic agent split.

### Claude cost and session defaults

- **Defaults:** `CLAUDE_PLAN_BARE=0`, `CLAUDE_PLAN_MINIMAL=1` (auth-safe minimal flags for typical subscription use).
- **Do** set `CLAUDE_PLAN_BARE=1` only for opt-in API-key workflows that need full Claude discovery.
- **Do** expect Claude CLI session rotation after `RALPH_PLAN_SESSION_MAX_TURNS` invocations (default `8`); set `0` to disable. Other runtimes are unaffected.
- **Don't** assume bare mode or minimal mode interact with hooks/MCP the way a normal Claude session does — see Reference map → [docs/TOOLING.md](docs/TOOLING.md).

### Naming and style

- **Do** name agents with lowercase and hyphens (e.g. `code-review`).
- **Don't** use underscores, spaces, or emoji in agent ids, code, comments, logs, or docs — see `.claude/rules/no-emoji.md` (also under `.cursor`, `.codex`, `.opencode`, `.agents`).

### Antigravity model contract

- **Do** list available models with `agy models` and pass the chosen exact display string unchanged to `agy --model "<exact model string from agy models>"`.
- **Don't** normalize, remap, or sort Antigravity model ids — Ralph preserves the CLI output verbatim.
- **Do** set `ANTIGRAVITY_PLAN_MODEL` or pass `--model` for non-interactive runs; saved `ralph models` entries apply only to Claude and Codex.

### Native runtime configuration preservation

Ralph preserves each runtime's native user, project, and local/private configuration chain. Runtime configurations are discovered from the Ralph project root, not the state root or agent workspace.

| Runtime | Native config sources (precedence order) | Ralph additions |
|---------|------------------------------------------|-----------------|
| **Claude** | `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`, user/global rules, skills, hooks, plugins, permissions, memory | Agent `mcp_servers` merged over ambient, then Ralph's protected `ralph` server in `ralph`/`hybrid` mode |
| **Cursor** | `.cursor/` rules, skills, hooks, settings; existing `.cursor/mcp.json` | Agent `mcp_servers` merged with agent precedence, then Ralph's protected `ralph` server |
| **Codex** | `~/.codex/config.toml`, trusted project `.codex/config.toml` (if project trusted) | Agent `mcp_servers` translated to `--config mcp_servers.<name>.*` overrides after native load |
| **OpenCode** | Global, custom, project `opencode.json` (JSONC preserved) | Agent `mcp_servers` merged into temporary `OPENCODE_CONFIG` with native settings preserved |
| **Antigravity** | `.agents/agents.md`, rules, skills, workflows; existing `.agents/mcp_config.json` | Agent `mcp_servers` merged into temporary `ANTIGRAVITY_CONFIG` only when needed |

All mutations use reversible workspace overlays or temporary config files. Byte-exact originals are restored on success, failure, timeout, and signal cleanup via runtime-config journals under `.ralph-workspace/runtime-config/<plan-key>/`.

### Agent MCP servers

Agents may declare optional `mcp_servers` in canonical frontmatter. The field accepts:
- **String references**: Names of ambient MCP servers to include (e.g., `playwright`, `github`)
- **Portable definitions**: Inline server definitions with `name`, `transport` (`stdio` or `http`), and transport-specific fields

**Precedence**: Native ambient > Agent definitions > Ralph's protected `ralph` server. Agent definitions with the same name as ambient servers override the ambient definition.

**Reserved name**: The server name `ralph` is reserved; agents cannot reference, redefine, or replace it.

**Supported transports**:
- `stdio`: `command` (required), `args` (optional array), `env` (optional map with `${ENV_VAR}` references)
- `http`: `url` (required), `headers` (optional map with `${ENV_VAR}` references)

**Secret policy**: Credential values must use `${ENV_VAR}` references. Literal secrets (values matching credential patterns) are rejected at validation. Secrets are resolved at invocation time and never written to disk longer than necessary.

**Failure behavior**: Unresolved references, invalid definitions, missing environment variables, or attempts to use the reserved `ralph` name cause validation failures before model invocation. Error messages include the runtime, agent, missing server/env name, and searched source paths.

See [docs/MCP.md](docs/MCP.md) for full syntax, portable examples, and troubleshooting. See [bundle/.claude/agents/README.md](bundle/.claude/agents/README.md) for the agent `config.json` schema including `mcp_servers`.

## Reference map (progressive disclosure)

Open these only when the task requires detail beyond this file.

| Read this | Only when |
|-----------|-----------|
| [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) | Env vars, session/resume flags, runtime `*_PLAN_*` chains, orchestrator knobs, agent source control (`RALPH_AGENT_SOURCE_ORDER`, `RALPH_AGENT_SOURCE`, `RALPH_AGENT_NATIVE_PASSTHROUGH`) |
| [docs/TOOLING.md](docs/TOOLING.md) | Ralph mode (`--ralph-mode`, `RALPH_MODE`), MCP proxy tools, shell compaction policy, native adapters, overlay journals and cleanup |
| [docs/MCP.md](docs/MCP.md) | Standalone Ralph MCP server, host wiring, third-party MCP for plan agents |
| [docs/AGENT-WORKFLOW.md](docs/AGENT-WORKFLOW.md) | Plan loop operator flow, human input, handoffs, orchestration prompts |
| [docs/GRAPH.md](docs/GRAPH.md) | Human-facing graph plan creation, authoring, execution, status, resume, checkpoints, isolation, and publishing |
| [docs/INSTALL.md](docs/INSTALL.md) | Global and in-repo install, `install.sh` flags, workspace registry, uninstall |
| [bundle/.ralph/docs/DELEGATION.md](bundle/.ralph/docs/DELEGATION.md) | Graph delegation capability model, brokered children, completion evidence, and threat controls |
| [bundle/.claude/agents/README.md](bundle/.claude/agents/README.md) | Agent `config.json` schema and validation rules (all runtimes) |
| [bundle/.agents/agents/README.md](bundle/.agents/agents/README.md) | Ralph-internal Antigravity agent metadata and model contract |

## Important patterns

### Adding a new agent

- **Single-file (Ralph-native, default):** `ralph agent new my-agent` creates only `.ralph/agents/my-agent.md` with canonical frontmatter. Use `ralph agent show my-agent` to inspect the resolved profile.
- **Dual-file (bundled):** `ralph agent new my-agent --all` scaffolds all runtime variants and runs sync automatically. For Antigravity, this updates both Ralph metadata under `.agents/agents/<agent-id>/` and the native `.agents/agents.md` registry.

Use `ralph agent list` to enumerate all agents across sources.

### Artifact namespace placeholders

| Token | Env var | Example value | Typical use |
|-------|---------|---------------|-------------|
| `{{ARTIFACT_NS}}` | `RALPH_ARTIFACT_NS` | `code-review` | Namespace from orchestration JSON or plan basename |
| `{{PLAN_KEY}}` | `RALPH_PLAN_KEY` | `code-review-01-cr1` | Plan namespace (falls back to `{{ARTIFACT_NS}}` when unset) |
| `{{STAGE_ID}}` | `RALPH_STAGE_ID` | `cr1` | Sanitized stage `id` from orchestration JSON |

Examples:

- `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/architecture.md` → `.ralph-workspace/artifacts/my-feature/architecture.md`
- `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}.md` → `.ralph-workspace/artifacts/code-review/cr1.md` (stage `cr1`)

### Ralph proxy batching (ralph/hybrid mode)

When Ralph MCP owned tools are active, batch two or more independent read/search/glob/result operations with `ralph_proxy_batch` instead of serial proxy calls. The tool accepts up to **8 read-only operations per call** (override with `RALPH_MCP_PROXY_BATCH_MAX_OPERATIONS`). Allowed operations: `ralph_proxy_read`, `ralph_proxy_grep`, `ralph_proxy_glob`, `ralph_proxy_search`, and `ralph_proxy_result_*`. Shell, async shell, edit, write, and repomap calls must stay outside the batch. After an invocation with consecutive native reads or grep-then-read sequences, the runner may feed forward a telemetry hint recommending batching on the next prompt.

### MCP server

```bash
RALPH_MCP_WORKSPACE="$PWD" bash .ralph/mcp-server.sh
```

Requires `jq`. Plan-run injection and overlays: see Reference map above.

### Validation and error handling

- `.ralph/bash-lib/install/install-ops.sh` — installer flag parsing
- `.ralph/agent-config-tool.sh` — agent config validation (all runtimes call this before plan runs)
- `scripts/validate-orchestration-schema.sh` — pipeline plan schema checks

## Testing notes

- **Framework:** Bats in `tests/bats/`; each file is standalone; use `load 'test_helper'`
- **Fixtures:** `scripts/setup-test-fixtures.sh` creates `.ralph-workspace/` stubs
- **CI:** GitHub Actions runs `bash scripts/run-bats.sh` (`bin/bats` adds `-T` for per-test durations)
- **Filter:** `bats tests/bats/run-plan/*.bats --filter "pattern"`

## Quick file reference

| File | Purpose |
|------|---------|
| `.ralph/run-plan.sh` | Main plan executor (unified across runtimes) |
| `.ralph/orchestrator.sh` | Multi-stage orchestration runner |
| `.ralph/bash-lib/run-plan/run-plan-invoke-*.sh` | Runtime-specific invoke logic |
| `.ralph/agent-config-tool.sh` | Agent config validation and context building |
| `.ralph/orchestration.template.json` | Starter orchestration template |
| `.ralph/plan-templates/classic.plan.template.md` | Starter classic plan template |
| `bundle/.claude/agents/README.md` | Agent configuration schema |
| `bundle/.agents/agents.md` | Antigravity-native team/persona registry |
| `bundle/.agents/agents/README.md` | Ralph-internal Antigravity agent metadata and model contract |
| `.ralph/ralph-dashboard/` (installed) or `ralph-dashboard/` (this repo) | Dashboard package |
| `scripts/run-bats.sh` | Bats runner (fixtures + `bin/bats` with `-T`) |
| `tests/bats/*.bats` | Bats test files |
