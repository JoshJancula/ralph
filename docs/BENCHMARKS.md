# Ralph Savings Report

Across 1 plan run, Ralph's tool-output optimizations netted **102,169 bytes** (~25,543 tokens) after stored-result readbacks.

Of the tool output Ralph inspected, it trimmed 43.6% before the AI read it (net of stored-result readbacks).

Bytes are measured from actual output differences; token figures are estimated at roughly 4 bytes per token. These are tool-output counterfactuals, not a discount off the billed session tokens below.

> **Generated file -- do not hand-edit.** Regenerate via `ralph benchmark --write-doc`.

## Session usage

Actual billed token usage from the session:

| Metric | Count |
| --- | --- |
| Input tokens | 14,423,920 |
| Output tokens | 109,007 |
| Cache creation input tokens | 2,426,467 |
| Cache read input tokens | 29,124,154 |
| Prompt bytes | 129,150 |
| Tool calls total | 636 |

Context reuse: **29,124,154** cache-read tokens (hit ratio **63.3%**). Cache reuse is not counted as savings above.

## Tool output: with vs without Ralph

Estimated tool-output bytes/tokens that would have reached the model with vs without Ralph. 'Actual with Ralph' includes stored-result readbacks that re-consumed tool output.

| Metric | Bytes | Tokens |
| --- | --- | --- |
| Hypothetical without Ralph | 234,473 | 58,619 |
| Actual with Ralph | 132,304 | 33,076 |
| Net savings | 102,169 | 25,543 |
| Net savings rate | 43.6% | - |

## Per run

| Run | Date | Bytes saved (measured) | Est. tokens saved | Trimmed % (of inspected output) |
| --- | --- | --- | --- | --- |
| agent-source-resolver.plan | 2026-06-17T06:02:13Z to 2026-06-17T17:09:00Z | 102,169 | 25,290 | 43.6% |

## Stored result follow-ups

Result windowing sends a compact preview; follow-up reads add bytes back. Effective windowing savings rate is the decision-grade net signal after capping readbacks at the original envelope size.

- Envelopes: **20**; readbacks: **27** (compacted **16**, raw **11**). Full preview re-reads: **9**.
- Gross follow-up reads: **189,615 bytes** (~62,496 tokens); net consumed: **131,876 bytes** (~44,091 tokens).
- Effective windowing savings rate: **1.1%** of original envelope bytes (net of capped readbacks).
- Raw readback share: **40.7%** of follow-up reads; diagnostic gross negation rate: **142.3%** of envelope original bytes.

## Improvement opportunities

Missed compaction opportunities:
- `compaction_skipped` (12,070 bytes)
- `compaction_skipped` (12,070 bytes)
- `compaction_skipped` (12,070 bytes)

Usage pattern opportunities:
- `native_read_after_grep`: Native read immediately after grep in tool_calls_sequence
- `repeated_native_read_like`: Consecutive native read/search tool calls in tool_calls_sequence

## How to read this

- **Session usage** shows actual billed tokens (input/output/cache) from the plan run; it is independent of the estimated tool-output counterfactuals.
- **Tool output: with vs without Ralph** estimates the bytes/tokens that reached the model from tool output. 'Actual with Ralph' includes follow-up stored-result readbacks, so heavy rereads can drive net savings toward zero even when previews were compact.
- **Stored result follow-ups** distinguishes gross re-read bytes (diagnostic) from net effective windowing savings. A high gross negation rate is expected when agents escalate to raw or full-preview views.
- **Why savings are low** prints root causes only when the net savings rate is near 0%: inactive paths, readback-negated windowing, or compaction measured but not applied.
- This report does not measure end-to-end wall-clock speedup.

Date range: 2026-06-17T06:02:13Z to 2026-06-17T17:09:00Z.