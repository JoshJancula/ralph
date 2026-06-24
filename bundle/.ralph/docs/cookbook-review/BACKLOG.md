# Ralph improvement backlog (from the cookbook review)

Distilled from the 7 cluster docs. This file is the implementation contract for
Tier 1 through Tier 3 work in PLAN12 and later cookbook TODOs.

Reach legend: **all** = shared Ralph layer across all 5 runtimes; **all+claude** =
shared core plus a Claude-native enhancement when the installed CLI exposes it;
**claude** = Claude-only mechanism.

Status legend: **not started** = no implementation yet; **partial** = related
machinery exists but the backlog contract is incomplete; **planned** = scoped in
PLAN12 with env gate defined; **capability-gated** = blocked on runtime CLI
capability detection.

## Runtime structured-output contract (verified June 2026)

Ralph does **not** assume direct Anthropic API features through Claude Code CLI.

| Runtime | Structured output when available | Fallback |
|---------|----------------------------------|----------|
| Claude | Stable prefix via `--system-prompt`; final JSON via `--json-schema` when capability-detected | Prompt contract + Ralph schema validation |
| Codex | `--output-schema` when capability-detected | Prompt contract + post-write validation |
| Cursor, OpenCode, Antigravity | N/A | Prompt contract + post-write validation |

Unsupported in current CLI surfaces and therefore **not promised** in docs or
implementation plans: `cache_control`, `tool_choice`, embedding/vector indexes,
and direct API batch/cache-breakpoint knobs.

## Rollout convention (all cookbook feature gates)

Every behavior-changing optimization in this roadmap shares one parsing contract:

1. **Ralph/hybrid mode** (`RALPH_MODE=ralph` or `hybrid`): feature is **enabled**
   unless its specific environment variable is set to `0`.
2. **Native/no mode** (unset, `no`, or any other value): feature is **disabled**
   unless its specific environment variable is set to `1`.
3. **Invalid boolean values** (`2`, `yes`, empty string after trim, etc.) fail
   early with an actionable error naming the variable and accepted values
   (`0`, `1`, or unset for default-mode behavior).

Document each feature's gate in `docs/ENVIRONMENT.md` when implemented.

## Implementation status (Tier 1 through Tier 3)

Promotion, migration, and baseline comparison: [MIGRATION.md](./MIGRATION.md),
[IMPLEMENTATION-RESULTS.md](./IMPLEMENTATION-RESULTS.md).

| # | Improvement | Status | Feature gate | Implementation location | Test location | Known runtime limitation |
|---|-------------|--------|--------------|-------------------------|---------------|--------------------------|
| 1 | Cache-friendly prompt ordering (stable prefix first) | implemented | `RALPH_PROMPT_STABLE_PREFIX` | `bundle/.ralph/bash-lib/run-plan/run-plan-core.sh` (`ralph_run_plan_merge_prompt`, `ralph_run_plan_stable_prefix_enabled`); `run-plan-invoke-claude.sh` (`--system-prompt`); `bundle/.ralph/python/ralph-usage-record.py` (`stable_prefix_bytes`, `stable_prefix_fingerprint`) | `tests/bats/run-plan/run-plan-prompt-order.bats`; `tests/fixtures/cookbook-roadmap/prompt-byte-order-baseline.json`; `tests/python/test_cookbook_offline_e2e.py` | Claude splits stable block via `--system-prompt`; Ralph/hybrid default is stable-first for Cursor/Codex/OpenCode/Antigravity. Native/no default preserves legacy merge (OpenCode stable-first; others stable-last). No `cache_control` CLI flag is invented. |
| 2 | Between-todo continuation summary | implemented | `RALPH_CONTINUATION_SUMMARY` | `run-plan-core.sh` (inject after stable prefix); `bundle/.ralph/python/continuation_summary.py`; `bundle/.ralph/python/verification_result.py` | `tests/python/test_continuation_summary.py`; `tests/bats/run-plan/run-plan-prompt-order.bats`; `tests/python/test_cookbook_offline_e2e.py` | Deterministic Markdown from runner-verifiable state only; no model-generated summary. State at `.ralph-workspace/sessions/<plan-key>/continuation-summary.json`. |
| 3 | Lexical `ralph_proxy_tool_search` compact catalog | implemented | `RALPH_MCP_COMPACT_TOOL_CATALOG` (default `1` in Ralph/hybrid); `RALPH_MCP_CORE_TOOLS` | `bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh` (`ralph_mcp_proxy_compact_tool_catalog_active`, `ralph_mcp_proxy_default_core_tool_names`); `bundle/.ralph/bash-lib/mcp/mcp-setup.sh`; `bundle/.ralph/mcp-server.sh`; `bundle/.ralph/python/mcp-proxy-tool-search-rank.py` | `tests/python/test_tool_search.py`; `tests/bats/mcp-proxy/mcp-proxy-search.bats`; `tests/fixtures/cookbook-roadmap/mcp-tools-list-baseline.json`; `tests/python/test_cookbook_offline_e2e.py` | Compact mode is Ralph/hybrid default; set `RALPH_MCP_COMPACT_TOOL_CATALOG=0` for full `tools/list`. Embeddings never required. `tools/list` never emits `nextCursor: null`. |
| 4 | JSON-schema artifact contracts at handoff | implemented | `RALPH_ARTIFACT_SCHEMA_VALIDATION` | `bundle/.ralph/bash-lib/orchestrator/orchestrator-handoffs.sh` (`verify_stage_artifact_schemas`); `bundle/.ralph/python/artifact_json_schema.py`; `scripts/validate-orchestration-schema.sh` | `tests/python/test_artifact_schema_validator.py`; `tests/bats/orchestration/orchestration-handoffs.bats`; `tests/python/test_cookbook_offline_e2e.py` | Optional `schema` on artifacts; omitted schema preserves legacy existence checks. Claude may add `--json-schema`; Codex may add `--output-schema`; Ralph stdlib validator is always source of truth post-write. |
| 5 | Formal evaluator `{status, feedback[]}` loopback | implemented | `RALPH_EVALUATOR_JSON_CONTRACT` | `bundle/.ralph/python/evaluator_contract.py`; `bundle/.ralph/bash-lib/review-status.sh`; `bundle/.ralph/bash-lib/run-plan/run-plan-loopback.sh`; `bundle/.ralph/orchestrator.sh`; `scripts/validate-orchestration-schema.sh`; `bundle/.ralph/bash-lib/plan-todo.sh` | `tests/python/test_evaluator_contract.py`; `tests/bats/orchestration/orchestration-handoffs.bats`; `tests/bats/plan/validate-plan.bats`; `tests/python/test_cookbook_offline_e2e.py` | Declared evaluator schema forces JSON-only parsing; legacy `<!-- REVIEW_STATUS -->` when no schema. `maxIterations` exhaustion fails unless `onExhausted: proceed`. |
| 6 | Contextual BM25 (deterministic context header) | implemented | `RALPH_MCP_CONTEXTUAL_SEARCH` | `bundle/.ralph/python/mcp-proxy-search-rank.py`; `bundle/.ralph/python/search_context.py`; `bundle/.ralph/python/repo_map.py` | `tests/python/test_mcp_proxy_search_rank.py`; `tests/python/test_retrieval_eval.py`; `tests/fixtures/retrieval-eval/baseline-metrics.json`; `tests/python/test_cookbook_offline_e2e.py` | Path/symbol/heading boosts only; path-only fallback when Python unavailable. Index cache under `$RALPH_PLAN_WORKSPACE_ROOT/search-context/`. |
| 7 | Retrieval eval harness (precision/recall/MRR) | implemented | Harness is offline-only (no runtime gate); ranker follows `RALPH_MCP_CONTEXTUAL_SEARCH` when `--contextual auto` | `bundle/.ralph/python/retrieval_eval.py`; `tests/fixtures/retrieval-eval/queries.json`; `tests/fixtures/retrieval-eval/baseline-metrics.json` | `tests/python/test_retrieval_eval.py`; `tests/fixtures/cookbook-roadmap/bm25-rankings-baseline.json` | CI compares contextual metrics to baseline with per-query safety gates; pre-contextual ordering gate remains in `bm25-rankings-baseline.json`. |
| 8 | Cross-runtime tool-eval harness | implemented | Offline default; live opt-in via `RALPH_TOOL_EVAL=live` (blocked in CI unless `RALPH_TOOL_EVAL_FORCE_LIVE=1`) | `bundle/.ralph/python/tool_eval.py`; `bundle/.ralph/python/tool_call_target_telemetry.py`; `bundle/.ralph/python/ralph-discover-report.py` | `tests/python/test_tool_eval.py`; `tests/fixtures/tool-eval/tasks.json`; `tests/fixtures/tool-eval/offline-traces.json`; `tests/fixtures/tool-eval/baseline-report.json` | Offline fake-runtime replays traces; live mode invokes real CLIs and writes only under state root. |
| 9 | Progressive rule/skill disclosure | implemented | `RALPH_PROGRESSIVE_CONTEXT`; `RALPH_PROGRESSIVE_CONTEXT_THRESHOLD`; `RALPH_PROGRESSIVE_CONTEXT_MAX_ITEMS` | `bundle/.ralph/python/context_metadata.py`; `bundle/.ralph/python/progressive_context.py`; `bundle/.ralph/bash-lib/agent-config/context-block.sh`; `run-plan-core.sh` | `tests/python/test_progressive_context.py`; `tests/bats/agent-config-tool.bats`; `tests/bats/run-plan/run-plan-prompt-order.bats` | `alwaysApply: true` rules always full; malformed metadata falls back to legacy full load with warning. Native Claude passthrough skips Ralph context assembly. |
| 10 | Provenance citations in handoff artifacts | implemented | `RALPH_ARTIFACT_PROVENANCE` | `bundle/.ralph/python/artifact_provenance.py`; `bundle/.ralph/bash-lib/orchestrator/orchestrator-handoffs.sh` (`verify_stage_artifact_provenance`); agent profile guidance | `tests/python/test_provenance.py`; `tests/bats/orchestration/orchestration-handoffs.bats` | File and generated-artifact citations only; external URL validation out of scope. |
| 11 | Canonical usage schema (Admin API dimensions) | partial | No env gate; readers always backward compatible | `bundle/.ralph/python/usage_accounting.py`; `bundle/.ralph/python/ralph-benchmark-report.py`; `bundle/.ralph/python/run-plan-cli-json-demux.py`; `bundle/.ralph/python/ralph-usage-summary-text.py` | `tests/python/test_usage_accounting.py`; `tests/python/test_benchmark_report.py`; `tests/python/test_ralph_usage_record.py` | v2 writers emit `uncached_input_tokens` and `cache_efficiency_ratio`; legacy `input_tokens` still read. Admin API reconciliation remains future opt-in. |
| 12 | Per-agent reasoning effort / thinking budget | implemented | `RALPH_REASONING_EFFORT`; agent `reasoning_effort`; runtime `*_PLAN_REASONING_EFFORT` | `bundle/.ralph/bash-lib/run-plan/run-plan-reasoning-effort.sh`; per-runtime invoke adapters; agent frontmatter / `config.json` | `tests/bats/run-plan/run-plan-runtime-invocation.bats` | Claude maps to `--effort` when supported; Codex to `model_reasoning_effort` when supported; Cursor/OpenCode/Antigravity log once and use `inherit`. |
| 13 | Independent rubric grader (`sessionStrategy: fresh`) | implemented | `RALPH_RUBRIC_GRADER`; orchestration `sessionStrategy: fresh` on grader stages | `bundle/.ralph/python/rubric_grader.py`; `bundle/.ralph/python/rubric_contract.py`; `bundle/.ralph/bash-lib/rubric-grader.sh`; `bundle/.ralph/bash-lib/review-status.sh`; `bundle/.ralph/orchestrator.sh` | `tests/python/test_rubric_grader.py`; `tests/bats/orchestrator/orchestrator.bats` | Deterministic criterion types run first; optional model judgment criteria when stage invokes a fresh session. |
| 14 | Router stage (schema-validated dispatch) | implemented | `RALPH_ROUTER_STAGE`; stage `router` block in orchestration JSON | `bundle/.ralph/bash-lib/orchestrator/orchestrator-router.sh`; `bundle/.ralph/python/router_contract.py`; `bundle/.ralph/orchestrator.sh`; `bundle/.ralph/schemas/router-decision.schema.json` | `tests/python/test_router_contract.py`; `tests/bats/orchestration/orchestration-schema.bats` | Forward-only dispatch; `loopControl` remains the sole backward path. Invalid router JSON fails the stage. |
| 15 | Ralph-owned per-plan memory store (MCP) | implemented | `RALPH_PLAN_MEMORY`; `RALPH_PLAN_MEMORY_MAX_*` | `bundle/.ralph/python/plan_memory.py`; `bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-plan-memory.sh`; `mcp-proxy-tools.sh` | `tests/python/test_plan_memory.py`; `tests/bats/mcp-proxy/mcp-proxy-policy.bats` | Isolated to plan key under state root; content treated as untrusted; no cross-plan search. |
| 16 | Guided/hierarchical continuation summary | implemented | `RALPH_CONTINUATION_SUMMARY_HIERARCHICAL`; `RALPH_CONTINUATION_SUMMARY_*` grouping/render limits | `bundle/.ralph/python/continuation_summary.py` (`build_consolidated_groups`, `rebuild_markdown`) | `tests/python/test_continuation_summary.py` | Deterministic window/stage consolidation only; no LLM summarizer. Render byte cap via `RALPH_CONTINUATION_SUMMARY_MAX_RENDER_BYTES`. |
| 17 | Stored-result local reduction (`result_reduce`) | implemented | `RALPH_RESULT_REDUCE`; `RALPH_RESULT_REDUCE_MAX_INPUT_BYTES` | `bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result-reduce.sh`; `bundle/.ralph/python/mcp_proxy_result_reduce.py`; `mcp-proxy-tools.sh` | `tests/python/test_mcp_proxy_result_reduce.py`; `tests/bats/mcp-proxy/mcp-proxy-envelope-next-actions.bats` | jq/grep/head/tail reduction paths; no arbitrary awk on untrusted input. |
| 18 | Structured final-output enforcement | implemented | `RALPH_FINAL_OUTPUT_SCHEMA`; `RALPH_STRUCTURED_OUTPUT_SCHEMA` | `bundle/.ralph/bash-lib/run-plan/run-plan-structured-output.sh`; `run-plan-invoke-claude.sh` (`--json-schema` when supported); `run-plan-invoke-codex.sh` (`--output-schema` when supported) | `tests/bats/run-plan/run-plan-runtime-invocation.bats`; `tests/python/test_artifact_schema_validator.py` | Capability-detected CLI flags plus post-invocation Ralph validation; not `tool_choice`. |
| 19 | Speculative cache warm (Claude) | capability-gated | `RALPH_CLAUDE_SPECULATIVE_CACHE_WARM` (default off everywhere) | `bundle/.ralph/bash-lib/run-plan/run-plan-claude-speculative-cache-warm.sh`; `run-plan-post-verify.sh` | `tests/bats/run-plan/run-plan-invoke-claude-mcp.bats`; `run-plan-process-teardown.bats`; `run-plan-invocation-usage.bats` | **Not fully implemented on current CLI surfaces:** probe requires both `--cache-control` and `--max-output-tokens`; Claude Code 2.1.x-style installs report `unsupported` and perform **no** warm request. Do not document or mark as production-ready until capability probe passes. |
| 20 | Planner / dynamic-decomposition stage | implemented | `RALPH_DYNAMIC_PLANNER` | `bundle/.ralph/bash-lib/orchestrator/orchestrator-planner.sh`; `bundle/.ralph/python/planner_contract.py`; `bundle/.ralph/orchestrator.sh`; generated plans under state root | `tests/python/test_plan_split.py`; `tests/bats/plan/validate-plan.bats`; `tests/bats/orchestration/orchestration-schema.bats` | Hard caps on generated todos/stages; never overwrites operator-authored plans. |
| 21 | SKILL.md package alignment + optional native Skill emission | implemented | `RALPH_SKILL_PACKAGE_VALIDATION` | `bundle/.ralph/python/skill_package.py`; `bundle/.ralph/bash-lib/agent-config/skill-package.sh`; `scripts/sync-runtime-assets.sh`; `bundle/.ralph/new-agent.sh` | `tests/python/test_skill_package.py`; `tests/bats/sync-runtime-assets-mcp.bats`; `tests/bats/agent-config-tool.bats` | Validates package layout and frontmatter at sync/agent-config time. Native Claude Skill emission only when project config allows; not required for Ralph context loading. |

## Tier 4 --- future / situational (notes, not near-term)

| # | Improvement | Source | Notes |
|---|-------------|--------|-------|
| 22 | **Batches API for offline eval/scoring** at 50% cost | batch processing | Only when an eval batch grows large; Claude-only; never in the live loop |
| 23 | **Model classifier fallback** for low-confidence routing/risk cases, backed by a confusion-matrix eval | classification | Keep deterministic fast path (`plan-todo-risk-classify.py`); model only on low-confidence |
| 24 | **Synthetic test-case generation** to broaden Bats/eval fixtures beyond hand-authored ones | generate test cases | Offline tooling; bootstraps items 7 and 8 |

## Suggested sequencing

1. **Items 4 + 5** first --- JSON-schema artifact contracts and the formalized
   evaluator loop are low-risk refinements of working machinery.
2. **Items 1 + 2** next --- cache-friendly ordering and continuation summary are
   the largest measurable shared-layer wins.
3. **Items 7 + 8** as the safety net --- retrieval and tool eval harnesses land
   before ranking/catalog changes (items 3, 6, 9, 13, 17).
4. Everything else follows Tier order within each band.

## Baseline fixtures

Pre-implementation metrics live under `tests/fixtures/cookbook-roadmap/`. See
`tests/fixtures/cookbook-roadmap/BASELINE.md` for which later TODOs must compare
against each metric. Validated offline by `tests/python/test_cookbook_roadmap_baseline.py`.
