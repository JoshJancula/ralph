# Ralph Savings Report

Across 1 plan run, Ralph's tool-output optimizations netted **6,490 bytes** (~2,287 tokens) after stored-result readbacks.

Of the tool output Ralph inspected, it trimmed 19.8% before the AI read it (net of stored-result readbacks).

Bytes are measured from actual output differences; token figures are estimated (some or all from a bytes/4-equivalent fallback where actual-text token data was unavailable -- see Data quality below). These are tool-output counterfactuals, not a discount off the billed session tokens below. All Ralph token figures are estimates, never provider-measured billed tokens.

> **Generated file -- do not hand-edit.** Regenerate via `ralph benchmark --write-doc`.

Ralph recorded 24 optimization events across 1,599 tool calls; optimization events are not unique-call coverage.

## Session usage

Actual billed token usage from the session:

| Metric | Count |
| --- | --- |
| Input tokens | 2,118,868 |
| Output tokens | 653,096 |
| Cache creation input tokens | 911,797 |
| Cache read input tokens | 75,123,455 |
| Prompt bytes | 195,188 |
| Tool calls total | 1,599 |

Context reuse: **75,123,455** cache-read tokens (hit ratio **96.1%**). Cache reuse is not counted as savings above.

## Tool output: with vs without Ralph

Estimated tool-output bytes/tokens that would have reached the model with vs without Ralph. 'Actual with Ralph' includes stored-result readbacks that re-consumed tool output.

| Metric | Bytes | Tokens |
| --- | --- | --- |
| Hypothetical without Ralph | 32,768 | 12,102 |
| Actual with Ralph | 26,278 | 9,815 |
| Net savings | 6,490 | 2,287 |
| Net savings rate | 19.8% | - |

## Unverified historical estimate

A further **10,063 bytes** (~4,966 tokens) across 20 event(s) were recorded by legacy telemetry that predates the inline-candidate baseline. **These are excluded from the savings figures above and should not be quoted.**

Legacy records measure savings against the full stored source rather than against what would actually have been inlined. Tool-level limits (grep's `head_limit`, read's `maxReadBytes`, the result byte caps) would have trimmed most of that source before the model ever saw it, so crediting all of it as "saved" systematically overstates the benefit. The true baseline is not recoverable from these records -- which is why the v2 measurement exists. The number is shown to make the gap visible, not to be added to the headline.

## Hook status by runtime

| Runtime | Channel | Status | Reasons |
| --- | --- | --- | --- |
| claude | auto_background | enabled | proven_channel:mode_default |
| claude | bash_compact | enabled | proven_channel:explicit_env |
| claude | bash_rewrite | disabled | gate_disabled |
| claude | native_result_compact | disabled | gate_disabled |
| claude | proxy_shell_compact | enabled | proven_channel:explicit_env |
| cursor | auto_background | enabled | channel_unsupported_on_runtime |
| cursor | bash_compact | enabled | runtime_cannot_mutate_output |
| cursor | bash_rewrite | disabled | gate_disabled |
| cursor | native_result_compact | disabled | gate_disabled |
| cursor | proxy_shell_compact | enabled | proven_channel:explicit_env |

## Result windowing by source tool

| Tool | Events | Inline candidate bytes | Delivered bytes | Net consumed bytes | Net saved bytes | Source-capped | Quality |
| --- | --- | --- | --- | --- | --- | --- | --- |
| bash | 20 | 13,840 | 3,777 | 3,777 | 10,063 | 0 | legacy |
| ralph_proxy_shell | 4 | 32,768 | 26,278 | 26,278 | 6,490 | 0 | v2 |

## Data quality

- Token-figure quality: **legacy_or_mixed** -- some or all token counterfactuals used a bytes/4-equivalent fallback rather than an estimate over actual text.

## Optimization by channel

Exact channel attribution shows where tool-output savings came from. Gross readback is diagnostic follow-up cost; net consumed is the decision-grade bytes agents actually re-read after windowing.

### Exact attribution

| Channel | Attribution | Saved bytes | Saved tokens | Gross readback | Net consumed |
| --- | --- | --- | --- | --- | --- |
| Native shell hook compaction | exact | 8,257 | 4,077 | - | 3,777 |

### Legacy / unknown attribution

Historical runs without channel metadata are grouped here. Treat these totals as approximate until a new run records exact channels.

| Channel | Attribution | Saved bytes | Saved tokens | Gross readback | Net consumed |
| --- | --- | --- | --- | --- | --- |
| Stored result readback | legacy (unknown) | 5,290 | 1,697 | - | 26,278 |

## Per run

| Run | Date | Gross trim % | Net savings % | Without Ralph bytes | With Ralph bytes |
| --- | --- | --- | --- | --- | --- |
| PLAN18.plan | 2026-09-14T19:21:48Z to 2026-09-14T22:38:06Z | 35.5% | 19.8% | 32,768 | 26,278 |

## Stored result follow-ups

Result windowing sends a compact preview; follow-up reads add bytes back. Effective windowing savings rate is the decision-grade net signal after capping readbacks at the original envelope size.

- Envelopes: **24**; readbacks: **0** (compacted **0**, raw **0**). Full preview re-reads: **0**.
- Gross follow-up reads: **0 bytes** (~0 tokens); net consumed: **30,055 bytes** (~11,354 tokens).
- Effective windowing savings rate: **35.5%** of original envelope bytes (net of capped readbacks).

## Improvement opportunities

Guidance sourced from the most recent eligible run: `PLAN18.plan` at 2026-09-14T22:38:06Z.

Usage pattern opportunities:
- `native_read_after_grep`: Native read immediately after grep in tool_calls_sequence
- `repeated_native_read_like`: Consecutive native read/search tool calls in tool_calls_sequence

Native read findings:
- `heavy_native_read_vs_proxy`: 92.0% of read-like calls were native reads.

## How to read this

- **Session usage** shows cumulative billed tokens (input/output/cache) from the plan run (these are the actual API call totals across all invocations). This is independent of the estimated tool-output counterfactuals below.
- **Tool output: with vs without Ralph** estimates the bytes/tokens that would have reached the model from tool output if Ralph had not trimmed it. These are counterfactual estimates of what the model would have ingested, not a discount off the billed session input tokens above. 'Actual with Ralph' includes follow-up stored-result readbacks, so heavy rereads can drive net savings toward zero even when previews were compact.
- **Optimization by channel** is the authoritative breakdown of where savings came from. Exact channels come from runtime telemetry; legacy/unknown rows reflect historical runs without channel metadata.
- **Net savings** (in the Tool output table) is the estimated reduction in bytes/tokens sent to the model after Ralph's optimizations. This is measured from tool-output differences only, not from the billed session usage totals.
- **Stored result follow-ups** distinguishes gross re-read bytes (diagnostic) from net effective windowing savings. A high gross negation rate is expected when agents escalate to raw or full-preview views.
- **Why savings are low** prints root causes only when the net savings rate is near 0%: inactive paths, readback-negated windowing, or compaction measured but not applied.
- This report does not measure end-to-end wall-clock speedup.

Date range: 2026-09-14T19:21:48Z to 2026-09-14T22:38:06Z.
