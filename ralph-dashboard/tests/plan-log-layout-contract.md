# Leaf plan log layout contract (dashboard read model)

Developer contract for how Ralph leaf-plan evidence on disk maps to dashboard
plan-run list/detail APIs and file viewing **today** (`dashboard-api.ts`,
`plan-run-detail.ts`, `plan-logs` UI). The next TODO refactors this read model;
this document inventories reality first.

## On-disk layouts Ralph produces

All paths are under the **state root** (default `<project>/.ralph-workspace`).

### A. Manifest-backed plan run (current default)

| Location | Role |
|----------|------|
| `logs/<plan-key>/runs/<run-id>/run-manifest.json` | Canonical run record (`kind: ralph_run_manifest`, `schema_version: 1`) |
| `logs/<plan-key>/runs/index.jsonl` | Append-only index for `--resume-run last` / `ralph state runs` |
| `logs/<plan-key>/plan-usage-summary.json` | Plan-level usage rollup (may span last run; shared across runs in one plan-key dir) |
| `logs/<plan-key>/invocation-usage.json` | Per-invocation history (`plan_invocation_usage_history`) |
| `logs/<plan-key>/discover-report.json` | Compaction/discover analytics (optional; python3) |
| `logs/<plan-key>/tool-catalog-telemetry.jsonl` | MCP catalog telemetry (optional) |
| `logs/<plan-key>/plan-runner-<name>.log` | Runner diagnostic log |
| `logs/<plan-key>/plan-runner-<name>-output.log` | Tee'd CLI stdout/stderr (primary execution log) |
| `logs/<plan-key>/plan-runner-<name>-output.ansi.log` | ANSI-preserving sibling of output log |
| `logs/<plan-key>/runs/<run-id>/overlay/` | Per-iteration overlay summary snapshots (`iter-<n>-<runtime>.json`) |
| `logs/<plan-key>/runs/<run-id>/overlay-timeline.jsonl` | Overlay compaction timeline |
| `logs/<plan-key>/post-verification-tracking.txt` | Post-verify byte suppression audit (optional) |
| `logs/<plan-key>/compression-audit-results.json` | Compression audit (optional) |
| `sessions/<plan-key>/` | Session ids, todo-session captures, operator-response (not under `logs/`) |
| `sessions/<plan-key>/todo-sessions/*.json` | Resume eligibility for `resume` block in detail API |
| `runtime-config/<plan-key>/` | Overlay journals for runtime config (included in plan-run file paths) |
| `tool-results/<plan-key>/` | Stored MCP tool results (not included in plan-run file paths today) |
| `artifacts/<artifact-ns>/` | Plan artifacts (linked from UI separately, not in plan-run file list) |
| `processes/<run-id>/run.json` | Live process metadata (**never** exposed via plan-run APIs; paths filtered) |

Graph-node leaf plans use `agent.log` / `agent.ansi.log` under the node log dir
instead of `plan-runner-*` names; manifest write is skipped when
`RALPH_GRAPH_NODE_LOG_DIR` is set.

### B. Legacy flat plan log directory

Before per-run manifests, telemetry lived **directly** under `logs/<plan-key>/`
(see `docs/WORKSPACE.md` "Legacy flat layout"). Same filenames as plan-level
rows in table A, without `runs/<run-id>/run-manifest.json`. Large
`*-output.log` files often dominate disk.

### C. Nested subdirectory under a plan log dir (legacy exploration)

Some trees place run-scoped logs one level down, e.g.
`logs/<plan-key>/<subdir>/plan-runner-*-output.log`. The dashboard **log
explorer** resolves these via `PlanLogResolutionService` (newest `.log` in the
plan dir, else newest subdir). Plan-run APIs do **not** treat `<subdir>` as a
separate run id unless a manifest or legacy summary exists at the plan-key root.

### D. Task / dashboard leaf attempts (out of scope for plan-key runs)

| Location | Role |
|----------|------|
| `logs/dashboard-leaf-runs/<id>.log` | Ephemeral log for dashboard-started leaf plans (`/api/plans/run`) |
| Task attempt logs under the tasks store | Scheduler leaf-plan launches; separate from `logs/<plan-key>/` |

## Discovery rules (current `collectPlanRunsFromWorkspace`)

1. Enumerate `logs/*` directories (skip hidden names).
2. For each `plan-key`, scan `logs/<plan-key>/runs/*/run-manifest.json`.
   - Valid manifest: `run_id` matches `PLAN_RUN_ID_RE` (`^[A-Za-z0-9._-]+$`).
   - List item `source: "manifest"`, `runDir` set, full manifest kept for detail.
3. If **any** manifest was found for that plan-key, **do not** synthesize a legacy run for that key (manifest-only listing for that plan).
4. Else if `logs/<plan-key>/plan-usage-summary.json` exists:
   - **Synthetic legacy run**: one row per plan-key (not per nested folder).
   - `runId`: `summary.run_id` when present and id-safe, else `legacy-<plan-key>`.
   - `source: "legacy"`, `runDir: null`, `manifest: null`.
   - `status`: `summary.status` or `"legacy"`.
   - `startedAt` / `endedAt`: from summary when present (may be empty).
5. Plan-key dirs with **only** output logs (no manifest run dir and no
   `plan-usage-summary.json`) produce **no** plan-run list rows today. Files
   remain browsable under the `logs` explorer root.

**Important:** Legacy file collection walks `logDir` but **skips** the entire
`runs/` subtree. Pre-manifest overlay paths under `logs/<plan-key>/runs/<id>/`
are therefore omitted from legacy synthetic run file lists even if present.

## File list assembly (`collectPlanRunFilePaths`)

Union of (paths state-root-relative, forward slashes):

1. Manifest `files[].path` entries except any under `processes/`.
2. All files under `runDir` recursively (manifest runs only).
3. All files under `logDir` except `runs/` and `runs/**`.
4. All files under `runtime-config/<plan-key>/`.
5. Drop any path with a `processes` path segment.

No `sessions/` or `tool-results/` paths in this union today.

## Classification (`classifyFiles` / file viewer roles)

**Summary bucket** (labeled; basename match only):

| Basename | Label | Viewer role |
|----------|-------|-------------|
| `plan-usage-summary.json` | Plan usage summary | `plan-usage-summary` |
| `invocation-usage.json` | Invocation usage history | (generic JSON) |
| `run-manifest.json` | Run manifest | `run-manifest` |
| `overlay-timeline.jsonl` | Overlay compaction timeline | structured JSONL in log viewer |

**Raw bucket:** every other discovered path (including output logs, discover
report, overlay iter snapshots, tool-catalog telemetry, runtime-config files).

**Related but not in plan-run file list:** `discover-report.json` (loaded via
`/api/metrics/discover/<planKey>` on detail), artifacts under
`artifacts/<plan-key>/`.

**Openability:** Any path returned in `files.summary` or `files.raw` must be
openable via `GET /api/file`. Plan-run handlers return **state-root-relative**
paths (prefix `logs/`, `runtime-config/`, etc.). The file API uses explorer
roots: for log evidence, `root=logs` and `path=<plan-key>/...` (strip a leading
`logs/` segment from the returned path). Runtime-config entries use
`root=runtime-config` with the path after that prefix. Paths under `processes/`
are never returned. Traversal and unknown roots are rejected. Summary-role JSON
uses the file viewer; `*.log` uses the log viewer; other extensions use the
generic file viewer.

## API payloads

### `GET /api/plan-runs?planKey=&workspaceRoot=`

```ts
{ items: PlanRunListItem[] }
```

| Field | Manifest run | Legacy synthetic |
|-------|--------------|------------------|
| `runId` | manifest `run_id` | summary `run_id` or `legacy-<plan-key>` |
| `planKey` | manifest or directory name | directory name |
| `status` | manifest `status` or `unknown` | summary `status` or `legacy` |
| `startedAt`, `endedAt` | manifest ISO strings (may be empty) | summary fields (may be empty) |
| `source` | `manifest` | `legacy` |
| `runtime`, `model` | manifest, else plan-level summary | plan-level summary only |
| `todosDone`, `todosTotal`, `inputTokens`, `outputTokens`, `elapsedSeconds` | plan-level `plan-usage-summary.json` (best-effort; nulls when missing) |

Sort: descending by `endedAt || startedAt` (lexicographic ISO).

### `GET /api/plan-runs/:runId?workspaceRoot=`

Extends enriched detail (`enrichPlanRunDetail`):

| Field | Notes |
|-------|-------|
| `planKey`, `status`, `source` | From located run |
| `files.summary[]` | `{ path, label }` |
| `files.raw[]` | Unlabeled path strings |
| `timeline[]` | From `invocation-usage.json` invocations matching `run_id`, plus synthetic catalog rows; `{ at, prose }` |
| `operatorNext` | `running` -> "Monitor run"; else "Inspect artifacts" |
| `discoverReport` | URL string or null |
| `resume` | `{ resumableTodoCount, command }` -- command uses manifest `plan_path` or `<plan>` placeholder |
| `usage` | Same card fields as list item |

### `GET /api/plan-runs/:runId/files?workspaceRoot=`

Returns `{ summary, raw }` only (same classification as detail).

Errors: `400` invalid `runId`; `404` unknown run.

## Workspace / project scoping

- `workspaceRoot` query resolves via `planRunsWorkspaceRoot` ->
  `findDashboardRoots()` when omitted (selected dashboard workspace).
- When set, must resolve through the workspace allowlist (`RALPH_WORKSPACES_FILE`
  + `RALPH_DASHBOARD_WORKSPACE_ROOT`); otherwise list is empty or lookup fails closed.
- Plan-run handlers do not accept arbitrary filesystem paths outside registered
  workspace roots.
- UI: `PlanLogsComponent` requires a resolved registry workspace (`projectRoot` +
  `workspaceRoot`) from `fetchWorkspaces()`; deep links pass `projectRoot` query.

## Empty and unavailable states

| Situation | List API | Detail UI expectation |
|-----------|----------|------------------------|
| No `logs/` or empty | `items: []` | "No runs have been recorded for this plan yet." |
| Legacy flat logs only (no summary) | `items: []` for that plan-key | Same empty state; logs still in sidebar `logs` root |
| Unknown `runId` | HTTP 404 | Error state |
| No invocation records for timeline | `timeline: []` | "No timeline events." |
| No discover report | `discoverReport: null` | "No discover report for this plan." |
| No artifact namespace files | (separate artifacts fetch) | "No artifacts in this namespace." |
| No labeled summary files in union | `files.summary: []` | "No labeled summary files." |
| Missing plan-level summary for card fields | zeros / null todos / empty runtime | UI shows "runtime unset", "duration unknown", em dashes for todos |

## Fallback labels (current)

- Unknown status: `"unknown"` (manifest) or `"legacy"` (synthetic default status).
- Timeline event without known fields: prose `"run activity"`; `at` from `ended_at`, `completed_at`, or `timestamp`.
- Raw files: no label; basename-only grouping in future work.

## Fixture shapes (see `fixtures/plan-log-layouts/README.md`)

Programmatic copies used in `plan-log-layout-contract.test.ts`:

1. **manifest-run** -- `runs/<id>/run-manifest.json` + plan-level usage/invocation.
2. **legacy-flat-output-only** -- only `*-output.log` at plan-key root (no list row).
3. **legacy-nested-subdir** -- `run-attempt-1/*-output.log` nested (no list row without summary).
4. **legacy-with-summary** -- `plan-usage-summary.json` with `run_id` (synthetic legacy row).

Verification: run `cd ralph-dashboard && npm run test:server -- plan-log-layout-contract`.
