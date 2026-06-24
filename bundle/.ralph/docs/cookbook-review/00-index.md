# Claude cookbook review for the Ralph ecosystem

This directory is a research artifact: a systematic review of Anthropic's Claude
cookbooks (https://platform.claude.com/cookbook/, 83 recipes as of June 2026)
read with one question in mind --- **what can each technique teach us about
improving the whole Ralph ecosystem across all 5 runtimes (claude, cursor,
codex, opencode, antigravity), not just the Claude path?**

It is documentation only. No runtime code, Python helpers, or tests were
changed during the initial review pass. The actionable output is
[BACKLOG.md](./BACKLOG.md); [MIGRATION.md](./MIGRATION.md) and
[IMPLEMENTATION-RESULTS.md](./IMPLEMENTATION-RESULTS.md) track integration and
baselines. The cluster files are the reasoning behind the backlog.

## How to read this

Cookbooks are grouped into 7 clusters by the Ralph subsystem they touch. Each
cluster file reviews its cookbooks with a consistent template:

- **What it teaches** --- the technique, condensed.
- **Ralph today** --- what already exists, cited to real file paths (every cited
  path was confirmed to exist; see the verification note below).
- **Opportunity** --- a concrete, *runtime-agnostic-first* improvement.
- **Runtime mapping** --- shared layer vs Claude-only vs per-runtime.
- **Effort / risk** --- S/M/L, low/med/high.

## Clusters

| File | Cluster | Core Ralph subsystem |
|------|---------|----------------------|
| [01-context-memory.md](./01-context-memory.md) | Context engineering, compaction, memory | compaction, result windowing, session strategy |
| [02-agent-patterns.md](./02-agent-patterns.md) | Agent patterns and orchestration | orchestrator, agents, loopControl |
| [03-tool-use.md](./03-tool-use.md) | Tool use | MCP proxy, tool surface, BM25 search |
| [04-retrieval-rag.md](./04-retrieval-rag.md) | Retrieval and RAG | BM25 ranker, repo-map |
| [05-caching-cost.md](./05-caching-cost.md) | Prompt caching, batching, cost observability | prompt assembly, cache estimation, benchmark reports |
| [06-output-quality.md](./06-output-quality.md) | Evals, citations, structured output, thinking | verification, telemetry, handoff artifacts |
| [07-skills.md](./07-skills.md) | Skills | agent/rule/skill packaging and loading |

## Relevance tiers and what was excluded

Coverage is the ~37 cookbooks relevant to an agentic CLI orchestrator. The
following categories were deliberately **not deep-read** (noted as not-applicable
rather than analyzed), per the agreed scope:

- Multimodal / vision (crop tool, charts, transcription, vision-with-tools).
- Voice (ElevenLabs low-latency assistant).
- Demo applications (Slack data bot, data-analyst agent, SRE responder, customer
  service agent) --- useful as patterns but covered abstractly by cluster 2.
- Third-party vector DBs and frameworks (Pinecone, MongoDB, LlamaIndex,
  LangChain, Wolfram, Deepgram) --- the dependency-free constraint
  (`.claude/rules/no-new-dependencies.md`) rules these out as direct adoptions;
  the underlying RAG ideas are covered in cluster 4.
- Managed Agents / Agent SDK hosting and SDK-migration recipes --- Ralph drives
  CLIs, not the SDK; the portable patterns (outcomes/verify, multi-agent,
  memory) are pulled into clusters 1, 2, 6.

## Cross-cutting constraints applied to every opportunity

- **No new dependencies.** Any embeddings/vector idea is reframed as a
  dependency-free lexical adaptation or flagged as optional/opt-in (python3 +
  local model only if present). Ralph stays POSIX bash + jq + optional python3.
- **Runtime-agnostic first.** Improvements that live in Ralph's shared layer
  (MCP proxy, orchestrator, prompt assembly, python helpers) are preferred;
  Claude-native API mechanisms (`cache_control`, `tool_choice`, native
  citations, native Skills) are **not** assumed available through the installed
  Claude Code CLI. Ralph uses capability detection for `--system-prompt`,
  `--json-schema`, and Codex `--output-schema` where present, and prompt plus
  post-write validation everywhere else.
- **Opt-in modes.** Anything that changes default behavior follows the
  RALPH_MODE opt-in discipline (`.claude/rules/ralph-mode-opt-in-required.md`).

## Verification of this artifact

Every `file:`-style path cited under "Ralph today" was confirmed present during
the review. The cluster docs contain no emojis (per
`.claude/rules/no-emoji.md`). See BACKLOG.md for the prioritized, cross-runtime
roadmap distilled from these clusters.

## Sources

- Cookbook index: https://platform.claude.com/cookbook/
- Repository: https://github.com/anthropics/claude-cookbooks
