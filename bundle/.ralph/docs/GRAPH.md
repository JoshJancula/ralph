# Graph mode

Graph mode runs a Ralph plan as a directed acyclic graph (DAG). Use it when parts of a job can run independently, must cross runtime or provider boundaries, need durable per-node recovery, or require controlled integration and verification.

Graph mode is opt-in. A plan enters it only when its frontmatter contains `execution: graph` or when you use `ralph graph`. Existing checklist plans, flat YAML plans, orchestration plans, and `.orch.json` files keep their existing behavior.

## Graph vs orchestration

A graph node genuinely *is* a pipeline stage plus a small number of extra fields — the two modes are close enough to confuse.

**Orchestration** (`ralph create orc`): stages run in order, or in parallel waves you declare. This is the simpler default — pick it unless you specifically need one of the graph capabilities below.

**Graph** (`ralph create graph`): stages form a dependency graph (`dependsOn`) instead of a fixed order, and adds:

- cross-provider consensus (multiple runtimes vote on one result)
- checkpoint nodes (pause for human ack without blocking unrelated branches)
- isolated workspace mutation (snapshot/worktree) for safer parallel writes

Not sure which you want? Run `ralph create wizard` — it asks this question interactively before handing off to the matching wizard.

## Choose the smallest execution model

| Need | Use |
|------|-----|
| Sequential TODOs in one working tree | A classic or YAML plan with `ralph run --plan ...` |
| Ordered stages with artifact handoffs | Orchestration with `ralph create orc` |
| Independently schedulable, resumable, or cross-provider stages | A graph node |
| Cheap read-only fan-out inside one model turn | A native subagent, when the runtime supports it |
| Isolated delegated work with its own result and retry record | A brokered child from a graph node |

A graph is the contract between nodes. An `agent` node with a `planFile` still runs the normal Ralph plan loop inside that node, including TODO selection and verification. This lets a graph coordinate durable stages without replacing the existing loop.

## Requirements

- `python3` compiles and validates graph plan frontmatter.
- `jq` runs the scheduler, ledger, status, and consensus aggregation.
- Every runtime named by a node must be installed and authenticated before the run starts.
- `worktree` mode additionally needs a clean Git repository and a runtime sandbox boundary Ralph can prove.

## Create a graph plan

Interactive (recommended if you're not sure of the exact shape yet):

```bash
ralph create graph
```

Authors `agent`, `consensus`, `checkpoint`, and `join` nodes step by step: node ids, runtime/agent/model, `dependsOn`, consensus voters and policy, workspace mode. `router`, `gate`, and `integrate` node types aren't wizard-authorable yet — hand-edit the generated plan to add them.

Non-interactive/scriptable: a general graph template,

```bash
ralph create plan --format graph --name my-graph
```

or the built-in presets, which cover the two most common shapes:

```bash
# Three independent providers review the same result.
ralph create plan --format graph \
  --preset cross-provider-jury \
  --name release-review

# Two to four isolated implementation lanes, integration, gates, and review.
ralph create plan --format graph \
  --preset parallel-implementation \
  --name feature-work \
  --lanes 3 \
  --workspace-mode snapshot
```

For parallel implementation, `snapshot` is the safe default. `--workspace-mode worktree` requires the Git and sandbox conditions described below. `--workspace-mode shared` is intentionally guarded and also requires `--acknowledge-shared-mutation-risk`. Add `--publish-checkpoint` to place a human checkpoint after review.

The installed source templates are under `.ralph/plan-templates/`:

- `graph-consensus.plan.template.md`
- `graph-parallel-implementation.plan.template.md`

## Compile before running

Compilation parses the plan, expands authoring macros such as consensus and repair rounds, derives edges, rejects unsafe ownership, validates the DAG, and writes a cached `.graph.json` beside the plan.

```bash
ralph graph compile path/to/graph.plan.md
ralph graph compile path/to/graph.plan.md --render mermaid
ralph graph render path/to/graph.plan.md --format ascii
```

Use `--out <path>` with `compile` or `render` to choose an output file. Use `--force` with `compile` to replace an existing cache. Rendering is a static view of the compiled topology, not live run state.

Compilation is also a useful lint step in review or CI because it performs no model invocation.

## Plan structure

A graph plan is a YAML-frontmatter pipeline with `execution: graph`:

```yaml
---
name: docs-review
namespace: docs-review
execution: graph
pipeline:
  maxParallel: 2
  edgeDerivation: both
  failurePolicy: drain
  publishMode: manual
  stages:
    - id: research
      runtime: cursor
      agent: research
      workspaceMode: snapshot
      produces:
        - path: "{{ARTIFACT_NS}}/research.md"

    - id: review
      runtime: codex
      agent: code-review
      workspaceMode: snapshot
      dependsOn: [research]
      requires:
        - path: "{{ARTIFACT_NS}}/research.md"

todos:
  - id: research-1
    stage: research
    content: Research the change and write the declared artifact.
    status: pending
  - id: review-1
    stage: review
    content: Review the research and record the result.
    status: pending
---
```

Top-level graph settings:

| Field | Meaning |
|-------|---------|
| `name` | Human-readable plan name. |
| `namespace` | Stable key used for the run ledger, artifacts, and logs. |
| `execution: graph` | Explicitly opts the plan into graph routing. |
| `pipeline.maxParallel` | Maximum nodes Ralph may run concurrently; default `2`. |
| `pipeline.edgeDerivation` | `declared`, `artifacts`, or `both`; default `both`. |
| `pipeline.strictEdges` | When true, require the stricter edge checks used by parallel implementation plans. |
| `pipeline.failurePolicy` | `drain` lets in-flight work finish; `cancel` stops it after a failure. |
| `pipeline.publishMode` | `manual` (default) or guarded `on-verified`. |

### Nodes

Entries in `pipeline.stages` become graph nodes. An agent node is the default and normally declares `id`, `runtime`, `agent` or `model`, and either inline TODOs or `planFile`.

| Type | Purpose |
|------|---------|
| `agent` | Run a Ralph stage or node-local plan on a selected runtime. |
| `consensus` | Expand independent voters and aggregate their verdicts. |
| `join` | Apply a join policy to upstream results. |
| `router` | Select one allowlisted downstream route from structured output. |
| `checkpoint` | Pause one subtree until a human creates its acknowledgement file. |
| `gate` | Run a named, model-free verification profile. |
| `integrate` | Apply isolated changesets in deterministic order. |
| `adjudicator` | Resolve a consensus result when the selected policy requires it. |

The compiler also creates internal node types such as consensus voters and barriers. Do not author those synthetic types directly.

Use a separate `planFile` when a node needs multiple local TODOs or its own readable checkpoint state:

```yaml
- id: implement-api
  runtime: codex
  agent: implementation
  planFile: .ralph-workspace/plans/feature/implement-api.plan.md
  workspaceMode: snapshot
  writeScopes: [src/api/**, tests/api/**]
```

### Edges and artifacts

Declare ordering directly with `dependsOn`, derive it from matching `produces` and `requires` paths, or use both:

- `edgeDerivation: declared` uses `dependsOn` only.
- `edgeDerivation: artifacts` connects producers to consumers.
- `edgeDerivation: both` combines both forms and is the default.

Artifact paths are also completion contracts. A downstream node is not released merely because its predecessor reports success; required artifacts must exist and be non-empty. `{{ARTIFACT_NS}}`, `{{PLAN_KEY}}`, and `{{STAGE_ID}}` are available in declared paths.

Prefer explicit `dependsOn` for control flow and artifact-derived edges for real data handoffs. The compiler rejects cycles, missing dependencies, duplicate producers where ownership is ambiguous, and invalid conditional routes.

## Run and inspect

Both commands below compile and run a graph plan:

```bash
ralph graph run path/to/graph.plan.md
ralph run --plan path/to/graph.plan.md
```

The general `ralph run` command detects `execution: graph` before it checks for a pipeline block. You can override the plan namespace or parallel limit for a direct graph run:

```bash
ralph graph run path/to/graph.plan.md \
  --namespace release-review \
  --max-parallel 3
```

### Reading the run output

A run opens with a header and a resolved agent table, so you can confirm which runtime, agent, and model each node will use before any of them start:

```
------------------------------------------------------------------------
Ralph graph run release-review
------------------------------------------------------------------------
  run id         run-20260811T135841Z-0-vk9YK7
  nodes          26
  max parallel   5 (per runtime: 1)
  on failure     drain

Node agents
  NODE                       RUNTIME   AGENT          MODEL
  define-canonical-inputs    cursor    architect      gpt-5.6-sol-high
  implement-cli-bootstrap    opencode  implementation ollama-cloud/kimi-k2.7-code
  start                      scheduler -              no model invoked
```

Nodes marked `scheduler` are gate, integration, and checkpoint nodes; they never invoke a model. A model shown as `(unresolved)` means the scheduler could not read one up front and the agent source or runtime default will apply at spawn time; it is a note, not an error.

During execution each node prints a lifecycle line, and a failure carries the underlying cause plus the log that produced it:

```
-> implement-cli-bootstrap opencode / implementation
ok start gate profile=noop
XX implement-cli-bootstrap exit=1 reason=outcome=failed policy=drain
   cause: kimi-k2.5 was retired at 2026-07-31 00:00:00 -0700 PDT
   log: .ralph-workspace/graph-runs/<ns>/<run-id>/logs/nodes/<safe-node-id>/<attempt-id>/agent.log
```

The run closes with a tally, the first failing node, and every node that did not succeed. Color is dropped when stderr is not a terminal, and when `NO_COLOR` or `RALPH_GRAPH_NO_COLOR=1` is set.

Inspect a live or completed run without modifying it:

```bash
ralph graph status --namespace release-review --run latest
```

`status` prints a node table and a Mermaid graph with state classes. It also surfaces attempt metadata such as workspace mode, scopes, integration inputs, gate outcomes, consensus provenance, and publish readiness when present.

By default `status` stays concise: the run summary plus one row per node (node, type, runtime, state, unique attempt count, duration). Add `--details` for verbose per-node and per-attempt metadata, and `--mermaid` for the flowchart. `--details` also reports attempts, elapsed active and wait time, usage or `n/a` when usage is unreliable, retry classification, and repeated-tool-call hints.

`status` never recovers a run. Reading a stale run tells you it is stale; it does not change it.

### Reading one attempt's logs

Every attempt owns three streams under the run directory. Print one without opening the files yourself:

```bash
ralph graph logs --namespace release-review --run latest \
  --node implement-cli-bootstrap \
  --stream agent --tail 200
```

- `--stream runner|agent|usage` selects the stream; the default is `agent`.
- `--attempt <id>` selects one attempt; the default is the latest.
- `--tail N` bounds the output, and `--follow` waits for new bytes, survives rotation and truncation, and exits when the attempt reaches a terminal state or on SIGINT/SIGTERM.

Paths come from the node ledger's `logPaths` and are resolved only when they stay inside the run directory. A missing v2 file falls back to the historical v1 namespace path. A missing log for a still-active attempt is reported explicitly but is not an error.

### Watching a run live

```bash
ralph graph attach --namespace release-review --run latest
```

`attach` is a read-only live view of run status and the event journal. Detaching with SIGINT or SIGTERM never cancels the supervisor and never mutates the ledger, and `attach` never recovers a run.

### Interactive viewer

```bash
ralph graph tui --namespace release-review --run latest
```

The TUI adds node navigation, a log pane over the same contained log-selection contract as `ralph graph logs`, and operator decisions bound to keys. It falls back to concise streaming status when `python3`, `curses`, or a suitable TTY is unavailable, and it restores terminal settings on normal exit, exception, SIGINT, and SIGTERM. `--no-tui` forces the streaming path. `ralph graph run --tui` launches the viewer once the run is created; `--no-tui` keeps the headless scheduler in the foreground.

## Durable state and resume

Each run has a durable ledger at:

```text
.ralph-workspace/graph-runs/<namespace>/<run-id>/
  run.json
  graph.json
  nodes/
  workspaces/
  latest -> <run-id>
```

`graph.json` is the frozen topology for that run. Node JSON files record state and attempts. Graph progress does not use checkboxes in the control plan; checkboxes remain local to a node's ordinary Ralph loop.

### Ledger schema versions

A run's ledger carries a `schemaVersion`. Version 2 records one `attempts[]` object per attempt id, updated in place as the attempt starts, heartbeats, reports usage, and terminalizes. Version 1 appended a separate record per state transition, so one attempt could appear twice.

Version 1 runs stay readable forever. Readers normalize a v1 file to the v2 shape in memory and never rewrite it, so `status`, `logs`, `attach`, `recover`, and `successor` all work against a run created before v2 existed. A v1 run also keeps its original write path: the scheduler reads the run's `schemaVersion` once and keeps writing v1 bytes for a v1 run. Ralph refuses a ledger whose `schemaVersion` is missing, non-numeric, or newer than it knows rather than guessing at the shape.

Resume the newest run with:

```bash
ralph graph resume path/to/graph.plan.md \
  --namespace release-review \
  --run latest
```

On resume Ralph recompiles the plan and compares its `graphSha` with the frozen graph:

- Succeeded nodes are skipped.
- An interrupted running node is adopted when its stage outcome report exists; otherwise it returns to pending.
- Failed, cancelled, or blocked nodes return to pending.
- A changed graph is rejected by default.

If the change is intentional, use `--accept-graph-change`. Ralph invalidates nodes whose stage definition or ancestor set changed instead of blindly trusting their old success. Prefer starting a new run for substantial topology changes.

The live graph is immutable. Dynamic planning that adds arbitrary nodes during execution is deliberately unsupported because it would make recovery from the frozen ledger ambiguous.

## Checkpoints

A `checkpoint` node pauses only its downstream subtree. Independent branches keep running, and the graph command exits with status `3` when the remaining work is awaiting acknowledgement.

The scheduler prints the exact acknowledgement path. With the default state root it is:

```text
.ralph-workspace/artifacts/<namespace>/checkpoints/<node-id>.ack
```

After reviewing the run, create that file and resume:

```bash
touch .ralph-workspace/artifacts/release-review/checkpoints/publish-checkpoint.ack
ralph graph resume path/to/graph.plan.md \
  --namespace release-review \
  --run latest
```

Resuming before the acknowledgement exists is a clean no-op; the node remains `awaiting-ack`.

## Operator permissions and approvals

When a runtime stops a node because it needs permission it did not have, the node does not fail. It enters `awaiting-operator`, records a request under the run directory, releases its runtime slot, and lets every independent branch keep scheduling. A permission pause does not consume a retry grant and does not charge the node's active-time budget.

List what is waiting, then answer it:

```bash
ralph graph actions list --namespace release-review --run latest
ralph graph actions respond <request-id> --decision allow-once
```

`actions list` prints the request id, node, runtime, action, resource, effect, and available choices. Add `--json` for the request objects.

### Decision lifetimes

| Decision | Scope | Stored |
|----------|-------|--------|
| `allow-once` | This request id only. The next identical request asks again. | The decision record for that request |
| `allow-run` | This exact normalized key, for the rest of this run. | `<run-dir>/operator/policy/<rule-id>.json` |
| `allow-always` | This exact normalized key, for this project, until revoked. | `<state-root>/operator-policy/approvals.json` |
| `deny` | This exact normalized key, for the rest of this run. | `<run-dir>/operator/policy/<rule-id>.json` |

`allow-always` is deliberately harder to grant than the others: it requires `--confirm-rule` with the exact normalized rule id, which writes a second confirmation record tied to the original request. Without that confirmation the rule never becomes active.

Requests resolve in a fixed order, and a broader allow can never weaken a narrower deny:

1. an explicit runtime or managed denial on the request
2. a Ralph `deny` rule for the exact normalized key
3. an `allow-once` decision for this request id
4. an exact `allow-run` rule for the same key
5. an exact active project `allow-always` rule for the same key
6. otherwise, ask

Matching is exact after normalization. Review and revoke project rules with:

```bash
ralph graph actions approvals list
ralph graph actions approvals revoke --runtime cursor --action Bash \
  --resource src/app.ts --effect write
```

Revoking the same rule twice is idempotent. These commands only ever touch Ralph's project-scoped approvals; they never edit runtime-global configuration.

## Retry and budgets

A failed attempt is classified before Ralph decides what to do with it. Only two classes are retried automatically:

| Class | Meaning | Retried |
|-------|---------|---------|
| `transient-runtime` | Connection reset, timeout, rate limit, provider hiccup | Up to `resilience.transientRetries` |
| `agent-correctable` | Verification failed, required artifact missing | Up to `resilience.correctiveRetries` |
| `operator-permission` | Runtime refused a permission-gated action | No; pauses for an operator decision |
| `plan-contract` | Wrote outside the declared scope, undeclared path | No; node enters `needs-plan-repair` |
| `terminal-configuration` | Bad credentials, unknown model, invalid schema | No |
| `cancelled` | Interrupted or signalled | No |

Retries are bounded and deterministic. A granted retry moves the node to `retry-wait` with a recorded classification, retry ordinal, backoff, and `retryAt`; the node returns to `pending` only once that timestamp elapses. Backoff comes from `resilience.backoffSeconds` and is capped, so a repeatedly failing node cannot stretch a run indefinitely. A retry reuses the node's isolated workspace and passes only a compact correction record forward: node identity, attempt and classification, the correction itself, required artifact paths, and references to the previous logs. Full prior prompts and transcripts are never replayed into the retry.

A `plan-contract` failure blocks only that node's descendants. Independent branches keep draining, which is what makes a single out-of-scope write survivable.

Budgets bound the clock rather than the attempt count:

- `budgets.maxActiveSeconds` caps one node's active execution time.
- `budgets.maxRunActiveSeconds` caps the whole run's active time.
- `budgets.missingUsage` (`warn` by default) decides what happens when a runtime reports no usable token usage.

Waiting is not active time. Checkpoint waits, permission pauses, and retry backoff do not charge either budget.

## Exit codes

`ralph graph run` and `ralph graph resume` report the state of the graph, not of the last node:

| Code | Meaning |
|------|---------|
| `0` | Every node succeeded. |
| `1` | The run failed. A node failed terminally, or nothing remains runnable and the graph cannot complete. |
| `3` | The run is incomplete but healthy: work remains that is waiting on a human. The run status distinguishes `awaiting-ack` (a checkpoint) from `awaiting-operator` (a permission request). |

Status `3` is not a failure and should not be treated as one in CI. Answer the checkpoint or the permission request, then resume.

## Recovery

A run whose supervisor died leaves attempts marked `running` that nothing is driving. `status` and `attach` report that condition but never repair it; recovery is always an explicit operator action:

```bash
ralph graph recover --namespace release-review --run latest
```

Recovery takes the run lock, interrupts orphaned running attempts, records `node-interrupted` and `node-recovered` events, and resets only those interrupted nodes to `pending`. Nodes in `succeeded`, `skipped`, `awaiting-operator`, and `needs-plan-repair` are preserved exactly as they were, so recovery never discards evidence or silently re-answers a permission request. Concurrent recoverers yield exactly one mutation. When recovery is not allowed, the command prints the recovery module's refusal reason and changes nothing.

## Successor runs

A successor run re-uses a finished run's evidence instead of repeating it. The default is a read-only report:

```bash
ralph graph successor --from latest --plan path/to/graph.plan.md \
  --namespace release-review
```

The report compares the predecessor with the newly compiled plan and lists which nodes are reusable. Add `--create` to write a linked successor run that copies only that reusable evidence, and `--run-id <id>` to name it. The predecessor is never mutated. `--from latest`, or a run id that exists in more than one namespace, requires `--namespace`.

## Scheduling and failure behavior

`maxParallel` is a global ceiling, not a promise that every ready node will overlap. Ralph also applies runtime admission controls. The normal per-runtime cap is one because concurrent invocations on the same runtime can otherwise interleave temporary configuration overlays. Distinct runtimes can proceed independently.

A node with `subagents: on` reserves its runtime allowance for the duration of that node. Use `subagents: inherit` for the runtime's normal behavior or `subagents: off` to remove dispatch. Consensus voters are always forced to `off` so each verdict remains an attributable independent measurement.

When a node fails:

- `failurePolicy: drain` stops new dispatch and lets already-running siblings finish.
- `failurePolicy: cancel` stops new dispatch and signals in-flight siblings to terminate.

Neither policy converts incomplete downstream nodes into success.

## Workspaces, mutation, and integration

Graph mode separates model work from supervisor-owned workspace and publication operations.

| Mode | Behavior | Use when |
|------|----------|----------|
| `snapshot` | Copy the frozen source into a non-Git isolated workspace. | Recommended default for read or write lanes, including dirty and non-Git callers. |
| `worktree` | Create a detached Git worktree from the frozen base. | The caller is a clean Git repository and the runtime sandbox is proven. |
| `shared` | Use the caller's agent workspace directly. | Mutation is intentionally serialized and you accept the reduced isolation. |

For isolated mutating nodes, declare project-relative `writeScopes`. Ralph rejects changes outside those scopes and captures an attributable changeset. Keep parallel lanes disjoint. For compatibility, omitting `workspaceMode` means `shared`; new graph presets select `snapshot` explicitly.

```yaml
- id: api-lane
  runtime: cursor
  agent: implementation
  workspaceMode: snapshot
  agentGitAccess: off
  writeScopes: [src/api/**, tests/api/**]
```

Unordered overlapping scopes are a compile error unless all overlapping lanes name the same `overlapOwner` and a downstream integration or repair owner is declared. This makes conflict ownership part of the frozen graph instead of an informal prompt instruction.

Shared mutation with scopes requires both safeguards on every mutating node:

```yaml
workspaceMode: shared
parallelMutation: allow
acknowledgeSharedMutationRisk: true
```

Those fields acknowledge risk; they do not create isolation. Prefer snapshots and a scheduler-owned `integrate` node. Keep `agentGitAccess: off` for worktrees. Ralph's supervisor should create workspaces, capture changesets, integrate results, and publish; agents should edit only their assigned files.

## Verification gates and repair rounds

A gate is a scheduler-owned, model-free verification step. Define allowlisted commands once, then reference the profile from a `gate` node:

```yaml
pipeline:
  verificationProfiles:
    - name: fast
      steps:
        - name: unit-tests
          command: npm test
          timeout: 600
          continueOnFailure: false
          requiredArtifacts: []
  stages:
    - id: fast-gate
      type: gate
      profile: fast
      dependsOn: [integrate]
```

Profiles support bounded timeouts, required artifacts, continuation behavior, and verification resource classes. Because the scheduler owns the command, a model cannot declare a gate passed without the command result. The first executable must be in Ralph's gate allowlist; operators can extend it with the colon-separated `RALPH_GATE_EXTRA_ALLOWED` environment variable.

`pipeline.repairRounds` is a compile-time macro for a bounded repair epoch. It expands a fixed sequence of integration, gate, diagnosis, scoped repair lanes, reintegration, and regating. A `changes-required` result routes findings through the ownership map; it never mutates the live graph. Start with the `parallel-implementation` preset for a complete example.

## Consensus

A `consensus` node compiles into independent voter nodes plus a barrier. Each voter should use a distinct runtime, agent, and model identity where practical:

```yaml
- id: review
  type: consensus
  policy: veto
  dependsOn: [full-gate]
  voters:
    - id: cursor-review
      runtime: cursor
      agent: code-review
      sessionStrategy: fresh
    - id: codex-review
      runtime: codex
      agent: code-review
      sessionStrategy: fresh
    - id: claude-review
      runtime: claude
      agent: code-review
      sessionStrategy: fresh
```

Available policies are `veto`, `unanimous`, `quorum`, and `adjudicate`. `onVoterError` controls whether an unavailable voter fails, is excluded, or is retried. Voter delegation is forced off, and voter provenance is recorded with the result. Aggregated results are written under `.ralph-workspace/artifacts/<namespace>/consensus/`.

The `cross-provider-jury` preset is the quickest way to produce a valid three-runtime jury.

## Delegation inside a node

Use native subagents only for bounded read-only work whose loss on retry is acceptable. They are internal to one runtime invocation: Ralph does not give them their own node state, checkpoint, attribution, or completion authority. The parent node must synthesize their findings, perform mutations, verify the result, and satisfy declared artifacts.

Use Ralph's brokered child delegation when delegated work needs an isolated child plan, durable result artifact, bounded retry, and ledger evidence. Brokered children are depth-limited and remain subordinate to the parent node's scope and completion checks. See the delegation guide, `DELEGATION.md` in Ralph's bundled docs (`.ralph/docs/` in an installed project), for the capability matrix and threat controls.

## Publication

`publishMode: manual` is the default. A successful run retains its integrated output and recovery bundle without changing the caller's working tree; inspect the recorded result and publish it deliberately.

`publishMode: on-verified` permits automatic publication only when the run is successful and complete, integration is drift-free, every required gate has passed, and the caller is still in a safe state. If any precondition fails, Ralph refuses publication and keeps recovery artifacts. Publication is supervisor-owned and journaled so interrupted work can be recovered without trusting a model-issued Git command.

## Files produced by a run

With the default state root, inspect these locations:

| Path | Contents |
|------|----------|
| `.ralph-workspace/graph-runs/<namespace>/<run-id>/` | Frozen graph, run state, node attempts, workspaces, changesets, integration and recovery records. |
| `.ralph-workspace/graph-runs/<namespace>/<run-id>/logs/` | Run-owned supervisor, admission, and per-attempt `runner.log` / `agent.log` / `usage.json`. |
| `.ralph-workspace/artifacts/<namespace>/` | Shared node artifacts, consensus results, checkpoints, and declared handoffs. |

If you set a separate state root with `--workspace-root` or `RALPH_PLAN_WORKSPACE_ROOT`, these `.ralph-workspace` paths resolve there. Runtime configuration still resolves from the Ralph project root, and the agent workspace remains the tree where the selected runtime reads and writes.

## Troubleshooting

**Compile reports a cycle, missing node, or duplicate producer.** Render the graph, then make control dependencies explicit. Ensure each required artifact has one unambiguous producer and every `dependsOn` id exists.

**A ready node does not start.** Check `maxParallel`, the per-runtime admission cap, workspace setup, and whether another node has reserved that runtime with `subagents: on`.

**Every node fails within seconds with `exit=1` and no token usage.** The agent CLI rejected the request before any work began, most often because the configured model id no longer exists at the provider. Read the `cause:` line under the failure and compare the run header's agent table against the models your CLI currently offers. Fix the canonical agent definition rather than a generated per-runtime config; editing one generated copy does not update the others.

**The run exits with status 3.** This is not a failure. Work remains that is waiting on a human: either an `awaiting-ack` checkpoint or an `awaiting-operator` permission request. Read `ralph graph status` to see which. For a checkpoint, create the printed `.ack` file after review; for a permission request, answer it with `ralph graph actions respond`. Then resume.

**A node sits in `awaiting-operator` and nothing happens.** Ralph is waiting for you. Run `ralph graph actions list` for the pending request and answer it. Independent branches keep draining while it waits, so a partially finished run is expected here.

**A node is stuck in `needs-plan-repair`.** The attempt wrote outside its declared scope. Only that node's descendants are blocked. Fix the plan's `writeScopes` or the node's work, then start a run that reflects the corrected plan.

**Attempts are marked `running` but nothing is progressing.** The supervisor died. `status` and `attach` will not repair this by design; run `ralph graph recover` explicitly.

**Resume says `graphSha` changed.** The plan no longer matches the frozen graph. Restore the original plan, begin a new run, or use `--accept-graph-change` only after reviewing which nodes will be invalidated.

**A node reports success but downstream work stays blocked.** Check its required artifacts, changeset scope, stage outcome report, and gate result. Graph completion is evidence-based; model text alone is insufficient.

**Worktree mode is rejected.** Confirm the project is a clean Git repository, keep `agentGitAccess: off`, and provide a runtime whose sandbox boundary Ralph can prove. Use `snapshot` otherwise.

**Publication is refused.** Inspect publish readiness in `ralph graph status`. Caller drift, uncommitted changes, incomplete integration, a failed gate, or an unfinished node intentionally prevents `on-verified` publication.

## Command reference

```bash
ralph graph compile <plan-path> [--render mermaid|dot|ascii] [--out <path>] [--force]
ralph graph preflight <plan-path> [--json] [--workspace <dir>]
ralph graph run <plan-path> [--namespace <ns>] [--max-parallel <n>] [--tui|--no-tui]
ralph graph resume <plan-path> --namespace <ns> --run <run-id|latest> [--accept-graph-change]
ralph graph status --namespace <ns> --run <run-id|latest> [--details] [--mermaid]
ralph graph render <plan-path> [--format mermaid|dot|ascii] [--out <path>]
ralph graph logs --namespace <ns> --run <run-id|latest> --node <id> [--attempt <id>] [--stream runner|agent|usage] [--tail N] [--follow]
ralph graph attach --namespace <ns> --run <run-id|latest>
ralph graph tui --namespace <ns> --run <run-id|latest> [--no-tui]
ralph graph actions list --namespace <ns> --run <run-id|latest> [--json]
ralph graph actions respond <request-id> --decision allow-once|allow-run|allow-always|deny [--confirm-rule <rule-id>]
ralph graph actions approvals list [--json]
ralph graph actions approvals revoke --runtime <rt> --action <name> --resource <path> --effect <effect>
ralph graph recover --namespace <ns> --run <run-id|latest>
ralph graph successor --from <run> --plan <path> [--namespace <ns>] [--create] [--run-id <id>] [--json]
```

Every verb accepts `--workspace <dir>`.

For the ordinary plan loop inside an agent node, see [Agent workflow](AGENT-WORKFLOW.md). For environment and root overrides, see [Environment](ENVIRONMENT.md). For the trust boundary around workspaces and model tools, see [Security](SECURITY.md).
