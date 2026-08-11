# Native Subagent Dispatch Capability Matrix

This document records the proven delegation capabilities for each runtime. The matrix is **fail-closed**: runtimes are unsupported until both recursion removal and read-only enforcement are proven.

## Summary Table

| Runtime | Dispatch Tool | Enable Mechanism | Disable Mechanism | Read-Only Child | Deny MCP Per-Child | Provenance Events | Headless Honors | Same-Runtime Parallel Safe | Status |
|---------|--------------|------------------|-------------------|-----------------|-------------------|-------------------|-----------------|----------------------------|--------|
| **claude** | `Agent` | `--allowedTools Agent` | `--disallowedTools Agent` | No | No | No | Yes | Yes (`temporary-cli-config`) | **PROVEN** |
| **opencode** | `task` | `--allowed-tools task` | `--disallowed-tools task` | Via permission rules | Via MCP config | No | Yes | Yes (`temporary-env-config`) | **UNPROVEN** |
| **codex** | custom agent | `--agent <name>` with subagents config | custom agent without subagents | Via sandbox config | Via config.toml | No | Yes | Yes (`temporary-cli-overrides`) | **UNPROVEN** |
| **cursor** | none proven | N/A | N/A | N/A | N/A | N/A | N/A | No (`project-root-overlay-journal`) | **UNSUPPORTED** |
| **antigravity** | none proven | N/A | N/A | N/A | N/A | N/A | N/A | Yes (`temporary-env-config`) | **UNSUPPORTED** |

The same-runtime parallel flag is independent of native-subagent support. It
only proves that Ralph-owned runtime configuration additions cannot collide
between graph invocations. An isolated snapshot or worktree agent workspace is
not proof: runtime configuration is discovered from the project root, and
user/global configuration plus overlay journals may otherwise still be shared.

## Detailed Runtime Analysis

### Claude (claude)

**Dispatch Tool:** `Agent`

**How Enabled:**
- Added to `--allowedTools` list when `subagents=on`
- Code path: `bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh:411-416`
- When `subagents_mode == "on"`, `Agent` is appended to the tools_use CSV

**How Removed from Child:**
- Explicit `--disallowedTools Agent` when `subagents_mode == "off"`
- Code path: `bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh:520-521`
- This deny flag is needed even when an ambient/native agent profile adds `Agent` after Ralph selected its allowed-tools list

**Child-Specific Read-Only Enforcement:**
- **NOT PROVEN** — Claude's Agent tool does not expose a per-child read-only flag
- Parent can restrict child's tools via `--allowedTools`, but filesystem write permissions are not granular per-child

**MCP Tools Denied Per-Child:**
- **NOT PROVEN** — No mechanism to deny specific MCP servers to a child Agent
- Parent's MCP config applies to all Agents in the session

**Subagent Events Expose Provenance:**
- **NOT PROVEN** — Agent tool events do not include distinct provenance metadata
- Cannot distinguish parent vs. child tool calls in event stream

**Headless Mode Honors Controls:**
- **YES** — `--disallowedTools Agent` works in headless mode
- Verified in `ralph_run_plan_invoke_claude` function

**Verdict:** **PROVEN** for enable/disable boundary only. Read-only, MCP denial, and provenance are NOT proven.

---

### OpenCode (opencode)

**Dispatch Tool:** `task`

**How Enabled:**
- OpenCode supports subagent dispatch via the `task` tool
- Would be enabled via `--allowed-tools task` flag
- Reference: OpenCode documentation on subagents

**How Removed from Child:**
- Would use `--disallowed-tools task` to remove from child context
- **NOT PROVEN** — No live probe confirms this boundary works

**Child-Specific Read-Only Enforcement:**
- **Via Permission Rules** — OpenCode supports permission rules that can enforce read-only access
- Would require child-specific permission configuration
- **NOT PROVEN** — No probe confirms per-child read-only works

**MCP Tools Denied Per-Child:**
- **Via MCP Config** — OpenCode's MCP configuration could theoretically deny specific servers per-child
- **NOT PROVEN** — No probe confirms per-child MCP denial works

**Subagent Events Expose Provenance:**
- **NOT PROVEN** — No evidence that task events include child provenance metadata

**Headless Mode Honors Controls:**
- **LIKELY** — OpenCode's headless `opencode run` mode respects tool allow/deny lists
- **NOT PROVEN** — No live probe confirms `--disallowed-tools` works in headless mode

**Verdict:** **UNPROVEN** — Requires live probes to confirm enable, disable, read-only, and no-recursion work as described.

---

### Codex (codex)

**Dispatch Tool:** Custom agent configuration

**How Enabled:**
- Codex supports subagents via custom agent configuration in `config.toml`
- Enabled via `--agent <name>` where the agent profile includes subagents configuration
- Reference: developers.openai.com/codex/subagents

**How Removed from Child:**
- Would require custom agent config without subagents for child
- **NOT PROVEN** — No probe confirms child agent boundary removes subagent capability

**Child-Specific Read-Only Enforcement:**
- **Via Sandbox Config** — Codex supports sandbox configuration that can enforce read-only access
- Would require child-specific sandbox configuration
- **NOT PROVEN** — No probe confirms per-child read-only works

**MCP Tools Denied Per-Child:**
- **Via config.toml** — Codex's MCP configuration in `config.toml` could theoretically deny specific servers per-child
- **NOT PROVEN** — No probe confirms per-child MCP denial works

**Subagent Events Expose Provenance:**
- **NOT PROVEN** — No evidence that subagent events include child provenance metadata

**Headless Mode Honors Controls:**
- **LIKELY** — Codex's headless `codex exec` mode respects agent configuration
- **NOT PROVEN** — No live probe confirms custom agent boundaries work in headless mode

**Verdict:** **UNPROVEN** — Requires live probes to confirm enable, disable, read-only, and no-recursion work as described.

---

### Cursor (cursor)

**Dispatch Tool:** **NONE PROVEN**

**Status:** **UNSUPPORTED**

**Reason:**
- No native subagent dispatch tool has been identified for Cursor
- The `ralph_run_plan_subagents_require_runtime_capability` function blocks Cursor from subagent delegation
- Code path: `bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh:160-161`

**Requirements for Support:**
1. Identify Cursor's native dispatch tool (if any exists)
2. Prove recursion removal mechanism
3. Prove read-only enforcement for child agents
4. Prove MCP tools can be denied per-child
5. Confirm headless mode honors all controls

**Verdict:** **UNSUPPORTED** until probes prove both recursion removal and read-only enforcement.

---

### Antigravity (antigravity)

**Dispatch Tool:** **NONE PROVEN**

**Status:** **UNSUPPORTED**

**Reason:**
- No native subagent dispatch tool has been identified for Antigravity
- The `ralph_run_plan_subagents_require_runtime_capability` function blocks Antigravity from subagent delegation
- Code path: `bundle/.ralph/bash-lib/run-plan/run-plan-invoke-antigravity.sh:143-144`

**Requirements for Support:**
1. Identify Antigravity's native dispatch tool (if any exists)
2. Prove recursion removal mechanism
3. Prove read-only enforcement for child agents
4. Prove MCP tools can be denied per-child
5. Confirm headless mode honors all controls

**Verdict:** **UNSUPPORTED** until probes prove both recursion removal and read-only enforcement.

---

## Enforcement in Ralph

### Capability Check Function

The `ralph_run_plan_subagents_require_runtime_capability` function in `bundle/.ralph/bash-lib/run-plan/run-plan-invoke-common.sh:34-41` enforces the capability matrix:

```bash
ralph_run_plan_subagents_require_runtime_capability() {
  local runtime="$1"
  local mode
  mode="$(ralph_run_plan_subagents_mode)" || return 1
  [[ "$mode" == "inherit" || "$mode" == "off" || "$runtime" == "claude" ]] && return 0
  echo "Error: subagents=$mode is unsupported for runtime $runtime until its native delegation capability is proven; refusing to expose ambient delegation." >&2
  return 1
}
```

**Behavior:**
- `inherit` mode is always allowed (preserves ambient behavior)
- `off` is always allowed: Ralph does not add a native dispatch surface, and
  runtimes with a proven deny control also receive that control
- `claude` runtime is allowed for `on` (proven capability)
- All other runtimes with `subagents=on` fail closed

### Consensus Voter Restrictions

Voters in consensus nodes are forced to `subagents=off` to ensure clean provenance:

- Code path: `bundle/.ralph/bash-lib/plan-todo.sh:2093-2110`
- Rationale: Subagent delegation makes recorded runtime/agent/model provenance inaccurate
- A voter that delegates to subagents makes its recorded model false

### Allowed Values

```python
ALLOWED_SUBAGENTS = {"inherit", "on", "off"}
```

- `inherit`: Preserves ambient runtime behavior byte-for-byte (default)
- `on`: Requests runtime-native dispatch surface (Claude only, subject to capability matrix)
- `off`: Removes dispatch surface even when ambient config or agent profile would add it

---

## Probe Requirements

To move a runtime from **UNPROVEN** or **UNSUPPORTED** to **PROVEN**, the following probes must pass:

### 1. Enable Probe
- Verify dispatch tool is added when `subagents=on`
- Confirm child agent can be spawned
- Log: "enable probe passed for <runtime>"

### 2. Disable Probe
- Verify dispatch tool is removed when `subagents=off`
- Confirm child agent spawn fails or is blocked
- Log: "disable probe passed for <runtime>"

### 3. Read-Only Probe
- Spawn child agent with read-only restriction
- Attempt write operation; must fail
- Log: "read-only probe passed for <runtime>"

### 4. No-Recursion Probe
- Spawn child agent with subagents disabled
- Child attempts to spawn grandchild; must fail
- Log: "no-recursion probe passed for <runtime>"

### 5. MCP Denial Probe (Optional)
- Configure parent with MCP server
- Deny MCP server to child
- Child attempts MCP call; must fail
- Log: "mcp-denial probe passed for <runtime>"

### 6. Provenance Probe (Optional)
- Spawn child agent
- Verify event stream includes child provenance metadata
- Log: "provenance probe passed for <runtime>"

### 7. Headless Probe
- Run all above probes in headless mode
- Confirm controls are honored
- Log: "headless probe passed for <runtime>"

---

## Fail-Closed Behavior

The capability matrix is deliberately **fail-closed**:

1. **Unknown Version:** If runtime version cannot be determined, subagents are blocked
2. **Unavailable Control:** If any required control (enable, disable, read-only) is unavailable, subagents are blocked
3. **Unproven Runtime:** All runtimes except Claude are blocked until probes pass

This ensures that subagent delegation never exposes capabilities that cannot be safely bounded.

---

## Graph Execution Model (v2)

Graph mode has two distinct kinds of delegation. Do not substitute one for the
other just because both create another model context.

| Mechanism | Use it when | Durable Ralph record | Mutation and verification authority |
|-----------|-------------|----------------------|-------------------------------------|
| Ordinary loop | A task is sequential, local to one plan, and does not need independent scheduling. | The plan checkbox and normal run logs. | The plan agent owns the task and its verification. |
| Graph node | Work must be resumable, attributable, independently scheduled, handed to another runtime, or isolated from sibling changes. | Node ledger state, attempt records, artifact handoff, and a frozen graph. | The node owns its plan; scheduler controls admission and successors. |
| Native subagent | A parent needs inexpensive, throwaway, read-only research or review and can redo it after a parent retry. | Best-effort native-event evidence only; it is nested under its parent, not a graph node. | The parent alone writes, verifies, and completes. |
| Brokered child | A graph node needs a bounded child task with a durable child ledger, a child plan, a result artifact, and a separately observable terminal state. | Request, status, attempts, provenance, result contract, and queue state under the parent's ledger. | The child can complete only its child plan; the parent still must adopt verified evidence before its own completion. |
| Consensus voter | An independent evaluation is needed across declared runtime, agent, and model samples. | Synthetic voter node and verdict artifact. | Delegation is forced off so one voter remains one attributable measurement. |
| Gate | A deterministic project check must decide whether work advances. | Model-free gate result and outcome in the ledger. | Scheduler runs only a frozen, named verification profile. |
| Repair epoch | A gate reports `changes-required` and the frozen ownership map can route findings to bounded repair lanes. | Conditional repair nodes, diagnosis, reintegration, and epoch outcome. | Only the declared repair owner may widen work within its write scope; the live graph is never changed. |

### Native subagents are deliberately read-only

`native.mode: read-only` is not a shortcut for parallel implementation. It is
currently proved only for Claude and only for the bounded roles `research`,
`code-review`, `log-analysis`, and `explorer`. Ralph generates a child overlay
with `Read`, `Grep`, and `Glob`; it does not give the child edit, shell,
delegation, TODO-completion, output-artifact, or authoritative-verification
authority. The parent must synthesize findings, perform all writes, and run the
required checks itself.

Consequently, write-heavy native subagents are disabled rather than merely
discouraged. Per-child write restrictions, per-child MCP denial, and native
event provenance are not a sufficient portable control boundary. Use separate
graph nodes with disjoint write scopes, or a brokered child with an isolated
workspace and result contract, for work that changes files. Native child events
are observational and best-effort; they never become a peer node in the frozen
DAG or proof of success.

### Recursion and child completion

Delegation depth is hard-capped at one. Ralph applies the cap redundantly:

1. Compilation freezes a policy whose effective `maxDepth` cannot exceed one.
2. Child environments set `RALPH_STAGE_SUBAGENTS=off`, disable cross-runtime
   delegation, and use the `native-subagent` or `delegated-child` MCP scope.
3. Those child scopes hide spawn and top-level-run tools as a usability guard.
4. Every MCP handler rechecks scope, graph identity, attempt identity, frozen
   policy, and depth; catalog hiding alone is not trusted.
5. The ledger rejects a depth greater than one even if a caller bypasses a
   handler. Denials are recorded in `no-recursion.log` without prompt content
   or secret values.

A broker request accepts only bounded task, idempotency key, runtime, agent,
workspace mode, per-child access (`read-only` or `changeset`), named
verification profile, and result kind. A stage whose frozen cross-runtime mode
is `changeset` may issue either access level; a read-only stage cannot elevate
a child to changeset access. It does not accept caller
chosen workspace, plan, graph, artifact, or environment paths. Those values are
derived from scheduler context and frozen policy. Its child plan states the
result artifact and disallows further delegation. A child succeeds only after
its plan completes, its required result artifact exists and is non-empty, and
its verification passes. A parent with a queued, failed, cancelled, or
unverified child is not allowed to claim normal completion; failure evidence is
returned for the parent to act on or retry within the bounded policy.

### Workspace and Git boundaries

Every graph run freezes a source base before dispatch. The selected workspace
mode is recorded in the node ledger and is not an instruction a model can
replace mid-run.

| Mode | What the agent sees | Recommended use | Constraints |
|------|---------------------|-----------------|-------------|
| `shared` | The caller's agent workspace. | Read-only work or deliberately serialized mutation. | No isolation. Parallel mutation needs `parallelMutation: allow` and `acknowledgeSharedMutationRisk: true`; otherwise compilation rejects it. |
| `snapshot` | A copied, non-Git workspace from the frozen base. | Default for independent lanes. | Snapshot copying excludes undeclared secrets and rejects unsafe inclusions. A scoped backend-neutral changeset is captured for integration. |
| `worktree` | A detached Git worktree at the frozen base. | An explicit efficiency option when Git-backed isolation is required. | Requires a proved runtime sandbox boundary. Ralph journals worktree operations and checks registration/ownership before reuse or cleanup. |

`writeScopes` are project-relative policy boundaries used to validate a node's
changeset. Unordered overlapping scopes are compile errors unless one explicit
downstream integration or repair owner is declared. Do not grant a lane a Ralph
control path, Git metadata path, or another lane's scope.

`agentGitAccess` describes agent access, not supervisor authority. Keep it
`off` for worktree lanes (the compiler supplies that default); `on` is admitted
only with a proved runtime sandbox boundary. Ralph's supervisor retains the
separate, auditable privilege to freeze the base, create/remove detached
worktrees, capture and validate changesets, integrate predecessor changesets,
and publish. An agent cannot use `agentGitAccess` to turn its workspace into a
new source of truth or to bypass scope validation.

### Integration, gates, repair, and publishing

Mutating isolated lanes emit backend-neutral scoped changesets. The
scheduler-owned integration node applies predecessor changesets without asking
a model to merge arbitrary workspaces. A gate then runs only the named,
operator-authored verification profile: ordered allowlisted commands, declared
timeouts, resource classes, and required artifacts. A `passed` result unlocks
success; `changes-required` follows only an explicit frozen repair edge, and a
missing edge fails closed. Repair epochs are bounded and route findings to the
declared ownership lane before reintegration and rerunning the gate.

This is intentionally stronger than an agent's completion text. A TODO cannot
advance solely from a completion footer, a native child response, or a
plausible-looking artifact. The ordinary loop keeps the TODO open/retries it
until its verification contract passes. At graph level, required artifacts,
scope-valid changesets, child terminal states, gate results, and downstream
edge conditions must all be satisfied. This makes verification feedback work
for the agent rather than an escape hatch for premature success.

Publication defaults to `manual`: Ralph retains the verified integration
workspace, changeset manifest/bundle, and handoff for an operator to apply.
`on-verified` is opt-in and publishes only after the run and all nodes and
delegations succeeded, the integration manifest/result identity is present,
there is no conflict artifact, and the caller workspace still matches the
frozen base. Any gate failure, pending acknowledgement, child failure,
integration conflict, or caller drift refuses publication, preserves caller
changes, and writes recovery instructions. A completed publish is identity
checked so a later caller drift is refused rather than overwritten.

## Threat Model and Defenses

The plan content, prompts, model outputs, child results, artifact text, and
native tool events are untrusted input. The scheduler, frozen graph/policy,
ledger, and operator-authored configuration are the authority boundaries. No
single prompt instruction or catalog filter is treated as a complete defense.

| Threat | Control and remaining boundary |
|--------|--------------------------------|
| Forged MCP request or caller identity | Handlers derive graph context from scheduler environment and revalidate scope, namespace, run/node/attempt identity, policy, delegation-id format, and ledger ownership on every request. The broker never trusts a caller-supplied workspace or plan path. |
| Prompt injection in a delegation argument | Tasks are length-bounded, structured request fields are allowlisted, profiles and policy choices must already be frozen, and commands/paths/environment overrides are not accepted. Treat task and result text as data, never as supervisor instructions. |
| Tool-surface inheritance | Child scopes remove spawn and top-level-run tools; native children get a read-only overlay. These are backed by handler and depth checks because a hidden tool catalog is not itself an authorization boundary. |
| Cross-workspace writes | Workspace path, mode, source base, ownership metadata, and write scopes are supervisor-derived. Isolated paths must be real owned directories, and changeset capture rejects out-of-scope and unsafe symlink edits. |
| Git metadata or path attacks | Graph stages cannot make Ralph/Git control paths writable. Worktrees are detached, registered, journaled, and ownership-checked; snapshot/workspace cleanup refuses unsafe symlinks and never performs broad caller cleanup. |
| Malicious changeset content | Changesets have deterministic content identity and scoped capture validation. Scheduler-owned integration consumes declared predecessor changesets, records conflicts, and publication requires a verified integration identity instead of trusting arbitrary child files. |
| Snapshot secret copying | Snapshot/worktree setup applies frozen secret exclusions, rejects undeclared nested secret inclusion and symlinks, and permits ignored content only through exact operator-approved configuration. Review setup profiles before freezing a run. |
| Process escape or child cancellation blast radius | Delegated children run with a fresh session and restricted environment. Process records are per child; cancellation signals the child process group, not the parent node. Supervisor cleanup is journaled and operates only on exact owned paths. |
| Denial of service through fan-out | Frozen max depth one, bounded broker requests, idempotency keys, queue/broker capacity, global and per-runtime admission caps, native-subagent slot reservation, and bounded gate resource classes limit concurrency. Do not encode unbounded work in a child task. |
| Usage explosion | Usage is recorded per invocation/child attempt and aggregate views avoid adding parent cumulative snapshots or child attempts twice. Admission and dashboard reduction reasons expose runtime-overlay, native-reservation, broker-capacity, token, and verification-resource constraints. Operators should set budgets and investigate unexpected retry/fan-out. |
| Stale-result adoption or replay | Delegation records bind the result to run, parent node, parent attempt, request fingerprint, and idempotency key. Resume compares the frozen graph hash, invalidates affected work only with explicit graph-change acceptance, and publish rechecks result and caller identities before acting. |

When a new runtime, tool, workspace backend, or publication behavior is added,
add an adversarial fixture for its authority boundary before treating it as
proven. In particular, do not relax the native-subagent allowlist or the
depth-one cap based only on documentation or an ambient runtime configuration.

---


## Testing the Capability Check

### Automated Verification Script

Run the capability matrix verification script:

```bash
# Run verification with human-readable output
bundle/.ralph/scripts/delegation-capabilities.sh

# Output capability matrix as JSON
bundle/.ralph/scripts/delegation-capabilities.sh --json

# Run with strict mode (fails if UNPROVEN runtime lacks probes)
bundle/.ralph/scripts/delegation-capabilities.sh --strict

# Run probes for a specific runtime
bundle/.ralph/scripts/delegation-capabilities.sh --probe claude
```

The script logs to `.ralph-workspace/logs/delegation-capabilities.log` and exits with:
- `0` - All supported runtimes have passing probes
- `1` - A supported runtime lacks a required passing probe
- `2` - Invalid arguments or missing dependencies

### Manual Testing

To verify fail-closed behavior manually:

```bash
# Test 1: Claude with subagents=on should pass
RALPH_PLAN_SUBAGENTS=on ralph_run_plan_subagents_require_runtime_capability claude
# Expected: exit 0

# Test 2: OpenCode with subagents=on should fail
RALPH_PLAN_SUBAGENTS=on ralph_run_plan_subagents_require_runtime_capability opencode
# Expected: exit 1, error message

# Test 3: Any runtime with subagents=inherit should pass
RALPH_PLAN_SUBAGENTS=inherit ralph_run_plan_subagents_require_runtime_capability cursor
# Expected: exit 0

# Test 4: Unknown runtime with subagents=on should fail
RALPH_PLAN_SUBAGENTS=on ralph_run_plan_subagents_require_runtime_capability unknown
# Expected: exit 1, error message
```

---

## References

- Claude Agent tool: Anthropic Claude CLI documentation
- OpenCode task tool: https://opencode.ai/docs/cli
- Codex subagents: https://developers.openai.com/codex/subagents
- Ralph subagents implementation: `bundle/.ralph/bash-lib/plan-todo.sh`
- Ralph invoke common: `bundle/.ralph/bash-lib/run-plan/run-plan-invoke-common.sh`
