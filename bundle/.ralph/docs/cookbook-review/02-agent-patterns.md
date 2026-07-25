# Cluster 2: Agent patterns and orchestration

Source cookbooks reviewed (4). These map onto Ralph's orchestrator
(`bundle/.ralph/orchestrator.sh`) and its 6 prebuilt agents
(`bundle/.ralph/agents/`: research, architect, implementation, code-review, qa,
security).

How Ralph handles this today: the orchestrator runs declared stages with
`sessionStrategy`, `inputArtifacts`/`outputArtifacts` handoffs
(`orchestrator-handoffs.sh`), per-stage `verify`
(`orchestrator-verify.sh`), `parallelStages` wave grouping
(`orchestrator.sh:1112`), and `loopControl.loopBackTo` + `maxIterations` driven
by an extracted review status (`orchestrator.sh:351` `check_loop_condition`,
defaults max 3, proceeds on `approved`). So Ralph already implements *fixed
chained workflows*, *parallelization*, and a *loopback gate* --- what it lacks is
**dynamic decomposition** and **rubric-driven grading**.

---

### Basic workflows: chaining, routing, parallelization  (Dec 2024, relevance: high)
URL: https://platform.claude.com/cookbook/patterns-agents-basic-workflows
What it teaches: Three primitives. Chaining = sequential steps each refining the
last (higher cost/latency, better quality). Parallelization = independent
subtasks run concurrently (same quality, lower latency). Routing = classify the
input, then dispatch to a specialized prompt (best quality for mixed inputs,
minimal overhead).
Ralph today: Chaining = ordered stages (have it). Parallelization =
`parallelStages` waves (have it, `orchestrator.sh:1112`). Routing = NOT present;
stage-to-agent assignment is static in the orchestration JSON.
Opportunity: Add a **router stage** --- a cheap classification step that picks
which downstream agent/plan to run based on the task (e.g. bug vs feature vs
docs routes to different agent chains). Ralph already has the building blocks
(stages + agents); routing is just a stage whose output selects the next stage
id, which `loopControl` machinery can already express.
Runtime mapping: Shared layer (orchestrator). Runtime-agnostic.
Effort / risk: M, low-medium (new stage type reusing loopControl dispatch).

### Orchestrator-workers (dynamic decomposition)  (Dec 2024, relevance: high)
URL: https://platform.claude.com/cookbook/patterns-agents-orchestrator-workers
What it teaches: A central LLM analyzes each input, emits structured subtask
descriptions (XML/JSON), and delegates to workers; results are synthesized.
Differs from fixed parallelization in that the *number and shape of subtasks
adapt to the input*. Recommends Opus for the orchestrator, Haiku for workers,
and warns about N+1 call cost and parse fragility (prefer JSON over XML).
Ralph today: Stages and their plans are authored ahead of time. Ralph has a
`plan-split.py` helper that splits broad todos into granular steps, but no
*model-driven* decomposition stage that emits new stages/todos at runtime.
Opportunity: A "planner" stage that reads the task and emits a stage list or a
generated plan file (Ralph already supports inline todos and `planFile` per
stage). This is the natural home for the Opus-orchestrator/Haiku-worker model
split --- which ties directly to Ralph's per-agent model selection. Use JSON
(Ralph is jq-native) not XML for the decomposition payload.
Runtime mapping: Shared layer. The decomposition prompt is runtime-agnostic;
model split leverages existing per-agent `models` frontmatter.
Effort / risk: L, medium (generates runtime artifacts; needs schema validation
+ Bats tests; guard against runaway stage generation with a cap).

### Evaluator-optimizer (generate/evaluate loop)  (Dec 2024, relevance: high)
URL: https://platform.claude.com/cookbook/patterns-agents-evaluator-optimizer
What it teaches: A generator LLM and a *separate* evaluator LLM in a loop. The
evaluator returns PASS / NEEDS_IMPROVEMENT / FAIL plus specific feedback; the
generator gets prior attempts + feedback and retries until PASS. Worth it when
criteria are clear and the model can act on its own feedback.
Ralph today: This is essentially what `loopControl` already does ---
code-review/qa/security stages produce a review whose status is extracted
(`extract_review_status`), and `check_loop_condition` loops back to a prior
stage unless `approved`, capped at `maxIterations` (default 3). The gap is that
the loop is coarse (whole-stage rerun) and the "evaluation" is a free-form
review, not a structured PASS/feedback contract.
Opportunity: Tighten the existing loop into an explicit evaluator contract:
require review stages to emit `{status, feedback[]}` (Ralph can validate with
jq), and feed the feedback array verbatim into the looped-back stage's prompt.
This is a refinement of working machinery, not net-new --- highest value-to-risk
in this cluster.
Runtime mapping: Shared layer (orchestrator + review status extraction).
Runtime-agnostic.
Effort / risk: M, low (formalize an existing contract; reuse loopback).

### Outcomes: grade-and-revise with a rubric  (May 2026, relevance: high)
URL: https://platform.claude.com/cookbook/managed-agents-cma-verify-with-outcome-grader
What it teaches: A *stateless, independent* grader is provisioned fresh each turn
with only the rubric + the artifact (not the writer's reasoning) and the same
tools. It checks an explicit, machine-checkable rubric (coverage checklist +
citation verification: live URL, verbatim quote, supports-claim) and returns
satisfied / needs_revision with per-criterion feedback. Key principle: make the
rubric specific enough to be checkable ("$/kW figure" not "mention demand
charges").
Ralph today: Review stages run with the *same* session/agent context as
upstream and grade against free-form agent instructions, not a separate rubric
artifact. Risk classification exists (`plan-todo-risk-classify.py`) and
verification commands are extracted (`plan_todo_extract_verification_commands.py`,
`plan-todo-verification-next.py`, `verification_result.py`), but there is no
independent-grader-with-rubric stage.
Opportunity: Two portable ideas. (1) Run review/qa/security stages with
`sessionStrategy: fresh` and pass only the artifact + a rubric file --- making
the grader genuinely independent (it cannot be argued into passing). (2)
Introduce a per-stage `rubric` artifact (a checklist file) that the grader must
verify item-by-item; Ralph's verification-command extraction already gives a
place to attach checkable assertions. This sharpens the existing verify gates
toward the cookbook's "make the grader earn satisfied" principle.
Runtime mapping: Shared layer. Rubric file + fresh-session grader are
runtime-agnostic.
Effort / risk: M, medium (rubric schema + fresh-grader wiring; Bats tests).

---

## Cluster takeaways for the backlog

1. **Formalize the evaluator contract on existing loopback.** Require review
   stages to emit `{status, feedback[]}`; feed feedback verbatim into the
   looped-back stage. Refines working machinery. Sources: evaluator-optimizer,
   outcomes.
2. **Independent rubric grader.** Run grade stages with `sessionStrategy: fresh`
   against an artifact + a checkable `rubric` file, not shared agent context.
   Source: outcomes.
3. **Router stage.** Cheap classification stage that selects the downstream
   agent/chain; expressible via existing loopControl dispatch. Source: basic
   workflows (routing).
4. **Planner / dynamic-decomposition stage.** Model emits stages or a generated
   plan file (JSON, capped); pairs Opus-planner with Haiku-workers via existing
   per-agent model frontmatter. Source: orchestrator-workers.
