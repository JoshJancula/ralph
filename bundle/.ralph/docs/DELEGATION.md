# Native subagents and delegated runs

This is the Ralph delegation contract for workflow stages. A runtime agent
executes model work; Ralph's supervisor owns admission, durable state,
isolation, verification, recovery, and completion evidence. Stage guidance is
inline workflow `instructions:` text—not a separate public role resource and
not a native agent profile.

## Stage placement

Ordinary executable stages may declare `type: agent` (or omit `type`, which
still means an agent stage). Supervisor-owned `join`, `router`, `checkpoint`,
`gate`, `integrate`, and `approval` nodes reject agent routing fields,
instructions, TODOs, and mutation scopes at validation time. They are
scheduler-owned and must not receive placeholder-agent configuration.

The runtime-facing word `agent` remains valid for the provider-supplied runtime
agent, native runtime features, `--agent-workspace`, and the compiled node type.
It is not a substitute for workflow stage `instructions:` and does not complete
a Ralph TODO by itself.

Removed fields such as stage `role:`, profile-selecting `agent:`, and
`agentSource:` are rejected. Do not document or require retired role CLI
or agent-migration commands as current.

## Native subagents

`nativeSubagents` controls the selected runtime's own child-assistant facility.
It is separate from Ralph delegated runs.

- Workflow agent stages default to `nativeSubagents: off` where the runtime has
  a proven deny boundary (claude, codex) and to `inherit` where it does not
  (cursor, opencode, antigravity); Ralph never defaults to a value it cannot
  enforce. An explicit `nativeSubagents: off` on a runtime with no proven deny
  boundary fails at preflight. `inherit` preserves the runtime's ambient
  behavior.
- Consensus voters are forced to `off`, and supervisor-owned nodes reject the
  field. The field is accepted on agent stages, consensus voters, and repair
  diagnose/lanes.

**Native subagents never replace or satisfy plan TODOs or stage completion.**
They are runtime-owned and opaque to Ralph's ledger. Ralph does not turn a
native child into a node, artifact owner, attempt, checkpoint, or authoritative
completion/provenance record. Native child events are observational; the parent
runtime agent remains responsible for every write, verification step, declared
artifact, and completion decision. Approval and operator-input waits are
supervisor action records (exit 3), not model claims.

## `delegatedRuns` policy

Delegated runs are Ralph-supervised child executions requested from a workflow
agent stage. The policy is a stage field:

```yaml
delegation:
  delegatedRuns:
    mode: read-only       # off | read-only | changeset
    runtimes: [codex]     # unique supported runtime ids
    maxRuns: 4            # positive total bound
    maxParallel: 2        # positive and <= maxRuns
```

When the policy is omitted, the compiled default is explicit:

```yaml
delegation:
  delegatedRuns:
    mode: off
    runtimes: []
    roles: []
    maxRuns: 0
    maxParallel: 0
```

`mode: off` accepts only `mode`. Enabled policies require a non-empty unique
`runtimes` allowlist, positive `maxRuns`, and positive `maxParallel` no greater
than `maxRuns`. An optional `roles` array, when present, is only an id-grammar
allowlist for child request tagging (stage-id shape); it does not restore the
removed public role CLI or inject role files into prompts.
`changeset` additionally requires the parent stage's `workspaceMode` to be
`snapshot` or `worktree`. Delegation is disabled on supervisor-owned nodes.

The request is bounded and scheduler-derived. It may contain a task,
idempotency key, supported runtime, optional allowlisted tag, and safe
project-relative artifact paths inside the child artifact namespace. Paths are
normalized and must not be absolute, empty-segment, parent-traversal, or
symlink escapes. It may not choose a model, workspace, plan, graph, or
environment path. Child depth is one; a delegated run cannot start another
delegated run. Same-runtime execution additionally requires proven temporary
overlay/config isolation and available runtime capacity.

## MCP tools

Workflow-node MCP exposes exactly these tools:

| Tool | Required input | Effect |
|------|----------------|--------|
| `ralph_delegated_run_start` | `task`, `idempotencyKey`, `runtime`; optional `role`, `artifactPaths` | Validate the frozen `delegatedRuns` policy, create the durable record, and enqueue a run. |
| `ralph_delegated_run_status` | `delegatedRunId` | Read the current status. |
| `ralph_delegated_run_wait` | `delegatedRunId`; optional `timeoutSeconds` | Wait for a terminal state; the wait is capped at 30 seconds. |
| `ralph_delegated_run_result` | `delegatedRunId` | Read the result only after a terminal state. |
| `ralph_delegated_run_cancel` | `delegatedRunId` | Cancel a queued or running run. |

`delegatedRunId` is derived from the outer run, node, attempt, and
`idempotencyKey`. Repeating an identical request is idempotent and returns the
existing id; a conflicting reuse is rejected. Start is available to the stage
context. Read, wait, result, and cancel require the corresponding context or
operator read surface and still revalidate ownership and policy.

## Durable record and states

Records live under the state root at:

```text
.ralph-workspace/delegated-runs/<delegatedRunId>/
  request.json
  status.json
  result.json                 # terminal record, when available
  events.jsonl
  artifacts/
  changeset.json              # changeset mode, after verified capture
  integration.json            # changeset mode, after verified integration
```

`status.json` and every event use schema version `2` and the same
`delegatedRunId`. The durable status is exactly one of:

```text
queued -> running -> succeeded
                  -> failed
                  -> cancelled
queued ----------------> cancelled
```

The five allowed states are `queued`, `running`, `succeeded`, `failed`, and
`cancelled`. Only the last three are terminal. A terminal result is written
once and is readable only when its status is terminal; terminal states cannot
be changed to another terminal state.

Success requires the child plan to finish, its verification to pass, and a
non-empty durable result artifact. Every declared artifact must also be copied
into the state-root-owned `artifacts/` directory. In `changeset` mode, the
scoped changeset must verify against the frozen base and the integration record
must verify before the result can be adopted. A queued, failed, cancelled, or
unverified run blocks normal parent completion. Parent TODO/stage completion
still requires supervisor evidence on the parent boundary—adopting a child
result is not enough for the parent to claim success without that evidence.

## Isolation and authority

Read-only runs execute from a supervisor-created `snapshot`; the parent agent
workspace is copied without `.git` or control-state roots. The result and
ledger remain outside the model-writable copy. Ralph compares before/after
identities and fails closed on a read-only mutation.

Changeset runs use a supervisor-created `snapshot` or detached `worktree`,
require declared write scopes, capture only scoped edits, and integrate only a
verified changeset. The supervisor, not the child, owns source-base identity,
workspace creation/removal, changeset capture, integration, and publication.
All paths are derived or validated as exact owned paths; symlink escapes,
absolute paths, parent traversal, and control-root writes are rejected.

Child cancellation signals only the delegated process group. It never signals
the parent node or supervisor. The child receives a fresh execution boundary,
native child dispatch is disabled for the delegated plan, and the parent must
adopt the verified result rather than trusting completion text.

## Recovery

Recovery is scheduler-owned and preserves durable identity. On restart, a
`running` run whose child process is no longer alive is requeued as `queued`
using its existing `delegatedRunId` and queue record; recovery never mints a
replacement id. A terminal succeeded run is adopted only when its non-empty
result and all declared evidence are present and verified. Missing result
evidence blocks adoption and parent completion.

Failed and cancelled runs remain terminal evidence and do not silently become
success. Parent cancellation propagates to queued/running delegated processes
and records `cancelled`. Inspect `request.json`, `status.json`,
`events.jsonl`, the durable artifacts, and any changeset/integration records
before retrying. Retries use the same request identity and a new attempt record
only when the frozen policy and scheduler admit them.

Internal engine script names (`graph-*`, orchestration bridges) and legacy
`checkpoint` / `humanAck` surfaces may still appear in compiled formats or
legacy recovery paths; public operator recovery uses
`ralph workflow status|resume|reset|recover|cancel` and common actions.
