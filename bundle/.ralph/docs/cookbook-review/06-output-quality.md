# Cluster 6: Evals, citations, structured output, extended thinking

Source cookbooks reviewed (5). These map onto Ralph's quality and observability
surface: verification (`verification_result.py`,
`plan_todo_extract_verification_commands.py`), tool-usage telemetry
(`tool_call_target_telemetry.py`, which already emits antipattern feedback), and
agent handoff artifacts.

How Ralph handles this today: quality is gated by pass/fail verification commands
and loopback review status; there is no scored eval harness, no labelled
regression set, no source attribution on agent outputs, and thinking budget is
left to each runtime's default.

---

### Building evals  (Mar 2024, relevance: high)
URL: https://platform.claude.com/cookbook/misc-building-evals
What it teaches: Every eval = input + output + golden answer + score. Three
grading tiers in priority order: code-based (string/regex, fast/cheap/reliable),
model-based (LLM-as-judge with a rubric, for subjective tasks --- and you must
test the grader), human (last resort). Make the eval set representative; prefer
volume over perfection; grading cost recurs every run so favor cheap methods.
Ralph today: Ralph has code-based pass/fail (verification commands) but no
golden-answer scoring and no LLM-as-judge. The cluster-2 review loop is an
implicit, unscored model grader.
Opportunity: Introduce a lightweight, stdlib eval harness with the three-tier
hierarchy. Code-based graders are a natural fit for Ralph (it already runs
verification commands); model-based grading slots in as the formalized
evaluator/rubric stage from cluster 2. The key new asset is a *checked-in eval
set* with golden answers --- start with the retrieval eval from cluster 4 and a
few plan-outcome cases --- run via `scripts/run-python-unit-tests.sh` style
tooling so eval becomes a regression gate.
Runtime mapping: Code-based graders = shared layer. Model graders = any runtime.
Runtime-agnostic.
Effort / risk: M, medium (harness + fixtures + tests; reuse verification result
parsing).

### Generate synthetic test data for a prompt template  (Aug 2024, relevance: med)
URL: https://platform.claude.com/cookbook/misc-generate-test-cases
What it teaches: Extract `{{VARIABLE}}` slots from a prompt template, then have
the model generate diverse, in-distribution test values via a meta-prompt;
combine with prompt caching to add many examples cheaply. Used to build eval
sets and few-shot examples without real data.
Ralph today: Ralph has many prompt templates (plan templates, the
`ralph_run_next_todo_prompt`, agent instruction bodies) but no way to generate
test cases for them; Bats fixtures are hand-authored
(`scripts/setup-test-fixtures.sh`).
Opportunity: Use this to bootstrap the eval set above --- generate synthetic
plans / todos / tool-output samples to exercise the runner, compactors, and
classifiers across more of the input distribution than hand-written fixtures
cover. Ralph's templates already use `{{TOKEN}}` placeholders
(ARTIFACT_NS/PLAN_KEY/STAGE_ID), so the variable-extraction step maps directly.
Runtime mapping: Offline tooling (any runtime generates the data). Runtime-agnostic.
Effort / risk: M, low (offline fixture generation; not in the live loop).

### Tool evaluation  (Sep 2025, relevance: high)
URL: https://platform.claude.com/cookbook/tool-evaluation-tool-evaluation
What it teaches: Evaluate *tools* (not prompts) by running agents through
task files and measuring accuracy, task duration, tool-calls-per-task, and
per-tool duration --- plus eliciting the agent's qualitative feedback on tool
naming, parameter docs, error messages, and missing functions.
Ralph today: This is strikingly close to what `tool_call_target_telemetry.py`
and `ralph-discover-report.py` already do --- they scan tool-call sequences for
antipatterns (heavy native reads, shell-status polling) and recommend batching.
Ralph measures tool *usage*, but not tool *success against tasks*, and it does
not collect the agent's feedback on its own tool ergonomics.
Opportunity: Turn Ralph's MCP proxy tool surface into a measured eval target.
Define task files (e.g. "find the function that does X", "edit file Y") and run
them across all 5 runtimes, scoring accuracy + tool-calls-per-task + duration.
This is the cross-runtime "are our proxy tools good?" harness --- it would, for
example, have caught the nextCursor tool-drop and the strict-proxy Read/Edit
deadlock (see those memories) as concrete task failures, not just anecdotes.
Add an agent-feedback capture step on tool ergonomics.
Runtime mapping: Shared layer (evaluates Ralph's own tools), run across every
runtime. Strongly runtime-agnostic --- this is the cross-runtime regression net.
Effort / risk: M-L, medium (task files + per-runtime harness + scoring; reuse
telemetry plumbing).

### Citations  (Mar 2024, relevance: med)
URL: https://platform.claude.com/cookbook/misc-using-citations
What it teaches: Native document citations attach `cited_text` + source location
to answer spans, with lower token cost and higher accuracy than prompt-based
quoting, and won't cite documents not supplied. Verification benefit: users can
spot-check claims against exact sources.
Ralph today: Agent handoff artifacts assert findings (research summaries,
review verdicts) with no provenance --- there is no link from a claim back to the
file/line or doc that supports it.
Opportunity: Require provenance lines in handoff artifacts: every material claim
cites a `file:line` or artifact path (Ralph's clickable `file_path:line`
convention already exists). On the Claude path, native citations can enforce
this when an agent reasons over provided documents. This pairs with the
outcomes/grade-and-revise rubric (cluster 2): a grader can mechanically check
that cited paths exist (`test -e`) and that quoted lines match --- the same
"LIVE / VERBATIM / SUPPORTS_CLAIM" checks the Outcomes cookbook uses for URLs.
Runtime mapping: Provenance convention = shared layer (any runtime can be
prompted to cite file:line). Native citations = Claude-only enhancement.
Effort / risk: M, low-medium (artifact convention + grader path-check).

### Extended thinking  (Feb 2025, relevance: med)
URL: https://platform.claude.com/cookbook/extended-thinking-extended-thinking
What it teaches: A `thinking` budget (>=1024 tokens) gives transparent reasoning
that improves complex multi-step tasks; thinking tokens bill as output and count
against the window; incompatible with temperature/top_p/top_k/prefill. Start
small, scale by task complexity. Redacted-thinking blocks must be passed back
intact. The companion cookbook covers thinking + tool use.
Ralph today: Ralph does not set or budget thinking; it inherits each runtime's
default. The earlier cluster-1 note about `clear_thinking_20251015` is the
context-management counterpart --- thinking can dominate the window.
Opportunity: Make thinking/reasoning budget a per-agent/per-stage knob
(architect/security stages benefit from more; mechanical edits need little),
surfaced in agent frontmatter alongside `models`. On the Claude path, map
supported values to `--effort` after capability detection. Do not assume a raw
`thinking` parameter is available through Claude Code CLI. Treat as advisory on
runtimes without a native reasoning-effort control.
Runtime mapping: Budget knob in frontmatter = shared layer; native enforcement
= per-runtime when capability-detected (Claude `--effort` where supported).
Effort / risk: S-M, low (frontmatter field + Claude param mapping).

---

## Cluster takeaways for the backlog

1. **Tool-eval harness across all 5 runtimes.** Task files scored on accuracy /
   tool-calls-per-task / duration + agent ergonomics feedback; the cross-runtime
   regression net that would catch tool-drop / deadlock classes of bug. Source:
   tool evaluation.
2. **Stdlib eval harness with the 3-tier grading hierarchy** and a checked-in
   golden-answer set; eval as a regression gate. Sources: building evals,
   generate test cases.
3. **Provenance in handoff artifacts** (`file:line` citations, grader checks
   they exist/match); native citations on Claude. Source: citations.
4. **Per-agent reasoning effort** in frontmatter, mapped to supported runtime
   controls (Claude `--effort` when detected). Source: extended thinking.
