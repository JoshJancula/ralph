# Cluster 3: Tool use

Source cookbooks reviewed (4). These map onto Ralph's MCP proxy
(`bundle/.ralph/mcp-server.sh`, `bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh`).

How Ralph handles this today: the proxy exposes a fixed tool set ---
`ralph_proxy_read/edit/write/grep/glob/search/repomap/batch`,
`ralph_proxy_result_read/search/summary`, async `shell_start`, plus the
orchestration tools --- all listed statically on `tools/list`. Crucially, a
known failure (see the mcp-nextcursor memory) is that Claude 2.1.x drops ALL
server tools when `tools/list` returns `nextCursor:null`, so the tool count and
payload size already bite Ralph. There is already a `ralph_proxy_batch` tool
(local fan-out) and a stdlib BM25 `ralph_proxy_search`
(`bundle/.ralph/python/mcp-proxy-search-rank.py`).

---

### Tool search with embeddings  (relevance: high)
URL: https://platform.claude.com/cookbook/tool-use-tool-search-with-embeddings
What it teaches: Present the model only a single `tool_search` meta-tool;
hide the full library server-side with precomputed embeddings. The model queries
in natural language, the server returns the top-k matching tool definitions as
`tool_reference` blocks, and the model uses them immediately. ~90% context
reduction; scales to thousands of tools.
Ralph today: All proxy tools are always listed. Ralph has no dynamic
discovery, and the static list already triggers the nextCursor tool-drop bug and
spends payload on tools a given plan never uses.
Opportunity: A **lexical** `ralph_proxy_tool_search` meta-tool --- the embeddings
are the cookbook's mechanism, but Ralph already owns a dependency-free BM25
ranker (`mcp-proxy-search-rank.py`) that can rank tool name+description text the
same way. Expose a minimal core set + the meta-tool, and surface the rest on
demand. This directly mitigates the nextCursor tool-drop problem by shrinking the
default `tools/list`, and it is runtime-agnostic (any MCP client benefits).
The no-new-dependencies rule (`.claude/rules/no-new-dependencies.md`) rules out a
hard embeddings dependency; document embeddings only as an optional, opt-in
enhancement if `python3` + a local model are present, never required.
Runtime mapping: Shared layer (MCP proxy). Runtime-agnostic; biggest immediate
benefit on Claude where the tool-drop bug lives.
Effort / risk: M, medium (new meta-tool + reuse BM25; Bats tests; tie to the
existing nextCursor handling).

### Programmatic tool calling (PTC)  (relevance: med)
URL: https://platform.claude.com/cookbook/tool-use-programmatic-tool-calling-ptc
What it teaches: Let the model write code that calls tools inside a code-exec
container; raw tool outputs stay in the container and only summaries return to
context. 85% token reduction on a metadata-heavy expense workload. Enabled via
`allowed_callers` + a `code_execution` tool; tool calls carry a `caller` field.
Ralph today: This is philosophically what Ralph already does outside the model:
`ralph_proxy_shell`/`shell_start` run commands, and compaction
(`shell-output-compact.py`) + result windowing keep only summaries in context.
`ralph_proxy_batch` already fans out tool calls locally.
Opportunity: PTC itself is a Claude-only beta (`advanced-tool-use-2025-11-20`).
The portable lesson: lean harder into "process locally, return summary." Ralph
could expose a `ralph_proxy_pipe`-style tool that runs a small user-provided
filter (jq/awk/grep) over a stored result and returns only the reduced output ---
giving every runtime the data-stays-out-of-context benefit without a code-exec
container. The `caller`-attribution idea also suggests Ralph's telemetry should
tag tool calls by origin (already partially done in `tool_call_classification.py`).
Runtime mapping: PTC native = Claude-only; the local-reduction pattern = shared
layer, runtime-agnostic.
Effort / risk: native PTC: out of scope (Claude beta); local-reduction tool:
M, low.

### Tool choice (auto / any / tool / none)  (relevance: med)
URL: https://platform.claude.com/cookbook/tool-use-tool-choice
What it teaches: `tool_choice` controls invocation --- `auto` (model decides,
needs careful prompting against over-eager calls), `any` (must use some tool),
`tool` (force a named tool, ideal for guaranteed structured output), `none`.
Ralph today: Ralph passes tools through to each runtime but does not set a
tool-choice contract; the model's tool selection is unconstrained, and the
discover report (`ralph-discover-report.py`) flags antipatterns like heavy
native reads after the fact. The installed Claude Code CLI does not expose a
`tool_choice` flag.
Opportunity: Where a stage's job is to *produce a structured artifact* (e.g. a
review verdict), use runtime-supported structured final-output controls when
available: Claude `--json-schema`, Codex `--output-schema` (both after capability
detection). Validate with Ralph's stdlib schema validator regardless. Other
runtimes rely on an explicit JSON prompt contract plus post-write validation.
The "prompt against over-eager tool use" guidance also reinforces Ralph's
existing antipattern detection.
Runtime mapping: Structured-output CLI flags = Claude/Codex when detected;
prompt + post-write validation = shared layer for all runtimes.
Effort / risk: S, low (capability detection + prompt fallback).

### Extracting structured JSON via tool use  (relevance: high)
URL: https://platform.claude.com/cookbook/tool-use-extracting-structured-json
What it teaches: Define a tool whose `input_schema` is your desired JSON shape,
force it with `tool_choice: tool`, and read `content.input` as validated JSON.
More reliable than free-form "JSON mode" because the schema is validated before
return; works across models. Use `required` and explicit types; `additionalProperties`
for unknown keys.
Ralph today: Agent handoff artifacts are free-form markdown
(`output_artifacts`, `orchestrator-handoffs.sh`); there is no schema validation
on what an agent produces. Ralph is jq-native and can validate JSON cheaply with
a stdlib schema subset validator.
Opportunity: Define JSON schemas for the artifacts that downstream stages
consume (review verdicts, qa results, the planner's stage list from cluster 2)
and validate before handoff. On Claude, pass compact schema JSON through
`--json-schema` when the installed CLI supports it; on Codex, use
`--output-schema` when detected. All other runtimes use prompt contracts plus
post-write validation. This underpins the evaluator-contract and
dynamic-decomposition items from cluster 2.
Runtime mapping: Ralph stdlib schema validation = shared layer; CLI structured
output = Claude/Codex when capability-detected.
Effort / risk: M, low-medium (schema files + validator in handoffs; tests).

---

## Cluster takeaways for the backlog

1. **Lexical `tool_search` meta-tool** to shrink the default `tools/list`,
   reusing the existing BM25 ranker; mitigates the nextCursor tool-drop bug.
   Embeddings optional/opt-in only. Source: tool-search-with-embeddings.
2. **JSON-schema artifact contracts** validated at handoff (`--json-schema` on
   Claude, `--output-schema` on Codex when detected; prompt + post-write
   validation elsewhere); enables the cluster-2 evaluator/planner contracts.
   Source: extracting structured JSON.
3. **Local-reduction proxy tool** (`pipe` a jq/awk/grep filter over a stored
   result, return only the summary) --- the runtime-agnostic slice of PTC.
   Source: PTC.
4. **Structured final-output enforcement** via capability-detected CLI flags,
   with Ralph schema validation as source of truth. Source: tool choice (API
   concept; not a Claude Code CLI flag).
