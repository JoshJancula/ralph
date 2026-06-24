# Cluster 5: Prompt caching, batching, and cost observability

Source cookbooks reviewed (4). These map onto Ralph's cost story: the OpenCode
cache estimator (`bundle/.ralph/python/opencode_cache_estimate.py`, prefix-
stability heuristic), the demux that reads `cached_tokens`/`cache_read` from CLI
JSON (`run-plan-cli-json-demux.py`), and the benchmark/usage reporting
(`ralph-benchmark-report.py`, `ralph-usage-summary-text.py`,
`ralph-discover-report.py`).

How Ralph handles this today: Ralph *measures* cache reads where a runtime
reports them and *estimates* them for OpenCode, but it does not actively shape
prompts to *create* cache hits. There is no batch path (Ralph runs one
invocation per todo, interactively). Cost accounting exists but is byte/token
estimate-based, with prior bugs around cumulative snapshots (see the
benchmark-savings memory) and savings clarity (see the savings-report memory).

---

### Prompt caching through the Claude API  (Aug 2024, relevance: high)
URL: https://platform.claude.com/cookbook/misc-prompt-caching
What it teaches: Mark stable prefixes with `cache_control: ephemeral`; cache
reads cost 0.1x input (90% saving), writes 1.25x, 5-min TTL refreshed on hit
(1-hour at 2x). Order content stable-first, volatile-last. Minimums: 1024 tokens
(Sonnet) / 4096 (Opus/Haiku). Up to 4 explicit breakpoints. Automatic caching
moves the breakpoint forward across turns.
Ralph today: Ralph assembles every prompt fresh per todo (rules + agent profile
+ repo-map + todo text) but does not place cache breakpoints or order content to
be cache-friendly. The operator's own workflow already understands the 5-min TTL
(it shapes the wakeup-interval guidance), but Ralph's *driven* prompts ignore it.
Opportunity: This is the single biggest measurable cost win. Order the per-todo
prompt stable-first (rules, agent instructions, repo-map = stable across all
todos in a plan) and volatile-last (the specific todo + prior results). On the
Claude path, pass the stable block through `--system-prompt` (verified on Claude
Code 2.1.x). Do not assume `cache_control` breakpoints --- the installed CLI
does not expose that API flag. Generalize the existing OpenCode estimator into a
cross-runtime "is our prefix stable?" check so Ralph can *report* cache
effectiveness for the prompts it builds, not just what the CLI happens to report.
Runtime mapping: Prompt ordering = shared layer (helps every runtime's own
caching). Explicit `cache_control` breakpoints = unavailable on current Claude
Code CLI; stable `--system-prompt` shaping = Claude path today.
Effort / risk: M, medium (prompt assembly reorder in `run-plan-core.sh` + Claude
breakpoint; watch the backtick-injection hazard noted in the prompt-injection
memory; Bats tests for prompt ordering).

### Speculative prompt caching  (May 2025, relevance: med)
URL: https://platform.claude.com/cookbook/misc-speculative-prompt-caching
What it teaches: Warm the cache during user think-time by firing a max_tokens=1
request with the full context + `cache_control`, so the real request hits a warm
cache. ~90% TTFT reduction on a 150k-token context.
Ralph today: No cache pre-warming. Each todo's first call pays the full
cache-write latency.
Opportunity: In a multi-todo run the stable prefix is known *before* the next
todo starts. If a future Claude adapter exposes a safe cache-warm mechanism,
Ralph could fire a bounded warm request during the current todo's verification/
idle phase. On Claude Code 2.1.x-style CLIs with no `cache_control` flag, treat
speculative warming as **unsupported** and no-op. This pairs naturally with the
cluster-1 "pre-build the next summary in the background" item --- same idle
window, same status-line discipline (per the runner-blocking-ops memory).
Runtime mapping: Claude-only when capability-detected; otherwise documented as
unsupported on current CLI surfaces.
Effort / risk: M, medium (Claude path only; reuse background-job plumbing).

### Batch processing with the Message Batches API  (Oct 2024, relevance: low-med)
URL: https://platform.claude.com/cookbook/misc-batch-processing
What it teaches: Submit many requests asynchronously for 50% cost reduction;
24-hour TTL; poll for completion. Best for non-interactive bulk work, not
real-time.
Ralph today: Ralph is interactive/iterative per todo; there is no bulk,
latency-tolerant workload in the core loop. The closest fit is offline tooling:
re-running evals, benchmark regeneration, or classifying a backlog of plans.
Opportunity: Narrow. If the cluster-4 retrieval eval or a future LLM-as-judge
eval set grows large, run it through the Batches API (Claude path) at 50% cost
for offline scoring --- not in the live loop. Flag as a future, Claude-only,
out-of-core-loop optimization; do not wire into `run-plan`.
Runtime mapping: Claude-only, offline tooling only.
Effort / risk: S, low (only if/when an offline eval batch exists); largely a note.

### Usage & cost Admin API  (Aug 2025, relevance: med)
URL: https://platform.claude.com/cookbook/observability-usage-cost-api
What it teaches: Programmatic usage (uncached_input, output, cache_creation,
cache_read, server_tool_use) and cost data, groupable by model / service_tier /
workspace / time bucket. Enables cache-efficiency reporting
(cache_reads / total_input) and cost attribution.
Ralph today: Ralph already computes cache-efficiency-style ratios from CLI-
reported usage in `ralph-benchmark-report.py` / `ralph-discover-report.py`, but
from per-invocation CLI output, not an authoritative billing source --- and that
self-measured path has hit accuracy bugs (cumulative-snapshot inflation; needs
the measured-vs-estimated labelling from the savings-report memory).
Opportunity: Two things. (1) Adopt the Admin API's *dimension model*
(uncached_input / cache_creation / cache_read / output as distinct buckets) as
the canonical schema for Ralph's own usage records, so cache-efficiency =
cache_read / total_input is computed consistently everywhere. (2) For Claude
users, optionally reconcile Ralph's self-measured numbers against the Admin API
as ground truth (opt-in, needs an admin key) --- the same "verify against ground
truth" discipline used for the Antigravity binary.
Runtime mapping: Schema/dimension model = shared layer (improves all-runtime
accounting). Admin-API reconciliation = Claude-only, opt-in.
Effort / risk: schema alignment: M, low; Admin reconciliation: M, medium
(opt-in, credential handling).

---

## Cluster takeaways for the backlog

1. **Cache-friendly prompt ordering + Claude stable `--system-prompt`.**
   Stable-first (rules/agent/repo-map), volatile-last (todo + results); no
   invented `cache_control` markup. Biggest measurable cost win; helps every
   runtime via ordering. Source: prompt caching.
2. **Canonical usage schema = Admin API dimensions.** uncached_input /
   cache_creation / cache_read / output buckets; consistent cache-efficiency
   ratio; fixes prior accounting ambiguity. Source: usage/cost Admin API.
3. **Speculative cache warm (Claude, capability-gated) in the idle window.**
   Only when the installed CLI exposes a safe warm mechanism; current Claude Code
   CLI surfaces report unsupported. Source: speculative caching.
4. **(Future, offline) Batches API** for large eval/scoring runs at 50% cost;
   not in the live loop. Source: batch processing.
