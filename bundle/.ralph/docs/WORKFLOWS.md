# Workflows

Ralph coordinates AI coding assistants around two durable units: a **leaf plan**
(one TODO loop with verification) and a **reusable workflow** (a series of plan
runs plus supervisor control). This page covers the operating model and how to
author or start workflows. For status versus watch, the live terminal viewer,
resume, reset, recover, and human-action journeys, see the operation sections
that follow in this guide and [AGENT-WORKFLOW.md](AGENT-WORKFLOW.md).

## Core operating model

Give a reusable workflow either:

1. a **task** (`--task "..."`), or
2. an **already refined Ralph plan** (`--plan <path>`).

**Task-based SDLCs** investigate the repository, generate a granular leaf plan,
then execute that plan TODO by TODO. **Plan-delivery** skips research and
planning: it starts execution immediately from the plan you supply.

Inside every plan-backed stage, `run-plan` works **one TODO at a time** with
durable verification. When a TODO declares `verification:` (agent-run checks) or
`verify:` / plan-level `verify:` (runner-executed commands), completion requires
that evidence—not a model claim. After implementation and review, **independent
QA** generates and runs its own plan against the integrated tree.

| Concept | Meaning |
|---------|---------|
| **Leaf plan** | One concrete classic or YAML checklist. Run with `ralph run --plan <path>`. Not a workflow definition. |
| **Reusable workflow** | Durable SDLC shape (`kind: workflow`). Stores investigation, planning, execution, review, and verification policy—never a task-specific implementation checklist. |
| **Generated / supplied source** | Immutable plan bytes for a run (planner output or operator `--plan`). Never rewritten by checkbox progress. |
| **Control plan** | Mutable checkbox copy derived from that source. Resume continues the same control copy. |
| **Autonomous cycle** | Workflow with no `type: approval` nodes; runs to completion when stages succeed. |
| **Human-verified cycle** | Workflow that pauses at approval nodes for explicit operator decisions before continuing. |

### Two copyable starts

Supplied-plan delivery (already refined plan):

```bash
ralph workflow start plan-delivery --plan path/to/leaf.plan.md
```

Task-based delivery (investigate, generate plan, execute):

```bash
ralph workflow start feature-delivery --task "Add CSV export for invoices"
```

Non-interactive starts require `--yes`. Both forms accept `--runtime`, `--model`,
`--workspace`, `--workspace-root`, and `--agent-workspace` when you need explicit
routing or roots.

### How scale works

The same workflow shape covers a one-line bugfix and a multi-week feature:

| Scale | What changes | What stays fixed |
|-------|--------------|------------------|
| Atomic bug | Short `--task`, small planner `maxTodos`, few TODOs in the generated plan | Stage topology, review/rework bound, integrate, independent QA |
| Medium change | Richer investigation artifact, more TODOs, still one `planFrom` consumer | Fresh-session TODO loop, immutable source + control copy |
| Massive feature | Larger planner budget (up to 200), longer overnight runs, resume/reset as needed | Workflow definition never stores the task checklist; each run freezes its own sources |

`ralph run --plan` remains the right tool for a single leaf plan you already
trust. Workflows coordinate **multiple** attributable plan runs (implement,
review rework, QA) under one outer run ID.

## Sequential vs Dependency

Create with exactly two commands:

```bash
ralph create plan                 # leaf plan
ralph create workflow             # reusable workflow (--mode sequential|dependency)
```

When `--mode` is omitted, `ralph create workflow` asks interactively.

| Need | Choose |
|------|--------|
| Ordered stages with artifact handoffs; linear or declared parallel waves | **Sequential** (`--mode sequential`) |
| DAG dependencies (`dependsOn`), isolated workspaces, consensus, compile-time rework loops, supervisor integrate/publish | **Dependency** (`--mode dependency`) |
| One TODO loop in a working tree, no multi-stage SDLC | Leaf plan via `ralph create plan` / `ralph run --plan` |

| Public `mode` | Internal implementation |
|---------------|-------------------------|
| `sequential` | Classic orchestration (`orchestrator.sh` and pipeline plans). Existing orchestration formats remain supported as the Sequential implementation. |
| `dependency` | Graph scheduler and durable ledger. |

Authored workflow frontmatter uses `kind: workflow` and `mode: sequential|dependency`.
A legacy `engine:` field is accepted only by the loader (maps to public mode with
a warning); new serializers emit `mode` only. Do not set both `mode` and a
legacy engine field. Materialized internal plans may still carry internal
execution markers for Sequential or Dependency.

Bundled SDLCs ship as `mode: dependency`. Classic orchestration is not a
separate public product surface—it is the Sequential implementation behind
`ralph create workflow --mode sequential` and Sequential workflow runs.

## Bundled SDLC stage shapes

Ten workflows are directly runnable (project, global, or bundled resolution).
Choose by intent:

| Workflow ID | When to choose | Stage shape (authored) |
|-------------|----------------|------------------------|
| `bug-fix` | Reproduce, smallest defensible fix, review, integrate, regression QA | `investigate` → `plan-implementation` → `implement` → `review` → `integrate` → `plan-qa` → `qa` → `qa-gate` |
| `feature-delivery` | Requirements investigation, full implementation plan, review, integrate, acceptance QA | Same topology as bug-fix; larger planner budgets and feature-oriented artifacts |
| `refactor` | Characterize invariants, migration/rollback plan, parity QA | `characterize` → `plan-implementation` → `implement` → `review` → `integrate` → `plan-qa` → `qa` → `qa-gate` |
| `investigation` | Read-only research; emit a recommended leaf plan **without** executing it | `investigate` → `recommend-plan` (zero `planFrom` consumers) |
| `release-gate` | Read-only candidate verification, security review, release verdict | `inspect-candidate` → `plan-verification` → `verify`; parallel `security`; `release-decision` → `release-gate-decision` |
| `plan-delivery` | You already have a refined Ralph plan; execute immediately under review + independent QA | `implement` (supplied plan) → `review` → `integrate` → `plan-qa` → `qa` → `qa-gate` |
| `human-verified-delivery` | Full delivery with mandatory human plan approval and result approval | Feature-delivery shape plus `approve-plan` and `approve-result` |
| `triage` | An unshaped request: classify it, study it to the depth it needs, and recommend which workflow should execute it | `classify` (router) → `scope-request` **or** `deep-investigation` → `recommend` |
| `assessment` | Read-only assessment of existing work along four axes at once | `inspect` → parallel `assess-correctness`, `assess-security`, `assess-performance`, `assess-compatibility` → `synthesize` → `assessment-gate` |
| `review-jury` | Read-only review where one reviewer's judgement is not enough | `prepare-review` → `jury` (3 cross-provider voters) → `jury-decision` → `report` → `review-gate` |

Compiler-derived join nodes such as `review-approved` are not authored stages.
Workflows without approval nodes are **autonomous**;
`human-verified-delivery` is the shipped **human-verified** shape.

### Concurrency

Every delivery workflow pins `maxParallel: 1`: its stages form a chain, so there
is nothing to overlap. Concurrency in the bundled catalog is **read-only** by
construction. `assessment` runs four assessors at once and `review-jury` runs
three jurors at once, and none of them declare `writeScopes`, so they cannot
conflict.

Parallel *mutation* is deliberately absent from the bundled catalog. Two
unordered stages that both write are rejected at compile time unless their
`writeScopes` are disjoint, and an `integrate` node does not merge: overlapping
changesets stop the run with a conflict bundle. Disjoint scopes are a fact about
one repository's layout, which a bundled workflow cannot know. Author parallel
lanes per project from
`bundle/.ralph/plan-templates/graph-parallel-implementation.plan.template.md`,
which is where the static ownership map belongs.

### Cross-provider workflows

`review-jury` pins `runtime:` on each consensus voter and therefore needs the
`claude`, `codex`, and `cursor` runtimes installed. This is the one sanctioned
exception to bundled runtime neutrality: a jury whose members share a runtime is
correlated, so the compiler requires `minRuntimes` distinct providers whenever
`quorum` is used. Every other bundled workflow resolves its runtime at start
time and runs on whichever single runtime you have.

### Verdict gates

Every delivery workflow ends in a model-free `type: gate` node. The `qa` stage
writes `qa-verdict.json` (the evaluator schema) alongside its prose handoff, and
`qa-gate` runs `evaluator_contract.py require-approved` against it: an
independent QA failure now makes the run non-zero. `release-gate` gates its own
`release-verdict.json` the same way through `release-gate-decision`. In
`human-verified-delivery` the human `approve-result` hold depends on `qa-gate`,
so a person is only asked to accept a result the automated verdict already
passed.

Gate step commands resolve `{{ARTIFACT_NS}}` and `{{STAGE_ID}}`, so a
verificationProfile can name a run-scoped artifact path.

One residual to be aware of: `integrate` still publishes on `review-approved`,
so `qa` runs against the integrated tree and the gate fails the run *after*
publication rather than preventing it. Running QA pre-publish requires a
downstream node to execute inside an upstream node's candidate snapshot, which
is not an authoring surface today.

List what is available:

```bash
ralph workflow list
ralph workflow show feature-delivery
ralph workflow path bug-fix --bundled
```

## Resolution and editing

Workflow IDs match `^[a-z0-9]+(-[a-z0-9]+)*$`. Lookup order:

1. `<state-root>/workflows/<id>.workflow.md` (**project**)
2. `${RALPH_HOME:-$HOME/.ralph}/workflows/<id>.workflow.md` (**global**)
3. Bundle install path `.../.ralph/workflows/<id>.workflow.md` (**bundled**)

`RALPH_DISABLE_GLOBAL_FALLBACK=1` skips global implicit lookup. Explicit
`--project`, `--global`, or `--bundled` never falls through.

| Verb | Behavior |
|------|----------|
| `list` | Sorted rows: `<id>`, source kind, overview |
| `show` | Byte-exact file contents |
| `path` | Absolute path of the winning (or scoped) file |
| `edit` | Edit project or global; if only bundled wins, creates a project shadow. Validates before and after; uses `$VISUAL` then `$EDITOR` then `vi`. Bundle assets stay immutable. |

Project and global workflows are user data (installer manifests never own them).
Bundled workflows are installer-owned.

## Authoring schema

### Frontmatter and defaults

```yaml
---
name: my-delivery
overview: Short description of the SDLC shape.
kind: workflow
mode: dependency          # or sequential
defaults:
  runtime: cursor         # optional; only runtime and model allowed
  # model: ...            # only with paired runtime
planInput:                # optional; see planInput below
  stage: implement
  required: false
pipeline:
  stages:
    - id: investigate
      instructions: |
        Investigate {{TASK}} and write the required artifact.
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md
          required: true
---
```

- `defaults:` may contain only `runtime` and `model`.
- Supervisor nodes (`integrate`, `join`, `gate`, `checkpoint`, `router`,
  `approval`) accept no runtime, model, instructions, TODOs, or mutation scopes.
- Ordinary executable stages may carry inline `instructions:` (non-empty text
  only—no lists, maps, path includes, or empty values). Instructions are injected
  into that stage's prompt as a delimited `WORKFLOW_STAGE_INSTRUCTIONS` block.

### Tokens

| Token | Meaning |
|-------|---------|
| `{{TASK}}` | Concrete request for this run (explicit `--task`, else plan overview / filename provenance) |
| `{{INPUT_PLAN}}` | Frozen supplied source path; valid only when the workflow declares `planInput` |
| `{{ARTIFACT_NS}}` | Artifact namespace for the run |
| `{{STAGE_ID}}` | Current stage id (for example review verdict paths) |

Task text is never written back into project, global, or bundled workflow files.

## Planner, planFrom, planInput, and `{{INPUT_PLAN}}`

### Planner stages

A stage with `planner: {outputMode: plan-file, maxTodos: N}` produces one JSON
artifact matching the planner-output schema (`maxTodos` default 100, hard max
200). The supervisor renders that JSON into an immutable YAML-frontmatter Ralph
plan plus a manifest under the run registry. Quality target: fewest independently
verifiable TODOs that fully cover the work—no padding.

### planFrom consumers

An ordinary agent stage declares `planFrom: <planner-stage-id>` to execute the
plan that planner produced. Rules:

- `planFrom` and `planFile` are mutually exclusive.
- A planner has zero consumers (recommended plan only) or exactly one direct
  consumer.
- Supervisors and other non-ordinary stages cannot declare `planFrom` /
  `planFile`.
- Resolution uses the latest succeeded planner attempt's manifest, verifies the
  source hash, then creates a durable **control** copy for checkbox state.
- Resume continues the same control copy. Review rework clones a fresh control
  copy of the same immutable source.

### planInput (supplied plans)

```yaml
planInput:
  stage: implement    # ordinary plan-backed stage; no authored TODOs
  required: true      # reject task-only start when true
```

| Rule | Behavior |
|------|----------|
| Required plan-input | Rejects task-only start; consumer may omit `planFrom` |
| Optional plan-input | Keeps a valid `planFrom` task path when `--plan` is absent |
| No `planInput` | Rejects `--plan` |
| Allowed plan roots | Project root, state root, `$HOME/.cursor/plans`, `$HOME/.claude/plans` |
| Plan shape | Classic or YAML leaf plan with at least one pending TODO—not a workflow |

Start forms:

```bash
ralph workflow start plan-delivery --plan path/to/leaf.plan.md
ralph workflow start --file path/to/workflow.workflow.md --plan path/to/leaf.plan.md
```

On start, Ralph byte-copies the plan to an immutable
`<registry-run>/plans/input/source.plan.md` and writes `manifest.json`. Changing
the original file later does not alter a frozen run; a new plan requires a new
workflow run. `{{INPUT_PLAN}}` resolves to that frozen source.

### Source versus control

| Copy | Mutable? | Purpose |
|------|----------|---------|
| Immutable source (`generated` or `provided`) | No | Binding for review, QA, reset, and audit hashes |
| Control plan | Yes (checkboxes only) | Live TODO progress for `run-plan` |
| Original operator path (provided) | Untouched | Provenance; never receives routing edits from Ralph |

Plan-backed status surfaces `planSourceKind`, immutable and control paths,
`completedTodos` / `totalTodos`, and optional `currentTodoId` so overnight stop
and resume remain attributable.

## Runtime and model precedence

Supported runtimes (canonical order): `cursor`, `claude`, `codex`, `opencode`,
`antigravity`.

**Workflow plan-run runtime:** TODO → stage → invocation → workflow default →
`RALPH_PLAN_RUNTIME` → interactive selection.

**Workflow plan-run model:** TODO → stage → invocation → workflow default →
saved model for effective runtime → runtime-native default.

**Supplied-plan routing:** TODO → workflow stage → invocation → **supplied-plan
header** → workflow default → saved model for effective runtime →
runtime-native default.

Stage or invocation may override supplied-plan defaults for this run only.
Overrides apply to the control copy or invocation context—never to the original
or frozen source. Model-only stage/TODO entries inherit that entry's effective
runtime; runtime-only entries select that runtime's saved or native model.

Interactive start prompts for unresolved stages: select a runtime (required),
then optionally choose a model or accept the runtime default. Non-interactive
unresolved runtime fails with `--runtime` guidance. Consensus voters keep
explicit runtimes; supervisors take none.

Standalone (non-workflow) leaf plans use TODO → CLI → plan header → environment
/ saved / native defaults.

## Approval nodes and `changesTarget`

Authored supervisor nodes with `type: approval` pause for an operator decision:

```yaml
- id: approve-plan
  type: approval
  dependsOn: [plan-implementation]
  changesTarget: plan-implementation
  question: Approve this implementation plan and acceptance scope?
```

| Field | Rule |
|-------|------|
| `question` | Required non-empty text |
| `changesTarget` | One upstream executable or planner stage; must be an ancestor whose reset closure reaches the approval |
| Forbidden | runtime, model, instructions, TODOs, `planFile`, `planFrom`, planner, workspace mutation, Git |

At activation the supervisor freezes evidence (artifacts, plan source/control
progress, verdicts, changesets) into the action request. Decisions:

| Decision | Effect |
|----------|--------|
| `approve` | Gate succeeds on resume |
| `request-changes` | Requires `--message`; run blocked; next action resets `--stage <changesTarget>` |
| `cancel` | Cancels the run |

Workflows without approval nodes remain autonomous. Respond with
`ralph workflow actions respond <run-id> <request-id> --decision approve|request-changes|cancel`
(details in the operation sections of this guide).

## Operator input protocol

Every ordinary workflow stage—including every generated-plan TODO—must follow:

- Continue through ordinary implementation choices supported by repository
  evidence (**autonomous** path).
- When blocked on a missing product decision, unavailable credential
  *configuration*, external fact, or mutually exclusive requirement, call:

  ```bash
  ralph workflow actions request --question "..." [--details "..."]
  ```

  Then stop without completing the TODO. Do not guess.
- Ask the operator to configure a named environment or native secret source and
  reply when ready—never request a secret value in the question or message.
- At most one outstanding `input` request per attempt. Input never grants
  permission and never mutates the plan.

Outstanding input leaves the TODO unchecked, marks the stage/run non-retryable
`waiting`, and exits 3. After
`ralph workflow actions respond ... --decision answer --message "..."`, resume
injects the answer into the same TODO's next fresh invocation exactly once.

## Inspect before start

```bash
ralph workflow inspect --file path/to/workflow.workflow.md
ralph workflow inspect feature-delivery
```

`inspect` validates and previews the workflow without starting a run. Start
always shows a pre-execution summary and requires confirmation unless `--yes` is
set. `ralph run --plan` rejects workflow-shaped inputs and prints the workflow
start replacement.

## Operation command map

Public verbs (both Sequential and Dependency):

| Verb | Purpose |
|------|---------|
| `list` / `show` / `path` / `edit` | Choose and edit a workflow definition |
| `inspect` | Validate/preview without starting |
| `start` | Materialize a run; prints exact run ID |
| `runs` | List outer runs (default 20 newest; `--all`, `--state`, `--workflow`, `--json`, `--tsv`) |
| `status` / `watch` | Read-only static report vs live viewer (`watch` accepts `--plain`) |
| `logs` | Stage/attempt/stream logs (`agent\|supervisor\|combined`, optional `--follow`) |
| `actions` | List/respond to human requests; stage-only `request` |
| `resume` / `reset` / `recover` / `cancel` | Lifecycle (exact run ID only; never `latest`) |

Exit codes: `0` success, `1` validation/refusal/runtime failure, `2` unknown/removed usage, `3` successfully persisted wait for human action (not a failure). Detaching the live viewer with Ctrl-C returns `130` without cancelling the workflow.

## Status, watch, and the terminal viewer

`ralph workflow status` and `ralph workflow watch` share the same engine-neutral
read model (`schemaVersion`, `run`, `stages`, `diagnosis`, `nextAction`). Dependency
stages also expose their frozen incoming `dependencies` with optional branch
conditions and task-salvage provenance (`workspaceMode`, `workspacePath`,
`workspaceAvailable`, `baseRevision`, `changesetManifest`, and `changedFiles`).
Viewers can therefore explain topology and locate unfinished code without
reading engine state. They
never mutate registry or engine state, never accept `latest`, and never take
internal engine selectors.

| Command | Role |
|---------|------|
| `ralph workflow status <exact-run-id>` | Finite, static, outcome-first report. Optional `--json` for scripts. |
| `ralph workflow watch <exact-run-id>` | Canonical live viewer for Sequential and Dependency runs. |
| `ralph workflow handoff <exact-run-id>` | Standalone task, failure, code-location, review-feedback, and retry report for another operator or agent. Optional `--json` emits its public status input. |
| `ralph usage --run <exact-run-id>` | Detailed token, cache, elapsed-time, runtime, model, and per-stage-plan usage for one workflow run. |
| `ralph workflow runs` | Newest-first run list. Suitable TTY: styled table. Redirected stdout or `--tsv`: stable six-column TSV. `--json` unchanged. |

### Status versus watch

- **status** prints one diagnosis and exits. Use it for overnight checks, CI
  capture, and deciding the single safe next action.
- **watch** follows that same public status until the run reaches a terminal
  state (`succeeded` / `failed` / `cancelled`) or a persisted wait (`waiting`),
  or until you detach. On a suitable interactive TTY it uses the curses viewer;
  otherwise it streams deterministic line-oriented text.

```bash
ralph workflow status run-20260827T183012Z-feature-delivery-a1b2c3
ralph workflow status run-20260827T183012Z-feature-delivery-a1b2c3 --json
ralph workflow watch run-20260827T183012Z-feature-delivery-a1b2c3
ralph workflow watch run-20260827T183012Z-feature-delivery-a1b2c3 --plain
ralph workflow handoff run-20260827T183012Z-feature-delivery-a1b2c3
```

`--plain` forces the streaming text path even on a TTY (CI logs, screen readers,
or when you want copy-pasteable frames).

### Automatic attach from `start`

On an interactive TTY, `ralph workflow start` attaches the same viewer used by
`watch` after durable run registration. The supervisor keeps running in an
isolated session; the viewer is read-only attach. Non-TTY starts stay
synchronous and keep the existing exit `0` / `1` / `2` / `3` meanings.

### Detach and reattach

| Input | Effect |
|-------|--------|
| `q` | Detach without cancelling. After durable dispatch, start returns success (`0`) and prints reattach guidance. |
| Ctrl-C | Detach only (viewer exit `130`). Never cancels the workflow. |
| `ralph workflow cancel <exact-run-id>` | The only cancellation path. |

The primary viewer keeps the common inspection commands visible with short
descriptions, including the selected stage and attempt for log commands. They
are also printed on detach:

```bash
ralph workflow status run-20260827T183012Z-feature-delivery-a1b2c3
ralph workflow watch run-20260827T183012Z-feature-delivery-a1b2c3
ralph workflow logs run-20260827T183012Z-feature-delivery-a1b2c3 --stream combined --tail 200 --follow
ralph workflow logs run-20260827T183012Z-feature-delivery-a1b2c3 --stream agent --tail 200 --follow
ralph workflow actions list run-20260827T183012Z-feature-delivery-a1b2c3
ralph workflow status run-20260827T183012Z-feature-delivery-a1b2c3 --json | jq -r '.stages[] | .artifacts[]?'
ralph workflow handoff run-20260827T183012Z-feature-delivery-a1b2c3
ralph usage --run run-20260827T183012Z-feature-delivery-a1b2c3
```

Leaf-plan execution prints its detailed usage summary from the runner's exit
handler on success, failure, persisted waits, and signals. Workflow start,
watch, resume, and cancel paths print the matching run aggregate when control
returns to the terminal. A viewer detach prints a partial aggregate while the
supervisor continues; reattaching through `watch` prints the final aggregate
when the workflow becomes terminal. Usage reporting is best-effort and never
changes the workflow command's original exit status.

### `runs` table, JSON, and TSV

```bash
ralph workflow runs
ralph workflow runs --workflow feature-delivery --state waiting
ralph workflow runs --tsv
ralph workflow runs --json
```

On a suitable TTY, `runs` prints an aligned ID / WORKFLOW / MODE / STATE / AGE /
TASK table. Redirected stdout and explicit `--tsv` keep the stable schema
`<runId><TAB><workflowId><TAB><mode><TAB><entryKind><TAB><state><TAB><createdAt>`.
JSON and TSV never include ANSI escapes. `--json` and `--tsv` are mutually
exclusive.

### Color, plain, and accessibility

Semantic colors match plan pretty output: running cyan, succeeded green,
waiting/attention amber, failed red, queued/downstream-blocked dim. State words,
structure, and focus remain understandable without color. Limited terminals fall
back to ASCII glyphs.

Curses is selected only when stdin and stdout are a suitable TTY and none of
these force plain/streaming output: `--plain`, non-TTY stdout/stdin,
`TERM=dumb`, `CI`, `RALPH_WORKFLOW_NO_COLOR`, `RALPH_GRAPH_PLAIN`,
`RALPH_GRAPH_NO_TUI`, `RALPH_GRAPH_SCREEN_READER`, or
`ACCESSIBILITY_SCREEN_READER`. Screen-reader and plain output use no animation,
cursor control, alternate screen, or required color interpretation.
`NO_COLOR` / `RALPH_WORKFLOW_NO_COLOR` also strip ANSI from static `status` and
`runs` tables. See [ENVIRONMENT.md](ENVIRONMENT.md#workflow-terminal-ui).

### Key bindings

Press `?` in the viewer for the full overlay. Contextual footer keys change with
focus; the common set:

| Key | Action |
|-----|--------|
| up/down or j/k | Select stage |
| PgUp/PgDn | Page selection |
| Home/End (or g/G) | First / last stage |
| `/` | Incremental stage filter (Enter apply, Esc cancel) |
| `d` | Toggle selected-stage detail |
| `l` or `c` | Expand copyable status commands plus live-tail and artifact commands for every stage |
| `r` | Refresh now |
| `?` | Toggle help |
| `q` | Detach (workflow keeps running) |
| Ctrl-C | Detach |

The viewer never streams log content itself. Reading a stage's log cost a
blocking public CLI call on every selection change, which made arrowing
between stages stall. The selected-stage detail carries the exact
`ralph workflow logs ... --follow` command instead, and `l` expands the full
copyable set, so you tail in a second terminal at full speed.

Viewer-driven operator actions (approval/input decisions, resume, reset,
recover) call the public `ralph workflow actions`, `resume`, `reset`, `recover`,
and `logs` routes. They write durable supervisor records under the registry run;
the Python viewer never writes request, decision, ledger, or workflow state
files itself. You can always run the same CLI verbs outside the viewer.

### Responsive layout

| Tier | Typical size | Shows |
|------|--------------|-------|
| Compact | 40x12 | Selected-stage-centered progress tree, inline log/artifact/action command, and contextual keys |
| Standard | 80x24 | Expanded dependency tree and selected detail, including every dependency and stage it unlocks |
| Wide | 120x40 | Adds more tree nodes and detail rows |

The progress tree places stages in prerequisite-first order and marks them
`complete`, `in progress`, `next`, `pending`, `conditional`, or `not needed`.
The selected node is reverse-highlighted and expanded with the most useful
available command and metadata: live logs for active work, artifact paths for
completed work, action commands for waits, and dependency/unlock context.
Compact terminals show a viewport centered around that selection; taller
terminals reveal more nodes automatically.

Dormant compile-time rework reached only through `changes-required` or `error`
is rendered as a conditional branch and excluded from the required remaining
count. If review activates the branch, its stages enter normal progress and the
approval join is placed beneath the repair review that actually ran. The
`Inspect` row explicitly says that Up/Down or `j`/`k` changes the selected stage.
Use `l` for focused live logs, `d` for full dependency/artifact/progress detail,
and `c` for exact log and artifact commands covering every stage. Derived
downstream `blocked` stages stay visually muted; approval/input waits and real
failures get primary attention.

## Task-based journey (copyable)

Example run ID used below:
`run-20260827T183012Z-feature-delivery-a1b2c3`.

```bash
# Choose
ralph workflow list
ralph workflow show feature-delivery
ralph workflow path feature-delivery

# Inspect, then start (non-interactive needs --yes)
ralph workflow inspect feature-delivery
ralph workflow start feature-delivery --task "Add CSV export for invoices" --yes

# Observe
ralph workflow runs
ralph workflow runs --workflow feature-delivery --state waiting
ralph workflow runs --tsv
ralph workflow status run-20260827T183012Z-feature-delivery-a1b2c3
ralph workflow status run-20260827T183012Z-feature-delivery-a1b2c3 --json
ralph workflow watch run-20260827T183012Z-feature-delivery-a1b2c3
ralph workflow watch run-20260827T183012Z-feature-delivery-a1b2c3 --plain
ralph workflow logs run-20260827T183012Z-feature-delivery-a1b2c3 --stage implement --stream combined

# Human actions when status says so
ralph workflow actions list run-20260827T183012Z-feature-delivery-a1b2c3

# Lifecycle (exact ID only)
ralph workflow resume run-20260827T183012Z-feature-delivery-a1b2c3 --yes
ralph workflow reset run-20260827T183012Z-feature-delivery-a1b2c3 --stage plan-implementation --yes
ralph workflow recover run-20260827T183012Z-feature-delivery-a1b2c3 --yes
ralph workflow cancel run-20260827T183012Z-feature-delivery-a1b2c3 --yes
```

Expected start output: outcome summary, workflow/mode/entry kind, then the new
run ID plus `ralph workflow status <run-id>` / `watch` / `logs` guidance and
exactly one safe next action (or `Action: none required` while running). On an
interactive TTY, start attaches the live viewer after durable registration;
`q` or Ctrl-C detaches without cancelling (see
[Status, watch, and the terminal viewer](#status-watch-and-the-terminal-viewer)).

## Supplied-plan journey (copyable)

```bash
ralph workflow list
ralph workflow inspect plan-delivery
ralph workflow start plan-delivery --plan path/to/leaf.plan.md --yes
# -> run-20260827T191500Z-plan-delivery-9f3e21

ralph workflow runs --workflow plan-delivery
ralph workflow status run-20260827T191500Z-plan-delivery-9f3e21
ralph workflow watch run-20260827T191500Z-plan-delivery-9f3e21
ralph workflow logs run-20260827T191500Z-plan-delivery-9f3e21 --stage implement --attempt 1
ralph workflow actions list run-20260827T191500Z-plan-delivery-9f3e21
ralph workflow resume run-20260827T191500Z-plan-delivery-9f3e21 --yes
ralph workflow reset run-20260827T191500Z-plan-delivery-9f3e21 --stage implement --yes
ralph workflow recover run-20260827T191500Z-plan-delivery-9f3e21 --yes
ralph workflow cancel run-20260827T191500Z-plan-delivery-9f3e21 --yes
```

On import Ralph byte-copies the leaf plan to the run's immutable
`plans/input/source.plan.md` and writes `manifest.json`. Editing the original
file afterward does not change this run; a different plan requires a **new**
`ralph workflow start ... --plan ...`.

## Planner artifact to independent QA

Task-based SDLCs separate **planner output** from **execution progress**:

1. Planner stage writes JSON (schema version 2). The supervisor renders an
   immutable source plan under
   `<registry-run>/plans/<planner-stage-id>/attempt-<n>.plan.md` plus
   `manifest.json`.
2. The `planFrom` consumer creates a **mutable control copy** for checkboxes.
3. `run-plan` executes TODOs one at a time in **fresh sessions** (no model-session
   memory). Two TODOs mean two independent invocations against the same control
   plan.
4. Overnight stop leaves `completedTodos` / `totalTodos` / `currentTodoId` on the
   plan-backed stage. Next day:

   ```bash
   ralph workflow status run-20260827T183012Z-feature-delivery-a1b2c3
   # Outcome: waiting (operator-request) — Resumes at: implement todo add-csv-export (3/12)
   ralph workflow resume run-20260827T183012Z-feature-delivery-a1b2c3 --yes
   ```

5. Review reads the immutable source + control progress + changeset; bounded
   rework clones get a **fresh control copy of the same source** plus the prior
   verdict.
6. After integrate, independent QA generates its **own** planner artifact and
   control plan—never reusing the implementation control copy as QA truth.

Operator-supplied plans follow the same control/progress/resume/review/QA rules
with `planSourceKind: provided` and `planSourceStageId: null`.

## Human-verified journey (complete)

Workflow: `human-verified-delivery`. Example run:
`run-20260827T200100Z-human-verified-delivery-c0ffee`.

### 1. Pending plan approval

Start pauses at `approve-plan` with exit 3 (`waiting` / `human-approval`,
`retryable: false`):

```bash
ralph workflow actions list run-20260827T200100Z-human-verified-delivery-c0ffee
ralph workflow actions respond run-20260827T200100Z-human-verified-delivery-c0ffee req-approve-plan-01 \
  --decision approve --yes
ralph workflow resume run-20260827T200100Z-human-verified-delivery-c0ffee --yes
```

Resume completes the approved gate and continues implementation. Do not call
`resume` while the approval is still outstanding—status prints
`ralph workflow actions list <run-id>` as the safe action.

### 2. Agent input question (same TODO)

An implementation TODO asks for a product decision, then stops (TODO unchecked,
exit 3, `waiting` / `operator-input`):

```bash
ralph workflow actions list run-20260827T200100Z-human-verified-delivery-c0ffee
ralph workflow actions respond run-20260827T200100Z-human-verified-delivery-c0ffee req-input-42 \
  --decision answer --message "Ship CSV only; defer PDF to a follow-up." --yes
ralph workflow resume run-20260827T200100Z-human-verified-delivery-c0ffee --yes
```

Resume injects the answer into the **same TODO's** next fresh invocation exactly
once, then continues the same control plan. Agent-side request syntax and answer
rules: [AGENT-WORKFLOW.md](AGENT-WORKFLOW.md#workflow-operator-input).

### 3. Final result approval

After review, integrate, and QA, `approve-result` waits again:

```bash
ralph workflow actions respond run-20260827T200100Z-human-verified-delivery-c0ffee req-approve-result-01 \
  --decision approve --yes
ralph workflow resume run-20260827T200100Z-human-verified-delivery-c0ffee --yes
```

### 4. Request-changes → exact reset → resume

```bash
ralph workflow actions respond run-20260827T200100Z-human-verified-delivery-c0ffee req-approve-result-01 \
  --decision request-changes --message "Cover refund edge cases in the plan." --yes
# Run becomes blocked (human-changes-requested).
# Sole next action (changesTarget is plan-implementation):
ralph workflow reset run-20260827T200100Z-human-verified-delivery-c0ffee --stage plan-implementation --yes
ralph workflow resume run-20260827T200100Z-human-verified-delivery-c0ffee --yes
```

Reset archives affected state, invalidates the approval and transitive
downstream stages/actions, binds the feedback to the target's next fresh
attempt, and prints resume as the sole next action. Approval decisions remain
immutable audit history.

## States and reason codes

| State | Meaning |
|-------|---------|
| `queued` | Accepted; not yet running |
| `running` | Live owner progressing work |
| `waiting` | Paused for operator / clean interruption / answered input ready |
| `blocked` | Cannot progress until reset or dependency repair |
| `stale` | Dead/orphaned owner; recover before resume |
| `failed` | Stage/runtime failure |
| `cancelled` | Operator cancel recorded |
| `succeeded` | Terminal success |

| `reasonCode` | Typical use |
|--------------|-------------|
| `operator-request` | Clean interruption or Dependency permission wait |
| `operator-input` | Outstanding or answered agent input |
| `human-approval` | Outstanding or approved gate |
| `human-changes-requested` | Gate `request-changes`; reset `changesTarget` |
| `unmet-dependency` | Prerequisite not satisfied |
| `failed-prerequisite` | Upstream stage failed |
| `missing-artifact` / `invalid-artifact` | Required evidence missing or bad |
| `loop-exhausted` | Rework/repair budget spent |
| `rework-stalled` | A blocking finding stayed open across rework rounds |
| `cycle` | Logical cycle / deadlock |
| `live-owner` | Another process still owns the run |
| `stale-owner` | Owner dead; `recover` |
| `stage-failed` | Stage failure (includes Sequential parallel-wave sibling failure) |
| `cancelled` / `none` | Cancelled run / no special reason |

Diagnosis shape (`status --json`): `{state,reasonCode,summary,stageId,evidence,retryable,nextAction}`.
Status always leads with outcome/reason and ends with one safe copyable next
action (or none required).

Nonterminal runs with nothing runnable are never left as `running`: clean
interruption or answered input → retryable `waiting`; outstanding approval/input
→ non-retryable `waiting`; changes/dependency/artifact/loop/cycle → `blocked`;
dead owner → `stale`.

## Source, control, and original

| Path | Mutable? | Role |
|------|----------|------|
| Generated source (`plans/<planner>/attempt-n.plan.md`) | No | Binding hash for review/QA/reset |
| Provided source (`plans/input/source.plan.md`) | No | Frozen copy of operator `--plan` |
| Control plan | Yes (checkboxes) | Live TODO progress; resume continues it |
| Original operator path | Untouched | Provenance only; Ralph never writes routing back |

Changing a supplied plan requires a **new workflow run**. Reset never deletes
immutable sources/manifests, logs, attempts, decisions, or definitions.

## Reset, recover, resume

| Command | Does | Does not |
|---------|------|----------|
| `resume <run-id>` | Retry `queued\|failed\|stale` with satisfied prereqs; continue same control plan; complete approved gates; inject answered input once | Rerun `succeeded`; accept `running\|cancelled\|succeeded`; accept unresolved input/approval; accept changes-requested without reset |
| `reset <run-id> [--stage\|--all]` | Archive under `archive/reset-<UTC>-<suffix>/`; invalidate selection + transitive downstream; invalidate outstanding actions; leave blocked-ready | Delete immutable input; select live-running/cancelled/succeeded runs; directly select supervisor/integrate/publish/approval nodes |
| `recover <run-id>` | Clear proven stale/orphaned supervisor via PID, process-start identity, hostname, heartbeat, and lock checks | Treat intentional approval/input wait as stale; manufacture/consume human decisions; accept `latest` |
| `cancel <run-id>` | Signal proven owned live processes; record `cancelled`; cancel outstanding actions without deleting records | Delete audit history or immutable input; accept `latest` |

**Reset planner vs consumer:** resetting a planner schedules a new numbered
attempt/source; downstream `planFrom` consumers wait for the new manifest.
Resetting only a generated or provided consumer reuses the same verified source
with a **fresh control copy**.

When the final unrolled review still requests changes, status reports
`loop-exhausted` instead of exposing the scheduler's internal no-edge error. It
names the final verdict artifact and recommends resetting the last repair stage.
That explicit reset keeps the frozen graph unchanged, creates a fresh control
copy, and carries the final review verdict into the repair stage's next attempt;
run `resume` after the reset.

This reset is a manual additional repair/review cycle, not stale-supervisor
recovery, and it can be repeated if another final review still requests
changes. For any failed run, `status` identifies the best recorded
code-producing stage, its workspace mode and absolute path, whether that path
still exists, whether it is a Git worktree, its frozen base revision, its
durable changeset manifest, and the changed-file count. `ralph workflow handoff
<run-id>` expands those facts into a standalone report with exact retry,
resume, verdict, log, and open-workspace commands. Another Ralph process can
use the same run from the same project and state root. Runtime/model routing
remains frozen; changing it requires a new run. Handoff does not export a run
to another machine or state root.

**`--all`** selects every executable/planner stage and invalidates derived
supervisors/approvals; it still does not replace a supplied immutable plan.

Preview with `--dry-run`. Non-interactive mutation needs `--yes`. With several
blockers and no `--stage`, interactive selection is required (noninteractive exits
1).

## Review rework: the defect ledger

A `changes-required` verdict does more than hand the next round a copy of the
last reviewer message.

**Findings, not prose.** The evaluator artifact
(`bundle/.ralph/schemas/evaluator-verdict.schema.json`) accepts a `findings`
array: each entry carries a stable `id`, a `severity` of `blocking` or
`advisory`, a `summary`, and optionally `evidence`, `requiredFix`,
`verification`, and a `disposition` of `open`, `fixed`, or `wontfix`. The older
`feedback: ["string"]` shape is still accepted and is normalized into blocking
findings, so existing workflows keep working unchanged.

**Findings accumulate.** Every verdict is folded into
`.ralph-workspace/artifacts/<ns>/defect-ledger.json`, which lives beside the
verdict artifact. A finding the current reviewer does not restate stays open and
is carried forward with its `roundsOpen` count incremented; only an explicit
`disposition` of `fixed` or `wontfix` closes one. Unraised **advisory** findings
close automatically, so advisory nits cannot block convergence.

**Approval is gated on the ledger.** A verdict cannot move to `approved` while
any blocking finding is still open. The reviewer must re-state each one with a
disposition. This is what stops a defect from disappearing between rounds.

**The rework brief covers every open finding.** The
`RALPH_EVALUATOR_FEEDBACK` block injected into the looped-back stage's control
plan is re-rendered from the whole ledger, not from the latest verdict alone. A
finding open for more than one round is flagged in the brief.

**Findings become real work.** Before a rework stage runs, one pending TODO is
synthesized per open blocking finding, carrying `addressesFinding: <id>`, the
reviewer's `requiredFix` as its content, and the reviewer's `verification` as
its verification command. Findings with no reviewer-supplied command fall back
to asserting the finding was dispositioned. Without this the rework stage
inherits a plan whose TODOs are already complete and has no work to do.

Supply a real `verification` command on a blocking finding wherever one can be
written: it is what turns the finding into a checkable rework TODO.

**Stalled loops stop early.** When a blocking finding stays open for
`RALPH_REWORK_STALL_ROUNDS` rounds (default `3`), the run fails with reason code
`rework-stalled` instead of spending its remaining rework budget on a loop that
is not converging. Set `RALPH_REWORK_STALL_ROUNDS=0` to disable.

**Compile-time shape is unchanged:** rework clones are still unrolled at compile
time, reuse the frozen planner source binding, and get a fresh control copy.
Resume never invents a new source for a rework clone.

## Exit 3, Sequential parity, review rework

- **Exit 3** means a wait was persisted successfully (approval or input). It is
  not classified as failure. Follow `actions list` / `respond`, then `resume`.
- **Sequential parity:** the same public states, reason codes, actions, resume,
  reset, recover, and cancel contracts apply to Sequential and Dependency.
  Sequential never surfaces native `permission` requests; Dependency may.
- **Review rework:** compile-time unrolled clones reuse the frozen planner
  source binding; each clone gets a fresh control copy plus the prior review
  verdict. Resume never invents a new source for a rework clone.

## Legacy orchestration: status-first recovery

Classic orchestration files (`.orch.json` / pipeline plans) and graph JSON remain
startable as `sourceKind: legacy-orchestration`. When a legacy Sequential run
looks deadlocked (no stage progressing, unclear owner, or stuck
`ORCHESTRATOR_HUMAN_ACK` / file ack path):

1. `ralph workflow status <exact-run-id>` — read outcome, reason, evidence, and
   the single printed next action.
2. Follow that action only (`actions list`, `resume`, `recover`, or `reset`
   with the named stage). Do not guess `latest` or skip diagnosis.
3. Intentional human waits are not stale: recover leaves them unchanged.
4. Public Sequential approvals use common actions + exit 3, not the legacy
   touch-file ack path. Env-gated `humanAck` remains internal to classic
   legacy-orchestration inputs only.

## Expected outputs and safe actions

| Situation | Typical `Action:` |
|-----------|-------------------|
| Running cleanly | none required (use `status` / `watch` / `logs`) |
| Overnight clean stop | `ralph workflow resume <run-id>` |
| Outstanding approval/input | `ralph workflow actions list <run-id>` |
| Answered input / approved gate | `ralph workflow resume <run-id>` |
| Changes requested | `ralph workflow reset <run-id> --stage <changesTarget>` |
| Automatic review rework exhausted | Inspect the named verdict, then `ralph workflow reset <run-id> --stage <last-repair-stage>` and `resume` |
| Stale owner | `ralph workflow recover <run-id>` |
| Live owner | none (wait or `cancel` if you own it) |

Do not pass `latest` to lifecycle verbs; use the exact run ID from start/status.

## Related pages

| Page | Use when |
|------|----------|
| [AGENT-WORKFLOW.md](AGENT-WORKFLOW.md) | Plan loop, workflow operator input (`--decision answer`), prompts |
| [orchestrated-ralph-example.md](orchestrated-ralph-example.md) | Sequential pipeline examples (classic orchestration internals) |
| [ENVIRONMENT.md](ENVIRONMENT.md) | Roots, session flags, models, workflow terminal UI env vars |
| [INSTALL.md](INSTALL.md) | Install and global `RALPH_HOME` layouts |
