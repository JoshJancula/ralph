# State workspace (`.ralph-workspace/`)

This is the canonical description of the **state root**. Default location:
`<project>/.ralph-workspace`. Override with `--workspace-root` /
`RALPH_PLAN_WORKSPACE_ROOT`. It is not the project root and not the agent
workspace. See [ENVIRONMENT.md](ENVIRONMENT.md#core-plan-runner-and-workspace).

Ralph writes derived run state here. Do not commit it. Retention is
best-effort and described below.

## Top-level directories

| Directory | Writers | Readers | Retention | Safe to delete | v2 home |
|-----------|---------|---------|-----------|----------------|
| `logs/` | `run-plan.sh`, graph and workflow engines | Dashboard, `ralph state`, `ralph usage`, `ralph benchmark` | Per-plan `logs/<key>/runs/` pruned by `RALPH_RETENTION_LOG_RUNS_*` (default 10 runs / 30 days). Non-terminal run dirs are kept. | Yes, except an in-progress run's log dir | `runs/<id>/stages/<stage>/attempts/<attempt>/` (legacy flat logs stay) |
| `artifacts/` | Plan agents, runner verification, workflow stages | Dashboard file viewer, later stages via artifact tools | Per-namespace prune by `RALPH_RETENTION_ARTIFACTS_*` (default 90 days or 512 MiB) | Yes for finished namespaces | unchanged |
| `sessions/` | `run-plan` session helpers, background jobs, human continuation | CLI resume, `--resume-run`, Stop hooks | No automatic prune of session ids | Deleting drops plan-level and per-TODO resume | `internal/sessions/` |
| `tool-results/` | MCP proxy / native shell compaction | `ralph_proxy_result_*` | `RALPH_MCP_PROXY_RESULT_STORE_*` (default 50 MiB, 7 days, 100 entries per plan key) | Yes | `cache/tool-results/` |
| `runtime-config/` | Overlay journals and original config snapshots | Cleanup / restore on success, failure, and signal | Journals pruned by `RALPH_RETENTION_JOURNALS_*` (default 20 / 30 days) | Do not delete `originals/` while a run is live | `internal/runtime-config/` |
| `graph-runs/` | Dependency engine (`graph-run.sh`) | `ralph workflow status`, graph dashboard | Terminal runs: `RALPH_GRAPH_RUN_MAX_COUNT` (10) and `RALPH_GRAPH_RUN_MAX_AGE_DAYS` (30) | Yes for old terminal namespaces; not while `running` or `awaiting-ack` | `runs/<id>/engine/graph/` |
| `workflow-runs/` | Workflow registry (`workflow-state.sh`) | `ralph workflow *`, dashboard workflows | No dedicated count/age knobs in retention.sh | Only when the operator intends to drop registry history | `runs/<id>/engine/workflow/` |
| `processes/` | Process supervisor (`ralph_process_supervisor.py`) | Teardown, `ralph state` style inspection | Live leases under `processes/active/` and `processes/leases/` | No while a run is live (contains process identity, not for the dashboard explorer) | `internal/processes/` |
| `plans/` | `ralph create plan`, workflow materialization | `ralph workflow list-plans`, MCP plan roots | None | Only copies you no longer need; live control plans live here | operator plans unchanged; controls under `runs/<id>/stages/<stage>/controls/` |
| `orchestration-plans/` | Sequential engine materialization | Orchestrator internals | None | Same caution as `plans/` | `runs/<id>/engine/sequential/` |
| `docs/` | Optional operator notes in some installs | Dashboard docs hub | None | Yes | unchanged |
| `memory/` | Plan-scoped `ralph_proxy_memory_*` | Later turns of the same plan key | Bounded per plan | Yes; content is untrusted model-authored notes | `internal/memory/` |
| `security/` | MCP approval watcher | Operator decision files | None while requests are outstanding | No during an approval wait | unchanged |
| `command-profiles/` | Profile store (`ralph profiles`) | Profile CLI | None | Yes if you accept losing saved profile stats | `internal/command-profiles/` |
| `metrics/` | Usage / discover reports when generated | Dashboard discover panel | None | Yes | `cache/metrics/` |
| `delegated-runs/` | Graph delegation ledger (`graph-delegation-ledger.sh`) | Child-run completion, `ralph_delegated_run_*` | None dedicated; tied to the parent graph run | No while a delegated child is live | `runs/<id>/engine/delegation/` |
| `handoffs/` | Sequential / workflow stage handoff writers | Downstream stages, dashboard | None dedicated | Yes for finished runs | `runs/<id>/stages/<stage>/attempts/<attempt>/handoffs/` |
| `manual-verification/` | Runner-owned `verify:` output | Dashboard, next invocation failure summary | Follows the owning plan run | Yes after the run is terminal | `runs/<id>/stages/<stage>/attempts/<attempt>/manual-verification/` |
| `repo-map/` | `ralph_proxy_repomap` / `repo-map.sh` | Proxy repomap cache | Cache keyed by tree slug | Yes | `cache/repo-map/` |
| `search-context/` | `ralph_proxy_search` contextual index (`search_context.py`) | Subsequent searches | Cache under `search-context/<slug>/` | Yes | `cache/search-context/` |
| `setup-journal/` | `setup-runtime.sh` / `setup-journal.sh` | Install/setup restore | Per operation id | Do not delete mid-setup | `internal/setup-journal/` |
| `workflows/` | Project-user workflow definitions (`ralph create workflow`) | `ralph workflow list/show/start` | None (operator data) | Only copies you no longer need | unchanged |

Top-level **files** (not directories) such as `hooks-config.jsonl` are overlay
journals for hook config and are restored with `runtime-config/`.

## Layout versions

Layout 1 is the existing top-level layout and remains readable indefinitely.
New layout 2 runs are grouped under `runs/<run-id>/`; operator-owned paths
(`plans/`, `workflows/`, `docs/`, `security/`, and `artifacts/`) remain at the
state root. A run is layout 2 only when `runs/<run-id>/run.json` exists and
contains `layoutVersion: 2`; otherwise it is layout 1. Readers must use the
recorded layout, rather than infer it from an id or from a current environment
default, so a resumed layout 1 run continues using layout 1 paths.

## State layout v2

```text
.ralph-workspace/
  README.md                         managed navigation entry point
  plans/  workflows/  docs/  security/        operator-owned, unchanged
  artifacts/<namespace>/            public artifact address contract, unchanged
  runs/<run-id>/                    outer workflow run or standalone plan run
    README.md                       managed per-run navigation
    run.json                        catalog + lifecycle
    inputs/                         immutable source copies and task text
    stages/<stage-id>/
      controls/                     mutable control plan copies for this stage
      attempts/<attempt-id>/        logs, handoffs, and manual verification
    engine/
      graph/  workflow/  sequential/  delegation/
  cache/                            reproducible; always safe to delete
  internal/                         shared, non-reproducible coordination state
```

A standalone plan uses stage `plan` and its process run id as its attempt id.
A workflow child attempt is stored under its outer run and authored stage id.
`run.json` is a catalog, not a ledger copy: it records `kind:
"ralph_run_catalog"`, `layoutVersion: 2`, run identity, lifecycle, parent,
artifact namespace, short task, relative input and engine paths, and one
bounded latest-attempt record per stage.

## Ownership map

The ownership map is the authoritative classification for state inspection,
retention, and later layout migration. `check-state-layout.sh` reports each
category without modifying the supplied root. "Shared" below means a path is
not tied to one run, not that it is safe to delete.

## State ownership map

| Category | Owner | Layout | v1 home | v2 home |
|----------|-------|--------|---------|---------|
| Plan attempts | plan attempt | v1 | `logs/<key>/runs/<run-id>/` | `runs/<id>/stages/<stage>/attempts/<attempt>/` |
| Run index | derived index | v1 | `logs/<key>/runs/index.jsonl` | `cache/indexes/runs.jsonl` |
| Legacy logs | legacy | v1 | `logs/<key>/*` outside `runs/` | unchanged, read-only |
| Graph engine | graph run | v1 | `graph-runs/<ns>/<run-id>/` | `runs/<id>/engine/graph/` |
| Workflow engine | workflow run | v1 | `workflow-runs/<run-id>/` | `runs/<id>/engine/workflow/` |
| Sequential engine | sequential run | v1 | `orchestration-plans/` | `runs/<id>/engine/sequential/` |
| Delegation ledger | parent graph run | v1 | `delegated-runs/` | `runs/<id>/engine/delegation/` |
| Handoffs | stage attempt | v1 | `handoffs/` | `runs/<id>/stages/<stage>/attempts/<attempt>/handoffs/` |
| Manual verification | plan attempt | v1 | `manual-verification/` | `runs/<id>/stages/<stage>/attempts/<attempt>/manual-verification/` |
| Control plans | run | v1 | materialized copies under `plans/` | `runs/<id>/stages/<stage>/controls/` |
| Run catalog and inputs | run | v2 | n/a | `runs/<id>/run.json`, `inputs/` |
| Sessions, config, processes, setup, memory, profiles | respective shared owner | shared | top-level category | `internal/` subdirectory |
| Tool results, repo map, search context, metrics, indexes | cache | shared | top-level category | `cache/` subdirectory |
| Operator data and artifacts | operator or public contract | shared | top-level category | unchanged |
| Anything else | unknown | shared | retained | unchanged and reported as unclassified |

## Path resolution contract

Readers source `bash-lib/state-paths.sh` and use
`ralph_state_path_resolve`, `ralph_state_layout_version`,
`ralph_state_shared_dir`, `ralph_state_workflow_run_dir`,
`ralph_state_graph_run_dir`, or `ralph_state_plan_attempt_dir` rather than
constructing a layout-owned path. The TypeScript dashboard equivalents are in
`src/server/state-paths.ts`. Each resolver refuses `..` components and
symlinks that leave the state root. A run catalog is authoritative: a valid
`runs/<id>/run.json` with `layoutVersion: 2` selects layout 2, otherwise the
run is layout 1 even if `RALPH_STATE_LAYOUT=2` is exported later. New runs
record the layout from `RALPH_STATE_LAYOUT` at admission (default `2` when
unset; set `1` to keep the pre-existing top-level paths) and never re-derive
it on resume. Shared writable homes for sessions, cache, and internal state
follow that same new-run default when no run catalog applies. See
[ENVIRONMENT.md](ENVIRONMENT.md#state-layout-ralph_state_layout).

## Three run kinds

Keep these distinct. They share a state root but different ids and homes.

| Kind | What it is | Id format | Layout 1 home | Layout 2 home |
|------|------------|-----------|---------------|---------------|
| **Plan run** | One `ralph run --plan` (leaf TODO loop) | Process run id, typically `<UTC>-<pid>-<hex>` (example `20260917T204940-93013-2edd8b0e`). Stored as `RALPH_PROCESS_RUN_ID`. | `logs/<plan-key>/runs/<run-id>/` with `run-manifest.json`; sessions at `sessions/<plan-key>/` | `runs/<run-id>/` (stage `plan`); sessions under `internal/sessions/` |
| **Workflow run** | An orchestrated series of plan runs plus supervisor nodes | Same mint as graph: `run-YYYYMMDDTHHMMSSZ-<ns>-<rand>` (`workflow_state_mint_run_id`) | `workflow-runs/<run-id>/` (`run.json`) | `runs/<run-id>/engine/workflow/` |
| **Graph run** | DAG engine underneath a Dependency workflow (and standalone `graph-run.sh`) | `run-YYYYMMDDTHHMMSSZ-<ns>-<rand>` (`graph_state_mint_run_id`) | `graph-runs/<namespace>/<run-id>/` (`run.json`, frozen `graph.json`) | `runs/<run-id>/engine/graph/` |

A workflow run is not a TODO checklist. A graph run is not a leaf plan. A plan
run may be started by a human or dispatched as one stage of a workflow.

### Pointers that join them

| Field | Where | Meaning |
|-------|-------|---------|
| `registryRunPath` | Graph `run.json` | Absolute path to the workflow registry directory (`workflow-runs/<id>/`) when the graph was started by the workflow layer |
| `engine.statePath` | Workflow `run.json` `.engine.statePath` | Absolute path to the graph (or sequential engine) state directory for that outer run |
| `artifactNamespace` | Workflow `run.json` | Shared artifact namespace (`RALPH_ARTIFACT_NS`) for stages of that workflow |
| `parent.workflow_run_id` / `parent.graph_run_id` / `parent.stage_id` | Plan `run-manifest.json` | How a leaf plan run attributes itself to an outer workflow or graph node |

## Plan run manifest schema

Written once by `ralph_run_plan_write_manifest` to
`logs/<plan-key>/runs/<run-id>/run-manifest.json` (`kind: ralph_run_manifest`,
`run_kind: plan`, `schema_version: 1`). Fields:

- Identity: `run_id`, `plan_key`, `artifact_ns`, `plan_path`, `runtime`, `model`
- Lifecycle: `status`, `started_at`, `ended_at`, `iterations`
- `parent`: `workflow_run_id`, `graph_run_id`, `graph_namespace`, `stage_id` (null when unset)
- `paths`: state-root-relative `log_dir`, `run_dir`, `session_dir`, `tool_results_dir`, `runtime_config_dir`, `artifacts_dir`, `process_run_dir`
- `files`: catalog entries with `path`, `role`, `tier`

`logs/<plan-key>/runs/index.jsonl` appends `{run_id, path, status}` for
`--resume-run last` and `ralph state runs`.

Graph and workflow ledgers use their own `run.json` schemas (`kind: graph` vs
workflow registry records), not this plan-run manifest.

## Retention defaults

Automatic prune runs from `bundle/.ralph/bash-lib/retention.sh` unless
`RALPH_RETENTION_AUTO=0`. Graph terminal-run prune is separate
(`cleanup-plan.sh` / `RALPH_GRAPH_RUN_*`). Workspace-registry age prune uses
`RALPH_WORKSPACE_PRUNE_DAYS` (default 60) in `ralph workspace` prune, not
per-plan log retention.

See [ENVIRONMENT.md](ENVIRONMENT.md#state-workspace-retention) for the env table.

## `ralph state`

Implemented by `bundle/.ralph/bash-lib/state-cli.sh`. State root is
`RALPH_PLAN_WORKSPACE_ROOT` or `$PWD/.ralph-workspace`.

| Command | Behavior |
|---------|----------|
| `ralph state status` | Per top-level directory: name, file count, disk size |
| `ralph state runs [--plan <key>]` | TSV of run id, plan key, status, `exact=` / `degraded=` TODO session counts, `hashes_match=` |
| `ralph state show <run-id>` | Plan `run-manifest.json` plus per-TODO session eligibility (`foreign-run-id` is expected for a later run; `mismatched-todo-hash` is a blocker) |
| `ralph state prune` | Preview (default): list retention-eligible paths, reasons, and byte totals. `ralph state prune --apply` removes only paths that remain eligible on re-check and writes a receipt under the state root. Orphans and unknown-owner paths are never candidates. `--dry-run` is a preview alias; `--json` emits structured output. |
| `ralph state reindex` | Notes that legacy summaries are synthesized on demand |
| `ralph state orphans` | Read-only report of top-level paths the ownership map cannot classify. Unclassified paths are retained and never eligible for prune. |

## Legacy flat layout

Older workspaces stored plan telemetry **directly** under
`logs/<plan-key>/` (for example `plan-usage-summary.json`,
`invocation-usage.json`, and large `*-output.log` files) without a
`runs/<run-id>/` subdirectory. `ralph state runs` still lists those as
`legacy` rows. The dashboard treats them as a plan-key fallback when no
manifest exists.

That flat tree is why a long-lived workspace can hold multiple gigabytes
(this repo's state root has been observed around 3.3 GB): unbounded logs,
tool-results, and artifacts accumulated before per-run directories and
retention knobs. New runs write under `logs/<plan-key>/runs/<run-id>/` and
rely on the retention defaults above. Legacy files are left in place until
the operator deletes them or retention matches a namespaced artifact/log
run dir.
