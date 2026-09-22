# Ralph Dashboard

Angular SSR app for browsing Ralph plan logs, artifacts, sessions, docs, and plan files in a workspace. Run it from the repository where Ralph is installed (the project root that contains `.ralph-workspace/`).

Ralph is **CLI-first**; this app is a visualizer and control surface for runs, workflows, and workspace state. Operator guides live in [`docs/`](docs/) — start with [`docs/START_HERE.md`](docs/START_HERE.md) and [`docs/HOW_RALPH_FITS_TOGETHER.md`](docs/HOW_RALPH_FITS_TOGETHER.md) for how the dashboard relates to per-project skills, rules, MCP, and the Ralph harness.

## Prerequisites

- **Node.js 22** (use [nvm](https://github.com/nvm-sh/nvm), for example `nvm install 22` and `nvm use v22`)
- **npm** (bundled with Node)

## Install

From this directory:

```bash
npm install
```

## Development

Use two terminals from `ralph-dashboard/`:

1. **Rebuild the app on change** (Angular client + server bundle):

   ```bash
   npm run watch
   ```

2. **Run the Node server with reload** (serves the last successful `dist/` build):

   ```bash
   npm run dev
   ```

Open the URL printed by the server (default port **8123**). Edit client or server code; `watch` rebuilds `dist/` and `dev` picks up changes to the server entry.

## Production

Build once, then start the server:

```bash
npm run build
npm start
```

The production server runs `dist/ralph-dashboard/server/server.mjs`.

## State ownership

The CLI is the sole writer for durable Ralph run state beneath the state root
(`.ralph-workspace/`): `plans`, `artifacts`, `workflows`, layout 1 homes such
as `logs`, `sessions`, `graph-runs`, and `workflow-runs`, and layout 2 homes
under `runs/`, `cache/`, and `internal/`. The dashboard reads that state but
does not rewrite it. Layout is recorded per run at admission
(`RALPH_STATE_LAYOUT`, default `2`); resume uses the recorded layout.

The dashboard alone writes its task and schedule records at
`<workspaceRoot>/dashboard/tasks-schedules.json` and its local endpoint record
at `$XDG_CONFIG_HOME/ralph/dashboard/` (or `~/.config/ralph/dashboard/`). A
dashboard `TaskAttempt` is operational metadata that refers to a Ralph run; it
is never the run's source of truth. Missing task metadata must therefore not
hide a run that exists on disk, and a task attempt with no live corresponding
run must be reconciled to a terminal state.

### Port

Default port is **8123**. Override with the `PORT` environment variable:

```bash
PORT=8124 npm start
```

## Tests

- **All tests** (Jest API/server unit tests, then Vitest Angular tests):

  ```bash
  npm test
  ```

- **With coverage** (both Jest and Vitest coverage; project thresholds apply):

  ```bash
  npm run test:cov
  ```

- **Browser (Playwright) tests** — real dashboard server, real fixture
  project root, no mocked filesystem state (see `playwright.config.ts` and
  `e2e/fixtures/`):

  ```bash
  npm run build   # e2e runs against dist/, not ng serve
  npm run test:e2e
  ```

  `e2e/fixtures/acceptance-workspace/` is a deterministic Ralph project root
  (duplicate plan basenames across two subprojects, a classic and a YAML
  plan, a project-level workflow override, usage volume). Workflow-run
  states (waiting approval, failed verification, rework, completed) come
  from `e2e/fixtures/ralph-stub.sh`, a `ralph` CLI stub that returns canned
  JSON for `workflow runs|status|actions` and delegates every other
  subcommand to the real installed `ralph` binary — the same technique
  `tests/ralph-cli.test.ts` already uses for the server unit suite.

## UI overview

The redesigned dashboard leads with five stable **product sections** in the
primary sidebar navigation, not a filesystem tree:

- **Home** (`/home`) — the default operational view. A "Needs you" queue
  (waiting approvals, failed verification, stalled runs) is prioritized above
  a "Continue" list of active/recent runs. Each item names its project,
  stage, status, elapsed time, and a specific next action.
- **Runs** (`/runs`) — an index of workflow and plan runs with status,
  project, current stage, and last event. Filter by active/waiting/failed/
  completed; open a run's durable detail URL to see its stage map,
  chronological event timeline, and the operator's next permitted action.
- **Plans** (`/plans`) — a compact, searchable, paginated plan list (name,
  type, status, checkbox progress, current TODO, project, last activity).
  Opening a plan goes to its dedicated detail view with Rendered/Source/Diff
  modes, a TODO outline, and linked artifacts — not the generic file viewer.
  **View logs** opens run history and grouped, openable evidence (usage,
  execution output, telemetry) for manifest-backed and legacy plan layouts;
  the plan file viewer's **View Logs** toolbar shortcut still jumps to the
  latest log under Browse / Logs.
- **Workflows** (`/workflows`) — a searchable catalog of workflow
  definitions (purpose, stage count, source precedence, write/gate
  metadata), with a compiled dependency graph, a synchronized stage
  inspector, and a guided creation/editing flow per workflow.
- **Insights** (`/insights`) — usage and telemetry for Ralph runs (token
  spend, trends, breakdown tables) plus a separate **IDE & CLI activity**
  section for machine-local Claude Code, Codex, and Antigravity quota (session /
  weekly bars, reset timers, transcript token totals in the selected date
  range). IDE data is read-only from `~/.claude` / `~/.claude.json`,
  `~/.codex/sessions`, and `agy --print /usage --output-format json`. When
  Claude's on-disk quota snapshot is older than
  `RALPH_DASHBOARD_CLAUDE_QUOTA_MAX_AGE_MS` (default 5 minutes), the dashboard
  refreshes it with `claude --print /usage` before reading. Collection is not
  scoped to the selected Ralph workspace. Set
  `RALPH_DASHBOARD_AMBIENT_USAGE=0` to hide IDE & CLI collection. Optional
  `RALPH_DASHBOARD_AMBIENT_USAGE_TTL_MS` controls rescan cache (default
  60000). Nothing on Home, Plans, Runs, or Workflows requests usage data;
  it loads only once you open Insights or Runtimes.
- **Runtimes** (`/runtimes`) — connection status for Claude, Codex,
  Antigravity, Cursor, and OpenCode (in that order), with plan / provider
  hints when available. Cursor links to the Cursor billing dashboard;
  OpenCode detects configured providers (for example `ollama-cloud`) and
  links to the matching settings page when known.

**Browse** is a secondary, explicit entry (in the workspace sidebar, below
the primary sections) for arbitrary filesystem exploration by root — Logs,
Artifacts, Sessions, Docs, or an orchestration-plans tree — for cases the
product sections above don't cover. It maps to these directories, relative
to the selected project's root:

| Root        | Path on disk                          |
|------------|----------------------------------------|
| Logs       | `.ralph-workspace/logs` (layout 1) or attempt dirs under `.ralph-workspace/runs/<run-id>/` (layout 2) |
| Artifacts  | `.ralph-workspace/artifacts`           |
| Sessions   | `.ralph-workspace/sessions` (layout 1) or `.ralph-workspace/internal/sessions` (layout 2) |
| Docs       | `docs`                                 |
| Plans      | `.ralph-workspace/plans` (and the project root) |

Runs are discovered from layout 2 catalogs at `.ralph-workspace/runs/<run-id>/run.json` when present, otherwise from the legacy layout 1 readers. The workflow graph defaults to authored logical stages (compiled rework clones appear as attempt history).

If a path does not exist yet, it may not appear in listings until it is created by Ralph or the project.

A **project switcher** in the header (searchable, with Pinned/Recent/All
projects grouping) replaces the old raw workspace dropdown; legacy
`?root=&path=&file=` deep links and the old `/plans?file=...` links continue
to resolve.

**Known gap:** nothing in the UI currently attaches a mutable control copy to
a plan automatically (the plans index API does not yet classify
`generated-control`/`supplied`/`workflow-derived` plans — every plan reports
as `leaf`). `PlanDetailComponent` itself fully supports Diff mode via a
`controlCopy` query param; it just has no automatic producer yet. See
`docs/DASHBOARD_REDESIGN_DECISION.md` for the recommended follow-up.

## Workflows studio

The sidebar's **Workflows** entry opens `/workflows`, a studio for browsing and
editing Ralph workflow definitions (`<id>.workflow.md` files), separate from
the file-tree explorer above:

- **List and detail.** Workflows are grouped by resolution scope (project,
  global, bundled) per `docs/WORKFLOWS.md` "Resolution and editing". The
  detail page shows the parsed stage graph (rendered with mermaid), defaults,
  and recent runs.
- **Structured editing.** A file that uses only the studio's structured-edit
  subset (see `docs/WORKFLOWS.md` "Dashboard") opens in a form-based stage
  editor. A file with any other frontmatter key opens in a raw-frontmatter
  text editor instead; both save through the same server-validated route.
- **Bundled workflows are immutable.** Their edit page offers **Customize for
  this project** or **Customize globally** — full-byte copies with the same
  seeding semantics as `ralph workflow edit` / `ralph workflow edit --global`.
  If the target file already exists, customize is idempotent and does not
  overwrite.
- **Precedence and layers.** Project overrides beat global copies, which beat
  bundled defaults. Detail views show which scopes exist for an `id` and link
  to edit non-winning layers. Deleting a project or global file reveals the
  next source in the chain (see `docs/WORKFLOWS.md` "Resolution and editing").
- **Saves and routing.** Structured, raw, and routing edits require the
  `sha256` of the loaded file; the server replaces the whole workflow after
  validation (optimistic concurrency). Routing changes use the same contract as
  `ralph workflow routing set`.
- **Workspace selection.** With a single project selected, project-scoped
  customize, delete, save, and run start use that project's allowlisted state
  root. In **all workspaces** mode (multiple registered projects, no
  selection), the list shows global and bundled definitions only; global
  customize remains available, but project-scoped mutations and starts are
  disabled until you pick a project.
- **Run controls.** Start a run from a workflow's detail page (task text,
  optional runtime/model override, and a confirmation step that shows the
  resolved `ralph workflow start` command before it runs). A run's own page
  (`/workflows/runs/<runId>`) polls status while the run is nonterminal and
  offers cancel, resume, and responses to any pending operator actions
  (approvals and input questions).

### Assistant

A floating **Ask** launcher (bottom-right, on every page) opens a chat dock
backed by a local agent CLI (Claude, Codex, Cursor, OpenCode, or
Antigravity — whichever is installed and selected).

Each turn starts from a seeded read of the live workflows, runs, tasks, and
schedules in this install, so responses describe what is actually here rather
than invented content. Beyond that seed the assistant can request more data
itself: it emits a fenced `ralph` block naming a tool, the server runs it and
feeds the result back, for a small fixed number of rounds. That is how it
reaches per-item detail such as one run's stage diagnosis or one workflow's
topology. Every round is a fresh CLI invocation, so the round budget is
deliberately small; `RALPH_DASHBOARD_ASSISTANT_MAX_ROUNDS` adjusts it.

Tools come in three kinds. `read` tools return live state. `draft` tools
check work without changing anything — `preview_cron` resolves a cron against
the real scheduler, and `validate_workflow_draft` runs a candidate workflow
through the real Ralph codec in a throwaway directory. `propose` tools change
state, and they never execute during a turn: they come back as confirm cards
in the dock.

A confirm card shows what would happen along with whatever the server could
verify up front — the next fire times for a proposed schedule, the validation
result for a proposed workflow. A card whose preview failed cannot be
confirmed at all. Confirming a task, schedule, or workflow posts it to the
same guarded REST routes the rest of the dashboard uses, so nothing bypasses
their validation. Nothing is ever created, started, scheduled, or cancelled
from the assistant's own prose.

When no agent runtime is available, the assistant still answers with the live
state it read, marked as a degraded reply. Chat history and the selected
runtime/model persist in the browser's local storage.

### Loopback write guard and capabilities

Every route that writes a workflow file, starts or cancels a run, or spawns
the assistant's agent CLI is refused unless the dashboard server itself is
bound to a loopback host (`HOST` defaults to `127.0.0.1`; see `PORT`
above) and the request's Host header names that same loopback address on the
server's own port — this blocks both plain cross-site requests and DNS
rebinding. `GET /api/capabilities` reports `{ workflowWrites, workflowRuns,
assistant }`, all `false` when the server is not loopback-bound, so the
client hides controls the server would refuse rather than showing a control
that always fails.

### RALPH_DASHBOARD_RALPH_BIN

The dashboard resolves the `ralph` entrypoint the same way `/api/ralph-
framework-root` does, with one override for tests and unusual installs: set
`RALPH_DASHBOARD_RALPH_BIN` to an absolute path and every workflow-studio
route uses that executable instead of the resolved default. Automated tests
always set this to a stub executable — no test invokes a real Ralph
runtime.
