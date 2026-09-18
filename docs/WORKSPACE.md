# State workspace (`.ralph-workspace/`)

This is the canonical description of the **state root**. Default location:
`<project>/.ralph-workspace`. Override with `--workspace-root` /
`RALPH_PLAN_WORKSPACE_ROOT`. It is not the project root and not the agent
workspace. See [ENVIRONMENT.md](ENVIRONMENT.md#core-plan-runner-and-workspace).

Ralph writes derived run state here. Do not commit it. Retention is
best-effort and described below.

## Top-level directories

| Directory | Writers | Readers | Retention | Safe to delete |
|-----------|---------|---------|-----------|----------------|
| `logs/` | `run-plan.sh`, graph and workflow engines | Dashboard, `ralph state`, `ralph usage`, `ralph benchmark` | Per-plan `logs/<key>/runs/` pruned by `RALPH_RETENTION_LOG_RUNS_*` (default 10 runs / 30 days). Non-terminal run dirs are kept. | Yes, except an in-progress run's log dir |
| `artifacts/` | Plan agents, runner verification, workflow stages | Dashboard file viewer, later stages via artifact tools | Per-namespace prune by `RALPH_RETENTION_ARTIFACTS_*` (default 90 days or 512 MiB) | Yes for finished namespaces |
| `sessions/` | `run-plan` session helpers, background jobs, human continuation | CLI resume, `--resume-run`, Stop hooks | No automatic prune of session ids | Deleting drops plan-level and per-TODO resume |
| `tool-results/` | MCP proxy / native shell compaction | `ralph_proxy_result_*` | `RALPH_MCP_PROXY_RESULT_STORE_*` (default 50 MiB, 7 days, 100 entries per plan key) | Yes |
| `runtime-config/` | Overlay journals and original config snapshots | Cleanup / restore on success, failure, and signal | Journals pruned by `RALPH_RETENTION_JOURNALS_*` (default 20 / 30 days) | Do not delete `originals/` while a run is live |
| `graph-runs/` | Dependency engine (`graph-run.sh`) | `ralph workflow status`, graph dashboard | Terminal runs: `RALPH_GRAPH_RUN_MAX_COUNT` (10) and `RALPH_GRAPH_RUN_MAX_AGE_DAYS` (30) | Yes for old terminal namespaces; not while `running` or `awaiting-ack` |
| `workflow-runs/` | Workflow registry (`workflow-state.sh`) | `ralph workflow *`, dashboard workflows | No dedicated count/age knobs in retention.sh | Only when the operator intends to drop registry history |
| `processes/` | Process supervisor (`ralph_process_supervisor.py`) | Teardown, `ralph state` style inspection | Live leases under `processes/active/` and `processes/leases/` | No while a run is live (contains process identity, not for the dashboard explorer) |
| `plans/` | `ralph create plan`, workflow materialization | `ralph workflow list-plans`, MCP plan roots | None | Only copies you no longer need; live control plans live here |
| `orchestration-plans/` | Sequential engine materialization | Orchestrator internals | None | Same caution as `plans/` |
| `docs/` | Optional operator notes in some installs | Dashboard docs hub | None | Yes |
| `memory/` | Plan-scoped `ralph_proxy_memory_*` | Later turns of the same plan key | Bounded per plan | Yes; content is untrusted model-authored notes |
| `security/` | MCP approval watcher | Operator decision files | None while requests are outstanding | No during an approval wait |
| `command-profiles/` | Profile store (`ralph profiles`) | Profile CLI | None | Yes if you accept losing saved profile stats |
| `metrics/` | Usage / discover reports when generated | Dashboard discover panel | None | Yes |
| `delegated-runs/` | Graph delegation ledger (`graph-delegation-ledger.sh`) | Child-run completion, `ralph_delegated_run_*` | None dedicated; tied to the parent graph run | No while a delegated child is live |
| `handoffs/` | Sequential / workflow stage handoff writers | Downstream stages, dashboard | None dedicated | Yes for finished runs |
| `manual-verification/` | Runner-owned `verify:` output | Dashboard, next invocation failure summary | Follows the owning plan run | Yes after the run is terminal |
| `repo-map/` | `ralph_proxy_repomap` / `repo-map.sh` | Proxy repomap cache | Cache keyed by tree slug | Yes |
| `search-context/` | `ralph_proxy_search` contextual index (`search_context.py`) | Subsequent searches | Cache under `search-context/<slug>/` | Yes |
| `setup-journal/` | `setup-runtime.sh` / `setup-journal.sh` | Install/setup restore | Per operation id | Do not delete mid-setup |
| `workflows/` | Project-user workflow definitions (`ralph create workflow`) | `ralph workflow list/show/start` | None (operator data) | Only copies you no longer need |

Top-level **files** (not directories) such as `hooks-config.jsonl` are overlay
journals for hook config and are restored with `runtime-config/`.

## Three run kinds

Keep these distinct. They share a state root but different ids and homes.

| Kind | What it is | Id format | Canonical home |
|------|------------|-----------|----------------|
| **Plan run** | One `ralph run --plan` (leaf TODO loop) | Process run id, typically `<UTC>-<pid>-<hex>` (example `20260917T204940-93013-2edd8b0e`). Stored as `RALPH_PROCESS_RUN_ID`. | `logs/<plan-key>/runs/<run-id>/` with `run-manifest.json`; sessions at `sessions/<plan-key>/` |
| **Workflow run** | An orchestrated series of plan runs plus supervisor nodes | Same mint as graph: `run-YYYYMMDDTHHMMSSZ-<ns>-<rand>` (`workflow_state_mint_run_id`) | `workflow-runs/<run-id>/` (`run.json`) |
| **Graph run** | DAG engine underneath a Dependency workflow (and standalone `graph-run.sh`) | `run-YYYYMMDDTHHMMSSZ-<ns>-<rand>` (`graph_state_mint_run_id`) | `graph-runs/<namespace>/<run-id>/` (`run.json`, frozen `graph.json`) |

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
| `ralph state prune` | Dry-run message; does not delete |
| `ralph state reindex` | Notes that legacy summaries are synthesized on demand |
| `ralph state orphans` | Reports only; no auto-delete |

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
