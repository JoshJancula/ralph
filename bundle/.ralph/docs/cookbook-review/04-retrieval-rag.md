# Cluster 4: Retrieval and RAG

Source cookbooks reviewed (4; text-to-SQL noted but not deep-read as low
relevance --- Ralph is not a SQL front-end). These map onto Ralph's code-search
surface: the BM25 lexical ranker
(`bundle/.ralph/python/mcp-proxy-search-rank.py`, stdlib, IDF-weighted, with
definition-pattern boosting) behind `ralph_proxy_search`, and the ctags-based
repo-map (`bundle/.ralph/python/repo_map.py`) behind `ralph_proxy_repomap`.

How Ralph handles this today: retrieval is purely lexical --- BM25 over file
content plus a symbol digest from ctags. There is no semantic/embedding index, no
chunk contextualization, no rerank pass, and no retrieval-quality measurement.
The dependency constraint (`.claude/rules/no-new-dependencies.md`) deliberately
forbids embedding/vector libraries, so the cookbook techniques must be adapted to
lexical-first, not adopted wholesale.

---

### Enhancing RAG with contextual retrieval  (Sep 2024, relevance: high)
URL: https://platform.claude.com/cookbook/capabilities-contextual-embeddings-guide
What it teaches: Prepend a short model-generated "situating" description to each
chunk *before* indexing, so a fragment carries its document context. Cuts
top-20 retrieval failures by 35%. Generated cheaply with prompt caching (cache
the document, 90% discount per chunk; 69% cost saving). Best results come from
**hybrid** retrieval --- contextual embeddings + contextual BM25 fused with
reciprocal rank fusion --- then a rerank pass (Pass@10 87% to 95%). Notably ~45%
of final hits came from BM25-only matches.
Ralph today: BM25 over raw file chunks with no context header; no fusion, no
rerank. The cookbook's own finding --- that BM25 alone carries ~45% of hybrid
results, especially for exact identifiers --- validates Ralph's lexical-first
choice for code search.
Opportunity: Adopt the *contextual prepend* idea without embeddings. Before BM25
scoring, prepend a cheap, deterministic context header to each chunk that Ralph
can build with no model call: file path, enclosing symbol (already available from
the ctags repo-map), and section heading. This is "contextual BM25" minus the
embedding half --- a dependency-free slice of the technique that should
measurably raise hit quality for code. Reranking with a model is available only
where a runtime can be invoked cheaply; treat as optional.
Runtime mapping: Shared layer (search proxy + repo-map). Runtime-agnostic.
Effort / risk: M, low-medium (header construction reuses repo-map symbols;
needs a ranking test in `tests/python/test_mcp_proxy_search_rank.py`).

### Retrieval augmented generation (optimization + evaluation)  (Jul 2024, relevance: high)
URL: https://platform.claude.com/cookbook/capabilities-retrieval-augmented-generation-guide
What it teaches: Practical levers --- summary indexing, model reranking, chunk
by heading not arbitrary tokens, tune k. But the durable lesson is the
**evaluation framework**: measure retrieval (precision, recall, F1, MRR)
separately from end-to-end answer quality (LLM-as-judge), using a synthetic
eval set with known-correct chunks. MRR jumped 0.74 to 0.87 with summary
indexing + rerank.
Ralph today: Ralph has no retrieval-quality measurement at all --- search
ranking changes are validated only by unit assertions on scoring, not by
recall/MRR over a labelled set.
Opportunity: Build a small, checked-in retrieval eval set (queries to
known-relevant files in this repo) and compute precision/recall/MRR in a stdlib
Python test. This turns search-ranking tuning from "vibes" into a regression
gate, and it is exactly the harness needed to prove the contextual-BM25 change
above actually helps. Chunk-by-heading also applies directly to how Ralph splits
files for search/compaction.
Runtime mapping: Shared layer (offline eval of Ralph's own ranker). Runtime-agnostic.
Effort / risk: M, low (stdlib test + small fixture set; no deps).

### Summarization with Claude  (Aug 2024, relevance: med)
URL: https://platform.claude.com/cookbook/capabilities-summarization-guide
What it teaches: Chunk long docs, summarize chunks with a cheap model (Haiku),
then meta-summarize with a stronger model (hierarchical summarization). Guided
summaries with an explicit framework (parties/terms/dates...) and XML/structured
output parse reliably. Summary-indexed retrieval ranks documents by summary
relevance. Notes summarization eval is subjective --- use ROUGE + pass/fail
frameworks.
Ralph today: Ralph's compaction (`shell-output-compact.py`) is family-rule
extraction, not hierarchical model summarization; the between-todo continuation
summary proposed in cluster 1 is the natural place for guided/structured
summaries.
Opportunity: Apply two ideas to the cluster-1 continuation summary: (1) a
*guided* template with an explicit framework (completed / state / errors / next
steps) rather than free-form, and (2) hierarchical summarization for very long
runs --- summarize per-todo, then meta-summarize across todos. The Haiku-for-
chunks / Opus-for-synthesis split reuses Ralph's per-agent model selection.
Runtime mapping: Shared layer (summary policy); model split leverages per-agent
`models` frontmatter.
Effort / risk: S-M, low (extends the cluster-1 item).

### Classification with Claude  (May 2024, relevance: med)
URL: https://platform.claude.com/cookbook/capabilities-classification-guide
What it teaches: Progressive accuracy (70% to 97%) via structured XML prompts +
temperature 0, then few-shot RAG (retrieve similar labelled examples), then
chain-of-thought scratchpad before the label. Evaluate with accuracy / per-class
precision-recall / confusion matrix over a labelled set.
Ralph today: Ralph already does rule-based classification in several places ---
`plan-todo-risk-classify.py` (manual/verification/destructive/implementation
gates), `tool_call_classification.py` (accounting buckets),
`shell-command-registry.py` (command families) --- all deterministic, no model.
Opportunity: Where deterministic rules are brittle (e.g. the router stage from
cluster 2, or risk classification of ambiguous todos), the few-shot + CoT pattern
is the upgrade path: keep the rule-based fast path, fall back to a model
classifier with retrieved examples only on low-confidence cases. The evaluation
discipline (confusion matrix over a labelled fixture) should back any such
classifier, mirroring the retrieval eval set above.
Runtime mapping: Rule-based = shared layer (have it); model fallback =
runtime-agnostic via any invoked runtime.
Effort / risk: M, medium (only if a model classifier is added; otherwise just
the eval-discipline note).

---

## Cluster takeaways for the backlog

1. **Contextual BM25.** Prepend a deterministic context header (path + enclosing
   symbol from repo-map + heading) to chunks before scoring --- dependency-free
   slice of contextual retrieval. Source: contextual retrieval.
2. **Retrieval eval harness.** Checked-in query->relevant-file fixture +
   precision/recall/MRR stdlib test; makes ranking changes a regression gate and
   proves the contextual-BM25 win. Source: RAG guide.
3. **Guided/hierarchical continuation summary.** Upgrade the cluster-1 summary
   with an explicit framework and per-todo->meta summarization for long runs.
   Source: summarization guide.
4. **(Optional) model classifier fallback** for low-confidence routing/risk
   cases, backed by a confusion-matrix eval. Source: classification guide.
