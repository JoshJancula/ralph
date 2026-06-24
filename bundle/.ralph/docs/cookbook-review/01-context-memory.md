# Cluster 1: Context engineering, compaction, and memory

Source cookbooks reviewed (4). These map onto Ralph's single biggest cost
surface: keeping long multi-todo / multi-stage runs inside the context window
without losing task state.

How Ralph handles this today, in one paragraph: Ralph compacts *tool output*
(`bundle/.ralph/python/shell-output-compact.py`, family-based) and windows
stored results (`bundle/.ralph/python/result_windowing_metrics.py`,
preview+readback netting). For *conversation history* it does not summarize
itself; it delegates to the runtime's own compaction by reusing the session id
with a compact command prefix before each todo
(`--session-strategy compact`, see
`bundle/.ralph/bash-lib/run-plan/run-plan-session.sh:244`). The four strategies
are `fresh|resume|reset|compact`. There is no Ralph-owned structured summary, no
tool-result clearing of the model's transcript, and no cross-session memory
store beyond the session-id file.

---

### Context engineering: memory, compaction, and tool clearing  (Mar 2026, relevance: high)
URL: https://platform.claude.com/cookbook/tool-use-context-engineering-context-engineering-tools
What it teaches: Three complementary primitives and a decision framework for
when each applies. Compaction (`compact_20260112`) summarizes the whole
transcript at a token trigger. Tool-result clearing (`clear_tool_uses_20250919`)
mechanically replaces old `tool_result` blocks with placeholders (no inference
cost) while keeping the last N. Memory tool (`memory_20250818`) is client-side
persistent storage Claude reads/writes for cross-session knowledge. Diagnosis
rule: clear when re-fetchable tool output dominates; compact when dialogue/
reasoning dominates; use memory when knowledge must survive a reset.
Ralph today: Ralph's "compaction" is output-level only and runtime-delegated;
there is no transcript-level clearing or model-visible memory store. The
diagnosis it implicitly makes (clear large tool output) it already does well via
result windowing.
Opportunity: Adopt the *diagnosis framework* as Ralph's compaction policy. Ralph
already knows, per todo, whether context is tool-output-heavy (it measures bytes
in result windowing) vs dialogue-heavy (turn count). Drive session-strategy
selection from that signal instead of a static flag. The "clear tool uses, keep
last N" behavior is conceptually what result-windowing already approximates ---
document the parallel and unify the accounting.
Runtime mapping: Shared layer. The *policy* (when to compact/clear) lives in
Ralph and benefits all 5 runtimes; the *mechanism* differs (Claude has native
context-management betas; cursor/codex/opencode/antigravity rely on their own
compact command, which Ralph already drives).
Effort / risk: M, low (policy doc + signal wiring; no new deps).

### Automatic context compaction  (Jun 2026, relevance: high)
URL: https://platform.claude.com/cookbook/tool-use-automatic-context-compaction
What it teaches: A tool_runner that, on crossing a token threshold, injects a
summary request, captures a `<summary>...</summary>` of completed work / status
/ patterns / next steps, replaces history with the summary, and resumes ---
optionally summarizing with a cheaper model (Haiku). Threshold guidance: low
(5-20k) for sequential item processing with clear boundaries; high (100-150k)
for context-heavy tasks. 58% token reduction on a sequential ticket workload.
Ralph today: Ralph processes a plan as a sequence of todos --- exactly the
"sequential item processing with clear boundaries" case this targets --- but
relies on the runtime to decide compaction. The summary structure (completed /
status / next steps) overlaps heavily with what Ralph already tracks in the plan
file checkboxes and verification results (`verification_result.py`).
Opportunity: Ralph can build a runtime-agnostic "continuation summary" between
todos from data it already owns: checked todos, verification outcomes, artifact
paths. Inject that as the prefix of the next todo's prompt rather than relying on
the runtime to reconstruct it. This is the highest-leverage cross-runtime win in
this cluster --- it gives codex/cursor/opencode/antigravity a compaction-quality
summary they otherwise lack.
Runtime mapping: Shared layer (Ralph-built summary), runtime-agnostic.
Effort / risk: M, medium (prompt-shape change; needs a Bats test for the
summary-prefix injection).

### Memory & context management with Claude Sonnet 4.6  (May 2025, relevance: med)
URL: https://platform.claude.com/cookbook/tool-use-memory-cookbook
What it teaches: The `memory_20250818` tool's six commands (view/create/
str_replace/insert/delete/rename) over a `/memories` dir, plus context editing
(`clear_thinking_20251015`, `clear_tool_uses_20250919`). Memory persists across
sessions; context editing keeps the live window bounded. Notes the
memory-poisoning / path-traversal risk and mitigations (path validation,
per-project isolation, logging).
Ralph today: No model-facing memory store. Ralph's own operator memory
(`.claude/.../memory/`) is for the human's assistant, not the driven runtime.
Cross-todo knowledge is carried only by the runtime session.
Opportunity: A bounded, Ralph-owned per-plan memory dir
(`.ralph-workspace/memory/<plan-key>/`) exposed as MCP proxy tools would give
*all* runtimes the cross-session persistence Claude gets natively --- and Ralph
already has the path-canonicalization guard (`mcp-policy-canonicalize-path.py`)
and result-store locking to do it safely. Flag the poisoning risk explicitly.
Runtime mapping: Shared layer via MCP proxy tools (works for any runtime that
speaks MCP); Claude could alternatively use its native memory tool.
Effort / risk: L, medium (new proxy tools + tests; reuse path guard).

### Session memory compaction (background threading)  (Jan 2026, relevance: med)
URL: https://platform.claude.com/cookbook/misc-session-memory-compaction
What it teaches: "Instant" compaction --- build the summary in a background
thread once a soft threshold is hit, then swap it in with zero wait when the hard
limit arrives. Structured summary format preserves exact identifiers, verbatim
error messages, user corrections, and precise in-progress state. Uses prompt
caching on the conversation prefix for ~80% cheaper background summaries.
Ralph today: Ralph compaction is reactive (compact prefix before next todo) and
synchronous; the operator has previously been confused by silent blocking ops
(see runner-blocking-ops memory). No background pre-build.
Opportunity: Two takeaways portable to bash: (1) the *summary format* (preserve
identifiers / errors verbatim / next steps) should be the template for the
between-todo continuation summary above. (2) Pre-build the next summary during
the current todo's idle/verify phase so the next todo starts instantly ---
Ralph can launch this as a background job, but must print a terminal status line
(per the runner-blocking-ops lesson) rather than hang silently.
Runtime mapping: Shared layer. Summary format is runtime-agnostic; background
pre-build is a Ralph orchestration detail.
Effort / risk: M, medium (background job + status line; reuse existing job
plumbing).

---

## Cluster takeaways for the backlog

1. **Between-todo continuation summary (runtime-agnostic compaction).** Build a
   structured summary (completed todos, verification outcomes, artifact paths,
   verbatim errors, next steps) from data Ralph already owns and inject it as the
   next todo's prompt prefix. Biggest cross-runtime win; sources: auto
   compaction + session memory compaction.
2. **Compaction *policy* driven by measured signal.** Use result-windowing byte
   share vs turn count to choose clear-like vs compact-like behavior instead of a
   static `--session-strategy`. Source: context engineering decision framework.
3. **Ralph-owned per-plan memory store via MCP proxy tools.** Bounded
   `/memories`-style persistence for all runtimes, reusing the path-canonicalize
   guard; document poisoning risk. Source: memory cookbook.
