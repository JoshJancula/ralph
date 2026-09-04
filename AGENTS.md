# AGENTS.md

**Audience:** This file is the agent contract for Claude Code, Cursor, Codex, OpenCode, Antigravity, and other AI assistants working in this repository. **Human operators** should use [README.md](README.md) and [docs/](docs/README.md). Open a docs page only when this file points you there.

## Overview

Ralph is a framework for organizing AI coding assistant workflows. It supports the Cursor, Claude, Codex, OpenCode, and Antigravity runtimes. It provides:

- **Leaf plans:** One TODO loop with durable verification. Create with `ralph create plan` (`--format classic` or `--format yaml`). Run with `ralph run --plan <path>` or `.ralph/run-plan.sh --plan <path>`. Older format tokens (`standard`, `structured`, `pipeline`, `cursor`) remain silent aliases for `yaml`.
- **Workflows:** Reusable SDLC shapes (`kind: workflow`, `mode: sequential|dependency`) that coordinate a series of attributable plan runs plus supervisor control. Create with `ralph create workflow`; start with `ralph workflow start`. Task-based starts use `--task`; supplied-plan starts use `--plan`. See [docs/WORKFLOWS.md](docs/WORKFLOWS.md).
- **Runtime agents:** The selected runtime supplies the actual agent session. Runtime-native subagents, teams, rules, skills, hooks, plugins, MCP, permissions, and memory remain owned by that runtime. Stage guidance is inline `instructions:` on the workflow—not a separate public role resource.
- **Dashboard:** Optional Node UI for monitoring plan execution and artifact generation.

Ralph is installed into projects via `./install.sh`. See Reference map → [docs/INSTALL.md](docs/INSTALL.md).

> **Runtime roots (this repo):** `.cursor`, `.claude`, `.codex`, `.opencode`, and `.agents` at the repo root are **project-owned** directories for Ralph's own development workflow. `bundle/.cursor/`, `bundle/.claude/`, `bundle/.codex/`, `bundle/.opencode/`, and `bundle/.agents/` are installable framework defaults and templates for downstream projects; editing bundle paths does not change repo-root runtime config. `.ralph/` at the repo root is a symlink to `bundle/.ralph/` (shared scripts); edits under `bundle/.ralph/` are reflected there.

## Architecture

### Bundle structure

```
bundle/
  .ralph/              # Shared across all runtimes
    run-plan.sh        # Unified plan executor (leaf TODO loop)
    orchestrator.sh    # Sequential engine (classic orchestration internals)
    graph-run.sh       # Dependency engine entry
    cleanup-plan.sh
    workflows/         # Bundled reusable SDLC definitions
    bash-lib/          # plan-todo, run-plan-*, workflow/*, graph/*, install-ops, ...
    mcp-server.sh
  .cursor/              # runtime-owned rules, skills, hooks, and settings
  .claude/              # runtime-owned rules, skills, hooks, and settings
  .codex/               # runtime-owned rules, skills, hooks, and settings
  .opencode/            # runtime-owned rules, skills, hooks, and settings
  .agents/              # runtime-owned Antigravity rules, skills, hooks, and settings
```

Runtime state (logs, artifacts, sessions, workflow registry runs) lives under `.ralph-workspace/` at the **state root** (default: `<project-root>/.ralph-workspace`). The **agent workspace** defaults to the directory that invoked `run-plan.sh` and may differ from both the project and state roots.

### How plans and workflows work

**Leaf plan:** A `.md` file with tasks like `- [ ] Do this` and `- [x] Done`. `.ralph/run-plan.sh --plan <path>` picks the next open task, invokes the CLI assistant, updates the **mutable control plan**, and repeats until done. **`--plan` is required.** The parser in `bundle/.ralph/bash-lib/run-plan/run-plan-args.sh` rejects unknown arguments and does not accept positional workspace or plan paths.

**Workflow:** A reusable definition under project, global, or bundled resolution (`kind: workflow`). `ralph workflow start <id> --task "..."` or `--plan <file>` (auto-detects: no TODOs = task text, has TODOs = leaf plan) materializes a registry run, freezes immutable input, and dispatches to the Sequential (`orchestrator.sh`) or Dependency (`graph-run.sh`) engine. Stages declare `id`, optional `runtime` / `model`, inline `instructions:`, artifacts, `planner` / `planFrom` / `planInput`, and supervisor nodes (`integrate`, `join`, `gate`, `approval`, and related). Public create routes are only `ralph create plan` and `ralph create workflow` (`--mode sequential|dependency`).

**Session resume (leaf):** `--cli-resume` or `RALPH_PLAN_CLI_RESUME=1` reuses CLI context via `session-id.<runtime>.txt` under `.ralph-workspace/sessions/<plan-key>/`. Workflow outer-run resume is `ralph workflow resume <run-id>` (same control plan). See Reference map → [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) and [docs/WORKFLOWS.md](docs/WORKFLOWS.md).

**Outputs:** Plan logs under `.ralph-workspace/logs/`; generated files under `.ralph-workspace/artifacts/`. Path templates support `{{ARTIFACT_NS}}`, `{{PLAN_KEY}}`, and `{{STAGE_ID}}` (see table below).

### Developer invariants

Keep these contracts intact when changing Ralph code or docs. Operator journeys live in [docs/WORKFLOWS.md](docs/WORKFLOWS.md).

- **Workflows coordinate durable plan runs.** A workflow is not itself a TODO checklist. It schedules attributable leaf-plan executions (and supervisor nodes) under one outer run ID. `ralph run --plan` remains the right tool for a single trusted leaf plan.
- **Generated and operator-supplied plans are supervisor-validated immutable input.** Planner output and `--plan` imports are byte-copied/hashed under the registry run. Checkbox progress never rewrites those source bytes. Changing a supplied plan requires a new run.
- **planFrom / planInput consumers and rework clones execute mutable control copies through `run-plan`.** The consumer binds a verified immutable source, then runs TODOs on a durable control copy. Resume continues that same control copy. Review rework clones get a **fresh** control copy of the **same** immutable source (plus prior review verdict)—never a new invented source.
- **Approval and input requests are supervisor records, not model claims.** Outstanding `approval` / `input` (and Dependency `permission`) actions are create-once files under `<registry-run>/actions/{requests,decisions,consumed}/` with run/stage/attempt identity binding. Stage success is refused while a request it created is outstanding or answered-but-unconsumed. Model prose cannot satisfy a gate.
- **Native runtime subagents never replace or satisfy plan TODOs or stage completion.** They are opaque to Ralph's ledger. The parent runtime agent remains responsible for every write, verification step, declared artifact, and completion decision. Consensus voters compile with native subagents forced off.
- **Source-kind routing is explicit.** Workflow resolution source kinds are `project` | `global` | `bundled`. Plan-backed stages surface `planSourceKind` `generated` | `provided`. Legacy `.orch.json` / pipeline / graph JSON imports may appear as `legacy-orchestration` and still start through the workflow layer. Public authored frontmatter uses `mode: sequential|dependency`; names such as `graph`, `orchestration`, `checkpoint`, and `humanAck` persist only in internal engines, legacy inputs, loader warnings, or compiled/materialized formats—not as public product vocabulary for new authoring.
- **Common action identity and consumption.** Request IDs bind run + stage + attempt (permissions also bind nonce/runtime). Decisions are append-only audit history. Answers inject once into the same TODO's next fresh invocation and are marked consumed; replay/conflict reuse is refused.
- **Exit 3 is a successful persisted wait.** When an approval or operator-input wait is recorded, the CLI exits `3` (not failure). Follow `ralph workflow actions list|respond`, then `resume`. Exit `2` is unknown usage or a removed public route (exact replacement on stderr). Exit `1` is validation/refusal/runtime failure. Exit `0` is success.
- **Approval `changesTarget` and reset feedback.** Authored `type: approval` nodes declare `changesTarget` (one upstream executable or planner ancestor). `request-changes` blocks the run (`human-changes-requested`); the sole next action is `ralph workflow reset <run-id> --stage <changesTarget>`, which carries bounded human feedback into the next fresh attempt and prints `resume` as the follow-on action.
- **Frozen topology.** The compiled/materialized run graph is frozen. Do not mutate live topology. Rework loops are unrolled at compile time; they are never live cycles. Progress belongs to the ledger and control-plan checkboxes—not to rewriting the workflow definition mid-run.
- **Supervisor evidence.** Success requires required artifacts, scoped changesets, completion checks, gate outcomes, and publish-readiness as applicable. Model claims alone are not completion evidence. Runtime admission, workspace creation, changeset capture, integration, verification, and publication are supervisor responsibilities.
- **Three-root model and native runtime configuration** remain mandatory (see below). Direct internal scripts (`.ralph/run-plan.sh`, `orchestrator.sh`, `graph-run.sh`, and bash-lib helpers) stay supported for development and tests; public operators use `ralph create|run|workflow|safety|plugin`.

Named tooling profiles (`raw`, `ralph-read-heavy`, `ralph-compact`, `ralph-aggressive`) resolve per agent stage from `pipeline.tooling` and are orthogonal to `contextBudget`. Delegation capability details: [bundle/.ralph/docs/DELEGATION.md](bundle/.ralph/docs/DELEGATION.md).

## Key commands

```bash
# Tests (default suite -- what CI runs)
bash scripts/run-bats.sh
bash scripts/run-bats.sh -j 8

# Create
ralph create plan                 # leaf plan
ralph create workflow             # reusable workflow (--mode sequential|dependency)

# Leaf plan run
ralph run --plan path/to/leaf.plan.md
.ralph/run-plan.sh --runtime cursor --plan PLAN.md

# Workflow lifecycle
ralph workflow list
ralph workflow show feature-delivery
ralph workflow start feature-delivery --task "..." --yes
ralph workflow start feature-delivery --plan ./specs/my-spec.md --yes   # no TODOs: content becomes task
ralph workflow start plan-delivery --plan path/to/leaf.plan.md --yes    # has TODOs: used as leaf plan
ralph workflow status <run-id>
ralph workflow resume <run-id>
ralph workflow actions list <run-id>

# Safety / plugins
ralph safety status
ralph plugin list

# Install
./install.sh                      # see docs/INSTALL.md
```

Unknown usage and retired public commands exit `2` with one exact replacement on stderr. Do not document retired commands as current.

Bats harness tiers, parallelism, and fixtures: [tests/README.md](tests/README.md). Dashboard development in this repo: `ralph-dashboard/` (after install: `.ralph/ralph-dashboard/`).

Recommended optional tools: `fzf` (interactive menus; `RALPH_SKIP_FZF_HINT=1` silences install hint), `python3` (CLI session resume / plan format helpers).

## Non-obvious patterns / gotchas

Rules that are easy to miss when skimming — read before running or editing Ralph.

### `run-plan.sh` CLI

- **Do** pass `--plan <path>` on every invocation; it is required.
- **Do** use only documented flags (`--runtime`, `--workspace`, `--workspace-root`, `--agent-workspace`, …).
- **Don't** pass positional plan or workspace paths. The parser in `bundle/.ralph/bash-lib/run-plan/run-plan-args.sh` rejects unknown arguments and does not accept positional paths.
- **Don't** pass workflow-shaped inputs to `ralph run --plan`; use `ralph workflow start` instead.

### Durable TODO continuations (background jobs)

- **Do** leave `RALPH_BG_JOBS` unset or `0` unless you intentionally opt in (default off). Human-answer and post-verify continuation are not gated by this flag.
- **Do** prefer plan/TODO strict `verify:` for completion gates. Background a command only when waiting inside the agent turn would cost extra model turns.
- **Do** use `.ralph/ralph-bg.sh '<command>'` then end the turn without a completion marker when `RALPH_BG_JOBS=1`. Tier 1 keeps the same session via the runtime Stop / stop hook; tier 2 resumes the same TODO by exact captured session id.
- **Don't** author agent-side polling loops, and don't treat async MCP shell (`ralph_proxy_shell_start` / `_status`) as the automation path for durable waits.
- **Don't** assume `RALPH_PLAN_SESSION_STRATEGY=fresh` restarts a suspended mid-TODO wait from scratch — `fresh` isolates the next distinct TODO; mid-TODO continuations bind exact session identity (or inject a bounded result once when capture is degraded).
- Env vars and tiers: [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md#background-jobs-and-durable-todo-continuations). Stop hook contract: [docs/TOOLING.md](docs/TOOLING.md#background-jobs-and-stop-hook-continuation). MCP surface unchanged: [docs/MCP.md](docs/MCP.md).

### Three-root model

Ralph separates three directory roots. Do not conflate them.

| Root | Flag / env | Default | Resolves |
|------|------------|---------|----------|
| **Project root** | `--workspace` / `--project-root`; `RALPH_PROJECT_ROOT` (exported) | Current directory when cwd is the project | `.ralph/`, runtime agent configs, project-relative plan paths |
| **State root** | `--workspace-root`; `RALPH_PLAN_WORKSPACE_ROOT` | `<project-root>/.ralph-workspace` | Logs, artifacts, sessions, tool-results, workflow registry, security sentinels under `.ralph-workspace/` |
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

### Stage guidance (not roles)

- **Do** put SDLC guidance in workflow stage `instructions:` (non-empty text). Supervisor nodes reject instructions, TODOs, runtime/model, and mutation scopes.
- **Don't** add `role:`, profile-selecting `agent:`, or role-based dynamic planner fields. Those surfaces were removed; use inline instructions and planner/planFrom/planInput contracts instead.
- **Don't** invent public role or agent-migration CLI flows—they exit `2`.
- **Runtime agents:** Preserve native runtime configuration. Do not create or modify runtime-native agent definitions as part of Ralph workflow work; use the vendor's documentation for native agents, teams, and subagents.

### Shared instruction fragments

- **Do** reuse cross-workflow stage guidance with `{{INCLUDE:<name>}}` inside a stage's `instructions:` block. Fragments live in `bundle/.ralph/workflows/_fragments/<name>.md` and are expanded on the raw workflow source before parsing, so everything downstream sees ordinary instruction text.
- **Do** add a new fragment when the same guidance would otherwise be restated in more than one workflow. Current set: `scope-discipline`, `evidence-citation`, `evaluator-contract`, `investigation-rigor`, `plan-budget`, `qa-independence`.
- **Don't** paste the same guidance into several workflows by hand — that duplication is what let the bundled workflows drift apart.
- **Don't** use a path as a fragment name. The token grammar admits a bare slug only, resolved inside the bundled `_fragments` directory; anything else fails closed.
- **Don't** nest a fragment inside another fragment; that is rejected.

### Review verdicts and the defect ledger

- **Do** have evaluator stages emit `findings` (`id`, `severity`, `summary`, `evidence`, `requiredFix`, `verification`, `disposition`). The legacy `feedback: ["string"]` shape still validates and is normalized into blocking findings.
- **Do** supply a `verification` command on a blocking finding whenever one can be written: it becomes the synthesized rework TODO's verification.
- **Do** re-state a prior finding with the same `id` and a `disposition` of `fixed` or `wontfix` to close it. Findings accumulate in `.ralph-workspace/artifacts/<ns>/defect-ledger.json`; an unmentioned blocking finding stays open and a verdict cannot reach `approved` while one is.
- **Don't** rely on the newest verdict alone carrying the full defect set — the rework brief is rendered from the ledger, not from one verdict.
- **Reason code `rework-stalled`:** a blocking finding open for `RALPH_REWORK_STALL_ROUNDS` rounds (default `3`) fails the run instead of spending the remaining rework budget. `0` disables it.

### Verdict gates

- **Do** end a delivery workflow with a model-free `type: gate` node that asserts an evaluator verdict. Every bundled delivery workflow now does: `qa` writes `qa-verdict.json` next to its prose handoff, and `qa-gate` runs `python3 .ralph/python/evaluator_contract.py require-approved` against it, so a QA failure makes the run non-zero instead of exiting `0`.
- **Do** use `{{ARTIFACT_NS}}` / `{{STAGE_ID}}` in a `verificationProfiles` step command; gate steps resolve them before execution.
- **Don't** rely on a stage's prose handoff to gate anything. `qa-handoff.md` had no schema and no consumer, which is why a run reporting FAIL on every check still succeeded.
- **Known residual:** `integrate` publishes on `review-approved`, so the QA gate fails the run *after* publication. Pre-publish QA needs a downstream node to run inside an upstream node's candidate snapshot, which no authoring surface exposes yet.

### Claude cost and session defaults

- **Defaults:** `CLAUDE_PLAN_BARE=0`, `CLAUDE_PLAN_MINIMAL=1` (auth-safe minimal flags for typical subscription use).
- **Do** set `CLAUDE_PLAN_BARE=1` only for opt-in API-key workflows that need full Claude discovery.
- **Do** expect Claude CLI session rotation after `RALPH_PLAN_SESSION_MAX_TURNS` invocations (default `8`); set `0` to disable. Other runtimes are unaffected.
- **Don't** assume bare mode or minimal mode interact with hooks/MCP the way a normal Claude session does — see Reference map → [docs/TOOLING.md](docs/TOOLING.md).

### Naming and style

- **Do** name workflow and stage ids with lowercase and hyphens (e.g. `feature-delivery`, `plan-implementation`).
- **Don't** use underscores, spaces, or emoji in ids, code, comments, logs, or docs — see `.claude/rules/no-emoji.md` (also under `.cursor`, `.codex`, `.opencode`, `.agents`).

### Antigravity model contract

- **Do** list available models with `agy models` and pass the chosen exact display string unchanged to `agy --model "<exact model string from agy models>"`.
- **Don't** normalize, remap, or sort Antigravity model ids — Ralph preserves the CLI output verbatim.
- **Do** set `ANTIGRAVITY_PLAN_MODEL` or pass `--model` for non-interactive runs; saved `ralph models` entries apply only to Claude and Codex.

### Native runtime configuration preservation

Ralph preserves each runtime's native user, project, and local/private configuration chain. Runtime configurations are discovered from the Ralph project root, not the state root or agent workspace.

| Runtime | Native config sources (precedence order) | Ralph additions |
|---------|------------------------------------------|-----------------|
| **Claude** | `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`, user/global rules, skills, hooks, plugins, permissions, memory | Native runtime configuration is preserved; Ralph adds only its protected integration when enabled |
| **Cursor** | `.cursor/` rules, skills, hooks, settings; existing `.cursor/mcp.json` | Native runtime configuration is preserved; Ralph adds only its protected integration |
| **Codex** | `~/.codex/config.toml`, trusted project `.codex/config.toml` (if project trusted) | Native runtime configuration is preserved; Ralph adds only its protected integration |
| **OpenCode** | Global, custom, project `opencode.json` (JSONC preserved) | Native runtime configuration is preserved; Ralph adds only its protected integration |
| **Antigravity** | `.agents/` rules, skills, workflows, settings, and existing MCP configuration | Native runtime configuration is preserved; Ralph adds only its protected integration when needed |

All mutations use reversible workspace overlays or temporary config files. Byte-exact originals are restored on success, failure, timeout, and signal cleanup via runtime-config journals under `.ralph-workspace/runtime-config/<plan-key>/`.

See [docs/MCP.md](docs/MCP.md) for the native ambient and protected Ralph MCP precedence, delegated-run tools, and troubleshooting.

## Reference map (progressive disclosure)

Open these only when the task requires detail beyond this file.

| Read this | Only when |
|-----------|-----------|
| [docs/WORKFLOWS.md](docs/WORKFLOWS.md) | Workflow authoring, Sequential vs Dependency, planner/planFrom/planInput, approvals, status/resume/reset/recover, exit 3 |
| [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) | Env vars, session/resume flags, `RALPH_BG_*` background-job vars (opt-in), runtime `*_PLAN_*` chains, orchestrator knobs, and named tooling profiles |
| [docs/TOOLING.md](docs/TOOLING.md) | Ralph mode (`--ralph-mode`, `RALPH_MODE`), prompt layering, named tooling profiles, MCP proxy tools, Stop hook continuation contract, shell compaction policy, native adapters, overlay journals, and cleanup |
| [docs/MCP.md](docs/MCP.md) | Standalone Ralph MCP server, host wiring, third-party MCP for plan agents (background continuation adds no MCP tools) |
| [docs/AGENT-WORKFLOW.md](docs/AGENT-WORKFLOW.md) | Plan loop operator flow, human input, durable TODO continuations, handoffs, workflow operator-input protocol |
| [docs/INSTALL.md](docs/INSTALL.md) | Global and in-repo install, `install.sh` flags, workspace registry, uninstall |
| [bundle/.ralph/docs/DELEGATION.md](bundle/.ralph/docs/DELEGATION.md) | Native subagents vs delegated runs, completion evidence, and threat controls |
| [bundle/.ralph/docs/AGENTS.md](bundle/.ralph/docs/AGENTS.md) | Installable copy of this agent contract |

## Important patterns

### Artifact namespace placeholders

| Token | Env var | Example value | Typical use |
|-------|---------|---------------|-------------|
| `{{ARTIFACT_NS}}` | `RALPH_ARTIFACT_NS` | `code-review` | Namespace from orchestration JSON or plan basename |
| `{{PLAN_KEY}}` | `RALPH_PLAN_KEY` | `code-review-01-cr1` | Plan namespace (falls back to `{{ARTIFACT_NS}}` when unset) |
| `{{STAGE_ID}}` | `RALPH_STAGE_ID` | `cr1` | Sanitized stage `id` from the workflow/orchestration stage |

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
- `.ralph/bash-lib/plan-todo.sh` — plan/workflow frontmatter and stage schema
- `scripts/validate-orchestration-schema.sh` — pipeline plan schema checks (Sequential internals)
- `scripts/sync-runtime-assets.sh --check` — generated rules/skills drift check

## Testing notes

- **Framework:** Bats in `tests/bats/`; each file is standalone; use `load 'test_helper'`
- **Fixtures:** `scripts/setup-test-fixtures.sh` creates `.ralph-workspace/` stubs
- **CI:** GitHub Actions runs `bash scripts/run-bats.sh` (`bin/bats` adds `-T` for per-test durations)
- **Filter:** `bats tests/bats/run-plan/*.bats --filter "pattern"`

## Quick file reference

| File | Purpose |
|------|---------|
| `.ralph/run-plan.sh` | Main plan executor (unified across runtimes) |
| `.ralph/orchestrator.sh` | Sequential multi-stage runner (classic orchestration internals) |
| `.ralph/graph-run.sh` | Dependency engine entry |
| `.ralph/bash-lib/run-plan/run-plan-invoke-*.sh` | Runtime-specific invoke logic |
| `.ralph/bash-lib/workflow/` | Public workflow CLI helpers |
| `.ralph/workflows/` | Bundled reusable workflow definitions |
| `.ralph/plan-templates/classic.plan.template.md` | Starter classic plan template |
| `bundle/.ralph/docs/AGENTS.md` | Installable copy of the agent contract |
| `.ralph/ralph-dashboard/` (installed) or `ralph-dashboard/` (this repo) | Dashboard package |
| `scripts/run-bats.sh` | Bats runner (fixtures + `bin/bats` with `-T`) |
| `tests/bats/*.bats` | Bats test files |
